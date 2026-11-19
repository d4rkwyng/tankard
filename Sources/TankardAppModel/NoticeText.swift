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
        let parts = text.split(separator: "`", omittingEmptySubsequences: false)
        // An odd number of backticks: the last one is shown as typed.
        let paired = parts.count % 2 == 1 ? parts.count : parts.count - 1
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
}
