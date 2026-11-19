import Foundation
import TankardCore

// Tankard ▸ Check for Tankard Updates…: one GET to GitHub's "latest release"
// API when the user asks, never in the background. Mostly for people who
// downloaded the zip: an app installed from the d4rkwyng/tap cask is
// upgraded through Homebrew instead (the normal queue), then relaunched.

/// A release newer than the running app.
public struct TankardRelease: Equatable, Sendable {
    /// "0.9.0" (the tag without its "v").
    public var version: String
    /// The release notes, shortened to a few headings and one line per
    /// change for the sheet.
    public var summary: ReleaseNotesSummary
    /// The release page (Download, Full Release Notes).
    public var url: URL

    /// The summary as plain text: headings, "• change" lines, then
    /// "…and N more".
    public var notes: String { summary.plainText }

    public init(version: String, summary: ReleaseNotesSummary, url: URL) {
        self.version = version
        self.summary = summary
        self.url = url
    }
}

/// 0.8.5: the release notes as a short list. GitHub's release body is the
/// CHANGELOG section (Scripts/changelog-section.sh) between an intro line
/// and an install line, and each change is a paragraph: a bold lead
/// sentence and the detail. 0.8.4 showed its first 700 characters, which
/// was the intro and one long change: one giant paragraph. Now: the
/// section headings (Added, Changed, Fixed) and, per change, only its bold
/// lead, or its first sentence when it has none; at most `limit` changes.
public struct ReleaseNotesSummary: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case heading(String)
        case bullet(String)
    }

    public var items: [Item]
    /// Changes left out after the first `limit`.
    public var more: Int

    public init(items: [Item] = [], more: Int = 0) {
        self.items = items
        self.more = more
    }

    public var isEmpty: Bool { items.isEmpty }

    public var bullets: [String] {
        items.compactMap { item -> String? in
            if case .bullet(let b) = item { return b }
            return nil
        }
    }

    public var plainText: String {
        var lines = items.map { item -> String in
            switch item {
            case .heading(let h): return h
            case .bullet(let b): return "• " + b
            }
        }
        if more > 0 { lines.append("…" + String(localized: "and \(more) more")) }
        return lines.joined(separator: "\n")
    }

    /// A change's line is cut (at a word, with "…") past this many characters.
    public static let lineLimit = 120

    public static func make(_ body: String, limit: Int = 12) -> ReleaseNotesSummary {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The intro ("Tankard v0.8.5: …") comes before the first heading.
        // A body with no heading at all starts at its first line.
        let start = lines.firstIndex { $0.hasPrefix("#") } ?? 0
        var items: [Item] = []
        var pendingHeading: String?
        var shown = 0, total = 0
        for raw in lines[start...] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                var h = Substring(line)
                while h.hasPrefix("#") { h = h.dropFirst() }
                let text = plain(String(h))
                pendingHeading = text.isEmpty ? nil : text
                continue
            }
            // Only top-level list items: an indented sub-item or a wrapped
            // line belongs to the change above it.
            guard raw.hasPrefix("- ") || raw.hasPrefix("* ") else { continue }
            let text = lead(String(raw.dropFirst(2)))
            guard !text.isEmpty else { continue }
            total += 1
            guard shown < limit else { continue }
            if let h = pendingHeading {
                items.append(.heading(h))
                pendingHeading = nil
            }
            items.append(.bullet(text))
            shown += 1
        }
        return ReleaseNotesSummary(items: items, more: total - shown)
    }

    /// One change's line: its bold lead when that is a sentence of its own
    /// ("**Long builds show their time.** While…" -> "Long builds show
    /// their time"), else the first sentence, Markdown dropped.
    static func lead(_ item: String) -> String {
        let t = item.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("**"), let close = t.range(of: "**", range: t.index(t.startIndex, offsetBy: 2)..<t.endIndex) {
            let bold = String(t[t.index(t.startIndex, offsetBy: 2)..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            if let last = bold.last, ".:!?".contains(last) {
                var b = plain(bold)
                while let l = b.last, ".:".contains(l) { b.removeLast() }
                return capped(b)
            }
        }
        return capped(firstSentence(plain(t)))
    }

    /// Bold, code and link Markdown dropped: "**x** `y` [z](u)" -> "x y z".
    static func plain(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        out = out.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Up to the first ". " (or the end), without the period.
    static func firstSentence(_ s: String) -> String {
        var sentence = s
        if let r = s.range(of: ". ") { sentence = String(s[..<r.lowerBound]) }
        while let l = sentence.last, ".:".contains(l) { sentence.removeLast() }
        return sentence
    }

    static func capped(_ s: String) -> String {
        guard s.count > lineLimit else { return s }
        let head = String(s.prefix(lineLimit - 1))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        var c = cut.trimmingCharacters(in: .whitespaces)
        while let l = c.last, ",;:(".contains(l) { c.removeLast() }
        return c + "…"
    }
}

/// Where a check stands.
public enum SelfUpdateCheck: Equatable, Sendable {
    case checking
    /// The running version is the latest (or newer: a development build).
    case upToDate(String)
    case available(TankardRelease)
    case failed(String)
}

/// Semantic versions ("0.8.0", "v1.2.3-rc.1"): numeric core, then a
/// pre-release sorts before the release (semver.org §11). Build metadata
/// ("+abc") is ignored.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public var core: [Int]
    public var prerelease: [String]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            s = String(s[..<dash])
            if pre.isEmpty || pre.contains(where: \.isEmpty) { return nil }
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            nums.append(n)
        }
        while nums.count < 3 { nums.append(0) }
        core = nums
        prerelease = pre
    }

    public var description: String {
        core.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: Self, b: Self) -> Bool {
        if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
        // A pre-release is older than its release.
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true   // numeric identifiers sort first
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// The request and its answer.
public struct UpdateFeed: Sendable {
    public typealias Fetch = @Sendable () async throws -> (Data, Int)

    /// GitHub's latest release: drafts and pre-releases are never "latest".
    public static let latestURL = URL(string: "https://api.github.com/repos/d4rkwyng/tankard/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/d4rkwyng/tankard/releases/latest")!
    /// The cask that installs Tankard.
    public static let tapCask = "d4rkwyng/tap/tankard"

    public var fetch: Fetch

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// live()'s session: ephemeral, no cache, TankardVersion.userAgent and
    /// GitHub's Accept header.
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.httpAdditionalHeaders = ["User-Agent": TankardVersion.userAgent, "Accept": "application/vnd.github+json"]
        return c
    }

    /// The real request: ephemeral session (no cookies, no cache), no
    /// credentials, only GitHub's required User-Agent and Accept headers.
    public static func live() -> UpdateFeed {
        let session = URLSession(configuration: sessionConfiguration())
        return UpdateFeed {
            let (data, response) = try await session.data(from: latestURL)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Screenshots and e2e (TANKARD_UPDATE_FEED=<file>): the file's
    /// contents as GitHub's answer; a missing file is an offline error.
    public static func file(_ path: String) -> UpdateFeed {
        UpdateFeed {
            guard let data = FileManager.default.contents(atPath: path) else { throw URLError(.notConnectedToInternet) }
            return (data, 200)
        }
    }

    public func check(current: String) async -> SelfUpdateCheck {
        do {
            let (data, status) = try await fetch()
            return Self.result(data: data, status: status, current: current)
        } catch {
            return .failed(Self.offlineMessage(error))
        }
    }

    static func offlineMessage(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                return String(localized: "Couldn't reach GitHub. Check the connection and try again.")
            default: break
            }
        }
        return error.localizedDescription
    }

    struct Release: Decodable {
        var tag_name: String
        var body: String?
        var html_url: String?
        var draft: Bool?
        var prerelease: Bool?
    }

    /// A release link Tankard will open: https on github.com itself.
    public static func releasePageOK(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
    }

    /// GitHub's answer, compared with the running version.
    public static func result(data: Data, status: Int, current: String) -> SelfUpdateCheck {
        guard status == 200 else {
            return .failed(status == 404 ? String(localized: "GitHub lists no release of Tankard.")
                                         : String(localized: "GitHub answered HTTP \(status)."))
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              let latest = SemanticVersion(release.tag_name),
              let running = SemanticVersion(current) else {
            return .failed(String(localized: "GitHub's answer couldn't be read."))
        }
        guard running < latest else { return .upToDate(current) }
        // 0.8.8 (security review #9): https and github.com, or the releases page.
        let page = release.html_url.flatMap(URL.init(string:)).flatMap { releasePageOK($0) ? $0 : nil } ?? releasesPage
        return .available(TankardRelease(version: latest.description, summary: ReleaseNotesSummary.make(release.body ?? ""), url: page))
    }
}

/// Is this Tankard the one the d4rkwyng/tap cask installed?
public enum SelfInstall {
    public static func isTankardCask(_ p: Package) -> Bool {
        guard p.kind == .cask, p.name.lowercased() == "tankard", let tap = p.tap?.lowercased() else { return false }
        return tap == "d4rkwyng/tap" || tap == e2eTap
    }

    /// 0.8.3, the self-update e2e only (ScriptLaunch, TANKARD_E2E_SELF_TAP):
    /// a throwaway local tap whose `tankard` cask counts as Tankard's own.
    /// Set once at launch, before any store exists; never in a normal launch.
    nonisolated(unsafe) public static var e2eTap: String?

    /// Only a throwaway tap name the e2e makes: `tankard-e2e-…/…`.
    public static func validE2ETap(_ v: String?) -> String? {
        guard let v = v?.lowercased(), v.hasPrefix("tankard-e2e-"), v.split(separator: "/").count == 2,
              v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "/" }) else { return nil }
        return v
    }

    /// The installed tankard cask whose app is the running bundle (brew's
    /// `brew info` artifacts name the app's path). nil for a zip download,
    /// a build, or a cask installed somewhere else.
    public static func brewPackage(in packages: [Package], bundlePath: String) -> Package? {
        let me = canonical(bundlePath)
        return packages.first { p in
            isTankardCask(p) && (p.appPaths ?? []).contains { canonical($0) == me }
        }
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
