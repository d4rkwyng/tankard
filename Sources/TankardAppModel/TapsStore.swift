import Foundation
import Observation
import TankardCore

// v0.7: Homebrew ▸ Taps…. The list is `brew tap-info --installed --json`
// (read-only, straight to the runner); `brew tap` and `brew untap` go
// through the queue and the activity sheet's live log, `brew trust --tap`
// and `brew untrust --tap` through the queue as a one-off command. All of
// them land in History. Nothing runs before the user confirms.

/// A tap the user asked to add, waiting for the confirmation.
public struct TapAddRequest: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable {
        case tapsSheet, brewfile
        /// 0.8.5: Discover's "Casks are off" banner (Enable Casks…).
        case discover
    }
    public var name: String
    public var url: String?
    public var source: Source
    public var id: String { name.lowercased() + "|" + (url ?? "") }

    public init(name: String, url: String? = nil, source: Source = .tapsSheet) {
        self.name = name
        self.url = url
        self.source = source
    }

    public var arguments: [String] { TapCommands.tap(name, url: url) }
    public var command: String { BrewCommands.display(arguments) }
    /// Where brew will clone from.
    public var remote: String? { url ?? TapInput.defaultRemote(name) }

    /// The confirmation's text. Official Homebrew taps don't need the warning.
    public var warning: String {
        let isOfficial = name.lowercased().hasPrefix("homebrew/")
        let source = remote ?? name
        if isOfficial { return String(localized: "brew clones \(source) and reads its formulae and casks.") }
        return String(localized: "A third-party tap is code from its author, not from Homebrew: its formulae and casks run Ruby on this Mac when brew loads them, and installs from it run their install steps. Add only taps you trust. brew clones \(source).")
    }
}

/// The Taps sheet's list filter.
public enum TapsFilter: String, CaseIterable, Identifiable, Sendable {
    case all, thirdParty, official
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .thirdParty: return String(localized: "Third-party")
        case .official: return String(localized: "Official")
        }
    }

    public func includes(_ t: TapInfo) -> Bool {
        switch self {
        case .all: return true
        case .thirdParty: return !t.official
        case .official: return t.official
        }
    }
}

@Observable @MainActor
public final class TapsStore {
    public enum Phase: Equatable, Sendable {
        case idle, loading, ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var taps: [TapInfo] = []
    public private(set) var selection: TapInfo.ID?
    public private(set) var filter: TapsFilter = .all
    /// The confirmations. Only one shows at a time.
    public private(set) var pendingAdd: TapAddRequest?
    public private(set) var pendingRemove: TapInfo?
    public private(set) var pendingTrust: TapInfo?

    /// `brew <args>` with the read-only environment (set by AppStore).
    @ObservationIgnored public var run: (@Sendable ([String]) async throws -> ProcessResult)?
    @ObservationIgnored private var loadToken = 0

    public init() {}

    // Every setter drops an unchanged value, so nothing re-renders for nothing.
    func setPhase(_ p: Phase) { if phase != p { phase = p } }
    func setTaps(_ t: [TapInfo]) { if taps != t { taps = t } }
    public func select(_ id: TapInfo.ID?) { if selection != id { selection = id } }
    public func setFilter(_ f: TapsFilter) { if filter != f { filter = f } }

    public var visibleTaps: [TapInfo] { taps.filter { filter.includes($0) } }
    public var selectedTap: TapInfo? { taps.first { $0.id == selection } }

    /// Reads the list. A failure keeps the last list.
    public func load() async {
        guard let run else {
            setPhase(.failed(String(localized: "Homebrew isn't ready yet.")))
            return
        }
        loadToken += 1
        let token = loadToken
        if taps.isEmpty { setPhase(.loading) }
        do {
            let r = try await run(TapCommands.infoArguments)
            guard token == loadToken else { return }
            do {
                setTaps(try TapInfo.decode(r.stdout))
                setPhase(.ready)
            } catch {
                let tail = r.stderrString.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
                setPhase(.failed(tail.isEmpty
                    ? String(localized: "brew tap-info printed something Tankard couldn't read.")
                    : String(localized: "brew tap-info printed something Tankard couldn't read:\n\(tail)")))
            }
        } catch {
            guard token == loadToken else { return }
            setPhase(.failed(String(localized: "Couldn't run brew tap-info: \(String(describing: error))")))
        }
        if let s = selection, !taps.contains(where: { $0.id == s }) { select(nil) }
    }

    /// Validates, then asks for confirmation. Returns the problem instead
    /// when the input isn't a tap name (and URL).
    @discardableResult
    public func requestAdd(name: String, url: String = "", source: TapAddRequest.Source = .tapsSheet) -> TapInput.Problem? {
        switch TapInput.validate(name: name, url: url) {
        case .failure(let p): return p
        case .success(let v):
            let req = TapAddRequest(name: v.name, url: v.url, source: source)
            if pendingAdd != req { pendingAdd = req }
            return nil
        }
    }

    /// Remove…: asks first. Blocked removals never get here (the view
    /// shows the reason), but this checks again.
    public func requestRemove(_ tap: TapInfo, packages: [Package]) -> TapRemoval {
        let check = TapRemoval.check(tap, packages: packages)
        if check.isAllowed, pendingRemove != tap { pendingRemove = tap }
        return check
    }

    public func requestTrust(_ tap: TapInfo) {
        guard !tap.official, pendingTrust != tap else { return }
        pendingTrust = tap
    }

    public func cancelPending() {
        if pendingAdd != nil { pendingAdd = nil }
        if pendingRemove != nil { pendingRemove = nil }
        if pendingTrust != nil { pendingTrust = nil }
    }

    /// Takes the confirmed request (clearing it).
    func takeAdd() -> TapAddRequest? { defer { if pendingAdd != nil { pendingAdd = nil } }; return pendingAdd }
    func takeRemove() -> TapInfo? { defer { if pendingRemove != nil { pendingRemove = nil } }; return pendingRemove }
    func takeTrust() -> TapInfo? { defer { if pendingTrust != nil { pendingTrust = nil } }; return pendingTrust }
}

public extension AppStore {
    /// Points the taps store at this brew (read-only environment).
    @discardableResult
    func prepareTaps() -> Bool {
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return false }
        var env = client.environment(for: detection, readOnly: true)
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let brew = client.installation.brewPath
        let runner = client.runner
        taps.run = { [env] args in try await runner.run(brew, args, environment: env) }
        return true
    }

    /// Homebrew ▸ Taps…: opens the sheet and reads the list.
    func openTaps() {
        prepareTaps()
        if toolSheet != .taps { toolSheet = .taps }
        Task { await taps.load() }
    }

    /// Installed packages that came from `tap`.
    func installedCount(from tap: TapInfo) -> Int { packages.filter { tap.owns($0) }.count }

    /// 0.8.6 (M1): of those, the ones brew can't read.
    func unreadableCount(from tap: TapInfo) -> Int { packages.filter { tap.owns($0) && $0.isUnreadable }.count }

    /// 0.8.6 (M1): installed packages brew can't read (Health, the list).
    public var unreadablePackages: [Package] { packages.filter(\.isUnreadable) }

    /// Clicking a tap: the Installed list, filtered to it ("tap:user/repo"
    /// in the search field, as Show Dependencies does).
    func showInstalled(from tap: TapInfo) {
        if tab != .installed { tab = .installed }
        if filter != .all { filter = .all }
        let q = RelatedSearch.tap(tap.name).query
        if search != q { search = q }
        closeToolSheet()
    }

    /// The confirmed Add: `brew tap` through the queue and the live log.
    /// The open sheet (Taps or Brewfile) closes first; the activity sheet
    /// opens once it has gone.
    func confirmAddTap() {
        guard let req = taps.takeAdd() else { return }
        let p = Self.tapPlaceholder(name: req.name, url: req.url)
        closeToolSheet()
        if req.source == .brewfile { brewfile.dismiss() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            self.startSession(.tap, packages: [p])
        }
    }

    /// The confirmed Remove: `brew untap` (never `--force`), checked again
    /// against what's installed.
    func confirmRemoveTap() {
        guard let tap = taps.takeRemove() else { return }
        if !TapRemoval.check(tap, packages: packages).isAllowed { return }
        let steps = Self.removeTapPlaceholders(tap)
        closeToolSheet()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            self.startSession(.untap, packages: steps)
        }
    }

    /// 0.8.7: Trust Tap… where brew refused a package from an untrusted
    /// tap (the detail pane's "can't be read" box, a failed run's sheet),
    /// after its confirmation: `brew trust --tap`, then the status again
    /// (the package becomes readable) and the Taps list if it was read.
    func trustTap(named tap: String) {
        let args = TapCommands.trust(tap, true)
        Task {
            guard let r = await runQuick(args) else { return }
            if r.failed {
                error = Self.quickError(verb: String(localized: "Trust"), name: tap, args: args, result: r)
                return
            }
            if !taps.taps.isEmpty { await taps.load() }
            // 0.9.4 (bug hunt R3): a read begun after the trust change.
            await refreshAfterChange()
        }
    }

    /// The confirmed Trust / Untrust: one queued command, then a re-read.
    func confirmTrustTap() {
        guard let tap = taps.takeTrust() else { return }
        let trusted = !(tap.trusted ?? false)
        let args = TapCommands.trust(tap.name, trusted)
        Task {
            guard let r = await runQuick(args) else { return }
            await taps.load()
            if r.failed {
                error = Self.quickError(verb: trusted ? String(localized: "Trust") : String(localized: "Untrust"), name: tap.name, args: args, result: r)
                return
            }
            // 0.9.4 (bug hunt): the status again, as Trust Tap… does: a
            // package from the tap becomes readable (or, untrusted, can't
            // be read). The list kept "can't be read", the tap row its
            // count, and Remove stayed blocked until the next Refresh.
            // 0.9.4 (bug hunt R3): a read of its own, begun after the
            // change: joining one already running (begun before it) kept
            // the old readability.
            await refreshAfterChange()
        }
    }

    /// 0.8.5 (L8): Remove's rows: `brew untrust --tap` first for a
    /// third-party tap (TapCommands.remove), then `brew untap`.
    nonisolated static func removeTapPlaceholders(_ tap: TapInfo) -> [Package] {
        var rows: [Package] = []
        if !tap.official {
            var u = tapPlaceholder(name: tap.name, url: nil)
            u.id = "untrust:\(tap.name.lowercased())"
            u.name = "untrust --tap " + tap.name
            rows.append(u)
        }
        rows.append(tapPlaceholder(name: tap.name, url: nil))
        return rows
    }

    /// The session row for a tap command. The URL rides in `desc` (the
    /// row shows `name`); `BrewCommands.arguments` reads both back.
    nonisolated static func tapPlaceholder(name: String, url: String?) -> Package {
        var p = Package.command(name)
        p.id = "tap:\(name.lowercased())"
        p.desc = url
        return p
    }
}
