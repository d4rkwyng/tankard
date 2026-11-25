import Foundation

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
