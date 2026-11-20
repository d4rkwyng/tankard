import Foundation
import Testing
@testable import TankardCore

// 0.8.10: when Adopt Apps offers "Replace with Homebrew's Version": only
// for a version mismatch (brew's --adopt refuses) where the cask's version
// is newer by brew's ordering. Never a downgrade, never equal versions,
// never versions without a number.

struct V0810AdoptReplaceTests {
    @Test func newerCaskIsOffered() {
        #expect(AdoptReplace.eligibility(installed: "3.2.6", cask: "3.2.8") == .update(installed: "3.2.6", cask: "3.2.8"))
        // Numbers compare as numbers, not text.
        #expect(AdoptReplace.eligibility(installed: "1.2.9", cask: "1.2.10") == .update(installed: "1.2.9", cask: "1.2.10"))
        // A pre-release to its release.
        #expect(AdoptReplace.eligibility(installed: "2.0-beta1", cask: "2.0") == .update(installed: "2.0-beta1", cask: "2.0"))
    }

    @Test func olderCaskIsNeverOffered() {
        #expect(AdoptReplace.eligibility(installed: "2.0", cask: "1.9") == .notNewer)
        #expect(AdoptReplace.eligibility(installed: "1.2.10", cask: "1.2.9") == .notNewer)
        // A release back to its own pre-release is a downgrade too.
        #expect(AdoptReplace.eligibility(installed: "2.0", cask: "2.0-beta1") == .notNewer)
    }

    @Test func equalVersionsAreNotOffered() {
        #expect(AdoptReplace.eligibility(installed: "1.4", cask: "1.4") == .notNewer)
        // brew's --adopt compares the strings (so it refuses), but by brew's
        // ordering they are the same version: nothing to update.
        #expect(AdoptReplace.eligibility(installed: "1.0", cask: "1.0.0") == .notNewer)
        #expect(AdoptReplace.eligibility(installed: " 1.4", cask: "1.4 ") == .notNewer)
    }

    @Test func unparseableVersionsAreNotOffered() {
        #expect(AdoptReplace.eligibility(installed: "1.0", cask: "latest") == .unparseable)
        #expect(AdoptReplace.eligibility(installed: "1.0", cask: "LATEST") == .unparseable)
        #expect(AdoptReplace.eligibility(installed: "", cask: "1.0") == .unparseable)
        #expect(AdoptReplace.eligibility(installed: "unknown", cask: "2.0") == .unparseable)
        #expect(AdoptReplace.eligibility(installed: "1.0", cask: "stable") == .unparseable)
        #expect(AdoptReplace.eligibility(installed: "HEAD-abc123", cask: "2.0") == .unparseable)
    }

    @Test func onlyAVersionMismatchCounts() {
        #expect(AdoptReplace.eligibility(nil) == .notVersionMismatch)
        #expect(AdoptReplace.eligibility(.ready) == .notVersionMismatch)
        #expect(AdoptReplace.eligibility(.readyUnchecked) == .notVersionMismatch)
        #expect(AdoptReplace.eligibility(.blocked(.pkg)) == .notVersionMismatch)
        #expect(AdoptReplace.eligibility(.blocked(.noVersion)) == .notVersionMismatch)
        #expect(AdoptReplace.eligibility(.needsUpdate(installed: "1.0", cask: "1.1")) == .update(installed: "1.0", cask: "1.1"))
        #expect(AdoptReplace.eligibility(.needsUpdate(installed: "1.1", cask: "1.0")) == .notNewer)
    }

    /// Through the matcher's own verdict: `latest`, self-updating casks and
    /// a cask version with a build part after the comma.
    @Test func throughTheVerdict() {
        let app = InstalledApp(path: "/Applications/Foo.app", root: "/Applications", relativePath: "Foo.app",
                               bundleID: "com.foo.Foo", shortVersion: "1.4", bundleVersion: "140")
        func e(_ v: String, autoUpdates: Bool = false) -> AdoptReplace.Eligibility {
            AdoptReplace.eligibility(AdoptVersion.verdict(app: app, caskVersion: v, autoUpdates: autoUpdates))
        }
        // `latest`: brew compares after downloading, so it isn't a mismatch.
        #expect(e("latest") == .notVersionMismatch)
        // auto_updates: brew adopts any version.
        #expect(e("1.5", autoUpdates: true) == .notVersionMismatch)
        // "1.5,151": the part before the comma is what counts.
        #expect(e("1.5,151") == .update(installed: "1.4", cask: "1.5"))
        #expect(e("1.3,130") == .notNewer)
        // The build number matching the cask's version: adoptable as it is.
        #expect(e("140") == .notVersionMismatch)
    }
}
