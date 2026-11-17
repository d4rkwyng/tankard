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
    /// The release notes, shortened for the sheet.
    public var notes: String
    /// The release page (Download).
    public var url: URL

    public init(version: String, notes: String, url: URL) {
        self.version = version
        self.notes = notes
        self.url = url
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

    /// The real request: ephemeral session (no cookies, no cache), no
    /// credentials, only GitHub's required User-Agent and Accept headers.
    public static func live() -> UpdateFeed {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.httpAdditionalHeaders = ["User-Agent": "Tankard/\(TankardVersion.string)", "Accept": "application/vnd.github+json"]
        let session = URLSession(configuration: c)
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
        let page = release.html_url.flatMap(URL.init(string:)).flatMap { $0.host == "github.com" ? $0 : nil } ?? releasesPage
        return .available(TankardRelease(version: latest.description, notes: excerpt(release.body ?? ""), url: page))
    }

    /// The notes as plain text: Markdown heading marks and bold dropped,
    /// at most `limit` characters, cut at a line end with "…".
    static func excerpt(_ body: String, limit: Int = 700) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line)
            while l.hasPrefix("#") { l.removeFirst() }
            return l.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        }
        var text = lines.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let cut = head.lastIndex(of: "\n").map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// Is this Tankard the one the d4rkwyng/tap cask installed?
public enum SelfInstall {
    public static func isTankardCask(_ p: Package) -> Bool {
        p.kind == .cask && p.name.lowercased() == "tankard" && p.tap?.lowercased() == "d4rkwyng/tap"
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
