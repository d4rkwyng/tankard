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
        /// 0.4: `AppStore.setPinned(p, true)`: `brew pin` through the queue.
        case pin
        /// 0.4: `AppStore.setPinned(p, false)`: `brew unpin` through the queue.
        case unpin
        /// 0.6: `AppStore.setVersionSkipped(p, true/false)`. No brew command.
        case skipVersion(Bool)
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
    /// - upgradeCommand: what Copy Upgrade Command copies, when it isn't the
    ///   plain command (0.4: `InsightsStore.upgradeDisplay`, which puts
    ///   `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1` in front of a cask upgrade when
    ///   "Don't quit running apps" is on).
    public static func installed(_ p: Package, dependents: [Package], dependencies: [Package],
                                 compileWarning: CompileWarning?, busy: Bool, kegPath: String?,
                                 upgradeCommand: String? = nil) -> [MenuEntry] {
        var actions: [MenuItemModel] = []
        if p.upgradeAvailable && p.isHeld {
            // brew won't upgrade a pinned package; unpin first.
            actions.append(MenuItemModel(id: "upgrade", title: String(localized: "Upgrade \(p.name) (pinned)"), systemImage: "pin",
                                         action: .upgrade, isEnabled: false))
        } else if p.upgradeAvailable {
            actions.append(MenuItemModel(id: "upgrade",
                                         title: upgradeTitle(p, compiles: compileWarning != nil),
                                         systemImage: compileWarning == nil ? "arrow.up.circle" : "hammer",
                                         action: .upgrade, isEnabled: !busy))
            if let v = p.currentVersion {
                actions.append(p.versionSkipped == true
                    ? MenuItemModel(id: "unskip-version", title: String(localized: "Don't Skip \(v)"), systemImage: "forward.end",
                                    action: .skipVersion(false))
                    : MenuItemModel(id: "skip-version", title: String(localized: "Skip Version \(v)"), systemImage: "forward.end",
                                    action: .skipVersion(true)))
            }
        }
        if BottleReplacement.isEligible(p) {
            actions.append(MenuItemModel(id: "replace-bottle", title: String(localized: "Replace with Bottle"),
                                         systemImage: "shippingbox.and.arrow.backward",
                                         action: .replaceWithBottle, isEnabled: !busy))
        }
        if PinCommands.offered(for: p) {
            actions.append(p.pinned
                ? MenuItemModel(id: "unpin", title: String(localized: "Unpin"), systemImage: "pin.slash", action: .unpin, isEnabled: !busy)
                : MenuItemModel(id: "pin", title: String(localized: "Pin"), systemImage: "pin", action: .pin, isEnabled: !busy))
        }
        actions.append(MenuItemModel(id: "uninstall", title: uninstallTitle(dependents: dependents),
                                     systemImage: dependents.isEmpty ? "trash" : "lock",
                                     action: .uninstall, isEnabled: !busy && dependents.isEmpty,
                                     isDestructive: true))

        var copy: [MenuItemModel] = [
            MenuItemModel(id: "copy-name", title: String(localized: "Copy Name"), systemImage: "doc.on.doc", action: .copy(p.name)),
        ]
        if p.upgradeAvailable {
            copy.append(MenuItemModel(id: "copy-command", title: String(localized: "Copy Upgrade Command"), systemImage: "terminal",
                                      action: .copy(upgradeCommand ?? BrewCommands.upgradeDisplay(for: p))))
        } else {
            copy.append(MenuItemModel(id: "copy-command", title: String(localized: "Copy Install Command"), systemImage: "terminal",
                                      action: .copy(BrewCommands.display(BrewCommands.installArguments(kind: p.kind, qualifiedName: p.qualifiedName)))))
        }

        var open: [MenuItemModel] = []
        if let url = webURL(p.homepage) {
            open.append(MenuItemModel(id: "homepage", title: String(localized: "Open Homepage"), systemImage: "safari", action: .open(url)))
        }
        if let page = p.releasePageURL {
            open.append(MenuItemModel(id: "release-page", title: String(localized: "Open Release Page"), systemImage: "arrow.up.right.square", action: .open(page)))
        }
        if let kegPath {
            open.append(MenuItemModel(id: "finder", title: String(localized: "Show in Finder"), systemImage: "folder", action: .revealInFinder(kegPath)))
        }

        let related = [
            MenuItemModel(id: "show-dependencies",
                          title: dependencies.isEmpty ? String(localized: "Show Dependencies") : String(localized: "Show Dependencies (\(dependencies.count))"),
                          systemImage: "arrow.down.right.circle", action: .showDependencies, isEnabled: !dependencies.isEmpty),
            MenuItemModel(id: "show-dependents",
                          title: dependents.isEmpty ? String(localized: "Show What Uses It") : String(localized: "Show What Uses It (\(dependents.count))"),
                          systemImage: "arrow.up.left.circle", action: .showDependents, isEnabled: !dependents.isEmpty),
        ]
        return joined([actions, copy, open, related])
    }

    /// "Uninstall…", or "Uninstall… (needed by vim, git +2)" when blocked.
    static func uninstallTitle(dependents: [Package]) -> String {
        guard !dependents.isEmpty else { return String(localized: "Uninstall…") }
        let names = dependents.prefix(3).map(\.name).joined(separator: ", ")
        let more = dependents.count > 3 ? " +\(dependents.count - 3)" : ""
        return String(localized: "Uninstall… (needed by \(names)\(more))")
    }

    /// Discover's Install (the row menu's and, 0.9.4, the detail pane's
    /// button): off until `brew info` details are in, since whether it
    /// compiles isn't known before, and the "Install (compiles)"
    /// confirmation must not be skipped. 0.9.4 (bug hunt): the detail
    /// pane's button didn't wait: in Intelbrew mode a formula with no bottle
    /// block read "Install foo" while "Asking brew info…" and started a
    /// source build at once.
    public static func discoverInstall(_ e: CatalogEntry, compileWarning: CompileWarning?, busy: Bool) -> MenuItemModel {
        guard e.detailsLoaded else {
            return MenuItemModel(id: "install", title: String(localized: "Install (checking…)"), systemImage: "arrow.down.circle",
                                 action: .install(confirmCompile: false), isEnabled: false)
        }
        // 0.9.4 (bug hunt R3): a formula whose bottle is still unknown once
        // the lookup is over (`brew info` failed or left it out) may
        // compile: Install asks first, as for one that does.
        let unverified = bottleUnverified(e, compileWarning: compileWarning)
        let compiles = compileWarning != nil || unverified
        // 0.9.4 (bug hunt R4): the lookup established no bottle either way:
        // "may compile", not "compiles".
        let title = unverified ? String(localized: "Install \(e.name) (may compile)…") : installTitle(e.name, compiles: compiles)
        return MenuItemModel(id: "install", title: title,
                             systemImage: compiles ? "hammer" : "arrow.down.circle",
                             action: .install(confirmCompile: compiles), isEnabled: !busy && !e.disabled)
    }

    /// 0.9.4 (bug hunt R3): whether brew can't say if installing `e`
    /// compiles: a formula with no bottle answer.
    public static func bottleUnknown(_ e: CatalogEntry) -> Bool {
        e.kind == .formula && e.bottle == .unknown
    }

    /// 0.9.4 (bug hunt R4): Install asks first only because the bottle is
    /// unknown (nothing says it compiles): its copy says it may.
    public static func bottleUnverified(_ e: CatalogEntry, compileWarning: CompileWarning?) -> Bool {
        compileWarning == nil && bottleUnknown(e)
    }

    /// Discover's row menu.
    ///
    /// Install waits for `brew info` details: until they're in, whether it
    /// compiles isn't known, and the menu must not skip that confirmation.
    public static func discover(_ e: CatalogEntry, installed: Bool, compileWarning: CompileWarning?, busy: Bool) -> [MenuEntry] {
        let install: MenuItemModel
        if installed {
            install = MenuItemModel(id: "show-installed", title: String(localized: "Show in Installed"), systemImage: "checkmark.circle",
                                    action: .showInInstalled)
        } else {
            install = discoverInstall(e, compileWarning: compileWarning, busy: busy)
        }
        let copy = [
            MenuItemModel(id: "copy-name", title: String(localized: "Copy Name"), systemImage: "doc.on.doc", action: .copy(e.name)),
            MenuItemModel(id: "copy-command", title: String(localized: "Copy Install Command"), systemImage: "terminal", action: .copy(e.installDisplay)),
        ]
        var open: [MenuItemModel] = []
        if let url = webURL(e.homepage) {
            open.append(MenuItemModel(id: "homepage", title: String(localized: "Open Homepage"), systemImage: "safari", action: .open(url)))
        }
        return joined([[install], copy, open])
    }

    /// 0.8.4: "Upgrade xz", or with "…" when it opens the upgrade plan
    /// first (UpgradePlan.needsConfirmation: it compiles, or a cask's
    /// installer asks for the password): "Upgrade xz (compiles)…".
    public static func upgradeTitle(_ p: Package, compiles: Bool) -> String {
        if compiles { return String(localized: "Upgrade \(p.name) (compiles)…") }
        return AdminPassword.required(p) ? String(localized: "Upgrade \(p.name)…") : String(localized: "Upgrade \(p.name)")
    }

    /// 0.8.4: "Install hello", or "Install node-red (compiles)…" (it opens
    /// the compile confirmation; it used to be "Install (compiles)").
    public static func installTitle(_ name: String, compiles: Bool) -> String {
        compiles ? String(localized: "Install \(name) (compiles)…") : String(localized: "Install \(name)")
    }

    /// The menu-bar list's row menu: Upgrade and Copy Name.
    public static func menuBarRow(_ p: Package, compileWarning: CompileWarning?, busy: Bool) -> [MenuEntry] {
        var items: [MenuEntry] = []
        if p.upgradeAvailable {
            items.append(.item(MenuItemModel(id: "upgrade",
                                             title: upgradeTitle(p, compiles: compileWarning != nil),
                                             systemImage: compileWarning == nil ? "arrow.up.circle" : "hammer",
                                             action: .upgrade, isEnabled: !busy)))
        }
        items.append(.item(MenuItemModel(id: "copy-name", title: String(localized: "Copy Name"), systemImage: "doc.on.doc", action: .copy(p.name))))
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
    static func webURL(_ s: String?) -> URL? { WebURL.from(s) }

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
    /// 0.7: "tap:user/repo", the Taps sheet's Show Installed.
    case tap(String)

    public static let dependenciesPrefix = "deps:"
    public static let dependentsPrefix = "uses:"
    public static let tapPrefix = "tap:"

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
        } else if q.lowercased().hasPrefix(Self.tapPrefix) {
            let name = String(q.dropFirst(Self.tapPrefix.count)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            self = .tap(name)
        } else {
            return nil
        }
    }

    public var query: String {
        switch self {
        case .dependencies(let n): return Self.dependenciesPrefix + n
        case .dependents(let n): return Self.dependentsPrefix + n
        case .tap(let n): return Self.tapPrefix + n
        }
    }

    var name: String {
        switch self {
        case .dependencies(let n), .dependents(let n), .tap(let n): return n
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
        if case .tap(let n) = self { return packages.filter { $0.tap?.lowercased() == n.lowercased() } }
        guard let t = target(in: packages, selected: selected) else { return nil }
        switch self {
        case .dependencies: return Dependents.dependencies(of: t, among: packages)
        case .dependents: return Dependents.of(t, among: packages)
        case .tap: return nil
        }
    }
}

/// 0.8.8 (security review #4): the only links Tankard opens from package
/// data (homepages, release pages, advisories, the self-update page) are
/// http and https with a host. `file:`, `smb:`, `ssh:` and app URL schemes
/// from a tap's metadata are never opened.
public enum WebURL {
    public static func from(_ s: String?) -> URL? {
        guard let s, let url = URL(string: s), isWeb(url) else { return nil }
        return url
    }

    public static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}
