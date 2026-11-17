import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

// v0.3: right-click menus. Which items appear comes from
// `ContextMenus` (TankardAppModel, tested); here they're rendered and each
// action goes to the same store call the detail panes use.

/// Renders a `[MenuEntry]` as menu buttons and dividers.
struct MenuEntries: View {
    var entries: [MenuEntry]
    var perform: (MenuItemModel.Action) -> Void

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .separator:
                Divider()
            case .item(let item):
                Button(role: item.isDestructive ? .destructive : nil) {
                    perform(item.action)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
                .disabled(!item.isEnabled)
            }
        }
    }
}

@MainActor
enum ContextMenuActions {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// The Installed table's row menu (single selection: the clicked row).
    @ViewBuilder
    static func installed(store: AppStore, ids: Set<Package.ID>) -> some View {
        if let id = ids.first, let p = store.packages.first(where: { $0.id == id }) {
            MenuEntries(entries: ContextMenus.installed(
                p,
                dependents: store.dependents(of: p),
                dependencies: Dependents.dependencies(of: p, among: store.packages),
                compileWarning: store.deps.classifier.upgradeWarning(p),
                busy: store.isBusy,
                kegPath: existingKegPath(p, store: store),
                upgradeCommand: store.insights.upgradeDisplay(for: p))) { action in
                    perform(action, on: p, store: store)
                }
        }
    }

    private static func existingKegPath(_ p: Package, store: AppStore) -> String? {
        guard let host = store.report?.host, let path = ContextMenus.kegPath(p, host: host),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    static func perform(_ action: MenuItemModel.Action, on p: Package, store: AppStore) {
        switch action {
        case .upgrade: store.requestUpgrade([p])
        case .replaceWithBottle: store.startReplaceWithBottle([p])
        case .uninstall:
            store.selection = p.id
            store.requestUninstall(p)
        case .copy(let s): copy(s)
        case .open(let url): open(url)
        case .revealInFinder(let path): reveal(path)
        case .showDependencies: store.showDependencies(of: p)
        case .showDependents: store.showDependents(of: p)
        case .pin: store.setPinned(p, true)
        case .unpin: store.setPinned(p, false)
        case .install, .showInInstalled: break // Discover only
        }
    }

    /// Discover's row menu.
    @ViewBuilder
    static func discover(store: AppStore, discover: DiscoverStore, ids: Set<CatalogEntry.ID>) -> some View {
        if let id = ids.first, let e = discover.results.first(where: { $0.id == id }) {
            MenuEntries(entries: ContextMenus.discover(
                e,
                installed: store.installedIDs.contains(e.id),
                compileWarning: store.deps.classifier.installWarning(e),
                busy: store.isUpgrading)) { action in
                    switch action {
                    case .install(let confirmCompile):
                        // The detail pane's button: the confirmation sheet
                        // hangs off the selected entry, so select it first.
                        if confirmCompile {
                            discover.selection = e.id
                            discover.confirmInstall = e.id
                        } else {
                            store.startInstall(e)
                        }
                    case .showInInstalled:
                        store.tab = .installed
                        store.selection = e.id
                    case .copy(let s): copy(s)
                    case .open(let url): open(url)
                    default: break
                    }
                }
        }
    }
}
