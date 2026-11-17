import AppKit
import ServiceManagement
import SwiftUI
import TankardAppModel
import TankardCore
@preconcurrency import UserNotifications

/// The menu-bar extra's panel (`.menuBarExtraStyle(.window)`): the
/// upgrade count and list, Upgrade all, Open Tankard, Check now, Quit.
/// Reads the same AppStore (and so the same cache) as the window.
struct MenuBarContent: View {
    @Bindable var store: AppStore
    var openMain: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let summary = MenuBarSummary(packages: store.report?.packages)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BrandMark(size: 28, intelbrew: store.intelbrewMode)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.title).font(.system(size: 13, weight: .semibold))
                    if let updated = store.lastUpdated {
                        Text(store.isRefreshing ? (store.refreshPhase ?? "Checking…") : "Checked \(updatedAgo(updated, now: Date()))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if store.isRefreshing {
                        Text(store.refreshPhase ?? "Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if !summary.rows.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(summary.rows) { row in
                        HStack(spacing: 6) {
                            Image(systemName: row.isCask ? "macwindow" : "shippingbox")
                                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                            Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if row.compiles {
                                Image(systemName: "hammer.fill").font(.system(size: 9))
                                    .foregroundStyle(theme.badge(.source).dot)
                                    .help(CompileWarning(context: .upgrade).label)
                            }
                            Spacer(minLength: 8)
                            Text(row.versions).font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    if summary.moreCount > 0 {
                        Text("and \(summary.moreCount) more").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()
            VStack(alignment: .leading, spacing: 1) {
                MenuRow(title: "Upgrade all", systemImage: "arrow.up.circle", shortcut: nil,
                        enabled: summary.count > 0 && !store.isUpgrading && !store.isRefreshing) {
                    openMain()
                    store.requestUpgrade()
                }
                MenuRow(title: "Open Tankard", systemImage: "macwindow", shortcut: nil, enabled: true, action: openMain)
                MenuRow(title: "Check now", systemImage: "arrow.clockwise", shortcut: nil,
                        enabled: !store.isRefreshing && !store.isUpgrading) {
                    Task { await store.refresh(manual: true) }
                }
                Divider().padding(.vertical, 3)
                MenuRow(title: "Quit Tankard", systemImage: "power", shortcut: "Q", enabled: true) {
                    NSApp.terminate(nil)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
        }
        .frame(width: 300)
        .background(theme.window ?? .clear)
        .task { if store.report == nil { await store.start() } }
    }
}

/// A full-width, menu-like row.
struct MenuRow: View {
    var title: String
    var systemImage: String
    var shortcut: String?
    var enabled: Bool
    var action: () -> Void
    private let hover = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 16)
                Text(title)
                Spacer()
                if let shortcut { Text("⌘\(shortcut)").foregroundStyle(.secondary) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hover.wrappedValue && enabled ? Color.accentColor.opacity(0.25) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover.wrappedValue = $0 }
    }
}

/// The menu-bar label: a mug and the count.
struct MenuBarLabel: View {
    var store: AppStore

    var body: some View {
        let summary = MenuBarSummary(packages: store.report?.packages)
        HStack(spacing: 2) {
            Image(systemName: summary.count > 0 ? "mug.fill" : "mug")
            if let badge = summary.badge { Text(badge) }
        }
        .help(summary.title)
    }
}

// MARK: system integrations

/// UserNotifications. Permission is asked only when the user turns
/// notifications on in Settings. UNUserNotificationCenter needs a real app
/// bundle; under `swift run` this does nothing.
@MainActor
final class SystemNotifier: UpgradeNotifying {
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// "Allowed", "Denied in System Settings", "Not asked yet", or "Unavailable".
    func authorizationText() async -> String {
        guard let center else { return "Unavailable outside Tankard.app" }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return "Allowed"
        case .denied: return "Off for Tankard in System Settings → Notifications"
        case .notDetermined: return "macOS will ask when you turn this on"
        default: return "Unknown"
        }
    }

    func post(_ message: UpgradeNotificationDiff.Message) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        center.add(UNNotificationRequest(identifier: message.identifier, content: content, trigger: nil))
    }
}

/// SMAppService.mainApp (macOS 13+). With an ad-hoc signature the system
/// may refuse or forget the registration; `statusNote` says so.
@MainActor
final class LoginItem: LoginItemControlling {
    private var lastError: String?

    var isEnabled: Bool {
        let s = SMAppService.mainApp.status
        return s == .enabled || s == .requiresApproval
    }

    var statusNote: String? {
        if let lastError { return lastError }
        switch SMAppService.mainApp.status {
        case .requiresApproval: return "Waiting for approval in System Settings → General → Login Items."
        case .notFound: return Bundle.main.bundleURL.pathExtension == "app" ? nil : "Only available in Tankard.app."
        default: return nil
        }
    }

    func setEnabled(_ on: Bool) throws {
        lastError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "macOS refused: \(error.localizedDescription)"
            throw error
        }
    }
}

// MARK: About and Help

@MainActor
enum AboutPanel {
    static func show(intelbrew: Bool = false) {
        let versions = AboutInfo.panelVersions(bundle: Bundle.main.infoDictionary)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Tankard",
            .applicationVersion: versions.application,
            .version: versions.build,
            .credits: credits(intelbrew: intelbrew),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): AboutInfo.copyright,
        ])
    }

    static func credits(intelbrew: Bool) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 3
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        let s = NSMutableAttributedString(string: AboutInfo.author + "\n", attributes: base)
        func link(_ text: String, _ url: URL) {
            var a = base
            a[.link] = url
            s.append(NSAttributedString(string: text, attributes: a))
            s.append(NSAttributedString(string: "\n", attributes: base))
        }
        link("github.com/d4rkwyng/tankard", AboutInfo.repository)
        link(intelbrew ? AboutInfo.intelbrewBottlesLine : "Intelbrew: d4rkwyng/intelbrew", AboutInfo.intelbrew)
        var dim = base
        dim[.foregroundColor] = NSColor.secondaryLabelColor
        s.append(NSAttributedString(string: AboutInfo.licence + "\n", attributes: dim))
        // Homebrew: three short lines (the panel is narrow), "brew.sh" linked.
        var small = dim
        small[.font] = NSFont.systemFont(ofSize: 10)
        let line = NSMutableAttributedString(string: AboutInfo.homebrewLine + "\n", attributes: small)
        if let r = AboutInfo.homebrewLine.range(of: "brew.sh") {
            line.addAttribute(.link, value: AboutInfo.homebrew, range: NSRange(r, in: AboutInfo.homebrewLine))
        }
        s.append(line)
        s.append(NSAttributedString(string: AboutInfo.homebrewCopyright + "\n" + AboutInfo.notAffiliated, attributes: small))
        return s
    }
}
