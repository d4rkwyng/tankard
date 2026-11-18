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
    /// Formulae (0.3): the `bottle do` block read from the file. nil when
    /// not scanned (the bottle is then unknown until `brew info`); an empty
    /// spec means the formula has no bottle block, so it compiles.
    public var bottle: BrewInfoJSON.BottleSpec?
    /// Formulae (0.3): `depends_on` names for macOS (runtime, and build-only).
    public var dependencies: [String]
    public var buildDependencies: [String]
    /// 0.8.6 (VM test L3): no bottle block, but a ready-made macOS download
    /// (`TapIndexer.prebuiltDownload`).
    public var prebuilt = false
    /// 0.8.6 (VM test L3): the file's literal `version "…"`, if it has one
    /// (brew info can't answer for an untrusted tap).
    public var version: String?

    public init(kind: PackageKind, name: String, tap: String, desc: String?, otherNames: [String] = [],
                bottle: BrewInfoJSON.BottleSpec? = nil, dependencies: [String] = [], buildDependencies: [String] = []) {
        self.kind = kind
        self.name = name
        self.tap = tap
        self.desc = desc
        self.otherNames = otherNames
        self.bottle = bottle
        self.dependencies = dependencies
        self.buildDependencies = buildDependencies
    }

    /// brew's full name: short in the two default taps, tap-qualified elsewhere.
    public var fullName: String {
        tap == "homebrew/core" || tap == "homebrew/cask" ? name : "\(tap)/\(name)"
    }

    public func catalogEntry() -> CatalogEntry {
        CatalogEntry(kind: kind, name: name, fullName: fullName, tap: tap, desc: desc, version: version,
                     dependencies: dependencies, buildDependencies: buildDependencies, otherNames: otherNames,
                     bottle: kind == .cask ? .cask : .unknown, detailsLoaded: false)
    }

    /// With the scanned bottle block judged for this Mac (Intelbrew-mode
    /// Discover knows every formula's bottle before any `brew info`).
    public func catalogEntry(builder: CatalogBuilder) -> CatalogEntry {
        var e = catalogEntry()
        guard kind == .formula, let spec = bottle else { return e }
        let (badge, tag, url) = builder.bottle(spec: spec)
        e.bottle = badge == .fromSource && prebuilt ? .prebuilt : badge
        e.bottleTag = tag
        e.bottleURL = url
        return e
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
    /// 0.8.6 (H1): only taps outside `homebrew/` (the user's own), for
    /// normal-mode Discover, where formulae.brew.sh already covers
    /// homebrew/core and homebrew/cask.
    public var userTapsOnly = false
    /// 0.8.6 (H1): stop reading after this many packages (a huge tap can't
    /// stall Discover).
    public var maxEntries = Int.max

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
                if userTapsOnly && Self.isHomebrewTap(user) { continue }
                out.append(("\(user)/\(repo.dropFirst("homebrew-".count))", userDir.appendingPathComponent(repo, isDirectory: true)))
            }
        }
        return out
    }

    /// homebrew/core, homebrew/cask and Homebrew's other own taps.
    public static func isHomebrewTap(_ userOrTap: String) -> Bool {
        let user = userOrTap.split(separator: "/").first.map(String.init) ?? userOrTap
        return user.lowercased() == "homebrew"
    }

    /// 0.8.6 (H1): changes when a tap is added, removed or updated (each
    /// checkout's directory and its git index, by modification time).
    /// Cheap: a few stat calls per tap, no file read.
    public func fingerprint() -> String {
        let fm = FileManager.default
        func mtime(_ path: String) -> String {
            let d = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return d.map { String($0.timeIntervalSince1970) } ?? "-"
        }
        return taps().map { tap, dir in
            "\(tap)@\(mtime(dir.path)),\(mtime(dir.appendingPathComponent(".git/index").path)),\(mtime(dir.appendingPathComponent(".git/FETCH_HEAD").path))"
        }.joined(separator: ";")
    }

    public func index() -> TapIndex {
        let start = Date()
        var entries: [TapIndexEntry] = []
        var names: [String] = []
        for (tap, dir) in taps() {
            if entries.count >= maxEntries { break }
            names.append(tap)
            let aliases = Self.aliases(in: dir.appendingPathComponent("Aliases"))
            var formulaFiles = Self.rubyFiles(in: dir.appendingPathComponent("Formula"))
                + Self.rubyFiles(in: dir.appendingPathComponent("HomebrewFormula"))
            if formulaFiles.isEmpty && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Casks").path) {
                // Older third-party taps keep formulae at the top level.
                formulaFiles = Self.rubyFiles(in: dir, recursive: false)
            }
            for file in formulaFiles where entries.count < maxEntries {
                let name = file.deletingPathExtension().lastPathComponent
                var head = Self.head(of: file)
                if head.count == Self.headSize, head.range(of: Data("\n  bottle do".utf8)) == nil,
                   let whole = try? Data(contentsOf: file) {
                    head = whole // a long formula: the bottle block may come later
                }
                let scanned = FormulaScanner.scan(head, tap: tap)
                var entry = TapIndexEntry(kind: .formula, name: name, tap: tap,
                                          desc: Self.argument("desc", in: head),
                                          otherNames: aliases[name] ?? [],
                                          bottle: scanned.bottle,
                                          dependencies: scanned.runtime, buildDependencies: scanned.build)
                // 0.8.6 (VM test L3): only for third-party taps (homebrew/core
                // has bottles, and this costs a scan per formula).
                if !Self.isHomebrewTap(tap), scanned.bottle.files.isEmpty {
                    entry.prebuilt = Self.prebuiltDownload(head)
                    entry.version = Self.argument("version", in: head)
                }
                entries.append(entry)
            }
            for file in Self.rubyFiles(in: dir.appendingPathComponent("Casks")) where entries.count < maxEntries {
                let head = Self.head(of: file)
                entries.append(TapIndexEntry(kind: .cask, name: file.deletingPathExtension().lastPathComponent, tap: tap,
                                             desc: Self.argument("desc", in: head),
                                             otherNames: Self.argument("name", in: head).map { [$0] } ?? []))
            }
        }
        return TapIndex(entries: entries, taps: names, seconds: Date().timeIntervalSince(start))
    }

    /// 0.8.6 (VM test L3): a formula with no bottle block that downloads a
    /// ready-made program for macOS (GoReleaser-style taps): a `url` whose
    /// file name names macOS or a Mac CPU (darwin, macos, arm64, amd64…),
    /// no build-only dependency, and no `system` call (nothing is built).
    /// Conservative: anything else stays "compiles".
    public static func prebuiltDownload(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("\n  bottle do") || text.contains("=> :build") { return false }
        var sawBinaryURL = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("system ") || line.hasPrefix("system(") { return false }
            guard line.hasPrefix("url "), let url = rubyStringArgument("url", in: String(line)) else { continue }
            let file = (url.split(separator: "/").last.map(String.init) ?? url).lowercased()
            if ["darwin", "macos", "mac_os", "osx", "apple", "arm64", "aarch64", "x86_64", "amd64", "universal"]
                .contains(where: { file.contains($0) }) { sawBinaryURL = true }
        }
        return sawBinaryURL
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
    static let headSize = 16 * 1024

    static func head(of url: URL) -> Data {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return Data() }
        defer { close(fd) }
        var buffer = Data(count: headSize)
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

/// Reads the two things Discover needs from a formula file without running
/// Ruby: the `bottle do` block and the `depends_on` lines. Only literal,
/// conventionally formatted lines are understood (brew's own style, which
/// `brew style` enforces in homebrew/core); anything else is skipped, and
/// `brew info` fills in the truth for the rows being looked at.
///
/// One pass over the bytes, no String per line: Intelbrew-mode Discover
/// scans every formula in the taps (8,732 on the Intel VM).
public enum FormulaScanner {
    public struct Result: Sendable, Equatable {
        /// Empty files (and nil root URL) when the formula has no bottle block.
        public var bottle: BrewInfoJSON.BottleSpec
        public var runtime: [String]
        public var build: [String]
    }

    public static func bottle(in source: String, tap: String) -> BrewInfoJSON.BottleSpec {
        scan(Data(source.utf8), tap: tap).bottle
    }

    public static func dependencies(in source: String) -> (runtime: [String], build: [String]) {
        let r = scan(Data(source.utf8), tap: "homebrew/core")
        return (r.runtime, r.build)
    }

    /// - bottle: `bottle do … end` at two-space indent; `root_url "…"` and
    ///   `sha256 [cellar: X,] <tag>: "…"` lines (brew pads the tag column).
    ///   Without `root_url`, homebrew/core bottles come from ghcr.io; without
    ///   `cellar:`, brew's default Cellar for the tag.
    /// - dependencies: `depends_on "x"` at top level and inside `on_macos`,
    ///   `on_intel`/`on_arm` and `on_<codename>` blocks; not inside `on_linux`,
    ///   `on_system`, `head`, `resource`, `test` or other blocks. `=> :build`
    ///   goes to `build`, `=> :test` is dropped. Arch blocks aren't told apart
    ///   (both kept), a slight overcount. Stops at the first method (`  def `):
    ///   brew style puts every depends_on and the bottle block before it.
    public static func scan(_ data: Data, tap: String) -> Result {
        var files: [String: BrewInfoJSON.BottleFile] = [:]
        var rootURL: String?
        var runtime: [String] = [], build: [String] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var inBottle = false
            var stack: [Bool] = []
            var excluded = 0
            var i = 0
            func has(_ lit: StaticString, at k: Int, end: Int) -> Bool {
                let c = lit.utf8CodeUnitCount
                guard end - k >= c else { return false }
                let l = lit.utf8Start
                for x in 0..<c where p[k + x] != l[x] { return false }
                return true
            }
            func string(_ a: Int, _ b: Int) -> String {
                String(decoding: UnsafeBufferPointer(rebasing: p[a..<b]), as: UTF8.self)
            }
            /// The "…" literal starting at k (after spaces), without escapes.
            func quoted(from k: Int, end: Int) -> (String, Int)? {
                var a = k
                while a < end && p[a] == 32 { a += 1 }
                guard a < end, p[a] == 34 || p[a] == 39 else { return nil }
                let q = p[a]
                var b = a + 1
                while b < end && p[b] != q {
                    if p[b] == 92 || (p[b] == 35 && b + 1 < end && p[b + 1] == 123) { return nil } // \ or #{
                    b += 1
                }
                guard b < end else { return nil }
                return (string(a + 1, b), b + 1)
            }
            func contains(_ lit: StaticString, _ a: Int, _ b: Int) -> Bool {
                var k = a
                while k < b { if has(lit, at: k, end: b) { return true }; k += 1 }
                return false
            }
            while i < n {
                var j = i
                while j < n && p[j] != 10 { j += 1 }
                defer { i = j + 1 }
                var s = i
                while s < j && (p[s] == 32 || p[s] == 9) { s += 1 }
                var e = j
                while e > s && (p[e - 1] == 32 || p[e - 1] == 9 || p[e - 1] == 13) { e -= 1 }
                guard s < e, p[s] != 35 else { continue } // blank or comment
                let indent = s - i
                if indent == 2 && has("def ", at: s, end: e) { break }
                let isEnd = e - s == 3 && has("end", at: s, end: e)
                if inBottle {
                    if isEnd {
                        inBottle = false
                    } else if has("root_url ", at: s, end: e) {
                        rootURL = quoted(from: s + 9, end: e)?.0
                    } else if has("sha256 ", at: s, end: e) {
                        var k = s + 7
                        while k < e && p[k] == 32 { k += 1 }
                        var cellar: String?
                        if has("cellar: ", at: k, end: e) {
                            k += 8
                            var c = k
                            while c < e && p[c] != 44 { c += 1 } // ","
                            guard c < e else { continue }
                            var a = k, b = c
                            while b > a && p[b - 1] == 32 { b -= 1 }
                            if b - a >= 2 && p[a] == 34 && p[b - 1] == 34 { a += 1; b -= 1 }
                            cellar = string(a, b)
                            k = c + 1
                            while k < e && p[k] == 32 { k += 1 }
                        }
                        var t = k
                        while t < e, (p[t] >= 97 && p[t] <= 122) || (p[t] >= 48 && p[t] <= 57) || p[t] == 95 { t += 1 }
                        guard t > k, t < e, p[t] == 58 else { continue } // "tag:"
                        let tag = string(k, t)
                        files[tag] = BrewInfoJSON.BottleFile(cellar: cellar ?? defaultCellar(tag: tag), url: nil)
                    }
                    continue
                }
                if indent == 2 && e - s == 9 && has("bottle do", at: s, end: e) {
                    inBottle = true
                    continue
                }
                if isEnd {
                    if let last = stack.popLast(), !last { excluded -= 1 }
                    continue
                }
                let opens = (e - s >= 3 && has(" do", at: e - 3, end: e)) || contains(" do |", s, e)
                if opens {
                    var w = s
                    while w < e && p[w] != 32 { w += 1 }
                    let included = has("on_", at: s, end: w) && !has("on_linux", at: s, end: w) && !has("on_system", at: s, end: w)
                    stack.append(included)
                    if !included { excluded += 1 }
                    continue
                }
                guard excluded == 0, has("depends_on ", at: s, end: e), let (name, after) = quoted(from: s + 11, end: e) else { continue }
                if contains(":build", after, e) {
                    build.append(name)
                } else if !contains(":test", after, e) {
                    runtime.append(name)
                }
            }
        }
        if rootURL == nil && !files.isEmpty && tap == "homebrew/core" {
            rootURL = "https://ghcr.io/v2/homebrew/core"
        }
        let r = dedupe(runtime)
        return Result(bottle: BrewInfoJSON.BottleSpec(rootURL: rootURL, files: files),
                      runtime: r, build: dedupe(build.filter { !r.contains($0) }))
    }

    /// brew's default Cellar for a tag when the line names none.
    static func defaultCellar(tag: String) -> String {
        if tag.hasSuffix("_linux") { return "/home/linuxbrew/.linuxbrew/Cellar" }
        return tag.hasPrefix("arm64_") ? "/opt/homebrew/Cellar" : "/usr/local/Cellar"
    }

    static func dedupe(_ a: [String]) -> [String] {
        var seen: Set<String> = []
        return a.filter { seen.insert($0).inserted }
    }
}
