import Foundation
import Observation
import TankardCore

// v0.8: Homebrew ▸ Adopt Apps…. Scans /Applications (and one folder below
// it) and ~/Applications, matches the apps to casks from formulae.brew.sh's
// cask.json (the copy Discover caches), and adopts the chosen ones with
// `brew install --cask --adopt` through the queue and the activity sheet's
// live log. Nothing runs before the user confirms.
//
//   TANKARD_ADOPT=1             any mode: open the sheet (the scan is read-only)
//   TANKARD_DEMO_ADOPT=1        demo: open the sheet on the demo's apps
//   TANKARD_DEMO_ADOPT=confirm  demo: also open the confirmation
//   TANKARD_DEMO_ADOPT=run      demo: also confirm (the fake brew adopts)

/// What the scan reads: the cask index and the apps on disk.
public struct AdoptInput: Sendable {
    public var index: AdoptIndex
    public var apps: [InstalledApp]
    /// "formulae.brew.sh · 7,828 casks", for the sheet's footer.
    public var source: String

    public init(index: AdoptIndex, apps: [InstalledApp], source: String) {
        self.index = index
        self.apps = apps
        self.source = source
    }
}

public typealias AdoptLoader = @Sendable () async throws -> AdoptInput

/// The sheet's four groups.
public enum AdoptGroup: String, CaseIterable, Identifiable, Sendable {
    case ready, needsUpdate, cantAdopt, noCask
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ready: return String(localized: "Ready to adopt")
        case .needsUpdate: return String(localized: "Needs update first")
        case .cantAdopt: return String(localized: "Can't adopt")
        case .noCask: return String(localized: "No cask")
        }
    }

    public var explanation: String {
        switch self {
        case .ready:
            return String(localized: "Homebrew has a cask for these apps and the installed version matches (or the app updates itself, so brew doesn't compare).")
        case .needsUpdate:
            return String(localized: "brew adopts only the exact version the cask installs. Update the app with its own updater, then Scan Again. Tankard doesn't replace the app for you.")
        case .cantAdopt:
            return String(localized: "These match a cask, but brew install --adopt wouldn't take them over.")
        case .noCask:
            return String(localized: "No Homebrew cask installs these apps.")
        }
    }

    public static func of(_ verdict: AdoptVerdict?) -> AdoptGroup {
        switch verdict {
        case .ready?, .readyUnchecked?: return .ready
        case .needsUpdate?: return .needsUpdate
        case .blocked?: return .cantAdopt
        case nil: return .noCask
        }
    }
}

public extension AdoptBlock {
    var text: String {
        switch self {
        case .pkg:
            return String(localized: "This cask runs an installer package, which ignores --adopt: brew would run the installer again, with your password.")
        case .location(let expected):
            return String(localized: "The cask installs to \(expected); brew adopts only an app at that exact place.")
        case .suite(let folder):
            return String(localized: "Part of the \(folder) folder, which the cask installs as a whole; brew would compare every file and refuse if anything differs.")
        case .disabled:
            return String(localized: "Homebrew has disabled this cask.")
        case .noVersion:
            return String(localized: "The app has no version brew can compare.")
        case .symlink:
            return String(localized: "This is a symbolic link, not the app itself. Tankard doesn't adopt links.")
        }
    }
}

public extension AdoptConfidence {
    var title: String {
        switch self {
        case .high: return String(localized: "Sure match")
        case .medium: return String(localized: "Likely match")
        case .low: return String(localized: "Name only")
        }
    }

    var help: String {
        switch self {
        case .high: return String(localized: "The app's bundle id is one the cask names.")
        case .medium: return String(localized: "The vendor matches, but the cask doesn't name this exact bundle id.")
        case .low: return String(localized: "Only the app's name matches. It may be a different app with the same name: check before adopting.")
        }
    }
}

/// One app the user confirmed, ready for the queue.
public struct AdoptPlanItem: Sendable, Equatable, Identifiable {
    public var token: String
    public var qualifiedName: String
    public var appPath: String
    public var appVersion: String?
    public var caskVersion: String
    public var autoUpdates: Bool
    /// After adopting: who updates it (only for self-updating apps).
    public var policy: SelfUpdatePolicy
    /// How sure the match is (a name-only one the user ticked gets a warning).
    public var confidence: AdoptConfidence = .high
    public var id: String { token }

    public var arguments: [String] { AdoptCommands.arguments(qualifiedName: qualifiedName) }
    public var command: String { BrewCommands.display(arguments) }

    /// The session row: the cask, as it will be once adopted.
    public func asPackage() -> Package {
        var p = Package.command(token)
        p.id = "cask:\(qualifiedName)"
        p.kind = .cask
        p.name = token
        p.fullName = token
        p.tap = qualifiedName.split(separator: "/").count == 3 ? qualifiedName.split(separator: "/").prefix(2).joined(separator: "/") : nil
        p.status = .cask
        p.desc = appPath
        p.installedVersion = appVersion ?? ""
        p.currentVersion = caskVersion
        p.autoUpdates = autoUpdates
        return p
    }
}

@Observable @MainActor
public final class AdoptStore {
    public enum Phase: Equatable, Sendable {
        case idle, scanning, ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var scan = AdoptScan()
    public private(set) var source = ""
    @ObservationIgnored public private(set) var index: AdoptIndex?
    /// Rows (app paths) ticked for adoption.
    public private(set) var ticked: Set<String> = []
    /// Rows whose cask the user picked among several.
    public private(set) var chosen: [String: String] = [:]
    /// Self-updating apps: who updates them after adopting.
    public private(set) var policies: [String: SelfUpdatePolicy] = [:]
    /// The confirmation, while it shows.
    public private(set) var pendingConfirm: [AdoptPlanItem]?

    /// Reads the index and the apps (set by AppStore).
    @ObservationIgnored public var loader: AdoptLoader?
    /// What brew already owns (set by AppStore, from the installed casks).
    @ObservationIgnored public var managed: @MainActor (AdoptIndex) -> ManagedApps = { _ in ManagedApps() }
    @ObservationIgnored private var loadToken = 0
    /// The running adoption's self-update choices, saved per app only once
    /// its adopt succeeded (qualified name → policy).
    @ObservationIgnored var policiesToSave: [String: SelfUpdatePolicy] = [:]

    public init() {}

    /// Scans. A failure keeps the last result.
    public func load() async {
        guard let loader else {
            phase = .failed(String(localized: "Homebrew isn't ready yet."))
            return
        }
        loadToken += 1
        let token = loadToken
        phase = .scanning
        do {
            let input = try await loader()
            guard token == loadToken else { return }
            apply(input)
        } catch {
            guard token == loadToken else { return }
            phase = .failed(String(localized: "Couldn't read Homebrew's cask list: \(String(describing: error))"))
        }
    }

    /// Matches `input` (no I/O) and resets the choices to their defaults.
    public func apply(_ input: AdoptInput) {
        index = input.index
        source = input.source
        scan = AdoptMatcher.match(input.apps, index: input.index, managed: managed(input.index))
        chosen = [:]
        policies = [:]
        ticked = Set(scan.rows.filter(defaultTicked).map(\.id))
        pendingConfirm = nil
        phase = .ready
    }

    // MARK: per row

    public func token(_ row: AdoptRow) -> String? { chosen[row.id] ?? row.bestToken }
    public func cask(_ row: AdoptRow) -> AdoptCask? { token(row).flatMap { index?.byToken[$0] } }
    public func verdict(_ row: AdoptRow) -> AdoptVerdict? { token(row).flatMap { row.verdicts[$0] } }
    public func confidence(_ row: AdoptRow) -> AdoptConfidence? { token(row).flatMap { row.confidence[$0] } }
    public func group(_ row: AdoptRow) -> AdoptGroup { AdoptGroup.of(verdict(row)) }
    public func policy(_ row: AdoptRow) -> SelfUpdatePolicy { policies[row.id] ?? .automatic }

    /// Ticked by default: ready and not name-only. For a cask that updates
    /// itself only a sure match (the bundle id): brew adopts those without
    /// comparing versions or files (moved.rb:102), so a wrong match would
    /// succeed, and a later upgrade or uninstall would replace or delete
    /// someone else's app.
    public func defaultTicked(_ row: AdoptRow) -> Bool {
        guard verdict(row) == .ready, let c = confidence(row) else { return false }
        if cask(row)?.autoUpdates == true { return c == .high }
        return c != .low
    }

    /// "Needs update first": the copyable `brew install --cask --force`,
    /// only for a sure match (on a weaker one it could overwrite a
    /// different app with the same name).
    public func offersReplace(_ row: AdoptRow) -> Bool {
        group(row) == .needsUpdate && confidence(row) == .high
    }

    public func rows(_ g: AdoptGroup) -> [AdoptRow] {
        scan.rows.filter { group($0) == g }
            .sorted { $0.app.displayName.localizedStandardCompare($1.app.displayName) == .orderedAscending }
    }

    public func isTicked(_ row: AdoptRow) -> Bool { ticked.contains(row.id) && group(row) == .ready }

    public func setTicked(_ row: AdoptRow, _ on: Bool) {
        guard group(row) == .ready || !on else { return }
        if on { ticked.insert(row.id) } else { ticked.remove(row.id) }
    }

    /// Picks another cask for an app with several (re-applies the default tick).
    public func choose(_ token: String, for row: AdoptRow) {
        guard row.candidates.contains(token), self.token(row) != token else { return }
        chosen[row.id] = token
        if defaultTicked(row) { ticked.insert(row.id) } else { ticked.remove(row.id) }
    }

    public func setPolicy(_ policy: SelfUpdatePolicy, for row: AdoptRow) {
        if policies[row.id] != policy { policies[row.id] = policy }
    }

    // MARK: adopting

    /// The ticked apps, as the queue will run them: one item per cask. A
    /// cask with two apps (two rows) is adopted once; the item names the
    /// first app, takes the weaker confidence and a self-update choice
    /// that isn't automatic.
    public var plan: [AdoptPlanItem] {
        var out: [AdoptPlanItem] = []
        for row in rows(.ready).filter(isTicked) {
            guard let c = cask(row) else { continue }
            let item = AdoptPlanItem(token: c.token, qualifiedName: c.qualifiedName, appPath: row.app.path,
                                     appVersion: row.app.shortVersion, caskVersion: c.version, autoUpdates: c.autoUpdates,
                                     policy: c.autoUpdates ? policy(row) : .automatic,
                                     confidence: confidence(row) ?? .low)
            if let i = out.firstIndex(where: { $0.qualifiedName == item.qualifiedName }) {
                out[i].confidence = min(out[i].confidence, item.confidence)
                if out[i].policy == .automatic { out[i].policy = item.policy }
            } else {
                out.append(item)
            }
        }
        return out
    }

    /// "Adopt N Apps…": the confirmation.
    public func requestAdopt() {
        let p = plan
        guard !p.isEmpty, pendingConfirm != p else { return }
        pendingConfirm = p
    }

    public func cancelConfirm() { if pendingConfirm != nil { pendingConfirm = nil } }

    func takeConfirm() -> [AdoptPlanItem]? {
        defer { if pendingConfirm != nil { pendingConfirm = nil } }
        return pendingConfirm
    }

    /// The confirmation's text: what adopting does. brew compares the
    /// download with the app only for casks that don't update themselves
    /// (moved.rb:102), so it says which apps go without that check, and
    /// warns about name-only matches the user ticked.
    public nonisolated static func confirmationText(_ items: [AdoptPlanItem]) -> String {
        func names(_ xs: [AdoptPlanItem]) -> String {
            xs.map { (($0.appPath as NSString).lastPathComponent as NSString).deletingPathExtension }.formatted(.list(type: .and))
        }
        let unchecked = items.filter(\.autoUpdates)
        let checked = items.filter { !$0.autoUpdates }
        var lines: [String] = []
        let nameOnly = items.filter { $0.confidence == .low }
        if !nameOnly.isEmpty {
            lines.append(String(localized: "Name only: \(names(nameOnly)). Nothing but the name matches, so it may be a different app; if it is, brew upgrade would replace it and uninstalling the cask would delete it."))
        }
        if unchecked.isEmpty {
            lines.append(String(localized: "For each app, brew downloads the cask, checks the download against the app that is there, and then records the cask as installed. The app itself stays where it is."))
        } else {
            lines.append(String(localized: "For each app, brew downloads the cask and records it as installed. The app itself stays where it is."))
            lines.append(String(localized: "Adopted without a version check: \(names(unchecked)). These apps update themselves, so brew doesn't compare the download with the app that is there."))
        }
        lines.append(String(localized: "From then on Homebrew owns these apps: brew upgrade replaces them with the cask's version, and uninstalling the cask (in Tankard or with brew uninstall) deletes the app."))
        if !unchecked.isEmpty {
            lines.append(String(localized: "Apps that update themselves keep doing so. Your choice of who updates each one is saved with the adoption."))
        }
        if unchecked.isEmpty {
            lines.append(String(localized: "If a download doesn't match, brew stops for that app and leaves it as it was."))
        } else if !checked.isEmpty {
            lines.append(String(localized: "The other apps are checked: if a download doesn't match, brew stops for that app and leaves it as it was."))
        }
        return lines.joined(separator: "\n\n")
    }

    /// The confirmation's commands: each one, as the queue runs them (the
    /// first 8, then "and N more").
    public nonisolated static func commandsText(_ items: [AdoptPlanItem]) -> String {
        let shown = items.prefix(8).map(\.command)
        let more = items.count > 8 ? [String(localized: "and \(items.count - 8) more")] : []
        return (items.count == 1 ? "" : "\n") + (shown + more).joined(separator: "\n")
    }

    /// "4 apps, 1 already managed, 2 from the App Store, 3 Apple": the footer.
    public var skippedLine: String {
        let s = scan.skipped
        var parts: [String] = []
        if !s.managed.isEmpty { parts.append(String(localized: "\(s.managed.count) already from Homebrew")) }
        if !s.appStore.isEmpty { parts.append(String(localized: "\(s.appStore.count) from the App Store")) }
        if !s.apple.isEmpty { parts.append(String(localized: "\(s.apple.count) from Apple")) }
        return parts.isEmpty ? "" : String(localized: "Not listed: \(parts.joined(separator: ", ")).")
    }
}

public extension AppStore {
    /// The scan's sources for this brew: the demo's fixture, or the real
    /// cask.json and the real disk. Intelbrew mode (or any brew told not to
    /// use Homebrew's API) has no cask.json to read, so it says so.
    @discardableResult
    func prepareAdopt() -> Bool {
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return false }
        adopt.managed = { [weak self] index in ManagedApps(packages: self?.packages ?? [], index: index) }
        if let custom = deps.adoptLoader {
            adopt.loader = custom
        } else if detection.detected || client.sources.effective(Intelbrew.noAPIKey) != nil {
            adopt.loader = { throw AdoptUnavailable.noAPI }
        } else {
            adopt.loader = Self.liveAdoptLoader(fetcher: APIFetcher())
        }
        return true
    }

    /// cask.json through Discover's cache (1 h, ETag), then the disk scan.
    nonisolated static func liveAdoptLoader(fetcher: APIFetcher) -> AdoptLoader {
        { @Sendable in
            let (data, _, _) = try await fetcher.fetch("cask.json")
            let index = try AdoptIndex.decode(caskJSON: data)
            let apps = AppScanner.scan()
            return AdoptInput(index: index, apps: apps,
                              source: String(localized: "formulae.brew.sh · \(index.count.formatted()) casks"))
        }
    }

    /// Homebrew ▸ Adopt Apps…: opens the sheet and scans.
    func openAdopt() {
        prepareAdopt()
        if toolSheet != .adopt { toolSheet = .adopt }
        Task { await adopt.load() }
    }

    /// The confirmed adoption: `brew install --cask --adopt` per app
    /// through the queue and the live log; each self-update choice is
    /// saved once that app's adopt has succeeded. The sheet closes first; the activity sheet opens once it
    /// has gone. A refresh follows the run (as after any session).
    func confirmAdopt() {
        guard let items = adopt.takeConfirm() else { return }
        closeToolSheet()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            // Something took brew in the gap (an automatic update): say so,
            // so the confirmed click isn't silently lost.
            if !self.startAdopt(items) {
                let what = items.count == 1 ? items[0].command : String(localized: "Adopt Apps…")
                self.showBusyNotice(Self.notStartedNotice(what, running: self.quickAction,
                                                          upgrading: self.isUpgrading || self.autoUpdate.isRunning))
            }
        }
    }

    /// The run itself, without the sheet (for a scripted real run). Returns
    /// false when it couldn't start (brew busy or not ready).
    @discardableResult
    func startAdopt(_ items: [AdoptPlanItem]) -> Bool {
        guard !items.isEmpty, !isUpgrading, !autoUpdate.isRunning, report != nil else { return false }
        startSession(.adopt, packages: items.map { $0.asPackage() })
        // 0.8.1: or waiting on the App Management explainer (it runs after).
        guard isUpgrading || appManagementPrompt?.action == .adopt else { return false }
        adopt.policiesToSave = Dictionary(items.filter { $0.autoUpdates && $0.policy != .automatic }.map { ($0.qualifiedName, $0.policy) },
                                          uniquingKeysWith: { $1 })
        return true
    }

    /// After an adopt session: the self-update choices of the apps it adopted
    /// (a failed or skipped adopt saves nothing).
    func adoptSessionFinished(_ session: UpgradeSession) {
        let policies = adopt.policiesToSave
        adopt.policiesToSave = [:]
        for item in session.items where item.state == .done {
            let key = SelfUpdateRule.key(item.package)
            if let policy = policies[key] { upgradeRules.setSelfUpdatePolicy(key, policy) }
        }
        // 0.8.1: macOS blocked some (App Management): their choices stay for
        // the retry, here or after a relaunch.
        let blocked = Set(session.blockedPackages.map(SelfUpdateRule.key))
        adopt.policiesToSave = policies.filter { blocked.contains($0.key) }
    }
}

public enum AdoptUnavailable: Error, CustomStringConvertible {
    case noAPI
    public var description: String {
        switch self {
        case .noAPI:
            return String(localized: "Adopt Apps reads Homebrew's cask list from formulae.brew.sh, which Tankard doesn't use with this Homebrew (Intelbrew, or HOMEBREW_NO_INSTALL_FROM_API).")
        }
    }
}
