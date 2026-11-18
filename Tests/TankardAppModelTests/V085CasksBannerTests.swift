import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5: Discover's "Apps (casks) are turned off" banner (CasksBanner.swift).

@MainActor
struct CasksBannerTests {
    @Test func intelbrewWithoutTheCaskTapShowsTheBannerAndEnablesThroughTheQueue() async throws {
        // The Intelbrew demo's taps are homebrew/core only, as a Mac set up
        // by the installer without casks.
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0.01))
        await store.start()
        let d = try #require(store.openDiscover())
        await d.activate()
        #expect(!d.casksEnabled)
        #expect(store.showsCasksBanner)

        store.requestEnableCasks()
        let req = try #require(store.taps.pendingAdd)
        #expect(req.source == .discover)
        #expect(req.arguments == ["tap", "homebrew/cask"])  // what install.sh runs
        #expect(req.command == "brew tap homebrew/cask")

        let loadedBefore = try #require(d.loadedAt)
        store.confirmAddTap()
        #expect(store.taps.pendingAdd == nil)
        #expect(await waitUntil { store.upgrade?.action == .tap })
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        // Discover reads the taps again after the tap (its TTL notwithstanding).
        #expect(await waitUntil { (d.loadedAt ?? loadedBefore) > loadedBefore })
    }

    @Test func closingTheBannerHidesItForGood() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0.01))
        await store.start()
        let d = try #require(store.openDiscover())
        await d.activate()
        #expect(store.showsCasksBanner)
        store.hideCasksBanner()
        #expect(!store.showsCasksBanner)
        #expect(AppSettings(defaults: store.settings.defaults).casksBannerHidden)
    }

    @Test func noBannerWhenCasksAreOn() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0.01))
        await store.start()
        let d = try #require(store.openDiscover())
        await d.activate()
        #expect(d.casksEnabled)
        #expect(!store.showsCasksBanner)
        // And nothing before Discover was opened.
        let fresh = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0.01))
        #expect(!fresh.showsCasksBanner)
    }

    /// Newbie review H1: searching for an app while apps are off says why
    /// nothing matched and offers Turn On Apps…, even with the banner closed.
    @Test func emptySearchWhileCasksAreOffExplainsIt() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0.01))
        await store.start()
        let d = try #require(store.openDiscover())
        await d.activate()
        store.hideCasksBanner()
        d.query = "firefox"
        await d.searchNow()
        #expect(d.results.isEmpty)
        #expect(store.searchEmptyBecauseCasksOff)
        #expect(CasksBanner.noMatchesDetail("firefox").contains("firefox"))
        // A search that finds formulae isn't affected.
        d.query = "xz"
        await d.searchNow()
        #expect(!d.results.isEmpty)
        #expect(!store.searchEmptyBecauseCasksOff)

        // With casks on, an empty search is a plain "No matches".
        let arm = AppStore(deps: Demo.dependencies(.arm64, pace: 0.01))
        await arm.start()
        let a = try #require(arm.openDiscover())
        await a.activate()
        a.query = "zzzz-nothing"
        await a.searchNow()
        #expect(a.results.isEmpty)
        #expect(!arm.searchEmptyBecauseCasksOff)
    }
}
