import Foundation
import Testing
@testable import Reforge

@Suite("Remove") @MainActor
struct RemoveTests {
    @Test func stopTrackingKeepsFiles() throws {
        let env = try TestEnv(addons: [tracked(1, "Alpha", fileId: 1), tracked(2, "Bravo", fileId: 2)])
        try env.makeFolder("Alpha")
        let model = env.makeModel()
        model.remove(model.config.addons[0], deleteFiles: false)
        #expect(model.config.addons.map(\.id) == [2])
        #expect(env.store.config?.addons.map(\.id) == [2])
        #expect(env.installer.uninstalls.isEmpty)
        #expect(env.exists("Alpha"))
        #expect(model.message == "Stopped tracking Alpha.")
    }

    @Test func uninstallUsesInstaller() throws {
        let env = try TestEnv(addons: [tracked(1, "Alpha", fileId: 1, folders: ["Alpha", "Alpha_Options"])])
        let model = env.makeModel()
        model.remove(model.config.addons[0], deleteFiles: true)
        #expect(env.installer.uninstalls == [["Alpha", "Alpha_Options"]])
        #expect(model.config.addons.isEmpty)
        #expect(model.message == "Moved Alpha to the Trash.")
    }

    @Test func uninstallFailureKeepsTracking() throws {
        let env = try TestEnv(addons: [tracked(1, "Alpha", fileId: 1)])
        env.installer.uninstallError = InstallFailure()
        let model = env.makeModel()
        model.remove(model.config.addons[0], deleteFiles: true)
        #expect(model.config.addons.map(\.id) == [1])
        #expect(env.store.saveCount == 0)
        #expect(model.message == "disk on fire")
    }

    /// Real Installer.uninstall with the Trash redirected into the test's temp dir.
    @Test func realUninstallTrashesOnlySafeFolders() throws {
        let env = try TestEnv(addons: [tracked(1, "Alpha", fileId: 1, folders: ["Alpha", "Alpha_Options", "Missing", "../Outside", ".", ""])])
        try env.makeFolder("Alpha")
        try env.makeFolder("Alpha_Options")
        try env.makeFolder("Keep")
        let outside = env.dir.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let model = env.makeModel(installer: try localInstaller(env, zip: Data()))

        model.remove(model.config.addons[0], deleteFiles: true)

        let trashed = try FileManager.default.contentsOfDirectory(atPath: env.dir.appendingPathComponent("Trash").path).sorted()
        #expect(trashed == ["Alpha", "Alpha_Options"])
        #expect(!env.exists("Alpha") && !env.exists("Alpha_Options"))
        #expect(env.exists("Keep"))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(model.config.addons.isEmpty)
    }
}
