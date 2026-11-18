import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.6 (walkthrough M2): the App Management explainer came after the plan
// was confirmed, and its "Not now" started the upgrade. It now has Cancel
// (runs nothing), Skip Apps (runs the rest) and Continue Without It (runs
// everything, the old "Not now").
@MainActor
struct V086AppManagementChoiceTests {
    func store(_ settings: AppSettings) async -> AppStore {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0.01), settings: settings)
        await store.start()
        return store
    }

    func mixed(_ store: AppStore) throws -> [Package] {
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        let formula = try #require(store.packages.first { $0.kind == .formula && $0.upgradeAvailable })
        return [formula, chrome]
    }

    @Test func cancelRunsNothingAndAsksAgainNextTime() async throws {
        let settings = testSettings()
        let store = await store(settings)
        store.startUpgrade(try mixed(store))
        let prompt = try #require(store.appManagementPrompt)
        #expect(prompt.appChanging.map(\.name) == ["google-chrome"])
        #expect(prompt.others.count == 1)
        store.appManagementCancel()
        #expect(store.appManagementPrompt == nil)
        #expect(store.upgrade == nil)
        #expect(!store.showUpgradeSheet)
        #expect(!settings.appManagementExplained)
    }

    @Test func skipAppsRunsOnlyTheRest() async throws {
        let settings = testSettings()
        let store = await store(settings)
        let targets = try mixed(store)
        store.startUpgrade(targets)
        store.appManagementSkipApps()
        let run = try #require(store.upgrade)
        #expect(run.items.map(\.package.name) == [targets[0].name])
        #expect(settings.appManagementExplained == false)
    }

    @Test func skipAppsWithNothingElseIsCancel() async throws {
        let store = await store(testSettings())
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        #expect(store.appManagementPrompt?.others.isEmpty == true)
        store.appManagementSkipApps()
        #expect(store.upgrade == nil)
        #expect(store.appManagementPrompt == nil)
    }

    @Test func continueWithoutItRunsEverything() async throws {
        let settings = testSettings()
        let store = await store(settings)
        let targets = try mixed(store)
        store.startUpgrade(targets)
        store.appManagementNotNow()
        #expect(Set(store.upgrade?.items.map(\.package.name) ?? []) == Set(targets.map(\.name)))
        #expect(settings.appManagementExplained)
    }

    @Test func buttonWords() {
        #expect(AppManagementPrompt.continueTitle == "Continue Without It")
        #expect(AppManagementPrompt.skipAppsTitle(1) == "Skip Apps, Upgrade 1 Other")
        #expect(AppManagementPrompt.skipAppsTitle(3) == "Skip Apps, Upgrade 3 Others")
    }
}
