import Foundation

/// 0.4: how installed packages depend on each other, from the `brew info`
/// JSON Tankard already has (receipts' runtime dependencies and casks'
/// `depends_on`). No extra brew calls.
///
/// - `dependencies(of:)` is the receipt's runtime dependencies: every
///   installed package it was linked against, recursively. That is what
///   `brew deps --installed <formula>` prints, or a superset: brew leaves out
///   linkage the formula doesn't declare (p11-kit under gnutls, for one).
/// - `dependents(of:)` is what `brew uses --installed <formula>` prints:
///   the installed packages whose receipts list it.
/// - `direct(of:)` is the first level of `brew deps --tree`: the receipt
///   entries marked `declared_directly`, in brew's order.
/// - `isLeaf` matches `brew leaves`: nothing installed needs it.
///
/// Checked against real output from the Intel VM and the arm64 Mac (see
/// the `*-deps-*`, `*-uses-*` and `*-leaves*` fixtures).
public struct DependencyGraph: Sendable {
    public let packages: [Package]
    /// Package ids that some other installed package needs.
    private let usedIDs: Set<String>
    private let formulae: [String: Package]
    private let casks: [String: Package]

    public init(_ packages: [Package]) {
        self.packages = packages
        var formulae: [String: Package] = [:]
        var casks: [String: Package] = [:]
        for p in packages {
            var keys = [p.fullName, p.name]
            if let tap = p.tap { keys.append("\(tap)/\(p.name)") }
            for k in keys {
                // A short name belongs to the default tap; other taps answer
                // only to their qualified names (as `Dependents.names` does).
                if k == p.name, k != p.fullName, !Self.isDefaultTap(p.tap) { continue }
                if p.kind == .formula {
                    if formulae[k] == nil { formulae[k] = p }
                } else if casks[k] == nil {
                    casks[k] = p
                }
            }
        }
        self.formulae = formulae
        self.casks = casks
        var used = Set<String>()
        for p in packages {
            for d in p.dependencies ?? [] {
                if let t = formulae[d], t.id != p.id { used.insert(t.id) }
            }
            for d in p.caskDependencies ?? [] {
                if let t = casks[d], t.id != p.id { used.insert(t.id) }
            }
        }
        usedIDs = used
    }

    static func isDefaultTap(_ tap: String?) -> Bool {
        tap == nil || tap == "homebrew/core" || tap == "homebrew/cask"
    }

    /// The installed formula a dependency name refers to.
    public func formula(named name: String) -> Package? { formulae[name] }
    public func cask(named name: String) -> Package? { casks[name] }

    /// Nothing installed needs it (`brew leaves`, plus casks).
    public func isLeaf(_ p: Package) -> Bool { !usedIDs.contains(p.id) }

    /// Installed on request and nothing installed needs it
    /// (`brew leaves --installed-on-request`, plus casks).
    public func isRequestedLeaf(_ p: Package) -> Bool { p.requested && isLeaf(p) }

    /// Every installed package `p` needs, recursively, sorted by name: a
    /// formula's receipt (what it was linked against, already recursive);
    /// a cask's `depends_on` plus what those need.
    public func dependencies(of p: Package) -> [Package] {
        let direct = Dependents.dependencies(of: p, among: packages)
        guard p.kind == .cask else { return direct }
        var seen = Set(direct.map(\.id))
        var out = direct
        for d in direct {
            for sub in Dependents.dependencies(of: d, among: packages) where sub.id != p.id && seen.insert(sub.id).inserted {
                out.append(sub)
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Installed packages that need `p`, sorted by name.
    public func dependents(of p: Package) -> [Package] {
        Dependents.of(p, among: packages)
    }

    /// The names `p` depends on directly, in brew's order.
    public func directNames(of p: Package) -> [String] {
        if p.kind == .cask { return (p.dependencies ?? []) + (p.caskDependencies ?? []) }
        if let d = p.directDependencies { return d }
        // A report from before 0.4: the recursive list minus everything its
        // members already bring in (a transitive reduction).
        let all = p.dependencies ?? []
        var indirect = Set<String>()
        for name in all {
            guard let d = formulae[name] else { continue }
            for sub in d.dependencies ?? [] {
                indirect.insert(sub)
                if let s = formulae[sub] { indirect.insert(s.fullName); indirect.insert(s.name) }
            }
        }
        return all.filter { name in
            guard !indirect.contains(name) else { return false }
            if let d = formulae[name] { return !indirect.contains(d.fullName) && !indirect.contains(d.name) }
            return true
        }
    }

    /// One node of the dependency tree.
    public struct Node: Identifiable, Sendable, Equatable {
        /// The path from the root ("python@3.15/zstd/xz"): unique per row.
        public var id: String
        /// As the parent's receipt names it.
        public var name: String
        /// The installed package, when it is installed.
        public var packageID: String?
        public var children: [Node]
        /// Already on the path above (a cycle; not expanded again).
        public var isCycle = false
        /// Cut off at the depth limit.
        public var isTruncated = false

        /// `brew deps --tree` style text, for tests and copying.
        public func treeText() -> String {
            var lines = [name]
            func walk(_ n: Node, _ prefix: String) {
                for (i, c) in n.children.enumerated() {
                    let last = i == n.children.count - 1
                    lines.append(prefix + (last ? "└── " : "├── ") + c.name)
                    walk(c, prefix + (last ? "    " : "│   "))
                }
            }
            walk(self, "")
            return lines.joined(separator: "\n")
        }

        /// Rows below this one, counting repeats.
        public var descendantCount: Int { children.reduce(0) { $0 + 1 + $1.descendantCount } }
    }

    /// The tree under `p`, like `brew deps --tree --installed` (repeated
    /// subtrees are shown again, as brew does without `--prune`).
    public func tree(of p: Package, maxDepth: Int = 16) -> Node {
        func build(_ name: String, package: Package?, path: String, seen: Set<String>, depth: Int) -> Node {
            var node = Node(id: path, name: name, packageID: package?.id, children: [])
            guard let package else { return node }
            if depth >= maxDepth {
                node.isTruncated = !directNames(of: package).isEmpty
                return node
            }
            var seen = seen
            seen.insert(package.id)
            for d in directNames(of: package) {
                let target = package.kind == .cask && (package.caskDependencies ?? []).contains(d) ? casks[d] : formulae[d]
                let childPath = path + "/" + d
                if let t = target, seen.contains(t.id) {
                    node.children.append(Node(id: childPath, name: d, packageID: t.id, children: [], isCycle: true))
                    continue
                }
                node.children.append(build(d, package: target, path: childPath, seen: seen, depth: depth + 1))
            }
            return node
        }
        return build(p.name, package: p, path: p.id, seen: [], depth: 0)
    }
}
