import Foundation
import os
import TankardCore

/// What Discover searches, as one load.
public struct CatalogLoad: Sendable {
    public var entries: [CatalogEntry]
    /// "formulae.brew.sh · 8,733 formulae · 7,832 casks"
    public var source: String
    /// When the data was fetched (API) or read (taps).
    public var fetchedAt: Date?
    /// homebrew/cask is available to search.
    public var casksEnabled: Bool
    /// Something to say above the results that isn't an error (a stale
    /// cache after a failed refresh).
    public var warning: String?

    public init(entries: [CatalogEntry], source: String, fetchedAt: Date? = nil, casksEnabled: Bool = true, warning: String? = nil) {
        self.entries = entries
        self.source = source
        self.fetchedAt = fetchedAt
        self.casksEnabled = casksEnabled
        self.warning = warning
    }
}

/// Where Discover's packages come from: formulae.brew.sh (normal mode) or
/// the local taps plus `brew info` (Intelbrew mode).
public protocol CatalogProviding: Sendable {
    /// The searchable index.
    func load() async throws -> CatalogLoad
    /// Fills in details (version, bottle, licence, deps) for entries that
    /// lack them. Returns the entries it could fill.
    func details(_ entries: [CatalogEntry]) async -> [CatalogEntry]
    /// Intelbrew mode (labels say so).
    var isLocalTaps: Bool { get }
}

// MARK: formulae.brew.sh

/// The on-disk copy of formulae.brew.sh's JSON with its ETag.
/// ~/Library/Caches/net.mindtricks.tankard/api/<name>(.meta.json)
public struct APICache: Sendable {
    public struct Meta: Codable, Sendable, Equatable {
        public var etag: String?
        public var fetchedAt: Date
    }

    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        StatusCache.defaultURL.deletingLastPathComponent().appendingPathComponent("api", isDirectory: true)
    }

    func dataURL(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func metaURL(_ name: String) -> URL { directory.appendingPathComponent(name + ".meta.json") }

    public func load(_ name: String) -> (Data, Meta)? {
        guard let meta = try? Data(contentsOf: metaURL(name)),
              let m = try? StatusReport.jsonDecoder().decode(Meta.self, from: meta),
              let data = try? Data(contentsOf: dataURL(name)) else { return nil }
        return (data, m)
    }

    public func save(_ name: String, data: Data?, meta: Meta) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data { try data.write(to: dataURL(name), options: .atomic) }
        try StatusReport.jsonEncoder().encode(meta).write(to: metaURL(name), options: .atomic)
    }
}

public enum APIFetchOutcome: Equatable, Sendable {
    /// The cache is younger than the TTL: no request made.
    case cacheFresh
    /// 304 Not Modified: the cached copy is current.
    case notModified
    /// 200: new data, saved.
    case downloaded
    /// The request failed; the cached copy (older than the TTL) is used.
    case staleAfterError(String)
}

public enum APIFetchError: Error, CustomStringConvertible {
    case http(Int, String)
    public var description: String {
        switch self {
        case .http(let code, let name): return "formulae.brew.sh answered \(code) for \(name)"
        }
    }
}

/// Fetches formulae.brew.sh/api/<name> with a 1 h TTL and
/// ETag/If-None-Match revalidation. The one network call Tankard makes
/// itself, and only when Discover is opened in normal mode.
public struct APIFetcher: Sendable {
    public static let baseURL = URL(string: "https://formulae.brew.sh/api/")!

    public var session: URLSession
    public var cache: APICache
    public var ttl: TimeInterval
    public var now: @Sendable () -> Date

    public init(session: URLSession = APIFetcher.makeSession(), cache: APICache = APICache(directory: APICache.defaultDirectory),
                ttl: TimeInterval = 3600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.cache = cache
        self.ttl = ttl
        self.now = now
    }

    /// Ephemeral: no cookies, no shared URLCache (Tankard keeps its own
    /// copy and ETag).
    public static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60
        c.httpAdditionalHeaders = ["User-Agent": "Tankard/\(TankardVersion.string)"]
        return URLSession(configuration: c)
    }

    public func fetch(_ name: String) async throws -> (Data, Date, APIFetchOutcome) {
        let cached = cache.load(name)
        if let (data, meta) = cached, now().timeIntervalSince(meta.fetchedAt) < ttl {
            return (data, meta.fetchedAt, .cacheFresh)
        }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(name))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = cached?.1.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (body, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let t = now()
            if status == 304, let (data, meta) = cached {
                try? cache.save(name, data: nil, meta: APICache.Meta(etag: meta.etag, fetchedAt: t))
                return (data, t, .notModified)
            }
            guard status == 200 else { throw APIFetchError.http(status, name) }
            let etag = http?.value(forHTTPHeaderField: "ETag")
            try? cache.save(name, data: body, meta: APICache.Meta(etag: etag, fetchedAt: t))
            return (body, t, .downloaded)
        } catch {
            if let (data, meta) = cached {
                return (data, meta.fetchedAt, .staleAfterError(String(describing: error)))
            }
            throw error
        }
    }
}

/// Discover in normal mode: formula.json and cask.json from formulae.brew.sh.
public final class APICatalog: CatalogProviding {
    public let fetcher: APIFetcher
    public let builder: CatalogBuilder
    /// The last outcome per file (for tests and the status line).
    public let outcomes = OSAllocatedUnfairLock<[String: APIFetchOutcome]>(initialState: [:])

    public init(fetcher: APIFetcher, platform: BottlePlatform) {
        self.fetcher = fetcher
        self.builder = CatalogBuilder(platform: platform, intelbrewMode: false)
    }

    public var isLocalTaps: Bool { false }

    public func load() async throws -> CatalogLoad {
        async let f = fetcher.fetch("formula.json")
        async let c = fetcher.fetch("cask.json")
        let (fData, fDate, fOutcome) = try await f
        let (cData, cDate, cOutcome) = try await c
        outcomes.withLock { $0 = ["formula.json": fOutcome, "cask.json": cOutcome] }
        var load = try Self.build(formulaJSON: fData, caskJSON: cData, builder: builder)
        load.fetchedAt = min(fDate, cDate)
        for case .staleAfterError(let e) in [fOutcome, cOutcome] {
            load.warning = "Couldn't refresh from formulae.brew.sh (\(e)); showing the saved copy."
        }
        return load
    }

    /// Decodes formula.json and cask.json (top-level arrays) into entries.
    public static func build(formulaJSON: Data, caskJSON: Data, builder: CatalogBuilder) throws -> CatalogLoad {
        let formulae = try JSONDecoder().decode([BrewInfoJSON.Formula].self, from: formulaJSON)
        let casks = try JSONDecoder().decode([BrewInfoJSON.Cask].self, from: caskJSON)
        return CatalogLoad(entries: formulae.map(builder.entry) + casks.map(builder.entry),
                           source: "formulae.brew.sh · \(formulae.count.formatted()) formulae · \(casks.count.formatted()) casks",
                           casksEnabled: true)
    }

    public func details(_ entries: [CatalogEntry]) async -> [CatalogEntry] { entries }
}

// MARK: local taps (Intelbrew mode)

public protocol TapIndexing: Sendable {
    func index() -> TapIndex
}

extension TapIndexer: TapIndexing {}

/// Discover in Intelbrew mode: names and descriptions from the tap
/// checkouts, everything else from `brew info --json=v2` in batches for
/// the rows being looked at. formulae.brew.sh is never asked: it describes
/// upstream Homebrew, not the fork this Mac installs from.
public final class TapCatalog: CatalogProviding {
    public let client: BrewClient
    public let env: [String: String]
    public let indexer: TapIndexing
    public let builder: CatalogBuilder
    public let batchSize: Int

    public init(client: BrewClient, detection: IntelbrewDetection, indexer: TapIndexing? = nil, batchSize: Int = 40) {
        self.client = client
        self.env = client.environment(for: detection)
        self.indexer = indexer ?? TapIndexer(repository: client.installation.repository)
        self.builder = CatalogBuilder(platform: client.platform, intelbrewMode: true)
        self.batchSize = batchSize
    }

    public var isLocalTaps: Bool { true }

    public func load() async throws -> CatalogLoad {
        let index = indexer.index()
        let entries = index.entries.map { $0.catalogEntry(builder: builder) }
        let formulae = index.entries.filter { $0.kind == .formula }.count
        let casks = index.entries.count - formulae
        var source = "Local taps (\(index.taps.joined(separator: ", "))) · \(formulae.formatted()) formulae"
        if casks > 0 { source += " · \(casks.formatted()) casks" }
        return CatalogLoad(entries: entries, source: source, fetchedAt: Date(), casksEnabled: index.hasCaskTap)
    }

    public func details(_ entries: [CatalogEntry]) async -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        for kind in [PackageKind.formula, .cask] {
            let wanted = entries.filter { $0.kind == kind && !$0.detailsLoaded }
            var start = 0
            while start < wanted.count {
                let batch = Array(wanted[start..<min(start + batchSize, wanted.count)])
                start += batchSize
                out += await fill(batch, kind: kind)
            }
        }
        return out
    }

    /// One `brew info` for the batch. brew prints no JSON at all when one
    /// name is unknown, so the names it complains about are dropped and the
    /// rest asked again once; anything still unanswered comes back marked
    /// loaded with no details, so it isn't asked for again.
    func fill(_ batch: [CatalogEntry], kind: PackageKind) async -> [CatalogEntry] {
        var names = batch.map(\.qualifiedName)
        for attempt in 0..<2 {
            do {
                let info = try await client.info(names, kind: kind, env: env)
                let built = (kind == .formula ? info.formulae.map(builder.entry) : info.casks.map(builder.entry))
                let byID = Dictionary(built.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                return batch.map { e in
                    if let d = byID[e.id] { return e.merging(d) }
                    var none = e
                    none.detailsLoaded = true
                    return none
                }
            } catch {
                guard attempt == 0, case BrewClientError.commandFailed(_, _, let stderr) = error else { break }
                let bad = Self.unavailableNames(stderr)
                let kept = names.filter { n in !bad.contains { $0 == n || n.hasSuffix("/" + $0) } }
                if kept.isEmpty || kept.count == names.count { break }
                names = kept
            }
        }
        return batch.map { var e = $0; e.detailsLoaded = true; return e }
    }

    /// Names in brew's `No available formula with the name "x"` lines.
    static func unavailableNames(_ stderr: String) -> [String] {
        stderr.split(separator: "\n").compactMap { line in
            guard line.contains("No available") || line.contains("unavailable"),
                  let open = line.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
            let rest = line[line.index(after: open)...]
            guard let close = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
            return String(rest[..<close])
        }
    }
}
