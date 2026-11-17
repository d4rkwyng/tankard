import Foundation
import TankardCore

// 0.8.3: Stop Now for every running sheet, one package or many.
//
// What brew 7 leaves behind when interrupted (SIGINT, which Stop Now sends
// first; checked on this Mac, see docs/usage.md): a fresh install stopped
// while pouring left nothing (no keg, no links: formula_installer.rb removes
// the prefix on any exception, "any exceptions must leave us with nothing
// installed"); an upgrade stopped mid-install kept the old version, still
// linked (reinstall/upgrade restore their backup under
// Utils::Interrupts.ignore). A stopped download leaves only brew's
// `.incomplete` file in its cache, which the next download resumes.
extension UpgradeSession {
    /// Whether Stop Now should ask first: only while brew may be changing a
    /// package on disk. Not while it downloads (nothing is installed yet),
    /// waits for brew's lock, or hasn't started; not for actions brew
    /// itself finishes before it stops (an uninstall removes its keg with
    /// interrupts deferred), nor clean up or taps.
    public var stopNowNeedsConfirmation: Bool {
        Self.stopNeedsConfirmation(action: action, running: current != nil && !isFinished,
                                   downloading: download != nil, waitingForLock: lockWait != nil)
    }

    nonisolated static func stopNeedsConfirmation(action: SessionAction, running: Bool, downloading: Bool,
                                                  waitingForLock: Bool) -> Bool {
        guard running, !downloading, !waitingForLock else { return false }
        switch action {
        case .upgrade, .install, .replaceBottle, .restore, .adopt: return true
        case .uninstall, .cleanup, .autoremove, .tap, .untap: return false
        }
    }

    /// The confirmation's text, for the running package.
    public var stopNowWarning: String {
        let name = current?.package.name ?? items.first?.package.name ?? ""
        return String(localized: "Homebrew is changing \(name) now. If you stop, Homebrew undoes the unfinished step and \(name) stays as it was. If anything is left half done, running it again usually fixes it.")
    }

    /// The sheet's Stop Now: at once, or after "Stop now?" when brew may be
    /// changing a package.
    public func requestStopNow() {
        if stopNowNeedsConfirmation { confirmingStop = true } else { stopNow() }
    }

    /// Stop Now has something to stop: a running or waiting step.
    public var canStopNow: Bool { !isFinished && !stoppingNow }
}
