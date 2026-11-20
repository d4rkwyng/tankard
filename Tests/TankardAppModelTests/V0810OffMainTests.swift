import AskpassSupport
import Darwin
import Foundation
import Testing

// 0.8.10: the code-signing checks (TestHooks, the askpass gate) run off the
// main thread: Security logged "This method should not be called on the main
// thread as it may lead to UI unresponsiveness" about 12 times per launch.
struct V0810OffMainTests {
    private static func threadID() -> UInt32 { pthread_mach_thread_np(pthread_self()) }

    @MainActor @Test func fromTheMainThreadTheWorkRunsOnAnotherThread() {
        #expect(Thread.isMainThread)
        let ranOnMain = OffMain.run { Thread.isMainThread }
        #expect(!ranOnMain)
        // The caller waited: the result is there, and still on main after.
        #expect(Thread.isMainThread)
    }

    @Test func offTheMainThreadItRunsInPlace() async {
        let outer = await Task.detached { () -> (UInt32, UInt32) in
            (Self.threadID(), OffMain.run { Self.threadID() })
        }.value
        #expect(outer.0 == outer.1)
    }

    @MainActor @Test func returnsTheBodysValueIncludingNil() {
        #expect(OffMain.run { 41 + 1 } == 42)
        let none: String? = OffMain.run { nil }
        #expect(none == nil)
        let pair: (String?, String?) = OffMain.run { ("a", nil) }
        #expect(pair.0 == "a" && pair.1 == nil)
    }

    /// The real Security calls, from the main actor the way the app makes
    /// them at launch: the same answer as the same calls made on a thread
    /// that was never the main one, and the same hooks decision. (The test
    /// runner itself is Apple-signed, so the answer is not ad-hoc here.) A
    /// debug build stops on a main-thread call (OffMain.assertOffMain).
    @MainActor @Test func ownSigningOffMainGivesTheSameAnswer() async {
        let fromMain = OffMain.run { TestHooks.ownSigning() }
        let fromTask = await Task.detached { TestHooks.ownSigning() }.value
        #expect(fromMain == fromTask)
        #expect(TestHooks.liveAllowed == TestHooks.allowed(signing: fromMain))
    }

    @MainActor @Test func repeatedCallsFromMainEachReturnInOrder() {
        // Many calls in a row from main: each returns (no deadlock), in order.
        var seen: [Int] = []
        for i in 0..<20 { seen.append(OffMain.run { i }) }
        #expect(seen == Array(0..<20))
    }
}
