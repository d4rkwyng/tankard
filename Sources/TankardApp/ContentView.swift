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
                    ThemedSegmentedPicker(title: String(localized: "View"), selection: $store.tab, options: MainTab.allCases, label: \.title)
                        .environment(\.theme, Theme.of(appearance.theme))
                        .help("Installed packages, or search everything Homebrew has (⌘1, ⌘2)")
                }
                ToolbarItem(placement: .primaryAction) {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small).frame(width: 28)
                            .help(store.refreshPhase ?? String(localized: "Refreshing"))
                    } else {
                        Button {
                            Task { await store.refresh(manual: true) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("brew update, then re-read installed packages (⌘R)")
                        .disabled(store.isUpgrading)
                    }
                }
            }
        }
        .sheet(isPresented: $store.showUpgradeSheet) {
            ActivitySheet(store: store).themed(theme)
        }
        .task {
            await store.start()
            await applyLaunchOptions()
        }
        .onChange(of: activeState) { _, state in
            if state == .key { store.revalidateIfStale() }
        }
        .onChange(of: store.tab) { _, tab in
            store.tabChanged(to: tab)
            if tab == .discover { openDiscover() }
            if tab == .services { store.openServices() }
        }
        .onChange(of: store.intelbrewMode, initial: true) { _, intelbrew in
            AppResources.updateDockIcon(intelbrew: intelbrew)
        }
        .themed(theme)
        .background(SnapshotHook(request: options.snapshot, makeView: { name in
            switch name {
            case "menubar":
                return AnyView(MenuBarContent(store: store, openMain: {})
                    .themed(theme)
                    .background(theme.window ?? Color(nsColor: .windowBackgroundColor)))
            case "settings":
                // The General tab's content (an off-screen TabView draws no tab bar).
                return AnyView(GeneralSettings(settings: store.settings, notifier: SystemNotifier(), loginItem: LoginItem())
                    .frame(width: 460)
                    .themed(theme)
                    .background(theme.window ?? Color(nsColor: .windowBackgroundColor)))
            case "settings-autoupdate":
                // 0.5: Settings → Upgrades with its Automatic updates section.
                return AnyView(UpgradeSettings(settings: store.insights.settings, autoUpdater: store.autoUpdate, appSettings: store.settings)
                    .frame(width: 460)
                    .themed(theme)
                    .background(theme.window ?? Color(nsColor: .windowBackgroundColor)))
            case "autoupdate-log":
                return AnyView(AutoUpdateLogView(log: store.autoUpdate.log)
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
            if store.tab == .installed {
                SummaryStrip(store: store)
                Divider()
                if let error = store.error {
                    ErrorBanner(error: error) { store.dismissError() }
                    Divider()
                }
                HStack(spacing: 0) {
                    PackageTable(store: store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    DetailPane(store: store)
                        .frame(width: 272)
                        .frame(maxHeight: .infinity)
                        .background(theme.pane)
                }
            } else if store.tab == .services, let services = store.services {
                ServicesView(store: store, services: services)
            } else if store.tab == .discover, let discover = store.discover {
                DiscoverView(store: store, discover: discover)
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
            AutoUpdateLogView(log: store.autoUpdate.log) { store.showAutoUpdateLog = false }.themed(theme)
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
    private func openDiscover() {
        guard let d = store.openDiscover() else { return }
        Task { await d.activate() }
    }

    @MainActor
    private func applyLaunchOptions() async {
        if let f = options.filter { store.filter = f }
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
        // 0.7 demo: TANKARD_DEMO_RESTORE=1 opens Restore Points; =confirm also opens the confirmation.
        if options.demo != nil, let mode = ProcessInfo.processInfo.environment["TANKARD_DEMO_RESTORE"], !mode.isEmpty {
            Demo.seedRestorePoints(store)
            store.openRestorePoints()
            if mode == "confirm", let p = store.restorePoints.points.first { store.requestRestore(p, pinAfter: true) }
        }
        if options.demo != nil, let mode = options.demoAutoUpdate {
            await AutoUpdateDemo.apply(mode, store: store)
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
        if options.demo != nil && options.demoReplace, let p = store.selectedPackage {
            store.startReplaceWithBottle([p])
        }
        if options.demo != nil, let name = options.demoUninstall,
           let p = store.packages.first(where: { $0.name == name }) {
            store.selection = p.id
            store.requestUninstall(p)
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

            ThemedSegmentedPicker(title: String(localized: "Filter"), selection: $store.filter, options: PackageFilter.segmented) { f in
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
            if let (ready, detail) = SummaryText.upgrades(summary) {
                Circle().fill(theme.upgrade).frame(width: 7, height: 7)
                Text(ready).fontWeight(.semibold).foregroundStyle(theme.upgrade)
                if showDetail { Text(detail).foregroundStyle(.secondary) }
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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
        var second = SummaryText.upgrades(report.summary).map { "\($0.0) \($0.1)" } ?? String(localized: "Everything is up to date")
        if let total = store.totalDiskBytes {
            second += " " + String(localized: "· \(DiskSizes.format(total)) on disk (brew info --sizes: kegs and Caskroom folders, apps through their links)")
        }
        return SummaryText.line(report.summary, intelbrewMode: store.intelbrewMode) + "\n" + second
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
                Text("Showing the last data Tankard read.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Dismiss", action: dismiss).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}

/// Buttons that belong to a filter: "Upgrade N with bottles" in Upgrades
/// when some would compile, "Replace all" in Bottle available.
struct FilterActions: View {
    @Bindable var store: AppStore
    @Environment(\.theme) private var theme

    var body: some View {
        switch store.filter {
        case .upgrades:
            let (bottled, compiling) = store.deps.classifier.partitionUpgrades(store.upgradable)
            if !compiling.isEmpty && !bottled.isEmpty {
                Button("Skip packages that would compile (\(bottled.count) with bottles)") { store.startUpgradeSkippingCompiles() }
                    .controlSize(.small)
                    .disabled(store.isUpgrading || store.isRefreshing)
                    .help("Upgrade only the packages that pour a bottle; skip \(compiling.map(\.name).joined(separator: ", "))")
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
                .disabled(store.isUpgrading || store.isRefreshing)
                .help("brew reinstall --force-bottle --formula each one, through the queue")
            }
        case .vulnerable:
            VulnerableFilterActions(store: store)
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

    var rows: [Package] {
        store.visiblePackages.sorted(using: sortState.wrappedValue)
    }

    private var rowsToken: Int {
        var h = Hasher()
        h.combine(store.selection)
        h.combine(rows.map(\.id))
        return h.finalize()
    }

    var body: some View {
        let intelbrew = store.intelbrewMode
        let _ = store.buildTimesRevision
        Table(rows, selection: $store.selection, sortOrder: sortState.projectedValue) {
            TableColumn("Package", value: \Package.name, comparator: .localizedStandard) { p in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(p.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                        if p.kind == .formula && !p.requested {
                            Text("dep").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 4).padding(.vertical, 0.5)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.tertiary, lineWidth: 0.5))
                                .fixedSize()
                                .help("Installed as a dependency")
                        }
                        if p.pinned { PinnedBadge() }
                        RetiredBadge(package: p)
                        VulnerabilityTag(package: p)
                    }
                    if let w = store.deps.classifier.upgradeWarning(p) {
                        // Orange in every list, not only Upgrades: it's what the user is about to wait for.
                        HStack(spacing: 3) {
                            Image(systemName: "hammer.fill").font(.system(size: 8.5))
                            Text(w.label)
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.badge(.source).dot)
                        .lineLimit(1)
                        .help(w.text)
                        .onAppear { store.compileWarningShown() }
                    } else if BottleReplacement.isEligible(p) {
                        HStack(spacing: 3) {
                            Image(systemName: "shippingbox.fill").font(.system(size: 8.5))
                            Text(BottleReplacement.badge(p, intelbrewMode: intelbrew))
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.badge(.bottle).dot)
                        .lineLimit(1)
                    } else if let sub = p.subtitle {
                        Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
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
            .width(min: 56, ideal: 72)
        }
        .contextMenu(forSelectionType: Package.ID.self) { ids in
            ContextMenuActions.installed(store: store, ids: ids)
        }
        // One configuration in every theme: changing it makes AppKit drop
        // the visible rows (see TableSelectionStyler). The stripes are
        // painted by the styler, the background is this view's.
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(theme.table ?? Color(nsColor: .controlBackgroundColor))
        .background(TableSelectionStyler(palette: theme.palette, token: rowsToken))
        .overlay {
            if store.report != nil && rows.isEmpty {
                ContentUnavailableView(store.search.isEmpty ? String(localized: "Nothing here") : String(localized: "No matches"),
                                       systemImage: store.search.isEmpty ? "tray" : "magnifyingglass",
                                       description: Text(store.search.isEmpty ? String(localized: "No packages in this group.") : String(localized: "No package matches “\(store.search)”.")))
            } else if store.report == nil && store.isRefreshing {
                ProgressView(store.refreshPhase ?? String(localized: "Loading…"))
            }
        }
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
