# Tankard architecture

How Tankard is built, how it runs brew, and how a release is made. What the app does is in
[usage.md](usage.md).

## Building

You only need the Command Line Tools (`xcode-select --install`). Xcode is not required.
Swift 6.0 or later (CLT 16.2 has Swift 6.0.3).

```sh
swift build -c release           # .build/release/tankard (the CLI)
Scripts/test.sh                  # unit tests (Swift Testing)
```

`Scripts/test.sh` runs `swift test`. With only the Command Line Tools installed, it also
adds the search and rpath flags Swift Testing needs, because CLT keeps the framework in a
non-default place. With Xcode, plain `swift test` works too.

### The app

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
else the default in `bundle-app.sh`, kept in step with `tankard --version`. `CFBundleVersion`
equals `CFBundleShortVersionString` (the script fails if they differ), so About shows
"Version 0.5.0" with no build number. Bundle id `net.mindtricks.tankard`, macOS 14 minimum, no App
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

A release signed with a Developer ID and notarized (see *Signing a release*) doesn't need this.

## Code

```
TankardCore      (step 1) brew JSON, status classification, versions, Intelbrew detection,
                 the Discover catalogue (CatalogEntry, ranking, bottle badges), the tap
                 index and FormulaScanner (bottle do / depends_on, no Ruby run), dependents,
                 CompileClassifier (BuildPlan: bottle or compile?, one answer for every
                 view), CleanupDryRun (parses `brew cleanup -n`), BottleReplacement,
                 brew's environment, DependencyGraph and BrewService (0.4),
                 ProcessRunner, and StreamingProcessRunner (merged
                 stdout/stderr in chunks, same no-shell / clean-env / process-group rules),
                 0.4: BrewVulnsJSON and VulnerabilityScan (`brew vulns --json`, stdout
                 only), DiskSizes (parses `brew info --sizes`), SelfUpdatingCasks
                 (`brew outdated --greedy --cask`)
                 0.6: PackageLifecycle (deprecation/disable dates, reasons,
                 replacements), DoctorReport and its warning mapping,
                 BrewFailure (brew's lock, network, disk full, permissions),
                 AutoremovePlan (Health.swift)
TankardAppModel  no SwiftUI; everything the app does, tested on its own
  AppStore         @Observable @MainActor: report, filter, search, selection, refresh,
                   cache-first loading, errors that keep data, starting upgrades
  CommandQueue     strict FIFO for mutating brew commands (see below)
  UpgradeSession   one upgrade run: per-package state, live log, log file, stop controls
  LineAssembler    bytes → lines, CR-aware (redraws replace the line), CRLF and UTF-8
                   split across reads, ANSI stripped
  StatusCache      the cached StatusReport JSON
  DiscoverStore    @Observable: catalogue loading (on open, TTL), debounced search,
                   coalesced `brew info` batches for the rows on screen
  CatalogSources   APIFetcher/APICatalog (formulae.brew.sh, ETag + 1 h TTL) and
                   TapCatalog (local taps + `brew info`, Intelbrew mode)
  Welcome          MacHardware (Intel or Apple silicon), the installer one-liners and
                   their .command scripts, HomebrewState
  Appearance       themes, their UserDefaults persistence, the Tankard and Dracula
                   palettes, the system themes' version and action greens, and their
                   WCAG contrast checks
  MenuBar          MenuBarSummary (the icon's count and list), BackgroundSchedule,
                   BackgroundChecker (the one timer: 0.3 notifications and 0.5
                   auto-update), UpgradeNotificationDiff (0.3)
  AutoUpdate       0.5: AutoUpdateSchedule and AutoUpdatePolicy (pure: due, AC,
                   idle, one run per slot), AutoUpdateSafeMode (the plan),
                   AutoUpdateSettings, AutoUpdateLog, AutoUpdater (one run).
                   Hidden test hooks (defaults, no UI): autoUpdateDryRun (Bool:
                   plan and log, run no brew command) and autoUpdateOnly
                   ([String]: only these package names are in scope; the
                   dependency checks still see everything). brew's installed-
                   dependents check is never turned off: a formula whose
                   upgrade would make brew upgrade or rebuild a dependent with
                   no bottle is skipped instead.
  BuildTimes       IntelbrewBuildTimes, BuildTimeSource (fetch, 24 h cache, bounds) (0.3)
  CleanupStore     the Cleanup sheet's dry run, cache size and run (0.3)
  AppManagement    which steps need it, the block matcher, the settings links (0.3)
  ContextMenus     which right-click items appear, as pure functions (0.3)
  Insights         InsightsStore (the background `brew vulns --json` and `brew info
                   --sizes`, their cache, decorating the report), InsightSettings,
                   PostInstallNotes, VulnerabilityNotice, VulnerabilityUpgrades and
                   its `isHeld` hook (pins), Caveats (0.4)
  InsightColors    the vulnerability warning's colours per theme, AA-checked (0.4)
  Demo             fake runners and the bundled fixture copies
  Pins             pin/unpin commands, the one-command queue runner pin and services
                   share, Upgrade all's pinned note, dependency links (0.4)
  ServicesStore    the Services tab: list and info reads, actions through the queue,
                   root services and brew's sudo advice (0.4)
  HomebrewManagement  the Homebrew menu: typed confirmation, the revert plan (profile
                   lines, backups, commands, script), the uninstaller script (0.4)
  History          0.6: HistoryLog (Application Support history.json, last 500,
                   the auto-update log's JSON format), HistoryRecorder (the
                   queue's observer: every queued command, its result and
                   duration), filters and Retry (through the queue)
  HealthStore      0.6: the Health sheet (`brew doctor`, `config`, `missing`,
                   read-only), the autoremove sheet (`brew autoremove
                   --dry-run`, then `brew autoremove` through the queue), the
                   deprecated/disabled/keg-only display and Install replacement
  PackageDisplay   badge labels, sub-lines, release-page URLs, commands, summary text,
                   fork summary, sudo detection
TankardApp       the SwiftUI views (App lifecycle), the menu-bar extra, Settings, About,
                 themes (Theme, Themed, PrimaryActionStyle), resources, snapshots
```

**Why the queue isn't just an actor.** Actors are re-entrant: at every `await` another
caller can run, so an actor method that starts brew and awaits it doesn't stop a second
brew from starting. `CommandQueue.enqueue` is synchronous (its order is the call order); it
appends to an `AsyncStream` under a lock, and one worker task runs each command to the end
before taking the next. Cancelling a waiting command skips it; cancelling the running one
cancels its task, and the runner sends SIGTERM to brew's whole process group, then SIGKILL
after 2 s.

Events from the queue arrive on background threads. Each upgrade session feeds them
through its own `AsyncStream` to one main-actor consumer, so they are applied in order.

Build notes for the CLT: the views use `State(initialValue:)` instead of `@State`, because
in the macOS 27 SDK `@State` is a macro whose plugin (SwiftUIMacros) ships with Xcode, not
the Command Line Tools. Resources are SwiftPM bundles copied into `Contents/Resources`, and
looked up there first, then through `Bundle.module` (for `swift run`).

**Themes are values, not view branches.** `Themed` applies one modifier chain for every
theme, and only the colours differ. An `if palette … else …` there gives each theme its
own view identity, so a switch replaces the window's content: a new `NSTableView`, with
the scroll position, column widths and selected row's place lost (the visible jump when
choosing Tankard before 0.3). `Scripts/layout-check.sh` fails if that comes back.

The same goes below `Themed`: nothing a theme changes may change a size or a control.
Before 0.4 the segmented pickers were the system control in Dark/Light/System and a
drawn one in Tankard/Dracula (13 against 12 points, equal against fitted segments, a
semibold selected label), so a switch moved the toolbar and filter labels; now
`ThemedSegmentedPicker` is one drawn control with theme colours (`Theme.segment…`).
The tables keep one configuration (`.inset(alternatesRowBackgrounds: false)`, hidden
content background) in every theme and `TableSelectionStyler` paints the stripes and,
for a palette, the selection: changing `alternatesRowBackgrounds`,
`.scrollContentBackground` or `usesAlternatingRowBackgroundColors` makes AppKit drop the
visible row views, and the ones it brought back from its reuse pool kept the previous
theme's stripes (purple rows in Dark). `Scripts/theme-geometry-check.sh` fails if either
comes back.

## Intelbrew detection and brew's environment

A GUI app launched from the Dock or Finder doesn't read `~/.zshenv`, so it has no PATH
to brew and no `HOMEBREW_*` settings. If brew ran with that environment, it would quietly
use Homebrew's API and build from source. So `BrewClient` doesn't inherit any
environment. It builds brew's from scratch, like `env -i`, and passes the arguments
directly to `posix_spawn` with no shell in between:

| variable | value |
|---|---|
| `HOME`, `USER`, `LOGNAME`, `TMPDIR` | from the process (with Foundation fallbacks) |
| `LANG` | `en_US.UTF-8` |
| `PATH` | `<brew's bin dir>:<prefix>/sbin:/usr/bin:/bin` |
| `HOMEBREW_NO_INSTALL_FROM_API=1`, `HOMEBREW_CORE_GIT_REMOTE`, `HOMEBREW_BREW_GIT_REMOTE` | Intelbrew mode only (the fork URLs, or your own spelling of them, such as an ssh URL) |
| `HOMEBREW_NO_AUTO_UPDATE=1` | read-only queries (all of step 1) |
| `HOMEBREW_NO_ENV_HINTS=1`, `HOMEBREW_NO_COLOR=1` | always |

Any other Homebrew setting you want Tankard's brew to use goes in a **brew.env** file.
`bin/brew` reads these itself, so they apply no matter who starts brew:
`/etc/homebrew/brew.env`, `<prefix>/etc/homebrew/brew.env`, then
`~/.homebrew/brew.env` (or `$XDG_CONFIG_HOME/homebrew/brew.env`). `HOMEBREW_*` exports in
your shell profile do **not** reach brew when Tankard runs it, apart from the three
Intelbrew variables above.

**Finding brew:** `--brew PATH`, then `$TANKARD_BREW`, then `/usr/local/bin/brew`, then
`/opt/homebrew/bin/brew`. The prefix is two directories above the brew path. The
repository is two directories above the resolved symlink: `/usr/local/bin/brew` points to
`/usr/local/Homebrew/bin/brew`. The bottle CPU comes from the prefix: `/opt/homebrew` is
arm64 and anything else is x86_64, which covers Intel brew under Rosetta.

**Intelbrew is detected when either of these is true:**

1. homebrew/core's `remote.origin.url` is the fork. Tankard checks this with
   `git -C <repository>/Library/Taps/homebrew/homebrew-core config --get
   remote.origin.url`, without starting brew. The URL is normalised first: case, `.git`,
   trailing `/`, and the `git@`, `ssh://`, `git://` and `http://` forms.
2. `HOMEBREW_CORE_GIT_REMOTE` points at the fork in brew.env, in this process's
   environment, or in a shell startup file. The startup files are, in read order:
   - zsh: `~/.zshenv`, then `$ZDOTDIR/.zshenv`, `.zprofile`, `.zshrc` and `.zlogin`
   - bash: the first of `.bash_profile`, `.bash_login` or `.profile`, then `.bashrc`

   This catches a Mac that is configured but has no core tap yet (API mode). Tankard
   warns about that case. Startup files are parsed the way the Intelbrew installer
   matches them. Only lines with a single assignment are read (`[export] NAME=value`,
   with optional quotes, `;` or comment). Values that need shell expansion are skipped.
   brew.env takes priority over the environment, and the environment takes priority over
   startup files.

**The fork-status footer and `fork` object** come from git, not `brew config`, because
git is faster:

- the core origin and branch
- the brew origin
- `git describe --tags` (what `brew --version` shows)
- the exact tag HEAD is on
- the newest `N.N.N` tag, from the local tags or, with `--remote`, from `ls-remote`

## Library shape

- `BrewClient`: `Sendable`, `async`. `status()` returns a `StatusReport`. Brew is found
  with `BrewClient.locate(override:)`. Command execution goes through `CommandRunning`
  (`ProcessRunner` in production, a fake in tests).
- `ProcessRunner`: built on `posix_spawn`. Arguments go straight to the program, the
  environment is exactly what is given, and the child gets its own session
  (`POSIX_SPAWN_SETSID`). Cancelling the Swift task sends SIGTERM to the whole process
  group, then SIGKILL after 2 s.
- `StreamingProcessRunner` (`StreamingCommandRunning`): the same rules, with stdout and
  stderr merged and handed over in chunks as they arrive, for `brew update` and
  `brew upgrade`.
- Reads run concurrently. Mutating commands go through the app's strict FIFO
  `CommandQueue` (see the app's architecture).
- `BrewClient.fileExists` is injectable, so tests and demo mode can claim a core tap.
- Pure, testable pieces: `StatusClassifier`, `BottlePlatform`, `BrewVersion`,
  `PkgVersion`, `IntelbrewDetector`, `BrewEnvironment`, `EnvFileParser`.
- Requires macOS 14. Locks use `OSAllocatedUnfairLock`, not `Mutex` (which needs macOS
  15). Test resources load with `Bundle.module`.

## JSON output (`tankard status --json`), schema version 1

`schemaVersion` changes on any breaking change. Within a version, fields are only ever
added. Keys are sorted. Optional fields are **left out** when there is no value.
`TankardCore.StatusReport` is the Codable type, and `StatusReport.jsonDecoder()` decodes
the output.

```jsonc
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-16T21:30:00Z",          // ISO 8601
  "host": {
    "brewPath": "/usr/local/bin/brew", "prefix": "/usr/local", "repository": "/usr/local/Homebrew",
    "bottleTag": "sonoma",                         // optional: unknown macOS has none
    "platform": { "arch": "x86_64", "macOSVersion": "14", "cellar": "/usr/local/Cellar" }
  },
  "intelbrew": {
    "detected": true,
    "reasons": ["homebrew/core origin is https://github.com/d4rkwyng/intelbrew-core"],
    "env":   { "HOMEBREW_NO_INSTALL_FROM_API": "1", "HOMEBREW_CORE_GIT_REMOTE": "…", "HOMEBREW_BREW_GIT_REMOTE": "…" },
    "found": { "HOMEBREW_CORE_GIT_REMOTE": { "value": "…", "source": "~/.zshenv" } }  // only the 3 Intelbrew keys
  },
  "fork": {
    "coreTapPath": "…/homebrew-core", "coreOrigin": "…", "coreBranch": "main", "coreIsFork": true,
    "brewRepository": "/usr/local/Homebrew", "brewOrigin": "…", "brewIsFork": true,
    "brewVersion": "7.0.14", "brewTag": "7.0.14",
    "brewNewestTag": "7.0.14", "brewNewestTagSource": "local",   // or "remote"
    "brewAtNewestTag": true                                       // optional: needs brewTag and brewNewestTag
  },
  "summary": {
    "installed": 20, "formulae": 20, "casks": 0,
    "bottled": 19, "intelbrewBottled": 13, "source": 1, "newer": 0, "noBottle": 0,
    "upgrades": 0, "upgradesWithBottle": 0, "upgradesFromSource": 0, "caskUpgrades": 0,
    "requested": 3, "dependencies": 17
  },
  "packages": [
    {
      "id": "formula:homebrew/core/xz",            // stable key: kind + tap + name
      "kind": "formula",                           // formula | cask
      "name": "xz", "fullName": "xz", "tap": "homebrew/core", "desc": "…",
      "status": "bottle",                          // bottle | source | newer | noBottle | cask
      "statusLabel": "Intelbrew bottle",           // bottle | Intelbrew bottle | Homebrew bottle | source | newer | no bottle | cask
      "installedVersion": "5.8.4", "installedVersions": ["5.8.4"], "currentVersion": "5.8.4",
      "requested": false, "pinned": false, "kegOnly": false, "deprecated": false, "disabled": false,
      "upgradeAvailable": false,
      "pouredFromBottle": true,                    // formulae only
      "currentHasBottle": true,                    // formulae only
      "bottleTag": "sonoma",                       // formulae with a pourable bottle
      "bottleOrigin": "intelbrew",                 // intelbrew | homebrew | other; only when installed == current
      "bottleURL": "https://github.com/…/xz-5.8.4.sonoma.bottle.tar.gz",  // formulae with a pourable bottle
      "installedAt": "2026-11-14T10:31:21Z",       // when brew recorded it
      "upgradeHasBottle": true,                    // formulae with an upgrade only
      "autoUpdates": true,                         // casks only
      "dependencies": ["lz4"],                     // 0.2+: formulae it needs (receipt runtime deps; casks: depends_on formulae)
      "caskDependencies": [],                      // 0.2+, casks only: depends_on casks
      "caveats": "…"                               // 0.4: brew's caveats, when there are any
    }
  ],
  "timingsMs": { "detect": 13, "info": 623, "git": 26, "total": 637 },   // Intel VM, 20 formulae
  "warnings": []
}
```

The app also keeps `diskBytes`, `vulnerabilities` and `selfUpdatingUpgrade` on its own
copies of packages (0.4); `tankard status` never sets them, so they are left out of its
JSON.

Formula versions include the `_N` revision. `bottleOrigin` is only set when the installed
version equals the current one. Receipts don't record which bottle URL was poured, so for
an older keg Tankard can't know.

## Demo mode, screenshots and the layout check

```sh
open -n --env TANKARD_DEMO=1 dist/Tankard.app
TANKARD_DEMO=1 dist/Tankard.app/Contents/MacOS/Tankard     # same, from a terminal
```

| variable | effect |
|---|---|
| `TANKARD_DEMO=1` | Fake brew fed by the Intel VM fixture, in Intelbrew mode. That Mac had nothing to upgrade, so demo mode makes five versions older and one newer (`Demo.intelTweaks`). Upgrades play a scripted brew log and then show as current. Nothing is spawned. |
| `TANKARD_DEMO=arm64` | The arm64 fixture as captured: API mode, normal (non-Intelbrew) look, 14 packages including casks, 5 of them outdated. |
| `TANKARD_DEMO_UPGRADE=1` | Demo only: start the upgrade sheet on launch; `=plan` opens it on its plan page (compile warnings). |
| `TANKARD_DEMO_PACE=0.5` | Demo only: speed of the scripted log (lower is faster). |
| `TANKARD_SELECT=<name>` | Select a package on launch (any mode). |
| `TANKARD_APPEARANCE=dark\|light\|system\|tankard\|dracula` | Use this theme for this run (not saved; otherwise the one from Settings). |
| `TANKARD_TAB=discover` | Open on Discover (any mode; normal mode then fetches the catalogue). |
| `TANKARD_DISCOVER=<query>` | Open Discover and search. `TANKARD_DISCOVER_SELECT=<name>` selects a result. |
| `TANKARD_DEMO_INSTALL=1` | Demo only: install the Discover selection (scripted log). |
| `TANKARD_DEMO_UNINSTALL=<name>` | Demo only: open the uninstall confirmation for an installed package. |
| `TANKARD_DEMO_NOBREW=intel\|arm64` | The welcome screen as on an Intel Mac or Apple silicon (nothing is opened). |
| `TANKARD_SNAPSHOT=<file.png>` | Write a 2x PNG of the window (and an open sheet) after `TANKARD_SNAPSHOT_DELAY` seconds (default 4); `TANKARD_SNAPSHOT_QUIT=1` quits after; `TANKARD_SNAPSHOT_SIZE=1040x620` sets the content size. The window draws itself, so this works without Screen Recording permission and while the screen is locked. |
| `TANKARD_FILTER=upgrades\|source\|newer\|bottle` | The Installed filter on launch. |
| `TANKARD_DEMO_CLEANUP=1` | Demo only: open Cleanup; `TANKARD_DEMO_CLEANUP_RUN=1` then clicks Clean up. |
| `TANKARD_DEMO_REPLACE=1` | Demo only: replace the selection with a bottle. |
| `TANKARD_DISCOVER_ALL=1` | Discover's bottle chip off. |
| `TANKARD_DEMO_INSTALL_CONFIRM=1` | Demo only: open "Install (compiles)" for the Discover selection. |
| `TANKARD_DEMO_APPMGMT=1\|fail` | Demo only: the App Management sheet; `fail` makes cask steps fail once with brew's message, then succeed on the retry. |
| `TANKARD_MENUBAR=0` | Hide the menu-bar icon for this run. |
| `TANKARD_SNAPSHOT_VIEW=menubar\|settings\|about` | Snapshot that view (the menu-bar menu, Settings' General tab, the About panel) instead of the window. |
| `TANKARD_SNAPSHOT_ORIGIN=x,y` | Window origin (screen points) to set first. |
| `TANKARD_SNAPSHOT_LAYOUT=1` | Also print the layout (window, table, rows, cells) to stderr. |
| `TANKARD_LOG_FRAMES=1` | Print every window move or resize, and the table's identity, scroll and column widths each second. |
| `TANKARD_SWITCH_APPEARANCE=<theme>@<s>` | Switch theme at runtime, as Settings does (not saved). |
| `TANKARD_RESELECT=<name>@<s>` | Select another row later, as a click would. |
| `TANKARD_FILTER=pinned\|leaves` | 0.4: the Pinned or Requested only filter. |
| `TANKARD_TAB=services` | 0.4: open on Services (reads only). `TANKARD_SERVICE_SELECT=<name>` selects one. |
| `TANKARD_TREE=all` | 0.4: open every dependency-tree row. |
| `TANKARD_DEMO_PINNED=a,b` | Demo only: these start pinned. |
| `TANKARD_DEMO_MANAGE=revert\|uninstall` | Demo only: open that Homebrew menu sheet; `TANKARD_DEMO_TYPED=<word>` pre-types the confirmation. |
| `TANKARD_FILTER=vulnerable\|notes` | 0.4: the Vulnerable or Has notes filter on launch. |
| `TANKARD_DEMO_NOTES=1` | 0.4, demo only: upgrade everything, close the finished sheet; the post-install notes follow. |
| `TANKARD_DEMO_VULN_NOTICE=1` | 0.4, demo only: the menu-bar vulnerability notice on, with nothing seen yet. |
| `TANKARD_SELF_UPDATING=1` | 0.4, demo only: "Include self-updating apps" on. |
| `TANKARD_SNAPSHOT_VIEW=settings-upgrades` | 0.4: Settings → Upgrades. |
| `TANKARD_BREW=<path>` | Use this brew instead of `/usr/local/bin/brew` or `/opt/homebrew/bin/brew`. |

Demo runs and snapshot runs use throwaway settings, never the real UserDefaults. Demo
Discover uses fixtures too: a slice of formulae.brew.sh (normal mode) and `brew info`
captured read-only on the Intel VM (Intelbrew mode), with no cask tap. Nothing is fetched.

`SET=v0.4b Scripts/screenshots.sh OUT_DIR` takes the 0.4 vulnerability, notes, size,
self-updating, settings and menu-bar notice shots in Dark and Tankard.

`Scripts/screenshots.sh [OUT_DIR]` takes the standard set (Intelbrew demo light and dark,
the upgrade sheet, the arm64 demo, the five themes, Discover in both modes, the install
sheet, the uninstall confirmation and its blocked form, the welcome screen on Intel and
Apple silicon, and this Mac's real data; `SKIP_REAL=1` skips the last). `SET=v0.3 Scripts/screenshots.sh OUT_DIR` takes only the 0.3 shots (menu bar,
compile warnings, cleanup, replace with bottle, Discover's chip, App Management, Settings,
About).

`SET=v0.4a Scripts/screenshots.sh OUT_DIR` takes the 0.4 part A shots (pins, Requested only,
the dependency tree, Services, the Homebrew menu's sheets) in Dark and Tankard. Demo
Services are an illustrative list (one running, one failed, one not loaded, one root
service) shaped like real output; the Intel VM has no services and the arm64 Mac one.

`Scripts/layout-check.sh [APP]` checks that the main window's layout doesn't depend on
the theme: the window frame, the table's position and insets, the visible rows and cells
must match between Dark, Tankard, Dracula and live switches (with a row selected before
the switch and another after), the window must not move or resize, and the table must not
be rebuilt. It uses the layout dump, so it works with the screen locked, but needs a
window server (it isn't part of `swift test`). `REAL=1` runs it on this Mac's Homebrew,
read-only.

`Scripts/theme-geometry-check.sh [APP]` checks a real launch of any build, the signed
release included, with this Mac's Homebrew: no `TANKARD_*` hooks. It re-signs a copy ad
hoc and loads `Scripts/theme-probe.m` into it, which opens Settings and clicks the
Appearance radio buttons. Every visible text, image, control, toolbar item and cell must
keep its place and size in all five themes, launched in each and through a chain of
switches, in every frame drawn after a click as well as once settled; and after each
switch every visible row's background (at the top, 40 rows down, and back) must match a
fresh launch in that theme. It backs up and restores the app's defaults.

`Scripts/launch-check.sh [APP]` launches the app for real (no demo, no snapshot, no
`TANKARD_*` variables, real settings and real brew, read-only) several times and fails
if it doesn't stay up or leaves a new crash report in `~/Library/Logs/DiagnosticReports`.
With no APP it builds `dist/Tankard.app` first; give it the downloaded release
(`Scripts/launch-check.sh --runs 5 ~/Downloads/Tankard.app`) to check what actually
ships. `release.sh` runs it on the signed app before notarizing. 0.3.0 crashed at
launch (App.body re-ran in a loop until the stack overflowed) and every demo, snapshot
and local build missed it: it needed the release toolchain and the signed app. The rule
that came out of it: **App.body is pure**. It reads no @Observable state that changes and
writes none; menu items that follow the store are views (`ViewCommands`, and 0.4's
`HomebrewCommands` for the Homebrew menu), bindings
handed to scenes (`MenuBarExtra(isInserted:)`) ignore unchanged writes, and settings
(`AppSettings.showMenuBarIcon`, `AppearanceSettings.theme`, and every 0.4
`InsightSettings` option) don't notify on an unchanged value, whatever the compiler's
@Observable does.

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

v0.4 (part B) adds: `brew vulns --json` captured read-only on the arm64 Mac and the Intel
VM (`*-vulns.json`, with the arm64 run's stderr in `arm64-vulns-stderr.txt`, which shows
why only stdout is decoded), `brew info --sizes` (`sonoma-intelbrew-sizes.txt` as printed;
`arm64-sizes.txt` trimmed to the arm64 fixture's packages with its totals recomputed),
`brew outdated --greedy --cask --json=v2` (`*-outdated-greedy.json`, arm64 trimmed the same
way), and the caveats of both `*-info.json` fixtures (from the same machines' current
`brew info`). Tests: decoding, severity order, partial-scan reasons, version matching,
size parsing and formatting, greedy marking and unmarking, the store's decoration,
filters and cache, scan failures, "Upgrade vulnerable" (and its hold hook), post-install
notes, the no-quit environment and command, the menu-bar notice, and the warning colours'
contrast in every theme. Demo mode answers the three reads from copies of these fixtures.

v0.3 adds: the compile classification and plan, the formula scanner against `brew info`,
the cleanup dry-run parser (read-only captures from this Mac and the Intel VM, home
directory renamed), bottle replacement eligibility and commands, build-time decoding,
bounds, caching and fallbacks (a fixture with a fake fetch), the background schedule and
notification diff, App Management gating and its block matcher, the context menus' items,
the version columns' and green buttons' contrast in every theme, and Discover's bottle chip
and ranking. `IndexBench` (`TANKARD_BENCH_TAPS=<taps dir>`) times the tap index.

v0.4 (part A) adds, against real output captured read-only on 2026-11-16 on the Intel VM
and the arm64 Mac (`*-deps-info.json`, trimmed to the keys read; `*-deps-installed.txt`,
`*-uses-installed.txt`, `*-leaves*.txt`, `sonoma-intelbrew-deps-tree-python.txt`,
`*-services-*.json`): Used by equals `brew uses --installed` and the leaves equal `brew
leaves` / `brew leaves -r` on both; Depends on contains `brew deps --installed` (equal on the
VM, 19 supersets on the arm64 Mac); the tree equals `brew deps --tree`; services decoding
(every status symbol, the empty outputs). With fake runners and demo mode: pin and unpin
through the queue, failures, pinned packages left out of Upgrade all and the menu bar,
Requested only, links, services through the queue, root services never reaching brew,
brew's sudo message, the typed confirmations, the revert plan, and its `cp`/`sed` lines run
for real on a temp file. The intel demo also lays the fresh receipts over its fixture, so
its dependency views are realistic.

## Signing a release

Two ways, sharing `Scripts/release.sh`:

**On your Mac** (Developer ID certificate in your login keychain). Once, store the notary
credentials in the keychain:

```sh
xcrun notarytool store-credentials tankard
# Apple ID, Team ID, and an app-specific password made at appleid.apple.com
```

Then:

```sh
Scripts/release.sh --dry-run   # print every step
Scripts/release.sh             # dist/Tankard.app (signed, notarized, stapled) and dist/Tankard.zip
```

It builds universal (`--host-arch` for this Mac's architecture only), finds the
"Developer ID Application:" identity with `security find-identity -v -p codesigning`
(override: `TANKARD_SIGN_ID`), signs nested code first and then the app with
`codesign --force --options runtime --timestamp` (no `--deep`), checks it with
`codesign --verify --strict --deep`, submits a zip with `notarytool --wait` (profile name:
`TANKARD_NOTARY_PROFILE`, default `tankard`), fails unless the status is Accepted, staples,
checks with `spctl -a -vv`, and zips the stapled app with `ditto -c -k --keepParent`.
`--skip-notarize` stops after signing. Before notarizing it real-launches the signed app
five times with `Scripts/launch-check.sh` and stops if it crashes (`--skip-launch-check`
only on a Mac with no GUI session; then run the check on the downloaded zip before
publishing the draft).

The hardened runtime needs no entitlements: the app is plain Swift with no third-party
libraries, plug-ins or JIT, and brew is a child process started with `posix_spawn`, which
the parent's runtime doesn't restrict. (Checked on the arm64 Mac: an ad-hoc,
hardened-runtime build reads real brew data.)

**On GitHub.** `.github/workflows/release.yml` runs on a `v*` tag push (or by hand with a
tag), on `macos-15`: tests, imports the certificate, runs `Scripts/release.sh`, and
attaches `Tankard.zip` to the release. Actions are pinned by commit SHA. The owner must add
five repository secrets first (the workflow stops with a clear message if any is missing):

| secret | value |
|---|---|
| `CERT_P12_BASE64` | `base64 -i DeveloperID.p12` of the exported Developer ID Application certificate and key |
| `CERT_P12_PASSWORD` | the .p12 password |
| `NOTARY_APPLE_ID` | Apple ID |
| `NOTARY_TEAM_ID` | Team ID |
| `NOTARY_PASSWORD` | app-specific password |

No secrets live in the repository.

### Release notes

`CHANGELOG.md` follows Keep a Changelog. `Scripts/changelog-section.sh X.Y.Z` prints that
version's section and exits 1 if it is missing or empty; `--self-test` checks the
extraction. The release workflow runs the self-test, builds the notes (an intro line, the
section, the install and upgrade commands) and passes them as the release body, so a tag
without a CHANGELOG section fails before anything is signed.
