import Foundation
import Testing
@testable import TankardAppModel

// 0.8.1: Hide Dock icon when the window is closed.

@MainActor
struct V081DockIconTests {
    @Test(arguments: [true, false], [true, false])
    func windowOpenIsAlwaysRegular(menuBar: Bool, option: Bool) {
        #expect(DockIconPolicy.desired(windowOpen: true, showMenuBarIcon: menuBar, hideDockIconWhenClosed: option) == .regular)
    }

    @Test func windowClosedHidesOnlyWithMenuBarIconAndOption() {
        #expect(DockIconPolicy.desired(windowOpen: false, showMenuBarIcon: true, hideDockIconWhenClosed: true) == .accessory)
        #expect(DockIconPolicy.desired(windowOpen: false, showMenuBarIcon: true, hideDockIconWhenClosed: false) == .regular)
        // Never without the menu-bar icon: Tankard would be unreachable.
        #expect(DockIconPolicy.desired(windowOpen: false, showMenuBarIcon: false, hideDockIconWhenClosed: true) == .regular)
        #expect(DockIconPolicy.desired(windowOpen: false, showMenuBarIcon: false, hideDockIconWhenClosed: false) == .regular)
    }

    @Test func optionIsEnabledOnlyWithTheMenuBarIcon() {
        #expect(DockIconPolicy.optionAvailable(showMenuBarIcon: true))
        #expect(!DockIconPolicy.optionAvailable(showMenuBarIcon: false))
    }

    @Test func transitionsCloseReopenAndMenuBarOff() {
        // Last window closes: hide.
        #expect(DockIconPolicy.transition(from: .regular, windowOpen: false, showMenuBarIcon: true, hideDockIconWhenClosed: true) == .accessory)
        // A window opens (menu-bar "Open Tankard", Settings, reopen): back.
        #expect(DockIconPolicy.transition(from: .accessory, windowOpen: true, showMenuBarIcon: true, hideDockIconWhenClosed: true) == .regular)
        // Menu-bar icon turned off while hidden: back, even with no window.
        #expect(DockIconPolicy.transition(from: .accessory, windowOpen: false, showMenuBarIcon: false, hideDockIconWhenClosed: true) == .regular)
        // Option turned off while hidden: back.
        #expect(DockIconPolicy.transition(from: .accessory, windowOpen: false, showMenuBarIcon: true, hideDockIconWhenClosed: false) == .regular)
        // No change: nothing to do.
        #expect(DockIconPolicy.transition(from: .regular, windowOpen: true, showMenuBarIcon: true, hideDockIconWhenClosed: true) == nil)
        #expect(DockIconPolicy.transition(from: .accessory, windowOpen: false, showMenuBarIcon: true, hideDockIconWhenClosed: true) == nil)
        #expect(DockIconPolicy.transition(from: .regular, windowOpen: false, showMenuBarIcon: false, hideDockIconWhenClosed: true) == nil)
    }

    @Test func settingDefaultsOnPersistsAndFeedsThePolicy() {
        let s = AppSettings.ephemeral("net.mindtricks.tankard.test.dock")
        #expect(s.hideDockIconWhenClosed)
        #expect(s.dockIconPolicy(windowOpen: false) == .accessory)
        s.hideDockIconWhenClosed = false
        #expect(AppSettings(defaults: s.defaults).hideDockIconWhenClosed == false)
        #expect(s.dockIconPolicy(windowOpen: false) == .regular)
        s.hideDockIconWhenClosed = true
        s.showMenuBarIcon = false
        #expect(s.dockIconPolicy(windowOpen: false) == .regular)
    }

    @Test func helpExplainsTheMenuBarRequirement() {
        #expect(SettingsHelp.all.contains(SettingsHelp.hideDockIcon))
        #expect(SettingsHelp.hideDockIcon.contains("Show Tankard in the menu bar"))
    }
}
