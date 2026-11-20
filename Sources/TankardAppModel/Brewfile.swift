import Foundation
import TankardCore

// v0.6 (part B): Brewfile export, check and restore through `brew bundle`.
// A Brewfile is a Ruby program, and `brew bundle` (check, list, install)
// runs it: Homebrew::Bundle loads the file with `instance_eval`, so any code
// in it runs as the user the moment brew reads it. Tankard itself never
// evaluates it. 0.8.8 (security review #2): Check Brewfile… first shows
// `BrewfileStaticReader`'s preview, which reads only plain literal lines and
// runs nothing; brew bundle check runs only after the user confirms that
// it will run the file's code. What is missing comes from `brew bundle
// check --file=… --verbose --no-upgrade`, and an export's counts from
// `brew bundle list --file=… --<kind>` on the file brew itself just wrote.
// Flags checked with `brew bundle <sub> --help` on brew 7.0.14.

public enum BrewfileKind: String, CaseIterable, Sendable, Codable {
    case tap, formula, cask, mas, vscode
    /// The `brew bundle list` flag for this kind.
    public var listFlag: String { "--\(rawValue)" }
    public var title: String {
        switch self {
        case .tap: return String(localized: "Taps")
        case .formula: return String(localized: "Formulae")
        case .cask: return String(localized: "Casks")
        case .mas: return String(localized: "App Store apps")
        case .vscode: return String(localized: "VS Code extensions")
        }
    }
}

public struct BrewfileEntry: Equatable, Hashable, Sendable {
    /// nil: a kind Tankard doesn't name (go, cargo, npm, …).
    public var kind: BrewfileKind?
    public var name: String
    public init(kind: BrewfileKind?, name: String) {
        self.kind = kind
        self.name = name
    }
}

public enum BrewfileCommands {
    /// `brew bundle dump --file=<path> --no-vscode --no-mas`; `--force`
    /// only after the save panel confirmed an overwrite. VS Code
    /// extensions and App Store apps are always left out: asking VS Code's
    /// `code` for its extensions hung dump for over 100 s on one Mac.
    public static func dump(path: String, force: Bool) -> [String] {
        ["bundle", "dump", "--file=\(path)", "--no-vscode", "--no-mas"] + (force ? ["--force"] : [])
    }

    public static func check(path: String) -> [String] {
        ["bundle", "check", "--file=\(path)", "--verbose", "--no-upgrade"]
    }

    public static func list(path: String, kind: BrewfileKind?) -> [String] {
        ["bundle", "list", "--file=\(path)", kind?.listFlag ?? "--all"]
    }

    /// What the user can run in Terminal instead (Tankard never runs a shell).
    public static func installDisplay(path: String) -> String {
        "brew bundle install --file=" + ShellQuote.quote(path) + " --no-upgrade"
    }

    /// `brew tap <name> [<url>]`, shown for a missing tap.
    public static func tapDisplay(_ name: String, url: String? = nil) -> String {
        "brew tap " + ShellQuote.quote(name) + (url.map { " " + ShellQuote.quote($0) } ?? "")
    }
}

enum ShellQuote {
    static func quote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+~@%:,="))
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum BrewfileParser {
    /// `brew bundle list` stdout: one name per line.
    public static func listNames(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The contents, from one `list --all` and one `list --<kind>` per kind.
    /// Names in `all` that no kind claimed are kept with kind nil.
    public static func contents(all: [String], byKind: [BrewfileKind: [String]]) -> [BrewfileEntry] {
        var out: [BrewfileEntry] = []
        var claimed: [String: Int] = [:]
        for k in BrewfileKind.allCases {
            for n in byKind[k] ?? [] {
                out.append(BrewfileEntry(kind: k, name: n))
                claimed[n, default: 0] += 1
            }
        }
        for n in all {
            if let c = claimed[n], c > 0 { claimed[n] = c - 1; continue }
            out.append(BrewfileEntry(kind: nil, name: n))
        }
        return out
    }

    /// `brew bundle check --verbose` lines, as brew 7.0.14 prints them:
    /// "→ Formula jq needs to be installed.", "→ Cask firefox needs to be
    /// installed.", "→ Tap user/repo needs to be tapped." Anything else
    /// (warnings, the summary lines) is ignored.
    public static func missing(_ lines: [String]) -> [BrewfileEntry] {
        let kinds: [(String, BrewfileKind?)] = [("Tap ", .tap), ("Formula ", .formula), ("Cask ", .cask),
                                                ("App Store app ", .mas), ("Mas ", .mas),
                                                ("VSCode extension ", .vscode), ("Vscode ", .vscode)]
        var out: [BrewfileEntry] = []
        for raw in lines {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("→") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard let r = s.range(of: " needs to be ") else { continue }
            let head = String(s[..<r.lowerBound])
            // 0.8.8 (security review #5): a name brew would take for an
            // option ("--force") is never listed, so never passed on.
            if let (prefix, kind) = kinds.first(where: { head.hasPrefix($0.0) }) {
                let name = String(head.dropFirst(prefix.count))
                guard !name.hasPrefix("-") else { continue }
                out.append(BrewfileEntry(kind: kind, name: name))
            } else if let sp = head.firstIndex(of: " ") {
                let name = String(head[head.index(after: sp)...])
                guard !name.hasPrefix("-") else { continue }
                out.append(BrewfileEntry(kind: nil, name: name))
            }
        }
        return out
    }
}

/// 0.8.5 (bug hunt M3): where a Brewfile's tap comes from. `brew bundle
/// check` names a missing tap but not its URL, and `brew bundle list` prints
/// names only, so a `tap "user/repo", "https://…"` line's URL used to be
/// lost: Add Tap… then cloned github.com/user/homebrew-repo, which may be
/// someone else's repo. The URL is read from the Brewfile's text, and only
/// from a plain line: `tap "user/repo"` or `tap "user/repo", "<url>"`
/// (single or double quotes, optional parentheses, keyword options after).
/// Anything else (a variable, string interpolation, a line Tankard can't
/// read) is `.unreadable`, and that tap is left to `brew bundle` in Terminal.
public enum BrewfileTapSource: Equatable, Sendable {
    /// No URL: brew's default remote (GitHub).
    case standard
    case url(String)
    case unreadable
}

public enum BrewfileTapScanner {
    /// Tap name (as brew bundle names it: lower case, no "homebrew-") → source.
    /// A tap named on more than one line, differently, is `.unreadable`.
    public static func scan(_ text: String) -> [String: BrewfileTapSource] {
        var out: [String: BrewfileTapSource] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("tap"), let (name, source) = parse(line) else { continue }
            let key = sanitize(name)
            if let old = out[key], old != source { out[key] = .unreadable } else { out[key] = source }
        }
        return out
    }

    /// brew bundle's `Dsl.sanitize_tap_name`.
    public static func sanitize(_ name: String) -> String {
        let n = name.lowercased()
        let parts = n.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].hasPrefix("homebrew-") else { return n }
        return parts[0] + "/" + parts[1].dropFirst("homebrew-".count)
    }

    static func parse(_ line: String) -> (String, BrewfileTapSource)? {
        var rest = Substring(line.dropFirst(3))
        guard let first = rest.first, first == " " || first == "(" || first == "\t" else { return nil }
        rest = rest.drop { $0 == " " || $0 == "\t" || $0 == "(" }
        guard let (name, afterName) = literal(rest) else { return nil }
        var tail = afterName.drop { $0 == " " || $0 == "\t" }
        if tail.isEmpty || tail.hasPrefix("#") || tail.hasPrefix(")") { return (name, .standard) }
        guard tail.hasPrefix(",") else { return (name, .unreadable) }
        tail = tail.dropFirst().drop { $0 == " " || $0 == "\t" }
        if let (url, after) = literal(tail) {
            let end = after.drop { $0 == " " || $0 == "\t" }
            guard end.isEmpty || end.hasPrefix(",") || end.hasPrefix(")") || end.hasPrefix("#") else { return (name, .unreadable) }
            return (name, .url(url))
        }
        // `tap "a/b", force_auto_update: true`: keyword options, no URL.
        if let colon = tail.firstIndex(of: ":"), tail[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
           !tail[..<colon].isEmpty {
            return (name, .standard)
        }
        return (name, .unreadable)
    }

    /// A '…' or "…" literal with no escapes or interpolation, and what follows it.
    static func literal(_ s: Substring) -> (String, Substring)? {
        guard let q = s.first, q == "\"" || q == "'" else { return nil }
        let body = s.dropFirst()
        guard let end = body.firstIndex(of: q) else { return nil }
        let value = body[..<end]
        if value.contains("\\") || (q == "\"" && value.contains("#{")) || value.isEmpty { return nil }
        return (String(value), body[body.index(after: end)...])
    }
}

/// What restoring a checked Brewfile would do.
public struct BrewfileRestorePlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String { "\(entry.kind?.rawValue ?? "other"):\(entry.name)" }
        public var entry: BrewfileEntry
        /// Formulae: no bottle for this Mac (per CompileClassifier). nil: not known.
        public var compiles: Bool?
        /// Casks with a pkg installer: macOS asks for an administrator.
        public var needsAdmin: Bool
        /// Formulae and casks go through Tankard's queue; taps are added by
        /// brew when a qualified name installs; the rest needs Terminal.
        public var throughQueue: Bool
        /// 0.8.5 (M3): a tap's source in the Brewfile (nil: not a tap).
        public var tapSource: BrewfileTapSource?

        /// A tap's URL from the Brewfile, for Add Tap….
        public var tapURL: String? {
            if case .url(let u)? = tapSource { return u }
            return nil
        }

        /// Add Tap… can add it as the Brewfile says.
        public var canAddTap: Bool { entry.kind == .tap && tapSource != .unreadable && !isBuiltInTap }

        /// 0.8.9 (0.8.8 confirm run on 15, LOW): `tap "homebrew/cask"` (or
        /// homebrew/core) in a Brewfile. Homebrew installs from these
        /// through its API without the tap, so `brew bundle check` lists
        /// it as missing, but nothing needs adding: Install with Tankard
        /// doesn't wait for it, and there is no Add Tap… (`brew tap
        /// homebrew/cask` refuses in API mode without --force, which
        /// Tankard never passes).
        public var isBuiltInTap: Bool {
            entry.kind == .tap && BrewfileRestorePlan.builtInTaps.contains(BrewfileTapScanner.sanitize(entry.name))
        }
    }

    /// Homebrew's own taps, served by its API.
    public static let builtInTaps: Set<String> = ["homebrew/core", "homebrew/cask"]

    public var items: [Item]
    public var path: String

    public init(missing: [BrewfileEntry], path: String, compiles: [String: Bool] = [:], needsAdmin: Set<String> = [],
                tapSources: [String: BrewfileTapSource]? = nil) {
        self.path = path
        items = missing.map { e in
            Item(entry: e, compiles: e.kind == .formula ? compiles[e.name] : nil,
                 needsAdmin: e.kind == .cask && needsAdmin.contains(e.name),
                 // 0.8.8 (#5): only a name brew accepts goes to `brew install`.
                 throughQueue: (e.kind == .formula || e.kind == .cask)
                    && BrewfileStaticReader.validName(e.name, e.kind ?? .formula),
                 tapSource: e.kind == .tap
                    ? (tapSources.map { $0[BrewfileTapScanner.sanitize(e.name)] ?? .unreadable } ?? .unreadable) : nil)
        }
    }

    /// 0.8.5 (M3): taps the Brewfile needs that aren't added yet. Install
    /// with Tankard waits for them: a formula from a missing tap would
    /// otherwise make brew tap it from GitHub, not from the Brewfile's URL.
    public var missingTaps: [Item] { items.filter { $0.entry.kind == .tap && !$0.isBuiltInTap } }
    public var canInstallWithTankard: Bool { !queued.isEmpty && missingTaps.isEmpty }

    public var queued: [Item] { items.filter(\.throughQueue) }
    public var terminalOnly: [Item] { items.filter { !$0.throughQueue } }
    public var compiling: [Item] { items.filter { $0.compiles == true } }
    public var adminCasks: [Item] { items.filter(\.needsAdmin) }
    public var terminalCommand: String { BrewfileCommands.installDisplay(path: path) }

    /// Placeholder packages for the install session (one `brew install`
    /// each, in the Brewfile's order).
    public func packages() -> [Package] {
        queued.map { item in
            var p = Package.command(item.entry.name)
            let k: PackageKind = item.entry.kind == .cask ? .cask : .formula
            p.kind = k
            p.id = "\(k.rawValue):\(item.entry.name)"
            p.fullName = item.entry.name
            p.status = k == .cask ? .cask : .bottle
            // 0.8.3: what the prefetch needs (a formula that compiles isn't fetched).
            p.upgradeHasBottle = k == .formula ? item.compiles != true : nil
            return p
        }
    }
}
