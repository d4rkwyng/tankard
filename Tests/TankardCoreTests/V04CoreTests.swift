import Foundation
import Testing
@testable import TankardCore

// v0.4 (part B): brew vulns, brew info --sizes, caveats, --greedy casks.
// Fixtures captured read-only with brew 7.0.14: `*-vulns.json` is brew
// vulns --json stdout as printed (the arm64 Mac and the Intel VM);
// `arm64-vulns-stderr.txt` is what the same run printed on stderr.

struct VulnsJSONTests {
    @Test func arm64Capture() throws {
        let json = try BrewVulnsJSON.decode(stdout: try Fixture.data("arm64-vulns"))
        #expect(!json.complete)
        #expect(json.checked == 142)
        #expect(json.skippedFormulae.count == 60)
        #expect(json.unscannedFormulae == ["obsidian-cli": "untrusted_tap"])
        #expect(json.findings.count == 14)

        let scan = VulnerabilityScan(json: json, scannedAt: Date(timeIntervalSince1970: 0),
                                     stderr: try Fixture.text("arm64-vulns-stderr"))
        // openjpeg has only patched ones: not counted, as in brew's text output.
        #expect(scan.vulnerableCount == 13)
        #expect(scan.findings["openjpeg"] == nil)
        #expect(scan.patchedCount == 16)
        #expect(scan.warnings == ["Warning: 1 installed keg from an untrusted tap not scanned:"])
        // Most severe first.
        let gme = try #require(scan.findings["game-music-emu"])
        #expect(gme.map(\.severity) == [.high, .medium, .low, .unknown, .unknown])
        #expect(gme.first?.id == "CVE-2026-0017")
        #expect(scan.partialReason == "61 not checked: 60 with no source repository brew can match, 1 from an untrusted tap")
        let ssl = try #require(scan.findings["openssl@3"])
        #expect(ssl.count == 4)
        #expect(ssl.first?.fixText == "Fixed upstream in commit 7b4f534 (+2 more)")
        #expect(scan.versions["openssl@3"] == "3.5.9")
    }

    @Test func intelVMCapture() throws {
        let json = try BrewVulnsJSON.decode(stdout: try Fixture.data("sonoma-intelbrew-vulns"))
        let scan = VulnerabilityScan(json: json, scannedAt: Date())
        #expect(!scan.complete)
        #expect(scan.checked == 11)
        #expect(scan.skipped.count == 9) // 11 + 9 = the VM's 20 formulae
        #expect(scan.findings.keys.sorted() == ["expat", "openssl@4"])
        #expect(scan.findings["expat"]?.map(\.id) == ["CVE-2026-124317", "CVE-2026-128241"])
        #expect(scan.findings["expat"]?.first?.fixText == "No fix listed")
        #expect(scan.partialReason == "9 not checked: 9 with no source repository brew can match")
        #expect(scan.warnings.isEmpty)
    }

    /// Why only stdout is decoded: stderr's warning in front breaks the JSON.
    @Test func stderrMixedInBreaksTheJSON() throws {
        let mixed = Data(try Fixture.text("arm64-vulns-stderr").utf8) + (try Fixture.data("arm64-vulns"))
        #expect(throws: (any Error).self) { try BrewVulnsJSON.decode(stdout: mixed) }
    }

    @Test func clientReadsStdoutDespiteExitOneAndWarnings() async throws {
        let stdout = try Fixture.data("arm64-vulns")
        let stderr = try Fixture.data("arm64-vulns-stderr", ext: "txt")
        let runner = FakeRunner { _, _ in ProcessResult(exitCode: 1, stdout: stdout, stderr: stderr) }
        let client = BrewClient(installation: BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew"),
                                platform: .armGoldenGate, runner: runner, sources: EnvironmentSources(process: [:]))
        let scan = try await client.vulnerabilityScan(env: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
        #expect(scan.vulnerableCount == 13)
        #expect(runner.calls.map(\.arguments) == [["vulns", "--json"]])
        #expect(runner.calls.first?.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test func olderBrewWithoutVulnsIsUnsupported() async throws {
        let runner = FakeRunner { _, _ in
            ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: Unknown command: brew vulns\n".utf8))
        }
        let client = BrewClient(installation: BrewInstallation(brewPath: "/usr/local/bin/brew", prefix: "/usr/local", repository: "/usr/local/Homebrew"),
                                platform: .intelSonoma, runner: runner, sources: EnvironmentSources(process: [:]))
        await #expect(throws: InsightError.self) { try await client.vulnerabilityScan(env: [:]) }
        let garbage = FakeRunner { _, _ in ProcessResult(exitCode: 2, stdout: Data("oops".utf8), stderr: Data("Error: OSV API request failed".utf8)) }
        var c2 = client
        c2.runner = garbage
        await #expect(throws: BrewClientError.self) { try await c2.vulnerabilityScan(env: [:]) }
    }

    @Test func severityAndLinks() {
        #expect(VulnerabilitySeverity(brew: "HIGH") == .high)
        #expect(VulnerabilitySeverity(brew: "Moderate") == .medium)
        #expect(VulnerabilitySeverity(brew: nil) == .unknown)
        #expect(VulnerabilitySeverity.critical > .high && VulnerabilitySeverity.low > .unknown)
        #expect(VulnerabilitySeverity.unknown.label == "Unknown severity")
        #expect(VulnerabilitySeverity.medium.label == "Medium")
        let v = PackageVulnerability(id: "CVE-2026-88822", severity: .high, fixedIn: ["3.5.10", "7b4f5344aa0401e7b777640050b5257ed2a70e88"])
        #expect(v.url?.absoluteString == "https://osv.dev/vulnerability/CVE-2026-88822")
        #expect(v.fixText == "Fixed in 3.5.10")
        #expect(PackageVulnerability.isCommit("7b4f5344aa0401e7b777640050b5257ed2a70e88"))
        #expect(!PackageVulnerability.isCommit("2.10.1"))
        #expect(PackageVulnerability(id: "GHSA-x/y", severity: .low).url?.absoluteString == "https://osv.dev/vulnerability/GHSA-x%2Fy")
    }

    /// The scan applies only to formulae, and only while the installed
    /// version is the one brew checked.
    @Test func matchesInstalledFormulaVersion() throws {
        let scan = VulnerabilityScan(json: try BrewVulnsJSON.decode(stdout: try Fixture.data("sonoma-intelbrew-vulns")), scannedAt: Date())
        let packages = StatusClassifier(platform: .intelSonoma, intelbrewMode: true).classify(info: try Fixture.info("sonoma-intelbrew-info"))
        var ssl = try #require(packages["openssl@4"])
        #expect(scan.vulnerabilities(for: ssl)?.count == 4)
        ssl.installedVersion = "4.1.1"   // upgraded since the scan
        #expect(scan.vulnerabilities(for: ssl) == nil)
        ssl.installedVersion = "4.1.0_1" // a revision bump: same upstream version
        #expect(scan.vulnerabilities(for: ssl)?.count == 4)
        ssl.kind = .cask
        #expect(scan.vulnerabilities(for: ssl) == nil)
        #expect(scan.vulnerabilities(for: try #require(packages["xz"])) == nil)
    }
}

struct DiskSizesTests {
    @Test func intelVMCapture() throws {
        let s = DiskSizes.parse(try Fixture.text("sonoma-intelbrew-sizes"))
        #expect(s.formulae.count == 20)
        #expect(s.casks.isEmpty)
        #expect(s.formulae["python@3.15"] == 77_300_000)
        #expect(s.formulae["gettext"] == 34_000_000)
        #expect(s.formulae["lua"] == 867_100)
        #expect(s.formulaeTotal == 289_100_000)
        // brew rounds each row: the rows add up to the total within 0.05 MB a row.
        let sum = s.formulae.values.reduce(0, +)
        #expect(abs(sum - 289_100_000) < 20 * 50_000)
        // Every installed formula of the same VM has a size.
        let packages = StatusClassifier(platform: .intelSonoma, intelbrewMode: true).classify(info: try Fixture.info("sonoma-intelbrew-info"))
        #expect(packages.allSatisfy { s.bytes(for: $0) != nil })
    }

    @Test func arm64CaptureWithCasks() throws {
        let s = DiskSizes.parse(try Fixture.text("arm64-sizes"))
        #expect(s.formulae.count == 9)
        #expect(s.casks.count == 5)
        #expect(s.casks["visual-studio-code"] == 1_000_000_000)
        #expect(s.casks["lm-studio"] == 1_200_000_000)
        #expect(s.formulae["pkgconf"] == 752_000)
        #expect(s.casksTotal == 3_200_000_000)
        let packages = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false).classify(info: try Fixture.info("arm64-api-info"))
        #expect(s.bytes(for: try #require(packages["iterm2"])) == 207_400_000)
        #expect(packages.allSatisfy { s.bytes(for: $0) != nil })
    }

    @Test func unitsAndFormat() {
        #expect(DiskSizes.bytes("512B") == 512)
        #expect(DiskSizes.bytes("1.2GB") == 1_200_000_000)
        #expect(DiskSizes.bytes("12 apples") == nil)
        #expect(DiskSizes.format(867_100) == "867.1 KB")
        #expect(DiskSizes.format(34_000_000) == "34 MB")
        #expect(DiskSizes.format(999_960) == "1 MB")
        #expect(DiskSizes.format(512) == "512 B")
        #expect(DiskSizes.format(3_210_000_000) == "3.2 GB")
        #expect(DiskSizes.parse("==> Formulae sizes:\nTotal 0B\n").formulae.isEmpty)
    }

    @Test func clientRunsBrewInfoSizes() async throws {
        let text = try Fixture.text("sonoma-intelbrew-sizes")
        let runner = FakeRunner { _, _ in ok(text) }
        let client = BrewClient(installation: BrewInstallation(brewPath: "/usr/local/bin/brew", prefix: "/usr/local", repository: "/usr/local/Homebrew"),
                                platform: .intelSonoma, runner: runner, sources: EnvironmentSources(process: [:]))
        let s = try await client.diskSizes(env: [:])
        #expect(s.formulae.count == 20)
        #expect(runner.calls.map(\.arguments) == [["info", "--sizes"]])
    }
}

struct CaveatsTests {
    @Test func caveatsFromBothCaptures() throws {
        let intel = StatusClassifier(platform: .intelSonoma, intelbrewMode: true).classify(info: try Fixture.info("sonoma-intelbrew-info"))
        #expect(intel.filter { $0.caveats != nil }.map(\.name).sorted() == ["lua", "openssl@4", "python@3.15", "ruby", "vim"])
        #expect(intel["python@3.15"]?.caveats?.contains("$HOMEBREW_PREFIX/bin/python3") == true)
        let arm = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false).classify(info: try Fixture.info("arm64-api-info"))
        #expect(arm.filter { $0.caveats != nil }.map(\.name).sorted() == ["cmake", "openssl@3", "python@3.14", "tailscale-app"])
        #expect(arm["tailscale-app"]?.caveats?.hasPrefix("tailscale-app requires a kernel extension") == true)
    }

    @Test func emptyCaveatsAreNone() throws {
        let json = #"{"formulae":[{"name":"a","versions":{"stable":"1"},"caveats":"  \n"}],"casks":[{"token":"b","version":"1","caveats":null}]}"#
        let info = try JSONDecoder().decode(BrewInfoJSON.self, from: Data(json.utf8))
        #expect(info.formulae[0].caveats == nil)
        #expect(info.casks[0].caveats == nil)
    }

    @Test func reportJSONOmitsUnsetFields() throws {
        let p = Package.command("x")
        let text = String(decoding: try StatusReport.jsonEncoder().encode(p), as: UTF8.self)
        for key in ["caveats", "diskBytes", "vulnerabilities", "selfUpdatingUpgrade"] { #expect(!text.contains(key)) }
    }
}

struct SelfUpdatingCaskTests {
    func armReport() throws -> StatusReport {
        let packages = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false).classify(info: try Fixture.info("arm64-api-info"))
        return StatusReport(generatedAt: Date(), host: HostInfo(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew",
                                                                platform: .armGoldenGate, bottleTag: "arm64_golden_gate"),
                            intelbrew: IntelbrewDetection(detected: false, reasons: [], env: [:], found: [:]),
                            fork: ForkStatus(brewRepository: "/opt/homebrew"), packages: packages)
    }

    /// The arm64 capture: `--greedy` adds tailscale-app (auto_updates, not
    /// outdated by brew's own flag); Chrome and VS Code were outdated already.
    @Test func greedyAddsSelfUpdatingCasks() throws {
        let report = try armReport()
        let greedy = try Fixture.outdated("arm64-outdated-greedy")
        #expect(greedy.casks.map(\.name) == ["google-chrome", "tailscale-app", "visual-studio-code"])
        let before = report.summary.caskUpgrades
        let marked = SelfUpdatingCasks.mark(report, greedy: greedy)
        let ts = try #require(marked.packages["tailscale-app"])
        #expect(ts.upgradeAvailable)
        #expect(ts.selfUpdatingUpgrade == true)
        #expect(ts.currentVersion == "1.104.7")
        #expect(marked.packages["google-chrome"]?.selfUpdatingUpgrade == nil)
        #expect(marked.summary.caskUpgrades == before + 1)
        let unmarked = SelfUpdatingCasks.unmark(marked)
        #expect(unmarked.packages["tailscale-app"]?.upgradeAvailable == false)
        #expect(unmarked.summary.caskUpgrades == before)
        #expect(SelfUpdatingCasks.unmark(report).summary == report.summary)
    }

    @Test func newerCaskIsNotAnUpgrade() throws {
        let packages = StatusClassifier(platform: .intelSonoma, intelbrewMode: true).classify(info: try Fixture.info("synthetic-intel-info"))
        let newer = try #require(packages["newer-cask"])
        #expect(newer.status == .newer)
        var report = try armReport()
        report.packages = [newer]
        let greedy = try JSONDecoder().decode(BrewOutdatedJSON.self, from: Data(#"{"casks":[{"name":"newer-cask","installed_versions":["2.1"],"current_version":"2.0"}]}"#.utf8))
        #expect(SelfUpdatingCasks.mark(report, greedy: greedy).packages[0].upgradeAvailable == false)
    }

    @Test func clientAsksForCasksOnly() async throws {
        let data = try Fixture.data("arm64-outdated-greedy")
        let runner = FakeRunner { _, _ in ok(data) }
        let client = BrewClient(installation: BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew"),
                                platform: .armGoldenGate, runner: runner, sources: EnvironmentSources(process: [:]))
        let out = try await client.greedyOutdatedCasks(env: [:])
        #expect(out.casks.count == 3)
        #expect(runner.calls.map(\.arguments) == [["outdated", "--greedy", "--cask", "--json=v2"]])
    }
}

extension Fixture {
    static func data(_ name: String, ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }
}
