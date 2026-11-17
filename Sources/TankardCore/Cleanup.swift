import Foundation

/// What `brew cleanup -n` (dry run) says it would remove.
///
/// brew prints one `Would remove: <path> (<size>)` line per item (size is
/// "64B", "457.3MB" or "1,850 files, 16.4MB"), `Would remove (broken
/// link): <path>` and `(empty directory)` lines without sizes, and, only
/// when the total isn't zero, `==> This operation would free approximately
/// 2.5GB of disk space.` (Homebrew/cmd/cleanup.rb, brew 7.0.14). Sizes use
/// brew's Formatter.disk_usage_readable: powers of 1000, B/KB/MB/GB.
public struct CleanupDryRun: Sendable, Equatable {
    public enum ItemKind: String, Sendable {
        /// An old keg in the Cellar.
        case oldVersion
        /// A download in brew's cache (bottles, source tarballs, cask files, language caches).
        case download
        /// A log directory under ~/Library/Logs/Homebrew.
        case log
        /// Broken symlinks, empty directories, anything else.
        case other
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public var path: String
        /// As brew printed it ("457.3MB"); nil for links and empty directories.
        public var sizeText: String?
        public var bytes: Int64?
        public var files: Int?
        public var kind: ItemKind
        public var id: String { path }
    }

    /// Items in brew's order, each path once.
    public var items: [Item]
    /// "2.5GB" from brew's summary line; nil when brew printed none.
    public var summaryText: String?
    public var summaryBytes: Int64?
    /// `Warning:` lines (deduplicated, in order).
    public var warnings: [String]
    /// `Error:` lines and what follows them.
    public var errors: [String]

    /// brew's own total when it printed one, else the sum of the items.
    public var totalBytes: Int64 {
        summaryBytes ?? items.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    /// "2.5GB" (brew's) or the summed total in brew's format.
    public var totalText: String {
        summaryText ?? CleanupDryRun.format(bytes: totalBytes)
    }

    /// Whether `totalText` is brew's figure (true) or Tankard's sum.
    public var totalIsFromBrew: Bool { summaryText != nil }

    public func bytes(of kind: ItemKind) -> Int64 {
        items.filter { $0.kind == kind }.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    public static func parse(_ output: String, cachePath: String? = nil) -> CleanupDryRun {
        var items: [Item] = []
        var seen: Set<String> = []
        var summaryText: String?
        var warnings: [String] = []
        var errors: [String] = []
        var inError = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { inError = false; continue }
            if let total = summary(line) {
                summaryText = total
                inError = false
            } else if let item = item(line, cachePath: cachePath) {
                inError = false
                if seen.insert(item.path).inserted { items.append(item) }
            } else if line.hasPrefix("Warning:") {
                inError = false
                if !warnings.contains(line) { warnings.append(line) }
            } else if line.hasPrefix("Error:") {
                inError = true
                errors.append(line)
            } else if inError {
                errors.append(line)
            }
        }
        return CleanupDryRun(items: items, summaryText: summaryText, summaryBytes: summaryText.flatMap(bytes),
                             warnings: warnings, errors: errors)
    }

    /// "2.5GB" from "==> This operation would free approximately 2.5GB of disk space."
    static func summary(_ line: String) -> String? {
        let l = line.hasPrefix("==> ") ? String(line.dropFirst(4)) : line
        for prefix in ["This operation would free approximately ", "This operation has freed approximately "] where l.hasPrefix(prefix) {
            let rest = l.dropFirst(prefix.count)
            guard let end = rest.range(of: " of disk space") else { return nil }
            return String(rest[..<end.lowerBound])
        }
        return nil
    }

    static func item(_ line: String, cachePath: String?) -> Item? {
        for prefix in ["Would remove (broken link): ", "Would remove (empty directory): "] where line.hasPrefix(prefix) {
            let path = String(line.dropFirst(prefix.count))
            return Item(path: path, sizeText: nil, bytes: nil, files: nil, kind: .other)
        }
        let prefixes = ["Would remove: ", "Removing: "]
        guard let prefix = prefixes.first(where: line.hasPrefix) else { return nil }
        var rest = String(line.dropFirst(prefix.count))
        var sizeText: String?
        var files: Int?
        // The size is in the last " (...)"; the path itself may contain parentheses.
        if rest.hasSuffix(")"), let open = rest.range(of: " (", options: .backwards) {
            let inside = rest[open.upperBound..<rest.index(before: rest.endIndex)]
            rest = String(rest[..<open.lowerBound])
            let parts = inside.components(separatedBy: ", ")
            if parts.count >= 2, parts.count <= 3, parts[parts.count - 2].hasSuffix(" files") || parts[parts.count - 2].hasSuffix(" file") {
                // "1,850 files, 16.4MB" (the number has its own comma: rejoin)
                let filePart = parts.dropLast().joined(separator: ",")
                files = Int(filePart.split(separator: " ").first.map { $0.replacingOccurrences(of: ",", with: "") } ?? "")
                sizeText = parts.last
            } else {
                sizeText = String(inside)
            }
        }
        if rest.hasSuffix("...") { rest = String(rest.dropLast(3)) } // "Removing: <path>... (size)"
        return Item(path: rest, sizeText: sizeText, bytes: sizeText.flatMap(bytes), files: files,
                    kind: kind(of: rest, cachePath: cachePath))
    }

    static func kind(of path: String, cachePath: String?) -> ItemKind {
        if path.contains("/Cellar/") { return .oldVersion }
        if let cache = cachePath, path.hasPrefix(cache.hasSuffix("/") ? cache : cache + "/") { return .download }
        if path.contains("/Library/Caches/Homebrew/") { return .download }
        if path.contains("/Library/Logs/Homebrew/") { return .log }
        return .other
    }

    /// "457.3MB" → 457_300_000. brew's units are powers of 1000.
    public static func bytes(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (u, m) in units where t.hasSuffix(u) {
            guard let v = Double(t.dropLast(u.count)) else { return nil }
            return Int64((v * m).rounded())
        }
        return nil
    }

    /// The same text brew would print for a byte count.
    public static func format(bytes: Int64) -> String {
        var size = Double(bytes)
        var unit = "B"
        for next in ["KB", "MB", "GB"] {
            if (size * 10).rounded() / 10 < 1000 { break }
            size /= 1000
            unit = next
        }
        let r = (size * 10).rounded() / 10
        return r.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(r))\(unit)" : String(format: "%.1f%@", r, unit)
    }
}

extension BrewClient {
    /// `brew cleanup -n`: read-only, so it runs off the queue. brew can
    /// exit non-zero (an untrusted tap) and still list items; the output is
    /// parsed either way and the exit code returned with it.
    public func cleanupDryRun(env: [String: String], cachePath: String?) async throws -> (CleanupDryRun, Int32) {
        let r = try await runner.run(installation.brewPath, ["cleanup", "-n"], environment: env)
        let text = r.stdoutString + "\n" + r.stderrString
        return (CleanupDryRun.parse(text, cachePath: cachePath), r.exitCode)
    }

    /// `brew --cache`.
    public func cachePath(env: [String: String]) async -> String? {
        guard let r = try? await runner.run(installation.brewPath, ["--cache"], environment: env), r.exitCode == 0 else { return nil }
        let s = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// `du -sk <path>` in bytes (KiB × 1024). nil when du fails.
    public func diskUsage(_ path: String, duPath: String = "/usr/bin/du") async -> Int64? {
        guard let r = try? await runner.run(duPath, ["-sk", path], environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]),
              let first = r.stdoutString.split(whereSeparator: \.isWhitespace).first, let kb = Int64(first) else { return nil }
        return kb * 1024
    }
}
