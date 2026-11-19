import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.8 (gauntlet 15): offline, an install sat at "Downloading bottle
// manifests" for about five minutes with no hint. After 30 s with no
// output and no download progress, the sheet says brew can't reach the
// network yet and keeps retrying.

extension V084SessionSubtitleTests {
    @Test func aStalledDownloadSaysTheNetworkIsUnreachable() async throws {
        let r = try rig { args, out in
            if args.first == "upgrade" {
                out(Data("==> Downloading bottle manifests\n".utf8))
                try? await Task.sleep(for: .seconds(2))
                return 1
            }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade()
        let s = try #require(r.store.upgrade)
        #expect(await waitUntil { s.current != nil && s.log.lines.contains("==> Downloading bottle manifests") })
        let last = try #require(s.lastActivityAt)
        // Not yet: under 30 s since the last line.
        #expect(s.networkHint(at: last.addingTimeInterval(10)) == nil)
        let hint = try #require(s.networkHint(at: last.addingTimeInterval(UpgradeSession.networkHintAfter + 1)))
        #expect(hint.contains("Can't reach the network yet"))
        #expect(await waitUntil { s.isFinished })
        // Finished: never.
        #expect(s.networkHint(at: Date().addingTimeInterval(600)) == nil)
    }

    @Test func aQuietStepThatIsNotDownloadingGetsNoHint() async throws {
        let r = try rig { args, out in
            if args.first == "upgrade" {
                out(Data("==> Pouring xz--5.8.1.bottle.tar.gz\n".utf8))
                try? await Task.sleep(for: .seconds(1))
            }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade()
        let s = try #require(r.store.upgrade)
        #expect(await waitUntil { s.current != nil && s.log.lines.contains { $0.hasPrefix("==> Pouring") } })
        #expect(s.networkHint(at: Date().addingTimeInterval(120)) == nil)
        #expect(await waitUntil { s.isFinished })
    }
}
