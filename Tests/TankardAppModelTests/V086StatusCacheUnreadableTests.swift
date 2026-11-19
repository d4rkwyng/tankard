import Foundation
import Testing
@testable import TankardAppModel
@testable import TankardCore

/// rc1 e2e: a Mac with one package brew can't read (no dependency list)
/// had its status cache refused on every launch, so the window waited for
/// brew instead of showing the cached list first.
struct V086StatusCacheUnreadableTests {
    func report(_ packages: [Package]) -> StatusReport {
        StatusReport(generatedAt: Date(), host: HostInfo(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew",
                                                         platform: BottlePlatform(arch: .arm64, macOSVersion: "15", cellar: "/opt/homebrew/Cellar"), bottleTag: "arm64_sequoia"),
                     intelbrew: IntelbrewDetection(detected: false, reasons: [], env: [:], found: [:]),
                     fork: ForkStatus(brewRepository: "/opt/homebrew"),
                     packages: packages)
    }

    func cache() -> StatusCache {
        StatusCache(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("tankard-cache-\(UUID().uuidString)/status.json"))
    }

    func readable(_ name: String) -> Package {
        var p = Package.command(name)
        p.id = "formula:\(name)"
        p.kind = .formula
        p.dependencies = []
        return p
    }

    @Test func anUnreadableRowKeepsTheCache() throws {
        var odd = Package.command("obsidian-cli")
        odd.id = "formula:yakitrak/yakitrak/obsidian-cli"
        odd.kind = .formula
        odd.dependencies = nil
        odd.unreadable = "Refusing to load formula from untrusted tap yakitrak/yakitrak."
        let c = cache()
        try c.save(report([readable("wget"), odd]))
        let loaded = try #require(c.load())
        #expect(loaded.packages.count == 2)
        #expect(loaded.packages[1].unreadable != nil)
    }

    @Test func aReadableRowWithoutDependenciesStillVoidsIt() throws {
        var old = readable("jq")
        old.dependencies = nil
        let c = cache()
        try c.save(report([readable("wget"), old]))
        #expect(c.load() == nil)
    }
}
