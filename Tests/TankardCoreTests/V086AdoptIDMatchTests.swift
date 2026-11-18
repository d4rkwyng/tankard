import Foundation
import Testing
@testable import TankardCore

// 0.8.6: Adopt Apps matched a "Copilot.app" that wasn't copilot-money's
// (a different Copilot, e.g. Microsoft's) to the cask copilot-money by file
// name alone. Adopting runs `brew install --cask --adopt`, so a wrong match
// hands someone else's app to brew upgrade and uninstall. A cask that names
// app IDs must now name the installed app's. The fixture is real
// `brew info --cask --json=v2 copilot-money` output (2026-11-18): app
// Copilot.app, auto_updates true, zap paths with com.copilot.production.

struct V086AdoptIDMatchTests {
    static func copilot() throws -> AdoptCask {
        let c = try #require(Fixture.info("copilot-money-info").casks.first)
        return AdoptCask(c)
    }

    static func app(_ rel: String, _ bid: String?, _ v: String = "6.8.2") -> InstalledApp {
        InstalledApp(path: "/Applications/" + rel, root: "/Applications", relativePath: rel, bundleID: bid,
                     shortVersion: v, bundleVersion: v)
    }

    @Test func copilotMoneyNamesItsAppID() throws {
        let c = try Self.copilot()
        #expect(c.token == "copilot-money" && c.autoUpdates)
        #expect(c.apps.map(\.target) == ["/Applications/Copilot.app"])
        // Containers/<id>, Application Scripts/<id>*, Group Containers/group.<id>.
        #expect(c.bundleIDs.contains("com.copilot.production"))
        #expect(c.bundleIDs.contains("group.com.copilot.production"))
    }

    @Test func aDifferentCopilotIsNotMatched() throws {
        let c = try Self.copilot()
        let idx = AdoptIndex(casks: [c])
        let other = Self.app("Copilot.app", "com.microsoft.copilot-mac", "1.25")
        #expect(AdoptMatcher.idEvidence(app: other, cask: c) == .mismatch)
        let row = AdoptMatcher.row(for: other, index: idx)
        #expect(row.candidates.isEmpty && row.bestToken == nil)
        #expect(row.verdicts.isEmpty && row.confidence.isEmpty)
        #expect(row.rejected == ["copilot-money"])
        // Through the whole scan too: a row with no cask.
        let scan = AdoptMatcher.match([other], index: idx, managed: ManagedApps())
        #expect(scan.rows.map(\.candidates) == [[]])
        // An app with no bundle id can't be checked against the cask's: not offered either.
        #expect(AdoptMatcher.row(for: Self.app("Copilot.app", nil), index: idx).candidates.isEmpty)
    }

    @Test func theRealCopilotMoneyIsMatchedByAppID() throws {
        let c = try Self.copilot()
        let row = AdoptMatcher.row(for: Self.app("Copilot.app", "com.copilot.production"), index: AdoptIndex(casks: [c]))
        #expect(row.candidates == ["copilot-money"] && row.rejected.isEmpty)
        #expect(row.confidence["copilot-money"] == .high)
        #expect(row.verdicts["copilot-money"] == .ready)
    }

    @Test func relatedIDFormsCountAsTheAppsID() {
        let ids: Set<String> = ["group.com.foo.bar", "abcde12345.com.baz.qux", "com.one.two.helper"]
        #expect(AdoptMatcher.names("com.foo.bar", ids))
        #expect(AdoptMatcher.names("com.baz.qux", ids))
        #expect(AdoptMatcher.names("com.one.two", ids))
        // Only whole labels: com.foo.ba is not com.foo.bar.
        #expect(!AdoptMatcher.names("com.foo.ba", ids))
        #expect(!AdoptMatcher.names("foo.bar", ids))
        // Same vendor, different product: not a match any more.
        #expect(!AdoptMatcher.names("com.foo.other", ids))
        // Two-label ids only exactly (md.obsidian).
        #expect(AdoptMatcher.names("md.obsidian", ["md.obsidian"]))
        #expect(!AdoptMatcher.names("com.one", ids))
    }

    @Test func caskWithoutIDsFallsBackToTheNameAtLowerConfidence() {
        let target = [BrewInfoJSON.Cask.AdoptArtifacts.App(source: "Foo.app", target: "/Applications/Foo.app")]
        let c = AdoptCask(token: "foo", version: "1.0", web: "https://example.org/foo", apps: target)
        let a = Self.app("Foo.app", "com.someone.foo", "1.0")
        #expect(AdoptMatcher.idEvidence(app: a, cask: c) == .none)
        let row = AdoptMatcher.row(for: a, index: AdoptIndex(casks: [c]))
        #expect(row.candidates == ["foo"] && row.confidence["foo"] == .low)
        // The developer's website names the vendor of the app's ID: medium.
        var site = c
        site.web = "https://someone.com/foo"
        #expect(AdoptMatcher.confidence(app: a, cask: site, ambiguous: false) == .medium)
    }

    @Test func ambiguousNameKeepsOnlyTheCasksThatFit() {
        let target = [BrewInfoJSON.Cask.AdoptArtifacts.App(source: "Copilot.app", target: "/Applications/Copilot.app")]
        let money = AdoptCask(token: "copilot-money", version: "6.8.2", apps: target, bundleIDs: ["com.copilot.production"])
        let other = AdoptCask(token: "copilot-other", version: "1.0", apps: target, bundleIDs: ["com.example.copilot"])
        let row = AdoptMatcher.row(for: Self.app("Copilot.app", "com.example.copilot", "1.0"),
                                   index: AdoptIndex(casks: [money, other]))
        #expect(row.candidates == ["copilot-other"] && !row.isAmbiguous)
        #expect(row.rejected == ["copilot-money"])
    }
}
