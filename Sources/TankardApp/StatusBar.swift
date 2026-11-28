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
                } else if store.error?.fromRefresh == true {
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
            if store.insights.scanState == .running || store.insights.shownScanOutcome != nil {
                if store.report != nil || store.refreshPhase != nil { separator }
                ScanProgressView(store: store)
            }
            if let notice = store.busyNotice {
                separator
                Image(systemName: "hourglass").foregroundStyle(.orange)
                    .accessibilityHidden(true) // 0.9.3: decoration; the notice says it
                Text(notice).lineLimit(1).truncationMode(.middle).help(notice)
            }
            Spacer()
            // 0.8.5: also while it is in the progress panel: a click
            // moves it to this window's sheet.
            if store.upgrade == nil, store.upgradePlan != nil, store.showsProgressPanel {
                // 0.8.5 review: a plan waiting in the progress panel.
                Button {
                    store.showActivity(windowInFront: true)
                } label: {
                    Label(store.activityMenuTitle, systemImage: "list.bullet")
                }
                .controlSize(.small)
            }
            if let session = store.upgrade, !store.showsActivitySheet {
                Button {
                    store.showActivity(windowInFront: true)
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
            // 0.9.4: one button for both: every upgrade (the count pill),
            // or only the selected rows' ("Upgrade N Selected").
            let button = store.upgradeBarButton
            if let note = store.pinnedUpgradeNote {
                Label(note, systemImage: "pin").lineLimit(1).help("Pinned packages stay at their version. Unpin one to include it.")
            }
            Button {
                store.upgradeFromBar()
            } label: {
                HStack(spacing: 6) {
                    // 0.8.8 (gauntlet 3, B7): the icons are decoration
                    // (VoiceOver read the check as "selected").
                    if button.isUpToDate {
                        Image(systemName: "checkmark").accessibilityHidden(true)
                        Text(button.title)
                    } else {
                        Image(systemName: "arrow.up").accessibilityHidden(true)
                        Text(button.title)
                        if button.showsCountPill { ActionCountPill(count: button.count) }
                    }
                }
            }
            .buttonStyle(.primaryAction)
            .disabled(button.isUpToDate || store.windowBrewActionsBlocked || store.isRefreshing)
            .help(button.help)
            .accessibilityLabel(Text(button.accessibilityLabel))
            .accessibilityIdentifier(AccessibilityText.ID.upgradeBar)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 44)
        .background(theme.bar)
    }

    /// 0.9.3: for the eye only, hidden from VoiceOver (otherwise each
    /// dot is a text element of its own between the status bar's parts).
    private var separator: some View {
        Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
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
