import AppKit
import Foundation
import UserNotifications

// Optional update checks while Reforge is closed.
//
// When turned on in Settings, a per-user LaunchAgent runs this same executable with
// `--background-check` every few hours. That run loads the saved settings and API key, asks
// CurseForge whether anything is newer (it never downloads or installs), posts one notification
// if there's something it hasn't mentioned yet, and exits. Nothing stays running between checks.

/// Runs the background check on a schedule, or stops it.
protocol BackgroundScheduler {
    /// Checks every `hours` hours; nil turns it off. Cheap to call again with the same value.
    func set(hours: Int?) throws
}

/// Posts the "updates available" notification.
protocol UpdateNotifier {
    /// Asks for permission the first time; afterwards just reports it. False if not allowed.
    func requestPermission() async -> Bool
    func post(title: String, body: String) async
}

enum BackgroundCheck {
    static let argument = "--background-check"
    static let intervals = [1, 3, 6, 12, 24]
    static let defaultHours = 6

    /// Which update (project id -> file id) each addon was last notified about, so the same
    /// update isn't announced every few hours.
    struct State: Codable, Equatable {
        var notified: [Int: Int] = [:]
    }

    enum Outcome: Equatable {
        case disabled, skipped, failed, nothingNew, notified(String)
    }

    /// One check. `appIsOpen`: the window already shows updates, so don't notify.
    @MainActor
    static func run(model: Model, stateFile: URL, notifier: UpdateNotifier, appIsOpen: Bool) async -> Outcome {
        guard model.config.backgroundCheckHours != nil else { return .disabled }
        guard !model.needsOnboarding, model.hasKey, !model.config.addons.isEmpty, !appIsOpen else { return .skipped }
        await model.checkForUpdates()
        guard model.lastChecked != nil else { return .failed }

        var current: [Int: Int] = [:]
        for a in model.updatable { if let f = model.latest[a.id] { current[a.id] = f.id } }
        let old = loadState(stateFile)
        let fresh = model.updatable.filter { old.notified[$0.id] != current[$0.id] }
        // Forget addons that were updated (or dropped) so a later release gets announced again.
        let new = State(notified: current)
        if new != old { saveState(new, to: stateFile) }
        guard !fresh.isEmpty else { return .nothingNew }

        let body = message(for: model.updatable.map(\.name))
        await notifier.post(title: "Addon updates available", body: body)
        return .notified(body)
    }

    /// "Alpha has an update." / "Alpha and Bravo have updates." / "Alpha, Bravo and 3 more have updates."
    static func message(for names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) has an update."
        case 2: return "\(names[0]) and \(names[1]) have updates."
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more have updates."
        }
    }

    static var stateFile: URL { Store.dir.appendingPathComponent("background-check.json") }

    static func loadState(_ file: URL) -> State {
        guard let data = try? Data(contentsOf: file) else { return State() }
        return (try? JSONDecoder().decode(State.self, from: data)) ?? State()
    }

    static func saveState(_ state: State, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: file, options: .atomic)
    }

    /// Entry point for the LaunchAgent's run: check once, then exit. Never returns.
    @MainActor
    static func runFromLaunchAgent() -> Never {
        Task { @MainActor in
            let model = Model()
            let me = getpid()
            let open = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .contains { $0.processIdentifier != me }
            let outcome = await run(model: model, stateFile: stateFile, notifier: SystemNotifier(), appIsOpen: open)
            NSLog("Reforge background check: \(outcome)")
            exit(0)
        }
        dispatchMain()
    }
}

/// macOS notifications. Clicking one opens Reforge, which checks for updates as it opens.
struct SystemNotifier: UpdateNotifier {
    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A fixed id: a newer notification replaces the previous one instead of piling up.
        let request = UNNotificationRequest(identifier: "updates", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// `~/Library/LaunchAgents/<bundle id>.update-check.plist`, loaded with launchctl. The label comes
/// from the bundle ID, so the dev build (local.reforge.dev) never replaces the installed app's agent.
struct LaunchAgentScheduler: BackgroundScheduler {
    var label = (Bundle.main.bundleIdentifier ?? "local.reforge") + ".update-check"
    var agentsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    var executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    /// Dev mode passes its settings folder along so the check reads `.dev/`, not your real setup.
    var environment: [String: String] = DevMode.dir.map { ["REFORGE_DEV_DIR": $0.path] } ?? [:]
    /// Runs launchctl with these arguments and returns its exit status.
    var launchctl: ([String]) -> Int32 = LaunchAgentScheduler.runLaunchctl

    struct Failed: LocalizedError {
        var errorDescription: String? { "launchctl couldn't load the background check." }
    }

    var plistFile: URL { agentsDir.appendingPathComponent("\(label).plist") }
    private var domain: String { "gui/\(getuid())" }

    func plist(hours: Int) throws -> Data {
        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, BackgroundCheck.argument],
            "StartInterval": hours * 3600,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
        ]
        if !environment.isEmpty { dict["EnvironmentVariables"] = environment }
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    func set(hours: Int?) throws {
        let fm = FileManager.default
        guard let hours else {
            guard fm.fileExists(atPath: plistFile.path) else { return }
            _ = launchctl(["bootout", "\(domain)/\(label)"])
            try fm.removeItem(at: plistFile)
            return
        }
        let data = try plist(hours: hours)
        // Already scheduled exactly like this (launchd loads it again at every login).
        if (try? Data(contentsOf: plistFile)) == data { return }
        _ = launchctl(["bootout", "\(domain)/\(label)"])   // fails harmlessly if not loaded
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try data.write(to: plistFile, options: .atomic)
        guard launchctl(["bootstrap", domain, plistFile.path]) == 0 else {
            try? fm.removeItem(at: plistFile)
            throw Failed()
        }
    }

    static func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
