import SwiftUI
import TankardAppModel
import TankardCore

// v0.6 (part B): the views for skip this version, snooze and bump rules.
// Short labels; the details are in tooltips.

/// The detail pane's "Skip This Version" / "Don't Skip", under Upgrade.
struct SkipVersionRow: View {
    var skipped: Bool
    var version: String
    var toggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if skipped {
                Label("Skipping \(version)", systemImage: "forward.end")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityLabel("Version \(version) is skipped")
                Spacer(minLength: 0)
                Button("Don't Skip") { toggle(false) }
                    .controlSize(.small)
                    .help("Count \(version) as an upgrade again")
            } else {
                Button("Skip This Version") { toggle(true) }
                    .controlSize(.small)
                    .help("Leave \(version) out of Upgrade all, the counts and auto-update. Upgrade still works by hand; a newer version clears this.")
            }
        }
    }
}

/// Settings: the bump rule and the snooze.
struct AutoUpdateRulesRows: View {
    @Bindable var rules: UpgradeRulesSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ExplainedRow(help: SettingsHelp.bumpRule) {
                Picker("Automatically upgrade:", selection: $rules.bumpRule) {
                    ForEach(BumpRule.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
            }
            AutoUpdateSnoozeControl(rules: rules)
        }
    }
}

/// "Snooze ▾" (1 day, 1 week, until turned back on) or "Resume".
struct AutoUpdateSnoozeControl: View {
    var rules: UpgradeRulesSettings

    var body: some View {
        let now = Date()
        HStack(spacing: 8) {
            if rules.isSnoozed(now: now) {
                Text(AutoUpdateText.snoozed(until: rules.snoozeEnds, now: now))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Resume") { rules.resume() }
                    .controlSize(.small)
                    .help("Turn automatic updates back on now")
            } else {
                Menu("Snooze") {
                    ForEach(SnoozeLength.allCases) { length in
                        Button(length.title) { rules.snooze(length, now: Date()) }
                    }
                }
                .fixedSize()
                .controlSize(.small)
                .help("Pause automatic updates. Manual upgrades still work.")
            }
        }
    }
}

/// The menu bar's snooze row, shown while auto-update is on.
struct AutoUpdateSnoozeMenuRow: View {
    var updater: AutoUpdater

    var body: some View {
        if updater.settings.enabled {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                    .accessibilityHidden(true)
                Text("Auto-update").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                AutoUpdateSnoozeControl(rules: updater.rules)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}
