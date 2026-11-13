import Foundation

/// `make dev` launches the app with REFORGE_DEV_DIR pointing at the repo's git-ignored `.dev/`
/// folder. In that mode settings and the API key live there instead of Application Support and
/// the Keychain, so rebuilt (re-signed) dev copies never trigger Keychain password prompts and
/// never touch your real setup.
enum DevMode {
    static let dir: URL? = {
        guard let path = ProcessInfo.processInfo.environment["REFORGE_DEV_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

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
