import Foundation
import Testing
@testable import TankardCore

// 0.8.6 (VM test M2, M3): `brew upgrade --cask hiddenbar` adds a version
// folder inside Caskroom/hiddenbar and leaves Caskroom's own date alone;
// `brew pin`/`unpin` change only var/homebrew/pinned (unpin removes it
// when empty, which changes var/homebrew); `brew tap user/x` adds a folder
// under Library/Taps/user. The probe now looks one level down (bounded),
// so window activation notices all of them.
struct V086ChangeProbeTests {
    let old = Date(timeIntervalSince1970: 1_700_000_000)

    func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tk-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func age(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func aCaskUpgradeInsideItsCaskroomFolderCounts() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let caskroom = root.appendingPathComponent("Caskroom")
        let token = caskroom.appendingPathComponent("hiddenbar")
        try FileManager.default.createDirectory(at: token.appendingPathComponent("1.13.0"), withIntermediateDirectories: true)
        try age(token, old)
        try age(caskroom, old)
        #expect(HomebrewChanges.latest(paths: [caskroom.path], childrenOf: [caskroom.path]) == old)
        // brew upgrade --cask: a new version folder inside the token's folder.
        try FileManager.default.createDirectory(at: token.appendingPathComponent("1.14.0"), withIntermediateDirectories: true)
        try age(caskroom, old)
        let t = try #require(HomebrewChanges.latest(paths: [caskroom.path], childrenOf: [caskroom.path]))
        #expect(t > old.addingTimeInterval(60))
    }

    @Test func pinAndUnpinAreWatched() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HomebrewChanges.paths(prefix: root.path, cellar: root.appendingPathComponent("Cellar").path)
        #expect(paths.contains(root.path + "/var/homebrew/pinned"))
        #expect(paths.contains(root.path + "/var/homebrew"))
        #expect(HomebrewChanges.childPaths(prefix: root.path) == [root.path + "/Caskroom"])
    }

    @Test func childScanIsBounded() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<5 {
            let c = root.appendingPathComponent("c\(i)")
            try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
            try age(c, old.addingTimeInterval(Double(i)))
        }
        try age(root, old)
        #expect(HomebrewChanges.newestChild(of: root.path, limit: 5) == old.addingTimeInterval(4))
        // Over the limit: no answer from the children (the folder's own date still counts).
        #expect(HomebrewChanges.newestChild(of: root.path, limit: 4) == nil)
    }
}
