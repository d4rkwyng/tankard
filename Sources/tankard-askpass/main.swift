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

/// How long the calling sudo has been running, from the kernel; nil when
/// the parent isn't sudo (a shell, the snapshot hook), so the retry
/// wording only ever follows a real sudo retry.
func parentAge(_ pid: pid_t) -> TimeInterval? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    guard name == "sudo" else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    let started = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    return Date().timeIntervalSince1970 - started
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
