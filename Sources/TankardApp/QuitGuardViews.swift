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
    /// termination blocked by modal sheet"), so ⌘Q did nothing over the
    /// Welcome sheet. With no brew running (nothing for the guard to ask
    /// about), the sheets are closed first; with brew running, quitting
    /// goes to the guard as before.
    static func quitFromMenu() {
        guard exempt || store?.quitPrompt == nil else {
            NSApp.terminate(nil)
            return
        }
        quitLog.notice("quit from menu: closing sheets first")
        // SwiftUI presents the sheets from the store's state: clear it, so
        // a sheet ended by AppKit isn't put back, then end what is attached.
        store?.closeToolSheet()
        Relauncher.closeSheets()
        // Terminate once the sheet is gone (SwiftUI removes it on the next
        // turns of the run loop).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    static func shouldTerminate() -> NSApplication.TerminateReply {
        guard !exempt, let store, let prompt = store.quitPrompt else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = prompt.message + " " + String(localized: "Quit anyway?")
        alert.informativeText = prompt.detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Keep Running"))
        alert.addButton(withTitle: String(localized: "Stop After Current and Quit"))
        alert.addButton(withTitle: String(localized: "Quit Now"))
        alert.buttons.last?.hasDestructiveAction = true
        let choice: QuitChoice
        switch alert.runModal() {
        case .alertSecondButtonReturn: choice = .afterCurrent
        case .alertThirdButtonReturn: choice = .now
        default: return .terminateCancel
        }
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
