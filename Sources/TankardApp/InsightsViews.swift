import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

// v0.4 (part B): the views for vulnerabilities, caveats, disk usage and
// the upgrade settings. The shared views (ContentView, DetailPane) only
// place these.

extension Theme {
    /// The vulnerability warning's colours for this theme.
    func warning(_ scheme: ColorScheme) -> (text: Color, tag: Color) {
        let s = VulnerabilityColors.style(kind, dark: scheme == .dark)
        return (Color(hex: s.text), Color(hex: s.tint, alpha: s.tintAlpha))
    }
}

/// The table's ⚠ tag next to a vulnerable formula's name: "⚠ High · 3".
struct VulnerabilityTag: View {
    var package: Package
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let label = package.vulnerabilityBadge {
            let w = theme.warning(scheme)
            let selected = prominence == .increased && !theme.isCustom
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8.5))
                Text(label)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(selected ? Color.white : w.text)
            .padding(.horizontal, 4).padding(.vertical, 0.5)
            .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.white.opacity(0.16) : w.tag))
            .fixedSize()
            .help(VulnerabilityText.help(package))
            .accessibilityLabel("Vulnerable: \(label)")
        }
    }
}

enum VulnerabilityText {
    /// "2 known vulnerabilities (High): CVE-…, CVE-…"
    static func help(_ p: Package) -> String {
        let list = p.vulnerabilities ?? []
        let ids = list.prefix(4).map(\.id).joined(separator: ", ") + (list.count > 4 ? ", …" : "")
        return "\(list.count) known vulnerabilit\(list.count == 1 ? "y" : "ies") (brew vulns): \(ids)"
    }

    /// "Scanned 5 min ago · partial scan".
    static func scanLine(_ scan: VulnerabilityScan) -> String {
        "Scanned \(updatedAgo(scan.scannedAt, now: Date()))" + (scan.complete ? "" : " · partial scan")
    }
}

/// The Size column: brew's own measurement.
struct SizeCell: View {
    var package: Package

    var body: some View {
        if let b = package.diskBytes {
            VersionText(text: DiskSizes.format(b), same: true)
        } else {
            VersionText(text: "–", same: true)
        }
    }
}

/// The filters that don't fit the segmented control (Pinned, Requested
/// only, Vulnerable, Has notes) and the vulnerability scan, as a menu next
/// to it. When one of them is the filter, the button shows it as selected.
struct MoreFiltersMenu: View {
    @Bindable var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let active = PackageFilter.more.contains(store.filter)
        let vulnerable = store.count(.vulnerable)
        Menu {
            ForEach(PackageFilter.more) { f in
                Button {
                    store.filter = f
                } label: {
                    if store.filter == f {
                        Label("\(f.title)  \(store.count(f))", systemImage: "checkmark")
                    } else {
                        Text("\(f.title)  \(store.count(f))")
                    }
                }
            }
            Divider()
            if let scan = store.insights.vulnerabilityScan {
                // brew reports "complete": false whenever it skipped anything.
                Text("Vulnerabilities: " + VulnerabilityText.scanLine(scan))
                if let reason = scan.partialReason { Text(reason) }
            }
            Button("Scan for Vulnerabilities Now") { store.scanVulnerabilitiesNow() }
                .disabled(store.insights.scanState == .running || store.report == nil)
        } label: {
            HStack(spacing: 4) {
                if vulnerable > 0 && !active {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning(scheme).text)
                }
                Text(active ? "\(store.filter.title)  \(store.count(store.filter))" : (vulnerable > 0 ? "\(vulnerable)" : "More"))
                    .fontWeight(active ? .semibold : .regular)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12))
            .foregroundStyle(active ? theme.onAccent : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? theme.accent : Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(vulnerable > 0 ? "\(vulnerable) vulnerable package\(vulnerable == 1 ? "" : "s"); more filters" : "More filters: Pinned (packages brew won't upgrade), Requested only (what you installed yourself that nothing else needs, brew leaves -r), Vulnerable, Has notes")
    }
}

/// The summary strip's size total: "· 4.1 GB on disk".
struct DiskTotalText: View {
    var store: AppStore

    var body: some View {
        if let total = store.totalDiskBytes {
            Text("· \(DiskSizes.format(total)) on disk")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
                .help("brew info --sizes: kegs and Caskroom folders (apps through their links)")
        } else if store.insights.sizesState == .running {
            Text("· measuring…").foregroundStyle(.tertiary).lineLimit(1).layoutPriority(-1)
        }
    }
}

/// Filter actions for Vulnerable: Upgrade vulnerable packages (green, the
/// normal upgrade path) and the scan's state.
struct VulnerableFilterActions: View {
    @Bindable var store: AppStore
    @Environment(\.theme) private var theme

    var body: some View {
        let targets = store.vulnerableUpgradeTargets
        let scan = store.insights.vulnerabilityScan
        // Compact: the strip also holds the summary, the segments and the menu.
        HStack(spacing: 8) {
            if store.count(.vulnerable) > 0 {
                Button {
                    store.upgradeVulnerable()
                } label: {
                    Label("Upgrade \(targets.count)", systemImage: "arrow.up")
                        .lineLimit(1)
                }
                .buttonStyle(.primaryAction)
                .disabled(targets.isEmpty || store.isUpgrading || store.isRefreshing)
                .help("Upgrade vulnerable packages. " + upgradeHelp(targets)
                      + (scan?.partialReason.map { " Partial scan: \($0)." } ?? ""))
            } else {
                ScanStateLabel(insights: store.insights)
            }
        }
        .fixedSize()
    }

    private func upgradeHelp(_ targets: [Package]) -> String {
        let none = VulnerabilityUpgrades.withoutUpgrade(store.packages)
        var s = targets.isEmpty ? "No vulnerable package has an upgrade yet." : "Upgrade \(targets.map(\.name).joined(separator: ", "))."
        if !none.isEmpty { s += " No upgrade yet for \(none.map(\.name).joined(separator: ", "))." }
        return s
    }
}

/// "Partial scan · 5 min ago", "Scanning…", or what went wrong, with Scan now.
struct ScanStateLabel: View {
    var insights: InsightsStore

    var body: some View {
        HStack(spacing: 5) {
            switch insights.scanState {
            case .running:
                ProgressView().controlSize(.mini)
                Text("Scanning…")
            case .failed(let s):
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(s == InsightsStore.scanTimedOutMessage ? "Scan timed out" : "Scan failed").help(s)
            case .unsupported(let s):
                Text("No brew vulns").help(s)
            case .idle:
                if let scan = insights.vulnerabilityScan {
                    Text(scan.complete ? "Full scan" : "Partial scan")
                        .help(scan.partialReason.map { "brew says the scan is incomplete: \($0)." } ?? "brew checked every installed formula.")
                } else {
                    Text("Not scanned yet")
                        .help("Scan for Vulnerabilities Now is in the filter menu. " + InsightSettings.scanPrivacyNote)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

// MARK: detail pane

/// The detail pane's vulnerability list: severity, linked advisory ids,
/// brew's summary and "fixed in".
struct VulnerabilitySection: View {
    var package: Package
    var scan: VulnerabilityScan?
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let list = package.vulnerabilities, !list.isEmpty {
            let w = theme.warning(scheme)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(list.count) known vulnerabilit\(list.count == 1 ? "y" : "ies")")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(w.text)
                ForEach(list) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let url = v.url {
                                Link(v.id, destination: url)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .help(url.absoluteString)
                            } else {
                                Text(v.id).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            }
                            Text(v.severity.label)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(v.severity >= .high ? w.text : Color.secondary)
                        }
                        if let summary = v.summary {
                            Text(summary).font(.system(size: 11)).lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(v.fixText).font(.system(size: 11)).foregroundStyle(.secondary)
                            .help(v.fixedIn.joined(separator: "\n"))
                    }
                }
                if let scan {
                    Text(VulnerabilityText.scanLine(scan) + ". From brew vulns (OSV.dev).")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .help(scan.partialReason ?? "")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(w.tag))
        } else if package.kind == .formula, let scan {
            let note: String = {
                if scan.skipped.contains(package.fullName) { return "Not checked by brew vulns: no source repository it can match." }
                if let reason = scan.unscanned[package.fullName] {
                    return reason == "untrusted_tap" ? "Not checked by brew vulns: untrusted tap." : "Not checked by brew vulns."
                }
                return "No known vulnerabilities (brew vulns)."
            }()
            Label(note, systemImage: "checkmark.shield")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// brew's caveats for the package, collapsible, with this Mac's prefix.
struct CaveatsSection: View {
    var package: Package
    var prefix: String?
    private let expanded = State(initialValue: true)

    var body: some View {
        if let raw = package.caveats {
            let text = Caveats.display(raw, prefix: prefix)
            DisclosureGroup(isExpanded: expanded.projectedValue) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        copyToPasteboard(text)
                    } label: {
                        Label("Copy notes", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            } label: {
                Label("Notes from brew", systemImage: "note.text")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }
}

// MARK: post-install notes

/// After an install or upgrade: the caveats of what changed, once.
struct PostInstallNotesSheet: View {
    var notes: PostInstallNotes
    var done: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "note.text").font(.system(size: 22)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Post-install notes").font(.system(size: 15, weight: .bold))
                    Text(notes.subtitle + ". brew printed these; they are also in each package's details.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(notes.notes) { n in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Image(systemName: n.kind == .cask ? "macwindow" : "shippingbox").foregroundStyle(.secondary)
                                Text(n.name).font(.system(size: 12.5, weight: .semibold))
                                Text(n.version).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(n.text)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(theme.logBackground))
                                .foregroundStyle(theme.logText)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            HStack {
                Button("Copy all") {
                    copyToPasteboard(notes.notes.map { "\($0.name) \($0.version)\n\($0.text)" }.joined(separator: "\n\n"))
                }
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: settings

/// Settings → Upgrades: self-updating apps, quitting apps, vulnerabilities.
struct UpgradeSettings: View {
    @Bindable var settings: InsightSettings
    /// 0.5: the Automatic updates section (nil: not shown).
    var autoUpdater: AutoUpdater? = nil
    var notifier: SystemNotifier? = nil
    var appSettings: AppSettings? = nil
    private let showLog = State(initialValue: false)

    var body: some View {
        Form {
            if let autoUpdater {
                AutoUpdateSettingsSection(updater: autoUpdater, notifier: notifier, appSettings: appSettings) {
                    showLog.wrappedValue = true
                }
                Divider().padding(.vertical, 4)
            }
            Toggle("Include self-updating apps", isOn: $settings.includeSelfUpdatingApps)
                .help("Also lists apps that update themselves (casks with auto_updates) or always download the newest version, as brew outdated --greedy does. These apps usually keep themselves current, so this is off by default.")

            Divider().padding(.vertical, 4)

            Toggle("Don't quit running apps during upgrades", isOn: $settings.dontQuitAppsDuringUpgrade)
                .help("By default brew quits a running app before upgrading its cask and opens it again afterwards. With this on, Tankard sets HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 for cask upgrades (shown in the command): the app keeps running, and the new version starts the next time you open it.")

            Divider().padding(.vertical, 4)

            Toggle("Scan for vulnerabilities when refreshing", isOn: $settings.scanVulnerabilitiesOnRefresh)
            Text(InsightSettings.scanPrivacyNote)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle("Show new vulnerabilities in the menu bar", isOn: $settings.notifyNewVulnerabilities)
                .help("Off by default. Scan for Vulnerabilities Now, in the filter menu next to the segments, runs one scan whenever you ask. brew vulns checks installed formulae against OSV.dev: brew sends each formula's source repository and version to api.osv.dev. Casks aren't checked. A scan that runs longer than a minute is stopped.")
        }
        .padding(20)
        .sheet(isPresented: showLog.projectedValue) {
            if let autoUpdater {
                AutoUpdateLogView(log: autoUpdater.log) { showLog.wrappedValue = false }
            }
        }
    }
}

// MARK: menu bar

/// The menu-bar menu's notice: vulnerabilities found since the last look.
struct VulnerabilityMenuNotice: View {
    var store: AppStore
    var openMain: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let names = store.insights.newVulnerableFormulae
        if !names.isEmpty {
            Divider()
            Button {
                openMain()
                store.showVulnerable()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning(scheme).text)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("New vulnerabilities").font(.system(size: 12.5, weight: .semibold))
                        Text(names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " and \(names.count - 4) more" : ""))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Text("Show").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
