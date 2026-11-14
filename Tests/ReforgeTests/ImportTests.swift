import Foundation
import Testing
@testable import Reforge

@Suite("Import from CurseForge app") @MainActor
struct ImportTests {
    /// A CurseForge AddonGameInstance.json with one instance at our folder and one elsewhere.
    func writeFixture(_ env: TestEnv) throws {
        let json: [[String: Any]] = [
            ["installedAddons": [
                ["addonID": 10, "name": "Zeta", "modFolderPath": env.addonsDir.path + "/",
                 "webSiteURL": "https://www.curseforge.com/wow/addons/zeta",
                 "installedFile": ["id": 1001, "displayName": "Zeta 1.0", "fileName": "Zeta-1.0.zip",
                                   "fileDate": "2024-01-02T03:04:05.123Z",
                                   "modules": [["foldername": "Zeta"], ["foldername": "Zeta_Config"]]]],
                // Older files use `addonId` and have no displayName.
                ["addonId": 11, "name": "alpha", "modFolderPath": env.addonsDir.appendingPathComponent("../AddOns").path,
                 "installedFile": ["id": 1101, "fileName": "Alpha-2.3.zip", "fileDate": "2024-02-03T04:05:06Z",
                                   "modules": [["foldername": "Alpha"]]]],
                // Skipped: no installed file.
                ["addonID": 12, "name": "Broken", "modFolderPath": env.addonsDir.path],
            ]],
            ["installedAddons": [
                ["addonID": 99, "name": "Elsewhere", "modFolderPath": "/somewhere/else/AddOns",
                 "installedFile": ["id": 9901, "displayName": "E", "modules": []]],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: env.importFile)
    }

    @Test func candidatesComeFromTheChosenFolderOnly() throws {
        let env = try TestEnv()
        try writeFixture(env)
        let found = env.makeModel().importCandidates()
        #expect(found.map(\.name) == ["alpha", "Zeta"])   // case-insensitive sort
        let alpha = try #require(found.first), zeta = try #require(found.last)
        #expect(alpha.id == 11 && alpha.fileId == 1101 && alpha.version == "Alpha-2.3" && alpha.folders == ["Alpha"])
        #expect(alpha.fileDate == Store.parseDate("2024-02-03T04:05:06Z"))
        #expect(zeta.id == 10 && zeta.fileId == 1001 && zeta.version == "Zeta 1.0")
        #expect(zeta.folders == ["Zeta", "Zeta_Config"])
        #expect(zeta.websiteURL == "https://www.curseforge.com/wow/addons/zeta")
        #expect(zeta.fileDate == Store.parseDate("2024-01-02T03:04:05.123Z"))
    }

    @Test func candidatesExcludeTrackedAddons() throws {
        let env = try TestEnv(addons: [tracked(10, "Zeta", fileId: 1000)])
        try writeFixture(env)
        #expect(env.makeModel().importCandidates().map(\.id) == [11])
    }

    @Test func missingFileMeansNothingToImport() throws {
        let env = try TestEnv()
        #expect(env.makeModel().importCandidates().isEmpty)
    }

    @Test func importAddonsAppendsSortsAndSaves() throws {
        let env = try TestEnv(addons: [tracked(5, "Middle", fileId: 1)])
        try writeFixture(env)
        let model = env.makeModel()
        model.importAddons(model.importCandidates())
        #expect(model.config.addons.map(\.name) == ["alpha", "Middle", "Zeta"])
        #expect(env.store.config?.addons.map(\.id) == [11, 5, 10])
    }

    @Test func reimportReportsCountThenNothingNew() throws {
        let env = try TestEnv()
        try writeFixture(env)
        let model = env.makeModel()
        model.reimportFromCurseForge()
        #expect(model.message == "Imported 2 addons.")
        #expect(model.config.addons.count == 2)
        model.reimportFromCurseForge()
        #expect(model.message == "Nothing new to import.")
        #expect(model.config.addons.count == 2)
    }
}
