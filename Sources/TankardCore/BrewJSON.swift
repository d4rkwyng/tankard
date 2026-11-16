import Foundation

// Decodable mirrors of the parts of brew's JSON that Tankard reads.
// Shapes taken from real output (`brew info --json=v2 --installed`,
// `brew outdated --json=v2`, brew 7.0.14); see Tests/TankardCoreTests/Fixtures.
// Explicit CodingKeys rather than .convertFromSnakeCase: that strategy would
// also rewrite dictionary keys such as bottle tags ("arm64_sonoma").

public struct BrewInfoJSON: Decodable, Sendable {
    public var formulae: [Formula]
    public var casks: [Cask]

    public struct Formula: Decodable, Sendable {
        public var name: String
        public var fullName: String
        public var tap: String?
        public var desc: String?
        public var versions: Versions
        public var revision: Int
        public var versionScheme: Int?
        /// Keyed by spec, in practice only "stable".
        public var bottle: [String: BottleSpec]
        public var installed: [Installed]
        public var linkedKeg: String?
        public var pinned: Bool
        public var outdated: Bool
        public var kegOnly: Bool
        public var deprecated: Bool?
        public var disabled: Bool?
        /// Declared runtime dependencies (formula names, tap-qualified when not in core).
        public var dependencies: [String]?
        public var homepage: String?
        /// SPDX expression, flattened to text ("MIT", "Apache-2.0 or MIT").
        public var license: String?
        public var aliases: [String]?
        public var oldnames: [String]?

        enum CodingKeys: String, CodingKey {
            case name, tap, desc, versions, revision, bottle, installed, pinned, outdated, deprecated, disabled
            case dependencies, homepage, license, aliases, oldnames
            case fullName = "full_name"
            case versionScheme = "version_scheme"
            case linkedKeg = "linked_keg"
            case kegOnly = "keg_only"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? name
            tap = try c.decodeIfPresent(String.self, forKey: .tap)
            desc = try c.decodeIfPresent(String.self, forKey: .desc)
            versions = try c.decode(Versions.self, forKey: .versions)
            revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
            versionScheme = try c.decodeIfPresent(Int.self, forKey: .versionScheme)
            bottle = try c.decodeIfPresent([String: BottleSpec].self, forKey: .bottle) ?? [:]
            installed = try c.decodeIfPresent([Installed].self, forKey: .installed) ?? []
            linkedKeg = try c.decodeIfPresent(String.self, forKey: .linkedKeg)
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            outdated = try c.decodeIfPresent(Bool.self, forKey: .outdated) ?? false
            kegOnly = try c.decodeIfPresent(Bool.self, forKey: .kegOnly) ?? false
            deprecated = try c.decodeIfPresent(Bool.self, forKey: .deprecated)
            disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled)
            dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies)
            homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
            license = (try? c.decodeIfPresent(LicenseExpression.self, forKey: .license))?.topLevel
            aliases = try? c.decodeIfPresent([String].self, forKey: .aliases)
            oldnames = try? c.decodeIfPresent([String].self, forKey: .oldnames)
        }

        /// stable version plus `_revision`, as brew prints it ("1.5.7_1").
        public var currentPkgVersion: String? {
            guard let stable = versions.stable else { return nil }
            return revision > 0 ? "\(stable)_\(revision)" : stable
        }
    }

    public struct Versions: Decodable, Sendable {
        public var stable: String?
        public var head: String?
        /// True when the formula has a bottle block at all (any platform).
        public var bottle: Bool?
    }

    public struct BottleSpec: Decodable, Sendable {
        public var rebuild: Int?
        public var rootURL: String?
        /// Keyed by bottle tag: "sonoma", "arm64_sonoma", "all", "x86_64_linux", ...
        public var files: [String: BottleFile]

        enum CodingKeys: String, CodingKey {
            case rebuild, files
            case rootURL = "root_url"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rebuild = try c.decodeIfPresent(Int.self, forKey: .rebuild)
            rootURL = try c.decodeIfPresent(String.self, forKey: .rootURL)
            files = try c.decodeIfPresent([String: BottleFile].self, forKey: .files) ?? [:]
        }

        public init(rootURL: String?, files: [String: BottleFile]) {
            self.rebuild = 0
            self.rootURL = rootURL
            self.files = files
        }
    }

    public struct BottleFile: Decodable, Sendable {
        /// ":any", ":any_skip_relocation", or an absolute Cellar path.
        public var cellar: String?
        public var url: String?
        public var sha256: String?

        public init(cellar: String?, url: String?, sha256: String? = nil) {
            self.cellar = cellar
            self.url = url
            self.sha256 = sha256
        }
    }

    public struct Installed: Decodable, Sendable {
        public var version: String
        /// Absent or null in some receipts; treated as unknown.
        public var pouredFromBottle: Bool?
        public var builtAsBottle: Bool?
        public var installedOnRequest: Bool?
        /// Older brews only; current brew removed the field (always use installedOnRequest).
        public var installedAsDependency: Bool?
        public var time: Double?
        /// Every runtime dependency this keg was linked against (recursive), from its receipt.
        public var runtimeDependencies: [RuntimeDependency]?

        public struct RuntimeDependency: Decodable, Sendable {
            public var fullName: String
            enum CodingKeys: String, CodingKey { case fullName = "full_name" }
        }

        enum CodingKeys: String, CodingKey {
            case version, time
            case runtimeDependencies = "runtime_dependencies"
            case pouredFromBottle = "poured_from_bottle"
            case builtAsBottle = "built_as_bottle"
            case installedOnRequest = "installed_on_request"
            case installedAsDependency = "installed_as_dependency"
        }
    }

    public struct Cask: Decodable, Sendable {
        public var token: String
        public var fullToken: String
        public var name: [String]?
        public var desc: String?
        public var tap: String?
        public var version: String
        public var installed: String?
        public var installedTime: Double?
        public var outdated: Bool
        public var autoUpdates: Bool?
        public var pinned: Bool?
        public var deprecated: Bool?
        public var disabled: Bool?
        public var homepage: String?
        public var dependsOn: DependsOn?

        /// The parts of `depends_on` Tankard reads: other packages.
        public struct DependsOn: Decodable, Sendable {
            public var formula: [String]
            public var cask: [String]

            public init(formula: [String] = [], cask: [String] = []) {
                self.formula = formula
                self.cask = cask
            }

            enum CodingKeys: String, CodingKey { case formula, cask }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                func list(_ k: CodingKeys) -> [String] {
                    if let a = try? c.decodeIfPresent([String].self, forKey: k) { return a }
                    if let s = try? c.decodeIfPresent(String.self, forKey: k) { return [s] }
                    return []
                }
                formula = list(.formula)
                cask = list(.cask)
            }
        }

        enum CodingKeys: String, CodingKey {
            case token, name, desc, tap, version, installed, outdated, pinned, deprecated, disabled, homepage
            case dependsOn = "depends_on"
            case fullToken = "full_token"
            case installedTime = "installed_time"
            case autoUpdates = "auto_updates"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            token = try c.decode(String.self, forKey: .token)
            fullToken = try c.decodeIfPresent(String.self, forKey: .fullToken) ?? token
            name = try c.decodeIfPresent([String].self, forKey: .name)
            desc = try c.decodeIfPresent(String.self, forKey: .desc)
            tap = try c.decodeIfPresent(String.self, forKey: .tap)
            version = try c.decode(String.self, forKey: .version)
            installed = try c.decodeIfPresent(String.self, forKey: .installed)
            installedTime = try c.decodeIfPresent(Double.self, forKey: .installedTime)
            outdated = try c.decodeIfPresent(Bool.self, forKey: .outdated) ?? false
            autoUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoUpdates)
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned)
            deprecated = try c.decodeIfPresent(Bool.self, forKey: .deprecated)
            disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled)
            homepage = try? c.decodeIfPresent(String.self, forKey: .homepage)
            dependsOn = try? c.decodeIfPresent(DependsOn.self, forKey: .dependsOn)
        }
    }
}

/// brew's `license` field: an SPDX id, or nested `any_of` / `all_of`
/// objects, or `{"GPL-2.0-only": {"with": "exception"}}`.
struct LicenseExpression: Decodable {
    var text: String

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            text = s
            return
        }
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        let c = try decoder.container(keyedBy: Key.self)
        var parts: [String] = []
        for key in c.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            switch key.stringValue {
            case "any_of", "all_of":
                let items = (try? c.decode([LicenseExpression].self, forKey: key))?.map(\.text) ?? []
                let joined = items.joined(separator: key.stringValue == "any_of" ? " or " : " and ")
                parts.append(items.count > 1 ? "(\(joined))" : joined)
            default:
                struct With: Decodable { var with: String? }
                let with = (try? c.decode(With.self, forKey: key))?.with
                parts.append(with.map { "\(key.stringValue) with \($0)" } ?? key.stringValue)
            }
        }
        text = parts.joined(separator: " and ")
    }

    /// The text without the outer brackets of a top-level `any_of`/`all_of`.
    var topLevel: String {
        guard text.hasPrefix("("), text.hasSuffix(")") else { return text }
        var depth = 0
        for (i, ch) in text.enumerated() {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if depth == 0 && i < text.count - 1 { return text } // "(a) and (b)"
        }
        return String(text.dropFirst().dropLast())
    }
}

public struct BrewOutdatedJSON: Decodable, Sendable {
    public var formulae: [Entry]
    public var casks: [Entry]

    public struct Entry: Decodable, Sendable {
        public var name: String
        public var installedVersions: [String]
        public var currentVersion: String
        public var pinned: Bool?
        public var pinnedVersion: String?

        enum CodingKeys: String, CodingKey {
            case name, pinned
            case installedVersions = "installed_versions"
            case currentVersion = "current_version"
            case pinnedVersion = "pinned_version"
        }
    }

    public init(formulae: [Entry] = [], casks: [Entry] = []) {
        self.formulae = formulae
        self.casks = casks
    }

    public init(from decoder: Decoder) throws {
        enum K: String, CodingKey { case formulae, casks }
        let c = try decoder.container(keyedBy: K.self)
        formulae = try c.decodeIfPresent([Entry].self, forKey: .formulae) ?? []
        casks = try c.decodeIfPresent([Entry].self, forKey: .casks) ?? []
    }
}
