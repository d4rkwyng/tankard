import Foundation
import Testing
@testable import TankardCore

/// 0.8: install counts from formulae.brew.sh's bulk analytics files.
struct InstallAnalyticsTests {
    func doc(_ key: String, _ rows: [(String, String)], end: String = "2026-11-17") -> Data {
        let items = rows.map { #"{"number":1,"\#(key)":"\#($0.0)","count":\#($0.1),"percent":"0.5"}"# }
        return Data(#"{"category":"x","total_items":\#(rows.count),"start_date":"2026-10-18","end_date":"\#(end)","total_count":9,"items":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    @Test func decodesMergesAndKeysLikeCatalogIDs() throws {
        let a = try InstallAnalytics.decode([
            (.formula, .days30, doc("formula", [("xz", #""327,759""#), ("hashicorp/tap/terraform", #""1,234""#),
                                                ("hello", #""17,697""#), ("hello --HEAD", #""8""#)])),
            (.formula, .days90, doc("formula", [("xz", #""1,001,234""#)], end: "2026-11-16")),
            (.formula, .days365, doc("formula", [("xz", "4100000")])), // a plain integer is fine too
            (.cask, .days30, doc("cask", [("firefox", #""13,167""#), ("anthropics/tap/ant", #""42""#)])),
            (.cask, .days365, doc("cask", [("firefox", #""182,009""#)])),
        ])
        #expect(a["formula:homebrew/core/xz"] == InstallCounts(days30: 327_759, days90: 1_001_234, days365: 4_100_000))
        // Another tap's package keeps its qualified name; missing windows are 0.
        #expect(a["formula:hashicorp/tap/terraform"] == InstallCounts(days30: 1234))
        // Option variants count toward the package.
        #expect(a["formula:homebrew/core/hello"]?.days30 == 17_705)
        #expect(a["cask:homebrew/cask/firefox"] == InstallCounts(days30: 13_167, days90: 0, days365: 182_009))
        #expect(a["cask:anthropics/tap/ant"]?.days30 == 42)
        // Formulae and casks don't mix, and an unknown package has nothing.
        #expect(a["formula:homebrew/core/firefox"] == nil)
        #expect(a["formula:homebrew/core/nope"] == nil)
        // The 30-day file's end date.
        #expect(a.endDate == "2026-11-17")
        #expect(a.popularity["formula:homebrew/core/xz"] == 327_759)
    }

    @Test func idsMatchCatalogEntries() {
        let xz = CatalogEntry(kind: .formula, name: "xz", fullName: "xz", tap: "homebrew/core", desc: nil, bottle: .forThisMac)
        let ff = CatalogEntry(kind: .cask, name: "firefox", fullName: "firefox", tap: "homebrew/cask", desc: nil, bottle: .cask)
        #expect(InstallAnalytics.id(kind: .formula, name: "xz") == xz.id)
        #expect(InstallAnalytics.id(kind: .cask, name: "firefox") == ff.id)
        #expect(AnalyticsPeriod.days90.endpoint(.formula) == "analytics/install/90d.json")
        #expect(AnalyticsPeriod.days365.endpoint(.cask) == "analytics/cask-install/365d.json")
    }

    @Test func badShapeThrows() {
        #expect(throws: (any Error).self) { try InstallAnalytics.decode([(.formula, .days30, Data("[]".utf8))]) }
    }

    /// Review: one unreadable count used to throw the whole file (and every
    /// count) away; now only that entry is skipped.
    @Test func badCountSkipsOnlyThatEntry() throws {
        let a = try InstallAnalytics.decode([
            (.formula, .days30, doc("formula", [("xz", #""lots""#), ("hello", #""1,234""#), ("sl", "null"),
                                                ("jq", #""-3""#), ("wget", #""""#), ("git", "42"), ("lua", #"{"n":1}"#)])),
        ])
        #expect(a[InstallAnalytics.id(kind: .formula, name: "hello")]?.days30 == 1234)
        #expect(a[InstallAnalytics.id(kind: .formula, name: "git")]?.days30 == 42)
        for bad in ["xz", "sl", "jq", "wget", "lua"] {
            #expect(a[InstallAnalytics.id(kind: .formula, name: bad)] == nil, "\(bad)")
        }
        #expect(a.endDate == "2026-11-17")
    }

    /// The app's compiled catalog (Scripts/l10n.py compile), one language.
    static func lproj(_ lang: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Sources/TankardApp/Resources/Localizations/\(lang).lproj").path
        return try #require(Bundle(path: path))
    }

    /// "1 install", not "1 installs": plural forms in every language.
    @Test func sentencesUseThePluralForms() throws {
        let en = try Self.lproj("en"), us = Locale(identifier: "en_US")
        #expect(InstallCounts.sentence(1, .days30, locale: us, bundle: en) == "1 install in the last 30 days")
        #expect(InstallCounts.sentence(0, .days90, locale: us, bundle: en) == "0 installs in the last 90 days")
        #expect(InstallCounts.sentence(12_345, .days365, locale: us, bundle: en) == "12,345 installs in the last 365 days")
        let de = try Self.lproj("de"), deDE = Locale(identifier: "de_DE")
        #expect(InstallCounts.sentence(1, .days30, locale: deDE, bundle: de) == "1 Installation in 30 Tagen")
        #expect(InstallCounts.sentence(12_345, .days30, locale: deDE, bundle: de) == "12.345 Installationen in 30 Tagen")
        let fr = try Self.lproj("fr"), frFR = Locale(identifier: "fr_FR")
        #expect(InstallCounts.sentence(1, .days30, locale: frFR, bundle: fr) == "1 installation ces 30 derniers jours")
        #expect(InstallCounts.sentence(2, .days30, locale: frFR, bundle: fr) == "2 installations ces 30 derniers jours")
        #expect(InstallCounts.sentence(1, .days30, locale: Locale(identifier: "es_ES"), bundle: try Self.lproj("es")) == "1 instalación en los últimos 30 días")
        #expect(InstallCounts.sentence(1, .days30, locale: Locale(identifier: "it_IT"), bundle: try Self.lproj("it")) == "1 installazione negli ultimi 30 giorni")
        #expect(InstallCounts.sentence(1, .days30, locale: Locale(identifier: "pt_BR"), bundle: try Self.lproj("pt-BR")) == "1 instalação nos últimos 30 dias")
        #expect(InstallCounts.sentence(1, .days30, locale: Locale(identifier: "ja_JP"), bundle: try Self.lproj("ja")) == "過去30日間に1回インストール")
        #expect(InstallCounts.sentence(1_234, .days30, locale: Locale(identifier: "ko_KR"), bundle: try Self.lproj("ko")) == "최근 30일간 1,234회 설치")
        #expect(InstallCounts.sentence(5, .days90, locale: Locale(identifier: "zh_Hans"), bundle: try Self.lproj("zh-Hans")) == "过去 90 天安装 5 次")
        // Every period, every language: a translation (no English key left).
        for lang in ["de", "fr", "es", "ja", "zh-Hans", "pt-BR", "it", "ko"] {
            let b = try Self.lproj(lang)
            for p in [AnalyticsPeriod.days30, .days90, .days365] {
                let one = InstallCounts.sentence(1, p, locale: Locale(identifier: lang), bundle: b)
                #expect(!one.contains("installs in the last"), "\(lang) \(p): \(one)")
                #expect(one.contains("1"), "\(lang) \(p): \(one)")
            }
        }
    }

    @Test func numbersFollowTheLocale() {
        #expect(InstallCounts.number(12_345, locale: Locale(identifier: "en_US")) == "12,345")
        #expect(InstallCounts.number(12_345, locale: Locale(identifier: "de_DE")) == "12.345")
        #expect(InstallCounts.number(1_234_567, locale: Locale(identifier: "de_DE")) == "1.234.567")
        #expect(InstallCounts.number(12_345, locale: Locale(identifier: "fr_FR")) == "12\u{202F}345")
        #expect(InstallCounts.number(12_345, locale: Locale(identifier: "ja_JP")) == "12,345")
        #expect(InstallCounts.number(0, locale: Locale(identifier: "en_US")) == "0")
        #expect(InstallCounts.sentence(12_345, .days30, locale: Locale(identifier: "en_US")) == "12,345 installs in the last 30 days")
        #expect(InstallCounts.sentence(12_345, .days365, locale: Locale(identifier: "de_DE")).hasPrefix("12.345 "))
    }
}

struct PopularityTieBreakTests {
    func e(_ name: String, desc: String? = nil, bottle: CatalogBottle = .forThisMac) -> CatalogEntry {
        CatalogEntry(kind: .formula, name: name, fullName: name, tap: "homebrew/core", desc: desc, bottle: bottle)
    }

    @Test func breaksTiesWithinATierOnly() {
        let entries = [e("git"), e("git-who"), e("git-lfs"), e("gitui"), e("lazygit"), e("git-zz", bottle: .fromSource)]
        let pop = ["formula:homebrew/core/git-lfs": 50_000, "formula:homebrew/core/git-who": 10,
                   "formula:homebrew/core/lazygit": 90_000, "formula:homebrew/core/git-zz": 1_000_000, "formula:homebrew/core/git": 1]
        // Without counts: name length, then alphabetical.
        #expect(CatalogSearch.search("git", in: entries, preferBottled: true).map(\.name)
                == ["git", "gitui", "git-lfs", "git-who", "git-zz", "lazygit"])
        // With counts: the exact match still leads and lazygit (contains)
        // stays below every prefix match; the bottle rank still beats
        // popularity; within the prefix tier the popular one comes first,
        // and a package with no count ranks as 0.
        #expect(CatalogSearch.search("git", in: entries, preferBottled: true, popularity: pop).map(\.name)
                == ["git", "git-lfs", "git-who", "gitui", "git-zz", "lazygit"])
    }
}
