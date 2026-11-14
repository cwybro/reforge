import Foundation
import Testing
@testable import Reforge

@Suite("Add addon") @MainActor
struct AddAddonTests {
    func env(addons: [TrackedAddon] = []) throws -> TestEnv {
        let env = try TestEnv(key: "k", addons: addons)
        env.api.add(cfMod(42, "Echo", slug: "echo-addon", files: [(4200, 1, retail)]), cfFile(4200, mod: 42, "Echo 1.2"))
        env.installer.folders[4200] = ["Echo", "Echo_Data"]
        return env
    }

    @Test(arguments: [
        ("42", "mod(42)"),
        (" 42\n", "mod(42)"),
        ("echo-addon", "mod(slug: echo-addon)"),
        ("https://www.curseforge.com/wow/addons/echo-addon", "mod(slug: echo-addon)"),
        ("https://www.curseforge.com/wow/addons/echo-addon/files?page=2#top", "mod(slug: echo-addon)"),
    ])
    func installsFromAnyInputForm(input: String, lookup: String) async throws {
        let env = try env(addons: [tracked(1, "Zulu", fileId: 1), tracked(2, "Alpha", fileId: 2)])
        let model = env.makeModel()
        await model.add(input)
        #expect(env.api.calls == [lookup, "files([4200])"])
        #expect(env.installer.installs.count == 1)
        #expect(env.installer.installs.first?.replacing == [])
        #expect(model.message == "Installed Echo.")
        #expect(model.config.addons.map(\.name) == ["Alpha", "Echo", "Zulu"])
        let echo = try #require(env.store.config?.addons.first { $0.id == 42 })
        #expect(echo.fileId == 4200 && echo.version == "Echo 1.2" && echo.fileDate == fileDate)
        #expect(echo.folders == ["Echo", "Echo_Data"])
        #expect(echo.websiteURL == "https://www.curseforge.com/wow/addons/echo-addon")
        #expect(model.status[42] == .upToDate)
        #expect(model.latest[42]?.id == 4200)
    }

    @Test func alreadyTracked() async throws {
        let env = try env(addons: [tracked(42, "Echo", fileId: 4000)])
        let model = env.makeModel()
        await model.add("42")
        #expect(model.message == "Echo is already tracked.")
        #expect(env.installer.installs.isEmpty)
        #expect(env.store.saveCount == 0)
    }

    @Test func noFileForGameVersion() async throws {
        let env = try env()
        env.store.config?.gameVersionTypeId = classicEra
        let model = env.makeModel()
        await model.add("echo-addon")
        #expect(model.message == "Echo has no file for this game version.")
        #expect(env.installer.installs.isEmpty)
        #expect(model.config.addons.isEmpty)
    }

    @Test func unknownSlug() async throws {
        let env = try env()
        let model = env.makeModel()
        await model.add("nope")
        #expect(model.message == "Couldn't find an addon matching “nope”.")
        #expect(model.config.addons.isEmpty)
    }

    @Test func installFailureLeavesAddonUntracked() async throws {
        let env = try env()
        env.installer.failing = [4200]
        let model = env.makeModel()
        await model.add("42")
        #expect(model.message == "disk on fire")
        #expect(model.config.addons.isEmpty)
        #expect(env.store.saveCount == 0)
    }

    @Test(arguments: ["", "   \n"])
    func blankInputDoesNothing(input: String) async throws {
        let env = try env()
        let model = env.makeModel()
        await model.add(input)
        #expect(env.api.calls.isEmpty)
        #expect(model.message == nil)
    }
}
