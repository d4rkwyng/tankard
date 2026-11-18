import Foundation
import Observation
import TankardCore

/// 0.8.5 (bug hunt M4): why the catalog didn't load, in a sentence. With
/// the network off and no cached catalog, Discover showed the raw NSError
/// (12 lines of `Error Domain=NSPOSIXErrorDomain Code=1 … UserInfo={…}`),
/// while Refresh offline said "Homebrew couldn't reach the network".
public enum CatalogFailure {
    public static func isNetwork(_ error: Error) -> Bool {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
                 .callIsActive, .cannotLoadFromNetwork:
                return true
            default: break
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, [-1009, -1005, -1003, -1004, -1001, -1006, -1018, -1020, -1200, -2000].contains(ns.code) {
            return true
        }
        // EPERM (a firewall or sandbox denying the connection), ENETDOWN,
        // ENETUNREACH, ECONNRESET, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH.
        if ns.domain == NSPOSIXErrorDomain, [1, 50, 51, 54, 60, 61, 64, 65].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isNetwork(underlying) }
        return false
    }

    public static func sentence(_ error: Error, localTaps: Bool) -> String {
        if !localTaps, isNetwork(error) {
            return String(localized: "Tankard couldn't reach the network to download Homebrew's list of packages. Check the internet connection (or a VPN or proxy), then try again.")
        }
        return localTaps ? String(localized: "Tankard couldn't read the packages in your taps. Try again in a moment.")
            : String(localized: "Tankard couldn't load Homebrew's list of packages. Try again in a moment.")
    }
}

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

    /// 0.8: install counts. `unavailable` in Intelbrew mode (formulae.brew.sh
    /// isn't asked there).
    public enum AnalyticsPhase: Equatable, Sendable {
        case idle, loading, ready, unavailable
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// 0.8.5 (bug hunt M4): the error behind `.failed`, as the system gave
    /// it, for the Details disclosure. `.failed` itself carries a sentence.
    public private(set) var failureDetail: String?
    public private(set) var results: [CatalogEntry] = []
    /// The query `results` answer (the field can be ahead while debouncing).
    public private(set) var resultsQuery = ""
    /// 0.8.4: what the header names: `resultsQuery` without a pasted
    /// `brew install …` around it ("wget", not "brew install wget").
    public var resultsTerm: String { PastedCommand.searchTerm(resultsQuery) }
    public private(set) var source = ""
    public private(set) var warning: String?
    public private(set) var casksEnabled = true
    public private(set) var isLocalTaps: Bool
    public private(set) var totalCount = 0
    public private(set) var loadedAt: Date?
    /// Bumped whenever entries change, so views reading `entry(_:)` update.
    public private(set) var revision = 0
    /// 0.8: install counts, loaded after the catalog without blocking it.
    public private(set) var analyticsPhase: AnalyticsPhase = .idle
    public private(set) var analytics: InstallAnalytics?

    public var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    public var kind: CatalogKindFilter = .all {
        didSet { if kind != oldValue { scheduleSearch(immediately: true) } }
    }
    /// 0.3: hide formulae known to compile ("Has Intel bottle" / "Has
    /// bottle"). On by default in Intelbrew mode, off in normal mode.
    public var bottledOnly: Bool {
        didSet { if bottledOnly != oldValue { scheduleSearch(immediately: true) } }
    }
    /// 0.3: the entry whose "Install (compiles)" confirmation is open.
    public var confirmInstall: CatalogEntry.ID?
    /// 0.3: formulae with a bottle for this Mac, of all formulae.
    public private(set) var bottledCount = 0
    public private(set) var formulaCount = 0
    public var selection: CatalogEntry.ID? {
        didSet { if let s = selection { needDetails([s]) } }
    }

    @ObservationIgnored public let provider: CatalogProviding
    @ObservationIgnored public let debounce: Duration
    @ObservationIgnored let ttl: TimeInterval
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored private var all: [CatalogEntry] = []
    @ObservationIgnored private var byID: [String: Int] = [:]
    /// Dependency name (short or tap-qualified full name) → index.
    @ObservationIgnored private var byName: [String: Int] = [:]
    @ObservationIgnored public let classifier: CompileClassifier
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDetails: [String] = []
    @ObservationIgnored private var requestedDetails: Set<String> = []
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var analyticsTask: Task<Void, Never>?
    @ObservationIgnored private var analyticsLoadedAt: Date?
    /// 0.8.6 (VM test M3): the provider's change key the catalog was read at.
    @ObservationIgnored private var loadedKey: String?
    /// 30-day installs by id: search's tie-break within a relevance tier.
    @ObservationIgnored private var popularity: [String: Int] = [:]
    /// How many rows from the top get details right after a search.
    @ObservationIgnored public var prefetch = 30

    public init(provider: CatalogProviding, ttl: TimeInterval = 3600, debounce: Duration = .milliseconds(250),
                now: @escaping @Sendable () -> Date = { Date() }, classifier: CompileClassifier = CompileClassifier(),
                bottledOnly: Bool? = nil) {
        self.provider = provider
        self.classifier = classifier
        self.bottledOnly = bottledOnly ?? provider.isLocalTaps
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
        return String(localized: "Casks aren't enabled: run `brew tap homebrew/cask` (about 620 MB)")
    }

    // MARK: loading

    /// Loads the catalog if it isn't loaded or is older than the TTL.
    /// Returns when loaded.
    public func activate() async {
        defer { loadAnalyticsIfNeeded() }
        if let running = loadTask {
            await running.value
            return
        }
        if phase == .ready, let t = loadedAt, now().timeIntervalSince(t) < ttl {
            // 0.8.6 (VM test M3): a tap added or removed outside Tankard.
            let provider = self.provider
            let key = await Task.detached(priority: .userInitiated) { provider.changeKey() }.value
            guard let key, key != loadedKey, loadTask == nil else { return }
            loadedAt = nil
            return await activate()
        }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// 0.8.5: loads again now, whatever the TTL (a tap was added or removed).
    public func reload() async {
        if let running = loadTask { await running.value }
        loadedAt = nil
        await activate()
    }

    private func performLoad() async {
        if all.isEmpty { phase = .loading }
        let provider = self.provider
        do {
            // The key before the read: a change during it reloads next time.
            let (key, load) = try await Task.detached(priority: .userInitiated) { (provider.changeKey(), try await provider.load()) }.value
            install(load)
            loadedKey = key
            failureDetail = nil
            phase = .ready
            await runSearch()
        } catch {
            // 0.8.5 (M4): a sentence, not the NSError dump; that goes under Details.
            let sentence = CatalogFailure.sentence(error, localTaps: isLocalTaps)
            if all.isEmpty {
                failureDetail = String(describing: error)
                phase = .failed(sentence)
            } else {
                warning = String(localized: "Couldn't reload: \(sentence)")
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
        var names: [String: Int] = [:]
        for (i, e) in all.enumerated() where e.kind == .formula {
            if names[e.fullName] == nil { names[e.fullName] = i }
            if let tap = e.tap, names["\(tap)/\(e.name)"] == nil { names["\(tap)/\(e.name)"] = i }
            if (e.tap == nil || e.tap == "homebrew/core"), names[e.name] == nil { names[e.name] = i }
        }
        byName = names
        let counts = CatalogSearch.bottledCount(all)
        bottledCount = counts.bottled
        formulaCount = counts.formulae
        loadedAt = load.fetchedAt ?? now()
        requestedDetails = []
        revision += 1
    }

    // MARK: install counts (0.8)

    /// The counts for an entry or installed package id; nil until loaded,
    /// and for a package formulae.brew.sh has no installs of.
    public func installCounts(_ id: String) -> InstallCounts? {
        analytics?[id]
    }

    /// Starts loading the counts once the catalog is ready, unless loaded
    /// within the TTL, already loading, or unavailable. Never awaited by
    /// Discover itself.
    func loadAnalyticsIfNeeded() {
        guard phase == .ready, analyticsTask == nil, analyticsPhase != .unavailable else { return }
        if analytics != nil, let t = analyticsLoadedAt, now().timeIntervalSince(t) < ttl { return }
        if analytics == nil { analyticsPhase = .loading }
        analyticsTask = Task { [weak self] in await self?.performAnalyticsLoad() }
    }

    /// Resolves when a running counts load has finished (tests).
    public func waitForAnalytics() async {
        while let t = analyticsTask { await t.value }
    }

    private func performAnalyticsLoad() async {
        let provider = self.provider
        do {
            let loaded = try await Task.detached(priority: .utility) { try await provider.analytics() }.value
            guard let loaded else {
                analyticsPhase = .unavailable
                analyticsTask = nil
                return
            }
            let pop = loaded.popularity
            analytics = loaded
            popularity = pop
            analyticsLoadedAt = now()
            analyticsPhase = .ready
            analyticsTask = nil
            // Re-rank what's on screen with the tie-break.
            if !resultsQuery.isEmpty { await runSearch() }
        } catch {
            if analytics == nil { analyticsPhase = .failed(String(describing: error)) }
            analyticsTask = nil
        }
    }

    // MARK: search

    /// The search running off the main actor (0.8.5: cancelled by the next).
    @ObservationIgnored private var searchWork: Task<[CatalogEntry], Never>?

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
        let q = query, k = kind, entries = all, only = bottledOnly, pop = popularity
        // 0.8.5 (bug hunt L5): the previous search stops when a new one
        // starts (a detached task doesn't follow its caller's cancellation).
        searchWork?.cancel()
        let work = Task.detached(priority: .userInitiated) {
            CatalogSearch.search(q, in: entries, kind: k, preferBottled: true, bottledOnly: only, popularity: pop)
        }
        searchWork = work
        let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !work.isCancelled, q == query, k == kind, only == bottledOnly else { return } // superseded
        results = found
        resultsQuery = q
        if let s = selection, !found.contains(where: { $0.id == s }) { selection = nil }
        needDetails(found.prefix(prefetch).map(\.id))
    }

    // MARK: compile warnings (0.3)

    /// 0.8.6 (H1): the empty search's explanation. Normal mode searches
    /// formulae.brew.sh and the taps already added; a package from any
    /// other tap needs that tap first.
    public func noMatchesDetail(_ query: String) -> String {
        isLocalTaps
            ? String(localized: "Nothing matches “\(query)”.")
            : String(localized: "Nothing matches “\(query)” in Homebrew's main catalog or in the taps you've added. A package from another tap shows here once you add that tap (Homebrew ▸ Taps…).")
    }

    /// "566 of 8,732 bottled"
    public var bottledCountText: String {
        String(localized: "\(bottledCount.formatted()) of \(formulaCount.formatted()) bottled")
    }

    /// The chip's label: "Has Intel bottle" in Intelbrew mode, "Has bottle" otherwise.
    public var bottledChipTitle: String { isLocalTaps ? String(localized: "Has Intel bottle") : String(localized: "Has bottle") }

    public func entry(named name: String) -> CatalogEntry? {
        _ = revision
        return byName[name].map { all[$0] }
    }

    /// Dependencies that installing `e` would also compile (not installed,
    /// no bottle), and names Discover couldn't look up.
    public func dependenciesThatCompile(_ e: CatalogEntry, installedIDs: Set<String>) -> (compiling: [CatalogEntry], unknown: [String]) {
        classifier.dependenciesThatCompile(e, lookup: { self.entry(named: $0) }, isInstalled: { installedIDs.contains($0.id) })
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
