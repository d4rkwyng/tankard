import Foundation

/// A name (and description) read from a tap checkout, before `brew info`.
public struct TapIndexEntry: Sendable, Equatable {
    public var kind: PackageKind
    public var name: String
    /// "homebrew/core"
    public var tap: String
    public var desc: String?
    /// Formula aliases (from the tap's Aliases directory); cask display names.
    public var otherNames: [String]

    public init(kind: PackageKind, name: String, tap: String, desc: String?, otherNames: [String] = []) {
        self.kind = kind
        self.name = name
        self.tap = tap
        self.desc = desc
        self.otherNames = otherNames
    }

    /// brew's full name: short in the two default taps, tap-qualified elsewhere.
    public var fullName: String {
        tap == "homebrew/core" || tap == "homebrew/cask" ? name : "\(tap)/\(name)"
    }

    public func catalogEntry() -> CatalogEntry {
        CatalogEntry(kind: kind, name: name, fullName: fullName, tap: tap, desc: desc, otherNames: otherNames,
                     bottle: kind == .cask ? .cask : .unknown, detailsLoaded: false)
    }
}

public struct TapIndex: Sendable {
    public var entries: [TapIndexEntry]
    /// "homebrew/core", ...
    public var taps: [String]
    public var seconds: Double

    public init(entries: [TapIndexEntry], taps: [String], seconds: Double = 0) {
        self.entries = entries
        self.taps = taps
        self.seconds = seconds
    }

    public var hasCaskTap: Bool { taps.contains("homebrew/cask") }
}

/// Reads formula and cask names from the tap checkouts under
/// `<repository>/Library/Taps`, the way Intelbrew mode searches: the local
/// taps are the truth there, not formulae.brew.sh.
///
/// It only lists files and reads the `desc` line of each; no Ruby is run
/// (brew 7 refuses to evaluate every formula of an untrusted tap, so
/// `brew search --desc` can't do this). Versions, bottles and licences come
/// from `brew info --json=v2` afterwards, for the rows being looked at.
public struct TapIndexer: Sendable {
    public var tapsDirectory: URL

    public init(repository: String) {
        tapsDirectory = URL(fileURLWithPath: repository).appendingPathComponent("Library/Taps", isDirectory: true)
    }

    public init(tapsDirectory: URL) {
        self.tapsDirectory = tapsDirectory
    }

    /// (tap name, checkout) for every `<user>/homebrew-<repo>` directory.
    public func taps() -> [(String, URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = []
        let users = (try? fm.contentsOfDirectory(atPath: tapsDirectory.path)) ?? []
        for user in users.sorted() where !user.hasPrefix(".") {
            let userDir = tapsDirectory.appendingPathComponent(user, isDirectory: true)
            let repos = (try? fm.contentsOfDirectory(atPath: userDir.path)) ?? []
            for repo in repos.sorted() where repo.hasPrefix("homebrew-") {
                out.append(("\(user)/\(repo.dropFirst("homebrew-".count))", userDir.appendingPathComponent(repo, isDirectory: true)))
            }
        }
        return out
    }

    public func index() -> TapIndex {
        let start = Date()
        var entries: [TapIndexEntry] = []
        var names: [String] = []
        for (tap, dir) in taps() {
            names.append(tap)
            let aliases = Self.aliases(in: dir.appendingPathComponent("Aliases"))
            var formulaFiles = Self.rubyFiles(in: dir.appendingPathComponent("Formula"))
                + Self.rubyFiles(in: dir.appendingPathComponent("HomebrewFormula"))
            if formulaFiles.isEmpty && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Casks").path) {
                // Older third-party taps keep formulae at the top level.
                formulaFiles = Self.rubyFiles(in: dir, recursive: false)
            }
            for file in formulaFiles {
                let name = file.deletingPathExtension().lastPathComponent
                let head = Self.head(of: file)
                entries.append(TapIndexEntry(kind: .formula, name: name, tap: tap,
                                             desc: Self.argument("desc", in: head),
                                             otherNames: aliases[name] ?? []))
            }
            for file in Self.rubyFiles(in: dir.appendingPathComponent("Casks")) {
                let head = Self.head(of: file)
                entries.append(TapIndexEntry(kind: .cask, name: file.deletingPathExtension().lastPathComponent, tap: tap,
                                             desc: Self.argument("desc", in: head),
                                             otherNames: Self.argument("name", in: head).map { [$0] } ?? []))
            }
        }
        return TapIndex(entries: entries, taps: names, seconds: Date().timeIntervalSince(start))
    }

    static func rubyFiles(in dir: URL, recursive: Bool = true) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        if !recursive {
            return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "rb" }
        }
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == "rb" { out.append(url) }
        return out
    }

    /// Formula name → its aliases, from the tap's Aliases symlinks
    /// (`Aliases/python3 -> ../Formula/p/python@3.14.rb`).
    static func aliases(in dir: URL) -> [String: [String]] {
        let fm = FileManager.default
        var out: [String: [String]] = [:]
        for alias in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !alias.hasPrefix(".") {
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(alias).path) else { continue }
            let target = URL(fileURLWithPath: dest).deletingPathExtension().lastPathComponent
            out[target, default: []].append(alias)
        }
        return out.mapValues { $0.sorted() }
    }

    /// The first 16 KB of a file: `desc` and `name` come near the top.
    static func head(of url: URL) -> Data {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return Data() }
        defer { close(fd) }
        var buffer = Data(count: 16 * 1024)
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        return n > 0 ? buffer.prefix(n) : Data()
    }

    /// `rubyStringArgument`, but finds the `  <method> ` line with a byte
    /// search first and decodes only that line (thousands of files).
    static func argument(_ method: String, in data: Data) -> String? {
        let needle = Data("\n  \(method) ".utf8)
        guard let r = data.range(of: needle) else {
            return rubyStringArgument(method, in: String(decoding: data, as: UTF8.self))
        }
        let start = r.lowerBound + 1
        let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
        return rubyStringArgument(method, in: String(decoding: data[start..<end], as: UTF8.self))
    }

    /// The literal string argument of the first `  <method> "..."` (or
    /// '...') line, unescaped. nil when the argument isn't a plain literal.
    public static func rubyStringArgument(_ method: String, in source: String) -> String? {
        for line in source.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.drop { $0 == " " || $0 == "\t" }
            guard t.hasPrefix(method + " ") else { continue }
            let arg = t.dropFirst(method.count + 1).drop { $0 == " " }
            guard let quote = arg.first, quote == "\"" || quote == "'" else { return nil }
            var out = ""
            var escaped = false
            for ch in arg.dropFirst() {
                if escaped {
                    switch ch {
                    case "n" where quote == "\"": out.append("\n")
                    case "t" where quote == "\"": out.append("\t")
                    case "\\", "\"", "'": out.append(ch)
                    default: out.append("\\"); out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == quote {
                    return out
                } else {
                    out.append(ch)
                }
            }
            return nil
        }
        return nil
    }
}
