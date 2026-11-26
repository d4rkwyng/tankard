import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.9.4 bug hunt, round 2: user-facing bugs found against fake Homebrew.

func v094Source(_ file: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("Sources/\(file)"), encoding: .utf8)
}

// MARK: Discover's detail-pane Install waits for brew info

// The row menu's Install reads "Install (checking…)" and is off until
// `brew info` details are in (whether it compiles isn't known before). The
// detail pane's button didn't wait: in Intelbrew mode a formula with no
// bottle block (bottle .unknown, no compile warning yet) read "Install foo"
// while "Asking brew info…" showed, and started a source build at once,
// skipping the "Install (compiles)" confirmation.
struct V094DiscoverInstallWaitsTests {
    static func entry(loaded: Bool) -> CatalogEntry {
        CatalogEntry(kind: .formula, name: "foo", fullName: "foo", tap: "homebrew/core", desc: nil, bottle: .unknown, detailsLoaded: loaded)
    }

    @Test func beforeDetailsItWaits() {
        let item = ContextMenus.discoverInstall(Self.entry(loaded: false), compileWarning: nil, busy: false)
        #expect(!item.isEnabled)
        #expect(item.title == "Install (checking…)")
    }

    @Test func afterDetailsItInstalls() {
        let item = ContextMenus.discoverInstall(Self.entry(loaded: true), compileWarning: nil, busy: false)
        #expect(item.isEnabled)
        #expect(item.action == .install(confirmCompile: false))
        #expect(!ContextMenus.discoverInstall(Self.entry(loaded: true), compileWarning: nil, busy: true).isEnabled)
    }

    /// The row menu and the detail pane share the rule.
    @Test func theDetailPaneUsesIt() throws {
        let menu = ContextMenus.discover(Self.entry(loaded: false), installed: false, compileWarning: nil, busy: false)
        #expect(menu.contains { if case .item(let m) = $0 { return m.id == "install" && !m.isEnabled }; return false })
        let view = try v094Source("TankardApp/DiscoverView.swift")
        #expect(view.contains("ContextMenus.discoverInstall(e, compileWarning: store.deps.classifier.installWarning(e)"))
        #expect(view.contains(".disabled(!install.isEnabled)"))
        #expect(!view.contains(".disabled(store.windowBrewActionsBlocked || e.disabled)"))
    }
}

// MARK: a pasted homebrew/core/… or homebrew/cask/… name finds it

// Tankard's own Copy Install Command gives `brew install --formula
// homebrew/core/wget` / `brew install --cask homebrew/cask/firefox`.
// Pasted into Discover it found nothing: the official taps' entries carry
// the short name as their full name.
struct V094QualifiedSearchTests {
    static let entries = [
        CatalogEntry(kind: .formula, name: "wget", fullName: "wget", tap: "homebrew/core", desc: "Internet file retriever", bottle: .forThisMac),
        CatalogEntry(kind: .cask, name: "firefox", fullName: "firefox", tap: "homebrew/cask", desc: "Web browser", bottle: .cask),
        CatalogEntry(kind: .formula, name: "probe", fullName: "walktest/probe/probe", tap: "walktest/probe", desc: nil, bottle: .forThisMac),
    ]

    @Test func officialTapNamesFindTheShortName() {
        #expect(CatalogSearch.search("homebrew/core/wget", in: Self.entries).map(\.name) == ["wget"])
        #expect(CatalogSearch.search("brew install --cask homebrew/cask/firefox", in: Self.entries).map(\.name) == ["firefox"])
        #expect(CatalogSearch.search("Homebrew/Core/WGET", in: Self.entries).map(\.name) == ["wget"])
    }

    @Test func tankardsOwnInstallCommandRoundTrips() {
        for e in Self.entries {
            #expect(CatalogSearch.search(e.installDisplay, in: Self.entries).first?.id == e.id, "\(e.installDisplay)")
        }
    }

    @Test func otherTapsAndPlainWordsAreUnchanged() {
        #expect(CatalogSearch.search("walktest/probe/probe", in: Self.entries).map(\.name) == ["probe"])
        #expect(CatalogSearch.search("homebrew/core/", in: Self.entries).isEmpty)
        #expect(CatalogSearch.officialShortName("homebrew/core/a/b") == "homebrew/core/a/b")
        #expect(CatalogSearch.officialShortName("wget") == "wget")
    }
}

// MARK: Discover's header and empty state name the searched term

// Spaces alone in the search field said "0 results for “”" (the table
// said "Search Homebrew"). A pasted command with no match said "Nothing
// matches “brew install --cask foo”" under "0 results for “foo”".
@MainActor
struct V094DiscoverTermTests {
    func store() async -> DiscoverStore {
        let d = DiscoverStore(provider: FixedAPICatalog(entries: V094QualifiedSearchTests.entries), debounce: .zero)
        await d.activate()
        return d
    }

    @Test func spacesSearchNothing() async {
        let d = await store()
        #expect(d.searchedNothing)
        d.query = "   "
        await d.searchNow()
        #expect(d.results.isEmpty)
        #expect(d.searchedNothing)
        d.query = "wget"
        await d.searchNow()
        #expect(!d.searchedNothing)
    }

    @Test func noMatchesNamesThePackage() async throws {
        let d = await store()
        d.query = "brew install --cask nothere"
        await d.searchNow()
        #expect(d.results.isEmpty)
        #expect(d.queryTerm == "nothere")
        #expect(d.noMatchesDetail(d.queryTerm).contains("“nothere”"))
        let view = try v094Source("TankardApp/DiscoverView.swift")
        #expect(view.contains("discover.noMatchesDetail(discover.queryTerm)"))
        #expect(view.contains("CasksBanner.noMatchesDetail(discover.queryTerm)"))
        #expect(view.contains("if discover.searchedNothing {"))
    }
}
