import Foundation
import Testing
@testable import TankardCore

struct BrewClientTests {
    static let install = BrewInstallation(brewPath: "/usr/local/bin/brew", prefix: "/usr/local", repository: "/usr/local/Homebrew")

    /// The VM, replayed: core on the fork, brew on upstream at 7.0.14.
    func vmRunner(infoFails: Bool = false) throws -> FakeRunner {
        let info = try Fixture.data("sonoma-intelbrew-info")
        return FakeRunner { exe, args in
            if exe.hasSuffix("brew") {
                if args.first == "info" { return infoFails ? failed : ok(info) }
                return failed
            }
            // git -C <repo> ...
            let repo = args[1], rest = Array(args.dropFirst(2))
            let isCore = repo.hasSuffix("homebrew-core")
            switch rest {
            case ["config", "--get", "remote.origin.url"]:
                return ok(isCore ? "https://github.com/d4rkwyng/intelbrew-core\n" : "https://github.com/Homebrew/brew\n")
            case ["rev-parse", "--abbrev-ref", "HEAD"]: return ok("intelbrew-staging\n")
            case ["describe", "--tags"], ["describe", "--tags", "--exact-match", "HEAD"]: return ok("7.0.14\n")
            case ["tag", "--list"]: return ok("7.0.9\n7.0.12\n7.0.13\n7.0.14\nnot-a-release\n")
            default: return failed
            }
        }
    }

    func client(_ runner: FakeRunner) -> BrewClient {
        BrewClient(installation: Self.install, platform: .intelSonoma, runner: runner,
                   sources: EnvironmentSources(process: ["HOME": "/Users/x"]))
    }

    @Test func forkStatusFromGit() async throws {
        // coreTapPath existence is checked on disk, so call the classifier-free parts directly.
        let tags = ["7.0.9", "7.0.12", "7.0.14", "7.0.13", "8.0.0-rc1"]
        #expect(BrewClient.newestReleaseTag(tags) == "7.0.14")
        #expect(BrewClient.newestReleaseTag(["7.0.9", "7.0.10"]) == "7.0.10") // not lexical
    }

    @Test func statusUsesIntelbrewEnvironment() async throws {
        let runner = try vmRunner()
        // Detection reads the core origin only if the tap exists on disk; the
        // test machine has no /usr/local/Homebrew, so supply the setting via env.
        var c = client(runner)
        c.sources = EnvironmentSources(process: ["HOME": "/Users/x", "HOMEBREW_CORE_GIT_REMOTE": Intelbrew.coreRemote])
        let report = try await c.status()

        #expect(report.intelbrew.detected)
        #expect(report.summary.installed == 20)
        #expect(report.summary.source == 1)
        #expect(report.packages["xz"]?.statusLabel == "Intelbrew bottle")
        #expect(report.fork.brewOrigin == "https://github.com/Homebrew/brew")
        #expect(!report.fork.brewIsFork)
        #expect(report.fork.brewTag == "7.0.14" && report.fork.brewNewestTag == "7.0.14")
        #expect(report.fork.brewAtNewestTag == true)
        #expect(Set(report.timingsMs.keys) == ["detect", "info", "git", "total"])

        let brewCalls = runner.calls.filter { $0.executable.hasSuffix("brew") }
        #expect(brewCalls.map(\.arguments) == [["info", "--json=v2", "--installed"]])
        for call in brewCalls {
            #expect(call.environment["HOMEBREW_NO_INSTALL_FROM_API"] == "1")
            #expect(call.environment["HOMEBREW_CORE_GIT_REMOTE"] == Intelbrew.coreRemote)
            #expect(call.environment["HOMEBREW_BREW_GIT_REMOTE"] == Intelbrew.brewRemote)
            #expect(call.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
            #expect(call.environment["PATH"] == "/usr/local/bin:/usr/local/sbin:/usr/bin:/bin")
        }
    }

    @Test func brewFailureIsReported() async throws {
        let c = client(try vmRunner(infoFails: true))
        await #expect(throws: BrewClientError.self) { try await c.status() }
    }

    @Test func jsonRoundTrip() async throws {
        var c = client(try vmRunner())
        c.sources = EnvironmentSources(process: ["HOME": "/Users/x", "HOMEBREW_CORE_GIT_REMOTE": Intelbrew.coreRemote])
        let report = try await c.status()
        let data = try StatusReport.jsonEncoder().encode(report)
        let back = try StatusReport.jsonDecoder().decode(StatusReport.self, from: data)
        #expect(back.packages == report.packages)
        #expect(back.summary == report.summary)
        #expect(back.schemaVersion == 1)

        // The documented top-level keys.
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(obj.keys) == ["schemaVersion", "generatedAt", "host", "intelbrew", "fork", "summary", "packages", "timingsMs", "warnings"])
    }

    @Test func textReport() async throws {
        var c = client(try vmRunner())
        c.sources = EnvironmentSources(process: ["HOME": "/Users/x", "HOMEBREW_CORE_GIT_REMOTE": Intelbrew.coreRemote])
        let report = try await c.status()
        let text = TextReport.render(report, filter: nil)
        #expect(text.contains("20 installed · 19 bottled · 1 source · 0 newer · 0 upgrades (0 with bottles)"))
        #expect(text.contains("brew: https://github.com/Homebrew/brew at 7.0.14 — NOT the d4rkwyng/brew fork"))
        let filtered = TextReport.render(report, filter: .source)
        #expect(filtered.contains("vim"))
        #expect(!filtered.contains("xz "))
        #expect(TextReport.render(report, filter: .newer).contains("No packages match --filter newer."))
    }
}
