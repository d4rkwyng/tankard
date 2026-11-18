import Foundation
import TankardCore

// 0.8.3: quitting while brew runs, and the run it interrupted.
//
// Quitting Tankard mid-step does NOT leave brew finishing in the
// background: brew writes its progress into Tankard's pipe, and once
// Tankard is gone its next write fails (EPIPE) and brew aborts the step,
// rolling it back (checked on brew 7.0.14: an upgrade whose reader quit
// mid-install left the old version installed and linked). So the quit guard
// offers to wait for the current step, or to stop brew cleanly (SIGINT, as
// Stop Now) before quitting, never to abandon it.
//
// The run journal: the packages an upgrade run set out to upgrade, saved
// when it starts and kept when it doesn't end normally (quit mid-run, a
// crash, a logout). At the next launch, the ones brew still lists as
// upgradable are offered: "Upgrade the remaining N packages", through
// requestUpgrade (the compile plan, pins and rules apply again). A run that
// ends in Tankard, even stopped, clears it.
//
// 0.8.4: an automatic run (AutoUpdate.swift) asks the same way while it is
// on an upgrade step. It writes no run journal and the next launch offers
// nothing: the automatic run is unattended, so a sheet at the next launch
// would ask about a run nobody started. Its own log records the stop
// (each step not run: "Tankard quit; the next automatic run upgrades it"),
// and the interrupted slot opens again, so the scheduler runs it at the
// next launch once its conditions hold (startup delay, AC power, idle),
// with a fresh brew update and safe-mode plan.

/// The upgrade run a quit interrupted (JSON in the settings' defaults).
public struct RunJournal: Codable, Equatable, Sendable {
    /// Full names (tap-qualified where brew gives one) of the run's packages.
    public var targets: [String]
    /// How many of them had finished when Tankard quit (nil: unknown, a crash).
    public var finished: Int?
    public var savedAt: Date

    static let key = "interruptedRunJournal"

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data) -> RunJournal? { try? JSONDecoder().decode(RunJournal.self, from: data) }

    /// The journal's packages that `upgradable` still lists, in its order.
    func remaining(in upgradable: [Package]) -> [Package] {
        let names = Set(targets)
        return upgradable.filter { names.contains($0.fullName) || names.contains($0.name) }
    }
}

/// "Upgrade the remaining N packages" after an interrupted run.
public struct InterruptedRunOffer: Equatable, Sendable {
    public var packages: [Package]
    /// How many the run had in all.
    public var total: Int
}

/// What the quit alert says: "Homebrew is still upgrading xz (3 of 7)."
public struct QuitPrompt: Equatable, Sendable {
    public var name: String
    public var index: Int
    public var total: Int

    public var isUpgrade: Bool
    /// 0.8.4: an automatic update's step.
    public var isAutomatic = false
    public var message: String {
        if isAutomatic {
            return total > 1 ? String(localized: "Tankard is upgrading \(name) automatically (\(index) of \(total)).")
                : String(localized: "Tankard is upgrading \(name) automatically.")
        }
        if isUpgrade {
            return total > 1 ? String(localized: "Homebrew is still upgrading \(name) (\(index) of \(total)).")
                : String(localized: "Homebrew is still upgrading \(name).")
        }
        return total > 1 ? String(localized: "Homebrew is still working on \(name) (\(index) of \(total)).")
            : String(localized: "Homebrew is still working on \(name).")
    }
    public var detail: String {
        isAutomatic ? String(localized: "Quitting now stops it: Homebrew undoes the unfinished step. The next automatic run upgrades what's left.")
            : total > 1 && isUpgrade ? String(localized: "Quitting now stops it: Homebrew undoes the unfinished step, and the rest won't run. Tankard offers to upgrade what's left next time.")
            : total > 1 ? String(localized: "Quitting now stops it: Homebrew undoes the unfinished step, and the rest won't run.")
            : String(localized: "Quitting now stops it: Homebrew undoes the unfinished step.")
    }
}

public enum QuitChoice: Sendable {
    /// Let the running step finish, skip the rest, then quit.
    case afterCurrent
    /// Stop brew now (as Stop Now), then quit once it has stopped.
    case now
}

extension AppStore {
    /// Non-nil when quitting would interrupt brew: the sheet's run is going,
    /// or (0.8.4) an automatic run is on an upgrade step.
    public var quitPrompt: QuitPrompt? {
        if autoUpdate.isRunning, !autoUpdate.quitRequested, let step = autoUpdate.step {
            return QuitPrompt(name: step.name, index: step.index, total: step.total, isUpgrade: true, isAutomatic: true)
        }
        guard let s = upgrade, !s.isFinished else { return nil }
        let c = s.current ?? s.items.first { $0.state == .waiting }
        guard let c else { return nil }
        let index = (s.items.firstIndex { $0.id == c.id } ?? 0) + 1
        return QuitPrompt(name: c.package.name, index: index, total: s.total, isUpgrade: s.action == .upgrade)
    }

    /// The quit alert's choice: keep the journal, stop, and call `done` once
    /// the run has ended (Tankard then quits). Quit Now gives brew up to
    /// `stopLimit` to wind down (its own SIGTERM/SIGKILL steps are within it).
    public func prepareToQuit(_ choice: QuitChoice, stopLimit: Duration = .seconds(35),
                              done: @escaping @MainActor () -> Void) {
        let deadline: ContinuousClock.Instant? = choice == .now ? .now + stopLimit : nil
        // 0.8.4: an automatic run: no journal (see the top of this file).
        if autoUpdate.isRunning, autoUpdate.step != nil {
            autoUpdate.stopForQuit(choice, queue: queue)
            Task { @MainActor in
                while self.autoUpdate.isRunning {
                    if let deadline, ContinuousClock.now > deadline { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                done()
            }
            return
        }
        guard let s = upgrade, !s.isFinished else { done(); return }
        quittingMidRun = true
        switch choice {
        case .afterCurrent: s.stopAfterCurrent()
        case .now: s.stopNow()
        }
        Task { @MainActor in
            while !s.isFinished {
                if let deadline, ContinuousClock.now > deadline { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            done()
        }
    }

    // MARK: the journal

    func saveRunJournal(_ targets: [Package]) {
        quittingMidRun = false
        let j = RunJournal(targets: targets.map(\.fullName), finished: nil, savedAt: deps.now())
        settings.defaults.set(j.encoded(), forKey: RunJournal.key)
    }

    /// A run ended in Tankard: clear the journal, unless it ended because
    /// Tankard is quitting (then it keeps the packages not upgraded).
    func runJournalSessionFinished(_ session: UpgradeSession) {
        guard session.action == .upgrade else { return }
        guard quittingMidRun else {
            settings.defaults.removeObject(forKey: RunJournal.key)
            return
        }
        let left = session.items.filter { $0.state != .done }.map(\.package)
        guard !left.isEmpty else {
            settings.defaults.removeObject(forKey: RunJournal.key)
            return
        }
        let j = RunJournal(targets: left.map(\.fullName), finished: session.succeededCount, savedAt: deps.now())
        settings.defaults.set(j.encoded(), forKey: RunJournal.key)
    }

    /// After the first fresh read at launch: offer the interrupted run's
    /// packages brew still lists as upgradable. Read once.
    @discardableResult
    func offerInterruptedRun() -> Bool {
        // This process's own run keeps its journal until it ends (and when
        // it ends for a quit, the journal is for the next launch).
        guard !quittingMidRun, !isUpgrading, let data = settings.defaults.data(forKey: RunJournal.key) else { return false }
        settings.defaults.removeObject(forKey: RunJournal.key)
        guard upgradePlan == nil, appManagementPrompt == nil, appManagementResume == nil,
              let j = RunJournal.decode(data) else { return false }
        let left = j.remaining(in: upgradable.filter(\.isManualUpgradeTarget))
        guard !left.isEmpty else { return false }
        interruptedRun = InterruptedRunOffer(packages: left, total: j.targets.count + (j.finished ?? 0))
        showUpgradeSheet = true
        return true
    }

    /// "Upgrade the Remaining N": the Upgrade button's path, gates on.
    public func interruptedRunConfirm() {
        guard let offer = interruptedRun else { return }
        interruptedRun = nil
        showUpgradeSheet = false
        requestUpgrade(offer.packages)
    }

    public func interruptedRunDismiss() {
        interruptedRun = nil
        if upgrade == nil || upgrade?.isFinished == true { showUpgradeSheet = false }
    }
}
