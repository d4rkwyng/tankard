import Foundation
import Testing
@testable import TankardCore

// 0.8.8: the defensive security review, core parts (the rest are in
// TankardAppModelTests/V088SecurityTests.swift).
struct V088SecurityCoreTests {
    /// #5: names after `brew info`'s options can't be read as options.
    @Test func infoPutsDoubleDashBeforeNames() {
        #expect(BrewClient.infoArguments(["--force", "jq"], kind: .formula) == ["info", "--json=v2", "--formula", "--", "--force", "jq"])
    }

    /// #7: an origin from .git/config is always the repository operand.
    @Test func lsRemoteOriginFollowsDoubleDash() async {
        #expect(BrewClient.lsRemoteTagsArguments("--upload-pack=touch /tmp/x")
                == ["ls-remote", "--tags", "--", "--upload-pack=touch /tmp/x"])
        let evil = "--upload-pack=touch /tmp/tankard-pwned"
        let runner = FakeRunner { _, args in
            args.contains("remote.origin.url") ? ok(evil) : ok("")
        }
        let installation = BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew")
        let client = BrewClient(installation: installation, runner: runner,
                                sources: EnvironmentSources(process: [:], shellProfiles: []), fileExists: { _ in true })
        _ = await client.forkStatus(checkRemote: true)
        let lsRemote = runner.calls.map(\.arguments).filter { $0.contains("ls-remote") }
        #expect(lsRemote == [["-C", "/opt/homebrew", "ls-remote", "--tags", "--", evil]])
    }

    /// #1: the GUI's brew is a standard one only.
    @Test func standardOnlyLocateRefusesOtherPaths() {
        #expect(BrewInstallation.locate(override: "/tmp/x/brew", standardOnly: true) == nil)
        #expect(BrewInstallation.locate(override: "/nonexistent/tankard-e2e/bin/brew", standardOnly: true) == nil)
        for c in BrewInstallation.candidates where FileManager.default.isExecutableFile(atPath: c) {
            #expect(BrewInstallation.locate(override: c, standardOnly: true)?.brewPath == c)
        }
    }
}
