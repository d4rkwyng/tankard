import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

struct ContentView: View {
    @Bindable var store: AppStore
    var options: LaunchOptions
    var appearance: AppearanceSettings
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let theme = Theme.of(appearance.theme)
        Group {
            if store.homebrewState.needsWelcome {
                WelcomeView(store: store, isDemo: options.isDemo)
            } else {
                main(theme)
            }
        }
        .navigationTitle(store.intelbrewMode ? "Intelbrew" : "Tankard")
        .navigationSubtitle(store.intelbrewMode ? String(localized: "Intel bottles for macOS 14+") : "Homebrew")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BrandMark(size: 32, intelbrew: store.intelbrewMode)
                    .padding(.horizontal, 4)
                    // 0.6.1: a drag on the logo moves the window, as on
                    // the rest of the toolbar.
                    .overlay(WindowDragArea())
            }
            if !store.homebrewState.needsWelcome {
                ToolbarItem(placement: .principal) {
                    // 0.8.10: on macOS 26 an AppKit view, so the focused
                    // element says it is focused (ToolbarAccessibility).
                    if #available(macOS 26, *) {
                        ToolbarSegmentedPicker(title: String(localized: "View"), selection: $store.tab, options: MainTab.allCases,
                                               label: \.title, theme: Theme.of(appearance.theme),
                                               help: String(localized: "Installed packages, everything Homebrew has, or your services (⌘1, ⌘2, ⌘3)"))
                    } else {
                        ThemedSegmentedPicker(title: String(localized: "View"), selection: $store.tab, options: MainTab.allCases, label: \.title)
                            .environment(\.theme, Theme.of(appearance.theme))
                            .help("Installed packages, everything Homebrew has, or your services (⌘1, ⌘2, ⌘3)")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small).frame(width: 28)
                            .help(store.refreshPhase ?? String(localized: "Refreshing"))
                            // 0.9.3: named like its tooltip (without a label it had no name).
                            .accessibilityLabel(Text(AccessibilityText.refreshing(phase: store.refreshPhase)))
                            .accessibilityIdentifier(AccessibilityText.ID.refreshProgress)
                    } else {
                        Button {
                            Task { await store.refreshFromUser(windowInFront: { MainWindowState.inFront }) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Check Homebrew for new versions and reload the list (⌘R)")
                        .disabled(store.isUpgrading)
                    }
                }
            }
        }
        // 0.8.5: not while the activity is in the progress panel (a
        // menu-bar Upgrade); a dismissal only closes the sheet's own.
        .sheet(isPresented: Binding(get: { store.showsActivitySheet },
                                    set: { if !$0 && store.showsActivitySheet { store.showUpgradeSheet = false } })) {
            ActivitySheet(store: store).themed(theme)
        }
        .task {
            await store.start()
            await applyLaunchOptions()
            if let script = options.script { await script.run(store: store) }
        }
        .onChange(of: activeState) { _, state in
            if state == .key { store.revalidateIfStale() }
        }
        // 0.8.6 (UI M2): how tall a sheet can be in this window.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { store.sheetRoom = Double(geo.size.height); store.windowWidth = Double(geo.size.width) }
                .onChange(of: geo.size.height) { _, h in store.sheetRoom = Double(h) }
                .onChange(of: geo.size.width) { _, w in store.windowWidth = Double(w) }
        })
        .onChange(of: store.tab) { _, tab in
            store.tabChanged(to: tab)
            if tab == .discover { openDiscover() }
            if tab == .services { store.openServices() }
        }
        // 0.9.4 (bug hunt): a tab chosen before brew's status was in (⌘3
        // during the first read) waited for it forever: its store is made
        // only on a tab change. Made now, once the status is in.
        .onChange(of: store.report != nil) { _, ready in
            guard ready else { return }
            if store.tab == .discover { openDiscover() }
            if store.tab == .services { store.openServices() }
        }
        // 0.9.4 (bug hunt R3): and a window opened with the tab already
        // chosen and the status already in (neither changes then).
        .onAppear { if store.report != nil { openSelectedTabStore() } }
        .onChange(of: store.intelbrewMode, initial: true) { _, intelbrew in
            AppResources.updateDockIcon(intelbrew: intelbrew)
        }
        .themed(theme)
        .modifier(NotificationWindowOpener())
        .background(SnapshotHook(request: options.snapshot, makeView: { name in
            switch name {
            case "menubar":
                return AnyView(MenuBarContent(store: store, openMain: {})
                    .themed(theme)
                    .background(theme.window ?? Color(nsColor: .windowBackgroundColor)))
            case "settings":
                // A Settings tab's content (an off-screen TabView draws no tab
                // bar): General, or TANKARD_SETTINGS_TAB=upgrades for the whole
                // Upgrades tab as the Settings window shows it (0.8.8:
                // =appearance for that tab).
                let tab = ProcessInfo.processInfo.environment["TANKARD_SETTINGS_TAB"]
                let content: AnyView = tab == "upgrades"
                    ? AnyView(UpgradeSettings(settings: store.insights.settings, autoUpdater: store.autoUpdate, notifier: SystemNotifier(),
                                              appSettings: store.settings, rollbackSettings: store.restorePoints.settings, store: store))
                    : tab == "appearance" ? AnyView(AppearanceTab(appearance: appearance))
                    : AnyView(GeneralSettings(settings: store.settings, notifier: SystemNotifier(), loginItem: LoginItem(),
                                              backgroundUpdateOptOut: store.backgroundUpdateOptOut))
                return AnyView(content
                    .frame(width: SettingsFit.width)
                    .themed(theme)
                    .background(theme.window ?? Color(nsColor: .windowBackgroundColor)))
            case "settings-autoupdate":
                // 0.5: Settings → Upgrades with its Automatic updates section.
                return AnyView(UpgradeSettings(settings: store.insights.settings, autoUpdater: store.autoUpdate, appSettings: store.settings)
                    .frame(width: 460)
                    .themed(theme)
                    .background(theme.window ?? Color(nsColor: .windowBackgroundColor)))
            case "autoupdate-log":
                return AnyView(AutoUpdateLogView(log: store.autoUpdate.log, done: nil, store: store)
                    .themed(theme)
                    .background(theme.window ?? Color(nsColor: .windowBackgroundColor)))
            case "settings-upgrades":
                return AnyView(UpgradeSettings(settings: store.insights.settings, store: store)
                    .frame(width: 460)
                    .themed(theme)
                    .background(theme.window ?? Color(nsColor: .windowBackgroundColor)))
            default:
                return nil
            }
        }, intelbrew: { store.intelbrewMode }))
    }

    @ViewBuilder
    private func main(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            if let notice = store.replaceLeftoverNotice {
                ReplaceLeftoverBanner(store: store, notice: notice)
                Divider()
            }
            if let text = store.bottleNoticeText {
                BottleNoticeBanner(store: store, text: text)
                Divider()
            }
            if store.tab == .installed {
                SummaryStrip(store: store)
                Divider()
                if store.filter == .vulnerable {
                    VulnerableScanBar(store: store)
                    Divider()
                }
                if let error = store.error {
                    ErrorBanner(error: error) { store.dismissError() }
                    Divider()
                }
                HStack(spacing: 0) {
                    PackageTable(store: store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    DetailPane(store: store)
                        .frame(width: CGFloat(DetailPaneWidth.width(window: store.windowWidth)))
                        .frame(maxHeight: .infinity)
                        .background(theme.pane)
                }
            } else if store.tab == .services, let services = store.services {
                ServicesView(store: store, services: services)
            } else if store.tab == .discover, let discover = store.discover {
                DiscoverView(store: store, discover: discover)
            } else if store.tab == .services {
                // 0.9.4 (bug hunt): it said "Discover…" on the Services tab.
                ContentUnavailableView("Services needs Homebrew's status first", systemImage: "gearshape.2",
                                       description: Text("Waiting for brew…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Discover needs Homebrew's status first", systemImage: "magnifyingglass",
                                       description: Text("Waiting for brew…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            StatusBar(store: store)
        }
        .sheet(item: $store.uninstallCandidate) { p in
            UninstallSheet(store: store, package: p).themed(theme)
        }
        .sheet(isPresented: $store.showCleanupSheet) {
            if let c = store.cleanup { CleanupSheet(store: store, cleanup: c).themed(theme) }
        }
        .sheet(item: $store.managementSheet) { kind in
            HomebrewManagementSheet(store: store, kind: kind, isDemo: options.isDemo).themed(theme)
        }
        .sheet(isPresented: BrewfileSheet.binding(store.brewfile)) {
            BrewfileSheet(store: store, brewfile: store.brewfile).themed(theme)
        }
        .sheet(isPresented: $store.showAutoUpdateLog) {
            AutoUpdateLogView(log: store.autoUpdate.log, done: { store.showAutoUpdateLog = false }, store: store).themed(theme)
        }
        .sheet(isPresented: RestorePointsSheet.binding(store.restorePoints)) {
            RestorePointsSheet(store: store, points: store.restorePoints).themed(theme)
        }
        .sheet(item: $store.toolSheet) { s in
            ToolSheetView(store: store, sheet: s).themed(theme)
        }
        .sheet(item: Bindable(store.insights).postInstallNotes) { n in
            PostInstallNotesSheet(notes: n) { store.insights.postInstallNotes = nil }.themed(theme)
        }
        .selfUpdateSheets(store: store, theme: theme)
        // Here, not on the window: the welcome screen has nothing to search.
        .searchable(text: searchBinding, placement: .toolbar,
                    prompt: store.tab == .installed ? String(localized: "Search installed") : store.tab == .services ? String(localized: "Search services") : String(localized: "Search Homebrew"))
    }

    /// The toolbar search field searches the tab on screen.
    private var searchBinding: Binding<String> {
        Binding(
            get: {
                switch store.tab {
                case .installed: return store.search
                case .discover: return store.discover?.query ?? ""
                case .services: return store.services?.query ?? ""
                }
            },
            set: { v in
                switch store.tab {
                case .installed: store.search = v
                case .discover: store.discover?.query = v
                case .services: store.services?.query = v
                }
            })
    }

    /// Discover loads its catalog when first opened, never at launch.
    /// The selected tab's store (Discover, Services), once the status is in.
    private func openSelectedTabStore() {
        if store.tab == .discover { openDiscover() }
        if store.tab == .services { store.openServices() }
    }

    private func openDiscover() {
        guard let d = store.openDiscover() else { return }
        Task { await d.activate() }
    }

    @MainActor
    private func applyLaunchOptions() async {
        if let f = options.filter { store.filter = f }
        if let q = options.search { store.search = q }
        await applyV04ALaunchOptions(store: store, options: options)
        await applyBrewfileLaunchOption(store: store, options: options)
        if let name = options.select, let p = store.packages.first(where: { $0.name == name }) {
            store.selection = p.id
        }
        if let (name, delay) = options.reselect {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                if let p = store.packages.first(where: { $0.name == name }) { store.selection = p.id }
            }
        }
        await applyV06ALaunchOptions(store: store, options: options)
        await applyTapsLaunchOptions(store: store, options: options)
        await applyAdoptLaunchOptions(store: store, options: options)
        await applyOnboardingLaunchOptions(store: store, options: options)
        // 0.7 demo: TANKARD_DEMO_RESTORE=1 opens Restore Points; =confirm also opens the confirmation.
        if options.demo != nil, let mode = ProcessInfo.processInfo.environment["TANKARD_DEMO_RESTORE"], !mode.isEmpty {
            Demo.seedRestorePoints(store)
            store.openRestorePoints()
            if mode == "confirm", let p = store.restorePoints.points.first { store.requestRestore(p, pinAfter: true) }
        }
        if options.demo != nil, let mode = options.demoAutoUpdate {
            await AutoUpdateDemo.apply(mode, store: store)
        }
        if options.demo != nil, let name = ProcessInfo.processInfo.environment["TANKARD_DEMO_PASSWORD"], !name.isEmpty {
            store.demoRequirePassword(name)
        }
        if options.demo != nil && options.demoUpgrade {
            store.startUpgrade()
        }
        if options.demo != nil && options.demoPlan {
            store.requestUpgrade()
        }
        if options.demo != nil && options.demoVulnNotice {
            store.insights.settings.notifyNewVulnerabilities = true
            await store.insights.waitForIdle()
            store.insights.settings.seenVulnerabilities = []
        }
        if options.demo != nil && options.demoBottleNotice {
            store.demoBottleNotice()
        }
        if options.demo != nil && options.demoNotes {
            // 0.4: upgrade, close the finished sheet, and the notes follow.
            store.startUpgrade()
            while store.upgrade?.isFinished != true || store.isRefreshing { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .milliseconds(500))
            store.closeUpgrade()
        }
        if options.demo != nil && options.demoCleanup {
            store.openCleanup()
            if options.demoCleanupRun {
                try? await Task.sleep(for: .seconds(2))
                store.startCleanup()
            }
        }
        if options.demo != nil && options.demoAppManagement == "1" {
            store.showAppManagementExplainer()
        }
        // 0.8.1: the Run again offer after a relaunch (saved, then read back).
        if options.demo != nil && options.demoAppManagement == "resume",
           let p = store.packages.first(where: { $0.kind == .cask && $0.upgradeAvailable }) {
            store.demoAppManagementResume([p])
        }
        // 0.8.1: the relaunch page, for a blocked upgrade.
        if options.demo != nil && options.demoAppManagement == "relaunch",
           let p = store.packages.first(where: { $0.kind == .cask }) {
            store.showAppManagementExplainer(packages: [p], reason: .blocked)
            store.appManagementDone()
        }
        if options.demo != nil && options.demoReplace, let p = store.selectedPackage {
            store.startReplaceWithBottle([p])
        }
        if options.demo != nil, let name = options.demoUninstall,
           let p = store.packages.first(where: { $0.name == name }) {
            store.selection = p.id
            store.requestUninstall(p)
        }
        // 0.8.3: a click on a menu-bar panel line, after a moment (so a
        // search, filter or selection set above is what it resets).
        if options.demo != nil, let what = options.demoMenuBarShow {
            try? await Task.sleep(for: .seconds(1))
            switch what.lowercased() {
            case "upgrades": store.showFromMenuBar(.upgrades)
            case "vulnerable": store.showFromMenuBar(.vulnerable)
            // 0.8.5: the menu-bar panel's Upgrade All with the window not
            // in front: the progress panel.
            case "upgrade": store.requestUpgradeFromMenuBar(nil, windowInFront: false)
            default:
                if let p = store.packages.first(where: { $0.name == what }) { store.showFromMenuBar(.package(p.id)) }
            }
        }
        // 0.8.5: the progress panel on one page (Scripts/panel-check.sh).
        if options.demo != nil, let page = ProcessInfo.processInfo.environment["TANKARD_DEMO_PANEL"], !page.isEmpty {
            store.demoProgressPanel(page)
        }
        if options.tab == .discover {
            store.tab = .discover
            guard let d = store.openDiscover() else { return }
            if options.discoverAll { d.bottledOnly = false }
            await d.activate()
            if let q = options.discoverQuery {
                d.query = q
                await d.searchNow()
            }
            if let name = options.discoverSelect, let e = d.results.first(where: { $0.name == name }) {
                d.selection = e.id
                await d.waitForDetails()
                if options.demo != nil && options.demoInstall, let e = d.selectedEntry {
                    store.startInstall(e)
                }
                if options.demo != nil && options.demoInstallConfirm {
                    d.confirmInstall = d.selection
                }
            }
        }
    }
}

// MARK: summary strip

struct SummaryStrip: View {
    @Bindable var store: AppStore
    @Environment(\.theme) private var theme

    static let summaryLineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 13, weight: .medium))

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                if let report = store.report {
                    // 0.6.2: the first form that fits, least important parts
                    // dropped first, rather than one line cut off mid-word
                    // when the More picker says "13 vulnerable", a scan is
                    // running, or the language is longer. Full text on hover.
                    ViewThatFits(in: .horizontal) {
                        ForEach(SummaryText.lines(report.summary, intelbrewMode: store.intelbrewMode), id: \.self) { line in
                            Text(line).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    // One height in every theme and form, so the table
                    // never moves between them.
                    .frame(height: Self.summaryLineHeight)
                    ViewThatFits(in: .horizontal) {
                        upgradesLine(report.summary, detail: true, disk: true)
                        upgradesLine(report.summary, detail: false, disk: true)
                        upgradesLine(report.summary, detail: false, disk: false)
                    }
                    .font(.system(size: 12))
                } else if store.isRefreshing {
                    Text("Reading installed packages…").font(.system(size: 13, weight: .medium))
                    Text(store.refreshPhase ?? " ").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text("No data yet").font(.system(size: 13, weight: .medium))
                    Text("Press Refresh to ask Homebrew.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(fullText)

            FilterActions(store: store)

            ThemedSegmentedPicker(title: String(localized: "Filter"), selection: $store.filter, options: store.visibleSegmentedFilters) { f in
                "\(f.title)  \(store.count(f))"
            }
            MoreFiltersPicker(store: store)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.strip)
    }

    /// The second line: "● 5 upgrades ready (4 with bottles, 1 compiles) · 289 MB on disk",
    /// or "Everything is up to date", with or without its detail and size.
    @ViewBuilder
    private func upgradesLine(_ summary: StatusSummary, detail showDetail: Bool, disk: Bool) -> some View {
        HStack(spacing: 6) {
            if let (ready, detail) = SummaryText.upgrades(summary, targets: store.upgradable) {
                Circle().fill(theme.upgrade).frame(width: 7, height: 7)
                Text(ready).fontWeight(.semibold).foregroundStyle(theme.upgrade)
                if showDetail, !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
            } else if store.upgradeCheckFailed {
                // 0.8.8 (gauntlet 3, B6): not "Everything is up to date"
                // when the check failed.
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityHidden(true)
                if showDetail || disk {
                    Text("Couldn't check for upgrades").foregroundStyle(.secondary)
                } else {
                    Text("Not checked").foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityHidden(true)
                // Two literals, not a ternary: a ternary of literals is a
                // String, which Text shows unlocalized.
                if showDetail || disk {
                    Text("Everything is up to date").foregroundStyle(.secondary)
                } else {
                    Text("Up to date").foregroundStyle(.secondary)
                }
            }
            if disk { DiskTotalText(store: store) }
        }
        .lineLimit(1)
    }

    /// Everything the strip's left side says, unshortened, for its tooltip.
    private var fullText: String {
        guard let report = store.report else { return "" }
        var second = SummaryText.upgrades(report.summary, targets: store.upgradable).map {
            $0.1.isEmpty ? $0.0 : "\($0.0) \($0.1)"
        }
            ?? (store.upgradeCheckFailed ? String(localized: "Couldn't check for upgrades") : String(localized: "Everything is up to date"))
        if let total = store.totalDiskBytes {
            second += " " + String(localized: "· \(DiskSizes.format(total)) on disk (brew info --sizes: kegs and Caskroom folders, apps through their links)")
        }
        return SummaryText.line(report.summary, intelbrewMode: store.intelbrewMode) + "\n" + second
    }
}

/// 0.8.10: a safety copy, or what Homebrew left (a `<name>.app.partial`),
/// from Replace. One notice, not a sheet. Show in Finder selects the
/// paths from the backup folder, never a path read from `.origin`.
struct ReplaceLeftoverBanner: View {
    var store: AppStore
    var notice: ReplaceLeftoverNotice

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(notice.message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Show in Finder") {
                let urls = notice.paths.map { URL(fileURLWithPath: $0) }
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
            .controlSize(.small)
            Button {
                store.dismissReplaceLeftoverNotice()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Hide this message"))
            .accessibilityLabel(Text("Hide this message"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }
}

/// Formulae built from source that newly have a bottle (after Refresh or a
/// background check). Replace with Bottle runs only on this click, for the
/// formulae named here.
/// 0.9.3: the icon is decoration (hidden from VoiceOver, like 0.8.9's boxes);
/// Show and Replace with Bottle say where they go and what they do as
/// hints, keeping their visible names as labels. One group, so VoiceOver
/// reads the sentence and then its buttons, in Tab's order.
struct BottleNoticeBanner: View {
    var store: AppStore
    var text: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Show") { store.showBottleAvailable() }
                .controlSize(.small)
                .accessibilityHint(Text(AccessibilityText.showBottleAvailableHint))
                .accessibilityIdentifier(AccessibilityText.ID.bottleNoticeShow)
            Button("Replace with Bottle") { store.replaceNoticedBottles() }
                .controlSize(.small)
                .disabled(store.windowBrewActionsBlocked || store.isRefreshing)
                .accessibilityHint(Text(AccessibilityText.replaceWithBottleHint))
                .accessibilityIdentifier(AccessibilityText.ID.bottleNoticeReplace)
            Button {
                store.dismissBottleNotice()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Hide this message"))
            .accessibilityLabel(Text("Hide this message"))
            .accessibilityIdentifier(AccessibilityText.ID.bottleNoticeClose)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityText.ID.bottleNotice)
    }
}

struct ErrorBanner: View {
    var error: StoreError
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(error.title).font(.system(size: 12, weight: .semibold))
                if !error.detail.isEmpty {
                    Text(error.detail)
                        .font(.system(size: 11, design: error.detail.contains("\n") ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                if let cmd = error.terminalCommand {
                    Text("Run this in Terminal:").font(.system(size: 11)).foregroundStyle(.secondary)
                    CommandBox(command: cmd).frame(maxWidth: 420)
                }
                if error.fromRefresh {
                    Text("Showing the last data Tankard read.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Dismiss", action: dismiss).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}

/// Buttons that belong to a filter: "Upgrade N without building from source" in Upgrades
/// when some would compile, "Replace all" in Bottle available.
struct FilterActions: View {
    @Bindable var store: AppStore
    @Environment(\.theme) private var theme

    var body: some View {
        switch store.filter {
        case .upgrades:
            if let button = store.skipCompilesButton {
                // 0.8.4: short, and never truncated (.fixedSize): the
                // summary on the left gives way. 0.8.5 (F1): opens the plan
                // with the compiling ones skipped, like the other Upgrade
                // buttons; casks count too, so it doesn't say "bottles".
                Button(button.title) { store.startUpgradeSkippingCompiles() }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(store.windowBrewActionsBlocked || store.isRefreshing)
                    .help(button.help)
            }
        case .bottleAvailable:
            let n = store.bottleReplaceable.count
            if n > 0 {
                Button {
                    store.startReplaceWithBottle()
                } label: {
                    Label("Replace all (\(n))", systemImage: "shippingbox.and.arrow.backward")
                }
                .controlSize(.small)
                .disabled(store.windowBrewActionsBlocked || store.isRefreshing)
                .help("Reinstall each one from a ready-made download instead of building it")
            }
        case .vulnerable:
            // In the filter's own header (VulnerableScanBar).
            EmptyView()
        default:
            EmptyView()
        }
    }
}

// MARK: table

struct PackageTable: View {
    @Bindable var store: AppStore
    @Environment(\.theme) private var theme
    // `State(...)` rather than `@State`: in the macOS 27 SDK `@State` is a
    // macro whose plugin (SwiftUIMacros) ships with Xcode, not the Command
    // Line Tools. The struct itself works the same way everywhere.
    private let sortState = State(initialValue: [KeyPathComparator(\Package.name, comparator: .localizedStandard)])
    /// 0.8.4: the table shows all its rows (see `firstFill`).
    private let filledState = State(initialValue: false)
    /// 0.8.8: no rows until the table measures none (RowHeightGate).
    private let gateState = State(initialValue: RowHeightGate())

    /// 0.8.4: when the rows go from none to many (the first status read at
    /// launch, a search that matched nothing), the table first gets one
    /// screenful and the rest a moment later. SwiftUI inserts new rows into
    /// the NSTableView in one beginUpdates/endUpdates; ~200 rows at once into
    /// an empty table with automatic row heights (estimated at 24 pt, really
    /// 30 and 43) made AppKit resize the table while it was still measuring
    /// rows: "Application performed a reentrant operation in its NSTableView
    /// delegate. This warning will become an assert in the future." on every
    /// launch. A fresh table per fill (an .id) avoided it too, but measured
    /// some one-line rows two lines high. 0.8.5: the rows have one fixed
    /// height now (PackageRow), which fixes the cause for every big change,
    /// not only the first fill; this staging is kept as it was. 0.8.8: only
    /// for a table that was switched to them, which `gateState` now makes
    /// sure of (a table made with rows kept measuring them).
    static let firstFill = 40

    var rows: [Package] {
        store.visiblePackages.sorted(using: sortState.wrappedValue)
    }

    private var rowsToken: Int {
        var h = Hasher()
        h.combine(store.selection)
        h.combine(rows.map(\.id))
        h.combine(gateState.wrappedValue.ready)
        return h.finalize()
    }

    /// The selection, kept while the table holds its rows back (an empty
    /// table must not clear it).
    private var selection: Binding<Package.ID?> {
        Binding(get: { store.selection },
                set: { v in if gateState.wrappedValue.ready { store.selection = v } })
    }

    var body: some View {
        let intelbrew = store.intelbrewMode
        let _ = store.buildTimesRevision
        let all = rows
        let staged = filledState.wrappedValue || all.count <= Self.firstFill ? all : Array(all.prefix(Self.firstFill))
        let shown = gateState.wrappedValue.rows(staged)
        Table(shown, selection: selection, sortOrder: sortState.projectedValue) {
            TableColumn("Package", value: \Package.name, comparator: .localizedStandard) { p in
                PackageNameCell(store: store, package: p, intelbrew: intelbrew)
            }
            .width(min: 150, ideal: 200)

            TableColumn("Installed", value: \Package.installedVersion, comparator: .localizedStandard) { p in
                VersionText(text: p.installedVersion)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Available") { (p: Package) in
                AvailableCell(package: p)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Source", value: \Package.statusLabel) { p in
                SourceBadge(kind: p.badgeKind, label: p.badgeLabel(intelbrewMode: intelbrew))
            }
            .width(min: 120, ideal: 130)

            TableColumn("Size", value: \Package.sizeSortKey) { p in
                SizeCell(package: p)
            }
            .width(min: 64, ideal: 72)
        }
        .contextMenu(forSelectionType: Package.ID.self) { ids in
            ContextMenuActions.installed(store: store, ids: ids)
        }
        // One configuration in every theme: changing it makes AppKit drop
        // the visible rows (see TableSelectionStyler). The stripes are
        // painted by the styler, the background is this view's.
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        // 0.8.5: the table's own row height (SwiftUI sets the NSTableView's
        // from it): the same as every row's (PackageRow).
        .environment(\.defaultMinListRowHeight, PackageRow.height)
        .task(id: all.isEmpty) {
            if all.isEmpty {
                if filledState.wrappedValue { filledState.wrappedValue = false }
                return
            }
            guard !filledState.wrappedValue else { return }
            // Cancelled (the rows went again): the next fill starts over.
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
            filledState.wrappedValue = true
        }
        .scrollContentBackground(.hidden)
        .background(theme.table ?? Color(nsColor: .controlBackgroundColor))
        .background(TableSelectionStyler(palette: theme.palette, token: rowsToken, fixedRowHeights: true,
                                         onRowHeights: { fixed in
                                             var g = gateState.wrappedValue
                                             g.report(fixed)
                                             if g != gateState.wrappedValue { gateState.wrappedValue = g }
                                         }))
        .background(TableRevealer(request: store.revealRequest, row: shown.firstIndex { $0.id == store.selection }))
        .background(TableTypeSelect(names: shown.map(\.name)))
        .id(gateState.wrappedValue.generation)
        .overlay {
            if store.report != nil && rows.isEmpty && store.filter == .vulnerable && store.search.isEmpty {
                VulnerableEmptyState(store: store)
            } else if store.report != nil && rows.isEmpty && store.searchFindsNothingInstalled {
                NotInstalledEmptyState(store: store)
            } else if store.report != nil && rows.isEmpty {
                ContentUnavailableView(store.search.isEmpty ? String(localized: "Nothing here") : String(localized: "No matches"),
                                       systemImage: store.search.isEmpty ? "tray" : "magnifyingglass",
                                       description: Text(store.search.isEmpty ? String(localized: "No packages in this group.") : String(localized: "No package matches “\(store.search)”.")))
            } else if store.report == nil && store.isRefreshing {
                ProgressView(store.refreshPhase ?? String(localized: "Loading…"))
            }
        }
    }
}

extension View {
    /// `.help` only when there is something to say (an empty `.help("")`
    /// would still be a tooltip region over the children's own).
    @ViewBuilder
    func tooltip(_ text: String?) -> some View {
        if let text, !text.isEmpty { help(text) } else { self }
    }
}

/// 0.8.5: the package lists' rows are all one height, `height`. With
/// heights measured per row (30 and 43 pt, estimated at 24), a big change
/// to the rows (Upgrades → All, clearing a search) made AppKit resize the
/// table while it was still measuring rows: "Application performed a
/// reentrant operation in its NSTableView delegate. This warning will
/// become an assert in the future." Now SwiftUI gives the NSTableView this
/// height (`.environment(\.defaultMinListRowHeight, …)`), the table
/// measures no row (TableSelectionStyler's `fixedRowHeights`), and every
/// row is one line: what used to be the second line (a compile warning,
/// a bottle on offer, a note like "Deprecated") sits after the name, short,
/// with the words in its tooltip.
enum PackageRow {
    static let height: CGFloat = 30
    /// The content's height inside a row (the inset table's 4 pt above and
    /// below). Marks up to `trailingBadge` high fit.
    static let content: CGFloat = 22
    /// The tallest mark the Package column's trailing area is laid out for
    /// (an icon-size badge).
    static let trailingBadge: CGFloat = 18
    /// 0.8.6: the gap between the trailing marks.
    static let markSpacing: CGFloat = 2
}

/// 0.8.6: the row's trailing marks (RowMark), each in a
/// `PackageRow.trailingBadge` square, `markSpacing` apart.
struct TrailingRowMarks: View {
    var store: AppStore
    var package: Package

    var body: some View {
        let marks = RowMark.marks(package, isElectron: store.electron.isElectron(package))
        if !marks.isEmpty {
            HStack(spacing: PackageRow.markSpacing) {
                ForEach(marks) { m in
                    mark(m).frame(width: PackageRow.trailingBadge, height: PackageRow.trailingBadge)
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func mark(_ m: RowMark) -> some View {
        switch m {
        case .updatesItself:
            SelfUpdateMark(help: package.selfUpdateHelp(policy: store.selfUpdatePolicy(package),
                                                        includeSelfUpdating: store.insights.settings.includeSelfUpdatingApps))
        case .password: PasswordLockBadge(size: 11)
        case .electron: ElectronMark()
        }
    }
}

/// The Package column's cell: the name, its badges, the row's note, and
/// the trailing area. 0.8.5: one line, `PackageRow.content` high.
struct PackageNameCell: View {
    var store: AppStore
    var package: Package
    var intelbrew: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let p = package
        HStack(spacing: 4) {
            // 0.8.6: the name keeps its first NameFit.nameChars characters;
            // the badges shrink to icons, then leave (the name's tooltip
            // lists them), before it does (NameCellLayout).
            NameCellLayout(nameMin: Self.nameMinWidth(p.name), spacing: 4) {
                Text(p.name).fontWeight(.medium).lineLimit(1)
                    .help(Self.badgeHelp(p) ?? "")
                ViewThatFits(in: .horizontal) {
                    NameBadges(package: p, compact: false)
                    NameBadges(package: p, compact: true)
                    Color.clear.frame(width: 0, height: 0)
                }
                note(p).frame(minWidth: 0, alignment: .leading).clipped()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The trailing area: marks up to PackageRow.trailingBadge high,
            // one cluster in RowMark's order (0.8.6).
            TrailingRowMarks(store: store, package: p)
        }
        .frame(maxHeight: PackageRow.content)
    }

    /// The width of the name's first NameFit.nameChars characters (the
    /// table's 13 pt, medium).
    static func nameMinWidth(_ name: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        return ceil((String(name.prefix(NameFit.nameChars)) as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    /// The badges in words, for the name's tooltip (they may show as icons
    /// or not at all). nil without badges.
    static func badgeHelp(_ p: Package) -> String? {
        var lines: [String] = []
        if p.kind == .formula && !p.requested { lines.append(String(localized: "Installed as a dependency")) }
        if p.pinned { lines.append(String(localized: "Pinned: upgrades leave it at this version")) }
        if let r = p.retiredLabel { lines.append(r) }
        if let u = p.unreadableDetail { lines.append(u) }
        if p.vulnerabilityBadge != nil { lines.append(VulnerabilityText.help(p)) }
        return lines.isEmpty ? nil : ([p.name] + lines).joined(separator: "\n")
    }

    /// What was the second line: the compile warning, the bottle on offer,
    /// or the subtitle (one at most). Its icon and short words, which give
    /// way first; the whole of it in the tooltip.
    @ViewBuilder
    func note(_ p: Package) -> some View {
        if let w = store.deps.classifier.upgradeWarning(p) {
            // Orange in every list, not only Upgrades: it's what the user is about to wait for.
            NoteMark(symbol: "hammer.fill", text: w.label, help: w.label + "\n" + w.text,
                     color: theme.badge(.source).dot, weight: .semibold)
                .onAppear { store.compileWarningShown() }
        } else if BottleReplacement.isEligible(p) {
            let text = BottleReplacement.badge(p, intelbrewMode: intelbrew)
            NoteMark(symbol: "shippingbox.fill", text: text, help: text, color: theme.badge(.bottle).dot, weight: .medium)
        } else if let sub = Self.note(p) {
            Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                .help(sub)
        }
    }

    /// The subtitle without "Deprecated" or "Disabled", which the badge
    /// next to the name already says (RetiredBadge).
    static func note(_ p: Package) -> String? {
        guard let sub = p.subtitle else { return nil }
        guard p.retiredLabel != nil else { return sub }
        let retired = [String(localized: "Disabled"), String(localized: "Deprecated")]
        let rest = sub.components(separatedBy: " · ").filter { !retired.contains($0) }
        return rest.isEmpty ? nil : rest.joined(separator: " · ")
    }
}

/// 0.8.6: the name's badges, as words or (compact) as icons only.
struct NameBadges: View {
    var package: Package
    var compact: Bool

    var body: some View {
        let p = package
        HStack(spacing: 4) {
            if p.kind == .formula && !p.requested && !compact {
                Text("dep").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 0.5)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.tertiary, lineWidth: 0.5))
                    .fixedSize()
                    .help("Installed as a dependency")
                    .accessibilityLabel(Text("Installed as a dependency")) // 0.8.6 (UI L6): was "dep"
            }
            if p.pinned { PinnedBadge(compact: compact) }
            RetiredBadge(package: p, compact: compact)
            UnreadableBadge(package: p, compact: compact)
            VulnerabilityTag(package: p, compact: compact)
        }
        .fixedSize()
    }
}

/// 0.8.6: lays out the Package cell's name, badges and note by
/// `NameFit.allocate` (subviews in that order; the note may be absent).
struct NameCellLayout: Layout {
    var nameMin: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = min(ideal.map(\.height).max() ?? 0, PackageRow.content)
        let width = proposal.width ?? ideal.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, ideal.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else {
            subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                                  proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }
        let nameIdeal = subviews[0].sizeThatFits(.unspecified).width
        let noteIdeal = subviews.count > 2 ? subviews[2].sizeThatFits(.unspecified).width : 0
        let a = NameFit.allocate(width: bounds.width, nameIdeal: nameIdeal, nameMin: nameMin, spacing: spacing,
                                 noteIdeal: noteIdeal) { w in
            subviews[1].sizeThatFits(ProposedViewSize(width: w, height: bounds.height)).width
        }
        var x = bounds.minX
        subviews[0].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: a.name, height: bounds.height))
        x += a.name + spacing
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: a.badges, height: bounds.height))
        if a.badges > 0 { x += a.badges + spacing }
        if subviews.count > 2 {
            subviews[2].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: a.note, height: bounds.height))
        }
    }
}

/// A row's note after the name: its icon and words, the words cut short
/// when the column is narrow (all of them in the tooltip).
struct NoteMark: View {
    var symbol: String
    var text: String
    var help: String
    var color: Color
    var weight: Font.Weight

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5)).accessibilityHidden(true)
            // The first to give way (the name and badges come first).
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 10.5, weight: weight))
        .foregroundStyle(color)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}

/// 0.8.3: the Installed search found nothing installed: offer the same
/// search in Discover (a new user often types "wget" or pastes
/// "brew install wget" into the field they see, which is Installed's).
struct NotInstalledEmptyState: View {
    var store: AppStore

    var body: some View {
        let term = store.searchTerm
        ContentUnavailableView {
            Label(String(localized: "Not installed"), systemImage: "magnifyingglass")
        } description: {
            Text("No installed package matches “\(term)”.")
        } actions: {
            Button("Search Discover for “\(term)”") {
                guard let d = store.searchDiscover(for: term) else { return }
                Task {
                    await d.activate()
                    await d.searchNow()
                }
            }
            .buttonStyle(.primaryAction)
            .disabled(!store.hasBrew)
        }
    }
}

/// 0.8.1: marks a self-updating cask (auto_updates). It replaced the
/// "Updates itself" line under the name (Derek: a symbol, so the row isn't
/// messy). The tooltip says it in words and who updates the app. 0.8.6: at
/// the end of the row with the other marks (TrailingRowMarks), 11 pt like
/// the lock.
struct SelfUpdateMark: View {
    var help: String
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominence == .increased && !theme.isCustom ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            .fixedSize()
            .help(help)
            .accessibilityElement()
            .accessibilityLabel(Text("Updates itself"))
            .accessibilityHint(Text(help))
    }
}

struct AvailableCell: View {
    var package: Package
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.theme) private var theme

    var body: some View {
        let v = package.currentVersion ?? "–"
        if package.upgradeAvailable {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                Text(v).fontWeight(.semibold).monospacedDigit()
                    .lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(prominence == .increased && !theme.isCustom ? Color.white : theme.upgrade)
            .lineLimit(1)
            .help("Upgrade available: \(v)")
            // 0.9.3: one element with the tooltip's words; otherwise the
            // arrow is named by its symbol, not as "upgrade available".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(AccessibilityText.upgradeAvailable(v)))
        } else {
            VersionText(text: v, same: true)
        }
    }
}

/// 0.6.1: an empty view that moves the window on a drag (the toolbar's
/// custom items otherwise swallow the mouse-down). AppKit's own
/// `performDrag`, so it behaves like the titlebar on every macOS version.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if let window { window.performDrag(with: event) } else { super.mouseDown(with: event) }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
