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
        .navigationSubtitle(store.intelbrewMode ? "Intel bottles for macOS 14+" : "Homebrew")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BrandMark(size: 32, intelbrew: store.intelbrewMode)
                    .padding(.horizontal, 4)
            }
            if !store.homebrewState.needsWelcome {
                ToolbarItem(placement: .principal) {
                    ThemedSegmentedPicker(title: "View", selection: $store.tab, options: MainTab.allCases, label: \.title)
                        .environment(\.theme, Theme.of(appearance.theme))
                        .help("Installed packages, or search everything Homebrew has (⌘1, ⌘2)")
                }
                ToolbarItem(placement: .primaryAction) {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small).frame(width: 28)
                            .help(store.refreshPhase ?? "Refreshing")
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
            if let session = store.upgrade {
                UpgradeSheet(session: session, store: store).themed(theme)
            }
        }
        .task {
            await store.start()
            await applyLaunchOptions()
        }
        .onChange(of: activeState) { _, state in
            if state == .key { store.revalidateIfStale() }
        }
        .onChange(of: store.tab) { _, tab in
            if tab == .discover { openDiscover() }
        }
        .onChange(of: store.intelbrewMode, initial: true) { _, intelbrew in
            AppResources.updateDockIcon(intelbrew: intelbrew)
        }
        .themed(theme)
        .background(SnapshotHook(request: options.snapshot))
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
            } else if let discover = store.discover {
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
        // Here, not on the window: the welcome screen has nothing to search.
        .searchable(text: searchBinding, placement: .toolbar,
                    prompt: store.tab == .installed ? "Search installed" : "Search Homebrew")
    }

    /// The toolbar search field searches the tab on screen.
    private var searchBinding: Binding<String> {
        Binding(
            get: { store.tab == .installed ? store.search : (store.discover?.query ?? "") },
            set: { v in
                if store.tab == .installed { store.search = v } else { store.discover?.query = v }
            })
    }

    /// Discover loads its catalog when first opened, never at launch.
    private func openDiscover() {
        guard let d = store.openDiscover() else { return }
        Task { await d.activate() }
    }

    @MainActor
    private func applyLaunchOptions() async {
        if let name = options.select, let p = store.packages.first(where: { $0.name == name }) {
            store.selection = p.id
        }
        if options.demo != nil && options.demoUpgrade {
            store.startUpgrade()
        }
        if options.demo != nil, let name = options.demoUninstall,
           let p = store.packages.first(where: { $0.name == name }) {
            store.selection = p.id
            store.requestUninstall(p)
        }
        if options.tab == .discover {
            store.tab = .discover
            guard let d = store.openDiscover() else { return }
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
            }
        }
    }
}

// MARK: summary strip

struct SummaryStrip: View {
    @Bindable var store: AppStore
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                if let report = store.report {
                    Text(SummaryText.line(report.summary, intelbrewMode: store.intelbrewMode))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        if let (ready, detail) = SummaryText.upgrades(report.summary) {
                            Circle().fill(theme.accent).frame(width: 7, height: 7)
                            Text(ready).fontWeight(.semibold).foregroundStyle(theme.accent)
                            Text(detail).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Everything is up to date").foregroundStyle(.secondary)
                        }
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

            ThemedSegmentedPicker(title: "Filter", selection: $store.filter, options: PackageFilter.allCases) { f in
                "\(f.title)  \(store.count(f))"
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.strip)
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
                    }
                    if let sub = p.subtitle {
                        Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 150, ideal: 220)

            TableColumn("Installed", value: \Package.installedVersion, comparator: .localizedStandard) { p in
                VersionText(text: p.installedVersion)
            }
            .width(min: 70, ideal: 110)

            TableColumn("Available") { (p: Package) in
                AvailableCell(package: p)
            }
            .width(min: 70, ideal: 110)

            TableColumn("Source", value: \Package.statusLabel) { p in
                SourceBadge(kind: p.badgeKind, label: p.badgeLabel(intelbrewMode: intelbrew))
            }
            .width(min: 120, ideal: 170)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: !theme.isTankard))
        .scrollContentBackground(theme.isTankard ? .hidden : .automatic)
        .background(theme.table ?? .clear)
        .background(TableSelectionStyler(tankard: theme.isTankard, token: rowsToken))
        .overlay {
            if store.report != nil && rows.isEmpty {
                ContentUnavailableView(store.search.isEmpty ? "Nothing here" : "No matches",
                                       systemImage: store.search.isEmpty ? "tray" : "magnifyingglass",
                                       description: Text(store.search.isEmpty ? "No packages in this group." : "No package matches “\(store.search)”."))
            } else if store.report == nil && store.isRefreshing {
                ProgressView(store.refreshPhase ?? "Loading…")
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
            }
            .foregroundStyle(prominence == .increased && !theme.isTankard ? Color.white : theme.accent)
            .lineLimit(1)
            .help("Upgrade available")
        } else {
            VersionText(text: v, same: true)
        }
    }
}
