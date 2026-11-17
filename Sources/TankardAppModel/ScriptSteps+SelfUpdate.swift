import Foundation
import TankardCore

// 0.8.3: the self-update steps (Scripts/e2e-selfupdate.sh). Each calls what
// the Check for Tankard Updates sheet and the "Tankard was upgraded" alert
// call. The run sets TANKARD_E2E_SELFUPDATE=1 (relaunch on, the guard
// counts it as the real app) and TANKARD_E2E_SELF_TAP (its throwaway tap).

extension ScriptRunner {
    static var selfUpdateSteps: [String: ScriptStepDef] { [
        "check-updates": ScriptStepDef("check-updates <version> [brew|download]  (Tankard ▸ Check for Tankard Updates…: <version> is offered, with Upgrade with Homebrew or Download)") { c in
            let version = try c.arg(0, "version")
            c.store.checkForTankardUpdates()
            try await c.waitUntil("the update check", timeout: 120) { c.store.selfUpdate != .checking && !c.store.isRefreshing }
            await c.snapshot("sheet")
            guard case .available(let r)? = c.store.selfUpdate else {
                throw ScriptFailure("no update offered: \(String(describing: c.store.selfUpdate))")
            }
            c.check("Tankard \(version) offered", r.version == version, r.version)
            switch c.arg(1) ?? "brew" {
            case "brew": c.check("Upgrade with Homebrew offered (the tankard cask installed this copy)", c.store.tankardCask != nil)
            case "download": c.check("Download offered", c.store.tankardCask == nil)
            default: throw ScriptFailure("brew or download, not \(c.args[1])")
            }
        },
        "upgrade-self": ScriptStepDef("upgrade-self <version>  (the sheet's Upgrade with Homebrew; the run ends with the relaunch offer and the quiet mode)") { c in
            let version = try c.arg(0, "version")
            let before = c.store.upgrade?.id
            c.store.upgradeTankardWithBrew(to: version)
            // Its `brew update` runs first (refresh manual), then the session.
            try await c.waitUntil("the self-upgrade to start", timeout: 300) {
                c.store.appManagementPrompt != nil || (c.store.upgrade != nil && c.store.upgrade?.id != before) || c.store.showSelfUpdate
            }
            if c.store.showSelfUpdate, case .failed(let m)? = c.store.selfUpdate { throw ScriptFailure("upgrade-self: \(m)") }
            if c.store.appManagementPrompt?.reason == .firstUse {
                await c.snapshot("app-management")
                c.store.appManagementNotNow()
                try await c.waitUntil("the self-upgrade to start after Not now", timeout: 15) { c.store.upgrade != nil && c.store.upgrade?.id != before }
            }
            guard let session = c.store.upgrade else { throw ScriptFailure("the self-upgrade did not start") }
            try await c.waitUntil("the self-upgrade to finish", timeout: 600) { session.isFinished }
            try await Task.sleep(for: .milliseconds(600))
            await c.snapshot("finished")
            let failed = session.failedItems.map { "\($0.package.name): \($0.state)" }
            c.check("every item done", failed.isEmpty, failed.joined(separator: "; "))
            c.check("quiet mode on (the bundle was replaced)", c.store.selfReplaced)
            c.check("relaunch offered", c.store.offerRelaunch)
            c.check("no re-read after the run", !c.store.isRefreshing)
            c.store.closeUpgrade()
            try await Task.sleep(for: .milliseconds(600))
            await c.snapshot("relaunch-offer")
        },
        "expect-quiet": ScriptStepDef("expect-quiet [seconds]  (after the self-upgrade: no refresh, no background update, no new brew command for that long)") { c in
            let secs = Double(c.arg(0) ?? "5") ?? 5
            let read = c.store.lastUpdated
            let updates = c.store.backgroundUpdateRuns
            var refreshed = false
            let end = Date().addingTimeInterval(secs)
            c.store.revalidateIfStale()
            while Date() < end {
                if c.store.isRefreshing || c.store.isUpgrading { refreshed = true }
                try await Task.sleep(for: .milliseconds(100))
            }
            c.check("quiet mode on", c.store.selfReplaced)
            c.check("no refresh or brew run", !refreshed && c.store.lastUpdated == read)
            c.check("no background brew update", c.store.backgroundUpdateRuns == updates)
            c.check("brew actions disabled", c.store.isBusy)
        },
        "open-sheet": ScriptStepDef("open-sheet history|health|taps  (a sheet over the window, as a user might leave one open)") { c in
            guard let s = ToolSheet(rawValue: try c.arg(0, "sheet")), [.history, .health, .taps].contains(s) else {
                throw ScriptFailure("history, health or taps, not \(c.args[0])")
            }
            c.store.toolSheet = s
            try await Task.sleep(for: .milliseconds(800))
            await c.snapshot("sheet")
        },
        "relaunch": ScriptStepDef("relaunch  (the \"Tankard was upgraded\" alert's Relaunch: this process quits, the helper opens the new bundle once it has exited)") { c in
            c.check("relaunch offered", c.store.offerRelaunch)
            c.check("relaunch available", c.store.deps.relaunch != nil)
            FileHandle.standardError.write(Data("e2e: relaunch from pid \(ProcessInfo.processInfo.processIdentifier)\n".utf8))
            c.store.relaunchAfterSelfUpgrade()
            // Quitting ends the script here; still running after this is the failure.
            try await Task.sleep(for: .seconds(8))
            c.check("this process quit", false, c.store.error.map { $0.title + ": " + $0.detail })
        },
    ] }
}
