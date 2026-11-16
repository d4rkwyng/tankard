# Development

[README](../README.md) · [Using Tankard](usage.md) · **Development** · [Architecture](architecture.md) · [Releasing](releasing.md)

## Build and test

You only need the Command Line Tools (`xcode-select --install`). Xcode is not required.
Swift 6.0 or later (CLT 16.2 has Swift 6.0.3).

```sh
swift build -c release           # .build/release/tankard
Scripts/test.sh                  # unit tests (Swift Testing)
```

`Scripts/test.sh` runs `swift test`. With only the Command Line Tools installed, it also
adds the search and rpath flags Swift Testing needs, because CLT keeps the framework in a
non-default place. With Xcode, plain `swift test` works too.

Under the CLT the swift-testing macro plugin also isn't on the default plugin path, so a
clean build would fail with "plugin for module 'TestingMacros' not found";
`Scripts/test.sh` passes `-plugin-path
/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`, plus `-F` and
rpaths for `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` and
`.../Library/Developer/usr/lib`. Extra arguments are passed through to `swift test`
(for example `--filter`).

## Building the app

```sh
Scripts/bundle-app.sh              # dist/Tankard.app for this Mac's architecture, ad-hoc signed
Scripts/bundle-app.sh --universal  # x86_64 + arm64 in one binary
open dist/Tankard.app
```

Command Line Tools only: SwiftPM builds the `TankardApp` executable, and the script wraps it
in an `.app` (Info.plist, resources, `codesign -s -`). There is no Xcode project, asset
catalog or string catalog. The app icon is a plain `Resources/AppIcon.icns`
(`CFBundleIconFile`), committed; `Scripts/make-icon.sh` rebuilds it from Tankard's
pixel-art mark (`Sources/TankardApp/Resources/tankard-mark.png`; nearest-neighbour
scaling only, on a drawn plate) with ffmpeg, `swiftc` and `iconutil`. In Intelbrew mode
the app sets its Dock icon at run time to the Intelbrew "i" mug (`intelbrew-mug.png`) on
the same plate, scaled 3x the same way. The version is `TANKARD_VERSION` (the release workflow sets it from the tag),
else the default in `bundle-app.sh`, kept in step with `tankard --version`. Bundle id `net.mindtricks.tankard`, macOS 14 minimum, no App
Sandbox (brew can't run inside one).

**Universal builds.** `--universal` first tries one `swift build --arch x86_64 --arch
arm64`. Newer SwiftPM (6.1 and later) does that with the CLT alone. SwiftPM 6.0 (CLT 16.x,
as on a macOS 14 Mac) hands multi-arch builds to `xcbuild`, which only comes with Xcode; the
script then builds each architecture separately and joins them with `lipo`. Both paths are
tested: the first on macOS 27 (Swift 6.4), the second on the Intel macOS 14 VM (Swift 6.0.3).

`swift run TankardApp` also works for development (the window opens from the terminal).

**Downloaded builds are quarantined.** An ad-hoc signed app from a zip or a browser
download is blocked by Gatekeeper ("can't be opened because Apple cannot check it…").
Either right-click → Open once, or clear the flag:

```sh
xattr -dr com.apple.quarantine Tankard.app
```

A release signed with a Developer ID and notarized ([releasing.md](releasing.md)) doesn't need this.

### Build notes for the Command Line Tools

The views use `State(initialValue:)` instead of `@State`, because
in the macOS 27 SDK `@State` is a macro whose plugin (SwiftUIMacros) ships with Xcode, not
the Command Line Tools. Resources are SwiftPM bundles copied into `Contents/Resources`, and
looked up there first, then through `Bundle.module` (for `swift run`).

## Demo mode and screenshots

```sh
open -n --env TANKARD_DEMO=1 dist/Tankard.app
TANKARD_DEMO=1 dist/Tankard.app/Contents/MacOS/Tankard     # same, from a terminal
```

| variable | effect |
|---|---|
| `TANKARD_DEMO=1` | Fake brew fed by the Intel VM fixture, in Intelbrew mode. That Mac had nothing to upgrade, so demo mode makes five versions older and one newer (`Demo.intelTweaks`). Upgrades play a scripted brew log and then show as current. Nothing is spawned. |
| `TANKARD_DEMO=arm64` | The arm64 fixture as captured: API mode, normal (non-Intelbrew) look, 14 packages including casks, 5 of them outdated. |
| `TANKARD_DEMO_UPGRADE=1` | Demo only: start the upgrade sheet on launch. |
| `TANKARD_DEMO_PACE=0.5` | Demo only: speed of the scripted log (lower is faster). |
| `TANKARD_SELECT=<name>` | Select a package on launch (any mode). |
| `TANKARD_APPEARANCE=dark\|light\|system\|tankard` | Use this theme for this run (not saved; otherwise the one from Settings). |
| `TANKARD_TAB=discover` | Open on Discover (any mode; normal mode then fetches the catalogue). |
| `TANKARD_DISCOVER=<query>` | Open Discover and search. `TANKARD_DISCOVER_SELECT=<name>` selects a result. |
| `TANKARD_DEMO_INSTALL=1` | Demo only: install the Discover selection (scripted log). |
| `TANKARD_DEMO_UNINSTALL=<name>` | Demo only: open the uninstall confirmation for an installed package. |
| `TANKARD_DEMO_NOBREW=intel\|arm64` | The welcome screen as on an Intel Mac or Apple silicon (nothing is opened). |
| `TANKARD_SNAPSHOT=<file.png>` | Write a 2x PNG of the window (and an open sheet) after `TANKARD_SNAPSHOT_DELAY` seconds (default 4); `TANKARD_SNAPSHOT_QUIT=1` quits after; `TANKARD_SNAPSHOT_SIZE=1040x620` sets the content size. The window draws itself, so this works without Screen Recording permission and while the screen is locked. |
| `TANKARD_BREW=<path>` | Use this brew instead of `/usr/local/bin/brew` or `/opt/homebrew/bin/brew`. |

Demo Discover uses fixtures too: a slice of formulae.brew.sh (normal mode) and `brew info`
captured read-only on the Intel VM (Intelbrew mode), with no cask tap. Nothing is fetched.

`Scripts/screenshots.sh [OUT_DIR]` takes the standard set (Intelbrew demo light and dark,
the upgrade sheet, the arm64 demo, the four themes, Discover in both modes, the install
sheet, the uninstall confirmation and its blocked form, the welcome screen on Intel and
Apple silicon, and this Mac's real data; `SKIP_REAL=1` skips the last).

## Tests and fixtures

`Tests/TankardCoreTests/Fixtures/` (inside the test target so SwiftPM can bundle it):

| fixture | source |
|---|---|
| `sonoma-intelbrew-*.json` | Real output from an Intel macOS 14 VM with core on the Intelbrew fork: 20 formulae, one built from source (vim). Trimmed to the keys Tankard reads. |
| `arm64-api-*.json` | Real output from an arm64 Mac in API mode: a subset with outdated formulae, source builds, and casks (one auto-updating cask that brew doesn't count as outdated). |
| `synthetic-intel-*.json` | The same JSON shape with made-up values, for cases neither machine had: newer, newer by revision only, no bottle (arm64-only, missing, wrong Cellar, newer macOS only), HEAD, several kegs, an older-macOS bottle, an `all` bottle, a newer cask, and a `latest` cask. |

Demo mode ships copies of the two `*-info.json` real fixtures in
`Sources/TankardAppModel/Resources/Demo/`; a test checks they stay byte-identical.

`Tests/TankardAppModelTests/` covers the app's logic with fake runners: the line assembler
(CR redraws, CRLF and UTF-8 split across reads, ANSI), the command queue (FIFO order under
concurrent enqueues, one at a time, cancelling waiting and running commands, a real
process group killed through the queue), the store (fresh and stale cache, failed refresh
keeps data, `brew update` first on manual refresh, sudo, brew not found, filters and
search), upgrades (qualified commands in order, log file, reconcile, stop after current,
stop now, sudo failure, refresh queued behind an upgrade), and demo mode end to end.

v0.2 adds: search ranking and filtering, bottle badges, the tap index (a temporary tap
tree), dependents, the API cache (a fake `URLProtocol`: ETag, If-None-Match, 304, TTL,
fallback to the stale copy), Intelbrew-mode search through a fake runner (batched,
qualified `brew info`, retry without an unknown name), install and uninstall command
building and runs, dependents blocking uninstall, theme persistence, the Tankard palette's
WCAG AA check, Mac detection, the `.command` scripts, and welcome → main once brew appears.

Two live canaries are off by default: `TANKARD_LIVE_SEARCH=<query>` times Intelbrew-mode
Discover against this Mac's brew (read-only), and `TANKARD_LIVE_API_DIR=<dir>` times
decoding a saved formula.json and cask.json (no network). Run them with
`Scripts/test.sh --filter LiveSearchCanary` / `--filter LiveAPIDecodeCanary`.
