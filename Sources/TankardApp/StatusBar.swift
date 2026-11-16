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
                                  + (store.reportFromCache ? " (from cache)" : ""))
                    }
                }
                if let phase = store.refreshPhase {
                    separator
                    ProgressView().controlSize(.mini)
                    Text(phase)
                } else if store.error != nil {
                    separator
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Last refresh failed")
                }
            } else if let phase = store.refreshPhase {
                ProgressView().controlSize(.mini)
                Text(phase)
            }
            Spacer()
            if let session = store.upgrade, !store.showUpgradeSheet {
                Button {
                    store.showUpgradeSheet = true
                } label: {
                    if session.isFinished {
                        Label(session.title, systemImage: session.failedItems.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Upgrading \(session.countLine)")
                        }
                    }
                }
                .controlSize(.small)
            }
            let n = store.upgradable.count
            Button {
                store.startUpgrade()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                    Text("Upgrade")
                    if n > 0 {
                        Text("\(n)")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6)
                            .background(Capsule().fill((theme.isTankard ? theme.onAccent : Color.white).opacity(0.22)))
                    }
                }
                .fontWeight(.semibold)
                .modifier(OnAccentLabel(theme: theme))
            }
            .buttonStyle(.borderedProminent)
            .disabled(n == 0 || store.isUpgrading || store.isRefreshing)
            .help(n == 0 ? "Nothing to upgrade" : "brew upgrade the \(n) outdated package\(n == 1 ? "" : "s"), one at a time")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 44)
        .background(theme.bar)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private func color(_ l: ForkSummary.Level) -> Color {
        switch l {
        case .ok: return theme.badge(.bottle).dot
        case .warning: return .orange
        case .problem: return .red
        }
    }
}

/// Tankard's prominent buttons are amber, so their labels are dark; other
/// themes keep the system's label colour.
struct OnAccentLabel: ViewModifier {
    var theme: Theme
    func body(content: Content) -> some View {
        if theme.isTankard { content.foregroundStyle(theme.onAccent) } else { content }
    }
}
