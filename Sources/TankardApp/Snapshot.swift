import AppKit
import SwiftUI

/// Screenshot support for docs and review, off unless asked for:
///
///   TANKARD_SNAPSHOT=/path/out.png   write the window (and an open sheet) here
///   TANKARD_SNAPSHOT_DELAY=4         seconds after launch (default 4)
///   TANKARD_SNAPSHOT_QUIT=1          quit after writing
///   TANKARD_SNAPSHOT_SIZE=1040x620   content size to set first
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

    init?(environment env: [String: String]) {
        guard let p = env["TANKARD_SNAPSHOT"], !p.isEmpty else { return nil }
        path = p
        delay = env["TANKARD_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 4
        quit = env["TANKARD_SNAPSHOT_QUIT"] == "1"
        if let s = env["TANKARD_SNAPSHOT_SIZE"]?.split(separator: "x"), s.count == 2,
           let w = Double(s[0]), let h = Double(s[1]) {
            width = w
            height = h
        }
    }
}

struct SnapshotHook: NSViewRepresentable {
    var request: SnapshotRequest?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        if let request {
            // A fixed size, so shots are comparable whatever frame the
            // window restored.
            DispatchQueue.main.async { [weak v] in
                v?.window?.setContentSize(NSSize(width: request.width, height: request.height))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + request.delay) { [weak v] in
                guard let window = v?.window else { return }
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
