import SwiftUI
import TankardAppModel
import TankardCore

/// Discover: search every formula and cask, see details, install.
struct DiscoverView: View {
    @Bindable var store: AppStore
    @Bindable var discover: DiscoverStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            DiscoverStrip(discover: discover)
            Divider()
            if store.showsCasksBanner {
                CasksOffBanner(store: store)
                Divider()
            }
            if let warning = discover.warning {
                NoticeBanner(text: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                Divider()
            }
            HStack(spacing: 0) {
                DiscoverTable(store: store, discover: discover)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                DiscoverDetail(store: store, discover: discover)
                    .frame(width: 292)
                    .frame(maxHeight: .infinity)
                    .background(theme.pane)
            }
        }
        // 0.8.5: Enable Casks…'s confirmation (the Taps sheet has its own).
        .modifier(TapAddConfirmation(store: store, taps: store.taps, only: .discover))
    }
}

/// 0.8.5: casks are off (no homebrew/cask tap): what that means, and the
/// one command that turns them on. Closing it hides it for good.
struct CasksOffBanner: View {
    var store: AppStore

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(CasksBanner.title).font(.system(size: 12, weight: .semibold))
                Text(CasksBanner.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Turn On Apps…") { store.requestEnableCasks() }
                .controlSize(.small)
                .disabled(store.isBusy)
                .help(String(localized: "Asks first, then turns apps on"))
            Button {
                store.hideCasksBanner()
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

struct DiscoverStrip: View {
    @Bindable var discover: DiscoverStore
    @Environment(\.theme) private var theme

    /// The Bottles chip as a two-option picker (bottled only, or all).
    enum BottleScope: String, CaseIterable, Identifiable {
        case bottled, all
        var id: Self { self }
    }

    private var bottleScope: Binding<BottleScope> {
        Binding(get: { discover.bottledOnly ? .bottled : .all },
                set: { discover.bottledOnly = $0 == .bottled })
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: discover.isLocalTaps ? "internaldrive" : "globe")
                    Text(discover.source.isEmpty ? (discover.isLocalTaps ? String(localized: "Local taps") : "formulae.brew.sh") : discover.source)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let t = discover.loadedAt, !discover.isLocalTaps {
                        Text("· fetched \(updatedAgo(t, now: Date()))")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help(discover.isLocalTaps
                      ? String(localized: "Intelbrew mode: names from the taps on this Mac, details from brew info. formulae.brew.sh isn't used: it describes upstream Homebrew.")
                      : String(localized: "From formulae.brew.sh, cached for an hour in ~/Library/Caches/net.mindtricks.tankard/api"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if discover.phase == .ready && discover.formulaCount > 0 {
                ThemedSegmentedPicker(title: String(localized: "Bottles"), selection: bottleScope, options: BottleScope.allCases) { scope in
                    scope == .bottled ? "\(discover.bottledChipTitle) (\(discover.bottledCountText))" : String(localized: "All")
                }
                .help(discover.isLocalTaps
                      ? String(localized: "Formulae with a bottle for this Mac (Intelbrew's or Homebrew's). The rest compile from source when installed.")
                      : String(localized: "Formulae with a bottle for this Mac. The rest compile from source when installed."))
            }

            ThemedSegmentedPicker(title: String(localized: "Kind"), selection: $discover.kind, options: CatalogKindFilter.allCases, label: \.title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.strip)
    }

    private var headline: String {
        switch discover.phase {
        case .idle, .loading: return discover.isLocalTaps ? String(localized: "Reading the local taps…") : String(localized: "Loading Homebrew's catalog…")
        case .failed: return String(localized: "Couldn't load the catalog")
        case .ready:
            if discover.resultsQuery.isEmpty { return String(localized: "Search \(discover.totalCount.formatted()) packages") }
            let n = discover.results.count
            if n == 200 { return String(localized: "Top 200 results for “\(discover.resultsTerm)”") }
        return n == 1 ? String(localized: "\(n) result for “\(discover.resultsTerm)”") : String(localized: "\(n) results for “\(discover.resultsTerm)”")
        }
    }
}

struct NoticeBanner: View {
    var text: String
    var systemImage: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(LocalizedStringKey(text)) // renders the `code` span
                .font(.system(size: 12))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(tint.opacity(0.08))
    }
}

struct DiscoverTable: View {
    @Bindable var store: AppStore
    @Bindable var discover: DiscoverStore
    @Environment(\.theme) private var theme

    var body: some View {
        let installed = store.installedIDs
        Table(discover.results, selection: $discover.selection) {
            TableColumn("Package") { (e: CatalogEntry) in
                // 0.8.5: one line (the rows are PackageRow.height); the
                // description after the name, the whole of it in the tooltip
                // and the detail.
                HStack(spacing: 5) {
                    Text(e.name).fontWeight(.medium).lineLimit(1).layoutPriority(2)
                    if installed.contains(e.id) {
                        InstalledMark()
                    }
                    if e.disabled || e.deprecated {
                        Text(e.disabled ? String(localized: "disabled") : String(localized: "deprecated")).font(.system(size: 9.5)).foregroundStyle(.orange)
                            .fixedSize()
                    }
                    if let d = e.desc {
                        Text(d).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(d)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: PackageRow.content)
                .onAppear { discover.needDetails([e.id]) }
            }
            .width(min: 180, ideal: 300)

            TableColumn("Version") { (e: CatalogEntry) in
                VersionText(text: e.version ?? (e.detailsLoaded ? "–" : "…"))
            }
            .width(min: 60, ideal: 90)

            TableColumn("Kind") { (e: CatalogEntry) in
                Text(e.kind == .cask ? String(localized: "Cask") : String(localized: "Formula")).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64)

            TableColumn("Bottle") { (e: CatalogEntry) in
                SourceBadge(kind: e.badgeKind, label: e.badgeLabel)
            }
            .width(min: 120, ideal: 160)
        }
        .contextMenu(forSelectionType: CatalogEntry.ID.self) { ids in
            ContextMenuActions.discover(store: store, discover: discover, ids: ids)
        }
        // One configuration in every theme: changing it makes AppKit drop
        // the visible rows (see TableSelectionStyler). The stripes are
        // painted by the styler, the background is this view's.
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        // 0.8.5: the table's own row height (SwiftUI sets the NSTableView's
        // from it): the same as every row's (PackageRow).
        .environment(\.defaultMinListRowHeight, PackageRow.height)
        .scrollContentBackground(.hidden)
        .background(theme.table ?? Color(nsColor: .controlBackgroundColor))
        .background(TableSelectionStyler(palette: theme.palette, token: rowsToken, fixedRowHeights: true))
        .background(TableTypeSelect(names: discover.results.map(\.name)))
        .overlay { overlay }
    }

    private var rowsToken: Int {
        var h = Hasher()
        h.combine(discover.selection)
        h.combine(discover.results.map(\.id))
        return h.finalize()
    }

    @ViewBuilder
    private var overlay: some View {
        switch discover.phase {
        case .idle, .loading:
            ProgressView(discover.isLocalTaps ? String(localized: "Reading the local taps…") : String(localized: "Loading formulae.brew.sh…"))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load the catalog", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                VStack(spacing: 10) {
                    Button("Try Again") { Task { await discover.activate() } }
                    // 0.8.5 (M4): the system's error, for a bug report.
                    if let detail = discover.failureDetail {
                        DisclosureGroup("Details") {
                            ScrollView {
                                Text(verbatim: detail).font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)
                        }
                        .font(.system(size: 11))
                        .frame(maxWidth: 420)
                    }
                }
            }
        case .ready:
            if discover.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("Search Homebrew", systemImage: "magnifyingglass",
                                       description: Text("Type a name or a word from a description."))
            } else if store.searchEmptyBecauseCasksOff {
                ContentUnavailableView {
                    Label(CasksBanner.noMatchesTitle, systemImage: "shippingbox")
                } description: {
                    Text(CasksBanner.noMatchesDetail(discover.query))
                } actions: {
                    Button("Turn On Apps…") { store.requestEnableCasks() }
                        .disabled(store.isBusy)
                        .help(String(localized: "Asks first, then turns apps on"))
                }
            } else if discover.results.isEmpty && discover.resultsQuery == discover.query {
                // 0.8.6 (H1): says where it looked, and how to add a tap.
                ContentUnavailableView {
                    Label("No matches", systemImage: "magnifyingglass")
                } description: {
                    Text(discover.noMatchesDetail(discover.query))
                } actions: {
                    if !discover.isLocalTaps {
                        Button("Taps…") { store.openTaps() }
                            .help(String(localized: "Add the tap a package comes from"))
                    }
                }
            }
        }
    }
}

struct InstalledMark: View {
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.theme) private var theme

    var body: some View {
        let selected = prominence == .increased && !theme.isCustom
        HStack(spacing: 2) {
            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
            Text("installed").font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(selected ? Color.white : theme.badge(.bottle).foreground)
        .padding(.horizontal, 4).padding(.vertical, 0.5)
        .background(Capsule().fill(selected ? Color.white.opacity(0.18) : theme.badge(.bottle).background))
        .fixedSize()
        .help("Already installed")
    }
}

struct DiscoverDetail: View {
    @Bindable var store: AppStore
    @Bindable var discover: DiscoverStore
    @Environment(\.theme) private var theme

    var body: some View {
        if let e = discover.selectedEntry {
            ScrollView {
                detail(e).padding(16)
            }
            .id(e.id)
            .sheet(isPresented: Binding(
                get: { discover.confirmInstall == e.id },
                set: { if !$0 { discover.confirmInstall = nil } })) {
                CompileInstallConfirm(store: store, discover: discover, entry: e).themed(theme)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text("Select a package").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func detail(_ e: CatalogEntry) -> some View {
        let installed = store.installedIDs.contains(e.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: theme.palette.map { [Color(hex: $0.plate), Color(hex: $0.window)] } ?? [Color(hex: 0x3a3a3c), Color(hex: 0x1c1c1e)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: e.kind == .cask ? "macwindow" : "shippingbox.fill")
                        .font(.system(size: 18)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.name).font(.system(size: 16, weight: .bold)).lineLimit(1).truncationMode(.middle)
                    Text(e.desc ?? (e.kind == .cask ? String(localized: "Cask") : String(localized: "Formula")))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                }
            }

            HStack(spacing: 6) {
                SourceBadge(kind: e.badgeKind, label: e.badgeLabel)
                if installed { InstalledMark() }
            }

            if !e.detailsLoaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Asking brew info…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                row(String(localized: "Version"), e.version ?? (e.detailsLoaded ? "–" : "…"))
                row(String(localized: "Kind"), e.kind == .cask ? String(localized: "Cask") : String(localized: "Formula"))
                if let tap = e.tap { row(String(localized: "Tap"), tap, mono: true) }
                if e.kind == .formula { row(String(localized: "License"), e.license ?? (e.detailsLoaded ? String(localized: "Not stated") : "…")) }
                if let tag = e.bottleTag { row(String(localized: "Bottle tag"), tag, mono: true) }
                if !e.otherNames.isEmpty {
                    row(e.kind == .cask ? String(localized: "Name") : String(localized: "Also"), e.otherNames.prefix(4).joined(separator: ", "))
                }
            }
            .font(.system(size: 12))

            InstallCountsView(counts: discover.installCounts(e.id), phase: discover.analyticsPhase,
                              endDate: discover.analytics?.endDate)

            if let home = e.homepage, let url = URL(string: home) {
                Link(destination: url) {
                    HStack(spacing: 3) {
                        Text(url.host ?? home).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .help(home)
            }

            let deps = e.dependencies + e.caskDependencies
            if !deps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dependencies (\(deps.count))").font(.system(size: 11)).foregroundStyle(.secondary)
                    FlowLayout(spacing: 4) {
                        ForEach(deps, id: \.self) { d in
                            let have = store.packages.contains { $0.name == d || $0.fullName == d }
                            HStack(spacing: 3) {
                                if have { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                                Text(d)
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(have ? theme.badge(.bottle).foreground : Color.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(have ? theme.badge(.bottle).background : theme.chip))
                            .help(have ? String(localized: "\(d) is installed") : String(localized: "\(d) would be installed too"))
                        }
                    }
                }
            } else if e.detailsLoaded && e.kind == .formula {
                Text("No dependencies").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }

            Divider()

            if e.disabled {
                Label("Disabled in its tap: brew won't install it.", systemImage: "nosign")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            } else if e.deprecated {
                Label("Deprecated: it still installs, but Homebrew plans to disable it.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            let _ = store.buildTimesRevision
            if let w = store.deps.classifier.installWarning(e) {
                CompileWarningBox(warning: w, intelbrew: discover.isLocalTaps,
                                  deps: discover.dependenciesThatCompile(e, installedIDs: store.installedIDs).compiling)
                    .task { store.compileWarningShown() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Install command").font(.system(size: 11)).foregroundStyle(.secondary)
                CommandBox(command: e.installDisplay)
                // 0.8.6 (VM test L4): brew trusts the formula as it installs it.
                if !installed, let trust = store.discoverTrustNote(e) {
                    Label(trust, systemImage: "checkmark.shield")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if installed {
                    HStack {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(theme.badge(.bottle).foreground)
                        Spacer()
                        Button("Show in Installed") {
                            store.showInInstalled(e.id)
                        }
                        .controlSize(.small)
                    }
                    .font(.system(size: 12))
                } else {
                    let compiles = store.deps.classifier.installWarning(e) != nil
                    Button {
                        if compiles { discover.confirmInstall = e.id } else { store.startInstall(e) }
                    } label: {
                        Label(ContextMenus.installTitle(e.name, compiles: compiles), systemImage: compiles ? "hammer" : "arrow.down.circle")
                    }
                    .buttonStyle(.primaryAction)
                    .disabled(store.windowBrewActionsBlocked || e.disabled)
                    .help(store.isUpgrading ? String(localized: "Wait for the running task to finish") : store.windowBrewActionsNote ?? String(localized: "Install \(e.name)"))
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
    }
}

/// 0.8: 30/90/365-day installs from formulae.brew.sh's analytics.
/// Nothing at all in Intelbrew mode (`.unavailable`) or before Discover
/// has asked; a quiet line when they couldn't be loaded.
struct InstallCountsView: View {
    var counts: InstallCounts?
    var phase: DiscoverStore.AnalyticsPhase
    var endDate: String?

    var body: some View {
        switch phase {
        case .idle, .unavailable:
            EmptyView()
        case .failed(let message):
            Text("Install counts unavailable")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .help(message)
        case .loading:
            section {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading install counts…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        case .ready:
            section {
                if let counts {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(AnalyticsPeriod.allCases) { period in
                            stat(counts[period], period)
                        }
                    }
                } else {
                    Text("No installs recorded")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Installs").font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(endDate.map { String(localized: "Homebrew's anonymous install analytics (formulae.brew.sh), to \($0)") }
              ?? String(localized: "Homebrew's anonymous install analytics (formulae.brew.sh)"))
    }

    private func stat(_ n: Int, _ period: AnalyticsPeriod) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: InstallCounts.number(n))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(period.title)
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(InstallCounts.sentence(n, period))
        .help(InstallCounts.sentence(n, period))
    }
}

/// Discover's warning for a formula with no bottle here.
struct CompileWarningBox: View {
    var warning: CompileWarning
    var intelbrew: Bool
    /// Dependencies that would compile too.
    var deps: [CatalogEntry]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "hammer.fill").foregroundStyle(theme.badge(.source).dot)
                VStack(alignment: .leading, spacing: 3) {
                    Text(intelbrew ? String(localized: "No Intelbrew bottle yet.") : String(localized: "No bottle for this Mac."))
                        .fontWeight(.semibold)
                    Text("Installing compiles from source, which can take a long time on older Macs.")
                        .fixedSize(horizontal: false, vertical: true)
                    if let est = warning.estimateText {
                        Text("It took \(est); expect longer on an older Mac.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !deps.isEmpty {
                        Text(verbatim: { () -> String in
                            let names = deps.prefix(5).map(\.name).joined(separator: ", ") + (deps.count > 5 ? "…" : "")
                            return deps.count == 1 ? String(localized: "+1 dependency also compiles: \(names)")
                                : String(localized: "+\(deps.count) dependencies also compile: \(names)")
                        }())
                            .fontWeight(.medium)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(theme.badge(.source).foreground)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.badge(.source).background))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.badge(.source).dot.opacity(0.5), lineWidth: 0.75))
    }
}
