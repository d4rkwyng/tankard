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
    static func quitFromMenu() {
        guard let store, !exempt else {
            closeSheetsAndTerminate()
            return
        }
        switch store.quitStep {
        case .ask(let prompt):
            quitLog.notice("quit from menu: brew is running, asking first")
            guard let choice = ask(prompt) else { return }
            exempt = true
            store.prepareToQuit(choice) {
                quitLog.notice("quit from menu: the run has ended, quitting")
                closeSheetsAndTerminate()
            }
        case .closeSheetsAndQuit:
            closeSheetsAndTerminate()
        }
    }

    /// Closes every sheet (store first, then AppKit), terminates on the
    /// next turns of the run loop, and once more if a sheet still refused
    /// it (the relaunch's sequence, with no helper).
    private static func closeSheetsAndTerminate() {
        quitLog.notice("quit from menu: closing sheets first")
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
                quitLog.error("quit from menu: still running after two terminate attempts")
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
