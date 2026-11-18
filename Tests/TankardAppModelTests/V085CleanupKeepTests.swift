import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5 (bug hunt M1): Clean Up removed the old versions "Keep the previous
// version after upgrades" keeps for Restore Points, while saying nothing you
// use is removed, with Clean Up as the Return default. Now those formulae go
// in HOMEBREW_NO_CLEANUP_FORMULAE for the preview and the real run, and any
// old version it would still remove is listed and takes Return away.
@MainActor
struct V085CleanupKeepTests {
    func kegs(_ name: String, _ versions: [String], kind: PackageKind = .formula) -> Package {
        var p = pkg(name, kind: kind, outdated: false)
        p.installedVersion = versions.last ?? ""
        p.installedVersions = versions
        return p
    }

    @Test func keptFormulaeAreTheOnesWithAnOldVersion() {
        let list = [kegs("xz", ["5.8.1", "5.8.2"]), kegs("jq", ["1.7"]), kegs("firefox", ["1", "2"], kind: .cask),
                    kegs("abc", ["1", "2", "3"]), kegs("dup", ["1", "1"])]
        #expect(CleanupKeep.keptFormulae(list, keepPrevious: true) == ["abc", "xz"])
        #expect(CleanupKeep.keptFormulae(list, keepPrevious: false).isEmpty)
    }

    @Test func environmentAddsToBrewEnv() {
        #expect(CleanupKeep.environment([], existing: "foo").isEmpty)
        #expect(CleanupKeep.environment(["xz"], existing: nil) == ["HOMEBREW_NO_CLEANUP_FORMULAE": "xz"])
        #expect(CleanupKeep.environment(["xz", "foo"], existing: "foo, bar") == ["HOMEBREW_NO_CLEANUP_FORMULAE": "foo,bar,xz"])
        #expect(CleanupKeep.kegLabel("/opt/homebrew/Cellar/bh-b/1.0") == "bh-b 1.0")
        #expect(CleanupKeep.kegLabel("/Users/x/Library/Caches/Homebrew/a--1.tar.gz") == nil)
    }

    @Test func previewAndCommandSkipKeptFormulae() async throws {
        let runner = EnvRecordingCleanupRunner(output: "Would remove: /Users/test/Library/Caches/Homebrew/x--1.tar.gz (1MB)\n")
        let c = CleanupStore(client: makeClient(runner), env: ["PATH": "/usr/bin"], kept: ["bh-b"], keepPrevious: true)
        await c.load()
        #expect(runner.cleanupEnv?["HOMEBREW_NO_CLEANUP_FORMULAE"] == "bh-b")
        #expect(c.command == "HOMEBREW_NO_CLEANUP_FORMULAE=bh-b brew cleanup")
        #expect(c.removesRollbackVersions.isEmpty)
        #expect(c.cleanUpIsDefault)
        #expect(c.keptNote == "Keeps the old versions of bh-b for Restore Points, because “Keep the previous version after upgrades” is on.")
        let many = CleanupStore(client: makeClient(runner), env: [:], kept: ["a", "b", "c", "d", "e"], keepPrevious: true)
        #expect(many.keptNote?.contains("a, b, c and 2 more") == true)
    }

    @Test func oldVersionsItWouldRemoveAreListedAndNotDefault() async throws {
        let runner = EnvRecordingCleanupRunner(output: """
            Would remove: /opt/homebrew/Cellar/bh-b/1.0 (4 files, 4KB)
            Would remove: /Users/test/Library/Caches/Homebrew/bh-b--1.0.tar.gz (443B)
            """)
        let c = CleanupStore(client: makeClient(runner), env: [:])
        await c.load()
        #expect(runner.cleanupEnv?["HOMEBREW_NO_CLEANUP_FORMULAE"] == nil)
        #expect(c.command == "brew cleanup")
        #expect(c.removesRollbackVersions == ["bh-b 1.0"])
        #expect(!c.cleanUpIsDefault)
        #expect(c.keptNote == nil)
    }

    @Test func realCleanupRunsWithTheSameVariable() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        store.restorePoints.settings.keepPreviousVersion = true
        var report = try #require(store.report)
        let i = try #require(report.packages.firstIndex { $0.kind == .formula })
        let name = report.packages[i].name
        report.packages[i].installedVersions = ["0.0.1", report.packages[i].installedVersion]
        store.report = report
        store.openCleanup()
        let c = try #require(store.cleanup)
        #expect(c.kept == [name])
        #expect(await waitUntil { c.phase == .ready && !c.measuringCache })
        store.startCleanup()
        let session = try #require(store.upgrade)
        #expect(session.items[0].command.arguments == ["cleanup"])
        #expect(session.items[0].command.environment["HOMEBREW_NO_CLEANUP_FORMULAE"] == name)
        #expect(session.items[0].command.display == "HOMEBREW_NO_CLEANUP_FORMULAE=\(name) brew cleanup")
        #expect(await waitUntil { session.isFinished })
    }
}

final class EnvRecordingCleanupRunner: CommandRunning, @unchecked Sendable {
    let output: String
    private let lock = NSLock()
    private var _env: [String: String]?
    var cleanupEnv: [String: String]? { lock.withLock { _env } }
    init(output: String) { self.output = output }
    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        func out(_ s: String) -> ProcessResult { ProcessResult(exitCode: 0, stdout: Data(s.utf8), stderr: Data()) }
        switch arguments {
        case ["--cache"]: return out("/Users/test/Library/Caches/Homebrew\n")
        case ["cleanup", "-n"]:
            lock.withLock { _env = environment }
            return out(output)
        default: return out("2\t/Users/test/Library/Caches/Homebrew\n")
        }
    }
}
