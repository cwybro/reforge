import Foundation
import Testing
@testable import Reforge

/// Writes files (relative path -> contents) under `dir`.
func writeFiles(_ files: [String: String], in dir: URL) throws {
    for (path, contents) in files {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}

/// A minimal addon folder: `<name>/<name>.toc` (with the given header lines) plus one Lua file.
func writeAddon(_ name: String, in dir: URL, header: [String] = [], lua: String = "print(1)") throws {
    try writeFiles(["\(name)/\(name).toc": (["## Interface: 110000"] + header + ["\(name).lua"]).joined(separator: "\n"),
                    "\(name)/\(name).lua": lua], in: dir)
}

@Suite("Fingerprints")
struct FingerprintTests {
    // Expected values come from a reference implementation that matched CurseForge's own
    // fingerprints for every folder of 7 real installed addons (15 folders).
    @Test(arguments: [("", 1_540_447_798 as UInt32), ("a", 626_045_324), ("ab", 1_692_487_918),
                      ("abc", 1_621_425_345), ("abcd", 3_376_380_438), ("hello world", 2_213_174_766)])
    func murmur2(input: String, expected: UInt32) {
        #expect(Fingerprint.murmur2(Array(input.utf8)) == expected)
    }

    @Test func fileFingerprintIgnoresWhitespace() {
        #expect(Fingerprint.file(Data("local x = 1\n\treturn x\r\n".utf8)) == 4_123_519_695)
        #expect(Fingerprint.file(Data("localx=1returnx".utf8)) == 4_123_519_695)
    }

    /// Every inclusion rule in one folder: flavor TOCs, TOC comments, backslash paths, case
    /// differences, XML comments, nested includes, ".." paths, missing files, Bindings.xml, and
    /// files nothing lists.
    static let foo: [String: String] = [
        "Foo/Foo.toc": "## Interface: 110000\n## Title: |cff00ff00Foo|r\n## Version: 1.2\n## X-Curse-Project-ID: 4242\n# comment\nFoo.lua\nlibs\\embeds.xml\n..\\Other\\evil.lua\nmissing.lua\n",
        "Foo/Foo_Mists.toc": "## Interface: 50500\nFoo.lua\n",
        "Foo/Foo.lua": "print('foo')\n",
        "Foo/Libs/Embeds.xml": "<Ui>\n<!-- <Script file=\"ignored.lua\"/> -->\n<Script file=\"Lib.lua\"/>\n<Include file=\"Sub\\sub.xml\"/>\n</Ui>\n",
        "Foo/Libs/Lib.lua": "local lib = {}\n",
        "Foo/Libs/Sub/sub.xml": "<Ui><Script file=\"deep.lua\" /></Ui>",
        "Foo/Libs/Sub/deep.lua": "return 1\n",
        "Foo/Libs/ignored.lua": "nope",
        "Foo/Bindings.xml": "<Bindings/>",
        "Foo/Unlisted.lua": "not included",
        "Foo/Other.toc": "## not ours",
    ]

    @Test func folderFingerprintFollowsInclusions() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFiles(Self.foo, in: dir)
        let folder = dir.appendingPathComponent("Foo")
        let names = Set(Fingerprint.includedFiles(in: folder).map { $0.lastPathComponent.lowercased() })
        #expect(names == ["bindings.xml", "foo.toc", "foo_mists.toc", "foo.lua", "embeds.xml", "lib.lua", "sub.xml", "deep.lua"])
        #expect(Fingerprint.folder(folder) == 1_699_912_582)
    }

    @Test func folderWithoutTocIsNotAnAddon() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFiles(["Junk/readme.txt": "hi"], in: dir)
        #expect(Fingerprint.folder(dir.appendingPathComponent("Junk")) == nil)
    }

    @Test func tocHeader() {
        let toc = TocInfo.parse("""
        ## Interface: 110000
        ## Title: |cff00ff00Foo|r Bar
        ## Version: 1.2
        ## Author: Someone
        ## X-Curse-Project-ID: 4242
        ## RequiredDeps: Ace3, LibStub
        ## Title: ignored second title
        Foo.lua
        """)
        #expect(toc == TocInfo(title: "Foo Bar", version: "1.2", author: "Someone", notes: nil,
                               curseProjectId: 4242, dependencies: ["Ace3", "LibStub"]))
    }

    @Test func scanSkipsTrackedAndNonAddonFolders() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAddon("Tracked", in: dir)
        try writeAddon("Mine", in: dir, header: ["## Title: Mine", "## Version: 0.1"])
        try writeFiles(["NotAnAddon/readme.txt": "x", ".hidden/.hidden.toc": "x", "stray.lua": "x"], in: dir)
        let found = LocalScanner.scan(addonsDir: dir, skipping: ["tracked"])
        #expect(found.map(\.name) == ["Mine"])
        #expect(found.first?.toc.version == "0.1")
    }
}

func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ReforgeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite("Grouping found addons")
struct DiscoveryGroupingTests {
    func folder(_ name: String, print: UInt32, title: String? = nil, project: Int? = nil) -> LocalFolder {
        LocalFolder(name: name, toc: TocInfo(title: title, version: "v-\(name)", curseProjectId: project), fingerprint: print)
    }

    func file(_ id: Int, mod: Int, modules: [(String, Int)]) -> CFFile {
        CFFile(id: id, modId: mod, displayName: "File \(id)", fileName: "f.zip", fileDate: fileDate, releaseType: 1,
               downloadUrl: nil, modules: modules.map { .init(name: $0.0, fingerprint: $0.1) })
    }

    @Test func fingerprintMatchesGroupTheFilesFolders() {
        let folders = [folder("DBM-Core", print: 1), folder("DBM-StatusBarTimers", print: 2), folder("Other", print: 9)]
        let match = CFFingerprintMatch(id: 8814, file: file(500, mod: 8814, modules: [("DBM-StatusBarTimers", 2), ("DBM-Core", 1)]))
        let found = Discovery.group(folders, matches: [match], mods: [8814: cfMod(8814, "Deadly Boss Mods")])
        #expect(found.map(\.title) == ["Deadly Boss Mods", "Other"])
        #expect(found[0].folders == ["DBM-StatusBarTimers", "DBM-Core"], "in the file's module order")
        #expect(found[0].projectId == 8814 && found[0].file?.id == 500 && found[0].version == "File 500")
        #expect(found[1].isLocal)
    }

    @Test func tocProjectIdCountsOnlyIfCurseForgeKnowsIt() {
        let folders = [folder("Foo", print: 1, title: "Foo!", project: 42), folder("Foo_Options", print: 2, project: 42),
                       folder("Bar", print: 3, project: 77)]
        let found = Discovery.group(folders, matches: [], mods: [42: cfMod(42, "Foo Addon")])
        #expect(found.map(\.title) == ["Foo Addon", "Bar"])
        #expect(found[0].folders == ["Foo", "Foo_Options"] && found[0].file == nil && found[0].version == "v-Foo")
        #expect(found[1].isLocal, "project 77 wasn't confirmed by CurseForge")
    }

    @Test func localHelpersGroupUnderTheirAddon() {
        let folders = [folder("Zed", print: 1, title: "Zed"), folder("Zed_Config", print: 2), folder("Zed-Extra_More", print: 3),
                       folder("Alpha", print: 4, title: "Alpha"), folder("Zedd", print: 5, title: "Zedd")]
        let found = Discovery.group(folders, matches: [], mods: [:])
        #expect(found.map(\.title) == ["Alpha", "Zed", "Zedd"])
        #expect(found[1].folders == ["Zed", "Zed-Extra_More", "Zed_Config"])
        #expect(found.allSatisfy { $0.isLocal })
    }
}

@Suite("Finding untracked addons") @MainActor
struct FoundAddonTests {
    /// Tracks Alpha (folder "Alpha"). On disk: Alpha, plus untracked Echo (+ Echo_Options, a CurseForge
    /// file matched by fingerprint), Foxtrot (X-Curse-Project-ID 9 in its .toc) and Homemade.
    func env(key: String = "k") throws -> TestEnv {
        let env = try TestEnv(key: key, addons: [tracked(1, "Alpha", fileId: 100)])
        try writeAddon("Alpha", in: env.addonsDir)
        try writeAddon("Echo", in: env.addonsDir, header: ["## Title: Echo"])
        try writeAddon("Echo_Options", in: env.addonsDir)
        try writeAddon("Foxtrot", in: env.addonsDir, header: ["## Title: Foxtrot", "## Version: 9.0", "## X-Curse-Project-ID: 9"])
        try writeAddon("Homemade", in: env.addonsDir, header: ["## Title: |cffff0000Home|rmade", "## Author: You", "## Version: 1.0.0"])
        let echo = Fingerprint.folder(env.addonsDir.appendingPathComponent("Echo"))!
        let options = Fingerprint.folder(env.addonsDir.appendingPathComponent("Echo_Options"))!
        let echoFile = CFFile(id: 4200, modId: 42, displayName: "Echo 1.2", fileName: "echo.zip", fileDate: fileDate,
                              releaseType: 1, downloadUrl: nil,
                              modules: [.init(name: "Echo", fingerprint: Int(echo)), .init(name: "Echo_Options", fingerprint: Int(options))])
        env.api.fingerprintFiles = [echo: (42, echoFile)]
        env.api.add(cfMod(1, "Alpha", files: [(100, 1, retail)]), cfFile(100, mod: 1, "Alpha 1"))
        env.api.add(cfMod(42, "Echo", files: [(4201, 1, retail)]), echoFile, cfFile(4201, mod: 42, "Echo 1.3"))
        env.api.add(cfMod(9, "Foxtrot", files: [(900, 1, retail)]), cfFile(900, mod: 9, "Foxtrot 9.1"))
        return env
    }

    @Test func findsAndIdentifiesUntrackedAddons() async throws {
        let env = try env()
        let model = env.makeModel()
        await model.scanAddonsFolder()
        #expect(model.found.map(\.title) == ["Echo", "Foxtrot", "Homemade"])
        let echo = model.found[0], fox = model.found[1], home = model.found[2]
        #expect(echo.folders == ["Echo", "Echo_Options"] && echo.file?.id == 4200 && echo.projectId == 42)
        #expect(fox.projectId == 9 && fox.file == nil && fox.version == "9.0")
        #expect(home.isLocal && home.author == "You" && home.version == "1.0.0")
        #expect(env.api.calls == ["fingerprintMatches(4)", "mods([9, 42])"], "Alpha is tracked, so it isn't sent")
    }

    @Test func trackingAFingerprintMatchRecordsTheInstalledFile() async throws {
        let env = try env()
        let model = env.makeModel()
        await model.scanAddonsFolder()
        await model.track(model.found[0])
        let echo = try #require(env.store.config?.addons.first { $0.id == 42 })
        #expect(echo.fileId == 4200 && echo.version == "Echo 1.2" && echo.folders == ["Echo", "Echo_Options"])
        #expect(env.installer.installs.isEmpty, "tracking downloads nothing")
        #expect(model.status[42] == .updateAvailable, "Echo 1.3 is newer than the installed 1.2")
        #expect(model.found.map(\.title) == ["Foxtrot", "Homemade"])
        #expect(model.message == "Now tracking Echo.")
    }

    @Test func trackingByTocIdOffersTheLatestFile() async throws {
        let env = try env()
        let model = env.makeModel()
        await model.scanAddonsFolder()
        await model.track(model.found[1])
        let fox = try #require(model.config.addons.first { $0.id == 9 })
        #expect(fox.fileId == 0 && fox.version == "9.0" && fox.folders == ["Foxtrot"])
        #expect(model.status[9] == .updateAvailable)
    }

    @Test func trackAllSkipsLocalAddons() async throws {
        let env = try env()
        let model = env.makeModel()
        await model.scanAddonsFolder()
        await model.trackAllFound()
        #expect(Set(model.config.addons.map(\.id)) == [1, 9, 42])
        #expect(model.found.map(\.title) == ["Homemade"])
        #expect(model.message == "Now tracking 2 addons.")
        #expect(env.api.calls.filter { $0.hasPrefix("mods(") }.count == 2, "one scan lookup and one update check")
    }

    @Test func aNewFolderOfATrackedAddonJoinsIt() async throws {
        let env = try env()
        env.store.config?.addons.append(tracked(42, "Echo", fileId: 4200, folders: ["Echo"]))
        let model = env.makeModel()
        await model.scanAddonsFolder()
        // Echo itself is tracked, so only Echo_Options is scanned. Nothing identifies it yet: local.
        let options = try #require(model.found.first { $0.folders == ["Echo_Options"] })
        #expect(options.isLocal)
        // Now CurseForge recognises it as part of Echo's file: tracking it joins the tracked Echo.
        let optionsPrint = Fingerprint.folder(env.addonsDir.appendingPathComponent("Echo_Options"))!
        env.api.fingerprintFiles[optionsPrint] = (42, env.api.filesById[4200]!)
        await model.scanAddonsFolder()
        let found = try #require(model.found.first { $0.folders == ["Echo_Options"] })
        await model.track(found)
        #expect(model.config.addons.filter { $0.id == 42 }.count == 1)
        #expect(model.config.addons.first { $0.id == 42 }?.folders == ["Echo", "Echo_Options"])
    }

    @Test func withoutAKeyEverythingIsLocal() async throws {
        let env = try env(key: "")
        let model = env.makeModel()
        await model.scanAddonsFolder()
        #expect(model.found.count == 3)
        #expect(model.found.allSatisfy { $0.isLocal })
        #expect(env.api.calls.isEmpty)
    }

    @Test func ifCurseForgeFailsEverythingIsLocal() async throws {
        let env = try env()
        env.api.error = Reforge.CFError.http(500, "down")
        let model = env.makeModel()
        await model.scanAddonsFolder()
        #expect(model.found.map(\.title) == ["Echo", "Foxtrot", "Homemade"])
        #expect(model.found.allSatisfy { $0.isLocal })
    }

    @Test func trashingALocalAddonMovesItsFolders() async throws {
        let env = try env()
        let model = env.makeModel()
        await model.scanAddonsFolder()
        let home = try #require(model.found.last)
        model.trash(home)
        #expect(env.installer.uninstalls == [["Homemade"]])
        #expect(!model.found.contains { $0.id == "Homemade" })
        #expect(model.message == "Moved Homemade to the Trash.")
    }

    @Test func stoppingTrackingListsTheAddonAsNotTracked() async throws {
        let env = try env()
        let alphaPrint = Fingerprint.folder(env.addonsDir.appendingPathComponent("Alpha"))!
        let alphaFile = CFFile(id: 100, modId: 1, displayName: "Alpha 1", fileName: "a.zip", fileDate: fileDate, releaseType: 1,
                               downloadUrl: nil, modules: [.init(name: "Alpha", fingerprint: Int(alphaPrint))])
        env.api.fingerprintFiles[alphaPrint] = (1, alphaFile)
        let model = env.makeModel()
        await model.scanAddonsFolder()
        #expect(!model.found.contains { $0.id == "Alpha" })

        await model.stopTracking(model.config.addons[0])
        #expect(model.config.addons.isEmpty)
        #expect(env.installer.uninstalls.isEmpty, "files stay")
        let alpha = try #require(model.found.first { $0.id == "Alpha" })
        #expect(alpha.projectId == 1 && alpha.file?.id == 100, "identified again, so it can be tracked back")
        #expect(model.message == "Stopped tracking Alpha.")
    }

    @Test func refreshChecksThenScans() async throws {
        let env = try env()
        let model = env.makeModel()
        await model.refresh()
        #expect(env.api.calls.first == "mods([1])")
        #expect(model.found.count == 3)
    }
}
