import Foundation
import Testing
@testable import TankardAppModel

// 0.8.7: type-select in the package lists matches the package name shown,
// not other text in the row (a note such as "No bottle: …").

struct V087TypeSelectTests {
    /// The Intel demo's Installed list, in the order shown.
    let names = ["ca-certificates", "curl-impersonate", "expat", "gettext", "json-c", "libsodium",
                 "libunistring", "libyaml", "lua", "lz4", "mpdecimal", "ncurses", "openssl@4",
                 "python@3.15", "readline", "ruby", "sqlite", "vim", "xz", "zstd"]

    @Test func firstLetterSelectsFirstNameWithIt() {
        var t = TypeSelect()
        #expect(t.select("o", at: 0, names: names, selected: nil) == 12)
        t.reset()
        #expect(t.select("l", at: 0, names: names, selected: nil) == 5)
        t.reset()
        #expect(t.select("z", at: 0, names: names, selected: nil) == 19)
    }

    /// "b" used to jump to openssl@4 (its note reads "No bottle: …"); no
    /// name starts with "b", so nothing is selected.
    @Test func letterWithNoNameSelectsNothing() {
        var t = TypeSelect()
        #expect(t.select("b", at: 0, names: names, selected: nil) == nil)
        t.reset()
        #expect(t.select("h", at: 0, names: names, selected: 3) == nil)
    }

    @Test func caseInsensitive() {
        var t = TypeSelect()
        #expect(t.select("P", at: 0, names: names, selected: nil) == 13)
        #expect(TypeSelect.matches("Visual Studio Code", prefix: "vis"))
        #expect(TypeSelect.matches("café", prefix: "CAFE"))
        #expect(!TypeSelect.matches("vim", prefix: ""))
    }

    /// Letters typed within the timeout refine the search from the
    /// selected row.
    @Test func multiLetterRefines() {
        var t = TypeSelect()
        var sel = t.select("l", at: 0, names: names, selected: nil)
        #expect(sel == 5) // libsodium
        sel = t.select("u", at: 0.3, names: names, selected: sel)
        #expect(sel == 8) // lua
        sel = t.select("a", at: 0.6, names: names, selected: sel)
        #expect(sel == 8)
        #expect(t.buffer == "lua")
        sel = t.select("z", at: 0.9, names: names, selected: sel)
        #expect(sel == nil) // "luaz"
        var u = TypeSelect()
        #expect(u.select("l", at: 0, names: names, selected: nil) == 5)
        #expect(u.select("z", at: 0.2, names: names, selected: 5) == 9) // lz4
    }

    /// After the timeout a key starts a new search, from the top.
    @Test func pauseStartsNewSearch() {
        var t = TypeSelect()
        #expect(t.select("x", at: 0, names: names, selected: nil) == 18)
        #expect(t.select("c", at: 0 + TypeSelect.timeout + 0.1, names: names, selected: 18) == 0)
        #expect(t.buffer == "c")
    }

    /// A new search goes to the first match from the top even when the
    /// selection is further down.
    @Test func newSearchIgnoresSelection() {
        var t = TypeSelect()
        #expect(t.select("c", at: 0, names: names, selected: 1) == 0)
    }

    @Test func refinementWrapsRoundToTop() {
        #expect(TypeSelect.match("c", in: names, selected: 17) == 0)
        #expect(TypeSelect.match("cu", in: names, selected: 1) == 1)
        #expect(TypeSelect.match("q", in: names, selected: 4) == nil)
        #expect(TypeSelect.match("a", in: [], selected: nil) == nil)
        #expect(TypeSelect.match("v", in: names, selected: 99) == 17)
    }

    @Test func whichKeysTakePart() {
        #expect(TypeSelect.isTypeSelectInput("a", bufferEmpty: true))
        #expect(TypeSelect.isTypeSelectInput("@", bufferEmpty: false))
        #expect(TypeSelect.isTypeSelectInput("3", bufferEmpty: true))
        #expect(!TypeSelect.isTypeSelectInput(" ", bufferEmpty: true))
        #expect(TypeSelect.isTypeSelectInput(" ", bufferEmpty: false))
        #expect(!TypeSelect.isTypeSelectInput("\r", bufferEmpty: true))
        #expect(!TypeSelect.isTypeSelectInput("\t", bufferEmpty: true))
        #expect(!TypeSelect.isTypeSelectInput("\u{1B}", bufferEmpty: true))
        #expect(!TypeSelect.isTypeSelectInput("\u{7F}", bufferEmpty: true))
        #expect(!TypeSelect.isTypeSelectInput("\u{F700}", bufferEmpty: true)) // up arrow
        #expect(!TypeSelect.isTypeSelectInput("", bufferEmpty: true))
    }
}
