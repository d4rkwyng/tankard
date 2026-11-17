import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

/// Which right-click items appear for which package states.
@MainActor
struct ContextMenuTests {
    func report() async throws -> StatusReport {
        try await makeClient(FakeInfoRunner(log: CallLog(), info: demoIntelInfo())).status()
    }

    /// A plain formula: bottled, up to date, nothing pending.
    func formula(_ name: String = "xz") async throws -> Package {
        var p = try #require(try await report().packages.first { $0.name == name && $0.kind == .formula })
        p.upgradeAvailable = false
        p.upgradeHasBottle = nil
        p.status = .bottle
        p.pouredFromBottle = true
        p.currentVersion = p.installedVersion
        p.homepage = nil
        p.bottleURL = nil
        return p
    }

    func ids(_ entries: [MenuEntry]) -> [String] {
        entries.map { $0.item?.id ?? "-" }
    }

    func item(_ entries: [MenuEntry], _ id: String) -> MenuItemModel? {
        entries.lazy.compactMap(\.item).first { $0.id == id }
    }

    @Test func upToDateFormula() async throws {
        let p = try await formula()
        let m = ContextMenus.installed(p, dependents: [], dependencies: [], compileWarning: nil, busy: false, kegPath: nil)
        #expect(ids(m) == ["uninstall", "-", "copy-name", "copy-command", "-", "show-dependencies", "show-dependents"])
        #expect(item(m, "uninstall")?.title == "Uninstall…")
        #expect(item(m, "uninstall")?.isEnabled == true)
        #expect(item(m, "uninstall")?.isDestructive == true)
        #expect(item(m, "copy-name")?.action == .copy("xz"))
        #expect(item(m, "copy-command")?.title == "Copy Install Command")
        #expect(item(m, "copy-command")?.action == .copy("brew install --formula homebrew/core/xz"))
        // Nothing related: shown, but disabled.
        #expect(item(m, "show-dependencies")?.isEnabled == false)
        #expect(item(m, "show-dependents")?.isEnabled == false)
        // Pin/Unpin isn't in v0.3.
        #expect(item(m, "pin") == nil)
    }

    @Test func upgradeUsesTheDetailPaneCommand() async throws {
        var p = try await formula()
        p.upgradeAvailable = true
        p.currentVersion = "9.9.9"
        let m = ContextMenus.installed(p, dependents: [], dependencies: [], compileWarning: nil, busy: false, kegPath: nil)
        #expect(ids(m).prefix(2) == ["upgrade", "uninstall"])
        #expect(item(m, "upgrade")?.title == "Upgrade xz")
        #expect(item(m, "upgrade")?.action == .upgrade)
        #expect(item(m, "copy-command")?.title == "Copy Upgrade Command")
        #expect(item(m, "copy-command")?.action == .copy(BrewCommands.upgradeDisplay(for: p)))
        #expect(item(m, "copy-command")?.action == .copy("brew upgrade --formula homebrew/core/xz"))
    }

    @Test func compilingUpgradeSaysSo() async throws {
        var p = try await formula()
        p.upgradeAvailable = true
        let m = ContextMenus.installed(p, dependents: [], dependencies: [],
                                       compileWarning: CompileWarning(context: .upgrade), busy: false, kegPath: nil)
        #expect(item(m, "upgrade")?.title == "Upgrade xz (compiles)")
        // Same action: requestUpgrade shows the plan with the warning.
        #expect(item(m, "upgrade")?.action == .upgrade)
    }

    @Test func replaceWithBottleOnlyWhenEligible() async throws {
        var p = try await formula("vim")
        #expect(item(ContextMenus.installed(p, dependents: [], dependencies: [], compileWarning: nil, busy: false, kegPath: nil),
                     "replace-bottle") == nil)
        p.status = .source
        p.pouredFromBottle = false
        p.currentHasBottle = true
        #expect(BottleReplacement.isEligible(p))
        let m = ContextMenus.installed(p, dependents: [], dependencies: [], compileWarning: nil, busy: false, kegPath: nil)
        #expect(ids(m).prefix(2) == ["replace-bottle", "uninstall"])
        #expect(item(m, "replace-bottle")?.action == .replaceWithBottle)
    }

    @Test func blockedUninstallSaysWhy() async throws {
        let p = try await formula()
        let all = try await report().packages.filter { $0.kind == .formula && $0.id != p.id }
        let one = Array(all.prefix(1)), five = Array(all.prefix(5))
        let m1 = ContextMenus.installed(p, dependents: one, dependencies: [], compileWarning: nil, busy: false, kegPath: nil)
        #expect(item(m1, "uninstall")?.isEnabled == false)
        #expect(item(m1, "uninstall")?.title == "Uninstall… (needed by \(one[0].name))")
        #expect(item(m1, "show-dependents")?.isEnabled == true)
        #expect(item(m1, "show-dependents")?.title == "Show What Uses It (1)")
        let m5 = ContextMenus.installed(p, dependents: five, dependencies: [], compileWarning: nil, busy: false, kegPath: nil)
        #expect(item(m5, "uninstall")?.title == "Uninstall… (needed by \(five.prefix(3).map(\.name).joined(separator: ", ")) +2)")
    }

    @Test func busyDisablesTheBrewActionsOnly() async throws {
        var p = try await formula("vim")
        p.upgradeAvailable = true
        let m = ContextMenus.installed(p, dependents: [], dependencies: [p], compileWarning: nil, busy: true, kegPath: nil)
        #expect(item(m, "upgrade")?.isEnabled == false)
        #expect(item(m, "uninstall")?.isEnabled == false)
        #expect(item(m, "copy-name")?.isEnabled == true)
        #expect(item(m, "copy-command")?.isEnabled == true)
        #expect(item(m, "show-dependencies")?.isEnabled == true)
    }

    @Test func linksOnlyWhenKnown() async throws {
        var p = try await formula()
        p.homepage = "https://tukaani.org/xz/"
        p.bottleURL = "https://github.com/d4rkwyng/intelbrew-core/releases/download/xz-5.8.1/xz-5.8.1.sonoma.bottle.tar.gz"
        let m = ContextMenus.installed(p, dependents: [], dependencies: [], compileWarning: nil, busy: false,
                                       kegPath: "/usr/local/Cellar/xz/5.8.1")
        #expect(ids(m) == ["uninstall", "-", "copy-name", "copy-command", "-", "homepage", "release-page", "finder",
                           "-", "show-dependencies", "show-dependents"])
        #expect(item(m, "homepage")?.action == .open(URL(string: "https://tukaani.org/xz/")!))
        #expect(item(m, "release-page")?.action == .open(URL(string: "https://github.com/d4rkwyng/intelbrew-core/releases/tag/xz-5.8.1")!))
        #expect(item(m, "finder")?.action == .revealInFinder("/usr/local/Cellar/xz/5.8.1"))

        // ghcr.io bottles have no release page; a non-web homepage isn't opened.
        p.bottleURL = "https://ghcr.io/v2/homebrew/core/xz/blobs/sha256:abc"
        p.homepage = "file:///etc/passwd"
        let m2 = ContextMenus.installed(p, dependents: [], dependencies: [], compileWarning: nil, busy: false, kegPath: nil)
        #expect(item(m2, "homepage") == nil)
        #expect(item(m2, "release-page") == nil)
        #expect(item(m2, "finder") == nil)
    }

    @Test func kegPaths() async throws {
        let r = try await report()
        var p = try await formula()
        p.installedVersion = "5.8.1_1"
        #expect(ContextMenus.kegPath(p, host: r.host) == "/usr/local/Cellar/xz/5.8.1_1")
        var c = CatalogEntry(kind: .cask, name: "firefox", fullName: "firefox", tap: "homebrew/cask", desc: nil, bottle: .cask).asPackage()
        c.installedVersion = "140.0"
        #expect(ContextMenus.kegPath(c, host: r.host) == "\(r.host.prefix)/Caskroom/firefox/140.0")
        c.installedVersion = ""
        #expect(ContextMenus.kegPath(c, host: r.host) == nil)
    }

    // MARK: Discover

    func entry(loaded: Bool = true, disabled: Bool = false) -> CatalogEntry {
        var e = CatalogEntry(kind: .formula, name: "node-red", fullName: "node-red", tap: "homebrew/core", desc: nil, bottle: .fromSource)
        e.detailsLoaded = loaded
        e.disabled = disabled
        e.homepage = "https://nodered.org"
        return e
    }

    @Test func discoverInstall() {
        let e = entry()
        let plain = ContextMenus.discover(e, installed: false, compileWarning: nil, busy: false)
        #expect(ids(plain) == ["install", "-", "copy-name", "copy-command", "-", "homepage"])
        #expect(item(plain, "install")?.title == "Install node-red")
        #expect(item(plain, "install")?.action == .install(confirmCompile: false))
        #expect(item(plain, "copy-command")?.action == .copy("brew install --formula homebrew/core/node-red"))
        #expect(item(plain, "copy-command")?.action == .copy(e.installDisplay))
        #expect(item(plain, "homepage")?.action == .open(URL(string: "https://nodered.org")!))

        let compiles = ContextMenus.discover(e, installed: false, compileWarning: CompileWarning(context: .install), busy: false)
        #expect(item(compiles, "install")?.title == "Install (compiles)")
        #expect(item(compiles, "install")?.action == .install(confirmCompile: true))
    }

    @Test func discoverInstallDisabledStates() {
        // Details not in yet: whether it compiles is unknown, so no install.
        #expect(item(ContextMenus.discover(entry(loaded: false), installed: false, compileWarning: nil, busy: false), "install")?.isEnabled == false)
        #expect(item(ContextMenus.discover(entry(disabled: true), installed: false, compileWarning: nil, busy: false), "install")?.isEnabled == false)
        #expect(item(ContextMenus.discover(entry(), installed: false, compileWarning: nil, busy: true), "install")?.isEnabled == false)
        // Installed: the detail pane's "Show in Installed" instead.
        let m = ContextMenus.discover(entry(), installed: true, compileWarning: nil, busy: false)
        #expect(item(m, "install") == nil)
        #expect(item(m, "show-installed")?.action == .showInInstalled)
    }

    @Test func menuBarRow() async throws {
        var p = try await formula()
        p.upgradeAvailable = true
        #expect(ids(ContextMenus.menuBarRow(p, compileWarning: nil, busy: false)) == ["upgrade", "copy-name"])
        #expect(ContextMenus.menuBarRow(p, compileWarning: CompileWarning(context: .upgrade), busy: true).first?.item?.isEnabled == false)
        p.upgradeAvailable = false
        #expect(ids(ContextMenus.menuBarRow(p, compileWarning: nil, busy: false)) == ["copy-name"])
    }

    // MARK: Show Dependencies / Show What Uses It

    @Test func relatedSearchTokens() {
        #expect(RelatedSearch("deps:vim") == .dependencies(of: "vim"))
        #expect(RelatedSearch("  USES: xz ") == .dependents(of: "xz"))
        #expect(RelatedSearch("deps:") == nil)
        #expect(RelatedSearch("vim") == nil)
        #expect(RelatedSearch.dependents(of: "homebrew/core/xz").query == "uses:homebrew/core/xz")
    }

    @Test func dependenciesAreTheInverseOfDependents() async throws {
        let all = try await report().packages
        let withDeps = try #require(all.first { !Dependents.dependencies(of: $0, among: all).isEmpty })
        for d in Dependents.dependencies(of: withDeps, among: all) {
            #expect(Dependents.of(d, among: all).contains { $0.id == withDeps.id })
        }
    }

    @Test func storeShowsRelatedRows() async throws {
        let r = try await report()
        let all = r.packages
        let target = try #require(all.first { !Dependents.dependencies(of: $0, among: all).isEmpty })
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        store.filter = .upgrades
        let p = try #require(store.packages.first { $0.id == target.id })

        store.showDependencies(of: p)
        #expect(store.filter == .all)
        #expect(store.selection == p.id)
        #expect(store.search == "deps:\(p.fullName)")
        #expect(store.visiblePackages.map(\.id) == Dependents.dependencies(of: p, among: store.packages).map(\.id))

        // Clicking one of the listed rows keeps the list.
        let first = try #require(store.visiblePackages.first)
        store.selection = first.id
        #expect(store.visiblePackages.map(\.id) == Dependents.dependencies(of: p, among: store.packages).map(\.id))

        store.showDependents(of: first)
        #expect(store.search == "uses:\(first.fullName)")
        #expect(store.visiblePackages.contains { $0.id == p.id })

        // An unknown name falls back to plain search (no matches).
        store.search = "uses:no-such-package"
        #expect(store.visiblePackages.isEmpty)
    }

    @Test func homepageIsOptionalInOldReports() throws {
        var p = CatalogEntry(kind: .formula, name: "xz", fullName: "xz", tap: "homebrew/core", desc: nil, bottle: .intelbrew).asPackage()
        p.homepage = "https://tukaani.org/xz/"
        let data = try StatusReport.jsonEncoder().encode(p)
        #expect(try StatusReport.jsonDecoder().decode(Package.self, from: data).homepage == "https://tukaani.org/xz/")
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "homepage")
        let old = try JSONSerialization.data(withJSONObject: obj)
        #expect(try StatusReport.jsonDecoder().decode(Package.self, from: old).homepage == nil)
    }
}
