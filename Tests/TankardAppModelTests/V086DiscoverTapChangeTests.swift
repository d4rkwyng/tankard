import Foundation
import Testing
import os
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6 (VM test M3): a tap added in Terminal stayed invisible to Discover
// until Tankard relaunched: activate() returned early within the TTL and
// Refresh didn't reload. It now compares the taps' fingerprint with the
// one its index was read at, and reloads when they differ.
@MainActor
@Suite(.serialized)
struct V086DiscoverTapChangeTests {
    /// Unique per test: UserTapsCatalog keeps one index per process, by key.
    final class Key: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock(initialState: UUID().uuidString)
        var value: String { get { lock.withLock { $0 } } set { lock.withLock { $0 = newValue } } }
    }

    func catalog(_ indexer: TapIndexing, key: Key) -> UserTapsCatalog {
        let client = makeClient(CatalogInfoRunner(), intelbrew: false)
        let detection = IntelbrewDetector.detect(coreOrigin: nil, sources: client.sources)
        return UserTapsCatalog(api: FixedAPICatalog(entries: V086UserTapsDiscoverTests.api), client: client,
                               detection: detection, indexer: indexer, fingerprint: { key.value })
    }

    @Test func aTapAddedInTerminalIsFoundOnTheNextActivate() async throws {
        let key = Key()
        let first = [TapIndexEntry(kind: .formula, name: "birdclaw", tap: "steipete/tap", desc: "Bird tool")]
        let indexer = SwitchingIndexer(first)
        let d = DiscoverStore(provider: catalog(indexer, key: key), debounce: .zero)
        await d.activate()
        #expect(d.totalCount == 3)
        // Same taps: within the TTL, nothing is read again.
        await d.activate()
        #expect(indexer.reads == 1)
        // `brew tap walktest/probe` in Terminal.
        indexer.entries = first + [TapIndexEntry(kind: .formula, name: "walk-new", tap: "walktest/probe", desc: "A probe formula")]
        key.value = UUID().uuidString
        await d.activate()
        #expect(indexer.reads == 2)
        #expect(d.totalCount == 4)
        d.query = "walk-new"
        await d.searchNow()
        #expect(d.results.map(\.fullName) == ["walktest/probe/walk-new"])
    }

    @Test func windowActivationReloadsAnOpenDiscover() async throws {
        let key = Key()
        let indexer = SwitchingIndexer([TapIndexEntry(kind: .formula, name: "birdclaw", tap: "steipete/tap", desc: "Bird tool")])
        let cat = catalog(indexer, key: key)
        let client = makeClient(FakeInfoRunner(log: CallLog(), info: demoIntelInfo()))
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: FakeStreamRunner(log: CallLog()) { _, _ in 0 },
                                         cache: nil, logURL: nil, makeCatalog: { _, _ in cat })
        let store = AppStore(deps: deps, settings: testSettings())
        await store.refresh(manual: false)
        let d = try #require(store.openDiscover())
        await d.activate()
        #expect(indexer.reads == 1)
        store.revalidateIfStale()
        try await Task.sleep(for: .milliseconds(100))
        #expect(indexer.reads == 1)
        indexer.entries += [TapIndexEntry(kind: .formula, name: "walk-new", tap: "walktest/probe", desc: "A probe formula")]
        key.value = UUID().uuidString
        store.revalidateIfStale()
        #expect(await waitUntil { d.totalCount == 4 })
        #expect(indexer.reads == 2)
    }

    @Test func aProviderWithoutAKeyKeepsTheTTL() async {
        let d = DiscoverStore(provider: FixedAPICatalog(entries: V086UserTapsDiscoverTests.api), debounce: .zero)
        await d.activate()
        #expect(d.totalCount == 2)
        #expect(FixedAPICatalog(entries: []).changeKey() == nil)
    }
}

final class SwitchingIndexer: TapIndexing, @unchecked Sendable {
    let lock = NSLock()
    private var _entries: [TapIndexEntry]
    private var _reads = 0
    init(_ entries: [TapIndexEntry]) { _entries = entries }
    var entries: [TapIndexEntry] { get { lock.withLock { _entries } } set { lock.withLock { _entries = newValue } } }
    var reads: Int { lock.withLock { _reads } }
    func index() -> TapIndex {
        let e: [TapIndexEntry] = lock.withLock { _reads += 1; return _entries }
        return TapIndex(entries: e, taps: Array(Set(e.map(\.tap))).sorted())
    }
}
