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
            if persists { defaults.set(theme.rawValue, forKey: Self.defaultsKey) }
            persists = true
            onChange?(theme)
        }
    }
    @ObservationIgnored private var persists = true

    /// Switches theme like Settings does, without saving (testing hook).
    public func preview(_ t: AppTheme) {
        persists = false
        theme = t
    }

    /// `override` (TANKARD_APPEARANCE, for screenshots) is used for this
    /// run and not saved; choosing a theme in Settings still saves.
    public init(defaults: UserDefaults = .standard, override: AppTheme? = nil) {
        self.defaults = defaults
        theme = override ?? AppTheme(name: defaults.string(forKey: Self.defaultsKey)) ?? .default
    }
}

/// One complete set of Tankard theme colours (sRGB hex). Every candidate
/// is a full set, so switching palettes is the one line in
/// `TankardPalette.active`; the contrast test checks them all.
public struct TankardColors: Sendable {
    public var name: String

    // Backgrounds.
    /// The upgrade/install log.
    public var log: UInt32
    /// Window, toolbar and sheets.
    public var window: UInt32
    /// The detail pane.
    public var pane: UInt32
    /// The summary strip above the table.
    public var strip: UInt32
    /// The status bar.
    public var bar: UInt32
    /// The brightest purple: command chips, the selected segment, gradients.
    public var plate: UInt32
    /// Table rows, and every other row's stripe.
    public var table: UInt32
    public var rowAlternate: UInt32
    /// The table's column header.
    public var header: UInt32

    // Text.
    public var foam: UInt32       // primary
    public var lavender: UInt32   // secondary
    public var muted: UInt32      // tertiary
    // Accent: buttons, progress, the upgrade arrow.
    public var amber: UInt32
    /// Text on amber.
    public var onAmber: UInt32
    /// The Installed column, and the Available column when it is the
    /// same version (the upgrade version stays amber). Explicit colours:
    /// in table rows `.secondary`/`.tertiary` resolve to the system's
    /// translucent greys, which came out dim (about 3.5:1 for Available).
    public var versionInstalled: UInt32
    public var versionSame: UInt32

    /// Table selection: `selectionTint` at `selectionAlpha` over the rows
    /// (`selectionInactiveAlpha` when the window isn't key). On the lighter
    /// palettes the tint is a deeper amber, so the rows' own light text,
    /// amber and badges stay AA on it.
    public var selectionTint: UInt32
    public var selectionAlpha: Double
    public var selectionInactiveAlpha: Double

    // Badges.
    public var bottle: TankardPalette.Badge
    public var source: TankardPalette.Badge
    public var newer: TankardPalette.Badge
    public var noBottle: TankardPalette.Badge
    public var cask: TankardPalette.Badge

    public var badges: [TankardPalette.Badge] { [bottle, source, newer, noBottle, cask] }

    public var selection: UInt32 { TankardPalette.blend(selectionTint, alpha: selectionAlpha, over: table) }
    public var selectionInactive: UInt32 { TankardPalette.blend(selectionTint, alpha: selectionInactiveAlpha, over: table) }

    /// Every text/background pair the theme draws, for the AA check.
    public var textPairs: [(String, UInt32, UInt32)] {
        var pairs: [(String, UInt32, UInt32)] = []
        let backgrounds = [("window", window), ("pane", pane), ("strip", strip), ("bar", bar), ("table", table),
                           ("row", rowAlternate), ("log", log)]
        for (bgName, bg) in backgrounds {
            pairs.append(("foam on \(bgName)", foam, bg))
            pairs.append(("lavender on \(bgName)", lavender, bg))
            pairs.append(("muted on \(bgName)", muted, bg))
            pairs.append(("amber on \(bgName)", amber, bg))
        }
        for (bgName, bg) in [("table", table), ("row", rowAlternate), ("selection", selection), ("inactive selection", selectionInactive)] {
            pairs.append(("installed version on \(bgName)", versionInstalled, bg))
            pairs.append(("same available version on \(bgName)", versionSame, bg))
        }
        // The column header carries only titles (primary/secondary) and the sort arrow.
        pairs.append(("foam on header", foam, header))
        pairs.append(("lavender on header", lavender, header))
        pairs.append(("text on amber", onAmber, amber))
        pairs.append(("foam on plate", foam, plate))
        pairs.append(("foam on selection", foam, selection))
        pairs.append(("lavender on selection", lavender, selection))
        pairs.append(("foam on inactive selection", foam, selectionInactive))
        pairs.append(("lavender on inactive selection", lavender, selectionInactive))
        pairs.append(("amber on selection", amber, selection))
        pairs.append(("amber on inactive selection", amber, selectionInactive))
        // The segmented picker: unselected labels on its track (in the
        // toolbar and the summary strip); the selected one is text on amber.
        for (bgName, bg) in [("window", window), ("strip", strip)] {
            pairs.append(("foam on segment track over \(bgName)", foam, TankardPalette.blend(plate, alpha: TankardPalette.segmentTrackAlpha, over: bg)))
        }
        for (i, b) in badges.enumerated() {
            for (bgName, bg) in backgrounds.filter({ $0.0 != "log" }) + [("selection", selection), ("inactive selection", selectionInactive)] {
                pairs.append(("badge \(i) on \(bgName)", b.text, TankardPalette.blend(b.tint, alpha: b.tintAlpha, over: bg)))
            }
        }
        return pairs.map { ("\(name): \($0.0)", $0.1, $0.2) }
    }
}

/// The Tankard theme's colours, kept here so the contrast test can check
/// them. The app turns them into SwiftUI colours.
public enum TankardPalette {
    /// The palette the app draws with. Switching palettes is this one line.
    public static let active = deep

    /// The icon plate's deep purples (#1f0d3d…#4a2580): v0.2's palette,
    /// plus row stripes, the header purple and brighter version columns.
    public static let deep = TankardColors(
        name: "deep",
        log: 0x170a2e, window: 0x1f0d3d, pane: 0x28124d, strip: 0x2c1556, bar: 0x331a62, plate: 0x4a2580,
        table: 0x1f0d3d, rowAlternate: 0x27124c, header: 0x2c1556,
        foam: 0xfff6e6, lavender: 0xd6c8f0, muted: 0xab9bd0, amber: 0xf2a93b, onAmber: 0x1f0d3d,
        versionInstalled: 0xece4f8, versionSame: 0xd6c8f0,
        selectionTint: 0xf2a93b, selectionAlpha: 0.30, selectionInactiveAlpha: 0.18,
        bottle: Badge(text: 0x8fe8a8, dot: 0x4ad97a, tint: 0x30d158, tintAlpha: 0.16),
        source: Badge(text: 0xffc46e, dot: 0xffa53a, tint: 0xff9f0a, tintAlpha: 0.17),
        newer: Badge(text: 0xb0ccff, dot: 0x6fa4ff, tint: 0x408cff, tintAlpha: 0.20),
        noBottle: Badge(text: 0xd2c8e4, dot: 0xa595c4, tint: 0xffffff, tintAlpha: 0.09),
        cask: Badge(text: 0xf3c2ff, dot: 0xd98cff, tint: 0xd98cff, tintAlpha: 0.18))

    /// L1, moderately lighter: still a rich purple, a step or two up.
    /// Tried and not chosen; kept so the comparison can be redone.
    public static let lighter = TankardColors(
        name: "L1",
        log: 0x2e1b54, window: 0x3a2366, pane: 0x4a2d80, strip: 0x4d2f86, bar: 0x52338e, plate: 0x6a42a8,
        table: 0x432873, rowAlternate: 0x4d2e85, header: 0x52338e,
        foam: 0xfff8ec, lavender: 0xe2d8f5, muted: 0xc4b8e2, amber: 0xf6b24a, onAmber: 0x2a1650,
        versionInstalled: 0xf3ecfa, versionSame: 0xe2d8f5,
        selectionTint: 0xa85d08, selectionAlpha: 0.35, selectionInactiveAlpha: 0.20,
        bottle: Badge(text: 0x9cf0b4, dot: 0x4ad97a, tint: 0x30d158, tintAlpha: 0.16),
        source: Badge(text: 0xffcd85, dot: 0xffa53a, tint: 0xff9f0a, tintAlpha: 0.17),
        newer: Badge(text: 0xc2d8ff, dot: 0x6fa4ff, tint: 0x408cff, tintAlpha: 0.20),
        noBottle: Badge(text: 0xe0d8ef, dot: 0xb3a5cf, tint: 0xffffff, tintAlpha: 0.09),
        cask: Badge(text: 0xf7d2ff, dot: 0xd98cff, tint: 0xd98cff, tintAlpha: 0.18))

    /// L2, "lavender dusk": a mid purple. Text and badges go paler to stay
    /// AA. Tried and not chosen. Its version columns reach 6.7:1, short of
    /// the 7:1 target the others meet (see `versionColumnPairs`).
    public static let lavenderDusk = TankardColors(
        name: "L2",
        log: 0x4c3283, window: 0x5b3d94, pane: 0x6a4aa6, strip: 0x6d4dab, bar: 0x6a4aa6, plate: 0x8462c4,
        table: 0x634499, rowAlternate: 0x6a4ba0, header: 0x6d4dab,
        foam: 0xffffff, lavender: 0xf0eafb, muted: 0xe2d9f4, amber: 0xffd68a, onAmber: 0x2a1650,
        versionInstalled: 0xffffff, versionSame: 0xf0eafb,
        selectionTint: 0x7a3e08, selectionAlpha: 0.45, selectionInactiveAlpha: 0.25,
        bottle: Badge(text: 0xb4f7c8, dot: 0x5be08a, tint: 0x30d158, tintAlpha: 0.16),
        source: Badge(text: 0xffe8c6, dot: 0xffb04d, tint: 0xff9f0a, tintAlpha: 0.17),
        newer: Badge(text: 0xdfeaff, dot: 0x8ab6ff, tint: 0x408cff, tintAlpha: 0.20),
        noBottle: Badge(text: 0xf5f1fb, dot: 0xc4b8de, tint: 0xffffff, tintAlpha: 0.09),
        cask: Badge(text: 0xfde9ff, dot: 0xe4a8ff, tint: 0xd98cff, tintAlpha: 0.18))

    /// The custom segmented picker's track: `plate` at this alpha.
    public static let segmentTrackAlpha = 0.55

    /// The version columns against their targets: installed >= 7:1 and an
    /// unchanged Available >= 5.5:1 on the rows and stripes (name, text,
    /// background, target).
    public static func versionColumnPairs(_ p: TankardColors) -> [(String, UInt32, UInt32, Double)] {
        [("table", p.table), ("row", p.rowAlternate)].flatMap { bgName, bg in
            [("\(p.name): installed on \(bgName)", p.versionInstalled, bg, 7.0),
             ("\(p.name): same available on \(bgName)", p.versionSame, bg, 5.5)]
        }
    }

    /// Every defined palette (the contrast test checks each).
    public static let all = [deep, lighter, lavenderDusk]

    /// The icon's own plate colours, for the Intelbrew Dock icon: brand art,
    /// independent of the window palette.
    public static let iconWindow: UInt32 = deep.window
    public static let iconPlate: UInt32 = deep.plate

    // The active palette's colours, by name.
    public static var log: UInt32 { active.log }
    public static var window: UInt32 { active.window }
    public static var pane: UInt32 { active.pane }
    public static var strip: UInt32 { active.strip }
    public static var bar: UInt32 { active.bar }
    public static var plate: UInt32 { active.plate }
    public static var table: UInt32 { active.table }
    public static var rowAlternate: UInt32 { active.rowAlternate }
    public static var header: UInt32 { active.header }
    public static var foam: UInt32 { active.foam }
    public static var lavender: UInt32 { active.lavender }
    public static var muted: UInt32 { active.muted }
    public static var amber: UInt32 { active.amber }
    public static var onAmber: UInt32 { active.onAmber }
    public static var versionInstalled: UInt32 { active.versionInstalled }
    public static var versionSame: UInt32 { active.versionSame }
    public static var selection: UInt32 { active.selection }
    public static var selectionInactive: UInt32 { active.selectionInactive }
    public static var bottle: Badge { active.bottle }
    public static var source: Badge { active.source }
    public static var newer: Badge { active.newer }
    public static var noBottle: Badge { active.noBottle }
    public static var cask: Badge { active.cask }
    public static var badges: [Badge] { active.badges }
    public static var textPairs: [(String, UInt32, UInt32)] { all.flatMap(\.textPairs) }

    /// Badge text and its background tint (alpha over the row).
    public struct Badge: Sendable {
        public var text: UInt32
        public var dot: UInt32
        public var tint: UInt32
        public var tintAlpha: Double
    }

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
}

/// The version columns' text in the system themes (Dark, and Light, which
/// had the same problem: `.tertiary` text on table rows is under 3:1).
/// The row colours are the system's, as rendered in the app's snapshots
/// (lighter than nominal, so the check errs on the safe side).
public enum StandardVersionText {
    public static let darkInstalled: UInt32 = 0xd8d8dc
    public static let darkSame: UInt32 = 0xbcbcc0
    public static let darkRows: [UInt32] = [0x282828, 0x3c3c3c]
    public static let lightInstalled: UInt32 = 0x3c3c43
    public static let lightSame: UInt32 = 0x58585e
    public static let lightRows: [UInt32] = [0xffffff, 0xf4f5f5]

    /// (name, text, background, target), as `TankardPalette.versionColumnPairs`.
    public static var pairs: [(String, UInt32, UInt32, Double)] {
        darkRows.flatMap { [("dark: installed on \(String($0, radix: 16))", darkInstalled, $0, 7.0),
                            ("dark: same available on \(String($0, radix: 16))", darkSame, $0, 5.5)] }
            + lightRows.flatMap { [("light: installed on \(String($0, radix: 16))", lightInstalled, $0, 7.0),
                                   ("light: same available on \(String($0, radix: 16))", lightSame, $0, 5.5)] }
    }
}
