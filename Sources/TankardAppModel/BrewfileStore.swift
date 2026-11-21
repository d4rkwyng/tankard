import Foundation
import Observation
import TankardCore

// v0.6 (part B): the Brewfile sheet's state. Export runs `brew bundle dump`
// then counts the file with `brew bundle list`; Check runs `brew bundle
// check`; the restore plan reads the missing formulae and casks with one
// `brew info --json=v2` call each. All of it is read-only apart from the
// file dump writes. Nothing here runs a shell. But `brew bundle check`
// runs the Brewfile's Ruby: 0.8.8 (security review #2) Check first shows
// the static preview (BrewfileStaticReader, nothing run), then asks before
// brew reads the file. The other looks at the Brewfile's own text are for
// missing taps' URLs (0.8.5, BrewfileTapScanner), which no brew bundle
// subcommand prints.

/// What an exported Brewfile holds, from `brew bundle list` per kind.
public struct BrewfileSummary: Equatable, Sendable {
    public var path: String
    public var taps: Int
    public var formulae: Int
    public var casks: Int

    public init(path: String, taps: Int, formulae: Int, casks: Int) {
        self.path = path
        self.taps = taps
        self.formulae = formulae
        self.casks = casks
    }

    /// From the three `brew bundle list --tap|--formula|--cask` outputs.
    public init(path: String, tapList: String, formulaList: String, caskList: String) {
        self.init(path: path, taps: BrewfileParser.listNames(tapList).count,
                  formulae: BrewfileParser.listNames(formulaList).count,
                  casks: BrewfileParser.listNames(caskList).count)
    }

    /// "3 taps, 41 formulae, 12 casks"
    public var line: String {
        let t = String(localized: "\(taps) taps", bundle: L10n.bundle)
        let f = String(localized: "\(formulae) formulae", bundle: L10n.bundle)
        let c = String(localized: "\(casks) casks", bundle: L10n.bundle)
        return [t, f, c].joined(separator: ", ")
    }
}

/// What `brew bundle check` found missing.
public struct BrewfileCheckResult: Equatable, Sendable {
    public var path: String
    public var missing: [BrewfileEntry]

    public init(path: String, missing: [BrewfileEntry]) {
        self.path = path
        self.missing = missing
    }

    public var isSatisfied: Bool { missing.isEmpty }
    public func names(_ kind: BrewfileKind?) -> [String] { missing.filter { $0.kind == kind }.map(\.name) }
}

/// Reads compile and admin marks out of `brew info --json=v2`.
public enum BrewfilePlanner {
    /// Formula name (and full name) → compiles on this Mac: no usable
    /// bottle for its platform, as the status classifier decides it.
    public static func compiles(_ info: BrewInfoJSON, platform: BottlePlatform) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for f in info.formulae {
            let usable = platform.bottle(in: f.bottle["stable"])?.usable ?? false
            out[f.name] = !usable
            out[f.fullName] = !usable
        }
        return out
    }

    /// Casks whose artifacts include a `pkg` installer.
    public static func needsAdmin(_ info: BrewInfoJSON) -> Set<String> {
        var out: Set<String> = []
        for c in info.casks where c.installsPkg == true {
            out.insert(c.token)
            out.insert(c.fullToken)
        }
        return out
    }
}

public enum BrewfileError: Error, Equatable, CustomStringConvertible {
    case timedOut(seconds: Int)
    case failed(String)

    public var description: String {
        switch self {
        case .timedOut(let s):
            return String(localized: "brew bundle didn't finish within \(s) seconds, so Tankard stopped it. Homebrew may be busy or waiting on the network; try again in a moment.")
        case .failed(let s): return s
        }
    }
}

/// Runs `op`, cancelling it (ProcessRunner then stops brew's process
/// group) when `timeout` passes first.
///
/// On a timeout the cancelled run is still shutting down. The runner has
/// sent SIGTERM and reaps brew only when the process has exited; its kill
/// grace bounds that (SIGKILL follows). Wait for the run to finish before
/// returning, so a caller that deletes the private copy in a `defer` does
/// it after brew has gone.
func withBrewfileTimeout<T: Sendable>(_ timeout: Duration, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    let result: T? = try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await op() }
        group.addTask { try await Task.sleep(for: timeout); return nil }
        let first = try await group.next() ?? nil
        group.cancelAll()
        if first == nil {
            while !group.isEmpty {
                do { _ = try await group.next() } catch {}
            }
        }
        return first
    }
    guard let result else {
        let c = timeout.components
        throw BrewfileError.timedOut(seconds: Int(c.seconds))
    }
    return result
}

@MainActor
@Observable
public final class BrewfileStore {
    public enum Page: Equatable, Sendable {
        case idle
        /// 0.8.8: the file's plain lines, read without running anything.
        case preview(BrewfilePreview)
        /// 0.8.8: "A Brewfile is a Ruby program…", before brew bundle check.
        case confirmRun(BrewfilePreview)
        case running(String)
        case exported(BrewfileSummary)
        case checked(BrewfileCheckResult)
        /// The plan is being read (`brew info`), then shown.
        case planning(BrewfileCheckResult)
        case plan(BrewfileRestorePlan, note: String?)
        case failed(String)
    }

    public private(set) var page: Page = .idle
    public var isPresented: Bool { page != .idle }

    /// brew commands run through this (set by AppStore: the client's runner
    /// and read-only environment). Arguments after `brew`.
    @ObservationIgnored public var run: (@Sendable ([String]) async throws -> ProcessResult)?
    @ObservationIgnored public var platform: BottlePlatform?
    /// 0.9.0 (F4): reads a Brewfile's bytes, once per use: the preview,
    /// the copy brew runs (BrewfilePrivateCopy) and the taps' URLs all come
    /// from such a read, never from brew opening the user's path.
    @ObservationIgnored public var readBytes: @Sendable (String) throws -> Data = { try BrewfileSnapshot.read($0) }
    /// 0.8.8: whether macOS marked the file as downloaded.
    @ObservationIgnored public var quarantined: @Sendable (String) -> Bool = { BrewfileStaticReader.isQuarantined($0) }
    @ObservationIgnored public var timeout: Duration = .seconds(60)
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 0.9.0 (F4): the text the last check ran, for the plan's tap URLs.
    @ObservationIgnored private var checkedText: (path: String, text: String)?

    public init() {}

    private func set(_ p: Page) {
        if page != p { page = p }
    }

    public func dismiss() {
        task?.cancel()
        task = nil
        set(.idle)
    }

    private static var notReady: String { String(localized: "Homebrew isn't ready yet.") }

    private func start(_ label: String, _ body: @escaping @MainActor (@escaping @Sendable ([String]) async throws -> ProcessResult) async throws -> Page) {
        guard let run else {
            set(.failed(Self.notReady))
            return
        }
        task?.cancel()
        set(.running(label))
        task = Task { [weak self] in
            do {
                let next = try await body(run)
                guard !Task.isCancelled else { return }
                self?.set(next)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.set(.failed(String(describing: error)))
            }
        }
    }

    private static func tail(_ r: ProcessResult) -> String {
        let text = (r.stderrString + "\n" + r.stdoutString).split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
        return text.isEmpty ? String(localized: "exit \(r.exitCode)") : text
    }

    /// Export: dump, then count the file per kind. 0.9.0 (F4): the counts
    /// come from a private copy of what dump wrote, read once.
    public func export(to path: String, force: Bool) {
        let timeout = self.timeout
        let readBytes = self.readBytes
        start(String(localized: "Writing Brewfile…")) { run in
            let dump = try await withBrewfileTimeout(timeout) { try await run(BrewfileCommands.dump(path: path, force: force)) }
            guard dump.exitCode == 0 else { throw BrewfileError.failed(String(localized: "brew bundle dump failed:\n") + Self.tail(dump)) }
            let copy = try BrewfilePrivateCopy.make(try readBytes(path))
            defer { copy.remove() }
            let summary = try await withBrewfileTimeout(timeout) {
                async let t = run(BrewfileCommands.list(path: copy.path, kind: .tap))
                async let f = run(BrewfileCommands.list(path: copy.path, kind: .formula))
                async let c = run(BrewfileCommands.list(path: copy.path, kind: .cask))
                return BrewfileSummary(path: path, tapList: try await t.stdoutString, formulaList: try await f.stdoutString,
                                       caskList: try await c.stdoutString)
            }
            return .exported(summary)
        }
    }

    /// 0.8.8: Check Brewfile…'s first page: the plain lines, nothing run.
    public func preview(path: String) {
        task?.cancel()
        task = nil
        do {
            let text = try BrewfileSnapshot.text(readBytes(path))
            set(.preview(BrewfileStaticReader.preview(path: path, text: text, quarantined: quarantined(path))))
        } catch {
            set(.failed(Self.unreadable(error)))
        }
    }

    private static func unreadable(_ error: Error) -> String {
        String(localized: "Tankard couldn't read this file as a Brewfile.") + "\n" + String(describing: error)
    }

    static var changedMessage: String {
        String(localized: "This Brewfile changed after Tankard showed it, so brew didn't run it. Check it again to see what it holds now.")
    }

    /// 0.8.8: from the preview to the "it runs the file's code" question.
    public func requestBrewCheck() {
        guard case .preview(let p) = page else { return }
        set(.confirmRun(p))
    }

    /// 0.8.8: back from that question to the preview.
    public func cancelBrewCheck() {
        guard case .confirmRun(let p) = page else { return }
        set(.preview(p))
    }

    /// 0.9.0: the preview and the confirm page. Not a refusal.
    public static var loadsOtherFilesWarning: String {
        String(localized: "This Brewfile loads other files. Tankard runs a private copy, so files it loads by a path relative to the Brewfile won't be found.")
    }

    /// The confirmation's words. `quarantined`: the louder warning first.
    public static func runWarning(quarantined: Bool) -> [String] {
        var out: [String] = []
        if quarantined {
            out.append(String(localized: "This Brewfile was downloaded from the internet. A downloaded Brewfile can run any program on this Mac as soon as brew reads it."))
        }
        out.append(String(localized: "A Brewfile is a Ruby program. Checking or installing it with brew bundle runs the code in it, with your permissions, before Tankard shows anything."))
        out.append(String(localized: "Continue only if you trust whoever wrote this file."))
        return out
    }

    /// Check: what the Brewfile at `path` needs that this Mac lacks.
    /// Runs the Brewfile (brew bundle check): only after `confirmRun`, or
    /// for the demo's fixture. 0.9.0 (F4): the file is read once
    /// (`readBytes`); when `expectedDigest` (the preview's) doesn't match
    /// those bytes, nothing runs. brew gets a private copy of the same
    /// bytes, deleted when it is done.
    public func check(path: String, expectedDigest: String? = nil) {
        guard run != nil else {
            task?.cancel()
            task = nil
            set(.failed(Self.notReady))
            return
        }
        let text: String
        let copy: BrewfilePrivateCopy
        do {
            let data = try readBytes(path)
            text = try BrewfileSnapshot.text(data)
            if let expectedDigest, BrewfileStaticReader.digest(text) != expectedDigest {
                task?.cancel()
                task = nil
                set(.failed(Self.changedMessage))
                return
            }
            copy = try BrewfilePrivateCopy.make(data)
        } catch {
            task?.cancel()
            task = nil
            set(.failed(Self.unreadable(error)))
            return
        }
        checkedText = (path, text)
        let timeout = self.timeout
        start(String(localized: "Checking Brewfile…")) { run in
            // On a timeout, withBrewfileTimeout waits for the runner to reap
            // brew (bounded by its kill grace) before this defer runs.
            defer { copy.remove() }
            let r = try await withBrewfileTimeout(timeout) { try await run(BrewfileCommands.check(path: copy.path)) }
            let lines = (r.stdoutString + "\n" + r.stderrString).components(separatedBy: "\n")
            let missing = BrewfileParser.missing(lines)
            // check exits 1 when something is missing; any other failure
            // has no "needs to be" lines.
            if r.exitCode != 0 && missing.isEmpty {
                throw BrewfileError.failed(String(localized: "brew bundle check failed:\n") + Self.tail(r))
            }
            return .checked(BrewfileCheckResult(path: path, missing: missing))
        }
    }

    /// The restore plan for a check result: one `brew info` for the
    /// missing formulae (compile marks), one for the casks (pkg installers).
    public func planRestore(_ result: BrewfileCheckResult) {
        let timeout = self.timeout
        let platform = self.platform
        let readBytes = self.readBytes
        let checked = checkedText
        // The text the check ran; another file is read (once) only when
        // the result came from elsewhere.
        let readFile: @Sendable (String) -> String? = { p in
            if let checked, checked.path == p { return checked.text }
            return (try? readBytes(p)).flatMap { try? BrewfileSnapshot.text($0) }
        }
        start(String(localized: "Reading package details…")) { run in
            let p = try await withBrewfileTimeout(timeout) {
                await Self.buildPlan(result, platform: platform, run: run, readFile: readFile)
            }
            return .plan(p.0, note: p.1)
        }
    }

    /// The plan, and a note when details couldn't be read (brew info fails
    /// the whole call when any name is unknown). Never throws: without
    /// details the marks are just left off.
    nonisolated static func buildPlan(_ result: BrewfileCheckResult, platform: BottlePlatform?,
                                      run: @Sendable ([String]) async throws -> ProcessResult,
                                      readFile: @Sendable (String) -> String? = { (try? BrewfileSnapshot.read($0)).flatMap { try? BrewfileSnapshot.text($0) } })
        async -> (BrewfileRestorePlan, String?) {
        var compiles: [String: Bool] = [:]
        var admin: Set<String> = []
        var notes: [String] = []
        let formulae = result.names(.formula), casks = result.names(.cask)
        func info(_ names: [String], _ kind: PackageKind) async -> BrewInfoJSON? {
            guard !names.isEmpty, let r = try? await run(BrewClient.infoArguments(names, kind: kind)) else { return nil }
            return try? JSONDecoder().decode(BrewInfoJSON.self, from: r.stdout)
        }
        if !formulae.isEmpty {
            if let i = await info(formulae, .formula), let platform {
                compiles = BrewfilePlanner.compiles(i, platform: platform)
            } else {
                notes.append(String(localized: "Couldn't read the formulae's details, so compiles aren't marked."))
            }
        }
        if !casks.isEmpty {
            if let i = await info(casks, .cask) {
                admin = BrewfilePlanner.needsAdmin(i)
            } else {
                notes.append(String(localized: "Couldn't read the casks' details, so admin passwords aren't marked."))
            }
        }
        // 0.8.5 (M3): the missing taps' URLs, read from the file's text.
        let tapSources = result.names(.tap).isEmpty ? [:] : readFile(result.path).map(BrewfileTapScanner.scan)
        let plan = BrewfileRestorePlan(missing: result.missing, path: result.path, compiles: compiles, needsAdmin: admin,
                                       tapSources: tapSources)
        return (plan, notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    /// Back from the plan to the check result.
    public func back(to result: BrewfileCheckResult) {
        task?.cancel()
        set(.checked(result))
    }

    /// Waits for a running step (demo and tests).
    public func waitForIdle() async {
        await task?.value
    }
}
