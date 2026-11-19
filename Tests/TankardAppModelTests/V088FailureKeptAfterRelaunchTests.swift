import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.8 (final gauntlet, bug 3): refresh offline, back online, ⌘Q,
// relaunch: only "Updated just now" showed, though no brew update had
// succeeded since. The failure is saved, so the next launch (same settings,
// the saved list) shows it until the next update or Dismiss.
extension AppStoreTests {
    @MainActor
    func relaunched(_ settings: AppSettings, cache: StatusCache, log: CallLog,
                    stream: @escaping @Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32 = { _, _ in 0 }) -> AppStore {
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: FakeStreamRunner(log: log, behaviour: stream),
                                         cache: cache, logURL: nil, ttl: 3600, now: { Date() })
        return AppStore(deps: deps, settings: settings)
    }

    @Test func theUpdateFailureSurvivesARelaunch() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings()
        let cache = StatusCache(url: dir.appendingPathComponent("status.json"))
        let first = relaunched(settings, cache: cache, log: CallLog(), stream: Self.offlineUpdate)
        await first.start()
        await first.refresh(manual: true)
        let failed = try #require(first.error)
        #expect(failed.fromRefresh)
        #expect(settings.lastUpdateFailure != nil)

        // Relaunch: the fresh cache is shown, no brew read, no update.
        let log = CallLog()
        let second = relaunched(AppSettings(defaults: settings.defaults), cache: cache, log: log)
        await second.start()
        #expect(second.reportFromCache)
        #expect(log.count("update") == 0)
        #expect(second.error == failed)
        // A read without an update keeps it, as within a session.
        await second.refresh(manual: false)
        #expect(second.error == failed)
    }

    @Test func aGoodUpdateOrDismissEndsTheSavedFailure() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings()
        let cache = StatusCache(url: dir.appendingPathComponent("status.json"))
        let first = relaunched(settings, cache: cache, log: CallLog(), stream: Self.offlineUpdate)
        await first.start()
        await first.refresh(manual: true)
        #expect(first.error != nil)

        // Dismiss: gone at the next launch too.
        first.dismissError()
        #expect(settings.lastUpdateFailure == nil)
        let afterDismiss = relaunched(AppSettings(defaults: settings.defaults), cache: cache, log: CallLog())
        await afterDismiss.start()
        #expect(afterDismiss.error == nil)

        // Failed again, then a good update: gone, and at the next launch.
        let failing = relaunched(AppSettings(defaults: settings.defaults), cache: cache, log: CallLog(), stream: Self.offlineUpdate)
        await failing.refresh(manual: true)
        #expect(failing.error != nil)
        let online = relaunched(AppSettings(defaults: settings.defaults), cache: cache, log: CallLog())
        #expect(online.updateFailure != nil)
        await online.refresh(manual: true)
        #expect(online.error == nil)
        #expect(settings.lastUpdateFailure == nil)
        let last = relaunched(AppSettings(defaults: settings.defaults), cache: cache, log: CallLog())
        await last.start()
        #expect(last.error == nil)
    }

    /// An update that succeeded outside the store after the failure (a
    /// background check's, `lastBrewUpdate`) drops the saved failure.
    @Test func aLaterSuccessfulUpdateElsewhereDropsIt() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings()
        let cache = StatusCache(url: dir.appendingPathComponent("status.json"))
        let first = relaunched(settings, cache: cache, log: CallLog(), stream: Self.offlineUpdate)
        await first.start()
        await first.refresh(manual: true)
        #expect(settings.lastUpdateFailure != nil)
        settings.lastBrewUpdate = Date().addingTimeInterval(1)
        let second = relaunched(AppSettings(defaults: settings.defaults), cache: cache, log: CallLog())
        await second.start()
        #expect(second.error == nil)
        #expect(settings.defaults.data(forKey: "lastUpdateFailure") == nil)
    }
}
