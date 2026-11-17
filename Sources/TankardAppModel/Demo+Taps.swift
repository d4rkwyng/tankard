import Foundation
import os
import TankardCore

// v0.7 demo: the Taps sheet. arm64 is `brew tap-info --installed --json` as
// captured read-only on the arm64 Mac (core and cask name lists trimmed);
// the Intelbrew demo is derived from it, illustratively: homebrew/core
// tapped from the Intelbrew fork (every demo package comes from it, so
// Remove is blocked), no cask tap, and Tankard's own cask tap. tap, untap,
// trust and untrust are scripted and change only this state.

final class TapsDemoState: Sendable {
    let added = OSAllocatedUnfairLock<[String: String?]>(initialState: [:])
    let removed = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    let trust = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])
}

extension Demo {
    static func tapList(_ variant: Variant, state: TapsDemoState) -> Data {
        var list = (try? JSONSerialization.jsonObject(with: fixtureData("arm64-tap-info"))) as? [[String: Any]] ?? []
        if variant == .intelbrew {
            list.removeAll { ($0["name"] as? String) == "homebrew/cask" || ($0["name"] as? String) == "mull-project/mull"
                || ($0["name"] as? String) == "steipete/tap" }
            for i in list.indices where list[i]["name"] as? String == "homebrew/core" {
                list[i]["installed"] = true
                list[i]["remote"] = Intelbrew.coreRemote
                list[i]["custom_remote"] = true
                list[i]["last_commit"] = "3 hours ago"
                list[i]["branch"] = "main"
            }
            list.append(["name": "d4rkwyng/tap", "user": "d4rkwyng", "repo": "tap", "installed": true, "official": false,
                         "trusted": false, "formula_names": [String](), "cask_tokens": ["d4rkwyng/tap/tankard"],
                         "remote": "https://github.com/d4rkwyng/homebrew-tap", "custom_remote": false, "private": false,
                         "last_commit": "2 days ago", "branch": "main"])
        }
        let removed = state.removed.withLock { $0 }
        list.removeAll { removed.contains(($0["name"] as? String ?? "").lowercased()) }
        for (name, url) in state.added.withLock({ $0 }).sorted(by: { $0.key < $1.key }) {
            list.append(["name": name, "installed": true, "official": false, "trusted": false,
                         "formula_names": ["\(name)/hello"], "cask_tokens": [String](),
                         "remote": url ?? TapInput.defaultRemote(name) ?? "", "custom_remote": url != nil,
                         "private": false, "last_commit": "1 minute ago", "branch": "main"])
        }
        let trust = state.trust.withLock { $0 }
        for i in list.indices {
            if let t = trust[(list[i]["name"] as? String ?? "").lowercased()] { list[i]["trusted"] = t }
        }
        return (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted])) ?? Data("[]".utf8)
    }

    static func tapsRead(_ variant: Variant, state: TapsDemoState, arguments: [String]) async throws -> ProcessResult? {
        guard arguments == TapCommands.infoArguments else { return nil }
        try await Task.sleep(for: .milliseconds(400))
        return ProcessResult(exitCode: 0, stdout: tapList(variant, state: state), stderr: Data())
    }

    /// `brew tap`, `untap`, `trust --tap`, `untrust --tap`, scripted.
    static func tapsStream(_ variant: Variant, state: TapsDemoState, arguments: [String],
                           say: (String, Double) async throws -> Void) async throws -> Int32? {
        guard let verb = arguments.first, ["tap", "untap", "trust", "untrust"].contains(verb), arguments.count >= 2 else { return nil }
        let prefix = variant == .intelbrew ? "/usr/local" : "/opt/homebrew"
        switch verb {
        case "tap":
            let name = arguments[1]
            let parts = name.split(separator: "/")
            let dir = "\(prefix)/Library/Taps/\(parts.first ?? "")/homebrew-\(parts.last ?? "")"
            try await say("==> Tapping \(name)\n", 300)
            try await say("Cloning into '\(dir)'...\n", 900)
            try await say("Tapped 1 formula (14 files, 18.2KB).\n", 100)
            state.added.withLock { $0[name.lowercased()] = arguments.count > 2 ? arguments[2] : nil }
            state.removed.withLock { _ = $0.remove(name.lowercased()) }
            return 0
        case "untap":
            let name = arguments[1]
            try await say("Untapping \(name)...\n", 600)
            try await say("Untapped 1 cask (31 files, 52.4KB).\n", 100)
            state.removed.withLock { _ = $0.insert(name.lowercased()) }
            state.added.withLock { _ = $0.removeValue(forKey: name.lowercased()) }
            return 0
        default:
            guard let name = arguments.last else { return 1 }
            state.trust.withLock { $0[name.lowercased()] = verb == "trust" }
            return 0
        }
    }
}
