import Foundation
import os
import TankardCore

// 0.8.3: a step that fails because another brew holds brew's lock waits for
// that brew to finish and runs again, instead of failing (and the rest of
// the run with it).
//
// brew 7.0.14's lock messages (the only ones this reacts to, through
// BrewFailure.classify == .locked):
// - lock_file.rb / exceptions.rb OperationInProgressError: "A `brew install
//   ffmpeg` process has already locked /opt/homebrew/Cellar/ffmpeg." The
//   lock file is HOMEBREW_LOCKS/"<basename>.<type>.lock" (FormulaLock for a
//   Cellar rack, CaskLock for a Caskroom token, DownloadLock otherwise).
// - utils/lock.sh (brew update): "Another `brew update` process is already
//   running." The lock file is HOMEBREW_LOCKS/"update" (spaces to dashes).
// HOMEBREW_LOCKS is HOMEBREW_PREFIX/var/homebrew/locks (startup/config.rb).
public enum BrewLock {
    /// The prefix of the brew at `brewPath` (`/opt/homebrew/bin/brew` → `/opt/homebrew`).
    public static func prefix(ofBrew brewPath: String) -> String {
        URL(fileURLWithPath: brewPath).deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// The lock file brew's lock failure names, or nil if the lines don't say.
    public static func lockFile<S: Sequence>(_ lines: S, prefix: String) -> String? where S.Element == String {
        let locks = prefix + "/var/homebrew/locks/"
        for line in lines {
            if let r = line.range(of: " process has already locked ") {
                var path = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if path.hasSuffix(".") { path.removeLast() }
                guard path.hasPrefix("/") else { continue }
                let url = URL(fileURLWithPath: path)
                let type: String
                switch url.deletingLastPathComponent().lastPathComponent {
                case "Cellar": type = "formula"
                case "Caskroom": type = "cask"
                default: type = "download"
                }
                return locks + "\(url.lastPathComponent).\(type).lock"
            }
            if let a = line.range(of: "Another `brew "), let b = line.range(of: "` process is already running", range: a.upperBound..<line.endIndex) {
                let command = line[a.upperBound..<b.lowerBound]
                guard !command.isEmpty, !command.contains("/") else { continue }
                return locks + command.replacingOccurrences(of: " ", with: "-")
            }
        }
        return nil
    }
}

/// How a queued command waits for brew's lock. Nil on a command: it fails
/// as before (tests, demo, everything outside the sheet).
public struct BrewLockWait: Sendable {
    /// How often the lock is looked at.
    public var interval: Duration
    /// The longest a step waits in all, then it fails as locked.
    public var limit: Duration
    /// Lock failures one step may wait out (a holder that keeps coming back).
    public var maxAttempts: Int
    /// The processes that have `lockFile` open ("pid command"); [] none
    /// (free); nil when that can't be told (then the step runs again after
    /// a few intervals and brew itself says).
    public var holders: @Sendable (_ lockFile: String) -> [String]?

    public init(interval: Duration = .seconds(2), limit: Duration = .seconds(15 * 60), maxAttempts: Int = 30,
                holders: @escaping @Sendable (String) -> [String]?) {
        self.interval = interval
        self.limit = limit
        self.maxAttempts = maxAttempts
        self.holders = holders
    }

    /// The real one: `lsof` on the lock file (brew keeps it open while it
    /// holds the lock; a failed lock attempt closes it at once), so
    /// Tankard never takes brew's lock itself, even for a moment.
    public static let live = BrewLockWait(holders: { LockHolders.lsof($0) })

    /// Waits until the lock in `lockFile` is free. True: run the step again.
    /// False: `limit` passed (fail as locked). Throws when cancelled.
    func waitUntilFree(_ lockFile: String?, since start: ContinuousClock.Instant,
                       report: (String) -> Void) async throws -> Bool {
        let first = lockFile.flatMap(holders) ?? []
        report(first.first ?? "")
        var unknown = 0
        while true {
            try await Task.sleep(for: interval)
            if ContinuousClock.now - start > limit { return false }
            guard let lockFile, let h = holders(lockFile) else {
                unknown += 1
                if unknown >= 3 { return true }
                continue
            }
            if h.isEmpty { return true }
        }
    }
}

enum LockHolders {
    /// "pid command" for each process with `file` open; nil if lsof can't run.
    static func lsof(_ file: String) -> [String]? {
        guard FileManager.default.fileExists(atPath: file) else { return [] }
        guard let out = run("/usr/sbin/lsof", ["-t", "--", file]) else { return nil }
        let pids = out.split(whereSeparator: \.isNewline).map(String.init).filter { Int32($0) != nil }
        guard !pids.isEmpty else { return [] }
        let commands = run("/bin/ps", ["-o", "pid=,command=", "-p", pids.joined(separator: ",")]) ?? ""
        let rows = commands.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return rows.isEmpty ? pids : rows
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The end of a command's output, for classifying its failure.
final class OutputTail: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Data())
    func add(_ d: Data) {
        lock.withLock { buf in
            buf.append(d)
            if buf.count > 16_384 { buf = Data(buf.suffix(16_384)) }
        }
    }
    var lines: [String] {
        var a = LineAssembler()
        a.feed(lock.withLock { $0 })
        a.finish()
        return a.lines
    }
}
