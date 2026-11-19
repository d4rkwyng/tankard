import Foundation
import Testing
@testable import TankardAppModel
import TankardCore

// 0.8.8 (gauntlet 26, P4): "Scanned 55 · 2 vulnerable" left the status bar
// after a relaunch, though the saved scan still marked the packages. The
// status line now falls back to the saved scan.

@MainActor
struct V088ScanOutcomeShownTests {
    func savedScan(in dir: URL, findings: [String]) throws -> InsightsCache {
        var s = VulnerabilityScan(json: try BrewVulnsJSON.decode(stdout: Data(#"{"findings":[]}"#.utf8)), scannedAt: Date())
        s.checked = 55
        s.complete = true
        s.findings = Dictionary(uniqueKeysWithValues: findings.map { ($0, [PackageVulnerability(id: "CVE-\($0)", severity: .high)]) })
        let cache = InsightsCache(url: dir.appendingPathComponent("insights.json"))
        try cache.save(.init(vulnerabilityScan: s))
        return cache
    }

    @Test func aRelaunchShowsTheSavedScan() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InsightsStore(settings: InsightSettings(defaults: TestDefaults.fresh()),
                                  cache: try savedScan(in: dir, findings: ["libssh2", "openssl@4"]),
                                  ttl: 3600, now: { Date() })
        #expect(store.scanOutcome == nil)
        #expect(store.shownScanOutcome == .done(checked: 55, found: 2, complete: true))
        #expect(ScanProgressText.outcome(store.shownScanOutcome!) == "Scanned 55 · 2 vulnerable")
    }

    @Test func nothingBeforeTheFirstScan() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let none = InsightsStore(settings: InsightSettings(defaults: TestDefaults.fresh()),
                                 cache: InsightsCache(url: dir.appendingPathComponent("none.json")), ttl: 3600, now: { Date() })
        #expect(none.shownScanOutcome == nil)
    }
}
