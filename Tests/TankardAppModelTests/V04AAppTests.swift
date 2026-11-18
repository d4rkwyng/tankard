import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.4 (part A): pin/unpin, the Pinned and Requested-only filters, dependency
// links, Services through the queue, and the Homebrew menu's scripts. Fake
// runners and demo mode only: nothing here runs brew.

/// Answers `brew info` from a fixture and `brew services` from canned JSON.
final class FakeServicesRunner: CommandRunning, @unchecked Sendable {
    let log: CallLog
    let info: Data
    let list: Data
    let detail: Data

    init(log: CallLog, info: Data, list: Data, detail: Data = Data("[]".utf8)) {
        self.log = log
        self.info = info
        self.list = list
        self.detail = detail
    }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        guard executable.hasSuffix("brew") else { return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data()) }
        log.add(arguments)
        if arguments == BrewServices.listArguments { return ProcessResult(exitCode: 0, stdout: list, stderr: Data()) }
        if arguments.starts(with: ["services", "info"]) { return ProcessResult(exitCode: 0, stdout: detail, stderr: Data()) }
        return ProcessResult(exitCode: 0, stdout: info, stderr: Data())
    }
}

@MainActor
struct PinTests {
    func rig(stream: (@Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32)? = nil) -> (AppStore, CallLog) {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log, behaviour: stream ?? { _, _ in 0 })
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil)
        return (AppStore(deps: deps), log)
    }

    @Test func commands() async throws {
        let (store, _) = rig()
        await store.start()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        #expect(PinCommands.arguments(pin: true, for: xz) == ["pin", "--formula", "homebrew/core/xz"])
        #expect(PinCommands.display(pin: false, for: xz) == "brew unpin --formula homebrew/core/xz")
        var cask = xz
        cask.kind = .cask
        cask.id = "cask:homebrew/cask/iterm2"
        #expect(PinCommands.arguments(pin: true, for: cask) == ["pin", "--cask", "homebrew/cask/iterm2"])
    }

    @Test func pinGoesThroughTheQueueThenReReads() async throws {
        let (store, log) = rig()
        await store.start()
        let reads = log.count("info")
        let xz = try #require(store.packages.first { $0.name == "xz" })
        store.setPinned(xz, true)
        #expect(await waitUntil { log.count("pin") == 1 && log.count("info") > reads && store.quickAction == nil })
        #expect(log.calls.contains(["pin", "--formula", "homebrew/core/xz"]))
        #expect(store.error == nil)
        // Already in that state (the fake brew still says unpinned): nothing runs.
        store.setPinned(xz, false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.count("unpin") == 0)
    }

    /// A click while brew is busy used to do nothing at all; now the status
    /// bar says why, and the notice clears itself.
    @Test func busyPinClickSaysSo() async throws {
        let (store, log) = rig()
        await store.start()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        #expect(store.busyNotice == nil)
        store.quickAction = "brew services stop -- php"   // something else holds the queue
        store.setPinned(xz, true)
        #expect(await waitUntil { store.busyNotice != nil })
        #expect(store.busyNotice == "brew pin --formula homebrew/core/xz didn't start: brew services stop -- php is still running. Try again when it finishes.")
        #expect(log.count("pin") == 0)
        store.quickAction = nil
        store.showBusyNotice("x", seconds: 0.05)
        #expect(await waitUntil { store.busyNotice == nil })
        #expect(AppStore.notStartedNotice("brew pin x", running: nil, upgrading: true)
                == "brew pin x didn't start: an upgrade is still running. Try again when it finishes.")
        #expect(AppStore.notStartedNotice("brew pin x", running: nil, upgrading: false).contains("isn't ready"))
    }

    @Test func failedPinShowsBrewsError() async throws {
        let (store, log) = rig { args, output in
            output(Data("Error: No such keg: /usr/local/Cellar/xz\n".utf8))
            return 1
        }
        await store.start()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        store.setPinned(xz, true)
        #expect(await waitUntil { store.error != nil && store.quickAction == nil })
        #expect(store.error?.title == "Pin xz failed (exit 1)")
        #expect(store.error?.detail.contains("No such keg") == true)
        #expect(store.error?.terminalCommand == "brew pin --formula homebrew/core/xz")
        #expect(log.count("pin") == 1)
    }

    @Test func pinnedUpgradesAreLeftOutOfUpgradeAll() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0, pinned: ["sqlite"]))
        await store.start()
        #expect(store.count(.upgrades) == 5)            // the filter still shows it
        #expect(store.upgradable.count == 4)            // Upgrade all doesn't
        #expect(!store.upgradable.contains { $0.name == "sqlite" })
        #expect(store.pinnedUpgrades.map(\.name) == ["sqlite"])
        #expect(store.pinnedUpgradeNote == "1 pinned upgrade not included (sqlite)")
        #expect(MenuBarSummary(packages: store.packages).count == 4)
        #expect(!UpgradeNotificationDiff.keys(store.packages).contains { $0.hasPrefix("formula:homebrew/core/sqlite@") })
        // Asking for it by name doesn't upgrade it either (brew would refuse).
        let sqlite = try #require(store.packages.first { $0.name == "sqlite" })
        store.requestUpgrade([sqlite])
        #expect(store.upgrade == nil && store.upgradePlan == nil)
        // Upgrade all runs the other four.
        store.startUpgrade()
        let session = try #require(store.upgrade)
        #expect(session.items.map(\.package.name).sorted() == ["openssl@4", "python@3.15", "ruby", "xz"])
        #expect(await waitUntil { session.isFinished })
    }

    @Test func demoPinAndUnpinRoundTrip() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        #expect(store.count(.pinned) == 0)
        let xz = try #require(store.packages.first { $0.name == "xz" })
        store.setPinned(xz, true)
        #expect(await waitUntil { store.packages.first { $0.name == "xz" }?.pinned == true && !store.isRefreshing })
        #expect(store.count(.pinned) == 1)
        store.filter = .pinned
        #expect(store.visiblePackages.map(\.name) == ["xz"])
        #expect(!store.upgradable.contains { $0.name == "xz" })
        let pinned = try #require(store.packages.first { $0.name == "xz" })
        store.setPinned(pinned, false)
        #expect(await waitUntil { store.packages.first { $0.name == "xz" }?.pinned == false && !store.isRefreshing })
        #expect(store.upgradable.contains { $0.name == "xz" })
    }

    @Test func contextMenuPinItems() async throws {
        let (store, _) = rig()
        await store.start()
        var p = try #require(store.packages.first { $0.name == "xz" })
        p.upgradeAvailable = true
        p.pinned = true
        let m = ContextMenus.installed(p, dependents: [], dependencies: [], compileWarning: nil, busy: false, kegPath: nil)
        let items = m.compactMap(\.item)
        #expect(items.first { $0.id == "unpin" }?.action == .unpin)
        #expect(items.first { $0.id == "pin" } == nil)
        let upgrade = try #require(items.first { $0.id == "upgrade" })
        #expect(upgrade.title == "Upgrade xz (pinned)")
        #expect(!upgrade.isEnabled)
        let busy = ContextMenus.installed(p, dependents: [], dependencies: [], compileWarning: nil, busy: true, kegPath: nil)
        #expect(busy.compactMap(\.item).first { $0.id == "unpin" }?.isEnabled == false)
    }
}

@MainActor
struct LeavesAndLinksTests {
    @Test func installedByYouFilter() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        // 0.8.2: brew's installed-on-request, whether or not something
        // else needs it (was `brew leaves -r`, "Requested only").
        let expected = store.packages.filter(\.requested).map(\.name).sorted()
        store.filter = .leaves
        #expect(store.visiblePackages.map(\.name).sorted() == expected)
        #expect(store.count(.leaves) == expected.count)
        #expect(!expected.isEmpty)
        // A dependency brew installed for something else isn't in it.
        #expect(store.packages.contains { !$0.requested })
        #expect(PackageFilter.leaves.title == "Installed by you")
        #expect(PackageFilter.segmented.count == 5)
        #expect(Set(PackageFilter.segmented + PackageFilter.more) == Set(PackageFilter.allCases))
    }

    @Test func revealClearsWhatHidesIt() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        store.filter = .upgrades
        store.search = "python"
        let xz = try #require(store.packages.first { $0.name == "lz4" })
        store.reveal(xz.id)
        #expect(store.selection == xz.id)
        #expect(store.filter == .all && store.search.isEmpty)
        // A visible one keeps the filter.
        store.filter = .all
        store.search = "z"
        store.reveal(xz.id)
        #expect(store.search == "z")
    }
}

@MainActor
struct ServicesStoreTests {
    static let list = Data("""
    [{"name":"postgresql@18","status":"started","user":"test","file":"/Users/test/Library/LaunchAgents/homebrew.mxcl.postgresql@18.plist","exit_code":0},
     {"name":"unbound","status":"started","user":"root","file":"/Library/LaunchDaemons/homebrew.mxcl.unbound.plist","exit_code":0},
     {"name":"php","status":"none","user":null,"file":"/usr/local/opt/php/homebrew.mxcl.php.plist","exit_code":null}]
    """.utf8)

    func rig(stream: (@Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32)? = nil) async throws -> (AppStore, ServicesStore, CallLog) {
        let log = CallLog()
        let infoRunner = FakeServicesRunner(log: log, info: demoIntelInfo(), list: Self.list,
                                            detail: try Data(contentsOf: Self.fixture("arm64-services-info")))
        let client = makeClient(infoRunner)
        let runner = FakeStreamRunner(log: log, behaviour: stream ?? { _, output in
            output(Data("==> Successfully started `x`\n".utf8))
            return 0
        })
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
        await store.start()
        let services = try #require(store.openServices())
        return (store, services, log)
    }

    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TankardCoreTests/Fixtures/\(name).json")
    }

    @Test func nothingRunsUntilOpened() async throws {
        let log = CallLog()
        let client = makeClient(FakeServicesRunner(log: log, info: demoIntelInfo(), list: Self.list))
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: FakeStreamRunner(log: log) { _, _ in 0 },
                                                         cache: nil, logURL: nil))
        await store.start()
        #expect(store.services == nil)
        #expect(!log.calls.contains { $0.first == "services" })
    }

    @Test func listIsAReadOffTheQueue() async throws {
        let (_, services, log) = try await rig()
        await services.load()
        #expect(services.phase == .ready)
        #expect(services.services.map(\.name) == ["postgresql@18", "unbound", "php"])
        #expect(services.summary == "3 services · 2 running")
        #expect(log.calls.filter { $0 == ["services", "list", "--json"] }.count == 1)
        services.selection = "php"
        await services.loadInfo("php")
        #expect(services.selected?.command == "/opt/homebrew/opt/php/sbin/php-fpm --nodaemonize")
        #expect(services.selected?.file == "/opt/homebrew/opt/php/sh.brew.php.plist")
    }

    @Test func startGoesThroughTheQueueThenReloads() async throws {
        let (store, services, log) = try await rig()
        await services.load()
        let php = try #require(services.services.first { $0.name == "php" })
        #expect(services.command(.start, php) == "brew services start -- php")
        await services.perform(.start, on: php, store: store)
        #expect(log.calls.contains(["services", "start", "--", "php"]))
        #expect(log.calls.filter { $0 == ["services", "list", "--json"] }.count == 2)
        #expect(services.actionError == nil)
        #expect(store.quickAction == nil)
    }

    @Test func busyServiceClickSaysSo() async throws {
        let (store, services, log) = try await rig()
        await services.load()
        let php = try #require(services.services.first { $0.name == "php" })
        store.quickAction = "brew pin --formula homebrew/core/xz"
        await services.perform(.start, on: php, store: store)
        #expect(!log.calls.contains(["services", "start", "--", "php"]))
        #expect(store.busyNotice?.hasPrefix("brew services start -- php didn't start: brew pin --formula homebrew/core/xz is still running") == true)
        store.quickAction = nil
    }

    @Test func rootServiceNeverReachesBrew() async throws {
        let (store, services, log) = try await rig()
        await services.load()
        let unbound = try #require(services.services.first { $0.name == "unbound" })
        #expect(services.needsSudo(unbound))
        await services.perform(.stop, on: unbound, store: store)
        #expect(!log.calls.contains(["services", "stop", "--", "unbound"]))
        #expect(services.actionError?.terminalCommand == "sudo brew services stop -- unbound")
    }

    @Test func brewsSudoMessageBecomesTerminalGuidance() async throws {
        let (store, services, _) = try await rig { _, output in
            // brew 7.0.14's wording (services/cli.rb), for a root-owned service.
            output(Data("Error: Service `postgresql@18` is started as `root`. Try:\n  sudo brew services stop postgresql@18\n".utf8))
            return 1
        }
        await services.load()
        let pg = try #require(services.services.first { $0.name == "postgresql@18" })
        #expect(!services.needsSudo(pg)) // the list said "test", brew disagreed
        await services.perform(.stop, on: pg, store: store)
        #expect(services.actionError?.terminalCommand == "sudo brew services stop -- postgresql@18")
        #expect(services.actionError?.title.contains("needs sudo") == true)
    }

    @Test func otherFailuresKeepBrewsWords() async throws {
        let (store, services, _) = try await rig { _, output in
            output(Data("Error: Formula `php` has not implemented #plist, #service or installed a locatable service file\n".utf8))
            return 1
        }
        await services.load()
        let php = try #require(services.services.first { $0.name == "php" })
        await services.perform(.start, on: php, store: store)
        #expect(services.actionError?.title == "Start php failed (exit 1)")
        #expect(services.actionError?.detail.contains("locatable service file") == true)
        #expect(services.actionError?.terminalCommand == "brew services start -- php")
    }

    @Test func sudoMarkers() {
        #expect(ServicesStore.outputNeedsSudo(["Error: Service `x` is started as `root`. Try:"], currentUser: "you"))
        #expect(ServicesStore.outputNeedsSudo(["  sudo brew services stop x"], currentUser: "you"))
        #expect(ServicesStore.outputNeedsSudo(["sudo: a terminal is required to read the password"], currentUser: "you"))
        #expect(!ServicesStore.outputNeedsSudo(["==> Successfully started `x`"], currentUser: "you"))
    }

    @Test func demoServicesEndToEnd() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        let services = try #require(store.openServices())
        await services.load()
        #expect(services.services.count == 4)
        // The demo's own user runs postgresql@18; root runs unbound.
        let pg = try #require(services.services.first { $0.name == "postgresql@18" })
        #expect(!services.needsSudo(pg))
        #expect(services.currentUser == "demo")
        let redis = try #require(services.services.first { $0.name == "redis" })
        #expect(redis.status == .none)
        await services.perform(.start, on: redis, store: store)
        #expect(services.services.first { $0.name == "redis" }?.status == .started)
        let unbound = try #require(services.services.first { $0.name == "unbound" })
        await services.perform(.restart, on: unbound, store: store)
        #expect(services.actionError?.terminalCommand == "sudo brew services restart -- unbound")
    }
}

struct HomebrewManagementTests {
    let home = "/Users/test"

    func plan(_ files: [String: String], zdotdir: String? = nil, brewEnv: [(String, [String: String])] = []) -> RevertPlan {
        RevertPlan.make(home: home, zdotdir: zdotdir, repository: "/usr/local/Homebrew", brewPath: "/usr/local/bin/brew",
                        brewEnvFiles: brewEnv, date: Date(timeIntervalSince1970: 1_800_000_000),
                        read: { files[$0] })
    }

    @Test func typedConfirmation() {
        #expect(HomebrewManagement.isConfirmed("revert", for: .revert))
        #expect(HomebrewManagement.isConfirmed("  Revert\n", for: .revert))
        #expect(!HomebrewManagement.isConfirmed("rev", for: .revert))
        #expect(!HomebrewManagement.isConfirmed("uninstall", for: .revert))
        #expect(HomebrewManagement.isConfirmed("uninstall", for: .uninstall))
        #expect(!HomebrewManagement.isConfirmed("", for: .uninstall))
    }

    @Test func lineMatcher() {
        #expect(RevertPlan.matches("export HOMEBREW_CORE_GIT_REMOTE=https://github.com/d4rkwyng/intelbrew-core"))
        #expect(RevertPlan.matches("  export\tHOMEBREW_NO_INSTALL_FROM_API=1"))
        #expect(RevertPlan.matches("HOMEBREW_BREW_GIT_REMOTE=\"https://github.com/d4rkwyng/brew\""))
        #expect(!RevertPlan.matches("# export HOMEBREW_CORE_GIT_REMOTE=x"))
        #expect(!RevertPlan.matches("export HOMEBREW_NO_ANALYTICS=1"))
        #expect(!RevertPlan.matches("export HOMEBREW_CORE_GIT_REMOTE_X=1"))
        #expect(!RevertPlan.matches("exportHOMEBREW_CORE_GIT_REMOTE=1"))
        #expect(RevertPlan.sedPattern == "^[[:blank:]]*(export[[:blank:]]+)?(HOMEBREW_NO_INSTALL_FROM_API|HOMEBREW_CORE_GIT_REMOTE|HOMEBREW_BREW_GIT_REMOTE)=")
    }

    @Test func planFindsTheInstallersLines() {
        let p = plan([
            "\(home)/.zshenv": "export PATH=x\nexport HOMEBREW_NO_INSTALL_FROM_API=1\nexport HOMEBREW_CORE_GIT_REMOTE=https://github.com/d4rkwyng/intelbrew-core\nexport HOMEBREW_BREW_GIT_REMOTE=https://github.com/d4rkwyng/brew\n",
            "\(home)/.bashrc": "HOMEBREW_CORE_GIT_REMOTE=https://github.com/d4rkwyng/intelbrew-core\n",
            "\(home)/.zshrc": "export HOMEBREW_NO_ANALYTICS=1\n",
        ], brewEnv: [("~/.homebrew/brew.env", ["HOMEBREW_CORE_GIT_REMOTE": "x"])])
        #expect(p.edits.map(\.label) == ["~/.zshenv", "~/.bashrc"])
        #expect(p.edits[0].lines.count == 3)
        #expect(p.brewEnvNotes == ["~/.homebrew/brew.env: HOMEBREW_CORE_GIT_REMOTE"])
        #expect(p.backupSuffix.hasPrefix("tankard-backup-"))
        let c = p.commands
        #expect(c.count == 2 * 2 + 3)
        #expect(c[0] == "cp -p /Users/test/.zshenv /Users/test/.zshenv.\(p.backupSuffix)")
        #expect(c[1] == "/usr/bin/sed -i '' -E '/\(RevertPlan.sedPattern)/d' /Users/test/.zshenv")
        #expect(c[4] == "unset HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_CORE_GIT_REMOTE HOMEBREW_BREW_GIT_REMOTE")
        // The README's two commands, with this brew's repository and path.
        #expect(c[5] == "git -C /usr/local/Homebrew remote set-url origin https://github.com/Homebrew/brew")
        #expect(c[6] == "/usr/local/bin/brew update")
    }

    @Test func zdotdirAndNoEdits() {
        #expect(RevertPlan.candidatePaths(home: home, zdotdir: "/Users/test/.config/zsh").contains("/Users/test/.config/zsh/.zshenv"))
        #expect(RevertPlan.candidatePaths(home: home, zdotdir: nil).filter { $0 == "\(home)/.zshenv" }.count == 1)
        let p = plan([:])
        #expect(p.edits.isEmpty)
        #expect(p.commands.first?.hasPrefix("unset ") == true)
    }

    @Test func revertScriptRemovesExactlyTheShownLines() throws {
        // Run the script's sed and cp lines on a temp copy (no brew, no git).
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zshenv = dir.appendingPathComponent(".zshenv")
        let original = """
        export PATH="$HOME/bin:$PATH"
        export HOMEBREW_NO_INSTALL_FROM_API=1
        export HOMEBREW_CORE_GIT_REMOTE=https://github.com/d4rkwyng/intelbrew-core
          export	HOMEBREW_BREW_GIT_REMOTE="https://github.com/d4rkwyng/brew"  # intelbrew
        export HOMEBREW_NO_ANALYTICS=1
        # export HOMEBREW_CORE_GIT_REMOTE=kept-as-a-comment

        """
        try original.write(to: zshenv, atomically: true, encoding: .utf8)
        // ~/.bashrc is a symlink into a dotfiles repo: BSD sed -i refuses
        // symlinks, so the real file is backed up and edited, and the link stays.
        let dotfiles = dir.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let realBashrc = dotfiles.appendingPathComponent("bashrc")
        let bashrcText = "alias ll='ls -l'\nexport HOMEBREW_CORE_GIT_REMOTE=https://github.com/d4rkwyng/intelbrew-core\n"
        try bashrcText.write(to: realBashrc, atomically: true, encoding: .utf8)
        let bashrc = dir.appendingPathComponent(".bashrc")
        try FileManager.default.createSymbolicLink(atPath: bashrc.path, withDestinationPath: "dotfiles/bashrc")
        let p = RevertPlan.make(home: dir.path, zdotdir: nil, repository: "/nonexistent", brewPath: "/nonexistent/brew",
                                brewEnvFiles: [], date: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(p.edits.count == 2)
        #expect(p.edits[0].lines.count == 3)
        #expect(!p.edits[0].isSymlink)
        let linked = try #require(p.edits.first { $0.label == "~/.bashrc" })
        #expect(linked.isSymlink)
        #expect(try FileManager.default.attributesOfItem(atPath: linked.target)[.type] as? FileAttributeType == .typeRegular)
        #expect(RevertPlan.realPath(realBashrc.path) == realBashrc.path)  // not a link: unchanged
        #expect(linked.target.hasSuffix("/dotfiles/bashrc"))
        #expect(p.commands.contains { $0.hasPrefix("/usr/bin/sed ") && $0.hasSuffix(linked.target) })
        #expect(!p.commands.contains { $0.hasSuffix(" " + bashrc.path) })
        let fileCommands = p.commands.prefix(4).joined(separator: "\n")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "set -e\n" + fileCommands]
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        let after = try String(contentsOf: zshenv, encoding: .utf8)
        let kept = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !RevertPlan.matches($0) }
        #expect(after == kept.joined(separator: "\n"))
        #expect(after.contains("HOMEBREW_NO_ANALYTICS") && after.contains("# export HOMEBREW_CORE_GIT_REMOTE"))
        let backup = dir.appendingPathComponent(".zshenv.\(p.backupSuffix)")
        let backedUp = try String(contentsOf: backup, encoding: .utf8)
        #expect(backedUp == original)
        // The symlink is still a symlink, its target lost only the Intelbrew
        // line, and the backup sits next to the target.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: bashrc.path)) == "dotfiles/bashrc")
        #expect(try String(contentsOf: realBashrc, encoding: .utf8) == "alias ll='ls -l'\n")
        #expect(try String(contentsOfFile: linked.target + "." + p.backupSuffix, encoding: .utf8) == bashrcText)
    }

    /// Removing the only line in an if/fi (or loop, or { }) body would leave
    /// broken bash. Such a file is left for the user, with a warning; a
    /// block that keeps another command, a one-liner and zsh files are fine.
    @Test func emptiedBlocksAreDetected() throws {
        let x = "export HOMEBREW_NO_INSTALL_FROM_API=1"
        #expect(RevertPlan.emptiedBlocks(["if [ -x /usr/local/bin/brew ]; then", "  \(x)", "fi"]) == [2])
        #expect(RevertPlan.emptiedBlocks(["if [ -x /usr/local/bin/brew ]", "then", "  \(x)", "  export HOMEBREW_CORE_GIT_REMOTE=y", "fi"]) == [3, 4])
        #expect(RevertPlan.emptiedBlocks(["if true; then", "  \(x)", "  export PATH=/x:$PATH", "fi"]).isEmpty)
        #expect(RevertPlan.emptiedBlocks(["if true; then", "  echo a", "else", "  \(x)  # intelbrew", "fi"]) == [4])
        #expect(RevertPlan.emptiedBlocks(["if true; then", "  \(x)", "elif false; then", "  echo b", "fi"]) == [2])
        #expect(RevertPlan.emptiedBlocks(["brewenv() {", "  \(x)", "}"]) == [2])
        #expect(RevertPlan.emptiedBlocks(["function brewenv {", "  \(x)", "}"]) == [2])
        #expect(RevertPlan.emptiedBlocks(["for f in a b; do", "  \(x)", "done"]) == [2])
        #expect(RevertPlan.emptiedBlocks(["while read -r l; do", "  # just a comment", "  \(x)", "done < f"]) == [3])
        #expect(RevertPlan.emptiedBlocks(["case $TERM in", "  xterm) \(x) ;;", "esac"]).isEmpty)   // not a removable line
        #expect(RevertPlan.emptiedBlocks(["case $TERM in", "  xterm)", "    \(x)", "    ;;", "esac"]).isEmpty) // empty case arm is fine
        #expect(RevertPlan.emptiedBlocks(["if true; then echo done; fi", x, "echo if then fi"]).isEmpty)
        #expect(RevertPlan.emptiedBlocks([x, "export PATH=x"]).isEmpty)
        // Nested: the inner body empties, the outer keeps the inner if.
        #expect(RevertPlan.emptiedBlocks(["if a; then", "  if b; then", "    \(x)", "  fi", "fi"]) == [3])

        // Every case above that is flagged really is a bash syntax error
        // after sed, and every unflagged one isn't.
        let cases: [[String]] = [
            ["if [ -x /usr/local/bin/brew ]; then", "  \(x)", "fi"],
            ["brewenv() {", "  \(x)", "}"],
            ["for f in a b; do", "  \(x)", "done"],
            ["if true; then", "  \(x)", "  export PATH=/x:$PATH", "fi"],
            ["case $TERM in", "  xterm)", "    \(x)", "    ;;", "esac"],
        ]
        for c in cases {
            let kept = c.filter { !RevertPlan.matches($0) }.joined(separator: "\n") + "\n"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-n", "-c", kept]
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
            #expect((proc.terminationStatus != 0) == !RevertPlan.emptiedBlocks(c).isEmpty, "\(c)")
        }

        // In a plan: the bash file is reported, not edited; the zsh file
        // (zsh runs an empty block) and a plain file are edited.
        let block = "if [ -d /usr/local ]; then\n  \(x)\nfi\n"
        let p = plan(["\(home)/.bashrc": block, "\(home)/.zshrc": block, "\(home)/.bash_profile": x + "\n"])
        let bashrc = try #require(p.edits.first { $0.label == "~/.bashrc" })
        #expect(!bashrc.isAutomatic && bashrc.emptiedBlockLines == [2])
        #expect(p.edits.first { $0.label == "~/.zshrc" }?.isAutomatic == true)
        #expect(p.edits.first { $0.label == "~/.bash_profile" }?.isAutomatic == true)
        #expect(!p.commands.contains { $0.contains("/.bashrc") })
        #expect(p.commands.contains { $0.hasSuffix("/Users/test/.zshrc") })
        #expect(p.commands.contains { $0.hasSuffix("/Users/test/.bash_profile") })
        #expect(p.script.contains("Not edited: ~/.bashrc (line 2 would leave an empty block)"))
    }

    @Test func linkedProfilesAreEditedOnce() {
        // .bash_profile and .bashrc both link to one file: one backup, one edit.
        let p = RevertPlan.make(home: home, zdotdir: nil, repository: "/r", brewPath: "/b", brewEnvFiles: [],
                                date: Date(timeIntervalSince1970: 1_800_000_000),
                                read: { $0.hasSuffix("bash_profile") || $0.hasSuffix("bashrc") ? "export HOMEBREW_BREW_GIT_REMOTE=x\n" : nil },
                                resolve: { $0.hasPrefix(home + "/.bash") ? home + "/dotfiles/bash" : $0 })
        #expect(p.edits.map(\.label) == ["~/.bash_profile"])
        #expect(p.edits[0].targetLabel == "~/dotfiles/bash")
        #expect(p.commands[0] == "cp -p /Users/test/dotfiles/bash /Users/test/dotfiles/bash.\(p.backupSuffix)")
    }

    @Test func scriptsShowWaitAndUseTheOfficialCommand() {
        #expect(HomebrewManagement.officialUninstallCommand
                == #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)""#)
        let u = HomebrewManagement.uninstallScript(prefix: "/usr/local")
        #expect(u.hasPrefix("#!/bin/bash\n"))
        #expect(u.contains("read -r -p"))
        let lines = u.split(separator: "\n").map(String.init)
        let readAt = lines.firstIndex { $0.hasPrefix("read ") }!
        let runAt = lines.firstIndex { $0 == HomebrewManagement.uninstallCommand(prefix: "/usr/local") }!
        #expect(readAt < runAt)

        let p = plan(["\(home)/.zshenv": "export HOMEBREW_NO_INSTALL_FROM_API=1\n"])
        let s = p.script
        #expect(s.contains("set -e"))
        let sl = s.split(separator: "\n").map(String.init)
        let pause = sl.firstIndex { $0.hasPrefix("read ") }!
        for c in p.commands {
            // Each command is listed before the pause and run after it.
            let run = sl.lastIndex(of: c)
            #expect(run != nil && run! > pause, "\(c)")
        }
        #expect(s.contains("brew untap homebrew/core"))
        #expect(!s.contains("\nbrew untap"))  // mentioned, never run
    }

    /// The uninstaller gets the prefix Tankard detected via uninstall.sh's
    /// --path, so a Mac with both /usr/local and /opt/homebrew loses only
    /// the one the sheet named. The quoting survives spaces and quotes.
    @Test func uninstallPinsTheDetectedPrefix() throws {
        #expect(HomebrewManagement.uninstallCommand(prefix: "/usr/local")
                == HomebrewManagement.officialUninstallCommand + " uninstall.sh --path='/usr/local'")
        #expect(HomebrewManagement.uninstallScript(prefix: "/usr/local").contains(" uninstall.sh --path='/usr/local'\n"))
        #expect(HomebrewManagement.uninstallScript(prefix: "/opt/homebrew").contains("--path='/opt/homebrew'"))
        #expect(!HomebrewManagement.uninstallScript(prefix: "/opt/homebrew").contains("--path='/usr/local'"))
        #expect(HomebrewManagement.uninstallCommand(prefix: "/Volumes/My Disk/brew").hasSuffix(" --path='/Volumes/My Disk/brew'"))
        // Run the generated line with the curl'd uninstall.sh swapped for a
        // stub that prints its argv: bash must hand uninstall.sh exactly one
        // --path=<prefix> argument, whatever the prefix contains.
        for prefix in ["/usr/local", "/Volumes/My Disk/brew", "/Users/o'brien/$HOME `x` \"q\""] {
            let line = HomebrewManagement.uninstallCommand(prefix: prefix)
                .replacingOccurrences(of: #""$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)""#,
                                      with: #"'printf "%s\n" "$0" "$@"'"#)
            #expect(!line.contains("curl"))
            let proc = Process()
            let out = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", line]
            proc.standardOutput = out
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 0)
            #expect(String(decoding: data, as: UTF8.self) == "uninstall.sh\n--path=\(prefix)\n")
        }
    }

    @Test func scriptsParseAsBash() throws {
        let p = plan(["\(home)/.zshenv": "export HOMEBREW_NO_INSTALL_FROM_API=1\n", "\(home)/.bash_profile": "export HOMEBREW_BREW_GIT_REMOTE=x\n"])
        for script in [p.script, HomebrewManagement.uninstallScript(prefix: "/usr/local"),
                       HomebrewManagement.uninstallScript(prefix: "/Users/o'brien/my brew")] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-n", "-c", script]   // syntax check only
            try proc.run()
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 0)
        }
    }

    @Test @MainActor func revertOnlyInIntelbrewMode() async throws {
        let arm = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await arm.start()
        arm.requestManagement(.revert)
        #expect(arm.managementSheet == nil)
        #expect(arm.revertPlan() == nil)
        arm.requestManagement(.uninstall)
        #expect(arm.managementSheet == .uninstall)

        let intel = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await intel.start()
        AppStore.profileReader = Demo.demoProfile
        defer { AppStore.profileReader = nil }
        intel.requestManagement(.revert)
        #expect(intel.managementSheet == .revert)
        let plan = try #require(intel.revertPlan())
        #expect(plan.edits.count == 1 && plan.edits[0].lines.count == 3)
        #expect(plan.commands.last == "/usr/local/bin/brew update")
    }

    @Test func terminalScriptIsExecutable() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try TerminalScript.write("#!/bin/bash\necho hi\n", name: "revert", in: dir)
        #expect(url.lastPathComponent == "tankard-revert.command")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }
}
