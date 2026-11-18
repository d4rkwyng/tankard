import AppKit
import IOKit
import IOKit.ps
import Network
import SwiftUI
import TankardAppModel
import TankardCore

// v0.5: automatic updates. The settings section (Settings → Upgrades), the
// Auto-update log, the menu-bar line, and the real power/idle/app checks.

// MARK: conditions

/// The real Mac: IOKit's power source and HIDIdleTime, NSWorkspace's
/// running apps. Each call reads afresh (cheap; called once a minute at
/// most while a run is due).
@MainActor
final class SystemConditions: AutoUpdateConditions {
    /// `IOPSGetProvidingPowerSourceType`: "AC Power", "Battery Power" or
    /// "UPS Power". Only AC counts (a UPS means the mains are out).
    func onACPower() -> Bool? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else { return nil }
        return type == kIOPMACPowerKey
    }

    /// IOHIDSystem's HIDIdleTime (nanoseconds since the last keyboard,
    /// mouse or trackpad input), else Core Graphics' combined-session idle time.
    func idleSeconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let n = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                return n.doubleValue / 1_000_000_000
            }
        }
        guard let any = CGEventType(rawValue: ~0) else { return nil }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map { RunningApp(path: $0.bundleURL?.path, bundleID: $0.bundleIdentifier) }
    }
}

/// 0.8.5: tells the store's ScheduleConditions when the Mac sleeps and
/// wakes (NSWorkspace) and whether there is a network (NWPathMonitor), so
/// scheduled checks don't start asleep or offline. Lives as long as the app.
@MainActor
final class SleepAndNetworkWatch {
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    init(_ conditions: ScheduleConditions) {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { conditions.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { conditions.didWake(at: Date()) }
        })
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { conditions.network(satisfied: ok, at: Date()) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.mindtricks.tankard.path"))
    }
}

// MARK: settings

/// Settings → Upgrades → Automatic updates.
struct AutoUpdateSettingsSection: View {
    var updater: AutoUpdater
    var notifier: SystemNotifier?
    /// To warn when the menu-bar icon is off (Tankard then quits with its window).
    var appSettings: AppSettings?
    var showLog: () -> Void
    private let notificationNote = State<String?>(initialValue: nil)

    var body: some View {
        let settings = updater.settings
        VStack(alignment: .leading, spacing: 8) {
            ExplainedRow(help: SettingsHelp.autoUpgrade) {
                Toggle("Upgrade packages automatically", isOn: Binding(
                    get: { settings.enabled },
                    set: { on in
                        guard on != settings.enabled else { return }
                        settings.enabled = on
                        // The same permission flow as upgrade notifications:
                        // macOS asks only now, when the user turns it on.
                        if on, let notifier {
                            Task {
                                let ok = await notifier.requestAuthorization()
                                let text = ok ? nil : String(localized: "Notifications are off for Tankard, so runs are only in the Auto-update log. ")
                                    + (await notifier.authorizationText())
                                if notificationNote.wrappedValue != text { notificationNote.wrappedValue = text }
                            }
                        }
                    }))
            }
            // Everything below belongs to the checkbox: indented under its title.
            VStack(alignment: .leading, spacing: 8) {
                AutoUpdateScheduleRow(settings: settings)
                    .disabled(!settings.enabled)
                AutoUpdateRulesRows(rules: updater.rules)
                    .disabled(!settings.enabled)
                Text(statusLine(settings))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if appSettings?.showMenuBarIcon == false {
                    Text("The menu-bar icon is off, so Tankard quits when you close its window, and nothing runs then.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // One short line; the full safe-mode rules are in the ⓘ.
                ExplainedRow(help: SettingsHelp.safeMode) {
                    Text("Safe mode: bottles only; skips pinned packages and running apps.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let note = notificationNote.wrappedValue {
                    Text(note).font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line = AutoUpdateText.lastLine(updater.log.latest, now: Date()) {
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Show Auto-update Log…", action: showLog)
                        .controlSize(.small)
                    AutoUpdateSnoozeControl(rules: updater.rules)
                        .disabled(!settings.enabled)
                }
            }
            .padding(.leading, SettingsNote.indent)
        }
    }

    /// "Next run: tomorrow 03:00" or "Due now: …". Schedule only (no
    /// IOKit reads in a view body).
    private func statusLine(_ s: AutoUpdateSettings) -> String {
        guard s.enabled else { return String(localized: "Off") }
        // 0.8.3: brew.env turned brew's dependents check off.
        if let paused = updater.pausedReason { return paused }
        let now = Date()
        if updater.rules.isSnoozed(now: now) { return AutoUpdateText.snoozed(until: updater.rules.snoozeEnds, now: now) }
        let d = AutoUpdatePolicy.decide(enabled: true, schedule: s.schedule, since: s.since, lastRun: s.lastRun,
                                        launchedAt: .distantPast, now: now, onAC: true, idle: .infinity, busy: false)
        if case .notDue(let next) = d { return String(localized: "\(s.schedule.text()). Next run: \(AutoUpdateText.when(next, now: now))") }
        return String(localized: "\(s.schedule.text()). Due now: runs when the Mac is on AC power and idle")
    }
}

/// "Every day / Every week", the weekday, and the time.
struct AutoUpdateScheduleRow: View {
    @Bindable var settings: AutoUpdateSettings

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $settings.frequency) {
                ForEach(AutoUpdateFrequency.allCases) { f in Text(f.title).tag(f) }
            }
            .labelsHidden()
            .fixedSize()
            if settings.frequency == .weekly {
                Picker("", selection: $settings.weekday) {
                    ForEach(1...7, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1]).tag(d) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("at")
            DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
        }
    }

    /// Today at the chosen time; only a real change reaches the settings
    /// (which ignore an equal write anyway).
    private var time: Binding<Date> {
        let settings = settings
        return Binding(
            get: { Calendar.current.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                if let h = c.hour, h != settings.hour { settings.hour = h }
                if let m = c.minute, m != settings.minute { settings.minute = m }
            })
    }
}

// MARK: the log

struct AutoUpdateLogView: View {
    var log: AutoUpdateLog
    var done: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 22)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-update log").font(.system(size: 15, weight: .bold))
                    Text("The last \(AutoUpdateLog.maxRuns) automatic runs. brew's full output is in \(AppPaths.tilde(AppPaths.upgradeLog)).")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if log.runs.isEmpty {
                Text("No automatic runs yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(log.runs) { run in AutoUpdateRunRow(run: run) }
                    }
                }
                .frame(maxHeight: 380)
            }
            if let done {
                HStack {
                    Spacer()
                    Button("Done", action: done).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

struct AutoUpdateRunRow: View {
    var run: AutoUpdateRun
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(AutoUpdateText.when(run.startedAt, now: Date())).font(.system(size: 12.5, weight: .semibold))
                Text(run.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                if let end = run.finishedAt {
                    Text(duration(end.timeIntervalSince(run.startedAt))).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let note = run.note {
                Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            items(run.upgraded, symbol: "checkmark.circle.fill", color: theme.badge(.bottle).dot)
            items(run.failed, symbol: "xmark.octagon.fill", color: .red)
            items(run.skipped, symbol: "forward.fill", color: .secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.logBackground.opacity(0.55)))
    }

    @ViewBuilder
    private func items(_ list: [AutoUpdateRun.Item], symbol: String, color: Color) -> some View {
        ForEach(list) { item in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color).frame(width: 14)
                Image(systemName: item.isCask ? "macwindow" : "shippingbox").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(item.name).font(.system(size: 12, weight: .medium))
                Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func duration(_ s: TimeInterval) -> String {
        s < 60 ? String(localized: "\(Int(s.rounded())) s") : String(localized: "\(Int((s / 60).rounded())) min")
    }
}

// MARK: menu bar

/// "Last auto-update: today 03:12 · 4 upgraded" (shown once a run has
/// happened), "Auto-update: upgrading xz" while one runs, and "Tankard 0.6.0
/// available" when brew lists an upgrade for Tankard's own cask.
struct AutoUpdateMenuLine: View {
    var store: AppStore
    var openLog: () -> Void

    var body: some View {
        let updater = store.autoUpdate
        let selfUpdate = MenuBarSummary.selfUpdateLine(store.report?.packages)
        let line = updater.activity ?? AutoUpdateText.lastLine(updater.log.latest, now: Date())
        let paused = updater.settings.enabled && !updater.isRunning ? updater.pausedReason : nil
        if line != nil || selfUpdate != nil || paused != nil {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                // 0.8.3: brew.env turned brew's dependents check off.
                if let paused {
                    Label(paused, systemImage: "pause.circle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line {
                    Button(action: openLog) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: updater.isRunning ? "arrow.triangle.2.circlepath" : "clock.arrow.circlepath")
                                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                            Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show the Auto-update log")
                }
                if let selfUpdate {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                        Text(selfUpdate).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help("Upgrade Tankard with brew upgrade --cask tankard (auto-update leaves Tankard to brew)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }
}

// MARK: demo

@MainActor
enum AutoUpdateDemo {
    /// TANKARD_DEMO_AUTOUPDATE=1: auto-update on, with sample earlier runs.
    /// =run: also a real run now, through the demo's fake brew (on AC,
    /// idle, with Google Chrome "running" in the arm64 demo).
    static func apply(_ mode: String, store: AppStore) async {
        let updater = store.autoUpdate
        updater.settings.enabled = true
        updater.settings.hour = 3
        updater.settings.minute = 0
        let now = Date()
        updater.log.seed(samples(now: now))
        guard mode == "run" else { return }
        updater.conditions = FixedConditions(ac: true, idle: 3600,
                                             apps: [RunningApp(path: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome")])
        await updater.run(store: store, notifier: nil)
    }

    static func samples(now: Date) -> [AutoUpdateRun] {
        let day: TimeInterval = 86400
        let at3 = Calendar.current.date(bySettingHour: 3, minute: 4, second: 0, of: now) ?? now
        return [
            AutoUpdateRun(startedAt: at3.addingTimeInterval(-day), finishedAt: at3.addingTimeInterval(-day + 74),
                          upgraded: [.init(name: "git", isCask: false, detail: "2.53.0 → 2.53.1"),
                                     .init(name: "curl", isCask: false, detail: "8.19.0 → 8.19.1")],
                          skipped: [.init(name: "ruby", isCask: false, detail: AutoUpdateSkip.compiles.text)]),
            AutoUpdateRun(startedAt: at3.addingTimeInterval(-2 * day + 3 * 3600), finishedAt: at3.addingTimeInterval(-2 * day + 3 * 3600 + 9),
                          failed: [.init(name: "wireshark-app", isCask: true, detail: "needs administrator rights")]),
            AutoUpdateRun(startedAt: at3.addingTimeInterval(-3 * day), finishedAt: at3.addingTimeInterval(-3 * day + 6)),
        ]
    }
}
