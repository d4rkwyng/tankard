import AppKit
import SwiftUI
import TankardAppModel

/// The tables' row styling, in every theme. SwiftUI's `Table` draws
/// selection with the system accent and ignores `.tint`, and its header and
/// row stripes in system greys, so this finds the table's NSTableView and
/// paints every other row's stripe itself: the palette's `rowAlternate`
/// (Tankard, Dracula) or the system's alternating row colour (Dark, Light,
/// System). For a palette it also turns the table's own highlight off,
/// paints the selected rows with the palette's `selection` (a blend the
/// rows' text and badges stay WCAG AA on), and tints the column header.
///
/// The stripes are painted in every theme, rather than left to the
/// system's `alternatesRowBackgrounds` in the system themes, so that a
/// theme switch never changes the table's configuration: changing
/// `.tableStyle(.inset(alternatesRowBackgrounds:))`,
/// `.scrollContentBackground` or `usesAlternatingRowBackgroundColors`
/// makes AppKit throw away the visible row views. For a frame the table
/// then drew empty rows 24 points high, and the row views that came back
/// from its reuse pool still carried the previous theme's stripe layers,
/// which this styler had not seen to remove (purple rows left in Dark).
struct TableSelectionStyler: NSViewRepresentable {
    /// The theme's palette (Tankard, Dracula); nil = system styling.
    var palette: TankardColors?
    /// Changes whenever the selection or the rows do, so SwiftUI calls
    /// `updateNSView` and the selected row is repainted (programmatic
    /// selection posts no selectionDidChange).
    var token: Int
    /// false: stripes only; the selection and the header stay the
    /// system's in every theme (Services).
    var paintsSelection = true
    /// 0.8.5: the rows are all the table's row height, none measured (the
    /// package lists; see PackageRow). SwiftUI sets the height itself
    /// (`defaultMinListRowHeight`), but not this.
    var fixedRowHeights = false
    /// 0.8.8: told, once per table, whether the table measures no row
    /// (true: fixed heights, it may have its rows) or was found with rows
    /// and automatic heights (false: it keeps them; the list makes a new,
    /// empty table). See RowHeightGate.
    var onRowHeights: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = AppearanceWatcher()
        v.setFrameSize(.zero)
        let c = context.coordinator
        // The system stripe colour follows the appearance (System theme:
        // macOS switching between light and dark while the app runs).
        v.onChange = { [weak c] in c?.apply() }
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        c.palette = palette
        c.paintsSelection = paintsSelection
        c.fixedRowHeights = fixedRowHeights
        c.onRowHeights = onRowHeights
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            c.attachAndApply(near: view, triesLeft: 5)
        }
    }

    /// Calls `onChange` when its effective appearance changes.
    final class AppearanceWatcher: NSView {
        var onChange: (() -> Void)?
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
    }

    /// The NSTableView sharing an ancestor with `view` (this view sits in
    /// the Table's background).
    @MainActor
    static func findTable(near view: NSView) -> NSTableView? {
        var ancestor: NSView? = view.superview
        for _ in 0..<8 {
            guard let a = ancestor else { return nil }
            if let t = firstTable(in: a) { return t }
            ancestor = a.superview
        }
        return nil
    }

    @MainActor
    static func firstTable(in v: NSView) -> NSTableView? {
        if let t = v as? NSTableView { return t }
        for s in v.subviews { if let t = firstTable(in: s) { return t } }
        return nil
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var table: NSTableView?
        var palette: TankardColors?
        var paintsSelection = true
        var fixedRowHeights = false
        /// 0.8.8: the table whose row heights were decided (`apply`). Kept
        /// per table, not per coordinator: SwiftUI can give this coordinator
        /// a new NSTableView (a rebuilt list), and that table decides anew.
        private weak var rowHeightsDecidedFor: NSTableView?
        var onRowHeights: ((Bool) -> Void)?
        /// The table `onRowHeights` was last told about.
        private weak var rowHeightsReportedFor: NSTableView?
        /// A notification's `apply` is waiting for the next turn.
        private var applyPending = false
        /// Whether the selection and header are painted here (a palette
        /// theme on a table that wants it).
        var tankard: Bool { palette != nil && paintsSelection }
        /// Block observers; removed in deinit (nonisolated(unsafe): only
        /// touched on the main thread, and deinit runs once nothing else can).
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        /// Finds the table (once) and applies. 0.8.8: a list shows no rows
        /// until it hears from `onRowHeights`, so a table not in the window
        /// yet is looked for again a moment later; if it never turns up the
        /// list is told to show its rows anyway.
        func attachAndApply(near view: NSView, triesLeft: Int) {
            if table == nil { attach(TableSelectionStyler.findTable(near: view)) }
            guard table != nil else {
                if triesLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak view] in
                        guard let self, let view else { return }
                        self.attachAndApply(near: view, triesLeft: triesLeft - 1)
                    }
                } else if fixedRowHeights {
                    onRowHeights?(true)
                }
                return
            }
            apply()
        }

        func attach(_ t: NSTableView?) {
            guard let t else { return }
            table = t
            let nc = NotificationCenter.default
            // 0.8.8: on the next turn, never inside the notification.
            // The table posts selectionDidChange and its clip view
            // boundsDidChange from inside its own update (endUpdates, while
            // SwiftUI inserts or removes rows); walking and repainting its
            // row views from there re-enters the table mid-update.
            let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.applySoon() }
            }
            observers.append(nc.addObserver(forName: NSTableView.selectionDidChangeNotification, object: t, queue: .main, using: refresh))
            if let clip = t.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: refresh))
            }
            // 0.8.8 (gauntlet 26, P7): a wider table (full screen) has
            // wider rows; their stripes and selection were painted at the
            // old width and stopped after the Available column.
            t.postsFrameChangedNotifications = true
            observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: t, queue: .main, using: refresh))
            observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: refresh))
            observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main, using: refresh))
        }

        /// `apply` on the next turn of the main queue, once however many
        /// notifications come before it.
        func applySoon() {
            guard !applyPending else { return }
            applyPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyPending = false
                self.apply()
            }
        }

        func apply() {
            guard let t = table else { return }
            // 0.8.8 (B1 again): decided once per table, when it is first
            // found, and only switched while it has never had a row.
            // SwiftUI fills a table with automatic row heights with cell
            // views laid out by constraints (translatesAutoresizingMask-
            // IntoConstraints false) and keeps reusing them. Once the table
            // stops using automatic row heights, AppKit no longer sizes
            // those cells: every cell it shows, reused or not, is 0×30 at
            // its column's x (seen on macOS 15 with a debug dump), so text
            // that fills its cell draws nothing and only the fixed-size
            // badge, size and marks overflow and draw. 0.8.7 switched a
            // table with rows only when its rows next went to none (a
            // search matching nothing), which still left the cells it had
            // made under automatic heights: clearing the search gave blank
            // rows. A table switched before its first row (launch, a tab
            // shown with an empty search) makes frame-laid cells and is
            // fine; a table made with rows keeps automatic heights for
            // good (its rows still measure 30 pt, PackageRow).
            if fixedRowHeights && rowHeightsDecidedFor !== t {
                rowHeightsDecidedFor = t
                if t.usesAutomaticRowHeights && t.numberOfRows == 0 { t.usesAutomaticRowHeights = false }
            }
            // 0.8.8: a table that kept automatic heights measures its rows
            // on every big change, and AppKit's row-height cache re-enters
            // itself while SwiftUI inserts or removes rows ("Application
            // performed a reentrant operation in its NSTableView delegate",
            // NSTableRowHeightData _cacheRowSpansInRange from endUpdates).
            // So the lists hold their rows back until their table is
            // found empty and switched (RowHeightGate), and are told here.
            if fixedRowHeights && rowHeightsReportedFor !== t {
                rowHeightsReportedFor = t
                onRowHeights?(!t.usesAutomaticRowHeights)
            }
            let highlight: NSTableView.SelectionHighlightStyle = tankard ? .none : .regular
            if t.selectionHighlightStyle != highlight { t.selectionHighlightStyle = highlight }
            styleHeader(t)
            paintRows()
            // Rows the table adds or brings back from its reuse pool a
            // moment later (with whatever layers they had) get painted on
            // the next passes.
            for delay in [0.05, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.paintRows() }
            }
        }

        /// The stripe colour: the palette's, or the system's alternating
        /// row colour resolved for the table's current appearance.
        private func stripeColor(_ t: NSTableView) -> NSColor {
            if let p = palette { return NSColor(hex: p.rowAlternate) }
            var c = NSColor.alternatingContentBackgroundColors.count > 1 ? NSColor.alternatingContentBackgroundColors[1] : NSColor.controlBackgroundColor
            t.effectiveAppearance.performAsCurrentDrawingAppearance {
                c = NSColor(cgColor: c.cgColor) ?? c
            }
            return c
        }

        /// Every available row: its stripe (odd rows), and its selection
        /// (palette themes; removed otherwise). Every row is set, never
        /// only the ones that changed, so no row keeps an earlier theme's.
        private func paintRows() {
            guard let t = table else { return }
            let stripe = stripeColor(t)
            let p = palette ?? TankardPalette.active
            let key = t.window?.isKeyWindow ?? false
            let selection = NSColor(hex: key ? p.selection : p.selectionInactive)
            let edge = p.selectionEdge.map { NSColor(hex: $0) }
            let paintSelection = tankard
            t.enumerateAvailableRowViews { row, index in
                Self.paint(row, color: paintSelection && t.isRowSelected(index) ? selection : nil, edge: edge)
                Self.stripe(row, color: index % 2 == 1 ? stripe : nil)
            }
        }

        /// Tints the column header and the corner above the scroller. Both
        /// sit on a banner view whose NSVisualEffectView draws the system
        /// grey material; under Tankard that is hidden and the banner filled
        /// with the palette's `header` instead.
        private func styleHeader(_ t: NSTableView) {
            guard let scroll = t.enclosingScrollView else { return }
            let color = tankard ? palette.map { NSColor(hex: $0.header).cgColor } : nil
            func walk(_ v: NSView, depth: Int) {
                if let effect = v as? NSVisualEffectView, let banner = effect.superview,
                   String(describing: type(of: banner)).contains("Banner") {
                    effect.isHidden = tankard
                    banner.wantsLayer = true
                    banner.layer?.backgroundColor = color
                }
                if depth < 3 { for s in v.subviews { walk(s, depth: depth + 1) } }
            }
            walk(scroll, depth: 0)
        }

        /// The row stripe: a rounded layer like the selection's, under it.
        static func stripe(_ row: NSTableRowView, color: NSColor?) {
            let name = "tankard.stripe"
            let all = row.layer?.sublayers?.filter { $0.name == name } ?? []
            all.dropFirst().forEach { $0.removeFromSuperlayer() }
            let existing = all.first
            guard let color else {
                existing?.removeFromSuperlayer()
                return
            }
            row.wantsLayer = true
            let layer = existing ?? {
                let l = CALayer()
                l.name = name
                l.cornerRadius = 5
                l.zPosition = -2
                row.layer?.insertSublayer(l, at: 0)
                return l
            }()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = color.cgColor
            layer.frame = row.bounds.insetBy(dx: 10, dy: 0)
            CATransaction.commit()
        }

        /// A rounded layer under the row's content, inset like the system's
        /// inset-style selection; nil removes it.
        /// `edge`: a 3-point bar down the left side (Dracula), clipped to
        /// the rounded corners.
        static func paint(_ row: NSTableRowView, color: NSColor?, edge: NSColor? = nil) {
            let name = "tankard.selection"
            let all = row.layer?.sublayers?.filter { $0.name == name } ?? []
            all.dropFirst().forEach { $0.removeFromSuperlayer() }
            let existing = all.first
            guard let color else {
                existing?.removeFromSuperlayer()
                return
            }
            row.wantsLayer = true
            let layer = existing ?? {
                let l = CALayer()
                l.name = name
                l.cornerRadius = 5
                l.zPosition = -1
                // Above the stripe, by order as well as zPosition (the
                // snapshot's cacheDisplay goes by order).
                let stripe = row.layer?.sublayers?.first { $0.name == "tankard.stripe" }
                if let stripe { row.layer?.insertSublayer(l, above: stripe) } else { row.layer?.insertSublayer(l, at: 0) }
                return l
            }()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = color.cgColor
            layer.frame = row.bounds.insetBy(dx: 10, dy: 0)
            layer.masksToBounds = true
            let bar = layer.sublayers?.first { $0.name == "tankard.edge" }
            if let edge {
                let b = bar ?? {
                    let l = CALayer()
                    l.name = "tankard.edge"
                    layer.addSublayer(l)
                    return l
                }()
                b.backgroundColor = edge.cgColor
                b.frame = CGRect(x: 0, y: 0, width: 3, height: layer.bounds.height)
            } else {
                bar?.removeFromSuperlayer()
            }
            CATransaction.commit()
        }

        deinit {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }
    }
}

/// 0.8.3: scrolls the table to `row` (the selection's index in the rows
/// the Table was given) when `request` changes (AppStore.revealRequest: a
/// menu-bar package row). SwiftUI's Table has no scroll-to, and a
/// programmatic selection doesn't scroll. The index comes from the rows,
/// not the NSTableView's selectedRow, which SwiftUI sets only later. A
/// table made after the request (the window was closed) scrolls once when
/// it appears; the table may not have its rows yet, so it tries again
/// briefly.
struct TableRevealer: NSViewRepresentable {
    var request: Int
    var row: Int?

    final class Coordinator {
        var seen: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.setFrameSize(.zero)
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        guard request > 0, c.seen != request, let row else { return }
        c.seen = request
        for delay in [0.0, 0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let view, let t = TableSelectionStyler.findTable(near: view), row < t.numberOfRows else { return }
                t.scrollRowToVisible(row)
            }
        }
    }
}

/// 0.8.7: type-select by package name (TypeSelect). SwiftUI's Table gives
/// AppKit no type-select string per row, so AppKit's own type-select
/// matched other text in the row's views (a note such as "No bottle: …"),
/// and typing a letter jumped to the wrong package. This turns AppKit's
/// off on the table and, while the table has the keyboard focus, takes the
/// typed letters (no ⌘, ⌃ or ⌥) and selects the first row whose name
/// starts with them, through the table (as AppKit's did, so SwiftUI's
/// selection binding follows) and scrolled into view.
struct TableTypeSelect: NSViewRepresentable {
    /// The rows' names, in the order the Table was given them.
    var names: [String]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.setFrameSize(.zero)
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        c.names = names
        guard c.table == nil else { return }
        DispatchQueue.main.async { [weak view] in
            guard let view, c.table == nil, let t = TableSelectionStyler.findTable(near: view) else { return }
            c.attach(t)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        weak var table: NSTableView?
        var names: [String] = []
        private var search = TypeSelect()
        nonisolated(unsafe) private var monitor: Any?

        func attach(_ t: NSTableView) {
            // A rebuilt table attaches again: drop the old monitor first.
            detach()
            table = t
            t.allowsTypeSelect = false
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Key events arrive on the main thread.
                nonisolated(unsafe) let e = event
                let handled = MainActor.assumeIsolated { self?.handle(e) ?? false }
                return handled ? nil : event
            }
        }

        func detach() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }

        /// 0.8.8 (gauntlet 15): the down arrow in the toolbar's search
        /// field moves into the results, as in Finder and Mail: the list
        /// takes the keyboard focus and, when nothing is selected, its
        /// first row. (It did nothing: the field kept the key.)
        private func moveFromSearchField(_ event: NSEvent) -> Bool {
            guard event.keyCode == 125, // down arrow
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let t = table, let w = t.window, event.window === w, !t.isHiddenOrHasHiddenAncestor,
                  let editor = w.firstResponder as? NSTextView, editor.isFieldEditor,
                  editor.delegate is NSSearchField,
                  t.numberOfRows > 0 else { return false }
            w.makeFirstResponder(t)
            if t.selectedRow < 0 {
                t.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            t.scrollRowToVisible(max(t.selectedRow, 0))
            return true
        }

        /// true: the key was type-select's (or the search field's down arrow).
        private func handle(_ event: NSEvent) -> Bool {
            if moveFromSearchField(event) { return true }
            guard let t = table, let w = t.window, event.window === w, w.firstResponder === t else { return false }
            guard event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty,
                  let chars = event.characters,
                  TypeSelect.isTypeSelectInput(chars, bufferEmpty: search.buffer.isEmpty) else {
                search.reset()
                return false
            }
            let count = min(names.count, t.numberOfRows)
            let current = t.selectedRow >= 0 && t.selectedRow < count ? t.selectedRow : nil
            guard let row = search.select(chars, at: event.timestamp, names: Array(names.prefix(count)), selected: current) else {
                return true
            }
            if row != t.selectedRow {
                t.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            t.scrollRowToVisible(row)
            return true
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}

