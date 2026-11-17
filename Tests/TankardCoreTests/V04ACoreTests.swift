import Foundation
import Testing
@testable import TankardCore

// v0.4 (part A): dependency graph, leaves, the tree, and brew services
// decoding, checked against real output captured read-only on the Intel
// macOS 14 VM (brew 7.0.14, Intelbrew) and the arm64 Mac (brew 7.0.14,
// API mode) on 2026-11-16:
//
//   brew info --json=v2 --installed     *-deps-info.json (trimmed to the keys read)
//   brew deps --installed               *-deps-installed.txt
//   brew uses --installed <formula>     *-uses-installed.txt (one line per formula)
//   brew leaves / brew leaves -r        *-leaves.txt / *-leaves-r.txt
//   brew deps --tree --installed python@3.15   sonoma-intelbrew-deps-tree-python.txt
//   brew services list --json           *-services-list.json
//   brew services info --all --json     arm64-services-info.json

enum TextFixture {
    static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// "name: a b c" lines (brew deps --installed, and the uses capture).
    static func map(_ name: String) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for line in try text(name).split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            out[key] = line[line.index(after: colon)...].split(separator: " ").map(String.init)
        }
        return out
    }

    static func lines(_ name: String) throws -> [String] {
        try text(name).split(separator: "\n").map(String.init)
    }
}

struct DependencyGraphTests {
    enum Machine: String, CaseIterable {
        case vm = "sonoma-intelbrew", arm64 = "arm64"
        var platform: BottlePlatform { self == .vm ? .intelSonoma : .armGoldenGate }
    }

    func packages(_ m: Machine) throws -> [Package] {
        StatusClassifier(platform: m.platform, intelbrewMode: m == .vm).classify(info: try Fixture.info("\(m.rawValue)-deps-info"))
    }

    @Test(arguments: Machine.allCases)
    func dependsOnMatchesBrewDepsInstalled(_ m: Machine) throws {
        let pkgs = try packages(m)
        let graph = DependencyGraph(pkgs)
        let expected = try TextFixture.map("\(m.rawValue)-deps-installed")
        #expect(pkgs.count == expected.count) // brew lists casks too
        #expect(pkgs.count > 15)
        var exact = 0
        for p in pkgs {
            let ours = Set(graph.dependencies(of: p).map(\.name))
            let theirs = Set(try #require(expected[p.name], "\(p.name)"))
            // Never missing anything brew lists; at most extra receipt linkage.
            #expect(theirs.isSubset(of: ours), "\(p.name)")
            if ours == theirs { exact += 1 }
        }
        switch m {
        case .vm: #expect(exact == pkgs.count)          // 20 of 20
        case .arm64: #expect(exact == pkgs.count - 19)  // 196 of 215; 19 formulae have extra linkage
        }
    }

    @Test(arguments: Machine.allCases)
    func usedByMatchesBrewUsesInstalled(_ m: Machine) throws {
        let pkgs = try packages(m)
        let graph = DependencyGraph(pkgs)
        let expected = try TextFixture.map("\(m.rawValue)-uses-installed")
        var checked = 0
        for p in pkgs where p.kind == .formula {
            guard let want = expected[p.name] else { continue }
            #expect(graph.dependents(of: p).map(\.name).sorted() == want.sorted(), "\(p.name)")
            checked += 1
        }
        #expect(checked == pkgs.filter { $0.kind == .formula }.count)
    }

    @Test(arguments: Machine.allCases)
    func leavesMatchBrewLeaves(_ m: Machine) throws {
        let pkgs = try packages(m)
        let graph = DependencyGraph(pkgs)
        let formulae = pkgs.filter { $0.kind == .formula }
        // Hoisted: Swift 6.0 rejects `try` inside #expect's autoclosure.
        let leaves = try TextFixture.lines("\(m.rawValue)-leaves").sorted()
        let requested = try TextFixture.lines("\(m.rawValue)-leaves-r").sorted()
        #expect(formulae.filter(graph.isLeaf).map(\.name).sorted() == leaves)
        #expect(formulae.filter(graph.isRequestedLeaf).map(\.name).sorted()
                == requested)
    }

    @Test func treeMatchesBrewDepsTree() throws {
        let pkgs = try packages(.vm)
        let graph = DependencyGraph(pkgs)
        let python = try #require(pkgs["python@3.15"])
        let want = try TextFixture.text("sonoma-intelbrew-deps-tree-python").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(graph.tree(of: python).treeText() == want)
        // The first level is the receipt's declared_directly entries, in its order.
        #expect(python.directDependencies == ["ca-certificates", "mpdecimal", "openssl@4", "sqlite", "xz", "zstd", "expat"])
        #expect(graph.directNames(of: python) == python.directDependencies)
        // Every node with a package is installed; nothing is a cycle.
        func walk(_ n: DependencyGraph.Node) { #expect(n.packageID != nil); #expect(!n.isCycle); n.children.forEach(walk) }
        walk(graph.tree(of: python))
    }

    @Test func receiptWithoutDeclaredDirectlyFallsBackToReduction() throws {
        var pkgs = try packages(.vm)
        for i in pkgs.indices { pkgs[i].directDependencies = nil }
        let graph = DependencyGraph(pkgs)
        let python = try #require(pkgs["python@3.15"])
        // ca-certificates comes with openssl@4, readline with sqlite, lz4 and xz with zstd.
        #expect(Set(graph.directNames(of: python)) == ["expat", "mpdecimal", "openssl@4", "sqlite", "zstd"])
        // Without the receipt flag, the declared list is used.
        #expect(StatusClassifier.directDependencies(nil, declared: ["a", "b"]) == ["a", "b"])
    }

    @Test func cyclesAndDepthAreBounded() throws {
        func pkg(_ name: String, _ deps: [String]) -> Package {
            var p = Package.command(name)
            p.id = "formula:homebrew/core/\(name)"
            p.name = name
            p.fullName = name
            p.tap = "homebrew/core"
            p.dependencies = deps
            p.directDependencies = deps
            return p
        }
        let a = pkg("a", ["b"]), b = pkg("b", ["a", "c"])
        let graph = DependencyGraph([a, b])
        let t = graph.tree(of: a)
        #expect(t.children.map(\.name) == ["b"])
        #expect(t.children[0].children.map(\.name) == ["a", "c"])
        #expect(t.children[0].children[0].isCycle)
        #expect(t.children[0].children[1].packageID == nil) // c isn't installed
        #expect(graph.tree(of: a, maxDepth: 1).children[0].isTruncated)
    }

    @Test func casksCountForLeavesAndUses() throws {
        let pkgs = try packages(.arm64)
        let graph = DependencyGraph(pkgs)
        // A cask nothing depends on is a requested leaf.
        let casks = pkgs.filter { $0.kind == .cask }
        #expect(!casks.isEmpty)
        #expect(casks.allSatisfy(graph.isRequestedLeaf))
    }
}

struct ServicesDecodeTests {
    @Test func armListAndInfo() throws {
        let list = try BrewServices.decode(Fixture.data("arm64-services-list"))
        #expect(list == [BrewService(name: "php", status: .none, user: nil,
                                     file: "/opt/homebrew/opt/php/sh.brew.php.plist", exitCode: nil)])
        let info = try #require(try BrewServices.decode(Fixture.data("arm64-services-info")).first)
        #expect(info.serviceName == "sh.brew.php")
        #expect(info.running == false && info.loaded == false && info.registered == false)
        #expect(info.pid == nil)
        #expect(info.command == "/opt/homebrew/opt/php/sbin/php-fpm --nodaemonize")
        #expect(info.errorLogPath == "/opt/homebrew/var/log/php-fpm.log")
        #expect(info.logPath == nil)
        let merged = list[0].merging(info: info)
        #expect(merged.name == "php" && merged.serviceName == "sh.brew.php")
        #expect(BrewServices.actions(for: list[0]) == [.start])
    }

    @Test func vmHasNoneAndInfoAllPrintsNothing() throws {
        let vm = try BrewServices.decode(Fixture.data("sonoma-intelbrew-services-list"))
        let empty = try BrewServices.decode(Data())
        let newline = try BrewServices.decode(Data("\n".utf8))
        #expect(vm.isEmpty)
        // `brew services info --all --json` printed nothing at all on the VM.
        #expect(empty.isEmpty)
        #expect(newline.isEmpty)
    }

    @Test func everyStatusSymbol() throws {
        let json = """
        [{"name":"a","status":"started","user":"you","file":"/Users/you/Library/LaunchAgents/homebrew.mxcl.a.plist","exit_code":0},
         {"name":"b","status":"scheduled","user":"you","file":null,"exit_code":0},
         {"name":"c","status":"stopped","user":"you","file":null,"exit_code":0},
         {"name":"d","status":"error","user":"you","file":null,"exit_code":78},
         {"name":"e","status":"unknown","user":null,"file":null,"exit_code":null},
         {"name":"f","status":"other","user":null,"file":null,"exit_code":null},
         {"name":"g","status":"none","user":null,"file":null,"exit_code":null},
         {"name":"h","status":"launching","user":null,"file":null,"exit_code":null},
         {"name":"r","status":"started","user":"root","file":"/Library/LaunchDaemons/homebrew.mxcl.r.plist","exit_code":0}]
        """
        let s = try BrewServices.decode(Data(json.utf8))
        #expect(s.map(\.status) == [.started, .scheduled, .stopped, .error, .unknown, .other, .none, .unrecognized("launching"), .started])
        #expect(s[3].exitCode == 78)
        #expect(BrewServices.actions(for: s[0]) == [.stop, .restart])
        #expect(BrewServices.actions(for: s[3]) == [.stop, .restart])
        #expect(BrewServices.actions(for: s[6]) == [.start])
        #expect(!s[0].needsSudo(currentUser: "you"))
        #expect(s[8].needsSudo(currentUser: "you"))
        #expect(!s[6].needsSudo(currentUser: "you"))
        var daemon = s[6]
        daemon.file = "/Library/LaunchDaemons/homebrew.mxcl.g.plist"
        #expect(daemon.needsSudo(currentUser: "you"))
    }

    @Test func arguments() {
        #expect(BrewServices.listArguments == ["services", "list", "--json"])
        #expect(BrewServices.infoArguments("php") == ["services", "info", "--json", "php"])
        #expect(BrewServices.arguments(.restart, "php") == ["services", "restart", "php"])
    }
}
