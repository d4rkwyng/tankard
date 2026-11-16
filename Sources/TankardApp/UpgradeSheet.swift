import SwiftUI
import TankardAppModel
import TankardCore

struct UpgradeSheet: View {
    var session: UpgradeSession
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandMark(intelbrew: session.intelbrewMode, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 14, weight: .bold))
                    Text(session.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)

            HStack {
                Text(session.statusLine)
                Spacer()
                Text(session.countLine).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 12))
            .padding(.bottom, 6)
            ProgressView(value: session.fraction)
                .progressViewStyle(.linear)

            FlowLayout(spacing: 6) {
                ForEach(session.items) { item in
                    Chip(item: item)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 10)

            if let cmd = session.current?.command.display ?? session.items.last(where: { $0.state.isTerminal })?.command.display {
                CommandBox(command: cmd).padding(.bottom, 8)
            }

            if let sudo = session.sudoCommand {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This step needs administrator rights, which Tankard can't ask for. Run this in Terminal:")
                            .font(.system(size: 12))
                        CommandBox(command: sudo)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                .padding(.bottom, 8)
            }

            LogView(assembler: session.log)
                .frame(height: 236)

            HStack(spacing: 8) {
                Text(session.logURL.map { "Full log saved to \(AppPaths.tilde($0))" } ?? "Demo mode: no log file written")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if session.isFinished {
                    Button("Done") { store.closeUpgrade() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    if session.stopRequested {
                        Button("Stop Now", role: .destructive) { session.stopNow() }
                            .help("Stop the running brew (and everything it started) immediately")
                    } else {
                        Button("Stop After Current") { session.stopAfterCurrent() }
                            .help("Let the current package finish, then skip the rest")
                    }
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
    }
}

struct Chip: View {
    var item: UpgradeSession.Item

    var body: some View {
        let name = item.package.name + (item.package.kind == .formula && item.package.upgradeHasBottle != true ? " · source" : "")
        HStack(spacing: 4) {
            switch item.state {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            case .running:
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 11, height: 11)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            case .cancelled:
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
        case .done: return BadgePalette.of(.bottle).foreground
        case .running: return .accentColor
        case .failed: return .red
        default: return .secondary
        }
    }

    private var background: Color {
        switch item.state {
        case .done: return BadgePalette.of(.bottle).background
        case .running: return Color.accentColor.opacity(0.12)
        case .failed: return Color.red.opacity(0.12)
        default: return Theme.chip
        }
    }
}

/// brew's output, monospace, following the end.
struct LogView: View {
    var assembler: LineAssembler

    var body: some View {
        let lines = assembler.displayLines
        let offset = assembler.droppedCount
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        LogLine(text: line, isCurrent: i == lines.count - 1)
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
        .foregroundStyle(Theme.logText)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.logBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .textSelection(.enabled)
    }
}

struct LogLine: View {
    var text: String
    var isCurrent: Bool

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
            return Text(text).foregroundColor(Theme.logText.opacity(0.55))
        }
        if text.hasPrefix("==>") {
            return Text("==>").foregroundColor(Theme.logArrow).fontWeight(.bold) + Text(text.dropFirst(3))
        }
        if text.hasPrefix("🍺") {
            return Text("🍺").foregroundColor(Theme.logGood) + Text(text.dropFirst(1))
        }
        return Text(text)
    }
}
