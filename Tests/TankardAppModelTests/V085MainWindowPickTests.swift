import Testing
@testable import TankardAppModel

// 0.8.5 (bug hunt M5): the menu bar's Open Tankard with the main window
// minimized brings that window back instead of opening a second one.
struct V085MainWindowPickTests {
    typealias C = MainWindowPick.Candidate

    @Test func minimizedMainWindowIsReused() {
        let minimized = [C(identifier: "com.apple.SwiftUI.Settings", isVisible: false, isMiniaturized: false),
                         C(identifier: "main-AppWindow-1", isVisible: false, isMiniaturized: true)]
        #expect(MainWindowPick.pick(minimized) == 1)
    }

    @Test func visibleWinsAndNoneMeansOpen() {
        let both = [C(identifier: "main-AppWindow-2", isVisible: false, isMiniaturized: true),
                    C(identifier: "main-AppWindow-1", isVisible: true, isMiniaturized: false)]
        #expect(MainWindowPick.pick(both) == 1)
        // Closed (neither visible nor minimized), or only other windows: open one.
        #expect(MainWindowPick.pick([C(identifier: "main-AppWindow-1", isVisible: false, isMiniaturized: false)]) == nil)
        #expect(MainWindowPick.pick([C(identifier: "progress", isVisible: true, isMiniaturized: false),
                                     C(identifier: nil, isVisible: false, isMiniaturized: true)]) == nil)
    }
}
