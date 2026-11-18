import Foundation
import TankardCore

// v0.8: the harness's built-in steps (ScriptRunner.swift explains the
// harness). Every step calls what the matching button or menu item calls.

extension ScriptRunner {
    static var coreSteps: [String: ScriptStepDef] { [
        // MARK: launch state
        "expect-welcome": ScriptStepDef("expect-welcome  (the no-Homebrew welcome screen is up)") { c in
            try await c.waitUntil("the brew check", timeout: 60) { c.store.homebrewState != .checking && !c.store.isRefreshing }
            c.check("welcome screen shown", c.store.homebrewState.needsWelcome, "\(c.store.homebrewState)")
        },
        "check-again": ScriptStepDef("check-again  (the welcome screen's Check Again)") { c in
            await c.store.checkAgain()
        },
        "expect-ready": ScriptStepDef("expect-ready [cached]  (the package list is up: read live from brew, or with cached from the status cache)") { c in
            let cached = c.arg(0) == "cached"
            try await c.waitUntil("brew's first answer", timeout: 120) {
                (c.store.homebrewState != .checking || (cached && c.store.report != nil)) && !c.store.isRefreshing
            }
            try await c.settle()
            if cached {
                // A launch inside the cache's hour shows the cache and asks
                // brew nothing (homebrewState stays .checking then).
                c.check("report shown from the status cache", c.store.report != nil && c.store.reportFromCache)
            } else {
                c.check("brew ready", c.store.homebrewState == .ready, "\(c.store.homebrewState)")
                c.check("report read from brew, not a cache", c.store.report != nil && !c.store.reportFromCache)
            }
            c.check("no error banner", c.store.error == nil, c.store.error?.title)
        },
        "expect-fresh": ScriptStepDef("expect-fresh  (first-launch defaults: nothing saved yet)") { c in
            let s = c.store
            c.check("menu-bar icon on (default)", s.settings.showMenuBarIcon)
            c.check("upgrade notifications off (default)", !s.settings.notifyNewUpgrades)
            c.check("App Management not yet explained", !s.settings.appManagementExplained)
            c.check("no background check yet", s.settings.lastBackgroundCheck == nil)
            c.check("keep previous version off (default)", !s.restorePoints.settings.keepPreviousVersion)
            c.check("vulnerability scan on refresh off (default)", !s.insights.settings.scanVulnerabilitiesOnRefresh)
            c.check("self-updating apps off (default)", !s.insights.settings.includeSelfUpdatingApps)
            c.check("auto-update off (default)", !s.autoUpdate.settings.enabled)
            c.check("no restore points yet", s.restorePoints.points.isEmpty, "\(s.restorePoints.points.count)")
            c.check("no History yet", s.history.entries.isEmpty, "\(s.history.entries.count)")
        },
        "refresh": ScriptStepDef("refresh [manual|away]  (manual: brew update first; away: Check Now with the window behind, 0.8.2)") { c in
            if c.arg(0) == "away" {
                await c.store.refreshFromUser(windowInFront: { false })
            } else {
                await c.store.refresh(manual: c.arg(0) == "manual")
            }
            try await c.settle()
            c.check("refresh left no error", c.store.error == nil, c.store.error.map { $0.title + ": " + $0.detail })
        },

        // MARK: navigation
        "tab": ScriptStepDef("tab installed|discover|services") { c in
            guard let t = MainTab(rawValue: try c.arg(0, "tab")) else { throw ScriptFailure("no tab \(c.args[0])") }
            c.store.tab = t
            if t == .discover, let d = c.store.openDiscover() { await d.activate() }
            if t == .services { c.store.openServices() }
        },
        // 0.8.4: the list jumps a user makes (Upgrades → All, clearing a
        // search), for the NSTableView reentrancy check (0.8.5: fixed row
        // heights, PackageRow in ContentView.swift). Script mode only, like
        // every step.
        "filter": ScriptStepDef("filter <all|upgrades|source|newer|bottleAvailable|pinned|leaves|vulnerable|hasNotes|deprecated>  (Installed's filter, as clicking it)") { c in
            let name = try c.arg(0, "filter")
            guard let f = PackageFilter.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
                throw ScriptFailure("no filter \(name)")
            }
            c.store.tab = .installed
            c.store.filter = f
            try await Task.sleep(for: .milliseconds(400)) // time for the table to settle (and PackageTable's first fill)
            c.check("filter \(f.rawValue): \(c.store.visiblePackages.count) rows", c.store.filter == f)
        },
        "search": ScriptStepDef("search <text>|-  (types into Installed's search field; - clears it)") { c in
            let text = try c.arg(0, "text")
            c.store.tab = .installed
            c.store.search = text == "-" ? "" : text
            try await Task.sleep(for: .milliseconds(400))
            c.check("search '\(c.store.search)': \(c.store.visiblePackages.count) rows", true)
        },
        "search-burst": ScriptStepDef("search-burst <text>|- ...  (each one 30 ms after the last: fast typing; - is an empty field)") { c in
            guard !c.args.isEmpty else { throw ScriptFailure("search-burst needs at least one text") }
            c.store.tab = .installed
            for t in c.args {
                c.store.search = t == "-" ? "" : t
                try await Task.sleep(for: .milliseconds(30))
            }
            try await Task.sleep(for: .milliseconds(400))
            c.check("search '\(c.store.search)': \(c.store.visiblePackages.count) rows", true)
        },
        "select": ScriptStepDef("select <name>  (a row in Installed)") { c in
            let p = try c.requirePackage(try c.arg(0, "name"))
            c.store.tab = .installed
            c.store.reveal(p.id)
            c.check("selected", c.store.selection == p.id)
        },
        "discover": ScriptStepDef("discover <query> [formulae|casks]  (search Discover)") { c in
            let d = try await c.openDiscover(kind: c.arg(1))
            d.query = try c.arg(0, "query")
            await d.searchNow()
            c.check("Discover found results", !d.results.isEmpty, "\(d.results.count) for '\(d.query)'")
        },

        // MARK: packages
        "install": ScriptStepDef("install formula|cask <name>  (Discover's Install button)") { c in
            let kind = try c.kind(0)
            let name = try c.arg(1, "name")
            c.store.selection = nil
            let d = try await c.openDiscover(kind: kind == .cask ? "casks" : "formulae")
            d.bottledOnly = false
            d.query = name
            await d.searchNow()
            guard let e = d.results.first(where: { $0.name == name && $0.kind == kind }) else {
                throw ScriptFailure("Discover has no \(kind.rawValue) named \(name)")
            }
            c.check("\(name) not installed before", !c.store.installedIDs.contains(e.id))
            d.selection = e.id
            await d.waitForDetails()
            await c.snapshot("discover")
            let entry = d.selectedEntry ?? e
            let compiles = c.store.deps.classifier.installWarning(entry) != nil
            try await c.runSession("install \(name)") {
                if compiles {
                    // "Install (compiles)", then the confirmation's Install.
                    d.confirmInstall = entry.id
                    d.confirmInstall = nil
                }
                c.store.startInstall(entry)
            }
            c.store.tab = .installed
            let p = c.package(name, kind: kind)
            c.check("\(name) installed", p != nil)
            if let p { c.store.reveal(p.id) }
        },
        "uninstall": ScriptStepDef("uninstall formula|cask <name> [deps on|off [<dep>...]]  (Uninstall…, then the sheet's Uninstall; deps: \"Also remove these\", and the dependencies it must list)") { c in
            let kind = try c.kind(0)
            let name = try c.arg(1, "name")
            let p = try c.requirePackage(name, kind: kind)
            c.store.tab = .installed
            c.store.reveal(p.id)
            c.store.requestUninstall(p)
            let orphans = c.store.uninstallOrphans(of: p)
            var removeDeps = true
            if c.arg(2) == "deps" {
                let v = try c.arg(3, "on|off")
                guard ["on", "off"].contains(v) else { throw ScriptFailure("deps on or off, not \(v)") }
                removeDeps = v == "on"
                c.store.uninstallRemovesOrphans = removeDeps
                let want = Array(c.args.dropFirst(4)).sorted()
                if !want.isEmpty {
                    c.check("the sheet lists \(want.joined(separator: ", ")) as no longer needed",
                            orphans.map(\.name).sorted() == want, orphans.map(\.name).joined(separator: ", "))
                }
            }
            orphans.forEach { c.watchName($0.name) }
            await c.snapshot("confirm")
            let needs = c.store.dependents(of: p).map(\.name)
            guard needs.isEmpty else { throw ScriptFailure("uninstall is blocked: \(needs.joined(separator: ", ")) need \(name)") }
            guard !p.pinned else { throw ScriptFailure("uninstall is blocked: \(name) is pinned (the sheet offers Unpin and Uninstall)") }
            let session = try await c.runSession("uninstall \(name)") { c.store.startUninstall(p) }
            c.check("\(name) gone", c.package(name, kind: kind) == nil)
            let ran = session.items.map(\.package.name)
            c.check("ran \(removeDeps ? "with" : "without") its \(orphans.count) unneeded dependencies",
                    ran == [p.name] + (removeDeps ? orphans.map(\.name) : []), ran.joined(separator: ", "))
            for o in orphans {
                let still = c.package(o.name, kind: .formula) != nil
                c.check("\(o.name) \(removeDeps ? "removed" : "kept")", still != removeDeps)
            }
        },
        "uninstall-blocked": ScriptStepDef("uninstall-blocked formula|cask <name> pinned  (Uninstall…: the sheet blocks it; its Uninstall would run nothing)") { c in
            let kind = try c.kind(0)
            let name = try c.arg(1, "name")
            let why = try c.arg(2, "pinned")
            guard why == "pinned" else { throw ScriptFailure("uninstall-blocked: only 'pinned' is checked, not \(why)") }
            let p = try c.requirePackage(name, kind: kind)
            c.store.tab = .installed
            c.store.reveal(p.id)
            c.store.requestUninstall(p)
            c.check("the uninstall sheet is up", c.store.uninstallCandidate?.id == p.id)
            c.check("\(name) is pinned", p.pinned)
            c.check("nothing else blocks it", c.store.dependents(of: p).isEmpty)
            await c.snapshot("sheet")
            // What a stray Uninstall would do now: nothing starts.
            let before = c.store.upgrade?.id
            c.store.startUninstall(p)
            try await Task.sleep(for: .milliseconds(500))
            c.check("no uninstall session started", c.store.upgrade?.id == before && !c.store.isUpgrading)
            c.check("\(name) still installed", c.package(name, kind: kind) != nil)
        },
        "unpin-uninstall": ScriptStepDef("unpin-uninstall formula|cask <name>  (Uninstall… on a pinned package, then Unpin and Uninstall)") { c in
            let kind = try c.kind(0)
            let name = try c.arg(1, "name")
            let p = try c.requirePackage(name, kind: kind)
            c.check("\(name) is pinned before", p.pinned)
            c.store.tab = .installed
            c.store.reveal(p.id)
            c.store.requestUninstall(p)
            await c.snapshot("confirm")
            // brew unpin and the re-read run first, then the uninstall session.
            try await c.runSession("unpin and uninstall \(name)", startTimeout: 180) { c.store.unpinAndUninstall(p) }
            c.check("\(name) gone", c.package(name, kind: kind) == nil)
            c.check("no error", c.store.error == nil, c.store.error?.detail)
        },
        "upgrade": ScriptStepDef("upgrade <name> [<name>...]  (the detail pane's Upgrade; several: Upgrade on a selection, 0.8.3: with the prefetch; a compile plan is confirmed)") { c in
            _ = try c.arg(0, "name")
            let ps = try c.args.map { try c.requirePackage($0) }
            for p in ps {
                c.check("\(p.name) has an upgrade", p.upgradeAvailable, "\(p.installedVersion) → \(p.currentVersion ?? "?")")
            }
            let before = c.store.restorePoints.points.count
            let names = ps.map(\.name).joined(separator: " ")
            let session = try await c.runSession("upgrade \(names)") {
                c.store.requestUpgrade(ps)
                if c.store.upgradePlan != nil { c.store.confirmUpgradePlan() }
            }
            c.check("a restore point was saved before the upgrade", c.store.restorePoints.points.count == before + 1,
                    "\(before) → \(c.store.restorePoints.points.count)")
            if ps.count > 1 {
                // 0.8.3: one `brew fetch` first, then the upgrades from the cache.
                let fetches = session.prefetch.map(\.command.display)
                c.check("one brew fetch ran before the upgrades", !fetches.isEmpty
                        && session.fetchStates.values.allSatisfy { $0 == .done }
                        && session.log.lines.first == "$ " + (fetches.first ?? ""), fetches.joined(separator: "; "))
                c.check("brew fetch finished every package", session.fetchedCount == session.fetchTotal,
                        "\(session.fetchedCount) of \(session.fetchTotal)")
            }
        },
        "pin": ScriptStepDef("pin <name>") { c in try await c.setPinned(true) },
        "unpin": ScriptStepDef("unpin <name>") { c in try await c.setPinned(false) },
        "notes": ScriptStepDef("notes <name>  (the post-install notes sheet lists it; then Done)") { c in
            let name = try c.arg(0, "name")
            try await c.waitUntil("the post-install notes", timeout: 10) { c.store.insights.postInstallNotes != nil }
            let names = c.store.insights.postInstallNotes?.notes.map(\.name) ?? []
            c.check("notes for \(name)", names.contains(name), names.joined(separator: ", "))
            await c.snapshot("sheet")
            c.store.insights.postInstallNotes = nil
        },

        // MARK: insights
        "scan-vulns": ScriptStepDef("scan-vulns  (Homebrew ▸ Scan for Vulnerabilities; waits for the end)") { c in
            c.store.scanVulnerabilitiesNow()
            c.check("scan started", c.store.insights.scanState == .running)
            await c.snapshot("running")
            await c.store.insights.waitForIdle()
            try await c.waitUntil("the scan to end", timeout: 90) { c.store.insights.scanState != .running }
            let st = c.store.insights.scanState
            c.check("scan ended without error", st == .idle, "\(st)")
            if case .done(let checked, let found, let complete)? = c.store.insights.scanOutcome {
                c.check("scan checked formulae", checked > 0, "checked \(checked), found \(found), complete \(complete)")
            } else {
                c.check("scan finished", false, c.store.insights.scanOutcome.map { "\($0)" } ?? "no outcome")
            }
            c.store.filter = .vulnerable
        },

        // MARK: restore points
        "save-restore-point": ScriptStepDef("save-restore-point  (Restore Points ▸ Save Now)") { c in
            let before = c.store.restorePoints.points.count
            c.store.openRestorePoints()
            let p = c.store.saveRestorePoint(.manual)
            c.check("saved", p != nil && c.store.restorePoints.points.count == before + 1)
            await c.snapshot("sheet")
            c.store.restorePoints.isShowing = false
        },
        "restore": ScriptStepDef("restore latest|<n> [nopin] [rollback <name>]  (Restore…, then Restore; n=1 is the newest; \"Pin rolled-back formulae\" is on as in the sheet unless nopin)") { c in
            let which = c.arg(0) ?? "latest"
            let n = which == "latest" ? 1 : (Int(which) ?? 0)
            let points = c.store.restorePoints.points
            guard n >= 1, n <= points.count else { throw ScriptFailure("no restore point \(which) (\(points.count) saved)") }
            let point = points[n - 1]
            c.store.openRestorePoints()
            c.store.restorePoints.selection = point.id
            let pinAfter = !c.args.contains("nopin")
            c.store.requestRestore(point, pinAfter: pinAfter)
            guard let plan = c.store.restorePoints.pendingPlan else { throw ScriptFailure("no restore plan") }
            if let i = c.args.firstIndex(of: "rollback"), let name = c.arg(i + 1) {
                c.watchName(name)
                c.check("plan rolls \(name) back", plan.steps.contains { ($0.package == name || $0.package.hasSuffix("/" + name)) && $0.kind == .rollbackUninstall },
                        plan.steps.map(\.display).joined(separator: " ; ")
                            + (plan.manual.isEmpty ? "" : " | manual: " + plan.manual.map { "\($0.change.now.name): \($0.block.rawValue)" }.joined(separator: ", ")))
            }
            await c.snapshot("confirm")
            guard !plan.steps.isEmpty else { throw ScriptFailure("the plan has nothing to run") }
            try await c.runSession("restore") { c.store.confirmRestore() }
            c.check("restore confirmation closed", c.store.restorePoints.pendingPlan == nil)
        },

        // MARK: taps
        "tap-add": ScriptStepDef("tap-add <user/repo> [url]  (Taps ▸ Add Tap)") { c in
            let name = try c.arg(0, "tap")
            c.store.openTaps()
            try await c.loadTaps()
            if let problem = c.store.taps.requestAdd(name: name, url: c.arg(1) ?? "") { throw ScriptFailure("\(problem)") }
            await c.snapshot("confirm")
            try await c.runSession("tap \(name)") { c.store.confirmAddTap() }
            c.store.prepareTaps()
            try await c.loadTaps()
            c.check("\(name) tapped", c.tap(name)?.tapped == true)
        },
        "tap-trust": ScriptStepDef("tap-trust <user/repo> on|off  (Taps ▸ Trust… / Untrust…, then the confirmation's button)") { c in
            let name = try c.arg(0, "tap")
            let want = try c.arg(1, "on|off") == "on"
            c.store.prepareTaps()
            try await c.loadTaps()
            guard let t = c.tap(name) else { throw ScriptFailure("no tap \(name)") }
            let was = t.trusted ?? false
            guard was != want else { throw ScriptFailure("\(name) is already \(want ? "trusted" : "untrusted")") }
            c.store.taps.requestTrust(t)
            c.store.confirmTrustTap()
            try await c.waitUntil("brew trust", timeout: 60) { c.store.quickAction == nil && c.store.taps.phase != .loading }
            try await Task.sleep(for: .milliseconds(300))
            try await c.loadTaps()
            c.check("\(name) trust is now \(!was)", (c.tap(name)?.trusted ?? false) == !was, "\(String(describing: c.tap(name)?.trusted))")
            c.check("no error", c.store.error == nil, c.store.error?.detail)
        },
        "tap-remove": ScriptStepDef("tap-remove <user/repo>  (Taps ▸ Remove…, then Remove)") { c in
            let name = try c.arg(0, "tap")
            c.store.openTaps()
            try await c.loadTaps()
            guard let t = c.tap(name) else { throw ScriptFailure("no tap \(name)") }
            let removal = c.store.taps.requestRemove(t, packages: c.store.packages)
            guard removal.isAllowed else { throw ScriptFailure(removal.reason ?? "remove not allowed") }
            await c.snapshot("confirm")
            try await c.runSession("untap \(name)") { c.store.confirmRemoveTap() }
            c.store.prepareTaps()
            try await c.loadTaps()
            c.check("\(name) untapped", c.tap(name)?.tapped != true)
        },

        // MARK: settings
        "set": ScriptStepDef("set <setting> on|off  (\(ScriptContext.settingNames.joined(separator: ", ")))") { c in
            let name = try c.arg(0, "setting")
            let v = try c.arg(1, "on|off")
            guard ["on", "off"].contains(v) else { throw ScriptFailure("set \(name): on or off, not \(v)") }
            try c.setSetting(name, v == "on")
        },

        // MARK: checks and evidence
        "expect": ScriptStepDef("expect installed <name> [version] | not-installed <name> | pinned <name> | not-pinned <name> | kegs <name> <n> | tap <t> | no-tap <t> | tap-trusted <t> on|off | setting <name> on|off | no-error | no-process <text>") { c in
            try await c.expect()
        },
        "snapshot": ScriptStepDef("snapshot [label]") { c in
            await c.snapshot(c.arg(0) ?? "")
        },
        "sleep": ScriptStepDef("sleep <seconds>") { c in
            try await Task.sleep(for: .seconds(Double(try c.arg(0, "seconds")) ?? 1))
        },
        "close-sheets": ScriptStepDef("close-sheets  (Done / Close on whatever is open)") { c in
            c.store.closeUpgrade()
            c.store.insights.postInstallNotes = nil
            c.store.restorePoints.isShowing = false
            c.store.toolSheet = nil
        },
        "quit": ScriptStepDef("quit  (ends the script; the app quits after any script)") { _ in },
    ] }
}

extension ScriptContext {
    func kind(_ i: Int) throws -> PackageKind {
        switch try arg(i, "formula|cask") {
        case "formula": return .formula
        case "cask": return .cask
        default: throw ScriptFailure("expected formula or cask, got \(args[i])")
        }
    }

    func watchName(_ name: String) { runner.watch(name) }

    /// Reads the tap list and waits for it. openTaps() starts its own read
    /// too; whichever finishes last wins (TapsStore's load token), so wait
    /// for the store to settle rather than for one call.
    func loadTaps() async throws {
        store.prepareTaps()
        await store.taps.load()
        try await waitUntil("the tap list", timeout: 60) { store.taps.phase == .ready && !store.taps.taps.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        await store.taps.load()
    }

    func tap(_ name: String) -> TapInfo? { store.taps.taps.first { $0.name.lowercased() == name.lowercased() } }

    /// Opens Discover (as the tab does) and waits for the catalog.
    func openDiscover(kind: String?) async throws -> DiscoverStore {
        store.tab = .discover
        guard let d = store.openDiscover() else { throw ScriptFailure("Discover needs brew's status first") }
        await d.activate()
        if case .failed(let m) = d.phase { throw ScriptFailure("Discover failed to load: \(m)") }
        switch kind {
        case "formulae"?: d.kind = .formulae
        case "casks"?: d.kind = .casks
        default: d.kind = .all
        }
        return d
    }

    /// Pin or Unpin (the detail pane's button), then the re-read.
    func setPinned(_ on: Bool) async throws {
        let p = try requirePackage(try arg(0, "name"))
        store.reveal(p.id)
        store.setPinned(p, on)
        // Done when brew ran and the re-read shows it, or it said why not.
        try await waitUntil("brew \(on ? "pin" : "unpin")", timeout: 120) {
            store.quickAction == nil && !store.isRefreshing
                && (store.packages.first { $0.id == p.id }?.pinned == on || store.error != nil || store.busyNotice != nil)
        }
        if let n = store.busyNotice { throw ScriptFailure("didn't start: \(n)") }
        try await settle()
        check("\(p.name) \(on ? "pinned" : "unpinned")", package(p.name, kind: p.kind)?.pinned == on)
        check("no error", store.error == nil, store.error?.detail)
    }

    static let settingNames = ["keepPreviousVersion", "scanVulnerabilitiesOnRefresh", "includeSelfUpdatingApps",
                               "dontQuitAppsDuringUpgrade", "notifyNewVulnerabilities", "showMenuBarIcon",
                               "notifyNewUpgrades", "appManagementExplained"]

    /// The Settings window's toggles (the same properties its bindings write).
    func setSetting(_ name: String, _ on: Bool) throws {
        let s = store
        switch name {
        case "keepPreviousVersion": s.restorePoints.settings.keepPreviousVersion = on
        case "scanVulnerabilitiesOnRefresh": s.insights.settings.scanVulnerabilitiesOnRefresh = on
        case "includeSelfUpdatingApps": s.insights.settings.includeSelfUpdatingApps = on
        case "dontQuitAppsDuringUpgrade": s.insights.settings.dontQuitAppsDuringUpgrade = on
        case "notifyNewVulnerabilities": s.insights.settings.notifyNewVulnerabilities = on
        case "showMenuBarIcon": s.settings.showMenuBarIcon = on
        case "notifyNewUpgrades": s.settings.notifyNewUpgrades = on
        case "appManagementExplained": s.settings.appManagementExplained = on
        default: throw ScriptFailure("unknown setting \(name) (one of \(Self.settingNames.joined(separator: ", ")))")
        }
        let stored = storedSetting(name)
        check("\(name) saved as \(on ? "on" : "off")", stored == on)
    }

    /// A setting as UserDefaults has it (a fresh settings object reads it back).
    func storedSetting(_ name: String) -> Bool? {
        let d = store.settings.defaults
        return switch name {
        case "keepPreviousVersion": RollbackSettings(defaults: d).keepPreviousVersion
        case "showMenuBarIcon", "notifyNewUpgrades", "appManagementExplained":
            AppSettings(defaults: d)[keyPath: name == "showMenuBarIcon" ? \AppSettings.showMenuBarIcon
                : name == "notifyNewUpgrades" ? \AppSettings.notifyNewUpgrades : \AppSettings.appManagementExplained]
        default: InsightSettings(defaults: d)[keyPath: name == "scanVulnerabilitiesOnRefresh" ? \InsightSettings.scanVulnerabilitiesOnRefresh
            : name == "includeSelfUpdatingApps" ? \InsightSettings.includeSelfUpdatingApps
            : name == "dontQuitAppsDuringUpgrade" ? \InsightSettings.dontQuitAppsDuringUpgrade : \InsightSettings.notifyNewVulnerabilities]
        }
    }

    func expect() async throws {
        let what = try arg(0, "what")
        switch what {
        case "installed":
            let name = try arg(1, "name")
            let p = package(name)
            check("\(name) installed", p != nil)
            if let v = arg(2), let p { check("\(name) is \(v)", p.installedVersion == v, p.installedVersion) }
        case "not-installed":
            let name = try arg(1, "name")
            check("\(name) not installed", package(name) == nil)
        case "pinned", "not-pinned":
            let p = try requirePackage(try arg(1, "name"))
            check("\(p.name) \(what)", p.pinned == (what == "pinned"))
        case "kegs":
            let p = try requirePackage(try arg(1, "name"))
            let n = Int(try arg(2, "count")) ?? -1
            check("\(p.name) has \(n) keg(s)", p.installedVersions.count == n, p.installedVersions.joined(separator: ", "))
        case "tap", "no-tap":
            let name = try arg(1, "tap")
            try await loadTaps()
            let tapped = tap(name)?.tapped == true
            check("\(name) \(what == "tap" ? "tapped" : "not tapped")", tapped == (what == "tap"))
        case "setting":
            let name = try arg(1, "setting")
            guard Self.settingNames.contains(name) else { throw ScriptFailure("unknown setting \(name)") }
            let want = try arg(2, "on|off") == "on"
            check("\(name) is \(want ? "on" : "off") after launch", storedSetting(name) == want)
        case "tap-trusted":
            let name = try arg(1, "tap")
            let want = try arg(2, "on|off") == "on"
            try await loadTaps()
            check("\(name) \(want ? "trusted" : "not trusted")", (tap(name)?.trusted ?? false) == want, "\(String(describing: tap(name)?.trusted))")
        case "no-error":
            check("no error banner", store.error == nil, store.error.map { $0.title + ": " + $0.detail })
        case "no-process":
            let text = try arg(1, "text")
            let found = Self.processes(matching: text)
            check("no process matching '\(text)'", found.isEmpty, found.joined(separator: "; "))
        default:
            throw ScriptFailure("expect: unknown check \(what)")
        }
    }

    /// Command lines of this app's descendant processes that contain
    /// `text`. Only descendants: another run's (or the user's own) brew on
    /// the same Mac isn't this run's leftover. e2e.sh checks for orphans
    /// after the app quit (the pids it saw under the app).
    nonisolated static func processes(matching text: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return ["ps failed: \(error)"] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return processes(matching: text, psOutput: String(decoding: data, as: UTF8.self),
                         root: ProcessInfo.processInfo.processIdentifier, excluding: [p.processIdentifier])
    }

    /// `ps -o pid=,ppid=,command=` lines: those under `root` (not root
    /// itself) whose command contains `text`, as "pid command".
    nonisolated static func processes(matching text: String, psOutput: String, root: Int32, excluding: Set<Int32> = []) -> [String] {
        var rows: [(pid: Int32, ppid: Int32, command: String)] = []
        for line in psOutput.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            rows.append((pid, ppid, String(f[2])))
        }
        var children: [Int32: [Int32]] = [:]
        for r in rows { children[r.ppid, default: []].append(r.pid) }
        var under = Set<Int32>()
        var stack = children[root] ?? []
        while let pid = stack.popLast() {
            guard under.insert(pid).inserted else { continue }
            stack += children[pid] ?? []
        }
        return rows.filter { under.contains($0.pid) && !excluding.contains($0.pid) && $0.command.contains(text) }
            .map { "\($0.pid) \($0.command)" }
    }
}
