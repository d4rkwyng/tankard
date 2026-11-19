import Foundation

/// 0.8.8: the lines of brew's output worth quoting under an error. A failed
/// `brew update` offline ends with brew's analytics notice and its call for
/// donations (and a terminal bell before them), so the last lines quoted
/// that instead of "Fetching /opt/homebrew failed!" and "Failed to download
/// …". This drops brew's notices and blank lines and strips control
/// characters before taking the last lines.
public enum BrewOutputTail {
    /// Lines brew prints after the work, whatever happened.
    static let noticePrefixes = [
        "==> Homebrew collects anonymous analytics",
        "Read the analytics documentation",
        "https://docs.brew.sh/Analytics",
        "No analytics have been recorded yet",
        "==> Homebrew is run entirely by unpaid volunteers",
        "https://github.com/Homebrew/brew#-donations",
    ]

    /// `line` without colour codes and control characters (a bell); a tab
    /// becomes a space.
    public static func clean(_ line: String) -> String {
        let plain = line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return String(String.UnicodeScalarView(plain.unicodeScalars.compactMap { s -> Unicode.Scalar? in
            if s == "\t" { return " " }
            return CharacterSet.controlCharacters.contains(s) ? nil : s
        }))
    }

    /// The last `limit` lines of `lines` that say something: cleaned, with
    /// brew's notices and blank lines left out.
    public static func lines(_ lines: [String], limit: Int) -> [String] {
        let kept = lines.map(clean).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !noticePrefixes.contains { t.hasPrefix($0) }
        }
        return Array(kept.suffix(limit))
    }
}
