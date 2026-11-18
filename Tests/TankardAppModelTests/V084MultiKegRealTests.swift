import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.4: Uninstall of a formula with two kegs against this Mac's REAL brew,
// through Tankard's own store, queue and session. Off unless asked for:
//
//   TANKARD_REAL_MULTIKEG=1 Scripts/test.sh --filter V084MultiKegRealTests
//
// It makes a throwaway tap (a local file:// git repo, as Scripts/e2e.sh's
// restore scenario does), `tankard-mk/probe`, with a one-script formula at
// 1.0, installs it, moves the tap to 1.1 and upgrades with
// HOMEBREW_NO_INSTALL_CLEANUP (two kegs, as "Keep the previous version"
// leaves them). Then: Uninstall, and (pinned, two kegs again) Unpin and
// Uninstall. Each must leave `brew list --versions` empty. The tap is
// untrusted and removed afterwards, whatever happened. Skips (fails the
// precondition) if the tap or formula already exists.

@MainActor
@Suite(.serialized)
struct V084MultiKegRealTests {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let tap = "tankard-mk/probe"
    static let formula = "tankard-mk-probe"
    static var qualified: String { "\(tap)/\(formula)" }
    static let brewPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"

    nonisolated static func run(_ exe: String, _ args: [String], cwd: URL? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                         "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1",
                         "HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_ENV_HINTS": "1",
                         "HOMEBREW_NO_ANALYTICS": "1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    static func brew(_ args: [String]) -> (Int32, String) { run(brewPath, args) }
    static func git(_ dir: URL, _ args: [String]) -> (Int32, String) {
        run("/usr/bin/git", ["-C", dir.path, "-c", "user.name=tankard-test", "-c", "user.email=test@localhost"] + args)
    }

    /// `brew list --versions <formula>`: the versions, [] when not installed.
    static func versions() -> [String] {
        let (code, out) = brew(["list", "--versions", "--formula", formula])
        guard code == 0 else { return [] }
        return out.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
    }

    static func formulaSource(_ work: URL, _ v: String) throws -> String {
        let tarball = work.appendingPathComponent("\(formula)-\(v).tar.gz")
        let sha = run("/usr/bin/shasum", ["-a", "256", tarball.path]).1.split(separator: " ").first.map(String.init) ?? ""
        return """
        class TankardMkProbe < Formula
          desc "Throwaway formula for Tankard's multi-keg uninstall test"
          homepage "https://github.com/d4rkwyng/tankard"
          url "file://\(tarball.path)"
          sha256 "\(sha)"
          license "MIT"

          def install
            bin.install "\(formula)"
          end
        end

        """
    }

    /// Installs 1.0, then upgrades to 1.1 keeping 1.0: two kegs.
    static func makeTwoKegs(_ work: URL, tapDir: URL) throws {
        let f = tapDir.appendingPathComponent("Formula/\(formula).rb")
        try formulaSource(work, "1.0").write(to: f, atomically: true, encoding: .utf8)
        #expect(git(tapDir, ["commit", "-qam", "probe 1.0", "--allow-empty"]).0 == 0)
        let i = brew(["install", "--formula", qualified])
        #expect(i.0 == 0, "install 1.0: \(i.1)")
        try formulaSource(work, "1.1").write(to: f, atomically: true, encoding: .utf8)
        #expect(git(tapDir, ["commit", "-qam", "probe 1.1"]).0 == 0)
        let u = brew(["upgrade", "--formula", qualified])
        #expect(u.0 == 0, "upgrade 1.1: \(u.1)")
        #expect(Set(versions()) == ["1.0", "1.1"], "two kegs")
    }

    func liveStore() -> AppStore {
        let deps = AppStore.Dependencies(makeClient: { try BrewClient.locate(override: nil) },
                                         streamRunner: StreamingProcessRunner(), cache: nil, logURL: nil)
        return AppStore(deps: deps, settings: testSettings())
    }

    func finishedUninstall(_ store: AppStore) async throws -> UpgradeSession {
        #expect(await waitUntil(timeout: .seconds(120)) { store.upgrade?.isFinished == true && store.upgrade?.checkingInstalled == false })
        let s = try #require(store.upgrade)
        print("multikeg-real: \(s.title) · \(s.statusLine)\n" + s.log.lines.joined(separator: "\n"))
        return s
    }

    @Test(.enabled(if: env["TANKARD_REAL_MULTIKEG"] != nil), .timeLimit(.minutes(10)))
    func uninstallRemovesEveryKeg() async throws {
        let repo = Self.brew(["--repository"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
        let tapsDir = URL(fileURLWithPath: repo).appendingPathComponent("Library/Taps/tankard-mk")
        try #require(!FileManager.default.fileExists(atPath: tapsDir.path), "\(tapsDir.path) already exists")
        try #require(Self.versions().isEmpty, "\(Self.formula) is already installed")

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-multikeg-\(UUID().uuidString)")
        let tapRepo = work.appendingPathComponent("tap")
        defer {
            if !Self.versions().isEmpty { _ = Self.brew(["uninstall", "--force", "--formula", Self.formula]) }
            if FileManager.default.fileExists(atPath: tapsDir.appendingPathComponent("homebrew-probe").path) {
                _ = Self.brew(["untrust", "--tap", Self.tap])
                _ = Self.brew(["untap", Self.tap])
            }
            try? FileManager.default.removeItem(at: work)
        }
        try FileManager.default.createDirectory(at: tapRepo.appendingPathComponent("Formula"), withIntermediateDirectories: true)
        for v in ["1.0", "1.1"] {
            let src = work.appendingPathComponent("src/\(Self.formula)-\(v)")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            let script = src.appendingPathComponent(Self.formula)
            try "#!/bin/sh\necho \"tankard multikeg probe \(v)\"\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            #expect(Self.run("/usr/bin/tar", ["-C", work.appendingPathComponent("src").path, "-czf",
                                              work.appendingPathComponent("\(Self.formula)-\(v).tar.gz").path, "\(Self.formula)-\(v)"]).0 == 0)
        }
        try Self.formulaSource(work, "1.0").write(to: tapRepo.appendingPathComponent("Formula/\(Self.formula).rb"), atomically: true, encoding: .utf8)
        #expect(Self.git(tapRepo, ["init", "-q", "-b", "main"]).0 == 0)
        #expect(Self.git(tapRepo, ["add", "-A"]).0 == 0)
        #expect(Self.git(tapRepo, ["commit", "-qm", "probe 1.0"]).0 == 0)
        let t = Self.brew(["tap", Self.tap, "file://\(tapRepo.path)"])
        try #require(t.0 == 0, "tap: \(t.1)")
        _ = Self.brew(["trust", "--tap", Self.tap])
        let tapDir = tapsDir.appendingPathComponent("homebrew-probe")

        // 1. Uninstall… with two kegs.
        try Self.makeTwoKegs(work, tapDir: tapDir)
        let store = liveStore()
        await store.start()
        let p = try #require(store.packages.first { $0.name == Self.formula })
        #expect(Set(p.installedVersions) == ["1.0", "1.1"])
        #expect(AppStore.uninstallSummary(p, dependenciesStay: true).contains("all installed versions"))
        store.requestUninstall(p)
        store.startUninstall(p)
        let s1 = try await finishedUninstall(store)
        #expect(s1.items.count == 2)
        #expect(s1.title == "Uninstall complete")
        #expect(s1.stillInstalled.isEmpty)
        #expect(Self.versions().isEmpty, "brew list --versions: \(Self.versions())")
        store.closeUpgrade()
        #expect(await waitUntil(timeout: .seconds(60)) { !store.isRefreshing && !store.packages.contains { $0.name == Self.formula } })

        // 2. Pinned with two kegs (as after a rollback): Unpin and Uninstall.
        #expect(Self.git(tapDir, ["reset", "-q", "--hard", "HEAD~1"]).0 == 0) // the tap back at 1.0
        try Self.makeTwoKegs(work, tapDir: tapDir)
        #expect(Self.brew(["pin", Self.formula]).0 == 0)
        await store.refresh(manual: false)
        let pinned = try #require(store.packages.first { $0.name == Self.formula })
        #expect(pinned.pinned)
        #expect(pinned.installedVersions.count == 2)
        store.requestUninstall(pinned)
        store.unpinAndUninstall(pinned)
        #expect(await waitUntil(timeout: .seconds(60)) { store.upgrade != nil && store.upgrade?.id != s1.id })
        let s2 = try await finishedUninstall(store)
        #expect(s2.items.count == 2)
        #expect(s2.title == "Uninstall complete")
        #expect(Self.versions().isEmpty, "brew list --versions: \(Self.versions())")
    }
}
