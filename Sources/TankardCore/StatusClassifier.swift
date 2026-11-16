import Foundation

/// Turns brew's JSON into `Package` values. Pure: no I/O, so the fixtures
/// test it directly.
public struct StatusClassifier: Sendable {
    public var platform: BottlePlatform
    /// Intelbrew mode: bottle labels say whose bottle it is.
    public var intelbrewMode: Bool

    public init(platform: BottlePlatform, intelbrewMode: Bool) {
        self.platform = platform
        self.intelbrewMode = intelbrewMode
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
            upgradeAvailable: outdated,
            upgradeHasBottle: outdated ? currentHasBottle : nil,
            autoUpdates: nil
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
            upgradeAvailable: outdated,
            upgradeHasBottle: nil,
            autoUpdates: c.autoUpdates
        )
    }

    func label(status: PackageStatus, origin: BottleOrigin?) -> String {
        switch status {
        case .bottle:
            guard intelbrewMode else { return "bottle" }
            switch origin {
            case .intelbrew: return "Intelbrew bottle"
            case .homebrew: return "Homebrew bottle"
            default: return "bottle"
            }
        case .source: return "source"
        case .newer: return "newer"
        case .noBottle: return "no bottle"
        case .cask: return "cask"
        }
    }
}
