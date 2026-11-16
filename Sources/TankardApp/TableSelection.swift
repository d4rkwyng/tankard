import AppKit
import SwiftUI
import TankardAppModel

/// The Tankard theme's table styling. SwiftUI's `Table` draws selection
/// with the system accent and ignores `.tint`, and its header and row
/// stripes in system greys, so under Tankard this finds the table's
/// NSTableView, turns its own highlight off, paints every other row with
/// `TankardPalette.rowAlternate` and the selected rows with
/// `TankardPalette.selection` (an amber blend the rows' text and badges
/// stay WCAG AA on), and tints the column header. Other themes leave the
/// table alone (system highlight and header restored).
struct TableSelectionStyler: NSViewRepresentable {
    var tankard: Bool
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
        c.tankard = tankard
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
        var tankard = false
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
            let color = NSColor(hex: key ? TankardPalette.selection : TankardPalette.selectionInactive)
            t.enumerateAvailableRowViews { row, index in
                Self.paint(row, color: tankard && t.isRowSelected(index) ? color : nil)
                Self.stripe(row, on: tankard && index % 2 == 1)
            }
            // Rows SwiftUI adds later get painted on the next pass.
            if tankard {
                for delay in [0.05, 0.3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.paintOnly() }
                }
            }
        }

        private func paintOnly() {
            guard let t = table, tankard else { return }
            let key = t.window?.isKeyWindow ?? false
            let color = NSColor(hex: key ? TankardPalette.selection : TankardPalette.selectionInactive)
            t.enumerateAvailableRowViews { row, index in
                Self.paint(row, color: t.isRowSelected(index) ? color : nil)
                Self.stripe(row, on: index % 2 == 1)
            }
        }

        /// Tints the column header and the corner above the scroller. Both
        /// sit on a banner view whose NSVisualEffectView draws the system
        /// grey material; under Tankard that is hidden and the banner filled
        /// with `TankardPalette.header` instead.
        private func styleHeader(_ t: NSTableView) {
            guard let scroll = t.enclosingScrollView else { return }
            let color = tankard ? NSColor(hex: TankardPalette.header).cgColor : nil
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
        static func stripe(_ row: NSTableRowView, on: Bool) {
            let name = "tankard.stripe"
            let existing = row.layer?.sublayers?.first { $0.name == name }
            guard on else {
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
            layer.backgroundColor = NSColor(hex: TankardPalette.rowAlternate).cgColor
            layer.frame = row.bounds.insetBy(dx: 10, dy: 0)
            CATransaction.commit()
        }

        /// A rounded layer under the row's content, inset like the system's
        /// inset-style selection; nil removes it.
        static func paint(_ row: NSTableRowView, color: NSColor?) {
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
            CATransaction.commit()
        }

        deinit {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }
    }
}
