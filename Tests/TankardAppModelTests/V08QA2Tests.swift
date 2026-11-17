import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8 QA round 2: the e2e harness's isolation, and the sheet waiting behind
// a background `brew update`.

struct APICacheRedirectTests {
    @Test func aScriptedRunKeepsDiscoversCacheInItsStateFolder() {
        let real = APICache.defaultDirectory
        #expect(real.path.hasSuffix("/Library/Caches/net.mindtricks.tankard/api"))
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-e2e-state/api", isDirectory: true)
        APICache.redirect(to: state)
        defer { APICache.redirect(to: nil) }
        #expect(APICache.defaultDirectory == state)
        // Discover's and Adopt Apps' fetchers use the default directory.
        #expect(APIFetcher().cache.directory == state)
    }
}

struct ScriptProcessCheckTests {
    /// `expect no-process` counts only the app's own descendants: another
    /// run's (or the user's) `brew vulns` isn't this run's leftover.
    @Test func onlyThisAppsDescendantsCount() {
        let ps = """
              1     0 /sbin/launchd
            100     1 /Applications/Tankard.app/Contents/MacOS/Tankard
            110   100 /bin/bash /opt/homebrew/bin/brew vulns --json
            111   110 /opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby brew.rb vulns --json
            200     1 /other/worktree/dist/Tankard.app/Contents/MacOS/Tankard
            210   200 /bin/bash /opt/homebrew/bin/brew vulns --json
            300     1 /bin/bash /opt/homebrew/bin/brew vulns --json
            120   100 /bin/ps -axww -o pid=,ppid=,command=
            """
        let mine = ScriptContext.processes(matching: " vulns --json", psOutput: ps, root: 100)
        #expect(mine.map { $0.split(separator: " ").first.map(String.init) ?? "" }.sorted() == ["110", "111"])
        #expect(ScriptContext.processes(matching: " vulns --json", psOutput: ps, root: 100, excluding: [111]).count == 1)
        #expect(ScriptContext.processes(matching: "-axww", psOutput: ps, root: 100, excluding: [120]).isEmpty)
        #expect(ScriptContext.processes(matching: " vulns --json", psOutput: ps, root: 999).isEmpty)
    }
}
