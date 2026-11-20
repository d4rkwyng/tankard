@testable import AskpassSupport
import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.9: the 0.8.8 security review's follow-ups (core parts in
// TankardCoreTests/V089SecurityCoreTests.swift).

/// F2: `brew fetch` and the restore plan's uninstall/link/pin.
@MainActor
struct V089OperandTests {
    func formula(_ qualified: String) -> Package {
        var p = pkg("x")
        p.id = "formula:\(qualified)"
        return p
    }

    @Test func fetchPutsDoubleDashBeforeNamesWhenOneLooksLikeAnOption() {
        #expect(Prefetch.arguments(.formula, [formula("homebrew/core/a"), formula("homebrew/core/b")])
                == ["fetch", "--formula", "homebrew/core/a", "homebrew/core/b"])
        #expect(Prefetch.arguments(.formula, [formula("homebrew/core/a"), formula("--force")])
                == ["fetch", "--formula", "--", "homebrew/core/a", "--force"])
    }

    @Test func restorePlanRollbackStepsUseIt() {
        var now = formula("--evil")
        now.installedVersion = "1.1"
        now.installedVersions = ["1.0", "1.1"]
        var then = now
        then.installedVersion = "1.0"
        let point = RestorePoint.capture([then], at: Date(timeIntervalSince1970: 1_800_000_000), reason: .upgrade)
        let plan = RestorePlan.make(RestoreDiff.between(point, [now]), installed: [now], pinAfter: true)
        #expect(plan.steps.map(\.arguments) == [
            ["uninstall", "--formula", "--", "--evil"],
            ["link", "--formula", "--", "--evil"],
            ["pin", "--formula", "--", "--evil"],
        ])
    }
}

/// F4: brew bundle check runs only the Brewfile the preview showed, and
/// only a regular file is read.
@MainActor
struct V089BrewfileTests {
    final class Text: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String
        init(_ v: String) { _value = v }
        var value: String {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    @Test func changedAfterPreviewIsNotRun() async throws {
        let text = Text("brew \"jq\"\n")
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.readBrewfile = { _ in text.value }
        let store = AppStore(deps: deps)
        await store.start()
        store.previewBrewfile(at: "/Users/you/Desktop/Brewfile")
        guard case .preview(let p) = store.brewfile.page else { Issue.record("no preview"); return }
        #expect(p.digest == BrewfileStaticReader.digest("brew \"jq\"\n"))
        #expect(p.digest.count == 64)
        store.brewfile.requestBrewCheck()
        text.value = "brew \"jq\"\nsystem \"curl x | sh\"\n"
        store.confirmBrewfileCheck()
        await store.brewfile.waitForIdle()
        guard case .failed(let why) = store.brewfile.page else { Issue.record("ran a changed file: \(store.brewfile.page)"); return }
        #expect(why.contains("changed after Tankard showed it"))
    }

    @Test func unchangedFileRuns() async throws {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.readBrewfile = { _ in "tap \"hashicorp/tap\"\n" }
        let store = AppStore(deps: deps)
        await store.start()
        store.previewBrewfile(at: "/Users/you/Desktop/Brewfile")
        store.brewfile.requestBrewCheck()
        store.confirmBrewfileCheck()
        await store.brewfile.waitForIdle()
        guard case .checked = store.brewfile.page else { Issue.record("no check result: \(store.brewfile.page)"); return }
    }

    @Test func fileKinds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-f4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Brewfile")
        try Data("brew \"jq\"\n".utf8).write(to: file)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let fifo = dir.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(BrewfileStaticReader.fileKind(file.path) == .regular)
        #expect(BrewfileStaticReader.fileKind(link.path) == .regular)
        #expect(BrewfileStaticReader.fileKind(fifo.path) == .other)
        #expect(BrewfileStaticReader.fileKind("/dev/null") == .other)
        #expect(BrewfileStaticReader.fileKind(dir.path) == .other)
        #expect(BrewfileStaticReader.fileKind(dir.appendingPathComponent("none").path) == .missing)
    }

    /// The real reader on a FIFO: refused at once, never opened (opening
    /// it would block with no writer).
    @Test func fifoIsNotPreviewed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-f4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("Brewfile")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let brewfile = BrewfileStore()
        brewfile.preview(path: fifo.path)
        guard case .failed = brewfile.page else { Issue.record("expected failed: \(brewfile.page)"); return }
    }

    /// Replaced by a FIFO between the preview and the run: not run.
    @Test func replacedByFifoIsNotRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-f4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Brewfile")
        try Data("brew \"jq\"\n".utf8).write(to: file)
        let brewfile = BrewfileStore()
        brewfile.preview(path: file.path)
        guard case .preview(let p) = brewfile.page else { Issue.record("no preview"); return }
        #expect(brewfile.verifyUnchanged(p))
        try FileManager.default.removeItem(at: file)
        #expect(mkfifo(file.path, 0o600) == 0)
        #expect(!brewfile.verifyUnchanged(p))
        guard case .failed = brewfile.page else { Issue.record("expected failed"); return }
    }
}

/// F5: the helper reads only the ancestors' own ticket files, and stray
/// names in the folder can't crowd the step's ticket out.
struct V089AskpassTicketTests {
    typealias T = AskpassTicket
    static let start = T.ProcessStart(sec: 1_790_000_000, usec: 123_456)

    func tempDir() throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-tk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }

    @Test func pidNamesAreCanonicalDecimalOnly() {
        #expect(T.pid(fromName: "4242") == 4242)
        for bad in ["04242", "+4242", "4242.x", "1", "0", "-5", "abc", "", "99999999999"] {
            #expect(T.pid(fromName: bad) == nil, "\(bad)")
        }
    }

    @Test func helperFindsItsTicketPastManyStrayFiles() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let dir = base + "/askpass-tickets"
        let t = T.Ticket(pid: 90_000, start: Self.start)
        _ = try #require(T.write(t, in: dir, isAlive: { _ in true }))
        // More junk than maxTickets, all sorting before "90000", plus
        // well-named files with low pids whose content isn't a ticket.
        for i in 0..<(T.maxTickets + 8) {
            let junk = dir + "/!junk\(i)"
            FileManager.default.createFile(atPath: junk, contents: Data("x".utf8), attributes: [.posixPermissions: 0o600])
            let low = dir + "/\(i + 2)"
            FileManager.default.createFile(atPath: low, contents: Data("x".utf8), attributes: [.posixPermissions: 0o600])
        }
        // A ticket file whose name and content disagree is not used.
        let lie = dir + "/77777"
        try T.encode(T.Ticket(pid: 4242, start: Self.start)).write(toFile: lie, atomically: false, encoding: .utf8)
        chmod(lie, 0o600)
        #expect(T.read(in: dir, pids: [1234, 90_000]) == [t])
        #expect(T.read(in: dir, pids: [77_777]).isEmpty)
        #expect(T.read(in: dir, pids: [90_000, 90_000]) == [t])
        // The same folder checks as read(in:).
        chmod(dir, 0o755)
        #expect(T.read(in: dir, pids: [90_000]).isEmpty)
    }

    @Test func writerDeletesStrayNamesKeepsMarks() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let dir = base + "/askpass-tickets"
        let old = T.Ticket(pid: 5000, start: Self.start)
        _ = try #require(T.write(old, in: dir, isAlive: { _ in true }))
        #expect(T.markCancelled(old, in: dir))
        let junk = dir + "/!junk"
        FileManager.default.createFile(atPath: junk, contents: Data("x".utf8), attributes: [.posixPermissions: 0o600])
        // read(in:) never deletes anything.
        _ = T.read(in: dir)
        #expect(FileManager.default.fileExists(atPath: junk))
        let t = T.Ticket(pid: 6000, start: Self.start)
        _ = try #require(T.write(t, in: dir, isAlive: { _ in true }))
        #expect(!FileManager.default.fileExists(atPath: junk))
        #expect(T.isCancelled(old, in: dir))
        #expect(Set(T.read(in: dir)) == [old, t])
    }
}
