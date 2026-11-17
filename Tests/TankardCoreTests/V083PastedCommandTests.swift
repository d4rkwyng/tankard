import Testing
@testable import TankardCore

// 0.8.3: a pasted "brew install x" searches for x.

struct PastedCommandTests {
    @Test func strips() {
        #expect(PastedCommand.searchTerm("brew install wget") == "wget")
        #expect(PastedCommand.searchTerm("  brew install --cask firefox\n") == "firefox")
        #expect(PastedCommand.searchTerm("brew upgrade jq") == "jq")
        #expect(PastedCommand.searchTerm("brew info --json=v2 jq") == "jq")
        #expect(PastedCommand.searchTerm("$ brew install wget") == "wget")
        #expect(PastedCommand.searchTerm("Brew Install Wget") == "Wget")
        #expect(PastedCommand.searchTerm("/opt/homebrew/bin/brew install wget") == "wget")
        // Tap-qualified names stay whole.
        #expect(PastedCommand.searchTerm("brew install d4rkwyng/tap/tankard") == "d4rkwyng/tap/tankard")
        #expect(PastedCommand.searchTerm("brew install --cask d4rkwyng/tap/tankard") == "d4rkwyng/tap/tankard")
    }

    @Test func leavesOtherTextAlone() {
        #expect(PastedCommand.searchTerm("wget") == "wget")
        #expect(PastedCommand.searchTerm("brew") == "brew")
        #expect(PastedCommand.searchTerm("brew install") == "brew install")
        #expect(PastedCommand.searchTerm("brew install --cask") == "brew install --cask")
        #expect(PastedCommand.searchTerm("brew doctor") == "brew doctor")
        #expect(PastedCommand.searchTerm("install wget") == "install wget")
        #expect(PastedCommand.searchTerm("command line brew tool") == "command line brew tool")
        #expect(PastedCommand.searchTerm("") == "")
    }

    @Test func catalogSearchUsesIt() {
        func f(_ n: String, tap: String = "homebrew/core") -> CatalogEntry {
            CatalogEntry(kind: .formula, name: n, fullName: tap == "homebrew/core" ? n : "\(tap)/\(n)", tap: tap, desc: nil, bottle: .forThisMac)
        }
        let entries = [f("wget"), f("wget2"), f("tankard", tap: "d4rkwyng/tap")]
        #expect(CatalogSearch.search("brew install wget", in: entries).first?.name == "wget")
        #expect(CatalogSearch.search("brew install d4rkwyng/tap/tankard", in: entries).map(\.name) == ["tankard"])
        #expect(CatalogSearch.search("brew install", in: entries).isEmpty)
    }
}
