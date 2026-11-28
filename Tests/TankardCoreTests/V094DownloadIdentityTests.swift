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

/// Every partial path and every final path beside one is judged by its file
/// number on every poll: the same number grew, any other number is a new
/// file (its whole size is new bytes), except the final file that was there
/// when its partial was first seen (the baseline) and the rename of the
/// partial that just ended (the growth since its last poll).
struct V094DownloadPathTests {
    private let final = hashA + "--A.zip"
    private var partial: String { final + ".incomplete" }
    private let other = hashB + "--B.zip.incomplete"
    private let folder = FakeDownloadFolder()
    private let watcher: DownloadWatcher
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var old: Date { start.addingTimeInterval(-3600) }

    init() {
        watcher = DownloadWatcher(directory: "/downloads", reader: folder, since: .distantPast)
    }

    private func id(_ inode: UInt64) -> DownloadFileID { DownloadFileID(device: 7, inode: inode) }

    /// A different final file beside a partial that is still running is a new file.
    @Test func newFinalBesideARunningPartialIsTraffic() async {
        folder.set(partial, size: 20_000_000)
        let first = await watcher.sample()
        folder.set(final, size: 25_000_000, fileID: id(1))

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 20_000_000)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 25_000_000)
        #expect(await watcher.fallbackCount == 0)
    }

    /// A finished file replaced by a different one: the new size shows and counts.
    @Test func replacedFinishedFileShowsAndCountsTheNewFile() async {
        folder.set(partial, size: 20_000_000)
        folder.set(other, size: 10_000_000)
        _ = await watcher.sample()
        folder.set(partial, size: 25_000_000)
        folder.rename(partial, final)
        let done = await watcher.sample()
        #expect(done.progress?.bytes == 35_000_000)
        folder.set(final, size: 40_000_000, fileID: id(1))

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 50_000_000)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - done.traffic == 40_000_000)
        #expect(await watcher.fallbackCount == 0)
    }

    /// The same finished file written over in place: its growth counts, the bar shows its size.
    @Test func finishedFileOverwrittenInPlaceCountsItsGrowth() async {
        folder.set(partial, size: 20_000_000)
        folder.set(other, size: 10_000_000)
        _ = await watcher.sample()
        folder.set(partial, size: 25_000_000)
        folder.rename(partial, final)
        let done = await watcher.sample()
        folder.set(final, size: 30_000_000) // the same file number

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 40_000_000)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - done.traffic == 5_000_000)
        #expect(await watcher.fallbackCount == 0)
    }

    /// An old modification date does not hide a different final file on a watched path.
    @Test func oldDifferentFinalAfterAWatchedPartialCounts() async {
        let w = DownloadWatcher(directory: "/downloads", reader: folder, since: start)
        folder.set(partial, size: 20, modified: start)
        folder.set(other, size: 10, modified: start)
        let first = await w.sample()
        folder.remove(partial)
        folder.set(final, size: 25, modified: old, fileID: id(1))

        let next = await w.sample()
        #expect(next.progress?.bytes == 35)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 25)
        #expect(await w.fallbackCount == 0)
    }

    /// An old modification date does not hide a replacement partial on a watched path.
    @Test func oldReplacementPartialOnAWatchedPathIsANewFile() async {
        let w = DownloadWatcher(directory: "/downloads", reader: folder, since: start)
        folder.set(partial, size: 20, modified: start)
        folder.set(other, size: 10, modified: start)
        let first = await w.sample()
        folder.set(partial, size: 5, modified: old, fileID: id(1))

        let next = await w.sample()
        #expect(next.progress?.bytes == 15)
        #expect(next.progress?.files == 2)
        #expect(next.traffic - first.traffic == 5)
        #expect(await w.fallbackCount == 0)
    }

    /// Two partial names linked to one file count it once.
    @Test func hardLinkedPartialsCountOnce() async {
        folder.set(partial, size: 20, fileID: id(1))
        folder.set(other, size: 20, fileID: id(1))

        let first = await watcher.sample()
        #expect(first.progress?.bytes == 20)
        #expect(first.traffic == 20)
        #expect(await watcher.fallbackCount == 0)
    }

    /// A final file linked to its partial at the first poll is the baseline:
    /// deleting the partial credits nothing.
    @Test func hardLinkedBaselineFinalIsNotCredited() async {
        folder.set(final, size: 20, fileID: id(1))
        folder.set(partial, size: 20, fileID: id(1))
        folder.set(other, size: 10)
        let first = await watcher.sample()
        #expect(first.traffic == 30)
        folder.remove(partial)

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 10)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 0)
        #expect(await watcher.fallbackCount == 0)
    }

    /// A file number used again after its file is gone is a new file, and
    /// gone paths are not kept.
    @Test func reusedFileNumberAfterTheFileIsGone() async {
        folder.set(partial, size: 20, fileID: id(1))
        folder.set(other, size: 10)
        _ = await watcher.sample()
        folder.rename(partial, final)
        _ = await watcher.sample()
        folder.remove(final)
        let gone = await watcher.sample()
        #expect(gone.progress?.bytes == 10)
        #expect(await watcher.trackedPathCount == 1)
        folder.set(partial, size: 5, fileID: id(1))
        let running = await watcher.sample()
        #expect(running.traffic - gone.traffic == 5)
        folder.set(partial, size: 8)
        folder.rename(partial, final)

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 18)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - gone.traffic == 8)
        #expect(await watcher.trackedPathCount == 2)
        #expect(await watcher.fallbackCount == 0)
    }

    /// A baseline final without a file number that went away and came back
    /// with a different known number is a new file, whatever its size.
    @Test func returnedFinalWithAKnownNumberIsANewFile() async {
        folder.set(partial, size: 20)
        folder.set(final, size: 3, fileID: nil)
        folder.set(other, size: 10)
        _ = await watcher.sample()
        folder.remove(final)
        let gone = await watcher.sample()
        folder.remove(partial)
        folder.set(final, size: 5, fileID: id(1))

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 15)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - gone.traffic == 5)
    }

    /// The partial has no file number, the final has one: name and size decide.
    @Test func fallbackWithoutThePartialsNumber() async {
        folder.set(partial, size: 20, fileID: nil)
        folder.set(other, size: 10)
        let first = await watcher.sample()
        let before = await watcher.fallbackCount
        folder.remove(partial)
        folder.set(final, size: 25, fileID: id(1))

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 35)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 5)
        #expect(await watcher.fallbackCount > before)
    }

    /// The partial has a file number, the final has none: name and size decide.
    @Test func fallbackWithoutTheFinalsNumber() async {
        folder.set(partial, size: 20, fileID: id(1))
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
}
