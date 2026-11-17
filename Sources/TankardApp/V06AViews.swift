import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

// v0.6 (part A): the deprecated/disabled badge and detail section, and the
// Health, History and Remove Unused Dependencies sheets. Colours only from
// Theme tokens; no theme-specific geometry.

/// The list's "deprecated" / "disabled" tag next to a package's name.
struct RetiredBadge: View {
    var package: Package
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let label = package.retiredLabel {
            let w = theme.warning(scheme)
            let selected = prominence == .increased && !theme.isCustom
            HStack(spacing: 2) {
                Image(systemName: package.disabled ? "nosign" : "clock.badge.exclamationmark").font(.system(size: 8))
                Text(label)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(selected ? Color.white : w.text)
            .padding(.horizontal, 4).padding(.vertical, 0.5)
            .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.white.opacity(0.16) : w.tag))
            .fixedSize()
            .help(package.retiredDetail ?? label)
        }
    }
}

/// The detail pane's deprecated/disabled box and keg-only / not-linked notes.
struct RetiredDetail: View {
    var package: Package
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = package
        if let detail = p.retiredDetail {
            let w = theme.warning(scheme)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: p.disabled ? "nosign" : "clock.badge.exclamationmark").foregroundStyle(w.text)
                    Text(detail).font(.system(size: 12)).foregroundStyle(w.text).fixedSize(horizontal: false, vertical: true)
                }
                Text(p.disabled ? "Homebrew no longer installs or upgrades it." : "Homebrew still has it, but will disable it later.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let r = p.replacement {
                    let installed = store.installedReplacement(r)
                    HStack(spacing: 8) {
                        Text("Replacement: ").font(.system(size: 11.5)) + Text(r.name).font(.system(size: 11.5, weight: .semibold))
                        Spacer(minLength: 0)
                        if installed != nil {
                            Text("installed").font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Button("Install \(r.name)") { store.installReplacement(for: p) }
                                .controlSize(.small)
                                .disabled(store.isBusy || store.report == nil)
                                .help(BrewCommands.display(BrewCommands.installArguments(kind: r.kind, qualifiedName: r.name)))
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(w.tag))
        }
        ForEach(p.linkNotes, id: \.self) { note in
            Label(note, systemImage: p.kegOnly == true ? "lock.shield" : "link.badge.plus")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A sheet's title row: icon, title, one line under it.
private struct SheetHeader: View {
    var icon: String
    var title: String
    var subtitle: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The 0.6 sheets, one presentation for all three.
struct ToolSheetView: View {
    @Bindable var store: AppStore
    var sheet: ToolSheet

    var body: some View {
        switch sheet {
        case .health:
            if let h = store.health { HealthSheet(store: store, health: h) }
        case .history:
            HistorySheet(store: store, history: store.history)
        case .autoremove:
            if let a = store.autoremove { AutoremoveSheet(store: store, autoremove: a) }
        }
    }
}

// MARK: Health

struct HealthSheet: View {
    @Bindable var store: AppStore
    var health: HealthStore
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetHeader(icon: "stethoscope.circle.fill", title: "Homebrew Health",
                        subtitle: "brew doctor, brew config and brew missing. Read-only: Tankard changes nothing here.")
            switch health.phase {
            case .idle, .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running brew doctor…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
            case .ready:
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { results }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("Fix commands are shown, never run. Copy one into Terminal if you want it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { Task { await health.load() } }
                    .disabled(health.phase == .running)
                Button("Done") { store.closeToolSheet() }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 640, height: 560, alignment: .top)
        .background(theme.window ?? .clear)
    }

    @ViewBuilder
    private var results: some View {
        if let d = health.doctor {
            Text(health.summary).font(.system(size: 16, weight: .bold))
                .foregroundStyle(d.warnings.isEmpty ? theme.accent : theme.warning(scheme).text)
            if d.maintainersNote {
                Text("brew says these warnings are for Homebrew maintainers: if everything works, you can ignore them.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(d.warnings) { w in DoctorWarningCard(warning: w) }
        }
        if !health.missing.isEmpty {
            Text("Missing dependencies").font(.system(size: 12, weight: .semibold))
            ForEach(health.missing) { m in
                Text("\(m.formula): \(m.missing.joined(separator: ", "))").font(.system(size: 11.5, design: .monospaced))
            }
        } else {
            Label("brew missing: no missing dependencies", systemImage: "checkmark.circle")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        DisclosureGroup("brew config") {
            Text(health.config).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        DisclosureGroup("brew doctor (raw output)") {
            Text(health.doctorRaw).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
    }
}

struct DoctorWarningCard: View {
    var warning: DoctorWarning
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    private let expanded = State(initialValue: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning(scheme).text)
                Text(warning.title).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let e = warning.explanation {
                Text(e).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let cmd = warning.fixCommand {
                CommandBox(command: cmd)
            }
            DisclosureGroup("What brew printed", isExpanded: expanded.projectedValue) {
                Text(warning.raw).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.warning(scheme).tag))
    }
}

// MARK: History

struct HistorySheet: View {
    @Bindable var store: AppStore
    var history: HistoryLog
    @Environment(\.theme) private var theme
    private let filter = State(initialValue: HistoryFilter.all)
    private let selectedID = State<HistoryEntry.ID?>(initialValue: nil)

    var body: some View {
        let rows = history.filtered(filter.wrappedValue)
        VStack(alignment: .leading, spacing: 10) {
            SheetHeader(icon: "clock.arrow.circlepath", title: "History",
                        subtitle: "Every brew command Tankard ran: when, the command, the result and how long it took.")
            HStack(spacing: 8) {
                ThemedSegmentedPicker(title: "Show", selection: filter.projectedValue,
                                      options: Array(HistoryFilter.menu.prefix(3)), label: \.title)
                Menu(categoryTitle) {
                    ForEach(Array(HistoryFilter.menu.dropFirst(3))) { f in
                        Button(f.title) { filter.wrappedValue = f }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Text("\(rows.count) of \(history.entries.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                ContentUnavailableView(history.entries.isEmpty ? "Nothing yet" : "Nothing matches",
                                       systemImage: "clock",
                                       description: Text(history.entries.isEmpty ? "Installs, upgrades, pins and more appear here." : "Try another filter."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(rows) { e in HistoryRow(entry: e, store: store) }
                    }
                }
            }
            HStack {
                Text("The last \(HistoryLog.maxEntries) are kept in Application Support.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { store.closeToolSheet() }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 680, height: 560, alignment: .top)
        .background(theme.window ?? .clear)
    }

    private var categoryTitle: String {
        if case .category(let c) = filter.wrappedValue { return "Type: \(c.title)" }
        return "Type"
    }
}

struct HistoryRow: View {
    var entry: HistoryEntry
    var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    private static let time: Date.FormatStyle = .dateTime.month(.abbreviated).day().hour().minute()

    var body: some View {
        let e = entry
        let w = theme.warning(scheme)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(e.isFailure ? w.text : e.outcome == .succeeded ? theme.badge(.bottle).dot : Color.secondary)
                Text(e.command).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if e.origin == .autoUpdate {
                    Text("auto").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 3).stroke(.tertiary, lineWidth: 0.5))
                }
                if e.canRetry {
                    Button("Retry") { store.retry(e) }
                        .controlSize(.small)
                        .disabled(store.isBusy)
                        .help(e.category == .upgrade
                              ? "Upgrade again the usual way: compile warnings, pins and skipped versions still apply"
                              : "Run \(e.command) again, through the queue")
                } else if let hint = e.rerunHint {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).help(hint)
                }
            }
            HStack(spacing: 8) {
                Text(e.startedAt.formatted(Self.time))
                Text(e.resultText).foregroundStyle(e.isFailure ? w.text : .secondary)
                Text(e.durationText).monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.leading, 24)
            if let k = e.failureKind {
                Text("\(k.title). \(k.explanation)").font(.system(size: 11)).foregroundStyle(w.text)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
            }
            if e.isFailure && !e.outputTail.isEmpty {
                DisclosureGroup("brew's output") {
                    Text(e.outputTail.joined(separator: "\n")).font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11)).padding(.leading, 24)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private var icon: String {
        switch entry.outcome {
        case .succeeded: return "checkmark.circle.fill"
        case .failed, .notStarted: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        }
    }
}

// MARK: Autoremove

struct AutoremoveSheet: View {
    @Bindable var store: AppStore
    var autoremove: AutoremoveStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetHeader(icon: "shippingbox.and.arrow.backward.fill", title: "Remove Unused Dependencies",
                        subtitle: "Formulae installed only as dependencies that nothing installed needs any more.")
            switch autoremove.phase {
            case .idle, .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running \(autoremove.dryRunCommand)…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
            case .ready:
                let names = autoremove.plan?.formulae ?? []
                Text(names.isEmpty ? "Nothing to remove" : "Would remove \(names.count) formula\(names.count == 1 ? "" : "e")")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(names.isEmpty ? Color.secondary : theme.accent)
                if !names.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(names, id: \.self) { n in
                                Text(n).font(.system(size: 12, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("To keep one, mark it as installed on request in Terminal first, then check again:")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        CommandBox(command: AutoremovePlan.keepCommand(names[0]))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Command").font(.system(size: 11)).foregroundStyle(.secondary)
                CommandBox(command: autoremove.command)
            }
            Spacer(minLength: 0)
            HStack {
                Text("Preview from \(autoremove.dryRunCommand) (changes nothing).").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { Task { await autoremove.load() } }
                    .disabled(autoremove.phase == .running)
                Button("Cancel") { store.closeToolSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove") { store.startAutoremove() }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
                    .disabled(autoremove.phase != .ready || (autoremove.plan?.formulae.isEmpty ?? true) || store.isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 600, height: 460, alignment: .top)
        .background(theme.window ?? .clear)
    }
}

/// Homebrew menu items for 0.6. A view, so its store reads aren't tracked
/// by App.body.
struct HealthCommands: View {
    var store: AppStore

    var body: some View {
        Divider()
        Button("Health…") { store.openHealth() }
            .disabled(store.report == nil)
        Button("History…") { store.openHistory() }
        Button("Remove Unused Dependencies…") { store.openAutoremove() }
            .disabled(store.isBusy || store.report == nil)
    }
}

/// 0.6 demo launch options: a seeded History and one of the new sheets.
@MainActor
func applyV06ALaunchOptions(store: AppStore, options: LaunchOptions) async {
    guard options.demo != nil else { return }
    Demo.seedHistory(store.history)
    switch options.demoSheet {
    case .health?: store.openHealth()
    case .history?: store.openHistory()
    case .autoremove?: store.openAutoremove()
    case nil: break
    }
}
