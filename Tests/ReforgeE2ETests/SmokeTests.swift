import ApplicationServices
import Foundation
import Testing

// Opt-in smoke tests against the real Reforge.app, every dependency stubbed (see E2EStubs.swift).
// Run with `make e2e`; skipped unless REFORGE_E2E=1. They need Accessibility permission for the
// app that runs them (terminal or IDE).

/// Launches Reforge on a fresh fixture, runs `body`, and always quits the app afterwards.
/// `addonFiles` (path -> contents) are written into the fixture's AddOns folder before launch.
func withReforge(_ start: E2EFixture.Start, edit: (inout [String: Any]) -> Void = { _ in },
                 addonFiles: [String: String] = [:],
                 _ body: (AXApp, E2EFixture) async throws -> Void) async throws {
    let fixture = try E2EFixture(start, edit: edit)
    for (path, contents) in addonFiles {
        let url = fixture.addonsDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    let app = try await AXApp.launch(fixture: fixture.fixtureFile)
    defer { app.terminate() }
    try await body(app, fixture)
}

@Suite("E2E smoke", .serialized, .enabled(if: ProcessInfo.processInfo.environment["REFORGE_E2E"] == "1"))
struct SmokeTests {
    /// Walks the welcome flow up to the API key step.
    private func goToKeyStep(_ app: AXApp) async throws {
        try await app.press("onboarding.getStarted")
        try await app.waitForText("onboarding.folder.path", containing: "AddOns")
        try await app.press("onboarding.folder.continue")
        try await app.element("onboarding.key.field")
    }

    @Test func onboardingHappyPath() async throws {
        try await withReforge(.fresh) { app, fx in
            try await goToKeyStep(app)
            try await app.setValue("onboarding.key.field", goodKey)
            try await app.press("onboarding.key.continue")

            // Import step offers the addon from the CurseForge app's tracking file.
            try await app.waitForText("onboarding.import.continue", containing: "Import 1 Addon")
            try await app.press("onboarding.import.continue")
            try await app.press("onboarding.done.open")

            try await app.element("addonRow.\(Mods.delta)")
            try await app.element("addonRow.\(Mods.delta).upToDate")   // the first update check ran
            #expect(fx.savedKey == goodKey)
            #expect(fx.config["onboarded"] as? Bool == true)
            #expect(fx.trackedFileIds == [Mods.delta: 4000])
        }
    }

    @Test func rejectedKeyShowsFriendlyError() async throws {
        try await withReforge(.fresh) { app, fx in
            try await goToKeyStep(app)
            try await app.setValue("onboarding.key.field", badKey)
            try await app.press("onboarding.key.continue")

            try await app.waitForText("onboarding.key.error", containing: "CurseForge didn't accept that key")
            #expect(app.find("onboarding.import.continue") == nil)
            #expect(fx.savedKey == nil)
        }
    }

    /// Bravo's update only appears from the second check on, so "2 updates available" proves the
    /// manual refresh ran (the window's own first check only finds Alpha's).
    @Test func updateOneRow() async throws {
        try await withReforge(.tracking, edit: { f in
            f["mods"] = [E2EFixture.mod(Mods.alpha, "Alpha", latest: 1001),
                         E2EFixture.mod(Mods.bravo, "Bravo", latest: 2000)]
            f["files"] = (f["files"] as! [Any]) + [E2EFixture.file(2000, mod: Mods.bravo, "Bravo 2.0", folder: "Bravo")]
            f["laterMods"] = [E2EFixture.mod(Mods.bravo, "Bravo", latest: 2001)]
        }) { app, fx in
            try await app.waitForText("status.message", containing: "1 update available")
            try await app.element("addonRow.\(Mods.bravo).upToDate")

            try await app.press("header.refresh")
            try await app.waitForText("status.message", containing: "2 updates available")
            try await app.element("addonRow.\(Mods.bravo).update")
            try await app.waitForText("addonRow.\(Mods.alpha).version", containing: "Alpha 1.1")

            try await app.press("addonRow.\(Mods.alpha).update")
            try await app.element("addonRow.\(Mods.alpha).upToDate")
            try await app.waitForText("status.message", containing: "Updated Alpha to Alpha 1.1")
            #expect(app.find("addonRow.\(Mods.bravo).update") != nil)

            try await app.waitFor("Alpha's new file id saved") { fx.trackedFileIds[Mods.alpha] == 1001 }
            #expect(fx.installs.map(\.fileId) == [1001])
            #expect(fx.installs.first?.replacing == ["Alpha"])
        }
    }

    /// The folder step's Change… button, with the system folder picker stubbed to pick OtherAddOns.
    @Test func changeFolderDuringOnboarding() async throws {
        try await withReforge(.fresh, edit: { $0["pickFolder"] = "OtherAddOns" }) { app, fx in
            let other = try fx.makeFolder("OtherAddOns")
            try await app.press("onboarding.getStarted")
            try await app.element("onboarding.folder.change")
            try await app.press("onboarding.folder.change")
            try await app.waitForText("onboarding.folder.path", containing: "OtherAddOns")

            try await app.press("onboarding.folder.continue")
            try await app.element("onboarding.key.field")
            try await app.waitFor("the new folder saved") { fx.config["addonsPath"] as? String == other.path }
        }
    }

    /// Settings window from the app menu: pick a folder (stubbed picker) and turn on beta releases.
    @Test func settingsWindow() async throws {
        try await withReforge(.tracking, edit: { $0["pickFolder"] = "OtherAddOns" }) { app, fx in
            let other = try fx.makeFolder("OtherAddOns")
            try await app.element("addonRow.\(Mods.alpha)")
            // The app menu carries the bundle name ("Reforge Dev" for the dev build).
            try await app.pressMenuItem(app.running.localizedName ?? "Reforge", titled: "Settings")

            try await app.press("settings.chooseFolder")
            try await app.waitForText("settings.folder", containing: "OtherAddOns")
            try await app.waitFor("the new folder saved") { fx.config["addonsPath"] as? String == other.path }

            try await app.press("settings.prerelease")
            try await app.waitFor("beta releases saved") { fx.config["allowPrerelease"] as? Bool == true }

            // The stub scheduler writes schedule.json instead of installing a LaunchAgent.
            try await app.press("settings.backgroundCheck")
            try await app.waitFor("background checks scheduled") {
                fx.config["backgroundCheckHours"] as? Int == 6 && fx.scheduledHours == 6
            }
            try await app.press("settings.backgroundCheck")
            try await app.waitFor("background checks turned off") {
                fx.config["backgroundCheckHours"] == nil && fx.scheduledHours == nil
            }
        }
    }

    @Test func updateAll() async throws {
        try await withReforge(.tracking) { app, fx in
            try await app.waitForText("header.updateAll", containing: "Update All (2)")
            try await app.press("header.updateAll")

            try await app.element("addonRow.\(Mods.alpha).upToDate")
            try await app.element("addonRow.\(Mods.bravo).upToDate")
            try await app.waitForText("status.message", containing: "All updates installed.")
            #expect(Set(fx.installs.map(\.fileId)) == [1001, 2001])
            try await app.waitFor("both file ids saved") {
                fx.trackedFileIds == [Mods.alpha: 1001, Mods.bravo: 2001]
            }
        }
    }

    @Test func addFromSheet() async throws {
        try await withReforge(.tracking) { app, fx in
            try await app.press("header.add")
            try await app.setValue("addSheet.field", "https://www.curseforge.com/wow/addons/charlie")
            try await app.press("addSheet.install")
            try await app.waitGone("addSheet.field")

            try await app.element("addonRow.\(Mods.charlie)")
            try await app.waitForText("status.message", containing: "Installed Charlie.")
            try await app.waitForText("status.count", containing: "3 addons")
            #expect(fx.installs.map(\.fileId) == [3001])
            try await app.waitFor("Charlie saved") { fx.trackedFileIds[Mods.charlie] == 3001 }
        }
    }

    /// Drives the row's context menu without the mouse: AXShowMenu on the row, then AXPress on the item.
    @Test func searchAndInstall() async throws {
        try await withReforge(.tracking) { app, fx in
            try await app.press("header.add")
            // An empty search browses; Alpha is already tracked.
            try await app.element("search.result.\(Mods.alpha).installed")
            try await app.element("search.result.\(Mods.charlie).install")

            try await app.setValue("addSheet.field", "char")
            try await app.waitGone("search.result.\(Mods.alpha)")
            try await app.press("search.result.\(Mods.charlie).install")
            try await app.element("search.result.\(Mods.charlie).installed")
            #expect(fx.installs.map(\.fileId) == [3001])
            try await app.waitFor("Charlie saved") { fx.trackedFileIds[Mods.charlie] == 3001 }

            // The sheet stays open for more; Done closes it and the list has the new addon.
            try await app.press("addSheet.cancel")
            try await app.waitGone("addSheet.field")
            try await app.element("addonRow.\(Mods.charlie)")
        }
    }

    @Test func foundAddons() async throws {
        let files = [
            // On CurseForge (project id in its .toc), but not tracked.
            "Charlie/Charlie.toc": "## Interface: 110000\n## Title: Charlie\n## Version: 3.0\n## X-Curse-Project-ID: \(Mods.charlie)\nCharlie.lua\n",
            "Charlie/Charlie.lua": "print('charlie')",
            // Homemade, with a helper folder.
            "Homebrew/Homebrew.toc": "## Interface: 110000\n## Title: Homebrew\n## Author: You\nHomebrew.lua\n",
            "Homebrew/Homebrew.lua": "print('home')",
            "Homebrew_Config/Homebrew_Config.toc": "## Interface: 110000\nconfig.lua\n",
            "Homebrew_Config/config.lua": "print('config')",
        ]
        try await withReforge(.tracking, addonFiles: files) { app, fx in
            try await app.element("found.Homebrew.local")
            try await app.waitForText("found.Homebrew", containing: "Homebrew, Homebrew_Config")
            try await app.waitForText("status.count", containing: "2 addons · 2 not tracked")

            try await app.press("found.Charlie.track")
            try await app.waitGone("found.Charlie")
            try await app.element("addonRow.\(Mods.charlie)")
            try await app.waitForText("status.message", containing: "Now tracking Charlie.")
            try await app.waitFor("Charlie tracked without downloading") {
                fx.trackedFileIds[Mods.charlie] == 0 && fx.installs.isEmpty
            }
            // Its installed version is unknown, so the latest file is offered as an update.
            try await app.element("addonRow.\(Mods.charlie).update")

            try await app.performNamedAction("Move to Trash", on: "found.Homebrew")
            try await app.waitGone("found.Homebrew")
            try await app.waitFor("both Homebrew folders trashed") { fx.uninstalls == [["Homebrew", "Homebrew_Config"]] }
        }
    }

    @Test func stopTracking() async throws {
        // Bravo's folder is on disk, so once untracked it's listed under Not tracked straight away.
        let bravo = ["Bravo/Bravo.toc": "## Interface: 110000\n## Title: Bravo\n## X-Curse-Project-ID: \(Mods.bravo)\nBravo.lua\n",
                     "Bravo/Bravo.lua": "print('bravo')"]
        try await withReforge(.tracking, addonFiles: bravo) { app, fx in
            try await app.element("addonRow.\(Mods.bravo).update")   // let the first check settle
            // The row's named accessibility action runs the same code as its context menu item.
            // (Opening a real context menu in a background app that never activates is unreliable.)
            try await app.performNamedAction("Stop Tracking", on: "addonRow.\(Mods.bravo)")

            try await app.waitGone("addonRow.\(Mods.bravo)")
            try await app.waitForText("status.message", containing: "Stopped tracking Bravo.")
            try await app.waitFor("Bravo removed from config") { fx.trackedFileIds[Mods.bravo] == nil }
            #expect(fx.uninstalls.isEmpty)
            try await app.element("found.Bravo.track")
            try await app.waitForText("status.count", containing: "1 addon · 1 not tracked")
        }
    }
}
