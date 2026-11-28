import Foundation
import Testing
@testable import TankardCore

// 0.8: download progress from brew's downloads folder (brew 7.0.14 prints no
// progress on pipes; see DownloadProgress.swift).

/// A downloads folder in memory: name -> (size, modified, contents, file
/// number). A new name gets a new file number; setting an existing one
/// (the file grew) and a rename keep it, as on disk.
final class FakeDownloadFolder: DownloadFolderReading, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (Int64, Date, Data?, DownloadFileID?)] = [:]
    private var nextID: UInt64 = 1

    func set(_ name: String, size: Int64, modified: Date = Date(), data: Data? = nil) {
        lock.withLock {
            let id: DownloadFileID?
            if let existing = files[name] {
                id = existing.3
            } else {
                id = DownloadFileID(device: 0, inode: nextID)
                nextID += 1
            }
            files[name] = (size, modified, data, id)
        }
    }
    func set(_ name: String, size: Int64, fileID: DownloadFileID?) {
        lock.withLock { files[name] = (size, Date(), nil, fileID) }
    }
    func set(_ name: String, size: Int64, modified: Date, fileID: DownloadFileID?) {
        lock.withLock { files[name] = (size, modified, nil, fileID) }
    }
    func remove(_ name: String) { lock.withLock { _ = files.removeValue(forKey: name) } }
    func rename(_ from: String, _ to: String) {
        lock.withLock {
            if let f = files.removeValue(forKey: from) { files[to] = f }
        }
    }

    func files(in directory: String) -> [String] { lock.withLock { Array(files.keys) } }
    func stat(_ path: String) -> (size: Int64, modified: Date, fileID: DownloadFileID?)? {
        let name = (path as NSString).lastPathComponent
        return lock.withLock { files[name].map { ($0.0, $0.1, $0.3) } }
    }
    func read(_ path: String) -> Data? {
        let name = (path as NSString).lastPathComponent
        return lock.withLock { files[name]?.2 }
    }
}

struct FakeLengths: ContentLengthFetching {
    var sizes: [String: Int64]
    let asked = AskLog()
    final class AskLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [String] = []
        func add(_ u: String) { lock.withLock { _urls.append(u) } }
        var urls: [String] { lock.withLock { _urls } }
    }
    func contentLength(of url: String) async -> Int64? {
        asked.add(url)
        return sizes[url]
    }
}

/// The shape of a real bottle manifest (figlet/lz4 on this Mac, trimmed).
func manifestJSON(_ entries: [(ref: String, size: Int64)]) -> Data {
    let list = entries.map { e in
        ["annotations": ["org.opencontainers.image.ref.name": e.ref, "sh.brew.bottle.size": String(e.size),
                         "sh.brew.bottle.digest": "abc"]]
    }
    return try! JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "manifests": list])
}

let hashA = String(repeating: "a", count: 64)
let hashB = String(repeating: "b", count: 64)

struct DownloadNameTests {
    @Test func parsesBrewsCacheNames() throws {
        // Real names from ~/Library/Caches/Homebrew/downloads (brew 7.0.14).
        let cask = try #require(BrewDownloadName.parse("9eb5d021fd72c7e1c9a95f0d3402afb8aea73fc1cd41258150c098913c1f0e1a--JetBrainsMono-2.304.zip.incomplete"))
        #expect(cask.incomplete)
        #expect(cask.basename == "JetBrainsMono-2.304.zip")
        #expect(cask.bottle == nil)

        let bottle = try #require(BrewDownloadName.parse("934628a9b389512f4a8dec4b4c1d65df128d68964a53ae4b1f6ddedc2ac4afbb--figlet--2.2.5.arm64_golden_gate.bottle.tar.gz.incomplete"))
        #expect(bottle.bottle == .init(formula: "figlet", version: "2.2.5", tag: "arm64_golden_gate", rebuild: 0))

        let rebuilt = try #require(BrewDownloadName.parse("efd51138d31d42d1b7063c4a74e2d95d5396e319bb1df628536dc8c6eb6ceabc--hello--2.12.3.arm64_golden_gate.bottle.1.tar.gz"))
        #expect(!rebuilt.incomplete)
        #expect(rebuilt.bottle == .init(formula: "hello", version: "2.12.3", tag: "arm64_golden_gate", rebuild: 1))

        // A source tarball isn't a bottle; a name without the hash isn't brew's.
        #expect(BrewDownloadName.parse("\(hashA)--pkgconf-3.0.10.tar.xz")?.bottle == nil)
        #expect(BrewDownloadName.parse("\(hashA)--python@3.13--3.13.1.sonoma.bottle.tar.gz")?.bottle?.formula == "python@3.13")
        #expect(BrewDownloadName.parse("Cask--font.zip.incomplete") == nil)
        #expect(BrewDownloadName.parse("nohash.incomplete") == nil)
    }

    @Test func urlHashIsBrewsPrefix() {
        // brew fetched this URL to 22dc37a4…--Fira_Code_v6.2.zip on this Mac.
        #expect(BrewDownloadName.urlHash("https://github.com/tonsky/FiraCode/releases/download/6.2/Fira_Code_v6.2.zip")
            == "22dc37a40de9a20229db1e451ca113ef910adcd5127f19abbf71daf004384dc0")
    }

    @Test func manifestSizeForTheBottlesTag() throws {
        let m = manifestJSON([("2.12.3.arm64_sonoma.1", 55004), ("2.12.3.arm64_golden_gate.1", 54641)])
        let b = BrewDownloadName.Bottle(formula: "hello", version: "2.12.3", tag: "arm64_golden_gate", rebuild: 1)
        #expect(BottleManifestSize.ref(b) == "2.12.3.arm64_golden_gate.1")
        #expect(BottleManifestSize.size(manifest: m, ref: BottleManifestSize.ref(b)) == 54641)
        #expect(BottleManifestSize.size(manifest: m, ref: "2.12.3.arm64_tahoe.1") == nil)
        #expect(BottleManifestSize.size(manifest: Data("nope".utf8), ref: "x") == nil)
        #expect(BottleManifestSize.matches("\(hashA)--hello-2.12.3-1.bottle_manifest.json", b))
        let plain = BrewDownloadName.Bottle(formula: "figlet", version: "2.2.5", tag: "arm64_golden_gate", rebuild: 0)
        #expect(BottleManifestSize.matches("\(hashA)--figlet-2.2.5.bottle_manifest.json", plain))
        #expect(!BottleManifestSize.matches("\(hashA)--figlet-2.2.5.bottle_manifest.json.incomplete", plain))
        #expect(!BottleManifestSize.matches("\(hashA)--figlet-2.2.6.bottle_manifest.json", plain))
    }

    @Test func sizeFormat() {
        let en = Locale(identifier: "en_US")
        #expect(DownloadSizeFormat.pieces(12_345_678, scale: 45_600_000, locale: en) == ("12.3", "MB"))
        #expect(DownloadSizeFormat.pieces(45_600_000, scale: 45_600_000, locale: en) == ("45.6", "MB"))
        #expect(DownloadSizeFormat.pieces(300_000, scale: 2_000_000_000, locale: en) == ("0.0", "GB"))
        #expect(DownloadSizeFormat.pieces(54_641, scale: 54_641, locale: en) == ("55", "KB"))
        #expect(DownloadSizeFormat.pieces(0, scale: 0, locale: en) == ("0", "KB"))
        #expect(DownloadSizeFormat.pieces(12_345_678, scale: 45_600_000, locale: Locale(identifier: "de_DE")).number == "12,3")
        let p = DownloadProgress(name: nil, bytes: 27, total: 100)
        #expect(p.fraction == 0.27 && p.percent == 27)
        #expect(DownloadProgress(name: nil, bytes: 5, total: nil).fraction == nil)
        #expect(DownloadProgress(name: nil, bytes: 500, total: 100).fraction == 1)
    }
}

struct DownloadWatcherTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func bottleProgressFromTheManifestThenDone() async throws {
        let dir = FakeDownloadFolder()
        let file = "\(hashA)--figlet--2.2.5.arm64_golden_gate.bottle.tar.gz"
        dir.set("\(hashB)--figlet-2.2.5.bottle_manifest.json", size: 3000, modified: start,
                data: manifestJSON([("2.2.5.arm64_golden_gate", 1_000_000), ("2.2.5.arm64_tahoe", 999)]))
        let w = DownloadWatcher(directory: "/cache/downloads", reader: dir, since: start)
        #expect(await w.poll() == nil)
        #expect(await !w.sawDownload)
        dir.set(file + ".incomplete", size: 250_000, modified: start.addingTimeInterval(1))
        let p = try #require(await w.poll())
        #expect(p == DownloadProgress(name: "figlet", bytes: 250_000, total: 1_000_000))
        #expect(p.percent == 25)
        dir.set(file + ".incomplete", size: 900_000, modified: start.addingTimeInterval(2))
        #expect(await w.poll()?.bytes == 900_000)
        dir.rename(file + ".incomplete", file)
        #expect(await w.poll() == nil)
        #expect(await w.sawDownload)
    }

    @Test func caskTotalFromAHeadRequestForTheMatchingURL() async throws {
        let dir = FakeDownloadFolder()
        let url = "https://example.com/Font-1.0.zip"
        let other = "https://example.com/unrelated.zip"
        let lengths = FakeLengths(sizes: [url: 5_000_000, other: 1])
        // The size of a URL that isn't this file's never counts.
        let w = DownloadWatcher(directory: "/d", reader: dir, lengths: lengths, since: start, urls: [other])
        await w.addURLs([url])
        await w.addURLs([url])
        let name = BrewDownloadName.urlHash(url) + "--Font-1.0.zip.incomplete"
        dir.set(name, size: 1_000_000, modified: start)
        let first = try #require(await w.poll())
        #expect(first.bytes == 1_000_000 && first.name == nil)
        var total: Int64?
        for _ in 0..<100 where total == nil {
            try await Task.sleep(for: .milliseconds(10))
            total = await w.poll()?.total
        }
        #expect(total == 5_000_000)
        #expect(lengths.asked.urls.sorted() == [url, other].sorted()) // each hinted URL asked once
        #expect(await w.poll()?.total == 5_000_000)
    }

    @Test func unknownTotalStaysIndeterminate() async throws {
        let dir = FakeDownloadFolder()
        let lengths = FakeLengths(sizes: [:])
        let w = DownloadWatcher(directory: "/d", reader: dir, lengths: lengths, since: start)
        dir.set("\(hashA)--Thing.dmg.incomplete", size: 42, modified: start)
        let p = try #require(await w.poll())
        #expect(p.total == nil && p.fraction == nil && p.bytes == 42)
        #expect(lengths.asked.urls.isEmpty) // no hint, no request
    }

    @Test func ignoresOldLeftoversAndManifests() async throws {
        let dir = FakeDownloadFolder()
        // A download stopped an hour ago, and a manifest still downloading.
        dir.set("\(hashA)--Old.zip.incomplete", size: 10, modified: start.addingTimeInterval(-3600))
        dir.set("\(hashB)--figlet-2.2.5.bottle_manifest.json.incomplete", size: 10, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        #expect(await w.poll() == nil)
        #expect(await !w.sawDownload)
    }

    @Test func parallelDownloadsAddUpAndFinishedOnesKeepCounting() async throws {
        let dir = FakeDownloadFolder()
        let a = "\(hashA)--aaa--1.0.sonoma.bottle.tar.gz"
        let b = "\(hashB)--bbb--2.0.sonoma.bottle.tar.gz"
        dir.set("\(hashA)--aaa-1.0.bottle_manifest.json", size: 1, modified: start, data: manifestJSON([("1.0.sonoma", 100)]))
        dir.set("\(hashB)--bbb-2.0.bottle_manifest.json", size: 1, modified: start, data: manifestJSON([("2.0.sonoma", 300)]))
        dir.set(a + ".incomplete", size: 50, modified: start)
        dir.set(b + ".incomplete", size: 100, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        let both = try #require(await w.poll())
        #expect(both == DownloadProgress(name: nil, bytes: 150, total: 400, files: 2))
        dir.set(a + ".incomplete", size: 100, modified: start) // curl wrote the rest before the rename
        dir.rename(a + ".incomplete", a)
        dir.set(b + ".incomplete", size: 200, modified: start)
        let one = try #require(await w.poll())
        // a's 100 still count: 300 of 400, not 200 of 300.
        #expect(one == DownloadProgress(name: "bbb", bytes: 300, total: 400, files: 1))
    }
}
