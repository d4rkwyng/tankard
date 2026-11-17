import Foundation
import Testing
@testable import TankardCore

/// Off by default. TANKARD_BENCH_TAPS=<a Library/Taps directory> times the
/// tap index and the 0.3 bottle/depends_on scan over it. Debug builds are
/// several times slower than the app; use
/// `Scripts/test.sh -c release -Xswiftc -enable-testing --filter IndexBench`.
struct IndexBench {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TANKARD_BENCH_TAPS"] != nil))
    func bench() {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TANKARD_BENCH_TAPS"]!)
        let ix = TapIndexer(tapsDirectory: dir)
        let files = TapIndexer.rubyFiles(in: dir.appendingPathComponent("homebrew/homebrew-core/Formula"))
        let c = ContinuousClock()
        var t = c.now
        let heads = files.map { TapIndexer.head(of: $0) }
        print("read heads", c.now - t); t = c.now
        _ = heads.map { TapIndexer.argument("desc", in: $0) }
        print("desc", c.now - t); t = c.now
        _ = heads.map { $0.range(of: Data("\n  bottle do".utf8)) }
        print("range bottle", c.now - t); t = c.now
        _ = heads.map { FormulaScanner.scan($0, tap: "homebrew/core") }
        print("scan", c.now - t); t = c.now
        let idx = ix.index()
        print("full index", c.now - t, idx.entries.count)
    }
}
