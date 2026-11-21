import Foundation
import os
import Testing
@testable import TankardCore
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

    /// A copy that is not this app is deleted. A faithful one, including a
    /// bundle id that differs only in case, is kept.
    @Test func anUnreliableCopyIsDeleted() throws {
        let d = Dir(), fm = FileManager.default
        try FakeBundle.make(d.app, version: "1.0", build: "100")
        try Data("extra".utf8).write(to: d.app.appendingPathComponent("Contents/Extra"))

        func copying(_ body: @escaping @Sendable (String, String, Bool) throws -> Void) -> AppReplaceSafety {
            AppReplaceSafety.live(root: d.root, copy: body)
        }
        func leftBehind() -> [String] {
            (try? fm.contentsOfDirectory(atPath: d.root.path)) ?? []
        }

        let wrongVersion = copying { _, dest, _ in
            try FakeBundle.make(URL(fileURLWithPath: dest), version: "9.0", build: "100")
            try Data("extra".utf8).write(to: URL(fileURLWithPath: dest).appendingPathComponent("Contents/Extra"))
        }
        #expect(throws: AppReplaceSafety.BackupError.self) { try wrongVersion.backup(d.app.path) }
        #expect(leftBehind().isEmpty)
        #expect(fm.fileExists(atPath: d.app.path))

        let wrongBuild = copying { _, dest, _ in
            try FakeBundle.make(URL(fileURLWithPath: dest), version: "1.0", build: "999")
            try Data("extra".utf8).write(to: URL(fileURLWithPath: dest).appendingPathComponent("Contents/Extra"))
        }
        #expect(throws: AppReplaceSafety.BackupError.self) { try wrongBuild.backup(d.app.path) }

        let wrongID = copying { _, dest, _ in
            try FakeBundle.make(URL(fileURLWithPath: dest), id: "com.other.Thing", version: "1.0", build: "100")
            try Data("extra".utf8).write(to: URL(fileURLWithPath: dest).appendingPathComponent("Contents/Extra"))
        }
        #expect(throws: AppReplaceSafety.BackupError.self) { try wrongID.backup(d.app.path) }

        let notWhole = copying { _, dest, _ in
            try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        }
        #expect(throws: AppReplaceSafety.BackupError.self) { try notWhole.backup(d.app.path) }

        let missingEntry = copying { src, dest, _ in
            try AppReplaceSafety.copyApp(from: src, to: dest, clone: false)
            try FileManager.default.removeItem(atPath: (dest as NSString).appendingPathComponent("Contents/Extra"))
        }
        #expect(throws: AppReplaceSafety.BackupError.self) { try missingEntry.backup(d.app.path) }
        #expect(leftBehind().isEmpty)

        // The same id, different case, and the same Contents names: kept.
        let sameID = copying { _, dest, _ in
            try FakeBundle.make(URL(fileURLWithPath: dest), id: "COM.foo.foo", version: "1.0", build: "100")
            try Data("extra".utf8).write(to: URL(fileURLWithPath: dest).appendingPathComponent("Contents/Extra"))
        }
        let copy = try sameID.backup(d.app.path)
        #expect(fm.fileExists(atPath: copy))
        #expect(AppReplaceSafety.isReliableCopy(copy, of: d.app.path))
        let parent = (copy as NSString).deletingLastPathComponent
        #expect(leftBehind() == [(parent as NSString).lastPathComponent])
    }

    /// The notice is the reliable-copy sentence, and brew does not start.
    @Test func anUnreliableCopyDoesNotReplace() async throws {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appReplaceSafety = AppReplaceSafety(
            backup: { _ in
                calls.withLock { $0.append("backup") }
                throw AppReplaceSafety.BackupError.unreliable
            },
            finish: { _, _, _, _ in
                calls.withLock { $0.append("finish") }
                return .discarded
            },
            readApp: { _ in
                calls.withLock { $0.append("read") }
                return .init(bundleID: "org.audacityteam.audacity4", shortVersion: "4.0.1", bundleVersion: "4.0.1")
            })
        let store = AppStore(deps: deps)
        store.settings.appManagementExplained = true
        await store.start()
        store.openAdopt()
        #expect(await waitUntil { store.adopt.phase == .ready })
        let row = try #require(store.adopt.rows(.needsUpdate).first { $0.app.displayName == "Audacity" })
        let plan = try #require(store.adopt.replacePlan(row))
        store.closeToolSheet()
        #expect(await !store.startReplace(plan))
        #expect(store.upgrade == nil)
        #expect(store.busyNotice == "Tankard couldn't make a reliable safety copy of Audacity, so it didn't replace it.")
        #expect(calls.withLock { $0 } == ["read", "backup"])
    }

    /// A cask name with a space and a semicolon is quoted for the shell.
    /// Tankard does not run the uninstall.
    @Test func stopNowRecoveryQuotesAHostileCaskName() async throws {
        let hostile = "bad name; echo hi"
        let info = AppReplaceSafety.BundleInfo(bundleID: "com.example.weird", shortVersion: "1.0", bundleVersion: "1")
        let plan = ReplaceAppPlan(token: hostile, qualifiedName: hostile, appName: "Weird",
                                  appPath: "/Applications/Weird.app", bundleID: "com.example.weird",
                                  installedVersion: "1.0", caskVersion: "2.0", bundleVersion: "1")
        var deps = Demo.dependencies(.arm64, pace: 0)
        let runner = HangInstall(deps.streamRunner)
        deps.streamRunner = runner
        deps.appReplaceSafety = AppReplaceSafety(
            backup: { _ in "/tmp/b/Weird.app" },
            finish: { _, _, ok, _ in
                #expect(!ok)
                return .restored
            },
            readApp: { _ in info })
        let store = AppStore(deps: deps)
        store.settings.appManagementExplained = true
        await store.start()
        #expect(await store.startReplace(plan))
        #expect(await waitUntil { store.upgrade?.current != nil })
        store.upgrade?.stopNow()
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        let lines = store.upgrade?.log.lines.joined(separator: "\n") ?? ""
        let recovery = "Copy Weird aside first, then run `brew uninstall --cask --force 'bad name; echo hi'`, then put the app back."
        #expect(lines.contains(recovery))
        #expect(!lines.contains("brew uninstall --cask --force bad name;"))
        #expect(!runner.args.withLock { $0 }.contains { $0.contains("uninstall") })
    }

    /// A verifying signature (or both unsigned) is the warning path. Anything
    /// else keeps the copy, leaves the new tree in place, and stays a failure.
    @Test func aBadSignatureIsARealFailure() throws {
        let d = Dir(), fm = FileManager.default
        let appPath = d.app.path
        func finish(_ signing: @escaping @Sendable (String) -> AppReplaceSafety.CodeSignature) throws -> (AppReplaceSafety.Outcome, String) {
            try FakeBundle.make(d.app, version: "1.0")
            let live = AppReplaceSafety.live(root: d.root, signature: signing)
            let copy = try live.backup(d.app.path)
            try FakeBundle.make(d.app, version: "2.0")
            return (live.finish(d.app.path, copy, false, "2.0"), copy)
        }
        func stayed(_ outcome: AppReplaceSafety.Outcome, _ copy: String) {
            #expect(fm.fileExists(atPath: copy))
            #expect(FakeBundle.version(URL(fileURLWithPath: copy)) == "1.0")
            #expect(FakeBundle.version(d.app) == "2.0")
            #expect(!fm.fileExists(atPath: (copy as NSString).deletingLastPathComponent + "/.origin"))
        }

        let (valid, validCopy) = try finish { _ in .valid }
        #expect(valid == .replacedDespiteError(backup: validCopy))
        stayed(valid, validCopy)

        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let (onlyInstalled, onlyCopy) = try finish { path in
            seen.withLock { $0.append(path) }
            return .valid
        }
        #expect(onlyInstalled == .replacedDespiteError(backup: onlyCopy))
        #expect(seen.withLock { $0 } == [appPath])

        let (invalid, invalidCopy) = try finish { _ in .invalid }
        #expect(invalid == .incomplete(backup: invalidCopy))
        stayed(invalid, invalidCopy)

        let (stripped, strippedCopy) = try finish { path in path == appPath ? .unsigned : .valid }
        #expect(stripped == .incomplete(backup: strippedCopy))
        stayed(stripped, strippedCopy)

        let (unreadableBackup, unreadableCopy) = try finish { path in path == appPath ? .unsigned : .invalid }
        #expect(unreadableBackup == .incomplete(backup: unreadableCopy))

        let (bothUnsigned, bothCopy) = try finish { _ in .unsigned }
        #expect(bothUnsigned == .replacedDespiteError(backup: bothCopy))
        stayed(bothUnsigned, bothCopy)
    }

    /// The sheet keeps brew's explanation and the retry advice, and names the copy.
    @Test func aBadSignatureKeepsTheFailureAndTheCopy() async throws {
        let info = AppReplaceSafety.BundleInfo(bundleID: "org.audacityteam.audacity4", shortVersion: "4.0.1", bundleVersion: "4.0.1")
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.streamRunner = LockOnce(deps.streamRunner)
        deps.lockWait = BrewLockWait(interval: .milliseconds(20), limit: .milliseconds(300), maxAttempts: 5, holders: { _ in
            ["99 brew install"]
        })
        deps.appReplaceSafety = AppReplaceSafety(
            backup: { p in "/tmp/b/\((p as NSString).lastPathComponent)" },
            finish: { _, backup, ok, _ in
                #expect(!ok)
                return .incomplete(backup: backup)
            },
            readApp: { _ in info })
        let store = AppStore(deps: deps)
        store.settings.appManagementExplained = true
        await store.start()
        store.openAdopt()
        #expect(await waitUntil { store.adopt.phase == .ready })
        let row = try #require(store.adopt.rows(.needsUpdate).first { $0.app.displayName == "Audacity" })
        let plan = try #require(store.adopt.replacePlan(row))
        store.closeToolSheet()
        #expect(await store.startReplace(plan))
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        let session = try #require(store.upgrade)
        let item = try #require(session.items.first)
        #expect(item.state != .done)
        #expect(session.failedItems.map(\.id) == [item.id])
        #expect(session.replacedDespiteError.isEmpty)
        #expect(session.failureKindByItem[item.id] == .locked)
        #expect(session.nextStep == "Another Homebrew command kept brew's lock. Retry once it has finished.")
        #expect(session.title == "Replace finished with problems")
        let lines = session.log.lines.joined(separator: "\n")
        #expect(lines.contains("Another Homebrew command is running. brew allows one command at a time."))
        #expect(lines.contains("Homebrew reported an error and Audacity may be incomplete. Tankard kept a copy of the old version at /tmp/b/Audacity 4.app."))
        #expect(!lines.contains("was updated to"))
    }

    /// brew exits 1 with its lock message, so the failure kind is `.locked`.
    final class LockOnce: StreamingCommandRunning, @unchecked Sendable {
        let inner: StreamingCommandRunning
        init(_ inner: StreamingCommandRunning) { self.inner = inner }
        func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                    output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
            if arguments.contains("--force") {
                output(Data("Error: A `brew install --cask audacity` process has already locked /opt/homebrew/Caskroom/audacity.\n".utf8))
                return 1
            }
            return try await inner.stream(executable, arguments, environment: environment, output: output)
        }
    }

    /// Hangs `brew install --cask --force` until Stop Now cancels it.
    final class HangInstall: StreamingCommandRunning, @unchecked Sendable {
        let inner: StreamingCommandRunning
        let args = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        init(_ inner: StreamingCommandRunning) { self.inner = inner }
        func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                    output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
            args.withLock { $0.append(arguments) }
            if arguments.contains("--force") {
                try await sleepUntilCancelled()
                return 0
            }
            return try await inner.stream(executable, arguments, environment: environment, output: output)
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
