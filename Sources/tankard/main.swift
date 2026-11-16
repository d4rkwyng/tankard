import Foundation
import TankardCore

let version = "0.1.0"

let usage = """
usage: tankard status [--json] [--filter upgrades|source|newer|nobottle|casks]
                      [--remote] [--timings] [--brew PATH]
       tankard --version

status    Installed formulae and casks, how each was installed, and what
          an upgrade would do. Read-only: never updates or installs.
--json    Machine-readable output (schema in README.md).
--filter  Show only one group (the summary still counts everything).
--remote  Ask the brew fork's remote for its newest tag (network) instead
          of using local tags.
--timings Print how long each step took.
--brew    Path to brew (default: TANKARD_BREW, else /opt/homebrew/bin/brew
          or /usr/local/bin/brew).
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args == ["-h"] || args == ["--help"] || args == ["help"] {
    print(usage)
    exit(args.isEmpty ? 2 : 0)
}
if args == ["--version"] {
    print("tankard \(version)")
    exit(0)
}
guard args.removeFirst() == "status" else { fail(usage, code: 2) }

var json = false
var filter: StatusFilter?
var remote = false
var timings = false
var brewOverride = ProcessInfo.processInfo.environment["TANKARD_BREW"]
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--json": json = true
    case "--remote": remote = true
    case "--timings": timings = true
    case "--filter":
        guard let v = args.first, let f = StatusFilter(rawValue: v.lowercased()) else {
            fail("--filter takes one of: \(StatusFilter.allCases.map(\.rawValue).joined(separator: ", "))", code: 2)
        }
        args.removeFirst()
        filter = f
    case "--brew":
        guard let v = args.first else { fail("--brew takes a path", code: 2) }
        args.removeFirst()
        brewOverride = v
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        fail("unknown option \(a)\n\n\(usage)", code: 2)
    }
}

do {
    let client = try BrewClient.locate(override: brewOverride)
    var report = try await client.status(checkRemote: remote)
    if json {
        if let filter {
            // Summary stays whole; only the package list is filtered.
            report.packages = report.packages.filter(filter.includes)
        }
        let data = try StatusReport.jsonEncoder().encode(report)
        FileHandle.standardOutput.write(data)
        print()
    } else {
        print(TextReport.render(report, filter: filter, showTimings: timings))
    }
} catch {
    fail("tankard: \(error)", code: 1)
}
