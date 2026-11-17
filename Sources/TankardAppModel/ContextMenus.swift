import Foundation
import TankardCore

// v0.3: right-click menus for the Installed table, Discover's table and the
// menu-bar list. Which items appear is decided here, as pure functions; the
// app only renders them and maps each action onto the same store calls the
// detail panes use (no new ways to run brew).

/// One row in a context menu.
public struct MenuItemModel: Equatable, Sendable, Identifiable {
    public enum Action: Equatable, Sendable {
        /// `AppStore.requestUpgrade([p])`: the upgrade plan (and its compile
        /// warning) when it would compile, otherwise the queue at once.
        case upgrade
        /// `AppStore.startReplaceWithBottle([p])`.
        case replaceWithBottle
        /// `AppStore.requestUninstall(p)`: the confirmation sheet.
        case uninstall
        /// Discover: `AppStore.startInstall(e)`, or the "Install (compiles)"
        /// confirmation first.
        case install(confirmCompile: Bool)
        /// Discover: switch to Installed with this package selected.
        case showInInstalled
        case copy(String)
        case open(URL)
        case revealInFinder(String)
        /// Installed: list the installed packages it needs.
        case showDependencies
        /// Installed: list the installed packages that need it.
        case showDependents
    }

    /// Stable per menu ("upgrade", "copy-name", ...), for tests and ForEach.
    public var id: String
    public var title: String
    public var systemImage: String
    public var action: Action
    public var isEnabled: Bool
    public var isDestructive: Bool

    public init(id: String, title: String, systemImage: String, action: Action,
                isEnabled: Bool = true, isDestructive: Bool = false) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.action = action
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
    }
}

public enum MenuEntry: Equatable, Sendable {
    case item(MenuItemModel)
    case separator

    public var item: MenuItemModel? {
        if case .item(let i) = self { return i }
        return nil
    }
}

public enum ContextMenus {
    /// The Installed table's row menu. The table is single-selection, so
    /// the menu is always about one package (the row clicked).
    ///
    /// - busy: a brew run is going (the detail pane disables its buttons too).
    /// - kegPath: the keg or Caskroom folder, only when it exists on disk.
    public static func installed(_ p: Package, dependents: [Package], dependencies: [Package],
                                 compileWarning: CompileWarning?, busy: Bool, kegPath: String?) -> [MenuEntry] {
        var actions: [MenuItemModel] = []
        if p.upgradeAvailable {
            actions.append(MenuItemModel(id: "upgrade",
                                         title: compileWarning == nil ? "Upgrade \(p.name)" : "Upgrade \(p.name) (compiles)",
                                         systemImage: compileWarning == nil ? "arrow.up.circle" : "hammer",
                                         action: .upgrade, isEnabled: !busy))
        }
        if BottleReplacement.isEligible(p) {
            actions.append(MenuItemModel(id: "replace-bottle", title: "Replace with Bottle",
                                         systemImage: "shippingbox.and.arrow.backward",
                                         action: .replaceWithBottle, isEnabled: !busy))
        }
        actions.append(MenuItemModel(id: "uninstall", title: uninstallTitle(dependents: dependents),
                                     systemImage: dependents.isEmpty ? "trash" : "lock",
                                     action: .uninstall, isEnabled: !busy && dependents.isEmpty,
                                     isDestructive: true))

        var copy: [MenuItemModel] = [
            MenuItemModel(id: "copy-name", title: "Copy Name", systemImage: "doc.on.doc", action: .copy(p.name)),
        ]
        if p.upgradeAvailable {
            copy.append(MenuItemModel(id: "copy-command", title: "Copy Upgrade Command", systemImage: "terminal",
                                      action: .copy(BrewCommands.upgradeDisplay(for: p))))
        } else {
            copy.append(MenuItemModel(id: "copy-command", title: "Copy Install Command", systemImage: "terminal",
                                      action: .copy(BrewCommands.display(BrewCommands.installArguments(kind: p.kind, qualifiedName: p.qualifiedName)))))
        }

        var open: [MenuItemModel] = []
        if let url = webURL(p.homepage) {
            open.append(MenuItemModel(id: "homepage", title: "Open Homepage", systemImage: "safari", action: .open(url)))
        }
        if let page = p.releasePageURL {
            open.append(MenuItemModel(id: "release-page", title: "Open Release Page", systemImage: "arrow.up.right.square", action: .open(page)))
        }
        if let kegPath {
            open.append(MenuItemModel(id: "finder", title: "Show in Finder", systemImage: "folder", action: .revealInFinder(kegPath)))
        }

        let related = [
            MenuItemModel(id: "show-dependencies",
                          title: dependencies.isEmpty ? "Show Dependencies" : "Show Dependencies (\(dependencies.count))",
                          systemImage: "arrow.down.right.circle", action: .showDependencies, isEnabled: !dependencies.isEmpty),
            MenuItemModel(id: "show-dependents",
                          title: dependents.isEmpty ? "Show What Uses It" : "Show What Uses It (\(dependents.count))",
                          systemImage: "arrow.up.left.circle", action: .showDependents, isEnabled: !dependents.isEmpty),
        ]
        // TODO: Pin / Unpin (`brew pin`) once it goes through the queue; not in v0.3.

        return joined([actions, copy, open, related])
    }

    /// "Uninstall…", or "Uninstall… (needed by vim, git +2)" when blocked.
    static func uninstallTitle(dependents: [Package]) -> String {
        guard !dependents.isEmpty else { return "Uninstall…" }
        let names = dependents.prefix(3).map(\.name).joined(separator: ", ")
        let more = dependents.count > 3 ? " +\(dependents.count - 3)" : ""
        return "Uninstall… (needed by \(names)\(more))"
    }

    /// Discover's row menu.
    ///
    /// Install waits for `brew info` details: until they're in, whether it
    /// compiles isn't known, and the menu must not skip that confirmation.
    public static func discover(_ e: CatalogEntry, installed: Bool, compileWarning: CompileWarning?, busy: Bool) -> [MenuEntry] {
        let install: MenuItemModel
        if installed {
            install = MenuItemModel(id: "show-installed", title: "Show in Installed", systemImage: "checkmark.circle",
                                    action: .showInInstalled)
        } else if !e.detailsLoaded {
            install = MenuItemModel(id: "install", title: "Install (checking…)", systemImage: "arrow.down.circle",
                                    action: .install(confirmCompile: false), isEnabled: false)
        } else {
            let compiles = compileWarning != nil
            install = MenuItemModel(id: "install", title: compiles ? "Install (compiles)" : "Install \(e.name)",
                                    systemImage: compiles ? "hammer" : "arrow.down.circle",
                                    action: .install(confirmCompile: compiles), isEnabled: !busy && !e.disabled)
        }
        let copy = [
            MenuItemModel(id: "copy-name", title: "Copy Name", systemImage: "doc.on.doc", action: .copy(e.name)),
            MenuItemModel(id: "copy-command", title: "Copy Install Command", systemImage: "terminal", action: .copy(e.installDisplay)),
        ]
        var open: [MenuItemModel] = []
        if let url = webURL(e.homepage) {
            open.append(MenuItemModel(id: "homepage", title: "Open Homepage", systemImage: "safari", action: .open(url)))
        }
        return joined([[install], copy, open])
    }

    /// The menu-bar list's row menu: Upgrade and Copy Name.
    public static func menuBarRow(_ p: Package, compileWarning: CompileWarning?, busy: Bool) -> [MenuEntry] {
        var items: [MenuEntry] = []
        if p.upgradeAvailable {
            items.append(.item(MenuItemModel(id: "upgrade",
                                             title: compileWarning == nil ? "Upgrade \(p.name)" : "Upgrade \(p.name) (compiles)",
                                             systemImage: compileWarning == nil ? "arrow.up.circle" : "hammer",
                                             action: .upgrade, isEnabled: !busy)))
        }
        items.append(.item(MenuItemModel(id: "copy-name", title: "Copy Name", systemImage: "doc.on.doc", action: .copy(p.name))))
        return items
    }

    /// Where the package lives on disk: `<Cellar>/<name>/<version>` for a
    /// formula, `<prefix>/Caskroom/<token>/<version>` for a cask. nil when
    /// the version isn't known.
    public static func kegPath(_ p: Package, host: HostInfo) -> String? {
        guard !p.installedVersion.isEmpty, !p.name.isEmpty else { return nil }
        switch p.kind {
        case .formula: return "\(host.platform.cellar)/\(p.name)/\(p.installedVersion)"
        case .cask: return "\(host.prefix)/Caskroom/\(p.name)/\(p.installedVersion)"
        }
    }

    /// http(s) URLs only: a homepage string is data from a tap.
    static func webURL(_ s: String?) -> URL? {
        guard let s, let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    /// Non-empty groups with a separator between each.
    static func joined(_ groups: [[MenuItemModel]]) -> [MenuEntry] {
        var out: [MenuEntry] = []
        for g in groups where !g.isEmpty {
            if !out.isEmpty { out.append(.separator) }
            out += g.map(MenuEntry.item)
        }
        return out
    }
}

/// "Show Dependencies" and "Show What Uses It" put a token in the Installed
/// search field ("deps:vim", "uses:xz"), so the list says why it's filtered
/// and clearing the field undoes it.
public enum RelatedSearch: Equatable, Sendable {
    case dependencies(of: String)
    case dependents(of: String)

    public static let dependenciesPrefix = "deps:"
    public static let dependentsPrefix = "uses:"

    public init?(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.lowercased().hasPrefix(Self.dependenciesPrefix) {
            let name = String(q.dropFirst(Self.dependenciesPrefix.count)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            self = .dependencies(of: name)
        } else if q.lowercased().hasPrefix(Self.dependentsPrefix) {
            let name = String(q.dropFirst(Self.dependentsPrefix.count)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            self = .dependents(of: name)
        } else {
            return nil
        }
    }

    public var query: String {
        switch self {
        case .dependencies(let n): return Self.dependenciesPrefix + n
        case .dependents(let n): return Self.dependentsPrefix + n
        }
    }

    var name: String {
        switch self {
        case .dependencies(let n), .dependents(let n): return n
        }
    }

    /// The package the token names: the selected one when it matches (a
    /// formula and a cask can share a name), else the first by full name,
    /// then by name.
    func target(in packages: [Package], selected: Package?) -> Package? {
        let n = name
        if let s = selected, s.fullName == n || s.name == n { return s }
        return packages.first { $0.fullName == n } ?? packages.first { $0.name == n }
    }

    /// The rows to show; nil when the token names nothing installed.
    public func rows(in packages: [Package], selected: Package?) -> [Package]? {
        guard let t = target(in: packages, selected: selected) else { return nil }
        switch self {
        case .dependencies: return Dependents.dependencies(of: t, among: packages)
        case .dependents: return Dependents.of(t, among: packages)
        }
    }
}
