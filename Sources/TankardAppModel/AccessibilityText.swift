import Foundation
import TankardCore

// 0.9.3: what VoiceOver says for controls whose visible words don't say
// enough on their own (the bottle notice's "Show", a decorative icon), and
// the identifiers of those controls. The views read them from here so the
// tests can check the words and the catalog has the keys.

public enum AccessibilityText {
    /// The hint for the window banner's Show and the menu-bar notice:
    /// where they go (Installed ▸ Bottle available). The banner's button
    /// keeps its visible name, "Show", as its label (Voice Control's
    /// "Click Show" still works); this says what it shows.
    public static var showBottleAvailableHint: String {
        String(localized: "Shows the Bottle available list")
    }

    /// The hint for the banner's Replace with Bottle: the same words as
    /// the Bottle available list's Replace all.
    public static var replaceWithBottleHint: String {
        String(localized: "Reinstall each one from a ready-made download instead of building it")
    }

    /// The hint for the menu-bar notice of new vulnerabilities: the same
    /// words as the panel's scan line.
    public static var showVulnerableHint: String {
        String(localized: "Show vulnerable packages in Tankard")
    }

    /// The Available column's upgrade arrow and version, read as one
    /// element (VoiceOver read the arrow as "Up Arrow"). The same words as
    /// its tooltip.
    public static func upgradeAvailable(_ version: String) -> String {
        String(localized: "Upgrade available: \(version)")
    }

    /// The toolbar's spinner while a refresh runs (VoiceOver read only
    /// "progress indicator"): the refresh's phase, or "Refreshing".
    public static func refreshing(phase: String?) -> String {
        phase ?? String(localized: "Refreshing")
    }

    // MARK: 0.10, the sheet's download speed (UpgradeSession+Speed.swift)

    /// "Downloading font-inter" (the visible line's "Downloading font-inter…"
    /// without the ellipsis, as a comma follows).
    public static func downloading(_ name: String) -> String {
        String(localized: "Downloading \(name)")
    }

    /// "2.1 of 2.3 GB", "91 percent"; "12.3 MB so far" (as shown) when the
    /// total is unknown.
    public static func downloadSize(_ d: DownloadProgress) -> [String] {
        guard let total = d.total, let pct = d.percent else { return [d.detail] }
        let done = DownloadSizeFormat.pieces(d.bytes, scale: total)
        let all = DownloadSizeFormat.pieces(total, scale: total)
        let unit = DownloadProgress.unit(all.unit)
        return [String(localized: "\(done.number) of \(all.number) \(unit)"), percent(pct)]
    }

    /// "91 percent" (VoiceOver reads "(91%)" with its brackets).
    public static func percent(_ pct: Int) -> String {
        String(localized: "\(pct) percent")
    }

    /// "4.2 megabytes per second": the number as shown, the unit in words.
    public static func speed(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        let p = DownloadSpeedFormat.pieces(bytesPerSecond: bytesPerSecond, locale: locale)
        switch p.unit {
        case .kilobytes: return String(localized: "\(p.number) kilobytes per second")
        case .megabytes: return String(localized: "\(p.number) megabytes per second")
        case .gigabytes: return String(localized: "\(p.number) gigabytes per second")
        }
    }

    /// 0.10 (review): the time left as VoiceOver reads it, the units in
    /// full words and in the number's plural form ("about 1 minute left",
    /// "about 20 seconds left", "about 1 hour and 5 minutes left"); the
    /// visible "min"/"sec" would be read as abbreviations.
    public static func timeLeft(_ seconds: TimeInterval) -> String {
        switch DownloadSpeedFormat.timeLeft(seconds) {
        case .fewSeconds: return String(localized: "a few seconds left")
        case .seconds(let s): return String(localized: "about \(s) seconds left", bundle: L10n.bundle)
        case .minutes(let m): return String(localized: "about \(m) minutes left", bundle: L10n.bundle)
        case .hours(let h, 0): return String(localized: "about \(h) hours left", bundle: L10n.bundle)
        case .hours(let h, let m):
            let minutes = String(localized: "\(m) minutes", bundle: L10n.bundle)
            return String(localized: "about \(h) hours and \(minutes) left", bundle: L10n.bundle)
        }
    }

    /// The spoken pieces of a status line, read as one sentence: the
    /// visible " · " becomes a comma.
    public static func joined(_ parts: [String]) -> String {
        parts.joined(separator: ", ")
    }

    /// accessibilityIdentifier values, for UI scripting and any later UI tests.
    public enum ID {
        public static let bottleNotice = "bottle-notice"
        public static let bottleNoticeShow = "bottle-notice.show"
        public static let bottleNoticeReplace = "bottle-notice.replace"
        public static let bottleNoticeClose = "bottle-notice.close"
        public static let bottleMenuNotice = "menu.bottle-notice"
        public static let vulnerabilityMenuNotice = "menu.vulnerability-notice"
        public static let refreshProgress = "toolbar.refresh-progress"
    }
}
