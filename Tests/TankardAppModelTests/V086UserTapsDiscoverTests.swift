import Foundation
import Testing
import os
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6 (walkthrough H1): normal-mode Discover searched only
// formulae.brew.sh, so a formula from a tap the user added (walktest/probe,
// steipete/tap) was "No matches". The user's own taps are now read like
// Intelbrew mode reads its taps, and merged in.

/// formulae.brew.sh stand-in: fixed entries, complete details.
struct FixedAPICatalog: CatalogProviding {
    var entries: [CatalogEntry]
    func load() async throws -> CatalogLoad {
        CatalogLoad(entries: entries, source: "formulae.brew.sh · \(entries.count) formulae · 0 casks")
    }
    func details(_ entries: [CatalogEntry]) async -> [CatalogEntry] { entries }
    var isLocalTaps: Bool { false }
}

/// Counts how often the taps are read.
final class CountingIndexer: TapIndexing, @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    let entries: [TapIndexEntry]
    init(_ entries: [TapIndexEntry]) { self.entries = entries }
    func index() -> TapIndex {
        lock.withLock { count += 1 }
        return TapIndex(entries: entries, taps: Array(Set(entries.map(\.tap))).sorted())
    }
}

@MainActor
@Suite(.serialized)
struct V086UserTapsDiscoverTests {
    static let api = [
        CatalogEntry(kind: .formula, name: "xz", fullName: "xz", tap: "homebrew/core", desc: "General-purpose data compression", bottle: .forThisMac),
        CatalogEntry(kind: .formula, name: "wget", fullName: "wget", tap: "homebrew/core", desc: "Internet file retriever", bottle: .forThisMac),
    ]
    static let mine = [
        TapIndexEntry(kind: .formula, name: "walk-new", tap: "walktest/probe", desc: "A probe formula", bottle: BrewInfoJSON.BottleSpec(rootURL: nil, files: [:])),
        TapIndexEntry(kind: .cask, name: "walk-app", tap: "walktest/probe", desc: "A probe app"),
        TapIndexEntry(kind: .formula, name: "birdclaw", tap: "steipete/tap", desc: "Bird tool"),
        // A homebrew/ tap that happens to be tapped is formulae.brew.sh's business.
        TapIndexEntry(kind: .formula, name: "xz", tap: "homebrew/core", desc: "dup"),
    ]

    func catalog(_ indexer: TapIndexing, runner: CommandRunning = CatalogInfoRunner(), key: @escaping @Sendable () -> String = { UUID().uuidString }) -> UserTapsCatalog {
        let client = makeClient(runner, intelbrew: false)
        let detection = IntelbrewDetector.detect(coreOrigin: nil, sources: client.sources)
        return UserTapsCatalog(api: FixedAPICatalog(entries: Self.api), client: client, detection: detection,
                               indexer: indexer, fingerprint: key)
    }

    @Test func aFormulaFromAnAddedTapIsFound() async throws {
        let runner = CatalogInfoRunner()
        let d = DiscoverStore(provider: catalog(FixedIndexer(entries: Self.mine), runner: runner), debounce: .zero)
        await d.activate()
        #expect(d.isLocalTaps == false)
        #expect(d.totalCount == 5) // 2 API + 3 from the user's taps, homebrew/core's xz not doubled
        #expect(d.source.contains("your taps (steipete/tap, walktest/probe) · 3"))
        d.query = "walk-new"
        await d.searchNow()
        let hit = try #require(d.results.first)
        #expect(hit.fullName == "walktest/probe/walk-new")
        #expect(hit.bottle == .fromSource) // the tap has no bottle block
        d.query = "birdclaw"
        await d.searchNow()
        #expect(d.results.map(\.fullName) == ["steipete/tap/birdclaw"])
        await d.waitForDetails()
        // Only the tap's row goes to brew info, fully qualified.
        #expect(runner.log.calls.allSatisfy { $0.contains("steipete/tap/birdclaw") })
        #expect(runner.log.calls.contains { $0.contains("xz") } == false)
    }

    @Test func theTapsAreReadOncePerFingerprint() async throws {
        UserTapsCatalog.cache.withLock { $0 = nil }
        let indexer = CountingIndexer(Self.mine)
        let key = OSAllocatedUnfairLock(initialState: "a")
        let c = catalog(indexer, key: { key.withLock { $0 } })
        _ = try await c.load()
        _ = try await c.load()
        #expect(indexer.lock.withLock { indexer.count } == 1)
        key.withLock { $0 = "b" } // a tap was added or updated
        _ = try await c.load()
        #expect(indexer.lock.withLock { indexer.count } == 2)
        UserTapsCatalog.cache.withLock { $0 = nil }
    }

    @Test func noUserTapsLeavesTheAPILoadAlone() async throws {
        let load = try await catalog(FixedIndexer(entries: [])).load()
        #expect(load.entries.count == 2)
        #expect(load.source == "formulae.brew.sh · 2 formulae · 0 casks")
    }

    @Test func emptySearchSaysWhereItLookedAndHowToAddATap() async {
        let d = DiscoverStore(provider: catalog(FixedIndexer(entries: Self.mine)), debounce: .zero)
        #expect(d.noMatchesDetail("zzz").contains("taps you've added"))
        #expect(d.noMatchesDetail("zzz").contains("Homebrew ▸ Taps…"))
        let runner = CatalogInfoRunner()
        let client = makeClient(runner)
        let local = TapCatalog(client: client, detection: IntelbrewDetector.detect(coreOrigin: Intelbrew.coreRemote, sources: client.sources),
                               indexer: FixedIndexer(entries: []))
        #expect(DiscoverStore(provider: local).noMatchesDetail("zzz") == "Nothing matches “zzz”.")
    }

    @Test func indexerSkipsHomebrewTapsAndStopsAtTheBound() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func formula(_ tap: String, _ name: String) throws {
            let parts = tap.split(separator: "/")
            let dir = root.appendingPathComponent("\(parts[0])/homebrew-\(parts[1])/Formula")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try "class X < Formula\n  desc \"\(name) tool\"\nend\n".write(to: dir.appendingPathComponent("\(name).rb"), atomically: true, encoding: .utf8)
        }
        try formula("homebrew/core", "xz")
        try formula("walktest/probe", "walk-a")
        try formula("walktest/probe", "walk-b")
        try formula("steipete/tap", "birdclaw")
        var idx = TapIndexer(tapsDirectory: root)
        idx.userTapsOnly = true
        let all = idx.index()
        #expect(all.taps == ["steipete/tap", "walktest/probe"])
        #expect(Set(all.entries.map(\.name)) == ["birdclaw", "walk-a", "walk-b"])
        idx.maxEntries = 2
        #expect(idx.index().entries.count == 2)

        let before = idx.fingerprint()
        #expect(before == idx.fingerprint())
        try formula("other/new", "thing")
        #expect(idx.fingerprint() != before)
    }
}

// 0.8.6 (walkthrough M1): the app's side of packages brew can't read.
@MainActor
struct V086UnreadableAppTests {
    @Test func healthAndTapsCountThem() throws {
        var p = Package.command("obsidian-cli")
        p.id = "formula:yakitrak/yakitrak/obsidian-cli"
        p.tap = "yakitrak/yakitrak"
        p.unreadable = "Refusing to load formula yakitrak/yakitrak/notesmd-cli from untrusted tap yakitrak/yakitrak."
        #expect(p.isUnreadable)
        #expect(HealthText.unreadableTitle(1) == "1 installed package Homebrew can't read")
        #expect(HealthText.unreadableTitle(2) == "2 installed packages Homebrew can't read")
        let detail = try #require(p.unreadableDetail)
        #expect(detail.hasPrefix("Homebrew can't read this package any more, so it won't upgrade it. brew says: Refusing"))
        #expect(detail.hasSuffix("Installed from yakitrak/yakitrak."))
    }
}
