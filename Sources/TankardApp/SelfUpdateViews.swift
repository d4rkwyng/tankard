import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

// Tankard ▸ Check for Tankard Updates… (TankardAppModel/SelfUpdate.swift).
//
//   TANKARD_UPDATE_FEED=<file>   any mode: GitHub's answer from this file
//                                (missing file: offline), for e2e and shots
//   TANKARD_UPDATE_CHECK=1       check at launch (needs a feed)
//   TANKARD_UPDATE_BREW=1        demo only: act as if the d4rkwyng/tap cask
//                                installed this app

/// The app menu item. A view, so its store reads aren't tracked by App.body.
struct CheckForUpdatesMenuItem: View {
    var store: AppStore

    var body: some View {
        Button("Check for Tankard Updates…") { store.checkForTankardUpdates() }
            .disabled(!store.canCheckForTankardUpdates || store.isSheetPresented)
    }
}

struct SelfUpdateSheet: View {
    var store: AppStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(icon: "arrow.down.app", title: String(localized: "Tankard Updates"),
                        subtitle: String(localized: "You have Tankard \(TankardVersion.string)."))
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        // One fixed size: the sheet opens while checking and must not
        // need to grow when the result (with its notes) arrives.
        .frame(width: 520, height: 430, alignment: .top)
        .background(theme.window ?? .clear)
    }

    @ViewBuilder
    private var content: some View {
        switch store.selfUpdate {
        case .checking?, nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").foregroundStyle(.secondary)
            }
        case .upToDate(let v)?:
            Label {
                // 0.8.6 (walkthrough L4): the subtitle already names the
                // version ("You have Tankard 0.8.5.").
                if v == TankardVersion.string {
                    Text("That's the latest version.")
                } else {
                    Text("Tankard \(v) is the latest version.")
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
        case .available(let r)?:
            Text("Tankard \(r.version) is available.").font(.system(size: 13, weight: .semibold))
            if !r.summary.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Release notes").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Full Release Notes") { if WebURL.isWeb(r.url) { NSWorkspace.shared.open(r.url) } }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help(r.url.absoluteString)
                }
                ScrollView {
                    ReleaseNotesList(summary: r.summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.table ?? Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            }
            if store.tankardCask != nil {
                Text("Homebrew installed this copy, so Homebrew upgrades it, through the queue. Tankard keeps running while brew replaces the app, then offers to relaunch.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Install with Homebrew to get updates automatically:")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                CommandBox(command: "brew install --cask \(UpdateFeed.tapCask)")
            }
        case .failed(let message)?:
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Couldn't check for updates").font(.system(size: 13, weight: .semibold))
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch store.selfUpdate {
            case .available(let r)?:
                Button("Later") { store.closeSelfUpdate() }
                    .keyboardShortcut(.cancelAction)
                if store.tankardCask != nil {
                    Button("Upgrade with Homebrew") { store.upgradeTankardWithBrew(to: r.version) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.isBusy)
                } else {
                    Button("Download") {
                        if WebURL.isWeb(r.url) { NSWorkspace.shared.open(r.url) }
                        store.closeSelfUpdate()
                    }
                    .keyboardShortcut(.defaultAction)
                    .help(r.url.absoluteString)
                }
            case .failed?:
                Button("Close") { store.closeSelfUpdate() }
                    .keyboardShortcut(.cancelAction)
                Button("Retry") { store.checkForTankardUpdates() }
                    .keyboardShortcut(.defaultAction)
            default:
                Button("Done") { store.closeSelfUpdate() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// 0.8.5: the release notes as a list: section headings as small bold
/// labels, one line per change with a hanging indent, then "…and N more".
struct ReleaseNotesList: View {
    var summary: ReleaseNotesSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(summary.items.enumerated()), id: \.offset) { i, item in
                switch item {
                case .heading(let h):
                    Text(h)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, i == 0 ? 0 : 6)
                case .bullet(let b):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•").foregroundStyle(.secondary)
                        Text(b).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                }
            }
            if summary.more > 0 {
                Text(verbatim: "…" + String(localized: "and \(summary.more) more"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .textSelection(.enabled)
    }
}

extension View {
    /// The update sheet, and the relaunch question once the upgrade's
    /// sheet is closed.
    func selfUpdateSheets(store: AppStore, theme: Theme) -> some View {
        self
            .sheet(isPresented: Binding(get: { store.showSelfUpdate },
                                        set: { if !$0 && store.showSelfUpdate { store.closeSelfUpdate() } })) {
                SelfUpdateSheet(store: store).themed(theme)
            }
            .alert(String(localized: "Tankard was upgraded"),
                   isPresented: Binding(get: { store.offerRelaunch && !store.showUpgradeSheet },
                                        set: { if !$0 && store.offerRelaunch { store.offerRelaunch = false } })) {
                Button("Relaunch") { store.relaunchAfterSelfUpgrade() }
                Button("Later", role: .cancel) { store.offerRelaunch = false }
            } message: {
                Text("Relaunch Tankard to use the new version.")
            }
    }
}
