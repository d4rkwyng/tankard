import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

/// 0.8.4: every request Tankard makes itself sends TankardVersion.userAgent,
/// "Tankard/<TankardVersion.string>", the version the update check uses.
struct V084UserAgentTests {
    private func agent(_ c: URLSessionConfiguration) -> String? {
        c.httpAdditionalHeaders?["User-Agent"] as? String
    }

    @Test func userAgentIsTheVersionString() {
        #expect(TankardVersion.userAgent == "Tankard/\(TankardVersion.string)")
    }

    @Test func formulaeBrewShSendsIt() {
        #expect(APIFetcher.baseURL.host == "formulae.brew.sh")
        #expect(agent(APIFetcher.makeSession().configuration) == TankardVersion.userAgent)
    }

    @Test func githubUpdateFeedSendsIt() {
        #expect(UpdateFeed.latestURL.host == "api.github.com")
        let c = UpdateFeed.sessionConfiguration()
        #expect(agent(c) == TankardVersion.userAgent)
        #expect(c.httpAdditionalHeaders?["Accept"] as? String == "application/vnd.github+json")
    }

    @Test func buildTimesSendsIt() {
        #expect(agent(BuildTimeSource.sessionConfiguration()) == TankardVersion.userAgent)
    }
}
