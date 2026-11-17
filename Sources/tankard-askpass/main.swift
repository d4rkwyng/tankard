// tankard-askpass: Tankard's password dialog for `sudo -A`.
//
// sudo runs this as the user (never as root) with its prompt as argv[1]
// and reads one line from stdout as the password. Exit 0 after OK, 1 after
// Cancel, a timeout, or when the calling sudo has gone away.
//
// Rules (see Sources/AskpassSupport/Askpass.swift and docs/architecture.md):
// - the password is written only to stdout (the pipe sudo reads), once,
//   followed by a newline; never to stderr, a file, a log or defaults;
// - stdout must not be a terminal (it would show the password);
// - NSSecureTextField: no echo, no copy, secure keyboard entry while it
//   has focus;
// - the context text comes from HOMEBREW_TANKARD_ASKPASS_CONTEXT, cleaned
//   to one short line; nothing from the environment is ever executed.
import AppKit
import AskpassSupport
import Darwin
import Security

/// The kernel's view of a process: its parent and start time.
func procInfo(_ pid: pid_t) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
    return info
}

/// The executable a process runs, as the kernel resolved it (symlinks
/// followed): what `exec` actually loaded, not argv[0] or p_comm.
func executablePath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return nil }
    return String(cString: buf)
}

/// How long the calling sudo has been running (the retry wording).
func parentAge(_ pid: pid_t) -> TimeInterval? {
    guard let info = procInfo(pid) else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    let started = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    return Date().timeIntervalSince1970 - started
}

/// sudo's parent, its parent, …: (pid, resolved path), at most `limit`.
func ancestors(above pid: pid_t, limit: Int) -> [(pid: pid_t, path: String?)] {
    var out: [(pid_t, String?)] = []
    var current = procInfo(pid)?.kp_eproc.e_ppid ?? 0
    while current > 1 && out.count < limit {
        out.append((current, executablePath(current)))
        current = procInfo(current)?.kp_eproc.e_ppid ?? 0
    }
    return out
}

/// The Team ID a code object is signed with; nil when there is none or
/// the signature doesn't check out.
func teamID(_ code: SecStaticCode) -> String? {
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
}

func ownTeamID() -> String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    return teamID(staticCode)
}

/// A running process's Team ID, only after its dynamic signature is valid.
func runningTeamID(_ pid: pid_t) -> String? {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
          SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    return teamID(staticCode)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("tankard-askpass: " + message + "\n").utf8))
    exit(1)
}

/// Writes the password and a newline to stdout, then overwrites the bytes.
/// (The NSSecureTextField's own string can't be wiped; this process exits
/// right after.)
func sendPassword(_ password: String) -> Bool {
    var bytes = Array(password.utf8)
    bytes.append(0x0A)
    defer { _ = bytes.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    var written = 0
    while written < bytes.count {
        let n = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress! + written, $0.count - written) }
        if n > 0 { written += n } else if n < 0 && errno == EINTR { continue } else { return false }
    }
    return true
}

let env = ProcessInfo.processInfo.environment
let ppid = getppid()

// The gate (AskpassGate): before anything is drawn or read, including the
// debug hooks. Refused: exit 1, one line on stderr, no window.
let helperPath = executablePath(getpid()) ?? ""
let parentPath = executablePath(ppid)
let above = ancestors(above: ppid, limit: AskpassGate.maxAncestors)
let helperTeam = ownTeamID()
let tankardTeam: String? = helperTeam == nil ? nil : AskpassGate.expectedTankard(helperPath: helperPath)
    .flatMap { expected in above.first { $0.path == expected } }
    .flatMap { runningTeamID($0.pid) }
let decision = AskpassGate.decide(parentPath: parentPath, ancestorPaths: above.map(\.path), helperPath: helperPath,
                                  helperTeam: helperTeam, tankardTeam: tankardTeam)
// The parent must still be the one checked (not exited and replaced).
guard decision == .allow, getppid() == ppid else {
    if case .deny(let why) = decision { fail("refused: \(why). Only Tankard's own brew commands can use this dialog.") }
    fail("refused: the calling sudo went away.")
}

let request = Askpass.request(arguments: CommandLine.arguments, environment: env, parentAge: parentAge(ppid))

if env[Askpass.describeKey] == "1" {
    // Text only, to stderr: nothing on stdout, so sudo could never take it
    // for a password.
    FileHandle.standardError.write(Data(AskpassText.describe(request).utf8))
    exit(1)
}
let snapshotPath = env[Askpass.snapshotKey].flatMap { $0.isEmpty ? nil : $0 }
if snapshotPath == nil && isatty(STDOUT_FILENO) == 1 {
    fail("this is sudo's password helper (SUDO_ASKPASS); its output is a password, so it won't write to a terminal.")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let alert = NSAlert()
alert.alertStyle = .warning
alert.messageText = request.isRetry ? AskpassText.retryTitle : AskpassText.title
alert.informativeText = AskpassText.body(request)
alert.addButton(withTitle: AskpassText.ok)
let cancelButton = alert.addButton(withTitle: AskpassText.cancel)
cancelButton.keyEquivalent = "\u{1b}"

let label = NSTextField(labelWithString: AskpassText.promptLabel(request.prompt))
label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
let field = NSSecureTextField(frame: .zero)
field.placeholderString = AskpassText.promptLabel(request.prompt).trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
let stack = NSStackView(views: [label, field])
stack.orientation = .vertical
stack.alignment = .leading
stack.spacing = 4
stack.frame = NSRect(x: 0, y: 0, width: 280, height: 44)
field.translatesAutoresizingMaskIntoConstraints = false
field.widthAnchor.constraint(equalToConstant: 280).isActive = true
alert.accessoryView = stack
alert.layout()
alert.window.initialFirstResponder = field
alert.window.level = .modalPanel

// Give up (as Cancel) after the timeout, or as soon as the sudo that asked
// is gone (brew stopped from Tankard, or killed): no orphan dialog.
let deadline = Date().addingTimeInterval(Askpass.timeout)
let watchdog = Timer(timeInterval: 1, repeats: true) { _ in
    MainActor.assumeIsolated {
        if getppid() != ppid || Date() > deadline { NSApplication.shared.abortModal() }
    }
}
RunLoop.main.add(watchdog, forMode: .common)

if let snapshotPath {
    // Debug only: picture of the empty dialog, then exit 1. Never reads
    // the field.
    let shot = Timer(timeInterval: 0.6, repeats: false) { _ in
        MainActor.assumeIsolated { snapshot(to: snapshotPath) }
    }
    RunLoop.main.add(shot, forMode: .common)
}

@MainActor func snapshot(to path: String) {
    if let view = alert.window.contentView,
       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    NSApplication.shared.abortModal()
}

app.activate(ignoringOtherApps: true)
let response = alert.runModal()
watchdog.invalidate()
guard snapshotPath == nil, response == .alertFirstButtonReturn else { exit(1) }
let ok = sendPassword(field.stringValue)
field.stringValue = ""
exit(ok ? 0 : 1)
