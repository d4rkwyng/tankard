// Draws one app-icon image: a rounded-square plate with a gradient, and the
// pixel-art mug on top, copied 1:1 at a whole-pixel offset. The mug comes in
// already scaled (nearest neighbour, by Scripts/make-icon.sh); nothing here
// resamples it.
//
//   icon-compose CANVAS_PX MUG_PNG OUT_PNG
//
// Run by Scripts/make-icon.sh. Command Line Tools only (CoreGraphics, ImageIO).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4, let n = Int(args[1]) else {
    FileHandle.standardError.write(Data("usage: icon-compose CANVAS_PX MUG_PNG OUT_PNG\n".utf8))
    exit(2)
}

// Deep purple, matching the mug's own purples (#7a3db5, #420e8a) but darker,
// so the handle and outline still read against it.
let plateTop: UInt32 = 0x4a2580
let plateBottom: UInt32 = 0x1f0d3d
// macOS app icon grid: an 824/1024 plate, centred.
let plateFraction = 824.0 / 1024.0

func color(_ v: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
            blue: CGFloat(v & 255) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let size = CGFloat(n)
let side = (size * plateFraction).rounded()
let inset = ((size - side) / 2).rounded()
let plate = CGRect(x: inset, y: inset, width: side, height: side)
let radius = side * 0.225
let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

// A soft drop shadow, as on the system icons; too small to help at 16/32 px.
if n >= 64 {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.02, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(platePath)
    ctx.setFillColor(color(plateBottom))
    ctx.fillPath()
    ctx.restoreGState()
}

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(plateTop), color(plateBottom)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
ctx.restoreGState()

// A faint light rim.
if n >= 64 {
    let rim = plate.insetBy(dx: size / 512, dy: size / 512)
    ctx.addPath(CGPath(roundedRect: rim, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(size / 256)
    ctx.strokePath()
}

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
      let mug = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("icon-compose: can't read \(args[2])\n".utf8))
    exit(1)
}
guard (n - mug.width) % 2 == 0, (n - mug.height) % 2 == 0 else {
    FileHandle.standardError.write(Data("icon-compose: a \(mug.width)x\(mug.height) mug can't be centred on whole pixels in \(n)\n".utf8))
    exit(1)
}
ctx.interpolationQuality = .none
ctx.draw(mug, in: CGRect(x: (n - mug.width) / 2, y: (n - mug.height) / 2, width: mug.width, height: mug.height))

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("icon-compose: can't write \(args[3])\n".utf8))
    exit(1)
}
