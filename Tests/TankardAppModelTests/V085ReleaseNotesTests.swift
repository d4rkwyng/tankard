import Foundation
import Testing
@testable import TankardAppModel

// 0.8.5: Check for Tankard Updates… showed the release notes as one giant
// paragraph (the 0.8.4 notes: the intro line and one long change in 700
// characters). Now a heading-and-bullets summary, checked against the real
// CHANGELOG sections wrapped the way release.yml builds GitHub's body.

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// CHANGELOG.md's section for `version`, as Scripts/changelog-section.sh
/// prints it, between release.yml's intro and install lines.
func releaseBody(_ version: String) throws -> String {
    let text = try String(contentsOf: packageRoot.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
    var on = false
    var section: [Substring] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("## [") {
            if on { break }
            on = line.hasPrefix("## [\(version)]")
            continue
        }
        if on && line.range(of: #"^\[[^]]+\]: "#, options: .regularExpression) != nil { break }
        if on { section.append(line) }
    }
    let body = section.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    try #require(!body.isEmpty, "no CHANGELOG section \(version)")
    return "Tankard v\(version) for macOS 14 Sonoma and later.\n\n" + body
        + "\n\nA native Homebrew app, universal (Intel and Apple silicon), signed with Developer ID and notarized."
        + "\n\nInstall or upgrade: `brew install --cask d4rkwyng/tap/tankard` / `brew upgrade --cask tankard`"
}

struct V085ReleaseNotesTests {
    @Test(arguments: ["0.8.4", "0.8.5", "0.8.6"])
    func realReleaseNotesAreAShortList(version: String) throws {
        let s = ReleaseNotesSummary.make(try releaseBody(version))
        #expect(s.bullets.count == 12)
        #expect(s.more > 0)
        let headings = s.items.compactMap { item -> String? in
            if case .heading(let h) = item { return h }
            return nil
        }
        #expect(headings.contains("Added"))
        // No paragraph: every line is short, no Markdown, no intro or install line.
        for line in s.plainText.split(separator: "\n") {
            #expect(line.count <= 140, "\(line)")
            #expect(!line.contains("**") && !line.contains("`"), "\(line)")
        }
        #expect(!s.plainText.contains("native Homebrew app"))
        #expect(!s.plainText.contains("Install or upgrade"))
        #expect(s.bullets.count + s.more == ReleaseNotesSummary.make(try releaseBody(version), limit: 1000).bullets.count)
    }

    @Test func v084Leads() throws {
        let s = ReleaseNotesSummary.make(try releaseBody("0.8.4"))
        #expect(s.items.prefix(4) == [
            .heading("Added"),
            .bullet("Automatic updates wait for brew and ask before quitting"),
            .bullet("Your shell profile's proxy settings reach brew (http_proxy, https_proxy, all_proxy, no_proxy and the forms brew keeps)"),
            .bullet("Health warns about brew.env settings that override Tankard, one row each with the reason: the dependents check, the…"),
        ])
    }

    /// 0.8.8: three Highlights and three fixes, all shown.
    @Test func v088ShowsEveryChange() throws {
        let s = ReleaseNotesSummary.make(try releaseBody("0.8.8"))
        #expect(s.items.first == .heading("Highlights"))
        #expect(s.bullets.count == 6)
        #expect(s.more == 0)
        let headings = s.items.compactMap { item -> String? in
            if case .heading(let h) = item { return h }
            return nil
        }
        #expect(headings == ["Highlights", "Fixed"])
        for line in s.plainText.split(separator: "\n") {
            #expect(line.count <= 140, "\(line)")
            #expect(!line.contains("**") && !line.contains("`"), "\(line)")
        }
    }

    @Test func oldAppShowsV088AsAList() throws {
        let shown = Self.excerpt084(try releaseBody("0.8.8"))
        let lines = shown.split(separator: "\n").map(String.init)
        #expect(lines.first == "Tankard v0.8.8 for macOS 14 Sonoma and later.")
        #expect(lines.contains("Highlights"))
        #expect(lines.filter { $0.hasPrefix("- ") }.count == 3, "\(shown)")
        for line in lines { #expect(line.count < 80, "\(line)") }
    }

    /// 0.8.7: four Highlights and seven changes, under the 12 the summary
    /// shows, so all of them show and there is no "and N more".
    @Test func v087ShowsEveryChange() throws {
        let s = ReleaseNotesSummary.make(try releaseBody("0.8.7"))
        #expect(s.bullets.count == 11)
        #expect(s.more == 0)
        let headings = s.items.compactMap { item -> String? in
            if case .heading(let h) = item { return h }
            return nil
        }
        #expect(headings == ["Highlights", "Added", "Fixed"])
        for line in s.plainText.split(separator: "\n") {
            #expect(line.count <= 140, "\(line)")
            #expect(!line.contains("**") && !line.contains("`"), "\(line)")
        }
        #expect(!s.plainText.contains("native Homebrew app"))
        #expect(!s.plainText.contains("Install or upgrade"))
    }

    @Test func v087StartsWithHighlights() throws {
        let s = ReleaseNotesSummary.make(try releaseBody("0.8.7"))
        #expect(s.items.first == .heading("Highlights"))
        #expect(s.items.dropFirst().prefix(4).allSatisfy { if case .bullet = $0 { true } else { false } })
        #expect(s.items[5] == .heading("Added"))
    }

    @Test func oldAppShowsV087AsAList() throws {
        let shown = Self.excerpt084(try releaseBody("0.8.7"))
        let lines = shown.split(separator: "\n").map(String.init)
        #expect(lines.first == "Tankard v0.8.7 for macOS 14 Sonoma and later.")
        #expect(lines.contains("Highlights"))
        let bullets = lines.filter { $0.hasPrefix("- ") }
        #expect(bullets.count == 4, "\(shown)")
        for line in lines { #expect(line.count < 80, "\(line)") }
    }

    @Test func v086StartsWithHighlights() throws {
        let s = ReleaseNotesSummary.make(try releaseBody("0.8.6"))
        #expect(s.items.first == .heading("Highlights"))
        #expect(s.items.dropFirst().prefix(6).allSatisfy { if case .bullet = $0 { true } else { false } })
        #expect(s.items[7] == .heading("Added"))
    }

    @Test func oldAppShowsV086AsAList() throws {
        let shown = Self.excerpt084(try releaseBody("0.8.6"))
        let lines = shown.split(separator: "\n").map(String.init)
        #expect(lines.first == "Tankard v0.8.6 for macOS 14 Sonoma and later.")
        #expect(lines.contains("Highlights"))
        let bullets = lines.filter { $0.hasPrefix("- ") }
        #expect((4...6).contains(bullets.count), "\(shown)")
        for line in lines { #expect(line.count < 80, "\(line)") }
    }

    @Test func v085StartsWithHighlights() throws {
        let s = ReleaseNotesSummary.make(try releaseBody("0.8.5"))
        #expect(s.items.first == .heading("Highlights"))
        #expect(s.items.dropFirst().prefix(6).allSatisfy { if case .bullet = $0 { true } else { false } })
        #expect(s.items[7] == .heading("Added"))
    }

    /// 0.8.4's excerpt, unchanged: what a 0.8.4 app shows for the 0.8.5
    /// release. The 0.8.5 section starts with a short Highlights list and
    /// release.yml's intro is one short line, so that is a tidy list too.
    static func excerpt084(_ body: String, limit: Int = 700) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line)
            while l.hasPrefix("#") { l.removeFirst() }
            return l.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        }
        var text = lines.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let cut = head.lastIndex(of: "\n").map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    @Test func oldAppShowsV085AsAList() throws {
        let shown = Self.excerpt084(try releaseBody("0.8.5"))
        let lines = shown.split(separator: "\n").map(String.init)
        #expect(lines.first == "Tankard v0.8.5 for macOS 14 Sonoma and later.")
        #expect(lines.contains("Highlights"))
        let bullets = lines.filter { $0.hasPrefix("- ") }
        #expect((4...6).contains(bullets.count), "\(shown)")
        for line in lines { #expect(line.count < 80, "\(line)") }
    }

    @Test func leadRules() {
        // A bold sentence: just it, without its period or colon.
        #expect(ReleaseNotesSummary.lead("**Long builds show their time.** While a package builds…") == "Long builds show their time")
        #expect(ReleaseNotesSummary.lead("**Smaller fixes:** a restore with nothing to run…") == "Smaller fixes")
        // Bold words inside a sentence: the first sentence, plain.
        #expect(ReleaseNotesSummary.lead("**Help ▸ Words** opens a glossary. More detail.") == "Help ▸ Words opens a glossary")
        // No bold: the first sentence; code and links plain.
        #expect(ReleaseNotesSummary.lead("A lock-wait test now waits on `events`. It used a clock.") == "A lock-wait test now waits on events")
        #expect(ReleaseNotesSummary.lead("See [the guide](https://x/y). Then more.") == "See the guide")
        // A long line is cut at a word.
        let long = ReleaseNotesSummary.lead(String(repeating: "word ", count: 60))
        #expect(long.count <= ReleaseNotesSummary.lineLimit)
        #expect(long.hasSuffix("word…"))
    }

    @Test func structure() {
        let body = "Intro line that is long.\n\n### Added\n- **One.** a\n  wrapped detail\n  - sub item\n- two\n\n### Fixed\n- three\n\nInstall: x"
        #expect(ReleaseNotesSummary.make(body).items == [.heading("Added"), .bullet("One"), .bullet("two"), .heading("Fixed"), .bullet("three")])
        // A heading whose changes are all past the limit isn't shown.
        let cut = ReleaseNotesSummary.make(body, limit: 2)
        #expect(cut.items == [.heading("Added"), .bullet("One"), .bullet("two")])
        #expect(cut.more == 1)
        // No heading at all: the list items still count; other lines don't.
        #expect(ReleaseNotesSummary.make("Notes.\n- a\n- b").items == [.bullet("a"), .bullet("b")])
        #expect(ReleaseNotesSummary.make("Just a paragraph.").isEmpty)
    }
}
