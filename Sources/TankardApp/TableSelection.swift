import AppKit
import SwiftUI
import TankardAppModel

/// The Tankard theme's table selection. SwiftUI's `Table` draws selection
/// with the system accent and ignores `.tint`, so under Tankard this finds
/// the table's NSTableView, turns its own highlight off, and paints the
/// selected rows' backgrounds with `TankardPalette.selection` (amber at 30%
/// over the window purple: the rows' text and badges stay WCAG AA on it).
/// Other themes leave the table alone (system highlight restored).
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
            let key = t.window?.isKeyWindow ?? false
            let color = NSColor(hex: key ? TankardPalette.selection : TankardPalette.selectionInactive)
            t.enumerateAvailableRowViews { row, index in
                Self.paint(row, color: tankard && t.isRowSelected(index) ? color : nil)
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
            }
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
                row.layer?.insertSublayer(l, at: 0)
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
