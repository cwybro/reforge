import Foundation
import Testing
@testable import Reforge

// `make perf` only (REFORGE_PERF=1): timings of the non-UI work behind the screens, on fixed,
// generated data. Budgets are loose regression guards; every result prints as a PERF line.
// See Tests/ReforgeE2ETests/PerformanceTests.swift for the UI side.

private func record(_ name: String, _ ms: Double, budget: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    let ok = ms <= budget
    print(String(format: "PERF|%@|%.2f|ms|%.0f|%@", name, ms, budget, ok ? "ok" : "OVER"))
    #expect(ok, "\(name): \(ms) ms, budget \(budget) ms", sourceLocation: sourceLocation)
}

/// Median wall time of `runs` runs of `body`, in ms (after one warm-up run).
private func time(runs: Int = 5, _ body: () async throws -> Void) async rethrows -> Double {
    try await body()
    let clock = ContinuousClock()
    var times: [Double] = []
    for _ in 0..<runs {
        let d = try await clock.measure { try await body() }
        times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }
    return times.sorted()[runs / 2]
}

@Suite("Performance (hot paths)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["REFORGE_PERF"] == "1"))
@MainActor
struct PerformanceBenchmarks {
    /// A big addon: a .toc listing 300 Lua files of ~8 KB each.
    func bigAddon(in dir: URL, name: String = "Big", files: Int = 300) throws {
        let lua = String(repeating: "local value = someFunction(arg1, arg2) -- comment\n", count: 160)
        var tree = ["\(name)/\(name).toc": "## Interface: 110000\n" + (0..<files).map { "src\\file\($0).lua" }.joined(separator: "\n")]
        for i in 0..<files { tree["\(name)/src/file\(i).lua"] = lua + "-- \(i)\n" }
        try writeFiles(tree, in: dir)
    }

    @Test func fingerprintABigAddon() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try bigAddon(in: dir)
        let folder = dir.appendingPathComponent("Big")
        let ms = await time { _ = Fingerprint.folder(folder) }
        record("fingerprint one addon (300 files, 2.4 MB)", ms, budget: 250)
    }

    @Test func scanAnAddOnsFolder() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<150 { try bigAddon(in: dir, name: "Addon\(i)", files: 10) }
        let ms = await time(runs: 3) { _ = LocalScanner.scan(addonsDir: dir, skipping: []) }
        record("scan AddOns folder (150 addons x 10 files)", ms, budget: 1500)
    }

    @Test func groupFoundAddons() async {
        var folders: [LocalFolder] = []
        for i in 0..<1000 {
            let name: String = i % 4 == 0 ? "Addon\(i / 4)" : "Addon\(i / 4)_Part\(i % 4)"
            let project: Int? = i % 3 == 0 ? i : nil
            folders.append(LocalFolder(name: name, toc: TocInfo(title: "Addon \(i)", curseProjectId: project),
                                       fingerprint: UInt32(i)))
        }
        let mods = Dictionary(uniqueKeysWithValues: stride(from: 0, to: 1000, by: 6).map { ($0, cfMod($0, "Mod \($0)")) })
        let ms = await time { _ = Discovery.group(folders, matches: [], mods: mods) }
        record("group 1000 found folders", ms, budget: 100)
    }

    @Test func decodeSearchResults() async throws {
        let page = try JSONSerialization.jsonObject(with: Data(SearchDecodingTests.response.utf8)) as! [String: Any]
        let one = (page["data"] as! [[String: Any]])[0]
        let big = try JSONSerialization.data(withJSONObject: ["data": Array(repeating: one, count: 50),
                                                             "pagination": ["totalCount": 10_000]])
        let ms = try await time {
            for _ in 0..<20 { _ = try Store.decoder.decode(CurseForgeAPI.SearchPage.self, from: big) }
        }
        record("decode 20 search pages (50 results each)", ms, budget: 150)
    }

    @Test func checkManyAddonsForUpdates() async throws {
        let addons = (0..<1000).map { tracked(10_000 + $0, String(format: "Addon %04d", $0), fileId: 1) }
        let env = try TestEnv(key: "k", addons: addons)
        for a in addons { env.api.add(cfMod(a.id, a.name, files: [(a.id * 10, 1, retail)]), cfFile(a.id * 10, mod: a.id, "\(a.name) new")) }
        let model = env.makeModel()
        let ms = await time { await model.checkForUpdates() }
        record("check 1000 tracked addons (fake API)", ms, budget: 100)
    }

    @Test func updateAllInTheModel() async throws {
        let ms = try await time(runs: 3) {
            let addons = (0..<300).map { tracked(10_000 + $0, String(format: "Addon %04d", $0), fileId: 1) }
            let env = try TestEnv(key: "k", addons: addons)
            for a in addons { env.api.add(cfMod(a.id, a.name, files: [(a.id * 10, 1, retail)]), cfFile(a.id * 10, mod: a.id, "\(a.name) new")) }
            let model = env.makeModel()
            await model.checkForUpdates()
            await model.updateAll()
        }
        record("Update All, 300 addons (fake installer, incl. setup)", ms, budget: 1000)
    }
}
