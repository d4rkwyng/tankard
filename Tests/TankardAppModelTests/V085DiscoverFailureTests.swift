import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5 (bug hunt M4, L5): Discover offline with no cached catalog showed
// the raw NSError; now a sentence, with the error under Details. And a long
// query no longer runs for seconds, nor keeps running once a newer search
// has started.
private struct FailingCatalog: CatalogProviding {
    let error: Error
    var isLocalTaps = false
    func load() async throws -> CatalogLoad { throw error }
    func details(_ entries: [CatalogEntry]) async -> [CatalogEntry] { entries }
}

@MainActor
struct V085DiscoverFailureTests {
    // What the bug hunt's sandboxed offline run produced.
    static let sandboxed = NSError(domain: NSPOSIXErrorDomain, code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Operation not permitted",
        "_NSURLErrorFailingURLSessionTaskErrorKey": "LocalDataTask <ABC>.<1>",
        "_kCFStreamErrorDomainKey": 1,
    ])

    @Test func offlineSaysItInASentence() async {
        for error in [Self.sandboxed as Error, URLError(.notConnectedToInternet),
                      NSError(domain: NSURLErrorDomain, code: -1009, userInfo: nil),
                      NSError(domain: "Other", code: 9, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])] {
            let store = DiscoverStore(provider: FailingCatalog(error: error), debounce: .zero)
            await store.activate()
            guard case .failed(let message) = store.phase else { Issue.record("not failed"); continue }
            #expect(message == "Tankard couldn't reach the network to download Homebrew's list of packages. Check the internet connection (or a VPN or proxy), then try again.")
            #expect(!message.contains("Error Domain"))
            #expect(store.failureDetail == String(describing: error))
        }
    }

    @Test func otherFailuresAreGeneric() async {
        let store = DiscoverStore(provider: FailingCatalog(error: CocoaError(.coderReadCorrupt)), debounce: .zero)
        await store.activate()
        #expect(store.phase == .failed("Tankard couldn't load Homebrew's list of packages. Try again in a moment."))
        #expect(store.failureDetail?.isEmpty == false)
        let local = DiscoverStore(provider: FailingCatalog(error: Self.sandboxed, isLocalTaps: true), debounce: .zero)
        await local.activate()
        #expect(local.phase == .failed("Tankard couldn't read the packages in your taps. Try again in a moment."))
    }

    @Test func longQueriesAreCappedAndFast() {
        let entries = (0..<3000).map { i in
            CatalogEntry(kind: .formula, name: "pkg\(i)", fullName: "pkg\(i)", tap: "homebrew/core", desc: "a package number \(i)", bottle: .forThisMac)
        }
        let long = "pkg12" + String(repeating: "x", count: 100_000)
        let start = Date()
        _ = CatalogSearch.search(long, in: entries)
        #expect(Date().timeIntervalSince(start) < 2)
        // The first 256 characters are what's searched.
        let exact = String(repeating: "q", count: CatalogSearch.maxQueryLength)
        let withQ = entries + [CatalogEntry(kind: .formula, name: exact, fullName: exact, tap: "homebrew/core", desc: "", bottle: .forThisMac)]
        #expect(CatalogSearch.search(exact + "zzz", in: withQ).first?.name == exact)
    }

    @Test func aCancelledSearchStops() async {
        let entries = (0..<20000).map { i in
            CatalogEntry(kind: .formula, name: "pkg\(i)", fullName: "pkg\(i)", tap: "homebrew/core", desc: "a package number \(i)", bottle: .forThisMac)
        }
        let task = Task.detached { () -> [CatalogEntry] in
            withUnsafeCurrentTask { $0?.cancel() }
            return CatalogSearch.search("pkg", in: entries)
        }
        #expect(await task.value.isEmpty)
    }
}
