import Foundation
import Testing
@testable import TankardAppModel
import TankardCore

/// The Vulnerable filter's scan header and empty state.
@MainActor
struct VulnerableScanStatusTests {
    func scan(checked: Int = 42, findings: [String] = [], complete: Bool = true, at: Date) -> VulnerabilityScan {
        var s = VulnerabilityScan(json: try! BrewVulnsJSON.decode(stdout: Data(#"{"findings":[]}"#.utf8)), scannedAt: at)
        s.checked = checked
        s.complete = complete
        if !complete { s.skipped = ["a", "b"] }
        s.findings = Dictionary(uniqueKeysWithValues: findings.map { ($0, [PackageVulnerability(id: "CVE-\($0)", severity: .high)]) })
        return s
    }

    @Test func notScannedYet() {
        let s = VulnerableScanStatus(state: .idle, scan: nil)
        #expect(s == .notScanned)
        #expect(s.line(now: Date()) == "Not scanned yet")
        #expect(s.emptyTitle == "No scan yet")
        #expect(s.emptyMessage(now: Date()).hasPrefix("Scan Now runs brew vulns"))
        #expect(s.emptyMessage(now: Date()).contains("OSV.dev"))
    }

    @Test func lastResultWithCountAndTime() {
        let now = Date()
        let s = VulnerableScanStatus(state: .idle, scan: scan(findings: ["expat", "xz"], at: now.addingTimeInterval(-300)))
        #expect(s.line(now: now) == "Scanned 42 · found 2 · 5 min ago")
        let none = VulnerableScanStatus(state: .idle, scan: scan(at: now.addingTimeInterval(-300)))
        #expect(none.emptyTitle == "No known vulnerabilities")
        #expect(none.emptyMessage(now: now) == "The last scan (5 min ago) found none.")
    }

    @Test func partialScanSaysSo() {
        let now = Date()
        let s = VulnerableScanStatus(state: .idle, scan: scan(complete: false, at: now))
        #expect(s.line(now: now) == "Scanned 42 · found 0 · partial scan · just now")
        #expect(s.emptyMessage(now: now).contains("brew says the scan is incomplete: 2 not checked: 2 with no source repository brew can match."))
    }

    @Test func runningFailedUnsupported() {
        let last = scan(at: Date())
        let running = VulnerableScanStatus(state: .running, scan: last)
        #expect(running == .running)
        #expect(running.line(now: Date()) == nil)
        #expect(running.emptyTitle == "Scanning…")
        let timedOut = VulnerableScanStatus(state: .failed(InsightsStore.scanTimedOutMessage), scan: last)
        #expect(timedOut.line(now: Date()) == "Scan timed out")
        #expect(timedOut.emptyMessage(now: Date()) == InsightsStore.scanTimedOutMessage)
        let failed = VulnerableScanStatus(state: .failed("network down"), scan: nil)
        #expect(failed.emptyTitle == "Scan failed")
        #expect(failed.emptyMessage(now: Date()) == "network down")
        #expect(VulnerableScanStatus(state: .unsupported("no vulns"), scan: nil).line(now: Date()) == "No brew vulns")
    }

    /// The same rule as Homebrew ▸ Scan for Vulnerabilities.
    @Test func scanNowFollowsTheMenuRule() {
        #expect(VulnerableScanStatus.canScan(state: .idle, hasReport: true))
        #expect(!VulnerableScanStatus.canScan(state: .running, hasReport: true))
        #expect(!VulnerableScanStatus.canScan(state: .idle, hasReport: false))
        #expect(VulnerableScanStatus.canScan(state: .failed("x"), hasReport: true))
    }
}
