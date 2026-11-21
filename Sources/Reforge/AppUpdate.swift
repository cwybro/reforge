import AppKit
import Foundation
import Observation

// Updating Reforge itself from its GitHub releases.
//
// Every push to main publishes a release tagged v1.0.<build> with a Reforge.zip
// (.github/workflows/release.yml). When the setting is on, the app asks GitHub for the latest
// release when it opens. If it's newer, a banner offers to install it: the zip is downloaded,
// checked (bundle id, version, signature), swapped in place of the running app, and Reforge
// relaunches. Only the installed release build updates itself, never dev builds.

/// A dotted version such as 1.0.42, compared number by number (1.0 < 1.0.1 < 1.0.10).
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    let description: String

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
        description = s
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

struct AppRelease: Equatable {
    let version: String
    /// The release's Reforge.zip.
    let downloadURL: URL
    /// The release page (notes, manual download).
    let pageURL: URL
}

/// Where releases come from; tests substitute a fake.
protocol ReleaseSource {
    /// The newest published release, or nil if there is none (or none with a Reforge.zip).
    func latest() async throws -> AppRelease?
}

/// Installs a release over the running app and relaunches it; tests substitute a fake.
protocol AppInstalling {
    func install(_ release: AppRelease, over app: URL) async throws
    func relaunch(_ app: URL)
}

/// GitHub's "latest release" for the repository (drafts and pre-releases are skipped by GitHub).
struct GitHubReleases: ReleaseSource {
    var repository = "cwybro/reforge"
    var assetName = "Reforge.zip"

    struct Payload: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let html_url: String
        let assets: [Asset]
    }

    func latest() async throws -> AppRelease? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Reforge", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await Store.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }   // no releases yet
        guard code == 200 else { throw UpdateError("GitHub answered HTTP \(code).") }
        return try Self.parse(data, assetName: assetName)
    }

    static func parse(_ data: Data, assetName: String = "Reforge.zip") throws -> AppRelease? {
        let p = try JSONDecoder().decode(Payload.self, from: data)
        guard let asset = p.assets.first(where: { $0.name == assetName }),
              let download = URL(string: asset.browser_download_url), let page = URL(string: p.html_url),
              AppVersion(p.tag_name) != nil else { return nil }
        return AppRelease(version: AppVersion(p.tag_name)!.description, downloadURL: download, pageURL: page)
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Downloads the zip, unpacks it with ditto, checks it's a Reforge release of the expected
/// version with an intact signature, and swaps it in place of the running app. The old copy
/// ends up in a temporary folder (the system clears it), not in the Trash.
struct BundleInstaller: AppInstalling {
    var bundleIdentifier = "local.reforge"

    func install(_ release: AppRelease, over app: URL) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ReforgeUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (download, resp) = try await Store.session.download(from: release.downloadURL)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        let zip = work.appendingPathComponent("Reforge.zip")
        try fm.moveItem(at: download, to: zip)

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], "Couldn't unpack the update.")
        guard let newApp = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("The update has no app inside.") }
        try Self.verify(newApp, bundleIdentifier: bundleIdentifier, version: release.version)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path], "The update's signature is broken.")

        // Swap: the running copy keeps working from its old files until it quits.
        _ = try fm.replaceItemAt(app, withItemAt: newApp, backupItemName: nil, options: [])
    }

    static func verify(_ app: URL, bundleIdentifier: String, version: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError("The download isn't a Reforge release.")
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("The download's version doesn't match the release.")
        }
    }

    /// Waits for this process to exit, then opens the (new) app.
    func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String], _ failure: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError(failure) }
    }
}

@MainActor @Observable
final class AppUpdater {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(AppRelease)
        case installing(AppRelease)
        case failed(String, AppRelease?)
    }

    private(set) var state = State.idle
    /// "Later" hides the banner until the next launch.
    var dismissed = false

    let currentVersion: String
    /// Only the installed release build updates itself (not dev builds or a copy elsewhere).
    let isSupported: Bool
    private let appURL: URL
    private let source: ReleaseSource
    private let installer: AppInstalling

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         appURL: URL = Bundle.main.bundleURL,
         isSupported: Bool = Bundle.main.bundleIdentifier == "local.reforge"
             && FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path),
         source: ReleaseSource = GitHubReleases(),
         installer: AppInstalling = BundleInstaller()) {
        self.currentVersion = currentVersion
        self.appURL = appURL
        self.isSupported = isSupported
        self.source = source
        self.installer = installer
    }

    /// Never checks or installs (previews, tests, and views that don't get a real updater).
    static let inert = AppUpdater(currentVersion: "0", appURL: URL(fileURLWithPath: "/"), isSupported: false,
                                  source: NoReleases(), installer: NoInstall())

    /// The release the banner offers, if any.
    var offered: AppRelease? {
        switch state {
        case .available(let r), .installing(let r): return r
        case .failed(_, let r): return r
        default: return nil
        }
    }

    var showsBanner: Bool { offered != nil && !dismissed }

    /// Asks GitHub for the newest release. Silent unless `manual` (the menu command), so being
    /// offline at launch never shows an error.
    func check(manual: Bool = false) async {
        guard isSupported, state != .checking else { return }
        if case .installing = state { return }
        state = .checking
        do {
            if let release = try await source.latest(),
               let latest = AppVersion(release.version), let current = AppVersion(currentVersion), current < latest {
                state = .available(release)
                if manual { dismissed = false }
            } else {
                state = .upToDate
            }
        } catch {
            state = manual ? .failed("Couldn't check for updates: \(error.localizedDescription)", nil) : .idle
        }
    }

    func install() async {
        guard let release = offered else { return }
        state = .installing(release)
        do {
            try await installer.install(release, over: appURL)
            installer.relaunch(appURL)
        } catch {
            state = .failed(error.localizedDescription, release)
        }
    }
}

private struct NoReleases: ReleaseSource { func latest() async throws -> AppRelease? { nil } }
private struct NoInstall: AppInstalling {
    func install(_ release: AppRelease, over app: URL) async throws {}
    func relaunch(_ app: URL) {}
}
