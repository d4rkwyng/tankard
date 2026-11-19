import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6 (HK-47 review, item 2): a failed step whose package has a newer keg
// after the run was always counted as upgraded, "over another package". But
// brew can pour the new keg and then fail on that same package: `brew link`
// (a conflicting file) or its post-install step. Those stay failed; and the
// note says "over another package" only when brew's error names one.
@MainActor
struct V086UpgradeEvidenceTests {
    func formula(_ name: String) -> Package {
        var p = Package.command(name)
        p.id = "formula:\(name)"
        p.installedVersion = "1.0"
        p.installedVersions = ["1.0"]
        p.currentVersion = "1.1"
        p.upgradeAvailable = true
        p.upgradeHasBottle = true
        p.linked = true
        return p
    }

    /// One `brew upgrade <name>` step per package; `output(name)` is what
    /// brew printed, and every step exits 1.
    func session(_ names: [String], output: @escaping @Sendable (String) -> String,
                 check: @escaping @Sendable ([Package]) async -> [String: InstalledNow]?) -> UpgradeSession {
        UpgradeSession(packages: names.map(formula), intelbrewMode: false, action: .upgrade,
                       queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { args, out in
                           out(Data(output(args.last ?? "").utf8))
                           return 1
                       }),
                       makeCommand: { p in QueuedCommand(executable: "/x/brew", arguments: ["upgrade", p.name], environment: [:], display: "brew upgrade \(p.name)") },
                       logURL: nil, upgradeCheck: check, onFinish: { _ in })
    }

    @Test func aLinkFailureStaysFailed() async {
        let s = session(["foo"], output: { _ in
            """
            ==> Upgrading foo
              1.0 -> 1.1
            ==> Pouring foo--1.1.arm64_sequoia.bottle.tar.gz
            Error: The `brew link` step did not complete successfully
            The formula built, but is not symlinked into /opt/homebrew
            Could not symlink bin/foo
            Target /opt/homebrew/bin/foo
            already exists. You may want to remove it:
              rm '/opt/homebrew/bin/foo'

            """
        }, check: { _ in ["formula:foo": "1.1"] })
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .failed(1))
        #expect(s.upgradedAnyway.isEmpty)
        #expect(!s.log.lines.contains { $0.contains("over another package") })
    }

    @Test func aPostInstallFailureStaysFailed() async {
        let s = session(["foo"], output: { _ in
            """
            ==> Upgrading foo
              1.0 -> 1.1
            ==> Pouring foo--1.1.arm64_sequoia.bottle.tar.gz
            Warning: The post-install step did not complete successfully
            You can try again using:
              brew postinstall foo

            """
        }, check: { _ in ["formula:foo": "1.1"] })
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .failed(1))
        #expect(s.upgradedAnyway.isEmpty)
    }

    /// brew's error names another package: upgraded, "over another package".
    @Test func aFailureOverAnotherPackageCounts() async {
        let s = session(["aws-c-auth"], output: { _ in
            """
            ==> Upgrading aws-c-auth
              1.0 -> 1.1
            ==> Pouring aws-c-auth--1.1.arm64_sequoia.bottle.tar.gz
            Error: awscli: the dependency lz4 is pinned

            """
        }, check: { _ in ["formula:aws-c-auth": "1.1"] })
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .done)
        #expect(s.upgradedAnyway == [s.items[0].id])
        #expect(s.upgradedOverAnotherPackage == [s.items[0].id])
        #expect(s.log.lines.contains { $0.contains("aws-c-auth is now 1.1") && $0.contains("over another package") })
    }

    /// An error that names no other package: still upgraded (new keg,
    /// linked), but the note doesn't claim another package was the cause.
    @Test func anUnnamedErrorDoesNotBlameAnotherPackage() async {
        let s = session(["foo"], output: { _ in
            """
            ==> Upgrading foo
              1.0 -> 1.1
            ==> Pouring foo--1.1.arm64_sequoia.bottle.tar.gz
            Error: Something went wrong after the upgrade.

            """
        }, check: { _ in ["formula:foo": "1.1"] })
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .done)
        #expect(s.log.lines.contains { $0.contains("foo is now 1.1") })
        #expect(!s.log.lines.contains { $0.contains("over another package") })
    }

    /// A dependency's link failed while the package asked for upgraded and
    /// linked: the failure is the dependency's.
    @Test func aDependencysLinkFailureIsAnotherPackage() async {
        let s = session(["foo"], output: { _ in
            """
            ==> Upgrading foo
              1.0 -> 1.1
            ==> Installing foo dependency: bar
            ==> Pouring bar--2.0.arm64_sequoia.bottle.tar.gz
            Error: The `brew link` step did not complete successfully
            The formula built, but is not symlinked into /opt/homebrew
            You can try again using:
              brew link bar
            ==> Pouring foo--1.1.arm64_sequoia.bottle.tar.gz

            """
        }, check: { _ in ["formula:foo": "1.1"] })
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .done)
        #expect(s.upgradedOverAnotherPackage == [s.items[0].id])
    }

    /// The new keg is in the Cellar but the old one is still linked.
    @Test func aNewKegThatIsNotLinkedStaysFailed() async {
        let s = session(["foo"], output: { _ in "==> Upgrading foo\nError: bar: it went wrong\n" },
                        check: { _ in ["formula:foo": InstalledNow(version: "1.1", linkedVersion: "1.0", kegOnly: false)] })
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .failed(1))
    }

    /// Keg-only: brew doesn't link it, so the new keg is enough.
    @Test func aKegOnlyFormulaNeedsNoLink() async {
        let s = session(["foo"], output: { _ in "==> Upgrading foo\nError: bar: it went wrong\n" },
                        check: { _ in ["formula:foo": InstalledNow(version: "1.1", linkedVersion: nil, kegOnly: true)] })
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .done)
    }

    @Test func historySaysAnotherPackageOnlyWhenKnown() {
        let log = HistoryLog(url: nil)
        let id = UUID()
        log.record(HistoryEntry(id: id, startedAt: Date(), duration: 3, command: "brew upgrade foo",
                                arguments: ["upgrade", "foo"], outcome: .failed, exitCode: 1, outputTail: []))
        #expect(log.markUpgradedAnyway(id, overAnotherPackage: false))
        #expect(log.entries[0].resultText == "upgraded (brew then exited 1)")
    }

    /// The read after the run: brew's `linked_keg` and `keg_only`.
    @Test func theReadCarriesTheLinkedKeg() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../TankardCoreTests/Fixtures/arm64-api-info.json")
        let info = try JSONDecoder().decode(BrewInfoJSON.self, from: Data(contentsOf: url))
        let found = AppStore.installedNow(info, classifier: StatusClassifier(platform: BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar"), intelbrewMode: false),
                                          ids: ["formula:homebrew/core/xz", "formula:homebrew/core/openssl@3"])
        #expect(found["formula:homebrew/core/xz"] == InstalledNow(version: "5.8.4", linkedVersion: "5.8.4", kegOnly: false))
        #expect(found["formula:homebrew/core/openssl@3"] == InstalledNow(version: "3.5.9", linkedVersion: nil, kegOnly: true))
    }
}
