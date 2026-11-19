import Foundation

/// 0.8.7: Homebrew 7 refuses to load a formula, cask or command from a
/// third-party tap until the user trusts it. trust.rb raises
/// UntrustedTapError:
///
///     Refusing to load formula user/tap/name from untrusted tap user/tap.
///     Run `brew trust --formula user/tap/name` or `brew trust user/tap` to trust it.
///
/// (`brew info` and `brew pin` on the name print it after "Error: ".)
/// `brew info --json=v2 --installed` skips such a keg and exits 0, so the
/// status read doesn't fail (the row shows as "can't be read", see
/// UnreadableKegs); a command by full name, such as `brew upgrade
/// user/tap/name`, trusts that one package itself. What fails is reading it
/// by name. Tankard says what that means and offers `brew trust --tap`.
public struct UntrustedTapRefusal: Equatable, Sendable {
    /// "formula", "cask" or "command".
    public var type: String
    /// The package as brew named it ("user/tap/name").
    public var name: String
    /// "user/tap".
    public var tap: String

    public init(type: String, name: String, tap: String) {
        self.type = type
        self.name = name
        self.tap = tap
    }

    /// `brew trust --tap user/tap`, the command Tankard runs.
    public var trustArguments: [String] { TapCommands.trust(tap, true) }
    /// The same, as typed in Terminal.
    public var trustCommand: String { "brew " + trustArguments.joined(separator: " ") }

    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(
        pattern: #"Refusing to load (formula|cask|command) (\S+) from untrusted tap ([A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*?)\.?(?:\s|$)"#)

    /// The first refusal in brew's output; nil when there is none.
    public static func parse(_ text: String) -> UntrustedTapRefusal? {
        let ns = text as NSString
        guard let m = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return UntrustedTapRefusal(type: ns.substring(with: m.range(at: 1)), name: ns.substring(with: m.range(at: 2)),
                                   tap: ns.substring(with: m.range(at: 3)))
    }

    public static func parse<S: Sequence>(lines: S) -> UntrustedTapRefusal? where S.Element == String {
        parse(lines.joined(separator: "\n"))
    }
}
