import Foundation

/// Text helpers for long commands shown in copyable command boxes.
public enum CommandText {
    /// Adds invisible break opportunities after path separators without
    /// changing the command copied or announced to the user.
    public static func breakable(_ command: String) -> String {
        command.replacingOccurrences(of: "/", with: "/\u{200B}")
    }

    /// Wraps at spaces or path separators, keeping each command component whole.
    public static func wrapped(_ command: String, width: Int) -> String {
        let width = max(1, width)
        var pieces: [String] = []
        var piece = ""
        for character in command {
            piece.append(character)
            if character == " " || character == "/" {
                pieces.append(piece)
                piece = ""
            }
        }
        if !piece.isEmpty { pieces.append(piece) }

        var lines: [String] = []
        var line = ""
        for piece in pieces {
            if !line.isEmpty && line.count + piece.count > width {
                lines.append(line)
                line = piece
            } else {
                line += piece
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}
