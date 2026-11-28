import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

@MainActor
struct V094DownloadIdentitySessionTests {
    private typealias Harness = V0100DownloadSpeedSessionTests
    private let harness = Harness()

    private func pollUntilStalled(_ r: Harness.Run, expectedBytes: Int64) async {
        for tick in 0...12 {
            await harness.poll(r, at: Double(tick) / 2)
        }
        #expect(r.session.download?.bytes == expectedBytes)
        #expect(r.session.downloadRate(at: r.clock.date) == .stalled)
    }

    @Test func differentFinalEndsStallWithItsFullTransferRate() async {
        let r = await harness.start()
        defer { r.finish.release() }
        r.folder.set(Harness.file, size: 20_000_000)
        r.folder.set(Harness.otherFile, size: 10_000_000)
        await pollUntilStalled(r, expectedBytes: 30_000_000)
        r.folder.remove(Harness.file)
        r.folder.set(Harness.done, size: 20_000_000)
        await harness.poll(r, at: 6.25)

        #expect(r.session.download?.bytes == 30_000_000)
        #expect(r.session.download?.files == 1)
        #expect(r.session.downloadRate(at: r.clock.date) == .measuring(bytesPerSecond: 3_200_000))
        #expect(r.session.statusLine.hasSuffix(" · 3.2 MB/s"))
        #expect(await r.watcher.fallbackCount == 0)
    }

    @Test func recreatedPartialEndsStallAtOneMegabyte() async {
        let r = await harness.start()
        defer { r.finish.release() }
        r.folder.set(Harness.file, size: 20_000_000)
        await pollUntilStalled(r, expectedBytes: 20_000_000)
        r.folder.remove(Harness.file)
        r.folder.set(Harness.file, size: 1_000_000)
        await harness.poll(r, at: 6.25)

        #expect(r.session.download?.bytes == 1_000_000)
        #expect(r.session.download?.files == 1)
        #expect(r.session.downloadRate(at: r.clock.date) == .measuring(bytesPerSecond: 160_000))
        #expect(await r.watcher.fallbackCount == 0)
    }

    @Test func deletingPartialBesideBaselineFinalLeavesSessionStalled() async {
        let r = await harness.start()
        defer { r.finish.release() }
        r.folder.set(Harness.done, size: 100_000_000)
        r.folder.set(Harness.file, size: 20_000_000)
        r.folder.set(Harness.otherFile, size: 10_000_000)
        await pollUntilStalled(r, expectedBytes: 30_000_000)
        r.folder.remove(Harness.file)
        await harness.poll(r, at: 6.25)

        #expect(r.session.download?.bytes == 10_000_000)
        #expect(r.session.download?.files == 1)
        #expect(r.session.downloadRate(at: r.clock.date) == .stalled)
        #expect(await r.watcher.fallbackCount == 0)
    }

    @Test func newFinalBesideARunningPartialEndsStall() async {
        let r = await harness.start()
        defer { r.finish.release() }
        r.folder.set(Harness.file, size: 20_000_000)
        await pollUntilStalled(r, expectedBytes: 20_000_000)
        r.folder.set(Harness.done, size: 25_000_000)
        await harness.poll(r, at: 6.25)

        #expect(r.session.download?.bytes == 20_000_000)
        #expect(r.session.download?.files == 1)
        #expect(r.session.downloadRate(at: r.clock.date) == .measuring(bytesPerSecond: 4_000_000))
        #expect(await r.watcher.fallbackCount == 0)
    }
}
