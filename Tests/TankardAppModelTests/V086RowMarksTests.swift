import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6: the package row's trailing marks are one cluster in a fixed order:
// updates itself, needs the password, Electron (Derek: the "updates
// itself" arrows sat after the name, apart from the lock at the end).

struct V086RowMarksTests {
    static func cask(_ name: String, auto: Bool = false, password: Bool = false) -> Package {
        var p = Package.command(name)
        p.kind = .cask
        p.autoUpdates = auto
        if password { p.installsPkg = true }
        return p
    }

    @Test func fixedOrder() {
        #expect(RowMark.allCases == [.updatesItself, .password, .electron])
        let all = Self.cask("chrome", auto: true, password: true)
        #expect(AdminPassword.required(all))
        #expect(RowMark.marks(all, isElectron: true) == [.updatesItself, .password, .electron])
        #expect(RowMark.marks(Self.cask("x", auto: true), isElectron: true) == [.updatesItself, .electron])
        #expect(RowMark.marks(Self.cask("x", password: true), isElectron: false) == [.password])
        #expect(RowMark.marks(Self.cask("x"), isElectron: false).isEmpty)
    }

    @Test func formulaeNeverShowTheCaskMarks() {
        var f = Package.command("wget")
        f.kind = .formula
        f.autoUpdates = true
        #expect(RowMark.marks(f, isElectron: false).isEmpty)
    }
}
