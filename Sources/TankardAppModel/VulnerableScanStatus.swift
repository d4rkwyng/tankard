import Foundation
import TankardCore

/// The Vulnerable filter's scan header and empty state: where the last
/// scan stands, from the scan state and the last result. The scan itself
/// is the menu's (`AppStore.scanVulnerabilitiesNow`), with the same rule
/// for when it can run (`canScan`).
public enum VulnerableScanStatus: Equatable, Sendable {
    case running
    case notScanned
    case scanned(checked: Int, found: Int, complete: Bool, partialReason: String?, at: Date)
    case failed(String, timedOut: Bool)
    case unsupported(String)

    @MainActor
    public init(state: InsightState, scan: VulnerabilityScan?) {
        switch state {
        case .running: self = .running
        case .failed(let s): self = .failed(s, timedOut: s == InsightsStore.scanTimedOutMessage)
        case .unsupported(let s): self = .unsupported(s)
        case .idle:
            if let scan {
                self = .scanned(checked: scan.checked, found: scan.findings.count, complete: scan.complete,
                                partialReason: scan.partialReason, at: scan.scannedAt)
            } else {
                self = .notScanned
            }
        }
    }

    /// The menu item's rule: not while a scan runs, and not before brew's
    /// status is in.
    public static func canScan(state: InsightState, hasReport: Bool) -> Bool {
        state != .running && hasReport
    }

    /// The header line: "Scanned 42 · found 2 · 5 min ago", "Not scanned yet",
    /// "Scan failed". nil while a scan runs (the progress line shows instead).
    public func line(now: Date) -> String? {
        switch self {
        case .running: return nil
        case .notScanned: return String(localized: "Not scanned yet")
        case .scanned(let checked, let found, let complete, _, let at):
            return ScanProgressText.outcome(.done(checked: checked, found: found, complete: complete))
                + " · " + updatedAgo(at, now: now)
        case .failed(_, let timedOut):
            return timedOut ? String(localized: "Scan timed out") : String(localized: "Scan failed")
        case .unsupported: return String(localized: "Security check not available")
        }
    }

    /// The empty list's title, when the filter shows nothing.
    public var emptyTitle: String {
        switch self {
        case .running: return String(localized: "Scanning…")
        case .notScanned: return String(localized: "No scan yet")
        case .scanned: return String(localized: "No known vulnerabilities")
        case .failed(_, let timedOut): return timedOut ? String(localized: "Scan timed out") : String(localized: "Scan failed")
        case .unsupported: return String(localized: "Security check not available")
        }
    }

    /// The empty list's explanation.
    public func emptyMessage(now: Date) -> String {
        switch self {
        case .running:
            return InsightSettings.scanPrivacyNote
        case .notScanned:
            return String(localized: "Scan Now runs brew vulns to find installed formulae with known vulnerabilities.")
                + " " + InsightSettings.scanPrivacyNote
        case .scanned(_, _, let complete, let reason, let at):
            var s = String(localized: "The last scan (\(updatedAgo(at, now: now))) found none.")
            if !complete, let reason { s += " " + String(localized: "brew says the scan is incomplete: \(reason).") }
            return s
        case .failed(let s, _), .unsupported(let s):
            return s
        }
    }
}
