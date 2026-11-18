import Foundation
import Testing
@testable import TankardAppModel
import TankardCore

/// Check for Tankard Updates…: the GitHub answer, the version compare and
/// how this copy was installed. No network: a fake fetcher.
@MainActor
struct SelfUpdateTests {
    func json(_ tag: String, body: String = "## Added\n- **Thing**: new") -> Data {
        Data(#"{"tag_name":"\#(tag)","body":\#(String(data: try! JSONEncoder().encode(body), encoding: .utf8)!),"html_url":"https://github.com/d4rkwyng/tankard/releases/tag/\#(tag)","draft":false,"prerelease":false}"#.utf8)
    }

    func feed(_ data: Data, _ status: Int = 200) -> UpdateFeed { UpdateFeed { (data, status) } }

    @Test func newerRelease() async {
        let r = await feed(json("v0.9.0")).check(current: "0.8.1")
        guard case .available(let rel) = r else { Issue.record("\(r)"); return }
        #expect(rel.version == "0.9.0")
        #expect(rel.notes == "Added\n• Thing: new")
        #expect(rel.url.absoluteString == "https://github.com/d4rkwyng/tankard/releases/tag/v0.9.0")
    }

    @Test func sameAndOlderAreUpToDate() async {
        #expect(await feed(json("v0.8.1")).check(current: "0.8.1") == .upToDate("0.8.1"))
        // A development build newer than the last release.
        #expect(await feed(json("v0.8.0")).check(current: "0.8.1") == .upToDate("0.8.1"))
    }

    @Test func malformedAndHTTPErrors() async {
        #expect(await feed(Data("not json".utf8)).check(current: "0.8.1") == .failed("GitHub's answer couldn't be read."))
        #expect(await feed(json("latest")).check(current: "0.8.1") == .failed("GitHub's answer couldn't be read."))
        #expect(await feed(Data(), 404).check(current: "0.8.1") == .failed("GitHub lists no release of Tankard."))
        #expect(await feed(Data(), 403).check(current: "0.8.1") == .failed("GitHub answered HTTP 403."))
        let pre = Data(#"{"tag_name":"v9.0.0","prerelease":true}"#.utf8)
        #expect(await feed(pre).check(current: "0.8.1") == .failed("GitHub's answer couldn't be read."))
    }

    @Test func offline() async {
        let r = await UpdateFeed { throw URLError(.notConnectedToInternet) }.check(current: "0.8.1")
        #expect(r == .failed("Couldn't reach GitHub. Check the connection and try again."))
        #expect(await UpdateFeed.file("/nonexistent/feed.json").check(current: "0.8.1")
                == .failed("Couldn't reach GitHub. Check the connection and try again."))
    }

    @Test func semverOrder() throws {
        func v(_ s: String) throws -> SemanticVersion { try #require(SemanticVersion(s)) }
        #expect(try v("0.8.1") < v("0.8.10"))
        #expect(try v("0.9.0-rc.1") < v("0.9.0"))
        #expect(try v("0.9.0-rc.2") < v("0.9.0-rc.10"))
        #expect(try v("v1.0") == v("1.0.0"))
        #expect(SemanticVersion("1.x") == nil)
        #expect(SemanticVersion("") == nil)
    }

    @Test func notesSummaryIsShortened() {
        let long = "## Fixed\n" + (1...100).map { "- line \($0)" }.joined(separator: "\n")
        let s = ReleaseNotesSummary.make(long, limit: 5)
        #expect(s.items == [.heading("Fixed"), .bullet("line 1"), .bullet("line 2"), .bullet("line 3"), .bullet("line 4"), .bullet("line 5")])
        #expect(s.more == 95)
        #expect(s.plainText.hasSuffix("…and 95 more"))
    }

    @Test func brewInstalledVersusZip() {
        let app = "/Applications/Tankard.app"
        let cask = AppStore.demoTankardCask(bundlePath: app)
        #expect(SelfInstall.isTankardCask(cask))
        #expect(SelfInstall.brewPackage(in: [cask], bundlePath: app) == cask)
        // A zip copy elsewhere, or no cask at all.
        #expect(SelfInstall.brewPackage(in: [cask], bundlePath: "/Users/x/Downloads/Tankard.app") == nil)
        #expect(SelfInstall.brewPackage(in: [], bundlePath: app) == nil)
        var other = cask
        other.tap = "someone/tap"
        #expect(SelfInstall.brewPackage(in: [other], bundlePath: app) == nil)
    }

    /// brew must not quit the app that runs it: always no-quit for Tankard's own cask.
    @Test func ownCaskUpgradeNeverQuitsTheApp() {
        let cask = AppStore.demoTankardCask(bundlePath: "/Applications/Tankard.app")
        #expect(InsightSettings.extraEnvironment(.upgrade, cask, dontQuitApps: false) == [InsightSettings.noQuitKey: "1"])
        var other = cask
        other.tap = "homebrew/cask"
        #expect(InsightSettings.extraEnvironment(.upgrade, other, dontQuitApps: false).isEmpty)
    }
}
