import Foundation
import Testing
@testable import Reforge

final class FakeReleases: ReleaseSource {
    var release: AppRelease?
    var error: Error?
    private(set) var calls = 0
    func latest() async throws -> AppRelease? {
        calls += 1
        if let error { throw error }
        return release
    }
}

final class FakeAppInstaller: AppInstalling {
    var error: Error?
    private(set) var installed: [(version: String, app: URL)] = []
    private(set) var relaunched: [URL] = []
    func install(_ release: AppRelease, over app: URL) async throws {
        installed.append((release.version, app))
        if let error { throw error }
    }
    func relaunch(_ app: URL) { relaunched.append(app) }
}

func release(_ version: String) -> AppRelease {
    AppRelease(version: version, downloadURL: URL(string: "https://example.invalid/v\(version)/Reforge.zip")!,
               pageURL: URL(string: "https://example.invalid/releases/v\(version)")!)
}

@Suite("App updates") @MainActor
struct AppUpdateTests {
    let app = URL(fileURLWithPath: "/Applications/Reforge.app")

    func updater(current: String = "1.0.8", supported: Bool = true, source: FakeReleases, installer: FakeAppInstaller = FakeAppInstaller()) -> AppUpdater {
        AppUpdater(currentVersion: current, appURL: app, isSupported: supported, source: source, installer: installer)
    }

    @Test(arguments: [("1.0", "1.0.1", true), ("1.0.9", "1.0.10", true), ("v1.0.10", "1.0.9", false),
                      ("1.0.0", "1.0", false), ("2", "1.9.9", false), ("1.2", "1.10", true)])
    func versionOrder(a: String, b: String, aIsOlder: Bool) throws {
        let x = try #require(AppVersion(a)), y = try #require(AppVersion(b))
        #expect((x < y) == aIsOlder)
    }

    @Test func notVersions() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("1.x") == nil)
        #expect(AppVersion("nightly") == nil)
    }

    @Test func newerReleaseShowsTheBanner() async {
        let source = FakeReleases(); source.release = release("1.0.12")
        let u = updater(source: source)
        await u.check()
        #expect(u.state == .available(release("1.0.12")))
        #expect(u.showsBanner)
        u.dismissed = true
        #expect(!u.showsBanner)
    }

    @Test(arguments: ["1.0.8", "1.0.7", "0.9"])
    func sameOrOlderReleaseIsUpToDate(version: String) async {
        let source = FakeReleases(); source.release = release(version)
        let u = updater(source: source)
        await u.check()
        #expect(u.state == .upToDate && !u.showsBanner)
    }

    @Test func noReleasesYetIsUpToDate() async {
        let u = updater(source: FakeReleases())
        await u.check()
        #expect(u.state == .upToDate)
    }

    @Test func devBuildsNeverCheck() async {
        let source = FakeReleases(); source.release = release("9.9")
        let u = updater(supported: false, source: source)
        await u.check(manual: true)
        #expect(source.calls == 0 && u.state == .idle)
    }

    @Test func offlineAtLaunchIsSilentButAManualCheckSays() async {
        let source = FakeReleases(); source.error = URLError(.notConnectedToInternet)
        let u = updater(source: source)
        await u.check()
        #expect(u.state == .idle && !u.showsBanner)
        await u.check(manual: true)
        guard case .failed(let why, nil) = u.state else { Issue.record("expected a failure, got \(u.state)"); return }
        #expect(why.hasPrefix("Couldn't check for updates"))
    }

    @Test func manualCheckBringsBackADismissedBanner() async {
        let source = FakeReleases(); source.release = release("1.0.12")
        let u = updater(source: source)
        await u.check()
        u.dismissed = true
        await u.check(manual: true)
        #expect(u.showsBanner)
    }

    @Test func installReplacesTheAppThenRelaunches() async {
        let source = FakeReleases(); source.release = release("1.0.12")
        let installer = FakeAppInstaller()
        let u = updater(source: source, installer: installer)
        await u.check()
        await u.install()
        #expect(installer.installed.map(\.version) == ["1.0.12"])
        #expect(installer.installed.first?.app == app)
        #expect(installer.relaunched == [app])
    }

    @Test func failedInstallKeepsTheBannerWithTheReason() async {
        let source = FakeReleases(); source.release = release("1.0.12")
        let installer = FakeAppInstaller(); installer.error = UpdateError("The download failed.")
        let u = updater(source: source, installer: installer)
        await u.check()
        await u.install()
        #expect(u.state == .failed("The download failed.", release("1.0.12")))
        #expect(u.showsBanner && installer.relaunched.isEmpty)
    }

    @Test func parsesGitHubsLatestRelease() throws {
        let json = """
        {"tag_name": "v1.0.12", "html_url": "https://github.com/cwybro/reforge/releases/tag/v1.0.12", "draft": false,
         "assets": [{"name": "notes.txt", "browser_download_url": "https://example.invalid/notes.txt"},
                    {"name": "Reforge.zip", "browser_download_url": "https://github.com/cwybro/reforge/releases/download/v1.0.12/Reforge.zip"}]}
        """
        let r = try #require(try GitHubReleases.parse(Data(json.utf8)))
        #expect(r.version == "1.0.12")
        #expect(r.downloadURL.absoluteString.hasSuffix("/v1.0.12/Reforge.zip"))
        #expect(r.pageURL.absoluteString.hasSuffix("/tag/v1.0.12"))

        let noZip = #"{"tag_name": "v1.0.13", "html_url": "https://x.invalid", "assets": []}"#
        #expect(try GitHubReleases.parse(Data(noZip.utf8)) == nil)
    }

    @Test func downloadedAppMustBeAReforgeReleaseOfThatVersion() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        func app(_ id: String, _ version: String) throws -> URL {
            let url = dir.appendingPathComponent("\(UUID().uuidString).app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try (["CFBundleIdentifier": id, "CFBundleShortVersionString": version] as NSDictionary)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            return url
        }
        #expect(throws: Never.self) { try BundleInstaller.verify(try app("local.reforge", "1.0.12"), bundleIdentifier: "local.reforge", version: "1.0.12") }
        #expect(throws: UpdateError.self) { try BundleInstaller.verify(try app("com.evil", "1.0.12"), bundleIdentifier: "local.reforge", version: "1.0.12") }
        #expect(throws: UpdateError.self) { try BundleInstaller.verify(try app("local.reforge", "1.0.11"), bundleIdentifier: "local.reforge", version: "1.0.12") }
    }

    @Test func settingDefaultsToOn() throws {
        let data = try JSONEncoder().encode(Config())
        let decoded = try Store.decoder.decode(Config.self, from: data)
        #expect(decoded.checkAppUpdates == nil, "nil means on")
    }
}
