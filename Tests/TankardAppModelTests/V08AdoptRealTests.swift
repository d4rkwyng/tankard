import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.8: a REAL adoption, off unless asked for. It runs this Mac's brew
// through Tankard's own code path: the live scan (formulae.brew.sh's
// cask.json through Discover's cache, the real /Applications), the sheet's
// choices and confirmation, `brew install --cask --adopt` through the
// queue, the refresh, then the uninstall session. Place the cask's own app
// at its target first (one you put there yourself, nothing else):
//
//   TANKARD_REAL_ADOPT_TOKEN=anybar TANKARD_REAL_ADOPT_APP=/Applications/AnyBar.app \
//     Scripts/test.sh --filter V08AdoptRealTests
//
// TANKARD_REAL_ADOPT_KEEP=1 leaves the cask installed (no uninstall).

@MainActor
struct V08AdoptRealTests {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["TANKARD_REAL_ADOPT_TOKEN"] != nil && env["TANKARD_REAL_ADOPT_APP"] != nil),
          .timeLimit(.minutes(5)))
    func realAdoptThenUninstall() async throws {
        let token = try #require(Self.env["TANKARD_REAL_ADOPT_TOKEN"])
        let appPath = try #require(Self.env["TANKARD_REAL_ADOPT_APP"])
        #expect(FileManager.default.fileExists(atPath: appPath), "place \(appPath) first")
        let deps = AppStore.Dependencies(makeClient: { try BrewClient.locate(override: nil) },
                                         streamRunner: StreamingProcessRunner(), cache: nil, logURL: nil)
        let store = AppStore(deps: deps)
        await store.start()
        #expect(store.report != nil)
        #expect(!store.packages.contains { $0.kind == .cask && $0.name == token }, "\(token) is already installed")

        // The scan, as Homebrew ▸ Adopt Apps… runs it.
        store.openAdopt()
        #expect(await waitUntil(timeout: .seconds(90)) { store.adopt.phase == .ready })
        let a = store.adopt
        print("adopt-real: source \(a.source); rows \(a.scan.rows.count); skipped managed \(a.scan.skipped.managed.count) appStore \(a.scan.skipped.appStore.count) apple \(a.scan.skipped.apple.count)")
        for g in AdoptGroup.allCases {
            print("adopt-real: \(g.rawValue): " + a.rows(g).map { "\($0.app.relativePath)=\(a.token($0) ?? "-")/\(a.confidence($0)?.rawValue ?? "-")" }.joined(separator: ", "))
        }
        let row = try #require(a.scan.rows.first { $0.app.path == appPath })
        #expect(a.token(row) == token)
        #expect(a.group(row) == .ready)
        // Only this app.
        for r in a.rows(.ready) { a.setTicked(r, r.id == row.id) }
        a.setTicked(row, true)
        #expect(a.plan.map(\.token) == [token])
        a.requestAdopt()
        #expect(a.pendingConfirm?.first?.arguments == ["install", "--cask", "--adopt", "homebrew/cask/\(token)"])
        store.confirmAdopt()
        #expect(await waitUntil(timeout: .seconds(10)) { store.upgrade?.action == .adopt })
        #expect(await waitUntil(timeout: .seconds(240)) { store.upgrade?.isFinished == true })
        let session = try #require(store.upgrade)
        print("adopt-real log:\n" + session.log.lines.joined(separator: "\n"))
        #expect(session.succeededCount == 1)
        #expect(await waitUntil(timeout: .seconds(60)) { store.packages.contains { $0.kind == .cask && $0.name == token } })
        #expect(FileManager.default.fileExists(atPath: appPath))
        await a.load()
        #expect(a.scan.skipped.managed.contains { $0.path == appPath })

        guard Self.env["TANKARD_REAL_ADOPT_KEEP"] != "1" else { return }
        // Uninstall through Tankard's own uninstall session.
        let pkg = try #require(store.packages.first { $0.kind == .cask && $0.name == token })
        #expect(await waitUntil(timeout: .seconds(30)) { !store.isUpgrading && !store.isRefreshing })
        store.startSession(.uninstall, packages: [pkg], skipGate: true)
        #expect(await waitUntil(timeout: .seconds(10)) { store.upgrade?.action == .uninstall })
        #expect(await waitUntil(timeout: .seconds(120)) { store.upgrade?.isFinished == true })
        print("adopt-real uninstall log:\n" + (store.upgrade?.log.lines.joined(separator: "\n") ?? ""))
        #expect(store.upgrade?.succeededCount == 1)
        #expect(await waitUntil(timeout: .seconds(60)) { !store.packages.contains { $0.kind == .cask && $0.name == token } })
        #expect(!FileManager.default.fileExists(atPath: appPath))
    }
}
