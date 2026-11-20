import Foundation

// 0.8.9 (confirm run on 15, MED): the quit Apple Event's "Quit anyway?"
// alert froze the run's sheet. `QuitGuard.handleQuitEvent` asked from a
// `Task { @MainActor in … }`, so `NSAlert.runModal()` ran inside a main-queue
// job. The main queue is serial: while that job is still running (the
// modal loop is nested in it), no other main-actor job runs, and the
// session's events (UpgradeSession's consumer task) waited until the alert
// closed. A modal loop entered from a run-loop source (a menu action, or a
// block given to the run loop as here) is not inside a main-queue job, and
// main-actor work goes on under it.

public enum RunLoopPerform {
    /// Runs `work` on the main thread as a run-loop block (common modes),
    /// outside any main-queue job, so a modal loop it enters doesn't hold
    /// up the main actor.
    public static func onMain(_ work: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { work() }
        }
    }
}
