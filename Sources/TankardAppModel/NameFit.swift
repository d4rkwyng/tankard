import CoreGraphics
import Foundation

/// 0.8.6: how the Package column's cell shares its width between the name,
/// its badges ("dep", "pinned", "Deprecated", "Vulnerable · 4") and the
/// row's note. In 0.8.5 the badges kept their full width and the name
/// collapsed to "…" ("… dep pinned Vulnerable · 4" for openssl@4, even at
/// the default window size). Now the name keeps up to `nameChars`
/// characters; the badges get what is left, as words, as icons only, or
/// not at all (the name's tooltip lists them); the name gets the rest up to
/// its full width, and the note what remains after that.
public enum NameFit {
    /// The name never shrinks below this many characters for the badges.
    public static let nameChars = 12

    public struct Allocation: Equatable, Sendable {
        public var name: CGFloat
        public var badges: CGFloat
        public var note: CGFloat
    }

    /// `width`: the space for name, badges and note. `nameIdeal`: the
    /// name's full width; `nameMin`: the width of its first `nameChars`
    /// characters. `badges(w)`: the width the badges take when offered `w`
    /// (the widest of words / icons / nothing that fits). `noteIdeal`: the
    /// note's full width.
    public static func allocate(width: CGFloat, nameIdeal: CGFloat, nameMin: CGFloat, spacing: CGFloat,
                                noteIdeal: CGFloat, badges: (CGFloat) -> CGFloat) -> Allocation {
        let keep = min(nameIdeal, nameMin)
        let offered = max(0, width - keep - spacing)
        let b = min(badges(offered), offered)
        let afterBadges = width - (b > 0 ? b + spacing : 0)
        let name = max(0, min(nameIdeal, afterBadges))
        let rest = afterBadges - name - spacing
        let note = noteIdeal > 0 && rest > 0 ? min(noteIdeal, rest) : 0
        return Allocation(name: name, badges: b, note: note)
    }
}
