import AppKit
import os
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
    /// 0.5: the "Last auto-update" line opens the log.
    var openAutoUpdateLog: () -> Void = {}
    @Environment(\.theme) private var theme

    var body: some View {
        let summary = MenuBarSummary(packages: store.report?.packages)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BrandMark(size: 28, intelbrew: store.intelbrewMode)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.title).font(.system(size: 13, weight: .semibold))
                    if let updated = store.lastUpdated {
                        Text(store.isRefreshing ? (store.refreshPhase ?? String(localized: "Checking…")) : String(localized: "Checked \(updatedAgo(updated, now: Date()))"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if store.isRefreshing {
                        Text(store.refreshPhase ?? String(localized: "Checking…")).font(.system(size: 11)).foregroundStyle(.secondary)
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
                        .contentShape(Rectangle())
                        .contextMenu { menuBarRowMenu(row) }
                    }
                    if let more = summary.moreText {
                        // 0.5: opens the window on the Upgrades list.
                        Button {
                            openMain()
                            store.showUpgrades()
                        } label: {
                            Text(more).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show all upgrades in Tankard")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // 0.6.1: a running scan, or how the last one ended.
            if store.insights.scanState == .running || store.insights.scanOutcome != nil {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                        .accessibilityHidden(true)
                    ScanProgressView(store: store)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            VulnerabilityMenuNotice(store: store, openMain: openMain)
            AutoUpdateMenuLine(store: store, openLog: openAutoUpdateLog)
            AutoUpdateSnoozeMenuRow(updater: store.autoUpdate)

            Divider()
            VStack(alignment: .leading, spacing: 1) {
                MenuRow(title: String(localized: "Upgrade All"), systemImage: "arrow.up.circle", shortcut: nil,
                        enabled: summary.count > 0 && !store.isUpgrading && !store.isRefreshing) {
                    openMain()
                    store.requestUpgrade()
                }
                MenuRow(title: String(localized: "Open Tankard"), systemImage: "macwindow", shortcut: nil, enabled: true, action: openMain)
                MenuRow(title: String(localized: "Check Now"), systemImage: "arrow.clockwise", shortcut: nil,
                        enabled: !store.isRefreshing && !store.isUpgrading) {
                    Task { await store.refreshFromUser(windowInFront: { MainWindowState.inFront }) }
                }
                Divider().padding(.vertical, 3)
                MenuRow(title: String(localized: "Quit Tankard"), systemImage: "power", shortcut: "Q", enabled: true) {
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

extension MenuBarContent {
    /// Upgrade (the window's path, so a compiling upgrade shows its plan
    /// first) and Copy Name.
    @ViewBuilder
    func menuBarRowMenu(_ row: MenuBarSummary.Row) -> some View {
        if let p = store.packages.first(where: { $0.id == row.id }) {
            MenuEntries(entries: ContextMenus.menuBarRow(p, compileWarning: store.deps.classifier.upgradeWarning(p),
                                                         busy: store.isUpgrading || store.isRefreshing)) { action in
                switch action {
                case .upgrade:
                    openMain()
                    store.requestUpgrade([p])
                case .copy(let s): ContextMenuActions.copy(s)
                default: break
                }
            }
        }
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
                if let shortcut { Text(verbatim: "⌘\(shortcut)").foregroundStyle(.secondary) }
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
            // A pixel tankard (handle on the left, like the logo); foam only
            // when upgrades are waiting.
            Image(nsImage: summary.count > 0 ? MenuBarIcon.full : MenuBarIcon.empty)
            if let badge = summary.badge { Text(badge) }
            // 0.4: the optional notice for new vulnerabilities.
            if !store.insights.newVulnerableFormulae.isEmpty { Image(systemName: "exclamationmark.triangle") }
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
    private static let log = Logger(subsystem: AppPaths.bundleID, category: "notifications")

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    /// 0.8.2: makes macOS show Tankard's notifications as banners while
    /// Tankard is the active app too (without a delegate it only puts them
    /// in Notification Centre). Tankard posts while active only for a check
    /// the user can't see: the window closed or behind another window.
    /// Called once at launch; logs the permission state.
    static func install() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationPresenter.shared
        NotificationActions.registerCategories(center)
        Task {
            let status = await center.notificationSettings().authorizationStatus
            log.notice("authorization at launch: \(Self.describe(status), privacy: .public)")
        }
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        let ok = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        Self.log.notice("authorization requested: \(ok ? "granted" : "not granted", privacy: .public)")
        return ok
    }

    /// Denied in System Settings (the toggle stays on, but nothing shows).
    func isDenied() async -> Bool {
        guard let center else { return false }
        return await center.notificationSettings().authorizationStatus == .denied
    }

    /// "Allowed", "Denied in System Settings", "Not asked yet", or "Unavailable".
    func authorizationText() async -> String {
        guard let center else { return String(localized: "Unavailable outside Tankard.app") }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return String(localized: "Allowed")
        case .denied: return String(localized: "Off for Tankard in System Settings → Notifications")
        case .notDetermined: return String(localized: "macOS will ask when you turn this on")
        default: return String(localized: "Unknown")
        }
    }

    func post(_ message: UpgradeNotificationDiff.Message) {
        guard let center else {
            Self.log.notice("post skipped: not running from Tankard.app")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        NotificationActions.configure(content, for: message)
        let id = message.identifier
        Task {
            let status = await center.notificationSettings().authorizationStatus
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                Self.log.notice("posted \(id.prefix(20), privacy: .public) (authorization: \(Self.describe(status), privacy: .public))")
            } catch {
                Self.log.error("post failed (authorization: \(Self.describe(status), privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static func describe(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        default: return "other(\(s.rawValue))"
        }
    }

    /// System Settings ▸ Notifications. Opens the pane itself: a `?id=<bundle id>`
    /// deep link to Tankard's own entry is unverified on current macOS, and
    /// NSWorkspace.open reports success even when the query is ignored.
    static func openSystemSettings() {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }
}

/// The notification centre's delegate (it holds it weakly, hence `shared`).
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// 0.8.2: whether the user can see the list right now: Tankard is the
/// active app and a main window is on screen (not minimized).
@MainActor
enum MainWindowState {
    static var inFront: Bool {
        guard NSApp.isActive else { return false }
        // The WindowGroup's id is "main" (its windows: "main-AppWindow-1"),
        // as ScriptLaunch and openMain look it up.
        return NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible && !$0.isMiniaturized }
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
        case .requiresApproval: return String(localized: "Waiting for approval in System Settings → General → Login Items.")
        case .notFound: return Bundle.main.bundleURL.pathExtension == "app" ? nil : String(localized: "Only available in Tankard.app.")
        default: return nil
        }
    }

    func setEnabled(_ on: Bool) throws {
        lastError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = String(localized: "macOS refused: \(error.localizedDescription)")
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
