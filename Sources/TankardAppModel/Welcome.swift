import Foundation
import TankardCore

/// What kind of Mac this is, for the welcome screen's install options.
public struct MacHardware: Sendable, Equatable {
    /// `uname -m`: "x86_64" or "arm64" (x86_64 under Rosetta too).
    public var machine: String
    /// sysctl.proc_translated == 1: this process runs under Rosetta.
    public var translated: Bool
    /// hw.optional.arm64 == 1: the CPU is Apple silicon (also seen under Rosetta).
    public var arm64Capable: Bool

    public init(machine: String, translated: Bool, arm64Capable: Bool) {
        self.machine = machine
        self.translated = translated
        self.arm64Capable = arm64Capable
    }

    /// A real Intel Mac: x86_64, not translated, and no arm64 CPU.
    public var isIntel: Bool { machine == "x86_64" && !translated && !arm64Capable }

    public static let intel = MacHardware(machine: "x86_64", translated: false, arm64Capable: false)
    public static let appleSilicon = MacHardware(machine: "arm64", translated: false, arm64Capable: true)

    public static func current() -> MacHardware {
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return MacHardware(machine: machine, translated: sysctlInt("sysctl.proc_translated") == 1,
                           arm64Capable: sysctlInt("hw.optional.arm64") == 1)
    }

    static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// A Homebrew installer the welcome screen offers. Installers ask for the
/// admin password and wait for Return, so they run in Terminal, never in
/// the app.
public enum HomebrewInstaller: String, Sendable, CaseIterable, Identifiable {
    case intelbrew
    case homebrew

    public var id: String { rawValue }

    /// The one-liners, verbatim from d4rkwyng/intelbrew's README and
    /// Homebrew/install's README.
    public var command: String {
        switch self {
        case .intelbrew:
            return #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/d4rkwyng/intelbrew/main/install.sh)""#
        case .homebrew:
            return #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        }
    }

    public var title: String {
        switch self {
        case .intelbrew: return String(localized: "Install Intelbrew (recommended for Intel Macs)")
        case .homebrew: return String(localized: "Install standard Homebrew")
        }
    }

    public var detail: String {
        switch self {
        case .intelbrew:
            return String(localized: "Homebrew no longer builds bottles for Intel Macs, so standard Homebrew compiles most packages from source here. Intelbrew is Homebrew with prebuilt Intel bottles.")
        case .homebrew:
            return String(localized: "The official installer from brew.sh.")
        }
    }

    /// Intel Macs: Intelbrew first, standard Homebrew second. Apple silicon: Homebrew only.
    public static func options(for hw: MacHardware) -> [HomebrewInstaller] {
        hw.isIntel ? [.intelbrew, .homebrew] : [.homebrew]
    }

    /// The `.command` file opened in Terminal: the one-liner, then a note.
    public var script: String {
        """
        #!/bin/bash
        # Written by Tankard. Runs the \(self == .intelbrew ? "Intelbrew" : "Homebrew") installer in Terminal.
        \(command)
        echo
        echo "When it finishes, return to Tankard and click Check Again."

        """
    }

    /// Writes the script to `directory/tankard-install-<id>.command`,
    /// executable, and returns its URL.
    public func writeScript(in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent("tankard-install-\(rawValue).command")
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

/// Whether there is a working brew to talk to.
public enum HomebrewState: Equatable, Sendable {
    /// Not checked yet (first launch, before brew has answered).
    case checking
    case ready
    /// No brew at the standard locations (or TANKARD_BREW).
    case missing(searched: [String])
    /// brew is there but doesn't run: what it printed.
    case broken(path: String, detail: String)

    public var needsWelcome: Bool {
        switch self {
        case .missing, .broken: return true
        default: return false
        }
    }
}
