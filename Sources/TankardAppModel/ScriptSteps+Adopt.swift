import Foundation
import TankardCore

// v0.8: the harness's Adopt Apps steps (ScriptRunner.swift explains the
// harness; AdoptStore.swift the feature). Each calls what the Adopt Apps
// sheet and the detail pane's self-update picker call.

extension ScriptRunner {
    static var adoptSteps: [String: ScriptStepDef] { [
        "adopt-scan": ScriptStepDef("adopt-scan  (Homebrew ▸ Adopt Apps…: the scan of /Applications against cask.json)") { c in
            c.store.openAdopt()
            try await c.waitUntil("the adopt scan", timeout: 120) { c.store.adopt.phase != .scanning && c.store.adopt.phase != .idle }
            let a = c.store.adopt
            c.check("scan finished", a.phase == .ready, "\(a.phase)")
            let counts = AdoptGroup.allCases.map { "\($0.rawValue) \(a.rows($0).count)" }.joined(separator: ", ")
            c.check("scan found apps", !a.scan.rows.isEmpty || !a.scan.skipped.managed.isEmpty, counts)
            await c.snapshot("sheet")
        },
        "adopt": ScriptStepDef("adopt <app path> [automatic|app|homebrew]  (tick only that app, its self-update choice, Adopt, then the confirmation's Adopt)") { c in
            let path = try c.arg(0, "app path")
            let a = c.store.adopt
            if a.phase != .ready {
                c.store.openAdopt()
                try await c.waitUntil("the adopt scan", timeout: 120) { a.phase != .scanning && a.phase != .idle }
            }
            guard let row = a.scan.rows.first(where: { $0.app.path == path }) else {
                throw ScriptFailure("the scan has no row for \(path)")
            }
            guard let token = a.token(row) else { throw ScriptFailure("no cask matches \(path)") }
            c.watchName(token)
            c.check("\(path) is ready to adopt", a.group(row) == .ready, "\(a.group(row).rawValue) as \(token)")
            for r in a.rows(.ready) where r.id != row.id { a.setTicked(r, false) }
            a.setTicked(row, true)
            if let p = c.arg(1) {
                guard let policy = SelfUpdatePolicy(rawValue: p) else { throw ScriptFailure("policy: automatic, app or homebrew") }
                a.setPolicy(policy, for: row)
            }
            c.check("plan is only \(token)", a.plan.map(\.token) == [token], a.plan.map(\.token).joined(separator: ", "))
            a.requestAdopt()
            c.check("confirmation runs brew install --cask --adopt",
                    a.pendingConfirm?.first?.arguments.prefix(3) == ["install", "--cask", "--adopt"],
                    a.pendingConfirm?.first?.command)
            await c.snapshot("confirm")
            try await c.runSession("adopt \(token)") { c.store.confirmAdopt() }
            c.check("\(token) is now a cask", c.package(token, kind: .cask) != nil)
            c.check("\(path) still there", FileManager.default.fileExists(atPath: path))
            c.store.toolSheet = nil
        },
        "self-update": ScriptStepDef("self-update <cask> automatic|app|homebrew  (the detail pane's self-update choice)") { c in
            let p = try c.requirePackage(try c.arg(0, "cask"), kind: .cask)
            guard let policy = SelfUpdatePolicy(rawValue: try c.arg(1, "policy")) else { throw ScriptFailure("policy: automatic, app or homebrew") }
            c.store.reveal(p.id)
            c.store.setSelfUpdatePolicy(p, policy)
            try await c.settle()
            c.check("\(p.name) self-update is \(policy.rawValue)", c.store.selfUpdatePolicy(p) == policy)
        },
        "expect-app": ScriptStepDef("expect-app present|absent <path>  (an app bundle on disk)") { c in
            let want = try c.arg(0, "present|absent") == "present"
            let path = try c.arg(1, "path")
            c.check("\(path) \(want ? "present" : "absent")", FileManager.default.fileExists(atPath: path) == want)
        },
    ] }
}
