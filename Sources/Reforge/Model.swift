import Foundation
import Observation

enum RowStatus: Equatable {
    case unknown, upToDate, updateAvailable, working, failed(String)
}

@MainActor @Observable
final class Model {
    var config: Config
    var latest: [Int: CFFile] = [:]          // project id -> newest matching file
    var status: [Int: RowStatus] = [:]
    var checking = false
    var message: String?
    var lastChecked: Date?
    /// Lives in the Keychain, never in config.json.
    var apiKey: String = ""
    /// Shown under the background-check setting when turning it on didn't work.
    var backgroundCheckProblem: String?

    // Production dependencies by default; tests inject fakes.
    private let makeAPI: (String) -> CurseForgeClient
    private let keyStore: KeyStore
    private let configStore: ConfigStore
    private let installer: AddonInstaller
    private let curseForgeImportFile: URL
    private let now: () -> Date
    /// Asks the user for a folder, starting at the given one; nil if they cancel.
    let chooseFolder: @MainActor (URL) -> URL?
    private let scheduler: BackgroundScheduler
    private let notifier: UpdateNotifier

    init(makeAPI: @escaping (String) -> CurseForgeClient = { CurseForgeAPI(apiKey: $0) },
         keyStore: KeyStore = SystemKeyStore(),
         configStore: ConfigStore = FileConfigStore(),
         installer: AddonInstaller = Installer(),
         curseForgeImportFile: URL = CurseForgeImport.file,
         now: @escaping () -> Date = Date.init,
         chooseFolder: @escaping @MainActor (URL) -> URL? = FolderPicker.openPanel,
         scheduler: BackgroundScheduler = LaunchAgentScheduler(),
         notifier: UpdateNotifier = SystemNotifier()) {
        self.makeAPI = makeAPI
        self.scheduler = scheduler
        self.notifier = notifier
        self.chooseFolder = chooseFolder
        self.keyStore = keyStore
        self.configStore = configStore
        self.installer = installer
        self.curseForgeImportFile = curseForgeImportFile
        self.now = now
        if let saved = configStore.load() {
            config = saved
        } else {
            // Fresh install: the welcome flow picks the folder and imports addons.
            config = Config()
        }
        apiKey = keyStore.read()
        // One-time move of a key saved by older versions into the Keychain.
        if let legacy = config.legacyApiKey {
            if apiKey.isEmpty, !legacy.isEmpty, keyStore.write(legacy) { apiKey = legacy }
            if !apiKey.isEmpty || legacy.isEmpty { config.legacyApiKey = nil; configStore.save(config) }
        }
    }

    var api: CurseForgeClient { makeAPI(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var addonsDir: URL { URL(fileURLWithPath: config.addonsPath, isDirectory: true) }
    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    func saveAPIKey() {
        apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyStore.write(apiKey) { message = "Couldn't save the API key to the Keychain." }
    }
    // MARK: Onboarding

    var needsOnboarding: Bool { config.onboarded != true }

    func finishOnboarding() { config.onboarded = true; save() }

    func showOnboardingAgain() { config.onboarded = false; save() }

    static func defaultAddonsPath(gameVersionTypeId: Int) -> String {
        let flavor = [517: "_retail_", 67408: "_classic_era_", 79434: "_classic_", 73246: "_anniversary_"][gameVersionTypeId] ?? "_retail_"
        return "/Applications/World of Warcraft/\(flavor)/Interface/AddOns"
    }

    /// CurseForge-managed addons in the chosen folder that we don't track yet.
    func importCandidates() -> [TrackedAddon] {
        let known = Set(config.addons.map(\.id))
        return CurseForgeImport.importAddons(addonsPath: config.addonsPath, from: curseForgeImportFile).filter { !known.contains($0.id) }
    }

    func importAddons(_ list: [TrackedAddon]) {
        config.addons += list
        sort(); save()
    }

    /// Checks the key against CurseForge and saves it to the Keychain. Returns an error message on failure.
    func verifyAndSaveKey(_ key: String) async -> String? {
        do {
            try await makeAPI(key).validateKey()
        } catch CFError.http(403, _) {
            return "CurseForge didn't accept that key. It should start with $2a$10$."
        } catch {
            return error.localizedDescription
        }
        apiKey = key
        saveAPIKey()
        return nil
    }

    // MARK: Background checks

    /// Turns checking while the app is closed on (every `hours` hours) or off (nil).
    func setBackgroundChecks(hours: Int?) async {
        backgroundCheckProblem = nil
        if hours != nil, !(await notifier.requestPermission()) {
            backgroundCheckProblem = "Reforge isn't allowed to send notifications. Turn them on in System Settings › Notifications."
            return
        }
        do {
            try scheduler.set(hours: hours)
            config.backgroundCheckHours = hours
            save()
        } catch {
            backgroundCheckProblem = "Couldn't schedule background checks: \(error.localizedDescription)"
        }
    }

    /// Re-applies the saved schedule at launch, e.g. after the app was moved or reinstalled.
    func syncBackgroundChecks() {
        do { try scheduler.set(hours: config.backgroundCheckHours) }
        catch { NSLog("Reforge: couldn't sync background checks: \(error.localizedDescription)") }
    }

    var updatable: [TrackedAddon] { config.addons.filter { status[$0.id] == .updateAvailable } }

    func save() { configStore.save(config) }

    func reimportFromCurseForge() {
        let imported = CurseForgeImport.importAddons(addonsPath: config.addonsPath, from: curseForgeImportFile)
        let known = Set(config.addons.map(\.id))
        let new = imported.filter { !known.contains($0.id) }
        config.addons += new
        sort(); save()
        message = new.isEmpty ? "Nothing new to import." : "Imported \(new.count) addons."
    }

    func checkForUpdates() async {
        guard hasKey, !config.addons.isEmpty, !checking else { return }
        checking = true; message = nil
        defer { checking = false }
        do {
            let mods = try await api.mods(config.addons.map(\.id))
            var wanted: [Int: Int] = [:]
            for m in mods {
                if let f = m.latestFileId(gameVersionTypeId: config.gameVersionTypeId,
                                          allowPrerelease: config.allowPrerelease) { wanted[m.id] = f }
            }
            let files = wanted.isEmpty ? [] : try await api.files(Array(wanted.values))
            let byId = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for a in config.addons {
                guard let fid = wanted[a.id], let f = byId[fid] else { status[a.id] = .unknown; continue }
                latest[a.id] = f
                if status[a.id] != .working {
                    status[a.id] = f.id > a.fileId ? .updateAvailable : .upToDate
                }
            }
            lastChecked = now()
            let n = updatable.count
            message = n == 0 ? "Everything is up to date." : "\(n) update\(n == 1 ? "" : "s") available."
        } catch {
            message = error.localizedDescription
        }
    }

    func update(_ addon: TrackedAddon) async {
        guard let file = latest[addon.id] else { return }
        status[addon.id] = .working
        do {
            let folders = try await installer.install(file, replacing: addon.folders, addonsDir: addonsDir)
            if let i = config.addons.firstIndex(where: { $0.id == addon.id }) {
                config.addons[i].fileId = file.id
                config.addons[i].version = file.displayName
                config.addons[i].fileDate = file.fileDate
                config.addons[i].folders = folders
            }
            save()
            status[addon.id] = .upToDate
            message = "Updated \(addon.name) to \(file.displayName)."
        } catch {
            status[addon.id] = .failed(error.localizedDescription)
            message = "\(addon.name): \(error.localizedDescription)"
        }
    }

    func updateAll() async {
        for a in updatable { await update(a) }
        let failed = config.addons.filter { if case .failed = status[$0.id] { return true }; return false }
        message = failed.isEmpty ? "All updates installed." : "\(failed.count) update(s) failed."
    }

    /// Accepts a CurseForge project ID or a curseforge.com/wow/addons/<slug> URL or bare slug.
    func add(_ input: String) async {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        message = "Looking up \(s)…"
        do {
            let mod: CFMod
            if let id = Int(s) {
                mod = try await api.mod(id)
            } else {
                var slug = s
                if let r = s.range(of: "/addons/") { slug = String(s[r.upperBound...]) }
                slug = String(slug.split(whereSeparator: { "/?#".contains($0) }).first ?? "")
                guard let m = try await api.mod(slug: slug) else { throw CFError.notFound(s) }
                mod = m
            }
            if config.addons.contains(where: { $0.id == mod.id }) { message = "\(mod.name) is already tracked."; return }
            guard let fid = mod.latestFileId(gameVersionTypeId: config.gameVersionTypeId,
                                             allowPrerelease: config.allowPrerelease),
                  let file = try await api.files([fid]).first else {
                message = "\(mod.name) has no file for this game version."; return
            }
            message = "Installing \(mod.name)…"
            let folders = try await installer.install(file, replacing: [], addonsDir: addonsDir)
            config.addons.append(TrackedAddon(id: mod.id, name: mod.name, fileId: file.id, version: file.displayName,
                                              fileDate: file.fileDate, folders: folders,
                                              websiteURL: mod.links?.websiteUrl))
            sort(); save()
            latest[mod.id] = file
            status[mod.id] = .upToDate
            message = "Installed \(mod.name)."
        } catch {
            message = error.localizedDescription
        }
    }

    func remove(_ addon: TrackedAddon, deleteFiles: Bool) {
        if deleteFiles {
            do { try installer.uninstall(folders: addon.folders, addonsDir: addonsDir) }
            catch { message = error.localizedDescription; return }
        }
        config.addons.removeAll { $0.id == addon.id }
        save()
        message = deleteFiles ? "Moved \(addon.name) to the Trash." : "Stopped tracking \(addon.name)."
    }

    private func sort() {
        config.addons.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
