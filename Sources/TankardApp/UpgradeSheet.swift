import SwiftUI
import TankardAppModel
import TankardCore

struct UpgradeSheet: View {
    var session: UpgradeSession
    @Bindable var store: AppStore
    @Environment(\.theme) private var theme
    /// 0.8.5: shown in the progress panel (a menu-bar Upgrade), not the sheet.
    @Environment(\.inProgressPanel) private var inPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandMark(size: 64, intelbrew: store.intelbrewMode)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 14, weight: .bold))
                    Text(session.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .panelButtonRow("session.title")
            .padding(.bottom, 14)

            HStack {
                // 0.10: while brew downloads, the line carries the speed and
                // time left, which change with no new bytes (a stall), so
                // it is redrawn every second then; otherwise as before.
                // The timeline only triggers the redraw: the time read is
                // the session's clock, once per render (SessionStatusText).
                if session.download != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        SessionStatusText(session: session, behindBrewUpdate: store.sessionWaitsForBrewUpdate, tick: context.date)
                    }
                } else {
                    SessionStatusText(session: session, behindBrewUpdate: store.sessionWaitsForBrewUpdate, tick: nil)
                }
                Spacer()
                Text(session.countLine).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 12))
            .padding(.bottom, 6)
            // Result notes (the recovery command, a kept copy, "Stop came
            // too late") in full. The log below still has them, one orange
            // line each, cut off at the sheet's width.
            if session.isFinished, !session.sessionNotes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.sessionNotes) { note in
                        SessionNoteLine(note: note)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                .padding(.bottom, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("session.notes")
            }
            // 0.8.5: a build from source: time so far, and an estimate from
            // this Mac's earlier builds when there is one.
            if !session.compilingItems.isEmpty, !session.isFinished {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    if let line = session.buildLine(at: context.date) {
                        Text(line)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(line)
                            .padding(.bottom, 6)
                    }
                }
            }
            // 0.8.8: a download that hasn't moved for a while (offline).
            if session.current != nil, !session.isFinished {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if let hint = session.networkHint(at: context.date) {
                        Label(hint, systemImage: "wifi.exclamationmark")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .help(hint)
                            .padding(.bottom, 6)
                    }
                }
            }
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

            // 0.8.8 (gauntlet 15): a 15-step Restore's chips took 12 rows
            // and pushed Done below a 660 pt window. Past a few rows they
            // scroll; a short run's chips take only their own height.
            ScrollView(.vertical) {
                FlowLayout(spacing: 6) {
                    ForEach(session.items) { item in
                        Chip(item: item, action: session.action, title: session.chipName(item),
                             incomplete: session.sudoSkipped[item.id] != nil,
                             warning: session.replacedDespiteError.contains(item.id))
                            .contextMenu {
                                // 0.8.3: one failed step again.
                                if session.retryableItems.contains(where: { $0.id == item.id }) {
                                    Button("Retry \(item.package.name)") { store.retryInSheet([item]) }
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: CGFloat(SessionSheetLayout.chipsMaxHeight))
            .fixedSize(horizontal: false, vertical: true)
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

            // 0.8.8 (gauntlet 3, B2): done, but without the part that needed
            // the password (hiddenbar's background service stays).
            let skipped = session.items.compactMap { session.sudoSkippedLine($0) }
            if !skipped.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(skipped, id: \.self) { line in
                            Text(line).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                .padding(.bottom, 8)
            }

            // 0.8.8: the log gives way first when the window is short.
            LogView(assembler: session.log)
                .frame(minHeight: CGFloat(SessionSheetLayout.logMinHeight), idealHeight: CGFloat(SessionSheetLayout.logHeight),
                       maxHeight: CGFloat(SessionSheetLayout.logHeight))

            // 0.8.3: what to do about a failure Tankard recognises.
            if let next = session.nextStep {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.uturn.forward.circle").foregroundStyle(.orange)
                    Text(next).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    // 0.8.7: brew refused a package from an untrusted tap.
                    if session.failureKinds.last == .untrustedTap, let r = session.untrustedTap {
                        Spacer(minLength: 4)
                        TrustTapButton(store: store, refusal: r)
                    }
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
                    if inPanel {
                        Button("Show in Tankard") { ProgressPanelController.showInTankard(store) }
                            .help("Open the Tankard window with this run in it")
                    }
                    // 0.8.5: the panel stays up only when something went
                    // wrong (a clean run closes it by itself): Close.
                    Button(inPanel ? String(localized: "Close") : String(localized: "Done")) { store.closeUpgrade() }
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
                    if inPanel {
                        // 0.8.5: Esc and the close button hide the panel
                        // (the menu-bar panel's Show Upgrade Progress
                        // brings it back); this moves the run to the window.
                        Button("Show in Tankard") { ProgressPanelController.showInTankard(store) }
                            .help("Open the Tankard window with this run in it")
                    } else {
                        Button("Hide") { store.showUpgradeSheet = false }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .panelButtonRow("session.buttons")
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 600)
        // 0.8.8 (gauntlet 15): never taller than the window (the 0.8.6
        // promise); the log shrinks to fit. The progress panel sizes
        // itself to the page and scrolls past the screen's height.
        .frame(maxHeight: inPanel ? nil : SessionSheetLayout.maxHeight(room: store.sheetRoom).map { CGFloat($0) }, alignment: .top)
        .background(theme.window ?? .clear)
        .alert("Stop now?", isPresented: Binding(get: { session.confirmingStop }, set: { session.confirmingStop = $0 })) {
            Button("Stop Now", role: .destructive) { session.stopNow() }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text(session.stopNowWarning)
        }
    }
}

/// The sheet's status line ("Downloading 10 of 11 · 2.1 of 2.3 GB (91%) ·
/// 4.2 MB/s · about 50 sec left").
struct SessionStatusText: View {
    var session: UpgradeSession
    var behindBrewUpdate: Bool
    /// The TimelineView's date while a download runs, nil otherwise. Only
    /// a change of input, so SwiftUI redraws each second; never read as
    /// the time (0.10 review: a poll can land after it, and the newest
    /// bytes would go with an older rate).
    var tick: Date?

    var body: some View {
        // One time per render, for both the visible line and its label.
        let at = session.now()
        Text(session.statusLine(behindBrewUpdate: behindBrewUpdate, at: at))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            // 0.10: read as a sentence (commas, units in words); VoiceOver
            // reads it again when asked, nothing is announced each second.
            .accessibilityLabel(Text(session.statusAccessibilityLabel(behindBrewUpdate: behindBrewUpdate, at: at)))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct Chip: View {
    var item: UpgradeSession.Item
    var action: SessionAction = .upgrade
    /// 0.8.5: the session's name for the step ("xz 5.8.3" for one
    /// version of several); nil: the package's name.
    var title: String? = nil
    /// 0.8.8 (gauntlet 3, B2): done, but brew skipped the part that needed
    /// the password: a warning mark, not a ✓.
    var incomplete = false
    /// 0.8.10: done, but brew reported an error after the app was replaced.
    var warning = false
    @Environment(\.theme) private var theme

    var body: some View {
        let compiles = (action == .upgrade || action == .install) && item.package.kind == .formula && item.package.upgradeHasBottle != true
        let name = (title ?? item.package.name) + (compiles ? String(localized: " · source") : "")
        HStack(spacing: 4) {
            switch item.state {
            case .done where incomplete:
                Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Done, with a step skipped"))
            case .done where warning:
                Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Done, with a warning"))
            case .done:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    .accessibilityLabel(Text("Done"))
            case .running:
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 11, height: 11)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .accessibilityLabel(Text("Failed"))
            case .cancelled, .skipped:
                Image(systemName: "minus").font(.system(size: 9, weight: .bold))
                    .accessibilityLabel(Text("Not run"))
            case .waiting:
                EmptyView()
            }
            Text(name)
            // 0.8.5: this step will ask for the password.
            if action == .upgrade, AdminPassword.required(item.package), !item.state.isTerminal {
                PasswordLockBadge(size: 8.5)
            }
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

/// One result note, wrapped and selectable. A note with a command gets
/// a Copy button for that command (several: one per line). The command
/// is the note's own field. The sentence is not scanned for backticks.
struct SessionNoteLine: View {
    var note: SessionNote
    // `State(...)`, not `@State`: see CommandBox (the macro needs Xcode).
    private let copiedState = State(initialValue: false)
    private var copied: Bool {
        get { copiedState.wrappedValue }
        nonmutating set { copiedState.wrappedValue = newValue }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(note.attributed)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let command = note.copyText {
                Button {
                    copyToPasteboard(command)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .help(note.commands.count > 1 ? Text("Copy the commands") : Text("Copy command"))
                .accessibilityLabel(copyLabel)
            }
        }
    }

    private var copyLabel: Text {
        if copied { return Text("Copied") }
        if note.commands.count > 1 { return Text("Copy the commands") }
        return Text("Copy command")
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
