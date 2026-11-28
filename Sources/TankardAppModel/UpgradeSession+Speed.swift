import Foundation
import TankardCore

// 0.10: the download's speed and time left on the sheet's status line
// (Derek: on a slow connection "2.1 of 2.3 GB (91%)" barely moves, and he
// couldn't tell whether it was still working). The tracker is
// TankardCore's DownloadSpeed, fed by each download poll with the
// session's clock.

/// What the status line says about a download's speed.
public enum DownloadRate: Equatable, Sendable {
    /// No download, or not enough samples yet: the line is as before.
    case none
    /// No new bytes for `DownloadSpeed.stallAfter` seconds: "Waiting for data…".
    case stalled
    /// A speed, not steady enough for a time left yet.
    case measuring(bytesPerSecond: Double)
    /// A steady speed; the time left when the total is known (and under
    /// `DownloadSpeed.longestTimeLeft`).
    case rate(bytesPerSecond: Double, eta: TimeInterval?)
}

extension UpgradeSession {
    /// The running download's speed at `date`.
    public func downloadRate(at date: Date) -> DownloadRate {
        guard let d = download else { return .none }
        if downloadSpeed.isStalled(at: date) { return .stalled }
        guard let bps = downloadSpeed.speed(at: date) else { return .none }
        guard downloadSpeed.isStable(at: date) else { return .measuring(bytesPerSecond: bps) }
        return .rate(bytesPerSecond: bps, eta: downloadSpeed.eta(bytes: d.bytes, total: d.total, at: date))
    }

    /// "Waiting for data…"
    public static var waitingForData: String { String(localized: "Waiting for data…") }

    /// The visible pieces after the size: ["4.2 MB/s", "about 1 min left"],
    /// ["Waiting for data…"], or none.
    func ratePieces(at date: Date) -> [String] {
        switch downloadRate(at: date) {
        case .none: return []
        case .stalled: return [Self.waitingForData]
        case .measuring(let bps): return [DownloadSpeedFormat.speed(bps)]
        case .rate(let bps, let eta):
            return [DownloadSpeedFormat.speed(bps)] + (eta.map { [DownloadSpeedFormat.timeLeftText($0)] } ?? [])
        }
    }

    /// " · 4.2 MB/s · about 1 min left", or "".
    func rateSuffix(at date: Date) -> String {
        ratePieces(at: date).map { " · " + $0 }.joined()
    }

    /// 0.10: the status line as VoiceOver reads it. While a download runs:
    /// the same sentence with commas for the dots and the units in words
    /// ("Downloading 10 of 11, 2.1 of 2.3 GB, 91 percent, 4.2 megabytes per
    /// second, about 1 min left"); otherwise the visible line.
    public func statusAccessibilityLabel(behindBrewUpdate: Bool, at date: Date) -> String {
        let line = statusLine(behindBrewUpdate: behindBrewUpdate, at: date)
        guard let d = download else { return line }
        // Only the two download lines; any other (stopping, a lock wait)
        // is read as shown.
        let head: String
        if isFetching {
            head = String(localized: "Downloading \(fetchedCount) of \(fetchTotal)")
            guard line.hasPrefix(head + " · ") else { return line }
        } else if let c = current, line.hasPrefix(String(localized: "Downloading \(d.name ?? c.package.name)…")) {
            head = AccessibilityText.downloading(d.name ?? c.package.name)
        } else {
            return line
        }
        var parts = [head] + AccessibilityText.downloadSize(d)
        switch downloadRate(at: date) {
        case .none: break
        case .stalled: parts.append(Self.waitingForData)
        case .measuring(let bps): parts.append(AccessibilityText.speed(bps))
        case .rate(let bps, let eta):
            parts.append(AccessibilityText.speed(bps))
            if let eta { parts.append(DownloadSpeedFormat.timeLeftText(eta)) }
        }
        return AccessibilityText.joined(parts)
    }
}
