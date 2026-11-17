import AppKit

/// The menu-bar icon: a 16×16 pixel-art tankard drawn as a template image
/// (macOS tints it for light/dark menu bars). Handle on the left and glass
/// ridges like Tankard's logo; the foam head shows only when upgrades are
/// waiting, so an up-to-date Mac shows an empty tankard.
@MainActor
enum MenuBarIcon {
    /// Rows top to bottom, 16 columns each. "#" is a filled pixel.
    static let foam: [String] = [
        "......##.##.....",
        "....#########...",
        "...###########..",
        "...###########..",
        "....#########...",
    ]
    static let glass: [String] = [
        "....#########...",
        ".#####.#.#.##...",
        "##..##.#.#.##...",
        "#...##.#.#.##...",
        "#...##.#.#.##...",
        "#...##.#.#.##...",
        "##..##.#.#.##...",
        ".#####.#.#.##...",
        "....#########...",
        "...###########..",
        "................",
    ]
    /// Without foam the rim is the top of the glass: an open rim row instead.
    static let emptyTop: [String] = [
        "................",
        "................",
        "................",
        "....#########...",
        "....#.......#...",
    ]

    static func rows(full: Bool) -> [String] { (full ? foam : emptyTop) + glass }

    static func image(full: Bool) -> NSImage {
        let grid = rows(full: full)
        let size = NSSize(width: 16, height: grid.count)
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in grid.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = full ? String(localized: "Tankard: upgrades ready") : "Tankard"
        return img
    }

    static let full = image(full: true)
    static let empty = image(full: false)
}
