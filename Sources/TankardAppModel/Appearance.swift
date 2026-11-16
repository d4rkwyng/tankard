import Foundation
import Observation

/// Settings → Appearance.
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case dark, light, system, tankard

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "System"
        case .tankard: return "Tankard"
        }
    }

    public var help: String {
        switch self {
        case .dark: return "Always dark."
        case .light: return "Always light."
        case .system: return "Follows macOS."
        case .tankard: return "Deep purple and amber, like the icon. Dark underneath."
        }
    }

    /// The default for a new install.
    public static let `default` = AppTheme.dark

    /// "dark", "light", "system", "tankard" (case-insensitive); nil otherwise.
    public init?(name: String?) {
        guard let n = name?.lowercased(), let t = AppTheme(rawValue: n) else { return nil }
        self = t
    }

    /// Whether the window is forced dark (Dark and Tankard), light, or
    /// follows the system (nil).
    public var forcesDark: Bool? {
        switch self {
        case .dark, .tankard: return true
        case .light: return false
        case .system: return nil
        }
    }
}

/// The chosen theme, persisted in UserDefaults ("appearance").
@Observable @MainActor
public final class AppearanceSettings {
    public static let defaultsKey = "appearance"

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after every change (the app sets NSApp.appearance here).
    @ObservationIgnored public var onChange: ((AppTheme) -> Void)?

    public var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Self.defaultsKey)
            onChange?(theme)
        }
    }

    /// `override` (TANKARD_APPEARANCE, for screenshots) is used for this
    /// run and not saved; choosing a theme in Settings still saves.
    public init(defaults: UserDefaults = .standard, override: AppTheme? = nil) {
        self.defaults = defaults
        theme = override ?? AppTheme(name: defaults.string(forKey: Self.defaultsKey)) ?? .default
    }
}

/// The Tankard theme's colours (sRGB hex), kept here so the contrast test
/// can check them. The app turns them into SwiftUI colours.
public enum TankardPalette {
    // Backgrounds: the icon plate's purples, darkest to lightest.
    public static let log: UInt32 = 0x170a2e
    public static let window: UInt32 = 0x1f0d3d
    public static let pane: UInt32 = 0x28124d
    public static let strip: UInt32 = 0x2c1556
    public static let bar: UInt32 = 0x331a62
    public static let plate: UInt32 = 0x4a2580
    public static let rowAlternate: UInt32 = 0x251148

    // Text.
    public static let foam: UInt32 = 0xfff6e6       // primary
    public static let lavender: UInt32 = 0xd6c8f0   // secondary
    public static let muted: UInt32 = 0xab9bd0      // tertiary
    // Accent: selection, buttons, progress, the upgrade arrow.
    public static let amber: UInt32 = 0xf2a93b
    /// Text on amber.
    public static let onAmber: UInt32 = 0x1f0d3d
    /// Table selection (key window): amber at 30% over the window purple.
    /// Selected rows keep their own text and badge colours (all AA on it);
    /// tertiary text is drawn as secondary there.
    public static let selection: UInt32 = blend(amber, alpha: 0.30, over: window)
    /// Table selection when the window isn't key: amber at 18%.
    public static let selectionInactive: UInt32 = blend(amber, alpha: 0.18, over: window)

    /// Badge text and its background tint (alpha over the row).
    public struct Badge: Sendable {
        public var text: UInt32
        public var dot: UInt32
        public var tint: UInt32
        public var tintAlpha: Double
    }

    public static let bottle = Badge(text: 0x8fe8a8, dot: 0x4ad97a, tint: 0x30d158, tintAlpha: 0.16)
    public static let source = Badge(text: 0xffc46e, dot: 0xffa53a, tint: 0xff9f0a, tintAlpha: 0.17)
    public static let newer = Badge(text: 0xb0ccff, dot: 0x6fa4ff, tint: 0x408cff, tintAlpha: 0.20)
    public static let noBottle = Badge(text: 0xd2c8e4, dot: 0xa595c4, tint: 0xffffff, tintAlpha: 0.09)
    public static let cask = Badge(text: 0xf3c2ff, dot: 0xd98cff, tint: 0xd98cff, tintAlpha: 0.18)
    public static let badges = [bottle, source, newer, noBottle, cask]

    // MARK: contrast (WCAG 2.x)

    static func channel(_ v: UInt32) -> Double {
        let c = Double(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func luminance(_ hex: UInt32) -> Double {
        0.2126 * channel((hex >> 16) & 0xff) + 0.7152 * channel((hex >> 8) & 0xff) + 0.0722 * channel(hex & 0xff)
    }

    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// `top` at `alpha` over `bottom`, as an opaque colour.
    public static func blend(_ top: UInt32, alpha: Double, over bottom: UInt32) -> UInt32 {
        func mix(_ shift: UInt32) -> UInt32 {
            let t = Double((top >> shift) & 0xff), b = Double((bottom >> shift) & 0xff)
            return UInt32((t * alpha + b * (1 - alpha)).rounded()) << shift
        }
        return mix(16) | mix(8) | mix(0)
    }

    /// Every text/background pair the theme draws, for the AA check.
    public static var textPairs: [(String, UInt32, UInt32)] {
        var pairs: [(String, UInt32, UInt32)] = []
        for (bgName, bg) in [("window", window), ("pane", pane), ("strip", strip), ("bar", bar), ("row", rowAlternate), ("log", log)] {
            pairs.append(("foam on \(bgName)", foam, bg))
            pairs.append(("lavender on \(bgName)", lavender, bg))
            pairs.append(("muted on \(bgName)", muted, bg))
            pairs.append(("amber on \(bgName)", amber, bg))
        }
        pairs.append(("text on amber", onAmber, amber))
        pairs.append(("foam on plate", foam, plate))
        pairs.append(("foam on selection", foam, selection))
        pairs.append(("lavender on selection", lavender, selection))
        pairs.append(("foam on inactive selection", foam, selectionInactive))
        pairs.append(("lavender on inactive selection", lavender, selectionInactive))
        pairs.append(("amber on selection", amber, selection))
        for (i, b) in badges.enumerated() {
            pairs.append(("badge \(i) on selection", b.text, blend(b.tint, alpha: b.tintAlpha, over: selection)))
            pairs.append(("badge \(i) on inactive selection", b.text, blend(b.tint, alpha: b.tintAlpha, over: selectionInactive)))
        }
        for (i, b) in badges.enumerated() {
            for (bgName, bg) in [("window", window), ("row", rowAlternate), ("pane", pane)] {
                pairs.append(("badge \(i) on \(bgName)", b.text, blend(b.tint, alpha: b.tintAlpha, over: bg)))
            }
        }
        return pairs
    }
}
