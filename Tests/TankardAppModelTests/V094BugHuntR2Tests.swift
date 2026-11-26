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

