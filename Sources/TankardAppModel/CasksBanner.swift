import Foundation
import TankardCore

// 0.8.5: Discover's "Casks are off" banner. In Intelbrew mode (or any brew
// told not to use Homebrew's API) casks come only from the homebrew/cask
// tap, a full git clone. The Intelbrew installer leaves it out unless asked
// (install.sh: "Enable casks? One-time download, about 620 MB", which runs
// `brew tap homebrew/cask`), so a Mac set up without it has no casks at all.
// Tankard already knew (TapIndex.hasCaskTap: no homebrew/cask among the
// local taps; DiscoverStore.casksNotice); now it says so plainly and offers
// the same `brew tap homebrew/cask` the installer runs, through the queue
// and the usual Add Tap confirmation.

public enum CasksBanner {
    public static let tap = "homebrew/cask"

    public static var title: String { String(localized: "Apps (casks) are turned off") }
    public static var detail: String {
        String(localized: "This Homebrew can install command-line tools but not apps like Firefox or VLC. Turning apps on is a one-time download of about 620 MB.")
    }
    /// Discover's empty search while apps are off (newbie review H1): a
    /// search for "firefox" finds nothing because apps aren't turned on, not
    /// because Homebrew doesn't have it. Nothing is looked up online.
    public static var noMatchesTitle: String { String(localized: "No command-line tools match") }
    public static func noMatchesDetail(_ query: String) -> String {
        String(localized: "If “\(query)” is an app, Homebrew can't find it because apps (casks) are turned off. Turning them on is a one-time download of about 620 MB.")
    }
}

public extension AppStore {
    /// Discover shows the banner: casks are off and it wasn't closed.
    var showsCasksBanner: Bool {
        guard let d = discover, d.casksNotice != nil else { return false }
        return !settings.casksBannerHidden
    }

    /// Enable Casks…: `brew tap homebrew/cask`, after the Add Tap confirmation.
    func requestEnableCasks() {
        taps.requestAdd(name: CasksBanner.tap, source: .discover)
    }

    /// A finished search found nothing and apps are off: the empty state
    /// says so and offers Turn On Apps… (even after the banner was closed).
    var searchEmptyBecauseCasksOff: Bool {
        guard let d = discover, d.casksNotice != nil else { return false }
        let q = d.query.trimmingCharacters(in: .whitespaces)
        return !q.isEmpty && d.results.isEmpty && d.resultsQuery == d.query
    }

    func hideCasksBanner() {
        settings.casksBannerHidden = true
    }
}
