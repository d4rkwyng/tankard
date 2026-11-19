import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.7 (B5): Homebrew 7's trust gate. The text is trust.rb's
// raise_untrusted! (brew 7.0.15), as `brew info tankprobe/trust/tprobe`
// printed it on the macOS 26 VM after `brew untrust --tap tankprobe/trust`.
@MainActor
struct V087UntrustedTapTests {
    nonisolated static let formulaError = [
        "Error: Refusing to load formula tankprobe/trust/tprobe from untrusted tap tankprobe/trust.",
        "Run `brew trust --formula tankprobe/trust/tprobe` or `brew trust tankprobe/trust` to trust it.",
    ]
    nonisolated static let caskError = [
        "Error: Refusing to load cask steipete/tap/codexbar from untrusted tap steipete/tap.",
        "Run `brew trust --cask steipete/tap/codexbar` or `brew trust steipete/tap` to trust it.",
    ]

    @Test func parsesFormulaCaskAndCommandRefusals() throws {
        let f = try #require(UntrustedTapRefusal.parse(lines: Self.formulaError))
        #expect(f == UntrustedTapRefusal(type: "formula", name: "tankprobe/trust/tprobe", tap: "tankprobe/trust"))
        #expect(f.trustArguments == ["trust", "--tap", "tankprobe/trust"])
        #expect(f.trustCommand == "brew trust --tap tankprobe/trust")
        let c = try #require(UntrustedTapRefusal.parse(lines: Self.caskError))
        #expect(c.type == "cask" && c.name == "steipete/tap/codexbar" && c.tap == "steipete/tap")
        // brew vulns' unscanned note puts it on an indented line, without "Error: ".
        let v = UntrustedTapRefusal.parse("  Refusing to load formula yakitrak/yakitrak/notesmd-cli from untrusted tap yakitrak/yakitrak.\nRun `brew trust` on the formula or tap")
        #expect(v?.tap == "yakitrak/yakitrak")
        #expect(UntrustedTapRefusal.parse("Refusing to load command foo/bar/baz from untrusted tap foo/bar.")?.type == "command")
        // A tap with dots and dashes; no trailing period.
        #expect(UntrustedTapRefusal.parse("Refusing to load formula my-org/my.tap/x from untrusted tap my-org/my.tap")?.tap == "my-org/my.tap")
    }

    @Test func otherErrorsAreNotRefusals() {
        #expect(UntrustedTapRefusal.parse("Error: No available formula with the name \"nope\".") == nil)
        #expect(UntrustedTapRefusal.parse("Warning: Skipping tankprobe/trust because it is not trusted. Run `brew trust tankprobe/trust` to trust it.") == nil)
        #expect(BrewFailure.classify(["Error: No available formula with the name \"nope\"."]) == nil)
    }

    @Test func aTapNameNeverStartsWithADash() {
        // It goes into argv after --tap, so it must not read as an option.
        #expect(UntrustedTapRefusal.parse("Refusing to load formula -x/y/z from untrusted tap -x/y.") == nil)
        #expect(UntrustedTapRefusal.parse("Refusing to load formula x/-y/z from untrusted tap x/-y.") == nil)
        #expect(UntrustedTapRefusal.parse("Refusing to load formula x/y/z from untrusted tap x/y.")?.tap == "x/y")
    }

    @Test func classifiedAsUntrustedTapNotABuildFailure() {
        #expect(BrewFailure.classify(Self.formulaError) == .untrustedTap)
        #expect(BrewFailure.classify(["Error: An exception occurred within a child process:"] + Self.caskError) == .untrustedTap)
        #expect(BrewFailureKind.untrustedTap.title == "This tap isn't trusted yet")
    }

    @Test func nextStepNamesTheExactCommand() throws {
        let r = try #require(UntrustedTapRefusal.parse(lines: Self.formulaError))
        #expect(UpgradeSession.trustStep(r) == "tankprobe/trust isn't trusted yet. Run `brew trust --tap tankprobe/trust` in Terminal, or click Trust Tap…, then try again.")
        #expect(UpgradeSession.nextStep(.untrustedTap) == BrewFailureKind.untrustedTap.explanation)
    }

    @Test func aQuickActionBannerOffersTheTrustCommand() {
        let e = AppStore.quickError(verb: "Pin", name: "tprobe", args: ["pin", "tankprobe/trust/tprobe"],
                                    result: QuickResult(exitCode: 1, lines: Self.formulaError))
        #expect(e.title == "Pin tprobe: This tap isn't trusted yet")
        #expect(e.terminalCommand == "brew trust --tap tankprobe/trust")
    }

    @Test func anUnreadablePackageKnowsItsTap() {
        var p = Package.command("tprobe")
        p.unreadable = UnreadableKegs.reason(stderr: Self.formulaError.joined(separator: "\n"))
        #expect(p.untrustedTapRefusal?.tap == "tankprobe/trust")
        p.unreadable = "" // brew gave no reason
        #expect(p.untrustedTapRefusal == nil)
    }

    /// A failed run says why, notes the command, and keeps the tap for Trust Tap….
    @Test func aRefusedRunNamesTheTap() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log, behaviour: { args, out in
            if args.first == "upgrade" {
                out(Data((Self.formulaError.joined(separator: "\n") + "\n").utf8))
                return 1
            }
            return 0
        })
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
        await store.start()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        store.startUpgrade([xz])
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        let s = try #require(store.upgrade)
        #expect(s.failureKinds == [.untrustedTap])
        #expect(s.untrustedTap?.tap == "tankprobe/trust")
        #expect(s.nextStep?.contains("brew trust --tap tankprobe/trust") == true)
        #expect(s.log.lines.contains { $0.contains("brew trust --tap tankprobe/trust") && !$0.contains("or `brew trust") })
    }

    /// Trust Tap… runs `brew trust --tap` through the queue, then reads again.
    @Test func trustTapRunsBrewTrust() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await store.start()
        let reads = store.refreshesCompleted
        store.trustTap(named: "mull-project/mull")
        #expect(await waitUntil { store.history.entries.contains { $0.arguments == ["trust", "--tap", "mull-project/mull"] } })
        #expect(await waitUntil { store.refreshesCompleted > reads })
        #expect(store.error == nil)
    }
}
