import AppKit
import SwiftUI
import TankardAppModel

extension Color {
    /// A colour with separate light and dark values, resolved by the
    /// view's appearance.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

/// Badge colours from the approved mockup (background, text, dot).
struct BadgePalette {
    var background: Color
    var foreground: Color
    var dot: Color

    /// The system (Dark / Light / System) badges.
    static func standard(_ kind: BadgeKind) -> BadgePalette {
        switch kind {
        case .bottle:
            return BadgePalette(background: Color(light: NSColor(hex: 0xe3f5e6), dark: NSColor(hex: 0x30d158, alpha: 0.16)),
                                foreground: Color(light: NSColor(hex: 0x1d7a35), dark: NSColor(hex: 0x5fdc7c)),
                                dot: Color(light: NSColor(hex: 0x30b14f), dark: NSColor(hex: 0x30d158)))
        case .source:
            return BadgePalette(background: Color(light: NSColor(hex: 0xfdecd9), dark: NSColor(hex: 0xff9f0a, alpha: 0.17)),
                                foreground: Color(light: NSColor(hex: 0xa85300), dark: NSColor(hex: 0xffb340)),
                                dot: Color(light: NSColor(hex: 0xf08a1c), dark: NSColor(hex: 0xff9f0a)))
        case .newer:
            return BadgePalette(background: Color(light: NSColor(hex: 0xe1ecfc), dark: NSColor(hex: 0x408cff, alpha: 0.18)),
                                foreground: Color(light: NSColor(hex: 0x1659b8), dark: NSColor(hex: 0x76aaff)),
                                dot: Color(light: NSColor(hex: 0x2f7ef0), dark: NSColor(hex: 0x409cff)))
        case .noBottle:
            return BadgePalette(background: Color(light: NSColor(hex: 0xececee), dark: NSColor(white: 1, alpha: 0.09)),
                                foreground: Color(light: NSColor(hex: 0x5e5e63), dark: NSColor(hex: 0xa8a8ad)),
                                dot: Color(light: NSColor(hex: 0x9a9aa0), dark: NSColor(hex: 0x8e8e93)))
        case .cask:
            return BadgePalette(background: Color(light: NSColor(hex: 0xefe6fb), dark: NSColor(hex: 0xbf5af2, alpha: 0.18)),
                                foreground: Color(light: NSColor(hex: 0x7a3fb8), dark: NSColor(hex: 0xd49cff)),
                                dot: Color(light: NSColor(hex: 0xaf52de), dark: NSColor(hex: 0xbf5af2)))
        }
    }

    /// A palette theme's badges (Tankard, Dracula; values and their
    /// contrast check live in `TankardColors`).
    static func custom(_ kind: BadgeKind, _ p: TankardColors) -> BadgePalette {
        let b: TankardPalette.Badge
        switch kind {
        case .bottle: b = p.bottle
        case .source: b = p.source
        case .newer: b = p.newer
        case .noBottle: b = p.noBottle
        case .cask: b = p.cask
        }
        return BadgePalette(background: Color(hex: b.tint, alpha: b.tintAlpha), foreground: Color(hex: b.text), dot: Color(hex: b.dot))
    }
}

/// The colours a view draws with, for the chosen appearance. Read from the
/// environment (`@Environment(\.theme)`), so sheets and the Settings window
/// follow a change at once.
struct Theme {
    var kind: AppTheme
    var strip: Color
    var pane: Color
    var bar: Color
    var logBackground: Color
    var logText: Color
    var logArrow: Color
    var logGood: Color
    var chip: Color
    var accent: Color
    /// Text on an accent-filled button or selection.
    var onAccent: Color
    /// "Upgrade available": arrows, versions, the upgrade-ready line.
    var upgrade: Color
    /// The window background; nil = the system's.
    var window: Color?
    /// The table's background (its rows); nil = the system's.
    var table: Color?
    /// Version columns: the installed version, and an Available version
    /// that is the same (see `TankardColors.versionInstalled`).
    var versionInstalled: Color
    var versionSame: Color
    /// The palette for Tankard and Dracula; nil for the system themes. All
    /// themes share the same layout code: a palette only changes colours.
    var palette: TankardColors?
    var isCustom: Bool { palette != nil }

    func badge(_ kind: BadgeKind) -> BadgePalette {
        palette.map { BadgePalette.custom(kind, $0) } ?? BadgePalette.standard(kind)
    }

    static let standard = Theme(
        kind: .dark,
        strip: Color(light: NSColor(hex: 0xfbfbfb), dark: NSColor(hex: 0x232323)),
        pane: Color(light: NSColor(hex: 0xfafafa), dark: NSColor(hex: 0x232323)),
        bar: Color(light: NSColor(hex: 0xf6f6f6), dark: NSColor(hex: 0x2c2c2c)),
        logBackground: Color(light: NSColor(hex: 0xfbfbfb), dark: NSColor(hex: 0x161616)),
        logText: Color(light: NSColor(hex: 0x2b2b2b), dark: NSColor(hex: 0xe2e2e2)),
        logArrow: Color(light: NSColor(hex: 0x2f7ef0), dark: NSColor(hex: 0x5ea0ff)),
        logGood: Color(light: NSColor(hex: 0x2b9a46), dark: NSColor(hex: 0x5fdc7c)),
        chip: Color(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.07)),
        accent: .accentColor,
        onAccent: .white,
        upgrade: .accentColor,
        window: nil,
        table: nil,
        versionInstalled: Color(light: NSColor(hex: StandardVersionText.lightInstalled), dark: NSColor(hex: StandardVersionText.darkInstalled)),
        versionSame: Color(light: NSColor(hex: StandardVersionText.lightSame), dark: NSColor(hex: StandardVersionText.darkSame)),
        palette: nil)

    /// A palette theme (Tankard, Dracula).
    static func custom(_ kind: AppTheme, _ p: TankardColors) -> Theme {
        Theme(
            kind: kind,
            strip: Color(hex: p.strip),
            pane: Color(hex: p.pane),
            bar: Color(hex: p.bar),
            logBackground: Color(hex: p.log),
            logText: Color(hex: p.foam),
            logArrow: Color(hex: p.accent),
            logGood: Color(hex: p.bottle.text),
            chip: Color(hex: p.plate, alpha: 0.55),
            accent: Color(hex: p.accent),
            onAccent: Color(hex: p.onAccent),
            upgrade: Color(hex: p.upgrade),
            window: Color(hex: p.window),
            table: Color(hex: p.table),
            versionInstalled: Color(hex: p.versionInstalled),
            versionSame: Color(hex: p.versionSame),
            palette: p)
    }

    static func of(_ t: AppTheme) -> Theme {
        if let p = TankardPalette.palette(for: t) { return custom(t, p) }
        var s = standard
        s.kind = t
        return s
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.standard
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Applies a theme to a view tree: the environment value, the accent
/// (`tint`), and for Tankard and Dracula the text hierarchy and backgrounds. Used on
/// the main window, every sheet and the Settings window.
struct Themed: ViewModifier {
    var theme: Theme

    func body(content: Content) -> some View {
        if let p = theme.palette {
            content
                .environment(\.theme, theme)
                .tint(theme.accent)
                .foregroundStyle(Color(hex: p.foam), Color(hex: p.lavender), Color(hex: p.muted))
                .background(theme.window ?? .clear)
                .toolbarBackground(theme.window ?? .clear, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        } else {
            content
                .environment(\.theme, theme)
        }
    }
}

extension View {
    func themed(_ theme: Theme) -> some View { modifier(Themed(theme: theme)) }
}

/// Sets the app's NSAppearance for a theme: forced dark (Dark, Tankard),
/// forced light, or the system's (nil).
@MainActor
func applyAppearance(_ t: AppTheme) {
    switch t.forcesDark {
    case true?: NSApp.appearance = NSAppearance(named: .darkAqua)
    case false?: NSApp.appearance = NSAppearance(named: .aqua)
    case nil: NSApp.appearance = nil
    }
}

/// The coloured capsule in the Source column.
struct SourceBadge: View {
    var kind: BadgeKind
    var label: String
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.theme) private var theme

    var body: some View {
        let p = theme.badge(kind)
        // Palette themes paint their own selection: badges keep their colours.
        let selected = prominence == .increased && !theme.isCustom
        let onSelection = Color.white
        HStack(spacing: 5) {
            Circle().fill(selected ? onSelection : p.dot).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? onSelection : p.foreground)
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .frame(height: 19)
        .background(Capsule().fill(selected ? onSelection.opacity(0.16) : p.background))
        .fixedSize()
    }
}

/// The logo in the toolbar and sheets: the Intelbrew "i" mug in Intelbrew
/// mode, Tankard's own mark otherwise. Drawn with no interpolation so the
/// pixels stay sharp; sizes of 32, 64 and 128 points are a whole-number
/// fraction or multiple of the 128 px art on 1x and 2x screens.
struct BrandMark: View {
    var size: CGFloat = 32
    var intelbrew = false

    var body: some View {
        if let logo = intelbrew ? AppResources.intelbrewMug : AppResources.tankardMark {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.none)
                .frame(width: size, height: size)
                .accessibilityLabel(intelbrew ? "Intelbrew" : "Tankard")
        } else {
            Image(systemName: "mug.fill")
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: size, height: size)
                .accessibilityLabel("Tankard")
        }
    }
}

/// Lays children out left to right, wrapping (for the package chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// A command in monospace with a copy button.
struct CommandBox: View {
    var command: String
    @Environment(\.theme) private var theme
    // `State(...)` rather than `@State`: in the macOS 27 SDK `@State` is a
    // macro whose plugin (SwiftUIMacros) ships with Xcode, not the Command
    // Line Tools. The struct itself works the same way everywhere.
    private let copiedState = State(initialValue: false)
    private var copied: Bool {
        get { copiedState.wrappedValue }
        nonmutating set { copiedState.wrappedValue = newValue }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copyToPasteboard(command)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help("Copy command")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.chip))
    }
}

/// A segmented picker. The system one (NSSegmentedControl) draws its
/// selected segment in a fixed grey that ignores `.tint` and
/// `selectedSegmentBezelColor` under SwiftUI, so the palette themes draw
/// their own: an accent-filled selected segment (amber in Tankard, purple
/// in Dracula) on a track. Other themes get the system control.
struct ThemedSegmentedPicker<Value: Hashable & Identifiable>: View {
    var title: String
    @Binding var selection: Value
    var options: [Value]
    var label: (Value) -> String
    @Environment(\.theme) private var theme

    var body: some View {
        if let p = theme.palette {
            HStack(spacing: 2) {
                ForEach(options) { option in
                    let selected = option == selection
                    Button {
                        selection = option
                    } label: {
                        Text(label(option))
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? theme.onAccent : Color(hex: p.foam))
                            .padding(.horizontal, 10)
                            .frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? theme.accent : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: p.plate, alpha: TankardPalette.segmentTrackAlpha)))
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        } else {
            Picker(title, selection: $selection) {
                ForEach(options) { option in Text(label(option)).tag(option) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// A version number in a table column: the installed version (`same:
/// false`) or an Available version equal to it (`same: true`). White on
/// the system's accent selection; palette themes' selections keep the colours.
struct VersionText: View {
    var text: String
    var same = false
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .foregroundStyle(prominence == .increased && !theme.isCustom ? Color.white
                             : same ? theme.versionSame : theme.versionInstalled)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
