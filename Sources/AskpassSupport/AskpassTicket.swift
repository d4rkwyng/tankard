import Darwin
import Foundation

/// 0.8.8 (security review #3): which brew run may use the password dialog.
///
/// Before, the helper accepted any `sudo -A` that descended from Tankard, so
/// code running under a formula-only step, or under an unattended
/// auto-update (where Tankard sets HOMEBREW_NO_SUDO, which a child can
/// unset), could set SUDO_ASKPASS itself and get Tankard's genuine dialog.
///
/// Now, when Tankard starts a brew step that may need sudo (its environment
/// has SUDO_ASKPASS: `AdminPassword.environment`), it writes a ticket naming
/// that brew process: its pid and its start time (which tells it from a
/// later process given the same pid). The ticket is a 0600 file in a 0700
/// folder of the user's (`directory`), removed when brew exits. The helper
/// allows the dialog only when one of sudo's ancestors is exactly a
/// ticketed process; every earlier check (the parent is /usr/bin/sudo, a
/// Tankard with the helper's Team ID above it) still applies.
///
/// What it does not do: the folder is the user's, so code already running
/// as the user could write a ticket of its own. It closes the window to
/// "while Tankard runs a step that may need a password" and to that step's
/// own brew; a boundary against same-user code would need a channel such
/// code can't write, which Tankard (no XPC, no sockets) doesn't have.
public enum AskpassTicket {
    /// A process's start time (`proc_pidinfo` PROC_PIDTBSDINFO).
    public struct ProcessStart: Equatable, Hashable, Sendable {
        public var sec: UInt64
        public var usec: UInt64
        public init(sec: UInt64, usec: UInt64) {
            self.sec = sec
            self.usec = usec
        }
    }

    public struct Ticket: Equatable, Hashable, Sendable {
        public var pid: Int32
        public var start: ProcessStart
        public init(pid: Int32, start: ProcessStart) {
            self.pid = pid
            self.start = start
        }
    }

    static let magic = "tankard-askpass-ticket 1"
    /// Tickets read at most (one per running step; a few is already odd).
    public static let maxTickets = 32

    /// `~/Library/Application Support/net.mindtricks.tankard/askpass-tickets`.
    public static func directory(home: String) -> String {
        home + "/Library/Application Support/net.mindtricks.tankard/askpass-tickets"
    }

    /// The user's home from the password database, not $HOME (which a
    /// caller of the helper sets).
    public static func liveHome() -> String? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }

    public static func encode(_ t: Ticket) -> String {
        "\(magic) \(t.pid) \(t.start.sec) \(t.start.usec)\n"
    }

    public static func decode(_ s: String) -> Ticket? {
        let words = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard words.count == 5, words[0...1].joined(separator: " ") == magic,
              let pid = Int32(words[2]), pid > 1, let sec = UInt64(words[3]), let usec = UInt64(words[4]),
              usec < 1_000_000 else { return nil }
        return Ticket(pid: pid, start: ProcessStart(sec: sec, usec: usec))
    }

    /// The gate's question: is one of sudo's ancestors (pid and start
    /// time, as read now) a ticketed brew? A pid whose start time can't be
    /// read never matches.
    public static func matches(tickets: [Ticket], ancestors: [(pid: Int32, start: ProcessStart?)]) -> Bool {
        matching(tickets: tickets, ancestors: ancestors) != nil
    }

    /// The ticket that matched (the nearest ticketed ancestor), or nil.
    public static func matching(tickets: [Ticket], ancestors: [(pid: Int32, start: ProcessStart?)]) -> Ticket? {
        let set = Set(tickets)
        for a in ancestors {
            if let start = a.start, set.contains(Ticket(pid: a.pid, start: start)) { return Ticket(pid: a.pid, start: start) }
        }
        return nil
    }

    // MARK: 0.8.8 (gauntlet 3, B2): the first Cancel is final for the step

    /// brew runs sudo more than once for one step (hiddenbar's launchctl
    /// service: `sudo launchctl list`, then the removal), and each sudo ran
    /// the dialog again, so one Cancel took three. When the user cancels,
    /// the helper leaves a mark next to the step's ticket; while it is
    /// there, the helper refuses at once, without a dialog, for that same
    /// brew process (pid and start time). The app removes the mark with the
    /// ticket when brew exits, and learns from it that the dialog was
    /// cancelled (brew hides the sudo's own messages for some steps).
    static let cancelMagic = "tankard-askpass-cancelled 1"

    public static func cancelPath(_ t: Ticket, in dir: String) -> String { dir + "/\(t.pid).cancelled" }

    /// The helper, after Cancel: the mark (0600, created exclusively, never
    /// through a symlink). An existing mark is left as it is. Only in a
    /// folder `read` would accept.
    @discardableResult
    public static func markCancelled(_ t: Ticket, in dir: String) -> Bool {
        var st = stat()
        guard lstat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { return false }
        let fd = open(cancelPath(t, in: dir), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return errno == EEXIST }
        defer { close(fd) }
        let bytes = Array("\(cancelMagic) \(t.pid) \(t.start.sec) \(t.start.usec)\n".utf8)
        return bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == bytes.count
    }

    /// Whether `t`'s step was cancelled: a mark naming exactly this process,
    /// a plain 0600 file of this user's in a 0700 folder of this user's.
    public static func isCancelled(_ t: Ticket, in dir: String) -> Bool {
        var st = stat()
        guard lstat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { return false }
        let path = cancelPath(t, in: dir)
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
              st.st_mode & 0o077 == 0, st.st_size < 256 else { return false }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "\(cancelMagic) \(t.pid) \(t.start.sec) \(t.start.usec)"
    }

    public static func processStart(_ pid: Int32) -> ProcessStart? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessStart(sec: info.pbi_start_tvsec, usec: info.pbi_start_tvusec)
    }

    // MARK: the app's side

    /// For a step whose environment has SUDO_ASKPASS: writes `pid`'s ticket
    /// and returns what removes it (call it when brew exits). nil otherwise,
    /// or when the ticket couldn't be written (the helper then refuses).
    /// 0.8.8: `cancelled` is called first when the step's dialog was
    /// cancelled (the helper's mark), and the mark goes with the ticket.
    public static func issue(pid: Int32, environment: [String: String],
                             directory dir: String? = liveHome().map(directory(home:)),
                             cancelled: (@Sendable () -> Void)? = nil) -> (@Sendable () -> Void)? {
        guard let dir, let helper = environment[Askpass.askpassKey], !helper.isEmpty,
              let start = processStart(pid) else { return nil }
        let ticket = Ticket(pid: pid, start: start)
        guard let path = write(ticket, in: dir) else { return nil }
        let mark = cancelPath(ticket, in: dir)
        return {
            if isCancelled(ticket, in: dir) { cancelled?() }
            unlink(mark)
            unlink(path)
        }
    }

    /// Writes the ticket file (0600, created exclusively, never through a
    /// symlink) in `dir` (made 0700 if needed). Stale tickets of processes
    /// that have gone are removed first. Returns the file's path.
    public static func write(_ t: Ticket, in dir: String, isAlive: (Ticket) -> Bool = { processStart($0.pid) == $0.start }) -> String? {
        guard prepareDirectory(dir) else { return nil }
        for (path, old) in readAll(in: dir) where !isAlive(old) {
            unlink(cancelPath(old, in: dir))
            unlink(path)
        }
        let path = dir + "/\(t.pid)"
        unlink(path) // a stale ticket of an earlier process with this pid
        unlink(cancelPath(t, in: dir)) // and its cancel mark
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { unlink(path); return nil }
        let bytes = Array(encode(t).utf8)
        let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard n == bytes.count else { unlink(path); return nil }
        return path
    }

    /// Creates the folder (and its parents) and makes sure it is a real
    /// folder of this user's, mode 0700.
    static func prepareDirectory(_ dir: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { return false }
        if st.st_mode & 0o077 != 0 { guard chmod(dir, 0o700) == 0 else { return false } }
        return true
    }

    // MARK: the helper's side

    /// The tickets in `dir`, only when the folder is a real folder of this
    /// user's that no one else can write or read (0700), and only from
    /// plain files of this user's with no group or other access.
    public static func read(in dir: String) -> [Ticket] {
        var st = stat()
        guard lstat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(),
              st.st_mode & 0o077 == 0 else { return [] }
        return readAll(in: dir).map(\.1)
    }

    static func readAll(in dir: String) -> [(String, Ticket)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [(String, Ticket)] = []
        for name in names.filter({ !$0.hasSuffix(".cancelled") }).sorted().prefix(maxTickets) {
            let path = dir + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
                  st.st_mode & 0o077 == 0, st.st_size < 256 else { continue }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            var buf = [UInt8](repeating: 0, count: 256)
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            close(fd)
            guard n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8), let t = decode(text) else { continue }
            out.append((path, t))
        }
        return out
    }
}
