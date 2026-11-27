import Foundation
import Testing

// 0.9.4 carryovers from 0.9.2:
// - release.sh runs Scripts/launch-check.sh on the app as it ships: after
//   stapling, `stapler validate` and `spctl`, right before Tankard.zip
//   (with --skip-notarize: after signing and verification, before the zip).
// - launch-check.sh puts the app's cache folder back as it found it, so it
//   leaves no status.json for release.yml's later smoke step.
// Nothing here launches Tankard or reads Homebrew: release.sh only runs as
// --dry-run (which prints and runs nothing, and with TANKARD_SIGN_ID set
// does not read the keychain), and launch-check.sh only ever launches a
// stub app under a throwaway HOME.

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private struct Ran {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs `executable` from the repo root with exactly `environment`. Every
/// wait is bounded, so nothing here can hang the test run: after `timeout`
/// seconds it gets SIGTERM, 2s later SIGKILL, and then at most 5s more to
/// be gone. Output is read as it comes; once the process is gone the pipes
/// get 5s to reach end of file (a descendant that kept one open can't hold
/// the test), and whatever arrived by then is returned.
///
/// The waits block, so they run off Swift's cooperative pool (see
/// `offCooperativePool`): a test awaiting this holds no pool thread.
private func runTool(_ executable: String, _ arguments: [String], environment: [String: String],
                     timeout: TimeInterval = 60) async throws -> Ran {
    try await offCooperativePoolThrowing {
        try runToolBlocking(executable, arguments, environment: environment, timeout: timeout)
    }
}

/// `runTool`'s body. Blocks its thread; only `runTool` calls it.
private func runToolBlocking(_ executable: String, _ arguments: [String], environment: [String: String],
                             timeout: TimeInterval) throws -> Ran {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    p.currentDirectoryURL = repoRoot
    p.environment = environment
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    let outBox = DataBox(), errBox = DataBox()
    let drained = DispatchGroup()
    for (pipe, box) in [(out, outBox), (err, errBox)] {
        drained.enter()
        let once = Once()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                if once.claim() { drained.leave() }
            } else {
                box.append(d)
            }
        }
    }
    do { try p.run() } catch {
        for pipe in [out, err] { pipe.fileHandleForReading.readabilityHandler = nil }
        throw error
    }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        stopBlocking(p, exited: exited)
    }
    if drained.wait(timeout: .now() + 5) == .timedOut {
        for pipe in [out, err] { pipe.fileHandleForReading.readabilityHandler = nil }
    }
    guard !p.isRunning else { throw StillRunning(pid: p.processIdentifier) }
    return Ran(status: p.terminationStatus,
               stdout: String(data: outBox.get(), encoding: .utf8) ?? "",
               stderr: String(data: errBox.get(), encoding: .utf8) ?? "")
}

/// SIGTERM, up to 2s, SIGKILL, up to 5s, awaited off the cooperative pool.
/// Returns whether it is gone.
@discardableResult
private func stop(_ p: Process) async -> Bool {
    let box = ProcessBox(p)
    return await offCooperativePool { stopBlocking(box.process) }
}

/// For a `defer`, which can't await: SIGKILL if it is still running, and
/// no wait. A test's own `await stop(...)` has normally stopped it already.
private func killNow(_ p: Process) {
    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
}

/// `stop`'s body. Blocks its thread. With `exited` (signalled by the
/// process's terminationHandler) it waits on that; otherwise it polls.
@discardableResult
private func stopBlocking(_ p: Process, exited: DispatchSemaphore? = nil) -> Bool {
    func gone(within seconds: TimeInterval) -> Bool {
        if let exited { return exited.wait(timeout: .now() + seconds) == .success || !p.isRunning }
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return !p.isRunning
    }
    guard p.isRunning else { return true }
    p.terminate()
    if gone(within: 2) { return true }
    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    return gone(within: 5)
}

private struct StillRunning: Error, CustomStringConvertible {
    var pid: Int32
    var description: String { "process \(pid) still running after SIGKILL" }
}

/// A Process handed to `blockingWaits` (Process is not Sendable; nothing
/// else touches it while the wait runs).
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// Polls `condition` every 50ms until it holds or `seconds` pass, with
/// `Task.sleep` (no pool thread held). Returns whether it held.
private func waitUntilTrue(within seconds: TimeInterval, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

/// One pipe's bytes, handed from the reading queue to the test.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    func get() -> Data { lock.withLock { data } }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}

/// Serialized: each test runs `bash` (release.sh's dry run), and nothing is
/// gained by starting them all at once on a 3-core CI runner.
@Suite(.serialized)
struct V094ReleaseOrderTests {
    /// `release.sh --dry-run` with a placeholder identity and no notary or
    /// version settings from the caller's environment.
    private func dryRun(_ extra: [String]) async throws -> Ran {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tankard-v094-dry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        return try await runTool("/bin/bash", ["Scripts/release.sh", "--dry-run"] + extra, environment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "TANKARD_SIGN_ID": "Developer ID Application: EXAMPLE (TEAMID)",
        ])
    }

    /// The `+ …` command lines, in order.
    private func commands(_ ran: Ran) -> [String] {
        ran.stdout.split(separator: "\n").map(String.init).filter { $0.hasPrefix("+ ") }
    }

    private func index(_ lines: [String], _ prefix: String) throws -> Int {
        try #require(lines.firstIndex { $0.hasPrefix(prefix) }, "no line starting \(prefix)")
    }

    private let launch = "+ Scripts/launch-check.sh dist/Tankard.app --runs 5 --seconds 10"
    private let finalZip = "+ ditto -c -k --keepParent dist/Tankard.app dist/Tankard.zip"

    @Test func defaultRunLaunchChecksTheStapledAcceptedAppRightBeforeTheZip() async throws {
        let ran = try await dryRun([])
        #expect(ran.status == 0)
        #expect(ran.stdout.contains("Release ready: dist/Tankard.zip"))
        let lines = commands(ran)
        #expect(lines.filter { $0.hasPrefix("+ Scripts/launch-check.sh") }.count == 1)
        let submit = try index(lines, "+ xcrun notarytool submit")
        let staple = try index(lines, "+ xcrun stapler staple dist/Tankard.app")
        let validate = try index(lines, "+ xcrun stapler validate dist/Tankard.app")
        let gatekeeper = try index(lines, "+ spctl -a -vv -t exec dist/Tankard.app")
        let check = try index(lines, launch)
        let dropOld = try index(lines, "+ rm -f dist/Tankard.zip dist/Tankard-notarize.zip")
        let zip = try index(lines, finalZip)
        #expect(submit < staple)
        #expect(staple < validate)
        #expect(validate < gatekeeper)
        // Right after Gatekeeper, and nothing changes the app in between.
        #expect(check == gatekeeper + 1)
        #expect(check < dropOld)
        #expect(dropOld + 1 == zip)
        #expect(zip == lines.count - 1)
        // Not on the pre-notarization app any more.
        let submitZip = try index(lines, "+ ditto -c -k --keepParent dist/Tankard.app dist/Tankard-notarize.zip")
        #expect(submitZip < check)
        #expect(!ran.stderr.contains("--skip-launch-check"))
    }

    @Test func skipNotarizeLaunchChecksTheSignedVerifiedAppBeforeTheZip() async throws {
        let ran = try await dryRun(["--skip-notarize"])
        #expect(ran.status == 0)
        #expect(ran.stdout.contains("Signed but not notarized: dist/Tankard.zip"))
        let lines = commands(ran)
        #expect(!lines.contains { $0.contains("notarytool") || $0.contains("stapler") || $0.contains("spctl") })
        #expect(lines.filter { $0.hasPrefix("+ Scripts/launch-check.sh") }.count == 1)
        let signApp = try index(lines, "+ codesign --force --options runtime --timestamp -s Developer\\ ID\\ Application:\\ EXAMPLE\\ \\(TEAMID\\) dist/Tankard.app")
        let verifyApp = try index(lines, "+ codesign --verify --strict --deep --verbose=2 dist/Tankard.app")
        let verifyHelper = try index(lines, "+ codesign --verify --strict --verbose=2 dist/Tankard.app/Contents/Helpers/TankardPassword.app")
        let check = try index(lines, launch)
        let zip = try index(lines, finalZip)
        #expect(signApp < verifyApp)
        #expect(verifyApp < verifyHelper)
        #expect(check == verifyHelper + 1)
        #expect(zip == check + 1)
        #expect(zip == lines.count - 1)
    }

    @Test func skipLaunchCheckLaunchesNothingAndSaysWhichApp() async throws {
        let stapled = try await dryRun(["--skip-launch-check"])
        #expect(stapled.status == 0)
        #expect(!commands(stapled).contains { $0.contains("launch-check") })
        #expect(stapled.stderr.contains("NOTE: --skip-launch-check: the stapled app was not launched. Run Scripts/launch-check.sh dist/Tankard.app before publishing."))
        #expect(commands(stapled).last == finalZip)

        let signed = try await dryRun(["--skip-notarize", "--skip-launch-check"])
        #expect(signed.status == 0)
        #expect(!commands(signed).contains { $0.contains("launch-check") })
        #expect(signed.stderr.contains("NOTE: --skip-launch-check: the signed app was not launched."))
        #expect(commands(signed).last == finalZip)
    }

    /// The source, so a dry run's order can't drift from the real one: one
    /// helper, called once on each path, each time right before a zip.
    @Test func releaseScriptCallsTheCheckOnlyBeforeEachFinalZip() async throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("Scripts/release.sh"), encoding: .utf8)
        #expect(text.components(separatedBy: "run Scripts/launch-check.sh").count == 2)
        #expect(text.components(separatedBy: "launch_check signed").count == 2)
        #expect(text.components(separatedBy: "launch_check stapled").count == 2)
        let helper = try #require(text.range(of: "launch_check() {"))
        let skipBlock = try #require(text.range(of: "if [ $NOTARIZE = 0 ]; then\n    launch_check signed\n    run ditto -c -k --keepParent \"$APP\" \"$ZIP\""))
        let notarize = try #require(text.range(of: "# 5. Notarize, staple, verify with Gatekeeper."))
        let gatekeeper = try #require(text.range(of: "run spctl -a -vv -t exec \"$APP\""))
        let stapled = try #require(text.range(of: "launch_check stapled"))
        let finalZip = try #require(text.range(of: "# 6. The distribution zip (stapled app)."))
        #expect(helper.lowerBound < skipBlock.lowerBound)
        #expect(skipBlock.lowerBound < notarize.lowerBound)
        #expect(gatekeeper.lowerBound < stapled.lowerBound)
        #expect(stapled.lowerBound < finalZip.lowerBound)
        // --help prints the whole header and stops before the code.
        let help = try await runTool("/bin/bash", ["Scripts/release.sh", "--help"], environment: ["PATH": "/usr/bin:/bin"])
        #expect(help.status == 0)
        #expect(help.stdout.hasSuffix("runtime). No App Sandbox, because brew can't run inside one.\n"))
        #expect(!help.stdout.contains("set -euo pipefail"))
    }

    @Test func scriptsPassBashSyntaxCheck() async throws {
        for script in ["Scripts/release.sh", "Scripts/launch-check.sh", "Scripts/smoke-launch.sh"] {
            let ran = try await runTool("/bin/bash", ["-n", script], environment: ["PATH": "/usr/bin:/bin"])
            #expect(ran.status == 0, "\(script): \(ran.stderr)")
        }
    }
}

/// launch-check.sh against a stub `Tankard` (a shell script) under a temp
/// HOME. The stub records what cache it saw and its environment, then
/// rewrites the cache the way a real launch would, and sleeps until told to
/// quit or killed. A stub `osascript` first in PATH stands in for the Quit
/// Apple event (a shell script is no NSRunningApplication): it sends the
/// pid in its script SIGUSR1, which the stub takes as Quit.
///
/// Serialized: one launch-check (and its stub app) at a time, rather than a
/// dozen at once on a 3-core CI runner (PR #12's `macos-15` run).
@Suite(.serialized)
struct V094LaunchCheckCacheTests {
    private struct Fixture {
        var directory: URL
        var home: URL
        var app: URL
        var mark: URL
        var bin: URL
        var mode: String
        var cache: URL { home.appendingPathComponent("Library/Caches/net.mindtricks.tankard") }
        /// Where `retarget` points the cache link.
        var other: URL { directory.appendingPathComponent("other/net.mindtricks.tankard") }
        var reports: URL { home.appendingPathComponent("Library/Logs/DiagnosticReports") }
        /// Another build's executable (a link to /bin/sleep), which
        /// `start-other` starts.
        var otherTankard: URL { directory.appendingPathComponent("Other.app/Contents/MacOS/Tankard") }
        var environment: [String: String] {
            ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": directory.path + "/",
             "STUB_MARK": mark.path, "STUB_MODE": mode, "STUB_OTHER": other.path, "TANKARD_DEMO": "1",
             "STUB_OTHER_TANKARD": otherTankard.path]
        }
        /// launch-check's work folders left in TMPDIR.
        func workFolders() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix("tankard-launch-check.") }
        }
    }

    /// `mode`: "" (exits 0 when told to quit), `crash-on-quit` (writes a
    /// crash report for its own pid when told to quit, then exits 0),
    /// `abnormal-quit` (exits 6 when told to quit, with no report),
    /// `ignore-quit` (the stub osascript sends nothing, so only SIGTERM
    /// stops it), `replace` (puts another folder where the cache folder
    /// was) or `retarget` (points the cache link, or the folder's place,
    /// at `Fixture.other`), `stall-quit` (the stub osascript takes no
    /// notice of its alarm or SIGTERM and sleeps 60s), `exit-unasked`
    /// (the stub osascript has the app exit 0 on its own, records the
    /// app's process state a moment later, then returns after 1s), or
    /// `start-other` (once it has written the cache, the app starts
    /// `Fixture.otherTankard`, another Tankard that outlives it).
    ///
    /// The stub installs its traps first, so a Quit can't arrive before it
    /// can take it, and holds a Quit that comes before it has written its
    /// marks (and the cache) until it has. It sleeps in 1s pieces it waits on, so a trap runs at
    /// once, and a SIGKILL (which it can't trap) leaves at most a 1s sleep.
    /// On SIGTERM it records `term` in the mark folder and dies of it.
    private func makeFixture(mode: String = "") throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tankard-v094-lc-\(UUID().uuidString)")
        let home = directory.appendingPathComponent("home")
        let mark = directory.appendingPathComponent("mark")
        let bin = directory.appendingPathComponent("bin")
        let macOS = directory.appendingPathComponent("Stub.app/Contents/MacOS")
        for d in [home, mark, bin, macOS] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let stub = """
            #!/bin/sh
            s=
            r="$HOME/Library/Logs/DiagnosticReports"
            quit() {
                [ -n "$s" ] && kill "$s" 2>/dev/null
                echo quit >> "$STUB_MARK/signals"
                case "$STUB_MODE" in
                    crash-on-quit)
                        mkdir -p "$r"
                        echo '{"pid" : '$$', "procName" : "Tankard"}' > "$r/Tankard-2026-11-25-120000.ips"
                        exit 0 ;;
                    abnormal-quit) exit 6 ;;
                esac
                exit 0
            }
            term() {
                [ -n "$s" ] && kill "$s" 2>/dev/null
                echo term >> "$STUB_MARK/signals"
                trap - TERM
                kill -TERM $$
            }
            ready=0 pending=0
            asked() { if [ $ready = 1 ]; then quit; else pending=1; fi; }
            trap asked USR1
            trap 'echo self > "$STUB_MARK/exited"; exit 0' USR2
            trap term TERM
            c="$HOME/Library/Caches/net.mindtricks.tankard"
            if [ -f "$c/status.json" ]; then cat "$c/status.json" > "$STUB_MARK/seen.tmp"; else echo none > "$STUB_MARK/seen.tmp"; fi
            /usr/bin/env > "$STUB_MARK/env"
            echo $$ > "$STUB_MARK/pid"
            mkdir -p "$c"
            echo '{"written":"by the launch"}' > "$c/status.json"
            echo '{}' > "$c/insights.json"
            case "$STUB_MODE" in
                replace) mv "$c" "$c.moved" && mkdir "$c" && echo replacement > "$c/mine.txt" ;;
                retarget) { if [ -L "$c" ]; then rm "$c"; else mv "$c" "$c.moved"; fi; } && ln -s "$STUB_OTHER" "$c" ;;
                start-other) "$STUB_OTHER_TANKARD" 60 </dev/null >/dev/null 2>&1 & echo $! > "$STUB_MARK/otherpid" ;;
            esac
            mv "$STUB_MARK/seen.tmp" "$STUB_MARK/seen"
            ready=1
            [ $pending = 1 ] && quit
            while :; do /bin/sleep 1 & s=$!; wait "$s"; done
            """
        let app = macOS.appendingPathComponent("Tankard")
        try stub.write(to: app, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
        // launch-check's Quit: `osascript -l JavaScript -e "…ProcessIdentifier(<pid>)…"`.
        let osascript = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$STUB_MARK/osascript"
            [ "$STUB_MODE" = ignore-quit ] && exit 0
            if [ "$STUB_MODE" = stall-quit ]; then
                echo $$ > "$STUB_MARK/osapid"
                trap '' ALRM TERM
                exec /bin/sleep 60
            fi
            pid=$(printf '%s\\n' "$*" | sed -n 's/.*runningApplicationWithProcessIdentifier(\\([0-9][0-9]*\\)).*/\\1/p')
            if [ "$STUB_MODE" = exit-unasked ]; then
                [ -n "$pid" ] && kill -USR2 "$pid"
                /bin/sleep 0.5
                ps -o stat= -p "$pid" > "$STUB_MARK/state"
                /bin/sleep 0.5
                exit 0
            fi
            [ -n "$pid" ] && kill -USR1 "$pid"
            exit 0
            """
        let fake = bin.appendingPathComponent("osascript")
        try osascript.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        return Fixture(directory: directory, home: home, app: directory.appendingPathComponent("Stub.app"),
                       mark: mark, bin: bin, mode: mode)
    }

    /// launch-check.sh on the fixture's stub app: one 1s run.
    private func launchCheck(_ f: Fixture, timeout: TimeInterval = 90) async throws -> Ran {
        try await runTool("/bin/bash", ["Scripts/launch-check.sh", "--app", f.app.path, "--runs", "1", "--seconds", "1"],
                          environment: f.environment, timeout: timeout)
    }

    /// What the stub was sent, one line each: `quit`, `term`.
    private func signals(_ f: Fixture) -> [String] {
        (read(f.mark.appendingPathComponent("signals")) ?? "").split(separator: "\n").map(String.init)
    }

    /// A process whose executable path is `path` (a link to /bin/sleep; a
    /// copy of it would not run), sleeping `seconds`.
    /// `home`: its HOME (otherwise this test process's). `target`: what
    /// the link points at (a platform binary, as /bin/sleep, keeps its
    /// environment from `ps -E`; see `buildSleeper` for one that doesn't).
    private func startSleeper(at path: URL, seconds: Int = 60, home: URL? = nil,
                              target: URL = URL(fileURLWithPath: "/bin/sleep")) async throws -> Process {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        let p = Process()
        p.executableURL = path
        p.arguments = [String(seconds)]
        if let home {
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            p.environment = environment
        }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        _ = await waitUntilTrue(within: 5) { await processTable().contains(path.path) }
        return p
    }

    /// A sleep(1) of our own, built into `directory`: not a platform
    /// binary, so `ps -E` shows its environment (HOME), as for Tankard.
    private func buildSleeper(in directory: URL) async throws -> URL {
        let source = directory.appendingPathComponent("sleeper.c")
        let binary = directory.appendingPathComponent("sleeper")
        try "#include <stdlib.h>\n#include <unistd.h>\nint main(int c, char **v) { sleep(c > 1 ? atoi(v[1]) : 60); return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        var environment = ["PATH": "/usr/bin:/bin"]
        environment["DEVELOPER_DIR"] = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        let ran = try await runTool("/usr/bin/cc", ["-o", binary.path, source.path], environment: environment, timeout: 120)
        try #require(ran.status == 0, "cc: \(ran.stderr)")
        return binary
    }

    private func processTable() async -> String {
        (try? await runTool("/bin/ps", ["-axww", "-o", "pid=", "-o", "comm="], environment: ["PATH": "/usr/bin:/bin"]))?.stdout ?? ""
    }

    /// The path launch-check said it kept its copy in.
    private func keptCopy(_ stderr: String) -> URL? {
        guard let r = stderr.range(of: "The copy from before the check is in ") else { return nil }
        let path = stderr[r.upperBound...].prefix { $0 != "\n" }
        return URL(fileURLWithPath: String(path))
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    @Test func anExistingCacheIsPutBackAsItWas() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try FileManager.default.createDirectory(at: f.cache, withIntermediateDirectories: true)
        let original = #"{"written":"before the check"}"#
        try original.write(to: f.cache.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        try "keep".write(to: f.cache.appendingPathComponent("build-times.json"), atomically: true, encoding: .utf8)

        let ran = try await launchCheck(f)
        #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stdout.contains("launch-check: run 1/1 OK"))
        // The launch read the real cache, as a user's does...
        #expect(read(f.mark.appendingPathComponent("seen"))?.trimmingCharacters(in: .whitespacesAndNewlines) == original)
        // ...and what it wrote is gone again.
        #expect(read(f.cache.appendingPathComponent("status.json")) == original)
        #expect(read(f.cache.appendingPathComponent("build-times.json")) == "keep")
        #expect(!FileManager.default.fileExists(atPath: f.cache.appendingPathComponent("insights.json").path))
        // Same switches as before: no TANKARD_*, no background brew update.
        let env = read(f.mark.appendingPathComponent("env")) ?? ""
        #expect(env.contains("HOMEBREW_NO_AUTO_UPDATE=1"))
        #expect(!env.contains("TANKARD_"))
        let pid = try #require(Int32(read(f.mark.appendingPathComponent("pid"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        #expect(!alive(pid))
        // Quit, asked of this pid, ended it; nothing was signalled after.
        #expect(read(f.mark.appendingPathComponent("osascript"))?.contains("runningApplicationWithProcessIdentifier(\(pid))") == true)
        #expect(signals(f) == ["quit"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.directory.path)
            .filter { $0.hasPrefix("tankard-launch-check.") }
        #expect(leftovers.isEmpty)
    }

    @Test func noCacheBeforeMeansNoCacheAfter() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let ran = try await launchCheck(f)
        #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
        #expect(read(f.mark.appendingPathComponent("seen"))?.trimmingCharacters(in: .whitespacesAndNewlines) == "none")
        #expect(!FileManager.default.fileExists(atPath: f.cache.path))
        #expect(try f.workFolders().isEmpty)
    }

    /// 0.9.4 review (round 2): with no cache folder before, the check makes
    /// the folder the app then writes into, and removes only that one. A
    /// folder put in its place during the check (another Tankard's, say)
    /// keeps everything, and the check fails saying so.
    @Test func aReplacedCacheFolderIsLeftAloneWhenThereWasNoneBefore() async throws {
        let f = try makeFixture(mode: "replace")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let ran = try await launchCheck(f)
        #expect(ran.status == 1, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stdout.contains("launch-check: run 1/1 OK"))
        #expect(ran.stderr.contains("did not remove \(f.cache.path): there was none before the check"))
        #expect(ran.stderr.contains("nothing in it was deleted"))
        #expect(read(f.mark.appendingPathComponent("seen"))?.trimmingCharacters(in: .whitespacesAndNewlines) == "none")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.cache.path) == ["mine.txt"])
        #expect(read(f.cache.appendingPathComponent("mine.txt")) == "replacement\n")
        // The folder the check made (moved aside by the stub) is not
        // followed either: what the launch wrote in it is still there.
        let moved = URL(fileURLWithPath: f.cache.path + ".moved")
        #expect(read(moved.appendingPathComponent("status.json"))?.contains("by the launch") == true)
        #expect(try f.workFolders().isEmpty)
    }

    /// The same with a link put where the made folder was: the link and
    /// the folder it points at are left as they are.
    @Test func aLinkInPlaceOfTheMadeCacheFolderIsLeftAlone() async throws {
        let f = try makeFixture(mode: "retarget")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try FileManager.default.createDirectory(at: f.other, withIntermediateDirectories: true)
        try "theirs".write(to: f.other.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        let ran = try await launchCheck(f)
        #expect(ran.status == 1, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stderr.contains("did not remove \(f.cache.path)"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.cache.path) == f.other.path)
        #expect(read(f.other.appendingPathComponent("status.json")) == "theirs")
    }

    /// 0.9.4 review (round 2): a relative TMPDIR. The copy's path is made
    /// absolute before the restore works from inside the cache folder;
    /// before, `$WORK/cache` was then looked up there, the restore failed,
    /// and the cache was left empty.
    @Test func aRelativeTmpdirStillPutsTheCacheBack() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try FileManager.default.createDirectory(at: f.cache, withIntermediateDirectories: true)
        let original = #"{"written":"before the check"}"#
        try original.write(to: f.cache.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        // f.directory, relative to the repo root (where launch-check runs).
        let root = repoRoot.resolvingSymlinksInPath().pathComponents.dropFirst()
        let relative = String(repeating: "../", count: root.count) + String(f.directory.path.dropFirst()) + "/"
        #expect(!relative.hasPrefix("/"))
        var environment = f.environment
        environment["TMPDIR"] = relative
        let ran = try await runTool("/bin/bash", ["Scripts/launch-check.sh", "--app", f.app.path, "--runs", "1", "--seconds", "1"],
                                    environment: environment, timeout: 90)
        #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.cache.path) == ["status.json"])
        #expect(read(f.cache.appendingPathComponent("status.json")) == original)
        #expect(try f.workFolders().isEmpty)
    }

    /// 0.9.4 review (round 2): an app that exits abnormally when told to
    /// quit fails the run, even with no crash report.
    @Test func anAbnormalExitWhenToldToQuitFailsTheCheck() async throws {
        let f = try makeFixture(mode: "abnormal-quit")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let ran = try await launchCheck(f)
        #expect(ran.status == 1, "\(ran.stdout)\n\(ran.stderr)")
        #expect(!ran.stdout.contains("OK"))
        #expect(ran.stderr.contains("launch-check: run 1/1 FAILED (running, then exited 6 when told to quit)"))
        #expect(!FileManager.default.fileExists(atPath: f.reports.path))
        #expect(signals(f) == ["quit"])
        #expect(!FileManager.default.fileExists(atPath: f.cache.path))
        #expect(try f.workFolders().isEmpty)
    }

    /// An app that does not take the Quit is stopped by the fallback
    /// SIGTERM, and that counts as a normal stop (the script's own signal).
    @Test func anAppThatIgnoresQuitIsStoppedBySIGTERMAndPasses() async throws {
        let f = try makeFixture(mode: "ignore-quit")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let ran = try await launchCheck(f)
        #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stdout.contains("launch-check: run 1/1 OK"))
        let pid = try #require(read(f.mark.appendingPathComponent("pid"))?.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(read(f.mark.appendingPathComponent("osascript"))?.contains("runningApplicationWithProcessIdentifier(\(pid))") == true)
        #expect(signals(f) == ["term"])
        #expect(ran.stderr.contains("was still up 5s after the Quit; sent it SIGTERM"))
        #expect(!ran.stderr.contains("SIGKILL"))
        #expect(!FileManager.default.fileExists(atPath: f.cache.path))
    }

    /// 0.9.4 review (round 3): an osascript that stalls (and takes no
    /// notice of its alarm or of SIGTERM) can't hold the check. It is
    /// stopped after 12s at most, and the fallback SIGTERM then stops the
    /// app. Before, the Quit ran unbounded, ahead of the fallback, and the
    /// check waited out the whole 60s stall.
    @Test func aStalledQuitDoesNotHangTheCheckAndTheFallbackRuns() async throws {
        let f = try makeFixture(mode: "stall-quit")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let start = Date()
        let ran = try await launchCheck(f)
        let elapsed = Date().timeIntervalSince(start)
        #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stdout.contains("launch-check: run 1/1 OK"))
        // 1s up, 12s for the osascript, 5s for the app, SIGTERM, 3s for a
        // crash report: well under the stall's 60s.
        #expect(elapsed < 40, "took \(elapsed)s")
        #expect(ran.stderr.contains("the Quit's osascript did not finish within 10s; it was stopped"))
        #expect(ran.stderr.contains("was still up 5s after the Quit; sent it SIGTERM"))
        #expect(signals(f) == ["term"])
        let osa = try #require(Int32(read(f.mark.appendingPathComponent("osapid"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        #expect(!alive(osa))
        #expect(!FileManager.default.fileExists(atPath: f.cache.path))
        #expect(try f.workFolders().isEmpty)
    }

    /// 0.9.4 review (round 3): the app exits on its own while the Quit's
    /// osascript is still running (the instant the old `jobs -rp` check
    /// could miss). Its pid stays reserved, a zombie not yet reaped, until
    /// the check has decided to send it nothing more; it is then reaped
    /// with no SIGTERM or SIGKILL, and the run counts as a normal quit.
    @Test func anAppThatExitsDuringTheQuitIsReapedAndNeverSignalled() async throws {
        let f = try makeFixture(mode: "exit-unasked")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let ran = try await launchCheck(f)
        #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stdout.contains("launch-check: run 1/1 OK"))
        #expect(read(f.mark.appendingPathComponent("exited")) == "self\n")
        // Half a second after it exited, its pid was still its own: a
        // zombie, not reaped while the Quit was under way.
        let state = read(f.mark.appendingPathComponent("state"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(state.hasPrefix("Z"), "process state: '\(state)'")
        #expect(!ran.stderr.contains("SIGTERM"))
        #expect(!ran.stderr.contains("SIGKILL"))
        #expect(signals(f).isEmpty)
        let pid = try #require(Int32(read(f.mark.appendingPathComponent("pid"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        #expect(!alive(pid))
        #expect(!FileManager.default.fileExists(atPath: f.cache.path))
    }

    /// 0.9.4 review (round 3): only the helper signals the app, and only
    /// while it has not reaped it. The script itself has no `kill` and
    /// no `jobs`, and runs no osascript.
    @Test func theScriptLeavesEverySignalToTheSupervisor() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("Scripts/launch-check.sh"), encoding: .utf8)
        let code = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        #expect(code.filter { $0.range(of: #"(^|[\s;&|(])(kill|jobs|osascript)(\s|$)"#, options: .regularExpression) != nil }.isEmpty)
        #expect(text.contains(#"/usr/bin/perl "$HELPER" supervise "$WORK/result" "$WORK/stop""#))
    }

    /// The helper's scripts pass perl's own syntax check.
    @Test func helperPassesPerlSyntaxCheck() async throws {
        let ran = try await runTool("/usr/bin/perl", ["-c", "Scripts/launch-check-helper.pl"], environment: ["PATH": "/usr/bin:/bin"])
        #expect(ran.status == 0, "\(ran.stderr)")
    }

    /// 0.9.4 review (round 3): every build of Tankard shares the cache
    /// folder, so another build running (not only this app) stops the
    /// check before the cache is copied or anything is launched, and that
    /// process is left alone.
    @Test func anotherTankardBuildRunningStopsTheCheck() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try FileManager.default.createDirectory(at: f.cache, withIntermediateDirectories: true)
        let original = #"{"written":"before the check"}"#
        try original.write(to: f.cache.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        let other = try await startSleeper(at: f.otherTankard, home: f.home, target: try await buildSleeper(in: f.directory))
        defer { killNow(other) }
        #expect(other.isRunning)

        let ran = try await launchCheck(f, timeout: 30)
        #expect(ran.status == 1, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stderr.contains("launch-check.sh: another Tankard is running (pid \(other.processIdentifier) \(f.otherTankard.path))"))
        #expect(!FileManager.default.fileExists(atPath: f.mark.appendingPathComponent("pid").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.cache.path) == ["status.json"])
        #expect(read(f.cache.appendingPathComponent("status.json")) == original)
        #expect(try f.workFolders().isEmpty)
        #expect(other.isRunning)
        await stop(other)
    }

    /// The same for a `swift run TankardApp` build (`.build/…/TankardApp`,
    /// not in a bundle): same bundle id, same cache folder.
    @Test func aSwiftRunBuildRunningStopsTheCheck() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let path = f.directory.appendingPathComponent("pkg/.build/debug/TankardApp")
        let other = try await startSleeper(at: path, home: f.home, target: try await buildSleeper(in: f.directory))
        defer { killNow(other) }

        let ran = try await launchCheck(f, timeout: 30)
        #expect(ran.status == 1, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stderr.contains("launch-check.sh: another Tankard is running (pid \(other.processIdentifier) \(path.path))"))
        #expect(!FileManager.default.fileExists(atPath: f.mark.appendingPathComponent("pid").path))
        #expect(!FileManager.default.fileExists(atPath: f.cache.path))
        #expect(try f.workFolders().isEmpty)
        #expect(other.isRunning)
        await stop(other)
    }

    /// A Tankard of another HOME (the Mac's own, while a test runs under a
    /// throwaway one) has its own cache folder: it does not stop the check,
    /// and is left alone.
    @Test func aTankardOfAnotherHomeDoesNotStopTheCheck() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let elsewhere = f.directory.appendingPathComponent("elsewhere-home")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let other = try await startSleeper(at: f.otherTankard, home: elsewhere, target: try await buildSleeper(in: f.directory))
        defer { killNow(other) }

        let ran = try await launchCheck(f)
        #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stdout.contains("launch-check: run 1/1 OK"))
        #expect(other.isRunning)
        await stop(other)
    }

    /// One whose environment can't be read (here a platform binary, which
    /// `ps -E` shows without it) may share the cache, so it counts.
    @Test func aTankardWhoseHomeCantBeReadStopsTheCheck() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let elsewhere = f.directory.appendingPathComponent("elsewhere-home")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let other = try await startSleeper(at: f.otherTankard, home: elsewhere)
        defer { killNow(other) }

        let ran = try await launchCheck(f, timeout: 30)
        #expect(ran.status == 1, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stderr.contains("launch-check.sh: another Tankard is running (pid \(other.processIdentifier) "))
        #expect(!FileManager.default.fileExists(atPath: f.mark.appendingPathComponent("pid").path))
        #expect(other.isRunning)
        await stop(other)
    }

    /// 0.9.4 review (round 3): another Tankard that starts during the check
    /// writes into the same folder, so nothing in it is deleted at the end:
    /// the check fails, saying so, and keeps the copy.
    @Test func aTankardStartedDuringTheCheckKeepsTheCacheAndTheCopy() async throws {
        let f = try makeFixture(mode: "start-other")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try FileManager.default.createDirectory(at: f.otherTankard.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.otherTankard, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        try FileManager.default.createDirectory(at: f.cache, withIntermediateDirectories: true)
        let original = #"{"written":"before the check"}"#
        try original.write(to: f.cache.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)

        let ran = try await launchCheck(f)
        let otherPid = Int32(read(f.mark.appendingPathComponent("otherpid"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        defer { if let otherPid { kill(otherPid, SIGKILL) } }
        #expect(ran.status == 1, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stdout.contains("launch-check: run 1/1 OK"))
        #expect(ran.stderr.contains("did not put back \(f.cache.path): another Tankard is running"))
        #expect(ran.stderr.contains("nothing in it was deleted"))
        let otherRunning = try #require(otherPid)
        #expect(alive(otherRunning))
        // What the launch wrote is still there; the copy has what was before.
        #expect(read(f.cache.appendingPathComponent("status.json"))?.contains("by the launch") == true)
        let copy = try #require(keptCopy(ran.stderr))
        #expect(read(copy.appendingPathComponent("status.json")) == original)
    }

    /// 0.9.4 review (round 3): the helper makes the cache folder as one
    /// step. Something already there (a folder, a link) is never taken for
    /// the folder it made, and is left as it is; the id it prints is the
    /// folder at that path, empty, with the usual mode.
    @Test func theCacheFolderIsMadeInOneStep() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let parent = f.directory.appendingPathComponent("caches")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        func mkcache(_ url: URL) async throws -> Ran {
            try await runTool("/bin/sh", ["-c", "umask 022; exec /usr/bin/perl Scripts/launch-check-helper.pl mkcache \"$1\"", "sh", url.path],
                              environment: ["PATH": "/usr/bin:/bin"], timeout: 30)
        }
        let made = parent.appendingPathComponent("made")
        let ran = try await mkcache(made)
        #expect(ran.status == 0, "\(ran.stderr)")
        let attrs = try FileManager.default.attributesOfItem(atPath: made.path)
        #expect(attrs[.type] as? FileAttributeType == .typeDirectory)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        let dev = (attrs[.systemNumber] as? NSNumber)?.intValue ?? -1
        let ino = (attrs[.systemFileNumber] as? NSNumber)?.intValue ?? -1
        #expect(ran.stdout == "\(dev):\(ino)\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: made.path).isEmpty)

        let existing = parent.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "theirs".write(to: existing.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        let emptyExisting = parent.appendingPathComponent("empty-existing")
        try FileManager.default.createDirectory(at: emptyExisting, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        for url in [existing, emptyExisting, link] {
            let r = try await mkcache(url)
            #expect(r.status == 1, "\(url.lastPathComponent): \(r.stdout)")
            #expect(r.stdout.isEmpty)
            #expect(r.stderr.contains("it appeared meanwhile"), "\(url.lastPathComponent): \(r.stderr)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path) == ["keep.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: emptyExisting.path).isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == existing.path)
        // No private folder left behind next to them.
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() == ["empty-existing", "existing", "link", "made"])
    }

    /// The cache folder can be a symlink (this build Mac keeps it on another
    /// volume). The link stays a link to the same place, and what it points
    /// at gets its old contents back.
    @Test func aSymlinkedCacheFolderStaysALink() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let target = f.directory.appendingPathComponent("elsewhere/net.mindtricks.tankard")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let original = #"{"written":"before the check"}"#
        try original.write(to: target.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.cache, withDestinationURL: target)

        let ran = try await launchCheck(f)
        #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
        #expect(read(f.mark.appendingPathComponent("seen"))?.trimmingCharacters(in: .whitespacesAndNewlines) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.cache.path) == target.path)
        #expect(read(target.appendingPathComponent("status.json")) == original)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("insights.json").path))
    }

    /// A link to nowhere (the volume is not mounted): nothing is launched,
    /// and the link is left alone.
    @Test func aBrokenCacheLinkStopsTheCheckBeforeAnyLaunch() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let missing = f.directory.appendingPathComponent("unmounted/net.mindtricks.tankard")
        try FileManager.default.createDirectory(at: f.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.cache, withDestinationURL: missing)

        let ran = try await launchCheck(f)
        #expect(ran.status == 1)
        #expect(ran.stderr.contains("is not a folder (or its link is broken); nothing was launched"))
        #expect(!FileManager.default.fileExists(atPath: f.mark.appendingPathComponent("pid").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.cache.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    /// Stopped mid-run (a cancelled CI job, Ctrl-C): the app is killed first,
    /// then the cache goes back, so the app can't write after the restore.
    @Test func anInterruptedCheckStillPutsTheCacheBack() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try FileManager.default.createDirectory(at: f.cache, withIntermediateDirectories: true)
        let original = #"{"written":"before the check"}"#
        try original.write(to: f.cache.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["Scripts/launch-check.sh", "--app", f.app.path, "--runs", "1", "--seconds", "60"]
        p.currentDirectoryURL = repoRoot
        p.environment = f.environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { killNow(p) }

        // Wait for the stub to have rewritten the cache (its last step).
        let seen = f.mark.appendingPathComponent("seen")
        _ = await waitUntilTrue(within: 30) { FileManager.default.fileExists(atPath: seen.path) }
        try #require(FileManager.default.fileExists(atPath: seen.path))
        #expect(read(f.cache.appendingPathComponent("status.json"))?.contains("by the launch") == true)
        let pid = try #require(Int32(read(f.mark.appendingPathComponent("pid"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))

        p.terminate()
        _ = await waitUntilTrue(within: 30) { !p.isRunning }
        try #require(!p.isRunning)
        #expect(p.terminationStatus == 143)
        #expect(!alive(pid))
        #expect(read(f.cache.appendingPathComponent("status.json")) == original)
        #expect(!FileManager.default.fileExists(atPath: f.cache.appendingPathComponent("insights.json").path))
    }

    /// 0.9.4 review: a crash while quitting (a report for the launched pid
    /// written as it handles Quit) fails the run. Before, the pid was
    /// cleared before the reports were matched, so this printed OK.
    @Test func aCrashWhileQuittingFailsTheCheck() async throws {
        let f = try makeFixture(mode: "crash-on-quit")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let ran = try await launchCheck(f)
        let report = f.reports.appendingPathComponent("Tankard-2026-11-25-120000.ips")
        let pid = try #require(read(f.mark.appendingPathComponent("pid"))?.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(read(report)?.contains(#""pid" : \#(pid),"#) == true)
        #expect(ran.status == 1, "\(ran.stdout)\n\(ran.stderr)")
        #expect(!ran.stdout.contains("OK"))
        #expect(ran.stderr.contains("launch-check: run 1/1 FAILED (running, new report: \(report.path)"))
        #expect(signals(f) == ["quit"])
        #expect(!FileManager.default.fileExists(atPath: f.cache.path))
        #expect(try f.workFolders().isEmpty)
    }

    /// 0.9.4 review: the cache folder replaced by another one during the
    /// check. Nothing in the new folder is deleted; the copy is kept, and
    /// the check fails saying where it is.
    @Test func aReplacedCacheFolderIsLeftAloneAndTheCopyKept() async throws {
        let f = try makeFixture(mode: "replace")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try FileManager.default.createDirectory(at: f.cache, withIntermediateDirectories: true)
        let original = #"{"written":"before the check"}"#
        try original.write(to: f.cache.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)

        let ran = try await launchCheck(f)
        #expect(ran.status == 1, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stdout.contains("launch-check: run 1/1 OK"))
        #expect(ran.stderr.contains("did not put back \(f.cache.path)"))
        #expect(ran.stderr.contains("nothing in it was deleted"))
        // The replacement is as the launch left it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.cache.path) == ["mine.txt"])
        #expect(read(f.cache.appendingPathComponent("mine.txt")) == "replacement\n")
        let moved = URL(fileURLWithPath: f.cache.path + ".moved")
        #expect(read(moved.appendingPathComponent("status.json"))?.contains("by the launch") == true)
        // The copy is where it says, with the contents from before.
        let copy = try #require(keptCopy(ran.stderr))
        #expect(copy.path.hasPrefix(f.directory.path))
        #expect(read(copy.appendingPathComponent("status.json")) == original)
    }

    /// 0.9.4 review: the cache link pointed somewhere else during the
    /// check. The other folder keeps what it had, the link stays as it now
    /// is, and the copy is kept.
    @Test func aRetargetedCacheLinkIsLeftAloneAndTheCopyKept() async throws {
        let f = try makeFixture(mode: "retarget")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let target = f.directory.appendingPathComponent("elsewhere/net.mindtricks.tankard")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let original = #"{"written":"before the check"}"#
        try original.write(to: target.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.other, withIntermediateDirectories: true)
        try "theirs".write(to: f.other.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        try "theirs too".write(to: f.other.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.cache, withDestinationURL: target)

        let ran = try await launchCheck(f)
        #expect(ran.status == 1, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stderr.contains("did not put back \(f.cache.path)"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.cache.path) == f.other.path)
        #expect(read(f.other.appendingPathComponent("status.json")) == "theirs")
        #expect(read(f.other.appendingPathComponent("keep.txt")) == "theirs too")
        let copy = try #require(keptCopy(ran.stderr))
        #expect(read(copy.appendingPathComponent("status.json")) == original)
    }

    /// 0.9.4 review: `--runs` and `--seconds` take whole numbers from 1 up,
    /// and a bad one stops the check before the cache is copied or
    /// anything is launched. Before, `--runs 0` ran nothing and exited 0.
    @Test func badRunsOrSecondsStopTheCheckBeforeAnything() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try FileManager.default.createDirectory(at: f.cache, withIntermediateDirectories: true)
        let original = #"{"written":"before the check"}"#
        try original.write(to: f.cache.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        let cases: [(String, String)] = [("--runs", "0"), ("--runs", "abc"), ("--runs", "1.5"), ("--runs", "-1"),
                                         ("--runs", ""), ("--seconds", "0"), ("--seconds", "abc"), ("--seconds", "007")]
        for (option, value) in cases {
            var args = ["Scripts/launch-check.sh", "--app", f.app.path, "--runs", "1", "--seconds", "2"]
            args += [option, value]
            let ran = try await runTool("/bin/bash", args, environment: f.environment, timeout: 30)
            #expect(ran.status == 2, "\(option) '\(value)': \(ran.stdout)\n\(ran.stderr)")
            #expect(ran.stderr.contains("launch-check.sh: \(option) needs a whole number of at least 1, not '\(value)'"))
            #expect(!ran.stdout.contains("launch-check: run"))
        }
        #expect(!FileManager.default.fileExists(atPath: f.mark.appendingPathComponent("pid").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.cache.path) == ["status.json"])
        #expect(read(f.cache.appendingPathComponent("status.json")) == original)
        #expect(try f.workFolders().isEmpty)
    }

    /// 0.9.4 review: another program whose path only starts like this
    /// app's (`Stub1app/…/Tankard-helper` against `Stub.app/…/Tankard`, a
    /// match for the old `^path` pattern) neither stops the check nor gets
    /// killed by it.
    @Test func aLookalikePathIsNotThisAppAndIsNotKilled() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let lookalike = f.directory.appendingPathComponent("Stub1app/Contents/MacOS/Tankard-helper")
        let other = try await startSleeper(at: lookalike)
        defer { killNow(other) }
        #expect(other.isRunning)

        let ran = try await launchCheck(f)
        #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stdout.contains("launch-check: run 1/1 OK"))
        #expect(other.isRunning)
        await stop(other)
    }

    /// The same app already running stops the check before anything, and
    /// that process is left alone.
    @Test func theSameAppAlreadyRunningStopsTheCheck() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let app = f.directory.appendingPathComponent("Running.app")
        let running = try await startSleeper(at: app.appendingPathComponent("Contents/MacOS/Tankard"))
        defer { killNow(running) }
        #expect(running.isRunning)

        let ran = try await runTool("/bin/bash", ["Scripts/launch-check.sh", "--app", app.path, "--runs", "1", "--seconds", "2"],
                                    environment: f.environment, timeout: 30)
        #expect(ran.status == 1, "\(ran.stdout)\n\(ran.stderr)")
        #expect(ran.stderr.contains("is already running; quit it first"))
        #expect(running.isRunning)
        #expect(try f.workFolders().isEmpty)
        await stop(running)
    }

    @Test func launchCheckHelpDescribesTheCacheAndTheOrder() async throws {
        let ran = try await runTool("/bin/bash", ["Scripts/launch-check.sh", "--help"], environment: ["PATH": "/usr/bin:/bin"])
        #expect(ran.status == 0)
        #expect(ran.stdout.contains("back as it found it (0.9.4)"))
        #expect(ran.stdout.hasSuffix("# for a later launch.\n"))
        let text = try String(contentsOf: repoRoot.appendingPathComponent("Scripts/launch-check.sh"), encoding: .utf8)
        #expect(text.contains("release.sh runs it on the notarized, stapled app (0.9.4"))
        #expect(!text.contains("release.sh runs it on the signed app before notarizing"))
        // The real launch is unchanged: no demo, no snapshot, real brew.
        #expect(text.contains(#"for v in $(env | sed -n 's/^\(TANKARD_[A-Z_]*\)=.*/\1/p'); do ENV_CLEAN+=(-u "$v"); done"#))
        #expect(!text.contains("sandbox-exec"))
    }
}
