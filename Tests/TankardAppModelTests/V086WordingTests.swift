import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6 (UI details M4, M5, M10): whole sentences per language, one
// phrase for a failed run, and ja/ko "Installed as".
struct V086WordingTests {
    static func strings(_ lang: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TankardApp/Resources/Localizations/\(lang).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    @Test func compileSentenceIsWholeInEveryLanguage() throws {
        #expect(PlanText.compiles(1) == "1 package has no bottle for this Mac and will compile from source, which can take a long time.")
        #expect(PlanText.compiles(3) == "3 packages have no bottle for this Mac and will compile from source, which can take a long time.")
        // 0.8.8 (gauntlet 3, B8): one plural entry (Localizable.stringsdict),
        // its "one" and "other" forms whole sentences.
        let key = "%lld packages have no bottle for this Mac and will compile from source, which can take a long time."
        for lang in ["de", "fr", "es", "ja", "zh-Hans", "pt-BR", "it", "ko"] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/TankardApp/Resources/Localizations/\(lang).lproj/Localizable.stringsdict")
            let dict = try #require(NSDictionary(contentsOf: url) as? [String: Any], "\(lang)")
            let forms = try #require((dict[key] as? [String: Any])?["n"] as? [String: String], "\(lang)")
            let one = try #require(forms["one"], "\(lang)")
            let many = try #require(forms["other"], "\(lang)")
            #expect(!one.contains("%@") && !many.contains("%@"))
            #expect(many.contains("%") && one.contains("%"))
        }
        #expect(try Self.strings("de")["%lld %@ no bottle for this Mac and will compile from source, which can take a long time."] == nil)
    }

    @MainActor
    @Test func failedRunSaysProblemsLikeItsWindow() async throws {
        let s = UpgradeSession(packages: [Package.command("walk-fail")], intelbrewMode: false, action: .upgrade,
                               queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { _, _ in 1 }),
                               makeCommand: { p in QueuedCommand(executable: "/x/brew", arguments: [p.name], environment: [:], display: p.name) },
                               logURL: nil, onFinish: { _ in })
        #expect(await waitUntil { s.isFinished })
        #expect(s.title == "Upgrade finished with problems")
    }

    @Test func installedAsInJapaneseAndKorean() throws {
        #expect(try Self.strings("ja")["Installed as"] == "インストール方法")
        #expect(try Self.strings("ko")["Installed as"] == "설치 방식")
    }
}

// 0.8.6 (UI details L1, L2): whole sentences; dates in the locale's style.
struct V086SentenceTests {
    @Test func installCompileMessageIsWhole() {
        #expect(InstallCompileText.message(name: "ffmpeg", intelbrew: false, deps: [], estimate: nil)
                == "ffmpeg has no bottle for this Mac, so brew compiles it. That can take a long time on older Macs.")
        #expect(InstallCompileText.message(name: "ffmpeg", intelbrew: true, deps: ["node"], estimate: "about 15 min")
                == "ffmpeg has no Intelbrew bottle for this Mac, so brew compiles it and 1 dependency (node). That can take a long time on older Macs. It took about 15 min.")
        #expect(InstallCompileText.message(name: "x", intelbrew: false, deps: ["a", "b"], estimate: nil).contains("and 2 dependencies (a, b)."))
    }

    @Test func autoUpdateTimesFollowTheLocale() {
        func cal(_ id: String) -> Calendar {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            c.locale = Locale(identifier: id)
            return c
        }
        let now = cal("en_US").date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 10))!
        let then = cal("en_US").date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 6, minute: 4))!
        let de = AutoUpdateText.when(then, now: now, calendar: cal("de_DE"))
        #expect(de.contains("Nov.") && de.contains("06:04"))
        let us = AutoUpdateText.when(then, now: now, calendar: cal("en_US"))
        #expect(us.contains("Nov") && us.contains("6:04") && us.contains("AM"))
    }
}
