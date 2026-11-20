import Darwin
import Foundation
import Security

/// 0.8.8 (security review #1): the `TANKARD_*` launch switches (demo,
/// snapshot, e2e scripts, TANKARD_BREW, TANKARD_UPDATE_FEED, the askpass
/// helper's snapshot and describe hooks) exist for tests and screenshots.
/// They are read only by a build without a Team ID: `swift build` and
/// Scripts/bundle-app.sh (ad-hoc signed), which every e2e, snapshot and
/// layout script runs. A release is Developer ID signed (Scripts/release.sh),
/// so `open --env TANKARD_BREW=…` from another process does nothing there.
///
/// A build with a Team ID (or one whose signature can't be read) never
/// honours them: there is no override. (An administrator marker file was
/// considered for the signed release-candidate e2e and dropped in review:
/// it would have unlocked TANKARD_BREW in a signed build.)
public enum TestHooks {
    public static let prefix = "TANKARD_"

    /// How the running code is signed.
    public enum Signing: Equatable, Sendable {
        case unsigned
        case adhoc
        case team(String)
        /// The signature couldn't be read: treated as a release.
        case unknown
    }

    public static func allowed(signing: Signing) -> Bool {
        switch signing {
        case .unsigned, .adhoc: return true
        case .team, .unknown: return false
        }
    }

    /// `env` without any `TANKARD_*` variable when the hooks are off.
    public static func filtered(_ env: [String: String], allowed: Bool) -> [String: String] {
        allowed ? env : env.filter { !$0.key.hasPrefix(prefix) }
    }

    /// The running code's own signature. Off the main thread only
    /// (OffMain): Security evaluates the certificate trust here.
    public static func ownSigning() -> Signing {
        OffMain.assertOffMain("TestHooks.ownSigning")
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unknown }
        var info: CFDictionary?
        let rc = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        if rc == errSecCSUnsigned { return .unsigned }
        guard rc == errSecSuccess, let dict = info as? [String: Any] else { return .unknown }
        return signing(info: dict)
    }

    /// From SecCodeCopySigningInformation's dictionary.
    public static func signing(info: [String: Any]) -> Signing {
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty { return .team(team) }
        if info[kSecCodeInfoIdentifier as String] == nil { return .unsigned }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return .adhoc }
        return .unknown
    }

    /// Decided once per process. 0.8.10: on a worker thread (OffMain), the
    /// caller waits for it.
    public static let liveAllowed: Bool = OffMain.run { allowed(signing: ownSigning()) }

    /// Removes every `TANKARD_*` variable from this process's environment
    /// when the hooks are off. Called first thing at launch, so no later
    /// read (ProcessInfo, a relaunch, a child) sees them.
    public static func sanitizeProcessEnvironment(allowed: Bool = liveAllowed) {
        guard !allowed else { return }
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix(prefix) { unsetenv(key) }
    }
}
