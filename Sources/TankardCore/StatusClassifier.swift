import Foundation

/// Turns brew's JSON into `Package` values. Pure: no I/O, so the fixtures
/// test it directly.
public struct StatusClassifier: Sendable {
    public var platform: BottlePlatform
    /// Intelbrew mode: bottle labels say whose bottle it is.
    public var intelbrewMode: Bool
    /// 0.8.4: the zone brew read a cask's install time in (see `CaskInstallTime`).
    public var timeZone: TimeZone
    /// 0.8.4: a cask's install folder's modification time (token,
    /// version), which tells whether brew's `installed_time` needs the
    /// correction (`CaskInstallTime`). nil (demo mode, tests): nothing is
    /// read from disk.
    public var folderTime: (@Sendable (_ token: String, _ version: String) -> Date?)?

    public init(platform: BottlePlatform, intelbrewMode: Bool, timeZone: TimeZone = .current,
                folderTime: (@Sendable (_ token: String, _ version: String) -> Date?)? = nil) {
        self.platform = platform
        self.intelbrewMode = intelbrewMode
        self.timeZone = timeZone
        self.folderTime = folderTime
    }

    /// The folder times read from `<caskroom>` (`CaskInstallTime.folderTime`).
    public init(platform: BottlePlatform, intelbrewMode: Bool, timeZone: TimeZone = .current, caskroom: String) {
        self.init(platform: platform, intelbrewMode: intelbrewMode, timeZone: timeZone,
                  folderTime: { CaskInstallTime.folderTime(caskroom: caskroom, token: $0, version: $1) })
    }

    public static func bottleOrigin(url: String?) -> BottleOrigin {
        guard let url = url?.lowercased() else { return .other }
        if url.contains("github.com/d4rkwyng/intelbrew-core/") { return .intelbrew }
        if url.contains("ghcr.io/v2/homebrew/core") { return .homebrew }
        return .other
    }

    /// Classifies every installed formula and cask. Upgrade-available is
    /// brew's own `outdated` flag; version comparison is used only to spot
    /// "newer than the tap".
    public func classify(info: BrewInfoJSON) -> [Package] {
        let formulae = info.formulae
            .filter { !$0.installed.isEmpty }
            .map { classify(formula: $0, outdated: $0.outdated) }
        let casks = info.casks
            .filter { $0.installed != nil }
            .map { classify(cask: $0, outdated: $0.outdated) }
        return (formulae + casks).sorted { ($0.kind == $1.kind) ? $0.name < $1.name : $0.kind == .formula }
    }

    /// Tap-qualified name ("homebrew/core/xz", "homebrew/cask/iterm2"), so a
    /// formula and a cask with the same short name, or the same name in two
    /// taps, never collide.
    static func qualified(tap: String?, name: String) -> String {
        guard let tap, !tap.isEmpty, !name.contains("/") else { return name }
        return "\(tap)/\(name)"
    }

    public func classify(formula f: BrewInfoJSON.Formula, outdated: Bool) -> Package {
        // Newest installed keg, by brew's own ordering.
        let kegs = f.installed
        let latest = kegs.max { PkgVersion(parsing: $0.version) < PkgVersion(parsing: $1.version) } ?? kegs[0]
        let installed = latest.version
        let current = f.currentPkgVersion

        let match = platform.bottle(in: f.bottle["stable"])
        let currentHasBottle = match?.usable ?? false

        let isHead = BrewVersion(installed).isHead
        var newer = false
        if !isHead, !outdated, let current,
           PkgVersion(parsing: installed).compare(to: PkgVersion(parsing: current)) == 1 {
            newer = true
        }

        let poured = latest.pouredFromBottle
        let status: PackageStatus
        if newer {
            status = .newer
        } else if isHead || poured == false {
            // A source build stays "source" when its bottle is missing too,
            // unless the current version has no bottle at all: then any
            // reinstall or upgrade compiles, which is the more useful fact.
            status = currentHasBottle || isHead ? .source : .noBottle
        } else if !currentHasBottle {
            status = .noBottle
        } else {
            status = .bottle
        }

        var origin: BottleOrigin?
        if let current, installed == current, let match, match.usable {
            origin = Self.bottleOrigin(url: match.url)
        }

        return Package(
            id: "formula:" + Self.qualified(tap: f.tap, name: f.fullName),
            kind: .formula,
            name: f.name,
            fullName: f.fullName,
            tap: f.tap,
            desc: f.desc,
            status: status,
            statusLabel: label(status: status, origin: origin),
            installedVersion: installed,
            installedVersions: kegs.map(\.version),
            currentVersion: current,
            requested: latest.installedOnRequest ?? !(latest.installedAsDependency ?? false),
            pinned: f.pinned,
            kegOnly: f.kegOnly,
            deprecated: f.deprecated ?? false,
            disabled: f.disabled ?? false,
            pouredFromBottle: poured,
            currentHasBottle: currentHasBottle,
            bottleTag: match?.usable == true ? match?.tag : nil,
            bottleOrigin: origin,
            bottleURL: match?.usable == true ? match?.url : nil,
            installedAt: latest.time.map { Date(timeIntervalSince1970: $0) },
            upgradeAvailable: outdated,
            upgradeHasBottle: outdated ? currentHasBottle : nil,
            autoUpdates: nil,
            dependencies: latest.runtimeDependencies.map { $0.map(\.fullName) } ?? f.dependencies ?? [],
            homepage: f.homepage,
            directDependencies: Self.directDependencies(latest.runtimeDependencies, declared: f.dependencies),
            caveats: f.caveats,
            lifecycle: f.lifecycle,
            kegOnlyReason: f.kegOnlyReason,
            linked: f.linkedKeg != nil
        )
    }

    public func classify(cask c: BrewInfoJSON.Cask, outdated: Bool) -> Package {
        let installed = c.installed ?? ""
        var newer = false
        if !outdated, installed != "latest", c.version != "latest",
           BrewVersion(installed).compare(to: BrewVersion(c.version)) == 1 {
            newer = true
        }
        let status: PackageStatus = newer ? .newer : .cask
        return Package(
            id: "cask:" + Self.qualified(tap: c.tap, name: c.fullToken),
            kind: .cask,
            name: c.token,
            fullName: c.fullToken,
            tap: c.tap,
            desc: c.desc,
            status: status,
            statusLabel: label(status: status, origin: nil),
            installedVersion: installed,
            installedVersions: [installed],
            currentVersion: c.version,
            requested: true,
            pinned: c.pinned ?? false,
            kegOnly: nil,
            deprecated: c.deprecated ?? false,
            disabled: c.disabled ?? false,
            pouredFromBottle: nil,
            currentHasBottle: nil,
            bottleTag: nil,
            bottleOrigin: nil,
            bottleURL: nil,
            installedAt: c.installedTime.map { t in
                CaskInstallTime.date(brewInstalledTime: t,
                                     folderTime: folderTime?(c.token, installed),
                                     timeZone: timeZone)
            },
            upgradeAvailable: outdated,
            upgradeHasBottle: nil,
            autoUpdates: c.autoUpdates,
            dependencies: c.dependsOn?.formula ?? [],
            caskDependencies: c.dependsOn?.cask ?? [],
            homepage: c.homepage,
            caveats: c.caveats,
            appPaths: c.appPaths,
            quitBundleIDs: c.quitBundleIDs,
            lifecycle: c.lifecycle,
            suitePaths: c.adoptArtifacts?.suites,
            installsPkg: c.installsPkg,
            sudoInstaller: c.sudoInstaller,
            sudoUninstall: c.sudoUninstall,
            caskArtifacts: c.artifactKinds,
            caskOwnership: c.ownership
        )
    }

    /// The receipt's `declared_directly` entries, in its order (what
    /// `brew deps --tree` shows), or the formula's declared dependencies when
    /// the receipt doesn't say.
    static func directDependencies(_ runtime: [BrewInfoJSON.Installed.RuntimeDependency]?, declared: [String]?) -> [String]? {
        if let runtime, runtime.contains(where: { $0.declaredDirectly != nil }) {
            return runtime.filter { $0.declaredDirectly == true }.map(\.fullName)
        }
        return declared
    }

    func label(status: PackageStatus, origin: BottleOrigin?) -> String {
        switch status {
        case .bottle:
            guard intelbrewMode else { return String(localized: "bottle") }
            switch origin {
            case .intelbrew: return String(localized: "Intelbrew bottle")
            case .homebrew: return String(localized: "Homebrew bottle")
            default: return String(localized: "bottle")
            }
        case .source: return String(localized: "source")
        case .newer: return String(localized: "newer")
        case .noBottle: return String(localized: "no bottle")
        case .cask: return String(localized: "cask")
        }
    }
}

/// 0.8.4: a cask's real install time from brew's `installed_time`.
///
/// brew names the cask's metadata folder after the install time in UTC
/// (cask/metadata.rb: `Time.now.utc.strftime("%Y%m%d%H%M%S.%L")`), then
/// reads it back with `Time.strptime(name, "%Y%m%d%H%M%S.%L")` and no zone
/// (cask/cask.rb `install_time`), which Ruby takes as local time. So
/// `installed_time` is off by the UTC offset: 7 hours late in Arizona (an
/// evening install shows the next day), early east of Greenwich. Formulae
/// (the receipt's `time`) are right. Adding the offset in force at that
/// instant undoes it exactly, daylight saving included.
///
/// Self-checking, so a brew that fixes this isn't shifted twice: the
/// folder's own modification time (`.metadata/<version>/<timestamp>`, set
/// when brew made it; on this Mac it matched the name to the second on
/// every cask, while the cask file inside was sometimes rewritten later)
/// is the real install time. The correction applies when brew's value is
/// off from it by the zone's offset (±1 min); brew's value is kept when it
/// matches the folder, or when neither does (a folder copied or touched
/// later). No folder time (not found, demo, tests): the correction applies,
/// since every brew so far has the bug and the uncorrected value is wrong
/// by hours for everyone off UTC.
public enum CaskInstallTime {
    static let tolerance: TimeInterval = 60

    public static func date(brewInstalledTime t: Double, folderTime: Date? = nil, timeZone: TimeZone = .current) -> Date {
        let read = Date(timeIntervalSince1970: t)
        let offset = TimeInterval(timeZone.secondsFromGMT(for: read))
        let corrected = read.addingTimeInterval(offset)
        guard offset != 0 else { return read }
        guard let folder = folderTime else { return corrected }
        let toCorrected = abs(folder.timeIntervalSince(corrected))
        let toRead = abs(folder.timeIntervalSince(read))
        return toCorrected <= tolerance && toCorrected < toRead ? corrected : read
    }

    /// The modification time of the newest `<caskroom>/<token>/.metadata/<version>/<timestamp>`
    /// folder (the one brew's `installed_time` comes from); nil when there is none.
    public static func folderTime(caskroom: String, token: String, version: String) -> Date? {
        let dir = "\(caskroom)/\(token)/.metadata/\(version)"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let stamps = names.filter { $0.wholeMatch(of: /[0-9]{14}\.[0-9]{3}/) != nil }
        guard let newest = stamps.max() else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir + "/" + newest)
        return attrs?[.modificationDate] as? Date
    }

    /// What brew reports for a cask installed at `date` (demo data, tests).
    public static func brewInstalledTime(for date: Date, timeZone: TimeZone = .current) -> Double {
        let guess = date.addingTimeInterval(-TimeInterval(timeZone.secondsFromGMT(for: date)))
        return date.timeIntervalSince1970 - TimeInterval(timeZone.secondsFromGMT(for: guess))
    }
}
