import Foundation

/// End-to-end stub mode, used only by `make e2e` (Tests/ReforgeE2ETests).
///
/// When REFORGE_E2E_FIXTURE points at a JSON fixture, the app builds its Model with fakes:
/// CurseForge answers from the fixture, settings and the API key live next to the fixture,
/// and installs/uninstalls are appended to log files there. No network, no Keychain, no real
/// AddOns folder, no Trash. When the variable is unset, `makeModel()` returns nil and the app
/// builds the normal production `Model()`.
///
/// Files in the fixture's folder:
///   fixture.json              {"validKeys": [...], "mods": [CFMod...], "files": [CFFile...],
///                              "laterMods": [CFMod...]?, "pickFolder": "name"?}
///   config.json               settings (seed it, or leave it out for a fresh install)
///   api-key                   the saved key
///   AddonGameInstance.json    stands in for the CurseForge app's tracking file
///   installs.jsonl            one {"fileId", "modId", "replacing"} line per install
///   uninstalls.jsonl          one ["Folder", ...] line per uninstall
enum E2E {
    struct Fixture: Decodable {
        /// Keys validateKey accepts; anything else gets HTTP 403 like the real API.
        var validKeys: [String]
        var mods: [CFMod]
        var files: [CFFile]
        /// From the second update check on, these replace the mods with the same id. Lets a test
        /// tell a manual refresh apart from the check the window runs when it opens.
        var laterMods: [CFMod]?
        /// What the folder picker "chooses": a folder name inside the fixture's folder. Unset = cancel.
        var pickFolder: String?
    }

    /// Shared by every stub client the Model creates, so it can count update checks.
    final class Calls { var modsCalls = 0 }

    @MainActor
    static func makeModel(environment: [String: String] = ProcessInfo.processInfo.environment) -> Model? {
        guard let path = environment["REFORGE_E2E_FIXTURE"], !path.isEmpty else { return nil }
        let file = URL(fileURLWithPath: path)
        let dir = file.deletingLastPathComponent()
        // Never fall back to production dependencies in this mode.
        guard let data = try? Data(contentsOf: file) else { fatalError("REFORGE_E2E_FIXTURE: can't read \(path)") }
        let fixture: Fixture
        do { fixture = try Store.decoder.decode(Fixture.self, from: data) }
        catch { fatalError("REFORGE_E2E_FIXTURE: bad fixture \(path): \(error)") }
        let calls = Calls()
        return Model(makeAPI: { StubCurseForge(key: $0, fixture: fixture, calls: calls) },
                     keyStore: FileKeyStore(file: dir.appendingPathComponent("api-key")),
                     configStore: FileConfigStore(dir: dir),
                     installer: RecordingInstaller(dir: dir),
                     curseForgeImportFile: dir.appendingPathComponent("AddonGameInstance.json"),
                     chooseFolder: { _ in fixture.pickFolder.map { dir.appendingPathComponent($0, isDirectory: true) } })
    }
}

/// CurseForge client that answers from the fixture.
struct StubCurseForge: CurseForgeClient {
    let key: String
    let fixture: E2E.Fixture
    let calls: E2E.Calls

    private func authorize() throws {
        if key.isEmpty { throw CFError.noKey }
        if !fixture.validKeys.contains(key) { throw CFError.http(403, "Forbidden") }
    }

    func validateKey() async throws { try authorize() }
    func mods(_ ids: [Int]) async throws -> [CFMod] {
        try authorize()
        calls.modsCalls += 1
        var mods = fixture.mods
        if calls.modsCalls > 1, let later = fixture.laterMods {
            mods = mods.map { m in later.first { $0.id == m.id } ?? m }
        }
        return mods.filter { ids.contains($0.id) }
    }
    func mod(_ id: Int) async throws -> CFMod {
        try authorize()
        guard let m = fixture.mods.first(where: { $0.id == id }) else { throw CFError.http(404, "not found") }
        return m
    }
    func files(_ ids: [Int]) async throws -> [CFFile] {
        try authorize()
        return fixture.files.filter { ids.contains($0.id) }
    }
    func mod(slug: String) async throws -> CFMod? {
        try authorize()
        return fixture.mods.first { $0.slug == slug }
    }
}

/// The API key in a plain file (same format as dev mode's `.dev/api-key`).
struct FileKeyStore: KeyStore {
    let file: URL
    func read() -> String {
        (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    func write(_ key: String) -> Bool { DevMode.writeKey(key, to: file) }
}

/// Logs installs and uninstalls instead of downloading or touching the AddOns folder.
struct RecordingInstaller: AddonInstaller {
    let dir: URL

    func install(_ file: CFFile, replacing oldFolders: [String], addonsDir: URL) async throws -> [String] {
        let entry: [String: Any] = ["fileId": file.id, "modId": file.modId, "replacing": oldFolders]
        try append(entry, to: "installs.jsonl")
        let folders = (file.modules ?? []).map(\.name)
        return folders.isEmpty ? [file.displayName] : folders
    }

    func uninstall(folders: [String], addonsDir: URL) throws {
        try append(folders, to: "uninstalls.jsonl")
    }

    private func append(_ object: Any, to name: String) throws {
        let url = dir.appendingPathComponent(name)
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }
}
