import AskpassSupport
import Foundation
import Observation
import os
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.8, gauntlet 3: the fixes for its findings (B1-B10).

// MARK: B1: the filter control and the Upgrades list from the menu bar

@MainActor
struct V088FilterControlTests {
    func demoStore() async -> AppStore {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        return store
    }

    /// The panel's "N upgrades ready" (and the notification) with the
    /// window just opened on All: the control's own selection is Upgrades,
    /// one of the segments it draws, and a view reading it is invalidated.
    @Test func showUpgradesMovesTheControlsSelection() async throws {
        let store = await demoStore()
        #expect(store.filter == .all)
        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = store.filter } onChange: { invalidated.withLock { $0 = true } }
        store.showFromMenuBar(.upgrades)
        #expect(invalidated.withLock { $0 })
        #expect(store.filter == .upgrades)
        #expect(store.visibleSegmentedFilters.contains(.upgrades))
        let rows = store.visiblePackages
        #expect(!rows.isEmpty && rows.allSatisfy { $0.upgradeAvailable })
        // A click on All afterwards: the list and the control agree again.
        store.filter = .all
        #expect(store.visiblePackages.count == store.packages.count)
        // The panel again: Upgrades once more.
        store.showFromMenuBar(.upgrades)
        #expect(store.filter == .upgrades)
    }

    /// The keyboard: one stop, the arrow keys move the selection and stop
    /// at the ends.
    @Test func arrowKeysStepThroughTheSegments() {
        let all: [PackageFilter] = [.all, .upgrades]
        #expect(SegmentedStep.move(from: PackageFilter.all, in: all, by: 1) == .upgrades)
        #expect(SegmentedStep.move(from: PackageFilter.upgrades, in: all, by: 1) == .upgrades)
        #expect(SegmentedStep.move(from: PackageFilter.upgrades, in: all, by: -1) == .all)
        #expect(SegmentedStep.move(from: PackageFilter.all, in: all, by: -1) == .all)
        #expect(SegmentedStep.move(from: PackageFilter.vulnerable, in: all, by: 1) == .all)
        #expect(SegmentedStep.move(from: PackageFilter.vulnerable, in: all, by: -1) == .upgrades)
        #expect(SegmentedStep.move(from: PackageFilter.all, in: [], by: 1) == nil)
    }
}

// MARK: B2: casks whose uninstall needs sudo; the first Cancel is final

struct V088UninstallSudoTests {
    func cask(_ artifacts: String) throws -> BrewInfoJSON.Cask {
        let json = #"{"token":"hiddenbar","full_token":"hiddenbar","version":"1.13.2","artifacts":"# + artifacts + "}"
        return try JSONDecoder().decode(BrewInfoJSON.Cask.self, from: Data(json.utf8))
    }

    /// hiddenbar's stanza (brew 7): a launchctl service and a quit.
    @Test func launchctlServiceNeedsThePassword() throws {
        let c = try cask(#"[{"uninstall":[{"launchctl":"com.dwarvesv.LauncherApplication","quit":"com.dwarvesv.minimalbar"}]},{"app":["Hidden Bar.app"],"target":"/Applications/Hidden Bar.app"},{"zap":[{"trash":["~/Library/Preferences/com.dwarvesv.minimalbar.plist"]}]}]"#)
        #expect(c.sudoUninstall == true)
        #expect(c.installsPkg == false && c.sudoInstaller == false)
        var p = pkg("hiddenbar", kind: .cask)
        p.sudoUninstall = c.sudoUninstall
        p.installsPkg = false
        #expect(AdminPassword.required(p))
        #expect(AdminPassword.onlyRemovalNeedsSudo(p))
        #expect(AdminPassword.noteText(helper: true, uninstall: false, removal: true).details
            .hasPrefix("brew removes the old version's background service or system files with sudo."))
        // Upgrades with a password go last, so this one does too.
        let order = AdminPassword.passwordStepsLast([p, pkg("rectangle", kind: .cask), pkg("xz")]).map(\.name)
        #expect(order == ["rectangle", "xz", "hiddenbar"])
    }

    @Test func otherSudoDirectivesAndOnesThatDontNeedIt() throws {
        do { let v = try cask(#"[{"uninstall":[{"pkgutil":"audio.existential.BlackHole2ch"}]}]"#).sudoUninstall; #expect(v == true) }
        do { let v = try cask(#"[{"uninstall":[{"kext":"com.x.driver"}]}]"#).sudoUninstall; #expect(v == true) }
        do { let v = try cask(#"[{"uninstall":[{"delete":"/Library/LaunchDaemons/com.x.plist"}]}]"#).sudoUninstall; #expect(v == true) }
        do { let v = try cask(#"[{"uninstall":[{"script":{"executable":"/usr/local/x/uninstall.sh","sudo":true}}]}]"#).sudoUninstall; #expect(v == true) }
        // quit, signal, login_item, a user path, Homebrew's own prefix: no sudo.
        do { let v = try cask(#"[{"uninstall":[{"quit":"com.x.app","signal":["TERM","com.x.app"],"login_item":"X"}]}]"#).sudoUninstall; #expect(v == false) }
        do { let v = try cask(#"[{"uninstall":[{"delete":["~/Library/X","/Applications/X.app","/opt/homebrew/bin/x"]}]}]"#).sudoUninstall; #expect(v == false) }
        // zap runs only with --zap, which Tankard never passes.
        do { let v = try cask(#"[{"zap":[{"launchctl":"com.x.agent","delete":"/Library/X"}]}]"#).sudoUninstall; #expect(v == false) }
        // No artifacts: unknown.
        let none = try JSONDecoder().decode(BrewInfoJSON.Cask.self, from: Data(#"{"token":"x","version":"1"}"#.utf8))
        #expect(none.sudoUninstall == nil)
    }

    typealias T = AskpassTicket
    static let start = T.ProcessStart(sec: 1_790_000_000, usec: 654_321)

    @Test func cancelMarkIsPrivateExactAndGoesWithTheTicket() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-cm-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let dir = base + "/askpass-tickets"
        let me = getpid()
        let start = try #require(T.processStart(me))
        let ticket = T.Ticket(pid: me, start: start)
        let cancels = OSAllocatedUnfairLock(initialState: 0)
        let onCancel: @Sendable () -> Void = { cancels.withLock { $0 += 1 } }
        let issued = T.issue(pid: me, environment: [Askpass.askpassKey: "/x/tankard-askpass"], directory: dir, cancelled: onCancel)
        let revoke = try #require(issued)
        #expect(!T.isCancelled(ticket, in: dir))
        #expect(T.markCancelled(ticket, in: dir))
        #expect(T.markCancelled(ticket, in: dir)) // a second Cancel: already marked
        #expect(T.isCancelled(ticket, in: dir))
        let mode = try FileManager.default.attributesOfItem(atPath: T.cancelPath(ticket, in: dir))[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // The mark is no ticket: the ticket list is unchanged.
        #expect(T.read(in: dir) == [ticket])
        // Another process with the same pid (or another pid): not cancelled.
        #expect(!T.isCancelled(T.Ticket(pid: me, start: Self.start), in: dir))
        #expect(!T.isCancelled(T.Ticket(pid: me + 1, start: start), in: dir))
        // brew exits: the app hears of the cancel once; mark and ticket go.
        revoke()
        #expect(cancels.withLock { $0 } == 1)
        #expect(!FileManager.default.fileExists(atPath: T.cancelPath(ticket, in: dir)))
        #expect(T.read(in: dir).isEmpty)
    }

    @Test func aMarkOthersCouldWriteIsIgnored() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-cm-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let dir = base + "/askpass-tickets"
        let t = T.Ticket(pid: 4242, start: Self.start)
        _ = try #require(T.write(t, in: dir, isAlive: { _ in true }))
        let path = T.cancelPath(t, in: dir)
        try "tankard-askpass-cancelled 1 4242 \(Self.start.sec) \(Self.start.usec)\n".write(toFile: path, atomically: false, encoding: .utf8)
        chmod(path, 0o644)
        #expect(!T.isCancelled(t, in: dir))
        chmod(path, 0o600)
        #expect(T.isCancelled(t, in: dir))
        // A stale ticket's mark is pruned with it.
        _ = T.write(T.Ticket(pid: 4343, start: Self.start), in: dir, isAlive: { $0 != t })
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

extension AdminPasswordTests {
    /// The run: brew removes hiddenbar's launchctl service (sudo, hidden
    /// output), the dialog is cancelled once, brew goes on and exits 0.
    @Test func doneButTheServiceWasNotRemovedIsNotAPlainTick() async throws {
        let cancels = OSAllocatedUnfairLock(initialState: 0)
        let runner = FakeStreamRunner(log: CallLog()) { args, out in
            guard args.first == "upgrade" else { return 0 }
            out(Data("==> Upgrading google-chrome\n==> Removing launchctl service com.google.keystone.agent\n".utf8))
            // The step has started (the session read the count then); the
            // helper's mark is counted when brew exits.
            try? await Task.sleep(for: .milliseconds(400))
            cancels.withLock { $0 += 1 }
            out(Data("==> Moving App 'Google Chrome.app' to '/Applications/Google Chrome.app'\n🍺  google-chrome was successfully upgraded!\n".utf8))
            return 0
        }
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.askpassHelper = Self.helper
        deps.streamRunner = runner
        deps.askpassFocus = AskpassFocus(find: { nil }, yield: { _ in }, cancelCount: { cancels.withLock { $0 } })
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        await #expect(waitUntil { store.upgrade?.isFinished == true })
        let session = try #require(store.upgrade)
        let item = try #require(session.items.first)
        #expect(item.state == .done)
        #expect(session.sudoSkipped[item.id] == ["com.google.keystone.agent"])
        #expect(session.sudoSkippedLine(item) == "google-chrome upgraded, but brew couldn't remove its background service (com.google.keystone.agent) because the password dialog was cancelled.")
        // Without a cancel during the step: a plain done.
        #expect(UpgradeSession.launchctlServices(["==> Removing launchctl service a", "x", "==> Removing launchctl service a"]) == ["a"])
    }

    @Test func noCancelNoMark() async throws {
        let runner = FakeStreamRunner(log: CallLog()) { args, out in
            guard args.first == "upgrade" else { return 0 }
            out(Data("==> Removing launchctl service com.google.keystone.agent\n".utf8))
            return 0
        }
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.askpassHelper = Self.helper
        deps.streamRunner = runner
        deps.askpassFocus = AskpassFocus(find: { nil }, yield: { _ in }, cancelCount: { 7 })
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        await #expect(waitUntil { store.upgrade?.isFinished == true })
        let session = try #require(store.upgrade)
        #expect(session.sudoSkipped.isEmpty)
        #expect(session.items.allSatisfy { session.sudoSkippedLine($0) == nil })
    }
}

// MARK: B4: the password helper is an app of its own (never in the Dock)

struct V088HelperAppTests {
    static let nested = "/Applications/Tankard.app/Contents/Helpers/TankardPassword.app/Contents/MacOS/tankard-askpass"
    static let tankard = "/Applications/Tankard.app/Contents/MacOS/Tankard"

    @Test func theNestedHelperAnswersOnlyToItsOwnTankard() {
        #expect(AskpassGate.expectedTankard(helperPath: Self.nested) == Self.tankard)
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: ["/bin/bash", Self.tankard],
                                   helperPath: Self.nested) == .allow)
        // Another copy's Tankard, a helper app elsewhere, a lookalike folder.
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: ["/tmp/Tankard.app/Contents/MacOS/Tankard"],
                                   helperPath: Self.nested) != .allow)
        #expect(AskpassGate.expectedTankard(helperPath: "/tmp/TankardPassword.app/Contents/MacOS/tankard-askpass") == nil)
        #expect(AskpassGate.expectedTankard(helperPath: "/x/Contents/Helpers/TankardPassword.app/Contents/MacOS/tankard-askpass") == nil)
        // The old place (Contents/MacOS) is no longer the helper's.
        #expect(AskpassGate.expectedTankard(helperPath: "/Applications/Tankard.app/Contents/MacOS/tankard-askpass") == nil)
    }

    @Test func theAppUsesTheNestedHelper() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-ha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let app = base.appendingPathComponent("Tankard.app")
        #expect(Askpass.helperPath(appBundle: app) == nil)
        func make(_ relative: String) throws {
            let url = app.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            chmod(url.path, 0o755)
        }
        try make("Contents/MacOS/tankard-askpass")
        #expect(Askpass.helperPath(appBundle: app) == nil)
        try make(Askpass.helperRelativePath)
        #expect(Askpass.helperPath(appBundle: app) == app.appendingPathComponent(Askpass.helperRelativePath).path)
    }
}

// MARK: B9: background checks while HOMEBREW_NO_AUTO_UPDATE is set

struct V088BackgroundUpdateSettingTests {
    @Test func optedOutShowsOffAndTheIntervalFollows() {
        let source = "~/.zprofile"
        // Saved on, but Homebrew's setting turns it off: shown off.
        #expect(!BackgroundUpdateSetting.shownOn(saved: true, optOut: source))
        #expect(BackgroundUpdateSetting.shownOn(saved: true, optOut: nil))
        #expect(!BackgroundUpdateSetting.shownOn(saved: false, optOut: nil))
        // "Check every": only while something checks.
        #expect(!BackgroundUpdateSetting.intervalEnabled(notify: false, saved: true, optOut: source))
        #expect(BackgroundUpdateSetting.intervalEnabled(notify: true, saved: true, optOut: source))
        #expect(BackgroundUpdateSetting.intervalEnabled(notify: false, saved: true, optOut: nil))
        #expect(!BackgroundUpdateSetting.intervalEnabled(notify: false, saved: false, optOut: nil))
    }
}

// MARK: B6: a failed refresh, then the network (or proxy) fixed

@MainActor
struct V088RefreshRecoveryTests {
    /// What brew doctor printed offline (gauntlet 3, a dead proxy): it
    /// tried to tap homebrew/core and failed; no warnings, no "ready".
    static let offlineDoctor = """
        ==> Tapping homebrew/core
        Cloning into '/opt/homebrew/Library/Taps/homebrew/homebrew-core'...
        fatal: unable to access 'https://github.com/Homebrew/homebrew-core/': Failed to connect to 127.0.0.1 port 3128 after 0 ms: Couldn't connect to server
        Error: Failure while executing; `/usr/bin/env git -c core.hooksPath=/dev/null clone` exited with 128. Here's the output:
        """

    @Test func doctorThatFailedIsNotNoWarnings() {
        let d = DoctorReport.parse(Self.offlineDoctor)
        #expect(d.warnings.isEmpty && !d.ready)
        #expect(d.failure?.hasPrefix("Failure while executing; `/usr/bin/env git") == true)
        // A normal run with warnings, or ready: no failure.
        #expect(DoctorReport.parse("Your system is ready to brew.\n").failure == nil)
        #expect(DoctorReport.parse("Warning: Some installed formulae are deprecated.\n  x\n").failure == nil)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _n = 0
        private var _fail = true
        var n: Int { lock.withLock { _n } }
        var fail: Bool {
            get { lock.withLock { _fail } }
            set { lock.withLock { _fail = newValue } }
        }
        func bump() { lock.withLock { _n += 1 } }
    }

    @Test func aRefreshReReadsBrewsSettingsAndAGoodOneClearsTheFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-b6-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let box = Box()
        let runner = FakeStreamRunner(log: log) { args, output in
            guard args.first == "update" else { output(Data("ok\n".utf8)); return 0 }
            if box.fail {
                output(Data("fatal: unable to access 'https://github.com/Homebrew/brew/': Failed to connect to 127.0.0.1 port 3128\n".utf8))
                return 1
            }
            output(Data("Already up-to-date.\n".utf8))
            return 0
        }
        var deps = AppStore.Dependencies(makeClient: { client }, streamRunner: runner,
                                         cache: StatusCache(url: dir.appendingPathComponent("status.json")),
                                         logURL: dir.appendingPathComponent("upgrade.log"), ttl: 3600, now: { Date() })
        deps.reloadSources = { c in
            box.bump()
            var s = c.sources
            s.process["TANKARD_TEST_RELOADED"] = "\(box.n)"
            return s
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.refresh(manual: true)
        #expect(store.error?.fromRefresh == true)
        #expect(store.upgradeCheckFailed)
        #expect(box.n == 1)
        #expect(store.brewSources?.process["TANKARD_TEST_RELOADED"] == "1")
        // A read without brew update (the window to the front) reads no settings.
        await store.refresh(manual: false)
        #expect(box.n == 1)
        #expect(store.upgradeCheckFailed)
        // The proxy is gone: the next Refresh succeeds and clears it all.
        box.fail = false
        await store.refresh(manual: true)
        #expect(box.n == 2)
        #expect(store.error == nil)
        #expect(!store.upgradeCheckFailed)
        #expect(!store.packages.isEmpty)
        #expect(store.packages.allSatisfy { $0.unreadable == nil })
    }
}

// MARK: B10: polish

@MainActor
struct V088PolishTests {
    @Test func aFilterThatHidesTheSelectionClearsTheDetailPane() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let current = try #require(store.packages.first { !$0.upgradeAvailable })
        let outdated = try #require(store.packages.first { $0.isUpgradeTarget })
        store.selection = current.id
        store.filter = .upgrades
        #expect(store.selection == nil)
        #expect(store.selectedPackage == nil)
        // A package the new filter still shows stays selected.
        store.filter = .all
        store.selection = outdated.id
        store.filter = .upgrades
        #expect(store.selection == outdated.id)
        // Not in the list yet (Show in Installed after an install): kept.
        let missing = Package.ID("formula:not-read-yet")
        store.selection = missing
        store.filter = .all
        store.filter = .upgrades
        #expect(store.selection == missing)
    }

    @Test func sizesOlderThanTheListAndMissingPackagesAreMeasuredAgain() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        var report = try #require(store.report)
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        report.generatedAt = t
        let all = DiskSizes(formulae: Dictionary(uniqueKeysWithValues: report.packages.filter { $0.kind == .formula }.map { ($0.fullName, Int64(1)) }),
                            casks: Dictionary(uniqueKeysWithValues: report.packages.filter { $0.kind == .cask }.map { ($0.fullName, Int64(1)) }),
                            measuredAt: t.addingTimeInterval(-60))
        #expect(!AppStore.sizesIncomplete(report: report, sizes: all))
        var some = all
        some.formulae = Dictionary(uniqueKeysWithValues: some.formulae.prefix(1).map { ($0.key, $0.value) })
        #expect(AppStore.sizesIncomplete(report: report, sizes: some))
        // Measured after the list: not again (brew gave no size for some).
        some.measuredAt = t.addingTimeInterval(1)
        #expect(!AppStore.sizesIncomplete(report: report, sizes: some))
        #expect(!AppStore.sizesIncomplete(report: report, sizes: nil))
    }

    @Test func theMenuItemNamesTheOnePackage() {
        #expect(UpgradeMenu.selectedTitle(nil) == "Upgrade Package")
        #expect(UpgradeMenu.selectedTitle(pkg("wget")) == "Upgrade wget")
    }
}

// MARK: B8: counts follow each language's plural rules

struct V088PluralTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func format(_ key: String, _ lang: String, _ n: Int) throws -> String {
        let dir = Self.root.appendingPathComponent("Sources/TankardApp/Resources/Localizations/\(lang).lproj")
        let bundle = try #require(Bundle(path: dir.path))
        let fmt = bundle.localizedString(forKey: key, value: nil, table: nil)
        return String(format: fmt, locale: Locale(identifier: lang), n)
    }

    /// French counts 0 as singular ("0 service"); English doesn't. Before,
    /// every count was `n == 1 ? singular : plural`.
    @Test func zeroIsSingularInFrenchAndPluralInEnglish() throws {
        #expect(try format("%lld services", "fr", 0) == "0 service")
        #expect(try format("%lld services", "fr", 2) == "2 services")
        #expect(try format("%lld services", "en", 0) == "0 services")
        #expect(try format("%lld services", "en", 1) == "1 service")
        #expect(try format("%lld upgrades ready", "pt-BR", 1).hasPrefix("1 "))
        #expect(try format("%lld hours", "de", 1) == "1 Stunde")
    }

    /// No count string is left as an `n == 1` pair: the singular keys are
    /// gone from the catalog.
    @Test func singularKeysAreGone() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Localizable.xcstrings"))
        let strings = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any])
        for gone in ["%lld service", "1 hour", "%lld upgrade ready", "1 known vulnerability", "Upgrade Selected"] {
            #expect(strings[gone] == nil, "\(gone)")
        }
        #expect(strings["%lld services"] != nil)
    }
}
