import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

// v0.4 (part A): the Services tab. The list is `brew services list --json`
// (a read); the pane adds `brew services info --json <name>`; Start, Stop
// and Restart go through the queue. Services that run as root get the sudo
// command to run in Terminal instead of a button.

extension BrewService {
    /// Badge colours: reuse the source badges, which are AA-checked in every theme.
    var badgeKind: BadgeKind {
        switch status {
        case .started: return .bottle
        case .scheduled: return .newer
        case .error: return .source
        case .stopped, .none: return .noBottle
        case .unknown, .other, .unrecognized: return .cask
        }
    }

    var statusLabel: String {
        switch status {
        case .started: return String(localized: "Running")
        case .scheduled: return String(localized: "Scheduled")
        case .stopped: return String(localized: "Stopped")
        case .error: return exitCode.map { String(localized: "Error (exit \($0))") } ?? String(localized: "Error")
        case .none: return String(localized: "Not running")
        case .unknown: return String(localized: "Unknown")
        case .other: return String(localized: "Other")
        case .unrecognized(let s): return s
        }
    }
}

struct ServicesView: View {
    @Bindable var store: AppStore
    @Bindable var services: ServicesStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                table.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ServiceDetail(store: store, services: services)
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    .background(theme.pane)
            }
        }
        .task { if services.phase == .idle { await services.load() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(services.phase == .loading && services.services.isEmpty ? String(localized: "Reading services…") : services.summary)
                    .font(.system(size: 13, weight: .medium))
                Text("Background services from installed formulae. Tankard controls your own (~/Library/LaunchAgents), never root's.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if services.phase == .loading {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await services.load() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(services.phase == .loading)
            .help(services.listCommand)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 54)
        .background(theme.strip)
    }

    private var rows: [BrewService] {
        let q = services.query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? services.services : services.services.filter { $0.name.lowercased().contains(q) }
    }

    private var table: some View {
        Table(rows, selection: $services.selection) {
            TableColumn("Service") { (s: BrewService) in
                Text(s.name).fontWeight(.medium).lineLimit(1)
            }
            .width(min: 110, ideal: 140)
            TableColumn("Status") { (s: BrewService) in
                SourceBadge(kind: s.badgeKind, label: s.statusLabel)
            }
            .width(min: 100, ideal: 130)
            TableColumn("User") { (s: BrewService) in
                Text(s.user ?? "–").foregroundStyle(s.user == nil ? .secondary : .primary).lineLimit(1)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Exit") { (s: BrewService) in
                Text(s.exitCode.map(String.init) ?? "–").monospacedDigit()
                    .foregroundStyle(s.exitCode == nil || s.exitCode == 0 ? .secondary : .primary)
            }
            .width(min: 34, ideal: 44)
            TableColumn("Plist") { (s: BrewService) in
                Text(s.file.map { abbreviate($0) } ?? "–")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(s.file ?? "")
            }
            .width(min: 100, ideal: 200)
        }
        // One configuration in every theme: changing it makes AppKit drop
        // the visible rows (see TableSelectionStyler). The stripes are
        // painted by the styler, the background is this view's.
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(theme.table ?? Color(nsColor: .controlBackgroundColor))
        .background(TableSelectionStyler(palette: theme.palette, token: 0, paintsSelection: false))
        .onChange(of: services.selection) { _, name in
            if let name { Task { await services.loadInfo(name) } }
        }
        .overlay {
            if services.phase == .ready && rows.isEmpty {
                ContentUnavailableView(services.services.isEmpty ? String(localized: "No services") : String(localized: "No matches"), systemImage: "gearshape.2",
                                       description: Text(services.services.isEmpty
                                                         ? String(localized: "None of the installed formulae has a background service.")
                                                         : String(localized: "No service matches “\(services.query)”.")))
            } else if case .failed(let message) = services.phase {
                ContentUnavailableView {
                    Label("brew services failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).font(.system(size: 11, design: .monospaced)).lineLimit(6)
                }
            }
        }
    }
}

func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

struct ServiceDetail: View {
    @Bindable var store: AppStore
    @Bindable var services: ServicesStore
    @Environment(\.theme) private var theme

    var body: some View {
        if let s = services.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(LinearGradient(colors: [Color(hex: 0x3a3a3c), Color(hex: 0x1c1c1e)], startPoint: .top, endPoint: .bottom))
                            .frame(width: 40, height: 40)
                            .overlay(Image(systemName: "gearshape.2.fill").font(.system(size: 17)).foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
                            SourceBadge(kind: s.badgeKind, label: s.statusLabel)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                        row(String(localized: "User"), s.user ?? String(localized: "not loaded"))
                        if let pid = s.pid { row(String(localized: "PID"), "\(pid)") }
                        row(String(localized: "Exit code"), s.exitCode.map(String.init) ?? "–")
                        if let label = s.serviceName { row(String(localized: "Label"), label, mono: true) }
                        if let file = s.file { row(String(localized: "Plist"), abbreviate(file), mono: true) }
                        if let log = s.logPath { row(String(localized: "Log"), abbreviate(log), mono: true) }
                        if let log = s.errorLogPath { row(String(localized: "Error log"), abbreviate(log), mono: true) }
                    }
                    .font(.system(size: 12))
                    if let cmd = s.command {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Runs").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(cmd).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    actions(s)
                    if let e = services.actionError {
                        ServiceProblem(error: e)
                    }
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "gearshape.2").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(services.services.isEmpty ? String(localized: "No services") : String(localized: "Select a service")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func actions(_ s: BrewService) -> some View {
        let available = BrewServices.actions(for: s)
        if services.needsSudo(s) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                    Text("Runs as \(s.user ?? "root") (started with sudo). Tankard only controls your own services and never runs sudo. To change it, run this in Terminal:")
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(available) { a in CommandBox(command: services.sudoCommand(a, s)) }
                Button("Open Terminal") { openTerminal() }
                    .controlSize(.small)
                    .help("Opens Terminal. Nothing is typed or run for you.")
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Text("Command").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(available) { a in CommandBox(command: services.command(a, s)) }
                HStack(spacing: 8) {
                    ForEach(available) { a in
                        let label = Label(a.title, systemImage: icon(a))
                        if a == available.first && a != .stop {
                            Button { run(a, s) } label: { label }
                                .buttonStyle(.primaryAction)
                                .disabled(store.isBusy)
                                .help(services.command(a, s))
                        } else {
                            Button { run(a, s) } label: { label }
                                .disabled(store.isBusy)
                                .help(services.command(a, s))
                        }
                    }
                    if let running = store.quickAction, running.hasPrefix("brew services") {
                        ProgressView().controlSize(.small).help(running)
                    }
                }
                Text(s.status == .none
                     ? String(localized: "Start also registers it to launch at login.")
                     : String(localized: "Stop also unregisters it from launching at login."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func run(_ a: ServiceAction, _ s: BrewService) {
        Task { await services.perform(a, on: s, store: store) }
    }

    private func icon(_ a: ServiceAction) -> String {
        switch a {
        case .start: return "play.fill"
        case .stop: return "stop.fill"
        case .restart: return "arrow.clockwise"
        }
    }

    private func openTerminal() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
    }
}

struct ServiceProblem: View {
    var error: StoreError

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error.title).font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !error.detail.isEmpty {
                Text(error.detail).font(.system(size: 11, design: error.detail.contains("\n") ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let cmd = error.terminalCommand { CommandBox(command: cmd) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }
}
