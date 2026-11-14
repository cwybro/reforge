import Foundation
import Testing
@testable import Reforge

/// The real Installer (zipinfo + ditto + folder swap) against a temp AddOns folder and an in-memory zip.
/// Kept to a few focused cases; flow tests use FakeInstaller.
@Suite("Installer") @MainActor
struct InstallerTests {
    let file = cfFile(500, mod: 5, "New 2.0")

    @Test func installReplacesOldFolders() async throws {
        let env = try TestEnv()
        try env.makeFolder("Old")
        try env.makeFolder("New", marker: "old new")
        try env.makeFolder("Unrelated")
        let zip = ZipWriter.make([("New/", ""), ("New/New.toc", "fresh"), ("New_Options/", ""),
                                  ("New_Options/New_Options.toc", "opts"), ("__MACOSX/", ""), ("readme.txt", "x")])
        let folders = try await localInstaller(env, zip: zip).install(file, replacing: ["Old", "New"], addonsDir: env.addonsDir)
        #expect(folders == ["New", "New_Options"])
        #expect(env.marker("New") == "fresh")
        #expect(env.marker("New_Options") == "opts")
        #expect(!env.exists("Old"))
        #expect(!env.exists("readme.txt") && !env.exists("__MACOSX"))
        #expect(env.marker("Unrelated") == "old")
    }

    /// Fail mid-swap: moving the new "B" into place fails after "A" already went in.
    @Test func failedSwapRestoresOldFolders() async throws {
        let env = try TestEnv()
        try env.makeFolder("A", marker: "original A")
        try env.makeFolder("Legacy", marker: "original Legacy")
        let zip = ZipWriter.make([("A/", ""), ("A/A.toc", "new A"), ("B/", ""), ("B/B.toc", "new B")])
        var installer = try localInstaller(env, zip: zip)
        installer.move = { src, dst in
            if src.lastPathComponent == "B" { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(at: src, to: dst)
        }
        await #expect(throws: (any Error).self) {
            try await installer.install(file, replacing: ["A", "Legacy"], addonsDir: env.addonsDir)
        }
        #expect(env.marker("A") == "original A")
        #expect(env.marker("Legacy") == "original Legacy")
        #expect(!env.exists("B"))
    }

    /// A dangling symlink where a new folder goes (e.g. a dev checkout that moved) is replaced on success.
    @Test func danglingSymlinkIsReplaced() async throws {
        let env = try TestEnv()
        let link = env.addonsDir.appendingPathComponent("B")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: env.dir.appendingPathComponent("nowhere"))
        let zip = ZipWriter.make([("B/", ""), ("B/B.toc", "new B")])
        let folders = try await localInstaller(env, zip: zip).install(file, replacing: [], addonsDir: env.addonsDir)
        #expect(folders == ["B"])
        #expect(env.marker("B") == "new B")
    }

    /// Rollback must put a dangling symlink back rather than delete it.
    @Test func danglingSymlinkSurvivesRollback() async throws {
        let env = try TestEnv()
        let link = env.addonsDir.appendingPathComponent("B")
        let target = env.dir.appendingPathComponent("nowhere")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let zip = ZipWriter.make([("A/", ""), ("A/A.toc", "new A"), ("B/", ""), ("B/B.toc", "new B")])
        var installer = try localInstaller(env, zip: zip)
        installer.move = { src, dst in
            if src.lastPathComponent == "B" { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(at: src, to: dst)
        }
        await #expect(throws: (any Error).self) {
            try await installer.install(file, replacing: [], addonsDir: env.addonsDir)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(!env.exists("A"))
    }

    @Test(arguments: [
        [("../Escape/", ""), ("../Escape/x.toc", "evil")],
        [("Ok/", ""), ("Ok/../../Escape.toc", "evil")],
        [("/tmp/Escape.toc", "evil")],
    ])
    func rejectsUnsafePaths(entries: [(String, String)]) async throws {
        let env = try TestEnv()
        try env.makeFolder("Ok", marker: "untouched")
        let zip = ZipWriter.make(entries.map { (name: $0.0, contents: $0.1) })
        await #expect {
            try await localInstaller(env, zip: zip).install(file, replacing: ["Ok"], addonsDir: env.addonsDir)
        } throws: { error in
            guard case InstallError.badArchive(let msg) = error else { return false }
            return msg.hasPrefix("unsafe path")
        }
        #expect(env.marker("Ok") == "untouched")
        #expect(!FileManager.default.fileExists(atPath: env.dir.appendingPathComponent("Escape").path))
    }

    @Test func rejectsArchiveWithoutFolders() async throws {
        let env = try TestEnv()
        try env.makeFolder("Old")
        let zip = ZipWriter.make([("loose.toc", "x")])
        await #expect(throws: InstallError.self) {
            try await localInstaller(env, zip: zip).install(file, replacing: ["Old"], addonsDir: env.addonsDir)
        }
        #expect(env.marker("Old") == "old")
    }

    /// The whole update flow with the real Installer underneath the Model.
    @Test func modelUpdateWithRealInstaller() async throws {
        let env = try TestEnv(key: "k", addons: [tracked(5, "New", fileId: 400, folders: ["New", "Gone"])])
        try env.makeFolder("New")
        try env.makeFolder("Gone")
        env.api.add(cfMod(5, "New", files: [(500, 1, retail)]), file)
        let zip = ZipWriter.make([("New/", ""), ("New/New.toc", "fresh")])
        let model = env.makeModel(installer: try localInstaller(env, zip: zip))
        await model.checkForUpdates()
        await model.updateAll()
        #expect(model.message == "All updates installed.")
        #expect(env.store.config?.addons.first?.folders == ["New"])
        #expect(env.marker("New") == "fresh")
        #expect(!env.exists("Gone"))
    }
}
