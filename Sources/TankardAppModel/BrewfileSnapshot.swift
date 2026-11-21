import Darwin
import Foundation

// 0.9.0 (F4, hardening): `brew bundle` never reads the user's Brewfile
// path itself. Tankard opens the file once (O_NOFOLLOW, O_NONBLOCK),
// checks on that descriptor that it is a regular file of at most 1 MB,
// reads it from the same descriptor, and hands brew a private copy (mode
// 0600, in a fresh 0700 folder under the per-user temporary folder),
// deleted when brew is done. So the file brew runs is the file Tankard
// read and showed: a swap between a check and a read (a symlink, a FIFO,
// another file moved into place) can't change it. See
// docs/architecture.md, "Brewfile reads".

/// Why a Brewfile wasn't read.
public enum BrewfileReadError: Error, Equatable, CustomStringConvertible {
    case missing
    case symlink
    case directory
    case fifo
    case device
    case notRegularFile
    case tooLarge(limit: Int)
    case notText
    case unreadable(errno: Int32)

    public var description: String {
        switch self {
        case .missing:
            return String(localized: "The Brewfile isn't there any more.")
        case .symlink:
            return String(localized: "This Brewfile is a symbolic link. Choose the file it points to instead.")
        case .directory:
            return String(localized: "This is a folder, not a Brewfile.")
        case .fifo:
            return String(localized: "This is a named pipe, not a Brewfile, so Tankard didn't read it.")
        case .device:
            return String(localized: "This is a device, not a Brewfile, so Tankard didn't read it.")
        case .notRegularFile:
            return String(localized: "This isn't a regular file, so Tankard didn't read it as a Brewfile.")
        case .tooLarge(let limit):
            return String(localized: "This file is larger than \(limit / 1_000_000) MB, too large for a Brewfile, so Tankard didn't read it.")
        case .notText:
            return String(localized: "This file isn't UTF-8 text, so Tankard didn't read it as a Brewfile.")
        case .unreadable(let e):
            return String(localized: "Tankard couldn't read this Brewfile: \(String(cString: strerror(e))).")
        }
    }
}

public enum BrewfileSnapshot {
    /// The largest Brewfile read (a real one is a few KB).
    public static let maxBytes = BrewfileStaticReader.maxBytes

    /// The file's bytes: one open, no symlink at the last component, only
    /// a regular file, at most `maxBytes`. A FIFO or a device is opened
    /// non-blocking and refused by fstat before anything is read.
    public static func read(_ path: String, maxBytes: Int = maxBytes) throws -> Data {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else {
            let e = errno
            switch e {
            case ELOOP: throw BrewfileReadError.symlink
            case ENOENT, ENOTDIR: throw BrewfileReadError.missing
            default: throw BrewfileReadError.unreadable(errno: e)
            }
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw BrewfileReadError.unreadable(errno: errno) }
        switch st.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: throw BrewfileReadError.directory
        case S_IFIFO: throw BrewfileReadError.fifo
        case S_IFCHR, S_IFBLK: throw BrewfileReadError.device
        case S_IFLNK: throw BrewfileReadError.symlink
        default: throw BrewfileReadError.notRegularFile
        }
        guard st.st_size <= off_t(maxBytes) else { throw BrewfileReadError.tooLarge(limit: maxBytes) }
        // The same descriptor, and the cap again: the file may grow after fstat.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw BrewfileReadError.unreadable(errno: errno)
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.count > maxBytes { throw BrewfileReadError.tooLarge(limit: maxBytes) }
        }
        return data
    }

    /// The bytes as text (what the preview shows and its digest covers).
    public static func text(_ data: Data) throws -> String {
        guard let s = String(data: data, encoding: .utf8) else { throw BrewfileReadError.notText }
        return s
    }
}

/// A private copy of a Brewfile for brew to read: `<tmp>/tankard-brewfile.XXXXXX/Brewfile`,
/// the folder 0700 (mkdtemp), the file 0600, written with O_EXCL.
public struct BrewfilePrivateCopy: Sendable {
    public let directory: String
    public let path: String

    /// `parent`: where the private folder goes (the per-user temporary
    /// folder: inside the container when sandboxed).
    public static func make(_ data: Data, parent: URL = FileManager.default.temporaryDirectory) throws -> BrewfilePrivateCopy {
        var template = Array(parent.appendingPathComponent("tankard-brewfile.XXXXXX").path.utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
        guard made != nil else { throw BrewfileReadError.unreadable(errno: errno) }
        let directory = String(cString: template)
        let copy = BrewfilePrivateCopy(directory: directory, path: directory + "/Brewfile")
        do {
            try copy.write(data)
        } catch {
            copy.remove()
            throw error
        }
        return copy
    }

    private func write(_ data: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BrewfileReadError.unreadable(errno: errno) }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw BrewfileReadError.unreadable(errno: errno) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw BrewfileReadError.unreadable(errno: errno)
                }
                // write(2) may return 0 without an error; don't spin on it.
                if n == 0 { throw BrewfileReadError.unreadable(errno: EIO) }
                offset += n
            }
        }
    }

    /// Deletes the copy and its folder (and anything brew left beside it).
    public func remove() {
        try? FileManager.default.removeItem(atPath: directory)
    }
}
