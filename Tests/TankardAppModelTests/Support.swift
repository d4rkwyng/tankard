import Foundation
import os
import TankardCore
@testable import TankardAppModel

/// A shared, ordered record of everything the fakes were asked to run.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    func add(_ c: [String]) { lock.withLock { _calls.append(c) } }
    var calls: [[String]] { lock.withLock { _calls } }
    func count(_ first: String) -> Int { calls.filter { $0.first == first }.count }
}

/// Answers `brew info` (from a fixture, or failing) and git probes.
final class FakeInfoRunner: CommandRunning, @unchecked Sendable {
    let log: CallLog
    let info: Data
    private let lock = NSLock()
    private var _failInfo = false
    var failInfo: Bool {
        get { lock.withLock { _failInfo } }
        set { lock.withLock { _failInfo = newValue } }
    }

    init(log: CallLog, info: Data) {
        self.log = log
        self.info = info
    }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        if executable.hasSuffix("brew") {
            log.add(arguments)
            if failInfo { return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: boom".utf8)) }
            return ProcessResult(exitCode: 0, stdout: info, stderr: Data())
        }
        return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data())
    }
}

/// A streaming runner whose behaviour per command is a closure.
struct FakeStreamRunner: StreamingCommandRunning {
    let log: CallLog
    var behaviour: @Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32

    func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        log.add(arguments)
        return try await behaviour(arguments, output)
    }
}

/// A one-shot latch tests can wait on or open.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        let w: [CheckedContinuation<Void, Never>] = lock.withLock {
            open = true
            defer { waiters = [] }
            return waiters
        }
        w.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if open { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }
}

let intelInstall = BrewInstallation(brewPath: "/usr/local/bin/brew", prefix: "/usr/local", repository: "/usr/local/Homebrew")
let intelPlatform = BottlePlatform(arch: .x86_64, macOSVersion: "14", cellar: "/usr/local/Cellar")

/// The Intel VM fixture with the demo's version tweaks (5 upgrades).
func demoIntelInfo() -> Data {
    Demo.currentInfo(.intelbrew, base: Demo.fixtureInfo(.intelbrew), upgraded: [])
}

func makeClient(_ runner: CommandRunning, intelbrew: Bool = true) -> BrewClient {
    var process = ["HOME": "/Users/test", "USER": "test"]
    if intelbrew { process["HOMEBREW_CORE_GIT_REMOTE"] = Intelbrew.coreRemote }
    return BrewClient(installation: intelInstall, platform: intelPlatform, runner: runner,
                      sources: EnvironmentSources(process: process), fileExists: { _ in false })
}

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Polls `condition` on the main actor until true or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Sleeps until cancelled (throws CancellationError then).
func sleepUntilCancelled() async throws {
    try await Task.sleep(for: .seconds(60))
}
