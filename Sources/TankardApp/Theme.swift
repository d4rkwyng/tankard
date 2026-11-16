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

    static func of(_ kind: BadgeKind) -> BadgePalette {
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
}

enum Theme {
    static let strip = Color(light: NSColor(hex: 0xfbfbfb), dark: NSColor(hex: 0x232323))
    static let pane = Color(light: NSColor(hex: 0xfafafa), dark: NSColor(hex: 0x232323))
    static let bar = Color(light: NSColor(hex: 0xf6f6f6), dark: NSColor(hex: 0x2c2c2c))
    static let logBackground = Color(light: NSColor(hex: 0xfbfbfb), dark: NSColor(hex: 0x161616))
    static let logText = Color(light: NSColor(hex: 0x2b2b2b), dark: NSColor(hex: 0xe2e2e2))
    static let logArrow = Color(light: NSColor(hex: 0x2f7ef0), dark: NSColor(hex: 0x5ea0ff))
    static let logGood = Color(light: NSColor(hex: 0x2b9a46), dark: NSColor(hex: 0x5fdc7c))
    static let chip = Color(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.07))
}

/// The coloured capsule in the Source column.
struct SourceBadge: View {
    var kind: BadgeKind
    var label: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let p = BadgePalette.of(kind)
        let selected = prominence == .increased
        HStack(spacing: 5) {
            Circle().fill(selected ? Color.white : p.dot).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.white : p.foreground)
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .frame(height: 19)
        .background(Capsule().fill(selected ? Color.white.opacity(0.22) : p.background))
        .fixedSize()
    }
}

/// The toolbar mark: the Intelbrew logo in Intelbrew mode, a mug otherwise.
struct BrandMark: View {
    var intelbrew: Bool
    var size: CGFloat = 28

    var body: some View {
        if intelbrew, let logo = (size > 40 ? AppResources.intelbrewLogoLarge : AppResources.intelbrewLogo) {
            Image(nsImage: logo)
                .resizable()
                .interpolation(size > 40 ? .high : .none)
                .frame(width: size, height: size)
                .accessibilityLabel("Intelbrew")
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
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
    }
}
