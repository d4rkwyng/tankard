import Foundation
import Observation
import TankardCore

/// 0.8.5: Electron apps on a Mac Pro (Late 2013).
///
/// The Mac Pro 6,1's AMD FirePro D300/D500/D700 (GCN 1.0) has no Apple
/// graphics driver after macOS 12 Monterey, the last macOS that supports
/// the model. Newer macOS runs on it only through OpenCore Legacy Patcher,
/// whose patched Metal driver Chromium draws badly on: blank, black or
/// flickering windows, garbled text. Every Electron app ships Chromium, so
/// Tankard marks installed casks whose app is an Electron app, with a short
/// explanation and the app's Chromium version. Information only: Tankard
/// changes no app.
///
/// Which Macs: hw.model "MacPro6,1" on macOS 13 or later. That OS version
/// can only be there through a patcher, so no patcher marker is required
/// (OpenCore Legacy Patcher does leave real ones: the NVRAM variable
/// `4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:OCLP-Version` and
/// `/Library/Application Support/Dortania`; but requiring them could only
/// miss an affected Mac, and on Monterey the Mac's own driver works).
public enum ElectronGPU {
    /// Models with the GCN 1.0 FirePro cards.
    public static let affectedModels: Set<String> = ["MacPro6,1"]
    /// The first macOS without a driver for them.
    public static let firstAffectedMacOS = 13

    public static func isAffected(model: String?, macOSMajor: Int) -> Bool {
        guard let model else { return false }
        return affectedModels.contains(model) && macOSMajor >= firstAffectedMacOS
    }

    /// What marks an Electron app (as the owner's script checks).
    public static let frameworkPath = "Contents/Frameworks/Electron Framework.framework"

    /// The framework's binary, as the script looks for it (the top-level
    /// link first, then the versioned file).
    public static func frameworkBinaries(app: String) -> [String] {
        let fw = (app as NSString).appendingPathComponent(frameworkPath)
        return [(fw as NSString).appendingPathComponent("Electron Framework"),
                (fw as NSString).appendingPathComponent("Versions/A/Electron Framework")]
    }

    /// The Chromium version in an Electron Framework binary: the first
    /// "Chrome/NN." or "Chrome/NNN." (the script's `strings | grep -o
    /// 'Chrome/[0-9]\{2,3\}\.'`), with the rest of its dotted number
    /// ("130.0.6723.191"). nil when there is none.
    public static func chromiumVersion(in data: Data) -> String? {
        let needle = Array("Chrome/".utf8)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.baseAddress, raw.count >= needle.count else { return nil }
            var offset = 0
            while offset < raw.count {
                guard let hit = needle.withUnsafeBytes({ n in
                    memmem(base + offset, raw.count - offset, n.baseAddress, n.count)
                }) else { return nil }
                let start = base.distance(to: UnsafeRawPointer(hit)) + needle.count
                if let v = version(raw, from: start) { return v }
                offset = start
            }
            return nil
        }
    }

    /// A version at `from`: 2 or 3 digits, a dot, then digits and dots.
    private static func version(_ raw: UnsafeRawBufferPointer, from: Int) -> String? {
        func isDigit(_ i: Int) -> Bool { i < raw.count && raw[i] >= 0x30 && raw[i] <= 0x39 }
        var i = from
        while isDigit(i) { i += 1 }
        let major = i - from
        guard (2...3).contains(major), i < raw.count, raw[i] == 0x2E else { return nil }
        var end = i
        while end < raw.count && (isDigit(end) || raw[end] == 0x2E) && end - from < 24 { end += 1 }
        while end > i && raw[end - 1] == 0x2E { end -= 1 }
        return String(decoding: UnsafeRawBufferPointer(rebasing: raw[from..<end]), as: UTF8.self)
    }

    /// The major version ("130.0.6723.191" → 130).
    public static func major(_ version: String) -> Int? {
        Int(version.prefix { $0 != "." })
    }
}

/// How the store looks at this Mac and its apps. Every closure runs off the
/// main thread. Tests and the demo inject their own.
public struct ElectronGPUProbe: Sendable {
    /// hw.model ("MacPro6,1"); nil when unknown.
    public var model: @Sendable () -> String?
    public var macOSMajor: @Sendable () -> Int
    /// Whether the app at this path is an Electron app.
    public var isElectronApp: @Sendable (String) -> Bool
    /// The Electron Framework binary's modification date (the cache key with
    /// the path); nil when it can't be read.
    public var frameworkDate: @Sendable (String) -> Date?
    /// The app's Chromium version (reads the framework binary).
    public var chromiumVersion: @Sendable (String) -> String?

    public init(model: @escaping @Sendable () -> String?, macOSMajor: @escaping @Sendable () -> Int,
                isElectronApp: @escaping @Sendable (String) -> Bool,
                frameworkDate: @escaping @Sendable (String) -> Date?,
                chromiumVersion: @escaping @Sendable (String) -> String?) {
        self.model = model
        self.macOSMajor = macOSMajor
        self.isElectronApp = isElectronApp
        self.frameworkDate = frameworkDate
        self.chromiumVersion = chromiumVersion
    }

    /// Never affected and reads nothing (tests, demo mode without the hook).
    public static let disabled = ElectronGPUProbe(model: { nil }, macOSMajor: { 0 }, isElectronApp: { _ in false },
                                                  frameworkDate: { _ in nil }, chromiumVersion: { _ in nil })

    /// This Mac and its apps.
    public static let live = ElectronGPUProbe(
        model: { sysctlString("hw.model") },
        macOSMajor: { ProcessInfo.processInfo.operatingSystemVersion.majorVersion },
        isElectronApp: { app in
            var dir: ObjCBool = false
            let fw = (app as NSString).appendingPathComponent(ElectronGPU.frameworkPath)
            return FileManager.default.fileExists(atPath: fw, isDirectory: &dir) && dir.boolValue
        },
        frameworkDate: { app in
            for bin in ElectronGPU.frameworkBinaries(app: app) {
                if let d = (try? FileManager.default.attributesOfItem(atPath: (bin as NSString).resolvingSymlinksInPath))?[.modificationDate] as? Date {
                    return d
                }
            }
            return nil
        },
        chromiumVersion: { app in
            for bin in ElectronGPU.frameworkBinaries(app: app) {
                // Mapped, not read: the binary is a few hundred MB.
                if let data = try? Data(contentsOf: URL(fileURLWithPath: bin), options: .alwaysMapped) {
                    return ElectronGPU.chromiumVersion(in: data)
                }
            }
            return nil
        })

    /// Demo (TANKARD_DEMO_ELECTRON=1): a Mac Pro 6,1 on macOS 15 whose
    /// Visual Studio Code and LM Studio are Electron apps. Reads nothing
    /// from this Mac.
    public static func demo(apps: [String: String] = ["Visual Studio Code.app": "132.0.6834.210",
                                                      "LM Studio.app": "134.0.6998.205"],
                            delay: TimeInterval = 0.6) -> ElectronGPUProbe {
        @Sendable func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        return ElectronGPUProbe(model: { "MacPro6,1" }, macOSMajor: { 15 },
                                isElectronApp: { apps[name($0)] != nil },
                                frameworkDate: { _ in Date(timeIntervalSince1970: 1_790_000_000) },
                                chromiumVersion: { path in
                                    // As long as reading a real framework takes, about.
                                    Thread.sleep(forTimeInterval: delay)
                                    return apps[name(path)]
                                })
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// 0.8.5: which installed casks are Electron apps on an affected Mac, and
/// their Chromium versions. Nothing at all happens on any other Mac: the
/// hardware check runs once, off the main thread, at the first report.
@Observable @MainActor
public final class ElectronGPUStore {
    public enum Chromium: Equatable, Sendable {
        case reading
        case version(String)
        case unknown
    }

    /// This Mac is affected (known after the first report).
    public private(set) var affected = false
    /// Package id → its Electron app's path.
    public private(set) var electronApps: [String: String] = [:]
    /// App path → its Chromium version, for the apps asked about.
    public private(set) var chromium: [String: Chromium] = [:]

    @ObservationIgnored let probe: ElectronGPUProbe
    @ObservationIgnored private var hardware: Bool?
    @ObservationIgnored private var lastKey: [String] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var versionTasks: [String: Task<Void, Never>] = [:]
    /// App path → (framework date, version): a version is read again only
    /// when the app changed.
    @ObservationIgnored private var versionCache: [String: (Date?, String?)] = [:]

    public init(probe: ElectronGPUProbe = .disabled) {
        self.probe = probe
    }

    public func isElectron(_ p: Package) -> Bool { affected && electronApps[p.id] != nil }

    /// The installed casks changed (or may have): checks which are Electron
    /// apps, off the main thread. Cheap when nothing changed.
    public func update(packages: [Package]) {
        if hardware == false { return }
        let casks = packages.filter { $0.kind == .cask }
            .compactMap { p -> (String, String)? in
                guard let app = p.appPaths?.first(where: { $0.hasSuffix(".app") }) else { return nil }
                return (p.id, app)
            }
        // The version is part of the key: an upgrade may replace the app.
        let key = packages.filter { $0.kind == .cask }.map { "\($0.id) \($0.installedVersion) \($0.appPaths ?? [])" }.sorted()
        guard key != lastKey else { return }
        lastKey = key
        scanTask?.cancel()
        let probe = probe
        let known = hardware
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (Bool, [String: String]) in
                let hw = known ?? ElectronGPU.isAffected(model: probe.model(), macOSMajor: probe.macOSMajor())
                guard hw else { return (false, [:]) }
                var found: [String: String] = [:]
                for (id, app) in casks where probe.isElectronApp(app) { found[id] = app }
                return (true, found)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.hardware = result.0
            if self.affected != result.0 { self.affected = result.0 }
            if self.electronApps != result.1 { self.electronApps = result.1 }
        }
    }

    /// Reads the app's Chromium version once (again only when the app
    /// changed), off the main thread. Call when the version is shown.
    public func loadChromium(for p: Package) {
        guard affected, let app = electronApps[p.id], versionTasks[app] == nil else { return }
        let probe = probe
        let cached = versionCache[app]
        if chromium[app] == nil { chromium[app] = .reading }
        versionTasks[app] = Task { [weak self] in
            let (date, version) = await Task.detached(priority: .utility) { () -> (Date?, String?) in
                let date = probe.frameworkDate(app)
                if let cached, cached.0 == date { return cached }
                return (date, probe.chromiumVersion(app))
            }.value
            guard let self else { return }
            self.versionTasks[app] = nil
            self.versionCache[app] = (date, version)
            let state: Chromium = version.map { .version($0) } ?? .unknown
            if self.chromium[app] != state { self.chromium[app] = state }
        }
    }

    public func chromiumState(for p: Package) -> Chromium? {
        electronApps[p.id].flatMap { chromium[$0] }
    }

    /// Tests: waits for the running checks.
    public func settle() async {
        await scanTask?.value
        for t in versionTasks.values { await t.value }
    }
}
