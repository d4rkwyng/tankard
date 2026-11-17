import Foundation

/// v0.4: the vulnerability warning's colours (the table's ⚠ tag, the
/// detail pane's list, the strip's count) in every theme. One red per
/// theme: the severity is in the words, not the colour. Kept here so the
/// contrast test can check every text/background pair at WCAG AA.
public enum VulnerabilityColors {
    public struct Style: Sendable, Equatable {
        /// Text and the warning icon.
        public var text: UInt32
        /// The tag's fill, drawn at `tintAlpha` over the row.
        public var tint: UInt32
        public var tintAlpha: Double
    }

    /// System Dark (and System in dark mode).
    public static let dark = Style(text: 0xffb0a8, tint: 0xff453a, tintAlpha: 0.18)
    /// System Light (and System in light mode).
    public static let light = Style(text: 0xb3261e, tint: 0xff3b30, tintAlpha: 0.12)
    /// Tankard: a warm coral that holds up on the deep purples and the amber selection.
    public static let tankard = Style(text: 0xffc6bf, tint: 0xff6b5e, tintAlpha: 0.18)
    /// Dracula's red (#ff5555), lightened for text as the theme's pink and greys are.
    public static let dracula = Style(text: 0xffbdbd, tint: 0xff5555, tintAlpha: 0.14)

    public static func style(_ theme: AppTheme, dark isDark: Bool) -> Style {
        switch theme {
        case .tankard: return tankard
        case .dracula: return dracula
        case .dark: return dark
        case .light: return light
        case .system: return isDark ? dark : light
        }
    }

    /// The backgrounds the warning is drawn on, per theme: rows, stripes,
    /// the detail pane and the summary strip (and the palettes' own
    /// selections; the system themes draw the tag white on their selection).
    static func backgrounds(_ theme: AppTheme, dark isDark: Bool) -> [(String, UInt32)] {
        if let p = TankardPalette.palette(for: theme) {
            return [("table", p.table), ("row", p.rowAlternate), ("pane", p.pane), ("strip", p.strip), ("window", p.window),
                    ("selection", p.selection), ("inactive selection", p.selectionInactive)]
        }
        if isDark || theme == .dark {
            return StandardVersionText.darkRows.map { ("row \(String($0, radix: 16))", $0) } + [("pane", 0x232323), ("strip", 0x232323), ("window", 0x1e1e1e)]
        }
        return StandardVersionText.lightRows.map { ("row \(String($0, radix: 16))", $0) } + [("pane", 0xfafafa), ("strip", 0xfbfbfb), ("window", 0xececec)]
    }

    /// Every pair for the AA (4.5:1) check: the text on its tag's tint over
    /// each background, and the bare text (pane list, strip) on each.
    public static var textPairs: [(String, UInt32, UInt32)] {
        let themes: [(AppTheme, Bool)] = [(.dark, true), (.light, false), (.system, true), (.system, false), (.tankard, true), (.dracula, true)]
        return themes.flatMap { theme, isDark -> [(String, UInt32, UInt32)] in
            let s = style(theme, dark: isDark)
            let name = theme == .system ? "system (\(isDark ? "dark" : "light"))" : theme.rawValue
            return backgrounds(theme, dark: isDark).flatMap { bgName, bg in
                [("\(name): warning text on \(bgName)", s.text, bg),
                 ("\(name): warning tag on \(bgName)", s.text, TankardPalette.blend(s.tint, alpha: s.tintAlpha, over: bg))]
            }
        }
    }
}
