import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6 (VM test L3, L4): steipete/tap/sonoscli has no `bottle do` block
// but downloads a release binary for macOS; Discover said "No bottle:
// compiles" and the result "1 build from source" for a 1-second install,
// and the Version field stayed "–" while the tap was untrusted although
// the formula says `version "0.3.6"`. Installing it by its full name also
// trusts the tap (brew's "Trusted formula …"), which the confirmation
// didn't say.
@MainActor
struct V086PrebuiltTapTests {
    static let goreleaser = """
    class Sonoscli < Formula
      desc "Control Sonos speakers from the command line"
      homepage "https://github.com/steipete/sonoscli"
      version "0.3.6"
      license "MIT"

      on_macos do
        if Hardware::CPU.arm?
          url "https://github.com/steipete/sonoscli/releases/download/v0.3.6/sonoscli_0.3.6_darwin_arm64.tar.gz"
          sha256 "aaaa"
        end
        if Hardware::CPU.intel?
          url "https://github.com/steipete/sonoscli/releases/download/v0.3.6/sonoscli_0.3.6_darwin_amd64.tar.gz"
          sha256 "bbbb"
        end
      end

      def install
        bin.install "sonoscli"
      end
    end
    """

    static let source = """
    class Walk < Formula
      desc "Builds from a source tarball"
      homepage "https://example.com"
      url "https://example.com/walk-1.2.tar.gz"
      sha256 "cccc"

      depends_on "go" => :build

      def install
        system "go", "build", *std_go_args
      end
    end
    """

    @Test func scanTellsAReadyMadeDownloadFromASourceBuild() {
        #expect(TapIndexer.prebuiltDownload(Data(Self.goreleaser.utf8)))
        #expect(!TapIndexer.prebuiltDownload(Data(Self.source.utf8)))
        // A darwin binary that is still built with `system` isn't ready-made.
        #expect(!TapIndexer.prebuiltDownload(Data(Self.goreleaser.replacingOccurrences(of: "bin.install \"sonoscli\"", with: "system \"make\"").utf8)))
        // A bottle block: the bottle decides, not this.
        #expect(!TapIndexer.prebuiltDownload(Data(Self.goreleaser.replacingOccurrences(of: "  license \"MIT\"\n", with: "  license \"MIT\"\n\n  bottle do\n    sha256 arm64_sequoia: \"dd\"\n  end\n").utf8)))
    }

    @Test func indexedEntryDownloadsAReadyMadeProgram() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("steipete/homebrew-tap/Formula")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.goreleaser.write(to: dir.appendingPathComponent("sonoscli.rb"), atomically: true, encoding: .utf8)
        try Self.source.write(to: dir.appendingPathComponent("walk.rb"), atomically: true, encoding: .utf8)
        let index = TapIndexer(tapsDirectory: root).index()
        let builder = CatalogBuilder(platform: BottlePlatform(arch: .arm64, macOSVersion: "15", cellar: "/opt/homebrew/Cellar"), intelbrewMode: false)
        let sonos = try #require(index.entries.first { $0.name == "sonoscli" }).catalogEntry(builder: builder)
        let walk = try #require(index.entries.first { $0.name == "walk" }).catalogEntry(builder: builder)
        #expect(sonos.bottle == .prebuilt)
        #expect(sonos.version == "0.3.6")
        #expect(sonos.badgeLabel == "Downloads a ready-made program")
        #expect(CompileClassifier().installWarning(sonos) == nil)
        #expect(walk.bottle == .fromSource)
        #expect(CompileClassifier().installWarning(walk) != nil)
        // brew info later says "no bottle": the scan's answer stays.
        var info = sonos
        info.bottle = .fromSource
        info.version = nil
        let merged = sonos.merging(info)
        #expect(merged.bottle == .prebuilt)
        #expect(merged.version == "0.3.6")
        // The install result doesn't call it a build from source.
        let p = sonos.asPackage()
        #expect(p.prebuiltDownload == true)
    }

    @Test func installSubtitleSaysReadyMadeNotBuild() async throws {
        var e = CatalogEntry(kind: .formula, name: "sonoscli", fullName: "steipete/tap/sonoscli", tap: "steipete/tap", desc: nil, bottle: .prebuilt)
        e.version = "0.3.6"
        let s = UpgradeSession(packages: [e.asPackage()], intelbrewMode: false, action: .install,
                               queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { _, _ in 0 }),
                               makeCommand: { p in QueuedCommand(executable: "/x/brew", arguments: ["install", p.fullName], environment: [:], display: "brew install \(p.fullName)") },
                               logURL: nil, onFinish: { _ in })
        #expect(await waitUntil { s.isFinished })
        #expect(!s.subtitle.contains("from source"))
        #expect(s.subtitle == "1 ready-made program")
    }

    @Test func untrustedTapInstallSaysItTrustsTheTap() {
        var e = CatalogEntry(kind: .formula, name: "sonoscli", fullName: "steipete/tap/sonoscli", tap: "steipete/tap", desc: nil, bottle: .prebuilt)
        #expect(DiscoverTrust.note(e, untrustedTaps: ["steipete/tap"]) == "Installing this trusts the tap steipete/tap for this formula.")
        #expect(DiscoverTrust.note(e, untrustedTaps: ["Steipete/Tap"]) != nil)
        #expect(DiscoverTrust.note(e, untrustedTaps: []) == nil)
        e.untrustedTap = true
        #expect(DiscoverTrust.note(e, untrustedTaps: []) != nil)
        // A cask from a tap: the same.
        let core = CatalogEntry(kind: .formula, name: "xz", fullName: "xz", tap: "homebrew/core", desc: nil, bottle: .forThisMac)
        #expect(DiscoverTrust.note(core, untrustedTaps: ["homebrew/core"]) == nil)
    }

    @Test func brewsRefusalNamesTheUntrustedTap() {
        let stderr = """
        Error: Refusing to load formula steipete/tap/sonoscli from untrusted tap steipete/tap.
        Run `brew trust --formula steipete/tap/sonoscli` or `brew trust steipete/tap` to trust it.
        """
        #expect(DiscoverTrust.untrustedTaps(in: stderr) == ["steipete/tap"])
        #expect(DiscoverTrust.untrustedTaps(in: "Error: No available formula with the name \"x\"") == [])
    }

    @Test func unreadablePackagesNameUntrustedTaps() {
        var p = Package.command("gifgrep")
        p.unreadable = "Refusing to load formula steipete/tap/gifgrep from untrusted tap steipete/tap."
        #expect(DiscoverTrust.untrustedTaps(packages: [p], taps: []) == ["steipete/tap"])
        let t = TapInfo(name: "other/tap", trusted: false)
        #expect(DiscoverTrust.untrustedTaps(packages: [], taps: [t]) == ["other/tap"])
        #expect(DiscoverTrust.untrustedTaps(packages: [], taps: [TapInfo(name: "x/y", trusted: true)]) == [])
    }
}
