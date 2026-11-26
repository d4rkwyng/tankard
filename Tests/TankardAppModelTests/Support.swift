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
/// here (`track`, `fresh`). Three things then remove them:
/// - Scripts/test.sh, after the test process has exited: it sets
///   TANKARD_TEST_DEFAULTS_LIST to a file, `track` appends each name to it,
///   and the script runs `defaults delete` and removes the plist for each
///   name listed, twice (the second pass after a wait). That is the
///   reliable one when the script itself exits: nothing in the tests can
///   still write by then.
/// - A sweeper started at the first `track`, in its own session. A crash,
///   a timeout, or SIGKILL never runs `atexit` and can kill a sweeper that
///   is still in this process group before its first delete; cfprefsd then
///   flushes the emptied domain as a `{}` plist (seen from about 1s to
///   about 8s later). The sweeper waits until this process is gone and
///   deletes twice. It is started even when the test script's list is set,
///   because that script's trap does not run if the script is killed.
///   Its list is `tankard-test-defaults-<pid>-<uuid>.txt`. The uuid is
///   chosen once, when the sweeper is armed, and the sweeper is given that
///   path: a later process that is handed the same pid writes a different
///   file and never opens this one. When the sweeper notices this process
///   is gone it copies the bytes written so far, and both passes delete
///   only names from that copy.
/// - An `atexit` hook that removes each suite in-process. If the early
///   sweeper could not be spawned, it also falls back to the same sweep
///   (`sweepAfterExit`) for a normal exit.
/// `Scoped` / `withTestDefaults` remove a suite as soon as the test is done.
/// Before 0.8.4 nothing removed them and a busy Mac collected over 10,000
/// plists in ~/Library/Preferences. Names are per-process (a UUID each), so
/// neither ever touches another, concurrent test run's suites.
enum TestDefaults {
    /// Seconds after the test process is gone before the first
    /// `defaults delete`, and the further wait before the second. A killed
    /// process's cfprefsd flush landed anywhere from about 1s to about 8s
    /// later. The first delete is early enough to drop the domain (it
    /// prevents a flush that has not happened yet), and the second pass
    /// runs after that 8s flush.
    static let sweepFirstDelaySeconds = 4
    static let sweepSecondGapSeconds = 8

    /// A name this process may delete. The app's own domain and any
    /// ephemeral suite are not sweepable, nor is a name containing `/` or
    /// whitespace (that could escape the one-name-per-line list).
    static func isSweepable(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name == "net.mindtricks.tankard" || name == "net.mindtricks.tankard.ephemeral" { return false }
        if name.contains("/") { return false }
        if name.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) { return false }
        if name.hasPrefix("net.mindtricks.tankard.ephemeral.") { return false }
        return name.hasPrefix("net.mindtricks.tankard.tests.") || name.hasPrefix("tankard-test-")
    }

    /// Shell run by the sweeper. `$1` is the test process, `$2` the name
    /// list, `$3` the first delay, `$4` the gap before the second pass,
    /// `$5` `echo` to print sweepable names instead of deleting. The list
    /// is read only after the test process is gone, so a name appended
    /// while it was alive is still covered. The bytes on disk at that
    /// moment are copied to `$2.frozen` before either sleep; both passes
    /// read the copy, and a line appended later is ignored. `DEFAULTS`,
    /// when set, replaces `/usr/bin/defaults` (the guard test points it
    /// at a stub).
    static let sweepScript = """
        parent=$1
        list=$2
        delay=${3:-4}
        gap=${4:-8}
        mode=${5:-delete}
        while kill -0 "$parent" 2>/dev/null; do
            sleep 0.2
        done
        if [ -z "$HOME" ] || [ "$HOME" = / ]; then
            exit 0
        fi
        if [ ! -f "$list" ]; then
            exit 0
        fi
        # Owner is gone. Freeze the bytes written so far. A later writer
        # (a pid reuse that somehow still had this path) must not add a
        # name this sweep deletes. The copy is renamed into place so a
        # reader never sees a half-written file.
        limit=$(/usr/bin/stat -f %z "$list" 2>/dev/null | /usr/bin/tr -d '[:space:]')
        case "$limit" in
            ''|*[!0-9]*) exit 0 ;;
        esac
        partial="$list.frozen.partial"
        snapshot="$list.frozen"
        if [ "$limit" -eq 0 ]; then
            : > "$partial"
        else
            /bin/dd if="$list" of="$partial" bs="$limit" count=1 2>/dev/null || {
                rm -f "$partial"
                exit 0
            }
        fi
        /bin/mv -f "$partial" "$snapshot" || {
            rm -f "$partial"
            exit 0
        }
        for pass in 1 2; do
            if [ "$pass" = 1 ]; then
                sleep "$delay"
            else
                sleep "$gap"
            fi
            while IFS= read -r name || [ -n "$name" ]; do
                case "$name" in
                    net.mindtricks.tankard|net.mindtricks.tankard.ephemeral) continue ;;
                    */*|*[[:space:]]*) continue ;;
                    net.mindtricks.tankard.tests.*|tankard-test-*) ;;
                    *) continue ;;
                esac
                if [ "$mode" = echo ]; then
                    printf '%s\\n' "$name"
                else
                    ${DEFAULTS:-/usr/bin/defaults} delete "$name" >/dev/null 2>&1 || true
                    rm -f "$HOME/Library/Preferences/$name.plist"
                fi
            done < "$snapshot"
        done
        rm -f "$snapshot" "$partial"
        if [ "$mode" != echo ]; then
            rm -f "$list"
        fi
        """

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        /// `true` the first time `name` is registered.
        func insert(_ name: String) -> Bool {
            lock.withLock { names.insert(name).inserted }
        }
        func drain() -> [String] {
            lock.withLock {
                defer { names.removeAll() }
                return Array(names)
            }
        }
    }

    /// One sweeper per process, spawned on the first tracked name. Its
    /// standard streams are /dev/null and it is not in this process group:
    /// a pipe inherited from the test runner kept `kill -0` true forever
    /// (the runner never saw EOF, so it never reaped the zombie), and a
    /// kill of the test's group must not take the sweeper with it.
    private final class Sweeper: @unchecked Sendable {
        private let lock = NSLock()
        private var attempted = false
        private var armed = false
        let listPath: String

        /// Pid plus a token chosen once, here. A later process that is
        /// given the same pid builds a different path. The sweeper is
        /// handed `listPath`; it does not derive the path itself, so it
        /// cannot open that other file.
        init() {
            let token = UUID().uuidString
            listPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("tankard-test-defaults-\(getpid())-\(token).txt").path
        }

        func arm() {
            lock.lock()
            defer { lock.unlock() }
            guard !attempted else { return }
            attempted = true
            armed = TestDefaults.spawnSweeper(listPath: listPath)
        }

        var isArmed: Bool { lock.withLock { armed } }
    }

    private static let registry = Registry()
    private static let sweeper = Sweeper()
    private static let exitHook: Void = { atexit { TestDefaults.removeAll() } }()

    /// The name list the sweeper reads after this process exits. The file
    /// name is this process's pid and the token chosen when the sweeper
    /// was armed.
    static var sweeperListPath: String { sweeper.listPath }

    /// Registers `name` for removal; returns it. The name is on disk before
    /// the caller creates the suite, so a kill in between still leaves the
    /// sweeper something to delete.
    @discardableResult static func track(_ name: String) -> String {
        _ = exitHook
        sweeper.arm()
        if registry.insert(name) {
            appendLine(name, to: sweeper.listPath)
            if let list = ProcessInfo.processInfo.environment["TANKARD_TEST_DEFAULTS_LIST"] {
                appendLine(name, to: list)
            }
        }
        return name
    }

    /// Appends one sweepable name with `O_APPEND`, so two processes sharing
    /// Scripts/test.sh's list cannot overwrite each other's lines.
    private static func appendLine(_ name: String, to path: String) {
        guard isSweepable(name) else { return }
        let fd = path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o644)) }
        guard fd >= 0 else { return }
        defer { close(fd) }
        var bytes = Array((name + "\n").utf8)
        bytes.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            var rest = buf.count
            var cursor = base
            while rest > 0 {
                let n = write(fd, cursor, rest)
                if n > 0 {
                    rest -= n
                    cursor = cursor.advanced(by: n)
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// Starts the sweeper in its own session. False if it could not be
    /// spawned; `sweepAfterExit` then covers a normal exit.
    private static func spawnSweeper(listPath: String) -> Bool {
        if !FileManager.default.fileExists(atPath: listPath) {
            FileManager.default.createFile(atPath: listPath, contents: Data())
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0 else { return false }

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attr) }
        // Own session, and no inherited descriptors: the test runner's
        // stdout pipe must not stay open in the sweeper.
        let flags = Int16(POSIX_SPAWN_SETSID) | Int16(POSIX_SPAWN_SETSIGMASK) | Int16(POSIX_SPAWN_SETSIGDEF)
            | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attr, flags) == 0 else { return false }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        var signalDefaults = sigset_t()
        sigfillset(&signalDefaults)
        posix_spawnattr_setsigdefault(&attr, &signalDefaults)

        let arguments = ["/bin/sh", "-c", sweepScript, "sh", String(getpid()), listPath,
                         String(sweepFirstDelaySeconds), String(sweepSecondGapSeconds)]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        return posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, envp) == 0
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
    ///
    /// 0.9.4: `CFPreferencesAppSynchronize` does not put a removed domain
    /// on disk. The old plist (with its keys) stays until cfprefsd's own
    /// flush, which came 0.2s to 4s later, so a plist unlinked here could
    /// come back as `{}` afterwards. That was the TestDefaultsTests flake
    /// (scopedSuiteLeavesNoPlist and withTestDefaultsLeavesNoPlist, on the
    /// check after the 0.5s wait). `flushPendingWrite` makes cfprefsd write
    /// the `{}` now; once it is written, nothing is pending, and the unlink
    /// is the last change to that path.
    static func remove(_ name: String) {
        removeInProcess(name)
        flushPendingWrite(name)
        try? FileManager.default.removeItem(at: plistURL(name))
    }

    /// The pre-0.9.4 `remove`, without the flush: `removeAll` runs it for
    /// every suite at exit (hundreds), where spawning `defaults` for each
    /// would be slow, and the sweeper's two passes after exit already cover
    /// a late write-back.
    private static func removeInProcess(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
    }

    /// Has cfprefsd write anything it still holds for `name` to disk before
    /// this returns. A read from another process does that (cfprefsd writes
    /// a dirty domain before it answers), so `defaults export <name>
    /// /dev/null` is enough: read-only, and the file it writes is
    /// /dev/null. Only test-shaped names, so a caller's mistake can never
    /// point it at the app's own domain. False if `defaults` could not be
    /// run or was stopped after 30s; true once it ran to the end (its exit
    /// status is 0 even for a domain with no file).
    @discardableResult static func flushPendingWrite(_ name: String) -> Bool {
        guard isSweepable(name) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["export", name, "/dev/null"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        // A stuck cfprefsd fails the caller's check instead of hanging the run.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        return p.terminationReason == .exit
    }

    static func plistURL(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
    }

    static func removeAll() {
        let names = registry.drain()
        for name in names {
            removeInProcess(name)
            try? FileManager.default.removeItem(at: plistURL(name))
        }
        sweepAfterExit()
    }

    /// Used only when the early sweeper could not be spawned, and only for
    /// a normal exit (this runs from `atexit`, which a kill skips). Same
    /// script and list. Not a new session: a kill of this process group
    /// would take it too, which is the hole the early sweeper closes.
    /// Under Scripts/test.sh the script's own two passes do this.
    private static func sweepAfterExit() {
        guard !sweeper.isArmed else { return }
        guard ProcessInfo.processInfo.environment["TANKARD_TEST_DEFAULTS_LIST"] == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", sweepScript, "sh", String(getpid()), sweeper.listPath,
                       String(sweepFirstDelaySeconds), String(sweepSecondGapSeconds)]
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
