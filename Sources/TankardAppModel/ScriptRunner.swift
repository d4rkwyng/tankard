import Foundation
import TankardCore

// v0.8: the scripted real-run harness (Scripts/e2e.sh).
//
// Nobody can click the UI on the build Mac, so a test needs another way to
// drive the real app through a user's flows against the real brew. A
// script is a plain-text file of steps, one per line. Each step calls the
// SAME store methods the buttons call (startInstall, startUninstall,
// setPinned, scanVulnerabilitiesNow, saveRestorePoint, requestRestore +
// confirmRestore, confirmAddTap, ...), so it goes through the same command
// queue, environment, sheets and reconciling refresh. Nothing here builds
// brew commands of its own.
//
// After each step the runner waits for it to finish, then writes
//   <out>/NN-<verb>.png   the window (and a sheet, if one is up)
//   <out>/results.jsonl   one JSON line per step: ok, error, assertions, model state
// and at the end <out>/summary.json. The app quits when the script ends.
//
// The app runs a script only with BOTH TANKARD_E2E=1 and
// TANKARD_SCRIPT=<file> (see TankardApp's LaunchOptions), so a stray
// variable can't install or remove anything.
//
// Script syntax:
//   # comment
//   refresh manual
//   install formula hello
//   always uninstall formula hello     <- "always": runs even after a failure
//   "quoted args" are one argument
// The first failing step stops the script; later `always` steps still run
// (cleanup). `ScriptRunner.help` lists the verbs.
//
// Adding steps (ScriptSteps+Adopt.swift is an example: adopt-scan, adopt,
// self-update, expect-app): write `extension ScriptRunner { static var adoptSteps: [String: ScriptStepDef] { [...] } }`
// in its own file, using the ScriptContext helpers (waitUntil, runSession,
// package(_:kind:), check, snapshot), and add `adoptSteps` to `stepTables`
// below (a computed var: a stored `static let` of these closures trips Swift 6.2's
// isolation checker). Each handler must drive the store the way the UI does.

/// One line of a script.
public struct ScriptStep: Equatable, Sendable {
    public var line: Int
    public var verb: String
    public var args: [String]
    /// Runs even after an earlier step failed (cleanup).
    public var always: Bool
    public var text: String

    public init(line: Int, verb: String, args: [String], always: Bool = false, text: String) {
        self.line = line
        self.verb = verb
        self.args = args
        self.always = always
        self.text = text
    }
}

public enum ScriptParseError: Error, Equatable, CustomStringConvertible {
    case unknownVerb(line: Int, verb: String)
    case unterminatedQuote(line: Int)

    public var description: String {
        switch self {
        case .unknownVerb(let l, let v): return "line \(l): unknown step '\(v)'"
        case .unterminatedQuote(let l): return "line \(l): unterminated quote"
        }
    }
}

public enum ScriptParser {
    /// Splits on whitespace; "double quotes" group words.
    static func tokens(_ line: String, number: Int) throws -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var has = false
        for ch in line {
            if ch == "\"" {
                inQuote.toggle()
                has = true
            } else if ch.isWhitespace && !inQuote {
                if has { out.append(cur) }
                cur = ""
                has = false
            } else {
                cur.append(ch)
                has = true
            }
        }
        if inQuote { throw ScriptParseError.unterminatedQuote(line: number) }
        if has { out.append(cur) }
        return out
    }

    /// The steps of `text`. Unknown verbs are an error before anything runs.
    @MainActor
    public static func parse(_ text: String, verbs: Set<String>? = nil) throws -> [ScriptStep] {
        let known = verbs ?? Set(ScriptRunner.steps.keys)
        var steps: [ScriptStep] = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var t = try tokens(line, number: i + 1)
            var always = false
            if t.first == "always" {
                always = true
                t.removeFirst()
            }
            guard let verb = t.first?.lowercased() else { continue }
            guard known.contains(verb) else { throw ScriptParseError.unknownVerb(line: i + 1, verb: verb) }
            steps.append(ScriptStep(line: i + 1, verb: verb, args: Array(t.dropFirst()), always: always, text: line))
        }
        return steps
    }
}

/// A failed check or step.
public struct ScriptFailure: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

/// One check a step made.
public struct ScriptAssertion: Codable, Equatable, Sendable {
    public var name: String
    public var ok: Bool
    public var detail: String?
}

/// The model state written after each step.
public struct ScriptState: Codable, Sendable {
    public struct Session: Codable, Sendable {
        public var action: String
        public var finished: Bool
        public var items: [String: String]
    }
    public struct Pkg: Codable, Sendable {
        public var id: String
        public var version: String
        public var versions: [String]
        public var pinned: Bool
    }

    public var homebrewState: String
    public var reportFromCache: Bool
    public var formulae: Int
    public var casks: Int
    public var isRefreshing: Bool
    public var isBusy: Bool
    public var error: String?
    public var busyNotice: String?
    public var tab: String
    public var selection: String?
    public var showUpgradeSheet: Bool
    public var session: Session?
    public var appManagementPrompt: String?
    public var scanState: String
    public var scanOutcome: String?
    public var vulnerableFormulae: Int?
    public var restorePoints: Int
    public var postInstallNotes: [String]?
    /// The packages the script named so far, as brew reports them now.
    public var watched: [String: Pkg?]
}

public struct ScriptStepResult: Codable, Sendable {
    public var index: Int
    public var line: Int
    public var step: String
    public var ok: Bool
    public var skipped: Bool
    public var error: String?
    public var assertions: [ScriptAssertion]
    public var seconds: Double
    public var snapshot: String?
    public var state: ScriptState
}

public struct ScriptSummary: Codable, Sendable {
    public var script: String
    public var passed: Int
    public var failed: Int
    public var skipped: Int
    public var failures: [String]
    public var ok: Bool { failed == 0 }
}

/// A step: its help line and what it does.
public struct ScriptStepDef {
    public var usage: String
    public var run: @Sendable @MainActor (ScriptContext) async throws -> Void
    public init(_ usage: String, _ run: @escaping @Sendable @MainActor (ScriptContext) async throws -> Void) {
        self.usage = usage
        self.run = run
    }
}

/// What a step handler works with.
@MainActor
public final class ScriptContext {
    public let store: AppStore
    public internal(set) var args: [String] = []
    public internal(set) var assertions: [ScriptAssertion] = []
    let runner: ScriptRunner

    init(store: AppStore, runner: ScriptRunner) {
        self.store = store
        self.runner = runner
    }

    public func arg(_ i: Int, _ what: String) throws -> String {
        guard i < args.count else { throw ScriptFailure("missing argument: \(what)") }
        return args[i]
    }

    public func arg(_ i: Int) -> String? { i < args.count ? args[i] : nil }

    /// Records a check; a false one fails the step (after the others ran).
    @discardableResult
    public func check(_ name: String, _ ok: Bool, _ detail: String? = nil) -> Bool {
        assertions.append(ScriptAssertion(name: name, ok: ok, detail: detail))
        return ok
    }

    /// A mid-step PNG (e.g. the finished activity sheet before Done).
    public func snapshot(_ label: String, settle: Double = 0.7) async {
        await runner.snapshot(label: label, settle: settle)
    }

    /// Polls `condition` until true; throws after `timeout` seconds.
    public func waitUntil(_ what: String, timeout: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw ScriptFailure("timed out after \(Int(timeout))s waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Lets queued work (a refresh started by a finished session) begin,
    /// then waits for refreshes to end.
    public func settle(timeout: Double = 120) async throws {
        try await Task.sleep(for: .milliseconds(400))
        try await waitUntil("the refresh to finish", timeout: timeout) { !store.isRefreshing }
    }

    /// An installed package by short or full name, optionally of one kind.
    public func package(_ name: String, kind: PackageKind? = nil) -> Package? {
        runner.watch(name)
        return store.packages.first { ($0.name == name || $0.fullName == name) && (kind == nil || $0.kind == kind) }
    }

    public func requirePackage(_ name: String, kind: PackageKind? = nil) throws -> Package {
        guard let p = package(name, kind: kind) else { throw ScriptFailure("\(name) is not installed") }
        return p
    }

    /// Starts a sheet session with `start` (a button's action) and runs it
    /// to the end the way a user does: the App Management explainer gets
    /// "Not now" (first use still runs), the finished sheet is captured,
    /// then Done. Throws when an item failed.
    @discardableResult
    public func runSession(_ what: String, timeout: Double = 900, startTimeout: Double = 15, start: () -> Void) async throws -> UpgradeSession {
        let before = store.upgrade?.id
        start()
        // Tap add/remove start their session after the tool sheet closes.
        try await waitUntil("\(what) to start", timeout: startTimeout) {
            store.appManagementPrompt != nil || (store.upgrade != nil && store.upgrade?.id != before)
        }
        if let prompt = store.appManagementPrompt, prompt.reason == .firstUse {
            check("app-management explainer shown first", true, prompt.packages.map(\.name).joined(separator: ", "))
            await snapshot("app-management")
            store.appManagementNotNow()
            try await waitUntil("\(what) to start after Not now", timeout: 15) { store.upgrade != nil && store.upgrade?.id != before }
        }
        guard let session = store.upgrade else { throw ScriptFailure("\(what) did not start") }
        try await waitUntil("\(what) to finish", timeout: timeout) { session.isFinished }
        try await settle()
        await snapshot("sheet")
        let failed = session.failedItems.map { "\($0.package.name): \($0.state)" }
        let blocked = store.appManagementPrompt?.reason == .blocked
        store.closeUpgrade()
        if blocked {
            // The block's own sheet ("I've done this" / "Not now"): close it.
            store.appManagementNotNow()
        }
        try await settle()
        check("\(what): every item done", failed.isEmpty && !blocked,
              blocked ? "blocked by App Management" : failed.isEmpty ? nil : failed.joined(separator: "; "))
        if !failed.isEmpty {
            let tail = session.log.lines.suffix(8).joined(separator: "\n")
            throw ScriptFailure("\(what) failed: \(failed.joined(separator: "; "))\n\(tail)")
        }
        return session
    }
}

/// Runs a parsed script against a store.
@MainActor
public final class ScriptRunner {
    public let store: AppStore
    public let steps: [ScriptStep]
    public let outputDirectory: URL
    public let scriptName: String
    /// Writes the window to a PNG at the path; false if it couldn't.
    let writeSnapshot: @MainActor (String) async -> Bool
    private var context: ScriptContext!
    private var stepIndex = 0
    private var stepVerb = ""
    private var stepSnapshots: [String] = []
    private var watched: [String] = []

    public init(store: AppStore, steps: [ScriptStep], outputDirectory: URL, scriptName: String = "script",
                snapshot: @escaping @MainActor (String) async -> Bool) {
        self.store = store
        self.steps = steps
        self.outputDirectory = outputDirectory
        self.scriptName = scriptName
        self.writeSnapshot = snapshot
        self.context = ScriptContext(store: store, runner: self)
    }

    func watch(_ name: String) {
        if !watched.contains(name) { watched.append(name) }
    }

    func snapshot(label: String, settle: Double = 0.7) async {
        // Let SwiftUI draw what just changed (a sheet appearing, a row).
        try? await Task.sleep(for: .seconds(settle))
        let file = String(format: "%02d-%@%@.png", stepIndex, stepVerb, label.isEmpty ? "" : "-" + label)
        let path = outputDirectory.appendingPathComponent(file).path
        if await writeSnapshot(path) { stepSnapshots.append(file) }
    }

    /// Runs every step; returns the summary (also in summary.json).
    public func run() async -> ScriptSummary {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let resultsURL = outputDirectory.appendingPathComponent("results.jsonl")
        FileManager.default.createFile(atPath: resultsURL.path, contents: nil)
        let out = try? FileHandle(forWritingTo: resultsURL)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var summary = ScriptSummary(script: scriptName, passed: 0, failed: 0, skipped: 0, failures: [])
        var stopped = false
        for (i, step) in steps.enumerated() {
            stepIndex = i + 1
            stepVerb = step.verb
            stepSnapshots = []
            context.args = step.args
            context.assertions = []
            let started = Date()
            var failure: String?
            let skip = stopped && !step.always
            if !skip {
                log("step \(stepIndex) (line \(step.line)): \(step.text)")
                do {
                    guard let def = Self.steps[step.verb] else { throw ScriptFailure("unknown step \(step.verb)") }
                    try await def.run(context)
                    if let bad = context.assertions.first(where: { !$0.ok }) {
                        throw ScriptFailure("check failed: \(bad.name)\(bad.detail.map { " (\($0))" } ?? "")")
                    }
                } catch {
                    failure = String(describing: error)
                }
                if step.verb != "snapshot" { await snapshot(label: "") }
            }
            let ok = !skip && failure == nil
            if skip { summary.skipped += 1 } else if ok { summary.passed += 1 } else {
                summary.failed += 1
                summary.failures.append("line \(step.line) \(step.text): \(failure ?? "")")
                stopped = true
            }
            log("  -> \(skip ? "SKIPPED" : ok ? "PASS" : "FAIL: \(failure ?? "")")")
            let result = ScriptStepResult(index: stepIndex, line: step.line, step: step.text, ok: ok, skipped: skip, error: failure,
                                          assertions: context.assertions, seconds: Date().timeIntervalSince(started),
                                          snapshot: stepSnapshots.last, state: state())
            if let data = try? enc.encode(result) { out?.write(data + Data("\n".utf8)) }
        }
        try? out?.close()
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? pretty.encode(summary).write(to: outputDirectory.appendingPathComponent("summary.json"))
        log("script \(scriptName): \(summary.passed) passed, \(summary.failed) failed, \(summary.skipped) skipped")
        return summary
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("e2e: \(s)\n".utf8))
    }

    /// The model, as the JSON line records it.
    func state() -> ScriptState {
        let s = store
        var hb: String
        switch s.homebrewState {
        case .checking: hb = "checking"
        case .ready: hb = "ready"
        case .missing: hb = "missing"
        case .broken(let path, _): hb = "broken:\(path)"
        }
        var session: ScriptState.Session?
        if let u = s.upgrade {
            var items: [String: String] = [:]
            for it in u.items { items[it.package.name] = "\(it.state)" }
            session = .init(action: u.action.rawValue, finished: u.isFinished, items: items)
        }
        var watchedPkgs: [String: ScriptState.Pkg?] = [:]
        for name in watched {
            let p = s.packages.first { $0.name == name || $0.fullName == name }
            watchedPkgs[name] = p.map { .init(id: $0.id, version: $0.installedVersion, versions: $0.installedVersions, pinned: $0.pinned) }
        }
        var outcome: String?
        if let o = s.insights.scanOutcome { outcome = "\(o)" }
        var scan: String
        switch s.insights.scanState {
        case .idle: scan = "idle"
        case .running: scan = "running"
        case .failed(let m): scan = "failed: \(m)"
        case .unsupported(let m): scan = "unsupported: \(m)"
        }
        return ScriptState(
            homebrewState: hb, reportFromCache: s.reportFromCache,
            formulae: s.packages.filter { $0.kind == .formula }.count, casks: s.packages.filter { $0.kind == .cask }.count,
            isRefreshing: s.isRefreshing, isBusy: s.isBusy,
            error: s.error.map { $0.title + ($0.detail.isEmpty ? "" : ": " + $0.detail) }, busyNotice: s.busyNotice,
            tab: s.tab.rawValue, selection: s.selection, showUpgradeSheet: s.showUpgradeSheet, session: session,
            appManagementPrompt: s.appManagementPrompt.map { "\($0.reason)" },
            scanState: scan, scanOutcome: outcome, vulnerableFormulae: s.insights.vulnerabilityScan?.findings.count,
            restorePoints: s.restorePoints.points.count,
            postInstallNotes: s.insights.postInstallNotes.map { $0.notes.map(\.name) },
            watched: watchedPkgs)
    }

    // MARK: the verbs

    /// Every step table. Add a feature's table here (see the header).
    static let stepTables: [[String: ScriptStepDef]] = [coreSteps, adoptSteps, backgroundUpdateSteps]

    public static let steps: [String: ScriptStepDef] = stepTables.reduce(into: [:]) { all, t in
        all.merge(t) { a, _ in a }
    }

    /// "verb usage" lines, for --help.
    public static var help: String {
        steps.keys.sorted().map { "  " + (steps[$0]?.usage ?? $0) }.joined(separator: "\n")
    }
}
