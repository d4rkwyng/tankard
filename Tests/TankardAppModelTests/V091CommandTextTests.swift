import Testing
@testable import TankardAppModel

struct V091CommandTextTests {
    @Test func breakableAddsInvisibleOnlyAfterSlashes() {
        let command = "brew fetch --formula homebrew/core/libffi"
        let display = CommandText.breakable(command)
        #expect(display == "brew fetch --formula homebrew/\u{200B}core/\u{200B}libffi")
        #expect(display.replacingOccurrences(of: "\u{200B}", with: "") == command)
        #expect(!command.contains("\u{200B}")) // CommandBox uses this unchanged for Copy and help.
    }

    @Test func wrappedBreaksAtSpacesAndSeparatorsWithoutSplittingComponents() {
        let command = "brew fetch --formula homebrew/core/libffi"
        let wrapped = CommandText.wrapped(command, width: 10)
        #expect(wrapped == "brew \nfetch \n--formula \nhomebrew/\ncore/\nlibffi")
        #expect(wrapped.replacingOccurrences(of: "\n", with: "") == command)
        #expect(wrapped.components(separatedBy: "\n").allSatisfy { $0.hasSuffix(" ") || $0.hasSuffix("/") || $0 == "libffi" })
    }
}
