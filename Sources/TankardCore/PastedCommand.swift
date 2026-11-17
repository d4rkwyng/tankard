import Foundation

/// 0.8.3: a search that is really a pasted Terminal command ("brew install
/// wget", "brew install --cask firefox", "$ brew info jq"). Both search
/// fields search for the package part only. Tap-qualified names
/// ("user/tap/tool") are kept as they are.
public enum PastedCommand {
    /// The brew subcommands whose argument is a package name.
    static let verbs: Set<String> = ["install", "upgrade", "info", "reinstall", "uninstall", "home"]

    /// The query to search for: `query` without a leading shell prompt
    /// ("$ ", "% "), `brew <verb>` and its options. Anything else is
    /// returned unchanged (trimmed). "brew" on its own, or "brew install"
    /// with nothing after it, is left alone, so typing one isn't fought.
    public static func searchTerm(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if let first = words.first, first == "$" || first == "%" || first == "#" { words.removeFirst() }
        guard words.count >= 3, words[0].lowercased() == "brew" || words[0].hasSuffix("/brew"),
              verbs.contains(words[1].lowercased()) else { return trimmed }
        let rest = words.dropFirst(2).filter { !$0.hasPrefix("-") }
        return rest.isEmpty ? trimmed : rest.joined(separator: " ")
    }
}
