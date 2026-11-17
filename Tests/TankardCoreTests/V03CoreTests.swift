import Foundation
import Testing
@testable import TankardCore

extension Fixture {
    static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: brew cleanup -n

struct CleanupParsingTests {
    /// Captured read-only on the arm64 mini (brew 7.0.14-13, API mode), home renamed.
    @Test func arm64Capture() throws {
        let d = CleanupDryRun.parse(try Fixture.text("arm64-cleanup-n"), cachePath: "/Users/you/Library/Caches/Homebrew")
        #expect(d.summaryText == "2.5GB")
        #expect(d.summaryBytes == 2_500_000_000)
        #expect(d.totalIsFromBrew)
        #expect(d.totalText == "2.5GB")
        #expect(d.items.count == 20)
        let llvm = try #require(d.items.first)
        #expect(llvm.path == "/Users/you/Library/Caches/Homebrew/llvm--23.1.4")
        #expect(llvm.sizeText == "457.3MB")
        #expect(llvm.bytes == 457_300_000)
        #expect(llvm.kind == .download)
        let boot = try #require(d.items.first { $0.path.contains("bootsnap/8d9e") })
        #expect(boot.files == 1850)
        #expect(boot.sizeText == "16.4MB")
        // A path with a comma in it (cursor's version) keeps it.
        #expect(d.items.contains { $0.path.hasSuffix("cursor--3.29.15,86776fcb52ca505783155631089b65d646f9b03f.zip") && $0.bytes == 310_400_000 })
        #expect(d.items.filter { $0.kind == .log }.count == 4)
        #expect(d.items.first { $0.kind == .log }?.bytes == 64)
        #expect(d.warnings.isEmpty && d.errors.isEmpty)
    }

    /// Captured read-only on the Intel macOS 14 VM (Intelbrew, brew 7.0.14):
    /// homebrew/core is untrusted there, so brew warns 3,379 times, exits 1
    /// with an Error, and prints no total.
    @Test func intelVMCaptureWithoutSummary() throws {
        let d = CleanupDryRun.parse(try Fixture.text("sonoma-intelbrew-cleanup-n"), cachePath: "/Users/you/Library/Caches/Homebrew")
        #expect(d.summaryText == nil)
        #expect(!d.totalIsFromBrew)
        #expect(d.items.count == 13)
        #expect(d.items.first { $0.path.hasSuffix("cargo_cache") }?.files == 413_811)
        #expect(d.items.first { $0.path.hasSuffix("cargo_cache") }?.bytes == 7_800_000_000)
        #expect(d.items.first { $0.path.hasSuffix("tuios--0.13.0.tar.gz") }?.bytes == 0)
        #expect(d.items.allSatisfy { $0.kind == .download })
        // Summed by Tankard: 957.5MB + 7.8GB + 3GB + 9.7KB + 291.4MB + 32MB + 94.3MB + 5.3GB + 37.1KB
        #expect(d.totalBytes == 17_475_246_800)
        #expect(d.totalText == "17.5GB")
        #expect(d.warnings.count == 748) // deduplicated
        #expect(d.warnings[0] == "Warning: Skipping checkov: tap formula is not trusted")
        #expect(d.errors == ["Error: Refusing to load formula homebrew/core/hello from untrusted tap homebrew/core.",
                             "Run `brew trust --formula homebrew/core/hello` or `brew trust homebrew/core` to trust it."])
    }

    @Test func otherLineShapes() {
        let out = """
        Would remove: /usr/local/Cellar/python@3.15/3.15.0 (3,214 files, 63.8MB)
        Would remove (broken link): /usr/local/bin/oldtool
        Would remove (empty directory): /usr/local/share/old
        Would remove: /Users/x/My (odd) dir/thing.tar.gz (1.2KB)
        ==> This operation would free approximately 63.8MB of disk space.
        """
        let d = CleanupDryRun.parse(out)
        #expect(d.items.map(\.kind) == [.oldVersion, .other, .other, .other])
        #expect(d.items[0].files == 3214)
        #expect(d.items[1].bytes == nil)
        #expect(d.items[3].path == "/Users/x/My (odd) dir/thing.tar.gz")
        #expect(d.items[3].bytes == 1200)
        #expect(d.summaryText == "63.8MB")
        #expect(CleanupDryRun.parse("").items.isEmpty)
        #expect(CleanupDryRun.parse("==> This operation has freed approximately 1GB of disk space.").summaryBytes == 1_000_000_000)
    }

    @Test func sizesLikeBrew() {
        #expect(CleanupDryRun.bytes("64B") == 64)
        #expect(CleanupDryRun.bytes("9.7KB") == 9700)
        #expect(CleanupDryRun.bytes("3GB") == 3_000_000_000)
        #expect(CleanupDryRun.bytes("lots") == nil)
        #expect(CleanupDryRun.format(bytes: 64) == "64B")
        #expect(CleanupDryRun.format(bytes: 2_500_000_000) == "2.5GB")
        #expect(CleanupDryRun.format(bytes: 999_960) == "1MB")
        #expect(CleanupDryRun.format(bytes: 187_600_128) == "187.6MB")
    }
}

// MARK: compile classification

struct CompileClassificationTests {
    func packages() throws -> [Package] {
        try StatusClassifier(platform: .intelSonoma, intelbrewMode: true).classify(info: Fixture.info("synthetic-intel-info"))
    }

    @Test func upgradeMethodUsesUpgradeHasBottle() throws {
        let c = CompileClassifier()
        var p = try #require(try packages().first { $0.kind == .formula })
        p.upgradeAvailable = true
        p.upgradeHasBottle = false
        #expect(c.upgradeMethod(p) == .compile)
        #expect(c.upgradeWarning(p)?.label == "No bottle: will compile from source")
        #expect(c.upgradeWarning(p)?.estimateText == nil)
        p.upgradeHasBottle = nil // unknown counts as compiling (brew's summary does the same)
        #expect(c.upgradeMethod(p).compiles)
        p.upgradeHasBottle = true
        p.bottleURL = "https://github.com/d4rkwyng/intelbrew-core/releases/download/x-1/x-1.sonoma.bottle.tar.gz"
        #expect(c.upgradeMethod(p) == .bottle(.intelbrew))
        #expect(c.upgradeWarning(p) == nil)
        p.upgradeAvailable = false
        #expect(c.upgradeMethod(p) == .notApplicable)
    }

    @Test func casksNeverCompile() throws {
        var cask = try #require(try packages().first { $0.kind == .cask })
        cask.upgradeAvailable = true
        #expect(CompileClassifier().upgradeMethod(cask) == .notApplicable)
    }

    @Test func installMethodAndLabels() {
        let c = CompileClassifier()
        func e(_ b: CatalogBottle) -> CatalogEntry { CatalogEntry(kind: .formula, name: "x", fullName: "x", tap: "homebrew/core", desc: nil, bottle: b) }
        #expect(c.installMethod(e(.fromSource)) == .compile)
        #expect(c.installWarning(e(.fromSource))?.label == "No bottle: compiles")
        #expect(c.installMethod(e(.intelbrew)) == .bottle(.intelbrew))
        #expect(c.installMethod(e(.unknown)) == .unknown)
        #expect(c.installMethod(e(.cask)) == .notApplicable)
        #expect(c.installWarning(e(.unknown)) == nil)
    }

    @Test func buildTimeEstimatesAttachLater() {
        let c = CompileClassifier(estimator: BuildTimeTable(seconds: ["rust": 1500, "jo": 20, "llvm": 10_800]))
        func e(_ n: String) -> CatalogEntry { CatalogEntry(kind: .formula, name: n, fullName: n, tap: "homebrew/core", desc: nil, bottle: .fromSource) }
        #expect(c.installWarning(e("rust"))?.estimateText == "at least ~25 min on the Intelbrew builder")
        #expect(c.installWarning(e("rust"))?.text == "No bottle: compiles (at least ~25 min on the Intelbrew builder)")
        #expect(c.installWarning(e("jo"))?.estimateText == "at least ~1 min on the Intelbrew builder")
        #expect(c.installWarning(e("llvm"))?.estimateText == "at least ~3 h on the Intelbrew builder")
        // Rounded up, never down.
        let up = CompileClassifier(estimator: BuildTimeTable(seconds: ["a": 61, "b": 5401]))
        #expect(up.installWarning(e("a"))?.estimateText == "at least ~2 min on the Intelbrew builder")
        #expect(up.installWarning(CatalogEntry(kind: .formula, name: "b", fullName: "b", tap: "homebrew/core", desc: nil, bottle: .fromSource))?.estimateText == "at least ~2 h on the Intelbrew builder")
        #expect(c.installWarning(e("other"))?.estimateText == nil)
    }

    @Test func partitionUpgrades() throws {
        var a = try #require(try packages().first { $0.kind == .formula })
        a.upgradeAvailable = true
        a.upgradeHasBottle = true
        var b = a
        b.id = "formula:homebrew/core/b"
        b.upgradeHasBottle = false
        let (bottled, compiling) = CompileClassifier().partitionUpgrades([a, b])
        #expect(bottled.map(\.id) == [a.id])
        #expect(compiling.map(\.id) == [b.id])
    }

    @Test func dependenciesThatCompileWalksTheGraph() {
        func f(_ n: String, _ b: CatalogBottle, deps: [String] = [], build: [String] = []) -> CatalogEntry {
            CatalogEntry(kind: .formula, name: n, fullName: n, tap: "homebrew/core", desc: nil, dependencies: deps, buildDependencies: build, bottle: b)
        }
        let all = [
            f("app", .fromSource, deps: ["liba", "libb", "installed"], build: ["cmake"]),
            f("liba", .fromSource, deps: ["libc"]),          // compiles, and needs libc
            f("libb", .intelbrew, deps: ["libd"]),           // bottled: only runtime deps
            f("libc", .fromSource, build: ["meson"]),        // compiles, needs meson to build
            f("libd", .fromSource),                          // compiles (pulled by a bottle)
            f("cmake", .forThisMac),                         // build dep with a bottle
            f("meson", .fromSource),                         // a build dep that compiles
            f("installed", .fromSource),                     // already installed: nothing to do
        ]
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        let r = CompileClassifier().dependenciesThatCompile(byName["app"]!, lookup: { byName[$0] },
                                                            isInstalled: { $0.name == "installed" })
        #expect(r.compiling.map(\.name) == ["liba", "libc", "libd", "meson"])
        #expect(r.unknown.isEmpty)
        let ghost = f("ghostly", .fromSource, deps: ["nowhere", "liba"])
        let g = CompileClassifier().dependenciesThatCompile(ghost, lookup: { byName[$0] }, isInstalled: { _ in false })
        #expect(g.unknown == ["nowhere"])
        #expect(g.compiling.map(\.name) == ["liba", "libc", "meson"])
        // A bottled formula's build deps don't count.
        let bottled = f("tool", .intelbrew, deps: ["libd"], build: ["meson"])
        #expect(CompileClassifier().dependenciesThatCompile(bottled, lookup: { byName[$0] }, isInstalled: { _ in false }).compiling.map(\.name) == ["libd"])
    }
}

// MARK: replace with bottle

struct BottleReplacementTests {
    func vm() throws -> [Package] {
        try StatusClassifier(platform: .intelSonoma, intelbrewMode: true).classify(info: Fixture.info("sonoma-intelbrew-info"))
    }

    /// The VM's vim is a real source build whose 9.2.1355 has an Intelbrew bottle.
    @Test func vimOnTheVMIsEligible() throws {
        let vim = try #require(try vm()["vim"])
        #expect(vim.pouredFromBottle == false)
        #expect(vim.currentHasBottle == true)
        #expect(BottleReplacement.isEligible(vim))
        #expect(BottleReplacement.origin(vim) == .intelbrew)
        #expect(BottleReplacement.badge(vim, intelbrewMode: true) == "Intelbrew bottle available")
        #expect(BottleReplacement.badge(vim, intelbrewMode: false) == "Bottle available")
        #expect(BottleReplacement.arguments(qualifiedName: "homebrew/core/vim") == ["reinstall", "--force-bottle", "--formula", "homebrew/core/vim"])
        // Everything else on the VM was poured from a bottle.
        #expect(try vm().filter(BottleReplacement.isEligible).map(\.name) == ["vim"])
    }

    @Test func notEligible() throws {
        let base = try #require(try vm()["vim"])
        var p = base
        p.pouredFromBottle = nil // unknown receipt: don't guess
        #expect(!BottleReplacement.isEligible(p))
        p = base; p.currentHasBottle = false; p.status = .noBottle
        #expect(!BottleReplacement.isEligible(p))
        p = base; p.upgradeAvailable = true // that's an upgrade, not a reinstall
        #expect(!BottleReplacement.isEligible(p))
        p = base; p.installedVersion = "9.2.1300"
        #expect(!BottleReplacement.isEligible(p))
        p = base; p.installedVersion = "HEAD-1a2b3c4"; p.currentVersion = "HEAD-1a2b3c4"
        #expect(!BottleReplacement.isEligible(p))
        p = base; p.kind = .cask
        #expect(!BottleReplacement.isEligible(p))
        p = base; p.bottleURL = "https://ghcr.io/v2/homebrew/core/vim/blobs/sha256:00"
        #expect(BottleReplacement.badge(p, intelbrewMode: true) == "Bottle available")
    }
}

// MARK: formula scanning (Intelbrew-mode Discover)

struct FormulaScannerTests {
    // Excerpts of real homebrew-core files from the Intel VM's Intelbrew checkout.
    let xz = """
    class Xz < Formula
      desc "General-purpose data compression with high compression ratio"
      url "https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz"
      license all_of: [
        "0BSD",
        "GPL-2.0-or-later",
      ]

      bottle do
        root_url "https://github.com/d4rkwyng/intelbrew-core/releases/download/xz-5.8.4"
        rebuild 1
        sha256 cellar: :any, sonoma: "a72d414ff1913c0f5f141422005945b3a0649d94716064e7c0c84be985959545"
      end

      deny_network_access!

      def install
        system "./configure", *std_configure_args
      end
    end
    """
    let lua = """
    class Lua < Formula
      bottle do
        sha256 cellar: :any, arm64_golden_gate: "058cec4331d0939089cf953851a35bd4bd108d932e0356d30636ad08327d2183"
        sha256 cellar: :any, arm64_sonoma:      "e102957f67a1fe9dc8bfd0d6409c4c776791daacb75f28910e28f0a13d1a438b"
        sha256 cellar: :any, sonoma:            "13ba70d9eeb49a39ed8d44b688f38cee7185bbe2ca88b400796a76a482833423"
        sha256 cellar: :any, x86_64_linux:      "d221d3bf5b1ac55775e12cb147d995e6b29dc46a3e5dfc33bc3c6295fed1561e"
      end
    end
    """
    let vim = """
    class Vim < Formula
      head "https://github.com/vim/vim.git", branch: "master"

      livecheck do
        url "https://github.com/vim/vim/tags.atom"
        strategy :xml do |xml, regex|
          xml.get_elements("//title").map { |item| item.text[regex, 1] }
        end
      end

      bottle do
        root_url "https://github.com/d4rkwyng/intelbrew-core/releases/download/vim-9.2.1355"
        sha256 sonoma: "246f68cd78fff32885bafef2c47437fa9563d2f1d8ee27c013a12fffce86155f"
      end

      depends_on "gettext" => :build
      depends_on "lua" => [:build, :test]
      depends_on "python@3.15" => [:build, :test]
      depends_on "ncurses"
      depends_on "pytest" => :test

      uses_from_macos "perl"

      on_linux do
        depends_on "acl"
      end

      on_macos do
        depends_on "libsodium"
      end

      def install
        depends_on "never-read"
      end
    end
    """

    @Test func bottleBlocks() {
        let x = FormulaScanner.bottle(in: xz, tap: "homebrew/core")
        #expect(x.rootURL == "https://github.com/d4rkwyng/intelbrew-core/releases/download/xz-5.8.4")
        #expect(x.files["sonoma"]?.cellar == ":any")
        let l = FormulaScanner.bottle(in: lua, tap: "homebrew/core")
        #expect(l.rootURL == "https://ghcr.io/v2/homebrew/core")
        #expect(Set(l.files.keys) == ["arm64_golden_gate", "arm64_sonoma", "sonoma", "x86_64_linux"])
        let v = FormulaScanner.bottle(in: vim, tap: "homebrew/core")
        #expect(v.files["sonoma"]?.cellar == "/usr/local/Cellar") // no cellar: brew's default for the tag
        let none = FormulaScanner.bottle(in: "class Foo < Formula\n  desc \"x\"\nend\n", tap: "homebrew/core")
        #expect(none.files.isEmpty && none.rootURL == nil)
        // brew style pads the tag column when some lines have a cellar (bcoin on the VM).
        let padded = FormulaScanner.bottle(in: """
          bottle do
            rebuild 3
            sha256 cellar: :any_skip_relocation, arm64_golden_gate: "677e"
            sha256                               sonoma:            "48ca"
            sha256 cellar: :any_skip_relocation, x86_64_linux:      "cf6e"
          end
        """, tap: "homebrew/core")
        #expect(padded.files["sonoma"]?.cellar == "/usr/local/Cellar")
        #expect(padded.files["arm64_golden_gate"]?.cellar == ":any_skip_relocation")
        #expect(padded.files.count == 3)
        let custom = FormulaScanner.bottle(in: "  bottle do\n    sha256 cellar: \"/opt/custom/Cellar\", sonoma: \"ab\"\n  end\n", tap: "me/tools")
        #expect(custom.files["sonoma"]?.cellar == "/opt/custom/Cellar")
        #expect(custom.rootURL == nil)
    }

    @Test func scannedBottlesJudgedForThisMac() {
        let b = CatalogBuilder(platform: .intelSonoma, intelbrewMode: true)
        #expect(b.bottle(spec: FormulaScanner.bottle(in: xz, tap: "homebrew/core")).0 == .intelbrew)
        #expect(b.bottle(spec: FormulaScanner.bottle(in: lua, tap: "homebrew/core")).0 == .forThisMac)
        #expect(b.bottle(spec: FormulaScanner.bottle(in: "class A < Formula\nend", tap: "homebrew/core")).0 == .fromSource)
        let arm = CatalogBuilder(platform: .armGoldenGate, intelbrewMode: false)
        #expect(arm.bottle(spec: FormulaScanner.bottle(in: xz, tap: "homebrew/core")).0 == .fromSource) // Intel only
        let entry = TapIndexEntry(kind: .formula, name: "xz", tap: "homebrew/core", desc: nil,
                                  bottle: FormulaScanner.bottle(in: xz, tap: "homebrew/core"))
        #expect(entry.catalogEntry(builder: b).bottle == .intelbrew)
        #expect(entry.catalogEntry().bottle == .unknown)
        #expect(TapIndexEntry(kind: .formula, name: "q", tap: "homebrew/core", desc: nil).catalogEntry(builder: b).bottle == .unknown)
    }

    @Test func dependencies() {
        let d = FormulaScanner.dependencies(in: vim)
        #expect(d.runtime == ["ncurses", "libsodium"])
        #expect(d.build == ["gettext", "lua", "python@3.15"])
        #expect(FormulaScanner.dependencies(in: xz).runtime.isEmpty)
    }

    @Test func indexerReadsTheBlocks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let formula = root.appendingPathComponent("homebrew/homebrew-core/Formula")
        try FileManager.default.createDirectory(at: formula.appendingPathComponent("v"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: formula.appendingPathComponent("x"), withIntermediateDirectories: true)
        try vim.write(to: formula.appendingPathComponent("v/vim.rb"), atomically: true, encoding: .utf8)
        // A long formula: the bottle block comes after the first 16 KB.
        let padded = "class Xz < Formula\n" + String(repeating: "  # padding padding padding padding\n", count: 600) + xz
        try padded.write(to: formula.appendingPathComponent("x/xz.rb"), atomically: true, encoding: .utf8)
        let index = TapIndexer(tapsDirectory: root).index()
        let byName = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.name, $0) })
        #expect(byName["vim"]?.bottle?.files["sonoma"] != nil)
        #expect(byName["vim"]?.dependencies == ["ncurses", "libsodium"])
        #expect(byName["xz"]?.bottle?.files["sonoma"]?.cellar == ":any")
    }
}

// MARK: Discover ranking

struct BottledRankingTests {
    func f(_ n: String, _ b: CatalogBottle, desc: String? = nil) -> CatalogEntry {
        CatalogEntry(kind: .formula, name: n, fullName: n, tap: "homebrew/core", desc: desc, bottle: b)
    }

    @Test func bottledFirstWithinATier() {
        let entries = [f("jqa", .fromSource), f("jqb", .intelbrew), f("jqc", .unknown), f("jq", .fromSource), f("jqzz", .forThisMac)]
        // Relevance first: the exact match stays on top even though it compiles.
        #expect(CatalogSearch.search("jq", in: entries, preferBottled: true).map(\.name) == ["jq", "jqb", "jqzz", "jqc", "jqa"])
        // Without the preference: shorter name, then alphabetical (v0.2 order).
        #expect(CatalogSearch.search("jq", in: entries).map(\.name) == ["jq", "jqa", "jqb", "jqc", "jqzz"])
    }

    @Test func bottledOnlyDropsKnownCompiles() {
        let entries = [f("jqa", .fromSource), f("jqb", .intelbrew), f("jqc", .unknown),
                       CatalogEntry(kind: .cask, name: "jqapp", fullName: "jqapp", tap: "homebrew/cask", desc: nil, bottle: .cask)]
        #expect(CatalogSearch.search("jq", in: entries, bottledOnly: true).map(\.name) == ["jqb", "jqc", "jqapp"])
        let counts = CatalogSearch.bottledCount(entries)
        #expect(counts.bottled == 1 && counts.formulae == 3)
    }
}
