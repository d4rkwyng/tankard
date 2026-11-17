import Foundation

// v0.4: `brew vulns --json` (new in brew 7). brew asks OSV.dev about the
// source repository and version tag of each installed formula; Tankard only
// reads what brew prints. Shapes from real output (brew 7.0.14, an arm64
// Mac and the Intel macOS 14 VM); see Tests/TankardCoreTests/Fixtures.

/// Decodable mirror of `brew vulns --json`. Decode **stdout only**: brew
/// prints its warnings (untrusted taps, outdated kegs without an SBOM) on
/// stderr, and mixing the two breaks the JSON.
public struct BrewVulnsJSON: Decodable, Sendable {
    public var findings: [Finding]
    /// Formulae brew couldn't map to a source repository and tag (not checked).
    public var skippedFormulae: [String]
    /// How many formulae were sent to OSV.dev.
    public var checked: Int
    /// brew's own flag: false when anything was skipped or not scanned.
    /// Even true doesn't promise there is nothing (brew's help says so).
    public var complete: Bool
    /// Kegs older than their formula with no SBOM: brew checked the current
    /// formula's source instead of what is installed.
    public var outdatedWithoutSBOM: [String]
    /// Name → reason ("untrusted_tap", "resolution_error").
    public var unscannedFormulae: [String: String]

    public struct Finding: Decodable, Sendable {
        /// The formula's full name (tap-qualified outside homebrew/core).
        public var formula: String
        /// The installed version brew checked (no `_N` revision).
        public var version: String?
        public var tag: String?
        public var repoURL: String?
        /// Open vulnerabilities.
        public var vulnerabilities: [Vuln]
        /// Ones a formula patch resolves (not counted, as in brew's text output).
        public var patched: [Vuln]

        enum CodingKeys: String, CodingKey {
            case formula, version, tag, vulnerabilities, patched
            case repoURL = "repo_url"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formula = try c.decode(String.self, forKey: .formula)
            version = try c.decodeIfPresent(String.self, forKey: .version)
            tag = try c.decodeIfPresent(String.self, forKey: .tag)
            repoURL = try c.decodeIfPresent(String.self, forKey: .repoURL)
            vulnerabilities = try c.decodeIfPresent([Vuln].self, forKey: .vulnerabilities) ?? []
            patched = try c.decodeIfPresent([Vuln].self, forKey: .patched) ?? []
        }
    }

    public struct Vuln: Decodable, Sendable {
        public var id: String
        /// "CRITICAL", "HIGH", "MEDIUM", "LOW" or "UNKNOWN".
        public var severity: String?
        public var summary: String?
        public var aliases: [String]
        /// OSV `fixed` events: release versions or git commit hashes.
        public var fixedVersions: [String]

        enum CodingKeys: String, CodingKey {
            case id, severity, summary, aliases
            case fixedVersions = "fixed_versions"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            severity = try c.decodeIfPresent(String.self, forKey: .severity)
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            aliases = (try? c.decodeIfPresent([String].self, forKey: .aliases)) ?? []
            fixedVersions = (try? c.decodeIfPresent([String].self, forKey: .fixedVersions)) ?? []
        }
    }

    enum CodingKeys: String, CodingKey {
        case findings, checked, complete
        case skippedFormulae = "skipped_formulae"
        case outdatedWithoutSBOM = "outdated_without_sbom"
        case unscannedFormulae = "unscanned_formulae"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        findings = try c.decode([Finding].self, forKey: .findings)
        skippedFormulae = (try? c.decodeIfPresent([String].self, forKey: .skippedFormulae)) ?? []
        checked = (try? c.decodeIfPresent(Int.self, forKey: .checked)) ?? 0
        complete = (try? c.decodeIfPresent(Bool.self, forKey: .complete)) ?? false
        outdatedWithoutSBOM = (try? c.decodeIfPresent([String].self, forKey: .outdatedWithoutSBOM)) ?? []
        unscannedFormulae = (try? c.decodeIfPresent([String: String].self, forKey: .unscannedFormulae)) ?? [:]
    }

    public static func decode(stdout: Data) throws -> BrewVulnsJSON {
        try JSONDecoder().decode(BrewVulnsJSON.self, from: stdout)
    }
}

/// OSV's severity words, in order.
public enum VulnerabilitySeverity: String, Codable, Sendable, CaseIterable, Comparable {
    case unknown, low, medium, high, critical

    /// From brew's "HIGH", "Moderate", nil, ...
    public init(brew value: String?) {
        switch value?.lowercased() {
        case "critical": self = .critical
        case "high": self = .high
        case "medium", "moderate": self = .medium
        case "low": self = .low
        default: self = .unknown
        }
    }

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    /// "Critical", "High", "Medium", "Low", "Unknown severity".
    public var label: String {
        switch self {
        case .unknown: return "Unknown severity"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// One open vulnerability of an installed formula.
public struct PackageVulnerability: Codable, Sendable, Equatable, Identifiable {
    /// "CVE-2026-88822", "OSV-2025-219", "GHSA-…".
    public var id: String
    public var severity: VulnerabilitySeverity
    public var summary: String?
    public var aliases: [String]
    /// brew's `fixed_versions`: release versions or commit hashes.
    public var fixedIn: [String]

    public init(id: String, severity: VulnerabilitySeverity, summary: String? = nil, aliases: [String] = [], fixedIn: [String] = []) {
        self.id = id
        self.severity = severity
        self.summary = summary
        self.aliases = aliases
        self.fixedIn = fixedIn
    }

    init(_ v: BrewVulnsJSON.Vuln) {
        self.init(id: v.id, severity: VulnerabilitySeverity(brew: v.severity),
                  summary: v.summary.flatMap { $0.isEmpty ? nil : $0 }, aliases: v.aliases, fixedIn: v.fixedVersions)
    }

    /// The advisory on osv.dev (where brew's data comes from). Opened only
    /// when the user clicks it.
    public var url: URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard let id = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://osv.dev/vulnerability/\(id)")
    }

    /// A git commit hash (40 or 64 hex digits), as OSV's GIT ranges give.
    public static func isCommit(_ s: String) -> Bool {
        (s.count == 40 || s.count == 64) && s.allSatisfy { $0.isHexDigit }
    }

    /// Release versions it is fixed in (commit hashes left out).
    public var fixedVersions: [String] { fixedIn.filter { !Self.isCommit($0) } }
    public var fixedCommits: [String] { fixedIn.filter(Self.isCommit) }

    /// "Fixed in 2.10.1", "Fixed upstream in commit 7b4f534", or "No fix listed".
    /// A commit only says upstream has a fix; brew's formula may not
    /// have a release with it yet.
    public var fixText: String {
        if !fixedVersions.isEmpty { return "Fixed in " + fixedVersions.joined(separator: ", ") }
        if let c = fixedCommits.first {
            let more = fixedCommits.count > 1 ? " (+\(fixedCommits.count - 1) more)" : ""
            return "Fixed upstream in commit \(c.prefix(7))\(more)"
        }
        return "No fix listed"
    }
}

/// What the app keeps from one `brew vulns --json` run.
public struct VulnerabilityScan: Codable, Sendable, Equatable {
    public var scannedAt: Date
    public var complete: Bool
    public var checked: Int
    public var skipped: [String]
    /// Name → reason, as brew gives it.
    public var unscanned: [String: String]
    public var outdatedWithoutSBOM: [String]
    /// Formula full name → open vulnerabilities (only formulae with any).
    public var findings: [String: [PackageVulnerability]]
    /// Formula full name → the version brew checked.
    public var versions: [String: String]
    /// Vulnerabilities brew counted as resolved by formula patches.
    public var patchedCount: Int
    /// brew's warnings from stderr ("Warning: 1 installed keg from an untrusted tap not scanned…"), first lines only.
    public var warnings: [String]

    public init(json: BrewVulnsJSON, scannedAt: Date, stderr: String = "") {
        self.scannedAt = scannedAt
        complete = json.complete
        checked = json.checked
        skipped = json.skippedFormulae
        unscanned = json.unscannedFormulae
        outdatedWithoutSBOM = json.outdatedWithoutSBOM
        var findings: [String: [PackageVulnerability]] = [:]
        var versions: [String: String] = [:]
        for f in json.findings where !f.vulnerabilities.isEmpty {
            // Most severe first, then by id.
            findings[f.formula, default: []] += f.vulnerabilities.map(PackageVulnerability.init)
                .sorted { ($0.severity, $1.id) > ($1.severity, $0.id) }
            if let v = f.version { versions[f.formula] = v }
        }
        self.findings = findings
        self.versions = versions
        patchedCount = json.findings.reduce(0) { $0 + $1.patched.count }
        warnings = stderr.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("Warning:") || $0.hasPrefix("Error:") }
    }

    /// Formulae with at least one open vulnerability.
    public var vulnerableCount: Int { findings.count }
    public var vulnerabilityCount: Int { findings.values.reduce(0) { $0 + $1.count } }

    /// Open vulnerabilities for an installed package: formulae only (brew
    /// doesn't scan casks), and only while the installed version is the
    /// one brew checked (an upgrade since then waits for the next scan).
    public func vulnerabilities(for p: Package) -> [PackageVulnerability]? {
        guard p.kind == .formula, let list = findings[p.fullName], !list.isEmpty else { return nil }
        if let checked = versions[p.fullName], Self.stripRevision(checked) != Self.stripRevision(p.installedVersion) {
            return nil
        }
        return list
    }

    static func stripRevision(_ v: String) -> String {
        guard let r = v.range(of: #"_\d+$"#, options: .regularExpression) else { return v }
        return String(v[..<r.lowerBound])
    }

    /// Why brew calls the scan incomplete, in words; nil when complete.
    /// "61 not checked: 59 with no source repository brew can match, 1 from an untrusted tap, …"
    public var partialReason: String? {
        guard !complete else { return nil }
        var parts: [String] = []
        if !skipped.isEmpty { parts.append("\(skipped.count) with no source repository brew can match") }
        let untrusted = unscanned.values.filter { $0 == "untrusted_tap" }.count
        if untrusted > 0 { parts.append("\(untrusted) from an untrusted tap") }
        let other = unscanned.count - untrusted
        if other > 0 { parts.append("\(other) brew couldn't load") }
        if !outdatedWithoutSBOM.isEmpty {
            parts.append("\(outdatedWithoutSBOM.count) checked against the current formula, not the installed keg")
        }
        let notChecked = skipped.count + unscanned.count
        let head = notChecked > 0 ? "\(notChecked) not checked" : "brew marks it incomplete"
        return parts.isEmpty ? head : "\(head): " + parts.joined(separator: ", ")
    }
}
