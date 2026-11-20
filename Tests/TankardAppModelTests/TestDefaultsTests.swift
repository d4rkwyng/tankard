import Foundation
import Testing

// 0.8.4: the suites tests make must not pile up in ~/Library/Preferences.

struct TestDefaultsTests {
    @Test func removeDeletesTheDomainAndItsPlist() throws {
        let name = "tankard-test-cleanup-\(UUID().uuidString)"
        let d = TestDefaults.fresh(name)
        d.set(true, forKey: "x")
        #expect(CFPreferencesAppSynchronize(name as CFString))
        let plist = TestDefaults.plistURL(name)
        #expect(FileManager.default.fileExists(atPath: plist.path))
        TestDefaults.remove(name)
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        #expect(UserDefaults(suiteName: name)!.object(forKey: "x") == nil)
    }

    /// 0.8.9: a Scoped suite leaves no plist for its UUID once released,
    /// even after a write was flushed to disk.
    @Test func scopedSuiteLeavesNoPlist() throws {
        var name = ""
        do {
            let scoped = TestDefaults.Scoped()
            name = scoped.name
            scoped.defaults.set("v", forKey: "k")
            #expect(CFPreferencesAppSynchronize(name as CFString))
            #expect(FileManager.default.fileExists(atPath: TestDefaults.plistURL(name).path))
        }
        #expect(name.hasPrefix("net.mindtricks.tankard.tests."))
        try assertNoPlist(name)
    }

    @Test func withTestDefaultsLeavesNoPlist() throws {
        let name = withTestDefaults { d, name in
            d.set(1, forKey: "k")
            #expect(CFPreferencesAppSynchronize(name as CFString))
            return name
        }
        try assertNoPlist(name)
    }

    /// No file for this suite's UUID, now or once cfprefsd has had a moment
    /// to write back anything it still held.
    private func assertNoPlist(_ name: String) throws {
        let uuid = try #require(name.split(separator: ".").last.map(String.init))
        #expect(UUID(uuidString: uuid) != nil)
        func leftovers() -> [String] {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(uuid) }
        }
        #expect(leftovers().isEmpty)
        Thread.sleep(forTimeInterval: 0.5)
        #expect(leftovers().isEmpty)
        #expect(UserDefaults(suiteName: name)!.object(forKey: "k") == nil)
    }
}
