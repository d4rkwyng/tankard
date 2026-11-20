import Foundation

/// Where brew lives. A GUI app has no useful PATH, so brew is found by its
/// standard locations rather than `which`.
public struct BrewInstallation: Sendable, Equatable {
    /// The `brew` executable (as found, e.g. /usr/local/bin/brew).
    public var brewPath: String
    /// HOMEBREW_PREFIX: /usr/local (Intel) or /opt/homebrew (Apple silicon).
    public var prefix: String
    /// HOMEBREW_REPOSITORY, the Homebrew/brew checkout: /usr/local/Homebrew or /opt/homebrew.
    public var repository: String

    public init(brewPath: String, prefix: String, repository: String) {
        self.brewPath = brewPath
        self.prefix = prefix
        self.repository = repository
    }

    /// homebrew/core's tap checkout (exists only in tap mode, not API mode).
    public var coreTapPath: String {
        "\(repository)/Library/Taps/homebrew/homebrew-core"
    }

    /// Standard locations in preference order, this Mac's native one first:
    /// /usr/local/bin/brew on Intel (Tankard's primary target), then
    /// /opt/homebrew/bin/brew. 0.8.9 (security review F3): on Apple silicon
    /// /opt/homebrew/bin/brew comes first. /usr/local/bin there is only
    /// Rosetta Homebrew's, and is often a directory other installers write
    /// to, so a brew planted there no longer wins over the real one. To use
    /// the Rosetta brew on a Mac with both, pass --brew / TANKARD_BREW (CLI).
    public static let candidates = candidates(arm64: hardwareIsArm64())

    /// The candidates for an Apple silicon Mac (`arm64`) or an Intel one.
    public static func candidates(arm64: Bool) -> [String] {
        arm64 ? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
              : ["/usr/local/bin/brew", "/opt/homebrew/bin/brew"]
    }

    /// The hardware, not the process: Tankard running under Rosetta on Apple
    /// silicon still prefers /opt/homebrew (hw.optional.arm64 is 1 there too).
    public static func hardwareIsArm64() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }

    /// Finds brew. `override` (a path, from --brew or TANKARD_BREW) wins.
    /// 0.8.8: `standardOnly` (the GUI app): only a standard location, never
    /// another executable, is run as brew; any other override finds nothing.
    public static func locate(override: String? = nil, standardOnly: Bool = false,
                              fileManager: FileManager = .default) -> BrewInstallation? {
        if standardOnly, let override, !candidates.contains(override) { return nil }
        let paths = override.map { [$0] } ?? candidates
        for path in paths where fileManager.isExecutableFile(atPath: path) {
            return from(brewPath: path)
        }
        return nil
    }

    /// Derives prefix and repository from the brew executable the way
    /// bin/brew does: resolve symlinks; the repository is two levels above
    /// the real bin/brew, the prefix two levels above the path as given.
    public static func from(brewPath: String) -> BrewInstallation {
        let given = URL(fileURLWithPath: brewPath)
        let real = given.resolvingSymlinksInPath()
        let repository = real.deletingLastPathComponent().deletingLastPathComponent().path
        let prefix = given.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
        return BrewInstallation(brewPath: brewPath, prefix: prefix, repository: repository)
    }
}
