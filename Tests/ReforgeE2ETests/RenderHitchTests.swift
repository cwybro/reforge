import ApplicationServices
import Foundation
import QuartzCore
import Testing

// `make perf-trace`: records each scenario with Instruments' "Animation Hitches" template
// (xctrace, needs Xcode) attached to the stub-mode app, then reads the hitches Instruments found.
// Unlike `make perf`'s in-app probe, this sees the whole pipeline: the app's commits, the render
// server and the display, so a hitch here is a frame that really reached the screen late.
//
// Reported per scenario: hitch count, hitch time ratio (ms of hitching per second; Apple calls
// under 5 good, 5-10 a warning, over 10 critical), the longest hitch, and main-thread hangs.
// Each .trace is kept in build/perf/traces/ to open in Instruments. Slow (Instruments processes
// every recording), so it's separate from `make perf`.

/// A table exported from a .trace: one dictionary per row, column mnemonic -> (fmt, raw text).
struct TraceTable {
    var rows: [[String: (fmt: String, text: String)]] = []

    /// Reads `schema` from the first run of `trace` with `xctrace export`.
    static func read(_ trace: URL, schema: String) async throws -> TraceTable {
        let run = try XcrunRun(["xctrace", "export", "--input", trace.path,
                                "--xpath", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"\(schema)\"]"])
        guard try await run.finish(within: .seconds(120)) == 0 else {
            throw E2EError("xctrace export of \(schema) failed: \(run.outputText)")
        }
        let data = run.output
        let parser = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw E2EError("Couldn't read \(schema) from \(trace.lastPathComponent)") }
        return TraceTable(rows: parser.rows)
    }

    /// xctrace's XML lists the columns once, then writes each value in full the first time
    /// (with an id) and as <x ref="id"/> after that.
    private final class Parser: NSObject, XMLParserDelegate {
        var columns: [String] = []
        var rows: [[String: (fmt: String, text: String)]] = []
        private var byId: [String: (fmt: String, text: String)] = [:]
        private var inMnemonic = false, mnemonic = ""
        private var row: [(fmt: String, text: String)]?
        /// The row's current top-level value: its id, fmt, collected text, and nesting depth.
        private var cell: (id: String?, fmt: String, text: String, depth: Int)?

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String]) {
            if name == "mnemonic" { inMnemonic = true; mnemonic = ""; return }
            if name == "row" { row = []; return }
            guard row != nil else { return }
            // Inside a value: just track nesting (its text still accrues to the value).
            if var c = cell { c.depth += 1; cell = c; return }
            // A repeated value (<x ref="7"/>) or an empty cell (<sentinel/>): complete as it opens.
            if let ref = a["ref"] { row!.append(byId[ref] ?? ("", "")); skipEnd = true; return }
            if name == "sentinel" { row!.append(("", "")); skipEnd = true; return }
            cell = (a["id"], a["fmt"] ?? "", "", 0)
        }

        /// The next end tag belongs to a value already recorded when it opened.
        private var skipEnd = false

        func parser(_ p: XMLParser, foundCharacters s: String) {
            if inMnemonic { mnemonic += s }
            if cell != nil { cell!.text += s }
        }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "mnemonic" { inMnemonic = false; columns.append(mnemonic); return }
            if name == "row", let r = row {
                var dict: [String: (fmt: String, text: String)] = [:]
                for (i, v) in r.enumerated() where i < columns.count { dict[columns[i]] = v }
                rows.append(dict)
                row = nil
                return
            }
            if skipEnd { skipEnd = false; return }
            guard var c = cell else { return }
            if c.depth > 0 { c.depth -= 1; cell = c; return }
            let value = (c.fmt, c.text)
            if let id = c.id { byId[id] = value }
            row?.append(value)
            cell = nil
        }
    }
}

/// One `xcrun` invocation. Waits with a termination handler set before launch rather than
/// `waitUntilExit()`, which can miss the exit when called off the main thread and hang forever,
/// and writes its output to a file so a full pipe can't block it.
final class XcrunRun: @unchecked Sendable {
    private let process = Process()
    private let outputFile: URL
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    init(_ arguments: [String]) throws {
        outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("reforge-xctrace-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputFile)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [weak self] p in
            try? handle.close()
            guard let self else { return }
            let w: CheckedContinuation<Int32, Never>? = self.lock.withLock {
                self.status = p.terminationStatus
                defer { self.waiter = nil }
                return self.waiter
            }
            w?.resume(returning: p.terminationStatus)
        }
        try process.run()
    }

    deinit { try? FileManager.default.removeItem(at: outputFile) }

    var output: Data { (try? Data(contentsOf: outputFile)) ?? Data() }
    var outputText: String { String(decoding: output, as: UTF8.self) }

    /// The exit status. Terminates xctrace if it runs past `limit`.
    func finish(within limit: Duration) async throws -> Int32 {
        let process = self.process
        let watchdog = Task {
            try await Task.sleep(for: limit)
            process.terminate()
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { c in
            let done: Int32? = lock.withLock {
                if let status { return status }
                waiter = c
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }
}

/// One Instruments recording of the app.
struct HitchRecording {
    let trace: URL
    let seconds: Double

    /// Records `template` attached to `pid` while `body` runs, for `seconds` in total.
    static func record(_ name: String, pid: pid_t, seconds: Int, template: String = "Animation Hitches",
                       _ body: () async throws -> Void) async throws -> HitchRecording {
        let dir = reforgeAppURL.deletingLastPathComponent().appendingPathComponent("perf/traces", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let trace = dir.appendingPathComponent("\(name).trace")
        try? FileManager.default.removeItem(at: trace)
        let run = try XcrunRun(["xctrace", "record", "--template", template, "--attach", String(pid),
                                "--time-limit", "\(seconds)s", "--output", trace.path, "--no-prompt"])
        // Recording starts a moment after xctrace says so; give it time before the scenario.
        try await Task.sleep(for: .seconds(2))
        try await body()
        // Instruments processes the recording after the time limit, which can take a while.
        let status = try await run.finish(within: .seconds(Double(seconds) + 180))
        guard status == 0, FileManager.default.fileExists(atPath: trace.path) else {
            throw E2EError("xctrace failed (\(status)): \(run.outputText)")
        }
        return HitchRecording(trace: trace, seconds: Double(seconds))
    }

    /// Checks the app's hitches and hangs against budgets and prints them as PERF lines.
    func check(_ label: String, pid: pid_t, ratioBudget: Double, longestBudgetMs: Double,
               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let mine = "(\(pid))"
        let hitches = try await TraceTable.read(trace, schema: "hitches").rows.filter { $0["process"]?.fmt.hasSuffix(mine) == true }
        let durations = hitches.compactMap { Double($0["duration"]?.text ?? "") }.map { $0 / 1e6 }
        let hangs = try await TraceTable.read(trace, schema: "potential-hangs").rows.filter { $0["process"]?.fmt.hasSuffix(mine) == true }
        let ratio = durations.reduce(0, +) / seconds
        print(String(format: "PERF|%@ hitches|%d|count|0|info (%@)", label, durations.count, trace.lastPathComponent))
        perfRecord("\(label) hitch time ratio", ratio, unit: "ms/s", budget: ratioBudget, sourceLocation: sourceLocation)
        perfRecord("\(label) longest hitch", durations.max() ?? 0, unit: "ms", budget: longestBudgetMs, sourceLocation: sourceLocation)
        perfRecord("\(label) hangs", Double(hangs.count), unit: "count", budget: 0, sourceLocation: sourceLocation)
    }
}

@Suite("Render hitches (Instruments)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["REFORGE_PERF_TRACE"] == "1"))
struct RenderHitchTests {
    @Test func scrollLongList() async throws {
        let s = try await PerfSession(.many(PerformanceTests.many))
        try await s.app.waitForText("status.message", containing: "updates available")
        let list = try await s.app.element("main.list")
        let bar = try #require(list.children(kAXChildrenAttribute).first {
            $0.string(kAXRoleAttribute) == kAXScrollBarRole && $0.string(kAXOrientationAttribute) == kAXVerticalOrientationValue
        })
        let pid = s.app.running.processIdentifier
        var furthest = 0.0
        let rec = try await HitchRecording.record("scroll", pid: pid, seconds: 5) {
            let steps = 240, clock = ContinuousClock(), start = clock.now
            for i in 0...steps {
                let x = Double(i) / Double(steps) * 2
                AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: x <= 1 ? x : 2 - x))
                furthest = max(furthest, (bar.attribute(kAXValueAttribute) as? NSNumber)?.doubleValue ?? 0)
                try await Task.sleep(until: start + .milliseconds(8 * (i + 1)), clock: clock)
            }
        }
        // No hitches only counts if the list really scrolled.
        #expect(furthest > 0.9, "the list only scrolled to \(furthest)")
        try await rec.check("scroll \(PerformanceTests.many) rows", pid: pid, ratioBudget: 40, longestBudgetMs: 100)
    }

    /// Opening the sheet costs one 50-60 ms frame (its first layout), so allow about one per open.
    @Test func openAddSheet() async throws {
        let s = try await PerfSession(.many(PerformanceTests.many))
        try await s.app.waitForText("status.message", containing: "updates available")
        let pid = s.app.running.processIdentifier
        let rec = try await HitchRecording.record("add-sheet", pid: pid, seconds: 5) {
            for _ in 0..<3 {
                try await s.app.press("header.add")
                try await s.app.element("addSheet.field")
                try await Task.sleep(for: .milliseconds(500))
                try await s.app.press("addSheet.cancel")
                try await Task.sleep(for: .milliseconds(400))
            }
        }
        try await rec.check("open/close Add sheet x3", pid: pid, ratioBudget: 40, longestBudgetMs: 100)
    }

    @Test func updateAll() async throws {
        let s = try await PerfSession(.many(PerformanceTests.many))
        try await s.app.waitForText("header.updateAll", containing: "Update All (\(PerformanceTests.many))")
        let pid = s.app.running.processIdentifier
        let rec = try await HitchRecording.record("update-all", pid: pid, seconds: 5) {
            try await s.app.press("header.updateAll")
            try await s.app.waitFor("all \(PerformanceTests.many) updates installed") {
                s.fixture.installs.count == PerformanceTests.many
            }
        }
        try await rec.check("Update All \(PerformanceTests.many)", pid: pid, ratioBudget: 60, longestBudgetMs: 250)
    }

    @Test func welcomeIdle() async throws {
        let s = try await PerfSession(.fresh)
        try await s.app.element("onboarding.getStarted")
        let pid = s.app.running.processIdentifier
        let rec = try await HitchRecording.record("welcome-idle", pid: pid, seconds: 4) {}
        try await rec.check("welcome screen idle", pid: pid, ratioBudget: 5, longestBudgetMs: 50)
    }
}
