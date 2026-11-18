import Foundation
import Testing
@testable import TankardCore

// v0.8.4: brew's cask `installed_time` is the UTC wall clock of the
// metadata folder's name read back as local time (cask.rb install_time).
struct V084CaskInstallTimeTests {
    /// What brew does: the folder name (UTC wall clock) parsed in `zone`.
    func brewValue(_ folder: String, _ zone: String) -> Double {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = TimeZone(identifier: zone)!
        return f.date(from: folder)!.timeIntervalSince1970
    }

    func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func localDay(_ d: Date, _ zone: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// The real case on this Mac: folder 20261108204610.660, brew said 1794195970.
    @Test func realBrewValueInArizona() {
        let tz = TimeZone(identifier: "America/Phoenix")!
        #expect(brewValue("20261108204610", "America/Phoenix") == 1_794_195_970)
        #expect(CaskInstallTime.date(brewInstalledTime: 1_794_195_970, timeZone: tz) == utc("2026-11-08T20:46:10Z"))
    }

    /// An evening install in a negative-offset zone stays on its own day.
    @Test(arguments: [("America/Phoenix", "2026-11-18T02:15:00Z", "2026-11-17"),   // 19:15 MST
                      ("America/Phoenix", "2026-11-18T06:59:00Z", "2026-11-17"),   // 23:59
                      ("America/Phoenix", "2026-11-18T07:01:00Z", "2026-11-18"),   // 00:01
                      ("America/New_York", "2026-07-04T03:59:00Z", "2026-07-03"),  // 23:59 EDT
                      ("America/New_York", "2026-07-04T04:00:00Z", "2026-07-04"),  // midnight EDT
                      ("America/Los_Angeles", "2026-12-31T07:59:30Z", "2026-12-30"), // 23:59 PST
                      ("Europe/Berlin", "2026-11-17T23:30:00Z", "2026-11-18"),     // 00:30 CET
                      ("Asia/Tokyo", "2026-11-17T14:59:00Z", "2026-11-17")])       // 23:59 JST
    func aroundMidnight(zone: String, installed: String, day: String) {
        let tz = TimeZone(identifier: zone)!
        let real = utc(installed)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        let brew = brewValue(f.string(from: real), zone)
        let read = CaskInstallTime.date(brewInstalledTime: brew, timeZone: tz)
        #expect(read == real)
        #expect(localDay(read, zone) == day)
        // Taken as is (before 0.8.4), west of Greenwich it was the next day.
        if zone == "America/Phoenix" && day == "2026-11-17" {
            #expect(localDay(Date(timeIntervalSince1970: brew), zone) == "2026-11-18")
        }
        // The demo's inverse gives brew's value back.
        #expect(CaskInstallTime.brewInstalledTime(for: real, timeZone: tz) == brew)
    }

    /// Across the US fall-back (Nov 1 2026) and spring-forward changes.
    @Test(arguments: ["2026-11-01T07:30:00Z", "2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z",
                      "2026-03-08T08:30:00Z", "2026-03-08T09:30:00Z", "2026-03-08T10:30:00Z"])
    func daylightSavingChanges(installed: String) {
        let zone = "America/Denver"
        let real = utc(installed)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        let brew = brewValue(f.string(from: real), zone)
        #expect(CaskInstallTime.date(brewInstalledTime: brew, timeZone: TimeZone(identifier: zone)!) == real)
    }

    /// The classifier applies it to casks only.
    @Test func classifierCorrectsCasks() throws {
        let json = """
        [{"token": "maccy", "version": "2.6", "installed": "2.6", "installed_time": 1794195970}]
        """
        let cask = try #require(try JSONDecoder().decode([BrewInfoJSON.Cask].self, from: Data(json.utf8)).first)
        let c = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false,
                                 timeZone: TimeZone(identifier: "America/Phoenix")!)
        #expect(c.classify(cask: cask, outdated: false).installedAt == utc("2026-11-08T20:46:10Z"))
        let utcC = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false, timeZone: TimeZone(identifier: "UTC")!)
        #expect(utcC.classify(cask: cask, outdated: false).installedAt == Date(timeIntervalSince1970: 1_794_195_970))
    }
}
