import Foundation

/// Dev builds (`build/Reforge Dev.app`) keep settings and the API key in the repo's git-ignored
/// `.dev/` folder instead of Application Support and the Keychain, so rebuilt (re-signed) dev
/// copies never trigger Keychain password prompts and never touch your real setup.
///
/// build.sh writes that folder into the dev bundle's Info.plist (`ReforgeDevDir`), so this holds
/// however the dev app is opened: `make dev`, Finder, Spotlight, or clicking its notification.
/// REFORGE_DEV_DIR overrides it. Release builds have neither and use the real locations.
enum DevMode {
    static let infoKey = "ReforgeDevDir"

    static let dir: URL? = resolve(environment: ProcessInfo.processInfo.environment,
                                   info: Bundle.main.infoDictionary ?? [:])

    static func resolve(environment: [String: String], info: [String: Any]) -> URL? {
        let path = [environment["REFORGE_DEV_DIR"], info[infoKey] as? String].compactMap { $0 }.first { !$0.isEmpty }
        return path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var keyFile: URL? { dir?.appendingPathComponent("api-key") }

    static func writeKey(_ key: String, to file: URL) -> Bool {
        let fm = FileManager.default
        if key.isEmpty { try? fm.removeItem(at: file); return true }
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(key.utf8).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            return false
        }
    }
}
