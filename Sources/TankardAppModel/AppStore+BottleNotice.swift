import Foundation
import TankardCore

// A formula you built from source that gains a bottle after `brew update`
// (Refresh, Check Now, a background check) is announced once: a banner in
// the window, and a notification when "Notify me about new upgrades" is on.
// Before, the only sign was the badge or the Bottle available filter.
// Nothing is replaced until the user clicks Replace with Bottle.

/// The formulae the window's banner names (keys from
/// `BottleAvailableNotificationDiff.key`).
public struct BottleNotice: Equatable, Sendable {
    public var keys: Set<String>
}

/// One comparison of the bottle-eligible formulae before and after an update.
public struct BottleNews: Equatable, Sendable {
    /// Eligible now.
    public var after: Set<String>
    /// Known before: the list before the update and the keys already seen.
    /// nil: neither exists yet (only record a baseline).
    public var previous: Set<String>?
    /// Eligible now and not known before.
    public var added: Set<String>
}

extension AppStore {
    /// Compares the list on screen with `before` (the eligible keys before
    /// the update; nil when there was no list) and the keys already seen.
    /// Something eligible before this update is never new, even the first
    /// time this runs.
    public func newBottles(before: Set<String>?) -> BottleNews {
        let after = BottleAvailableNotificationDiff.keys(packages)
        let known = settings.notifiedBottles
        let previous: Set<String>? = before == nil && known == nil ? nil : (before ?? []).union(known ?? [])
        return BottleNews(after: after, previous: previous, added: previous.map { after.subtracting($0) } ?? [])
    }

    /// Shows the banner for what's new, posts to `notifier` (nil: no
    /// notification), and remembers the keys so no later check announces
    /// them again.
    public func recordNewBottles(_ news: BottleNews, postTo notifier: UpgradeNotifying?) {
        if !news.added.isEmpty {
            // Added to what the banner already names, if still eligible.
            let showing = Set(bottleNoticePackages.map(BottleAvailableNotificationDiff.key))
            bottleNotice = BottleNotice(keys: showing.union(news.added))
            if let notifier, let message = BottleAvailableNotificationDiff.decide(previous: news.previous, current: news.after, packages: packages) {
                notifier.post(message)
            }
        }
        // Seen keys stay while that version is installed, so a bottle that
        // goes away and comes back isn't announced twice.
        let installed = Set(packages.map { "\($0.id)@\($0.installedVersion)" })
        settings.notifiedBottles = news.after.union((settings.notifiedBottles ?? []).filter(installed.contains))
    }

    /// The banner's formulae that still have a bottle to pour (a refresh
    /// after a replace, or a bottle withdrawn, drops them).
    public var bottleNoticePackages: [Package] {
        guard let keys = bottleNotice?.keys else { return [] }
        return packages.filter { BottleReplacement.isEligible($0) && keys.contains(BottleAvailableNotificationDiff.key($0)) }
    }

    /// The banner's sentence; nil: no banner.
    public var bottleNoticeText: String? {
        let names = bottleNoticePackages.map(\.name).sorted()
        return names.isEmpty ? nil : BottleAvailableNotificationDiff.phrase(names)
    }

    /// The banner's close button. The keys were recorded when it appeared;
    /// added again here in case Settings reset them since.
    public func dismissBottleNotice() {
        if let keys = bottleNotice?.keys { settings.notifiedBottles = (settings.notifiedBottles ?? []).union(keys) }
        bottleNotice = nil
    }

    /// The banner's Replace with Bottle: the same session as the detail
    /// pane's button, for the formulae the banner names, and only on click.
    /// (startReplaceWithBottle takes them off the banner once it starts.)
    public func replaceNoticedBottles() {
        let targets = bottleNoticePackages
        guard !targets.isEmpty else { return }
        startReplaceWithBottle(targets)
    }

    /// A notification click, the banner's Show and the menu-bar notice:
    /// Installed ▸ Bottle available. Never starts a replace. Only a real
    /// change is written (as `showUpgrades()`).
    public func showBottleAvailable() {
        if tab != .installed { tab = .installed }
        if !search.isEmpty { search = "" }
        if filter != .bottleAvailable { filter = .bottleAvailable }
    }
}
