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
