import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.3: Stop Now and the lock wait against this Mac's REAL brew, through
// Tankard's own store, queue, runner and session (what the sheet shows).
// Off unless asked for:
//
//   TANKARD_REAL_CANCEL_CASK=font-inter Scripts/test.sh --filter V083QueueRobustRealTests
//     installs the cask (no app; remove its cached download first so brew
//     really downloads), clicks Stop Now mid-download; nothing may be installed.
//
//   TANKARD_REAL_LOCK_FORMULA=tap/name/formula Scripts/test.sh --filter V083QueueRobustRealTests
//     a throwaway formula, installed and outdated, whose upgrade takes a
//     while: a second brew (started here, as a Terminal brew would be)
//     upgrades it and holds its lock while Tankard upgrades it too.

@MainActor
struct V083QueueRobustRealTests {
    nonisolated static let env = ProcessInfo.processInfo.environment

    func liveStore() throws -> AppStore {
        var deps = AppStore.Dependencies(makeClient: { try BrewClient.locate(override: nil) },
                                         streamRunner: StreamingProcessRunner(), cache: nil, logURL: nil)
        deps.downloadMonitor = { client, env in DownloadMonitor.live(client: client, env: env) }
        deps.lockWait = .live
        return AppStore(deps: deps, settings: .ephemeral("net.mindtricks.tankard.test.real083"))
    }

    nonisolated static func brew(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        p.arguments = args
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                         "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1",
                         "HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    @Test(.enabled(if: env["TANKARD_REAL_CANCEL_CASK"] != nil), .timeLimit(.minutes(5)))
    func stopNowDuringARealDownload() async throws {
        let token = try #require(Self.env["TANKARD_REAL_CANCEL_CASK"])
        #expect(Self.brew(["list", "--cask", token]).0 != 0, "\(token) is already installed")
        let store = try liveStore()
        await store.start()
        var p = Package.command(token)
        p.id = "cask:homebrew/cask/\(token)"
        p.kind = .cask
        p.tap = "homebrew/cask"
        store.startSession(.install, packages: [p], skipGate: true)
        let s = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(90)) { (s.download?.bytes ?? 0) > 0 || s.isFinished })
        let seen = s.download
        print("cancel-real: mid-download: \(s.statusLine)")
        #expect(seen != nil, "no download seen (cached?)")
        #expect(!s.stopNowNeedsConfirmation, "downloading: Stop Now needs no confirmation")
        let stopAt = ContinuousClock.now
        s.requestStopNow()
        #expect(await waitUntil(timeout: .seconds(40)) { s.isFinished })
        print("cancel-real: stopped in \(ContinuousClock.now - stopAt)")
        print("cancel-real log:\n" + s.log.lines.joined(separator: "\n"))
        #expect(s.items[0].state == .cancelled)
        #expect(s.title == "Install stopped")
        #expect(await waitUntil(timeout: .seconds(5)) { store.history.entries.first?.outcome == .cancelled })
        print("cancel-real: History: \(store.history.entries.first.map { "\($0.command) → \($0.resultText)" } ?? "none")")
        #expect(await waitUntil(timeout: .seconds(60)) { !store.isRefreshing })
        #expect(!store.packages.contains { $0.kind == .cask && $0.name == token })
        let list = Self.brew(["list", "--cask", token])
        print("cancel-real: brew list --cask \(token): exit \(list.0) \(list.1.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(list.0 != 0, "nothing installed")
    }

    @Test(.enabled(if: env["TANKARD_REAL_LOCK_FORMULA"] != nil), .timeLimit(.minutes(5)))
    func waitsForARealBrewHoldingTheLock() async throws {
        let full = try #require(Self.env["TANKARD_REAL_LOCK_FORMULA"])
        let name = String(full.split(separator: "/").last ?? "")
        let store = try liveStore()
        await store.start()
        let pkg = try #require(store.packages.first { $0.name == name && $0.upgradeAvailable }, "\(name) installed and outdated")
        // The other brew, as one in Terminal.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        holder.arguments = ["upgrade", "--formula", full]
        holder.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                              "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1"]
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        let lockFile = "/opt/homebrew/var/homebrew/locks/\(name).formula.lock"
        let held = await waitUntil(timeout: .seconds(60)) { !(LockHolders.lsof(lockFile) ?? []).isEmpty }
        #expect(held, "the other brew never took \(lockFile)")
        print("lock-real: holder \(LockHolders.lsof(lockFile) ?? [])")
        store.startUpgrade([pkg])
        let s = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(60)) { s.lockWait != nil || s.isFinished })
        print("lock-real: while held: \(s.statusLine) [lockWait: \(s.lockWait ?? "nil")]")
        #expect(s.statusLine == "Waiting for another Homebrew command to finish…")
        #expect(await waitUntil(timeout: .seconds(180)) { s.isFinished })
        holder.waitUntilExit()
        print("lock-real: holder exit \(holder.terminationStatus)")
        print("lock-real log:\n" + s.log.lines.joined(separator: "\n"))
        #expect(s.items[0].state == .done)
        #expect(s.failedItems.isEmpty)
        #expect(s.log.lines.contains { $0.contains("running it again") })
        #expect(await waitUntil(timeout: .seconds(5)) { store.history.entries.first?.outcome == .succeeded })
    }
}
