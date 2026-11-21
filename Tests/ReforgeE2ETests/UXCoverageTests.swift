import ApplicationServices
import Foundation
import Testing

// Every screen, route and interaction a user can reach, so a change that breaks one fails here.
// SmokeTests covers the main happy paths; this covers the rest: back/skip navigation, menus,
// pickers, links, error and retry paths, and each settings control. See AGENTS.md ("New UI").
//
// Conventions: buttons and fields by accessibility identifier; context-menu commands through the
// row's matching named accessibility action; menu pickers through increment/decrement
// (`.adjustable`), since AppKit doesn't reliably open menus for this never-active app; links and
// Finder reveals are recorded by the stub mode (opens.jsonl) instead of opening anything.

private func openSettings(_ app: AXApp) async throws {
    try await app.pressMenuItem(app.running.localizedName ?? "Reforge", titled: "Settings")
    try await app.element("settings.key")
}

private func goToKeyStep(_ app: AXApp) async throws {
    try await app.press("onboarding.getStarted")
    try await app.press("onboarding.folder.continue")
    try await app.element("onboarding.key.field")
}

@Suite("UX coverage", .serialized, .enabled(if: ProcessInfo.processInfo.environment["REFORGE_E2E"] == "1"))
struct UXCoverageTests {
    // MARK: Welcome flow

    @Test func onboardingBackSkipAndSavedKey() async throws {
        try await withReforge(.fresh) { app, fx in
            try await app.press("onboarding.getStarted")
            try await app.press("onboarding.folder.back")
            try await app.press("onboarding.getStarted")
            try await app.press("onboarding.folder.continue")
            try await app.press("onboarding.key.back")
            try await app.press("onboarding.folder.continue")

            try await app.setValue("onboarding.key.field", goodKey)
            try await app.press("onboarding.key.continue")
            try await app.waitForText("onboarding.import.continue", containing: "Import 1 Addon")
            // Back to the key step: with a key saved, Continue on an empty field keeps it.
            try await app.press("onboarding.import.back")
            try await app.setValue("onboarding.key.field", "")
            try await app.press("onboarding.key.continue")
            try await app.press("onboarding.import.skip")
            try await app.press("onboarding.done.open")

            try await app.element("main.empty")
            try await app.waitFor("onboarding saved without imports") {
                fx.config["onboarded"] as? Bool == true && fx.trackedFileIds.isEmpty
            }
            #expect(fx.savedKey == goodKey)
        }
    }

    @Test func onboardingMissingFolderThenChoose() async throws {
        try await withReforge(.fresh, edit: { $0["pickFolder"] = "Picked" }, prepare: { fx in
            try FileManager.default.removeItem(at: fx.addonsDir)
            try fx.makeFolder("Picked")
        }) { app, _ in
            try await app.press("onboarding.getStarted")
            try await app.element("onboarding.folder.missing")
            #expect(app.find("onboarding.folder.continue")?.bool(kAXEnabledAttribute) == false)
            try await app.press("onboarding.folder.change")
            try await app.waitForText("onboarding.folder.path", containing: "Picked")
            try await app.waitGone("onboarding.folder.missing")
            try await app.press("onboarding.folder.continue")
            try await app.element("onboarding.key.field")
        }
    }

    @Test func onboardingGameVersionPicksItsFolder() async throws {
        try await withReforge(.fresh) { app, _ in
            try await app.press("onboarding.getStarted")
            try await app.pressChild(of: "onboarding.folder.version", titled: "Classic Era")
            try await app.waitForText("onboarding.folder.path", containing: "_classic_era_")
        }
    }

    @Test func onboardingKeyHelpLinkOpensCurseForgeDocs() async throws {
        try await withReforge(.fresh) { app, fx in
            try await goToKeyStep(app)
            try await app.press("onboarding.key.learn")
            try await app.waitFor("the docs opened") { fx.openedURLs.contains { $0.contains("docs.curseforge.com") } }
        }
    }

    @Test func showWelcomeScreenFromTheMenu() async throws {
        try await withReforge(.tracking) { app, fx in
            try await app.element("addonRow.\(Mods.alpha)")
            try await app.pressMenuItem(app.running.localizedName ?? "Reforge", titled: "Show Welcome Screen")
            try await app.element("onboarding.getStarted")
            try await app.waitFor("onboarded flag cleared") { fx.config["onboarded"] as? Bool == false }
        }
    }

    // MARK: Main window

    @Test func emptyState() async throws {
        try await withReforge(.many(0)) { app, _ in
            try await app.element("main.empty")
            try await app.waitForText("status.count", containing: "0 addons")
        }
    }

    @Test func keyBannerSavesAndChecks() async throws {
        try await withReforge(.trackingNoKey) { app, fx in
            try await app.setValue("keyBanner.field", goodKey)
            try await app.press("keyBanner.save")
            try await app.waitGone("keyBanner.field")
            try await app.element("addonRow.\(Mods.alpha).update")   // the check ran with the new key
            #expect(fx.savedKey == goodKey)
        }
    }

    @Test func checkForUpdatesFromTheMenu() async throws {
        try await withReforge(.tracking, edit: { f in
            f["mods"] = [E2EFixture.mod(Mods.alpha, "Alpha", latest: 1001), E2EFixture.mod(Mods.bravo, "Bravo", latest: 2000)]
            f["laterMods"] = [E2EFixture.mod(Mods.bravo, "Bravo", latest: 2001)]
        }) { app, _ in
            try await app.waitForText("status.message", containing: "1 update available")
            try await app.pressMenuItem("File", titled: "Check for Updates")
            try await app.waitForText("status.message", containing: "2 updates available")
        }
    }

    @Test func failedUpdateCanBeRetried() async throws {
        try await withReforge(.tracking, edit: { $0["failInstallFileIds"] = [1001] }) { app, fx in
            try await app.press("addonRow.\(Mods.alpha).update")
            try await app.waitForText("status.message", containing: "Alpha:")
            try await app.press("addonRow.\(Mods.alpha).retry")
            try await app.waitFor("a second attempt") { fx.installs.filter { $0.fileId == 1001 }.count == 2 }
            try await app.element("addonRow.\(Mods.alpha).retry")
            #expect(fx.trackedFileIds[Mods.alpha] == 1000, "a failed update leaves the old version recorded")
        }
    }

    @Test func failedCheckShowsTheError() async throws {
        try await withReforge(.tracking, edit: { $0["failChecks"] = true }) { app, _ in
            try await app.waitForText("status.message", containing: "CurseForge is down")
            #expect(app.find("addonRow.\(Mods.alpha).update") == nil)
        }
    }

    @Test func uninstallFromARow() async throws {
        try await withReforge(.tracking) { app, fx in
            try await app.element("addonRow.\(Mods.alpha).update")
            try await app.performNamedAction("Uninstall (Move to Trash)", on: "addonRow.\(Mods.alpha)")
            try await app.waitGone("addonRow.\(Mods.alpha)")
            try await app.waitFor("Alpha's folder trashed and untracked") {
                fx.uninstalls == [["Alpha"]] && fx.trackedFileIds[Mods.alpha] == nil
            }
        }
    }

    @Test func rowOpensCurseForgeAndShowsInFinder() async throws {
        try await withReforge(.tracking) { app, fx in
            try await app.element("addonRow.\(Mods.alpha)")
            try await app.performNamedAction("Open on CurseForge", on: "addonRow.\(Mods.alpha)")
            try await app.performNamedAction("Show in Finder", on: "addonRow.\(Mods.alpha)")
            try await app.waitFor("page opened and folder revealed") {
                fx.openedURLs == ["https://www.curseforge.com/wow/addons/alpha"] && fx.revealed == [["Alpha"]]
            }
        }
    }

    // MARK: Add sheet

    @Test func sortAndCategoryReachTheSearch() async throws {
        try await withReforge(.tracking, edit: { $0["categories"] = [["id": 7, "name": "Bags"]] }) { app, fx in
            try await app.press("header.add")
            try await app.element("search.result.\(Mods.alpha)")
            try await app.perform(kAXIncrementAction, on: "search.sort")
            try await app.waitFor("a search sorted by Recently updated") { fx.searches.last?.sort == 3 }
            try await app.perform(kAXIncrementAction, on: "search.category")
            try await app.waitFor("a search in Bags") { fx.searches.last?.categoryId == 7 }
        }
    }

    @Test func noResultsAndSearchErrorWithRetry() async throws {
        try await withReforge(.tracking, edit: { $0["failSearchContaining"] = "boom" }) { app, fx in
            try await app.press("header.add")
            try await app.setValue("addSheet.field", "zzz")
            try await app.element("search.empty")
            try await app.setValue("addSheet.field", "boom")
            try await app.element("search.error")
            let before = fx.searches.filter { $0.text == "boom" }.count
            try await app.press("search.retry")
            try await app.waitFor("the search retried") { fx.searches.filter { $0.text == "boom" }.count == before + 1 }
            try await app.setValue("addSheet.field", "char")
            try await app.element("search.result.\(Mods.charlie)")
        }
    }

    @Test func resultWithoutAFileExplainsWhy() async throws {
        try await withReforge(.tracking, edit: { f in
            var mods = f["mods"] as! [[String: Any]]
            var echo = E2EFixture.mod(105, "Echo", latest: 5000)
            echo["latestFilesIndexes"] = [["fileId": 5000, "releaseType": 1, "gameVersionTypeId": 67408]]   // Classic only
            mods.append(echo)
            f["mods"] = mods
        }) { app, fx in
            try await app.press("header.add")
            try await app.setValue("addSheet.field", "Echo")
            try await app.press("search.result.105.install")
            try await app.waitForText("search.result.105.failure", containing: "no file for this game version")
            #expect(fx.installs.isEmpty)
        }
    }

    @Test func resultLinkOpensItsPage() async throws {
        try await withReforge(.tracking) { app, fx in
            try await app.press("header.add")
            try await app.press("search.result.\(Mods.charlie).link")
            try await app.waitFor("Charlie's page opened") { fx.openedURLs.contains { $0.hasSuffix("/addons/charlie") } }
        }
    }

    // MARK: Not tracked

    @Test func trackAllFoundAddons() async throws {
        let files = [
            "Charlie/Charlie.toc": "## Interface: 110000\n## X-Curse-Project-ID: \(Mods.charlie)\nCharlie.lua\n",
            "Charlie/Charlie.lua": "print(1)",
            "Delta/Delta.toc": "## Interface: 110000\n## X-Curse-Project-ID: \(Mods.delta)\nDelta.lua\n",
            "Delta/Delta.lua": "print(2)",
        ]
        try await withReforge(.tracking, addonFiles: files) { app, fx in
            try await app.press("found.trackAll")
            try await app.waitGone("found.header")
            try await app.element("addonRow.\(Mods.charlie)")
            try await app.element("addonRow.\(Mods.delta)")
            try await app.waitForText("status.message", containing: "Now tracking 2 addons.")
            try await app.waitFor("both saved") { fx.trackedFileIds[Mods.charlie] == 0 && fx.trackedFileIds[Mods.delta] == 0 }
        }
    }

    @Test func foundRowOpensCurseForgeAndShowsInFinder() async throws {
        let files = ["Charlie/Charlie.toc": "## Interface: 110000\n## X-Curse-Project-ID: \(Mods.charlie)\nCharlie.lua\n",
                     "Charlie/Charlie.lua": "print(1)"]
        try await withReforge(.tracking, addonFiles: files) { app, fx in
            try await app.element("found.Charlie.track")
            try await app.performNamedAction("Open on CurseForge", on: "found.Charlie")
            try await app.performNamedAction("Show in Finder", on: "found.Charlie")
            try await app.waitFor("page opened and folder revealed") {
                fx.openedURLs.contains { $0.hasSuffix("/addons/charlie") } && fx.revealed == [["Charlie"]]
            }
        }
    }

    // MARK: Reforge updates

    @Test func laterHidesTheUpdateBanner() async throws {
        try await withReforge(.tracking, edit: { $0["appUpdate"] = "99.0.0" }) { app, fx in
            try await app.press("update.later")
            try await app.waitGone("update.banner")
            #expect(fx.appUpdateLog.isEmpty)
        }
    }

    @Test func failedAppUpdateCanBeRetried() async throws {
        try await withReforge(.tracking, edit: { $0["appUpdate"] = "99.0.0"; $0["appUpdateFails"] = true }) { app, fx in
            try await app.press("update.install")
            try await app.waitForText("update.error", containing: "The download failed.")
            try await app.press("update.install")   // now "Try Again"
            try await app.waitFor("a second attempt, no relaunch") {
                fx.appUpdateLog.count == 2 && !fx.appUpdateLog.contains { $0["relaunched"] != nil }
            }
        }
    }

    @Test func whatsNewOpensTheRelease() async throws {
        try await withReforge(.tracking, edit: { $0["appUpdate"] = "99.0.0" }) { app, fx in
            try await app.press("update.whatsNew")
            try await app.waitFor("the release page opened") { fx.openedURLs.contains { $0.hasSuffix("/releases/v99.0.0") } }
        }
    }

    @Test func checkForReforgeUpdatesFromTheMenu() async throws {
        try await withReforge(.tracking) { app, _ in
            try await app.element("addonRow.\(Mods.alpha).update")
            try await app.pressMenuItem(app.running.localizedName ?? "Reforge", titled: "Check for Reforge Updates")
            try await app.waitForText("status.message", containing: "Reforge 1.0 is up to date.")
        }
    }

    // MARK: Settings

    @Test func settingsKeyIsSavedWhenClosed() async throws {
        try await withReforge(.tracking) { app, fx in
            try await openSettings(app)
            try await app.setValue("settings.key", "$2a$10$replaced-key")
            try await app.closeWindow(titled: "Settings")
            try await app.waitFor("the new key saved") { fx.savedKey == "$2a$10$replaced-key" }
        }
    }

    @Test func settingsGameVersionAndCheckInterval() async throws {
        try await withReforge(.tracking) { app, fx in
            try await openSettings(app)
            try await app.perform(kAXIncrementAction, on: "settings.gameVersion")
            try await app.waitFor("Classic Era saved") { fx.config["gameVersionTypeId"] as? Int == 67408 }

            try await app.press("settings.backgroundCheck")
            try await app.waitFor("checks every 6 hours") { fx.scheduledHours == 6 }
            try await app.perform(kAXIncrementAction, on: "settings.backgroundInterval")
            try await app.waitFor("checks every 12 hours") {
                fx.scheduledHours == 12 && fx.config["backgroundCheckHours"] as? Int == 12
            }
        }
    }

    @Test func settingsImportFromCurseForgeApp() async throws {
        try await withReforge(.tracking, prepare: { try $0.writeCurseForgeImport([(Mods.delta, "Delta", 4000)]) }) { app, fx in
            try await openSettings(app)
            try await app.press("settings.import")
            try await app.waitFor("Delta imported") { fx.trackedFileIds[Mods.delta] == 4000 }
        }
    }

    @Test func settingsExplainsDeniedNotifications() async throws {
        try await withReforge(.tracking, edit: { $0["denyNotifications"] = true }) { app, fx in
            try await openSettings(app)
            try await app.press("settings.backgroundCheck")
            try await app.waitForText("settings.backgroundCheckProblem", containing: "System Settings")
            #expect(fx.scheduledHours == nil)
        }
    }
}

