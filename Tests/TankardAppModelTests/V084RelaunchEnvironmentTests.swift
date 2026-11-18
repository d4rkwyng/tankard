import Foundation
import Testing
@testable import TankardAppModel

// 0.8.4: what the relaunch helper (and `open -n`) passes to the new copy.

@MainActor
struct V084RelaunchEnvironmentTests {
    static let base = ["HOME": "/Users/t", "PATH": "/usr/bin:/bin", "HOMEBREW_NO_AUTO_UPDATE": "1",
                       "HOMEBREW_CASK_OPTS": "--appdir=/Applications", "LANG": "de_DE.UTF-8"]

    @Test func normalRunDropsEveryTankardVariableAndKeepsTheRest() {
        var env = Self.base
        for k in ["TANKARD_DEMO", "TANKARD_DEMO_PACE", "TANKARD_SNAPSHOT", "TANKARD_SNAPSHOT_QUIT",
                  "TANKARD_UPDATE_FEED", "TANKARD_LOG_TIMING", "TANKARD_APPEARANCE", "TANKARD_BREW"] { env[k] = "x" }
        let r = AppManagement.relaunchEnvironment(env)
        #expect(r.environment == Self.base)
        #expect(r.note == nil && r.scriptPath == nil)
    }

    @Test func scriptWithoutE2ESwitchIsNotAnE2ERun() {
        var env = Self.base
        env["TANKARD_SCRIPT"] = "/o/A/steps.txt"
        env["TANKARD_E2E_SUITE"] = "net.mindtricks.tankard.e2e.123"
        let r = AppManagement.relaunchEnvironment(env)
        #expect(r.environment == Self.base)
        #expect(r.note == nil)
    }

    @Test func e2eRunGetsOnlyAnIdleIsolatedIdentity() {
        var env = Self.base
        env["TANKARD_E2E"] = "1"
        env["TANKARD_E2E_SUITE"] = "net.mindtricks.tankard.e2e.4711"
        env["TANKARD_E2E_STATE"] = "/o/A/state"
        env["TANKARD_E2E_SELFUPDATE"] = "1"
        env["TANKARD_E2E_SELF_TAP"] = "tankard-e2e-self/tap"
        env["TANKARD_SCRIPT"] = "/o/A/steps.txt"
        env["TANKARD_SCRIPT_OUT"] = "/o/A"
        env["TANKARD_UPDATE_FEED"] = "/o/feed.json"
        env["TANKARD_E2E_BACKGROUND"] = "1"
        env["TANKARD_DEMO"] = "intelbrew"
        let r = AppManagement.relaunchEnvironment(env)
        var want = Self.base
        want["TANKARD_E2E"] = "1"
        want["TANKARD_E2E_SUITE"] = "net.mindtricks.tankard.e2e.4711"
        want["TANKARD_E2E_STATE"] = "/o/A/state"
        want["TANKARD_E2E_SELFUPDATE"] = "1"
        want["TANKARD_E2E_SELF_TAP"] = "tankard-e2e-self/tap"
        want["TANKARD_SCRIPT_OUT"] = "/o/A/relaunched"
        want["TANKARD_SCRIPT"] = "/o/A/relaunched/steps.txt"
        want["TANKARD_SCRIPT_STAY"] = "1"
        #expect(r.environment == want)
        #expect(r.scriptPath == "/o/A/relaunched/steps.txt")
        #expect(r.note == nil)
    }

    @Test func e2eDefaultsFollowScriptLaunch() {
        // No TANKARD_SCRIPT_OUT/STATE: ScriptLaunch's <script>.out and <out>/state.
        var env = Self.base
        env["TANKARD_E2E"] = "1"
        env["TANKARD_E2E_SUITE"] = "net.mindtricks.tankard.e2e.9"
        env["TANKARD_SCRIPT"] = "/o/s.txt"
        let e = AppManagement.relaunchEnvironment(env).environment
        #expect(e["TANKARD_E2E_STATE"] == "/o/s.txt.out/state")
        #expect(e["TANKARD_SCRIPT_OUT"] == "/o/s.txt.out/relaunched")
        #expect(e["TANKARD_SCRIPT"] == "/o/s.txt.out/relaunched/steps.txt")
        #expect(e["TANKARD_E2E_SELFUPDATE"] == nil)
    }

    @Test(arguments: [nil, "", "net.mindtricks.tankard", "net.mindtricks.tankard.e2e", "net.mindtricks.tankard.e2e.",
                      "com.example.e2e.1", "net.mindtricks.tankard.e2e.a/b", "net.mindtricks.tankard.e2ex"])
    func invalidSuiteGivesNoE2EIdentityAndANote(suite: String?) {
        var env = Self.base
        env["TANKARD_E2E"] = "1"
        env["TANKARD_SCRIPT"] = "/o/A/steps.txt"
        env["TANKARD_E2E_STATE"] = "/o/A/state"
        if let suite { env["TANKARD_E2E_SUITE"] = suite }
        let r = AppManagement.relaunchEnvironment(env)
        #expect(r.environment == Self.base)
        #expect(r.scriptPath == nil)
        #expect(r.note?.hasPrefix("relaunch: e2e identity dropped (invalid TANKARD_E2E_SUITE") == true)
    }

    @Test func validSuiteRule() {
        #expect(AppManagement.validE2ESuite("net.mindtricks.tankard.e2e.123") == "net.mindtricks.tankard.e2e.123")
        #expect(AppManagement.validE2ESuite("net.mindtricks.tankard.e2e.selfupd") != nil)
        #expect(AppManagement.validE2ESuite("net.mindtricks.tankard") == nil)
        #expect(AppManagement.validE2ESuite("net.mindtricks.tankard.e2e") == nil)
    }

    @Test func prepareCreatesAnEmptyStepFileOnceAndAnEmptyScriptParses() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var env = Self.base
        env["TANKARD_E2E"] = "1"
        env["TANKARD_E2E_SUITE"] = "net.mindtricks.tankard.e2e.1"
        env["TANKARD_SCRIPT"] = dir.appendingPathComponent("steps.txt").path
        env["TANKARD_SCRIPT_OUT"] = dir.path
        let r = AppManagement.relaunchEnvironment(env)
        try AppManagement.prepareRelaunchScript(r)
        let path = try #require(r.scriptPath)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "")
        #expect(try ScriptParser.parse("").isEmpty)
        try "expect-ready\n".write(toFile: path, atomically: true, encoding: .utf8)
        try AppManagement.prepareRelaunchScript(r)   // an existing file is kept
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "expect-ready\n")
        try AppManagement.prepareRelaunchScript(AppManagement.relaunchEnvironment(Self.base)) // no-op
    }
}
