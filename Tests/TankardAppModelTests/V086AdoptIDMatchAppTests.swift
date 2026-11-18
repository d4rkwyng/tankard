import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6: the Adopt sheet's side of the app-ID rule (V086AdoptIDMatchTests):
// a same-name app with a different ID isn't offered and says why; the
// evidence each match shows; name-only matches are never ticked for you.

@MainActor
struct V086AdoptIDMatchAppTests {
    func adoptStore(_ casks: [AdoptCask], _ apps: [InstalledApp]) -> AdoptStore {
        let a = AdoptStore()
        a.apply(AdoptInput(index: AdoptIndex(casks: casks), apps: apps, source: "test"))
        return a
    }

    static func app(_ rel: String, _ bid: String, _ v: String) -> InstalledApp {
        InstalledApp(path: "/Applications/" + rel, root: "/Applications", relativePath: rel, bundleID: bid,
                     shortVersion: v, bundleVersion: v)
    }

    static let target = [BrewInfoJSON.Cask.AdoptArtifacts.App(source: "Copilot.app", target: "/Applications/Copilot.app")]
    static let money = AdoptCask(token: "copilot-money", version: "6.8.2,340-69efc0f9", autoUpdates: true, apps: target,
                                 bundleIDs: ["com.copilot.production", "group.com.copilot.production"])

    @Test func differentCopilotIsListedAsNotOffered() throws {
        let a = adoptStore([Self.money], [Self.app("Copilot.app", "com.microsoft.copilot-mac", "1.25")])
        let row = try #require(a.scan.rows.first)
        #expect(a.group(row) == .noCask && !a.isTicked(row) && a.plan.isEmpty)
        a.setTicked(row, true)
        #expect(a.plan.isEmpty)
        #expect(a.differentAppNote(row) == "Copilot: possibly a different app, not offered. The cask copilot-money is for the app ID com.copilot.production; this app's ID is com.microsoft.copilot-mac.")
    }

    @Test func realCopilotMoneyIsReadyAndTicked() throws {
        let a = adoptStore([Self.money], [Self.app("Copilot.app", "com.copilot.production", "6.8.2")])
        let row = try #require(a.scan.rows.first)
        #expect(a.group(row) == .ready && a.isTicked(row))
        #expect(a.evidence(row) == .appID && a.evidence(row)?.title == "Matched by app ID")
        #expect(a.differentAppNote(row) == nil)
        #expect(a.plan.map(\.token) == ["copilot-money"])
    }

    @Test func evidenceTitlesInPlainWords() {
        #expect(AdoptMatchEvidence.appID.title == "Matched by app ID")
        #expect(AdoptMatchEvidence.developer.title == "Matched by name and developer")
        #expect(AdoptMatchEvidence.website.title == "Matched by name and website")
        #expect(AdoptMatchEvidence.nameOnly.title == "Matched by name only — check before adopting")
        #expect(AdoptMatchEvidence(.match, confidence: .high) == .appID)
        #expect(AdoptMatchEvidence(.vendor, confidence: .medium) == .developer)
        #expect(AdoptMatchEvidence(AdoptMatcher.IDEvidence.none, confidence: .medium) == .website)
        #expect(AdoptMatchEvidence(AdoptMatcher.IDEvidence.none, confidence: .low) == .nameOnly)
    }

    @Test func demoShowsTheDifferentCopilot() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        store.settings.appManagementExplained = true
        await store.start()
        store.openAdopt()
        #expect(await waitUntil { store.adopt.phase == .ready })
        let a = store.adopt
        let row = try #require(a.rows(.noCask).first { $0.app.displayName == "Copilot" })
        #expect(row.rejected == ["copilot-money"])
        #expect(a.differentAppNote(row)?.contains("com.copilot.production") == true)
        #expect(!a.plan.contains { $0.token == "copilot-money" })
    }
}
