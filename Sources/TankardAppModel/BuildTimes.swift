import Foundation
import os
import TankardCore

/// Intelbrew's build-time data: how long each formula took on the Intelbrew
/// builder. https://github.com/d4rkwyng/intelbrew-core/releases/download/metadata/build-times.json
///
///   {"schema":1, "generated_at":…, "measured_on":…,
///    "formulae": {"<name>": {"median_seconds", "samples", "last_seconds", "last_version"}}}
public struct IntelbrewBuildTimes: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        public var medianSeconds: Double?
        public var samples: Int?
        public var lastSeconds: Double?
        public var lastVersion: String?

        enum CodingKeys: String, CodingKey {
            case samples
            case medianSeconds = "median_seconds"
            case lastSeconds = "last_seconds"
            case lastVersion = "last_version"
        }
    }

    public var schema: Int
    public var generatedAt: String?
    public var measuredOn: String?
    public var formulae: [String: Entry]

    enum CodingKeys: String, CodingKey {
        case schema, formulae
        case generatedAt = "generated_at"
        case measuredOn = "measured_on"
    }

    /// Upper bound for a believable build time (about 116 days). Anything
    /// at or above it is treated as bad data.
    public static let maxSeconds: Double = 1e7

    /// Seconds for a formula: the median, else the last build. nil when the
    /// formula isn't listed or neither value is usable (missing is never
    /// zero). Usable: finite, > 0 and < `maxSeconds`.
    public func seconds(_ name: String) -> Double? {
        guard let e = formulae[name] else { return nil }
        for s in [e.medianSeconds, e.lastSeconds] {
            if let s, Self.isUsable(s) { return s }
        }
        return nil
    }

    public static func isUsable(_ s: Double) -> Bool {
        s.isFinite && s > 0 && s < maxSeconds
    }
}

/// The second network request Tankard makes, and only in Intelbrew mode:
/// the build-time JSON, fetched when a compile warning is first shown,
/// cached on disk for 24 hours. Any error (including the 404 while the
/// builder replaces the asset each day) means "no new data": the cached
/// copy, if any, stays in use.
public final class BuildTimeSource: BuildTimeEstimating, @unchecked Sendable {
    public static let url = URL(string: "https://github.com/d4rkwyng/intelbrew-core/releases/download/metadata/build-times.json")!
    public static let ttl: TimeInterval = 24 * 3600
    public static let retryAfter: TimeInterval = 3600
    /// Larger responses are rejected (the cache stays). The real file is a
    /// few hundred KB.
    public static let maxBytes = 5_000_000
    /// The whole request, including the download.
    public static let resourceTimeout: TimeInterval = 30

    /// Returns the body and HTTP status.
    public typealias Fetch = @Sendable () async throws -> (Data, Int)

    struct State {
        var table: IntelbrewBuildTimes?
        var fetchedAt: Date?
        var loading: Task<Void, Never>?
        var loadedFromDisk = false
        /// The last fetch attempt (success or not): at most one per hour
        /// while the cache is stale, so a missing asset isn't hammered.
        var lastAttempt: Date?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let fetch: Fetch
    let cacheURL: URL?
    let now: @Sendable () -> Date

    public init(fetch: @escaping Fetch, cacheURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch
        self.cacheURL = cacheURL
        self.now = now
    }

    /// The real thing: an ephemeral URLSession, the cache next to status.json.
    public static func live() -> BuildTimeSource {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = resourceTimeout
        c.timeoutIntervalForResource = resourceTimeout
        c.httpAdditionalHeaders = ["User-Agent": "Tankard/\(TankardVersion.string)"]
        let session = URLSession(configuration: c)
        return BuildTimeSource(fetch: {
            let (data, response) = try await session.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }, cacheURL: StatusCache.defaultURL.deletingLastPathComponent().appendingPathComponent("build-times.json"))
    }

    public var table: IntelbrewBuildTimes? { state.withLockUnchecked { $0.table } }

    public func estimatedSeconds(forFormula name: String) -> Double? {
        table?.seconds(name)
    }

    /// Loads the disk copy, then fetches when it is missing or older than
    /// 24 hours. Concurrent callers share one fetch. Returns when done.
    public func refreshIfNeeded() async {
        loadFromDiskOnce()
        let task: Task<Void, Never>? = state.withLockUnchecked { s in
            if let running = s.loading { return running }
            if let t = s.fetchedAt, now().timeIntervalSince(t) < Self.ttl { return nil }
            if let a = s.lastAttempt, now().timeIntervalSince(a) < Self.retryAfter { return nil }
            s.lastAttempt = now()
            let t = Task { await self.performFetch() }
            s.loading = t
            return t
        }
        await task?.value
    }

    private func performFetch() async {
        defer { state.withLockUnchecked { $0.loading = nil } }
        guard let (data, status) = try? await fetch(), status == 200, let table = Self.decode(data) else {
            return // no data: keep whatever is cached
        }
        let t = now()
        state.withLockUnchecked { s in
            s.table = table
            s.fetchedAt = t
        }
        if let cacheURL {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// A usable table, or nil ("no data"): at most `maxBytes`, schema 1,
    /// and at least one formula. An empty table never replaces a good cache.
    static func decode(_ data: Data) -> IntelbrewBuildTimes? {
        guard data.count <= maxBytes,
              let table = try? JSONDecoder().decode(IntelbrewBuildTimes.self, from: data),
              table.schema == 1, !table.formulae.isEmpty else { return nil }
        return table
    }

    private func loadFromDiskOnce() {
        let first = state.withLockUnchecked { s -> Bool in
            defer { s.loadedFromDisk = true }
            return !s.loadedFromDisk
        }
        guard first, let cacheURL, let data = try? Data(contentsOf: cacheURL), let table = Self.decode(data) else { return }
        let modified = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
        state.withLockUnchecked { s in
            if s.table == nil {
                s.table = table
                s.fetchedAt = modified
            }
        }
    }
}
