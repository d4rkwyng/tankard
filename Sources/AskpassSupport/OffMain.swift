import Foundation

/// 0.8.10: Security.framework's code-signing calls (SecCodeCopySelf,
/// SecCodeCopyGuestWithAttributes, SecCodeCheckValidity and
/// SecCodeCopySigningInformation with kSecCSSigningInformation, which
/// evaluates the signing certificate's trust) log a fault-level runtime
/// issue when made on the main thread: "This method should not be called on
/// the main thread as it may lead to UI unresponsiveness" (about 12 per
/// launch in the notarized 0.8.9, macOS 15 and 26).
///
/// Both callers need the answer before they go on: the app sanitizes its
/// environment (TestHooks) before anything reads it, and the askpass helper
/// decides its gate before anything is drawn. So `run` does the work on a
/// dedicated thread and waits for it: the order and the result are the same
/// as before, only the thread that talks to Security changes. The thread
/// runs at user-interactive QoS, so the wait is no priority inversion.
public enum OffMain {
    /// `body` on a thread that isn't the main thread; returns its result.
    /// Off the main thread already: runs `body` in place.
    public static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
        if !Thread.isMainThread { return body() }
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.name = "net.mindtricks.tankard.security"
        thread.qualityOfService = .userInteractive
        thread.start()
        done.wait()
        return box.value!
    }

    /// Debug builds (tests): stops on a Security call made on the main
    /// thread. Compiled out of a release build.
    public static func assertOffMain(_ what: StaticString, file: StaticString = #fileID, line: UInt = #line) {
        assert(!Thread.isMainThread, "\(what) must not run on the main thread (OffMain.run)", file: file, line: line)
    }
}

/// Written once by the worker thread before it signals; read once after the
/// wait (the semaphore orders the two).
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
