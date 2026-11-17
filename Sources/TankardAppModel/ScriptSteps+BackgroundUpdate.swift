import Foundation
import TankardCore

// v0.8: the harness's background-update steps (Scripts/e2e.sh's
// `background` scenario; AppStore+BackgroundUpdate.swift is the feature).
// The app must run with TANKARD_E2E_BACKGROUND=1 so the background checker
// runs at all; e2e.sh sets a tiny interval in the run's settings suite.

extension ScriptRunner {
    static var backgroundUpdateSteps: [String: ScriptStepDef] { [
        "wait-background-update": ScriptStepDef("wait-background-update [seconds]  (the background checker's `brew update` runs and ends; default 300 s)") { c in
            let timeout = Double(c.arg(0) ?? "") ?? 300
            let s = c.store
            try await c.waitUntil("a background brew update to start", timeout: timeout) { s.backgroundUpdateRuns > 0 }
            await c.snapshot("running")
            try await c.waitUntil("the background brew update to finish", timeout: timeout) { !s.backgroundUpdating }
            try await c.settle()
            c.check("the update succeeded", s.lastBackgroundUpdateFailure == nil)
            c.check("no error banner", s.error == nil, s.error?.title)
            c.check("brew update recorded", s.settings.lastBrewUpdate != nil)
        },
        "expect-background-updates": ScriptStepDef("expect-background-updates <n> [after <seconds>]  (this launch ran exactly n background updates; the decision is logged)") { c in
            let n = Int(try c.arg(0, "n")) ?? -1
            if c.arg(1) == "after", let secs = Double(c.arg(2) ?? "") {
                try await Task.sleep(for: .seconds(secs))
            }
            let s = c.store
            let decision = s.backgroundUpdateDecision(launchedAt: .distantPast, now: Date())
            c.check("\(n) background update(s) this launch", s.backgroundUpdateRuns == n,
                    "ran \(s.backgroundUpdateRuns); decision now: \(decision)")
        },
        "expect-background-decision": ScriptStepDef("expect-background-decision off|opted-out|not-due|run  (the throttle's decision right now)") { c in
            let want = try c.arg(0, "decision")
            let d = c.store.backgroundUpdateDecision(launchedAt: .distantPast, now: Date())
            let got: String
            switch d {
            case .off: got = "off"
            case .optedOut: got = "opted-out"
            case .notDue: got = "not-due"
            case .waiting: got = "waiting"
            case .run: got = "run"
            }
            c.check("background decision is \(want)", got == want, "\(d)")
        },
        "upgrade-during-update": ScriptStepDef("upgrade-during-update <name>  (wait for the background `brew update`, click Upgrade while it runs: the sheet waits for it, then upgrades)") { c in
            let name = try c.arg(0, "name")
            let s = c.store
            try await c.waitUntil("the background brew update to start", timeout: 300) { s.backgroundUpdating }
            let p = try c.requirePackage(name)
            c.check("\(p.name) has an upgrade", p.upgradeAvailable, "\(p.installedVersion) → \(p.currentVersion ?? "?")")
            let before = s.upgrade?.id
            s.requestUpgrade([p])
            if s.upgradePlan != nil { s.confirmUpgradePlan() }
            try await c.waitUntil("the upgrade sheet", timeout: 15) { s.upgrade != nil && s.upgrade?.id != before }
            guard let session = s.upgrade else { throw ScriptFailure("upgrade \(name) did not start") }
            let line = session.statusLine(behindBrewUpdate: s.sessionWaitsForBrewUpdate)
            c.check("the update was still running", s.backgroundUpdating)
            c.check("the sheet says it waits for brew update", line == String(localized: "Waiting for brew update to finish…"), line)
            // A quick shot: an update with nothing new to fetch can end
            // within a second. Whether it still showed the line is noted.
            await c.snapshot("waiting", settle: 0.15)
            c.check("waiting shot", true, s.sessionWaitsForBrewUpdate ? "taken while still waiting" : "the update had already ended")
            try await c.waitUntil("upgrade \(name) to finish", timeout: 900) { session.isFinished }
            try await c.settle()
            await c.snapshot("sheet")
            let failed = session.failedItems.map { "\($0.package.name): \($0.state)" }
            s.closeUpgrade()
            try await c.settle()
            c.check("upgrade \(name): every item done", failed.isEmpty, failed.joined(separator: "; "))
            c.check("the update ran first", s.backgroundUpdateRuns >= 1 && !s.backgroundUpdating)
        },
    ] }
}
