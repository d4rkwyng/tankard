import Foundation
import Testing
import TankardCore

struct V094DownloadIdentityTests {
    private let final = hashA + "--A.zip"
    private var partial: String { final + ".incomplete" }
    private let other = hashB + "--B.zip.incomplete"
    private let folder = FakeDownloadFolder()
    private let watcher: DownloadWatcher

    init() {
        watcher = DownloadWatcher(directory: "/downloads", reader: folder, since: .distantPast)
    }

    @Test func differentFinalCountsItsWholeSizeAsTraffic() async {
        folder.set(partial, size: 20_000_000)
        folder.set(other, size: 10_000_000)
        let first = await watcher.sample()
        #expect(first.progress?.bytes == 30_000_000)
        folder.remove(partial)
        folder.set(final, size: 20_000_000)

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 30_000_000)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 20_000_000)
        #expect(await watcher.fallbackCount == 0)
    }

    @Test func recreatedPartialCountsItsWholeSizeAsTraffic() async {
        folder.set(partial, size: 20_000_000)
        let first = await watcher.sample()
        folder.remove(partial)
        folder.set(partial, size: 1_000_000)

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 1_000_000)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 1_000_000)
        #expect(await watcher.fallbackCount == 0)
    }

    @Test func finalPresentAtStartAddsNoTrafficWhenPartialIsDeleted() async {
        folder.set(final, size: 100_000_000)
        folder.set(partial, size: 20_000_000)
        folder.set(other, size: 10_000_000)
        let first = await watcher.sample()
        #expect(first.traffic == 30_000_000)
        folder.remove(partial)

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 10_000_000)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 0)
        #expect(await watcher.fallbackCount == 0)
    }

    @Test func renameOverExistingFinalCreditsOnlyGrowth() async {
        folder.set(final, size: 100_000_000)
        folder.set(partial, size: 20_000_000)
        folder.set(other, size: 10_000_000)
        let first = await watcher.sample()
        folder.set(partial, size: 25_000_000)
        folder.rename(partial, final)

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 35_000_000)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 5_000_000)
        #expect(await watcher.fallbackCount == 0)
    }

    @Test func sameInodeOnAnotherDeviceIsANewFile() async {
        folder.set(partial, size: 20, fileID: DownloadFileID(device: 1, inode: 5))
        folder.set(other, size: 10)
        let first = await watcher.sample()
        folder.remove(partial)
        folder.set(final, size: 25, fileID: DownloadFileID(device: 2, inode: 5))

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 35)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 25)
        #expect(await watcher.fallbackCount == 0)
    }

    @Test func missingIdentityUsesAppearanceAndSizeForRename() async {
        folder.set(partial, size: 20, fileID: nil)
        folder.set(other, size: 10)
        let first = await watcher.sample()
        let before = await watcher.fallbackCount
        folder.remove(partial)
        folder.set(final, size: 25, fileID: nil)

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 35)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 5)
        #expect(await watcher.fallbackCount > before)
    }

    @Test func liveRenamePreservesIdentityAndCreditsAppendedBytes() async throws {
        let manager = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let source = directory.appendingPathComponent(partial)
        let destination = directory.appendingPathComponent(final)
        try Data(repeating: 0x11, count: 20).write(to: source)
        // An empty running download keeps the finished size visible.
        try Data().write(to: directory.appendingPathComponent(other))
        let live = LiveDownloadFolder()
        let watcher = DownloadWatcher(directory: directory.path, reader: live, since: .distantPast)
        let original = try #require(live.stat(source.path)?.fileID)
        let first = await watcher.sample()
        #expect(first.traffic == 20)
        try appendFixtureBytes(to: source)
        try manager.moveItem(at: source, to: destination)

        let renamed = try #require(live.stat(destination.path)?.fileID)
        #expect(renamed == original)
        let next = await watcher.sample()
        #expect(next.progress?.bytes == 27)
        #expect(next.progress?.files == 1)
        #expect(next.traffic == 27)
        #expect(await watcher.fallbackCount == 0)
    }

    private func appendFixtureBytes(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x22, count: 7))
    }
}
