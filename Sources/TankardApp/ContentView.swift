import SwiftUI
import TankardAppModel
import TankardCore

struct ContentView: View {
    @Bindable var store: AppStore
    var options: LaunchOptions
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(spacing: 0) {
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
                    .background(Theme.pane)
            }
            Divider()
            StatusBar(store: store)
        }
        .navigationTitle(store.intelbrewMode ? "Intelbrew" : "Tankard")
        .navigationSubtitle(store.intelbrewMode ? "Intel bottles for macOS 14+" : "Homebrew")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BrandMark(intelbrew: store.intelbrewMode, size: 30)
                    .padding(.horizontal, 4)
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
        .searchable(text: $store.search, placement: .toolbar, prompt: "Search packages")
        .sheet(isPresented: $store.showUpgradeSheet) {
            if let session = store.upgrade {
                UpgradeSheet(session: session, store: store)
            }
        }
        .task {
            await store.start()
            await applyDemoOptions()
        }
        .onChange(of: activeState) { _, state in
            if state == .key { store.revalidateIfStale() }
        }
        .background(SnapshotHook(request: options.snapshot))
    }

    @MainActor
    private func applyDemoOptions() async {
        if let name = options.select, let p = store.packages.first(where: { $0.name == name }) {
            store.selection = p.id
        }
        if options.demo != nil && options.demoUpgrade {
            store.startUpgrade()
        }
    }
}

// MARK: summary strip

struct SummaryStrip: View {
    @Bindable var store: AppStore

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
                            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                            Text(ready).fontWeight(.semibold).foregroundStyle(Color.accentColor)
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

            Picker("Filter", selection: $store.filter) {
                ForEach(PackageFilter.allCases) { f in
                    Text("\(f.title)  \(store.count(f))").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.strip)
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
    // `State(...)` rather than `@State`: in the macOS 27 SDK `@State` is a
    // macro whose plugin (SwiftUIMacros) ships with Xcode, not the Command
    // Line Tools. The struct itself works the same way everywhere.
    private let sortState = State(initialValue: [KeyPathComparator(\Package.name, comparator: .localizedStandard)])

    var rows: [Package] {
        store.visiblePackages.sorted(using: sortState.wrappedValue)
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
                Text(p.installedVersion).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).truncationMode(.middle)
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
        .tableStyle(.inset(alternatesRowBackgrounds: true))
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

    var body: some View {
        let v = package.currentVersion ?? "–"
        if package.upgradeAvailable {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                Text(v).fontWeight(.semibold).monospacedDigit()
            }
            .foregroundStyle(prominence == .increased ? Color.white : Color.accentColor)
            .lineLimit(1)
            .help("Upgrade available")
        } else {
            Text(v).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
    }
}
