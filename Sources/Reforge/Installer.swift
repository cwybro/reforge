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

enum Installer {
    /// Downloads `file`, swaps its folders into `addonsDir`, and returns the new folder list.
    /// Old folders are moved aside first and restored if anything fails.
    static func install(_ file: CFFile, replacing oldFolders: [String], addonsDir: URL) async throws -> [String] {
        guard let url = file.resolvedDownloadURL else { throw InstallError.noURL }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Reforge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (tmp, resp) = try await Store.session.download(from: url)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
            throw InstallError.tool("Download failed (HTTP \(code))")
        }
        let zip = work.appendingPathComponent("addon.zip")
        try fm.moveItem(at: tmp, to: zip)

        // Reject archives with absolute paths or ".." before extracting anything.
        let listing = try run("/usr/bin/zipinfo", ["-1", zip.path])
        for entry in listing.split(separator: "\n") {
            if entry.hasPrefix("/") || entry.split(separator: "/").contains("..") {
                throw InstallError.badArchive("unsafe path \(entry)")
            }
        }

        let out = work.appendingPathComponent("x", isDirectory: true)
        _ = try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])

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
        let toReplace = Set(oldFolders + newFolders).filter(isSafeName)
        do {
            for name in toReplace {
                let src = addonsDir.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) {
                    try fm.moveItem(at: src, to: backup.appendingPathComponent(name))
                    movedAside.append(name)
                }
            }
            for name in newFolders {
                try fm.moveItem(at: out.appendingPathComponent(name), to: addonsDir.appendingPathComponent(name))
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
    static func uninstall(folders: [String], addonsDir: URL) throws {
        for name in folders where isSafeName(name) {
            let url = addonsDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
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
