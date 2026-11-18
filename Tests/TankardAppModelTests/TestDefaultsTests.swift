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
}
