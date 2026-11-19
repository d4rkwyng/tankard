import CoreGraphics
import CryptoKit
import Foundation
import Observation
import os
import TankardCore

// v0.3: the menu-bar extra, background checks and their notifications.

/// What the menu-bar icon and its menu show. Built from the same store (and
/// so the same cache) as the window.
public struct MenuBarSummary: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// "3.15.1 → 3.15.2"; 0.8.4: shortened (`MenuBarSummary.versionPair`).
        public var versions: String
        /// 0.8.4: both versions in full, for the tooltip.
        public var fullVersions: String = ""
        /// 0.8.8: `versions` in its two halves, so the panel can cut the
        /// old version and keep the new one whole ("3.15.1", "3.15.2").
        public var from: String {
            versions.components(separatedBy: " → ").first ?? versions
        }
        public var to: String {
            let parts = versions.components(separatedBy: " → ")
            return parts.count > 1 ? parts.dropFirst().joined(separator: " → ") : ""
        }
        public var compiles: Bool
        public var isCask: Bool
    }

    /// How many rows the menu lists before "and N more…" (0.5: 8, was 12).
    public static let maxRows = 8
    /// The largest count the badge spells out; above it, "99+".
    public static let maxBadge = 99

    public var count: Int
    public var rows: [Row]
    /// Upgrades not listed (beyond `maxRows`).
    public var moreCount: Int
    /// Whether any data has been read yet (cache or brew).
    public var hasData: Bool

    public init(packages: [Package]?, classifier: CompileClassifier = CompileClassifier()) {
        // Pinned packages aren't upgraded (0.4), so they aren't counted;
        // self-updating casks are, when that setting listed them.
        let up = (packages ?? []).filter(\.isUpgradeTarget).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        hasData = packages != nil
        count = up.count
        rows = up.prefix(Self.maxRows).map { p in
            Row(id: p.id, name: p.name, versions: Self.versionPair(p.installedVersion, p.currentVersion),
                fullVersions: "\(p.installedVersion) → \(p.currentVersion ?? "?")",
                compiles: classifier.upgradeMethod(p).compiles, isCask: p.kind == .cask)
        }
        moreCount = max(0, up.count - Self.maxRows)
    }

    /// 0.8.4: "3.29.15 → 3.30.14" for cursor's "3.29.15,86776fcb…" →
    /// "3.30.14,5f54c817…": a cask version's ",<build or hash>" suffix is
    /// dropped (the panel cut the line from the front and showed only the
    /// hash's tail), unless the versions differ only there; a bare commit
    /// hash is shortened to 7 characters, as git does.
    public static func versionPair(_ installed: String, _ current: String?) -> String {
        let a = split(installed), b = split(current ?? "?")
        if a.main == b.main && a.build != b.build {
            func full(_ v: (main: String, build: String?)) -> String { v.build.map { "\(v.main) (\($0))" } ?? v.main }
            return "\(full(a)) → \(full(b))"
        }
        return "\(a.main) → \(b.main)"
    }

    /// "3.30.14,5f54c8173e55…" → ("3.30.14", "5f54c81"); hashes shortened.
    static func split(_ v: String) -> (main: String, build: String?) {
        let parts = v.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let main = shortHash(parts[0])
        guard parts.count > 1, !main.isEmpty else { return (main.isEmpty ? v : main, nil) }
        return (main, shortHash(parts[1]))
    }

    /// A commit hash (12+ hex digits, at least one a-f) as its first 7;
    /// anything else as is. All digits is a build number or a timestamp
    /// ("202411081530"), not a hash: cut to 7, two builds of the same day
    /// would read the same.
    static func shortHash(_ s: String) -> String {
        s.count >= 12 && s.allSatisfy(\.isHexDigit) && !s.allSatisfy(\.isNumber) ? String(s.prefix(7)) : s
    }

    /// "5 upgrades ready", "1 upgrade ready", "Everything is up to date",
    /// or "No data yet".
    public var title: String {
        guard hasData else { return String(localized: "No data yet") }
        if count == 0 { return String(localized: "Everything is up to date") }
        return count == 1 ? String(localized: "\(count) upgrade ready") : String(localized: "\(count) upgrades ready")
    }

    /// The number next to the mug; nil (icon only) when there are none,
    /// "99+" above 99 so the menu bar item stays narrow.
    public var badge: String? {
        guard count > 0 else { return nil }
        return count > Self.maxBadge ? "\(Self.maxBadge)+" : "\(count)"
    }

    /// 0.8.6: what the menu-bar item shows: the full or empty tankard, and
    /// the count unless Settings turned it off (it stays in the tooltip,
    /// `title`, and the panel).
    public struct Label: Equatable, Sendable {
        public var full: Bool
        public var badge: String?
    }

    public func label(showCount: Bool) -> Label {
        Label(full: count > 0, badge: showCount ? badge : nil)
    }

    /// "and 3 more…" under the rows; nil when every upgrade is listed.
    public var moreText: String? { moreCount > 0 ? String(localized: "and \(moreCount) more…") : nil }

    /// 0.5: "Tankard 0.6.0 available" when brew lists an upgrade for
    /// Tankard's own cask (the status read already has it). Tankard never
    /// upgrades itself; that stays with brew.
    public static func selfUpdateLine(_ packages: [Package]?) -> String? {
        guard let p = packages?.first(where: { AutoUpdateSafeMode.isTankard($0) && $0.upgradeAvailable }) else { return nil }
        if let v = p.currentVersion { return String(localized: "Tankard \(v) available") }
        return String(localized: "Tankard update available")
    }
}

/// Decides whether a background check should post a notification: only
/// when upgrades appear that weren't in the last set seen. A set that only
/// shrinks (something was upgraded) posts nothing.
public enum UpgradeNotificationDiff {
    /// One key per upgrade: the package and the version it would go to,
    /// so a newer version of an already-known upgrade counts as new.
    public static func keys(_ packages: [Package]) -> Set<String> {
        Set(packages.filter(\.isUpgradeTarget).map { "\($0.id)@\($0.currentVersion ?? "")" })
    }

    public struct Message: Equatable, Sendable {
        public var title: String
        public var body: String
        /// The new keys (for tests and the notification's identifier).
        public var newKeys: Set<String>
        /// 0.8.3: what a click opens (NotificationRoute). Upgrades ready
        /// notifications also get the Upgrade All… / Later actions.
        public var kind: Kind = .upgrades

        public enum Kind: String, Sendable {
            case upgrades, autoUpdate
            /// 0.8.5: a progress panel's upgrade finished (opens History).
            case upgradeDone
            /// 0.8.5 (review): a hidden progress panel's run finished with
            /// problems or notes (opens the results).
            case upgradeResults
        }

        /// "upgrades-<sha256 of the sorted keys>": the same set gives the
        /// same id in every launch, so the system replaces rather than
        /// stacks a repeat.
        public var identifier: String {
            let digest = SHA256.hash(data: Data(newKeys.sorted().joined(separator: "\n").utf8))
            return "upgrades-" + digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// nil = post nothing. `previous == nil` is the first check after
    /// notifications were turned on: it only records the baseline.
    public static func decide(previous: Set<String>?, current: Set<String>, packages: [Package]) -> Message? {
        guard let previous else { return nil }
        let added = current.subtracting(previous)
        guard !added.isEmpty else { return nil }
        let names = packages.filter { added.contains("\($0.id)@\($0.currentVersion ?? "")") }.map(\.name).sorted()
        let total = current.count
        let title = total == 1 ? String(localized: "\(total) upgrade ready") : String(localized: "\(total) upgrades ready")
        let shown = names.prefix(4).joined(separator: ", ")
        let body = names.count > 4
            ? String(localized: "New: \(shown) and \(names.count - 4) more")
            : String(localized: "New: \(shown)")
        return Message(title: title, body: body, newKeys: added)
    }
}

/// When the next background check runs.
public struct BackgroundSchedule: Equatable, Sendable {
    public static let allowedHours = 1...48
    public static let defaultHours = 6
    /// No check sooner than this after launch (let the window's own read finish).
    public static let startupDelay: TimeInterval = 120
    /// When the queue is busy (an upgrade is running), try again after this.
    public static let busyRetry: TimeInterval = 15 * 60

    public var intervalHours: Int

    public init(intervalHours: Int) {
        self.intervalHours = min(max(intervalHours, Self.allowedHours.lowerBound), Self.allowedHours.upperBound)
    }

    public var interval: TimeInterval { TimeInterval(intervalHours) * 3600 }

    /// The last check plus the interval, but never before `launchedAt` plus
    /// the startup delay. No last check: as soon as the startup delay allows.
    /// A check missed while the Mac slept runs as soon as it wakes.
    public func nextCheck(lastCheck: Date?, launchedAt: Date) -> Date {
        let earliest = launchedAt.addingTimeInterval(Self.startupDelay)
        guard let lastCheck else { return earliest }
        return max(lastCheck.addingTimeInterval(interval), earliest)
    }

    public func isDue(lastCheck: Date?, launchedAt: Date, now: Date) -> Bool {
        nextCheck(lastCheck: lastCheck, launchedAt: launchedAt) <= now
    }
}

/// v0.3 settings, in UserDefaults next to `appearance`.
@Observable @MainActor
public final class AppSettings {
    enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let notifyNewUpgrades = "notifyNewUpgrades"
        static let checkIntervalHours = "checkIntervalHours"
        static let notifiedUpgrades = "notifiedUpgrades"
        static let lastBackgroundCheck = "lastBackgroundCheck"
        static let appManagementExplained = "appManagementExplained"
        static let backgroundUpdate = "backgroundUpdate"
        static let lastBrewUpdate = "lastBrewUpdate"
        static let appManagementPendingRetry = "appManagementPendingRetry"
        static let onboardingDone = "onboardingDone"
        static let hideDockIconWhenClosed = "hideDockIconWhenClosed"
        static let notifyHintShown = "notifyHintShown"
        static let casksBannerHidden = "casksBannerHidden"
        static let showMenuBarCount = "showMenuBarCount"
    }

    @ObservationIgnored public let defaults: UserDefaults

    /// The mug in the menu bar. Default on.
    ///
    /// Writing the value it already has does nothing, and in particular does
    /// not notify observers. 0.3.0 crashed at launch without this: SwiftUI
    /// writes `MenuBarExtra(isInserted:)`'s binding back with the same value
    /// while it builds the scenes, App.body reads this property, and
    /// @Observable notifies on every write, equal or not, so each write
    /// re-ran App.body, which wrote it again (a loop until the stack ran out).
    public var showMenuBarIcon: Bool {
        get {
            access(keyPath: \.showMenuBarIcon)
            return _showMenuBarIcon
        }
        set {
            guard newValue != _showMenuBarIcon else { return }
            withMutation(keyPath: \.showMenuBarIcon) { _showMenuBarIcon = newValue }
            defaults.set(newValue, forKey: Key.showMenuBarIcon)
        }
    }
    @ObservationIgnored private var _showMenuBarIcon: Bool
    /// Background `brew update` + a notification when new upgrades appear.
    /// Default off (opt-in): it is the only thing Tankard does on its own.
    public var notifyNewUpgrades: Bool {
        didSet {
            defaults.set(notifyNewUpgrades, forKey: Key.notifyNewUpgrades)
            // Turning it on starts from a fresh baseline (turning it off
            // keeps the set; runCheck checks the toggle before posting).
            if notifyNewUpgrades && !oldValue { notifiedUpgrades = nil }
        }
    }
    /// Hours between background checks (1–48). Default 6.
    public var checkIntervalHours: Int {
        didSet {
            let c = BackgroundSchedule(intervalHours: checkIntervalHours).intervalHours
            if c != checkIntervalHours { checkIntervalHours = c; return }
            defaults.set(c, forKey: Key.checkIntervalHours)
        }
    }
    /// The upgrade keys the last background check saw (nil: no baseline yet).
    public var notifiedUpgrades: Set<String>? {
        didSet { defaults.set(notifiedUpgrades.map { Array($0).sorted() }, forKey: Key.notifiedUpgrades) }
    }
    public var lastBackgroundCheck: Date? { didSet { defaults.set(lastBackgroundCheck, forKey: Key.lastBackgroundCheck) } }
    /// The App Management explainer was shown and dismissed once.
    public var appManagementExplained: Bool { didSet { defaults.set(appManagementExplained, forKey: Key.appManagementExplained) } }
    /// 0.8: `brew update` in the background, at most once per check
    /// interval, so the upgrade counts are fresh. Default on.
    public var backgroundUpdate: Bool {
        didSet { if backgroundUpdate != oldValue { defaults.set(backgroundUpdate, forKey: Key.backgroundUpdate) } }
    }
    /// 0.8: when a `brew update` Tankard ran last succeeded (any of them:
    /// the Refresh button, a background check, auto-update).
    public var lastBrewUpdate: Date? { didSet { defaults.set(lastBrewUpdate, forKey: Key.lastBrewUpdate) } }
    /// 0.8.1: the operation to run again after "Relaunch Tankard"
    /// (`AppManagementPendingRetry`, JSON). Read once at the next launch.
    public var appManagementPendingRetry: Data? {
        didSet { defaults.set(appManagementPendingRetry, forKey: Key.appManagementPendingRetry) }
    }
    /// 0.8.1: the first-launch welcome sheet was closed.
    public var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: Key.onboardingDone) } }
    /// 0.8.1: no Dock icon while every window is closed (needs the menu-bar
    /// icon; see DockIconPolicy). Default on. Only a real change is written.
    public var hideDockIconWhenClosed: Bool {
        didSet { if hideDockIconWhenClosed != oldValue { defaults.set(hideDockIconWhenClosed, forKey: Key.hideDockIconWhenClosed) } }
    }

    /// 0.8.2: the "Turn on notifications…" hint after a Refresh was shown once.
    public var notifyHintShown: Bool { didSet { defaults.set(notifyHintShown, forKey: Key.notifyHintShown) } }
    /// 0.8.5: Discover's "Casks are off" banner was closed (CasksBanner).
    public var casksBannerHidden: Bool {
        didSet { if casksBannerHidden != oldValue { defaults.set(casksBannerHidden, forKey: Key.casksBannerHidden) } }
    }

    /// 0.8.6: the number of upgrades next to the menu-bar icon. Default on.
    public var showMenuBarCount: Bool {
        didSet { if showMenuBarCount != oldValue { defaults.set(showMenuBarCount, forKey: Key.showMenuBarCount) } }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showMenuBarCount = defaults.object(forKey: Key.showMenuBarCount) as? Bool ?? true
        _showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        notifyNewUpgrades = defaults.bool(forKey: Key.notifyNewUpgrades)
        let h = defaults.integer(forKey: Key.checkIntervalHours)
        checkIntervalHours = BackgroundSchedule(intervalHours: h == 0 ? BackgroundSchedule.defaultHours : h).intervalHours
        notifiedUpgrades = (defaults.array(forKey: Key.notifiedUpgrades) as? [String]).map(Set.init)
        lastBackgroundCheck = defaults.object(forKey: Key.lastBackgroundCheck) as? Date
        appManagementExplained = defaults.bool(forKey: Key.appManagementExplained)
        backgroundUpdate = defaults.object(forKey: Key.backgroundUpdate) as? Bool ?? true
        lastBrewUpdate = defaults.object(forKey: Key.lastBrewUpdate) as? Date
        appManagementPendingRetry = defaults.data(forKey: Key.appManagementPendingRetry)
        onboardingDone = defaults.bool(forKey: Key.onboardingDone)
        hideDockIconWhenClosed = defaults.object(forKey: Key.hideDockIconWhenClosed) as? Bool ?? true
        notifyHintShown = defaults.bool(forKey: Key.notifyHintShown)
        casksBannerHidden = defaults.bool(forKey: Key.casksBannerHidden)
    }

    /// Settings that persist nowhere real (tests, demo mode): a private
    /// suite, emptied first.
    public static func ephemeral(_ name: String = "net.mindtricks.tankard.ephemeral") -> AppSettings {
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return AppSettings(defaults: d)
    }
}

/// Posts user notifications. The app uses UNUserNotificationCenter; tests a fake.
@MainActor
public protocol UpgradeNotifying: AnyObject {
    /// Asks for permission (only called when the user turns notifications on).
    func requestAuthorization() async -> Bool
    func post(_ message: UpgradeNotificationDiff.Message)
}

/// Launch at login (SMAppService.mainApp in the app; a fake in tests).
@MainActor
public protocol LoginItemControlling: AnyObject {
    var isEnabled: Bool { get }
    /// A sentence when the system needs the user to approve it in System
    /// Settings, or the registration failed.
    var statusNote: String? { get }
    func setEnabled(_ on: Bool) throws
}

/// Runs `brew update` and re-reads status every N hours while notifications
/// are on, then posts a notification when the set of upgrades grows.
@MainActor
public final class BackgroundChecker {
    public let store: AppStore
    public let settings: AppSettings
    public let notifier: UpgradeNotifying?
    public let launchedAt: Date
    let now: @Sendable () -> Date
    private var loop: Task<Void, Never>?

    public init(store: AppStore, settings: AppSettings, notifier: UpgradeNotifying?,
                launchedAt: Date = Date(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.settings = settings
        self.notifier = notifier
        self.launchedAt = launchedAt
        self.now = now
    }

    /// Starts the timer loop. It wakes at least every 5 minutes, so a
    /// changed interval or toggle takes effect without a restart.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.tick()
                try? await Task.sleep(for: .seconds(max(5, min(wait, 300))))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One step of the shared timer (0.3 notifications, 0.5 automatic
    /// updates): runs whatever is due. Returns seconds until the next look.
    /// With both off it just looks again in 5 minutes.
    @discardableResult
    public func tick() async -> TimeInterval {
        // 0.8.3: the bundle was replaced; the relaunched app checks.
        if store.selfReplaced { return 300 }
        // 0.8.5: nothing scheduled starts while the Mac sleeps (or is going
        // to), while macOS says there is no network, or in the settle delay
        // after a wake or the network coming back. Whatever is due then runs
        // once (each policy runs a missed slot or interval once, not per miss).
        let gate = store.system.gate(now: now())
        if gate != .open {
            LaunchTiming.note("scheduled checks wait: \(gate)")
            return store.system.retry(now: now())
        }
        var waits: [TimeInterval] = []
        if store.autoUpdate.settings.enabled {
            let (wait, ran) = await autoUpdateStep()
            // A run just did brew update and re-read: leave the notification
            // check for the next tick rather than run brew update again.
            if ran { return wait }
            waits.append(wait)
        }
        if store.deps.backgroundUpdates {
            let (wait, attempted, updated) = await backgroundUpdateStep()
            waits.append(wait)
            // That update was the notification check's brew update too.
            if updated, settings.notifyNewUpgrades {
                settings.lastBackgroundCheck = now()
                postIfNewUpgrades()
            }
            // 0.8.5: it didn't finish (offline, brew busy, slept): no second
            // `brew update` right behind it from the notification check
            // (Derek's History: a lock failure 0.2 s after each network one).
            if attempted && !updated { return waits.min() ?? 300 }
        }
        if settings.notifyNewUpgrades { waits.append(await notificationStep()) }
        return waits.min() ?? 300
    }

    /// 0.8: the throttled background `brew update`. Returns the wait and
    /// whether an update ran and the list was re-read.
    private func backgroundUpdateStep() async -> (TimeInterval, attempted: Bool, updated: Bool) {
        let t = now()
        let decision = store.backgroundUpdateDecision(launchedAt: launchedAt, now: t)
        LaunchTiming.note("background update: \(decision)")
        switch decision {
        case .off, .optedOut: return (300, false, false)
        case .notDue(let next): return (max(1, next.timeIntervalSince(t)), false, false)
        case .waiting(let retry): return (retry, false, false)
        case .run:
            let ok = await store.runBackgroundUpdate()
            if !ok, store.lastBackgroundUpdateFailure != nil {
                // Look again when the retry is due (the policy has the time).
                let next = store.backgroundUpdateDecision(launchedAt: launchedAt, now: now())
                if case .notDue(let at) = next { return (max(5, at.timeIntervalSince(now())), true, false) }
                return (BackgroundUpdatePolicy.busyRetry, true, false)
            }
            return (store.deps.backgroundUpdateInterval ?? BackgroundSchedule(intervalHours: settings.checkIntervalHours).interval, true, ok)
        }
    }

    /// The 0.3 check: due by its interval.
    private func notificationStep() async -> TimeInterval {
        let schedule = BackgroundSchedule(intervalHours: settings.checkIntervalHours)
        let t = now()
        let next = schedule.nextCheck(lastCheck: settings.lastBackgroundCheck, launchedAt: launchedAt)
        guard next <= t else { return next.timeIntervalSince(t) }
        guard !store.isBusy, !store.isRefreshing, !store.homebrewState.needsWelcome else { return BackgroundSchedule.busyRetry }
        await runCheck()
        return schedule.interval
    }

    /// 0.5: an automatic update, when AutoUpdatePolicy says so.
    private func autoUpdateStep() async -> (TimeInterval, Bool) {
        let t = now()
        store.autoUpdate.checkPause(store: store)
        switch store.autoUpdate.decide(store: store, launchedAt: launchedAt, now: t) {
        case .off: return (300, false)
        case .snoozed: return (300, false)
        case .notDue(let next): return (max(5, next.timeIntervalSince(t)), false)
        case .waiting(_, let retry): return (retry, false)
        case .run:
            await store.autoUpdate.run(store: store, notifier: notifier, now: { [now] in now() })
            return (AutoUpdatePolicy.recheck, true)
        }
    }

    /// `brew update` (through the queue), re-read, compare, maybe notify.
    public func runCheck() async {
        // 0.8.5: a scheduled refresh: time limit, sleep, quiet "try later".
        await store.refresh(.scheduled)
        settings.lastBackgroundCheck = now()
        if store.lastScheduledUpdate?.quiet != nil { return } // keep the old baseline
        guard store.report != nil, store.error == nil else { return } // keep the old baseline on failure
        postIfNewUpgrades()
    }

    /// Compares the upgrades on screen with the last set seen; posts when
    /// new ones appeared.
    func postIfNewUpgrades() {
        // Turned off while brew update ran: post nothing, keep no baseline.
        guard settings.notifyNewUpgrades else { return }
        let keys = UpgradeNotificationDiff.keys(store.packages)
        let message = UpgradeNotificationDiff.decide(previous: settings.notifiedUpgrades, current: keys, packages: store.packages)
        AppStore.notificationLog.notice("background check: \(keys.count, privacy: .public) upgrades, baseline=\(self.settings.notifiedUpgrades?.count ?? -1, privacy: .public), post=\(message != nil, privacy: .public)")
        if let message { notifier?.post(message) }
        settings.notifiedUpgrades = keys
    }
}

/// 0.8.4: the menu-bar panel's frame once its content is `fitting` points
/// tall: nil unless that is shorter than the window's content now (SwiftUI
/// grows the window itself); the top edge stays where it is (AppKit's
/// origin is the bottom-left corner), so the panel stays under the menu bar.
public enum MenuBarPanelFrame {
    public static func shrunk(frame: CGRect, contentHeight: CGFloat, fitting: CGFloat) -> CGRect? {
        guard fitting > 1, contentHeight - fitting > 0.5 else { return nil }
        let delta = contentHeight - fitting
        return CGRect(x: frame.minX, y: frame.minY + delta, width: frame.width, height: frame.height - delta)
    }
}
