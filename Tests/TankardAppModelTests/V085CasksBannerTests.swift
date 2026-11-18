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
}
