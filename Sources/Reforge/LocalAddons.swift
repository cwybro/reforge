import Foundation

// Finding addons in the AddOns folder that Reforge doesn't track yet.
//
// Each addon folder gets the same fingerprint CurseForge computes for the "modules" of its
// files, so CurseForge's fingerprint API can say exactly which project and file is installed.
// Folders it doesn't know (homemade, WoWInterface, Wago, GitHub) are listed as local addons.

/// CurseForge's addon fingerprint.
///
/// - A file's fingerprint is MurmurHash2 (seed 1) of its bytes with tabs, newlines, carriage
///   returns and spaces removed.
/// - A folder's fingerprint covers its `.toc` files (every `<Folder>.toc` / `<Folder>[-_]<flavor>.toc`),
///   the `.lua`/`.xml` files those list, everything the XML files `<Include>` or `<Script>`,
///   recursively, and `Bindings.xml`. The file fingerprints are sorted numerically, written out as
///   decimal digits with no separator, and that text is hashed again (as is, not normalized).
enum Fingerprint {
    static func murmur2<S: Sequence>(_ bytes: S, seed: UInt32 = 1) -> UInt32 where S.Element == UInt8 {
        let data = Array(bytes)
        let m: UInt32 = 0x5bd1_e995
        var h = seed ^ UInt32(truncatingIfNeeded: data.count)
        var i = 0
        while data.count - i >= 4 {
            var k = UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
            k = k &* m; k ^= k >> 24; k = k &* m
            h = h &* m; h ^= k
            i += 4
        }
        switch data.count - i {
        case 3: h ^= UInt32(data[i + 2]) << 16; fallthrough
        case 2: h ^= UInt32(data[i + 1]) << 8; fallthrough
        case 1: h ^= UInt32(data[i]); h = h &* m
        default: break
        }
        h ^= h >> 13; h = h &* m; h ^= h >> 15
        return h
    }

    /// One file's fingerprint (whitespace removed first).
    static func file(_ data: Data) -> UInt32 {
        murmur2(data.lazy.filter { $0 != 9 && $0 != 10 && $0 != 13 && $0 != 32 })
    }

    /// The folder's fingerprint, or nil when it has no `.toc` (so it isn't an addon).
    static func folder(_ folder: URL) -> UInt32? {
        let files = includedFiles(in: folder)
        guard files.contains(where: { $0.pathExtension.lowercased() == "toc" }) else { return nil }
        let prints = files.compactMap { try? Data(contentsOf: $0) }.map(file).sorted()
        return murmur2(Data(prints.map(String.init).joined().utf8))
    }

    /// The files that make up an addon folder, as CurseForge counts them.
    static func includedFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let name = folder.lastPathComponent
        let entries = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var found: [URL] = []
        var seen = Set<String>()
        /// Adds a file once (names compared case-insensitively); false if it was already there.
        func add(_ url: URL) -> Bool {
            guard seen.insert(url.standardizedFileURL.path.lowercased()).inserted else { return false }
            found.append(url)
            return true
        }
        for e in entries where e.lowercased() == "bindings.xml" { _ = add(folder.appendingPathComponent(e)) }
        let tocName = try! NSRegularExpression(pattern: "^\(NSRegularExpression.escapedPattern(for: name))([-_][^/.]+)?\\.toc$",
                                               options: .caseInsensitive)
        func include(_ url: URL) {
            guard let real = resolve(url), add(real) else { return }
            let text = String(decoding: (try? Data(contentsOf: real)) ?? Data(), as: UTF8.self)
            let dir = real.deletingLastPathComponent()
            for path in inclusions(in: text, ext: real.pathExtension.lowercased()) {
                include(dir.appendingPathComponent(path.replacingOccurrences(of: "\\", with: "/")))
            }
        }
        for e in entries.sorted() where tocName.firstMatch(in: e, range: NSRange(e.startIndex..., in: e)) != nil {
            include(folder.appendingPathComponent(e))
        }
        return found
    }

    private static let tocComment = try! NSRegularExpression(pattern: "\\s*#.*$", options: .anchorsMatchLines)
    private static let tocFile = try! NSRegularExpression(pattern: "^\\s*((?:(?<!\\.\\.).)+\\.(?:xml|lua))\\s*$",
                                                          options: [.anchorsMatchLines, .caseInsensitive])
    private static let xmlComment = try! NSRegularExpression(pattern: "<!--.*?-->", options: .dotMatchesLineSeparators)
    private static let xmlFile = try! NSRegularExpression(pattern: "<(?:Include|Script)\\s+file=[\"']((?:(?<!\\.\\.).)+)[\"']\\s*/>",
                                                          options: .caseInsensitive)

    /// Files a `.toc` lists, or an `.xml` includes. Paths with ".." are ignored.
    static func inclusions(in text: String, ext: String) -> [String] {
        let (comment, file): (NSRegularExpression, NSRegularExpression)
        switch ext {
        case "toc": (comment, file) = (tocComment, tocFile)
        case "xml": (comment, file) = (xmlComment, xmlFile)
        default: return []
        }
        let stripped = comment.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return file.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)).compactMap {
            Range($0.range(at: 1), in: stripped).map { String(stripped[$0]) }
        }
    }

    /// The file on disk, matching names case-insensitively like WoW does.
    private static func resolve(_ url: URL) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) { return isDir.boolValue ? nil : url }
        let dir = url.deletingLastPathComponent()
        guard dir.path != url.path, let parent = resolveDir(dir),
              let hit = (try? fm.contentsOfDirectory(atPath: parent.path))?.first(where: { $0.lowercased() == url.lastPathComponent.lowercased() })
        else { return nil }
        let real = parent.appendingPathComponent(hit)
        return fm.fileExists(atPath: real.path, isDirectory: &isDir) && !isDir.boolValue ? real : nil
    }

    private static func resolveDir(_ url: URL) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) { return isDir.boolValue ? url : nil }
        let parentURL = url.deletingLastPathComponent()
        guard parentURL.path != url.path, let parent = resolveDir(parentURL),
              let hit = (try? fm.contentsOfDirectory(atPath: parent.path))?.first(where: { $0.lowercased() == url.lastPathComponent.lowercased() })
        else { return nil }
        return parent.appendingPathComponent(hit)
    }
}

/// What an addon says about itself in its `.toc` header.
struct TocInfo: Equatable {
    var title: String?
    var version: String?
    var author: String?
    var notes: String?
    var curseProjectId: Int?
    var dependencies: [String] = []

    /// Reads `<Folder>.toc`, or failing that any of the folder's flavor `.toc` files.
    static func read(folder: URL) -> TocInfo? {
        let name = folder.lastPathComponent
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".toc") && $0.lowercased().hasPrefix(name.lowercased()) }
            .sorted { ($0.lowercased() == name.lowercased() + ".toc" ? 0 : 1, $0) < ($1.lowercased() == name.lowercased() + ".toc" ? 0 : 1, $1) }
        guard let first = entries.first,
              let data = try? Data(contentsOf: folder.appendingPathComponent(first)) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> TocInfo {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("##"), let colon = l.firstIndex(of: ":") else { continue }
            let key = l[l.index(l.startIndex, offsetBy: 2)..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil, !value.isEmpty { fields[key] = value }
        }
        var info = TocInfo()
        info.title = fields["title"].map(stripColors)
        info.version = fields["version"]
        info.author = fields["author"]
        info.notes = fields["notes"].map(stripColors)
        info.curseProjectId = fields["x-curse-project-id"].flatMap { Int($0) }
        info.dependencies = [fields["dependencies"], fields["requireddeps"], fields["dep"]]
            .compactMap { $0 }
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return info
    }

    /// Removes WoW's inline colour codes (|cffRRGGBB … |r) from titles.
    static func stripColors(_ s: String) -> String {
        s.replacingOccurrences(of: "\\|c[0-9A-Fa-f]{8}|\\|r", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// An addon folder Reforge doesn't track.
struct LocalFolder: Equatable {
    var name: String
    var toc: TocInfo
    var fingerprint: UInt32
}

enum LocalScanner {
    /// Every addon folder (one with a `.toc`) in `addonsDir` except those in `skipping`.
    static func scan(addonsDir: URL, skipping: Set<String>) -> [LocalFolder] {
        let fm = FileManager.default
        let skip = Set(skipping.map { $0.lowercased() })
        let names = ((try? fm.contentsOfDirectory(atPath: addonsDir.path)) ?? []).sorted()
        return names.compactMap { name in
            guard !name.hasPrefix("."), !skip.contains(name.lowercased()) else { return nil }
            let folder = addonsDir.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue,
                  let toc = TocInfo.read(folder: folder),
                  let print = Fingerprint.folder(folder) else { return nil }
            return LocalFolder(name: name, toc: toc, fingerprint: print)
        }
    }
}

/// An addon in the AddOns folder that Reforge doesn't track: identified on CurseForge (so it
/// can be tracked and updated), or local (homemade, WoWInterface, Wago, GitHub…).
struct FoundAddon: Identifiable {
    /// The main folder first, then any helper folders that belong to it.
    var folders: [String]
    var title: String
    var version: String?
    var author: String?
    var notes: String?
    /// The CurseForge project, when identified.
    var projectId: Int?
    var websiteURL: String?
    /// The exact CurseForge file that's installed, when the folder fingerprints matched one.
    var file: CFFile?

    var id: String { folders[0] }
    var isLocal: Bool { projectId == nil }
}

enum Discovery {
    /// Groups untracked folders into addons. Fingerprint matches win (they name the exact file
    /// and all its folders), then `X-Curse-Project-ID` from the `.toc` (if CurseForge knows that
    /// project), and everything else is local, with helper folders such as `Foo_Options` or
    /// `Foo-Core` grouped under `Foo` when it's there.
    static func group(_ folders: [LocalFolder], matches: [CFFingerprintMatch], mods: [Int: CFMod]) -> [FoundAddon] {
        var remaining = folders
        var identified: [FoundAddon] = []
        var seenProjects = Set<Int>()

        for match in matches where !seenProjects.contains(match.id) {
            let prints = Set((match.file.modules ?? []).compactMap(\.fingerprint))
            let mine = remaining.filter { prints.contains(Int($0.fingerprint)) }
            guard !mine.isEmpty else { continue }
            seenProjects.insert(match.id)
            remaining.removeAll { f in mine.contains { $0.name == f.name } }
            let moduleOrder = (match.file.modules ?? []).map(\.name)
            let ordered = mine.sorted { (moduleOrder.firstIndex(of: $0.name) ?? .max, $0.name) < (moduleOrder.firstIndex(of: $1.name) ?? .max, $1.name) }
            let mod = mods[match.id]
            identified.append(FoundAddon(folders: ordered.map(\.name),
                                         title: mod?.name ?? ordered[0].toc.title ?? ordered[0].name,
                                         version: match.file.displayName, author: ordered[0].toc.author,
                                         notes: ordered[0].toc.notes, projectId: match.id,
                                         websiteURL: mod?.links?.websiteUrl, file: match.file))
        }

        let byProject = Dictionary(grouping: remaining.filter { $0.toc.curseProjectId.map { mods[$0] != nil } ?? false },
                                   by: { $0.toc.curseProjectId! })
        for (pid, group) in byProject.sorted(by: { $0.key < $1.key }) where !seenProjects.contains(pid) {
            let ordered = mainFirst(group)
            remaining.removeAll { f in group.contains { $0.name == f.name } }
            let mod = mods[pid]!
            identified.append(FoundAddon(folders: ordered.map(\.name), title: mod.name,
                                         version: ordered[0].toc.version, author: ordered[0].toc.author,
                                         notes: ordered[0].toc.notes, projectId: pid,
                                         websiteURL: mod.links?.websiteUrl, file: nil))
        }

        // Local: attach helpers to the longest folder name they extend ("Foo_Options", "Foo-Core"
        // -> "Foo"). Only the name's own prefixes before a "_" or "-" can be owners, so look those up.
        let byLower = Dictionary(remaining.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
        var parent: [String: String] = [:]
        for f in remaining {
            let lower = f.name.lowercased()
            var owner: String?
            for i in lower.indices where lower[i] == "_" || lower[i] == "-" {
                if let o = byLower[String(lower[..<i])] { owner = o }   // later separators give longer owners
            }
            if let owner { parent[f.name] = owner }
        }
        func root(_ name: String) -> String { parent[name].map(root) ?? name }
        let localGroups = Dictionary(grouping: remaining, by: { root($0.name) })
        let local = localGroups.map { rootName, group -> FoundAddon in
            let main = group.first { $0.name == rootName }!
            return FoundAddon(folders: [rootName] + group.map(\.name).filter { $0 != rootName }.sorted(),
                              title: main.toc.title ?? rootName, version: main.toc.version,
                              author: main.toc.author, notes: main.toc.notes)
        }

        let byTitle: (FoundAddon, FoundAddon) -> Bool = { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return identified.sorted(by: byTitle) + local.sorted(by: byTitle)
    }

    /// The folder others extend (Foo before Foo_Options), else alphabetical.
    private static func mainFirst(_ group: [LocalFolder]) -> [LocalFolder] {
        group.sorted { a, b in
            let aMain = group.contains { $0.name != a.name && $0.name.lowercased().hasPrefix(a.name.lowercased()) }
            let bMain = group.contains { $0.name != b.name && $0.name.lowercased().hasPrefix(b.name.lowercased()) }
            return aMain != bMain ? aMain : a.name < b.name
        }
    }
}
