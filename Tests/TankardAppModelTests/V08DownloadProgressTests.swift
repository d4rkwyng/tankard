import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8: the sheet's download progress (Derek: "Installing an app doesn't show
// download progress"). brew is a fake that grows a fake file in a fake
// downloads folder, as curl grows <hash>--<name>.incomplete.

/// A new name gets a new file number; growing and a rename keep it.
final class GrowingFolder: DownloadFolderReading, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (Int64, Data?, DownloadFileID)] = [:]
    private var nextID: UInt64 = 1
    let modified: Date

    init(modified: Date) { self.modified = modified }

    func set(_ name: String, size: Int64, data: Data? = nil) {
        lock.withLock {
            let id = files[name]?.2 ?? DownloadFileID(device: 1, inode: nextID)
            if files[name] == nil { nextID += 1 }
            files[name] = (size, data, id)
        }
    }
    func rename(_ from: String, _ to: String) {
        lock.withLock { if let f = files.removeValue(forKey: from) { files[to] = f } }
    }
    func files(in directory: String) -> [String] { lock.withLock { Array(files.keys) } }
    func stat(_ path: String) -> (size: Int64, modified: Date, fileID: DownloadFileID?)? {
        let n = (path as NSString).lastPathComponent
        return lock.withLock { files[n].map { ($0.0, modified, $0.2) } }
    }
    func read(_ path: String) -> Data? {
        let n = (path as NSString).lastPathComponent
        return lock.withLock { files[n]?.1 }
    }
}

struct StaticLengths: ContentLengthFetching {
    var sizes: [String: Int64]
    func contentLength(of url: String) async -> Int64? { sizes[url] }
}

@MainActor
struct DownloadProgressSessionTests {
    nonisolated static let url = "https://example.com/Inter-4.1.zip"
    nonisolated static let file = BrewDownloadName.urlHash(url) + "--Inter-4.1.zip"

    func cask(_ name: String = "font-inter") -> Package {
        var p = Package.command(name)
        p.id = "cask:homebrew/cask/\(name)"
        p.kind = .cask
        p.fullName = name
        return p
    }

    func monitor(_ folder: GrowingFolder, lengths: ContentLengthFetching? = nil, urls: [String] = [url],
                 asked: CallLog? = nil) -> DownloadMonitor {
        DownloadMonitor(directory: { "/cache/downloads" },
                        urls: { p in asked?.add([p.name]); return urls },
                        reader: folder, lengths: lengths, interval: .milliseconds(5),
                        now: { folder.modified })
    }

    func session(_ action: SessionAction = .install, packages: [Package], runner: FakeStreamRunner,
                 downloads: DownloadMonitor?) -> UpgradeSession {
        UpgradeSession(packages: packages, intelbrewMode: false, action: action, queue: CommandQueue(runner: runner),
                       makeCommand: { p in
                           QueuedCommand(executable: "/opt/homebrew/bin/brew", arguments: ["install", "--cask", p.name],
                                         environment: [:], display: "brew install --cask \(p.name)")
                       },
                       logURL: nil, downloads: downloads, onFinish: { _ in })
    }

    @Test func caskInstallShowsDeterminateProgressThenInstalling() async throws {
        let folder = GrowingFolder(modified: Date())
        let grown = Latch(), renamed = Latch(), finish = Latch()
        let runner = FakeStreamRunner(log: CallLog()) { _, out in
            out(Data("==> Fetching downloads for: font-inter\n".utf8))
            folder.set(Self.file + ".incomplete", size: 12_300_000)
            await grown.wait()
            folder.rename(Self.file + ".incomplete", Self.file)
            out(Data("✔︎ Cask font-inter (4.1)\n".utf8))
            await renamed.wait()
            out(Data("==> Installing Cask font-inter\n".utf8))
            await finish.wait()
            return 0
        }
        let s = session(packages: [cask()], runner: runner,
                        downloads: monitor(folder, lengths: StaticLengths(sizes: [Self.url: 45_600_000])))
        #expect(await waitUntil { s.download?.total == 45_600_000 })
        let d = try #require(s.download)
        #expect(d.bytes == 12_300_000 && d.percent == 26)
        #expect(s.statusLine.hasPrefix("Downloading font-inter…"))
        #expect(s.statusLine.contains("12.3") && s.statusLine.contains("45.6") && s.statusLine.contains("26%"))
        grown.release()
        // Renamed: the download is over, the line is the action again.
        #expect(await waitUntil { s.download == nil })
        #expect(s.statusLine == "Installing font-inter…")
        renamed.release()
        finish.release()
        #expect(await waitUntil { s.isFinished })
        #expect(s.download == nil)
        #expect(s.downloadObservations > 0)
        // The log is brew's output, untouched.
        #expect(s.log.lines.contains("==> Installing Cask font-inter"))
        #expect(!s.log.lines.contains { $0.contains("Downloading") })
    }

    @Test func unknownTotalShowsBytesSoFar() async throws {
        let folder = GrowingFolder(modified: Date())
        let go = Latch()
        let runner = FakeStreamRunner(log: CallLog()) { _, _ in
            folder.set(Self.file + ".incomplete", size: 3_400_000)
            await go.wait()
            return 0
        }
        // No HEAD answer (a server without Content-Length).
        let s = session(packages: [cask()], runner: runner, downloads: monitor(folder, lengths: StaticLengths(sizes: [:])))
        #expect(await waitUntil { s.download != nil })
        #expect(s.download?.fraction == nil)
        #expect(s.statusLine.contains("3.4") && s.statusLine.contains("so far"))
        go.release()
        #expect(await waitUntil { s.isFinished })
        #expect(s.download == nil)
    }

    @Test func bottleUpgradeUsesTheManifestAndTheFormulasName() async throws {
        let folder = GrowingFolder(modified: Date())
        let manifest = try JSONSerialization.data(withJSONObject: ["manifests": [
            ["annotations": ["org.opencontainers.image.ref.name": "3.6.0.arm64_tahoe", "sh.brew.bottle.size": "8000000"]],
        ]])
        let hash = String(repeating: "c", count: 64)
        let go = Latch()
        let runner = FakeStreamRunner(log: CallLog()) { _, _ in
            folder.set(String(repeating: "d", count: 64) + "--openssl@3-3.6.0.bottle_manifest.json", size: 1, data: manifest)
            folder.set(hash + "--openssl@3--3.6.0.arm64_tahoe.bottle.tar.gz.incomplete", size: 2_000_000)
            await go.wait()
            return 0
        }
        var wget = Package.command("wget")
        wget.id = "formula:homebrew/core/wget"
        let s = session(.upgrade, packages: [wget], runner: runner, downloads: monitor(folder, urls: []))
        #expect(await waitUntil { s.download != nil })
        #expect(s.download == DownloadProgress(name: "openssl@3", bytes: 2_000_000, total: 8_000_000))
        #expect(s.statusLine.hasPrefix("Downloading openssl@3…"))
        go.release()
        #expect(await waitUntil { s.isFinished })
    }

    @Test func stopNowEndsTheWatchAndTheCommand() async throws {
        let folder = GrowingFolder(modified: Date())
        let runner = FakeStreamRunner(log: CallLog()) { _, _ in
            folder.set(Self.file + ".incomplete", size: 1_000)
            try await sleepUntilCancelled()
            return 0
        }
        let s = session(packages: [cask(), cask("font-hack")], runner: runner, downloads: monitor(folder))
        #expect(await waitUntil { s.download != nil })
        s.stopNow()
        #expect(await waitUntil { s.isFinished })
        #expect(s.download == nil)
        #expect(s.items.map(\.state) == [.cancelled, .cancelled])
        // The leftover .incomplete doesn't bring it back.
        let seen = s.downloadObservations
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.download == nil && s.downloadObservations == seen)
    }

    @Test func stopAfterCurrentKeepsWatchingTheRunningCommand() async throws {
        let folder = GrowingFolder(modified: Date())
        let go = Latch()
        let runner = FakeStreamRunner(log: CallLog()) { _, _ in
            folder.set(Self.file + ".incomplete", size: 1_000)
            await go.wait()
            return 0
        }
        let s = session(packages: [cask(), cask("font-hack")], runner: runner, downloads: monitor(folder))
        #expect(await waitUntil { s.download != nil })
        s.stopAfterCurrent() // the waiting second item is cancelled; the running one goes on
        folder.set(Self.file + ".incomplete", size: 2_000)
        #expect(await waitUntil { s.download?.bytes == 2_000 })
        go.release()
        #expect(await waitUntil { s.isFinished })
        #expect(s.items.map(\.state) == [.done, .cancelled])
    }

    @Test func uninstallAndCleanupAreNotWatched() async throws {
        let folder = GrowingFolder(modified: Date())
        let asked = CallLog()
        let runner = FakeStreamRunner(log: CallLog()) { _, _ in
            folder.set(Self.file + ".incomplete", size: 1_000)
            try await Task.sleep(for: .milliseconds(60))
            return 0
        }
        for action in [SessionAction.uninstall, .cleanup] {
            let s = session(action, packages: [cask()], runner: runner, downloads: monitor(folder, asked: asked))
            #expect(await waitUntil { s.isFinished })
            #expect(s.downloadObservations == 0)
        }
        #expect(asked.calls.isEmpty)
        #expect(DownloadMonitor.watches(.adopt) && DownloadMonitor.watches(.upgrade) && DownloadMonitor.watches(.replaceBottle))
    }

    @Test func noMonitorNoProgress() async throws {
        let runner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let s = session(packages: [cask()], runner: runner, downloads: nil)
        #expect(await waitUntil { s.isFinished })
        #expect(s.download == nil && s.downloadObservations == 0)
    }

    @Test func detailStrings() {
        #expect(DownloadProgress(name: nil, bytes: 12_300_000, total: 45_600_000).detail.contains("of"))
        #expect(DownloadProgress(name: nil, bytes: 300_000, total: nil).detail.contains("300"))
    }

    @Test func storePassesItsMonitorToInstallSessions() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let folder = GrowingFolder(modified: Date())
        let go = Latch()
        let runner = FakeStreamRunner(log: log) { args, _ in
            if args.first == "install" {
                folder.set(Self.file + ".incomplete", size: 5_000)
                await go.wait()
            }
            return 0
        }
        var deps = AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil)
        let m = monitor(folder)
        deps.downloadMonitor = { _, env in
            #expect(env["HOMEBREW_NO_AUTO_UPDATE"] == "1")
            return m
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let entry = CatalogEntry(kind: .cask, name: "font-inter", fullName: "font-inter", tap: "homebrew/cask", desc: nil, bottle: .forThisMac)
        store.startInstall(entry)
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.download?.bytes == 5_000 })
        go.release()
        #expect(await waitUntil { s.isFinished })
    }
}
