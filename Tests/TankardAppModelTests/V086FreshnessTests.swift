import Foundation
import Testing
import os
import TankardCore
@testable import TankardAppModel

// 0.8.6 (walkthrough M4): a `brew install` in Terminal stayed invisible for
// up to an hour (the cache TTL), and so did "The last upgrade didn't
// finish" after a crash. Tankard now compares the Cellar's, Caskroom's and
// opt's modification time with the report's (a few stat calls) at launch
// and when the window comes to the front, and reads again at launch when
// an interrupted run's journal is waiting.
@MainActor
struct V086FreshnessTests {
    final class Changed: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock<Date?>(initialState: nil)
        var value: Date? { get { lock.withLock { $0 } } set { lock.withLock { $0 = newValue } } }
    }

    func rig(now: Date, changed: Changed, settings: AppSettings = testSettings()) throws -> (AppStore, CallLog, StatusCache, URL) {
        let dir = try tempDir()
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let cache = StatusCache(url: dir.appendingPathComponent("status.json"))
        var deps = AppStore.Dependencies(makeClient: { client }, streamRunner: FakeStreamRunner(log: log) { _, _ in 0 },
                                         cache: cache, logURL: nil, ttl: 3600, now: { now })
        deps.homebrewChangedAt = { _ in changed.value }
        return (AppStore(deps: deps, settings: settings), log, cache, dir)
    }

    func cached(at date: Date) async throws -> StatusReport {
        var r = try await makeClient(FakeInfoRunner(log: CallLog(), info: Demo.fixtureInfo(.intelbrew))).status()
        r.generatedAt = date
        return r
    }

    @Test func aChangeAfterTheCachedReadIsReadAtLaunch() async throws {
        let now = Date()
        let changed = Changed()
        changed.value = now.addingTimeInterval(-60) // brew install in Terminal a minute ago
        let (store, log, cache, dir) = try rig(now: now, changed: changed)
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save(try await cached(at: now.addingTimeInterval(-600)))
        await store.start()
        #expect(log.count("info") == 1)
        #expect(!store.reportFromCache)
    }

    @Test func noChangeKeepsTheCache() async throws {
        let now = Date()
        let changed = Changed()
        changed.value = now.addingTimeInterval(-3000) // before the cached read
        let (store, log, cache, dir) = try rig(now: now, changed: changed)
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save(try await cached(at: now.addingTimeInterval(-600)))
        await store.start()
        #expect(log.count("info") == 0)
        #expect(store.reportFromCache)
        #expect(!store.homebrewChangedSinceRead)
    }

    @Test func comingToTheFrontReadsAgainAfterAChange() async throws {
        let now = Date()
        let changed = Changed()
        let (store, log, cache, dir) = try rig(now: now, changed: changed)
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save(try await cached(at: now.addingTimeInterval(-600)))
        await store.start()
        #expect(log.count("info") == 0)
        store.revalidateIfStale()
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.count("info") == 0)
        changed.value = now // Terminal changed something
        store.revalidateIfStale()
        #expect(await waitUntil { log.count("info") == 1 && !store.isRefreshing })
    }

    @Test func anInterruptedRunIsReadAtLaunchWhateverTheTTL() async throws {
        let now = Date()
        let settings = testSettings()
        settings.defaults.set(Data("{}".utf8), forKey: RunJournal.key)
        let (store, log, cache, dir) = try rig(now: now, changed: Changed(), settings: settings)
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save(try await cached(at: now.addingTimeInterval(-600)))
        await store.start()
        #expect(log.count("info") == 1)
    }

    @Test func liveProbeReadsModificationTimes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Cellar"), withIntermediateDirectories: true)
        let t = try #require(HomebrewChanges.latest(paths: [dir.appendingPathComponent("Cellar").path, dir.appendingPathComponent("Caskroom").path]))
        #expect(abs(t.timeIntervalSinceNow) < 60)
        #expect(HomebrewChanges.latest(paths: [dir.appendingPathComponent("nope").path]) == nil)
    }
}
