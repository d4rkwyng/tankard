import Foundation
import os
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.10: a Replace with Homebrew's Version that never finished (Tankard
// quit or crashed while brew ran, or a finished run kept the copy) leaves
// its safety copy in replace-backup/<uuid>/. At launch the copies are
// listed, logged, and one notice is shown. Nothing is moved or deleted:
// each may be the only copy of the user's app.

@MainActor
struct V0810ReplaceLeftoversTests {
    @Test func leftoverCopiesListsEachCopyAndKeepsThem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tankard-replace-leftovers-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        #expect(AppReplaceSafety.leftoverCopies(root: root).isEmpty) // no folder yet

        let a = root.appendingPathComponent("AAAA").appendingPathComponent("Foo.app/Contents")
        let b = root.appendingPathComponent("BBBB").appendingPathComponent("Bar Baz.app")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: a.appendingPathComponent("Info.plist"))
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try fm.createDirectory(at: root.appendingPathComponent("CCCC"), withIntermediateDirectories: true) // empty

        let found = AppReplaceSafety.leftoverCopies(root: root)
        #expect(found == [root.appendingPathComponent("AAAA/Foo.app").path,
                          root.appendingPathComponent("BBBB/Bar Baz.app").path])
        // Read only: everything is still there.
        #expect(fm.fileExists(atPath: a.appendingPathComponent("Info.plist").path))
        #expect(fm.fileExists(atPath: b.path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("CCCC").path))
        // live() lists the same folder, and not a copy that lives somewhere else.
        #expect(AppReplaceSafety.live(root: root).leftovers() == found)
    }

    /// Kept copies are made under Application Support. An older copy still
    /// under Caches is listed and left where it is. A test root does not
    /// read the user's Caches folder.
    @Test func keptCopiesAreOutsideCachesAndOldCacheCopiesStayListed() throws {
        let fm = FileManager.default
        #expect(AppReplaceSafety.defaultRoot.path.hasSuffix("/Library/Application Support/net.mindtricks.tankard/replace-backup"))
        #expect(AppReplaceSafety.legacyCachesRoot.path.hasSuffix("/Library/Caches/net.mindtricks.tankard/replace-backup"))
        #expect(!AppReplaceSafety.defaultRoot.path.contains("/Caches/"))

        let base = fm.temporaryDirectory.appendingPathComponent("tankard-replace-root-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let support = base.appendingPathComponent("Application Support")
        let caches = base.appendingPathComponent("Caches")
        let elsewhere = base.appendingPathComponent("Elsewhere")
        let app = base.appendingPathComponent("Applications/Foo.app")
        try FakeBundle.make(app, version: "1.0")

        let live = AppReplaceSafety.live(root: support, legacyRoots: [caches])
        let copy = try live.backup(app.path)
        #expect(copy.hasPrefix(support.path + "/"))
        #expect(!copy.contains("/Caches/"))
        #expect(FakeBundle.version(URL(fileURLWithPath: copy)) == "1.0")
        #expect(AppReplaceSafety.sameVolume(app.path, support.path))
        #expect(!AppReplaceSafety.sameVolume(app.path, support.appendingPathComponent("missing").path))

        let exe = "Contents/MacOS/Foo"
        let srcExe = app.appendingPathComponent(exe).path
        if let srcID = Self.cloneID(srcExe), let copiedID = Self.cloneID((copy as NSString).appendingPathComponent(exe)) {
            #expect(srcID == copiedID)
        }
        let plain = support.appendingPathComponent("plain/Foo.app")
        try fm.createDirectory(at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AppReplaceSafety.copyApp(from: app.path, to: plain.path, clone: false)
        #expect(FakeBundle.version(plain) == "1.0")
        if let srcID = Self.cloneID(srcExe), let plainID = Self.cloneID(plain.appendingPathComponent(exe).path) {
            #expect(srcID != plainID)
        }

        let old = caches.appendingPathComponent("OLDID/Old.app")
        try FakeBundle.make(old, version: "9.0")
        let marker = old.appendingPathComponent("Contents/marker")
        try Data("keep".utf8).write(to: marker)
        let only = elsewhere.appendingPathComponent("ONLY/Only.app")
        try FakeBundle.make(only, version: "3.0")

        let listed = live.leftovers()
        #expect(listed.contains(copy))
        #expect(listed.contains(old.path))
        #expect(listed.contains(plain.path))
        #expect(!listed.contains(only.path))
        #expect(listed == listed.sorted())
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
        #expect(FakeBundle.version(old) == "9.0")
        #expect(fm.fileExists(atPath: old.path))

        let isolated = AppReplaceSafety.live(root: support).leftovers()
        #expect(isolated.contains(copy))
        #expect(isolated.contains(plain.path))
        #expect(!isolated.contains(old.path))
        #expect(!isolated.contains(only.path))
    }

    /// The clone id of a file, when the volume reports one.
    private static func cloneID(_ path: String) -> UInt64? {
        var attr = attrlist()
        attr.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attr.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attr.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        var buf = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &attr, &buf, buf.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0 else { return nil }
        return buf.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }
    }

    @Test func launchLogsLeftoversAndNeverFinishesThem() async throws {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let safety = AppReplaceSafety(
            backup: { _ in calls.withLock { $0.append("backup") }; return "/tmp/x" },
            finish: { _, _, _, _ in calls.withLock { $0.append("finish") }; return .discarded },
            leftovers: { calls.withLock { $0.append("leftovers") }; return ["/c/AAAA/Foo.app"] })
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appReplaceSafety = safety
        let store = AppStore(deps: deps)
        await store.start()
        #expect(await waitUntil { calls.withLock { $0.contains("leftovers") } })
        #expect(await store.noteReplaceLeftovers() == ["/c/AAAA/Foo.app"])
        // Listed only: no copy is put back or deleted, none is made.
        #expect(!calls.withLock { $0.contains("finish") || $0.contains("backup") })
    }

    @Test func noSafetyNoLeftoverCheck() async {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await store.start()
        #expect(await store.noteReplaceLeftovers().isEmpty)
    }
}
