import AppKit
import SwiftUI

/// Screenshot support for docs and review, off unless asked for:
///
///   TANKARD_SNAPSHOT=/path/out.png   write the window (and an open sheet) here
///   TANKARD_SNAPSHOT_DELAY=4         seconds after launch (default 4)
///   TANKARD_SNAPSHOT_QUIT=1          quit after writing
///   TANKARD_SNAPSHOT_SIZE=1040x620   content size to set first
///   TANKARD_SNAPSHOT_ORIGIN=20,300   window origin (screen points) to set first
///   TANKARD_LOG_FRAMES=1             print every window move/resize to stderr
///   TANKARD_SNAPSHOT_LAYOUT=1        also print the layout (window, table,
///                                    rows, cells) to stderr, for comparing themes
///
/// The window draws itself into a bitmap (`cacheDisplay`), so this works
/// without Screen Recording permission and while the screen is locked,
/// where `screencapture` only sees black. An attached sheet is drawn on top
/// at its real position.
struct SnapshotRequest {
    var path: String
    var delay: Double
    var quit: Bool
    var width: CGFloat = 1040
    var height: CGFloat = 620
    /// 0.3: TANKARD_SNAPSHOT_VIEW=menubar|settings|about: write that view
    /// (the menu-bar panel, the Settings window's General tab, the About
    /// panel) instead of the main window.
    var view: String?
    var origin: NSPoint?

    init?(environment env: [String: String]) {
        guard let p = env["TANKARD_SNAPSHOT"], !p.isEmpty else { return nil }
        path = p
        delay = env["TANKARD_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 4
        quit = env["TANKARD_SNAPSHOT_QUIT"] == "1"
        view = env["TANKARD_SNAPSHOT_VIEW"].flatMap { $0.isEmpty ? nil : $0.lowercased() }
        if let s = env["TANKARD_SNAPSHOT_SIZE"]?.split(separator: "x"), s.count == 2,
           let w = Double(s[0]), let h = Double(s[1]) {
            width = w
            height = h
        }
        if let o = env["TANKARD_SNAPSHOT_ORIGIN"]?.split(separator: ","), o.count == 2,
           let x = Double(o[0]), let y = Double(o[1]) {
            origin = NSPoint(x: x, y: y)
        }
    }
}

struct SnapshotHook: NSViewRepresentable {
    var request: SnapshotRequest?
    /// Builds the view named by `request.view` ("menubar", "settings"), if any.
    var makeView: (String) -> AnyView? = { _ in nil }
    /// Intelbrew mode (the About panel's Intelbrew line).
    var intelbrew: () -> Bool = { false }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        if let request {
            // A fixed size, so shots are comparable whatever frame the
            // window restored.
            DispatchQueue.main.async { [weak v] in
                guard let w = v?.window else { return }
                w.setContentSize(NSSize(width: request.width, height: request.height))
                if let o = request.origin { w.setFrameOrigin(o) }
                if ProcessInfo.processInfo.environment["TANKARD_LOG_FRAMES"] == "1" { Snapshot.logFrames(of: w) }
            }
            if request.view == "about" {
                let intelbrew = self.intelbrew
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, request.delay - 1)) { AboutPanel.show(intelbrew: intelbrew()) }
            }
            let makeView = self.makeView
            DispatchQueue.main.asyncAfter(deadline: .now() + request.delay) { [weak v] in
                guard let window = v?.window else { return }
                if let name = request.view {
                    if name == "about" {
                        if let panel = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.className.contains("Panel") })
                            ?? NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.title.isEmpty }) {
                            Snapshot.write(window: panel, to: request.path)
                        } else {
                            FileHandle.standardError.write(Data("snapshot: no About panel found\n".utf8))
                        }
                    } else if let content = makeView(name) {
                        Snapshot.write(view: content, appearance: window.effectiveAppearance, to: request.path)
                    }
                    if request.quit { exit(0) }
                    return
                }
                if ProcessInfo.processInfo.environment["TANKARD_SNAPSHOT_LAYOUT"] == "1" {
                    FileHandle.standardError.write(Data(Snapshot.layout(of: window).utf8))
                }
                Snapshot.write(window: window, to: request.path)
                // exit, not terminate: AppKit won't terminate with a sheet up.
                if request.quit { exit(0) }
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
enum Snapshot {
    /// Prints the window's frame now and on every move or resize.
    static func logFrames(of window: NSWindow) {
        @Sendable func log(_ why: String, _ f: NSRect) {
            FileHandle.standardError.write(Data(String(format: "frame: %@ %.1f,%.1f %.1fx%.1f t=%.2f\n", why, f.minX, f.minY, f.width, f.height,
                                                       ProcessInfo.processInfo.systemUptime).utf8))
        }
        log("start", window.frame)
        // Once a second: the table's identity, scroll offset and column
        // widths, to see whether a theme switch rebuilds or scrolls it.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let content = window?.contentView else { return }
                func tables(_ v: NSView) -> [NSTableView] { (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables) }
                for t in tables(content) {
                    let clip = t.enclosingScrollView?.contentView.bounds.origin ?? .zero
                    let widths = t.tableColumns.map { String(format: "%.0f", $0.width) }.joined(separator: "/")
                    FileHandle.standardError.write(Data(String(format: "table: %@ scroll=%.0f,%.0f cols=%@ t=%.2f\n",
                        "\(ObjectIdentifier(t).hashValue)", clip.x, clip.y, widths, ProcessInfo.processInfo.systemUptime).utf8))
                }
            }
        }
        for (name, why) in [(NSWindow.didMoveNotification, "move"), (NSWindow.didResizeNotification, "resize")] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let f = window?.frame { log(why, f) } }
            }
        }
    }

    /// The geometry that must not depend on the theme: the window, the
    /// content view, and for each table its scroll view's insets, spacing,
    /// and the first rows' and cells' frames in window coordinates.
    static func layout(of window: NSWindow) -> String {
        func r(_ f: NSRect) -> String { String(format: "%.1f,%.1f %.1fx%.1f", f.minX, f.minY, f.width, f.height) }
        var out = ["layout: window \(r(window.frame))"]
        guard let content = window.contentView else { return out.joined(separator: "\n") + "\n" }
        out.append("layout: content \(r(content.frame))")
        func tables(_ v: NSView) -> [NSTableView] {
            (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables)
        }
        for t in tables(content) {
            let sv = t.enclosingScrollView
            out.append("layout: table \(r(t.convert(t.bounds, to: nil))) style=\(t.style.rawValue) spacing=\(t.intercellSpacing) "
                       + "insets=\(sv.map { "\($0.contentInsets)" } ?? "-") scroll=\(sv.map { r($0.convert($0.bounds, to: nil)) } ?? "-")"
                       + " clip=\(sv.map { r($0.contentView.frame) } ?? "-")"
                       + " scroller=\(sv.map { "\($0.scrollerStyle.rawValue)/\($0.verticalScroller.map { r($0.frame) + ($0.isHidden ? " hidden" : "") } ?? "-")" } ?? "-")")
            out.append("layout:  heights " + (0..<t.numberOfRows).map { String(format: "%.0f", t.rect(ofRow: $0).height) }.joined(separator: ","))
            for i in 0..<min(t.numberOfRows, 4) {
                guard let row = t.rowView(atRow: i, makeIfNecessary: false) else { continue }
                var line = "layout:  row \(i) \(r(row.convert(row.bounds, to: nil)))"
                for c in 0..<t.numberOfColumns {
                    if let cell = t.view(atColumn: c, row: i, makeIfNecessary: false) {
                        line += " | c\(c) \(r(cell.convert(cell.bounds, to: nil)))"
                    }
                }
                out.append(line)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func render(_ window: NSWindow) -> NSBitmapImageRep? {
        // The frame view includes the title bar and toolbar.
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        // Always 2x, even when the window's screen reports 1x (a locked or
        // headless display).
        let b = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = b.size
        view.cacheDisplay(in: b, to: rep)
        return rep
    }

    /// A SwiftUI view on its own, at its fitting size, in an off-screen window.
    static func write(view: AnyView, appearance: NSAppearance, to path: String) {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        let size = host.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = appearance
        w.contentView = host
        w.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        let rect = host.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = rect.size
        host.cacheDisplay(in: rect, to: rep)
        w.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("snapshot: wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
        }
    }

    static func write(window: NSWindow, to path: String) {
        guard let base = render(window) else {
            FileHandle.standardError.write(Data("snapshot: could not render window\n".utf8))
            return
        }
        let scale = CGFloat(base.pixelsWide) / max(window.frame.width, 1)
        let size = NSSize(width: base.pixelsWide, height: base.pixelsHigh)
        let out = NSImage(size: size) // drawn in pixels
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        base.draw(in: NSRect(origin: .zero, size: size))
        if let sheet = window.attachedSheet, let rep = render(sheet) {
            // Dim the parent like the real thing, then draw the sheet where it sits.
            NSColor.black.withAlphaComponent(0.10).setFill()
            NSRect(origin: .zero, size: size).fill(using: .sourceOver)
            let f = sheet.frame
            let rect = NSRect(x: (f.minX - window.frame.minX) * scale, y: (f.minY - window.frame.minY) * scale,
                              width: f.width * scale, height: f.height * scale)
            NSColor.black.withAlphaComponent(0.25).setFill()
            rect.insetBy(dx: -1, dy: -1).fill(using: .sourceOver)
            rep.draw(in: rect)
        }
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("snapshot: wrote \(path) (\(base.pixelsWide)x\(base.pixelsHigh))\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
        }
    }
}
