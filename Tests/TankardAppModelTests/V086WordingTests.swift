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
        for lang in ["de", "fr", "es", "ja", "zh-Hans", "pt-BR", "it", "ko"] {
            let s = try Self.strings(lang)
            let one = try #require(s["1 package has no bottle for this Mac and will compile from source, which can take a long time."], "\(lang)")
            let many = try #require(s["%lld packages have no bottle for this Mac and will compile from source, which can take a long time."], "\(lang)")
            #expect(!one.contains("%@") && !many.contains("%@"))
            #expect(many.contains("%lld"))
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
