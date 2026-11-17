import Foundation
import TankardCore

// v0.6 (part B): Brewfile export, check and restore through `brew bundle`.
// A Brewfile is Ruby: Tankard never evaluates or parses its source. What
// is in it comes from `brew bundle list --file=… --<kind>`, and what is
// missing from `brew bundle check --file=… --verbose --no-upgrade`.
// Flags checked with `brew bundle <sub> --help` on brew 7.0.14.

public enum BrewfileKind: String, CaseIterable, Sendable, Codable {
    case tap, formula, cask, mas, vscode
    /// The `brew bundle list` flag for this kind.
    public var listFlag: String { "--\(rawValue)" }
    public var title: String {
        switch self {
        case .tap: return "Taps"
        case .formula: return "Formulae"
        case .cask: return "Casks"
        case .mas: return "App Store apps"
        case .vscode: return "VS Code extensions"
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
    /// `brew bundle dump --file=<path>`; `--force` only after the save
    /// panel confirmed an overwrite. `--no-vscode` for the retry when
    /// VS Code's `code` doesn't answer (it hangs on some Macs).
    public static func dump(path: String, force: Bool, noVSCode: Bool = false) -> [String] {
        ["bundle", "dump", "--file=\(path)"] + (force ? ["--force"] : []) + (noVSCode ? ["--no-vscode"] : [])
    }

    public static func check(path: String) -> [String] {
        ["bundle", "check", "--file=\(path)", "--verbose", "--no-upgrade"]
    }

    public static func list(path: String, kind: BrewfileKind?) -> [String] {
        ["bundle", "list", "--file=\(path)", kind?.listFlag ?? "--all"]
    }

    /// What the user can run in Terminal instead (Tankard never runs a shell).
    public static func installDisplay(path: String) -> String {
        "brew bundle install --file=" + ShellQuote.quote(path)
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
            if let (prefix, kind) = kinds.first(where: { head.hasPrefix($0.0) }) {
                out.append(BrewfileEntry(kind: kind, name: String(head.dropFirst(prefix.count))))
            } else if let sp = head.firstIndex(of: " ") {
                out.append(BrewfileEntry(kind: nil, name: String(head[head.index(after: sp)...])))
            }
        }
        return out
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
    }

    public var items: [Item]
    public var path: String

    public init(missing: [BrewfileEntry], path: String, compiles: [String: Bool] = [:], needsAdmin: Set<String> = []) {
        self.path = path
        items = missing.map { e in
            Item(entry: e, compiles: e.kind == .formula ? compiles[e.name] : nil,
                 needsAdmin: e.kind == .cask && needsAdmin.contains(e.name),
                 throughQueue: e.kind == .formula || e.kind == .cask)
        }
    }

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
            return p
        }
    }
}
