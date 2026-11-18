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
        return list.count == 1 ? String(localized: "1 known vulnerability (brew vulns): \(ids)") : String(localized: "\(list.count) known vulnerabilities (brew vulns): \(ids)")
    }

    /// "Scanned 5 min ago · partial scan".
    static func scanLine(_ scan: VulnerabilityScan) -> String {
        String(localized: "Scanned \(updatedAgo(scan.scannedAt, now: Date()))") + (scan.complete ? "" : String(localized: " · partial scan"))
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

/// The filters that don't fit the segmented control (Vulnerable, Pinned,
/// Installed by you, Has notes, Deprecated), as a standard menu picker next
/// to it. 0.6.1: a native pop-up (Picker, .menu) instead of the custom
/// styled Menu, after which the window could no longer be dragged by its
/// toolbar until the Installed tab was rebuilt. The scan moved to Settings,
/// the Homebrew menu and the status bar's progress line. 0.8.2: each item
/// shows its count, and items with nothing to show are greyed (except the
/// selected one).
struct MoreFiltersPicker: View {
    @Bindable var store: AppStore
    @Environment(\.theme) private var theme

    var body: some View {
        let active = store.moreFilterSelection != nil
        let items = store.moreFilterItems
        let vulnerable = items.first { $0.filter == .vulnerable }?.count ?? 0
        Picker("More filters", selection: Binding(get: { store.moreFilterSelection },
                                                 set: { store.moreFilterSelection = $0 })) {
            if !active {
                if vulnerable > 0 {
                    Label("\(vulnerable) vulnerable", systemImage: "exclamationmark.triangle.fill").tag(PackageFilter?.none)
                } else {
                    Text("More").tag(PackageFilter?.none)
                }
                Divider()
            }
            ForEach(items) { item in
                Text(verbatim: "\(item.filter.title)  \(item.count)")
                    .tag(PackageFilter?.some(item.filter))
                    // .disabled does nothing to a pop-up's items; this greys them.
                    .selectionDisabled(!item.isEnabled)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        // A pop-up sizes itself to its widest item ("Installed by you 123");
        // keep it compact so the summary beside it isn't cut off.
        .frame(width: 128)
        // The active look: the theme's accent ring. Colour only; the frame
        // is the same in every theme and state.
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? theme.accent : Color.clear, lineWidth: 1.5)
            .allowsHitTesting(false))
        .help(Self.help(vulnerable: vulnerable, selected: store.moreFilterSelection))
    }

    /// The pop-up's tooltip: the selected filter's meaning, else what's
    /// in the menu.
    static func help(vulnerable: Int, selected: PackageFilter?) -> String {
        if let selected, let h = selected.help { return h }
        if vulnerable > 0 {
            return vulnerable == 1 ? String(localized: "1 vulnerable package; more filters") : String(localized: "\(vulnerable) vulnerable packages; more filters")
        }
        return String(localized: "More filters: Vulnerable, Pinned (packages brew won't upgrade), Installed by you (packages you installed yourself, not ones pulled in as dependencies), Has notes, Deprecated")
    }
}

/// 0.6.1: the scan's progress: spinner, "Scanning N formulae…", elapsed
/// time and Stop; afterwards "Scanned N · found M" (or why it ended).
struct ScanProgressView: View {
    var store: AppStore
    var showOutcome = true

    var body: some View {
        let insights = store.insights
        if insights.scanState == .running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(ScanProgressText.running(formulae: insights.scanFormulaCount))
                if let start = insights.scanStartedAt {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(ScanProgressText.elapsed(ctx.date.timeIntervalSince(start))).monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                Button("Stop") { insights.stopScan() }
                    .controlSize(.small)
                    .help("Stop brew vulns. The last result, if any, is kept.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        } else if showOutcome, let o = insights.scanOutcome {
            Text(ScanProgressText.outcome(o))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help(insights.vulnerabilityScan?.partialReason.map { String(localized: "brew says the scan is incomplete: \($0).") } ?? String(localized: "From brew vulns (OSV.dev)."))
        }
    }
}

/// 0.6.1: a small ⓘ that shows a setting's explanation on click (the
/// tooltip stays for hover).
struct InfoButton: View {
    var text: String
    private let shown: State<Bool>

    init(text: String) {
        self.text = text
        // Screenshots: TANKARD_DEMO_INFO=<start of a text> opens that one.
        shown = State(initialValue: Self.demoOpen.map { !$0.isEmpty && text.hasPrefix($0) } ?? false)
    }

    static let demoOpen = ProcessInfo.processInfo.environment["TANKARD_DEMO_INFO"]

    var body: some View {
        Button {
            shown.wrappedValue.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(text)
        .accessibilityLabel("Explain")
        .popover(isPresented: shown.projectedValue, arrowEdge: .trailing) {
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }
}

/// A settings row: the control, then its ⓘ.
struct ExplainedRow<Content: View>: View {
    var help: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            content.help(help)
                .fixedSize(horizontal: false, vertical: true)
            InfoButton(text: help)
        }
    }
}

/// The summary strip's size total: "· 4.1 GB on disk". Its explanation is
/// in the strip's tooltip, which also has the full text when the strip is short.
struct DiskTotalText: View {
    var store: AppStore

    var body: some View {
        if let total = store.totalDiskBytes {
            Text("· \(DiskSizes.format(total)) on disk")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if store.insights.sizesState == .running {
            Text("· measuring…").foregroundStyle(.tertiary).lineLimit(1)
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
                .disabled(targets.isEmpty || store.windowBrewActionsBlocked || store.isRefreshing)
                .help(String(localized: "Upgrade vulnerable packages. ") + upgradeHelp(targets)
                      + (scan?.partialReason.map { String(localized: " Partial scan: \($0).") } ?? ""))
            }
            // Otherwise nothing: the scan's state and Scan Now are in the
            // filter's header (VulnerableScanBar).
        }
        .fixedSize()
    }

    private func upgradeHelp(_ targets: [Package]) -> String {
        let none = VulnerabilityUpgrades.withoutUpgrade(store.packages)
        var s = targets.isEmpty ? String(localized: "No vulnerable package has an upgrade yet.") : String(localized: "Upgrade \(targets.map(\.name).joined(separator: ", ")).")
        if !none.isEmpty { s += String(localized: " No upgrade yet for \(none.map(\.name).joined(separator: ", ")).") }
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
                Text(s == InsightsStore.scanTimedOutMessage ? String(localized: "Scan timed out") : String(localized: "Scan failed")).help(s)
            case .unsupported(let s):
                Text("No brew vulns").help(s)
            case .idle:
                if let scan = insights.vulnerabilityScan {
                    Text(scan.complete ? String(localized: "Full scan") : String(localized: "Partial scan"))
                        .help(scan.partialReason.map { String(localized: "brew says the scan is incomplete: \($0).") } ?? String(localized: "brew checked every installed formula."))
                } else {
                    Text("Not scanned yet")
                        .help("Scan Now is in Settings → Upgrades and the Homebrew menu. " + InsightSettings.scanPrivacyNote)
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
                    Text(list.count == 1 ? String(localized: "1 known vulnerability") : String(localized: "\(list.count) known vulnerabilities"))
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
                    Text(VulnerabilityText.scanLine(scan) + String(localized: ". From brew vulns (OSV.dev)."))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .help(scan.partialReason ?? "")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(w.tag))
        } else if package.kind == .formula, let scan {
            let note: String = {
                if scan.skipped.contains(package.fullName) { return String(localized: "Not checked by brew vulns: no source repository it can match.") }
                if let reason = scan.unscanned[package.fullName] {
                    return reason == "untrusted_tap" ? String(localized: "Not checked by brew vulns: untrusted tap.") : String(localized: "Not checked by brew vulns.")
                }
                return String(localized: "No known vulnerabilities (brew vulns).")
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
                        Label("Copy Notes", systemImage: "doc.on.doc")
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
                    Text(notes.subtitle + String(localized: ". brew printed these; they are also in each package's details."))
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
                Button("Copy All") {
                    copyToPasteboard(notes.notes.map { "\($0.name) \($0.version)\n\($0.text)" }.joined(separator: "\n\n"))
                }
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
            }
            .panelButtonRow("notes.buttons")
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
    /// 0.7: "Keep the previous version after upgrades" (nil: not shown).
    var rollbackSettings: RollbackSettings? = nil
    /// 0.6.1: Scan Now and its progress (nil: not shown).
    var store: AppStore? = nil
    private let showLog = State(initialValue: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("When upgrading")
            ExplainedRow(help: SettingsHelp.includeSelfUpdatingApps) {
                Toggle("Include self-updating apps", isOn: $settings.includeSelfUpdatingApps)
            }
            ExplainedRow(help: SettingsHelp.dontQuitApps) {
                Toggle("Don't quit running apps during upgrades", isOn: $settings.dontQuitAppsDuringUpgrade)
            }
            if let rollbackSettings {
                KeepPreviousVersionToggle(settings: rollbackSettings)
            }

            if let autoUpdater {
                SettingsSectionDivider()
                SettingsSectionHeader("Automatic updates")
                AutoUpdateSettingsSection(updater: autoUpdater, notifier: notifier, appSettings: appSettings) {
                    showLog.wrappedValue = true
                }
            }

            SettingsSectionDivider()
            SettingsSectionHeader("Vulnerability scan")
            ExplainedRow(help: SettingsHelp.scanOnRefresh) {
                Toggle("Scan for vulnerabilities when refreshing", isOn: $settings.scanVulnerabilitiesOnRefresh)
            }
            SettingsNote(InsightSettings.scanPrivacyNote)
            if let store {
                HStack(spacing: 8) {
                    if store.insights.scanState != .running {
                        Button("Scan Now") { store.scanVulnerabilitiesNow() }
                            .controlSize(.small)
                            .disabled(store.report == nil)
                            .help("Runs brew vulns once now. " + InsightSettings.scanPrivacyNote)
                    }
                    ScanProgressView(store: store)
                    if store.insights.scanState != .running, store.insights.scanOutcome == nil,
                       let scan = store.insights.vulnerabilityScan {
                        Text("Vulnerabilities: " + VulnerabilityText.scanLine(scan))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(scan.partialReason ?? "")
                    }
                }
                .padding(.leading, SettingsNote.indent)
            }
            ExplainedRow(help: SettingsHelp.notifyNewVulnerabilities) {
                Toggle("Show new vulnerabilities in the menu bar", isOn: $settings.notifyNewVulnerabilities)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: showLog.projectedValue) {
            if let autoUpdater {
                AutoUpdateLogView(log: autoUpdater.log, done: { showLog.wrappedValue = false }, store: store)
            }
        }
    }
}

/// A Settings section's title ("Automatic updates").
struct SettingsSectionHeader: View {
    var title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

/// The line between two Settings sections.
struct SettingsSectionDivider: View {
    var body: some View { Divider().padding(.vertical, 6) }
}

/// A setting's small note, under its checkbox and lined up with the
/// checkbox's title. Wraps rather than truncating (German).
struct SettingsNote: View {
    /// A checkbox's width plus its gap: where its title starts.
    static let indent: CGFloat = 20
    var text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, Self.indent)
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
                        Text(names.prefix(4).joined(separator: ", ") + (names.count > 4 ? String(localized: " and \(names.count - 4) more") : ""))
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
