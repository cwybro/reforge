import ApplicationServices
import Foundation
import Testing

// Opt-in smoke tests against the real Reforge.app, every dependency stubbed (see E2EStubs.swift).
// Run with `make e2e`; skipped unless REFORGE_E2E=1. They need Accessibility permission for the
// app that runs them (terminal or IDE).

/// Launches Reforge on a fresh fixture, runs `body`, and always quits the app afterwards.
func withReforge(_ start: E2EFixture.Start, edit: (inout [String: Any]) -> Void = { _ in },
                 _ body: (AXApp, E2EFixture) async throws -> Void) async throws {
    let fixture = try E2EFixture(start, edit: edit)
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
    @Test func stopTrackingFromContextMenu() async throws {
        try await withReforge(.tracking) { app, fx in
            let row = try await app.element("addonRow.\(Mods.bravo)")
            try await app.element("addonRow.\(Mods.bravo).update")   // let the first check settle
            // AppKit runs the menu in a modal tracking loop, so the AXShowMenu call itself may not
            // report success (kAXErrorCannotComplete) even though the menu opened; the wait below
            // is what checks it.
            let shown = AXUIElementPerformAction(row, kAXShowMenuAction as CFString)
            try #require(shown == .success || shown == .cannotComplete, "AXShowMenu failed: \(shown.rawValue)")
            var item: AXUIElement?
            try await app.waitFor("the Stop Tracking menu item") {
                item = app.menuItem(titled: "Stop Tracking")
                return item != nil
            }
            #expect(AXUIElementPerformAction(item!, kAXPressAction as CFString) == .success)

            try await app.waitGone("addonRow.\(Mods.bravo)")
            try await app.waitForText("status.message", containing: "Stopped tracking Bravo.")
            try await app.waitFor("Bravo removed from config") { fx.trackedFileIds[Mods.bravo] == nil }
            #expect(fx.uninstalls.isEmpty)
        }
    }
}
