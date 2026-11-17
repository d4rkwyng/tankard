import Foundation
import TankardCore

// v0.6 (part B): `brew bundle` in demo mode. Nothing is written or read:
// dump "succeeds", list prints the demo Mac's own packages, and check
// reports a fixed set of missing items (minus whatever the demo has since
// installed). The check lines are in brew 7.0.14's format (see
// V06BBrewfileTests). The pkg cask's `artifacts` entry is added here
// because the Discover cask fixture carries no artifacts;
// chrome-remote-desktop-host really does install with a pkg.

extension Demo {
    static func brewfileMissing(_ variant: Variant) -> [BrewfileEntry] {
        switch variant {
        case .arm64:
            return [BrewfileEntry(kind: .tap, name: "hashicorp/tap"),
                    BrewfileEntry(kind: .formula, name: "bit-git"),
                    BrewfileEntry(kind: .formula, name: "git-absorb"),
                    BrewfileEntry(kind: .formula, name: "jsontoolkit"),
                    BrewfileEntry(kind: .cask, name: "firefox"),
                    BrewfileEntry(kind: .cask, name: "chrome-remote-desktop-host")]
        case .intelbrew:
            return [BrewfileEntry(kind: .tap, name: "hashicorp/tap"),
                    BrewfileEntry(kind: .formula, name: "bit-git"),
                    BrewfileEntry(kind: .formula, name: "atomgit-cli"),
                    BrewfileEntry(kind: .formula, name: "cgit")]
        }
    }

    static let brewfilePkgCasks: Set<String> = ["chrome-remote-desktop-host"]

    /// nil: not a `brew bundle` call (or a cask `info` the plan asks for).
    static func brewfile(_ variant: Variant, state: State, info: Data, arguments: [String]) async throws -> ProcessResult? {
        func ok(_ s: String) -> ProcessResult { ProcessResult(exitCode: 0, stdout: Data(s.utf8), stderr: Data()) }
        if arguments.first == "info", arguments.contains("--cask"), arguments.contains(where: brewfilePkgCasks.contains) {
            var r = catalogInfo(variant, arguments: arguments)
            guard r.exitCode == 0, var root = (try? JSONSerialization.jsonObject(with: r.stdout)) as? [String: Any],
                  var casks = root["casks"] as? [[String: Any]] else { return r }
            for i in casks.indices where brewfilePkgCasks.contains(casks[i]["token"] as? String ?? "") {
                casks[i]["artifacts"] = [["pkg": ["Chrome Remote Desktop Host.pkg"]], ["uninstall": [["pkgutil": "com.google.pkg.ChromeRemoteDesktopHost"]]]]
            }
            root["casks"] = casks
            r.stdout = (try? JSONSerialization.data(withJSONObject: root)) ?? r.stdout
            return r
        }
        guard arguments.count >= 2, arguments[0] == "bundle" else { return nil }
        switch arguments[1] {
        case "dump":
            try await Task.sleep(for: .milliseconds(900))
            return ok("")
        case "list":
            let parsed = try? JSONDecoder().decode(BrewInfoJSON.self, from: state.info(variant, base: info))
            let formulae = parsed?.formulae.map(\.name) ?? [], casks = parsed?.casks.map(\.token) ?? []
            if arguments.contains("--tap") { return ok("") }
            if arguments.contains("--formula") { return ok(formulae.joined(separator: "\n") + "\n") }
            if arguments.contains("--cask") { return ok(casks.joined(separator: "\n") + "\n") }
            return ok((formulae + casks).joined(separator: "\n") + "\n")
        case "check":
            try await Task.sleep(for: .milliseconds(1200))
            let installed = state.installed.withLock { Set($0.keys) }
            let missing = brewfileMissing(variant).filter { !installed.contains($0.name) }
            if missing.isEmpty { return ok("The Brewfile's dependencies are satisfied.\n") }
            let lines = missing.map { e -> String in
                switch e.kind {
                case .tap: return "→ Tap \(e.name) needs to be tapped."
                case .cask: return "→ Cask \(e.name) needs to be installed."
                default: return "→ Formula \(e.name) needs to be installed."
                }
            }
            let out = "brew bundle can't satisfy your Brewfile's dependencies.\n" + lines.joined(separator: "\n")
                + "\nSatisfy missing dependencies with `brew bundle install`.\n"
            return ProcessResult(exitCode: 1, stdout: Data(out.utf8), stderr: Data())
        default:
            return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: not in the demo\n".utf8))
        }
    }
}
