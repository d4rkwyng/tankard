import Foundation
import os
import TankardCore
@testable import TankardAppModel

/// A shared, ordered record of everything the fakes were asked to run.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    func add(_ c: [String]) { lock.withLock { _calls.append(c) } }
    var calls: [[String]] { lock.withLock { _calls } }
    func count(_ first: String) -> Int { calls.filter { $0.first == first }.count }
}

/// Answers `brew info` (from a fixture, or failing) and git probes.
final class FakeInfoRunner: CommandRunning, @unchecked Sendable {
    let log: CallLog
    private let lock = NSLock()
    private var _info: Data
    /// What `brew info` answers (settable: brew's state changing mid-run).
    var info: Data {
        get { lock.withLock { _info } }
        set { lock.withLock { _info = newValue } }
    }
    private var _failInfo = false
    var failInfo: Bool {
        get { lock.withLock { _failInfo } }
        set { lock.withLock { _failInfo = newValue } }
    }

    init(log: CallLog, info: Data) {
        self.log = log
        self._info = info
    }

    /// 0.4: the background reads (`brew vulns`, `brew info --sizes`,
    /// `brew outdated --greedy`) are answered here and recorded apart, so
    /// `log` stays the status reads and queued commands.
    let insightLog = CallLog()
    private var _insights: [[String]: ProcessResult] = [
        BrewClient.vulnsArguments: ProcessResult(exitCode: 0, stdout: Data(#"{"findings":[],"skipped_formulae":[],"checked":0,"complete":true,"outdated_without_sbom":[],"unscanned_formulae":{}}"#.utf8), stderr: Data()),
        BrewClient.sizesArguments: ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()),
        BrewClient.greedyOutdatedArguments: ProcessResult(exitCode: 0, stdout: Data(#"{"formulae":[],"casks":[]}"#.utf8), stderr: Data()),
    ]
    func setInsight(_ arguments: [String], _ result: ProcessResult) { lock.withLock { _insights[arguments] = result } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        if executable.hasSuffix("brew"), let r = lock.withLock({ _insights[arguments] }) {
            insightLog.add(arguments)
            return r
        }
        if executable.hasSuffix("brew") {
            log.add(arguments)
            if failInfo { return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: boom".utf8)) }
            return ProcessResult(exitCode: 0, stdout: info, stderr: Data())
        }
        return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data())
    }
}

/// A streaming runner whose behaviour per command is a closure.
struct FakeStreamRunner: StreamingCommandRunning {
    let log: CallLog
    var behaviour: @Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32

    func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        log.add(arguments)
        return try await behaviour(arguments, output)
    }
}

/// A one-shot latch tests can wait on or open.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        let w: [CheckedContinuation<Void, Never>] = lock.withLock {
            open = true
            defer { waiters = [] }
            return waiters
        }
        w.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if open { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }
}

let intelInstall = BrewInstallation(brewPath: "/usr/local/bin/brew", prefix: "/usr/local", repository: "/usr/local/Homebrew")
let intelPlatform = BottlePlatform(arch: .x86_64, macOSVersion: "14", cellar: "/usr/local/Cellar")

/// The Intel VM fixture with the demo's version tweaks (5 upgrades).
func demoIntelInfo() -> Data {
    Demo.currentInfo(.intelbrew, base: Demo.fixtureInfo(.intelbrew), upgraded: [])
}

func makeClient(_ runner: CommandRunning, intelbrew: Bool = true) -> BrewClient {
    var process = ["HOME": "/Users/test", "USER": "test"]
    if intelbrew { process["HOMEBREW_CORE_GIT_REMOTE"] = Intelbrew.coreRemote }
    return BrewClient(installation: intelInstall, platform: intelPlatform, runner: runner,
                      sources: EnvironmentSources(process: process), fileExists: { _ in false })
}

/// The UserDefaults suites tests create, and their removal. Swift Testing
/// has no tearDown, so every helper that makes a suite registers its name
/// here (`track`, `fresh`). Two things then remove them:
/// - Scripts/test.sh, after the test process has exited: it sets
///   TANKARD_TEST_DEFAULTS_LIST to a file, `track` appends each name to it,
///   and the script runs `defaults delete` and removes the plist for each
///   name listed. That is the reliable one: nothing in the tests can still
///   write by then.
/// - An `atexit` hook here, for a bare `swift test`: it removes each suite
///   and then leaves a detached sweeper to delete the plists cfprefsd writes
///   back once the process has gone (`sweepAfterExit`).
/// `Scoped` / `withTestDefaults` remove a suite as soon as the test is done.
/// Before 0.8.4 nothing removed them and a busy Mac collected over 10,000
/// plists in ~/Library/Preferences. Names are per-process (a UUID each), so
/// neither ever touches another, concurrent test run's suites.
enum TestDefaults {
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        private let list: FileHandle? = ProcessInfo.processInfo.environment["TANKARD_TEST_DEFAULTS_LIST"]
            .flatMap { FileHandle(forWritingAtPath: $0) }
        func add(_ name: String) {
            lock.withLock {
                guard names.insert(name).inserted, let list else { return }
                list.seekToEndOfFile()
                list.write(Data((name + "\n").utf8))
            }
        }
        func drain() -> [String] {
            lock.withLock {
                defer { names.removeAll() }
                return Array(names)
            }
        }
    }
    private static let registry = Registry()
    private static let exitHook: Void = { atexit { TestDefaults.removeAll() } }()

    /// Registers `name` for removal; returns it.
    @discardableResult static func track(_ name: String) -> String {
        _ = exitHook
        registry.add(name)
        return name
    }

    /// A new, empty suite named `name`, registered for removal.
    static func fresh(_ name: String = "net.mindtricks.tankard.tests.\(UUID().uuidString)") -> UserDefaults {
        track(name)
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// Removes one suite now: its contents, then its plist (cfprefsd leaves
    /// an emptied domain behind as a `{}` file).
    static func remove(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: plistURL(name))
    }

    static func plistURL(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
    }

    static func removeAll() {
        let names = registry.drain()
        names.forEach(remove)
        sweepAfterExit(names)
    }

    /// 0.8.9: cfprefsd writes an emptied domain back as a `{}` plist when
    /// the process disconnects, after anything this process could delete
    /// (a bare `swift test` left ~175 per run that way). So for a bare run,
    /// a detached `sh` waits for this process to be gone and then deletes
    /// each listed plist, the exact path and only test-shaped names. Under
    /// Scripts/test.sh (TANKARD_TEST_DEFAULTS_LIST set) the script does this.
    private static func sweepAfterExit(_ names: [String]) {
        guard ProcessInfo.processInfo.environment["TANKARD_TEST_DEFAULTS_LIST"] == nil else { return }
        let safe = names.filter {
            ($0.hasPrefix("net.mindtricks.tankard.tests.") || $0.hasPrefix("tankard-test-")) && !$0.contains("/")
        }
        guard !safe.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; sleep 3; shift
            for n; do rm -f "$HOME/Library/Preferences/$n.plist"; done
            """, "sh", String(getpid())] + safe
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// 0.8.9: a suite that removes itself (domain and plist) when the test
    /// is done with it, rather than only at process exit, so a run that is
    /// killed part-way doesn't leave every suite behind. For tests that own
    /// the suite outright; a suite handed to a store whose async work may
    /// still write after the test returns stays on `fresh`/`track`, which
    /// clean up after the process (and Scripts/test.sh after that).
    final class Scoped: @unchecked Sendable {
        let name: String
        let defaults: UserDefaults
        init(_ name: String = "net.mindtricks.tankard.tests.\(UUID().uuidString)") {
            self.name = name
            defaults = TestDefaults.fresh(name)
        }
        deinit { TestDefaults.remove(name) }
    }
}

/// Runs `body` with a fresh suite, removed (domain and plist) when it returns.
func withTestDefaults<R>(_ body: (UserDefaults, String) throws -> R) rethrows -> R {
    let scoped = TestDefaults.Scoped()
    defer { withExtendedLifetime(scoped) {} }
    return try body(scoped.defaults, scoped.name)
}

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Polls `condition` on the main actor until true or `timeout` passes.
/// It returns as soon as the condition holds, so the timeout costs nothing
/// on success; it is only how long a broken test hangs. 30 s, not 5: the
/// whole suite runs at once and on GitHub's macos-15 runner (3 slow cores)
/// a demo session that takes 0.2 s here took over 5 s of wall clock.
@MainActor
func waitUntil(timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Sleeps until cancelled (throws CancellationError then).
func sleepUntilCancelled() async throws {
    try await Task.sleep(for: .seconds(60))
}

/// Waits for a status read that ended after `reads` (`refreshesCompleted`
/// taken before the session started): the read a finished session starts.
/// `waitUntil { !store.isRefreshing }` right after `isFinished` could pass
/// before that read began (it runs in a Task) and race it.
@MainActor
func waitForRead(_ store: AppStore, after reads: Int, timeout: Duration = .seconds(30)) async -> Bool {
    await waitUntil(timeout: timeout) { store.refreshesCompleted > reads && !store.isRefreshing }
}

/// 0.8.4: `AppStore(deps:)` in a test gets settings TestDefaults removes.
/// Without settings the store makes its own suite,
/// net.mindtricks.tankard.ephemeral.<UUID> (AppStore.swift), which nothing
/// deleted: about 33 plists a test run. Swift prefers this overload, which
/// needs no default argument, over `init(deps:settings: = nil)`.
extension AppStore {
    convenience init(deps: Dependencies) {
        self.init(deps: deps, settings: testSettings())
    }
}
