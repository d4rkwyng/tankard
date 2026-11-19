import Foundation
import Testing
@testable import TankardAppModel

// 0.8.8 (gauntlet 26, P2): offline, the refresh banner quoted brew's
// analytics notice and donation request, with a raw bell character,
// instead of the lines that said what failed.

struct V088BrewOutputTailTests {
    /// The output tail of the gauntlet's failed `brew update` (History).
    static let offline = [
        "Fetching /opt/homebrew failed!",
        "Fetching /opt/homebrew/Library/Taps/equinix-labs/homebrew-otel-cli failed!",
        "Fetching /opt/homebrew/Library/Taps/openai/homebrew-tools failed!",
        "Failed to download https://formulae.brew.sh/api/internal/packages.arm64_tahoe.jws.json!",
        "\u{07}==> Homebrew collects anonymous analytics.",
        "Read the analytics documentation (and how to opt-out) here:",
        "  https://docs.brew.sh/Analytics",
        "No analytics have been recorded yet (nor will be during this `brew` run).",
        "",
        "==> Homebrew is run entirely by unpaid volunteers. Please consider donating:",
        "  https://github.com/Homebrew/brew#-donations",
        "",
    ]

    @Test func quotesWhatFailedNotBrewsNotices() {
        #expect(BrewOutputTail.lines(Self.offline, limit: 6) == Array(Self.offline.prefix(4)))
    }

    @MainActor @Test func updateErrorBannerHasTheFailedLines() {
        let e = AppStore.updateError(code: 1, lines: Self.offline, display: "brew update")
        #expect(e.detail.contains("Fetching /opt/homebrew failed!"))
        #expect(e.detail.contains("Failed to download"))
        #expect(!e.detail.contains("analytics"))
        #expect(!e.detail.contains("donating"))
        #expect(!e.detail.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" })
    }

    @Test func controlCharactersAreStripped() {
        #expect(BrewOutputTail.clean("\u{07}Error: \u{1B}[31mboom\u{1B}[0m") == "Error: boom")
        #expect(BrewOutputTail.clean("a\tb") == "a b")
        #expect(BrewOutputTail.lines(["\u{07}", "  ", "x"], limit: 6) == ["x"])
    }

    @Test func keepsTheLastLinesWhenAllSaySomething() {
        let lines = (1...9).map { "line \($0)" }
        #expect(BrewOutputTail.lines(lines, limit: 6) == Array(lines.suffix(6)))
    }
}
