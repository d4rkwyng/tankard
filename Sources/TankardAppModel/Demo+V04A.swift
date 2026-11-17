import Foundation
import os
import TankardCore

// v0.4 (part A) in demo mode: pins and services, with nothing spawned.

extension Demo {
    /// What the demo's pin and service commands have changed.
    final class V04AState: Sendable {
        /// Short names pinned now (`TANKARD_DEMO_PINNED` seeds it).
        let pinned: OSAllocatedUnfairLock<Set<String>>
        /// Service name → status after a demo start/stop/restart.
        let serviceStatus = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

        init(pinned: Set<String> = []) {
            self.pinned = OSAllocatedUnfairLock(initialState: pinned)
        }
    }

    /// The demo's shell profile for "Revert to standard Homebrew…": the
    /// three lines the Intelbrew installer writes, among others.
    public static func demoProfile(_ path: String) -> String? {
        guard path.hasSuffix("/.zshenv") else { return nil }
        return """
        # ~/.zshenv
        export PATH="$HOME/bin:$PATH"
        export HOMEBREW_NO_INSTALL_FROM_API=1
        export HOMEBREW_CORE_GIT_REMOTE=https://github.com/d4rkwyng/intelbrew-core
        export HOMEBREW_BREW_GIT_REMOTE=https://github.com/d4rkwyng/brew

        """
    }

    /// The full receipts' runtime dependencies (with `declared_directly`)
    /// from the same VM, captured again for 0.4 (`sonoma-intelbrew-deps-info`):
    /// the original demo fixture was trimmed to one dependency each.
    static func vmReceipts() -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: fixtureData("sonoma-intelbrew-deps-info"))) as? [String: Any],
              let list = root["formulae"] as? [[String: Any]] else { return [:] }
        var out: [String: Any] = [:]
        for f in list {
            if let name = f["name"] as? String, let deps = (f["installed"] as? [[String: Any]])?.first?["runtime_dependencies"] {
                out[name] = deps
            }
        }
        return out
    }

    /// Sets `pinned` in the demo's `brew info` JSON and, for the Intel demo,
    /// the full receipt dependencies.
    static func applyPins(_ data: Data, pinned: Set<String>, variant: Variant = .arm64) -> Data {
        guard !pinned.isEmpty || variant == .intelbrew,
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        if variant == .intelbrew, var list = root["formulae"] as? [[String: Any]] {
            let vmReceipts = vmReceipts()
            for i in list.indices {
                guard let name = list[i]["name"] as? String, let deps = vmReceipts[name],
                      var kegs = list[i]["installed"] as? [[String: Any]], !kegs.isEmpty else { continue }
                kegs[0]["runtime_dependencies"] = deps
                list[i]["installed"] = kegs
            }
            root["formulae"] = list
        }
        for key in ["formulae", "casks"] {
            guard var list = root[key] as? [[String: Any]] else { continue }
            for i in list.indices {
                let name = (list[i]["name"] as? String) ?? ""
                let token = (list[i]["token"] as? String) ?? ""
                list[i]["pinned"] = pinned.contains(key == "casks" ? token : name)
            }
            root[key] = list
        }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    /// The demo's `brew services list --json`: an illustrative list (one
    /// running, one failed, one not loaded, one started as root), shaped
    /// like real brew 7.0.14 output. Real captures are in the test
    /// fixtures; the Intel VM has no services at all.
    static func servicesJSON(_ variant: Variant, state: V04AState, info: Bool, name: String? = nil) -> Data {
        let prefix = variant == .intelbrew ? "/usr/local" : "/opt/homebrew"
        let home = variant == .intelbrew ? "/Users/demo" : "/Users/you"
        let user = variant == .intelbrew ? "demo" : "you"
        let overrides = state.serviceStatus.withLock { $0 }
        var rows: [[String: Any]] = [
            ["name": "postgresql@18", "status": "started", "user": user,
             "file": "\(home)/Library/LaunchAgents/homebrew.mxcl.postgresql@18.plist", "exit_code": 0,
             "pid": 412, "log_path": "\(prefix)/var/log/postgresql@18.log",
             "command": "\(prefix)/opt/postgresql@18/bin/postgres -D \(prefix)/var/postgresql@18"],
            ["name": "redis", "status": "none", "user": NSNull(),
             "file": "\(prefix)/opt/redis/homebrew.mxcl.redis.plist", "exit_code": NSNull(),
             "log_path": "\(prefix)/var/log/redis.log", "command": "\(prefix)/opt/redis/bin/redis-server \(prefix)/etc/redis.conf"],
            ["name": "syncthing", "status": "error", "user": user,
             "file": "\(home)/Library/LaunchAgents/homebrew.mxcl.syncthing.plist", "exit_code": 78,
             "log_path": "\(prefix)/var/log/syncthing.log", "command": "\(prefix)/opt/syncthing/bin/syncthing serve --no-browser"],
            ["name": "unbound", "status": "started", "user": "root",
             "file": "/Library/LaunchDaemons/homebrew.mxcl.unbound.plist", "exit_code": 0,
             "command": "\(prefix)/opt/unbound/sbin/unbound -d -c \(prefix)/etc/unbound/unbound.conf"],
        ]
        for i in rows.indices {
            let n = rows[i]["name"] as? String ?? ""
            guard let s = overrides[n] else { continue }
            rows[i]["status"] = s
            if s == "started" {
                rows[i]["user"] = user
                rows[i]["exit_code"] = 0
                rows[i]["file"] = "\(home)/Library/LaunchAgents/homebrew.mxcl.\(n).plist"
            } else if s == "none" {
                rows[i]["user"] = NSNull()
                rows[i]["exit_code"] = NSNull()
                rows[i]["file"] = "\(prefix)/opt/\(n)/homebrew.mxcl.\(n).plist"
            }
        }
        if let name { rows = rows.filter { $0["name"] as? String == name } }
        if !info {
            rows = rows.map { r in r.filter { ["name", "status", "user", "file", "exit_code"].contains($0.key) } }
        } else {
            rows = rows.map { r in
                var r = r
                let s = r["status"] as? String
                r["service_name"] = "homebrew.mxcl.\(r["name"] as? String ?? "")"
                r["running"] = s == "started"
                r["loaded"] = s != "none"
                r["registered"] = s != "none"
                if s != "started" { r["pid"] = NSNull() }
                return r
            }
        }
        return (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
    }

    /// Reads for v0.4a commands (`brew services list|info`), or nil.
    static func v04aRead(_ variant: Variant, state: State, arguments: [String]) -> ProcessResult? {
        guard arguments.first == "services" else { return nil }
        if arguments == BrewServices.listArguments {
            return ProcessResult(exitCode: 0, stdout: servicesJSON(variant, state: state.v04a, info: false), stderr: Data())
        }
        if arguments.count == 5, arguments[1] == "info", arguments[2] == "--json", arguments[3] == "--" {
            return ProcessResult(exitCode: 0, stdout: servicesJSON(variant, state: state.v04a, info: true, name: arguments[4]), stderr: Data())
        }
        return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: unknown demo command\n".utf8))
    }

    /// Queued v0.4a commands (pin, unpin, services start/stop/restart), or nil.
    static func v04aStream(_ variant: Variant, state: State, arguments: [String],
                           say: (String, Double) async throws -> Void) async throws -> Int32? {
        switch arguments.first {
        case "pin", "unpin":
            guard let qualified = arguments.last else { return 1 }
            let name = qualified.split(separator: "/").last.map(String.init) ?? qualified
            let pin = arguments.first == "pin"
            try await say("", 300) // brew pin prints nothing when it works
            state.v04a.pinned.withLock { if pin { $0.insert(name) } else { $0.remove(name) } }
            return 0
        case "services":
            guard arguments.count == 4, let action = ServiceAction(rawValue: arguments[1]), arguments[2] == "--" else { return nil }
            let name = arguments[3]
            if name == "unbound" {
                // As brew 7.0.14 says it (services/cli.rb) for a root service.
                try await say("Error: Service `unbound` is started as `root`. Try:\n  sudo brew services \(action.rawValue) unbound\n", 300)
                return 1
            }
            switch action {
            case .start, .restart:
                if action == .restart { try await say("Stopping `\(name)`... (might take a while)\n", 400) }
                try await say("==> Successfully started `\(name)` (label: homebrew.mxcl.\(name))\n", 500)
                state.v04a.serviceStatus.withLock { $0[name] = "started" }
            case .stop:
                try await say("Stopping `\(name)`... (might take a while)\n", 500)
                try await say("==> Successfully stopped `\(name)` (label: homebrew.mxcl.\(name))\n", 200)
                state.v04a.serviceStatus.withLock { $0[name] = "none" }
            }
            return 0
        default:
            return nil
        }
    }
}
