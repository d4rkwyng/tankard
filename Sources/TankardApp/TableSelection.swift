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
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            if c.table == nil { c.attach(Self.findTable(near: view)) }
            c.apply()
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
        /// Whether the selection and header are painted here (a palette
        /// theme on a table that wants it).
        var tankard: Bool { palette != nil && paintsSelection }
        /// Block observers; removed in deinit (nonisolated(unsafe): only
        /// touched on the main thread, and deinit runs once nothing else can).
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        func attach(_ t: NSTableView?) {
            guard let t else { return }
            table = t
            let nc = NotificationCenter.default
            let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            observers.append(nc.addObserver(forName: NSTableView.selectionDidChangeNotification, object: t, queue: .main, using: refresh))
            if let clip = t.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: refresh))
            }
            observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: refresh))
            observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main, using: refresh))
        }

        func apply() {
            guard let t = table else { return }
            if fixedRowHeights && t.usesAutomaticRowHeights { t.usesAutomaticRowHeights = false }
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
