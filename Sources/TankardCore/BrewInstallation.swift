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

    /// Standard locations in preference order: /usr/local/bin/brew first
    /// (Intel, Tankard's primary target), then /opt/homebrew/bin/brew. On an
    /// Apple silicon Mac with both, pass --brew / TANKARD_BREW to pick.
    public static let candidates = ["/usr/local/bin/brew", "/opt/homebrew/bin/brew"]

    /// Finds brew. `override` (a path, from --brew or TANKARD_BREW) wins.
    public static func locate(override: String? = nil, fileManager: FileManager = .default) -> BrewInstallation? {
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
