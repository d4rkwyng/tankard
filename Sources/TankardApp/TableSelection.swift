import AppKit
import SwiftUI
import TankardAppModel

/// The Tankard theme's table styling. SwiftUI's `Table` draws selection
/// with the system accent and ignores `.tint`, and its header and row
/// stripes in system greys, so under Tankard this finds the table's
/// NSTableView, turns its own highlight off, paints every other row with
/// the palette's `rowAlternate` and the selected rows with its
/// `selection` (a blend the rows' text and badges
/// stay WCAG AA on), and tints the column header. Other themes leave the
/// table alone (system highlight and header restored).
struct TableSelectionStyler: NSViewRepresentable {
    /// The theme's palette (Tankard, Dracula); nil = system styling.
    var palette: TankardColors?
    /// Changes whenever the selection or the rows do, so SwiftUI calls
    /// `updateNSView` and the selected row is repainted (programmatic
    /// selection posts no selectionDidChange).
    var token: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.setFrameSize(.zero)
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        c.palette = palette
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            if c.table == nil { c.attach(Self.findTable(near: view)) }
            c.apply()
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
        var tankard: Bool { palette != nil }
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
            t.selectionHighlightStyle = tankard ? .none : .regular
            styleHeader(t)
            let key = t.window?.isKeyWindow ?? false
            let p = palette ?? TankardPalette.active
            let color = NSColor(hex: key ? p.selection : p.selectionInactive)
            let edge = p.selectionEdge.map { NSColor(hex: $0) }
            t.enumerateAvailableRowViews { row, index in
                Self.paint(row, color: tankard && t.isRowSelected(index) ? color : nil, edge: edge)
                Self.stripe(row, color: tankard && index % 2 == 1 ? NSColor(hex: p.rowAlternate) : nil)
            }
            // Rows SwiftUI adds later get painted on the next pass.
            if tankard {
                for delay in [0.05, 0.3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.paintOnly() }
                }
            }
        }

        private func paintOnly() {
            guard let t = table, let p = palette else { return }
            let key = t.window?.isKeyWindow ?? false
            let color = NSColor(hex: key ? p.selection : p.selectionInactive)
            let edge = p.selectionEdge.map { NSColor(hex: $0) }
            t.enumerateAvailableRowViews { row, index in
                Self.paint(row, color: t.isRowSelected(index) ? color : nil, edge: edge)
                Self.stripe(row, color: index % 2 == 1 ? NSColor(hex: p.rowAlternate) : nil)
            }
        }

        /// Tints the column header and the corner above the scroller. Both
        /// sit on a banner view whose NSVisualEffectView draws the system
        /// grey material; under Tankard that is hidden and the banner filled
        /// with the palette's `header` instead.
        private func styleHeader(_ t: NSTableView) {
            guard let scroll = t.enclosingScrollView else { return }
            let color = palette.map { NSColor(hex: $0.header).cgColor }
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
            let existing = row.layer?.sublayers?.first { $0.name == name }
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
            let existing = row.layer?.sublayers?.first { $0.name == name }
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
