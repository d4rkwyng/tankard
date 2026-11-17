import Foundation

// v0.7: taps. `brew tap-info --installed --json` (read-only), and the argv
// for `brew tap`, `brew untap`, `brew trust --tap` and `brew untrust --tap`.
// Flags as printed by `brew <cmd> --help` on brew 7.0.14 (arm64 Mac,
// 2026-11-17): tap-info's `--json` takes only v1 and is the default;
// `brew trust` / `brew untrust` take `--tap` for a tap.

/// One element of `brew tap-info --installed --json`. Only the keys Tankard
/// reads. In API mode the official taps are listed with `installed: false`
/// and no `remote`, `last_commit` or `branch`.
public struct TapInfoJSON: Decodable, Equatable, Sendable {
    public var name: String
    public var user: String?
    public var repo: String?
    public var path: String?
    public var installed: Bool?
    public var official: Bool?
    public var trusted: Bool?
    public var formulaNames: [String]?
    public var caskTokens: [String]?
    public var remote: String?
    public var customRemote: Bool?
    public var isPrivate: Bool?
    public var lastCommit: String?
    public var branch: String?

    enum CodingKeys: String, CodingKey {
        case name, user, repo, path, installed, official, trusted, remote, branch
        case formulaNames = "formula_names"
        case caskTokens = "cask_tokens"
        case customRemote = "custom_remote"
        case isPrivate = "private"
        case lastCommit = "last_commit"
    }
}

/// A tap as the Taps sheet shows it.
public struct TapInfo: Equatable, Sendable, Identifiable {
    public var name: String
    /// The git remote; nil for an official tap in API mode.
    public var remote: String?
    public var official: Bool
    /// brew 7's trust (`brew trust --tap`). nil: brew didn't say.
    public var trusted: Bool?
    /// A local git checkout exists (`installed` in brew's JSON). Official
    /// taps in API mode are listed but not tapped.
    public var tapped: Bool
    public var formulaCount: Int
    public var caskCount: Int
    /// "35 hours ago", as brew prints it.
    public var lastCommit: String?
    public var customRemote: Bool
    public var isPrivate: Bool
    public var formulaNames: [String]
    public var caskTokens: [String]

    public var id: String { name.lowercased() }

    public init(name: String, remote: String? = nil, official: Bool = false, trusted: Bool? = nil, tapped: Bool = true,
                formulaNames: [String] = [], caskTokens: [String] = [], lastCommit: String? = nil,
                customRemote: Bool = false, isPrivate: Bool = false) {
        self.name = name
        self.remote = remote
        self.official = official
        self.trusted = trusted
        self.tapped = tapped
        self.formulaNames = formulaNames
        self.caskTokens = caskTokens
        self.formulaCount = formulaNames.count
        self.caskCount = caskTokens.count
        self.lastCommit = lastCommit
        self.customRemote = customRemote
        self.isPrivate = isPrivate
    }

    public init(_ j: TapInfoJSON) {
        self.init(name: j.name, remote: j.remote, official: j.official ?? false, trusted: j.trusted,
                  tapped: j.installed ?? true, formulaNames: j.formulaNames ?? [], caskTokens: j.caskTokens ?? [],
                  lastCommit: j.lastCommit, customRemote: j.customRemote ?? false, isPrivate: j.isPrivate ?? false)
    }

    /// Decodes `brew tap-info --installed --json`, sorted: official first,
    /// then by name.
    public static func decode(_ data: Data) throws -> [TapInfo] {
        try JSONDecoder().decode([TapInfoJSON].self, from: data).map(TapInfo.init)
            .sorted { ($0.official ? 0 : 1, $0.name.lowercased()) < ($1.official ? 0 : 1, $1.name.lowercased()) }
    }

    /// Whether this package was installed from this tap (case-insensitive,
    /// as brew treats tap names).
    public func owns(_ p: Package) -> Bool {
        p.tap?.lowercased() == name.lowercased()
    }

    /// "Official", "Third-party".
    public var originLabel: String { official ? String(localized: "Official") : String(localized: "Third-party") }
}

/// The argv Tankard runs (after `brew`). Never `--force`: `brew untap
/// --force` uninstalls everything from the tap first.
public enum TapCommands {
    public static let infoArguments = ["tap-info", "--installed", "--json"]

    /// `brew tap user/repo [URL]`.
    public static func tap(_ name: String, url: String? = nil) -> [String] {
        ["tap", name] + (url.map { [$0] } ?? [])
    }

    public static func untap(_ name: String) -> [String] { ["untap", name] }

    /// `brew trust --tap user/repo` / `brew untrust --tap user/repo`.
    public static func trust(_ name: String, _ trusted: Bool) -> [String] {
        [trusted ? "trust" : "untrust", "--tap", name]
    }
}

/// Checks what the user typed in Add Tap before anything runs.
public enum TapInput {
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case emptyName
        case badName
        case badURL

        public var description: String {
            switch self {
            case .emptyName: return String(localized: "Type a tap name: user/repo.")
            case .badName: return String(localized: "A tap name is user/repo: letters, digits, '.', '_' or '-', one slash, no spaces.")
            case .badURL: return String(localized: "The URL must be https://, http://, ssh://, git:// or file://, or git@host:path, with no spaces.")
            }
        }
    }

    /// `user/repo`; neither part may start with '-', so it can never read
    /// as a flag.
    static let nameRegex = #"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$"#
    /// A git URL brew's two-argument form accepts.
    static let urlRegex = #"^((https?|ssh|git|file)://[^\s]+|[A-Za-z0-9_.-]+@[A-Za-z0-9.-]+:[^\s]+)$"#

    /// The cleaned name and URL, or what's wrong. The URL is optional.
    public static func validate(name: String, url: String = "") -> Result<(name: String, url: String?), Problem> {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return .failure(.emptyName) }
        guard n.range(of: nameRegex, options: .regularExpression) != nil, !n.contains("..") else { return .failure(.badName) }
        if u.isEmpty { return .success((n, nil)) }
        guard u.range(of: urlRegex, options: .regularExpression) != nil else { return .failure(.badURL) }
        return .success((n, u))
    }

    public static func problem(name: String, url: String = "") -> Problem? {
        if case .failure(let p) = validate(name: name, url: url) { return p }
        return nil
    }

    /// The URL brew clones with one argument: https://github.com/user/homebrew-repo.
    public static func defaultRemote(_ name: String) -> String? {
        let parts = name.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let repo = parts[1].hasPrefix("homebrew-") ? String(parts[1]) : "homebrew-" + parts[1]
        return "https://github.com/\(parts[0])/\(repo)"
    }
}

/// Why a tap can't be removed now. brew refuses to untap while anything
/// from the tap is installed; Tankard says so before running anything.
public enum TapRemoval: Equatable, Sendable {
    case allowed
    /// Official taps in API mode aren't tapped: nothing to remove.
    case notTapped
    case inUse([String])

    public static func check(_ tap: TapInfo, packages: [Package]) -> TapRemoval {
        guard tap.tapped else { return .notTapped }
        let users = packages.filter { tap.owns($0) }.map(\.name).sorted()
        return users.isEmpty ? .allowed : .inUse(users)
    }

    public var isAllowed: Bool { self == .allowed }

    /// The explanation shown instead of Remove.
    public var reason: String? {
        switch self {
        case .allowed: return nil
        case .notTapped: return String(localized: "Not tapped: Homebrew reads this tap from its API, so there is nothing to remove.")
        case .inUse(let names):
            let list = names.prefix(5).joined(separator: ", ") + (names.count > 5 ? " +\(names.count - 5)" : "")
            return names.count == 1
                ? String(localized: "1 installed package comes from this tap (\(list)). Uninstall it first; brew refuses to untap while they're installed.")
                : String(localized: "\(names.count) installed packages come from this tap (\(list)). Uninstall them first; brew refuses to untap while they're installed.")
        }
    }
}
