import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.8: the scripted real-run harness's parser and runner. The runner is
// exercised against the demo's fake brew (Scripts/e2e.sh runs it for real).

@MainActor
struct ScriptParserTests {
    @Test func parsesStepsCommentsQuotesAndAlways() throws {
        let steps = try ScriptParser.parse("""
            # a comment

            refresh manual
              expect no-process " vulns --json"
            always uninstall formula hello
            """)
        #expect(steps.count == 3)
        #expect(steps[0] == ScriptStep(line: 3, verb: "refresh", args: ["manual"], text: "refresh manual"))
        #expect(steps[1].args == ["no-process", " vulns --json"])
        #expect(steps[1].line == 4)
        #expect(steps[2].always)
        #expect(steps[2].verb == "uninstall")
        #expect(steps[2].args == ["formula", "hello"])
    }

    @Test func rejectsUnknownVerbsAndOpenQuotesBeforeRunning() {
        #expect(throws: ScriptParseError.unknownVerb(line: 2, verb: "explode")) {
            try ScriptParser.parse("refresh\nexplode now")
        }
        #expect(throws: ScriptParseError.unterminatedQuote(line: 1)) {
            try ScriptParser.parse("expect no-process \"brew")
        }
    }

    @Test func everyVerbHasUsage() {
        for (verb, def) in ScriptRunner.steps {
            #expect(def.usage.hasPrefix(verb), "\(verb)")
        }
        #expect(ScriptRunner.help.contains("tap-add"))
    }
}

@MainActor
struct ScriptRunnerTests {
    func run(_ text: String) async throws -> (ScriptSummary, [[String: Any]], URL, AppStore) {
        let dir = try tempDir()
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        var shots: [String] = []
        let runner = ScriptRunner(store: store, steps: try ScriptParser.parse(text), outputDirectory: dir) { path in
            shots.append(path)
            return FileManager.default.createFile(atPath: path, contents: Data("png".utf8))
        }
        let summary = await runner.run()
        let lines = try String(contentsOf: dir.appendingPathComponent("results.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        #expect(!shots.isEmpty)
        return (summary, lines, dir, store)
    }

    @Test func pinsThroughTheQueueAndRecordsStateAndSnapshots() async throws {
        let (summary, lines, dir, store) = try await run("""
            pin xz
            expect pinned xz
            unpin xz
            expect not-pinned xz
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(summary.passed == 4 && summary.failed == 0)
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0["ok"] as? Bool == true })
        let state = lines[0]["state"] as? [String: Any]
        let watched = (state?["watched"] as? [String: Any])?["xz"] as? [String: Any]
        #expect(watched?["pinned"] as? Bool == true)
        #expect(lines[0]["snapshot"] as? String == "01-pin.png")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.json").path))
        // Through History: the same queue the buttons use.
        #expect(store.history.entries.contains { $0.command.contains("pin") })
    }

    @Test func aFailureSkipsTheRestButAlwaysStepsStillRun() async throws {
        let (summary, lines, dir, _) = try await run("""
            expect installed no-such-package
            pin xz
            always unpin xz
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(summary.failed == 1)
        #expect(summary.skipped == 1)
        #expect(summary.passed == 1)
        #expect(lines[1]["skipped"] as? Bool == true)
        #expect(lines[2]["ok"] as? Bool == true)
        #expect(!summary.ok)
    }

    @Test func settingsAreWrittenAndReadBack() async throws {
        let (summary, _, dir, store) = try await run("""
            set keepPreviousVersion on
            expect setting keepPreviousVersion on
            set scanVulnerabilitiesOnRefresh off
            expect setting scanVulnerabilitiesOnRefresh off
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(summary.ok)
        #expect(store.restorePoints.settings.keepPreviousVersion)
    }

    @Test func savesARestorePoint() async throws {
        let (summary, _, dir, store) = try await run("save-restore-point")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(summary.ok)
        #expect(store.restorePoints.points.count == 1)
        #expect(!store.restorePoints.isShowing)
    }

    @Test func blockedUninstallFailsWithoutRunning() async throws {
        let (summary, _, dir, store) = try await run("uninstall formula xz")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(summary.failures.first?.contains("blocked") == true)
        #expect(store.upgrade == nil)
    }
}
