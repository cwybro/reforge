import Foundation

// Minimal client for the official CurseForge API (https://docs.curseforge.com).
// Requires a free API key from https://console.curseforge.com.

struct CFFile: Decodable {
    struct Module: Decodable {
        let name: String
        /// CurseForge's fingerprint of this folder (see Fingerprint.folder).
        var fingerprint: Int? = nil
    }
    let id: Int
    let modId: Int
    let displayName: String
    let fileName: String
    let fileDate: Date
    let releaseType: Int   // 1 release, 2 beta, 3 alpha
    let downloadUrl: String?
    let modules: [Module]?

    /// Authors can disable third-party download URLs; the CDN path is still predictable.
    var resolvedDownloadURL: URL? {
        if let s = downloadUrl, let u = URL(string: s) { return u }
        guard let name = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://edge.forgecdn.net/files/\(id / 1000)/\(id % 1000)/\(name)")
    }
}

struct CFMod: Decodable {
    struct FileIndex: Decodable {
        let fileId: Int
        let releaseType: Int
        let gameVersionTypeId: Int?
    }
    struct Links: Decodable { let websiteUrl: String? }
    struct Author: Decodable { let name: String }
    struct Logo: Decodable { let thumbnailUrl: String? }
    struct Category: Decodable { let id: Int; let name: String }
    let id: Int
    let name: String
    let slug: String
    let links: Links?
    let latestFilesIndexes: [FileIndex]
    // Shown in search results; optional so lookups and fixtures can leave them out.
    var summary: String? = nil
    var downloadCount: Double? = nil
    var dateModified: Date? = nil
    var authors: [Author]? = nil
    var logo: Logo? = nil
    var categories: [Category]? = nil

    func latestFileId(gameVersionTypeId: Int, allowPrerelease: Bool) -> Int? {
        latestFilesIndexes
            .filter { $0.gameVersionTypeId == gameVersionTypeId && (allowPrerelease || $0.releaseType == 1) }
            .map(\.fileId)
            .max()
    }
}

/// A file CurseForge recognised from an installed folder's fingerprint.
struct CFFingerprintMatch: Decodable {
    /// The project (mod) id.
    let id: Int
    let file: CFFile
}

/// An addon category (Bags & Inventory, Boss Encounters, …).
struct CFCategory: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    var isClass: Bool? = nil
}

/// Orders for /v1/mods/search (CurseForge's ModsSearchSortField).
enum SearchSort: Int, CaseIterable, Identifiable {
    case popularity = 2, lastUpdated = 3, name = 4, totalDownloads = 6
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .popularity: return "Popular"
        case .lastUpdated: return "Recently updated"
        case .name: return "Name"
        case .totalDownloads: return "Most downloaded"
        }
    }
    var ascending: Bool { self == .name }
}

/// One page of an addon search. An empty `text` browses (e.g. the most popular addons).
struct SearchQuery: Equatable {
    var text = ""
    var sort = SearchSort.popularity
    var categoryId: Int?
    var gameVersionTypeId = 517
    var index = 0
    var pageSize = 50
}

enum CFError: LocalizedError {
    case noKey, http(Int, String), notFound(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "No CurseForge API key set."
        case .http(403, _): return "CurseForge rejected the API key (HTTP 403)."
        case .http(let c, let body): return "CurseForge API error \(c): \(body.prefix(200))"
        case .notFound(let s): return "Couldn't find an addon matching “\(s)”."
        }
    }
}

/// The CurseForge calls Model makes; tests substitute a fake.
protocol CurseForgeClient {
    func validateKey() async throws
    func mods(_ ids: [Int]) async throws -> [CFMod]
    func mod(_ id: Int) async throws -> CFMod
    func files(_ ids: [Int]) async throws -> [CFFile]
    func mod(slug: String) async throws -> CFMod?
    /// WoW addons matching the query, plus the total number of matches.
    func search(_ query: SearchQuery) async throws -> (mods: [CFMod], total: Int)
    /// WoW addon categories.
    func categories() async throws -> [CFCategory]
    /// The CurseForge files whose folders have exactly these fingerprints.
    func fingerprintMatches(_ fingerprints: [UInt32]) async throws -> [CFFingerprintMatch]
}

struct CurseForgeAPI: CurseForgeClient {
    let apiKey: String
    private let base = URL(string: "https://api.curseforge.com")!
    private struct Wrap<T: Decodable>: Decodable { let data: T }
    /// The /v1/mods/search response.
    struct SearchPage: Decodable {
        struct Pagination: Decodable { let totalCount: Int }
        let data: [CFMod]
        let pagination: Pagination?
        var total: Int { pagination?.totalCount ?? data.count }
    }

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        try await requestRaw(path, query: query, body: body, as: Wrap<T>.self).data
    }

    private func requestRaw<T: Decodable>(_ path: String, query: [URLQueryItem], body: [String: Any]?, as: T.Type) async throws -> T {
        guard !apiKey.isEmpty else { throw CFError.noKey }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await Store.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CFError.http(code, String(decoding: data, as: UTF8.self)) }
        return try Store.decoder.decode(T.self, from: data)
    }

    /// Cheap authenticated call used to check that a key works.
    func validateKey() async throws {
        struct Game: Decodable { let id: Int }
        let _: Game = try await request("/v1/games/1")
    }

    func mods(_ ids: [Int]) async throws -> [CFMod] {
        try await request("/v1/mods", body: ["modIds": ids, "filterPcOnly": true])
    }

    func mod(_ id: Int) async throws -> CFMod {
        try await request("/v1/mods/\(id)")
    }

    func files(_ ids: [Int]) async throws -> [CFFile] {
        try await request("/v1/mods/files", body: ["fileIds": ids])
    }

    /// Find a WoW addon by its curseforge.com slug.
    func mod(slug: String) async throws -> CFMod? {
        let results: [CFMod] = try await request("/v1/mods/search", query: [
            .init(name: "gameId", value: "1"),
            .init(name: "classId", value: "1"),
            .init(name: "slug", value: slug),
        ])
        return results.first
    }

    func search(_ q: SearchQuery) async throws -> (mods: [CFMod], total: Int) {
        var query: [URLQueryItem] = [
            .init(name: "gameId", value: "1"),
            .init(name: "classId", value: "1"),
            .init(name: "gameVersionTypeId", value: String(q.gameVersionTypeId)),
            .init(name: "sortField", value: String(q.sort.rawValue)),
            .init(name: "sortOrder", value: q.sort.ascending ? "asc" : "desc"),
            .init(name: "index", value: String(q.index)),
            .init(name: "pageSize", value: String(q.pageSize)),
        ]
        let text = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { query.append(.init(name: "searchFilter", value: text)) }
        if let c = q.categoryId { query.append(.init(name: "categoryId", value: String(c))) }
        let page = try await requestRaw("/v1/mods/search", query: query, body: nil, as: SearchPage.self)
        return (page.data, page.total)
    }

    func categories() async throws -> [CFCategory] {
        try await request("/v1/categories", query: [.init(name: "gameId", value: "1"), .init(name: "classId", value: "1")])
    }

    func fingerprintMatches(_ fingerprints: [UInt32]) async throws -> [CFFingerprintMatch] {
        struct Result: Decodable { let exactMatches: [CFFingerprintMatch] }
        let result: Result = try await request("/v1/fingerprints/1", body: ["fingerprints": fingerprints.map(Int.init)])
        return result.exactMatches
    }
}
