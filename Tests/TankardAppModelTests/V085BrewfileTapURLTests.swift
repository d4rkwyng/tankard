import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5 (bug hunt M3): a Brewfile's `tap "user/repo", "https://…"` lost its
// URL, so Add Tap… cloned GitHub's default remote, and Install with Tankard
// ran while taps were missing (brew then auto-taps a qualified name from
// GitHub). Now the URL is read from the file's text, shown and passed to
// `brew tap`, and Install waits for the taps.
@MainActor
struct V085BrewfileTapURLTests {
    @Test func scansPlainTapLines() {
        let text = """
        # my Mac
        tap "homebrew/bundle"
        tap "Acme/homebrew-Tools", "https://git.acme.internal/tools.git"
        tap 'me/probe', 'file:///Users/me/tap'  # local
        tap("paren/tap", "git@example.com:paren/tap.git")
        tap "opts/tap", force_auto_update: true
        tap "var/tap", ENV["TAP_URL"]
        tap "interp/tap", "https://#{host}/x.git"
        tap "both/tap"
        tap "both/tap", "https://example.com/both.git"
        brew "jq"
        tapper "not/a-tap"
        """
        let s = BrewfileTapScanner.scan(text)
        #expect(s["homebrew/bundle"] == .standard)
        #expect(s["acme/tools"] == .url("https://git.acme.internal/tools.git"))
        #expect(s["me/probe"] == .url("file:///Users/me/tap"))
        #expect(s["paren/tap"] == .url("git@example.com:paren/tap.git"))
        #expect(s["opts/tap"] == .standard)
        #expect(s["var/tap"] == .unreadable)
        #expect(s["interp/tap"] == .unreadable)
        #expect(s["both/tap"] == .unreadable)
        #expect(s["not/a-tap"] == nil)
        #expect(s.count == 8)
    }

    @Test func planCarriesTheURLAndWaitsForTaps() async throws {
        let result = BrewfileCheckResult(path: "/x/Brewfile", missing: [
            BrewfileEntry(kind: .tap, name: "acme/tools"), BrewfileEntry(kind: .tap, name: "hidden/tap"),
            BrewfileEntry(kind: .formula, name: "acme/tools/widget")])
        let (plan, _) = await BrewfileStore.buildPlan(result, platform: nil, run: { _ in
            ProcessResult(exitCode: 1, stdout: Data(), stderr: Data())
        }, readFile: { path in
            path == "/x/Brewfile" ? "tap \"acme/tools\", \"https://git.acme.internal/tools.git\"\nbrew \"acme/tools/widget\"\n" : nil
        })
        let acme = try #require(plan.items.first { $0.entry.name == "acme/tools" })
        #expect(acme.tapURL == "https://git.acme.internal/tools.git")
        #expect(acme.canAddTap)
        // Not literally in the file: left to brew bundle in Terminal.
        let hidden = try #require(plan.items.first { $0.entry.name == "hidden/tap" })
        #expect(!hidden.canAddTap)
        #expect(plan.missingTaps.count == 2)
        #expect(!plan.canInstallWithTankard)
        #expect(BrewfileCommands.tapDisplay("acme/tools", url: acme.tapURL) == "brew tap acme/tools https://git.acme.internal/tools.git")

        // Without taps missing, Install is on.
        let ready = BrewfileRestorePlan(missing: [BrewfileEntry(kind: .formula, name: "jq")], path: "/x/Brewfile")
        #expect(ready.canInstallWithTankard)
    }

    @Test func addTapUsesTheURLAndInstallWaits() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await store.start()
        let item = BrewfileRestorePlan(missing: [BrewfileEntry(kind: .tap, name: "acme/tools")], path: "/b",
                                       tapSources: ["acme/tools": .url("https://git.acme.internal/tools.git")]).items[0]
        #expect(store.taps.requestAdd(name: item.entry.name, url: item.tapURL ?? "", source: .brewfile) == nil)
        let req = try #require(store.taps.pendingAdd)
        #expect(req.arguments == ["tap", "acme/tools", "https://git.acme.internal/tools.git"])
        // The confirmation names the Brewfile's remote, not GitHub's.
        #expect(req.warning.contains("https://git.acme.internal/tools.git"))
        #expect(!req.warning.contains("github.com"))

        // The demo's plan: hashicorp/tap is missing, so Install waits.
        store.checkBrewfile(at: "/Users/you/Desktop/Brewfile")
        await store.brewfile.waitForIdle()
        guard case .checked(let r) = store.brewfile.page else { Issue.record("no check result"); return }
        store.brewfile.planRestore(r)
        await store.brewfile.waitForIdle()
        guard case .plan(let plan, _) = store.brewfile.page else { Issue.record("no plan"); return }
        #expect(plan.items.first { $0.entry.kind == .tap }?.tapSource == .standard)
        #expect(!plan.canInstallWithTankard)
        store.installBrewfilePlan(plan)
        #expect(store.brewfile.isPresented)
        #expect(store.upgrade == nil)
    }
}
