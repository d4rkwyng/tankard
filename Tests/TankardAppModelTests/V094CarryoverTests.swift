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

/// Runs `executable` from the repo root with exactly `environment`, killing
/// it after `timeout` seconds rather than hanging the test run.
private func runTool(_ executable: String, _ arguments: [String], environment: [String: String],
                     timeout: TimeInterval = 60) throws -> Ran {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    p.currentDirectoryURL = repoRoot
    p.environment = environment
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    // Drain both pipes while it runs, so a chatty script can't block.
    let outBox = DataBox(), errBox = DataBox()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { outBox.set(out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
    group.enter()
    DispatchQueue.global().async { errBox.set(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    p.waitUntilExit()
    killer.cancel()
    group.wait()
    return Ran(status: p.terminationStatus,
               stdout: String(data: outBox.get(), encoding: .utf8) ?? "",
               stderr: String(data: errBox.get(), encoding: .utf8) ?? "")
}

/// One pipe's bytes, handed from the reading queue to the test.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.withLock { data = d } }
    func get() -> Data { lock.withLock { data } }
}

struct V094ReleaseOrderTests {
    /// `release.sh --dry-run` with a placeholder identity and no notary or
    /// version settings from the caller's environment.
    private func dryRun(_ extra: [String]) throws -> Ran {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tankard-v094-dry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        return try runTool("/bin/bash", ["Scripts/release.sh", "--dry-run"] + extra, environment: [
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

    @Test func defaultRunLaunchChecksTheStapledAcceptedAppRightBeforeTheZip() throws {
        let ran = try dryRun([])
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

    @Test func skipNotarizeLaunchChecksTheSignedVerifiedAppBeforeTheZip() throws {
        let ran = try dryRun(["--skip-notarize"])
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

    @Test func skipLaunchCheckLaunchesNothingAndSaysWhichApp() throws {
        let stapled = try dryRun(["--skip-launch-check"])
        #expect(stapled.status == 0)
        #expect(!commands(stapled).contains { $0.contains("launch-check") })
        #expect(stapled.stderr.contains("NOTE: --skip-launch-check: the stapled app was not launched. Run Scripts/launch-check.sh dist/Tankard.app before publishing."))
        #expect(commands(stapled).last == finalZip)

        let signed = try dryRun(["--skip-notarize", "--skip-launch-check"])
        #expect(signed.status == 0)
        #expect(!commands(signed).contains { $0.contains("launch-check") })
        #expect(signed.stderr.contains("NOTE: --skip-launch-check: the signed app was not launched."))
        #expect(commands(signed).last == finalZip)
    }

    /// The source, so a dry run's order can't drift from the real one: one
    /// helper, called once on each path, each time right before a zip.
    @Test func releaseScriptCallsTheCheckOnlyBeforeEachFinalZip() throws {
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
        let help = try runTool("/bin/bash", ["Scripts/release.sh", "--help"], environment: ["PATH": "/usr/bin:/bin"])
        #expect(help.status == 0)
        #expect(help.stdout.hasSuffix("runtime). No App Sandbox, because brew can't run inside one.\n"))
        #expect(!help.stdout.contains("set -euo pipefail"))
    }

    @Test func scriptsPassBashSyntaxCheck() throws {
        for script in ["Scripts/release.sh", "Scripts/launch-check.sh", "Scripts/smoke-launch.sh"] {
            let ran = try runTool("/bin/bash", ["-n", script], environment: ["PATH": "/usr/bin:/bin"])
            #expect(ran.status == 0, "\(script): \(ran.stderr)")
        }
    }
}

/// launch-check.sh against a stub `Tankard` (a shell script) under a temp
/// HOME. The stub records what cache it saw and its environment, then
/// rewrites the cache the way a real launch would, and sleeps until killed.
struct V094LaunchCheckCacheTests {
    private struct Fixture {
        var directory: URL
        var home: URL
        var app: URL
        var mark: URL
        var cache: URL { home.appendingPathComponent("Library/Caches/net.mindtricks.tankard") }
        var environment: [String: String] {
            ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": directory.path + "/",
             "STUB_MARK": mark.path, "TANKARD_DEMO": "1"]
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tankard-v094-lc-\(UUID().uuidString)")
        let home = directory.appendingPathComponent("home")
        let mark = directory.appendingPathComponent("mark")
        let macOS = directory.appendingPathComponent("Stub.app/Contents/MacOS")
        for d in [home, mark, macOS] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let stub = """
            #!/bin/sh
            c="$HOME/Library/Caches/net.mindtricks.tankard"
            if [ -f "$c/status.json" ]; then cat "$c/status.json" > "$STUB_MARK/seen.tmp"; else echo none > "$STUB_MARK/seen.tmp"; fi
            /usr/bin/env > "$STUB_MARK/env"
            echo $$ > "$STUB_MARK/pid"
            mkdir -p "$c"
            echo '{"written":"by the launch"}' > "$c/status.json"
            echo '{}' > "$c/insights.json"
            mv "$STUB_MARK/seen.tmp" "$STUB_MARK/seen"
            exec /bin/sleep 120
            """
        let bin = macOS.appendingPathComponent("Tankard")
        try stub.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return Fixture(directory: directory, home: home, app: directory.appendingPathComponent("Stub.app"), mark: mark)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    @Test func anExistingCacheIsPutBackAsItWas() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try FileManager.default.createDirectory(at: f.cache, withIntermediateDirectories: true)
        let original = #"{"written":"before the check"}"#
        try original.write(to: f.cache.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        try "keep".write(to: f.cache.appendingPathComponent("build-times.json"), atomically: true, encoding: .utf8)

        let ran = try runTool("/bin/bash", ["Scripts/launch-check.sh", "--app", f.app.path, "--runs", "1", "--seconds", "2"],
                              environment: f.environment, timeout: 90)
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
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.directory.path)
            .filter { $0.hasPrefix("tankard-launch-check.") }
        #expect(leftovers.isEmpty)
    }

    @Test func noCacheBeforeMeansNoCacheAfter() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let ran = try runTool("/bin/bash", ["Scripts/launch-check.sh", "--app", f.app.path, "--runs", "1", "--seconds", "2"],
                              environment: f.environment, timeout: 90)
        #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
        #expect(read(f.mark.appendingPathComponent("seen"))?.trimmingCharacters(in: .whitespacesAndNewlines) == "none")
        #expect(!FileManager.default.fileExists(atPath: f.cache.path))
    }

    /// The cache folder can be a symlink (this build Mac keeps it on another
    /// volume). The link stays a link to the same place, and what it points
    /// at gets its old contents back.
    @Test func aSymlinkedCacheFolderStaysALink() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let target = f.directory.appendingPathComponent("elsewhere/net.mindtricks.tankard")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let original = #"{"written":"before the check"}"#
        try original.write(to: target.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.cache, withDestinationURL: target)

        let ran = try runTool("/bin/bash", ["Scripts/launch-check.sh", "--app", f.app.path, "--runs", "1", "--seconds", "2"],
                              environment: f.environment, timeout: 90)
        #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
        #expect(read(f.mark.appendingPathComponent("seen"))?.trimmingCharacters(in: .whitespacesAndNewlines) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.cache.path) == target.path)
        #expect(read(target.appendingPathComponent("status.json")) == original)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("insights.json").path))
    }

    /// A link to nowhere (the volume is not mounted): nothing is launched,
    /// and the link is left alone.
    @Test func aBrokenCacheLinkStopsTheCheckBeforeAnyLaunch() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let missing = f.directory.appendingPathComponent("unmounted/net.mindtricks.tankard")
        try FileManager.default.createDirectory(at: f.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.cache, withDestinationURL: missing)

        let ran = try runTool("/bin/bash", ["Scripts/launch-check.sh", "--app", f.app.path, "--runs", "1", "--seconds", "2"],
                              environment: f.environment, timeout: 90)
        #expect(ran.status == 1)
        #expect(ran.stderr.contains("is not a folder (or its link is broken); nothing was launched"))
        #expect(!FileManager.default.fileExists(atPath: f.mark.appendingPathComponent("pid").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.cache.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    /// Stopped mid-run (a cancelled CI job, Ctrl-C): the app is killed first,
    /// then the cache goes back, so the app can't write after the restore.
    @Test func anInterruptedCheckStillPutsTheCacheBack() throws {
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
        defer { if p.isRunning { p.interrupt(); p.waitUntilExit() } }

        // Wait for the stub to have rewritten the cache (its last step).
        let seen = f.mark.appendingPathComponent("seen")
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: seen.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try #require(FileManager.default.fileExists(atPath: seen.path))
        #expect(read(f.cache.appendingPathComponent("status.json"))?.contains("by the launch") == true)
        let pid = try #require(Int32(read(f.mark.appendingPathComponent("pid"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))

        p.terminate()
        let stop = Date().addingTimeInterval(30)
        while p.isRunning, Date() < stop { Thread.sleep(forTimeInterval: 0.05) }
        try #require(!p.isRunning)
        #expect(p.terminationStatus == 143)
        #expect(!alive(pid))
        #expect(read(f.cache.appendingPathComponent("status.json")) == original)
        #expect(!FileManager.default.fileExists(atPath: f.cache.appendingPathComponent("insights.json").path))
    }

    @Test func launchCheckHelpDescribesTheCacheAndTheOrder() throws {
        let ran = try runTool("/bin/bash", ["Scripts/launch-check.sh", "--help"], environment: ["PATH": "/usr/bin:/bin"])
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
