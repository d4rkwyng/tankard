import AppKit
import os
import SwiftUI
import TankardAppModel

// 0.8.3: ⌘Q, Quit Tankard in the menu-bar panel, or a logout while brew
// runs asks first (QuitGuard.swift in TankardAppModel says why quitting
// can't leave brew finishing in the background).

private let quitLog = Logger(subsystem: "net.mindtricks.tankard", category: "quit")

@MainActor
enum QuitGuard {
    static var store: AppStore?
    /// Set by a quit that must not ask (the App Management relaunch, which
    /// only runs while nothing does).
    static var exempt = false

    /// 0.8.6: Tankard ▸ Quit Tankard (⌘Q) and the menu-bar panel's Quit.
    /// AppKit refuses to terminate while a sheet is attached ("App
    /// termination blocked by modal sheet"), and it refuses before it asks
    /// applicationShouldTerminate, so neither the guard's question nor a
    /// plain quit got anywhere over a sheet.
    /// 0.8.8 (gauntlets 15 and 26): ⌘Q over a run's sheet, or over a
    /// finished "Install complete" or Post-install notes sheet, did
    /// nothing. With brew running, the guard asks here (`AppStore.quitStep`);
    /// then, or with nothing running, every sheet is closed in the store
    /// (so SwiftUI doesn't put it back) and in AppKit, and Tankard quits.
    static func quitFromMenu() { quit(.menu) }

    /// 0.8.8 (final gauntlet, bug 1): every quit, from the menu or from
    /// outside (the quit Apple Event: the Dock, AppleScript, a logout,
    /// restart or shutdown; `handleQuitEvent`), decided here
    /// (QuitDecision). `decided(true)`: Tankard is quitting now (after the
    /// run, when the question was asked); `decided(false)`: Keep Running.
    static func quit(_ source: QuitSource, decided: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let sheetOpen = NSApp.windows.contains { $0.attachedSheet != nil }
        let step = exempt ? nil : store?.quitStep
        let decision = QuitDecision.decide(source, step: step, sheetOpen: sheetOpen)
        let from: String
        switch source {
        case .menu: from = "menu"
        case .appleEvent(let reason): from = "quit event (\(reason.logName))"
        }
        switch decision {
        case .ask(let prompt, let bringForward):
            quitLog.notice("quit from \(from, privacy: .public): brew is running, asking first")
            if bringForward { NSApp.activate(ignoringOtherApps: true) }
            guard let store, let choice = ask(prompt) else {
                quitLog.notice("quit from \(from, privacy: .public): Keep Running")
                decided(false)
                return
            }
            exempt = true
            store.prepareToQuit(choice) {
                quitLog.notice("quit from \(from, privacy: .public): the run has ended, quitting")
                decided(true)
                closeSheetsAndTerminate()
            }
        case .closeSheetsAndQuit:
            quitLog.notice("quit from \(from, privacy: .public): sheet open \(sheetOpen, privacy: .public)")
            decided(true)
            closeSheetsAndTerminate()
        }
    }

    /// 0.8.8: the quit Apple Event (kCoreEventClass/kAEQuitApplication),
    /// installed by AppDelegate.applicationWillFinishLaunching in place of
    /// AppKit's, which refused under a sheet (-128, "App termination
    /// blocked by modal sheet"). The event is suspended while Tankard
    /// decides, so the sender (AppleScript, loginwindow) hears back only
    /// then: no error once Tankard is quitting, -128 after Keep Running,
    /// as AppKit answers a cancelled quit.
    static func handleQuitEvent(reasonCode: UInt32?) {
        let manager = NSAppleEventManager.shared()
        nonisolated(unsafe) let suspension = manager.suspendCurrentAppleEvent()
        let reason = QuitEventReason(code: reasonCode)
        // Out of the event handler before any alert or terminate.
        // 0.8.9 (confirm run on 15, MED): as a run-loop block, not a
        // main-actor Task: the alert's modal loop inside a Task (a
        // main-queue job) held up every other main-actor job, so the run's
        // sheet froze and its events waited until the alert closed
        // (RunLoopPerform).
        RunLoopPerform.onMain {
            quit(.appleEvent(reason)) { quitting in
                guard let suspension else { return }
                if !quitting {
                    manager.replyAppleEvent(forSuspensionID: suspension)
                        .setParam(NSAppleEventDescriptor(int32: QuitDecision.cancelledReplyError),
                                  forKeyword: AEKeyword(keyErrorNumber))
                }
                manager.resume(withSuspensionID: suspension)
            }
        }
    }

    /// Closes every sheet (store first, then AppKit), terminates on the
    /// next turns of the run loop, and once more if a sheet still refused
    /// it (the relaunch's sequence, with no helper).
    private static func closeSheetsAndTerminate() {
        quitLog.notice("quit: closing sheets first")
        _ = RelaunchSequence(
            startHelper: { true },
            closeSheets: Relauncher.closeSheets,
            terminate: {
                exempt = true
                NSApp.terminate(nil)
            },
            after: { delay, work in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    work()
                }
            },
            gaveUp: {
                quitLog.error("quit: still running after two terminate attempts")
                exempt = false
                store?.terminationCancelled()
            }).run()
    }

    /// The guard's question. nil: Keep Running.
    private static func ask(_ prompt: QuitPrompt) -> QuitChoice? {
        let alert = NSAlert()
        alert.messageText = prompt.message + " " + String(localized: "Quit anyway?")
        alert.informativeText = prompt.detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Keep Running"))
        alert.addButton(withTitle: String(localized: "Stop After Current and Quit"))
        alert.addButton(withTitle: String(localized: "Quit Now"))
        alert.buttons.last?.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .afterCurrent
        case .alertThirdButtonReturn: return .now
        default: return nil
        }
    }

    /// A quit that didn't come from the menu (the Dock, a logout): AppKit
    /// asks here when no sheet is attached.
    static func shouldTerminate() -> NSApplication.TerminateReply {
        guard !exempt, let store, let prompt = store.quitPrompt else { return .terminateNow }
        guard let choice = ask(prompt) else { return .terminateCancel }
        store.prepareToQuit(choice) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// "Upgrade the remaining N packages" at the launch after an interrupted run.
struct InterruptedRunSheet: View {
    @Bindable var store: AppStore
    var offer: InterruptedRunOffer
    @Environment(\.theme) private var theme

    var body: some View {
        let n = offer.packages.count
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                BrandMark(size: 64, intelbrew: store.intelbrewMode)
                VStack(alignment: .leading, spacing: 4) {
                    Text("The last upgrade didn't finish")
                        .font(.system(size: 15, weight: .bold))
                    Text(offer.total > n
                         ? String(localized: "Tankard quit after \(offer.total - n) of \(offer.total). Still to upgrade: \(offer.packages.map(\.name).joined(separator: ", ")).")
                         : String(localized: "Still to upgrade: \(offer.packages.map(\.name).joined(separator: ", "))."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Not Now") { store.interruptedRunDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    store.interruptedRunConfirm()
                } label: {
                    Text(n == 1 ? String(localized: "Upgrade the Remaining Package") : String(localized: "Upgrade the Remaining \(n) Packages"))
                        .fontWeight(.semibold).modifier(OnAccentLabel(theme: theme))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(theme.window ?? .clear)
    }
}
