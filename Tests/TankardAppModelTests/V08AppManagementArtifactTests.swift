import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.8 fix from the e2e pass: the App Management explainer showed before
// uninstalling a font cask; it is only for casks that install apps.

@MainActor
struct AppManagementArtifactTests {
    func cask(apps: [String]?, suites: [String]? = [], pkg: Bool? = false) -> Package {
        var p = CatalogEntry(kind: .cask, name: "x", fullName: "x", tap: "homebrew/cask", desc: nil, bottle: .cask).asPackage()
        p.appPaths = apps
        p.suitePaths = apps == nil ? nil : suites
        p.installsPkg = apps == nil ? nil : pkg
        return p
    }

    @Test func onlyCasksWithAppsGetTheExplainer() {
        let font = cask(apps: [])
        #expect(!AppManagement.modifiesApps(.uninstall, font))
        #expect(!AppManagement.modifiesApps(.upgrade, font))
        #expect(AppManagement.isCaskChange(.uninstall, font)) // the block check still runs
        #expect(AppManagement.modifiesApps(.uninstall, cask(apps: ["/Applications/AnyBar.app"])))
        #expect(AppManagement.modifiesApps(.uninstall, cask(apps: [], suites: ["/Applications/KiCad"])))
        #expect(AppManagement.modifiesApps(.uninstall, cask(apps: [], pkg: true)))
        // Unknown: no artifacts read, or a report from before 0.8.
        #expect(AppManagement.modifiesApps(.uninstall, cask(apps: nil)))
        var old = cask(apps: [])
        old.suitePaths = nil
        old.installsPkg = nil
        #expect(AppManagement.modifiesApps(.uninstall, old))
        #expect(!AppManagement.modifiesApps(.install, cask(apps: ["/Applications/AnyBar.app"])))
    }

    @Test func aFontUninstallStartsWithoutTheExplainer() async throws {
        let settings = testSettings()
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0.01), settings: settings)
        await store.start()
        let real = try #require(store.packages.first { $0.kind == .cask })
        var font = real
        font.appPaths = []
        font.suitePaths = []
        font.installsPkg = false
        store.startUninstall(font)
        #expect(store.appManagementPrompt == nil)
        #expect(store.upgrade != nil)
        #expect(!settings.appManagementExplained) // still shown before the first app cask
        let s = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { s.isFinished })
        #expect(await waitUntil { !store.isRefreshing })
        store.closeUpgrade()
        let app = try #require(store.packages.first { $0.kind == .cask && $0.id != real.id })
        var withApp = app
        withApp.appPaths = ["/Applications/\(app.name).app"]
        withApp.suitePaths = []
        withApp.installsPkg = false
        store.startUninstall(withApp)
        #expect(store.appManagementPrompt?.reason == .firstUse)
    }
}
