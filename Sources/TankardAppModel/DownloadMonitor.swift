import Foundation
import os
import TankardCore

/// 0.8: how a sheet session finds out what brew is downloading (see
/// TankardCore/DownloadProgress.swift for why it watches brew's downloads
/// folder rather than brew's output).
public struct DownloadMonitor: Sendable {
    /// brew's downloads folder (`$(brew --cache)/downloads`); nil: don't watch.
    public var directory: @Sendable () async -> String?
    /// URLs a package's command may download (a cask's `url`), for the HEAD
    /// request that gives the total. Asked once per command, after it starts.
    public var urls: @Sendable (Package) async -> [String]
    public var reader: DownloadFolderReading
    public var lengths: ContentLengthFetching?
    public var interval: Duration
    public var now: @Sendable () -> Date

    public init(directory: @escaping @Sendable () async -> String?,
                urls: @escaping @Sendable (Package) async -> [String] = { _ in [] },
                reader: DownloadFolderReading = LiveDownloadFolder(),
                lengths: ContentLengthFetching? = nil,
                interval: Duration = .milliseconds(250),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.urls = urls
        self.reader = reader
        self.lengths = lengths
        self.interval = interval
        self.now = now
    }

    /// The sheet runs that download something.
    public static func watches(_ action: SessionAction) -> Bool {
        switch action {
        case .upgrade, .install, .replaceBottle, .restore, .adopt: return true
        case .uninstall, .cleanup, .autoremove, .tap, .untap: return false
        }
    }

    /// The real one for `client`: the folder from `brew --cache` (asked once,
    /// on the first command that runs), a cask's URL from `brew info`, and a
    /// HEAD request for the size when the download isn't a bottle.
    public static func live(client: BrewClient, env: [String: String]) -> DownloadMonitor {
        let memo = OSAllocatedUnfairLock<String??>(initialState: nil)
        return DownloadMonitor(
            directory: {
                if let known = memo.withLock({ $0 }) { return known }
                var dir: String?
                if let r = try? await client.runner.run(client.installation.brewPath, ["--cache"], environment: env),
                   r.exitCode == 0 {
                    let path = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if path.hasPrefix("/") { dir = path + "/downloads" }
                }
                let found = dir
                memo.withLock { $0 = .some(found) }
                return found
            },
            urls: { p in
                switch p.kind {
                case .cask:
                    let info = try? await client.info([p.fullName], kind: .cask, env: env)
                    return info?.casks.compactMap(\.url) ?? []
                case .formula:
                    return p.bottleURL.map { [$0] } ?? []
                }
            },
            lengths: HTTPContentLength())
    }
}

extension DownloadProgress {
    /// "12.3 of 45.6 MB (27%)", or "12.3 MB so far" when the total is unknown.
    public var detail: String {
        if let total, let pct = percent {
            let done = DownloadSizeFormat.pieces(bytes, scale: total)
            let all = DownloadSizeFormat.pieces(total, scale: total)
            let unit = Self.unit(all.unit)
            return String(localized: "\(done.number) of \(all.number) \(unit) (\(pct)%)")
        }
        let p = DownloadSizeFormat.pieces(bytes, scale: bytes)
        return String(localized: "\(p.number) \(Self.unit(p.unit)) so far")
    }

    static func unit(_ u: String) -> String {
        switch u {
        case "GB": return String(localized: "GB")
        case "MB": return String(localized: "MB")
        default: return String(localized: "KB")
        }
    }
}
