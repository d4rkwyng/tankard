import Foundation
import os
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.10: a Replace with Homebrew's Version that never finished (Tankard
// quit or crashed while brew ran) leaves its safety copy in
// replace-backup/<uuid>/. At launch the copies are listed and logged, never
// deleted: each may be the only copy of the user's app.

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
        // live() lists the same folder.
        #expect(AppReplaceSafety.live(root: root).leftovers() == found)
    }

    @Test func launchLogsLeftoversAndNeverFinishesThem() async throws {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let safety = AppReplaceSafety(
            backup: { _ in calls.withLock { $0.append("backup") }; return "/tmp/x" },
            finish: { _, _, _ in calls.withLock { $0.append("finish") }; return .discarded },
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
