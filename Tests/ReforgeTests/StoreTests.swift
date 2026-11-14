import Foundation
import Testing
@testable import Reforge

@Suite("Config persistence")
struct StoreTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ReforgeTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func roundTripsThroughFile() throws {
        let dir = tempDir().appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = FileConfigStore(dir: dir)
        #expect(store.load() == nil)

        var config = Config()
        config.addonsPath = "/tmp/AddOns"
        config.gameVersionTypeId = classicEra
        config.allowPrerelease = true
        config.onboarded = true
        config.addons = [TrackedAddon(id: 1, name: "Alpha", fileId: 10, version: "1.0", fileDate: fileDate,
                                      folders: ["Alpha"], websiteURL: "https://example.invalid")]
        store.save(config)

        let file = dir.appendingPathComponent("config.json")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let loaded = try #require(store.load())
        #expect(loaded.addonsPath == "/tmp/AddOns")
        #expect(loaded.gameVersionTypeId == classicEra)
        #expect(loaded.allowPrerelease)
        #expect(loaded.onboarded == true)
        #expect(loaded.addons == config.addons)
        #expect(loaded.legacyApiKey == nil)
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("apiKey"))
    }

    @Test func readsLegacyKeyField() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"apiKey":"old","addonsPath":"/x","gameVersionTypeId":517,"allowPrerelease":false,"addons":[]}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        let loaded = try #require(FileConfigStore(dir: dir).load())
        #expect(loaded.legacyApiKey == "old")
        #expect(loaded.onboarded == nil)
    }

    @Test func parsesBothDateForms() {
        #expect(Store.parseDate("2024-01-02T03:04:05Z") == Date(timeIntervalSince1970: 1_704_164_645))
        #expect(Store.parseDate("2024-01-02T03:04:05.500Z") == Date(timeIntervalSince1970: 1_704_164_645.5))
        #expect(Store.parseDate("yesterday") == nil)
    }

    @Test func modPicksNewestMatchingFile() {
        let mod = cfMod(1, "A", files: [(10, 1, retail), (30, 2, retail), (20, 1, retail), (40, 1, classicEra)])
        #expect(mod.latestFileId(gameVersionTypeId: retail, allowPrerelease: false) == 20)
        #expect(mod.latestFileId(gameVersionTypeId: retail, allowPrerelease: true) == 30)
        #expect(mod.latestFileId(gameVersionTypeId: 1, allowPrerelease: true) == nil)
    }

    @Test func downloadURLFallsBackToCDN() {
        let f = CFFile(id: 4_567_890, modId: 1, displayName: "X", fileName: "My Addon.zip", fileDate: fileDate,
                       releaseType: 1, downloadUrl: nil, modules: nil)
        #expect(f.resolvedDownloadURL?.absoluteString == "https://edge.forgecdn.net/files/4567/890/My%20Addon.zip")
    }
}
