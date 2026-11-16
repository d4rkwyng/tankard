import Foundation
@testable import TankardCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }

    static func info(_ name: String) throws -> BrewInfoJSON {
        try JSONDecoder().decode(BrewInfoJSON.self, from: data(name))
    }

    static func outdated(_ name: String) throws -> BrewOutdatedJSON {
        try JSONDecoder().decode(BrewOutdatedJSON.self, from: data(name))
    }
}

extension BottlePlatform {
    /// The Intel test VM: macOS 14, /usr/local.
    static let intelSonoma = BottlePlatform(arch: .x86_64, macOSVersion: "14", cellar: "/usr/local/Cellar")
    /// The arm64 mini the arm64 fixture came from: macOS 27, /opt/homebrew.
    static let armGoldenGate = BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar")
}

extension Array where Element == Package {
    subscript(name: String) -> Package? { first { $0.name == name } }
}

/// Answers brew and git calls from canned output and records what was run.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call { var executable: String; var arguments: [String]; var environment: [String: String] }

    private let lock = NSLock()
    private var _calls: [Call] = []
    let respond: @Sendable (String, [String]) -> ProcessResult

    init(respond: @escaping @Sendable (String, [String]) -> ProcessResult) {
        self.respond = respond
    }

    var calls: [Call] { lock.withLock { _calls } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        lock.withLock { _calls.append(Call(executable: executable, arguments: arguments, environment: environment)) }
        return respond(executable, arguments)
    }
}

func ok(_ s: String) -> ProcessResult { ProcessResult(exitCode: 0, stdout: Data(s.utf8), stderr: Data()) }
func ok(_ d: Data) -> ProcessResult { ProcessResult(exitCode: 0, stdout: d, stderr: Data()) }
let failed = ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("fatal".utf8))
