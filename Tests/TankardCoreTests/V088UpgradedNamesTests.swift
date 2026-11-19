import Foundation
import Testing
@testable import TankardCore

// 0.8.8 (VM retest of 0.8.7, macOS 15): Upgrade All ran `brew upgrade
// aws-c-auth`, which also upgraded s2n, aws-c-http (dependencies) and
// awscli with its dependencies aws-c-mqtt, aws-c-s3, lz4 (a dependent).
// The later `brew upgrade s2n` steps found them "already installed" and
// were reported as done by another Homebrew command. The lines below are
// brew's real output from that run (15-upgrade.log).
struct V088UpgradedNamesTests {
    static let awsCAuth = """
    ==> Fetching downloads for: aws-c-auth, aws-c-s3 and awscli
    ==> Would upgrade 2 dependencies:
    s2n         1.7.13 -> 1.7.14
    aws-c-http  1.2.0  -> 1.3.0
    ==> Would upgrade 1 requested outdated package
    aws-c-auth 1.0.3_1 -> 1.1.0 (108.7KB)
    ==> Would upgrade 2 dependents
    aws-c-s3  1.5.2_1 -> 1.5.2_3  (149.8KB)
    awscli    2.39.6  -> 2.41.1   (24.5MB)
    ✔︎ Bottle aws-c-auth (1.1.0)
    ✔︎ Bottle s2n (1.7.14)
    ==> Upgrading aws-c-auth
      1.0.3_1 -> 1.1.0 
    ==> Installing dependencies for aws-c-auth: s2n and aws-c-http
    ==> Upgrading aws-c-auth dependency: s2n (1.7.13 -> 1.7.14)
    ==> Pouring s2n--1.7.14.arm64_sequoia.bottle.tar.gz
    🍺  /opt/homebrew/Cellar/s2n/1.7.14: 28 files, 3MB
    ==> Upgrading aws-c-auth dependency: aws-c-http (1.2.0 -> 1.3.0)
    ==> Pouring aws-c-http--1.3.0.arm64_sequoia.bottle.tar.gz
    ==> Installing aws-c-auth
    ==> Pouring aws-c-auth--1.1.0.arm64_sequoia.bottle.tar.gz
    ==> Not upgrading aws-c-s3: installed runtime dependencies satisfy bottle metadata
    ==> Upgrading 1 dependent of upgraded formulae:
    awscli 2.39.6 -> 2.41.1
    ==> Upgrading awscli
      2.39.6 -> 2.41.1 
    ==> Installing dependencies for awscli: aws-c-mqtt, aws-c-s3 and lz4
    ==> Upgrading awscli dependency: aws-c-mqtt (1.1.2_1 -> 1.1.3_1)
    ==> Pouring aws-c-mqtt--1.1.3_1.arm64_sequoia.bottle.tar.gz
    ==> Upgrading awscli dependency: aws-c-s3 (1.5.2_1 -> 1.5.2_3)
    ==> Pouring aws-c-s3--1.5.2_3.arm64_sequoia.bottle.tar.gz
    ==> Upgrading awscli dependency: lz4 (1.11.0 -> 1.11.1)
    ==> Pouring lz4--1.11.1.arm64_sequoia.bottle.tar.gz
    ==> Installing awscli
    ==> Pouring awscli--2.41.1.arm64_sequoia.bottle.tar.gz
    ==> Caveats
    zsh completions and functions have been installed to:
      /opt/homebrew/share/zsh/site-functions
    ==> Upgraded 1 requested outdated package
    aws-c-auth 1.0.3_1 -> 1.1.0
    ==> Upgraded 1 dependent
    awscli 2.39.6 -> 2.41.1
    """

    static let pkgconf = """
    ==> Fetching downloads for: pkgconf and ruby-build
    ==> Would upgrade 1 requested outdated package
    pkgconf 3.0.10 -> 3.0.11 (195.4KB)
    ==> Would upgrade 1 dependent
    ruby-build 20261023 -> 20261119 (82.9KB)
    ==> Upgrading pkgconf
      3.0.10 -> 3.0.11 
    ==> Pouring pkgconf--3.0.11.arm64_sequoia.bottle.tar.gz
    ==> Not upgrading ruby-build: installed runtime dependencies satisfy bottle metadata
    """

    func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }

    @Test func everythingTheAwsCAuthStepUpgraded() {
        #expect(BrewRefusal.upgradedNames(lines(Self.awsCAuth))
                == ["aws-c-auth", "s2n", "aws-c-http", "awscli", "aws-c-mqtt", "aws-c-s3", "lz4"])
    }

    @Test func wouldUpgradeAndNotUpgradingAreNotUpgrades() {
        // ruby-build was only planned ("Would upgrade 1 dependent") and then
        // not upgraded; the later `brew upgrade ruby-build` really upgraded it.
        let got = BrewRefusal.upgradedNames(lines(Self.pkgconf))
        #expect(got == ["pkgconf"])
        #expect(!got.contains("ruby-build"))
    }

    @Test func headingsThatCountAreNotNames() {
        let got = BrewRefusal.upgradedNames(["==> Upgrading 1 dependent of upgraded formulae:", "awscli 2.39.6 -> 2.41.1",
                                             "==> Upgrading 2 outdated packages:", "yq 4.54.2 -> 4.54.3", "gh 2.103.3 -> 2.105.0",
                                             "==> Caveats", "zsh completions have been installed to:"])
        #expect(got == ["awscli", "yq", "gh"])
    }

    @Test func alreadyInstalledOutputUpgradedNothing() {
        #expect(BrewRefusal.upgradedNames(["Warning: s2n 1.7.14 already installed"]).isEmpty)
        #expect(BrewRefusal.alreadyInstalled(["Warning: s2n 1.7.14 already installed"]))
    }

    @Test func tapNamesMatchShortOrFull() {
        #expect(BrewRefusal.contains(["walktest/probe/walk-slow"], "walk-slow"))
        #expect(BrewRefusal.contains(["walk-slow"], "walktest/probe/walk-slow"))
        #expect(!BrewRefusal.contains(["walk-a"], "walk-slow"))
    }
}
