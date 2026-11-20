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

    // 0.8.10 fix: a cask whose version is the app's build number.

    /// short 2.0, build 200, cask 199: "199" is newer than "2.0" by brew's
    /// ordering, but older than the build. Not offered.
    @Test func buildNumberCaskIsNotADowngradeOffer() {
        #expect(AdoptReplace.eligibility(installed: "2.0", cask: "199", bundleVersion: "200") == .cantTell)
        let app = InstalledApp(path: "/Applications/Foo.app", root: "/Applications", relativePath: "Foo.app",
                               bundleID: "com.foo.Foo", shortVersion: "2.0", bundleVersion: "200")
        let v = AdoptVersion.verdict(app: app, caskVersion: "199", autoUpdates: false)
        #expect(v == .needsUpdate(installed: "2.0", cask: "199"))
        #expect(AdoptReplace.eligibility(v, bundleVersion: app.bundleVersion) == .cantTell)
        // Newer than both short version and build: still can't tell (a
        // bare build number against a dotted version).
        #expect(AdoptReplace.eligibility(installed: "2.0", cask: "201", bundleVersion: "200") == .cantTell)
        #expect(AdoptReplace.eligibility(installed: "2.0", cask: "199") == .cantTell)
        // The other way round: a dotted cask version against an app whose
        // short version is a bare number.
        #expect(AdoptReplace.eligibility(installed: "2", cask: "2.1") == .cantTell)
        // Dotted build newer than the cask: can't tell.
        #expect(AdoptReplace.eligibility(installed: "1.4", cask: "1.5", bundleVersion: "1.6.2") == .cantTell)
        // Bare build numbers on both sides: compared.
        #expect(AdoptReplace.eligibility(installed: "199", cask: "198", bundleVersion: "199") == .notNewer)
        #expect(AdoptReplace.eligibility(installed: "199", cask: "200", bundleVersion: "199") == .update(installed: "199", cask: "200"))
    }

    /// The usual case stays offered, with whatever build number the app has.
    @Test func normalUpdatesAreStillOffered() {
        // Hidden Bar: short 1.13.1, build 15 (a bare number: not comparable
        // with "1.13.2", so not in the way).
        #expect(AdoptReplace.eligibility(installed: "1.13.1", cask: "1.13.2", bundleVersion: "15") == .update(installed: "1.13.1", cask: "1.13.2"))
        #expect(AdoptReplace.eligibility(installed: "1.13.1", cask: "1.13.2", bundleVersion: "1.13.1") == .update(installed: "1.13.1", cask: "1.13.2"))
        #expect(AdoptReplace.eligibility(installed: "1.13.1", cask: "1.13.2", bundleVersion: nil) == .update(installed: "1.13.1", cask: "1.13.2"))
        #expect(AdoptReplace.eligibility(installed: "1.13.1", cask: "1.13.2", bundleVersion: "") == .update(installed: "1.13.1", cask: "1.13.2"))
        #expect(AdoptReplace.eligibility(installed: "3.2.6", cask: "3.2.8", bundleVersion: "3.2.6.1") == .update(installed: "3.2.6", cask: "3.2.8"))
        let app = InstalledApp(path: "/Applications/Hidden Bar.app", root: "/Applications", relativePath: "Hidden Bar.app",
                               bundleID: "com.dwarvesv.minimalbar", shortVersion: "1.13.1", bundleVersion: "15")
        let v = AdoptVersion.verdict(app: app, caskVersion: "1.13.2", autoUpdates: false)
        #expect(AdoptReplace.eligibility(v, bundleVersion: app.bundleVersion) == .update(installed: "1.13.1", cask: "1.13.2"))
    }

    /// `brew install --cask --force` overwrites every artifact; Tankard keeps
    /// a copy of one app. Only a cask that installs exactly one app counts.
    @Test func onlyACaskWithExactlyOneApp() throws {
        func cask(_ artifacts: String) throws -> AdoptCask {
            let json = #"{"token":"foo","version":"2.0","artifacts":["# + artifacts + "]}"
            return AdoptCask(try JSONDecoder().decode(BrewInfoJSON.Cask.self, from: Data(json.utf8)))
        }
        let uninstallZap = #"{"uninstall":[{"quit":"com.foo.Foo"}]},{"zap":[{"trash":["~/Library/Foo"]}]}"#
        // One app (and uninstall/zap, which --force doesn't run): offered.
        #expect(AdoptReplace.installsOnlyOneApp(try cask(#"{"app":["Foo.app"],"target":"/Applications/Foo.app"},"# + uninstallZap)))
        // karabiner-elements: two apps.
        #expect(!AdoptReplace.installsOnlyOneApp(try cask(#"{"app":["Karabiner-Elements.app"],"target":"/Applications/Karabiner-Elements.app"},{"app":["Karabiner-EventViewer.app"],"target":"/Applications/Karabiner-EventViewer.app"}"#)))
        #expect(!AdoptReplace.installsOnlyOneApp(try cask(#"{"app":["A.app","B.app"]}"#)))
        // An app and a binary, a command wrapper, a pkg, a font.
        #expect(!AdoptReplace.installsOnlyOneApp(try cask(#"{"app":["Foo.app"],"target":"/Applications/Foo.app"},{"binary":["foo"],"target":"/usr/local/bin/foo"}"#)))
        #expect(!AdoptReplace.installsOnlyOneApp(try cask(#"{"app":["Foo.app"],"target":"/Applications/Foo.app"},{"command_wrapper":["foo"],"target":"/usr/local/bin/foo"}"#)))
        #expect(!AdoptReplace.installsOnlyOneApp(try cask(#"{"app":["Foo.app"],"target":"/Applications/Foo.app"},{"pkg":["Foo.pkg"]}"#)))
        #expect(!AdoptReplace.installsOnlyOneApp(try cask(#"{"app":["Foo.app"],"target":"/Applications/Foo.app"},{"font":["Foo.ttf"]}"#)))
        // A suite, or no artifacts at all (unknown).
        #expect(!AdoptReplace.installsOnlyOneApp(try cask(#"{"suite":["Foo"],"target":"/Applications/Foo"}"#)))
        #expect(!AdoptReplace.installsOnlyOneApp(AdoptCask(try JSONDecoder().decode(BrewInfoJSON.Cask.self,
                                                                                     from: Data(#"{"token":"foo","version":"2.0"}"#.utf8)))))
    }
}
