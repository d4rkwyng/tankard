import Foundation
import Testing
@testable import TankardCore

struct CatalogSearchTests {
    func e(_ name: String, desc: String? = nil, kind: PackageKind = .formula, other: [String] = [],
           deprecated: Bool = false) -> CatalogEntry {
        CatalogEntry(kind: kind, name: name, fullName: name, tap: kind == .cask ? "homebrew/cask" : "homebrew/core",
                     desc: desc, otherNames: other, deprecated: deprecated, bottle: kind == .cask ? .cask : .forThisMac)
    }

    var catalog: [CatalogEntry] {
        [
            e("ipython", desc: "Interactive computing in Python"),
            e("python@3.14", desc: "Interpreted, interactive, object-oriented programming language", other: ["python3", "python"]),
            e("python@3.9", desc: "Interpreted, interactive, object-oriented programming language", deprecated: true),
            e("python-build", desc: "Simple, correct PEP 517 build frontend"),
            e("bpython", desc: "Fancy interface to the Python interpreter"),
            e("jq", desc: "Lightweight and flexible command-line JSON processor"),
            e("cython", desc: "Compiler for writing C extensions for the Python language"),
            e("python", desc: "Cask with the same short name", kind: .cask, other: ["Python Launcher"]),
            e("zstd", desc: "Zstandard is a real-time compression algorithm"),
        ]
    }

    @Test func exactBeatsPrefixBeatsContainsBeatsDescription() {
        let names = CatalogSearch.search("python", in: catalog).map(\.name)
        // Exact matches: the cask named python and python@3.14 (alias "python").
        // A tie goes to the shorter name, so the cask leads.
        #expect(names.prefix(2) == ["python", "python@3.14"])
        // Prefix next (python-build), then the deprecated prefix match, then name-contains, then description.
        #expect(Array(names[2...3]) == ["python-build", "python@3.9"])
        #expect(Array(names[4...5]) == ["bpython", "ipython"])
        #expect(names.last == "cython") // description only
        #expect(!names.contains("jq"))
    }

    @Test func deprecatedLosesATie() {
        let s = CatalogSearch.search("python@3", in: catalog).map(\.name)
        #expect(s == ["python@3.14", "python@3.9"])
    }

    @Test func kindFilterAndEmptyQuery() {
        #expect(CatalogSearch.search("python", in: catalog, kind: .casks).map(\.name) == ["python"])
        #expect(!CatalogSearch.search("python", in: catalog, kind: .formulae).contains { $0.kind == .cask })
        #expect(CatalogSearch.search("   ", in: catalog).isEmpty)
    }

    @Test func caseInsensitiveAliasesAndAllWords() {
        #expect(CatalogSearch.search("PYTHON3", in: catalog).first?.name == "python@3.14")
        #expect(CatalogSearch.search("launcher", in: catalog).map(\.name) == ["python"])
        // Every word somewhere (name or description), not as one phrase.
        #expect(CatalogSearch.search("json processor", in: catalog).map(\.name) == ["jq"])
        #expect(CatalogSearch.search("compression zstandard", in: catalog).map(\.name) == ["zstd"])
    }

    @Test func limit() {
        let many = (0..<500).map { e("lib\($0)") }
        #expect(CatalogSearch.search("lib", in: many, limit: 50).count == 50)
    }
}

struct CatalogBuilderTests {
    @Test func bottleBadgesFromTheIntelFixture() throws {
        let info = try Fixture.info("sonoma-intelbrew-info")
        let ib = CatalogBuilder(platform: .intelSonoma, intelbrewMode: true)
        let byName = Dictionary(info.formulae.map { ($0.name, ib.entry($0)) }, uniquingKeysWith: { a, _ in a })
        // python@3.15's sonoma bottle is on d4rkwyng/intelbrew-core.
        #expect(byName["python@3.15"]?.bottle == .intelbrew)
        #expect(byName["python@3.15"]?.bottleTag == "sonoma")
        // ca-certificates pours Homebrew's "all" bottle from ghcr.io.
        #expect(byName["ca-certificates"]?.bottle == .forThisMac)
        // Outside Intelbrew mode an Intelbrew-hosted bottle is just a bottle.
        let plain = CatalogBuilder(platform: .intelSonoma, intelbrewMode: false)
        let py = try #require(info.formulae.first { $0.name == "python@3.15" })
        #expect(plain.entry(py).bottle == .forThisMac)
        // No bottle for this platform: builds from source.
        let tahoeOnly = CatalogBuilder(platform: BottlePlatform(arch: .arm64, macOSVersion: "13", cellar: "/opt/homebrew/Cellar"),
                                       intelbrewMode: false)
        #expect(tahoeOnly.entry(py).bottle == .fromSource)
        #expect(byName["python@3.15"]?.id == "formula:homebrew/core/python@3.15")
        #expect(byName["python@3.15"]?.qualifiedName == "homebrew/core/python@3.15")
    }

    @Test func apiShapedJSONDecodes() throws {
        let formula = #"""
        [{"name":"zstd","full_name":"zstd","tap":"homebrew/core","desc":"Zstandard",
          "license":"BSD-3-Clause","homepage":"https://facebook.github.io/zstd/",
          "versions":{"stable":"1.5.7","head":"HEAD","bottle":true},"revision":1,
          "dependencies":["lz4","xz"],"aliases":["zstandard"],"oldnames":[],
          "bottle":{"stable":{"rebuild":0,"root_url":"https://ghcr.io/v2/homebrew/core",
            "files":{"arm64_golden_gate":{"cellar":":any","url":"https://ghcr.io/v2/homebrew/core/zstd/blobs/sha256:1"}}}},
          "deprecated":false,"disabled":false,"installed":[],"outdated":false,"pinned":false,"keg_only":false},
         {"name":"weird","full_name":"weird","tap":"homebrew/core","versions":{"stable":"1"},
          "license":{"any_of":["MIT",{"all_of":["GPL-2.0-only","BSD-2-Clause"]}]}}]
        """#
        let fs = try JSONDecoder().decode([BrewInfoJSON.Formula].self, from: Data(formula.utf8))
        let b = CatalogBuilder(platform: .armGoldenGate, intelbrewMode: false)
        let z = b.entry(fs[0])
        #expect(z.version == "1.5.7_1")
        #expect(z.license == "BSD-3-Clause")
        #expect(z.dependencies == ["lz4", "xz"])
        #expect(z.homepage == "https://facebook.github.io/zstd/")
        #expect(z.bottle == .forThisMac)
        #expect(z.otherNames == ["zstandard"])
        #expect(fs[1].license == "MIT or (GPL-2.0-only and BSD-2-Clause)")

        let cask = #"""
        [{"token":"orbstack","full_token":"orbstack","tap":"homebrew/cask","name":["OrbStack"],"desc":null,
          "homepage":"https://orbstack.dev/","version":"2.0","depends_on":{"macos":{">=":["13"]},"formula":"docker","cask":["x"]}}]
        """#
        let cs = try JSONDecoder().decode([BrewInfoJSON.Cask].self, from: Data(cask.utf8))
        let o = b.entry(cs[0])
        #expect(o.bottle == .cask)
        #expect(o.dependencies == ["docker"])
        #expect(o.caskDependencies == ["x"])
        #expect(o.id == "cask:homebrew/cask/orbstack")
        #expect(o.asPackage().kind == .cask)
    }
}

struct DependentsTests {
    @Test func runtimeDependenciesFromTheReceipt() throws {
        let packages = StatusClassifier(platform: .intelSonoma, intelbrewMode: true)
            .classify(info: try Fixture.info("sonoma-intelbrew-info"))
        let python = try #require(packages["python@3.15"])
        #expect(python.dependencies?.contains("ca-certificates") == true)
        let ca = try #require(packages["ca-certificates"])
        let needs = Dependents.of(ca, among: packages).map(\.name)
        #expect(needs.contains("python@3.15"))
        #expect(!needs.contains("ca-certificates"))
        // A leaf nothing needs.
        let vim = try #require(packages["vim"])
        #expect(Dependents.of(vim, among: packages).isEmpty)
    }

    @Test func namesMatchShortAndQualifiedButNotOtherTaps() throws {
        let packages = StatusClassifier(platform: .intelSonoma, intelbrewMode: true)
            .classify(info: try Fixture.info("sonoma-intelbrew-info"))
        var xz = try #require(packages["xz"])
        var user = try #require(packages["vim"])
        user.dependencies = ["homebrew/core/xz"]
        #expect(Dependents.of(xz, among: [xz, user]).map(\.name) == ["vim"])
        user.dependencies = ["someone/tap/xz"]
        #expect(Dependents.of(xz, among: [xz, user]).isEmpty)
        // A formula in another tap is only named by its qualified name.
        xz.tap = "someone/tap"
        xz.fullName = "someone/tap/xz"
        user.dependencies = ["xz"]
        #expect(Dependents.of(xz, among: [xz, user]).isEmpty)
        user.dependencies = ["someone/tap/xz"]
        #expect(Dependents.of(xz, among: [xz, user]).map(\.name) == ["vim"])
    }

    @Test func caskDependsOnCask() throws {
        let json = #"""
        {"formulae":[],"casks":[
          {"token":"docker-desktop","full_token":"docker-desktop","tap":"homebrew/cask","version":"4","installed":"4"},
          {"token":"kitematic","full_token":"kitematic","tap":"homebrew/cask","version":"1","installed":"1",
           "depends_on":{"cask":["docker-desktop"]}}]}
        """#
        let info = try JSONDecoder().decode(BrewInfoJSON.self, from: Data(json.utf8))
        let ps = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false).classify(info: info)
        let docker = try #require(ps["docker-desktop"])
        #expect(Dependents.of(docker, among: ps).map(\.name) == ["kitematic"])
    }
}

struct TapIndexTests {
    func makeTaps() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-taps-\(UUID().uuidString)")
        let core = root.appendingPathComponent("homebrew/homebrew-core")
        let fm = FileManager.default
        try fm.createDirectory(at: core.appendingPathComponent("Formula/x"), withIntermediateDirectories: true)
        try fm.createDirectory(at: core.appendingPathComponent("Formula/p"), withIntermediateDirectories: true)
        try fm.createDirectory(at: core.appendingPathComponent("Aliases"), withIntermediateDirectories: true)
        try """
        class Xz < Formula
          desc "General-purpose data compression with high compression ratio"
          homepage "https://tukaani.org/xz/"
        end
        """.write(to: core.appendingPathComponent("Formula/x/xz.rb"), atomically: true, encoding: .utf8)
        try """
        class PythonAT314 < Formula
          desc 'Interpreted, interactive, "object-oriented" language'
        end
        """.write(to: core.appendingPathComponent("Formula/p/python@3.14.rb"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: core.appendingPathComponent("Aliases/python3").path,
                                  withDestinationPath: "../Formula/p/python@3.14.rb")
        let other = root.appendingPathComponent("someone/homebrew-tools/Formula")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try "class Thing < Formula\n  desc \"A \\\"quoted\\\" thing\"\nend\n"
            .write(to: other.appendingPathComponent("thing.rb"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func readsNamesDescriptionsAndAliases() throws {
        let root = try makeTaps()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = TapIndexer(tapsDirectory: root).index()
        #expect(index.taps == ["homebrew/core", "someone/tools"])
        #expect(!index.hasCaskTap)
        let byName = Dictionary(index.entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["xz"]?.desc == "General-purpose data compression with high compression ratio")
        #expect(byName["python@3.14"]?.desc == #"Interpreted, interactive, "object-oriented" language"#)
        #expect(byName["python@3.14"]?.otherNames == ["python3"])
        #expect(byName["thing"]?.desc == #"A "quoted" thing"#)
        #expect(byName["thing"]?.fullName == "someone/tools/thing")
        let e = try #require(byName["thing"]).catalogEntry()
        #expect(e.id == "formula:someone/tools/thing")
        #expect(!e.detailsLoaded)
        #expect(e.bottle == .unknown)
    }

    @Test func rubyStringArgument() {
        #expect(TapIndexer.rubyStringArgument("desc", in: "  desc \"a \\\\ b\"\n") == "a \\ b")
        #expect(TapIndexer.rubyStringArgument("desc", in: "  desc 'it\\'s'\n") == "it's")
        #expect(TapIndexer.rubyStringArgument("desc", in: "  desc some_method\n") == nil)
        #expect(TapIndexer.rubyStringArgument("name", in: "cask \"x\" do\n  name \"X App\"\n  desc \"d\"\n") == "X App")
    }

    @Test func infoArguments() {
        #expect(BrewClient.infoArguments(["homebrew/core/xz"], kind: .formula) == ["info", "--json=v2", "--formula", "--", "homebrew/core/xz"])
        #expect(BrewClient.infoArguments(["homebrew/cask/firefox"], kind: .cask) == ["info", "--json=v2", "--cask", "--", "homebrew/cask/firefox"])
    }
}
