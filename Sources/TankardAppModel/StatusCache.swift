import Foundation
import TankardCore

/// The last status report, kept on disk so the window opens with data
/// before brew answers. ~/Library/Caches/net.mindtricks.tankard/status.json.
public struct StatusCache: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        return caches.appendingPathComponent(AppPaths.bundleID, isDirectory: true)
            .appendingPathComponent("status.json")
    }

    /// nil when missing, unreadable, or from another schema version.
    public func load() -> StatusReport? {
        guard let data = try? Data(contentsOf: url),
              let report = try? StatusReport.jsonDecoder().decode(StatusReport.self, from: data),
              report.schemaVersion == StatusReport.currentSchemaVersion else { return nil }
        return report
    }

    public func save(_ report: StatusReport) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StatusReport.jsonEncoder().encode(report).write(to: url, options: .atomic)
    }
}

public enum AppPaths {
    public static let bundleID = "net.mindtricks.tankard"

    /// ~/Library/Logs/Tankard/upgrade.log
    public static var upgradeLog: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Tankard", isDirectory: true)
            .appendingPathComponent("upgrade.log")
    }

    /// "~/Library/Logs/Tankard/upgrade.log" for display.
    public static func tilde(_ url: URL) -> String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// Appends to the upgrade log. Each command gets a header line; output is
/// written as finished lines (progress redraws are collapsed, not repeated).
public final class LogFile: @unchecked Sendable {
    private let url: URL
    private var handle: FileHandle?
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.withLock {
            if handle == nil {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    }

    public func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }

    deinit { try? handle?.close() }
}
