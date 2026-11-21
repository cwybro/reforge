import AppKit
import SwiftUI
import Testing
@testable import Reforge

/// Lays out each screen in an off-screen NSHostingView. Catches crashes and broken layout, not pixels.
@Suite("View smoke") @MainActor
struct ViewSmokeTests {
    init() {
        // Header and the welcome icon read NSApp.applicationIconImage; create the shared app (never run it).
        _ = NSApplication.shared
    }

    func render<V: View>(_ view: V, width: CGFloat = 760, height: CGFloat = 540) {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        #expect(host.fittingSize.height > 0)
    }

    /// No key: ContentView's `.task` check returns before calling the API.
    @Test func contentViewEmpty() throws {
        let env = try TestEnv()
        let model = env.makeModel()
        render(ContentView(model: model))
        render(RootView(model: model))
        #expect(env.api.calls.isEmpty)
    }

    @Test func contentViewWithAddons() async throws {
        let env = try updatesEnv(key: "")
        let model = env.makeModel()
        model.status = [1: .upToDate, 2: .updateAvailable, 3: .failed("boom")]
        model.latest[2] = cfFile(250, mod: 2, "Bravo 2.5")
        model.message = "1 update available."
        render(ContentView(model: model))
        model.found = [FoundAddon(folders: ["Echo", "Echo_Options"], title: "Echo", version: "Echo 1.2", projectId: 42,
                                  file: cfFile(4200, mod: 42, "Echo 1.2")),
                       FoundAddon(folders: ["Mine"], title: "Mine", version: "1.0", author: "You")]
        render(ContentView(model: model))
    }

    @Test func onboardingSteps() throws {
        let env = try TestEnv(config: nil)
        let model = env.makeModel()
        model.config.addonsPath = env.addonsDir.path   // FolderStep checks the folder exists
        render(RootView(model: model))
        render(OnboardingView(model: model))
        render(WelcomeStep(next: {}))
        render(FolderStep(model: model, next: {}, back: {}))
        render(KeyStep(model: model, next: {}, back: {}))
        render(ImportStep(model: model, next: {}, back: {}))
        render(DoneStep(count: 3, finish: {}))
    }

    @Test func settingsView() throws {
        let env = try TestEnv(key: "$2a$10$k")
        render(SettingsView(model: env.makeModel()), width: 520, height: 320)
    }

    @Test func updateBanner() async throws {
        let source = FakeReleases(); source.release = release("1.0.12")
        let u = AppUpdater(currentVersion: "1.0.8", appURL: URL(fileURLWithPath: "/tmp/R.app"), isSupported: true,
                           source: source, installer: FakeAppInstaller())
        await u.check()
        let env = try TestEnv(key: "$2a$10$k")
        render(ContentView(model: env.makeModel(), updater: u))
        render(UpdateBanner(updater: u), width: 700, height: 80)
        render(SettingsView(model: env.makeModel(), updater: u), width: 520, height: 400)
    }

    @Test func addSheet() throws {
        let env = try TestEnv(key: "$2a$10$k")
        render(AddSheet(model: env.makeModel()), width: 620, height: 580)
        render(KeyBanner(model: env.makeModel()), width: 600, height: 100)
    }
}
