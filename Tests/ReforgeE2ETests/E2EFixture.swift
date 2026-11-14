import Foundation

// One test's world on disk: a unique temp dir holding the fixture the app's stub mode reads
// (see Sources/Reforge/E2EStubs.swift), plus the config/key/import files it starts from.

let goodKey = "$2a$10$e2e-good-key"
let badKey = "$2a$10$e2e-rejected-key"

/// Alpha and Bravo are tracked with older files; Charlie can be added; Delta comes from the import file.
enum Mods {
    static let alpha = 101, bravo = 102, charlie = 103, delta = 104
}

final class E2EFixture {
    let dir: URL
    var fixtureFile: URL { dir.appendingPathComponent("fixture.json") }
    var addonsDir: URL { dir.appendingPathComponent("AddOns", isDirectory: true) }

    enum Start {
        /// Welcome flow, no key, one addon waiting in the CurseForge import file.
        case fresh
        /// Onboarded, valid key, Alpha and Bravo tracked with updates available.
        case tracking
    }

    /// `edit` adjusts the stub's fixture.json (see E2E.Fixture) before the app reads it.
    init(_ start: Start, edit: (inout [String: Any]) -> Void = { _ in }) throws {
        let fm = FileManager.default
        dir = fm.temporaryDirectory.appendingPathComponent("ReforgeE2E-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: addonsDir, withIntermediateDirectories: true)
        var fixture = Self.fixture
        edit(&fixture)
        try write("fixture.json", fixture)
        switch start {
        case .fresh:
            try write("config.json", config(onboarded: false, addons: []))
            try write("AddonGameInstance.json", [["installedAddons": [[
                "addonID": Mods.delta, "name": "Delta", "modFolderPath": addonsDir.path,
                "installedFile": ["id": 4000, "displayName": "Delta 4.0", "modules": [["foldername": "Delta"]]],
            ]]]])
        case .tracking:
            try write("config.json", config(onboarded: true, addons: [
                tracked(Mods.alpha, "Alpha", fileId: 1000),
                tracked(Mods.bravo, "Bravo", fileId: 2000),
            ]))
            try Data(goodKey.utf8).write(to: dir.appendingPathComponent("api-key"))
        }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// Makes a folder inside this test's dir, e.g. one the stubbed folder picker returns.
    @discardableResult
    func makeFolder(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Reading back what the app did

    /// Lines of installs.jsonl: what the stub installer was asked to install.
    var installs: [(fileId: Int, replacing: [String])] {
        lines("installs.jsonl").compactMap { obj in
            guard let o = obj as? [String: Any], let id = o["fileId"] as? Int else { return nil }
            return (id, o["replacing"] as? [String] ?? [])
        }
    }

    var uninstalls: [[String]] { lines("uninstalls.jsonl").compactMap { $0 as? [String] } }

    var savedKey: String? {
        (try? String(contentsOf: dir.appendingPathComponent("api-key"), encoding: .utf8))
    }

    /// The saved config.json as a dictionary.
    var config: [String: Any] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    var trackedFileIds: [Int: Int] {
        var out: [Int: Int] = [:]
        for a in config["addons"] as? [[String: Any]] ?? [] {
            if let id = a["id"] as? Int, let f = a["fileId"] as? Int { out[id] = f }
        }
        return out
    }

    // MARK: Helpers

    private func lines(_ name: String) -> [Any] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }

    private func write(_ name: String, _ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent(name))
    }

    private func config(onboarded: Bool, addons: [[String: Any]]) -> [String: Any] {
        ["addonsPath": addonsDir.path, "gameVersionTypeId": 517, "allowPrerelease": false,
         "addons": addons, "onboarded": onboarded]
    }

    private func tracked(_ id: Int, _ name: String, fileId: Int) -> [String: Any] {
        ["id": id, "name": name, "fileId": fileId, "version": "\(name) old", "folders": [name]]
    }

    static func mod(_ id: Int, _ name: String, latest: Int) -> [String: Any] {
        ["id": id, "name": name, "slug": name.lowercased(),
         "links": ["websiteUrl": "https://www.curseforge.com/wow/addons/\(name.lowercased())"],
         "latestFilesIndexes": [["fileId": latest, "releaseType": 1, "gameVersionTypeId": 517]]]
    }

    static func file(_ id: Int, mod: Int, _ displayName: String, folder: String) -> [String: Any] {
        ["id": id, "modId": mod, "displayName": displayName, "fileName": "\(displayName).zip",
         "fileDate": "2024-01-01T00:00:00Z", "releaseType": 1, "modules": [["name": folder]]]
    }

    private static let fixture: [String: Any] = [
        "validKeys": [goodKey],
        "mods": [
            mod(Mods.alpha, "Alpha", latest: 1001),
            mod(Mods.bravo, "Bravo", latest: 2001),
            mod(Mods.charlie, "Charlie", latest: 3001),
            mod(Mods.delta, "Delta", latest: 4000),
        ],
        "files": [
            file(1001, mod: Mods.alpha, "Alpha 1.1", folder: "Alpha"),
            file(2001, mod: Mods.bravo, "Bravo 2.1", folder: "Bravo"),
            file(3001, mod: Mods.charlie, "Charlie 3.1", folder: "Charlie"),
            file(4000, mod: Mods.delta, "Delta 4.0", folder: "Delta"),
        ],
    ]
}
