import Foundation
@testable import Reforge

// Shared fakes and fixtures. Every test builds its own `TestEnv` (own temp dir, own fakes),
// so nothing is shared between tests and Swift Testing can run them in parallel.

let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
let fileDate = Date(timeIntervalSince1970: 1_690_000_000)
let retail = 517, classicEra = 67408

// MARK: Fixtures

func cfMod(_ id: Int, _ name: String, slug: String? = nil,
           files: [(id: Int, releaseType: Int, gameVersion: Int)] = []) -> CFMod {
    CFMod(id: id, name: name, slug: slug ?? name.lowercased(),
          links: .init(websiteUrl: "https://www.curseforge.com/wow/addons/\(slug ?? name.lowercased())"),
          latestFilesIndexes: files.map { .init(fileId: $0.id, releaseType: $0.releaseType, gameVersionTypeId: $0.gameVersion) })
}

func cfFile(_ id: Int, mod: Int, _ displayName: String, releaseType: Int = 1) -> CFFile {
    CFFile(id: id, modId: mod, displayName: displayName, fileName: "\(displayName).zip", fileDate: fileDate,
           releaseType: releaseType, downloadUrl: "https://example.invalid/\(id).zip", modules: nil)
}

func tracked(_ id: Int, _ name: String, fileId: Int, folders: [String]? = nil) -> TrackedAddon {
    TrackedAddon(id: id, name: name, fileId: fileId, version: "\(name) old", fileDate: nil,
                 folders: folders ?? [name], websiteURL: nil)
}

// MARK: Fakes

/// Canned CurseForge responses; records every call. Throws `.noKey` for an empty key like the real client.
final class FakeCurseForge: CurseForgeClient {
    var modsById: [Int: CFMod] = [:]
    var filesById: [Int: CFFile] = [:]
    /// Thrown by validateKey.
    var validateError: Error?
    /// Thrown by every data call.
    var error: Error?
    /// The key Model built the client with most recently.
    var key = ""
    private(set) var calls: [String] = []

    func add(_ mod: CFMod, _ files: CFFile...) {
        modsById[mod.id] = mod
        for f in files { filesById[f.id] = f }
    }

    private func call(_ name: String) throws {
        calls.append(name)
        if key.isEmpty { throw Reforge.CFError.noKey }
    }

    func validateKey() async throws {
        try call("validateKey(\(key))")
        if let validateError { throw validateError }
    }
    func mods(_ ids: [Int]) async throws -> [CFMod] {
        try call("mods(\(ids.sorted()))")
        if let error { throw error }
        return ids.sorted().compactMap { modsById[$0] }
    }
    func mod(_ id: Int) async throws -> CFMod {
        try call("mod(\(id))")
        if let error { throw error }
        guard let m = modsById[id] else { throw Reforge.CFError.http(404, "not found") }
        return m
    }
    func files(_ ids: [Int]) async throws -> [CFFile] {
        try call("files(\(ids.sorted()))")
        if let error { throw error }
        return ids.sorted().compactMap { filesById[$0] }
    }
    func mod(slug: String) async throws -> CFMod? {
        try call("mod(slug: \(slug))")
        if let error { throw error }
        return modsById.values.sorted { $0.id < $1.id }.first { $0.slug == slug }
    }

    var categoryList: [CFCategory] = []
    private(set) var searches: [SearchQuery] = []
    /// Lets a test hold a search mid-flight (to check that stale responses are dropped).
    var searchGate: (() async -> Void)?

    /// Name contains the text (case-insensitive), sorted by id, paged by index/pageSize.
    func search(_ q: SearchQuery) async throws -> (mods: [CFMod], total: Int) {
        try call("search(\(q.text))")
        searches.append(q)
        if let gate = searchGate { await gate() }
        if let error { throw error }
        let all = modsById.values.sorted { $0.id < $1.id }
            .filter { q.text.isEmpty || $0.name.localizedCaseInsensitiveContains(q.text) }
        return (Array(all.dropFirst(q.index).prefix(q.pageSize)), all.count)
    }

    func categories() async throws -> [CFCategory] {
        try call("categories")
        if let error { throw error }
        return categoryList
    }

    /// Fingerprint -> (project id, file) that fingerprintMatches recognises.
    var fingerprintFiles: [UInt32: (mod: Int, file: CFFile)] = [:]
    func fingerprintMatches(_ fingerprints: [UInt32]) async throws -> [CFFingerprintMatch] {
        try call("fingerprintMatches(\(fingerprints.count))")
        if let error { throw error }
        return fingerprints.compactMap { fingerprintFiles[$0] }.map { CFFingerprintMatch(id: $0.mod, file: $0.file) }
    }
}

final class FakeKeyStore: KeyStore {
    var stored = ""
    var failWrites = false
    private(set) var writes: [String] = []
    func read() -> String { stored }
    func write(_ key: String) -> Bool {
        writes.append(key)
        if failWrites { return false }
        stored = key
        return true
    }
}

final class MemoryConfigStore: ConfigStore {
    var config: Config?
    private(set) var saveCount = 0
    func load() -> Config? { config }
    func save(_ config: Config) { self.config = config; saveCount += 1 }
}

struct InstallFailure: LocalizedError {
    var errorDescription: String? { "disk on fire" }
}

/// Records installs; returns canned folders per file id, or throws for ids in `failing`.
final class FakeInstaller: AddonInstaller {
    var folders: [Int: [String]] = [:]
    var failing: Set<Int> = []
    var uninstallError: Error?
    private(set) var installs: [(fileId: Int, replacing: [String])] = []
    private(set) var uninstalls: [[String]] = []

    func install(_ file: CFFile, replacing oldFolders: [String], addonsDir: URL) async throws -> [String] {
        installs.append((file.id, oldFolders))
        if failing.contains(file.id) { throw InstallFailure() }
        return folders[file.id] ?? [file.displayName]
    }
    func uninstall(folders: [String], addonsDir: URL) throws {
        uninstalls.append(folders)
        if let uninstallError { throw uninstallError }
    }
}

/// Records schedule changes instead of touching launchd.
final class FakeScheduler: BackgroundScheduler {
    var error: Error?
    private(set) var calls: [Int?] = []
    func set(hours: Int?) throws {
        calls.append(hours)
        if let error { throw error }
    }
}

/// Answers the permission prompt with `allowed`; records posted notifications.
final class FakeNotifier: UpdateNotifier {
    var allowed = true
    private(set) var permissionRequests = 0
    private(set) var posts: [(title: String, body: String)] = []
    func requestPermission() async -> Bool { permissionRequests += 1; return allowed }
    func post(title: String, body: String) async { posts.append((title, body)) }
}

// MARK: Environment

/// One test's world: a unique temp dir plus fresh fakes, wired into a Model.
@MainActor
final class TestEnv {
    let dir: URL
    let api = FakeCurseForge()
    let keys = FakeKeyStore()
    let store = MemoryConfigStore()
    let installer = FakeInstaller()
    let scheduler = FakeScheduler()
    let notifier = FakeNotifier()

    var addonsDir: URL { dir.appendingPathComponent("AddOns", isDirectory: true) }
    var importFile: URL { dir.appendingPathComponent("AddonGameInstance.json") }

    /// `config: nil` simulates a fresh install. Otherwise the config points at this env's AddOns folder.
    init(key: String = "", config: Config? = Config(), addons: [TrackedAddon] = []) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReforgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("AddOns"), withIntermediateDirectories: true)
        keys.stored = key
        if var config {
            config.addonsPath = addonsDir.path
            config.addons = addons
            config.onboarded = true
            store.config = config
        }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func makeModel(installer: AddonInstaller? = nil) -> Model {
        let api = self.api
        return Model(makeAPI: { api.key = $0; return api },
                     keyStore: keys,
                     configStore: store,
                     installer: installer ?? self.installer,
                     curseForgeImportFile: importFile,
                     now: { fixedNow },
                     chooseFolder: { _ in nil },
                     scheduler: scheduler,
                     notifier: notifier)
    }

    func makeFolder(_ name: String, marker: String = "old") throws {
        let folder = addonsDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: folder.appendingPathComponent("\(name).toc"))
    }

    func marker(_ name: String) -> String? {
        (try? Data(contentsOf: addonsDir.appendingPathComponent(name).appendingPathComponent("\(name).toc")))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: addonsDir.appendingPathComponent(name).path)
    }
}

// MARK: Zip fixtures

/// Writes an uncompressed ("stored") zip in-process: deterministic, fast, and able to hold
/// entry names (like "../x") that the zip tools refuse to create.
enum ZipWriter {
    /// Entries ending in "/" are directories; others are files with the given contents.
    static func make(_ entries: [(name: String, contents: String)]) -> Data {
        var out = Data(), central = Data()
        for (name, contents) in entries {
            let isDir = name.hasSuffix("/")
            let body = Data(contents.utf8), nameData = Data(name.utf8)
            let crc = crc32(body)
            let offset = UInt32(out.count)
            out.le32(0x0403_4b50); out.le16(20); out.le16(0); out.le16(0)   // signature, version, flags, stored
            out.le16(0); out.le16(0x21)                                       // 1980-01-01 00:00
            out.le32(crc); out.le32(UInt32(body.count)); out.le32(UInt32(body.count))
            out.le16(UInt16(nameData.count)); out.le16(0)
            out.append(nameData); out.append(body)

            central.le32(0x0201_4b50); central.le16(20); central.le16(20); central.le16(0); central.le16(0)
            central.le16(0); central.le16(0x21)
            central.le32(crc); central.le32(UInt32(body.count)); central.le32(UInt32(body.count))
            central.le16(UInt16(nameData.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(isDir ? 0x10 : 0); central.le32(offset)
            central.append(nameData)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x0605_4b50); out.le16(0); out.le16(0)
        out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
        out.le32(UInt32(central.count)); out.le32(cdOffset); out.le16(0)
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

/// A real Installer whose download step copies a local zip and whose Trash is a folder in `env.dir`.
@MainActor
func localInstaller(_ env: TestEnv, zip: Data) throws -> Installer {
    let source = env.dir.appendingPathComponent("fixture.zip")
    try zip.write(to: source)
    let downloads = env.dir.appendingPathComponent("downloads", isDirectory: true)
    let trash = env.dir.appendingPathComponent("Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    return Installer(
        download: { _ in
            // Installer takes ownership of (moves) the downloaded file, so hand it a fresh copy.
            let copy = downloads.appendingPathComponent(UUID().uuidString + ".zip")
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        },
        trash: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
}
