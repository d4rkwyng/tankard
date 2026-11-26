import Foundation
import Testing

// 0.8.4: the suites tests make must not pile up in ~/Library/Preferences.

struct TestDefaultsTests {
    @Test func removeDeletesTheDomainAndItsPlist() async throws {
        let name = "tankard-test-cleanup-\(UUID().uuidString)"
        let d = TestDefaults.fresh(name)
        d.set(true, forKey: "x")
        #expect(CFPreferencesAppSynchronize(name as CFString))
        let plist = TestDefaults.plistURL(name)
        #expect(FileManager.default.fileExists(atPath: plist.path))
        // remove and the flush wait on `defaults`: off the test pool.
        #expect(await offCooperativePool { TestDefaults.remove(name) })
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        // 0.9.4: nothing left for cfprefsd to write back. Forcing its
        // pending write now finds no `{}` to put back.
        #expect(await offCooperativePool { TestDefaults.flushPendingWrite(name) })
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        #expect(UserDefaults(suiteName: name)!.object(forKey: "x") == nil)
    }

    /// 0.9.4: the flush is read-only, and never reaches a name that is
    /// not test-shaped.
    @Test func flushPendingWriteOnlyReadsTestShapedNames() async throws {
        #expect(!TestDefaults.flushPendingWrite("net.mindtricks.tankard"))
        #expect(!TestDefaults.flushPendingWrite("net.mindtricks.tankard.ephemeral"))
        #expect(!TestDefaults.flushPendingWrite("tankard-test-bad \(UUID().uuidString)"))
        let name = "tankard-test-flush-\(UUID().uuidString)"
        #expect(await offCooperativePool { TestDefaults.flushPendingWrite(name) })
        #expect(!FileManager.default.fileExists(atPath: TestDefaults.plistURL(name).path))
    }

    /// 0.9.4 review: the flush counts only a `defaults` that exited 0, and
    /// a stuck one is stopped within its timeout plus a few seconds.
    /// Each run waits on its process, so it runs off the test pool.
    @Test func flushSucceedsOnlyOnExitZeroAndIsBounded() async throws {
        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> Bool {
            await offCooperativePool { TestDefaults.runToSuccess(executable, arguments, timeout: timeout) }
        }
        #expect(await run("/usr/bin/true", [], timeout: 10))
        #expect(!(await run("/usr/bin/false", [], timeout: 10)))
        #expect(!(await run("/bin/sh", ["-c", "exit 3"], timeout: 10)))
        #expect(!(await run("/nonexistent/defaults", [], timeout: 10)))
        let start = Date()
        #expect(!(await run("/bin/sleep", ["30"], timeout: 0.3)))
        // SIGTERM ends sleep at once; the SIGKILL fallback adds at most 4s.
        #expect(Date().timeIntervalSince(start) < 5)
        // Ignoring SIGTERM is not enough to hang it either. `exec`: one
        // process, the one runToSuccess signals, ignoring TERM (an ignored
        // signal stays ignored across exec), so SIGKILL is what ends it,
        // and no `sleep 30` is left behind when it does.
        let stubborn = Date()
        let marker = "tankard-test-stubborn-\(UUID().uuidString)"
        #expect(!(await run("/bin/sh", ["-c", "trap '' TERM; exec -a \(marker) /bin/sleep 30"], timeout: 0.3)))
        let elapsed = Date().timeIntervalSince(stubborn)
        // SIGTERM ignored: it took the 2s wait and the SIGKILL.
        #expect(elapsed >= 2)
        #expect(elapsed < 6)
        let left = await offCooperativePool { () -> String in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-axww", "-o", "args="]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "ps did not run" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }
        #expect(!left.contains(marker))
    }

    /// 0.8.9: a Scoped suite leaves no plist for its UUID once released,
    /// even after a write was flushed to disk.
    @Test func scopedSuiteLeavesNoPlist() async throws {
        var name = ""
        do {
            let scoped = TestDefaults.Scoped()
            name = scoped.name
            scoped.defaults.set("v", forKey: "k")
            #expect(CFPreferencesAppSynchronize(name as CFString))
            #expect(FileManager.default.fileExists(atPath: TestDefaults.plistURL(name).path))
        }
        #expect(name.hasPrefix("net.mindtricks.tankard.tests."))
        try await assertNoPlist(name)
    }

    @Test func withTestDefaultsLeavesNoPlist() async throws {
        let name = withTestDefaults { d, name in
            d.set(1, forKey: "k")
            #expect(CFPreferencesAppSynchronize(name as CFString))
            return name
        }
        try await assertNoPlist(name)
    }

    /// The app's domain is not a test suite, whatever a list file might say.
    @Test func onlyTestShapedNamesAreSweepable() {
        let id = UUID().uuidString
        #expect(TestDefaults.isSweepable("net.mindtricks.tankard.tests.\(id)"))
        #expect(TestDefaults.isSweepable("tankard-test-cleanup-\(id)"))
        #expect(!TestDefaults.isSweepable("net.mindtricks.tankard"))
        #expect(!TestDefaults.isSweepable("net.mindtricks.tankard.ephemeral"))
        #expect(!TestDefaults.isSweepable("net.mindtricks.tankard.ephemeral.\(id)"))
        #expect(!TestDefaults.isSweepable("net.mindtricks.tankard.tests.\(id)/extra"))
        #expect(!TestDefaults.isSweepable("tankard-test-bad \(id)"))
        #expect(!TestDefaults.isSweepable("net.mindtricks.tankard.tests"))
        #expect(!TestDefaults.isSweepable("tankard-test"))
        #expect(!TestDefaults.isSweepable(""))
    }

    /// `fresh` records the suite before anything can flush it, and a second
    /// name is appended rather than written over the first.
    @Test func freshAppendsTheSuiteNameForTheSweeper() throws {
        let first = "tankard-test-listed-\(UUID().uuidString)"
        let second = "net.mindtricks.tankard.tests.\(UUID().uuidString)"
        _ = TestDefaults.fresh(first)
        _ = TestDefaults.fresh(second)
        let listed = try String(contentsOfFile: TestDefaults.sweeperListPath, encoding: .utf8)
        #expect(listed.contains(first + "\n"))
        #expect(listed.contains(second + "\n"))
        if let shared = ProcessInfo.processInfo.environment["TANKARD_TEST_DEFAULTS_LIST"] {
            let text = try String(contentsOfFile: shared, encoding: .utf8)
            #expect(text.contains(first + "\n"))
            #expect(text.contains(second + "\n"))
        }
        TestDefaults.remove(first)
        TestDefaults.remove(second)
    }

    /// The sweep deletes twice, and the second wait is after the late flush.
    @Test func sweepScriptDeletesTwiceAndTheSecondPassIsLate() throws {
        let script = TestDefaults.sweepScript
        #expect(script.contains("for pass in 1 2"))
        #expect(script.contains("net.mindtricks.tankard|net.mindtricks.tankard.ephemeral"))
        #expect(TestDefaults.sweepFirstDelaySeconds >= 4)
        #expect(TestDefaults.sweepSecondGapSeconds >= 8)
        #expect(script.contains("${3:-\(TestDefaults.sweepFirstDelaySeconds)}"))
        #expect(script.contains("${4:-\(TestDefaults.sweepSecondGapSeconds)}"))
        #expect(script.contains("/usr/bin/defaults"))
        let delete = script.range(of: #"delete "$name""#)
        let remove = script.range(of: #"rm -f "$HOME/Library/Preferences/$name.plist""#)
        #expect(delete != nil && remove != nil && delete!.lowerBound < remove!.lowerBound)
        // The copy is taken when the owner is noticed gone, before either sleep.
        let frozen = try #require(script.range(of: "$list.frozen"))
        let delaySleep = try #require(script.range(of: "sleep \"$delay\""))
        #expect(frozen.lowerBound < delaySleep.lowerBound)
    }

    /// The list file is not `tankard-test-defaults-<pid>.txt`. A token
    /// chosen for this process is part of the name, and it does not change
    /// for the rest of the process. A new process, even with this pid,
    /// would choose its own token and open a different file.
    @Test func sweeperListIsKeyedByPidAndAProcessToken() {
        let path = TestDefaults.sweeperListPath
        #expect(TestDefaults.sweeperListPath == path)
        let base = URL(fileURLWithPath: path).lastPathComponent
        let prefix = "tankard-test-defaults-\(getpid())-"
        #expect(base.hasPrefix(prefix))
        #expect(base.hasSuffix(".txt"))
        #expect(base != "tankard-test-defaults-\(getpid()).txt")
        let token = String(base.dropFirst(prefix.count).dropLast(".txt".count))
        #expect(UUID(uuidString: token) != nil)
    }

    /// A line appended after the owner is gone is not swept. The copy is
    /// taken first; both passes read that copy. Echo mode, so a broken
    /// filter still cannot delete the real domain.
    @Test func sweepIgnoresNamesAppendedAfterTheOwnerDied() throws {
        let before = realPreferencesHash()
        let fixture = try makeSweepFixture()
        let early = try #require(fixture.sweepable.first)
        let late = "tankard-test-late-\(UUID().uuidString)"
        #expect(TestDefaults.isSweepable(late))
        #expect(!early.contains(late))

        let dead = "99999999"
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/kill")
        probe.arguments = ["-0", dead]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        try #require(probe.terminationStatus != 0)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Two seconds of sleep after the copy, so the append lands while
        // the sweep is waiting and before either pass reads.
        p.arguments = ["-c", TestDefaults.sweepScript, "sh", dead, fixture.list.path, "2", "0", "echo"]
        p.environment = [
            "HOME": fixture.home.path,
            "PATH": "/bin:/usr/bin",
            "DEFAULTS": fixture.stub.path,
            "FAKE_DEFAULTS_LOG": fixture.log.path,
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var started = false
        defer {
            if started {
                if p.isRunning { p.terminate() }
                p.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try p.run()
        started = true

        let frozen = URL(fileURLWithPath: fixture.list.path + ".frozen")
        #expect(waitForFile(frozen, timeout: 5))
        let handle = try FileHandle(forWritingTo: fixture.list)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((late + "\n").utf8))
        try handle.close()
        // The append happened while the sweep was still in its first sleep,
        // not after it had already exited.
        #expect(p.isRunning)
        let frozenText = try String(contentsOf: frozen, encoding: .utf8)
        #expect(frozenText.contains(early + "\n"))
        #expect(!frozenText.contains(late))

        let deadline = Date().addingTimeInterval(8)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(!p.isRunning)
        guard !p.isRunning else { return }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.filter { $0 == early }.count == 2)
        #expect(!lines.contains(late))
        #expect(!lines.contains("net.mindtricks.tankard"))
        let listed = try String(contentsOf: fixture.list, encoding: .utf8)
        #expect(listed.contains(late + "\n"))
        #expect(!FileManager.default.fileExists(atPath: frozen.path))
        let log = (try? String(contentsOf: fixture.log, encoding: .utf8)) ?? ""
        #expect(log.isEmpty)
        #expect(realPreferencesHash() == before)
    }

    /// Echo mode, delay 0, against a dead pid. The list names the app's own
    /// domain; stdout may contain only sweepable names, and `defaults` is
    /// the stub, so a broken filter still cannot delete the real domain.
    @Test func sweepEchoListsOnlySweepableNames() throws {
        let before = realPreferencesHash()
        let fixture = try makeSweepFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let stdout = try runSweep(fixture: fixture, mode: "echo")
        let printed = Set(stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        #expect(printed == Set(fixture.sweepable))
        #expect(printed.allSatisfy(TestDefaults.isSweepable))
        #expect(!printed.contains("net.mindtricks.tankard"))
        let log = (try? String(contentsOf: fixture.log, encoding: .utf8)) ?? ""
        #expect(log.isEmpty)
        #expect(realPreferencesHash() == before)
    }

    /// Delete mode through the stub, with HOME pointed at a temp directory.
    /// The app domain is in the list and must not be handed to `defaults`
    /// or removed from that HOME.
    @Test func sweepDeleteTouchesOnlySweepableNames() throws {
        let before = realPreferencesHash()
        let fixture = try makeSweepFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let stdout = try runSweep(fixture: fixture, mode: nil)
        #expect(stdout.isEmpty)
        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        let lines = log.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { $0.hasPrefix("delete ") })
        let deleted = Set(lines.map { String($0.dropFirst("delete ".count)) })
        #expect(deleted == Set(fixture.sweepable))
        let prefs = fixture.home.appendingPathComponent("Library/Preferences")
        for name in fixture.sweepable {
            #expect(!FileManager.default.fileExists(atPath: prefs.appendingPathComponent("\(name).plist").path))
        }
        for name in fixture.blocked where !name.contains("/") {
            #expect(FileManager.default.fileExists(atPath: prefs.appendingPathComponent("\(name).plist").path))
        }
        #expect(realPreferencesHash() == before)
    }

    @Test func testScriptSweepsListedSuitesTwice() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Scripts/test.sh"), encoding: .utf8)
        #expect(text.contains("for pass in 1 2"))
        #expect(text.contains("sleep 10"))
        #expect(text.contains("[[ $name == net.mindtricks.tankard ]] && continue"))
        #expect(text.contains("net.mindtricks.tankard.tests.*"))
        #expect(text.contains("tankard-test-*"))
        let loop = try #require(text.range(of: "for pass in 1 2"))
        let delete = try #require(text.range(of: "defaults delete \"$name\""))
        let remove = try #require(text.range(of: #"rm -f ~/Library/Preferences/"$name".plist"#))
        let dropList = try #require(text.range(of: #"rm -f "$DEFAULTS_LIST""#))
        #expect(loop.lowerBound < delete.lowerBound)
        #expect(delete.lowerBound < remove.lowerBound)
        #expect(remove.lowerBound < dropList.lowerBound)
    }

    /// Polls until `url` exists. The sweep's copy is renamed into place,
    /// so the file appearing means the snapshot has been written.
    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// No file for this suite's UUID, now, once cfprefsd has been made to
    /// write anything it still held, and after a moment more.
    private func assertNoPlist(_ name: String) async throws {
        let uuid = try #require(name.split(separator: ".").last.map(String.init))
        #expect(UUID(uuidString: uuid) != nil)
        func leftovers() -> [String] {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(uuid) }
        }
        #expect(leftovers().isEmpty)
        // 0.9.4: cfprefsd's own flush of a removed domain came 0.2s to 4s
        // later, so the 0.5s wait alone caught a late `{}` only sometimes.
        // Have it write whatever it still holds now; a write-back
        // `remove` left pending is on disk before the next check.
        #expect(await offCooperativePool { TestDefaults.flushPendingWrite(name) })
        #expect(leftovers().isEmpty)
        try await Task.sleep(for: .milliseconds(500))
        #expect(leftovers().isEmpty)
        #expect(UserDefaults(suiteName: name)!.object(forKey: "k") == nil)
    }

    private struct SweepFixture {
        var directory: URL
        var list: URL
        var home: URL
        var log: URL
        var stub: URL
        var sweepable: [String]
        /// Names that must survive, including ones that are not a single
        /// path component (those have no plist to keep).
        var blocked: [String]
    }

    /// A temp HOME, a stub `defaults`, and a list that includes the real
    /// app domain. Nothing here calls `/usr/bin/defaults`.
    private func makeSweepFixture() throws -> SweepFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tankard-sweep-\(UUID().uuidString)")
        let home = directory.appendingPathComponent("home")
        let prefs = home.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        let stub = directory.appendingPathComponent("defaults")
        let stubSource = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FAKE_DEFAULTS_LOG\"\nexit 0\n"
        try stubSource.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let id = UUID().uuidString
        let sweepable = [
            "tankard-test-echo-\(id)",
            "net.mindtricks.tankard.tests.\(id)",
        ]
        let blocked = [
            "net.mindtricks.tankard",
            "net.mindtricks.tankard.ephemeral",
            "net.mindtricks.tankard.ephemeral.\(id)",
            "tankard-test-bad \(id)",
            "net.mindtricks.tankard.tests.\(id)/extra",
            "not-a-suite",
        ]
        for name in sweepable + blocked where !name.contains("/") {
            FileManager.default.createFile(atPath: prefs.appendingPathComponent("\(name).plist").path, contents: Data("x".utf8))
        }
        let list = directory.appendingPathComponent("names.txt")
        try (sweepable + blocked).joined(separator: "\n").appending("\n").write(to: list, atomically: true, encoding: .utf8)
        let log = directory.appendingPathComponent("defaults.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        return SweepFixture(directory: directory, list: list, home: home, log: log, stub: stub,
                            sweepable: sweepable, blocked: blocked)
    }

    /// Runs the sweep script with both delays at 0. `mode` nil is the
    /// deleting path; the stub and the temp HOME are the only things it can
    /// touch. Fails rather than hanging if the dead pid is actually alive.
    private func runSweep(fixture: SweepFixture, mode: String?) throws -> String {
        let dead = "99999999"
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/kill")
        probe.arguments = ["-0", dead]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        try #require(probe.terminationStatus != 0)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        var arguments = ["-c", TestDefaults.sweepScript, "sh", dead, fixture.list.path, "0", "0"]
        if let mode { arguments.append(mode) }
        p.arguments = arguments
        p.environment = [
            "HOME": fixture.home.path,
            "PATH": "/bin:/usr/bin",
            "DEFAULTS": fixture.stub.path,
            "FAKE_DEFAULTS_LOG": fixture.log.path,
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        try #require(p.terminationStatus == 0)
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// md5 of the app's preferences, when that file exists. Compared around
    /// a sweep so a filter bug cannot pass quietly.
    private func realPreferencesHash() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/net.mindtricks.tankard.plist").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/md5")
        p.arguments = ["-q", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
