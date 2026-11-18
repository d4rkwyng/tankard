import SwiftUI
import TankardAppModel
import TankardCore

// The Vulnerable filter (More ▸ Vulnerable) offers the scan where the list
// is: a header with the last result and Scan Now (or the running scan's
// progress and Stop), and an empty state with Scan Now when the list is
// empty. Same scan, state and rules as Homebrew ▸ Scan for Vulnerabilities.
//
//   TANKARD_FILTER=vulnerable        open on the filter
//   TANKARD_DEMO_SCAN=off            demo only: no scan at all (not scanned yet)
//   TANKARD_DEMO_SCAN=slow           demo only: a 30 s scan at launch (scanning)

extension AppStore {
    var vulnerableScanStatus: VulnerableScanStatus {
        VulnerableScanStatus(state: insights.scanState, scan: insights.vulnerabilityScan)
    }

    var canScanVulnerabilities: Bool {
        VulnerableScanStatus.canScan(state: insights.scanState, hasReport: report != nil)
    }
}

/// The header above the list while the Vulnerable filter is on.
struct VulnerableScanBar: View {
    var store: AppStore
    @Environment(\.theme) private var theme

    var body: some View {
        let status = store.vulnerableScanStatus
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if status == .running {
                // Spinner, "Scanning N formulae…", elapsed time and Stop.
                ScanProgressView(store: store, showOutcome: false)
                Spacer(minLength: 8)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(status.line(now: ctx.date) ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(help(status))
                .layoutPriority(-1)
                Spacer(minLength: 8)
                ScanNowButton(store: store)
            }
            // Upgrade N: here rather than in the summary strip, which then
            // keeps room for its summary in narrow windows and long languages.
            VulnerableFilterActions(store: store)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .frame(minHeight: 30)
        .background(theme.strip)
    }

    private func help(_ status: VulnerableScanStatus) -> String {
        switch status {
        case .scanned(_, _, let complete, let reason, _):
            return complete ? String(localized: "From brew vulns (OSV.dev).")
                : (reason.map { String(localized: "brew says the scan is incomplete: \($0).") } ?? "")
        case .failed(let s, _), .unsupported(let s): return s
        default: return InsightSettings.scanPrivacyNote
        }
    }
}

/// Scan Now: the Homebrew menu's Scan for Vulnerabilities.
struct ScanNowButton: View {
    var store: AppStore

    var body: some View {
        Button("Scan Now") { store.scanVulnerabilitiesNow() }
            .controlSize(.small)
            .disabled(!store.canScanVulnerabilities)
            .help(String(localized: "Checks for known security problems once now.") + " " + InsightSettings.scanPrivacyNote)
            .fixedSize()
    }
}

/// The Vulnerable filter's empty list: why it is empty, with Scan Now.
struct VulnerableEmptyState: View {
    var store: AppStore

    var body: some View {
        let status = store.vulnerableScanStatus
        ContentUnavailableView {
            Label {
                Text(status.emptyTitle)
            } icon: {
                if status == .running {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: status == .notScanned ? "shield" : "checkmark.shield")
                }
            }
        } description: {
            Text(status.emptyMessage(now: Date()))
        } actions: {
            if status != .running {
                Button("Scan Now") { store.scanVulnerabilitiesNow() }
                    .disabled(!store.canScanVulnerabilities)
                    .help(String(localized: "Checks for known security problems once now.") + " " + InsightSettings.scanPrivacyNote)
            }
        }
    }
}
