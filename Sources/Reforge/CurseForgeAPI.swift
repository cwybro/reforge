import Foundation

// Minimal client for the official CurseForge API (https://docs.curseforge.com).
// Requires a free API key from https://console.curseforge.com.

struct CFFile: Decodable {
    struct Module: Decodable { let name: String }
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
    let id: Int
    let name: String
    let slug: String
    let links: Links?
    let latestFilesIndexes: [FileIndex]

    func latestFileId(gameVersionTypeId: Int, allowPrerelease: Bool) -> Int? {
        latestFilesIndexes
            .filter { $0.gameVersionTypeId == gameVersionTypeId && (allowPrerelease || $0.releaseType == 1) }
            .map(\.fileId)
            .max()
    }
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

struct CurseForgeAPI {
    let apiKey: String
    private let base = URL(string: "https://api.curseforge.com")!
    private struct Wrap<T: Decodable>: Decodable { let data: T }

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
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
        return try Store.decoder.decode(Wrap<T>.self, from: data).data
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
}
