import AskpassSupport
import Foundation
import Security
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.8: the defensive security review (scratch/security/tankard-review.md).
// One suite per finding; the core-only ones are in V088SecurityCoreTests.

/// #1: the TANKARD_* test switches are inert in a Developer ID build.
struct V088TestHooksTests {
    @Test func onlyBuildsWithoutATeamIDHonourTheSwitches() {
        #expect(TestHooks.allowed(signing: .adhoc, markerTrusted: false))
        #expect(TestHooks.allowed(signing: .unsigned, markerTrusted: false))
        #expect(!TestHooks.allowed(signing: .team("ABCDE12345"), markerTrusted: false))
        // A signature that can't be read counts as a release (fails closed).
        #expect(!TestHooks.allowed(signing: .unknown, markerTrusted: false))
        // The release-candidate e2e: an administrator's marker file.
        #expect(TestHooks.allowed(signing: .team("ABCDE12345"), markerTrusted: true))
    }

    @Test func signingKindFromTheSignatureInformation() {
        let team = [kSecCodeInfoIdentifier as String: "net.mindtricks.tankard",
                    kSecCodeInfoTeamIdentifier as String: "ABCDE12345"] as [String: Any]
        #expect(TestHooks.signing(info: team) == .team("ABCDE12345"))
        let adhoc = [kSecCodeInfoIdentifier as String: "TankardApp",
                     kSecCodeInfoFlags as String: NSNumber(value: SecCodeSignatureFlags.adhoc.rawValue)] as [String: Any]
        #expect(TestHooks.signing(info: adhoc) == .adhoc)
        #expect(TestHooks.signing(info: [:]) == .unsigned)
        // Signed, no Team ID, not ad-hoc: unknown, so treated as a release.
        #expect(TestHooks.signing(info: [kSecCodeInfoIdentifier as String: "x"]) == .unknown)
    }

    @Test func releaseEnvironmentLosesEveryTankardVariable() {
        let env = ["TANKARD_BREW": "/Users/x/.x/brew", "TANKARD_E2E": "1", "TANKARD_SCRIPT": "/tmp/s",
                   "TANKARD_UPDATE_FEED": "/tmp/f", "TANKARD_SNAPSHOT": "/tmp/p.png", "TANKARD_ASKPASS_SNAPSHOT": "/tmp/a.png",
                   "HOME": "/Users/x", "HOMEBREW_TANKARD_ASKPASS_CONTEXT": "brew upgrade --cask x"]
        let release = TestHooks.filtered(env, allowed: false)
        #expect(release == ["HOME": "/Users/x", "HOMEBREW_TANKARD_ASKPASS_CONTEXT": "brew upgrade --cask x"])
        #expect(TestHooks.filtered(env, allowed: true) == env)
    }

    @Test func markerMustBeRootsAndUnwritableByOthersAllTheWayUp() {
        let marker = TestHooks.markerPath
        let rootDir = TestHooks.FileFacts(kind: .directory, uid: 0, mode: 0o755)
        let rootFile = TestHooks.FileFacts(kind: .file, uid: 0, mode: 0o644)
        func check(_ overrides: [String: TestHooks.FileFacts?]) -> Bool {
            TestHooks.markerTrusted(path: marker) { path in
                if let o = overrides[path] { return o }
                return path == marker ? rootFile : rootDir
            }
        }
        #expect(check([:]))
        #expect(!check([marker: nil]))
        #expect(!check([marker: .init(kind: .file, uid: 501, mode: 0o644)]))
        #expect(!check([marker: .init(kind: .file, uid: 0, mode: 0o666)]))
        #expect(!check([marker: .init(kind: .other, uid: 0, mode: 0o755)])) // a symlink
        #expect(!check(["/Library/Application Support/Tankard": .init(kind: .directory, uid: 501, mode: 0o755)]))
        #expect(!check(["/Library/Application Support": .init(kind: .directory, uid: 0, mode: 0o777)]))
        #expect(!check(["/Library": .init(kind: .other, uid: 0, mode: 0o755)]))
    }

    @Test func appRunsOnlyAStandardBrew() async throws {
        // TANKARD_BREW pointing anywhere else finds no brew at all.
        let deps = AppStore.Dependencies.live(environment: ["TANKARD_BREW": "/Users/x/.x/brew"])
        #expect(throws: BrewClientError.self) { try deps.makeClient() }
        #expect(BrewInstallation.locate(override: "/bin/ls", standardOnly: true) == nil)
        // The CLI keeps its --brew / TANKARD_BREW.
        #expect(BrewInstallation.locate(override: "/bin/ls")?.brewPath == "/bin/ls")
    }
}
