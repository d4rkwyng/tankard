import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5: Electron apps on a Mac Pro (Late 2013) running macOS 13 or later
// (OpenCore Legacy Patcher): which Macs, which casks, the Chromium version
// read lazily and cached. No real app or hardware is read here.

struct ElectronGPUDetectTests {
    @Test(arguments: [
        ("MacPro6,1", 15, true), ("MacPro6,1", 13, true),
        ("MacPro6,1", 12, false), // Monterey: Apple's own driver
        ("MacPro7,1", 15, false), ("MacBookPro11,5", 15, false), ("Mac14,3", 27, false),
    ])
    func affectedMacs(model: String, major: Int, expected: Bool) {
        #expect(ElectronGPU.isAffected(model: model, macOSMajor: major) == expected)
    }

    @Test func unknownModelIsNotAffected() {
        #expect(!ElectronGPU.isAffected(model: nil, macOSMajor: 15))
    }

    @Test func chromiumVersionAsTheScriptReadsIt() {
        // Binary noise, a format string without digits, then the real one.
        var d = Data([0, 1, 2, 0xFF])
        d.append(Data("Chrome/%s Electron/%s\0Mozilla/5.0 Chrome/130.0.6723.191 Electron/33.2.1 Safari/537.36\0".utf8))
        d.append(Data("Chrome/131.0.1.1".utf8))
        #expect(ElectronGPU.chromiumVersion(in: d) == "130.0.6723.191")
        #expect(ElectronGPU.major("130.0.6723.191") == 130)
    }

    @Test func chromiumVersionNeedsTwoOrThreeDigitsAndADot() {
        #expect(ElectronGPU.chromiumVersion(in: Data("Chrome/1.0 Chrome/1234.0 Chrome/99".utf8)) == nil)
        #expect(ElectronGPU.chromiumVersion(in: Data("xxChrome/99.".utf8)) == "99")
        #expect(ElectronGPU.chromiumVersion(in: Data()) == nil)
        #expect(ElectronGPU.chromiumVersion(in: Data("Chrome/".utf8)) == nil)
    }

    @Test func frameworkBinaryPaths() {
        #expect(ElectronGPU.frameworkBinaries(app: "/Applications/Slack.app") == [
            "/Applications/Slack.app/Contents/Frameworks/Electron Framework.framework/Electron Framework",
            "/Applications/Slack.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework",
        ])
    }
}

@MainActor
struct ElectronGPUStoreTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func add(_ k: String) { lock.withLock { counts[k, default: 0] += 1 } }
        func count(_ k: String) -> Int { lock.withLock { counts[k, default: 0] } }
    }

    final class Dates: @unchecked Sendable {
        private let lock = NSLock()
        private var _date = Date(timeIntervalSince1970: 1)
        var date: Date { get { lock.withLock { _date } } set { lock.withLock { _date = newValue } } }
    }

    static func cask(_ token: String, app: String?, version: String = "1.0") -> Package {
        var p = pkg(token, kind: .cask, outdated: false, apps: app.map { ["/Applications/\($0)"] })
        p.installedVersion = version
        return p
    }

    static func probe(model: String = "MacPro6,1", major: Int = 15, electron: Set<String> = ["Slack.app"],
                      counter: Counter = Counter(), dates: Dates = Dates()) -> ElectronGPUProbe {
        ElectronGPUProbe(model: { counter.add("model"); return model }, macOSMajor: { major },
                         isElectronApp: { counter.add("is " + $0); return electron.contains(($0 as NSString).lastPathComponent) },
                         frameworkDate: { _ in dates.date },
                         chromiumVersion: { counter.add("read " + $0); return "132.0.6834.210" })
    }

    let packages = [cask("slack", app: "Slack.app"), cask("iterm2", app: "iTerm.app"), cask("font-x", app: nil)]

    @Test func marksElectronCasksOnAnAffectedMac() async {
        let s = ElectronGPUStore(probe: Self.probe())
        s.update(packages: packages)
        await s.settle()
        #expect(s.affected)
        #expect(s.isElectron(packages[0]))
        #expect(!s.isElectron(packages[1]))
        #expect(!s.isElectron(packages[2]))
    }

    @Test func otherMacsLookAtNoApp() async {
        let counter = Counter()
        let s = ElectronGPUStore(probe: Self.probe(model: "MacPro7,1", counter: counter))
        s.update(packages: packages)
        await s.settle()
        #expect(!s.affected)
        #expect(!s.isElectron(packages[0]))
        #expect(counter.count("is /Applications/Slack.app") == 0)
        // The hardware is checked once; later reports do nothing.
        s.update(packages: packages + [Self.cask("discord", app: "Discord.app")])
        await s.settle()
        #expect(counter.count("model") == 1)
    }

    @Test func sameCasksAreNotCheckedAgain() async {
        let counter = Counter()
        let s = ElectronGPUStore(probe: Self.probe(counter: counter))
        s.update(packages: packages)
        await s.settle()
        s.update(packages: packages)
        await s.settle()
        #expect(counter.count("is /Applications/Slack.app") == 1)
        // An upgraded cask (another version) is checked again.
        s.update(packages: [Self.cask("slack", app: "Slack.app", version: "2.0")] + packages.dropFirst())
        await s.settle()
        #expect(counter.count("is /Applications/Slack.app") == 2)
    }

    @Test func chromiumIsReadWhenAskedAndCachedByDate() async {
        let counter = Counter(), dates = Dates()
        let s = ElectronGPUStore(probe: Self.probe(counter: counter, dates: dates))
        s.update(packages: packages)
        await s.settle()
        // Nothing read until the detail asks.
        #expect(counter.count("read /Applications/Slack.app") == 0)
        #expect(s.chromiumState(for: packages[0]) == nil)
        s.loadChromium(for: packages[0])
        #expect(s.chromiumState(for: packages[0]) == .reading)
        await s.settle()
        #expect(s.chromiumState(for: packages[0]) == .version("132.0.6834.210"))
        s.loadChromium(for: packages[0])
        await s.settle()
        #expect(counter.count("read /Applications/Slack.app") == 1)
        // The app changed on disk: read again.
        dates.date = Date(timeIntervalSince1970: 2)
        s.loadChromium(for: packages[0])
        await s.settle()
        #expect(counter.count("read /Applications/Slack.app") == 2)
        // Not an Electron app: nothing to read.
        s.loadChromium(for: packages[1])
        await s.settle()
        #expect(counter.count("read /Applications/iTerm.app") == 0)
    }

    @Test func unreadableVersionIsUnknown() async {
        let s = ElectronGPUStore(probe: ElectronGPUProbe(model: { "MacPro6,1" }, macOSMajor: { 14 }, isElectronApp: { _ in true },
                                                        frameworkDate: { _ in nil }, chromiumVersion: { _ in nil }))
        s.update(packages: packages)
        await s.settle()
        s.loadChromium(for: packages[0])
        await s.settle()
        #expect(s.chromiumState(for: packages[0]) == .unknown)
    }

    @Test func disabledProbeByDefaultAndInDemo() async {
        #expect(AppStore.Dependencies(makeClient: { throw BrewClientError.brewNotFound(searched: []) },
                                      streamRunner: FakeStreamRunner(log: CallLog()) { _, _ in 0 },
                                      cache: nil, logURL: nil).electronGPU.model() == nil)
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0), settings: testSettings())
        await store.start()
        await store.electron.settle()
        #expect(!store.electron.affected)
        #expect(store.electron.electronApps.isEmpty)
    }

    @Test func demoHookMarksTheDemoCasks() async {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.electronGPU = .demo(delay: 0)
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        #expect(await waitUntil { store.electron.affected })
        let marked = store.packages.filter { store.electron.isElectron($0) }.map(\.name).sorted()
        #expect(marked == ["lm-studio", "visual-studio-code"])
        guard let code = store.packages.first(where: { $0.name == "visual-studio-code" }) else {
            Issue.record("no visual-studio-code in the arm64 demo")
            return
        }
        store.electron.loadChromium(for: code)
        await store.electron.settle()
        #expect(store.electron.chromiumState(for: code) == .version("132.0.6834.210"))
    }

    @Test func demoRowsPadTheList() async {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0, extraRows: 250), settings: testSettings())
        await store.start()
        let plain = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await plain.start()
        #expect(store.packages.count == plain.packages.count + 250)
        #expect(store.packages.contains { $0.name == "demo-row-250" })
    }
}
