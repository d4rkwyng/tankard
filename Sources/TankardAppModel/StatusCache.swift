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

    /// nil when missing, unreadable, or from another schema version. Also
    /// nil for a report written before Tankard 0.2 (no dependency lists):
    /// uninstall's dependents check needs them, so that cache is re-read.
    /// 0.8.6: a row brew can't read has no dependency list by nature (and
    /// can't be removed from Tankard), so it doesn't void the cache.
    public func load() -> StatusReport? {
        guard let data = try? Data(contentsOf: url),
              let report = try? StatusReport.jsonDecoder().decode(StatusReport.self, from: data),
              report.schemaVersion == StatusReport.currentSchemaVersion,
              report.packages.allSatisfy({ $0.dependencies != nil || $0.unreadable != nil }) else { return nil }
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
        tildePath(url.path)
    }

    public static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
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
            // 0.8.4: never a URL's user:password (a proxy's, if brew, git or
            // curl ever prints one).
            let text = ProxySettings.maskText(lines.joined(separator: "\n"))
            try? handle?.write(contentsOf: Data((text + "\n").utf8))
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
