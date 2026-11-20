import Foundation
import TankardCore

// v0.8 demo: Adopt Apps. demo-adopt.json holds a few casks copied from
// formulae.brew.sh's cask.json (2026-11-17) and an illustrative set of apps
// (no real Mac's /Applications): one of each group, an app with two casks,
// a name-only match, a pkg cask, a suite, an app in ~/Applications, an App
// Store app, an Apple app and an app Homebrew already owns. Adopting is
// scripted and adds the cask to the demo's installed list.

extension Demo {
    struct AdoptFixture: Decodable {
        var apps: [InstalledApp]
    }

    /// The fixture's casks as raw JSON (for the demo's installed list).
    static func adoptCaskJSON(_ token: String) -> Data? {
        let root = (try? JSONSerialization.jsonObject(with: fixtureData("demo-adopt"))) as? [String: Any]
        guard let e = (root?["casks"] as? [[String: Any]])?.first(where: { $0["token"] as? String == token }) else { return nil }
        return try? JSONSerialization.data(withJSONObject: e)
    }

    static let adoptLoader: AdoptLoader = { @Sendable in
        try await Task.sleep(for: .milliseconds(300))
        let data = fixtureData("demo-adopt")
        struct Casks: Decodable { var casks: [BrewInfoJSON.Cask] }
        let casks = try JSONDecoder().decode(Casks.self, from: data).casks
        let apps = try JSONDecoder().decode(AdoptFixture.self, from: data).apps
        let index = AdoptIndex(casks: casks.map(AdoptCask.init))
        return AdoptInput(index: index, apps: apps, source: String(localized: "Demo · \(index.count.formatted()) casks"))
    }

    /// `brew install --cask --adopt <token>`, scripted. 0.8.10: and
    /// `--force` (Replace with Homebrew's Version).
    static func adoptStream(state: State, arguments: [String], say: (String, Double) async throws -> Void) async throws -> Int32? {
        guard arguments.count == 4, Array(arguments.prefix(2)) == ["install", "--cask"],
              arguments[2] == "--adopt" || arguments[2] == "--force", let qualified = arguments.last else { return nil }
        let replacing = arguments[2] == "--force"
        let token = qualified.split(separator: "/").last.map(String.init) ?? qualified
        guard let json = adoptCaskJSON(token) ?? catalogJSON(.arm64, kind: .cask, name: token),
              let e = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            try await say("Error: Cask '\(qualified)' is unavailable: No Cask with this name exists.\n", 200)
            return 1
        }
        let version = e["version"] as? String ?? "?"
        let target = ((e["artifacts"] as? [[String: Any]])?.first { $0["app"] != nil }?["target"] as? String) ?? "/Applications/\(token).app"
        try await say("==> Downloading \(token) \(version)\n", 300)
        try await say("==> Installing Cask \(token)\n", 400)
        if replacing {
            try await say("Warning: It seems there is already an App at '\(target)'; overwriting.\n", 300)
            try await say("==> Removing App '\(target)'\n", 300)
            try await say("==> Moving App '\((target as NSString).lastPathComponent)' to '\(target)'\n", 500)
        } else {
            try await say("==> Adopting existing App at '\(target)'\n", 500)
        }
        try await say("🍺  \(token) was successfully installed!\n", 300)
        state.removed.withLock { _ = $0.remove(token) }
        state.installed.withLock { $0[token] = (.cask, json) }
        return 0
    }
}
