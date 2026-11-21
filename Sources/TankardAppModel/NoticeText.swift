import Foundation

/// 0.8.8 (security review #8): banner text as plain text. Before, the
/// Discover banner went through `LocalizedStringKey`, which parses Markdown,
/// so a `[link](…)` in a message (an error text, or a future caller passing
/// tap or brew output) became a live link. Now only `code` spans between
/// backticks are styled; everything else, brackets and URLs included, is
/// shown as typed, and no run carries a link.
public enum NoticeText {
    public static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        let (parts, paired) = split(text)
        for (i, part) in parts.enumerated() {
            if i >= paired {
                out += AttributedString("`" + part)
                continue
            }
            var run = AttributedString(part)
            if i % 2 == 1 { run.inlinePresentationIntent = .code }
            out += run
        }
        return out
    }

    /// The text of each paired `code` span, in order. An unpaired trailing
    /// backtick is not a span (it is shown as typed). A span that is only
    /// whitespace is not a command, so it is left out.
    public static func codeSpans(_ text: String) -> [String] {
        let (parts, paired) = split(text)
        var spans: [String] = []
        for (i, part) in parts.enumerated() {
            if i >= paired { break }
            guard i % 2 == 1 else { continue }
            let s = String(part)
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                spans.append(s)
            }
        }
        return spans
    }

    /// An odd number of backticks: the last one is shown as typed.
    private static func split(_ text: String) -> ([Substring], Int) {
        let parts = text.split(separator: "`", omittingEmptySubsequences: false)
        let paired = parts.count % 2 == 1 ? parts.count : parts.count - 1
        return (parts, paired)
    }
}
