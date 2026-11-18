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

// 0.8.4: compact. The secure field (sudo's prompt as its placeholder, and
// as a label only when it isn't the usual "Password:"), then a collapsed
// "Details" disclosure with the brew command in small monospaced text.
let width: CGFloat = 260
let field = NSSecureTextField(frame: .zero)
field.placeholderString = AskpassText.promptLabel(request.prompt).trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
field.translatesAutoresizingMaskIntoConstraints = false
field.widthAnchor.constraint(equalToConstant: width).isActive = true
var rows: [NSView] = []
if request.prompt != "Password:" {
    let label = NSTextField(labelWithString: request.prompt)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    rows.append(label)
}
rows.append(field)

/// Shows or hides the command, then lets the alert fit its new height.
@MainActor final class DetailsToggle: NSObject {
    let disclosure: NSButton
    let command: NSTextField
    let stack: NSStackView
    init(disclosure: NSButton, command: NSTextField, stack: NSStackView) {
        self.disclosure = disclosure
        self.command = command
        self.stack = stack
    }
    /// From the triangle (its state already flipped) or the "Details" word.
    @objc func toggle(_ sender: NSButton) {
        if sender !== disclosure { disclosure.state = disclosure.state == .on ? .off : .on }
        command.isHidden = disclosure.state != .on
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(stack.fittingSize)
        alert.layout()
    }
}
var detailsToggle: DetailsToggle?
let stack = NSStackView()
if let commandText = AskpassText.command(request) {
    let disclosure = NSButton(title: "", target: nil, action: nil)
    disclosure.bezelStyle = .disclosure
    disclosure.setButtonType(.pushOnPushOff)
    disclosure.state = .off
    let word = NSButton(title: AskpassText.details, target: nil, action: nil)
    word.isBordered = false
    word.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    word.contentTintColor = .secondaryLabelColor
    let header = NSStackView(views: [disclosure, word])
    header.orientation = .horizontal
    header.spacing = 2
    let command = NSTextField(wrappingLabelWithString: commandText)
    command.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
    command.textColor = .secondaryLabelColor
    command.isSelectable = true
    command.preferredMaxLayoutWidth = width
    command.translatesAutoresizingMaskIntoConstraints = false
    command.widthAnchor.constraint(equalToConstant: width).isActive = true
    command.isHidden = true
    let toggle = DetailsToggle(disclosure: disclosure, command: command, stack: stack)
    for b in [disclosure, word] {
        b.target = toggle
        b.action = #selector(DetailsToggle.toggle(_:))
        b.refusesFirstResponder = true
    }
    detailsToggle = toggle
    rows += [header, command]
}
for v in rows { stack.addArrangedSubview(v) }
stack.orientation = .vertical
stack.alignment = .leading
stack.spacing = 6
stack.layoutSubtreeIfNeeded()
stack.frame = NSRect(origin: .zero, size: NSSize(width: width, height: stack.fittingSize.height))
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
    // the field. TANKARD_ASKPASS_DETAILS=1 opens Details first, through the
    // same toggle a click uses.
    if env[Askpass.detailsKey] == "1", let detailsToggle {
        let open = Timer(timeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated { detailsToggle.disclosure.performClick(nil) }
        }
        RunLoop.main.add(open, forMode: .modalPanel)
    }
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

// Come to the front. The helper is a background child of sudo (brew's
// child, Tankard's grandchild), and macOS 14+ activation is cooperative:
// a process can't take focus; the active app has to yield it. Tankard does
// that (`NSApp.yieldActivation(to:)`, AskpassFocus in the app) as soon as
// it sees this helper; here the helper asks with the cooperative
// `NSApp.activate()`. Measured on macOS 27 without a yield: the window is
// visible and the secure field editing, but the app is not active and the
// window not key. Fallback when focus never comes: the modal-panel level
// and `orderFrontRegardless()` keep the window in front of other apps'
// normal windows, and a click on it gives it focus.
@MainActor func bringToFront() {
    NSApplication.shared.activate()
    alert.window.level = .modalPanel
    alert.window.makeKeyAndOrderFront(nil)
    alert.window.orderFrontRegardless()
    alert.window.makeFirstResponder(field)
}
// Once right after runModal shows the window, and again a little later
// (Tankard's yield can arrive after the first request).
for delay in [0.05, 0.6, 1.5] {
    let front = Timer(timeInterval: delay, repeats: false) { _ in
        MainActor.assumeIsolated { bringToFront() }
    }
    RunLoop.main.add(front, forMode: .modalPanel)
}

app.finishLaunching()
app.activate()
let response = alert.runModal()
watchdog.invalidate()
guard snapshotPath == nil, response == .alertFirstButtonReturn else { exit(1) }
let ok = sendPassword(field.stringValue)
field.stringValue = ""
exit(ok ? 0 : 1)
