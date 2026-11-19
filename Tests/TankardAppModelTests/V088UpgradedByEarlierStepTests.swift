import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.8 (VM retest of 0.8.7): Upgrade All's later steps for packages brew
// had already upgraded in an earlier step of the same run (as a dependency
// or dependent) said "another Homebrew command (in Terminal, perhaps) did
// it", and the summary read "7 upgraded, 7 already up to date" when the run
// had upgraded all 14. They now count as upgraded by this run.
@MainActor
struct V088UpgradedByEarlierStepTests {
    func formula(_ name: String) -> Package {
        var p = Package.command(name)
        p.upgradeAvailable = true
        p.upgradeHasBottle = true
        return p
    }

    func session(_ packages: [Package], output: @escaping @Sendable ([String]) -> String) -> UpgradeSession {
        UpgradeSession(packages: packages, intelbrewMode: false, action: .upgrade,
                       queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { args, out in
                           out(Data(output(args).utf8)); return 0
                       }),
                       makeCommand: { p in QueuedCommand(executable: "/x/brew", arguments: ["upgrade", p.name], environment: [:], display: "brew upgrade \(p.name)") },
                       logURL: nil, onFinish: { _ in })
    }

    /// brew's real output for each step of the retest's run (15-upgrade.log).
    nonisolated static func brew(_ name: String) -> String {
        switch name {
        case "aws-c-auth": return V088Fixture.awsCAuth
        case "cmake": return "==> Upgrading cmake\n  4.4.5 -> 4.5.0 \n==> Pouring cmake--4.5.0.arm64_sequoia.bottle.tar.gz\n"
        default:
            let v = ["aws-c-http": "1.3.0", "s2n": "1.7.14", "awscli": "2.41.1", "lz4": "1.11.1"][name] ?? "1.0"
            return "Warning: \(name) \(v) already installed\n"
        }
    }

    @Test func dependenciesAndDependentsUpgradedEarlierCountAsThisRuns() async {
        let names = ["aws-c-auth", "aws-c-http", "awscli", "cmake", "lz4", "s2n"]
        let s = session(names.map(formula)) { args in Self.brew(args.last ?? "") }
        #expect(await waitUntil { s.isFinished })
        #expect(s.doneElsewhere.isEmpty)
        #expect(s.doneByEarlierStep.count == 4)
        #expect(Set(s.doneByEarlierStep.values) == ["aws-c-auth"])
        #expect(s.succeededCount == 6)
        #expect(s.title == "Upgrade complete")
        #expect(s.statusLine == "6 upgraded")
        #expect(!s.subtitle.contains("already up to date"))
        #expect(!s.log.lines.contains { $0.contains("another Homebrew command") })
        #expect(s.log.lines.contains { $0.contains("brew upgraded s2n while upgrading aws-c-auth") })
    }

    @Test func alreadyInstalledWithNoEarlierStepStillSaysElsewhere() async {
        // lz4 isn't upgraded by cmake's step: still done elsewhere.
        let s = session(["cmake", "lz4"].map(formula)) { args in Self.brew(args.last ?? "") }
        #expect(await waitUntil { s.isFinished })
        #expect(s.doneByEarlierStep.isEmpty)
        #expect(s.doneElsewhere.count == 1)
        #expect(s.statusLine == "1 upgraded, 1 already up to date")
        #expect(s.log.lines.contains { $0.contains("another Homebrew command") })
    }

    @Test func aLaterStepDoesNotCountForAnEarlierOne() async {
        // s2n runs first and is already installed; aws-c-auth upgrades it
        // only afterwards: s2n's step was done elsewhere.
        let s = session(["s2n", "aws-c-auth"].map(formula)) { args in Self.brew(args.last ?? "") }
        #expect(await waitUntil { s.isFinished })
        #expect(s.doneElsewhere.count == 1)
        #expect(s.doneByEarlierStep.isEmpty)
    }
}

/// The aws-c-auth step's real output, shared with the Core parser tests.
enum V088Fixture {
    static let awsCAuth = """
    ==> Upgrading aws-c-auth
      1.0.3_1 -> 1.1.0 
    ==> Installing dependencies for aws-c-auth: s2n and aws-c-http
    ==> Upgrading aws-c-auth dependency: s2n (1.7.13 -> 1.7.14)
    ==> Pouring s2n--1.7.14.arm64_sequoia.bottle.tar.gz
    ==> Upgrading aws-c-auth dependency: aws-c-http (1.2.0 -> 1.3.0)
    ==> Pouring aws-c-http--1.3.0.arm64_sequoia.bottle.tar.gz
    ==> Installing aws-c-auth
    ==> Pouring aws-c-auth--1.1.0.arm64_sequoia.bottle.tar.gz
    ==> Not upgrading aws-c-s3: installed runtime dependencies satisfy bottle metadata
    ==> Upgrading 1 dependent of upgraded formulae:
    awscli 2.39.6 -> 2.41.1
    ==> Upgrading awscli
      2.39.6 -> 2.41.1 
    ==> Upgrading awscli dependency: lz4 (1.11.0 -> 1.11.1)
    ==> Pouring lz4--1.11.1.arm64_sequoia.bottle.tar.gz
    ==> Pouring awscli--2.41.1.arm64_sequoia.bottle.tar.gz
    ==> Upgraded 1 requested outdated package
    aws-c-auth 1.0.3_1 -> 1.1.0
    ==> Upgraded 1 dependent
    awscli 2.39.6 -> 2.41.1

    """
}
