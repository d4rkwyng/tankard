import Foundation

/// The bottle badge in Discover: what installing this package would do on
/// this Mac.
public enum CatalogBottle: String, Codable, Sendable {
    /// A bottle brew would pour here (Homebrew's, or any non-Intelbrew host).
    case forThisMac
    /// Intelbrew mode: the matching bottle is on d4rkwyng/intelbrew-core.
    case intelbrew
    /// No usable bottle: installing compiles.
    case fromSource
    /// Casks have no bottles.
    case cask
    /// Not known yet (Intelbrew mode, before `brew info` has answered).
    case unknown
}

/// One formula or cask Discover can show and install.
public struct CatalogEntry: Sendable, Identifiable, Equatable {
    /// "formula:homebrew/core/xz" / "cask:homebrew/cask/firefox", the same
    /// form as `Package.id`, so "installed" is a plain id lookup.
    public var id: String
    public var kind: PackageKind
    public var name: String
    public var fullName: String
    public var tap: String?
    public var desc: String?
    /// Formulae: stable version with `_revision`; casks: the version.
    public var version: String?
    public var homepage: String?
    public var license: String?
    /// Formula dependencies (declared); casks: `depends_on` formulae.
    public var dependencies: [String]
    /// Casks: `depends_on` casks.
    public var caskDependencies: [String]
    /// Formula aliases and old names; cask display names ("Mozilla Firefox").
    public var otherNames: [String]
    public var deprecated: Bool
    public var disabled: Bool
    public var bottle: CatalogBottle
    public var bottleTag: String?
    public var bottleURL: String?
    /// False while only the name and description are known (Intelbrew mode
    /// reads the tap first and asks `brew info` for the rest lazily).
    public var detailsLoaded: Bool

    // Lower-cased once, for search.
    var keyName: String
    var keyFull: String
    var keyOther: [String]
    var keyDesc: String

    public init(kind: PackageKind, name: String, fullName: String, tap: String?, desc: String?,
                version: String? = nil, homepage: String? = nil, license: String? = nil,
                dependencies: [String] = [], caskDependencies: [String] = [], otherNames: [String] = [],
                deprecated: Bool = false, disabled: Bool = false, bottle: CatalogBottle,
                bottleTag: String? = nil, bottleURL: String? = nil, detailsLoaded: Bool = true) {
        self.id = "\(kind.rawValue):" + StatusClassifier.qualified(tap: tap, name: fullName)
        self.kind = kind
        self.name = name
        self.fullName = fullName
        self.tap = tap
        self.desc = desc
        self.version = version
        self.homepage = homepage
        self.license = license
        self.dependencies = dependencies
        self.caskDependencies = caskDependencies
        self.otherNames = otherNames
        self.deprecated = deprecated
        self.disabled = disabled
        self.bottle = bottle
        self.bottleTag = bottleTag
        self.bottleURL = bottleURL
        self.detailsLoaded = detailsLoaded
        keyName = name.lowercased()
        keyFull = fullName.lowercased()
        keyOther = otherNames.map { $0.lowercased() }
        keyDesc = (desc ?? "").lowercased()
    }

    /// "homebrew/core/xz": what install and uninstall are given.
    public var qualifiedName: String {
        guard let colon = id.firstIndex(of: ":") else { return fullName }
        return String(id[id.index(after: colon)...])
    }

    /// The same entry with `brew info`'s details filled in (keeps the id).
    public func merging(_ details: CatalogEntry) -> CatalogEntry {
        var e = details
        if e.desc == nil { e.desc = desc }
        if e.otherNames.isEmpty { e.otherNames = otherNames; e.keyOther = keyOther }
        e.keyDesc = (e.desc ?? "").lowercased()
        return e
    }

    /// A `Package` for the install sheet, which shows packages. Marked as
    /// requested, current, not yet installed.
    public func asPackage() -> Package {
        Package(id: id, kind: kind, name: name, fullName: fullName, tap: tap, desc: desc,
                status: kind == .cask ? .cask : (bottle == .fromSource ? .noBottle : .bottle),
                statusLabel: "", installedVersion: "", installedVersions: [], currentVersion: version,
                requested: true, pinned: false, kegOnly: nil, deprecated: deprecated, disabled: disabled,
                pouredFromBottle: nil, currentHasBottle: kind == .formula ? (bottle == .forThisMac || bottle == .intelbrew) : nil,
                bottleTag: bottleTag, bottleOrigin: bottle == .intelbrew ? .intelbrew : nil, bottleURL: bottleURL,
                installedAt: nil, upgradeAvailable: false,
                upgradeHasBottle: kind == .formula ? (bottle == .forThisMac || bottle == .intelbrew) : nil,
                autoUpdates: nil, dependencies: dependencies, caskDependencies: caskDependencies)
    }
}

/// Turns brew's formula and cask JSON (formulae.brew.sh's API or
/// `brew info --json=v2`, the same shapes) into catalog entries.
public struct CatalogBuilder: Sendable {
    public var platform: BottlePlatform
    public var intelbrewMode: Bool

    public init(platform: BottlePlatform, intelbrewMode: Bool) {
        self.platform = platform
        self.intelbrewMode = intelbrewMode
    }

    public func bottle(for f: BrewInfoJSON.Formula) -> (CatalogBottle, String?, String?) {
        guard let match = platform.bottle(in: f.bottle["stable"]), match.usable else { return (.fromSource, nil, nil) }
        let origin = StatusClassifier.bottleOrigin(url: match.url)
        return (intelbrewMode && origin == .intelbrew ? .intelbrew : .forThisMac, match.tag, match.url)
    }

    public func entry(_ f: BrewInfoJSON.Formula) -> CatalogEntry {
        let (badge, tag, url) = bottle(for: f)
        return CatalogEntry(kind: .formula, name: f.name, fullName: f.fullName, tap: f.tap, desc: f.desc,
                            version: f.currentPkgVersion ?? f.versions.head.map { "HEAD (\($0))" },
                            homepage: f.homepage, license: f.license, dependencies: f.dependencies ?? [],
                            otherNames: (f.aliases ?? []) + (f.oldnames ?? []),
                            deprecated: f.deprecated ?? false, disabled: f.disabled ?? false,
                            bottle: badge, bottleTag: tag, bottleURL: url)
    }

    public func entry(_ c: BrewInfoJSON.Cask) -> CatalogEntry {
        CatalogEntry(kind: .cask, name: c.token, fullName: c.fullToken, tap: c.tap, desc: c.desc,
                     version: c.version, homepage: c.homepage, license: nil,
                     dependencies: c.dependsOn?.formula ?? [], caskDependencies: c.dependsOn?.cask ?? [],
                     otherNames: c.name ?? [], deprecated: c.deprecated ?? false, disabled: c.disabled ?? false,
                     bottle: .cask)
    }
}

public enum CatalogKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all, formulae, casks

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .formulae: return "Formulae"
        case .casks: return "Casks"
        }
    }

    public func includes(_ kind: PackageKind) -> Bool {
        switch self {
        case .all: return true
        case .formulae: return kind == .formula
        case .casks: return kind == .cask
        }
    }
}

/// In-memory search over the catalog: name first, then other names, then
/// description.
public enum CatalogSearch {
    /// Higher is better; nil means no match.
    ///
    ///   1000 exact name (or full name, alias, cask display name)
    ///    800 name starts with the query
    ///    700 another name starts with it
    ///    600 name contains it
    ///    500 another name contains it
    ///    300 description contains the whole query
    ///    200 every word of the query is somewhere in name, names or description
    ///
    /// Deprecated and disabled packages lose 50, so a live package wins a tie.
    public static func score(_ e: CatalogEntry, query q: String, words: [String]) -> Int? {
        var s: Int?
        if e.keyName == q || e.keyFull == q || e.keyOther.contains(q) {
            s = 1000
        } else if e.keyName.hasPrefix(q) || e.keyFull.hasPrefix(q) {
            s = 800
        } else if e.keyOther.contains(where: { $0.hasPrefix(q) }) {
            s = 700
        } else if e.keyName.contains(q) || (q.contains("/") && e.keyFull.contains(q)) {
            s = 600
        } else if e.keyOther.contains(where: { $0.contains(q) }) {
            s = 500
        } else if e.keyDesc.contains(q) {
            s = 300
        } else if words.count > 1, words.allSatisfy({ w in
            e.keyName.contains(w) || e.keyDesc.contains(w) || e.keyOther.contains { $0.contains(w) }
        }) {
            s = 200
        }
        guard let base = s else { return nil }
        return base - (e.deprecated || e.disabled ? 50 : 0)
    }

    /// The best `limit` matches, best first. Ties: shorter name, then
    /// alphabetical, then formula before cask.
    public static func search(_ query: String, in entries: [CatalogEntry], kind: CatalogKindFilter = .all,
                              limit: Int = 200) -> [CatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        var hits: [(Int, CatalogEntry)] = []
        for e in entries where kind.includes(e.kind) {
            if let s = score(e, query: q, words: words) { hits.append((s, e)) }
        }
        hits.sort { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            if a.1.name.count != b.1.name.count { return a.1.name.count < b.1.name.count }
            if a.1.name != b.1.name { return a.1.name < b.1.name }
            return a.1.kind == .formula && b.1.kind == .cask
        }
        return hits.prefix(limit).map(\.1)
    }
}

/// Which installed packages need a given one (uninstall is blocked while
/// any do).
public enum Dependents {
    /// Whether dependency name `dep` (as brew lists it: "xz",
    /// "homebrew/core/xz", "user/tap/foo") names `target`.
    static func names(_ dep: String, _ target: Package) -> Bool {
        if dep == target.fullName { return true }
        if let tap = target.tap, dep == "\(tap)/\(target.name)" { return true }
        // A short name means the default tap.
        if dep == target.name, target.tap == nil || target.tap == "homebrew/core" || target.tap == "homebrew/cask" {
            return true
        }
        return false
    }

    /// Installed packages (other than `target`) that depend on it, sorted by name.
    public static func of(_ target: Package, among installed: [Package]) -> [Package] {
        installed.filter { p in
            guard p.id != target.id else { return false }
            let deps = target.kind == .formula ? (p.dependencies ?? []) : (p.caskDependencies ?? [])
            return deps.contains { names($0, target) }
        }
        .sorted { $0.name < $1.name }
    }
}
