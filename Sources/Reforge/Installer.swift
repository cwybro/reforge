import Foundation

enum InstallError: LocalizedError {
    case noURL, badArchive(String), tool(String)
    var errorDescription: String? {
        switch self {
        case .noURL: return "No download URL for this file."
        case .badArchive(let s): return "Bad archive: \(s)"
        case .tool(let s): return s
        }
    }
}

/// Installs and removes addon folders; tests substitute a fake, or a real `Installer` with local hooks.
protocol AddonInstaller {
    func install(_ file: CFFile, replacing oldFolders: [String], addonsDir: URL) async throws -> [String]
    func uninstall(folders: [String], addonsDir: URL) throws
}

struct Installer: AddonInstaller {
    /// Fetches a file's zip into a local temp file that `install` then takes ownership of.
    var download: (URL) async throws -> URL = Installer.httpDownload
    /// Moves an item to the Trash.
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// Moves a freshly extracted folder into the AddOns folder.
    var move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }

    static func httpDownload(_ url: URL) async throws -> URL {
        let (tmp, resp) = try await Store.session.download(from: url)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
            throw InstallError.tool("Download failed (HTTP \(code))")
        }
        return tmp
    }

    /// Downloads `file`, swaps its folders into `addonsDir`, and returns the new folder list.
    /// Old folders are moved aside first and restored if anything fails.
    func install(_ file: CFFile, replacing oldFolders: [String], addonsDir: URL) async throws -> [String] {
        guard let url = file.resolvedDownloadURL else { throw InstallError.noURL }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Reforge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let tmp = try await download(url)
        let zip = work.appendingPathComponent("addon.zip")
        try fm.moveItem(at: tmp, to: zip)

        // Reject archives with absolute paths or ".." before extracting anything.
        let listing = try Self.run("/usr/bin/zipinfo", ["-1", zip.path])
        for entry in listing.split(separator: "\n") {
            if entry.hasPrefix("/") || entry.split(separator: "/").contains("..") {
                throw InstallError.badArchive("unsafe path \(entry)")
            }
        }

        let out = work.appendingPathComponent("x", isDirectory: true)
        _ = try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])

        let newFolders = try fm.contentsOfDirectory(atPath: out.path)
            .filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
            .filter { var isDir: ObjCBool = false
                return fm.fileExists(atPath: out.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue }
            .sorted()
        guard !newFolders.isEmpty else { throw InstallError.badArchive("no addon folders inside") }

        // Move every folder we're about to replace into a backup dir.
        let backup = work.appendingPathComponent("backup", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var movedAside: [String] = []
        let toReplace = Set(oldFolders + newFolders).filter(Self.isSafeName)
        do {
            for name in toReplace {
                let src = addonsDir.appendingPathComponent(name)
                if Self.itemExists(at: src) {
                    try fm.moveItem(at: src, to: backup.appendingPathComponent(name))
                    movedAside.append(name)
                }
            }
            for name in newFolders {
                try move(out.appendingPathComponent(name), addonsDir.appendingPathComponent(name))
            }
        } catch {
            // Roll back: remove anything partially installed, restore originals.
            for name in newFolders where !movedAside.contains(name) {
                try? fm.removeItem(at: addonsDir.appendingPathComponent(name))
            }
            for name in movedAside {
                let dst = addonsDir.appendingPathComponent(name)
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: backup.appendingPathComponent(name), to: dst)
            }
            throw error
        }
        return newFolders
    }

    /// Moves an addon's folders to the Trash.
    func uninstall(folders: [String], addonsDir: URL) throws {
        for name in folders where Self.isSafeName(name) {
            let url = addonsDir.appendingPathComponent(name)
            if Self.itemExists(at: url) {
                try trash(url)
            }
        }
    }

    /// True if anything is at `url`, including a symlink whose target is gone. (`fileExists`
    /// follows symlinks, so it reports a dangling link as missing and rollback would delete it.)
    static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/")
    }

    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw InstallError.tool("\(tool) failed: \(text.prefix(300))") }
        return text
    }
}
