import Foundation

// One classification for "will this compile?", shared by the upgrade sheet,
// the Upgrades filter and Discover (v0.3). Everything here is pure.

/// How brew would get a formula onto this Mac.
public enum BuildMethod: Sendable, Equatable {
    /// Pours a bottle (whose, when known).
    case bottle(BottleOrigin?)
    /// No usable bottle: brew compiles from source.
    case compile
    /// Not known yet (Discover before brew info or the tap scan answered).
    case unknown
    /// Casks, and packages with nothing to install (no upgrade pending).
    case notApplicable

    public var compiles: Bool { self == .compile }
}

/// Seconds a formula usually takes to build on this kind of Mac.
///
/// In Intelbrew mode the app uses `BuildTimeSource` (Intelbrew's
/// build-times.json, fetched when a compile warning is shown); otherwise
/// `NoBuildTimeEstimates`.
public protocol BuildTimeEstimating: Sendable {
    /// nil when unknown.
    func estimatedSeconds(forFormula name: String) -> Double?
}

/// The default: no estimates.
public struct NoBuildTimeEstimates: BuildTimeEstimating {
    public init() {}
    public func estimatedSeconds(forFormula name: String) -> Double? { nil }
}

/// A fixed map (tests, and the shape a future JSON file would decode into).
public struct BuildTimeTable: BuildTimeEstimating, Decodable {
    public var seconds: [String: Double]
    public init(seconds: [String: Double]) { self.seconds = seconds }
    public func estimatedSeconds(forFormula name: String) -> Double? { seconds[name] }
}

/// The orange "this compiles" mark.
public struct CompileWarning: Sendable, Equatable {
    public enum Context: Sendable { case upgrade, install }

    public var context: Context
    /// Present only when an estimator knew this formula.
    public var estimatedSeconds: Double?

    public init(context: Context, estimatedSeconds: Double? = nil) {
        self.context = context
        self.estimatedSeconds = estimatedSeconds
    }

    /// "No bottle: will compile from source" (upgrades) or
    /// "No bottle: compiles" (Discover rows and badges).
    public var label: String {
        context == .upgrade ? "No bottle: will compile from source" : "No bottle: compiles"
    }

    /// "at least ~25 min on the Intelbrew builder", or nil without an
    /// estimate. Rounded up, and never a precise single number: the builder
    /// is a fast Mac, older Macs take longer.
    public var estimateText: String? {
        guard let s = estimatedSeconds, s > 0 else { return nil }
        let min = Int((s / 60).rounded(.up))
        let amount = min >= 90 ? "~\(Int((s / 3600).rounded(.up))) h" : "~\(max(1, min)) min"
        return "at least \(amount) on the Intelbrew builder"
    }

    /// The label plus the estimate when there is one.
    public var text: String {
        estimateText.map { "\(label) (\($0))" } ?? label
    }
}

public struct CompileClassifier: Sendable {
    public var estimator: BuildTimeEstimating

    public init(estimator: BuildTimeEstimating = NoBuildTimeEstimates()) {
        self.estimator = estimator
    }

    /// What `brew upgrade` would do for an installed package. Uses
    /// `upgradeHasBottle` from the status report.
    public func upgradeMethod(_ p: Package) -> BuildMethod {
        guard p.kind == .formula, p.upgradeAvailable else { return .notApplicable }
        guard p.upgradeHasBottle == true else { return .compile }
        return .bottle(p.bottleURL.map { StatusClassifier.bottleOrigin(url: $0) })
    }

    /// What `brew install` would do for a Discover entry.
    public func installMethod(_ e: CatalogEntry) -> BuildMethod {
        switch e.bottle {
        case .cask: return .notApplicable
        case .unknown: return .unknown
        case .fromSource: return .compile
        case .intelbrew: return .bottle(.intelbrew)
        case .forThisMac: return .bottle(e.bottleURL.map { StatusClassifier.bottleOrigin(url: $0) })
        }
    }

    public func upgradeWarning(_ p: Package) -> CompileWarning? {
        guard upgradeMethod(p).compiles else { return nil }
        return CompileWarning(context: .upgrade, estimatedSeconds: estimator.estimatedSeconds(forFormula: p.name))
    }

    public func installWarning(_ e: CatalogEntry) -> CompileWarning? {
        guard installMethod(e).compiles else { return nil }
        return CompileWarning(context: .install, estimatedSeconds: estimator.estimatedSeconds(forFormula: e.name))
    }

    /// Splits an upgrade list into (pours a bottle or is a cask, compiles).
    public func partitionUpgrades(_ packages: [Package]) -> (bottled: [Package], compiling: [Package]) {
        var a: [Package] = [], b: [Package] = []
        for p in packages { if upgradeMethod(p).compiles { b.append(p) } else { a.append(p) } }
        return (a, b)
    }

    /// Dependencies of `entry` that installing it would also compile: not
    /// installed, no bottle. Walks the graph: a formula that compiles needs
    /// its build dependencies too; one that pours a bottle needs only its
    /// runtime dependencies. Dependencies `lookup` can't find are skipped
    /// (counted in `unknown`). Sorted by name.
    public func dependenciesThatCompile(_ entry: CatalogEntry,
                                        lookup: (String) -> CatalogEntry?,
                                        isInstalled: (CatalogEntry) -> Bool) -> (compiling: [CatalogEntry], unknown: [String]) {
        var seen: Set<String> = [entry.id]
        var compiling: [CatalogEntry] = []
        var unknown: [String] = []
        var queue = Self.needs(entry, compiles: installMethod(entry).compiles)
        while !queue.isEmpty {
            let name = queue.removeFirst()
            guard let dep = lookup(name) else {
                if !unknown.contains(name) { unknown.append(name) }
                continue
            }
            guard seen.insert(dep.id).inserted, !isInstalled(dep) else { continue }
            let compiles = installMethod(dep).compiles
            if compiles { compiling.append(dep) }
            queue += Self.needs(dep, compiles: compiles)
        }
        return (compiling.sorted { $0.name < $1.name }, unknown)
    }

    static func needs(_ e: CatalogEntry, compiles: Bool) -> [String] {
        compiles ? e.dependencies + e.buildDependencies : e.dependencies
    }
}

// MARK: replace a source build with a bottle

/// A formula built from source whose installed version has a bottle this
/// Mac can pour: `brew reinstall --force-bottle` swaps the build for it.
public enum BottleReplacement {
    /// Eligible: a formula, not poured from a bottle (the receipt says so,
    /// not merely unknown), not a HEAD install, installed version equal to
    /// the current one (otherwise it's an upgrade, not a reinstall), no
    /// upgrade pending, and the current version has a usable bottle here.
    public static func isEligible(_ p: Package) -> Bool {
        guard p.kind == .formula, p.pouredFromBottle == false, p.currentHasBottle == true else { return false }
        guard !p.upgradeAvailable, p.status == .source else { return false }
        guard !BrewVersion(p.installedVersion).isHead, let current = p.currentVersion else { return false }
        return p.installedVersion == current
    }

    /// Whose bottle it would pour (from the current version's bottle URL).
    public static func origin(_ p: Package) -> BottleOrigin? {
        p.bottleURL.map { StatusClassifier.bottleOrigin(url: $0) }
    }

    /// "Intelbrew bottle available" in Intelbrew mode when the bottle is on
    /// intelbrew-core, otherwise "Bottle available".
    public static func badge(_ p: Package, intelbrewMode: Bool) -> String {
        intelbrewMode && origin(p) == .intelbrew ? "Intelbrew bottle available" : "Bottle available"
    }

    /// `brew reinstall --force-bottle --formula homebrew/core/vim`.
    /// `--force-bottle` (checked in `brew reinstall --help`, brew 7.0.14)
    /// makes brew pour even when the keg was built with options; `--formula`
    /// and the tap-qualified name keep a same-named cask out of it.
    public static func arguments(qualifiedName: String) -> [String] {
        ["reinstall", "--force-bottle", "--formula", qualifiedName]
    }
}
