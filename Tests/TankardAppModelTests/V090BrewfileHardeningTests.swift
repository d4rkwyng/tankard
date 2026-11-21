import Darwin
import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.9.0 (F4 hardening): a Brewfile is opened once (O_NOFOLLOW, O_NONBLOCK),
// must be a regular file of at most 1 MB, and brew bundle runs a private
// 0600 copy of the bytes read, deleted afterwards (BrewfileSnapshot.swift).

@MainActor
struct V090BrewfileHardeningTests {
    final class Paths: @unchecked Sendable {
        private let lock = NSLock()
        private var _files: [String] = []
        private var _seen: [String: (mode: mode_t, dirMode: mode_t, text: String?)] = [:]
        var files: [String] { lock.withLock { _files } }
        func seen(_ p: String) -> (mode: mode_t, dirMode: mode_t, text: String?)? { lock.withLock { _seen[p] } }
        /// Records the `--file=` path brew got, and what was there while brew ran.
        func record(_ args: [String]) {
            guard let arg = args.first(where: { $0.hasPrefix("--file=") }) else { return }
            let p = String(arg.dropFirst("--file=".count))
            var st = stat(), dst = stat()
            let isReg = lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
            _ = lstat((p as NSString).deletingLastPathComponent, &dst)
            let text = isReg ? try? String(contentsOfFile: p, encoding: .utf8) : nil
            lock.withLock {
                _files.append(p)
                _seen[p] = (isReg ? st.st_mode & 0o7777 : 0, dst.st_mode & 0o7777, text)
            }
        }
    }

    nonisolated static let ok = ProcessResult(exitCode: 0, stdout: Data("The Brewfile's dependencies are satisfied.\n".utf8), stderr: Data())

    func store(_ paths: Paths) -> BrewfileStore {
        let s = BrewfileStore()
        s.run = { args in paths.record(args); return Self.ok }
        return s
    }

    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-f4h-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func fifoIsRejectedWithoutBlocking() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("Brewfile")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        // No writer: a blocking open would hang here.
        #expect(throws: BrewfileReadError.fifo) { try BrewfileSnapshot.read(fifo.path) }
        let paths = Paths()
        let s = store(paths)
        s.check(path: fifo.path)
        guard case .failed(let why) = s.page else { Issue.record("not refused: \(s.page)"); return }
        #expect(why.contains("named pipe"))
        #expect(paths.files.isEmpty)
    }

    @Test func symlinkIsRejected() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("real")
        try Data("brew \"jq\"\n".utf8).write(to: file)
        let link = dir.appendingPathComponent("Brewfile")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: BrewfileReadError.symlink) { try BrewfileSnapshot.read(link.path) }
        let paths = Paths()
        let s = store(paths)
        s.preview(path: link.path)
        guard case .failed(let why) = s.page else { Issue.record("previewed a symlink: \(s.page)"); return }
        #expect(why.contains("symbolic link"))
        s.check(path: link.path)
        guard case .failed = s.page else { Issue.record("ran a symlink: \(s.page)"); return }
        #expect(paths.files.isEmpty)
    }

    @Test func directoryAndDeviceAreRejected() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: BrewfileReadError.directory) { try BrewfileSnapshot.read(dir.path) }
        #expect(throws: BrewfileReadError.device) { try BrewfileSnapshot.read("/dev/null") }
        #expect(throws: BrewfileReadError.missing) { try BrewfileSnapshot.read(dir.appendingPathComponent("none").path) }
    }

    @Test func oversizeIsRejected() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("Brewfile")
        try Data(repeating: UInt8(ascii: "#"), count: BrewfileSnapshot.maxBytes + 1).write(to: big)
        #expect(throws: BrewfileReadError.tooLarge(limit: BrewfileSnapshot.maxBytes)) { try BrewfileSnapshot.read(big.path) }
        let paths = Paths()
        let s = store(paths)
        s.check(path: big.path)
        guard case .failed(let why) = s.page else { Issue.record("ran an oversize file: \(s.page)"); return }
        #expect(why.contains("larger than 1 MB"))
        #expect(paths.files.isEmpty)
        // At the limit it is read.
        let edge = dir.appendingPathComponent("edge")
        try Data(repeating: UInt8(ascii: "#"), count: BrewfileSnapshot.maxBytes).write(to: edge)
        #expect(try BrewfileSnapshot.read(edge.path).count == BrewfileSnapshot.maxBytes)
    }

    /// brew gets a private 0600 copy (in a 0700 folder) holding the bytes
    /// read, not the user's path.
    @Test func regularFileIsCopiedPrivately() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Brewfile")
        let text = "tap \"hashicorp/tap\"\nbrew \"jq\"\n"
        try Data(text.utf8).write(to: file)
        #expect(chmod(file.path, 0o644) == 0)
        let paths = Paths()
        let s = store(paths)
        s.preview(path: file.path)
        guard case .preview(let p) = s.page else { Issue.record("no preview: \(s.page)"); return }
        s.check(path: file.path, expectedDigest: p.digest)
        await s.waitForIdle()
        #expect(s.page == .checked(BrewfileCheckResult(path: file.path, missing: [])))
        let used = try #require(paths.files.first)
        #expect(paths.files.count == 1)
        #expect(used != file.path)
        #expect(used.hasSuffix("/Brewfile"))
        #expect(used.contains("/tankard-brewfile."))
        let seen = try #require(paths.seen(used))
        #expect(seen.mode == 0o600)
        #expect(seen.dirMode == 0o700)
        #expect(seen.text == text)
    }

    /// The copy and its folder are gone once brew is done: after a check,
    /// after a failed one, and after an export's counts.
    @Test func copyIsDeletedAfterTheRun() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Brewfile")
        try Data("brew \"jq\"\n".utf8).write(to: file)
        let paths = Paths()
        let s = store(paths)
        s.check(path: file.path)
        await s.waitForIdle()
        s.run = { args in paths.record(args); return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: boom\n".utf8)) }
        s.check(path: file.path)
        await s.waitForIdle()
        guard case .failed = s.page else { Issue.record("not failed: \(s.page)"); return }
        s.run = { args in paths.record(args); return Self.ok }
        s.export(to: file.path, force: true)
        await s.waitForIdle()
        guard case .exported = s.page else { Issue.record("not exported: \(s.page)"); return }
        let used = paths.files
        #expect(used.count == 6) // check, check, dump (the user's path), 3 lists
        #expect(used[2] == file.path)
        for p in used where p != file.path {
            #expect(!FileManager.default.fileExists(atPath: p))
            #expect(!FileManager.default.fileExists(atPath: (p as NSString).deletingLastPathComponent))
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// The preview's digest is checked against the one read brew's copy is
    /// made from: a file changed in between never reaches brew.
    @Test func changedBytesNeverReachBrew() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Brewfile")
        try Data("brew \"jq\"\n".utf8).write(to: file)
        let paths = Paths()
        let s = store(paths)
        s.preview(path: file.path)
        guard case .preview(let p) = s.page else { Issue.record("no preview"); return }
        try Data("brew \"jq\"\nsystem \"curl x | sh\"\n".utf8).write(to: file)
        s.check(path: file.path, expectedDigest: p.digest)
        await s.waitForIdle()
        #expect(s.page == .failed(BrewfileStore.changedMessage))
        #expect(paths.files.isEmpty)
    }

    /// A relative require won't resolve from the private copy. Warn, and still check.
    @Test func loadTokensAreWarnedAndTheCheckStillRuns() async throws {
        let tokens = ["require \"helper\"", "require_relative \"helper\"", "load \"helper\"",
                      "puts __dir__", "puts __FILE__", "Kernel.require \"helper\"",
                      "brew \"jq#" + "{require 'x'}\""]
        for text in tokens {
            #expect(BrewfileStaticReader.loadsOtherFiles(text), "\(text)")
        }
        let text = "require \"helper\"\nbrew \"jq\"\n"
        let preview = BrewfileStaticReader.preview(path: "/b", text: text, quarantined: false)
        #expect(preview.loadsOtherFiles)
        #expect(preview.names(.formula) == ["jq"])
        #expect(BrewfileStore.loadsOtherFilesWarning == "This Brewfile loads other files. Tankard runs a private copy, so files it loads by a path relative to the Brewfile won't be found.")
        let store = BrewfileStore()
        store.readBytes = { _ in Data(text.utf8) }
        store.run = { _ in Self.ok }
        store.preview(path: "/b")
        guard case .preview(let shown) = store.page else { Issue.record("no preview"); return }
        #expect(shown.loadsOtherFiles)
        store.requestBrewCheck()
        guard case .confirmRun(let asked) = store.page else { Issue.record("no confirm"); return }
        #expect(asked.loadsOtherFiles)
        store.check(path: "/b", expectedDigest: shown.digest)
        await store.waitForIdle()
        #expect(store.page == .checked(BrewfileCheckResult(path: "/b", missing: [])))
    }

    /// Ordinary lines, a longer identifier, a string and a symbol are not that token.
    @Test func ordinaryBrewfileIsNotWarned() {
        let text = """
        tap "user/repo"
        brew "jq"
        cask "firefox"
        mas "Xcode", id: 497799835
        required = 1
        download "x"
        preload "x"
        puts __file__
        puts __dirname
        brew "require"
        brew 'load'
        :require
        @require
        $load
        %q{require "x"}
        <<EOF
        require "inside a heredoc"
        EOF
        """
        #expect(!BrewfileStaticReader.loadsOtherFiles(text))
        #expect(!BrewfileStaticReader.preview(path: "/b", text: text, quarantined: false).loadsOtherFiles)
    }

    /// `::require` and `Foo::require` are calls, not symbols. A leading `::`
    /// and a constant's scope both load another file.
    @Test func scopeResolutionRequireIsWarned() {
        let texts = ["::require \"x\"", "Foo::require \"x\"", "::load \"x\"",
                     "Foo::require_relative \"x\"", "Kernel::load \"x\""]
        for text in texts {
            #expect(BrewfileStaticReader.loadsOtherFiles(text), "\(text)")
        }
    }

    /// A method call on a receiver is not a load of another file.
    /// `Kernel.load` and a call with no receiver still are.
    @Test func aMethodCallOnAReceiverIsNotALoad() {
        let calls = ["obj.load(\"helper\")", "obj.require \"x\"", "foo.bar.load",
                     "obj.require_relative \"x\"", "helper.__dir__"]
        for text in calls {
            #expect(!BrewfileStaticReader.loadsOtherFiles(text), "\(text)")
        }
        let loads = ["Kernel.load \"x\"", "Kernel.require \"x\"", "Kernel.require_relative \"x\"",
                     "load(\"helper\")", "::require \"x\""]
        for text in loads {
            #expect(BrewfileStaticReader.loadsOtherFiles(text), "\(text)")
        }
    }

    /// The same words in a comment, including a trailing one and a block comment, don't count.
    @Test func aTokenInACommentIsNotWarned() {
        #expect(!BrewfileStaticReader.loadsOtherFiles("# require \"helper\"\n"))
        #expect(!BrewfileStaticReader.loadsOtherFiles("brew \"jq\" # require_relative \"helper\"\n"))
        #expect(!BrewfileStaticReader.loadsOtherFiles("brew \"jq\" # __FILE__\n"))
        let block = """
        =begin
        require "helper"
        load __dir__
        __FILE__
        =end
        brew "jq"
        """
        #expect(!BrewfileStaticReader.loadsOtherFiles(block))
        // Indented, so it is not a block comment: the require below is code.
        #expect(BrewfileStaticReader.loadsOtherFiles("  =begin\nrequire \"helper\"\n"))
    }

    /// A pause cancellation does not cut short: the runner's stand-in for
    /// waitpid during the kill grace.
    private nonisolated static func uncancelledPause(_ milliseconds: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { c.resume() }
        }
    }

    /// On a timeout brew is still shutting down. The private copy stays
    /// until the runner returns, and the defer deletes it after that.
    @Test func timeoutKeepsTheCopyUntilTheRunnerHasExited() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Brewfile")
        try Data("brew \"jq\"\n".utf8).write(to: file)
        let paths = Paths()
        let presentDuringShutdown = LockBox(false)
        let s = BrewfileStore()
        s.timeout = .milliseconds(150)
        s.run = { args in
            paths.record(args)
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await Self.uncancelledPause(200)
                if let p = paths.files.first {
                    presentDuringShutdown.set(FileManager.default.fileExists(atPath: p))
                }
                throw error
            }
            return Self.ok
        }
        s.check(path: file.path)
        await s.waitForIdle()
        guard case .failed(let why) = s.page else { Issue.record("not timed out: \(s.page)"); return }
        #expect(why.contains("didn't finish"))
        #expect(presentDuringShutdown.get)
        let used = try #require(paths.files.first)
        #expect(used != file.path)
        #expect(!FileManager.default.fileExists(atPath: used))
        #expect(!FileManager.default.fileExists(atPath: (used as NSString).deletingLastPathComponent))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

/// A Bool the runner closure can set from off the main actor.
private final class LockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
    var get: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
