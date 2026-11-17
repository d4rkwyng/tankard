import CryptoKit
import Foundation

// 0.8: download progress for the install/upgrade sheet.
//
// brew draws its download progress only on a terminal. Tankard runs it on
// pipes, and there brew 7 prints just "==> Fetching downloads for: x" and,
// when a file is done, "✔︎ Cask x (1.2)" (download_queue.rb: the progress
// line is drawn only when $stdout is a tty; utils/curl.rb adds --silent to
// curl when it isn't). A pty would bring back cursor-movement redraws,
// spinner frames and a width-dependent line format, and would make brew
// (and sudo) think someone can answer prompts.
//
// What brew does on any stdout: curl writes each download to
//   <HOMEBREW_CACHE>/downloads/<sha256(url)>--<basename>.incomplete
// and renames it when done (download_strategy/abstract_file_download_strategy.rb,
// curl_download_strategy.rb). brew's own progress line is the size of that
// file against the Content-Length of a HEAD request. Tankard does the same:
// it watches that folder while a command runs. The total comes from
//   - a bottle: the bottle manifest brew downloaded just before (in the
//     same folder), whose entry for the bottle's tag has
//     `sh.brew.bottle.size`; no network;
//   - anything else (a cask): a HEAD request's Content-Length for the URL
//     `brew info` gives the cask (what brew itself sends a HEAD to), used
//     only for the file whose prefix is that URL's sha256. Without one the
//     sheet shows the bytes so far.

/// One download as the sheet shows it.
public struct DownloadProgress: Equatable, Sendable {
    /// The formula a bottle is for, or nil (the sheet uses the package's name).
    public var name: String?
    public var bytes: Int64
    /// nil when unknown (indeterminate bar).
    public var total: Int64?
    /// How many files are downloading at once (brew fetches dependencies in parallel).
    public var files: Int

    public init(name: String?, bytes: Int64, total: Int64?, files: Int = 1) {
        self.name = name
        self.bytes = bytes
        self.total = total
        self.files = files
    }

    /// 0...1, or nil when the total is unknown.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(total)))
    }

    public var percent: Int? { fraction.map { Int(($0 * 100).rounded(.down)) } }
}

/// A file name in brew's downloads folder.
public struct BrewDownloadName: Equatable, Sendable {
    /// sha256 of the URL brew downloads it from (lowercase hex).
    public var urlHash: String
    /// The rest: "JetBrainsMono-2.304.zip", "figlet--2.2.5.arm64_tahoe.bottle.tar.gz".
    public var basename: String
    public var incomplete: Bool

    public struct Bottle: Equatable, Sendable {
        public var formula: String
        public var version: String
        public var tag: String
        /// 0 when the file name has none.
        public var rebuild: Int
    }

    /// "<name>--<version>.<tag>.bottle[.<rebuild>].tar.gz"
    public var bottle: Bottle? {
        guard basename.hasSuffix(".tar.gz"), let sep = basename.range(of: "--") else { return nil }
        let formula = String(basename[..<sep.lowerBound])
        var rest = String(basename[sep.upperBound...].dropLast(".tar.gz".count))
        var rebuild = 0
        if let dot = rest.lastIndex(of: "."), let n = Int(rest[rest.index(after: dot)...]) {
            rebuild = n
            rest = String(rest[..<dot])
        }
        guard rest.hasSuffix(".bottle") else { return nil }
        rest = String(rest.dropLast(".bottle".count))
        guard let tagDot = rest.lastIndex(of: ".") else { return nil }
        let version = String(rest[..<tagDot])
        let tag = String(rest[rest.index(after: tagDot)...])
        guard !formula.isEmpty, !version.isEmpty, !tag.isEmpty else { return nil }
        return Bottle(formula: formula, version: version, tag: tag, rebuild: rebuild)
    }

    public static func parse(_ file: String) -> BrewDownloadName? {
        var f = file
        let incomplete = f.hasSuffix(".incomplete")
        if incomplete { f = String(f.dropLast(".incomplete".count)) }
        guard let sep = f.range(of: "--") else { return nil }
        let hash = String(f[..<sep.lowerBound])
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        return BrewDownloadName(urlHash: hash.lowercased(), basename: String(f[sep.upperBound...]), incomplete: incomplete)
    }

    /// The prefix brew gives a download from `url`.
    public static func urlHash(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The bottle size a manifest gives for one tag (`sh.brew.bottle.size`).
public enum BottleManifestSize {
    /// `ref` is "<version>.<tag>[.<rebuild>]", as in org.opencontainers.image.ref.name.
    public static func size(manifest: Data, ref: String) -> Int64? {
        guard let obj = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let list = obj["manifests"] as? [[String: Any]] else { return nil }
        for m in list {
            guard let a = m["annotations"] as? [String: Any],
                  a["org.opencontainers.image.ref.name"] as? String == ref else { continue }
            if let s = a["sh.brew.bottle.size"] as? String { return Int64(s) }
            if let n = a["sh.brew.bottle.size"] as? NSNumber { return n.int64Value }
        }
        return nil
    }

    public static func ref(_ b: BrewDownloadName.Bottle) -> String {
        "\(b.version).\(b.tag)" + (b.rebuild > 0 ? ".\(b.rebuild)" : "")
    }

    /// Manifest file names that can hold `b`: "<hash>--<formula>-<version>[-<rebuild>].bottle_manifest.json".
    public static func matches(_ file: String, _ b: BrewDownloadName.Bottle) -> Bool {
        guard let n = BrewDownloadName.parse(file), !n.incomplete,
              n.basename.hasSuffix(".bottle_manifest.json") else { return false }
        let stem = String(n.basename.dropLast(".bottle_manifest.json".count))
        let want = "\(b.formula)-\(b.version)"
        return stem == want || stem == want + "-\(b.rebuild)"
    }
}

/// What the watcher reads from disk (a fake in tests).
public protocol DownloadFolderReading: Sendable {
    /// File names in `directory` (not paths); empty if it can't be read.
    func files(in directory: String) -> [String]
    /// Size and modification date, nil if gone.
    func stat(_ path: String) -> (size: Int64, modified: Date)?
    func read(_ path: String) -> Data?
}

public struct LiveDownloadFolder: DownloadFolderReading {
    public init() {}
    public func files(in directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    }
    public func stat(_ path: String) -> (size: Int64, modified: Date)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (a[.size] as? NSNumber)?.int64Value, let modified = a[.modificationDate] as? Date else { return nil }
        return (size, modified)
    }
    public func read(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }
}

/// A download's expected size from the server (a fake in tests).
public protocol ContentLengthFetching: Sendable {
    func contentLength(of url: String) async -> Int64?
}

/// A HEAD request, following redirects, as brew's own one does (curl
/// --head --location). ghcr.io wants brew's anonymous bearer token.
public struct HTTPContentLength: ContentLengthFetching {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func contentLength(of url: String) async -> Int64? {
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http" else { return nil }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "HEAD"
        if u.host == "ghcr.io" { req.setValue("Bearer QQ==", forHTTPHeaderField: "Authorization") }
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let n = http.expectedContentLength
        return n > 0 ? n : nil
    }
}

/// Watches brew's downloads folder while one command runs.
public actor DownloadWatcher {
    public let directory: String
    let reader: DownloadFolderReading
    let lengths: ContentLengthFetching?
    /// Files last modified before this are someone else's (an old, stopped download).
    let since: Date
    /// sha256 prefix → the HEAD request's answer (nil inside: no length).
    private var hinted: [String: Int64?] = [:]
    private var asking: Set<String> = []
    private var totals: [String: Int64?] = [:]
    /// Files this command downloaded that are done (renamed), with their size.
    private var finished: [String: Int64] = [:]
    private var active: [String: Int64] = [:]

    public init(directory: String, reader: DownloadFolderReading = LiveDownloadFolder(),
                lengths: ContentLengthFetching? = nil, since: Date, urls: [String] = []) {
        self.directory = directory
        self.reader = reader
        self.lengths = lengths
        self.since = since
        Task { await self.addURLs(urls) }
    }

    /// URLs the command may download (a cask's `url`), learnt after start.
    /// Their sizes are asked for at once, while brew is still starting up
    /// (its own HEAD request and setup take about a second), so the total is
    /// usually known by the time the first bytes arrive: on a fast link a
    /// 34 MB download takes well under a second.
    public func addURLs(_ urls: [String]) {
        guard let lengths else { return }
        for u in urls {
            let hash = BrewDownloadName.urlHash(u)
            guard !asking.contains(hash) else { continue }
            asking.insert(hash)
            Task { [weak self] in
                let size = await lengths.contentLength(of: u)
                await self?.setHinted(hash, size)
            }
        }
    }

    private func setHinted(_ hash: String, _ size: Int64?) {
        hinted[hash] = .some(size)
    }

    /// Whether any download of this command was seen.
    public var sawDownload: Bool { !active.isEmpty || !finished.isEmpty }

    /// The downloads running now, summed; nil when none is.
    public func poll() -> DownloadProgress? {
        let names = reader.files(in: directory)
        var now: [String: (BrewDownloadName, Int64)] = [:]
        for f in names where f.hasSuffix(".incomplete") {
            // A bottle manifest is a few KB fetched before the downloads start.
            guard let n = BrewDownloadName.parse(f), !n.basename.hasSuffix(".bottle_manifest.json"),
                  let st = reader.stat(directory + "/" + f),
                  st.modified >= since.addingTimeInterval(-2) else { continue }
            now[f] = (n, st.size)
        }
        // A file that was growing and is gone was renamed: done (or removed
        // after a failure; either way it no longer counts as running).
        for (f, size) in active where now[f] == nil {
            finished[f] = (totals[f] ?? nil) ?? size
        }
        active = now.mapValues(\.1)
        guard !now.isEmpty else { return nil }

        var bytes: Int64 = 0
        var total: Int64? = 0
        for (f, (n, size)) in now {
            bytes += size
            let t = totalSize(f, n, names: names)
            if let t, let sum = total { total = sum + max(t, size) } else { total = nil }
        }
        // Files of this command that finished while others still run keep
        // counting, so the bar doesn't jump back.
        for (_, size) in finished {
            bytes += size
            total = total.map { $0 + size }
        }
        let bottles = now.values.compactMap { $0.0.bottle?.formula }
        let name = now.count == 1 ? bottles.first : nil
        return DownloadProgress(name: name, bytes: bytes, total: total, files: now.count)
    }

    private func totalSize(_ file: String, _ n: BrewDownloadName, names: [String]) -> Int64? {
        if let known = totals[file] { return known }
        if let b = n.bottle {
            for m in names where BottleManifestSize.matches(m, b) {
                if let data = reader.read(directory + "/" + m),
                   let size = BottleManifestSize.size(manifest: data, ref: BottleManifestSize.ref(b)) {
                    totals[file] = size
                    return size
                }
            }
        }
        if let answer = hinted[n.urlHash] {
            totals[file] = answer
            return answer
        }
        return nil
    }
}

/// Formats "12.3 of 45.6 MB (27%)" / "12.3 MB": decimal units, like brew
/// and Finder. The caller localizes the sentence around the pieces.
public enum DownloadSizeFormat {
    /// The number and unit for `bytes`, in the unit that suits `scale` (the
    /// total, or the bytes themselves).
    public static func pieces(_ bytes: Int64, scale: Int64, locale: Locale = .current) -> (number: String, unit: String) {
        let units: [(Double, String)] = [(1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        let (div, unit) = units.first { Double(scale) >= $0.0 } ?? (1e3, "KB")
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = div >= 1e6 ? 1 : 0
        f.maximumFractionDigits = div >= 1e6 ? 1 : 0
        let n = f.string(from: NSNumber(value: Double(bytes) / div)) ?? "\(bytes)"
        return (n, unit)
    }
}
