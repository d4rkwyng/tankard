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
            if let notice = discover.casksNotice {
                NoticeBanner(text: notice, systemImage: "info.circle")
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
                    Text(discover.source.isEmpty ? (discover.isLocalTaps ? "Local taps" : "formulae.brew.sh") : discover.source)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let t = discover.loadedAt, !discover.isLocalTaps {
                        Text("· fetched \(updatedAgo(t, now: Date()))")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help(discover.isLocalTaps
                      ? "Intelbrew mode: names from the taps on this Mac, details from brew info. formulae.brew.sh isn't used: it describes upstream Homebrew."
                      : "From formulae.brew.sh, cached for an hour in ~/Library/Caches/net.mindtricks.tankard/api")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if discover.phase == .ready && discover.formulaCount > 0 {
                ThemedSegmentedPicker(title: "Bottles", selection: bottleScope, options: BottleScope.allCases) { scope in
                    scope == .bottled ? "\(discover.bottledChipTitle) (\(discover.bottledCountText))" : "All"
                }
                .help(discover.isLocalTaps
                      ? "Formulae with a bottle for this Mac (Intelbrew's or Homebrew's). The rest compile from source when installed."
                      : "Formulae with a bottle for this Mac. The rest compile from source when installed.")
            }

            ThemedSegmentedPicker(title: "Kind", selection: $discover.kind, options: CatalogKindFilter.allCases, label: \.title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.strip)
    }

    private var headline: String {
        switch discover.phase {
        case .idle, .loading: return discover.isLocalTaps ? "Reading the local taps…" : "Loading Homebrew's catalogue…"
        case .failed: return "Couldn't load the catalogue"
        case .ready:
            if discover.resultsQuery.isEmpty { return "Search \(discover.totalCount.formatted()) packages" }
            let n = discover.results.count
            return "\(n == 200 ? "Top 200" : "\(n)") result\(n == 1 ? "" : "s") for “\(discover.resultsQuery)”"
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
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(e.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                        if installed.contains(e.id) {
                            InstalledMark()
                        }
                        if e.disabled || e.deprecated {
                            Text(e.disabled ? "disabled" : "deprecated").font(.system(size: 9.5)).foregroundStyle(.orange)
                        }
                    }
                    if let d = e.desc {
                        Text(d).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
                .onAppear { discover.needDetails([e.id]) }
            }
            .width(min: 180, ideal: 300)

            TableColumn("Version") { (e: CatalogEntry) in
                VersionText(text: e.version ?? (e.detailsLoaded ? "–" : "…"))
            }
            .width(min: 60, ideal: 90)

            TableColumn("Kind") { (e: CatalogEntry) in
                Text(e.kind == .cask ? "Cask" : "Formula").foregroundStyle(.secondary)
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
        .tableStyle(.inset(alternatesRowBackgrounds: !theme.isCustom))
        .scrollContentBackground(theme.isCustom ? .hidden : .automatic)
        .background(theme.table ?? .clear)
        .background(TableSelectionStyler(palette: theme.palette, token: rowsToken))
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
            ProgressView(discover.isLocalTaps ? "Reading the local taps…" : "Loading formulae.brew.sh…")
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load the catalogue", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await discover.activate() } }
            }
        case .ready:
            if discover.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("Search Homebrew", systemImage: "magnifyingglass",
                                       description: Text("Type a name or a word from a description."))
            } else if discover.results.isEmpty && discover.resultsQuery == discover.query {
                ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                       description: Text("Nothing matches “\(discover.query)”."))
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
                    Text(e.desc ?? (e.kind == .cask ? "Cask" : "Formula"))
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
                row("Version", e.version ?? (e.detailsLoaded ? "–" : "…"))
                row("Kind", e.kind == .cask ? "Cask" : "Formula")
                if let tap = e.tap { row("Tap", tap, mono: true) }
                if e.kind == .formula { row("Licence", e.license ?? (e.detailsLoaded ? "Not stated" : "…")) }
                if let tag = e.bottleTag { row("Bottle tag", tag, mono: true) }
                if !e.otherNames.isEmpty {
                    row(e.kind == .cask ? "Name" : "Also", e.otherNames.prefix(4).joined(separator: ", "))
                }
            }
            .font(.system(size: 12))

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
                            .help(have ? "\(d) is installed" : "\(d) would be installed too")
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
                Label("Deprecated: it still installs, but won't be updated for long.", systemImage: "exclamationmark.triangle")
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
                if installed {
                    HStack {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(theme.badge(.bottle).foreground)
                        Spacer()
                        Button("Show in Installed") {
                            store.tab = .installed
                            store.selection = e.id
                        }
                        .controlSize(.small)
                    }
                    .font(.system(size: 12))
                } else {
                    let compiles = store.deps.classifier.installWarning(e) != nil
                    Button {
                        if compiles { discover.confirmInstall = e.id } else { store.startInstall(e) }
                    } label: {
                        Label(compiles ? "Install (compiles)" : "Install \(e.name)", systemImage: compiles ? "hammer" : "arrow.down.circle")
                    }
                    .buttonStyle(.primaryAction)
                    .disabled(store.isUpgrading || e.disabled)
                    .help(store.isUpgrading ? "Wait for the running brew to finish" : e.installDisplay)
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
                    Text(intelbrew ? "No Intelbrew bottle yet." : "No bottle for this Mac.")
                        .fontWeight(.semibold)
                    Text("Installing compiles from source, which can take a long time on older Macs.")
                        .fixedSize(horizontal: false, vertical: true)
                    if let est = warning.estimateText {
                        Text("It took \(est); expect longer on an older Mac.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !deps.isEmpty {
                        Text("+\(deps.count) dependenc\(deps.count == 1 ? "y" : "ies") also compile\(deps.count == 1 ? "s" : ""): \(deps.prefix(5).map(\.name).joined(separator: ", "))\(deps.count > 5 ? "…" : "")")
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
