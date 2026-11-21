import Foundation

/// An addon we manage. `id` is the CurseForge project ID.
struct TrackedAddon: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var fileId: Int
    var version: String
    var fileDate: Date?
    var folders: [String]
    var websiteURL: String?
}

struct Config: Codable {
    /// Only present in configs written before the key moved to the Keychain.
    var legacyApiKey: String?
    var addonsPath: String = "/Applications/World of Warcraft/_retail_/Interface/AddOns"
    /// CurseForge game-version type: 517 = Retail.
    var gameVersionTypeId: Int = 517
    /// Include beta/alpha files when looking for updates.
    var allowPrerelease: Bool = false
    var addons: [TrackedAddon] = []
    /// nil/false until the welcome flow has been completed.
    var onboarded: Bool?
    /// How often to check for updates while the app is closed; nil = never (see BackgroundCheck).
    var backgroundCheckHours: Int?
    /// Look for a newer Reforge on GitHub when the app opens; nil = on (see AppUpdate.swift).
    var checkAppUpdates: Bool?

    enum CodingKeys: String, CodingKey {
        case legacyApiKey = "apiKey", addonsPath, gameVersionTypeId, allowPrerelease, addons, onboarded,
             backgroundCheckHours, checkAppUpdates
    }
}

/// Where Model persists its config; tests pass a temp dir or an in-memory store.
protocol ConfigStore {
    func load() -> Config?
    func save(_ config: Config)
}

/// config.json in `dir` (the app's real settings folder by default).
struct FileConfigStore: ConfigStore {
    var dir = Store.dir
    func load() -> Config? { Store.load(dir: dir) }
    func save(_ config: Config) { Store.save(config, dir: dir) }
}

enum Store {
    static let dir = DevMode.dir ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Reforge", isDirectory: true)
    /// Where settings lived before the app was renamed from "Addon Updater".
    private static let legacyDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AddonUpdater", isDirectory: true)

    static func load(dir: URL = dir) -> Config? {
        let fm = FileManager.default
        let file = dir.appendingPathComponent("config.json")
        if dir == Store.dir, DevMode.dir == nil, !fm.fileExists(atPath: file.path), fm.fileExists(atPath: legacyDir.appendingPathComponent("config.json").path) {
            try? fm.moveItem(at: legacyDir, to: dir)
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(Config.self, from: data)
    }

    static func save(_ config: Config, dir: URL = dir) {
        let file = dir.appendingPathComponent("config.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(config).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            NSLog("Reforge: failed to save config: \(error)")
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }()

    // Formatters are expensive to create; build them once.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? {
        fractionalFormatter.date(from: s) ?? plainFormatter.date(from: s)
    }

    /// No response cache: nothing we fetch is worth keeping in memory or on disk.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
}

/// Reads the CurseForge app's own tracking file so existing installs carry over.
enum CurseForgeImport {
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CurseForge/agent/GameInstances/AddonGameInstance.json")

    static func importAddons(addonsPath: String, from file: URL = file) -> [TrackedAddon] {
        guard let data = try? Data(contentsOf: file),
              let instances = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let wanted = URL(fileURLWithPath: addonsPath).standardized.path
        var result: [TrackedAddon] = []
        for inst in instances {
            for a in inst["installedAddons"] as? [[String: Any]] ?? [] {
                guard let folder = a["modFolderPath"] as? String,
                      URL(fileURLWithPath: folder).standardized.path == wanted,
                      let id = a["addonID"] as? Int ?? a["addonId"] as? Int,
                      let file = a["installedFile"] as? [String: Any],
                      let fileId = file["id"] as? Int else { continue }
                let modules = (file["modules"] as? [[String: Any]] ?? []).compactMap { $0["foldername"] as? String }
                let fileName = file["fileName"] as? String ?? ""
                let version = (file["displayName"] as? String)
                    ?? (fileName.hasSuffix(".zip") ? String(fileName.dropLast(4)) : fileName)
                result.append(TrackedAddon(
                    id: id,
                    name: a["name"] as? String ?? "Addon \(id)",
                    fileId: fileId,
                    version: version,
                    fileDate: (file["fileDate"] as? String).flatMap(Store.parseDate),
                    folders: modules,
                    websiteURL: a["webSiteURL"] as? String))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
