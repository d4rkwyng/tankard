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
/// A signed build honours them only when an administrator has created
/// `markerPath` (owned by root, not writable by anyone else, in root-owned
/// folders): the notarized release-candidate e2e
/// (Scripts/rc-selfupdate-signed.sh) needs that, and creating the file
/// takes an administrator password, which same-user code doesn't have.
public enum TestHooks {
    public static let prefix = "TANKARD_"
    public static let markerPath = "/Library/Application Support/Tankard/allow-test-hooks"

    /// How the running code is signed.
    public enum Signing: Equatable, Sendable {
        case unsigned
        case adhoc
        case team(String)
        /// The signature couldn't be read: treated as a release.
        case unknown
    }

    public static func allowed(signing: Signing, markerTrusted: Bool) -> Bool {
        switch signing {
        case .unsigned, .adhoc: return true
        case .team, .unknown: return markerTrusted
        }
    }

    /// `env` without any `TANKARD_*` variable when the hooks are off.
    public static func filtered(_ env: [String: String], allowed: Bool) -> [String: String] {
        allowed ? env : env.filter { !$0.key.hasPrefix(prefix) }
    }

    /// What `lstat` says about one path.
    public struct FileFacts: Equatable, Sendable {
        public enum Kind: Sendable { case file, directory, other }
        public var kind: Kind
        public var uid: uid_t
        public var mode: mode_t
        public init(kind: Kind, uid: uid_t, mode: mode_t) {
            self.kind = kind
            self.uid = uid
            self.mode = mode
        }
    }

    /// The marker counts only when it and every folder above it (up to
    /// /Library) are root's and writable by no one else, and it is a plain
    /// file (no symlink: `lstat`).
    public static func markerTrusted(path: String = markerPath, lstat facts: (String) -> FileFacts?) -> Bool {
        func rootOnly(_ f: FileFacts) -> Bool { f.uid == 0 && f.mode & 0o022 == 0 }
        guard let m = facts(path), m.kind == .file, rootOnly(m) else { return false }
        var dir = (path as NSString).deletingLastPathComponent
        while dir != "/" && !dir.isEmpty {
            guard let d = facts(dir), d.kind == .directory, rootOnly(d) else { return false }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return true
    }

    public static func liveFacts(_ path: String) -> FileFacts? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        let kind: FileFacts.Kind = type == S_IFREG ? .file : type == S_IFDIR ? .directory : .other
        return FileFacts(kind: kind, uid: st.st_uid, mode: st.st_mode & 0o7777)
    }

    /// The running code's own signature.
    public static func ownSigning() -> Signing {
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

    /// Decided once per process.
    public static let liveAllowed: Bool = allowed(signing: ownSigning(),
                                                  markerTrusted: markerTrusted(lstat: liveFacts))

    /// Removes every `TANKARD_*` variable from this process's environment
    /// when the hooks are off. Called first thing at launch, so no later
    /// read (ProcessInfo, a relaunch, a child) sees them.
    public static func sanitizeProcessEnvironment(allowed: Bool = liveAllowed) {
        guard !allowed else { return }
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix(prefix) { unsetenv(key) }
    }
}
