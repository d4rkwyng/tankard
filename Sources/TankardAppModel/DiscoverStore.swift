import Foundation
import Observation
import TankardCore

/// Discover: search every formula and cask, see details, install.
///
/// - The catalog loads when Discover is opened (`activate()`), never at
///   launch, and again only when older than the TTL.
/// - Search is in memory, debounced, ranked by `CatalogSearch`.
/// - In Intelbrew mode rows start with only a name and description;
///   `brew info` fills in the rest in batches for the rows on screen and
///   the selection (`needDetails`).
@Observable @MainActor
public final class DiscoverStore {
    public enum Phase: Equatable, Sendable {
        case idle, loading, ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var results: [CatalogEntry] = []
    /// The query `results` answer (the field can be ahead while debouncing).
    public private(set) var resultsQuery = ""
    public private(set) var source = ""
    public private(set) var warning: String?
    public private(set) var casksEnabled = true
    public private(set) var isLocalTaps: Bool
    public private(set) var totalCount = 0
    public private(set) var loadedAt: Date?
    /// Bumped whenever entries change, so views reading `entry(_:)` update.
    public private(set) var revision = 0

    public var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    public var kind: CatalogKindFilter = .all {
        didSet { if kind != oldValue { scheduleSearch(immediately: true) } }
    }
    public var selection: CatalogEntry.ID? {
        didSet { if let s = selection { needDetails([s]) } }
    }

    @ObservationIgnored public let provider: CatalogProviding
    @ObservationIgnored public let debounce: Duration
    @ObservationIgnored let ttl: TimeInterval
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored private var all: [CatalogEntry] = []
    @ObservationIgnored private var byID: [String: Int] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDetails: [String] = []
    @ObservationIgnored private var requestedDetails: Set<String> = []
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    /// How many rows from the top get details right after a search.
    @ObservationIgnored public var prefetch = 30

    public init(provider: CatalogProviding, ttl: TimeInterval = 3600, debounce: Duration = .milliseconds(250),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.ttl = ttl
        self.debounce = debounce
        self.now = now
        self.isLocalTaps = provider.isLocalTaps
    }

    public var selectedEntry: CatalogEntry? {
        _ = revision
        guard let selection, let i = byID[selection] else { return nil }
        return all[i]
    }

    public func entry(_ id: String) -> CatalogEntry? {
        _ = revision
        return byID[id].map { all[$0] }
    }

    /// Intelbrew mode without homebrew/cask tapped.
    public var casksNotice: String? {
        guard isLocalTaps, phase == .ready, !casksEnabled else { return nil }
        return "Casks aren't enabled: run `brew tap homebrew/cask` (about 620 MB)"
    }

    // MARK: loading

    /// Loads the catalog if it isn't loaded or is older than the TTL.
    /// Returns when loaded.
    public func activate() async {
        if let running = loadTask {
            await running.value
            return
        }
        if phase == .ready, let t = loadedAt, now().timeIntervalSince(t) < ttl { return }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        if all.isEmpty { phase = .loading }
        let provider = self.provider
        do {
            let load = try await Task.detached(priority: .userInitiated) { try await provider.load() }.value
            install(load)
            phase = .ready
            await runSearch()
        } catch {
            if all.isEmpty {
                phase = .failed(String(describing: error))
            } else {
                warning = "Couldn't reload: \(error)"
            }
        }
    }

    private func install(_ load: CatalogLoad) {
        all = load.entries
        byID = Dictionary(all.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        source = load.source
        warning = load.warning
        casksEnabled = load.casksEnabled
        totalCount = load.entries.count
        loadedAt = load.fetchedAt ?? now()
        requestedDetails = []
        revision += 1
    }

    // MARK: search

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        let delay = immediately ? Duration.zero : debounce
        searchTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    /// Searches now (tests and the Return key skip the debounce).
    public func searchNow() async {
        searchTask?.cancel()
        await runSearch()
    }

    private func runSearch() async {
        let q = query, k = kind, entries = all
        let found = await Task.detached(priority: .userInitiated) {
            CatalogSearch.search(q, in: entries, kind: k)
        }.value
        guard q == query, k == kind else { return } // superseded
        results = found
        resultsQuery = q
        if let s = selection, !found.contains(where: { $0.id == s }) { selection = nil }
        needDetails(found.prefix(prefetch).map(\.id))
    }

    // MARK: details (Intelbrew mode)

    /// Asks for details of these entries, coalesced into `brew info` batches.
    public func needDetails(_ ids: [String]) {
        let wanted = ids.filter { id in
            guard let i = byID[id] else { return false }
            return !all[i].detailsLoaded && !requestedDetails.contains(id)
        }
        guard !wanted.isEmpty else { return }
        requestedDetails.formUnion(wanted)
        pendingDetails += wanted
        guard detailsTask == nil else { return }
        detailsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60)) // gather rows appearing together
            await self?.drainDetails()
        }
    }

    /// Resolves when every requested detail batch has come back.
    public func waitForDetails() async {
        while let t = detailsTask { await t.value }
    }

    private func drainDetails() async {
        while !pendingDetails.isEmpty {
            // Selection first, then in request order.
            if let s = selection, let i = pendingDetails.firstIndex(of: s) {
                pendingDetails.remove(at: i)
                pendingDetails.insert(s, at: 0)
            }
            let ids = Array(pendingDetails.prefix(40))
            pendingDetails.removeFirst(ids.count)
            let entries = ids.compactMap { entry($0) }
            let provider = self.provider
            let filled = await Task.detached(priority: .userInitiated) { await provider.details(entries) }.value
            apply(filled)
        }
        detailsTask = nil
    }

    private func apply(_ filled: [CatalogEntry]) {
        var changed: [String: CatalogEntry] = [:]
        for e in filled {
            guard let i = byID[e.id] else { continue }
            all[i] = e
            changed[e.id] = e
        }
        if !changed.isEmpty {
            results = results.map { changed[$0.id] ?? $0 }
            revision += 1
        }
    }
}
