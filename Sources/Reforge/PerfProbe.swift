import AppKit
import QuartzCore

/// Timing hooks for `make perf` (Tests/ReforgeE2ETests/PerformanceTests.swift). Off unless the
/// app runs in E2E stub mode with REFORGE_PERF_DIR set; then every call here is cheap and
/// everything else is untouched.
///
/// - Marks: `PerfProbe.mark("addSheet")` records when something appeared, resolved to the next
///   display refresh after it (roughly when it reached the screen). Lines go to marks.jsonl.
/// - Frames: the test posts "begin:<name>" / "end:<name>" as a distributed notification; between
///   the two, the time of every display-link callback on the main thread is recorded, and
///   frames-<name>.json gets the intervals. A long interval means the main thread was busy and a
///   frame was missed (a hitch).
///
/// All times are CACurrentMediaTime (mach absolute time), which is the same clock in every
/// process, so the test can subtract its own timestamps from the app's.
@MainActor
final class PerfProbe: NSObject {
    static let notification = Notification.Name("local.reforge.perf")

    /// Created on first use (the first mark can come before applicationDidFinishLaunching).
    private static var shared: PerfProbe? = {
        guard E2E.isActive, let path = ProcessInfo.processInfo.environment["REFORGE_PERF_DIR"], !path.isEmpty else { return nil }
        let probe = PerfProbe(dir: URL(fileURLWithPath: path, isDirectory: true))
        DistributedNotificationCenter.default().addObserver(probe, selector: #selector(command(_:)),
                                                            name: notification, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        probe.startLink()
        return probe
    }()

    /// AppKit runs sheet (and window-move) animations with the main run loop in this private mode,
    /// which isn't one of the `.common` modes. Without it the display link pauses for the whole
    /// ~300 ms sheet animation, so marks resolve late and the animation's frames go unrecorded.
    private static let animationMode = RunLoop.Mode("_NSMoveTimerRunLoopMode")

    private let dir: URL
    private lazy var marks: FileHandle? = {
        let url = dir.appendingPathComponent("marks.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()
    private var link: CADisplayLink?
    private var pending: [(name: String, at: CFTimeInterval)] = []
    private var recording: (name: String, ticks: [CFTimeInterval])?

    private init(dir: URL) { self.dir = dir }

    /// Starts the probe when REFORGE_PERF_DIR is set (stub mode only), if a mark hasn't already.
    static func startIfRequested() { _ = shared }

    /// Records that `name` appeared; resolved at the next display refresh.
    static func mark(_ name: String) {
        guard let probe = shared else { return }
        probe.pending.append((name, CACurrentMediaTime()))
    }

    private func startLink() {
        guard link == nil, let screen = NSScreen.main ?? NSScreen.screens.first else {
            // No screen yet: try again shortly so pending marks still resolve.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.startLink() }
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        link.add(to: .main, forMode: Self.animationMode)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if !pending.isEmpty {
            for p in pending {
                guard var line = try? JSONSerialization.data(withJSONObject: ["name": p.name, "event": p.at, "frame": now]) else { continue }
                line.append(0x0A)
                try? marks?.write(contentsOf: line)
            }
            pending.removeAll()
        }
        recording?.ticks.append(now)
    }

    @objc private func command(_ note: Notification) {
        guard let cmd = note.object as? String else { return }
        if cmd.hasPrefix("begin:") {
            recording = (String(cmd.dropFirst(6)), [CACurrentMediaTime()])
        } else if cmd.hasPrefix("end:"), let rec = recording {
            recording = nil
            let ticks = rec.ticks + [CACurrentMediaTime()]
            let intervals = zip(ticks.dropFirst(), ticks).map { ($0 - $1) * 1000 }
            let nominal = (link.map { $0.targetTimestamp - $0.timestamp } ?? (1.0 / 60)) * 1000
            write(["intervalsMs": intervals, "nominalMs": nominal], file: "frames-\(rec.name).json")
        }
    }

    private func write(_ object: [String: Any], file: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: dir.appendingPathComponent(file), options: .atomic)
    }
}
