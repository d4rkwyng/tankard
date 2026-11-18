import AppKit
import ObjectiveC

// 0.8.5 (0.8.3 review F4, still open in 0.8.4): demo, snapshot and script
// runs wrote "NSWindow Frame main-AppWindow-1" into the real
// net.mindtricks.tankard defaults domain. SwiftUI gives the main window a
// frame autosave name when it creates it, and AppKit saves the frame under
// it on every move or resize (a snapshot's TANKARD_SNAPSHOT_SIZE included),
// always in the standard defaults: a settings suite can't catch it, and
// ScriptLaunch.isolate ran only after the window existed and only in script
// runs. For those runs, NSWindow's two entry points into the frame autosave
// are turned into no-ops before any window exists, so no window of the
// process ever reads or writes a saved frame.

@MainActor
enum WindowFrameIsolation {
    private(set) static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        exchange(#selector(NSWindow.setFrameAutosaveName(_:)), #selector(NSWindow.tankardIsolatedSetFrameAutosaveName(_:)))
        exchange(#selector(NSWindow.saveFrame(usingName:)), #selector(NSWindow.tankardIsolatedSaveFrame(usingName:)))
    }

    private static func exchange(_ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(NSWindow.self, original),
              let b = class_getInstanceMethod(NSWindow.self, replacement) else {
            FileHandle.standardError.write(Data("tankard: frame isolation: \(original) not found\n".utf8))
            return
        }
        method_exchangeImplementations(a, b)
    }
}

extension NSWindow {
    /// Replaces `setFrameAutosaveName(_:)` in isolated runs: no name, so
    /// nothing is saved; reports success as AppKit would.
    @objc func tankardIsolatedSetFrameAutosaveName(_ name: String) -> Bool { true }

    /// Replaces `saveFrame(usingName:)` in isolated runs: saves nothing.
    @objc func tankardIsolatedSaveFrame(usingName name: String) {}
}
