import AppKit
import ApplicationServices
import Foundation
import Testing

// Drives a real, bundled Reforge.app through the macOS Accessibility API.
//
// Elements are found by their SwiftUI `.accessibilityIdentifier` (AXIdentifier) and pressed with
// AXPress, so nothing depends on window position, screen coordinates or the mouse. The flip side:
// AXPress skips real hit-testing, so these tests can't catch click-routing bugs such as the old
// title-bar toolbar swallowing clicks on the header buttons. We deliberately don't synthesize
// CGEvents to cover that.

struct E2EError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The repo's dev build, "build/Reforge Dev.app" (built by ./build.sh), or REFORGE_APP_PATH.
let reforgeAppURL: URL = {
    if let path = ProcessInfo.processInfo.environment["REFORGE_APP_PATH"], !path.isEmpty {
        return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/Reforge Dev.app")
}()

/// One launched instance of Reforge running in E2E stub mode.
final class AXApp {
    let running: NSRunningApplication
    let root: AXUIElement
    /// Default wait for any single condition. Generous, but bounded.
    var timeout: Duration = .seconds(10)

    private init(running: NSRunningApplication) {
        self.running = running
        root = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 5)
    }

    /// Launches a fresh instance with REFORGE_E2E_FIXTURE set. Always pair with `terminate()`.
    static func launch(fixture: URL, environment: [String: String] = [:]) async throws -> AXApp {
        guard AXIsProcessTrusted() else {
            throw E2EError("""
                Accessibility permission is missing, so the E2E tests can't drive Reforge.app.
                Grant it to the app running the tests (your terminal or IDE) in System Settings →
                Privacy & Security → Accessibility, then restart that app and run `make e2e` again.
                """)
        }
        // While the screen is locked or the display asleep, macOS hides window contents from the
        // Accessibility API, so every lookup would time out. Say so instead.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true || CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            throw E2EError("The screen is locked or the display is asleep. UI tests need an unlocked, awake Mac.")
        }
        guard FileManager.default.fileExists(atPath: reforgeAppURL.path) else {
            throw E2EError("\(reforgeAppURL.path) not found. Run ./build.sh first (make e2e does this).")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.addsToRecentItems = false
        config.environment = environment.merging(["REFORGE_E2E_FIXTURE": fixture.path]) { $1 }
        // Don't restore windows from a previous (possibly real) session.
        config.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let running = try await NSWorkspace.shared.openApplication(at: reforgeAppURL, configuration: config)
        let app = AXApp(running: running)
        do {
            try await app.waitFor("a window") { !app.windows.isEmpty }
        } catch {
            app.terminate()
            throw error
        }
        return app
    }

    /// Kills the app. Safe to call more than once; used in every test's cleanup path.
    func terminate() {
        guard !running.isTerminated else { return }
        running.forceTerminate()
    }

    // MARK: Queries

    var windows: [AXUIElement] { root.children(kAXWindowsAttribute) }

    /// Depth-first search of every window (sheets included) for an AXIdentifier.
    func find(_ id: String) -> AXUIElement? {
        for w in windows { if let hit = Self.find(id, in: w, depth: 0) { return hit } }
        return nil
    }

    private static func find(_ id: String, in el: AXUIElement, depth: Int) -> AXUIElement? {
        if el.string(kAXIdentifierAttribute) == id { return el }
        guard depth < 80 else { return nil }
        for child in el.children(kAXChildrenAttribute) {
            if let hit = find(id, in: child, depth: depth + 1) { return hit }
        }
        return nil
    }

    /// Presses an item in the menu bar, e.g. ("Reforge", "Settings"). Matches the item's title by
    /// prefix so "Settings…" matches "Settings". The menu doesn't need to be open.
    func pressMenuItem(_ menu: String, titled title: String,
                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var item: AXUIElement?
        try await waitFor("menu item \(menu) → \(title)", sourceLocation: sourceLocation) {
            guard let bar = root.attribute(kAXMenuBarAttribute) else { return false }
            let barItem = (bar as! AXUIElement).children(kAXChildrenAttribute)
                .first { $0.string(kAXTitleAttribute) == menu }
            item = barItem?.children(kAXChildrenAttribute).first?.children(kAXChildrenAttribute)
                .first { $0.string(kAXTitleAttribute)?.hasPrefix(title) == true }
            return item != nil
        }
        let err = AXUIElementPerformAction(item!, kAXPressAction as CFString)
        try #require(err == .success, "AXPress on \(menu) → \(title) failed: \(err.rawValue)", sourceLocation: sourceLocation)
    }

    /// Performs a standard action, e.g. kAXIncrementAction on a picker made `.adjustable`.
    func perform(_ action: String, on id: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let el = try await element(id, sourceLocation: sourceLocation)
        let err = AXUIElementPerformAction(el, action as CFString)
        try #require(err == .success, "\(action) on \(id) failed: \(err.rawValue)", sourceLocation: sourceLocation)
    }

    /// Presses the child of `id` with this title, e.g. one segment of a segmented picker.
    func pressChild(of id: String, titled title: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let parent = try await element(id, sourceLocation: sourceLocation)
        func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
            if el.string(kAXTitleAttribute) == title || el.string(kAXDescriptionAttribute) == title { return el }
            guard depth < 6 else { return nil }
            for c in el.children(kAXChildrenAttribute) { if let hit = search(c, depth: depth + 1) { return hit } }
            return nil
        }
        let child = try #require(search(parent, depth: 0), "\(id) has no child titled \(title)", sourceLocation: sourceLocation)
        let err = AXUIElementPerformAction(child, kAXPressAction as CFString)
        try #require(err == .success, "AXPress on \(title) failed: \(err.rawValue)", sourceLocation: sourceLocation)
    }

    /// Closes the window whose title contains `title` with its close button.
    func closeWindow(titled title: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var window: AXUIElement?
        try await waitFor("a window titled \(title)", sourceLocation: sourceLocation) {
            window = windows.first { $0.string(kAXTitleAttribute)?.contains(title) == true }
            return window != nil
        }
        let close = try #require(window!.attribute(kAXCloseButtonAttribute).map { $0 as! AXUIElement },
                                 "\(title) has no close button", sourceLocation: sourceLocation)
        AXUIElementPerformAction(close, kAXPressAction as CFString)
    }

    /// Performs a SwiftUI `.accessibilityAction(named:)` on an element. AX lists those as
    /// "Name:<name>\nTarget:…" action strings, so match on the name line.
    func performNamedAction(_ name: String, on id: String,
                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let el = try await element(id, sourceLocation: sourceLocation)
        var names: CFArray?
        AXUIElementCopyActionNames(el, &names)
        let all = (names as? [String]) ?? []
        let action = try #require(all.first { $0 == name || $0.hasPrefix("Name:\(name)\n") || $0.hasPrefix("Name:\(name)") },
                                  "\(id) has no action named \(name); it has \(all)", sourceLocation: sourceLocation)
        let err = AXUIElementPerformAction(el, action as CFString)
        try #require(err == .success, "\(name) on \(id) failed: \(err.rawValue)", sourceLocation: sourceLocation)
    }

    /// All text in an element and its descendants (AXValue, AXTitle, AXDescription), joined.
    func text(_ id: String) -> String? { find(id).map { $0.allText() } }

    // MARK: Waiting

    /// Polls `condition` until it holds, or fails after `timeout`.
    func waitFor(_ what: String, timeout: Duration? = nil,
                 sourceLocation: SourceLocation = #_sourceLocation,
                 _ condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + (timeout ?? self.timeout)
        while true {
            if running.isTerminated { throw E2EError("Reforge quit while waiting for \(what)") }
            if try condition() { return }
            if clock.now >= deadline {
                Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
                throw E2EError("Timed out waiting for \(what)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @discardableResult
    func element(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> AXUIElement {
        var found: AXUIElement?
        try await waitFor("element \(id)", sourceLocation: sourceLocation) { found = find(id); return found != nil }
        return found!
    }

    func waitGone(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitFor("element \(id) to disappear", sourceLocation: sourceLocation) { find(id) == nil }
    }

    func waitForText(_ id: String, containing needle: String,
                     sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitFor("\(id) to contain “\(needle)” (now: “\(text(id) ?? "missing")”)",
                          sourceLocation: sourceLocation) { text(id)?.contains(needle) == true }
    }

    // MARK: Actions

    /// Waits for the element to exist and be enabled, then sends AXPress.
    func press(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var target: AXUIElement?
        try await waitFor("\(id) to be enabled", sourceLocation: sourceLocation) {
            target = find(id)
            return target?.bool(kAXEnabledAttribute) ?? false
        }
        let err = AXUIElementPerformAction(target!, kAXPressAction as CFString)
        guard err == .success else { throw E2EError("AXPress on \(id) failed: \(err.rawValue)") }
    }

    /// Sets a text field's AXValue (SwiftUI pushes it into the binding).
    func setValue(_ id: String, _ value: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let field = try await element(id, sourceLocation: sourceLocation)
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let err = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString)
        guard err == .success else { throw E2EError("Setting AXValue on \(id) failed: \(err.rawValue)") }
    }
}

// MARK: - AXUIElement conveniences

extension AXUIElement {
    func attribute(_ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? { attribute(name) as? String }
    func bool(_ name: String) -> Bool? { (attribute(name) as? NSNumber)?.boolValue }
    func children(_ name: String) -> [AXUIElement] { (attribute(name) as? [AXUIElement]) ?? [] }

    func allText(depth: Int = 0) -> String {
        var parts = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { string($0) }.filter { !$0.isEmpty }
        if depth < 20 {
            parts += children(kAXChildrenAttribute).map { $0.allText(depth: depth + 1) }.filter { !$0.isEmpty }
        }
        return parts.joined(separator: " ")
    }
}
