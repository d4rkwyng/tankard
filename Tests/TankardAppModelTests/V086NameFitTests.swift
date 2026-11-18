import CoreGraphics
import Foundation
import Testing
@testable import TankardAppModel

// 0.8.6 (UI sweep M1): names collapsed to "…" while their badges kept full
// width. openssl@4, a pinned dependency with 4 vulnerabilities, at the
// Package column's widths: 200 pt (ideal, the default 1040 pt window) and
// 150 pt (its minimum, the 820 pt minimum window), less the trailing
// marks. Badge widths as drawn: words "dep pinned Vulnerable · 4" about
// 140 pt, icons only about 44 pt.

struct V086NameFitTests {
    static let words: CGFloat = 140, icons: CGFloat = 44
    static func badges(_ w: CGFloat) -> CGFloat { w >= words ? words : w >= icons ? icons : 0 }
    // "openssl@4" at 13 pt medium: about 62 pt; a long name: 180 pt, its first 12 characters 80 pt.

    @Test func defaultWindowKeepsTheWholeName() {
        // 200 pt: the whole name and the badges as icons (0.8.5: the badges'
        // words, and 56 pt left for the name: "…").
        let a = NameFit.allocate(width: 200, nameIdeal: 62, nameMin: 62, spacing: 4, noteIdeal: 0, badges: Self.badges)
        #expect(a.name == 62 && a.badges == Self.icons)
        // A wider column: words.
        let w = NameFit.allocate(width: 260, nameIdeal: 62, nameMin: 62, spacing: 4, noteIdeal: 0, badges: Self.badges)
        #expect(w.name == 62 && w.badges == Self.words)
    }

    @Test func minimumWindowKeepsTheName() {
        // 150 pt column: icons next to the whole name.
        let a = NameFit.allocate(width: 150, nameIdeal: 62, nameMin: 62, spacing: 4, noteIdeal: 0, badges: Self.badges)
        #expect(a.name == 62 && a.badges == Self.icons)
        // With the password lock and ⓘ at the end (2 × 18 + 2 pt, 4 pt gap):
        // no room for the icons either; the name stays whole, the tooltip lists the badges.
        let b = NameFit.allocate(width: 150 - 38 - 4, nameIdeal: 62, nameMin: 62, spacing: 4, noteIdeal: 0, badges: Self.badges)
        #expect(b.name == 62 && b.badges == 0)
    }

    @Test func longNameKeepsTwelveCharacters() {
        // 0.8.5 gave the badges 140 pt and the name what was left (56 pt: "…").
        let a = NameFit.allocate(width: 200, nameIdeal: 180, nameMin: 80, spacing: 4, noteIdeal: 0, badges: Self.badges)
        #expect(a.badges == Self.icons && a.name == 200 - Self.icons - 4)
        #expect(a.name >= 80)
        // Too narrow even for icons: the badges go (the tooltip lists them), the name stays.
        let b = NameFit.allocate(width: 110, nameIdeal: 180, nameMin: 80, spacing: 4, noteIdeal: 0, badges: Self.badges)
        #expect(b.badges == 0 && b.name == 110)
    }

    @Test func noteGetsWhatIsLeft() {
        let a = NameFit.allocate(width: 300, nameIdeal: 62, nameMin: 62, spacing: 4, noteIdeal: 200, badges: Self.badges)
        #expect(a.name == 62 && a.badges == Self.words && a.note == 300 - 62 - 140 - 8)
        let b = NameFit.allocate(width: 200, nameIdeal: 62, nameMin: 62, spacing: 4, noteIdeal: 200, badges: { _ in 0 })
        #expect(b.badges == 0 && b.note == 200 - 62 - 4)
    }
}
