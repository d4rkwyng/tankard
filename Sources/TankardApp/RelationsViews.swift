import Observation
import SwiftUI
import TankardAppModel
import TankardCore

// v0.4 (part A): the pinned badge, the "More" filters, and the detail
// pane's pin box, Depends on / Used by links and dependency tree. The
// store comes from the environment (DetailPane sets it), so PackageDetail's
// own signature doesn't change.

/// "Pinned" next to a package's name in the table.
struct PinnedBadge: View {
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.theme) private var theme

    var body: some View {
        let p = theme.badge(.newer)
        let selected = prominence == .increased && !theme.isCustom
        HStack(spacing: 2) {
            Image(systemName: "pin.fill").font(.system(size: 8))
            Text("pinned").font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(selected ? Color.white : p.foreground)
        .padding(.horizontal, 4).padding(.vertical, 0.5)
        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.white.opacity(0.16) : p.background))
        .fixedSize()
        .help("Pinned: brew upgrade skips it, and Upgrade All leaves it out")
    }
}

/// Pin box, Depends on, Used by and the dependency tree, under the
/// detail pane's facts.
struct PackageRelationsSection: View {
    var package: Package
    @Environment(AppStore.self) private var store: AppStore?
    @Environment(\.theme) private var theme

    var body: some View {
        if let store {
            let graph = store.dependencyGraph
            VStack(alignment: .leading, spacing: 12) {
                PinBox(package: package, busy: store.isBusy, running: store.quickAction) { pin in
                    store.setPinned(package, pin)
                }
                let uses = graph.dependents(of: package)
                let deps = graph.dependencies(of: package)
                if !deps.isEmpty {
                    PackageLinks(title: String(localized: "Depends on"), help: String(localized: "From its receipt: everything installed it was linked against (brew deps --installed can list fewer)"),
                                 packages: deps) { store.reveal($0) }
                }
                if !uses.isEmpty {
                    PackageLinks(title: String(localized: "Used by"), help: String(localized: "brew uses --installed: installed packages that need it"),
                                 packages: uses) { store.reveal($0) }
                }
                if !graph.directNames(of: package).isEmpty {
                    DependencyTreeView(root: graph.tree(of: package)) { store.reveal($0) }
                        .id(package.id)
                }
            }
        }
    }
}

struct PinBox: View {
    var package: Package
    var busy: Bool
    var running: String?
    var setPinned: (Bool) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let p = package
        let command = PinCommands.display(pin: !p.pinned, for: p)
        if p.pinned {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    PinnedBadge()
                    Text("Pinned at \(p.installedVersion)").font(.system(size: 12, weight: .medium))
                }
                Text(p.upgradeAvailable
                     ? String(localized: "\(p.currentVersion ?? String(localized: "A newer version")) is available, but this package is pinned: brew upgrade and Upgrade All skip it. Unpin it to upgrade.")
                     : String(localized: "brew won't upgrade it, and Upgrade All leaves it out."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CommandBox(command: command)
                HStack(spacing: 8) {
                    Button {
                        setPinned(false)
                    } label: {
                        Label("Unpin", systemImage: "pin.slash")
                    }
                    .disabled(busy)
                    .help(command)
                    if let running, running.hasPrefix("brew unpin") || running.hasPrefix("brew pin") {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.badge(.newer).background.opacity(0.6)))
        } else {
            HStack(spacing: 8) {
                Button {
                    setPinned(true)
                } label: {
                    Label("Pin", systemImage: "pin")
                }
                .controlSize(.small)
                .disabled(busy)
                .help("\(command): brew upgrade and Upgrade All will skip it")
                // Wraps rather than truncating: a long version (or the
                // narrow detail pane at 1040x620) cut the sentence off.
                Text("Keeps \(p.installedVersion); upgrades skip it")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Keeps \(p.installedVersion); upgrades skip it")
                if let running, running.hasPrefix("brew pin") {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

/// "Depends on (9)" with each package as a link that selects it.
struct PackageLinks: View {
    var title: String
    var help: String
    var packages: [Package]
    var select: (Package.ID) -> Void
    static let limit = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: "\(title) (\(packages.count))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .help(help)
            FlowLayout(spacing: 5) {
                ForEach(packages.prefix(Self.limit)) { p in
                    LinkChip(title: p.name, isCask: p.kind == .cask) { select(p.id) }
                }
                if packages.count > Self.limit {
                    Text("+\(packages.count - Self.limit) more").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct LinkChip: View {
    var title: String
    var isCask = false
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if isCask { Image(systemName: "macwindow").font(.system(size: 9)) }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.isCustom ? theme.accent : Color.accentColor)
        .help("Select \(title)")
    }
}

/// Which tree rows are open. A class in `State(initialValue:)`: `@State` is
/// a macro whose plugin isn't in the Command Line Tools.
@Observable @MainActor
final class TreeExpansion {
    var open: Set<String>
    init(open: Set<String>) { self.open = open }
}

/// The expandable dependency tree (`brew deps --tree --installed`, from
/// the receipts Tankard already read).
struct DependencyTreeView: View {
    var root: DependencyGraph.Node
    var select: (Package.ID) -> Void
    /// TANKARD_TREE=all: open every row on launch (screenshots).
    static let expandAll = ProcessInfo.processInfo.environment["TANKARD_TREE"] == "all"

    private let expansion: State<TreeExpansion>
    private let shownState: State<Bool>

    init(root: DependencyGraph.Node, select: @escaping (Package.ID) -> Void) {
        self.root = root
        self.select = select
        // A static function, not a local one passed to forEach: Swift 6.0
        // (the macOS 14 VM) calls that a throwing call.
        let open: Set<String> = Self.expandAll ? Self.ids(root) : [root.id]
        expansion = State(initialValue: TreeExpansion(open: open))
        shownState = State(initialValue: Self.expandAll)
    }

    static func ids(_ n: DependencyGraph.Node) -> Set<String> {
        var out: Set<String> = [n.id]
        for c in n.children { out.formUnion(ids(c)) }
        return out
    }

    var body: some View {
        let shown = Binding(get: { shownState.wrappedValue }, set: { shownState.wrappedValue = $0 })
        DisclosureGroup(isExpanded: shown) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows(root, depth: 0), id: \.node.id) { row in
                    TreeRow(node: row.node, depth: row.depth, expansion: expansion.wrappedValue, select: select)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Dependency tree (\(root.children.count) direct, \(Set(allNames(root)).count) in all)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .help(Text(verbatim: "brew deps --tree --installed \(root.name)"))
        }
    }

    private func allNames(_ n: DependencyGraph.Node) -> [String] {
        n.children.flatMap { [$0.name] + allNames($0) }
    }

    /// Visible rows, depth-first, under open nodes only.
    private func rows(_ n: DependencyGraph.Node, depth: Int) -> [(node: DependencyGraph.Node, depth: Int)] {
        guard expansion.wrappedValue.open.contains(n.id) else { return [] }
        return n.children.flatMap { c in [(c, depth)] + rows(c, depth: depth + 1) }
    }
}

struct TreeRow: View {
    var node: DependencyGraph.Node
    var depth: Int
    var expansion: TreeExpansion
    var select: (Package.ID) -> Void

    var body: some View {
        let open = expansion.open.contains(node.id)
        HStack(spacing: 4) {
            if node.children.isEmpty {
                Color.clear.frame(width: 12, height: 12)
            } else {
                Button {
                    if open { expansion.open.remove(node.id) } else { expansion.open.insert(node.id) }
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(open ? String(localized: "Collapse") : String(localized: "Expand (\(node.descendantCount))"))
            }
            if let id = node.packageID {
                LinkChip(title: node.name) { select(id) }
            } else {
                Text(node.name).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("not installed").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if node.isCycle {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Already above in this branch")
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
