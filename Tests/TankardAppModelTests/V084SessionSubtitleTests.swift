import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.4: a finished sheet with failures says what was done, not the plan
// (a failed download said "1 build from source" though nothing was built).
@MainActor
struct V084SessionSubtitleTests {
    struct Rig {
        var store: AppStore
        var log: CallLog
        var dir: URL
    }

    /// The Intel fixture: openssl@4, python@3.15, sqlite, xz with bottles, ruby from source.
    func rig(stream: @escaping @Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32) throws -> Rig {
        let dir = try tempDir()
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log, behaviour: stream)
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil,
                                         logURL: dir.appendingPathComponent("Logs/upgrade.log"), ttl: 3600, now: { Date() })
        return Rig(store: AppStore(deps: deps), log: log, dir: dir)
    }

    func upgradeAll(_ r: Rig) async throws -> UpgradeSession {
        await r.store.start()
        r.store.startUpgrade()
        let s = try #require(r.store.upgrade)
        #expect(await waitUntil { s.isFinished })
        return s
    }

    @Test func failedSourceDownloadIsNotABuild() async throws {
        let r = try rig { args, out in
            if args.last == "homebrew/core/ruby" {
                out(Data("curl: (37) Couldn't open file /nonexistent/ruby.tar.gz\nError: ruby: Failed to download resource\n".utf8))
                return 1
            }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let s = try await upgradeAll(r)
        #expect(s.failedItems.map(\.package.name) == ["ruby"])
        #expect(s.title == "Upgrade finished with errors")
        // The four bottles were poured; ruby built nothing.
        #expect(s.subtitle == "4 bottles from Intelbrew")
        #expect(!s.subtitle.contains("source"))
    }

    @Test func everythingFailedSaysWhyWhenKnown() async throws {
        let r = try rig { args, out in
            if args.first == "upgrade" {
                out(Data("curl: (6) Could not resolve host: ghcr.io\nError: Failed to download resource\n".utf8))
                return 1
            }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let s = try await upgradeAll(r)
        #expect(s.failedItems.count == 5)
        #expect(s.subtitle == "Homebrew couldn't reach the network")
    }

    @Test func everythingFailedForAnUnknownReason() async throws {
        let r = try rig { args, out in
            if args.first == "upgrade" { out(Data("Error: something odd\n".utf8)); return 1 }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let s = try await upgradeAll(r)
        #expect(s.subtitle == "The log below shows what brew printed")
    }

    @Test func runningAndSuccessfulSessionsStillShowThePlan() async throws {
        let r = try rig { _, _ in 0 }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let s = try await upgradeAll(r)
        #expect(s.failedItems.isEmpty)
        #expect(s.subtitle == "4 bottles from Intelbrew · 1 build from source (ruby)")
    }
}
