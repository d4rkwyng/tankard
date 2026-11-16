import Foundation

public enum CPUArch: String, Codable, Sendable {
    case arm64
    case x86_64
}

/// The bottle platform a brew installation pours for: CPU architecture,
/// macOS version and Cellar. Mirrors brew's bottle tag matching
/// (Utils::Bottles::Collector#find_matching_tag plus the macOS
/// find_older_compatible_tag extension) and Bottle#compatible_locations?.
public struct BottlePlatform: Codable, Sendable, Equatable {
    public var arch: CPUArch
    /// "14", "15", "26", "10.15".
    public var macOSVersion: String
    /// HOMEBREW_CELLAR, e.g. "/usr/local/Cellar".
    public var cellar: String

    public init(arch: CPUArch, macOSVersion: String, cellar: String) {
        self.arch = arch
        self.macOSVersion = macOSVersion
        self.cellar = cellar
    }

    /// Brew's MacOSVersion::RELEASES (brew 7.0.14).
    public static let releases: [String: String] = [
        "golden_gate": "27",
        "tahoe": "26",
        "sequoia": "15",
        "sonoma": "14",
        "ventura": "13",
        "monterey": "12",
        "big_sur": "11",
        "catalina": "10.15",
        "mojave": "10.14",
        "high_sierra": "10.13",
        "sierra": "10.12",
        "el_capitan": "10.11",
    ]

    public var codename: String? {
        Self.releases.first { $0.value == macOSVersion }?.key
    }

    /// The bottle tag brew asks for first: "sonoma" on Intel, "arm64_sonoma" on Apple silicon.
    public var bottleTag: String? {
        guard let codename else { return nil }
        return arch == .arm64 ? "arm64_\(codename)" : codename
    }

    /// Parses a bottle tag into (arch, macOS version). nil for "all", Linux
    /// tags, and unknown codenames.
    static func parse(tag: String) -> (CPUArch, String)? {
        var arch = CPUArch.x86_64
        var system = tag
        if tag.hasPrefix("arm64_") {
            arch = .arm64
            system = String(tag.dropFirst("arm64_".count))
        } else if tag.hasPrefix("x86_64_") {
            system = String(tag.dropFirst("x86_64_".count))
        }
        guard let version = releases[system] else { return nil }
        return (arch, version)
    }

    static func compareOSVersions(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// The tag brew would pick for this platform, or nil if there is none:
    /// exact tag, then "all", then the newest older macOS of the same arch.
    public func matchingTag(in tags: some Collection<String>) -> String? {
        if let exact = bottleTag, tags.contains(exact) { return exact }
        if tags.contains("all") { return "all" }
        var best: (tag: String, version: String)?
        for tag in tags {
            guard let (tagArch, version) = Self.parse(tag: tag), tagArch == arch,
                  Self.compareOSVersions(version, macOSVersion) <= 0 else { continue }
            if best == nil || Self.compareOSVersions(version, best!.version) > 0 {
                best = (tag, version)
            }
        }
        return best?.tag
    }

    /// Bottle#compatible_locations?: relocatable bottles pour anywhere;
    /// others only into the Cellar they were built for.
    public func cellarIsCompatible(_ cellar: String?) -> Bool {
        guard let cellar else { return true }
        if cellar == ":any" || cellar == ":any_skip_relocation" { return true }
        return cellar == self.cellar
    }

    public struct BottleMatch: Sendable, Equatable {
        public var tag: String
        public var url: String?
        public var usable: Bool
    }

    /// Whether `spec` has a bottle brew would pour on this platform.
    public func bottle(in spec: BrewInfoJSON.BottleSpec?) -> BottleMatch? {
        guard let spec, let tag = matchingTag(in: spec.files.keys) else { return nil }
        let file = spec.files[tag]
        return BottleMatch(
            tag: tag,
            url: file?.url ?? spec.rootURL,
            usable: cellarIsCompatible(file?.cellar)
        )
    }

    /// The platform of the running Mac for a brew at `prefix`. The arch comes
    /// from the prefix (brew's rule: /opt/homebrew is arm64, /usr/local is
    /// Intel, including Intel brew under Rosetta).
    public static func current(prefix: String) -> BottlePlatform {
        let arch: CPUArch = prefix.hasPrefix("/opt/homebrew") ? .arm64 : .x86_64
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = v.majorVersion >= 11 ? "\(v.majorVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        return BottlePlatform(arch: arch, macOSVersion: version, cellar: prefix + "/Cellar")
    }
}
