import Foundation
import Testing
@testable import TankardAppModel

// 0.8.6: the shorter tooltip delay is registered in memory, never written.

struct V086ToolTipDelayTests {
    @Test func registersInMemoryOnly() throws {
        let name = TestDefaults.track("net.mindtricks.tankard.tests.\(UUID().uuidString)")
        let d = try #require(UserDefaults(suiteName: name))
        #expect(d.object(forKey: ToolTipDelay.key) == nil)
        ToolTipDelay.register(in: d)
        #expect(d.integer(forKey: ToolTipDelay.key) == 350)
        // The registration domain isn't persisted: the suite's own domain stays empty.
        #expect(d.persistentDomain(forName: name)?[ToolTipDelay.key] == nil)
        // A value the user set wins.
        d.set(1500, forKey: ToolTipDelay.key)
        ToolTipDelay.register(in: d)
        #expect(d.integer(forKey: ToolTipDelay.key) == 1500)
        d.removeObject(forKey: ToolTipDelay.key)
    }
}
