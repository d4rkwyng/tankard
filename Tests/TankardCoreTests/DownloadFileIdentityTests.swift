import Foundation
import Testing
import TankardCore

struct DownloadFileIdentityTests {
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
struct DownloadPathObservationTests {
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

/// brew renames a finished file at any moment, also between two reads of
/// one poll: after the folder was listed, or between the stat of the partial
/// file and the stat of the final file.
struct DownloadRenameRaceTests {
    private let final = hashA + "--A.zip"
    private var partial: String { final + ".incomplete" }
    private let other = hashB + "--B.zip.incomplete"
    private let folder = FakeDownloadFolder()
    private let watcher: DownloadWatcher

    init() {
        watcher = DownloadWatcher(directory: "/downloads", reader: folder, since: .distantPast)
    }

    /// The partial grows to `size` and is renamed, as brew does when done.
    private func finish(at size: Int64) {
        folder.set(partial, size: size)
        folder.rename(partial, final)
    }

    /// The next listing is taken, and then the download finishes.
    private func finishAfterTheNextListing(at size: Int64) {
        folder.afterListing = { [self] names in
            folder.afterListing = nil
            finish(at: size)
            return names
        }
    }

    /// The partial is next read at `seen`, and then the download finishes.
    private func finishAfterTheNextPartialStat(seen: Int64, at size: Int64) {
        folder.set(partial, size: seen)
        folder.afterStat = { [self] name in
            guard name == partial else { return }
            folder.afterStat = nil
            finish(at: size)
        }
    }

    /// Renamed after the listing, before the stat of the partial file.
    @Test func renameAfterTheListingIsStillSeen() async {
        folder.set(partial, size: 20_000_000)
        folder.set(other, size: 10_000_000)
        let first = await watcher.sample()
        #expect(first.progress?.bytes == 30_000_000)
        finishAfterTheNextListing(at: 25_000_000)

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 35_000_000)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 5_000_000)

        let following = await watcher.sample()
        #expect(following.progress?.bytes == 35_000_000)
        #expect(following.progress?.files == 1)
        #expect(following.traffic == next.traffic)
        #expect(await watcher.fallbackCount == 0)
    }

    /// Renamed between the stat of the partial file (22 MB) and the stat of
    /// the final file (25 MB): one file, its growth counted once.
    @Test func renameBetweenTheTwoStatsCountsOnce() async {
        folder.set(partial, size: 20_000_000)
        folder.set(other, size: 10_000_000)
        let first = await watcher.sample()
        finishAfterTheNextPartialStat(seen: 22_000_000, at: 25_000_000)

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 35_000_000)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 5_000_000)

        let following = await watcher.sample()
        #expect(following.progress?.bytes == 35_000_000)
        #expect(following.progress?.files == 1)
        #expect(following.traffic == next.traffic)
        #expect(await watcher.fallbackCount == 0)
    }

    /// The same between the two stats, for a partial file first seen in this poll.
    @Test func newPartialRenamedBetweenTheTwoStatsCountsItsWholeSize() async {
        folder.set(other, size: 10_000_000)
        let first = await watcher.sample()
        finishAfterTheNextPartialStat(seen: 22_000_000, at: 25_000_000)

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 35_000_000)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 25_000_000)

        let following = await watcher.sample()
        #expect(following.progress?.bytes == 35_000_000)
        #expect(following.traffic == next.traffic)
        #expect(await watcher.fallbackCount == 0)
    }

    /// A finished file that one listing leaves out is still there: it stays
    /// on the bar and is not new traffic, then or when it is listed again.
    @Test func finishedFileMissingFromOneListingIsKept() async {
        folder.set(partial, size: 20_000_000)
        folder.set(other, size: 10_000_000)
        _ = await watcher.sample()
        finish(at: 25_000_000)
        let done = await watcher.sample()
        #expect(done.progress?.bytes == 35_000_000)
        folder.afterListing = { [final] names in names.filter { $0 != final } }

        let glitch = await watcher.sample()
        #expect(glitch.progress?.bytes == 35_000_000)
        #expect(glitch.traffic == done.traffic)
        folder.afterListing = nil

        let listed = await watcher.sample()
        #expect(listed.progress?.bytes == 35_000_000)
        #expect(listed.progress?.files == 1)
        #expect(listed.traffic == done.traffic)
        #expect(await watcher.trackedPathCount == 2)
        #expect(await watcher.fallbackCount == 0)
    }

    /// The first poll after the rename lists neither A name. The watcher
    /// still has the partial, so it finds the final file: 35 MB shown,
    /// 5 MB of new traffic, and the next poll adds nothing.
    @Test func firstPollAfterTheRenameOmitsBothNames() async {
        folder.set(partial, size: 20_000_000)
        folder.set(other, size: 10_000_000)
        let first = await watcher.sample()
        #expect(first.progress?.bytes == 30_000_000)
        finish(at: 25_000_000)
        folder.afterListing = { [self] names in
            folder.afterListing = nil
            return names.filter { $0 != final && $0 != partial }
        }

        let next = await watcher.sample()
        #expect(next.progress?.bytes == 35_000_000)
        #expect(next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 5_000_000)

        let following = await watcher.sample()
        #expect(following.progress?.bytes == 35_000_000)
        #expect(following.progress?.files == 1)
        #expect(following.traffic == next.traffic)
        #expect(await watcher.fallbackCount == 0)
    }

    /// A finished file that is listed but gone when it is read is forgotten.
    @Test func finishedFileGoneAfterTheListingIsForgotten() async {
        folder.set(partial, size: 20_000_000)
        folder.set(other, size: 10_000_000)
        _ = await watcher.sample()
        finish(at: 25_000_000)
        let done = await watcher.sample()
        #expect(await watcher.trackedPathCount == 2)
        folder.afterListing = { [folder, final] names in
            folder.afterListing = nil
            folder.remove(final)
            return names
        }

        let gone = await watcher.sample()
        #expect(gone.progress?.bytes == 10_000_000)
        #expect(gone.progress?.files == 1)
        #expect(gone.traffic == done.traffic)
        #expect(await watcher.trackedPathCount == 1)
        #expect(await watcher.fallbackCount == 0)
    }
}
