import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.1: the first-launch welcome sheet.

@MainActor
struct V081OnboardingTests {
    func store(_ settings: AppSettings = testSettings(), exists: Bool = true) async -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementProbeExists = { _ in exists }
        let store = AppStore(deps: deps, settings: settings)
        await store.start()
        return store
    }

    @Test func showsOnceOnARealFirstLaunchAndDoneIsForGood() async throws {
        let settings = testSettings()
        let store = await store(settings)
        store.showOnboardingIfFirstLaunch(allowed: false) // demo, script, e2e
        #expect(store.toolSheet == nil)
        store.showOnboardingIfFirstLaunch(allowed: true)
        #expect(store.toolSheet == .welcome)
        let state = try #require(store.onboarding)
        #expect(state.adoptable == nil) // the scan runs; the sheet doesn't wait
        #expect(await waitUntil { state.adoptable != nil })
        #expect(state.showsAdopt)
        #expect(state.adoptable == store.adopt.rows(.ready).count)
        store.finishOnboarding()
        #expect(store.toolSheet == nil)
        #expect(settings.onboardingDone)
        store.showOnboardingIfFirstLaunch(allowed: true)
        #expect(store.toolSheet == nil)
    }

    @Test func adoptAppsReplacesItWithTheAdoptSheet() async throws {
        let settings = testSettings()
        let store = await store(settings)
        store.presentOnboarding()
        store.onboardingOpenAdopt()
        #expect(store.toolSheet == .adopt)
        #expect(settings.onboardingDone)
    }

    @Test func aFailedScanHidesTheAdoptCard() async throws {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.adoptLoader = { throw AdoptUnavailable.noAPI }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.presentOnboarding()
        let state = try #require(store.onboarding)
        #expect(await waitUntil { store.adopt.phase != .scanning && store.adopt.phase != .idle })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.adoptable == nil)
        #expect(!state.showsAdopt)
    }

    @Test func checkUsesTheProbeOnABrewApp() async throws {
        let store = await store()
        store.presentOnboarding()
        let state = try #require(store.onboarding)
        store.checkAppManagement()
        #expect(await waitUntil { state.check != nil && !state.isChecking })
        #expect(state.check == .blocked) // the demo's probe
        #expect(!state.nothingToCheck)

        let none = await self.store(exists: false)
        none.presentOnboarding()
        none.checkAppManagement()
        #expect(none.onboarding?.check == .unknown)
        #expect(none.onboarding?.nothingToCheck == true)
    }

    @Test func relaunchFromTheWelcomeLeavesNothingPending() async throws {
        let settings = testSettings()
        let flag = Flag()
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.relaunch = { flag.set() }
        let store = AppStore(deps: deps, settings: settings)
        await store.start()
        store.presentOnboarding()
        store.onboardingRelaunch()
        #expect(flag.value)
        #expect(settings.onboardingDone)
        #expect(settings.appManagementPendingRetry == nil)
    }
}
