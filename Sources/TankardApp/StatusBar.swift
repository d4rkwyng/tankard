import SwiftUI
import TankardAppModel
import TankardCore

struct StatusBar: View {
    @Bindable var store: AppStore
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if let report = store.report {
                if store.intelbrewMode {
                    let fork = ForkSummary(report.fork)
                    Circle().fill(color(fork.level)).frame(width: 7, height: 7)
                    Text(fork.text).help(fork.help)
                    separator
                }
                if let updated = store.lastUpdated {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text("Updated \(updatedAgo(updated, now: ctx.date))")
                            .help(updated.formatted(date: .abbreviated, time: .standard)
                                  + (store.reportFromCache ? String(localized: " (from cache)") : ""))
                    }
                }
                if let phase = store.refreshPhase {
                    separator
                    ProgressView().controlSize(.mini)
                    Text(phase)
                } else if store.backgroundUpdating {
                    // 0.8: the background brew update, kept quiet.
                    separator
                    ProgressView().controlSize(.mini)
                    Text("Checking for updates…").foregroundStyle(.tertiary)
                        .help(SettingsHelp.backgroundUpdate)
                } else if let note = store.checkNote {
                    // 0.8.2: what the Refresh just found (UserCheckFeedback).
                    separator
                    Text(note).lineLimit(1).truncationMode(.tail).help(note)
                } else if store.error != nil {
                    separator
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Last refresh failed")
                }
            } else if let phase = store.refreshPhase {
                ProgressView().controlSize(.mini)
                Text(phase)
            }
            // Vulnerability scan progress lives here (not in the filter row,
            // where it squeezed the summary).
            if store.insights.scanState == .running || store.insights.scanOutcome != nil {
                if store.report != nil || store.refreshPhase != nil { separator }
                ScanProgressView(store: store)
            }
            if let notice = store.busyNotice {
                separator
                Image(systemName: "hourglass").foregroundStyle(.orange)
                Text(notice).lineLimit(1).truncationMode(.middle).help(notice)
            }
            Spacer()
            if let session = store.upgrade, !store.showUpgradeSheet {
                Button {
                    store.showUpgradeSheet = true
                } label: {
                    if session.isFinished {
                        Label(session.title, systemImage: !session.hasProblems ? "checkmark.circle" : "exclamationmark.triangle")
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(verbatim: "\(session.action.gerund) \(session.countLine)")
                        }
                    }
                }
                .controlSize(.small)
            }
            let n = store.upgradable.count
            if let note = store.pinnedUpgradeNote {
                Label(note, systemImage: "pin").lineLimit(1).help("Pinned packages aren't upgraded: brew upgrade skips them. Unpin one to include it.")
            }
            Button {
                store.requestUpgrade()
            } label: {
                HStack(spacing: 6) {
                    if n == 0 {
                        Image(systemName: "checkmark")
                        Text("Up to date")
                    } else {
                        Image(systemName: "arrow.up")
                        Text("Upgrade")
                        ActionCountPill(count: n)
                    }
                }
            }
            .buttonStyle(.primaryAction)
            .disabled(n == 0 || store.isUpgrading || store.isRefreshing)
            .help(n == 0 ? String(localized: "Nothing to upgrade") : (n == 1 ? String(localized: "brew upgrade the 1 outdated package, one at a time") : String(localized: "brew upgrade the \(n) outdated packages, one at a time")))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 44)
        .background(theme.bar)
    }

    private var separator: some View {
        Text(verbatim: "·").foregroundStyle(.tertiary)
    }

    private func color(_ l: ForkSummary.Level) -> Color {
        switch l {
        case .ok: return theme.badge(.bottle).dot
        case .warning: return .orange
        case .problem: return .red
        }
    }
}

/// The palette themes' prominent buttons are accent-filled (amber, purple)
/// with dark labels; other themes keep the system's label colour.
struct OnAccentLabel: ViewModifier {
    var theme: Theme
    func body(content: Content) -> some View {
        if theme.isCustom { content.foregroundStyle(theme.onAccent) } else { content }
    }
}
