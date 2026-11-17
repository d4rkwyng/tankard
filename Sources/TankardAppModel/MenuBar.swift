import CryptoKit
import Foundation
import Observation
import TankardCore

// v0.3: the menu-bar extra, background checks and their notifications.

/// What the menu-bar icon and its menu show. Built from the same store (and
/// so the same cache) as the window.
public struct MenuBarSummary: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// "3.15.1 → 3.15.2"
        public var versions: String
        public var compiles: Bool
        public var isCask: Bool
    }

    /// How many rows the menu lists before "and N more".
    public static let maxRows = 12

    public var count: Int
    public var rows: [Row]
    /// Upgrades not listed (beyond `maxRows`).
    public var moreCount: Int
    /// Whether any data has been read yet (cache or brew).
    public var hasData: Bool

    public init(packages: [Package]?, classifier: CompileClassifier = CompileClassifier()) {
        // Pinned packages aren't upgraded (0.4), so they aren't counted.
        let up = (packages ?? []).filter { $0.upgradeAvailable && !$0.pinned }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        hasData = packages != nil
        count = up.count
        rows = up.prefix(Self.maxRows).map { p in
            Row(id: p.id, name: p.name, versions: "\(p.installedVersion) → \(p.currentVersion ?? "?")",
                compiles: classifier.upgradeMethod(p).compiles, isCask: p.kind == .cask)
        }
        moreCount = max(0, up.count - Self.maxRows)
    }

    /// "5 upgrades ready", "1 upgrade ready", "Everything is up to date",
    /// or "No data yet".
    public var title: String {
        guard hasData else { return "No data yet" }
        if count == 0 { return "Everything is up to date" }
        return "\(count) upgrade\(count == 1 ? "" : "s") ready"
    }

    /// The number next to the mug; nil (icon only) when there are none.
    public var badge: String? { count > 0 ? "\(count)" : nil }
}

/// Decides whether a background check should post a notification: only
/// when upgrades appear that weren't in the last set seen. A set that only
/// shrinks (something was upgraded) posts nothing.
public enum UpgradeNotificationDiff {
    /// One key per upgrade: the package and the version it would go to,
    /// so a newer version of an already-known upgrade counts as new.
    public static func keys(_ packages: [Package]) -> Set<String> {
        Set(packages.filter { $0.upgradeAvailable && !$0.pinned }.map { "\($0.id)@\($0.currentVersion ?? "")" })
    }

    public struct Message: Equatable, Sendable {
        public var title: String
        public var body: String
        /// The new keys (for tests and the notification's identifier).
        public var newKeys: Set<String>

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
        let title = "\(total) upgrade\(total == 1 ? "" : "s") ready"
        let shown = names.prefix(4).joined(separator: ", ")
        let more = names.count > 4 ? " and \(names.count - 4) more" : ""
        let body = "New: \(shown)\(more)"
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
    }

    @ObservationIgnored public let defaults: UserDefaults

    /// The mug in the menu bar. Default on.
    public var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        notifyNewUpgrades = defaults.bool(forKey: Key.notifyNewUpgrades)
        let h = defaults.integer(forKey: Key.checkIntervalHours)
        checkIntervalHours = BackgroundSchedule(intervalHours: h == 0 ? BackgroundSchedule.defaultHours : h).intervalHours
        notifiedUpgrades = (defaults.array(forKey: Key.notifiedUpgrades) as? [String]).map(Set.init)
        lastBackgroundCheck = defaults.object(forKey: Key.lastBackgroundCheck) as? Date
        appManagementExplained = defaults.bool(forKey: Key.appManagementExplained)
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

    /// One step: runs a check if due. Returns seconds until the next look.
    @discardableResult
    public func tick() async -> TimeInterval {
        guard settings.notifyNewUpgrades else { return 300 }
        let schedule = BackgroundSchedule(intervalHours: settings.checkIntervalHours)
        let t = now()
        let next = schedule.nextCheck(lastCheck: settings.lastBackgroundCheck, launchedAt: launchedAt)
        guard next <= t else { return next.timeIntervalSince(t) }
        guard !store.isUpgrading, !store.isRefreshing, !store.homebrewState.needsWelcome else { return BackgroundSchedule.busyRetry }
        await runCheck()
        return schedule.interval
    }

    /// `brew update` (through the queue), re-read, compare, maybe notify.
    public func runCheck() async {
        await store.refresh(manual: true)
        settings.lastBackgroundCheck = now()
        guard store.report != nil, store.error == nil else { return } // keep the old baseline on failure
        // Turned off while brew update ran: post nothing, keep no baseline.
        guard settings.notifyNewUpgrades else { return }
        let keys = UpgradeNotificationDiff.keys(store.packages)
        if let message = UpgradeNotificationDiff.decide(previous: settings.notifiedUpgrades, current: keys, packages: store.packages) {
            notifier?.post(message)
        }
        settings.notifiedUpgrades = keys
    }
}
