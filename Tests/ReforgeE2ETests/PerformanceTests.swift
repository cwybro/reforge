import AppKit
import ApplicationServices
import Darwin
import Foundation
import QuartzCore
import Testing

// `make perf`: launches the dev build in stub mode with REFORGE_PERF_DIR set and measures how it
// feels: launch time, idle CPU and memory, how fast screens appear, and missed frames while
// scrolling and animating. Not part of `make test` / `make e2e`: timings vary between runs and
// machines, so budgets are loose regression guards, and every number is printed as a PERF line.
//
// The app measures itself (Sources/Reforge/PerfProbe.swift): it stamps when a screen reached the
// display and every display refresh while a segment is recorded, on the same clock as this
// process. So the test doesn't poll the Accessibility tree while timing, which would keep the
// app's main thread busy and skew the numbers.
//
// Windows stay visible during these runs (never focused), since SwiftUI may skip drawing an
// invisible one. Needs Accessibility permission and an unlocked screen, like `make e2e`.

/// Prints a result and checks it against its budget.
func perfRecord(_ name: String, _ value: Double, unit: String, budget: Double,
                sourceLocation: SourceLocation = #_sourceLocation) {
    let ok = value <= budget
    print(String(format: "PERF|%@|%.1f|%@|%.0f|%@", name, value, unit, budget, ok ? "ok" : "OVER"))
    #expect(ok, "\(name): \(String(format: "%.1f", value)) \(unit), budget \(budget) \(unit)", sourceLocation: sourceLocation)
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2]
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

/// One app launch with the probe on.
final class PerfSession {
    let fixture: E2EFixture
    let app: AXApp
    let dir: URL
    let launchedAt: CFTimeInterval

    init(_ start: E2EFixture.Start, edit: (inout [String: Any]) -> Void = { _ in }) async throws {
        fixture = try E2EFixture(start, edit: edit)
        dir = fixture.dir.appendingPathComponent("perf", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        launchedAt = CACurrentMediaTime()
        app = try await AXApp.launch(fixture: fixture.fixtureFile, environment: ["REFORGE_PERF_DIR": dir.path])
    }

    deinit { app.terminate() }

    /// Sends a command to the app's probe.
    func post(_ command: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("local.reforge.perf"), object: command, userInfo: nil, deliverImmediately: true)
    }

    /// Waits (reading files only) for the first `name` mark whose event happened after `after`,
    /// and returns the display-refresh time it resolved to.
    func mark(_ name: String, after: CFTimeInterval, timeout: Double = 10) async throws -> CFTimeInterval {
        let deadline = CACurrentMediaTime() + timeout
        let url = dir.appendingPathComponent("marks.jsonl")
        while CACurrentMediaTime() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          o["name"] as? String == name, let event = o["event"] as? Double, event >= after,
                          let frame = o["frame"] as? Double else { continue }
                    return frame
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw E2EError("No \(name) mark within \(timeout)s")
    }

    /// Records display refreshes while `body` runs; returns the frame intervals in ms and the nominal one.
    func frames(_ name: String, _ body: () async throws -> Void) async throws -> (intervals: [Double], nominal: Double) {
        let url = dir.appendingPathComponent("frames-\(name).json")
        try? FileManager.default.removeItem(at: url)
        post("begin:\(name)")
        try await Task.sleep(for: .milliseconds(50))   // let the notification arrive before the work
        try await body()
        post("end:\(name)")
        let deadline = CACurrentMediaTime() + 5
        while CACurrentMediaTime() < deadline {
            if let data = try? Data(contentsOf: url),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let intervals = o["intervalsMs"] as? [Double], let nominal = o["nominalMs"] as? Double {
                return (intervals, nominal)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw E2EError("No frame log for \(name)")
    }

    /// The app's CPU use (% of one core) and memory footprint (MB) over `seconds`.
    func idleCost(seconds: Double) async throws -> (cpu: Double, footprintMB: Double) {
        let before = usage()
        let t0 = CACurrentMediaTime()
        try await Task.sleep(for: .seconds(seconds))
        let after = usage()
        let elapsed = CACurrentMediaTime() - t0
        return (Double(after.cpuNs - before.cpuNs) / 1e9 / elapsed * 100, Double(after.footprint) / 1_048_576)
    }

    private func usage() -> (cpuNs: UInt64, footprint: UInt64) {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(app.running.processIdentifier, RUSAGE_INFO_V4, $0) }
        }
        guard r == 0 else { return (0, 0) }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticks = info.ri_user_time + info.ri_system_time
        return (ticks * UInt64(tb.numer) / UInt64(tb.denom), info.ri_phys_footprint)
    }
}

/// Frame-interval stats against budgets: the slowest frame, the 95th percentile (as a multiple of
/// the display's refresh interval), and how many frames ran more than twice as long as they should.
func checkFrames(_ name: String, _ f: (intervals: [Double], nominal: Double), maxMs: Double, p95Frames: Double,
                 droppedPercent: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    let slow = f.intervals.filter { $0 > 2 * f.nominal }.count
    let dropped = f.intervals.isEmpty ? 0 : Double(slow) / Double(f.intervals.count) * 100
    print(String(format: "PERF|%@ frames|%d|frames|0|info (%.1f ms refresh)", name, f.intervals.count, f.nominal))
    perfRecord("\(name) slowest frame", f.intervals.max() ?? 0, unit: "ms", budget: maxMs, sourceLocation: sourceLocation)
    perfRecord("\(name) p95 frame", percentile(f.intervals, 0.95) / f.nominal, unit: "x refresh", budget: p95Frames,
               sourceLocation: sourceLocation)
    perfRecord("\(name) dropped", dropped, unit: "% frames", budget: droppedPercent, sourceLocation: sourceLocation)
}

@Suite("Performance", .serialized, .enabled(if: ProcessInfo.processInfo.environment["REFORGE_PERF"] == "1"))
struct PerformanceTests {
    static let many = 300

    @Test func launchToList() async throws {
        var times: [Double] = []
        for _ in 0..<3 {
            let s = try await PerfSession(.many(Self.many))
            let shown = try await s.mark("main.list", after: s.launchedAt)
            times.append((shown - s.launchedAt) * 1000)
        }
        perfRecord("launch to list (\(Self.many) addons, median of 3)", median(times), unit: "ms", budget: 2500)
    }

    @Test func idleMainWindow() async throws {
        let s = try await PerfSession(.many(Self.many))
        try await s.app.waitForText("status.message", containing: "\(Self.many) updates available")
        try await Task.sleep(for: .seconds(1))   // let the first check's work finish
        let cost = try await s.idleCost(seconds: 3)
        perfRecord("idle CPU, main window", cost.cpu, unit: "% core", budget: 2)
        perfRecord("memory, main window (\(Self.many) addons)", cost.footprintMB, unit: "MB", budget: 300)
    }

    @Test func idleWelcomeScreen() async throws {
        let s = try await PerfSession(.fresh)
        try await s.app.element("onboarding.getStarted")
        try await Task.sleep(for: .seconds(1))
        let frames = try await s.frames("welcome idle") {
            let cost = try await s.idleCost(seconds: 3)
            perfRecord("idle CPU, welcome screen (sparkles)", cost.cpu, unit: "% core", budget: 8)
        }
        checkFrames("welcome idle", frames, maxMs: 50, p95Frames: 1.5, droppedPercent: 2)
    }

    @Test func scrollLongList() async throws {
        let s = try await PerfSession(.many(Self.many))
        try await s.app.waitForText("status.message", containing: "updates available")
        let list = try await s.app.element("main.list")
        let bar = try #require(list.children(kAXChildrenAttribute).first {
            $0.string(kAXRoleAttribute) == kAXScrollBarRole && $0.string(kAXOrientationAttribute) == kAXVerticalOrientationValue
        }, "main.list has no vertical scroll bar")
        try await Task.sleep(for: .milliseconds(500))
        // Down and back up in 240 steps, one every ~8 ms (about two seconds).
        let frames = try await s.frames("scroll") {
            let steps = 240, clock = ContinuousClock(), start = clock.now
            for i in 0...steps {
                let x = Double(i) / Double(steps) * 2
                AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: x <= 1 ? x : 2 - x))
                try await Task.sleep(until: start + .milliseconds(8 * (i + 1)), clock: clock)
            }
        }
        // Baseline (M-series, 120 Hz): p95 ~2.9x refresh, ~14% of frames over 2x. Budgets leave headroom.
        checkFrames("scroll \(Self.many) rows", frames, maxMs: 100, p95Frames: 4, droppedPercent: 25)
    }

    @Test func addSheetAndSearch() async throws {
        let s = try await PerfSession(.many(Self.many))
        try await s.app.waitForText("status.message", containing: "updates available")
        try await Task.sleep(for: .milliseconds(500))

        var opens: [Double] = []
        for _ in 0..<5 {
            let t0 = CACurrentMediaTime()
            try await s.app.press("header.add")
            opens.append((try await s.mark("addSheet", after: t0) - t0) * 1000)
            try await s.app.press("addSheet.cancel")
            try await s.app.waitGone("addSheet.field")
        }
        // Click to the sheet's first frame. macOS then slides it in for about 300 ms more.
        // Baseline ~45 ms, whether the list behind it has 2 rows or 300.
        perfRecord("open Add sheet, click to first frame (median of 5)", median(opens), unit: "ms", budget: 150)

        // Frame pacing while it slides in (AppKit's sheet animation, see PerfProbe.animationMode).
        let opening = try await s.frames("sheet open") {
            try await s.app.press("header.add")
            try await Task.sleep(for: .milliseconds(600))
        }
        checkFrames("sheet open", opening, maxMs: 120, p95Frames: 3, droppedPercent: 20)
        try await s.app.press("addSheet.cancel")
        try await s.app.waitGone("addSheet.field")

        try await s.app.press("header.add")
        try await s.app.element("addSheet.field")
        var searches: [Double] = []
        let frames = try await s.frames("search") {
            // Each query gives a different, non-empty result list (names are "Addon 0001"…"Addon 0300").
            for q in ["Addon 01", "Addon 02", "Addon 00", "Addon 015", "Addon 029"] {
                let t0 = CACurrentMediaTime()
                try await s.app.setValue("addSheet.field", q)
                searches.append((try await s.mark("search.results", after: t0) - t0) * 1000)
            }
        }
        // Includes the sheet's deliberate 300 ms pause after typing.
        perfRecord("type to search results (median of 5, incl. 300 ms debounce)", median(searches), unit: "ms", budget: 900)
        checkFrames("search", frames, maxMs: 120, p95Frames: 3, droppedPercent: 15)
    }

    @Test func updateAllMany() async throws {
        let s = try await PerfSession(.many(Self.many))
        try await s.app.waitForText("header.updateAll", containing: "Update All (\(Self.many))")
        try await Task.sleep(for: .milliseconds(500))
        var elapsed = 0.0
        let frames = try await s.frames("update all") {
            let t0 = CACurrentMediaTime()
            try await s.app.press("header.updateAll")
            elapsed = (try await s.mark("updateAll.done", after: t0, timeout: 60) - t0) * 1000
        }
        perfRecord("Update All, \(Self.many) addons (stubbed installs)", elapsed, unit: "ms", budget: 10_000)
        // Baseline: p95 ~3x refresh, ~28% of frames over 2x while 300 rows change state.
        checkFrames("update all", frames, maxMs: 250, p95Frames: 5, droppedPercent: 45)
    }
}
