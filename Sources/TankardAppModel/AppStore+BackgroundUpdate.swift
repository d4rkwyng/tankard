import Foundation
import os
import TankardCore

// 0.8: a throttled `brew update` in the background, after the list is on
// screen, so "N upgrades ready" is as fresh as brew's own data. Driven by
// BackgroundChecker's timer (never started in demo mode); the store side is
// here.

/// When the background `brew update` runs. Pure, so it can be tested.
public enum BackgroundUpdatePolicy {
    /// Not before this long after launch: the window's own read goes first.
    public static let launchDelay: TimeInterval = 3
    /// Something else is using brew (a refresh, a sheet's run, auto-update):
    /// look again after this.
    public static let busyRetry: TimeInterval = 10
    /// After a failure (offline, brew's lock): at most one more try per hour.
    public static let failureRetry: TimeInterval = 3600

    public enum Decision: Equatable, Sendable {
        /// The setting is off, or this build doesn't run it (demo, tests).
        case off
        /// The user told brew not to auto-update: HOMEBREW_NO_AUTO_UPDATE and
        /// where it is set ("environment", "~/.zprofile", "brew.env").
        case optedOut(source: String)
        case notDue(next: Date)
        case waiting(retry: TimeInterval)
        case run
    }

    /// The check interval (Settings ▸ General ▸ Check every), or the user's
    /// HOMEBREW_AUTO_UPDATE_SECS when that is longer: Tankard never updates
    /// more often than brew was told to.
    public static func interval(hours: Int, autoUpdateSecs: String?) -> TimeInterval {
        let ours = BackgroundSchedule(intervalHours: hours).interval
        guard let s = autoUpdateSecs.flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }), s > ours else { return ours }
        return s
    }

    /// `lastUpdate`: the newest of Tankard's last successful `brew update`
    /// and the brew repository's last fetch (any `brew update`, Terminal's too).
    public static func decide(enabled: Bool, available: Bool, optOut: String?, interval: TimeInterval,
                              lastUpdate: Date?, lastFailure: Date?, launchedAt: Date, now: Date,
                              busy: Bool, retryAfterFailure: TimeInterval = failureRetry) -> Decision {
        guard available, enabled else { return .off }
        if let optOut { return .optedOut(source: optOut) }
        var next = launchedAt.addingTimeInterval(launchDelay)
        if let lastUpdate { next = max(next, lastUpdate.addingTimeInterval(interval)) }
        if let lastFailure { next = max(next, lastFailure.addingTimeInterval(min(interval, retryAfterFailure))) }
        if next > now { return .notDue(next: next) }
        return busy ? .waiting(retry: busyRetry) : .run
    }

    /// brew skips its own auto-update when HOMEBREW_NO_AUTO_UPDATE is set to
    /// anything non-empty (Library/Homebrew/utils/auto-update.sh); so does Tankard.
    public static func optOut(_ sources: EnvironmentSources?) -> String? {
        guard let s = sources?.effective("HOMEBREW_NO_AUTO_UPDATE"), !s.value.isEmpty else { return nil }
        return s.source
    }
}

extension AppStore {
    private static let log = Logger(subsystem: AppPaths.bundleID, category: "background-update")

    /// Anything else using brew, or nothing on screen yet to refresh.
    /// A list from the status cache counts as on screen: a relaunch inside
    /// the cache's hour reads no status, so homebrewState stays .checking,
    /// and waiting for .ready meant no background update that whole session
    /// (found by e2e.sh's background scenario). Only the welcome screen
    /// (brew missing or broken) stops it.
    var backgroundUpdateBusy: Bool {
        isBusy || isRefreshing || backgroundUpdating || report == nil || homebrewState.needsWelcome
            || insights.sizesState == .running
    }

    /// The sheet's first step is queued behind the background `brew update`
    /// (the queue runs one brew at a time): the sheet says it is waiting for it.
    public var sessionWaitsForBrewUpdate: Bool {
        guard let u = upgrade else { return false }
        return backgroundUpdating && u.notStarted
    }

    /// HOMEBREW_NO_AUTO_UPDATE's source when the user set it (Settings shows it).
    public var backgroundUpdateOptOut: String? { BackgroundUpdatePolicy.optOut(brewSources) }

    public func backgroundUpdateDecision(launchedAt: Date, now: Date) -> BackgroundUpdatePolicy.Decision {
        let sources = brewSources
        let interval = deps.backgroundUpdateInterval
            ?? BackgroundUpdatePolicy.interval(hours: settings.checkIntervalHours,
                                               autoUpdateSecs: sources?.effective("HOMEBREW_AUTO_UPDATE_SECS")?.value)
        let last = [settings.lastBrewUpdate, brewLastFetch].compactMap { $0 }.max()
        return BackgroundUpdatePolicy.decide(enabled: settings.backgroundUpdate, available: deps.backgroundUpdates,
                                             optOut: BackgroundUpdatePolicy.optOut(sources), interval: interval,
                                             lastUpdate: last, lastFailure: lastBackgroundUpdateFailure,
                                             launchedAt: launchedAt, now: now, busy: backgroundUpdateBusy,
                                             retryAfterFailure: backgroundFailureRetry)
    }

    /// `brew update` through the queue (so never beside another brew command
    /// Tankard runs), then a re-read for the new upgrade badges. Selection,
    /// filter, search and scroll stay; a failure is logged, not shown.
    /// Returns whether the update succeeded and the list was re-read.
    @discardableResult
    public func runBackgroundUpdate() async -> Bool {
        guard !backgroundUpdating, !isBusy, !selfReplaced, let client = try? resolvedClient() else { return false }
        backgroundUpdating = true
        backgroundUpdateRuns += 1
        defer { backgroundUpdating = false }
        let started = deps.now()
        // 0.8.5: with a time limit, stopped by sleep; "try later" is quiet.
        let result = await runScheduledUpdate(client)
        lastScheduledUpdate = result
        if let quiet = result.quiet {
            lastBackgroundUpdateFailure = deps.now()
            backgroundFailureRetry = quiet.retryAfter
            Self.log.notice("background brew update: \(quiet.rawValue, privacy: .public); will retry")
            deps.logURL.map(LogFile.init)?.append(["=== \(ISO8601DateFormatter().string(from: started)) background brew update failed: \(quiet.rawValue); will retry"])
            return false
        }
        if let failure = result.error {
            lastBackgroundUpdateFailure = deps.now()
            backgroundFailureRetry = BackgroundUpdatePolicy.failureRetry
            let line = ProxySettings.maskText("background brew update failed: \(failure.title)"
                + (failure.detail.isEmpty ? "" : ": " + (failure.detail.split(separator: "\n").last.map(String.init) ?? "")))
            Self.log.notice("\(line, privacy: .public)")
            deps.logURL.map(LogFile.init)?.append(["=== \(ISO8601DateFormatter().string(from: started)) \(line)"])
            return false
        }
        lastBackgroundUpdateFailure = nil
        LaunchTiming.mark("brew update")
        // The user started something meanwhile (it queued behind the
        // update): its own re-read at the end covers this one.
        guard !isBusy else { return true }
        await refresh(.afterUpdate)
        LaunchTiming.mark("re-read")
        return error == nil
    }
}

/// 0.8.8 (gauntlet 3, B9): Settings → General's background-check controls
/// while HOMEBREW_NO_AUTO_UPDATE is set (`optOut`, its source): the checkbox
/// shows off (it showed the saved "on", dimmed, under "Off: …"), and "Check
/// every" is enabled only when something still checks (notifications).
public enum BackgroundUpdateSetting {
    public static func shownOn(saved: Bool, optOut: String?) -> Bool {
        optOut == nil && saved
    }

    public static func intervalEnabled(notify: Bool, saved: Bool, optOut: String?) -> Bool {
        notify || shownOn(saved: saved, optOut: optOut)
    }
}
