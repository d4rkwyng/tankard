import Foundation
import os
import TankardCore

// 0.10, demo only: a download to show the sheet's speed and time left
// (screenshots). TANKARD_DEMO_DOWNLOAD=slow|stall, with TANKARD_DEMO=1 and
// TANKARD_DEMO_UPGRADE=1. The first command of the demo upgrade that
// downloads (the prefetch, or the first upgrade) holds while a fake file
// grows in an in-memory downloads folder, against the real clock:
//   slow   about 4.2 MB/s toward 2.3 GB, from 90% (a slow connection)
//   stall  the same, then no new bytes after 3 seconds
// Nothing reads or writes the disk, and nothing goes to the network: the
// folder and the HEAD request's answer are both this object.

extension Demo {
    public enum DownloadScenario: String, Sendable {
        case slow, stall

        public init?(environmentValue v: String?) {
            guard let v, let s = DownloadScenario(rawValue: v.lowercased()) else { return nil }
            self = s
        }
    }

    /// Adds the fake download to the demo's dependencies.
    public static func addDownload(_ scenario: DownloadScenario, to deps: inout AppStore.Dependencies) {
        let fake = FakeDownload(scenario: scenario)
        deps.streamRunner = DownloadHoldRunner(inner: deps.streamRunner, fake: fake)
        let monitor = DownloadMonitor(directory: { FakeDownload.directory }, urls: { _ in [FakeDownload.url] },
                                      batchURLs: { _ in [FakeDownload.url] }, reader: fake, lengths: fake)
        deps.downloadMonitor = { _, _ in monitor }
    }

    /// One file growing in a downloads folder that exists only here.
    final class FakeDownload: DownloadFolderReading, ContentLengthFetching, @unchecked Sendable {
        static let directory = "/demo-only/downloads"
        static let url = "https://example.invalid/demo/tankard-demo-download.tar.gz"
        static let total: Int64 = 2_300_000_000
        static let startBytes: Int64 = 2_080_000_000
        static let bytesPerSecond = 4_200_000.0
        /// stall: seconds of growth before the bytes stop.
        static let stallAfter: TimeInterval = 3
        static let file = BrewDownloadName.urlHash(url) + "--tankard-demo-download.tar.gz.incomplete"

        let scenario: DownloadScenario
        private struct State {
            var claimed = false
            var startedAt: Date?
            var finished = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(scenario: DownloadScenario) { self.scenario = scenario }

        /// The first command that downloads gets the fake download.
        func claim() -> Bool {
            state.withLock { s in
                if s.claimed { return false }
                s.claimed = true
                return true
            }
        }

        func start(_ date: Date) { state.withLock { $0.startedAt = date } }
        func finish() { state.withLock { $0.finished = true } }

        /// Seconds the file has grown for at `date`.
        private func grown(at date: Date) -> TimeInterval? {
            guard let start = state.withLock({ $0.finished ? nil : $0.startedAt }) else { return nil }
            let t = max(0, date.timeIntervalSince(start))
            return scenario == .stall ? min(t, Self.stallAfter) : t
        }

        func size(at date: Date) -> Int64? {
            grown(at: date).map { min(Self.total, Self.startBytes + Int64($0 * Self.bytesPerSecond)) }
        }

        /// Still downloading: the slow one until it is complete.
        func running(at date: Date) -> Bool {
            guard let size = size(at: date) else { return false }
            return size < Self.total
        }

        func files(in directory: String) -> [String] {
            directory == Self.directory && size(at: Date()) != nil ? [Self.file] : []
        }

        /// The one file's file number (any: there is no other file).
        static let fileID: UInt64 = 1

        func stat(_ path: String) -> (size: Int64, modified: Date, fileID: UInt64?)? {
            guard path == Self.directory + "/" + Self.file, let start = state.withLock({ $0.startedAt }),
                  let size = size(at: Date()), let grown = grown(at: Date()) else { return nil }
            return (size, start.addingTimeInterval(grown), Self.fileID)
        }

        func read(_ path: String) -> Data? { nil }

        func contentLength(of url: String) async -> Int64? { url == Self.url ? Self.total : nil }
    }

    /// The demo's fake brew, with its first download held while the fake
    /// file grows (at most `longest` seconds).
    struct DownloadHoldRunner: StreamingCommandRunning {
        var inner: StreamingCommandRunning
        var fake: FakeDownload
        var longest: TimeInterval = 180

        func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                    output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
            let downloads = ["fetch", "upgrade", "install", "reinstall"].contains(arguments.first ?? "")
            guard downloads, fake.claim() else {
                return try await inner.stream(executable, arguments, environment: environment, output: output)
            }
            let fetch = arguments.first == "fetch"
            let names = arguments.dropFirst(2).map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            let kind = arguments.contains("--cask") ? "Cask" : "Bottle"
            if fetch {
                // All but the last are done: "Downloading 3 of 4 · …".
                for n in names.dropLast() { output(Data("✔︎ \(kind) \(n)\n".utf8)) }
            }
            let start = Date()
            fake.start(start)
            defer { fake.finish() }
            while fake.running(at: Date()), Date().timeIntervalSince(start) < longest {
                try await Task.sleep(for: .milliseconds(250))
            }
            fake.finish()
            if fetch {
                if let last = names.last { output(Data("✔︎ \(kind) \(last)\n".utf8)) }
                return 0
            }
            return try await inner.stream(executable, arguments, environment: environment, output: output)
        }
    }
}
