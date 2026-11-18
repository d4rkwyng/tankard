import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5 (bug hunt M2): one History entry Tankard can't read no longer
// empties History and lets the next command overwrite the file. Entries are
// read one by one; an outcome this build doesn't know shows as "result
// unknown"; a file that can't be read at all is moved aside before anything
// new is written.
@MainActor
struct V085SafeLoadTests {
    func entryJSON(_ i: Int, outcome: String = "succeeded", extra: String = "") -> String {
        """
        {"id":"\(UUID().uuidString)","startedAt":"2027-01-15T08:00:\(String(format: "%02d", i % 60))Z","duration":1,\
        "command":"brew pin p\(i)","arguments":["pin","p\(i)"],"outcome":"\(outcome)","origin":"user","outputTail":[]\(extra)}
        """
    }

    func asides(_ dir: URL, _ name: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(name + ".unreadable-") }
    }

    @Test func unknownOutcomeStillShows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        let json = "[" + [entryJSON(1), entryJSON(2, outcome: "skipped"), entryJSON(3, extra: ",\"origin2\":1"),
                          entryJSON(4, extra: ",\"quietReason\":\"marsQuake\"")].joined(separator: ",") + "]"
        try Data(json.utf8).write(to: url)
        let log = HistoryLog(url: url)
        #expect(log.entries.count == 4)
        let odd = try #require(log.entries.first { $0.command == "brew pin p2" })
        #expect(odd.outcome == .unknown)
        #expect(odd.resultText == "result unknown")
        #expect(!odd.isFailure)
        #expect(!odd.canRetry)
        // A quiet reason this build doesn't know: an ordinary line.
        #expect(log.entries.first { $0.command == "brew pin p4" }?.quietReason == nil)
        // Nothing was lost, so nothing was set aside.
        #expect(try asides(dir, "history.json").isEmpty)
    }

    @Test func corruptEntryIsSkippedAndTheFileKept() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        // 5 good entries, one with no date, one that isn't an object.
        let json = "[" + (0..<5).map { entryJSON($0) }.joined(separator: ",")
            + ",{\"id\":\"\(UUID().uuidString)\",\"command\":\"broken\"},42]"
        try Data(json.utf8).write(to: url)
        let log = HistoryLog(url: url)
        #expect(log.entries.count == 5)
        // The original, with the two it couldn't read, is kept beside it.
        let kept = try asides(dir, "history.json")
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: kept[0]) == Data(json.utf8))
        // The next command keeps the readable ones.
        log.record(HistoryEntry(startedAt: Date(timeIntervalSince1970: 1_900_000_000), duration: 1, command: "brew update",
                                arguments: ["update"], outcome: .succeeded))
        #expect(HistoryLog(url: url).entries.count == 6)
    }

    @Test func unreadableFileIsMovedAsideNotOverwritten() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        let junk = Data("{\"not\": \"a list\"".utf8)
        try junk.write(to: url)
        let log = HistoryLog(url: url)
        #expect(log.entries.isEmpty)
        let kept = try asides(dir, "history.json")
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: kept[0]) == junk)
        log.record(HistoryEntry(startedAt: Date(), duration: 1, command: "brew update", arguments: ["update"], outcome: .succeeded))
        #expect(HistoryLog(url: url).entries.count == 1)
        #expect(try Data(contentsOf: kept[0]) == junk)
    }

    @Test func autoUpdateLogReadsRunByRun() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("auto-update-log.json")
        let good = """
        {"id":"\(UUID().uuidString)","startedAt":"2027-01-15T03:00:00Z","upgraded":[{"name":"xz","isCask":false,"detail":"1 → 2"}],\
        "skipped":[],"failed":[],"dryRun":false}
        """
        let bad = "{\"id\":\"\(UUID().uuidString)\",\"startedAt\":\"yesterday\"}"
        try Data("[\(good),\(bad)]".utf8).write(to: url)
        let log = AutoUpdateLog(url: url)
        #expect(log.runs.count == 1)
        #expect(log.runs.first?.upgraded.first?.name == "xz")
        #expect(try asides(dir, "auto-update-log.json").count == 1)

        let url2 = dir.appendingPathComponent("other.json")
        try Data("not json".utf8).write(to: url2)
        #expect(AutoUpdateLog(url: url2).runs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url2.path))
        #expect(try asides(dir, "other.json").count == 1)
    }

    @Test func missingFileIsJustEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(HistoryLog(url: dir.appendingPathComponent("history.json")).entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
