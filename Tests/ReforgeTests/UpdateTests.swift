import Foundation
import Testing
@testable import Reforge

/// Three tracked addons: Alpha is current, Bravo has an update (plus a newer beta), Charlie has
/// only Classic files. Delta, when included, also has an update.
@MainActor
func updatesEnv(key: String = "$2a$10$k", withDelta: Bool = false) throws -> TestEnv {
    var addons = [tracked(1, "Alpha", fileId: 100), tracked(2, "Bravo", fileId: 200, folders: ["Bravo"]),
                  tracked(3, "Charlie", fileId: 300)]
    if withDelta { addons.append(tracked(4, "Delta", fileId: 400)) }
    let env = try TestEnv(key: key, addons: addons)
    env.api.add(cfMod(1, "Alpha", files: [(100, 1, retail)]), cfFile(100, mod: 1, "Alpha 1.0"))
    env.api.add(cfMod(2, "Bravo", files: [(250, 1, retail), (260, 2, retail), (240, 1, classicEra)]),
                cfFile(250, mod: 2, "Bravo 2.5"), cfFile(260, mod: 2, "Bravo 2.6-beta", releaseType: 2),
                cfFile(240, mod: 2, "Bravo 2.4-classic"))
    env.api.add(cfMod(3, "Charlie", files: [(390, 1, classicEra)]), cfFile(390, mod: 3, "Charlie classic"))
    env.api.add(cfMod(4, "Delta", files: [(450, 1, retail)]), cfFile(450, mod: 4, "Delta 4.5"))
    return env
}

@Suite("Check for updates") @MainActor
struct CheckForUpdatesTests {
    @Test func mixedStatuses() async throws {
        let env = try updatesEnv()
        let model = env.makeModel()
        await model.checkForUpdates()
        #expect(model.status[1] == .upToDate)
        #expect(model.status[2] == .updateAvailable)
        #expect(model.status[3] == .unknown)
        #expect(model.latest[2]?.id == 250)
        #expect(model.latest[3] == nil)
        #expect(model.updatable.map(\.id) == [2])
        #expect(model.message == "1 update available.")
        #expect(model.lastChecked == fixedNow)
        #expect(!model.checking)
        #expect(env.api.calls == ["mods([1, 2, 3])", "files([100, 250])"])
        #expect(env.api.key == "$2a$10$k")
    }

    @Test func pluralMessage() async throws {
        let env = try updatesEnv(withDelta: true)
        let model = env.makeModel()
        await model.checkForUpdates()
        #expect(model.message == "2 updates available.")
        #expect(model.updatable.map(\.id) == [2, 4])
    }

    @Test func prereleaseOptIn() async throws {
        let env = try updatesEnv()
        env.store.config?.allowPrerelease = true
        let model = env.makeModel()
        await model.checkForUpdates()
        #expect(model.latest[2]?.id == 260)
    }

    @Test func gameVersionSwitch() async throws {
        let env = try updatesEnv()
        env.store.config?.gameVersionTypeId = classicEra
        let model = env.makeModel()
        await model.checkForUpdates()
        #expect(model.status[1] == .unknown)
        #expect(model.latest[2]?.id == 240)
        #expect(model.status[3] == .updateAvailable)
    }

    @Test func everythingUpToDate() async throws {
        let env = try TestEnv(key: "k", addons: [tracked(1, "Alpha", fileId: 100)])
        env.api.add(cfMod(1, "Alpha", files: [(100, 1, retail)]), cfFile(100, mod: 1, "Alpha 1.0"))
        let model = env.makeModel()
        await model.checkForUpdates()
        #expect(model.message == "Everything is up to date.")
        #expect(model.updatable.isEmpty)
    }

    @Test func noMatchingFilesSkipsFilesCall() async throws {
        let env = try TestEnv(key: "k", addons: [tracked(3, "Charlie", fileId: 300)])
        env.api.add(cfMod(3, "Charlie", files: [(390, 1, classicEra)]))
        let model = env.makeModel()
        await model.checkForUpdates()
        #expect(env.api.calls == ["mods([3])"])
        #expect(model.status[3] == .unknown)
        #expect(model.message == "Everything is up to date.")
    }

    @Test func networkErrorSurfaces() async throws {
        let env = try updatesEnv()
        env.api.error = Reforge.CFError.http(500, "upstream down")
        let model = env.makeModel()
        await model.checkForUpdates()
        #expect(model.message == "CurseForge API error 500: upstream down")
        #expect(model.lastChecked == nil)
        #expect(!model.checking)
        #expect(model.status.isEmpty)
    }

    @Test func noKeyMakesNoCall() async throws {
        let env = try updatesEnv(key: "")
        let model = env.makeModel()
        await model.checkForUpdates()
        #expect(env.api.calls.isEmpty)
        #expect(model.message == nil)
        #expect(model.lastChecked == nil)
    }

    @Test func noAddonsMakesNoCall() async throws {
        let env = try TestEnv(key: "k")
        await env.makeModel().checkForUpdates()
        #expect(env.api.calls.isEmpty)
    }
}

@Suite("Update and Update All") @MainActor
struct UpdateTests {
    @Test func updateOneRecordsNewFileAndPersists() async throws {
        let env = try updatesEnv()
        env.installer.folders[250] = ["Bravo_Options", "Bravo"]
        let model = env.makeModel()
        await model.checkForUpdates()
        let bravo = try #require(model.config.addons.first { $0.id == 2 })
        await model.update(bravo)

        #expect(env.installer.installs.map(\.fileId) == [250])
        #expect(env.installer.installs.first?.replacing == ["Bravo"])
        let saved = try #require(env.store.config?.addons.first { $0.id == 2 })
        #expect(saved.fileId == 250)
        #expect(saved.version == "Bravo 2.5")
        #expect(saved.fileDate == fileDate)
        #expect(saved.folders == ["Bravo_Options", "Bravo"])
        #expect(model.status[2] == .upToDate)
        #expect(model.updatable.isEmpty)
        #expect(model.message == "Updated Bravo to Bravo 2.5.")
    }

    @Test func failedInstallMarksRowFailed() async throws {
        let env = try updatesEnv()
        env.installer.failing = [250]
        let model = env.makeModel()
        await model.checkForUpdates()
        let saves = env.store.saveCount
        await model.update(try #require(model.config.addons.first { $0.id == 2 }))
        #expect(model.status[2] == .failed("disk on fire"))
        #expect(model.message == "Bravo: disk on fire")
        #expect(model.config.addons.first { $0.id == 2 }?.fileId == 200)
        #expect(env.store.saveCount == saves)
    }

    @Test func updateWithoutCheckIsNoOp() async throws {
        let env = try updatesEnv()
        let model = env.makeModel()
        await model.update(try #require(model.config.addons.first))
        #expect(env.installer.installs.isEmpty)
        #expect(model.status.isEmpty)
    }

    @Test func updateAllSucceeds() async throws {
        let env = try updatesEnv(withDelta: true)
        let model = env.makeModel()
        await model.checkForUpdates()
        let saves = env.store.saveCount
        await model.updateAll()
        #expect(env.installer.installs.map(\.fileId) == [250, 450])
        // One save for the whole run, not one per addon.
        #expect(env.store.saveCount == saves + 1)
        #expect(model.message == "All updates installed.")
        #expect(env.store.config?.addons.map(\.fileId) == [100, 250, 300, 450])
        #expect(model.updatable.isEmpty)
    }

    @Test func updateAllReportsFailures() async throws {
        let env = try updatesEnv(withDelta: true)
        env.installer.failing = [450]
        let model = env.makeModel()
        await model.checkForUpdates()
        await model.updateAll()
        #expect(model.status[2] == .upToDate)
        #expect(model.status[4] == .failed("disk on fire"))
        #expect(model.message == "1 update(s) failed.")
        #expect(env.store.config?.addons.map(\.fileId) == [100, 250, 300, 400])
    }
}
