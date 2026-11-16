import Foundation
import Testing
@testable import TankardCore

struct ClassificationTests {
    // Real data: the Intel Sonoma VM, core on the Intelbrew fork, 20 formulae.
    @Test func intelbrewVM() throws {
        let info = try Fixture.info("sonoma-intelbrew-info")
        let pkgs = StatusClassifier(platform: .intelSonoma, intelbrewMode: true).classify(info: info)

        #expect(pkgs.count == 20)
        let vim = try #require(pkgs["vim"])
        #expect(vim.status == .source)
        #expect(vim.pouredFromBottle == false)
        #expect(vim.currentHasBottle == true)
        #expect(vim.requested)

        let xz = try #require(pkgs["xz"])
        #expect(xz.status == .bottle)
        #expect(xz.bottleOrigin == .intelbrew)
        #expect(xz.statusLabel == "Intelbrew bottle")
        #expect(xz.bottleTag == "sonoma")
        #expect(!xz.requested)

        // Upstream bottles the fork kept: "all" and a ghcr sonoma bottle.
        #expect(pkgs["ca-certificates"]?.bottleTag == "all")
        #expect(pkgs["ca-certificates"]?.statusLabel == "Homebrew bottle")
        #expect(pkgs["libsodium"]?.bottleOrigin == .homebrew)

        #expect(pkgs["zstd"]?.installedVersion == "1.5.7_1")
        #expect(pkgs["zstd"]?.currentVersion == "1.5.7_1")
        #expect(pkgs["ncurses"]?.kegOnly == true)

        let s = StatusSummary(packages: pkgs)
        #expect(s.installed == 20 && s.formulae == 20 && s.casks == 0)
        #expect(s.bottled == 19 && s.source == 1 && s.newer == 0 && s.noBottle == 0)
        #expect(s.intelbrewBottled == 13) // 14 fork bottles, but vim was built from source
        #expect(s.upgrades == 0)
        #expect(s.requested == 3 && s.dependencies == 17)
    }

    // Real data: arm64 mini in API mode, with outdated formulae and casks.
    @Test func arm64APIMode() throws {
        let info = try Fixture.info("arm64-api-info")
        let pkgs = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false).classify(info: info)

        let ada = try #require(pkgs["ada-url"])
        #expect(ada.upgradeAvailable && ada.upgradeHasBottle == true)
        #expect(ada.installedVersion == "4.0.0_1" && ada.currentVersion == "4.0.0_2")
        #expect(ada.status == .bottle)
        #expect(ada.bottleOrigin == nil)  // installed != current: what was poured is unknown
        #expect(ada.statusLabel == "bottle")

        #expect(pkgs["blake3"]?.status == .source)
        #expect(pkgs["pkgconf"]?.status == .source)
        #expect(pkgs["zstd"]?.status == .bottle)
        #expect(pkgs["openssl@3"]?.status == .bottle)

        // Auto-updating cask older than the tap but not outdated per brew:
        // trust brew, and it's not "newer" either.
        let ts = try #require(pkgs["tailscale-app"])
        #expect(ts.kind == .cask && ts.status == .cask && !ts.upgradeAvailable)
        #expect(pkgs["visual-studio-code"]?.upgradeAvailable == true)
        #expect(pkgs["lm-studio"]?.status == .cask)

        let s = StatusSummary(packages: pkgs)
        #expect(s.formulae == 9 && s.casks == 5)
        #expect(s.upgrades == 5 && s.upgradesWithBottle == 3 && s.caskUpgrades == 2 && s.upgradesFromSource == 0)
        #expect(s.line == "14 installed · 7 bottled · 2 source · 0 newer · 5 casks · 5 upgrades (3 with bottles, 2 casks)")
    }

    // Synthetic values in the real JSON shape, for cases the two machines don't have.
    @Test func edgeCases() throws {
        let info = try Fixture.info("synthetic-intel-info")
        let pkgs = StatusClassifier(platform: .intelSonoma, intelbrewMode: true).classify(info: info)
        func status(_ n: String) -> PackageStatus? { pkgs[n]?.status }

        #expect(status("newer-from-api") == .newer)
        #expect(status("newer-revision") == .newer)       // 2.0_3 vs 2.0_2
        #expect(status("upgrade-no-bottle") == .noBottle) // only arm64 bottles
        #expect(pkgs["upgrade-no-bottle"]?.upgradeHasBottle == false)
        #expect(status("upgrade-with-bottle") == .bottle)
        #expect(pkgs["upgrade-with-bottle"]?.upgradeHasBottle == true)
        #expect(status("current-no-bottle") == .noBottle)
        #expect(status("source-built") == .source)
        #expect(pkgs["source-built"]?.bottleOrigin == .intelbrew)
        #expect(status("head-build") == .source)          // HEAD is never "newer"
        #expect(pkgs["multi-keg"]?.installedVersion == "8.1")
        #expect(pkgs["multi-keg"]?.installedVersions == ["8.0", "8.1"])
        #expect(pkgs["older-os-bottle"]?.bottleTag == "ventura")
        #expect(status("older-os-bottle") == .bottle)
        #expect(status("cellar-mismatch") == .noBottle)
        #expect(status("all-bottle") == .bottle)
        #expect(pkgs["all-bottle"]?.statusLabel == "Homebrew bottle")
        #expect(status("newer-bottle-only") == .noBottle) // sequoia bottle can't pour on sonoma
        #expect(status("newer-cask") == .newer)
        #expect(status("latest-cask") == .cask)

        let s = StatusSummary(packages: pkgs)
        #expect(s.installed == 14)
        #expect(s.bottled + s.source + s.newer + s.noBottle + pkgs.filter { $0.status == .cask }.count == s.installed)
        #expect(s.newer == 3 && s.noBottle == 4 && s.source == 2 && s.bottled == 4)
        #expect(s.upgrades == 2 && s.upgradesWithBottle == 1 && s.upgradesFromSource == 1)
    }

    /// Upgrade-available comes from info's `outdated` flag; on the real
    /// captures it names exactly the packages `brew outdated --json=v2` lists.
    @Test(arguments: ["arm64-api", "sonoma-intelbrew", "synthetic-intel"])
    func infoOutdatedFlagMatchesBrewOutdated(fixture: String) throws {
        let info = try Fixture.info(fixture + "-info")
        let outdated = try Fixture.outdated(fixture + "-outdated")
        let pkgs = StatusClassifier(platform: .intelSonoma, intelbrewMode: false).classify(info: info)
        let flagged = Set(pkgs.filter(\.upgradeAvailable).map(\.name))
        #expect(flagged == Set(outdated.formulae.map(\.name) + outdated.casks.map(\.name)))
    }

    @Test func qualifiedIDs() throws {
        let pkgs = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false).classify(info: try Fixture.info("arm64-api-info"))
        #expect(pkgs["xz"]?.id == "formula:homebrew/core/xz")
        #expect(pkgs["iterm2"]?.id == "cask:homebrew/cask/iterm2")
        #expect(Set(pkgs.map(\.id)).count == pkgs.count)
        #expect(StatusClassifier.qualified(tap: "user/tools", name: "user/tools/foo") == "user/tools/foo")
    }

    @Test func bottleOriginFromURL() {
        #expect(StatusClassifier.bottleOrigin(url: "https://github.com/d4rkwyng/intelbrew-core/releases/download/vim-9.2/x.tar.gz") == .intelbrew)
        #expect(StatusClassifier.bottleOrigin(url: "https://ghcr.io/v2/homebrew/core/xz/blobs/sha256:00") == .homebrew)
        #expect(StatusClassifier.bottleOrigin(url: "https://example.com/b.tar.gz") == .other)
        #expect(StatusClassifier.bottleOrigin(url: nil) == .other)
    }
}

struct BottlePlatformTests {
    let intel = BottlePlatform.intelSonoma

    @Test func tags() {
        #expect(intel.bottleTag == "sonoma")
        #expect(BottlePlatform.armGoldenGate.bottleTag == "arm64_golden_gate")
        #expect(BottlePlatform(arch: .x86_64, macOSVersion: "15", cellar: "/usr/local/Cellar").bottleTag == "sequoia")
    }

    @Test func matching() {
        #expect(intel.matchingTag(in: ["arm64_sonoma", "sonoma", "ventura"]) == "sonoma")
        #expect(intel.matchingTag(in: ["all"]) == "all")
        #expect(intel.matchingTag(in: ["monterey", "ventura", "big_sur"]) == "ventura") // newest older
        #expect(intel.matchingTag(in: ["arm64_sonoma", "arm64_ventura"]) == nil)       // other arch
        #expect(intel.matchingTag(in: ["sequoia", "tahoe"]) == nil)                    // newer macOS only
        #expect(intel.matchingTag(in: ["x86_64_linux"]) == nil)
        // An OCLP Mac on Sequoia pours the fork's Sonoma bottles.
        let sequoia = BottlePlatform(arch: .x86_64, macOSVersion: "15", cellar: "/usr/local/Cellar")
        #expect(sequoia.matchingTag(in: ["sonoma"]) == "sonoma")
    }

    @Test func cellar() {
        #expect(intel.cellarIsCompatible(":any"))
        #expect(intel.cellarIsCompatible(":any_skip_relocation"))
        #expect(intel.cellarIsCompatible("/usr/local/Cellar"))
        #expect(!intel.cellarIsCompatible("/opt/homebrew/Cellar"))
    }
}
