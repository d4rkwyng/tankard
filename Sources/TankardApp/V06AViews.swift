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
    /// 0.8.6: the symbol only (a narrow Package column).
    var compact = false
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let label = package.retiredLabel {
            let w = theme.warning(scheme)
            let selected = prominence == .increased && !theme.isCustom
            HStack(spacing: 2) {
                Image(systemName: package.disabled ? "nosign" : "clock.badge.exclamationmark").font(.system(size: 8))
                if !compact { Text(label) }
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(selected ? Color.white : w.text)
            .padding(.horizontal, 4).padding(.vertical, 0.5)
            .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.white.opacity(0.16) : w.tag))
            .fixedSize()
            .help(package.retiredDetail ?? label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
        }
    }
}

/// 0.8.6 (M1): "can't read" next to the name of a package brew can't load.
struct UnreadableBadge: View {
    var package: Package
    var compact = false
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if package.isUnreadable {
            let w = theme.warning(scheme)
            let selected = prominence == .increased && !theme.isCustom
            HStack(spacing: 2) {
                Image(systemName: "questionmark.folder").font(.system(size: 8))
                if !compact { Text("can't be read") }
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(selected ? Color.white : w.text)
            .padding(.horizontal, 4).padding(.vertical, 0.5)
            .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.white.opacity(0.16) : w.tag))
            .fixedSize()
            .help(package.unreadableDetail ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Homebrew can't read this package"))
        }
    }
}

/// 0.8.6 (M1): the detail pane's box for a package brew can't read.
struct UnreadableDetail: View {
    var package: Package
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let detail = package.unreadableDetail {
            let w = theme.warning(scheme)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "questionmark.folder").foregroundStyle(w.text)
                    Text(detail).font(.system(size: 12)).foregroundStyle(w.text).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text("It is still installed (brew list shows it). Trusting its tap, or installing it again under its new name, lets Homebrew read it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if package.tap != nil {
                    Button("Taps…") { store.openTaps() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(w.tag))
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
                Text(p.disabled ? String(localized: "Homebrew no longer installs or upgrades it.") : String(localized: "Homebrew still has it, but will disable it later."))
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
struct SheetHeader: View {
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
        case .taps:
            TapsSheet(store: store, taps: store.taps)
        case .adopt:
            AdoptSheet(store: store, adopt: store.adopt)
        case .welcome:
            if let o = store.onboarding { OnboardingSheet(store: store, state: o) }
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
            SheetHeader(icon: "stethoscope.circle.fill", title: String(localized: "Homebrew Health"),
                        subtitle: String(localized: "Homebrew's own check-up. Looking changes nothing."))
            switch health.phase {
            case .idle, .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running Homebrew's check-up…").font(.system(size: 12)).foregroundStyle(.secondary)
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
                Text("Where Tankard can fix something itself, there's a button. Terminal commands are under Details.")
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
        .sheetFrame(width: 640, height: 560, store: store)
        .escapeCloses { store.closeToolSheet() }
        .background(theme.window ?? .clear)
    }

    @ViewBuilder
    private var results: some View {
        if let d = health.doctor {
            Text(health.summary).font(.system(size: 16, weight: .bold))
                .foregroundStyle(d.warnings.isEmpty ? theme.accent : health.onlyHarmless ? Color.primary : Color.orange)
            // 0.8.5 (newbie review H5): lead with the reassurance.
            if !d.warnings.isEmpty {
                Text("Everything works? Then you can ignore these. They are mostly for people who build software or report problems to Homebrew.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(d.warnings) { w in DoctorWarningCard(warning: w, store: store) }
        }
        // 0.8.6 (M1): installed packages brew can't read (not a brew doctor note).
        let unreadable = store.unreadablePackages
        if !unreadable.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(HealthText.unreadableTitle(unreadable.count), systemImage: "questionmark.folder")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.warning(scheme).text)
                ForEach(unreadable) { p in
                    Text(verbatim: "\(p.name): \(p.unreadableDetail ?? "")").font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        if !health.missing.isEmpty {
            Text("Missing dependencies").font(.system(size: 12, weight: .semibold))
            ForEach(health.missing) { m in
                Text(verbatim: "\(m.formula): \(m.missing.joined(separator: ", "))").font(.system(size: 11.5, design: .monospaced))
            }
        } else {
            Label("brew missing: no missing dependencies", systemImage: "checkmark.circle")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        if !health.environment.isEmpty {
            EnvironmentDisclosure(entries: health.environment)
        }
        DisclosureGroup {
            Text(health.config).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(verbatim: "brew config")
        }
        .font(.system(size: 12))
        DisclosureGroup("brew doctor (raw output)") {
            Text(health.doctorRaw).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
    }
}

/// 0.8.4: the Environment disclosure, open from the start (with a warning
/// sign) when a brew.env setting overrides one of Tankard's.
struct EnvironmentDisclosure: View {
    var entries: [EnvironmentPolicy.Entry]
    private let expanded: State<Bool>
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    init(entries: [EnvironmentPolicy.Entry]) {
        self.entries = entries
        expanded = State(initialValue: entries.contains { $0.conflict != nil })
    }

    var body: some View {
        DisclosureGroup(isExpanded: expanded.projectedValue) {
            EnvironmentList(entries: entries)
        } label: {
            HStack(spacing: 4) {
                Text("Environment")
                if entries.contains(where: { $0.conflict != nil }) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning(scheme).text)
                }
            }
        }
        .font(.system(size: 12))
    }
}

/// 0.8.3: Health ▸ Environment. Each HOMEBREW_* setting, where it came
/// from, and whether Tankard's brew gets it (EnvironmentPolicy). 0.8.4:
/// proxies and XDG_CONFIG_HOME too (proxy passwords masked), and a warning
/// on each brew.env setting that overrides one of Tankard's.
struct EnvironmentList: View {
    var entries: [EnvironmentPolicy.Entry]
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your HOMEBREW_*, proxy and XDG_CONFIG_HOME settings and what Tankard does with each when it runs brew.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: line(e)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    if let c = e.conflict {
                        Label(Self.conflictReason(c), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(theme.warning(scheme).text)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(Self.explanation(e)).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("brew reads brew.env files itself, so a setting there reaches brew whatever this list says.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Tankard's own downloads (Discover, install counts, update check) use the proxy in System Settings, not these.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func line(_ e: EnvironmentPolicy.Entry) -> String {
        var s = e.key + "=" + (e.value ?? e.tankardValue ?? "")
        if let src = e.source { s += "  (\(src))" }
        if let t = e.tankardValue, e.value != nil, t != e.value, e.status != .brewEnv { s += "  → \(t)" }
        return s
    }

    /// 0.8.4: why a brew.env setting gets a warning.
    static func conflictReason(_ c: EnvironmentPolicy.BrewEnvConflict) -> String {
        switch c {
        case .dependentsCheck: return String(localized: "Set in brew.env, so it reaches Tankard's brew: automatic updates pause while it is set.")
        case .greedy: return String(localized: "Set in brew.env, so it overrides Tankard's self-updating apps setting.")
        case .intelbrew: return String(localized: "Set in brew.env, so it overrides Intelbrew mode's value.")
        case .autoremove: return String(localized: "Set in brew.env, so Uninstall may also remove other unused dependencies.")
        case .output: return String(localized: "Set in brew.env: it changes brew's output, which Tankard reads.")
        case .caskOptions: return String(localized: "Set in brew.env, so it applies to Tankard's installs too; Adopt Apps' location checks assume /Applications.")
        case .askpass: return String(localized: "Set in brew.env, so brew would send password prompts to this helper: Tankard offers no password dialog, and steps that need sudo run in Terminal.")
        case .location: return String(localized: "Set in brew.env: it moves brew's files from where Tankard looks.")
        case .defaultFolders: return String(localized: "Set in brew.env: Tankard's download progress and Clean Up assume the default folders.")
        case .trust: return String(localized: "Set in brew.env, so it applies to Tankard's brew: it changes where brew gets code from, or what it trusts.")
        case .mirror: return String(localized: "Set in brew.env, so brew uses this mirror; Discover and the tap index don't.")
        }
    }

    static func explanation(_ e: EnvironmentPolicy.Entry) -> String {
        switch e.status {
        case .passed where EnvironmentPolicy.configHomeKeys.contains(e.key):
            return String(localized: "Passed to brew: it picks the brew.env file brew reads.")
        case .passed: return String(localized: "Passed to brew.")
        case .droppedByBrew: return String(localized: "Not passed: brew ignores the upper-case form; use the lower-case one.")
        case .partial: return caskOptions(e.caskOptions)
        case .brewEnv:
            // CASK_OPTS in brew.env with options Tankard would drop: they apply anyway.
            if e.caskOptions != nil {
                return String(localized: "Set in brew.env, so it applies to Tankard's installs too; Adopt Apps' location checks assume /Applications.")
            }
            return String(localized: "From brew.env: brew reads it itself.")
        case .ignored: return String(localized: "Ignored: not on Tankard's list of settings it passes to brew.")
        case .tankard(let why):
            switch why {
            case .output: return e.tankardValue == nil
                ? String(localized: "Not passed: Tankard reads brew's output.")
                : String(localized: "Set by Tankard: it reads brew's output.")
            case .autoUpdate: return String(localized: "Set by Tankard for checks and upgrades: Tankard decides when brew update runs.")
            case .greedy: return String(localized: "Not passed: Tankard's self-updating apps setting decides this.")
            case .intelbrew: return String(localized: "Set by Intelbrew mode.")
            }
        case .denied(let d):
            switch d {
            case .location: return String(localized: "Not passed: changes where brew lives or keeps its files.")
            case .trust: return String(localized: "Not passed: changes where brew gets code from, or what it trusts.")
            case .mirror: return String(localized: "Not applied by Tankard (set in shell): download mirrors aren't supported yet.")
            case .credential: return String(localized: "Not passed: a credential.")
            case .dependentsCheck: return String(localized: "Not passed: auto-update relies on brew's dependents check.")
            case .defaultFolders: return String(localized: "Not passed: Tankard's download progress and Clean Up assume the default folders.")
            }
        }
    }

    /// HOMEBREW_CASK_OPTS: "Partly applied: --require-sha" and a line per dropped option.
    static func caskOptions(_ c: CaskOptions?) -> String {
        guard let c else { return "" }
        var lines = [c.kept.isEmpty ? String(localized: "Not applied: none of these cask options are safe to pass.")
                                    : String(localized: "Partly applied: \(c.kept.joined(separator: " "))")]
        for (option, reason) in c.dropped {
            let why: String
            switch reason {
            case .location: why = String(localized: "changes where apps go, which Adopt and App Management rely on")
            case .confirmation: why = String(localized: "would overwrite or take over apps without confirmation")
            case .other: why = String(localized: "not on Tankard's list of cask options")
            }
            lines.append(String(localized: "Ignored: \(option) (\(why))"))
        }
        return lines.joined(separator: "\n")
    }
}

struct DoctorWarningCard: View {
    var warning: DoctorWarning
    var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    private let expanded = State(initialValue: false)

    var body: some View {
        // 0.8.5 (newbie review H5): known harmless notes are neutral
        // information; the rest (and unknown ones) yellow, never red.
        let harmless = warning.isHarmless
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: harmless ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(harmless ? Color.secondary : Color.yellow)
                Text(warning.title).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if harmless {
                    Text("Usually harmless").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if let e = warning.explanation {
                Text(e).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let action = warning.action {
                actionButton(action)
                if let cmd = warning.fixCommand { CommandDetails(commands: [cmd]) }
            } else if let cmd = warning.fixCommand {
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
        .background(RoundedRectangle(cornerRadius: 8).fill(harmless ? theme.chip : Color.yellow.opacity(scheme == .dark ? 0.16 : 0.14)))
    }

    @ViewBuilder
    private func actionButton(_ action: DoctorFixAction) -> some View {
        switch action {
        case .cleanUp:
            Button("Clean Up…") { store.openCleanupFromHealth() }
                .controlSize(.small)
                .disabled(store.isBusy)
                .help(String(localized: "Removes old versions and leftover downloads, after showing what goes"))
        case .softwareUpdate:
            Button("Open Software Update") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
            .help(String(localized: "Opens System Settings, where macOS offers the Command Line Tools update"))
        }
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
            SheetHeader(icon: "clock.arrow.circlepath", title: String(localized: "History"),
                        subtitle: String(localized: "Every brew command Tankard ran: when, the command, the result and how long it took."))
            HStack(spacing: 8) {
                ThemedSegmentedPicker(title: String(localized: "Show"), selection: filter.projectedValue,
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
                ContentUnavailableView(history.entries.isEmpty ? String(localized: "Nothing yet") : String(localized: "Nothing matches"),
                                       systemImage: "clock",
                                       description: Text(history.entries.isEmpty ? String(localized: "Installs, upgrades, pins and more appear here.") : String(localized: "Try another filter.")))
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
        .sheetFrame(width: 680, height: 560, store: store)
        .escapeCloses { store.closeToolSheet() }
        .background(theme.window ?? .clear)
    }

    private var categoryTitle: String {
        if case .category(let c) = filter.wrappedValue { return String(localized: "Type: \(c.title)") }
        return String(localized: "Type")
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
                              ? String(localized: "Upgrade again the usual way: compile warnings, pins and skipped versions still apply")
                              : String(localized: "Run \(e.command) again, through the queue"))
                } else if let hint = e.rerunHint {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).help(hint)
                        .accessibilityLabel(Text(hint)) // 0.8.6 (UI L6): was "info"
                }
            }
            HStack(spacing: 8) {
                if let since = e.quietSince {
                    // 0.8.5: a collapsed run of quiet scheduled checks.
                    Text(verbatim: "\(since.formatted(Self.time)) – \(e.startedAt.formatted(Self.time))")
                } else {
                    Text(e.startedAt.formatted(Self.time))
                }
                Text(e.resultText).foregroundStyle(e.isFailure ? w.text : .secondary)
                Text(e.durationText).monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.leading, 24)
            if let k = e.failureKind, e.quietReason == nil {
                Text(verbatim: "\(k.title). \(k.explanation)").font(.system(size: 11)).foregroundStyle(w.text)
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
        // 0.8.5: a scheduled check that will retry (offline, busy, slept).
        if entry.quietReason != nil { return "clock.arrow.circlepath" }
        switch entry.outcome {
        case .succeeded: return "checkmark.circle.fill"
        case .noChange: return "equal.circle"
        case .failed, .notStarted: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: Autoremove

struct AutoremoveSheet: View {
    @Bindable var store: AppStore
    @Bindable var autoremove: AutoremoveStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetHeader(icon: "shippingbox.and.arrow.backward.fill", title: String(localized: "Remove Unused Dependencies"),
                        subtitle: String(localized: "Packages Homebrew installed only because something else needed them, and nothing needs anymore."))
            switch autoremove.phase {
            case .idle, .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking what can be removed…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
            case .ready:
                let names = autoremove.plan?.formulae ?? []
                Text(names.isEmpty ? String(localized: "Nothing to remove") : (names.count == 1 ? String(localized: "Would remove 1 formula") : String(localized: "Would remove \(names.count) formulae")))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(names.isEmpty ? Color.secondary : theme.accent)
                if !names.isEmpty {
                    Text("Untick any you want to keep. Tankard marks those as installed by you, so later clean-ups leave them (and what they need) too.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(names, id: \.self) { n in row(n) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                }
            }
            CommandDetails(commands: commands)
            Spacer(minLength: 0)
            HStack {
                Text("A preview: nothing is removed until you click Remove.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { Task { await autoremove.load() } }
                    .disabled(autoremove.phase == .running)
                Button("Cancel") { store.closeToolSheet() }
                    .keyboardShortcut(.cancelAction)
                // 0.8.5 (newbie review H3): no default button. Return
                // doesn't remove anything.
                Button(removeTitle, role: .destructive) { store.startAutoremove() }
                    .disabled(autoremove.phase != .ready || autoremove.toRemove.isEmpty || store.isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .sheetFrame(width: 600, height: 500, store: store)
        .background(theme.window ?? .clear)
    }

    private var removeTitle: String {
        let n = autoremove.toRemove.count
        let all = autoremove.plan?.formulae.count ?? 0
        return n == all || n == 0 ? String(localized: "Remove") : String(localized: "Remove \(n)")
    }

    private var commands: [String] {
        let keep = autoremove.toKeep
        return (keep.isEmpty ? [] : [BrewCommands.display(AutoremovePlan.keepArguments(keep))]) + [autoremove.command]
    }

    @ViewBuilder
    private func row(_ name: String) -> some View {
        let p = store.autoremovePackage(name)
        let shown = p?.name ?? (name.split(separator: "/").last.map(String.init) ?? name)
        Toggle(isOn: Binding(get: { !autoremove.keep.contains(name) }, set: { autoremove.setKeep(name, !$0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(shown).font(.system(size: 12, weight: .medium))
                if let d = p?.desc, !d.isEmpty {
                    Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                if AutoremovePlan.oftenUsedDirectly(name) {
                    Label("You may use this one directly in Terminal. Untick it to keep it.", systemImage: "terminal")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// Homebrew menu items for 0.6 (Remove Unused Dependencies… sits with
/// Clean Up… in HomebrewCommands). A view, so its store reads aren't
/// tracked by App.body.
struct HealthCommands: View {
    var store: AppStore

    var body: some View {
        // 0.8.4: Health runs brew (read-only): not during a run. History
        // only reads Tankard's file: during a run too, but not over a sheet.
        Button("Health…") { store.openHealth() }
            .disabled(store.report == nil || store.menuActionsBlocked)
        Button("History…") { store.openHistory() }
            .disabled(store.isSheetPresented)
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
    case .taps?: store.openTaps()
    case .adopt?: store.openAdopt()
    case .welcome?: store.presentOnboarding()
    case nil: break
    }
}
