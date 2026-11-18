import SwiftUI
import TankardAppModel
import TankardCore

struct UpgradeSheet: View {
    var session: UpgradeSession
    @Bindable var store: AppStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandMark(size: 64, intelbrew: store.intelbrewMode)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 14, weight: .bold))
                    Text(session.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)

            HStack {
                Text(session.statusLine(behindBrewUpdate: store.sessionWaitsForBrewUpdate))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(session.countLine).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 12))
            .padding(.bottom, 6)
            // 0.8: while brew downloads, the bar is the download's (no total:
            // an indeterminate bar); the count stays on the right.
            Group {
                if let d = session.download {
                    if let f = d.fraction {
                        ProgressView(value: f)
                    } else {
                        ProgressView()
                    }
                } else {
                    ProgressView(value: session.fraction)
                }
            }
            .progressViewStyle(.linear)

            FlowLayout(spacing: 6) {
                ForEach(session.items) { item in
                    Chip(item: item, action: session.action)
                        .contextMenu {
                            // 0.8.3: one failed step again.
                            if session.retryableItems.contains(where: { $0.id == item.id }) {
                                Button("Retry \(item.package.name)") { store.retryInSheet([item]) }
                            }
                        }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 10)

            if let cmd = session.current?.command.display ?? session.runningFetch?.display
                ?? session.items.last(where: { $0.state.isTerminal })?.command.display {
                CommandBox(command: cmd).padding(.bottom, 8)
            }

            // 0.8.3: the password dialog is up: keep the Terminal route in view.
            if session.awaitingPassword, let cmd = session.current?.command.display {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Waiting for your password in the Tankard dialog. Don't see it? Cancel it and run this in Terminal:")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        CommandBox(command: cmd)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                .padding(.bottom, 8)
            }

            if let sudo = session.sudoCommand {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text((session.sudoOutcome ?? .noPrompt).message)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        CommandBox(command: sudo)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                .padding(.bottom, 8)
            }

            LogView(assembler: session.log)
                .frame(height: 236)

            // 0.8.3: what to do about a failure Tankard recognises.
            if let next = session.nextStep {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.uturn.forward.circle").foregroundStyle(.orange)
                    Text(next).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
            }

            HStack(spacing: 8) {
                Text(session.logURL.map { String(localized: "Full log saved to \(AppPaths.tilde($0))") } ?? String(localized: "Demo mode: no log file written"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if session.isFinished {
                    let retry = session.retryableItems
                    if !retry.isEmpty {
                        Button(session.total == 1 ? String(localized: "Retry") : String(localized: "Retry Failed (\(retry.count))")) {
                            store.retryInSheet()
                        }
                        .help("Run the failed steps again (the same checks as the Upgrade and Install buttons apply)")
                    }
                    Button("Done") { store.closeUpgrade() }
                        .buttonStyle(.primaryAction)
                        .keyboardShortcut(.defaultAction)
                } else {
                    // 0.8.3: every running sheet can stop now, one package
                    // or many; while brew changes a package it asks first.
                    if session.total > 1 && !session.stopRequested {
                        Button("Stop After Current") { session.stopAfterCurrent() }
                            .help("Let the current package finish, then skip the rest")
                    }
                    Button("Stop Now", role: .destructive) {
                        session.requestStopNow()
                    }
                    .help("Stop the running brew (and everything it started) immediately")
                    .disabled(!session.canStopNow)
                    Button("Hide") { store.showUpgradeSheet = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 600)
        .background(theme.window ?? .clear)
        .alert("Stop now?", isPresented: Binding(get: { session.confirmingStop }, set: { session.confirmingStop = $0 })) {
            Button("Stop Now", role: .destructive) { session.stopNow() }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text(session.stopNowWarning)
        }
    }
}

struct Chip: View {
    var item: UpgradeSession.Item
    var action: SessionAction = .upgrade
    @Environment(\.theme) private var theme

    var body: some View {
        let compiles = (action == .upgrade || action == .install) && item.package.kind == .formula && item.package.upgradeHasBottle != true
        let name = item.package.name + (compiles ? String(localized: " · source") : "")
        HStack(spacing: 4) {
            switch item.state {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            case .running:
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 11, height: 11)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            case .cancelled, .skipped:
                Image(systemName: "minus").font(.system(size: 9, weight: .bold))
            case .waiting:
                EmptyView()
            }
            Text(name)
        }
        .font(.system(size: 11, weight: item.state == .running ? .semibold : .regular))
        .foregroundStyle(foreground)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch item.state {
        case .done: return theme.badge(.bottle).foreground
        case .running: return theme.upgrade
        case .failed: return .red
        default: return .secondary
        }
    }

    private var background: Color {
        switch item.state {
        case .done: return theme.badge(.bottle).background
        case .running: return theme.upgrade.opacity(0.14)
        case .failed: return Color.red.opacity(0.12)
        default: return theme.chip
        }
    }
}

/// brew's output, monospace, following the end.
struct LogView: View {
    var assembler: LineAssembler
    @Environment(\.theme) private var theme

    var body: some View {
        let lines = assembler.displayLines
        let offset = assembler.droppedCount
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        // 0.8.4: never a URL's user:password on screen.
                        LogLine(text: line.contains("@") ? ProxySettings.maskText(line) : line, isCurrent: i == lines.count - 1, theme: theme)
                            .id(offset + i)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count + offset) { _, _ in
                proxy.scrollTo(offset + lines.count - 1, anchor: .bottom)
            }
            .onChange(of: lines.last) { _, _ in
                proxy.scrollTo(offset + lines.count - 1, anchor: .bottom)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(theme.logText)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.logBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .textSelection(.enabled)
    }
}

struct LogLine: View {
    var text: String
    var isCurrent: Bool
    var theme: Theme

    var body: some View {
        styled
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1.5)
    }

    private var styled: Text {
        if text.hasPrefix("$ ") {
            return Text(text).fontWeight(.semibold).foregroundColor(.secondary)
        }
        if text.hasPrefix("tankard: ") {
            return Text(text).foregroundColor(.orange)
        }
        if text.hasPrefix("Error:") {
            return Text(text).foregroundColor(.red)
        }
        let dim = text.hasPrefix("==> Fetching") || text.hasPrefix("==> Downloading") || text.hasPrefix("Removing:")
            || text.hasPrefix("#") || text.hasPrefix("Already up-to-date")
        if dim {
            return Text(text).foregroundColor(theme.logText.opacity(0.62))
        }
        if text.hasPrefix("==>") {
            return Text(verbatim: "==>").foregroundColor(theme.logArrow).fontWeight(.bold) + Text(text.dropFirst(3))
        }
        if text.hasPrefix("🍺") {
            return Text(verbatim: "🍺").foregroundColor(theme.logGood) + Text(text.dropFirst(1))
        }
        return Text(text)
    }
}
