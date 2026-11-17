import Foundation
import Testing
@testable import TankardCore

// v0.6 (part A): deprecated/disabled data, brew doctor parsing and its
// mapping, brew failure classification, the autoremove dry run.
// Fixtures (arm64 Mac, brew 7.0.14, read-only):
//   brew info --json=v2 icu4c@78 openssl@3 readline   arm64-lifecycle-info.json
//   brew doctor (stdout+stderr)                         arm64-doctor.txt
//   brew config                                         arm64-config.txt
// Synthetic, shaped on brew's sources (diagnostic.rb, cleanup.rb, utils/lock.sh):
//   synthetic-doctor.txt, synthetic-autoremove-n.txt, synthetic-brew-lock.txt

struct LifecycleTests {
    func packages() throws -> [Package] {
        let info = try Fixture.info("arm64-lifecycle-info")
        return StatusClassifier(platform: BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar"),
                                intelbrewMode: false).classify(info: info)
    }

    @Test func realFieldNamesDecode() throws {
        let ps = try packages()
        let icu = try #require(ps.first { $0.name == "icu4c@78" })
        #expect(icu.deprecated)
        #expect(!icu.disabled)
        #expect(icu.lifecycle?.deprecationDate == "2026-10-30")
        #expect(icu.lifecycle?.deprecationReason == "versioned_formula")
        #expect(icu.lifecycle?.disableDate == "2027-10-30")
        #expect(icu.kegOnly == true)
        #expect(icu.kegOnlyReason == "it is a versioned formula")
        #expect(icu.linked == false)
    }

    @Test func futureDateWithoutFlagIsNotDeprecated() throws {
        let ssl = try #require(try packages().first { $0.name == "openssl@3" })
        #expect(!ssl.deprecated)
        #expect(ssl.lifecycle?.deprecationDate == "2030-04-08")
    }

    @Test func kegOnlyExplanationWins() throws {
        let rl = try #require(try packages().first { $0.name == "readline" })
        #expect(rl.kegOnlyReason == "macOS provides BSD libedit")
    }

    @Test func reasonWords() {
        #expect(PackageLifecycle.describe(reason: "repo_archived") == "has an archived upstream repository")
        #expect(PackageLifecycle.describe(reason: ":unmaintained") == "is not maintained upstream")
        #expect(PackageLifecycle.describe(reason: "upstream moved to foo") == "upstream moved to foo")
        #expect(PackageLifecycle.describe(reason: nil) == nil)
    }

    @Test func olderReportsStillDecode() throws {
        // A 0.5 report has none of the new keys.
        var p = Package.command("x")
        p.lifecycle = nil
        let data = try StatusReport.jsonEncoder().encode([p])
        let back = try StatusReport.jsonDecoder().decode([Package].self, from: data)
        #expect(back.first?.lifecycle == nil && back.first?.linked == nil)
    }
}

struct DoctorTests {
    @Test func realOutput() throws {
        let r = DoctorReport.parse(try TextFixture.text("arm64-doctor"))
        #expect(r.maintainersNote)
        #expect(!r.ready)
        #expect(r.warnings.count == 2)
        #expect(r.warnings[0].kind == .deprecatedDisabled)
        #expect(r.warnings[0].fixCommand == "brew upgrade ada-url merve")
        #expect(r.warnings[1].kind == .sbinNotInPath)
        #expect(r.warnings[1].fixCommand?.hasPrefix("printf ") == true)
        #expect(r.warnings[1].raw.contains("Consider setting your PATH"))
    }

    @Test func mappingAndUnknown() throws {
        let r = DoctorReport.parse(try TextFixture.text("synthetic-doctor"))
        #expect(r.warnings.map(\.kind) == [.brokenSymlinks, .unlinkedKegs, .outdatedCLT, nil])
        #expect(r.warnings[0].title == "There are broken links in Homebrew's folders")
        #expect(r.warnings[0].fixCommand == "brew cleanup") // the kind's own: brew's line is a path
        #expect(r.warnings[2].fixCommand == "sudo rm -rf /Library/Developer/CommandLineTools")
        // Unknown: brew's own headline, no explanation, raw kept.
        #expect(r.warnings[3].title == "Something brand new that Tankard has never seen.")
        #expect(r.warnings[3].explanation == nil)
        #expect(r.warnings.allSatisfy { !$0.raw.isEmpty })
    }

    @Test func everyKindHasWords() {
        for k in DoctorWarningKind.allCases {
            #expect(!k.title.isEmpty && !k.explanation.isEmpty)
        }
    }

    @Test func cleanDoctor() {
        let r = DoctorReport.parse("Your system is ready to brew.\n")
        #expect(r.ready && r.warnings.isEmpty && !r.maintainersNote)
    }

    @Test func missing() {
        let m = MissingDependencies.parse("vim: lua ruby\nfoo:\n")
        #expect(m.count == 1 && m[0].formula == "vim" && m[0].missing == ["lua", "ruby"])
        #expect(MissingDependencies.parse("").isEmpty)
    }
}

struct BrewFailureTests {
    @Test func lockFromLockSh() throws {
        let lines = try TextFixture.text("synthetic-brew-lock").split(separator: "\n").map(String.init)
        #expect(BrewFailure.classify(lines) == .locked)
    }

    @Test func lockFromOperationInProgress() {
        #expect(BrewFailure.classify(["Error: A `brew install jq` process has already locked /opt/homebrew/var/homebrew/locks/jq.formula.lock.",
                                      "Please wait for it to finish or terminate it to continue."]) == .locked)
    }

    @Test func others() {
        #expect(BrewFailure.classify(["curl: (6) Could not resolve host: ghcr.io"]) == .network)
        #expect(BrewFailure.classify(["Error: No space left on device @ rb_sysopen"]) == .diskFull)
        #expect(BrewFailure.classify(["Error: Permission denied @ dir_s_mkdir - /usr/local/Cellar/x"]) == .permissions)
        #expect(BrewFailure.classify(["Error: jq: no bottle available!"]) == nil)
        for k in BrewFailureKind.allCases { #expect(!k.title.isEmpty && !k.explanation.isEmpty) }
    }
}

struct AutoremovePlanTests {
    @Test func parsesDryRun() throws {
        let p = AutoremovePlan.parse(try TextFixture.text("synthetic-autoremove-n"))
        #expect(p.formulae == ["icu4c@78", "libyaml", "homebrew/core/m4"])
    }

    @Test func emptyWhenNothing() {
        // brew 7.0.14 prints nothing at all (the arm64 Mac, rc 0).
        #expect(AutoremovePlan.parse("").formulae.isEmpty)
        #expect(AutoremovePlan.parse("Warning: something\n").formulae.isEmpty)
    }

    @Test func commands() {
        #expect(AutoremovePlan.dryRunArguments == ["autoremove", "--dry-run"])
        #expect(AutoremovePlan.keepCommand("libyaml") == "brew tab --installed-on-request libyaml")
    }
}
