import Foundation

/// Tankard's version: `tankard --version`, the API User-Agent, the update
/// check. Keep `source` in step with the default in Scripts/bundle-app.sh
/// (release.sh refuses a TANKARD_VERSION that differs from it).
public enum TankardVersion {
    /// This tree's version.
    public static let source = "0.8.4"

    /// 0.8.4: inside Tankard.app, the bundle's CFBundleShortVersionString,
    /// which bundle-app.sh writes from TANKARD_VERSION; elsewhere (the CLI,
    /// tests) `source`. So a build made with another TANKARD_VERSION (the
    /// self-update e2e's 0.8.4-e2e.0) checks for updates as the version its
    /// Info.plist says, not as `source`. A release's plist is the tag's
    /// version, which release.sh requires to equal `source`: shipped builds
    /// get the same string either way.
    public static let string: String = resolve(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        shortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)

    /// 0.8.4: the User-Agent of every request Tankard makes itself
    /// (formulae.brew.sh, api.github.com, the Intelbrew build-times file):
    /// the same version as the update check and About.
    public static var userAgent: String { "Tankard/\(string)" }

    /// The rule behind `string`: Tankard's own bundle (net.mindtricks.tankard,
    /// or a copy re-signed as net.mindtricks.tankard.<suffix> by the e2e
    /// scripts) with a non-empty short version uses it.
    public static func resolve(bundleIdentifier: String?, shortVersion: String?) -> String {
        guard let id = bundleIdentifier, id == "net.mindtricks.tankard" || id.hasPrefix("net.mindtricks.tankard."),
              let v = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty
        else { return source }
        return v
    }
}
