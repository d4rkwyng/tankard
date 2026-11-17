import Foundation

public enum PackageKind: String, Codable, Sendable, CaseIterable {
    case formula
    case cask
}

/// One status per installed package. Precedence when several apply:
/// newer > noBottle > source > bottle (formulae); newer > cask (casks).
public enum PackageStatus: String, Codable, Sendable, CaseIterable {
    /// Poured from a bottle.
    case bottle
    /// Built from source (including HEAD installs).
    case source
    /// Installed version is newer than the tap's current version (for example
    /// installed from Homebrew's API before switching core to a fork).
    case newer
    /// The current version has no bottle for this macOS/arch/Cellar, so an
    /// upgrade or reinstall would compile.
    case noBottle
    /// A cask (casks have no bottles; they install the vendor's app).
    case cask
}

/// Who built the bottle the current formula version would pour.
public enum BottleOrigin: String, Codable, Sendable {
    /// Bottle URL on github.com/d4rkwyng/intelbrew-core.
    case intelbrew
    /// Bottle URL on ghcr.io/v2/homebrew/core.
    case homebrew
    case other
}

public struct Package: Codable, Sendable, Identifiable, Equatable {
    /// "formula:<tap>/<name>" or "cask:<tap>/<token>", e.g. "formula:homebrew/core/xz".
    /// Use this, not `name`, as the key: short names can collide across kinds and taps.
    public var id: String
    public var kind: PackageKind
    public var name: String
    public var fullName: String
    public var tap: String?
    public var desc: String?

    public var status: PackageStatus
    /// Human label: "bottle", "Intelbrew bottle", "Homebrew bottle", "source",
    /// "newer", "no bottle", "cask".
    public var statusLabel: String

    /// Newest installed version (formulae: with `_N` revision).
    public var installedVersion: String
    /// Every installed keg version (formulae can have several).
    public var installedVersions: [String]
    /// The tap's current version (formulae: with `_N` revision). nil for a
    /// formula with no stable spec (HEAD-only).
    public var currentVersion: String?

    /// Installed on request (true) or only as a dependency (false). Casks: always true.
    public var requested: Bool
    public var pinned: Bool
    public var kegOnly: Bool?
    public var deprecated: Bool
    public var disabled: Bool

    /// Formulae: whether the newest installed keg was poured from a bottle. nil for casks or unknown.
    public var pouredFromBottle: Bool?
    /// Formulae: whether the current version has a pourable bottle for this platform. nil for casks.
    public var currentHasBottle: Bool?
    /// Formulae: bottle tag that would be poured for the current version ("sonoma", "all", ...).
    public var bottleTag: String?
    /// Formulae: who built the current version's bottle. Set only when the
    /// installed version equals the current version (otherwise what was poured
    /// is unknown: receipts don't record the bottle URL).
    public var bottleOrigin: BottleOrigin?
    /// Formulae: URL of the bottle the current version would pour (set with `bottleTag`).
    public var bottleURL: String?
    /// When the newest installed keg (or the cask) was installed, if brew recorded it.
    public var installedAt: Date?

    /// brew's own `outdated` flag from `brew info --json=v2 --installed`.
    public var upgradeAvailable: Bool
    /// Formulae with an upgrade: whether the upgrade pours a bottle (false = compiles). nil otherwise.
    public var upgradeHasBottle: Bool?
    /// Casks: the app updates itself (brew skips these in `outdated` unless --greedy).
    public var autoUpdates: Bool?
    /// Formulae this package needs: for a formula, the newest keg's receipt
    /// (recursive runtime dependencies), else its declared dependencies; for
    /// a cask, `depends_on` formulae. Names as brew gives them. nil only in
    /// reports written before Tankard 0.2.
    public var dependencies: [String]? = nil
    /// Casks: `depends_on` casks. nil for formulae.
    public var caskDependencies: [String]? = nil
    /// The formula's or cask's homepage, from `brew info`. nil in reports
    /// written before Tankard 0.3, or when brew gives none.
    public var homepage: String? = nil
    /// 0.4: the formulae this one declares directly (receipt entries with
    /// `declared_directly`, in brew's order), for the dependency tree. nil
    /// for casks (their `dependencies` are already direct) and in reports
    /// written before Tankard 0.4.
    public var directDependencies: [String]? = nil

    public var isDependency: Bool { !requested }

    /// A placeholder row for a sheet run that isn't about one package
    /// (`brew cleanup`). Not a real package: its id starts with "command:".
    public static func command(_ title: String) -> Package {
        Package(id: "command:\(title)", kind: .formula, name: title, fullName: title, tap: nil, desc: nil,
                status: .bottle, statusLabel: "", installedVersion: "", installedVersions: [], currentVersion: nil,
                requested: true, pinned: false, kegOnly: nil, deprecated: false, disabled: false,
                pouredFromBottle: nil, currentHasBottle: nil, bottleTag: nil, bottleOrigin: nil, bottleURL: nil,
                installedAt: nil, upgradeAvailable: false, upgradeHasBottle: true, autoUpdates: nil)
    }
}

public struct StatusSummary: Codable, Sendable, Equatable {
    public var installed: Int
    public var formulae: Int
    public var casks: Int
    /// status == bottle
    public var bottled: Int
    /// status == bottle and bottleOrigin == intelbrew
    public var intelbrewBottled: Int
    public var source: Int
    public var newer: Int
    public var noBottle: Int
    /// Formulae with an upgrade, plus outdated casks.
    public var upgrades: Int
    /// Formula upgrades that pour a bottle.
    public var upgradesWithBottle: Int
    /// Formula upgrades that would compile.
    public var upgradesFromSource: Int
    public var caskUpgrades: Int
    public var requested: Int
    public var dependencies: Int

    public init(packages: [Package]) {
        func count(_ p: (Package) -> Bool) -> Int { packages.lazy.filter(p).count }
        installed = packages.count
        formulae = count { $0.kind == .formula }
        casks = count { $0.kind == .cask }
        bottled = count { $0.status == .bottle }
        intelbrewBottled = count { $0.status == .bottle && $0.bottleOrigin == .intelbrew }
        source = count { $0.status == .source }
        newer = count { $0.status == .newer }
        noBottle = count { $0.status == .noBottle }
        upgrades = count { $0.upgradeAvailable }
        upgradesWithBottle = count { $0.upgradeAvailable && $0.kind == .formula && $0.upgradeHasBottle == true }
        upgradesFromSource = count { $0.upgradeAvailable && $0.kind == .formula && $0.upgradeHasBottle != true }
        caskUpgrades = count { $0.upgradeAvailable && $0.kind == .cask }
        requested = count { $0.requested }
        dependencies = count { !$0.requested }
    }

    /// "142 installed · 128 bottled · 9 source · 5 newer · 5 upgrades (4 with bottles)".
    /// Segments for no-bottle, casks, compiling upgrades and cask upgrades
    /// appear only when non-zero, so the status segments always add up to
    /// "installed".
    public var line: String {
        var parts = ["\(installed) installed", "\(bottled) bottled", "\(source) source", "\(newer) newer"]
        if noBottle > 0 { parts.append("\(noBottle) no bottle") }
        if casks > 0 { parts.append("\(casks) casks") }
        var detail = ["\(upgradesWithBottle) with bottles"]
        if upgradesFromSource > 0 { detail.append("\(upgradesFromSource) compile") }
        if caskUpgrades > 0 { detail.append("\(caskUpgrades) casks") }
        parts.append("\(upgrades) upgrades (\(detail.joined(separator: ", ")))")
        return parts.joined(separator: " · ")
    }
}

/// Where Homebrew/brew and homebrew/core point, read from their git checkouts.
public struct ForkStatus: Codable, Sendable, Equatable {
    /// homebrew/core tap checkout; nil when brew runs in API mode (no local core tap).
    public var coreTapPath: String?
    public var coreOrigin: String?
    public var coreBranch: String?
    public var coreIsFork: Bool
    public var brewRepository: String
    public var brewOrigin: String?
    public var brewIsFork: Bool
    /// `git describe --tags` of Homebrew/brew ("7.0.14", or "7.0.10-16-g41f40de" between tags).
    public var brewVersion: String?
    /// The release tag HEAD sits exactly on, if any.
    public var brewTag: String?
    /// Newest N.N.N tag known locally (or on the remote when checked with --remote).
    public var brewNewestTag: String?
    /// "local" or "remote": where brewNewestTag came from.
    public var brewNewestTagSource: String?
    /// brewTag == brewNewestTag. nil when either is unknown.
    public var brewAtNewestTag: Bool?

    public init(coreTapPath: String? = nil, coreOrigin: String? = nil, coreBranch: String? = nil,
                coreIsFork: Bool = false, brewRepository: String, brewOrigin: String? = nil,
                brewIsFork: Bool = false, brewVersion: String? = nil, brewTag: String? = nil,
                brewNewestTag: String? = nil, brewNewestTagSource: String? = nil, brewAtNewestTag: Bool? = nil) {
        self.coreTapPath = coreTapPath
        self.coreOrigin = coreOrigin
        self.coreBranch = coreBranch
        self.coreIsFork = coreIsFork
        self.brewRepository = brewRepository
        self.brewOrigin = brewOrigin
        self.brewIsFork = brewIsFork
        self.brewVersion = brewVersion
        self.brewTag = brewTag
        self.brewNewestTag = brewNewestTag
        self.brewNewestTagSource = brewNewestTagSource
        self.brewAtNewestTag = brewAtNewestTag
    }
}

public struct HostInfo: Codable, Sendable, Equatable {
    public var brewPath: String
    public var prefix: String
    public var repository: String
    public var platform: BottlePlatform
    public var bottleTag: String?
}

/// Everything `tankard status --json` prints. schemaVersion bumps on any
/// breaking change; fields are only ever added within a version.
public struct StatusReport: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: Date
    public var host: HostInfo
    public var intelbrew: IntelbrewDetection
    public var fork: ForkStatus
    public var summary: StatusSummary
    public var packages: [Package]
    /// Wall-clock milliseconds per step ("detect", "info", "git", "total").
    public var timingsMs: [String: Int]
    /// Non-fatal problems (a brew call that failed, unreadable git checkout, ...).
    public var warnings: [String]

    public init(generatedAt: Date, host: HostInfo, intelbrew: IntelbrewDetection, fork: ForkStatus,
                packages: [Package], timingsMs: [String: Int] = [:], warnings: [String] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.host = host
        self.intelbrew = intelbrew
        self.fork = fork
        self.summary = StatusSummary(packages: packages)
        self.packages = packages
        self.timingsMs = timingsMs
        self.warnings = warnings
    }

    public static func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
