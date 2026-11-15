import Foundation
import Testing
@testable import Reforge

@MainActor
@Suite struct BackgroundCheckTests {
    /// Alpha (101) and Bravo (102) tracked at old files, newer ones on CurseForge; checks on every 3 hours.
    static func env(hours: Int? = 3) throws -> TestEnv {
        var config = Config()
        config.backgroundCheckHours = hours
        let env = try TestEnv(key: "k", config: config, addons: [
            tracked(101, "Alpha", fileId: 1000), tracked(102, "Bravo", fileId: 2000)])
        env.api.add(cfMod(101, "Alpha", files: [(1001, 1, retail)]), cfFile(1001, mod: 101, "Alpha 1.1"))
        env.api.add(cfMod(102, "Bravo", files: [(2000, 1, retail)]), cfFile(2000, mod: 102, "Bravo 2.0"))
        return env
    }

    func run(_ env: TestEnv, appIsOpen: Bool = false) async -> BackgroundCheck.Outcome {
        await BackgroundCheck.run(model: env.makeModel(), stateFile: env.dir.appendingPathComponent("state.json"),
                                  notifier: env.notifier, appIsOpen: appIsOpen)
    }

    @Test func notifiesOnceAboutANewUpdate() async throws {
        let env = try Self.env()
        #expect(await run(env) == .notified("Alpha has an update."))
        #expect(env.notifier.posts.map(\.title) == ["Addon updates available"])
        // Same update on the next run: stay quiet.
        #expect(await run(env) == .nothingNew)
        #expect(env.notifier.posts.count == 1)
        #expect(env.installer.installs.isEmpty, "background checks never install")
    }

    @Test func aNewerReleaseIsAnnouncedAgain() async throws {
        let env = try Self.env()
        _ = await run(env)
        env.api.add(cfMod(101, "Alpha", files: [(1002, 1, retail)]), cfFile(1002, mod: 101, "Alpha 1.2"))
        env.api.add(cfMod(102, "Bravo", files: [(2001, 1, retail)]), cfFile(2001, mod: 102, "Bravo 2.1"))
        #expect(await run(env) == .notified("Alpha and Bravo have updates."))
    }

    @Test func updatingThenANewReleaseNotifiesAgain() async throws {
        let env = try Self.env()
        _ = await run(env)
        // The user installed Alpha 1.1 in the app; later the same file id can't re-trigger, but 1.2 does.
        env.store.config?.addons[0].fileId = 1001
        #expect(await run(env) == .nothingNew)
        env.api.add(cfMod(101, "Alpha", files: [(1002, 1, retail)]), cfFile(1002, mod: 101, "Alpha 1.2"))
        #expect(await run(env) == .notified("Alpha has an update."))
    }

    @Test func staysQuietWhenOffOpenOrNotSetUp() async throws {
        #expect(await run(try Self.env(hours: nil)) == .disabled)
        #expect(await run(try Self.env(), appIsOpen: true) == .skipped)
        let noKey = try Self.env()
        noKey.keys.stored = ""
        #expect(await run(noKey) == .skipped)
        #expect(noKey.api.calls.isEmpty)
    }

    @Test func failedCheckKeepsState() async throws {
        let env = try Self.env()
        _ = await run(env)
        env.api.error = URLError(.notConnectedToInternet)
        #expect(await run(env) == .failed)
        env.api.error = nil
        #expect(await run(env) == .nothingNew, "the earlier notification is still remembered")
    }

    @Test func messageWording() {
        #expect(BackgroundCheck.message(for: ["A", "B", "C", "D"]) == "A, B and 2 more have updates.")
    }

    // MARK: Settings

    @Test func turningOnAsksPermissionThenSchedules() async throws {
        let env = try Self.env(hours: nil)
        let model = env.makeModel()
        await model.setBackgroundChecks(hours: 6)
        #expect(env.notifier.permissionRequests == 1)
        #expect(env.scheduler.calls == [6])
        #expect(env.store.config?.backgroundCheckHours == 6)

        await model.setBackgroundChecks(hours: nil)
        #expect(env.notifier.permissionRequests == 1, "turning off doesn't ask")
        #expect(env.scheduler.calls == [6, nil])
        #expect(env.store.config?.backgroundCheckHours == nil)
    }

    @Test func deniedNotificationsLeaveItOff() async throws {
        let env = try Self.env(hours: nil)
        env.notifier.allowed = false
        let model = env.makeModel()
        await model.setBackgroundChecks(hours: 3)
        #expect(env.scheduler.calls.isEmpty)
        #expect(model.config.backgroundCheckHours == nil)
        #expect(model.backgroundCheckProblem?.contains("System Settings") == true)
    }

    @Test func schedulerFailureIsReported() async throws {
        let env = try Self.env(hours: nil)
        env.scheduler.error = LaunchAgentScheduler.Failed()
        let model = env.makeModel()
        await model.setBackgroundChecks(hours: 3)
        #expect(model.config.backgroundCheckHours == nil)
        #expect(model.backgroundCheckProblem?.contains("launchctl") == true)
    }
}

/// The real scheduler, pointed at a temp folder with launchctl faked out.
@Suite struct LaunchAgentSchedulerTests {
    final class Launchctl { var calls: [[String]] = []; var status: Int32 = 0 }

    func make(_ dir: URL, _ lc: Launchctl, env: [String: String] = [:]) -> LaunchAgentScheduler {
        LaunchAgentScheduler(label: "test.reforge.update-check", agentsDir: dir, executable: "/Apps/Reforge.app/Contents/MacOS/Reforge",
                             environment: env, launchctl: { lc.calls.append($0); return lc.status })
    }

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ReforgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func writesAndLoadsTheAgent() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let lc = Launchctl()
        let s = make(dir, lc, env: ["REFORGE_DEV_DIR": "/repo/.dev"])
        try s.set(hours: 6)

        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: s.plistFile), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "test.reforge.update-check")
        #expect(plist["ProgramArguments"] as? [String] == ["/Apps/Reforge.app/Contents/MacOS/Reforge", "--background-check"])
        #expect(plist["StartInterval"] as? Int == 6 * 3600)
        #expect((plist["EnvironmentVariables"] as? [String: String])?["REFORGE_DEV_DIR"] == "/repo/.dev")
        #expect(lc.calls.map(\.first) == ["bootout", "bootstrap"])

        // Same schedule again (every launch): nothing to do.
        try s.set(hours: 6)
        #expect(lc.calls.count == 2)

        try s.set(hours: nil)
        #expect(lc.calls.last?.first == "bootout")
        #expect(!FileManager.default.fileExists(atPath: s.plistFile.path))
        // Already off: doesn't even run launchctl.
        try s.set(hours: nil)
        #expect(lc.calls.count == 3)
    }

    @Test func failedLoadLeavesNoPlist() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let lc = Launchctl(); lc.status = 5
        let s = make(dir, lc)
        #expect(throws: LaunchAgentScheduler.Failed.self) { try s.set(hours: 3) }
        #expect(!FileManager.default.fileExists(atPath: s.plistFile.path))
    }
}
