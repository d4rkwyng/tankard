import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

/// A live canary for Intelbrew-mode Discover, off by default. With
/// TANKARD_LIVE_SEARCH=<query> it runs the real thing against this Mac's
/// brew, read-only: index the local taps, search, then one `brew info`
/// batch for the top rows, and prints the timings.
///
///   TANKARD_LIVE_SEARCH=python Scripts/test.sh --filter LiveSearchCanary
@MainActor
struct LiveSearchCanary {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TANKARD_LIVE_SEARCH"] != nil))
    func timings() async throws {
        let query = ProcessInfo.processInfo.environment["TANKARD_LIVE_SEARCH"] ?? "python"
        let client = try BrewClient.locate(override: ProcessInfo.processInfo.environment["TANKARD_BREW"])
        let detection = await client.detectIntelbrew()
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> String { String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }

        let catalog = TapCatalog(client: client, detection: detection)
        let t0 = clock.now
        let load = try await catalog.load()
        let tIndex = clock.now - t0

        let t1 = clock.now
        let results = CatalogSearch.search(query, in: load.entries)
        let tSearch = clock.now - t1

        let top = Array(results.prefix(30))
        let t2 = clock.now
        let filled = await catalog.details(top)
        let tInfo = clock.now - t2

        let t3 = clock.now
        let one = await catalog.details(Array(results.prefix(1)))
        let tOne = clock.now - t3

        // The bottle the tap scan found vs what brew info says, for the same rows.
        let scanned = Dictionary(top.map { ($0.id, $0.bottle) }, uniquingKeysWith: { a, _ in a })
        var agree = 0
        var disagree: [String] = []
        for f in filled where f.kind == .formula {
            if scanned[f.id] == f.bottle { agree += 1 } else { disagree.append("\(f.name) scan=\(scanned[f.id].map { "\($0)" } ?? "?") info=\(f.bottle)") }
        }
        print("""
        live search: intelbrew=\(detection.detected) \(load.source)
          index (list taps, read desc lines, scan bottle blocks and depends_on): \(ms(tIndex)) for \(load.entries.count) entries
          search "\(query)" in memory: \(ms(tSearch)), \(results.count) results
          brew info --json=v2, top \(top.count) in one batch: \(ms(tInfo)), \(filled.filter { $0.version != nil }.count) with versions
          brew info --json=v2, 1 name: \(ms(tOne))
          badges: \(filled.prefix(8).map { "\($0.name)=\($0.badgeLabel)" }.joined(separator: ", "))
          casks enabled: \(load.casksEnabled)
          0.3 bottle scan: \(CatalogSearch.bottledCount(load.entries).bottled) of \(CatalogSearch.bottledCount(load.entries).formulae) formulae bottled for this Mac
          0.3 scan vs brew info (top \(filled.count)): \(agree) agree\(disagree.isEmpty ? "" : "; differ: " + disagree.joined(separator: ", "))
        """)
        #expect(!load.entries.isEmpty)
        #expect(one.count <= 1)
    }
}

/// Off by default. TANKARD_LIVE_API_DIR=<dir with formula.json and
/// cask.json> times decoding the full formulae.brew.sh catalogue and one
/// search over it (no network).
@MainActor
struct LiveAPIDecodeCanary {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TANKARD_LIVE_API_DIR"] != nil))
    func timings() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TANKARD_LIVE_API_DIR"]!)
        let f = try Data(contentsOf: dir.appendingPathComponent("formula.json"))
        let c = try Data(contentsOf: dir.appendingPathComponent("cask.json"))
        let clock = ContinuousClock()
        let t0 = clock.now
        let load = try APICatalog.build(formulaJSON: f, caskJSON: c,
                                        builder: CatalogBuilder(platform: BottlePlatform.current(prefix: "/usr/local"), intelbrewMode: false))
        let tDecode = clock.now - t0
        let t1 = clock.now
        let r = CatalogSearch.search("python", in: load.entries)
        let tSearch = clock.now - t1
        print("live api: decode \(f.count + c.count) bytes -> \(load.entries.count) entries: \(tDecode); search python: \(tSearch), \(r.count) results")
        #expect(load.entries.count > 1000)
    }
}
