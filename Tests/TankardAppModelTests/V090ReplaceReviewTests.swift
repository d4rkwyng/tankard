import Foundation
import Testing
@testable import TankardAppModel

// 0.9.0 review of Replace with Homebrew's Version. The plain (cross-volume)
// copy must keep a bundle's internal symlinks. `sameVolume` false forces
// that path even when both folders are on one volume.

@MainActor
struct V090ReplaceReviewTests {
    final class Dir {
        let url: URL
        let root: URL
        init() {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-replace-review-\(UUID().uuidString)")
            root = url.appendingPathComponent("backups")
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var app: URL { url.appendingPathComponent("Applications/Foo.app") }
    }

    /// A framework's `Versions/Current` and the top-level binary link stay
    /// symlinks. The two paths are on one volume; `sameVolume` false is what
    /// selects the plain copy.
    @Test func plainCopyKeepsInternalSymlinks() throws {
        let d = Dir(), fm = FileManager.default
        try FakeBundle.make(d.app, version: "1.0")
        let fw = d.app.appendingPathComponent("Contents/Frameworks/Foo.framework")
        let versionA = fw.appendingPathComponent("Versions/A")
        try fm.createDirectory(at: versionA, withIntermediateDirectories: true)
        try Data("framework".utf8).write(to: versionA.appendingPathComponent("Foo"))
        try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Foo").path, withDestinationPath: "Versions/Current/Foo")
        try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")

        // The backup folder has to exist before statfs can see its volume.
        // It is the same volume as the app; the closure is what forces the
        // plain copy.
        try fm.createDirectory(at: d.root, withIntermediateDirectories: true)
        #expect(AppReplaceSafety.sameVolume(d.app.path, d.root.path))
        let live = AppReplaceSafety.live(root: d.root, sameVolume: { _, _ in false })
        let copy = try live.backup(d.app.path)
        let copied = URL(fileURLWithPath: copy).appendingPathComponent("Contents/Frameworks/Foo.framework")

        let current = copied.appendingPathComponent("Versions/Current").path
        let binary = copied.appendingPathComponent("Foo").path
        let resources = copied.appendingPathComponent("Resources").path
        #expect(Self.isSymlink(current))
        #expect(try fm.destinationOfSymbolicLink(atPath: current) == "A")
        #expect(Self.isSymlink(binary))
        #expect(try fm.destinationOfSymbolicLink(atPath: binary) == "Versions/Current/Foo")
        #expect(Self.isSymlink(resources))
        #expect(try fm.destinationOfSymbolicLink(atPath: resources) == "Versions/Current/Resources")
        #expect(try Data(contentsOf: copied.appendingPathComponent("Foo")) == Data("framework".utf8))
        #expect(FakeBundle.version(URL(fileURLWithPath: copy)) == "1.0")

        let srcExe = d.app.appendingPathComponent("Contents/MacOS/Foo").path
        let copiedExe = (copy as NSString).appendingPathComponent("Contents/MacOS/Foo")
        if let srcID = Self.cloneID(srcExe), let copiedID = Self.cloneID(copiedExe) {
            #expect(srcID != copiedID)
        }
    }

    private static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// The clone id of a file, when the volume reports one.
    private static func cloneID(_ path: String) -> UInt64? {
        var attr = attrlist()
        attr.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attr.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attr.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        var buf = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &attr, &buf, buf.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0 else { return nil }
        return buf.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }
    }
}
