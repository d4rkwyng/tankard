import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.3: the self-upgrade relaunch (never two Tankards), the single-instance
// guard, the quiet mode once brew replaced Tankard's own bundle, and the
// tankard cask found when the status cache predates it.

@MainActor
struct V083SelfUpdateTests {
    // MARK: relaunch sequencing

    /// A fake run loop: `after` queues, `step` runs the next one.
    @MainActor final class Clock {
        var queue: [(TimeInterval, @MainActor () -> Void)] = []
        var events: [String] = []
        func after(_ d: TimeInterval, _ f: @escaping @MainActor () -> Void) { queue.append((d, f)) }
        @discardableResult func step() -> Bool {
            guard !queue.isEmpty else { return false }
            let (d, f) = queue.removeFirst()
            events.append("wait \(d)")
            f()
            return true
        }
    }

    func sequence(_ c: Clock, helper: Bool = true) -> RelaunchSequence {
        RelaunchSequence(startHelper: { c.events.append("helper"); return helper },
                         closeSheets: { c.events.append("close sheets") },
                         terminate: { c.events.append("terminate") },
                         after: { c.after($0, $1) },
                         gaveUp: { c.events.append("gave up") })
    }

    @Test func relaunchStartsTheWaitingHelperThenClosesSheetsThenTerminates() {
        let c = Clock()
        #expect(sequence(c).run())
        // The helper first (it only waits for this pid), sheets closed at
        // once, terminate on the next turn, after the sheets' dismissal.
        #expect(c.events == ["helper", "close sheets"])
        c.step()
        #expect(c.events == ["helper", "close sheets", "wait 0.2", "terminate"])
        // A terminate that works ends the process: nothing else runs.
    }

    @Test func aRefusedTerminateIsRetriedOnceThenGivesUpWithoutOpening() {
        let c = Clock()
        _ = sequence(c).run()
        while c.step() {}
        #expect(c.events == ["helper", "close sheets", "wait 0.2", "terminate",
                             "wait 1.5", "close sheets", "terminate", "wait 1.5", "gave up"])
        #expect(!c.events.contains { $0.contains("open") })
    }

    @Test func noHelperNoQuit() {
        let c = Clock()
        #expect(!sequence(c, helper: false).run())
        #expect(c.events == ["helper"])
        #expect(c.queue.isEmpty)
    }

    /// The real helper script: it opens only after the pid has exited, and
    /// with the pid still alive after the wait it opens nothing.
    @Test func helperOpensOnlyAfterThePidExits() async throws {
        func run(_ cmd: (executable: String, arguments: [String])) throws -> (Int32, String, Date) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cmd.executable)
            p.arguments = cmd.arguments
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            try p.run()
            let data = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self), Date())
        }
        // A pid that lives ~0.6 s; the bundle path doesn't exist, so the
        // final `open -n` fails loudly: proof it was reached, and when.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.6"]
        try sleeper.run()
        let started = Date()
        let missing = "/nonexistent/tankard-relaunch-test-\(UUID().uuidString).app"
        let (status, err, ended) = try run(AppManagement.relaunchCommand(bundlePath: missing, pid: sleeper.processIdentifier, waitTenths: 50))
        #expect(ended.timeIntervalSince(started) >= 0.5)
        #expect(!sleeper.isRunning)
        #expect(status != 0)
        #expect(!err.contains("still running"))
        #expect(err.contains("tankard-relaunch-test"), "open -n ran after the pid exited: \(err)")

        // Still alive after the wait: nothing opened.
        let alive = Process()
        alive.executableURL = URL(fileURLWithPath: "/bin/sleep")
        alive.arguments = ["5"]
        try alive.run()
        defer { alive.terminate() }
        let (s2, e2, _) = try run(AppManagement.relaunchCommand(bundlePath: missing, pid: alive.processIdentifier, waitTenths: 3))
        #expect(s2 == 1)
        #expect(e2.contains("still running"))
        #expect(!e2.contains("tankard-relaunch-test"))
    }

    // MARK: single-instance guard

    let written = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func noOtherCopyProceeds() {
        #expect(SingleInstance.decide(others: [], executableWritten: written) == .proceed)
        // Dev runs (demo, snapshot, script) never count.
        let dev = SingleInstance.Other(pid: 9, launchDate: written.addingTimeInterval(60), isDevRun: true)
        #expect(SingleInstance.decide(others: [dev], executableWritten: written) == .proceed)
    }

    @Test func aSameBuildSecondLaunchYieldsToTheRunningCopy() {
        let first = SingleInstance.Other(pid: 42, launchDate: written.addingTimeInterval(3600))
        #expect(SingleInstance.decide(others: [first], executableWritten: written) == .yield(to: 42))
    }

    @Test func aCopyLaunchedBeforeTheBundleWasReplacedIsStale() {
        // 0.8.2's Relaunch opened the new copy before quitting the old one.
        let old = SingleInstance.Other(pid: 7, launchDate: written.addingTimeInterval(-600))
        #expect(SingleInstance.decide(others: [old], executableWritten: written) == .replaceStale([7]))
    }

    @Test func aCurrentCopyWinsOverStaleOnesAndUnknownDatesAreSameBuild() {
        let old = SingleInstance.Other(pid: 7, launchDate: written.addingTimeInterval(-600))
        let current = SingleInstance.Other(pid: 8, launchDate: written.addingTimeInterval(5))
        #expect(SingleInstance.decide(others: [old, current], executableWritten: written) == .yield(to: 8))
        let undated = SingleInstance.Other(pid: 9, launchDate: nil)
        #expect(SingleInstance.decide(others: [undated], executableWritten: written) == .yield(to: 9))
        #expect(SingleInstance.decide(others: [old], executableWritten: nil) == .yield(to: 7))
    }

    /// unzip and brew's move keep the build's modification time; the
    /// status-change time says when the file reached this disk.
    @Test func writtenDateIgnoresAnOldModificationTime() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("Tankard").path
        FileManager.default.createFile(atPath: f, contents: Data("x".utf8))
        let before = Date().addingTimeInterval(-5)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: f)
        let w = try #require(SingleInstance.writtenDate(path: f))
        #expect(w > before)
        #expect(SingleInstance.writtenDate(path: dir.appendingPathComponent("missing").path) == nil)
    }

    @Test func devRunsAreRecognisedFromTheEnvironment() {
        #expect(!SingleInstance.isDevRun(environment: [:]))
        #expect(!SingleInstance.isDevRun(environment: ["TANKARD_DEMO": ""]))
        #expect(SingleInstance.isDevRun(environment: ["TANKARD_DEMO": "intelbrew"]))
        #expect(SingleInstance.isDevRun(environment: ["TANKARD_DEMO_NOBREW": "intel"]))
        #expect(SingleInstance.isDevRun(environment: ["TANKARD_SNAPSHOT": "/tmp/x.png"]))
        #expect(SingleInstance.isDevRun(environment: ["TANKARD_E2E": "1", "TANKARD_SCRIPT": "/tmp/s"]))
        // The self-update e2e acts as the real app.
        #expect(!SingleInstance.isDevRun(environment: ["TANKARD_E2E": "1", "TANKARD_SCRIPT": "/tmp/s", "TANKARD_E2E_SELFUPDATE": "1"]))
        #expect(!SingleInstance.isDevRun(environment: ["TANKARD_E2E": "1"]))
    }

    @Test func procArgsAreParsed() {
        var b: [UInt8] = [2, 0, 0, 0]
        b += Array("/Applications/Tankard.app/Contents/MacOS/Tankard".utf8) + [0, 0, 0, 0]
        b += Array("Tankard".utf8) + [0] + Array("-ApplePersistenceIgnoreState".utf8) + [0]
        b += Array("TANKARD_DEMO=arm64".utf8) + [0] + Array("PATH=/usr/bin:/bin".utf8) + [0] + Array("EMPTY=".utf8) + [0, 0]
        #expect(SingleInstance.parseProcArgs(b) == ["TANKARD_DEMO": "arm64", "PATH": "/usr/bin:/bin", "EMPTY": ""])
        #expect(SingleInstance.parseProcArgs([1, 0]) == nil)
        // This process's own, read the way the guard reads another's.
        let own = SingleInstance.environment(pid: ProcessInfo.processInfo.processIdentifier)
        #expect(own?["PATH"] == ProcessInfo.processInfo.environment["PATH"])
    }

    // MARK: quiet mode after the self-upgrade

    func demoStore(relaunch: (@MainActor @Sendable () -> Bool)? = nil) async -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0.01)
        deps.relaunch = relaunch
        deps.updateFeed = UpdateFeed { (Data(#"{"tag_name":"v9.9.9"}"#.utf8), 200) }
        let settings = testSettings()
        settings.appManagementExplained = true
        let store = AppStore(deps: deps, settings: settings)
        await store.start()
        return store
    }

    @Test func afterTheOwnCaskUpgradesOnlyTheRelaunchOfferRemains() async throws {
        let store = await demoStore()
        let read = store.lastUpdated
        let cask = AppStore.demoTankardCask(bundlePath: "/Applications/Tankard.app")
        store.startSession(.upgrade, packages: [cask])
        let session = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { session.isFinished })
        #expect(store.selfReplaced)
        #expect(store.offerRelaunch)
        // No reconcile re-read, now or on any trigger.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!store.isRefreshing)
        await store.refresh(manual: false)
        await store.refresh(manual: true)
        store.revalidateIfStale()
        #expect(store.lastUpdated == read)
        #expect(!(await store.runBackgroundUpdate()))
        // No new brew command, no update check, Done shows no notes.
        #expect(store.isBusy)
        store.closeUpgrade()
        #expect(store.upgrade == nil)
        let other = try #require(store.packages.first { $0.kind == .formula })
        store.startSession(.upgrade, packages: [other])
        #expect(store.upgrade == nil)
        store.checkForTankardUpdates()
        #expect(store.selfUpdate == nil && !store.showSelfUpdate)
        #expect(store.insights.postInstallNotes == nil)
    }

    @Test func anotherCaskUpgradeStillReconciles() async throws {
        let store = await demoStore()
        let cask = try #require(store.packages.first { $0.kind == .cask && $0.upgradeAvailable })
        store.startSession(.upgrade, packages: [cask])
        let session = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { session.isFinished })
        #expect(!store.selfReplaced && !store.offerRelaunch)
        #expect(!store.isBusy || store.isRefreshing)
    }

    @Test func relaunchGoesThroughTheHelperAndSaysSoWhenItCant() async {
        let calls = CallLog()
        let store = await demoStore(relaunch: { calls.add(["relaunch"]); return true })
        store.offerRelaunch = true
        store.relaunchAfterSelfUpgrade()
        #expect(calls.count("relaunch") == 1)
        #expect(!store.offerRelaunch)
        #expect(store.error == nil)
        // No helper (a build outside an app bundle) or it didn't start.
        let none = await demoStore()
        none.relaunchAfterSelfUpgrade()
        #expect(none.error?.title == "Couldn't relaunch Tankard")
        store.relaunchGaveUp()
        #expect(store.error?.detail == AppStore.quitAndReopen)
    }

    // MARK: the tankard cask with a status cache from before it

    func infoWithTankardCask(appPath: String) throws -> Data {
        var root = try #require(try JSONSerialization.jsonObject(with: demoIntelInfo()) as? [String: Any])
        var casks = root["casks"] as? [[String: Any]] ?? []
        casks.append(["token": "tankard", "full_token": "d4rkwyng/tap/tankard", "name": ["Tankard"], "tap": "d4rkwyng/tap",
                      "version": "0.8.4", "installed": "0.8.3", "installed_time": 1_800_000_000, "outdated": true,
                      "artifacts": [["app": ["Tankard.app"], "target": appPath]]])
        root["casks"] = casks
        return try JSONSerialization.data(withJSONObject: root)
    }

    @Test func theUpdateSheetRereadsWhenTheCaskroomHasTankardButTheCachedListDoesnt() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = "/Applications/Tankard.app"
        let log = CallLog()
        let info = FakeInfoRunner(log: log, info: demoIntelInfo())
        let client = makeClient(info)
        let cache = StatusCache(url: dir.appendingPathComponent("status.json"))
        var deps = AppStore.Dependencies(makeClient: { client }, streamRunner: FakeStreamRunner(log: log) { _, _ in 0 },
                                         cache: cache, logURL: nil)
        deps.bundlePath = app
        deps.updateFeed = UpdateFeed { (Data(#"{"tag_name":"v0.8.4"}"#.utf8), 200) }
        deps.selfCaskroomExists = { path in path == intelInstall.prefix + "/Caskroom/tankard" }
        // A cache 10 minutes old, written before the tankard cask was installed.
        var old = try await client.status()
        old.generatedAt = Date().addingTimeInterval(-600)
        try cache.save(old)
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        #expect(store.reportFromCache)
        #expect(store.tankardCask == nil)
        info.info = try infoWithTankardCask(appPath: app)
        let reads = log.count("info")

        store.checkForTankardUpdates()
        #expect(await waitUntil { store.selfUpdate != .checking })
        #expect(log.count("info") == reads + 1)
        #expect(store.tankardCask?.installedVersion == "0.8.3")
        guard case .available(let r)? = store.selfUpdate else { Issue.record("\(String(describing: store.selfUpdate))"); return }
        #expect(r.version == "0.8.4")

        // A zip copy (no tankard in the Caskroom): no extra read.
        var zip = deps
        zip.selfCaskroomExists = { _ in false }
        zip.bundlePath = "/Users/x/Downloads/Tankard.app"
        let z = AppStore(deps: zip, settings: testSettings())
        await z.start()
        let before = log.count("info")
        z.checkForTankardUpdates()
        #expect(await waitUntil { z.selfUpdate != .checking })
        #expect(log.count("info") == before)
        #expect(z.tankardCask == nil)
    }

    @Test func theE2ETapOnlyAcceptsThrowawayNames() {
        #expect(SelfInstall.validE2ETap("tankard-e2e-self/tap") == "tankard-e2e-self/tap")
        #expect(SelfInstall.validE2ETap("d4rkwyng/tap") == nil)
        #expect(SelfInstall.validE2ETap("homebrew/cask") == nil)
        #expect(SelfInstall.validE2ETap("tankard-e2e-x/tap/../y") == nil)
        #expect(SelfInstall.validE2ETap(nil) == nil)
    }

    // MARK: framework callbacks are never main-actor isolated

    /// 0.8.2 crashed in `Relaunch.now()`: the NSWorkspace completion handler
    /// was formed in a @MainActor type, so it was main-actor isolated, and
    /// LaunchServices calls it on its own queue: Swift's runtime isolation
    /// check trapped (EXC_BREAKPOINT in _dispatch_assert_queue_fail). This
    /// lint keeps callbacks Apple frameworks may call off the main thread
    /// explicitly @Sendable (or delivered on the main queue).
    @Test func frameworkCallbacksAreSendable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let risky = ["openApplication(", "NSImage(size:", "terminationHandler", "readabilityHandler", "addObserver(forName:",
                     "withCompletionHandler", "completionHandler:", "setEventHandler", "setCancelHandler", "pathUpdateHandler",
                     "dataTask(", "downloadTask(", "Timer(timeInterval", "Timer.scheduledTimer", "beginSheetModal", "coordinate("]
        var problems: [String] = []
        for dir in ["Sources/TankardApp", "Sources/TankardAppModel"] {
            let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path).filter { $0.hasSuffix(".swift") }
            for f in files {
                let text = try String(contentsOf: root.appendingPathComponent(dir).appendingPathComponent(f), encoding: .utf8)
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = line.components(separatedBy: "//").first ?? ""
                    // A closure on the line (a delegate method's own declaration isn't one).
                    guard risky.contains(where: code.contains), code.contains("{"), !code.contains("func "), !code.contains("@escaping") else { continue }
                    // Safe: an explicit @Sendable closure, or delivery on the main queue.
                    if code.contains("@Sendable") || code.contains("queue: .main") { continue }
                    problems.append("\(dir)/\(f):\(i + 1): \(code.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(problems.isEmpty, "closures a framework may call off the main thread must be @Sendable:\n\(problems.joined(separator: "\n"))")
    }
}
