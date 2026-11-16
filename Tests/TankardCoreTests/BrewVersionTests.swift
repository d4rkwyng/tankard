import Testing
@testable import TankardCore

/// Expected results follow brew's Version#<=> (version.rb, brew 7.0.14),
/// including its test suite's cases where they apply.
struct BrewVersionTests {
    func cmp(_ a: String, _ b: String) -> Int? { BrewVersion(a).compare(to: BrewVersion(b)) }

    @Test(arguments: [
        ("1.0", "1.0", 0),
        ("1.0", "1.0.0", 0),          // trailing zeros don't count
        ("1.0.1", "1.0", 1),
        ("1.10", "1.9", 1),           // numeric, not lexical
        ("2.0", "10.0", -1),
        ("3.54.1", "3.54.0", 1),
        ("1.0a1", "1.0", -1),         // alpha < release
        ("1.0b1", "1.0a2", 1),        // beta > alpha
        ("1.0rc1", "1.0b9", 1),       // rc > beta
        ("1.0pre1", "1.0b1", 1),      // pre > beta
        ("1.0rc1", "1.0pre9", 1),     // rc > pre
        ("1.0rc1", "1.0", -1),        // rc < release
        ("1.0rc2", "1.0rc10", -1),
        ("1.0p1", "1.0", 1),          // patch > release
        ("1.0.post1", "1.0", 1),      // post > release
        ("1.0alpha", "1.0beta", -1),
        ("2026-11-05", "2026-10-29", 1), // date-versioned (ca-certificates)
        ("20260817.0", "20260527.1", 1),
        ("r3222", "r3108", 1),        // x264
        ("3.6.11-0102f49a", "3.6.10-ffeefe5d", 1),   // hash-suffixed cask
        ("3.30.14,5f54c8173e", "3.29.15,86776fcb52", 1), // comma cask version
        ("0.4.28,2", "0.4.28,1", 1),
        ("HEAD", "99.0", 1),          // HEAD beats any release
        ("HEAD-abc1234", "HEAD-def5678", 0),
        ("1.2.3", "HEAD", -1),
        ("123456789012345678901234567890", "123456789012345678901234567889", 1), // > Int64
        ("1.01", "1.1", 0),           // leading zeros are numeric
    ])
    func compare(a: String, b: String, expected: Int) {
        #expect(cmp(a, b) == expected, "\(a) vs \(b)")
        #expect(cmp(b, a) == -expected, "\(b) vs \(a) (antisymmetry)")
    }

    @Test func tokenization() {
        let kinds = BrewVersion("1.0rc1-beta2.post3").tokens.map(\.kind)
        #expect(kinds == [.numeric, .numeric, .rc, .beta, .post])
        // "preview": brew scans "pre" then "view".
        #expect(BrewVersion("1.0preview").tokens.map(\.value) == ["1", "0", "pre", "view"])
    }

    @Test(arguments: [
        ("1.5.7_1", "1.5.7", 1),
        ("1.5.7_2", "1.5.7_10", -1),  // revisions compare numerically
        ("4.0.0_1", "4.0.0_2", -1),
        ("1.5.8", "1.5.7_9", 1),      // version beats revision
        ("1.5.7", "1.5.7_0", 0),
    ])
    func pkgVersion(a: String, b: String, expected: Int) {
        #expect(PkgVersion(parsing: a).compare(to: PkgVersion(parsing: b)) == expected)
    }

    @Test func pkgVersionParsing() {
        let v = PkgVersion(parsing: "18.6_2")
        #expect(v.version.raw == "18.6")
        #expect(v.revision == 2)
        #expect(v.description == "18.6_2")
        // Only a trailing _<digits> is a revision.
        #expect(PkgVersion(parsing: "1_beta").revision == 0)
        #expect(PkgVersion(parsing: "2026_11").version.raw == "2026")
    }
}
