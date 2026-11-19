import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.8 (gauntlet 26, P5): Installed marked zoom (a pkg installer) with a
// lock; Discover showed nothing before the install asked for a password.

struct V088DiscoverPasswordMarkTests {
    func cask(_ name: String) -> CatalogEntry {
        CatalogEntry(kind: .cask, name: name, fullName: name, tap: "homebrew/cask", desc: nil, bottle: .cask)
    }

    @Test func pkgAndSudoInstallerCasksNeedThePassword() {
        var zoom = cask("zoom")
        #expect(!AdminPassword.required(zoom)) // details not in yet
        zoom.installsPkg = true
        #expect(AdminPassword.required(zoom))
        #expect(AdminPassword.required(zoom) == AdminPassword.required(zoom.asPackage()))
        var script = cask("karabiner-elements")
        script.sudoInstaller = true
        #expect(AdminPassword.required(script))
        var firefox = cask("firefox")
        firefox.installsPkg = false
        #expect(!AdminPassword.required(firefox))
    }

    @Test func formulaeNever() {
        var f = CatalogEntry(kind: .formula, name: "wget", fullName: "wget", tap: "homebrew/core", desc: nil, bottle: .forThisMac)
        f.installsPkg = true
        #expect(!AdminPassword.required(f))
    }

    @Test func theDiscoverTooltipSaysInstall() {
        #expect(AdminPassword.installBadgeHelp == "Needs your password to install")
        #expect(AdminPassword.installBadgeHelp != AdminPassword.badgeHelp)
    }
}
