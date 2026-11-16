import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

@MainActor
struct AppStoreTests {
    struct Rig {
        var store: AppStore
        var log: CallLog
        var info: FakeInfoRunner
        var dir: URL
        var cache: StatusCache
    }

    /// A store on the demo-tweaked Intel fixture (5 upgrades), with a cache
    /// and log in a temp dir. `now` is when the store thinks it is.
    func rig(now: Date = Date(),
             stream: (@Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32)? = nil) throws -> Rig {
        let dir = try tempDir()
        let log = CallLog()
        let info = FakeInfoRunner(log: log, info: demoIntelInfo())
        let client = makeClient(info)
        let cache = StatusCache(url: dir.appendingPathComponent("cache/status.json"))
        let runner = FakeStreamRunner(log: log, behaviour: stream ?? { _, output in
            output(Data("ok\n".utf8))
            return 0
        })
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: cache,
                                         logURL: dir.appendingPathComponent("Logs/upgrade.log"),
                                         ttl: 3600, now: { now })
        return Rig(store: AppStore(deps: deps), log: log, info: info, dir: dir, cache: cache)
    }

    /// A report as if read at `date`.
    func cachedReport(at date: Date) async throws -> StatusReport {
        let log = CallLog()
        var report = try await makeClient(FakeInfoRunner(log: log, info: Demo.fixtureInfo(.intelbrew))).status()
        report.generatedAt = date
        return report
    }

    // MARK: cache-first, stale-while-revalidate

    @Test func freshCacheIsShownWithoutAskingBrew() async throws {
        let now = Date()
        let r = try rig(now: now)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        try r.cache.save(try await cachedReport(at: now.addingTimeInterval(-600)))  // 10 min old

        await r.store.start()
        #expect(r.store.report != nil)
        #expect(r.store.reportFromCache)
        #expect(r.log.count("info") == 0)
        #expect(r.store.packages.count == 20)
        #expect(r.store.upgradable.isEmpty) // the cached (untweaked) data, not brew's
    }

    @Test func staleCacheIsShownThenRevalidated() async throws {
        let now = Date()
        let r = try rig(now: now)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        try r.cache.save(try await cachedReport(at: now.addingTimeInterval(-7200)))  // 2 h old

        let started = Task { await r.store.start() }
        // The cached data is on screen before brew answers.
        #expect(await waitUntil { r.store.report != nil })
        #expect(r.store.reportFromCache || r.log.count("info") == 1)
        await started.value
        #expect(r.log.count("info") == 1)
        #expect(!r.store.reportFromCache)
        #expect(r.store.upgradable.count == 5)
        // No `brew update` on an automatic revalidation.
        #expect(r.log.count("update") == 0)
        // And the fresh report was cached.
        #expect(r.cache.load()?.summary.upgrades == 5)
    }

    @Test func noCacheReadsBrew() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        #expect(r.log.count("info") == 1)
        #expect(r.store.intelbrewMode)
        #expect(r.store.error == nil)
    }

    @Test func failedRefreshKeepsDataAndShowsError() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        let before = r.store.report?.packages
        r.info.failInfo = true
        await r.store.refresh(manual: false)
        #expect(r.store.report?.packages == before)
        #expect(r.store.error?.title == "Refresh failed")
        #expect(r.store.error?.detail.contains("boom") == true)
        // The next good refresh clears it.
        r.info.failInfo = false
        await r.store.refresh(manual: false)
        #expect(r.store.error == nil)
    }

    @Test func manualRefreshRunsBrewUpdateFirst() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.refresh(manual: true)
        #expect(r.log.calls.map { $0.first! } == ["update", "info"])
    }

    @Test func brewUpdateNeedingSudoSaysRunItInTerminal() async throws {
        let r = try rig { args, output in
            output(Data("Error: sudo: a terminal is required to read the password\n".utf8))
            return 1
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.refresh(manual: true)
        #expect(r.store.error?.terminalCommand == "brew update")
        #expect(r.store.error?.title.contains("administrator") == true)
        // Status was still read.
        #expect(r.store.report != nil)
    }

    @Test func brewNotFound() async throws {
        let deps = AppStore.Dependencies(makeClient: { throw BrewClientError.brewNotFound(searched: ["/nope"]) },
                                         streamRunner: FakeStreamRunner(log: CallLog()) { _, _ in 0 },
                                         cache: nil, logURL: nil)
        let store = AppStore(deps: deps)
        await store.start()
        #expect(store.report == nil)
        #expect(store.error?.title == "Homebrew not found")
    }

    // MARK: filters and search

    @Test func filtersAndSearch() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        let s = r.store
        #expect(s.count(.all) == 20)
        #expect(s.count(.upgrades) == 5)
        #expect(s.count(.source) == 1)
        #expect(s.count(.newer) == 1)
        s.filter = .upgrades
        #expect(Set(s.visiblePackages.map(\.name)) == ["python@3.15", "openssl@4", "sqlite", "xz", "ruby"])
        s.search = "PYTH"
        #expect(s.visiblePackages.map(\.name) == ["python@3.15"])
        s.filter = .all
        s.search = "interactive" // matches the description
        #expect(s.visiblePackages.map(\.name).contains("python@3.15"))
    }

    // MARK: upgrades

    @Test func upgradeRunsFullyQualifiedCommandsInOrderAndReconciles() async throws {
        let r = try rig { args, output in
            output(Data("==> Upgrading \(args.last!)\n\r##  50%\r#### 100%\n".utf8))
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        let infoCalls = r.log.count("info")
        r.store.startUpgrade()
        let session = try #require(r.store.upgrade)
        #expect(r.store.showUpgradeSheet)
        #expect(await waitUntil { session.isFinished })

        let upgrades = r.log.calls.filter { $0.first == "upgrade" }
        #expect(upgrades == session.items.map { ["upgrade", "--formula", "homebrew/core/\($0.package.name)"] })
        #expect(upgrades.count == 5)
        #expect(session.items.allSatisfy { $0.state == .done })
        #expect(session.subtitle == "4 bottles from Intelbrew · 1 build from source (ruby)")
        #expect(session.items.first?.command.display == "brew upgrade --formula homebrew/core/openssl@4")
        #expect(session.items.first?.command.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(session.items.first?.command.environment["HOMEBREW_CORE_GIT_REMOTE"] == Intelbrew.coreRemote)

        // CR redraws collapse to the final line in the session log.
        #expect(session.log.lines.contains("#### 100%"))
        #expect(!session.log.lines.contains("##  50%"))

        // Log file: a header per command plus the finished lines.
        let text = try String(contentsOf: r.dir.appendingPathComponent("Logs/upgrade.log"), encoding: .utf8)
        #expect(text.components(separatedBy: "$ brew upgrade --formula homebrew/core/").count == 6)
        #expect(text.contains("==> Upgrading homebrew/core/xz"))

        // Reconcile: status is read again after the run.
        #expect(await waitUntil { r.log.count("info") == infoCalls + 1 && !r.store.isRefreshing })
        #expect(r.log.count("update") == 0)
    }

    @Test func stopAfterCurrentSkipsTheRest() async throws {
        let gate = Latch()
        let r = try rig { _, output in
            await gate.wait()
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade()
        let session = try #require(r.store.upgrade)
        #expect(await waitUntil { session.current != nil })
        session.stopAfterCurrent()
        gate.release()
        #expect(await waitUntil { session.isFinished })
        #expect(r.log.count("upgrade") == 1)
        #expect(session.items.map(\.state) == [.done, .cancelled, .cancelled, .cancelled, .cancelled])
        #expect(session.title == "Upgrade stopped")
    }

    @Test func stopNowCancelsTheRunningCommand() async throws {
        let r = try rig { _, _ in
            try await sleepUntilCancelled()
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade()
        let session = try #require(r.store.upgrade)
        #expect(await waitUntil { session.current != nil })
        session.stopNow()
        #expect(await waitUntil { session.isFinished })
        #expect(session.items.allSatisfy { $0.state == .cancelled })
        #expect(session.log.lines.contains("tankard: Stopped."))
    }

    @Test func sudoFailureInUpgradeShowsTerminalCommandAndContinues() async throws {
        let r = try rig { args, output in
            if args.last == "homebrew/core/python@3.15" {
                output(Data("sudo: a password is required\nError: Failure while executing\n".utf8))
                return 1
            }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade()
        let session = try #require(r.store.upgrade)
        #expect(await waitUntil { session.isFinished })
        #expect(session.sudoCommand == "brew upgrade --formula homebrew/core/python@3.15")
        #expect(session.failedItems.map(\.package.name) == ["python@3.15"])
        #expect(session.succeededCount == 4)
        #expect(session.title == "Upgrade finished with errors")
    }

    @Test func upgradesAndRefreshShareOneQueue() async throws {
        // A manual refresh's `brew update` waits behind a running upgrade.
        let gate = Latch()
        let r = try rig { args, _ in
            if args.first == "upgrade" { await gate.wait() }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade([r.store.upgradable[0]])
        let session = try #require(r.store.upgrade)
        #expect(await waitUntil { session.current != nil })
        let refresh = Task { await r.store.refresh(manual: true) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.log.count("update") == 0)
        gate.release()
        await refresh.value
        let firsts = r.log.calls.map { $0.first! }
        #expect(firsts.firstIndex(of: "upgrade")! < firsts.firstIndex(of: "update")!)
    }
}
