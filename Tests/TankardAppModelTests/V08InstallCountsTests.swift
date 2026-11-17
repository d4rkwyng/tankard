import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

/// 0.8: install counts in Discover. The network tests live in
/// APICacheTests (serialized) because FakeURLProtocol is shared.
extension APICacheTests {
    var arm64: BottlePlatform { BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar") }

    @Test func analyticsFetchesTheSixBulkFilesAndKeepsThemADay() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        FakeURLProtocol.reset(apiHandler)
        let catalog = APICatalog(fetcher: fetcher(dir, clock), platform: arm64)

        let a = try #require(try await catalog.analytics())
        #expect(a["formula:homebrew/core/xz"] == InstallCounts(days30: 327_759, days90: 1_001_234, days365: 4_100_000))
        #expect(a["formula:user/tap/xz"] == InstallCounts(days30: 5))
        #expect(a["cask:homebrew/cask/firefox"] == InstallCounts(days30: 13_167, days90: 33_293, days365: 182_009))
        #expect(Set(FakeURLProtocol.seen.map(\.path)) == [
            "/api/analytics/install/30d.json", "/api/analytics/install/90d.json", "/api/analytics/install/365d.json",
            "/api/analytics/cask-install/30d.json", "/api/analytics/cask-install/90d.json", "/api/analytics/cask-install/365d.json",
        ])
        #expect(FakeURLProtocol.seen.count == 6)
        // Cached flat next to formula.json, with the ETag.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("analytics-install-30d.json").path))
        #expect(APICache(directory: dir).load("analytics/cask-install/365d.json")?.1.etag == "\"a\"")

        // Past the catalog's hour but within the day: no requests.
        clock.advance(3 * 3600)
        _ = try await catalog.analytics()
        #expect(FakeURLProtocol.seen.count == 6)
        #expect(catalog.outcomes.withLock { $0["analytics/install/30d.json"] } == .cacheFresh)

        // After a day: revalidated with the ETag.
        clock.advance(86_400)
        FakeURLProtocol.reset { req in
            req.value(forHTTPHeaderField: "If-None-Match") == "\"a\"" ? (304, [:], Data()) : (500, [:], Data())
        }
        let again = try #require(try await catalog.analytics())
        #expect(again["formula:homebrew/core/zstd"]?.days30 == 330_001)
        #expect(FakeURLProtocol.seen.count == 6)
        #expect(FakeURLProtocol.seen.allSatisfy { $0.ifNoneMatch == "\"a\"" })
    }

    @Test func discoverDoesNotWaitForCounts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        // The analytics files are slow; the catalog isn't.
        FakeURLProtocol.reset { req in
            if req.url!.path.hasPrefix("/api/analytics/") { Thread.sleep(forTimeInterval: 0.4) }
            return try apiHandler(req)
        }
        let catalog = APICatalog(fetcher: fetcher(dir, clock), platform: arm64)
        let store = await DiscoverStore(provider: catalog, debounce: .zero)
        await store.activate()
        await MainActor.run {
            #expect(store.phase == .ready)
            #expect(store.analyticsPhase == .loading)
            #expect(store.installCounts("formula:homebrew/core/xz") == nil)
            store.query = "xz"
        }
        await store.searchNow()
        await MainActor.run { #expect(store.results.map(\.name) == ["xz"]) }
        await store.waitForAnalytics()
        await MainActor.run {
            #expect(store.analyticsPhase == .ready)
            #expect(store.installCounts("formula:homebrew/core/xz")?.days365 == 4_100_000)
            #expect(store.installCounts("cask:homebrew/cask/firefox")?.days30 == 13_167)
            #expect(store.analytics?.endDate == "2026-11-17")
        }
    }

    @Test func countsThatFailLeaveDiscoverWorking() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        FakeURLProtocol.reset { req in
            req.url!.path.hasPrefix("/api/analytics/") ? (503, [:], Data()) : try apiHandler(req)
        }
        let catalog = APICatalog(fetcher: fetcher(dir, clock), platform: arm64)
        let store = await DiscoverStore(provider: catalog, debounce: .zero)
        await store.activate()
        await store.waitForAnalytics()
        await MainActor.run {
            #expect(store.phase == .ready)
            #expect(store.warning == nil)
            if case .failed(let m) = store.analyticsPhase { #expect(m.contains("503")) } else {
                Issue.record("expected failed, got \(store.analyticsPhase)")
            }
            #expect(store.installCounts("formula:homebrew/core/xz") == nil)
        }
        // The next visit (after the TTL) tries again and recovers.
        FakeURLProtocol.reset(apiHandler)
        clock.advance(3601)
        await store.activate()
        await store.waitForAnalytics()
        await MainActor.run { #expect(store.analyticsPhase == .ready) }
    }
}

@MainActor
struct InstallCountsStoreTests {
    @Test func intelbrewModeHasNoCountsAndAsksNothing() async throws {
        let runner = CatalogInfoRunner()
        let client = makeClient(runner)
        let indexer = FixedIndexer(entries: [TapIndexEntry(kind: .formula, name: "xz", tap: "homebrew/core", desc: "x")])
        let detection = IntelbrewDetector.detect(coreOrigin: Intelbrew.coreRemote, sources: client.sources)
        let store = DiscoverStore(provider: TapCatalog(client: client, detection: detection, indexer: indexer), debounce: .zero)
        await store.activate()
        await store.waitForAnalytics()
        #expect(store.analyticsPhase == .unavailable)
        #expect(store.installCounts("formula:homebrew/core/xz") == nil)
    }

    @Test func demoSliceHasRealShapedCounts() async throws {
        let a = try Demo.fixtureAnalytics()
        #expect((a["formula:homebrew/core/git"]?.days365 ?? 0) > 1_000_000)
        #expect((a["cask:homebrew/cask/firefox"]?.days30 ?? 0) > 0)
        #expect(a["cask:homebrew/cask/firefox@cn"] == nil) // the "no installs recorded" case
        #expect(a.endDate == "2026-11-17")

        // The demo catalog gets them, and the counts re-rank search ties.
        let platform = BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar")
        let store = DiscoverStore(provider: Demo.FixtureAPICatalog(platform: platform), debounce: .zero)
        store.query = "ffmpeg@"
        await store.activate()
        let before = store.results.map(\.name)
        await store.waitForAnalytics()
        #expect(store.analyticsPhase == .ready)
        let after = store.results.map(\.name)
        #expect(Set(before) == Set(after))
        let counts = after.map { store.installCounts("formula:homebrew/core/\($0)")?.days30 ?? 0 }
        // Same tier and bottle rank → most installed first.
        let ranks = after.map { n -> [Int] in
            guard let e = store.entry("formula:homebrew/core/\(n)") else { return [] }
            return [CatalogSearch.score(e, query: "ffmpeg@", words: ["ffmpeg@"]) ?? 0, e.bottle == .fromSource ? 2 : 0]
        }
        #expect(after.count >= 5)
        for i in 1..<after.count where ranks[i] == ranks[i - 1] {
            #expect(counts[i - 1] >= counts[i], "\(after[i - 1]) before \(after[i])")
        }
    }
}
