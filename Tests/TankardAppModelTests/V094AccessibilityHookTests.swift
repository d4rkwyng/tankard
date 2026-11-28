import Foundation
import Testing
@testable import TankardAppModel

// 0.9.4: accessibilityIdentifier hooks on the Installed list and the
// status-bar Upgrade button, so a throwaway VM can drive Cmd-click, Esc
// and the context menu through System Events. The identifiers are test
// hooks; they don't change what VoiceOver says. A SwiftUI view can't be
// inspected from this target, so the wiring is checked in the views' source
// the same way as V093AccessibilityTests.

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func source(_ file: String) throws -> String {
    try String(contentsOf: packageRoot.appendingPathComponent("Sources/TankardApp/\(file)"), encoding: .utf8)
}

struct V094AccessibilityHookTests {
    @Test func packageRowIdentifierUsesThePackageID() {
        #expect(AccessibilityText.ID.packageRow("formula:homebrew/core/xz") == "package-row.formula:homebrew/core/xz")
        #expect(AccessibilityText.ID.packageRow("cask:homebrew/cask/firefox") == "package-row.cask:homebrew/cask/firefox")
        #expect(AccessibilityText.ID.packageList == "package-list")
        #expect(AccessibilityText.ID.upgradeBar == "upgrade-bar")
        // Distinct from the 0.9.3 banner and toolbar identifiers.
        let ids = [AccessibilityText.ID.packageList, AccessibilityText.ID.upgradeBar,
                   AccessibilityText.ID.packageRow("formula:homebrew/core/xz")]
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(AccessibilityText.ID.refreshProgress))
    }

    @Test func packageNameCellWiresTheRowIdentifier() throws {
        let src = try source("ContentView.swift")
        #expect(src.contains("struct PackageNameCell: View"))
        #expect(src.contains(".accessibilityIdentifier(AccessibilityText.ID.packageRow(p.id))"))
        #expect(src.contains(".accessibilityIdentifier(AccessibilityText.ID.packageList)"))
    }

    @Test func statusBarWiresTheUpgradeButtonIdentifier() throws {
        let src = try source("StatusBar.swift")
        #expect(src.contains(".accessibilityIdentifier(AccessibilityText.ID.upgradeBar)"))
        // The identifier is on the same Upgrade button as the 0.9.4 title.
        #expect(src.contains("store.upgradeBarButton"))
    }
}
