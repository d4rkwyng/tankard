# Tankard architecture

How Tankard is built, how it runs brew, and how a release is made. How to use the app is in
[usage.md](usage.md); the mechanics behind each feature are in
[App behaviour in detail](#app-behaviour-in-detail).

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
in an `.app` (Info.plist, resources, `codesign -s -`). There is no Xcode project or asset
catalog. Strings live in a string catalog, `Resources/Localizable.xcstrings`; the Command
Line Tools can't compile one, so `Scripts/l10n.py compile` writes
`<lang>.lproj/Localizable.strings` (and `.stringsdict`) into
`Sources/TankardApp/Resources/Localizations/`, and `bundle-app.sh` copies them into the
app. The app icon is a plain `Resources/AppIcon.icns`
(`CFBundleIconFile`), committed; `Scripts/make-icon.sh` rebuilds it from Tankard's
pixel-art mark (`Sources/TankardApp/Resources/tankard-mark.png`; nearest-neighbour
scaling only, on a drawn plate) with ffmpeg, `swiftc` and `iconutil`. In Intelbrew mode
the app sets its Dock icon at run time to the Intelbrew "i" mug (`intelbrew-mug.png`) on
the same plate, scaled 3x the same way. The version is `TANKARD_VERSION` (the release workflow sets it from the tag),
else the default in `bundle-app.sh`, kept in step with `tankard --version`. `CFBundleVersion`
equals `CFBundleShortVersionString` (the script fails if they differ), so About shows
"Version <x.y.z>" with no build number. Bundle id `net.mindtricks.tankard`, macOS 14 minimum, no App
Sandbox (brew can't run inside one).

**Universal builds.** `--universal` first tries one `swift build --arch x86_64 --arch
arm64`. Newer SwiftPM (6.1 and later) does that with the CLT alone. SwiftPM 6.0 (CLT 16.x,
as on a macOS 14 Mac) hands multi-arch builds to `xcbuild`, which only comes with Xcode; the
script then builds each architecture separately and joins them with `lipo`. Both paths are
tested: the first on macOS 27 (Swift 6.4), the second on the Intel macOS 14 VM (Swift 6.0.3).

`swift run TankardApp` also works for development (the window opens from the terminal).

**Downloaded builds are quarantined.** An ad-hoc signed app from a zip or a browser
download is blocked by Gatekeeper ("can't be opened because Apple cannot check it…").
On macOS 14, right-click → Open once; on macOS 15 and later (where right-click → Open no
longer bypasses Gatekeeper), try to open it, then click **Open Anyway** in System Settings ▸
Privacy & Security. Or clear the flag:

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
                 BrewFailure (brew's lock, network, disk full, permissions;
                 0.8.3 checksum), AutoremovePlan (Health.swift)
                 0.8.3: EnvironmentPolicy and CaskOptions (which HOMEBREW_* settings
                 pass, see below), PastedCommand (a pasted `brew install x` searches
                 for x)
AskpassSupport   0.8.3: Askpass (the variable names, timeout), AskpassText (the
                 dialog's wording), AskpassGate (who may ask); shared by the app and
                 the helper
tankard-askpass  0.8.3: the sudo password dialog, shipped as
                 Contents/MacOS/tankard-askpass (see *sudo password dialog*)
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
                   share, Upgrade All's pinned note, dependency links (0.4)
  ServicesStore    the Services tab: list and info reads, actions through the queue,
                   root services and brew's sudo advice (0.4)
  HomebrewManagement  the Homebrew menu: typed confirmation, the revert plan (profile
                   lines, backups, commands, script), the uninstaller script (0.4)
  History          0.6: HistoryLog (Application Support history.json, last 500,
                   the auto-update log's JSON format), HistoryRecorder (the
                   queue's observer: every queued command, its result and
                   duration), filters and Retry (through the queue)
  TapsStore        0.7: the Taps sheet (`brew tap-info --installed --json`,
                   read-only), Add/Remove (`brew tap`/`untap` through the queue
                   and the activity sheet), Trust (`brew trust --tap`, one queued
                   command), the "tap:" Installed search; TankardCore/Taps.swift
                   decodes the JSON, checks names and URLs, and blocks untap
  HealthStore      0.6: the Health sheet (`brew doctor`, `config`, `missing`,
                   read-only), the autoremove sheet (`brew autoremove
                   --dry-run`, then `brew autoremove` through the queue), the
                   deprecated/disabled/keg-only display and Install replacement
  PackageDisplay   badge labels, sub-lines, release-page URLs, commands, summary text,
                   fork summary, sudo detection
  AdminPassword    0.8.3: which commands get SUDO_ASKPASS, which casks need a password
                   first, SudoOutcome, AskpassProcess/AskpassFocus (the dialog's focus)
  Prefetch         0.8.3: the `brew fetch` before a multi-package run, FetchOutput
  BrewLockWait     0.8.3: BrewLock (the lock file brew's message names) and the wait
  QuitGuard        0.8.3: QuitPrompt/QuitChoice (quitting mid-run), RunJournal and
                   InterruptedRunOffer (the run a quit interrupted)
  SingleInstance   0.8.3: the launch-time guard against a second or stale copy, and
                   RelaunchSequence (the self-upgrade and App Management relaunch)
  NotificationRoute  0.8.3: what a click on a notification or its actions opens
TankardApp       the SwiftUI views (App lifecycle), the menu-bar extra, Settings, About,
                 themes (Theme, Themed, PrimaryActionStyle), resources, snapshots
```

**Why the queue isn't just an actor.** Actors are re-entrant: at every `await` another
caller can run, so an actor method that starts brew and awaits it doesn't stop a second
brew from starting. `CommandQueue.enqueue` is synchronous (its order is the call order); it
appends to an `AsyncStream` under a lock, and one worker task runs each command to the end
before taking the next. Cancelling a waiting command skips it; cancelling the running one
cancels its task, and the runner sends SIGINT (brew's Ctrl-C: it rolls back the unfinished
step) to brew's whole process group, then SIGTERM after 15 s and SIGKILL after 15 s more.
Before 0.8.3 it was SIGTERM, then SIGKILL after 2 s, which could cut brew's rollback short.

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
| `HOMEBREW_COLOR`, `HOMEBREW_VERBOSE`, `HOMEBREW_VERBOSE_USING_DOTS`, `HOMEBREW_DEBUG` | never (Tankard reads brew's output) |
| `HOMEBREW_UPGRADE_GREEDY`, `HOMEBREW_UPGRADE_GREEDY_CASKS`, `HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS` | never (the self-updating apps setting decides) |
| the user's allowed `HOMEBREW_*` settings (0.8.3) | from this process's environment, else the last shell startup file that sets them |
| the proxy variables bin/brew keeps, `XDG_CONFIG_HOME`, `HOMEBREW_XDG_CONFIG_HOME` (0.8.4) | the same way |

**The user's settings (0.8.3, `EnvironmentPolicy` in TankardCore).** Before 0.8.3 no
`HOMEBREW_*` export from a shell profile reached brew apart from the Intelbrew three, so
`HOMEBREW_NO_ANALYTICS` in `~/.zshrc` was dropped. Now an explicit allow list passes
(`EnvironmentPolicy.allowed`): privacy and network safety (`NO_ANALYTICS`,
`NO_INSECURE_REDIRECT`, `NO_GITHUB_API`, `CURL_RETRIES`, `FORCE_BREWED_CURL`,
`VERIFY_ATTESTATIONS`), the user's own restrictions (`FORBIDDEN_*`,
`FORBID_PACKAGES_FROM_PATHS`) and behaviour preferences (`TEMP`, `CASK_OPTS` filtered,
`DISPLAY_INSTALL_TIMES`, `NO_EMOJI`, `INSTALL_BADGE`, the cleanup settings,
`NO_AUTOREMOVE`, `NO_INSTALL_UPGRADE`, `NO_UPGRADE_QUIT_CASKS`, `NO_UPDATE_REPORT_NEW`, the
auto-update settings, `DOWNLOAD_CONCURRENCY`, `MAKE_JOBS`, `FAIL_LOG_LINES`). Tankard's
own values (the table above, and what the callers add per command) override them. Denied,
with the reason shown in Health ▸ Environment: where brew lives (`PREFIX`, `CELLAR`,
`REPOSITORY`, `LIBRARY`...), `CACHE` and `LOGS` (download progress and Clean Up assume the
default folders), where it gets code or what it trusts
(every `*_GIT_REMOTE`, `NO_INSTALL_FROM_API`, `DEVELOPER`, `NO_VERIFY_ATTESTATIONS`,
`*TRUST*`, tool paths...), mirrors (`*_DOMAIN`), credentials (`*TOKEN*` and the like) and
`NO_INSTALLED_DEPENDENTS_CHECK` (auto-update's safe mode relies on it). Any other name is
ignored. Intelbrew mode's remotes win, unchanged.

`HOMEBREW_CASK_OPTS` is filtered (`CaskOptions`). brew 7 shell-splits it and reads only
`--flag=value` options, `--require-sha` and `--[no-]binaries`. Tankard keeps
`--require-sha` and `--language=codes`, and drops every `--*dir=` (it would move where apps
go, which Adopt's location verdicts and the App Management probe rely on), `--[no-]binaries`,
and `--force`/`--adopt`/`--no-quarantine` (no effect there in brew 7, named so the user sees
it). If nothing is left, the variable isn't set. Health shows it as partly applied, with
each dropped option and why. A `CASK_OPTS` in a brew.env file can't be filtered: bin/brew
`export`s every brew.env line over the environment (checked on 7.0.14 with a throwaway
HOME: `--require-sha` in the environment, `--appdir=/x --force` in `~/.homebrew/brew.env`
gives `brew config` `["--appdir=/x", "--force"]`, and an empty value in the environment
loses too). Health warns on that row when it has options Tankard would drop.

For the same reason a brew.env `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` would reach
auto-update's runs, whose safe mode relies on that check. `AutoUpdater.checkPause` reads
the brew.env files (re-read from disk each background tick in the app) with bin/brew's
precedence (`EnvironmentSources.brewEnvSetting`: the last file wins, except `/etc` when it
sets `HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY`) and brew's `boolean: true` rule (`BrewBoolean`:
blank, `0`, `false`, `no`, `off` and `nil` mean unset). When it is set, every automatic run
is skipped: an upgrade.log line, an Auto-update log entry, the menu-bar note and the
Settings status say why. Manual upgrades are unaffected.

**Proxies (0.8.4, `ProxySettings`).** bin/brew filters its environment with `env -i` and
keeps `http_proxy`, `https_proxy`, `ftp_proxy`, `no_proxy`, `all_proxy`, `HTTPS_PROXY`,
`FTP_PROXY` and `ALL_PROXY` (7.0.14 `ENV_VAR_NAMES`); it drops `HTTP_PROXY` (curl ignores it
too) and `NO_PROXY`. Tankard reads all ten from its environment and the shell startup files
(precedence as for `HOMEBREW_*`: the environment first, then the last file; empty means
unset) and passes the eight bin/brew keeps; the other two show in Health as dropped by brew.
`EnvFileParser.parseShell` reads them, plus one expansion: a proxy set to another proxy
assigned earlier in the same file (`export https_proxy=$http_proxy`). The git probes get the
proxies too (`git ls-remote` for the fork status). Health masks a proxy URL's user:password
(`http://•••@proxy:8080`, `ProxySettings.mask`) and the same in the `brew config` and
`brew doctor` text it shows (`maskText`: brew config prints proxy values as they are);
Tankard never logs the environment it passes. Checked on 7.0.14 with a throwaway HOME
(`EnvironmentRealCanary`): a profile's `http_proxy=http://u:p@127.0.0.1:9` gives
`brew config` `http_proxy: http://u:p@127.0.0.1:9`.

Tankard's own URLSession requests (Discover's catalog and install counts, the cask size
probe, the update check) don't use these. URLSession follows the system proxy settings
(System Settings, PAC files included), which is what users expect from a Mac app, and a
shell-profile proxy is meant for command-line tools. Copying it into URLSession would also
mean handling credentials and `no_proxy` matching ourselves.

**brew.env conflicts (0.8.4, `EnvironmentPolicy.brewEnvConflict`).** Every brew.env
setting (as brew reads it: the last file wins) that undoes a value Tankard forces, or one it
denies from the shell, gets a warning in Health ▸ Environment with its reason:
`NO_INSTALLED_DEPENDENTS_CHECK` on (automatic updates pause, as in 0.8.3); the greedy
switches on; in Intelbrew mode a core or brew remote that normalises to something other than
the fork, or an empty `NO_INSTALL_FROM_API`; `NO_AUTOREMOVE` off (Tankard's uninstall sets
it to 1 so only the listed dependencies go); `COLOR`, `VERBOSE`, `VERBOSE_USING_DOTS`,
`DEBUG` on, or `NO_COLOR`/`NO_ENV_HINTS` emptied; `CASK_OPTS` with options Tankard would
drop; `SUDO_ASKPASS` (bin/brew takes it from brew.env, over Tankard's askpass); `CELLAR`;
`CACHE`/`LOGS`; the trust settings and other remotes (a fork remote outside Intelbrew mode
doesn't warn: it is how Intelbrew is configured); and mirrors. On or off follows
env_config.rb: `boolean: true` settings are off for `0`, `false`, `no`, `off`, `nil`;
`boolean: :set` ones are on for any non-empty value (so `HOMEBREW_VERBOSE=0` is on). Tokens
don't warn; `HOMEBREW_PREFIX`, `REPOSITORY`, `LIBRARY`, `BREW_FILE` and
`USER_CONFIG_HOME` aren't read from brew.env at all (bin/brew's `BIN_BREW_EXPORTED_VARS`),
so `parseBrewEnv` skips them too, and it reads `SUDO_ASKPASS` and the lower-case proxies as
bin/brew does.

Mitigations, checked in 7.0.14's source: none of these has a command-line flag that beats
the environment for the commands Tankard runs. `--greedy` is a plain switch with no
negation (cmd/upgrade.rb, cmd/outdated.rb), `uninstall` has no autoremove flag, `--verbose`
and `--debug` can't be turned off, and utils/tty.sh colours shell-side output whenever
`HOMEBREW_COLOR` is set, whatever `HOMEBREW_NO_COLOR` says. The one exception is
`CASK_OPTS`: explicit `--appdir=`-style and `--[no-]binaries` flags beat it
(cask/config.rb's `explicit` over `env`). Tankard doesn't pass them, since forcing
`/Applications` would silently undo a choice the user made deliberately in brew.env; it
warns instead. No variable stops bin/brew reading brew.env (`HOMEBREW_USER_CONFIG_HOME` is
one it won't take), and pointing `XDG_CONFIG_HOME` somewhere empty would hide the user's
file without saying so.

**Which user brew.env (0.8.4).** bin/brew takes the user file from `XDG_CONFIG_HOME`, else
`HOMEBREW_XDG_CONFIG_HOME`, else `~/.homebrew`. Before 0.8.4 Tankard looked it up with its
own `XDG_CONFIG_HOME` but never passed that to brew, so a terminal launch could show one
file while brew read another, and a profile's `XDG_CONFIG_HOME` was never seen at all. Now
both come from one place: `EnvironmentSources.configHomeEnvironment()` (the same pass-through
as the allowed settings), which `BrewEnvironment.build` hands to brew and `load` uses to
pick the brew.env it reads, so Intelbrew detection, the auto-update pause check and Health
read the file brew reads. `parseShell` expands a leading `$HOME`, `${HOME}` or `~` in
`XDG_CONFIG_HOME` (only there); anything else that needs the shell is skipped. bin/brew
passes the value on to Ruby as `HOMEBREW_XDG_CONFIG_HOME` (and `HOMEBREW_USER_CONFIG_HOME`),
so the other files brew keeps in that folder (`trust.json` for `brew trust`, the global
Brewfile, the livecheck watchlist) are now the ones Terminal's brew uses too. The git probes
see it, as git in Terminal does.

**brew.env files** are read by `bin/brew` itself and exported over the top of the
environment Tankard passes, so anything there applies no matter who starts brew (and can
override Tankard's own values): `/etc/homebrew/brew.env`, `<prefix>/etc/homebrew/brew.env`,
then `~/.homebrew/brew.env` (or `$XDG_CONFIG_HOME/homebrew/brew.env`). Tankard doesn't copy
them in, it only lists them in Health ▸ Environment (with the warnings above).

**Mirrors and Tankard's own requests.** Discover and the tap index still fetch
formulae.brew.sh and ghcr.io directly, even with `HOMEBREW_API_DOMAIN` set; following it is
left for later (brew falls back to the default domain when a mirror file is missing, and
Tankard would need the same fallback).

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
  `brew upgrade`. Cancelling it (0.8.3) sends SIGINT first, then SIGTERM after 15 s and
  SIGKILL after 15 s more, so brew can undo the step it was in.
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

## Command-line tool

`swift build -c release` builds `.build/release/tankard`. It is not part of Tankard.app or
the cask.

```
tankard status [--json] [--filter upgrades|source|newer|nobottle|casks]
               [--remote] [--timings] [--brew PATH]
```

Real output from the Intel test VM (core on the fork, brew still on upstream), trimmed:

```
NAME              INSTALLED   CURRENT     STATUS            NOTES
ca-certificates   2026-11-05  2026-11-05  Homebrew bottle   dep
curl-impersonate  2.3.2       2.3.2       Intelbrew bottle
python@3.15       3.15.2      3.15.2      Intelbrew bottle
vim               9.2.1355    9.2.1355    source
xz                5.8.4       5.8.4       Intelbrew bottle  dep
zstd              1.5.7_1     1.5.7_1     Homebrew bottle   dep

20 installed · 19 bottled · 1 source · 0 newer · 0 upgrades (0 with bottles)

Intelbrew mode (homebrew/core origin is https://github.com/d4rkwyng/intelbrew-core)
  core: https://github.com/d4rkwyng/intelbrew-core, branch intelbrew-staging — Intelbrew fork
  brew: https://github.com/Homebrew/brew at 7.0.14 — NOT the d4rkwyng/brew fork
```

- The status counts add up to "installed". The no-bottle and cask counts only appear when
  they aren't zero. In the upgrades bracket, "compile" (formula upgrades with no bottle)
  and "casks" also only appear when they aren't zero.
- `--filter` narrows the table, or the `packages` array with `--json`. The summary still
  counts everything.
- `--remote` gets the brew fork's newest tag with `git ls-remote`, which needs the
  network. Without it, Tankard uses the tags already in the local checkout, which are
  current as of your last `brew update`.
- Exit codes: 0 for success, 1 when brew isn't found or a brew call fails, 2 for a usage
  error.

## Package status

Each installed package gets exactly one `status`. When more than one applies, the first
in this list wins: newer, noBottle, source, bottle.

| status | meaning |
|---|---|
| `bottle` | Poured from a bottle. In Intelbrew mode the label shows whose bottle it was: **Intelbrew bottle** (URL on `github.com/d4rkwyng/intelbrew-core`) or **Homebrew bottle** (`ghcr.io/v2/homebrew/core`, which the fork keeps for `all` bottles and the formulae it hasn't rebuilt). A package whose installed version is older than the tap's shows plain "Bottle". |
| `source` | Built from source (`poured_from_bottle: false`), or a HEAD install. |
| `newer` | The installed version is newer than the tap's current version, and brew doesn't call it outdated. This usually means it was installed from Homebrew's API before core was switched to the fork. brew never downgrades. |
| `noBottle` | The current version has no bottle this Mac can pour, so a reinstall or upgrade would compile. This beats `source`: a source build whose formula has no bottle shows as `noBottle`. |
| `cask` | A cask. Casks have no bottles. A cask can also be `newer`. |

Other fields (see the [JSON schema](#json-output-tankard-status---json-schema-version-1))
cover: upgrade available, whether that upgrade has a bottle, requested or dependency,
pinned, keg-only, and formula or cask.

**Upgrade available** is brew's own `outdated` flag from `brew info --json=v2
--installed`. Tankard never decides that a package is outdated by comparing versions
itself. On the arm64 Mac (23 outdated) and the Intel VM (none), the flag listed exactly
the same packages as `brew outdated --json=v2`, so Tankard skips that second brew call. One
consequence: a cask with `auto_updates true` that is behind the tap is not outdated, which
is brew's rule. `upgradeHasBottle` is whether the current version has a pourable bottle.

**Can this Mac pour the bottle?** Tankard follows brew's own matching rules:

1. Use the exact tag: `sonoma` on Intel, `arm64_sonoma` on Apple silicon.
2. Otherwise use `all`.
3. Otherwise use the newest bottle built for an older macOS on the same CPU. This is how
   an OpenCore Legacy Patcher Mac running Sequoia pours the fork's Sonoma bottles.
4. Finally, the bottle's Cellar must be `:any`, `:any_skip_relocation`, or this
   install's own Cellar. Otherwise brew compiles.

**Replace with Bottle** is offered for a formula built from source (`poured_from_bottle:
false`) whose installed version is the current one, with no upgrade pending, not HEAD, and
a bottle this Mac can pour. brew fails cleanly if there turns out to be no bottle.

## Version comparison

Tankard only compares versions to find `newer` packages. `BrewVersion` and `PkgVersion`
are a Swift port of brew's `Version#<=>` and `PkgVersion#<=>` (`version.rb` and
`pkg_version.rb`, brew 7.0.14). A version is split into tokens: numbers, words, and the
special words alpha, beta, pre, rc, p and .post. The rules:

- Pre-releases sort in this order: alpha < beta < pre < rc < release < p (patch) and
  .post.
- Trailing zeros are ignored (1.0 equals 1.0.0). Numbers compare as numbers, including
  leading zeros and digit runs longer than 64 bits.
- `_N` is the formula revision. It only counts when the versions are otherwise equal:
  1.5.7_1 > 1.5.7, and 1.5.8 > 1.5.7_9.
- `HEAD` and `HEAD-<sha>` count as newer than any release. HEAD installs are never
  reported as `newer`.
- Date versions (2026-11-05), r-numbers (r3222), and cask versions with commas or hash
  suffixes (3.30.14,5f54c81; 3.6.11-0102f49a) are tokenised the same way brew does it.
  Because of that, the hash part can decide the order when the numbers before it are
  equal. That matches brew, even though it is arbitrary.

Known gaps:

- **`version_scheme`.** A formula can bump `version_scheme` to reset version ordering,
  and brew then treats any keg with an older scheme as outdated. The installed entries in
  `brew info` don't include the scheme (only INSTALL_RECEIPT.json has it). Tankard
  doesn't read receipts, so a keg with a newer number under an older scheme could be
  misreported as `newer`. In practice brew already flags such a keg as outdated, and
  outdated packages are never classed as `newer`.
- **Cask `latest`.** It is never compared, so it is never `newer`.
- **Why not call brew to compare?** That would mean `brew ruby`, which is a developer
  command. Running one switches `brew update` onto the default branch, and Intelbrew
  depends on release tags.

## App behaviour in detail

The user guide ([usage.md](usage.md)) says what each feature does. This section keeps the
mechanics behind it.

**Cache first.** The last report is kept in
`~/Library/Caches/net.mindtricks.tankard/status.json`. On launch the window shows it at
once; if it is older than an hour, Tankard asks brew again in the background
(stale-while-revalidate), and again when the window comes back to the front. If a refresh
fails, the data on screen stays and a banner says what went wrong. Revalidating the cache
never runs `brew update`. Sizes (`brew info --sizes`) and, with "Include self-updating
apps" on, `brew outdated --greedy --cask --json=v2` run beside `brew info` and fill in
when they arrive.

**Commands.** Upgrades run one `brew upgrade --formula|--cask <tap>/<name>` per package,
fully qualified so a formula and a cask with the same name can't be confused, with
`HOMEBREW_NO_AUTO_UPDATE=1`, so you get exactly the versions the list showed. After a run,
Tankard re-reads status rather than assuming what changed. `brew update` and every
mutating command go through the one FIFO `CommandQueue`; status reads stay off it. brew's
stdin is `/dev/null` and it has no terminal, so sudo can't read a password from it. For a
cask change (0.8.3) Tankard sets `SUDO_ASKPASS` to its own helper (see *sudo password
dialog* below); when the output still shows sudo failed (Cancel, three wrong passwords, no
helper), the app shows the command to run in Terminal. The upgrade log's `\r` progress
redraws collapse into one line.

**sudo password dialog (0.8.3).** Homebrew passes `-A` to `/usr/bin/sudo` when
`SUDO_ASKPASS` is set (`system_command.rb`, `env_config.rb`), and `bin/brew` keeps
`SUDO_ASKPASS` and every `HOMEBREW_*` variable when it rebuilds its environment. sudo runs
the askpass program as the user (not root), with its prompt as argv[1], and reads the
password from its stdout; a non-zero exit makes sudo fail with "no password was provided".

- *Helper.* `Sources/tankard-askpass` (AppKit, links only `AskpassSupport`), shipped as
  `Tankard.app/Contents/MacOS/tankard-askpass`. Living in Contents/MacOS makes Tankard.app
  its main bundle, so the dialog gets Tankard's icon and Localizable.strings. It is an
  `NSAlert` with an `NSSecureTextField` (no echo, no copy, secure keyboard entry while
  focused). OK writes the password plus a newline to stdout once and wipes that byte
  buffer; Cancel, a 5-minute timeout, or the calling sudo going away exit 1. Stop Now's
  signals to brew's process group (SIGINT, then SIGTERM) reach sudo and the helper too (brew starts sudo without
  a new process group: `pgroup: sudo? ? nil : true` in system_command.rb; sudo itself
  ignores SIGTERM while it waits for a password, the helper doesn't). It
  refuses to run with stdout on a terminal, writes nothing to disk, logs or defaults, and
  never executes anything from its environment.
- *Gate (security review).* Before drawing or reading anything, debug hooks included, the
  helper checks `AskpassGate.decide` (pure, tested) over kernel facts: the parent's
  `proc_pidpath` must be exactly `/usr/bin/sudo` (SIP-protected; never p_comm), and within
  10 processes above sudo (brew's ruby, bash, …) there must be this bundle's own
  `Contents/MacOS/Tankard`, derived from the helper's own `proc_pidpath` (so a symlink
  resolves to the real helper, and a copy outside a `.app/Contents/MacOS/` has no Tankard).
  When the helper carries a Team ID (Developer ID release), that Tankard process must pass
  `SecCodeCheckValidity` and have the same Team ID, which stops a copied helper in a
  home-made bundle next to a program named Tankard. Anything else: exit 1, one
  "refused: …" line on stderr, no window; sudo then fails as on Cancel. Residual risk,
  inherent to Homebrew: brew's prefix is user-writable, so a process that already runs as
  the user can replace `brew` itself, and the real Tankard would then run that brew, which
  could ask through the dialog for a command of its choosing. The same is true of
  `brew` in Terminal.
- *Focus.* macOS 14+ activation is cooperative: a background helper started by sudo can't
  take focus. While a command with `SUDO_ASKPASS` runs, the session polls (every 0.4 s, off
  the main actor) for a process whose `proc_pidpath` is this bundle's helper and whose
  ancestors include this Tankard process (`AskpassProcess.find`); when one appears, Tankard
  calls `NSApp.yieldActivation(to:)` with its `NSRunningApplication` once, on the main
  actor (no NSWorkspace notifications or KVO), and the sheet shows "Waiting for your
  password in the Tankard dialog…" with the Terminal command. The helper calls the
  cooperative `NSApp.activate()` before and just after showing the alert, sets
  `.modalPanel`, `makeKeyAndOrderFront`, `orderFrontRegardless()` (the fallback when focus
  never comes: in front of other apps' windows, a click focuses it), and makes the secure
  field first responder.
- *Context.* `HOMEBREW_TANKARD_ASKPASS_CONTEXT`, set per command by Tankard to the command
  as displayed (`brew upgrade --cask windows-app`), cleaned to one line of at most 400
  characters with no control characters. 0.8.4: the dialog is short: "Tankard needs your
  password", one line derived from the command (`Askpass.step`: "To upgrade windows-app.",
  generic when it isn't a brew install/reinstall/upgrade/uninstall), "Goes only to sudo,
  never stored.", the field, and the command under a collapsed Details disclosure.
  A `HOMEBREW_` name because `bin/brew` drops other unknown variables; verified to reach the
  helper through `brew` → `sudo -A` on brew 7.0.14. The context is not secret.
- *Retry wording.* sudo calls the helper again after a wrong password, from the same sudo
  process. If that sudo started more than 1.5 s before the helper (sudo waits about 2 s after a wrong password), the dialog says the
  password was incorrect (kernel process start time via `sysctl`; no state file).
- *Why not `osascript`.* `display dialog … with hidden answer` would work, but the dialog
  belongs to osascript (its icon, not Tankard's), the context would have to be passed into
  AppleScript source or read with `system attribute`, there is no clean timeout or
  parent-gone handling, and the script would be an unsigned shell wrapper. A small signed
  Mach-O keeps the code that touches the password tiny and reviewable.
- *Which commands.* `AdminPassword.mayNeedSudo`: `install|reinstall|upgrade|uninstall
  --cask` (adopt is `install --cask --adopt`), for sessions and restore steps. Never
  formulae, `brew update`, cleanup, taps, services, or reads. The variables are not in the
  displayed command (the Terminal fallback must ask in Terminal); the log notes it.
- *Before starting.* `AdminPassword.required`: the cask has a `pkg` artifact or an
  `installer` script with `sudo: true` (`BrewInfoJSON.Cask.sudoInstaller`). The upgrade plan
  page opens for those ("needs your administrator password"), and the uninstall sheet says it.
- *Auto-update.* Safe mode skips `required` casks (`AutoUpdateSkip.needsPassword`) and every
  automatic command gets `HOMEBREW_NO_SUDO=1` and no `SUDO_ASKPASS`, even one from
  brew.env: brew then refuses sudo ("…requires sudo, but HOMEBREW_NO_SUDO is set").
- *Timestamp.* Before its first sudo, brew runs `sudo --reset-timestamp`
  (`utils/sudo.sh`), so every brew command asks once; later sudo calls from the same brew
  process reuse sudo's ppid-keyed timestamp (no tty), so they don't ask again.
- *Failure.* `SudoOutcome.classify`: "no password was provided" is a cancel, "N incorrect
  password attempts" a wrong password; both keep the Terminal command in the sheet.
- *Signing.* `bundle-app.sh` builds and copies the helper (lipo for universal);
  `release.sh` signs it first with the hardened runtime, a secure timestamp and identifier
  `net.mindtricks.tankard.askpass`, then seals the app; notarization covers both.
- *Debug hooks* (never set by Tankard, and only after the gate allows the request):
  `TANKARD_ASKPASS_DESCRIBE=1` prints the dialog's text to stderr and exits 1;
  `TANKARD_ASKPASS_SNAPSHOT=<png>` draws the empty dialog to a PNG and exits 1;
  `TANKARD_ASKPASS_RETRY=1` shows the retry wording; `TANKARD_ASKPASS_DETAILS=1` opens
  Details before the snapshot. None reads a password. bin/brew drops
  these names, so in practice they work only in a test harness that is itself under Tankard.

**Download progress (0.8.1).** brew prints no progress when it isn't in a terminal, so
Tankard watches brew's downloads folder. A bottle's size comes from the manifest brew
already fetched; for a cask, one HEAD request to the cask's own URL from `brew info`.
Without a size, the bytes so far and an indeterminate bar.

**Parallel downloads (0.8.3, `Prefetch`).** brew 7's `brew fetch` puts every package it
is given on its download queue, `HOMEBREW_DOWNLOAD_CONCURRENCY` at a time (default `auto`,
twice the CPU cores), also without a terminal. Before an upgrade or install session
(Upgrade All, a selection, a Brewfile's missing packages) and before an automatic run,
Tankard queues one `brew fetch --formula` and one `brew fetch --cask` for each kind with
at least two packages to download (the two flags can't be combined): formulae whose
upgrade pours a bottle and aren't pinned, and casks other than `version :latest`. A
formula that compiles is left to its own step. The user's `HOMEBREW_DOWNLOAD_CONCURRENCY`
(brew.env, the environment or a shell profile) is passed on. Progress counts brew's
"✔︎ Bottle x" / "✔︎ Cask x" / "✘ …" lines (or "Downloaded to:" with concurrency 1;
`FetchOutput`). A download that fails fails no package: that package's own step
downloads it again and fails with brew's own error if it still can't.

**Stop Now, the lock wait and quitting (0.8.3).** Stop Now cancels the queue item, so the
runner's SIGINT, SIGTERM, SIGKILL sequence applies (see *Why the queue isn't just an
actor*); pressed before `posix_spawn` has returned, the stop starts as soon as brew's pid
is known (before 0.8.3 it found no pid and the step ran to the end). It asks
first ("Stop now?") while an upgrade, install, Replace with Bottle, restore or adopt step
runs, but not while that step is downloading or waiting for the lock. A step whose output
is brew's lock failure (`BrewFailure.locked`) waits instead of failing when the session
has a `BrewLockWait`: `BrewLock` derives the lock file from brew's message
(`<prefix>/var/homebrew/locks/<name>.formula|cask|download.lock`, or `update`), and
`lsof -t` on it every 2 s says whether brew in Terminal still holds it, so Tankard never
takes brew's lock itself. Free: the step runs again. After 15 minutes (or 30 lock failures
for one step) it fails as locked. The rest of the queue waits behind it.
Quitting mid-step doesn't leave brew finishing in the background: brew writes into
Tankard's pipe, and once Tankard is gone its next write fails (EPIPE) and brew rolls the
step back. So the quit alert (`QuitPrompt`) offers to wait for the current step or to
stop it as Stop Now does (Quit Now waits up to 35 s for brew to wind down), never to
abandon it. An upgrade session saves a `RunJournal` (the packages, in the settings'
defaults) when it starts and clears it when the run ends in Tankard, even stopped; one
left behind by a quit or a crash becomes "Upgrade the Remaining N Packages" at the next
launch, for those still listed as upgrades, through the Upgrade button's path (the plan,
pins and rules apply again).

**One Tankard at a time (0.8.3, `SingleInstance`).** At launch Tankard looks at other
running copies with its bundle id. Only copies from the same bundle path count, and
demo, snapshot and script runs (read from that process's environment with
`KERN_PROCARGS2`) never do. A copy launched after this app's executable was written to
disk (the later of its mtime and ctime: unzip and brew's move keep the mtime) runs the
same build, so this launch is the duplicate: it activates that copy and quits. Copies
launched before it run a bundle brew has since replaced: they are asked to quit
(`terminate`, never forced), and if one is still running after 5 s an alert says "An
older copy of Tankard is still running" with **Show Older Copy**.

**Background `brew update` (0.8).** Starts at least 3 seconds after launch, once the list
is on screen. Due once per check interval (Settings ▸ General ▸ Check every), or
`HOMEBREW_AUTO_UPDATE_SECS` when that is longer. Any `brew update` counts, including one
run in Terminal: Tankard reads when the brew repository last fetched, as brew's own
throttle does. It re-reads status without measuring sizes again; selection, filter and
search stay. A failure (offline, brew's lock) goes to the system log and
`~/Library/Logs/Tankard/upgrade.log`, and the next try is at most an hour later. Off when
`HOMEBREW_NO_AUTO_UPDATE` is set in the environment, a shell startup file or brew.env.
Never in demo or snapshot runs.

**Notifications for new upgrades.** A check is `brew update` through the queue, then the
normal status read, every N hours, never sooner than 2 minutes after launch. A check
missed during sleep runs at the next wake-up; one that meets a running upgrade or refresh
retries in 15 minutes. The first check after turning notifications on only records what
is outdated; after that, only a new package or a newer version of one already waiting
posts. The baseline is kept in UserDefaults (`notifiedUpgrades`) and not changed by a
failed check. Under `swift run` (no app bundle) notifications are skipped. Since 0.8.2 a
Refresh or Check Now the user asked for (`UserCheckFeedback`) also posts, when the setting
is on and the window isn't in front; otherwise the status bar shows "N new upgrades" or
"No new upgrades" for a few seconds. Upgrades reported this way aren't announced again.
Since 0.8.3 upgrade notifications carry a category with **Upgrade All…** and **Later**
actions; the delegate turns the response into a `NotificationRoute` (a click opens
Installed ▸ Upgrades, Upgrade All… also opens the Upgrade All plan and never starts a run,
Later does nothing, an automatic-update notification opens the Auto-update log).

**Automatic updates (0.5).** AC power comes from IOKit's power source (a battery or UPS
waits); idle time from IOKit's `HIDIdleTime`. Never in the first 5 minutes after launch.
No helper or launch agent. Each upgrade runs with `HOMEBREW_NO_AUTO_UPDATE=1` and
`HOMEBREW_NO_ASK=1`. A formula is skipped when it, an outdated dependency, or any
installed dependent brew would upgrade or rebuild with it has no bottle ("upgrading X
would need Y rebuilt from source; upgrade by hand"). brew's installed-dependents check is
never turned off: doing so could leave Y linked to the old keg's library after a library
bump. Packages with a pinned outdated dependency are skipped too. A running cask app is
matched by the app path and the bundle ids from `brew info`'s artifacts; every automatic
cask upgrade runs with `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`. The log is
`~/Library/Application Support/net.mindtricks.tankard/auto-update-log.json`. Test hooks:
`defaults write net.mindtricks.tankard autoUpdateDryRun -bool true` (plan and log, run no
brew command) and `defaults write net.mindtricks.tankard autoUpdateOnly -array xz` (limit
a run to the named packages; `defaults delete … autoUpdateOnly` removes the limit).
Before the upgrades, one `brew fetch` per kind downloads them (see *Parallel downloads*).
Every automatic command runs with `HOMEBREW_NO_SUDO=1` and no `SUDO_ASKPASS`, and a
brew.env `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` pauses the runs (see *The user's
settings*).

**Vulnerability scan (0.4).** `brew vulns --json`, stdout only (brew prints its warnings on
stderr). brew marks a scan incomplete (`"complete": false`) when it skipped any formula (no
source repository it can match, an untrusted tap, an old keg without an SBOM). Advisories
link to `osv.dev/vulnerability/<id>`; "Fixed upstream in commit abc1234" means OSV only
knows a commit. Findings apply only while the installed version is the one brew checked.
Cached for an hour (`insights.json` next to `status.json`); with the setting on it runs
again after a manual refresh and after every install, upgrade or uninstall. After 60
seconds brew's whole process group is stopped; a failed or timed-out scan keeps the last
result. brew sends each formula's source repository URL and version tag to
`api.osv.dev/v1/querybatch`, then `api.osv.dev/v1/vulns/<id>`.

**Sizes.** `brew info --sizes`: brew's own measurement (kegs, and each cask's Caskroom
folder followed to the app), decimal units rounded to 0.1, so a row can be off by 0.05 of
a unit.

**Installed by you (Requested only before 0.8.2), Depends on, Used by.** All from the
`brew info --json=v2 --installed` data, no extra brew calls. Since 0.8.2 Installed by you is
brew's installed-on-request flag (every cask counts). Before 0.8.2 Requested only was
`brew leaves --installed-on-request`, plus casks nothing depends on; checked against `brew leaves` and `brew leaves -r` on the Intel
VM and the arm64 Mac. Depends on comes from the receipts (recursive, what it was linked
against): on the Intel VM it equals `brew deps --installed` for every formula; on the arm64
Mac for 183 of 202, and the other 19 list a few more (linkage the formula doesn't declare,
such as p11-kit under gnutls). Never fewer. Used by equals `brew uses --installed` for
every formula on both Macs. The tree is built from the receipts' `declared_directly`
entries in brew's order; for a report cached by an older Tankard, the recursive list minus
what its members bring in.

**Uninstall (0.8).** Runs with `HOMEBREW_NO_AUTOREMOVE=1` (brew 7 otherwise runs
`brew autoremove` after every uninstall), then removes exactly the listed dependencies by
name. "Needed by" comes from the receipts' runtime dependencies or a cask's `depends_on`.
Each listed dependency is checked again (`brew info`) right before it goes and kept if it
has since been installed on request, pinned, or needed by something else. brew refuses a
pinned package but still reports success, so a run whose output has brew's refusal is
shown as failed.

**Self-updating casks.** brew's `outdated` skips casks with `auto_updates true` and
`version :latest`. "Include self-updating apps" adds `brew outdated --greedy --cask
--json=v2`; they upgrade with the same `brew upgrade --cask <tap>/<token>`, since brew
upgrades a named cask as if `--greedy` was given. `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1` is
brew's variable for its `--no-quit` switch. The per-app choice is kept per cask (tap
included) and forgotten when the cask is uninstalled through Tankard.

**Adopt Apps (0.8).** Scans /Applications (and one folder below it) and ~/Applications,
and matches against formulae.brew.sh's `cask.json` (Discover's cached copy). Sure match:
the bundle id is one the cask names; likely: same vendor. For a cask whose app updates
itself, only a sure match is ticked. For Needs update first with a sure match, the
`brew install --cask --force` command is shown to copy; Tankard never runs it. brew
doesn't compare the download with the installed app for `auto_updates` casks. Not
available with `HOMEBREW_NO_INSTALL_FROM_API` set.

**App Management (0.8.1).** The welcome sheet's **Check** does what Homebrew does before
changing an app (cask/quarantine.rb): it creates an empty `.tankard-write-test` file at
the top of an app that an installed cask put in Applications, and deletes it at once. It
never touches an app Homebrew doesn't manage. The attempt is also what makes macOS list
Tankard in App Management. Blocks are recognised from brew's "does not have App Management
permissions", macOS's "prevented from modifying apps", or "Operation not permitted" on an
Applications path. **Relaunch Tankard** saves the operation once the relaunch helper has
started; if Tankard is still running after about 10 seconds, the helper doesn't open a
second copy (it writes a line tagged Tankard to the system log with `logger`). Run Again
is offered if the operation is less than 15 minutes old; only the casks that change apps
are kept, and an upgrade whose available version or bottle-or-compile answer changed is
left out. Relaunch is offered only from Tankard.app (not `swift run`) and not while brew
runs. A restore's blocked step is explained without a retry.

**Discover.** Search is debounced and ranked: exact name, then name prefix, other names,
name contains, description; within a tier, bottled before unknown before compiles, and in
normal mode more-installed first. Normal mode: `formulae.brew.sh/api/formula.json` and
`cask.json` (about 32 MB and 19 MB, gzip on the wire), first fetched when Discover opens,
never at launch, kept in `~/Library/Caches/net.mindtricks.tankard/api/` with their ETag;
within an hour used as is, after that revalidated with `If-None-Match`. On failure the
saved copy is used and a banner says so. Install counts:
`formulae.brew.sh/api/analytics/install/{30d,90d,365d}.json` and
`analytics/cask-install/{30d,90d,365d}.json` (about 13 MB together), kept a day with
their ETag. Intelbrew mode never uses formulae.brew.sh (it describes upstream Homebrew):
Discover lists the local taps (`<repository>/Library/Taps/*/*`: file names, the `desc`
line, Aliases), reads each formula's `bottle do` block and `depends_on` lines (no Ruby is
run), and asks `brew info --json=v2 --formula <tap>/<name>…` in batches of up to 40 for
the rows on screen. brew 7 refuses `--eval-all` and won't evaluate every formula of an
untrusted tap, so `brew search --desc` can't do this. Measured on the Intel macOS 14 VM
(8,732 formulae): 5,344 have a bottle that Mac can pour (554 on intelbrew-core); the index
takes about 0.35 to 0.40 s in a release build, search 27 ms, `brew info` for the top 30
rows 0.6 s. If homebrew/cask isn't tapped, Discover says so.

**Intelbrew build times.** When a compile warning is shown, Tankard reads
`https://github.com/d4rkwyng/intelbrew-core/releases/download/metadata/build-times.json`
and caches it for 24 hours in `~/Library/Caches/net.mindtricks.tankard/build-times.json`.
Never in normal mode. A 404, any error, bad JSON, another schema, an empty table or a
response over 5 MB means "no new data": the cached copy stays, and Tankard asks again at
most once an hour (30 s timeout). The estimate is the median (else the last build),
rounded up; hours from 90 minutes; no data means no estimate, never zero.

**Check for Tankard Updates (0.8.1).** One GET to
`api.github.com/repos/d4rkwyng/tankard/releases/latest` with a `Tankard/<version>`
User-Agent. Not in demo mode. Upgrade with Homebrew runs `brew update`, then
`brew upgrade --cask d4rkwyng/tap/tankard` through the queue with
`HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`, so brew doesn't quit the app running it. **Relaunch**
(0.8.3, `RelaunchSequence`) starts the same detached `/bin/sh` helper as the App
Management relaunch (it waits for this pid to exit, then `open -n`s the bundle, and gives
up after about 10 s), closes every sheet in the store's own state (AppKit refuses to
terminate under a modal sheet), and terminates; if Tankard is still running 1.5 s later
it tries once more, then gives up and says so, opening nothing. Before 0.8.3 Relaunch
opened the new copy first, and NSWorkspace's completion handler, isolated to the main
actor but called on LaunchServices' queue, crashed the old one (EXC_BREAKPOINT).

**Clean up.** `brew cleanup -n` (dry run), `brew --cache` and `du -sk` on the cache. When
brew prints no total (it exits with an error on a Mac whose core tap brew 7 calls
untrusted), Tankard shows its own sum of the items, labelled as such, with brew's error.

**Services.** `brew services list --json` when the tab opens (off the queue) and
`brew services info --json -- <name>` for the selection. A service that runs as another
user or from /Library/LaunchDaemons gets no buttons; brew's "Service `x` is started as
`root`" answer, or a sudo prompt, gets the same advice.

**Revert to Standard Homebrew.** Follows d4rkwyng/intelbrew's README ("How do I go back to
upstream Homebrew?"). The script: for each zsh or bash startup file with an Intelbrew line
(`~/.zshenv`, `$ZDOTDIR/.zshenv`, `.zprofile`, `.zshrc`, `.zlogin`, `~/.bash_profile`,
`.bash_login`, `.profile`, `.bashrc`), `cp -p` to `<file>.tankard-backup-<date>`, then
delete the lines that assign `HOMEBREW_NO_INSTALL_FROM_API`, `HOMEBREW_CORE_GIT_REMOTE` or
`HOMEBREW_BREW_GIT_REMOTE` (BSD sed); unset those variables; `git -C <repository> remote
set-url origin https://github.com/Homebrew/brew`; `brew update`. brew.env files are
reported, not edited. The optional `brew untap homebrew/core` is mentioned, not run.
**Uninstall Homebrew** runs the official uninstaller from the Homebrew/install README,
pinned to the detected prefix with uninstall.sh's own `--path` option:
`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" uninstall.sh --path='<prefix>'`.
Without it, a Mac with both /usr/local and /opt/homebrew would lose /opt/homebrew.
Demo mode opens nothing.

**Welcome screen (no brew).** Shown when no brew is found, or `brew --version` fails (with
what it printed). Intel is `uname -m` x86_64, not translated by Rosetta,
`hw.optional.arm64` 0. "Open in Terminal" writes the one-liner to a temporary `.command`
file and opens it, because the installers ask for a password and wait for Return.
Bringing the window to the front also looks for brew again.

**Themes.** Saved in UserDefaults (`appearance`), applied app-wide including sheets,
Settings and the menu-bar menu. Tankard: #1f0d3d to #4a2580, amber #f2a93b. The version
columns are held at 7:1 (installed) and 5.5:1 (unchanged available) in every theme. The
primary action colour: Dark #30d158 with dark text, Light #1a7f37 with white text (5.1:1),
Tankard its amber #f2a93b, Dracula #50fa7b; every text pair is checked at WCAG AA (4.5:1) and the
green against the status bar at 3:1.

**Open at login.** `SMAppService.mainApp`. The login item is tied to the code signature,
so it is reliable with a Developer ID build; an ad-hoc build may be refused or forgotten.
Not tested end to end.

**Menu-bar icon.** A 16×16 pixel-art tankard drawn as a template image (`MenuBarIcon`),
with a foam head only when upgrades are waiting; at most 8 upgrades listed, "99+"
above 99. It reads the same store, cache and refresh as the window. Since 0.8.3 a click on
a line opens the window on it (`MenuBarDestination`): a package row selects it in
Installed and scrolls to it (the search cleared, and a filter that would hide it reset to
All), "N upgrades ready" and "and N more…" the
Upgrades filter, the scan line the Vulnerable filter.

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
| `TANKARD_UPDATE_FEED=<file.json>` | Any mode: Check for Tankard Updates… reads GitHub's answer from this file (a missing file acts as offline). `TANKARD_UPDATE_CHECK=1` checks at launch; `TANKARD_UPDATE_BREW=1` (demo only) acts as if the d4rkwyng/tap cask installed the app. |
| `TANKARD_MENU_DUMP=<file.txt>` | Write the main menu as a text outline (items, shortcuts, "(disabled)", `---` separators) after `TANKARD_SNAPSHOT_DELAY` seconds; `TANKARD_SNAPSHOT_QUIT=1` quits after. Menus can't be captured by the snapshot hook; this is how they are reviewed. 0.8.2: then each pop-up button in the open windows (the More filter), its items with "(disabled)" and "✓" on the selected one. |
| `TANKARD_FILTER=upgrades\|source\|newer\|bottle` | The Installed filter on launch. |
| `TANKARD_DEMO_CLEANUP=1` | Demo only: open Cleanup; `TANKARD_DEMO_CLEANUP_RUN=1` then clicks Clean Up. |
| `TANKARD_DEMO_REPLACE=1` | Demo only: replace the selection with a bottle. |
| `TANKARD_DISCOVER_ALL=1` | Discover's bottle chip off. |
| `TANKARD_DEMO_INSTALL_CONFIRM=1` | Demo only: open "Install (compiles)" for the Discover selection. |
| `TANKARD_DEMO_APPMGMT=1\|fail\|relaunch\|resume` | Demo only: the App Management sheet; `fail` makes cask steps (install, adopt, upgrade, uninstall) fail once with brew's message, then succeed on the retry; `relaunch` shows the sheet's Relaunch Tankard page for a blocked cask (the button does nothing in the demo); `resume` shows the Run again offer that follows a relaunch. |
| `TANKARD_DEMO_ONBOARDING=1\|check` | Demo only: the first-launch welcome sheet; `check` also runs its App Management check (the demo's probe answers "Not allowed yet" without touching a real app). |
| `TANKARD_MENUBAR=0` | Hide the menu-bar icon for this run. |
| `TANKARD_SNAPSHOT_VIEW=menubar\|settings\|about` | Snapshot that view (the menu-bar menu, Settings' General tab, the About panel) instead of the window. |
| `TANKARD_SNAPSHOT_ORIGIN=x,y` | Window origin (screen points) to set first. |
| `TANKARD_SNAPSHOT_LAYOUT=1` | Also print the layout (window, table, rows, cells) to stderr. |
| `TANKARD_LOG_FRAMES=1` | Print every window move or resize, and the table's identity, scroll and column widths each second. |
| `TANKARD_SWITCH_APPEARANCE=<theme>@<s>` | Switch theme at runtime, as Settings does (not saved). |
| `TANKARD_RESELECT=<name>@<s>` | Select another row later, as a click would. |
| `TANKARD_FILTER=pinned\|leaves` | 0.4: the Pinned or Installed by you (0.4–0.8.1: Requested only) filter. |
| `TANKARD_TAB=services` | 0.4: open on Services (reads only). `TANKARD_SERVICE_SELECT=<name>` selects one. |
| `TANKARD_TREE=all` | 0.4: open every dependency-tree row. |
| `TANKARD_DEMO_PINNED=a,b` | Demo only: these start pinned. |
| `TANKARD_DEMO_REPLACED=a,b` | 0.8.2, demo only: these source builds start reinstalled from a bottle (`vim` gives Bottle available 0, hidden in the bar). |
| `TANKARD_DEMO_MANAGE=revert\|uninstall` | Demo only: open that Homebrew menu sheet; `TANKARD_DEMO_TYPED=<word>` pre-types the confirmation. |
| `TANKARD_FILTER=vulnerable\|notes` | 0.4: the Vulnerable or Has notes filter on launch. |
| `TANKARD_DEMO_SCAN=1\|slow\|off` | Demo only: scan for vulnerabilities at launch (`slow`: the scan takes 30 s, to show its progress); `off`: no scan at all, not even on refresh (the Vulnerable filter's "No scan yet"). |
| `TANKARD_DEMO_NOTES=1` | 0.4, demo only: upgrade everything, close the finished sheet; the post-install notes follow. |
| `TANKARD_DEMO_VULN_NOTICE=1` | 0.4, demo only: the menu-bar vulnerability notice on, with nothing seen yet. |
| `TANKARD_DEMO_MENUBAR_SHOW=<package>\|upgrades\|vulnerable` | 0.8.3, demo only: a second after launch, does what a click on that menu-bar panel line does (selects the package in Installed, or opens the Upgrades or Vulnerable list). |
| `TANKARD_SELF_UPDATING=1` | 0.4, demo only: "Include self-updating apps" on. |
| `TANKARD_SNAPSHOT_VIEW=settings-upgrades` | 0.4: Settings → Upgrades. |
| `TANKARD_DEMO_SHEET=taps` | 0.7, demo only: the Taps sheet. `TANKARD_DEMO_TAP_SELECT=<tap>` selects one, `TANKARD_DEMO_TAP_ADD=<user/repo>` opens Add's confirmation, `TANKARD_DEMO_TAP_SHOW=1` clicks Show Installed, `TANKARD_DEMO_TAP_REMOVE=1` asks to remove the selection. |
| `TANKARD_BREW=<path>` | Use this brew instead of `/usr/local/bin/brew` or `/opt/homebrew/bin/brew`. |
| `TANKARD_SEARCH=<text>` | 0.8.3: type this into the Installed search on launch (any mode; a pasted `brew install x` or the "Search Discover for" empty state). |
| `TANKARD_DEMO_PASSWORD=<cask>` | 0.8.3, demo only: that cask runs a `.pkg` installer, so the upgrade plan and the uninstall sheet show "needs your administrator password". The demo's brew is fake; the dialog never appears. |

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
| `arm64-tap-info.json` | 0.7: `brew tap-info --installed --json` on the arm64 Mac (brew 7.0.14, read-only), homebrew/core's and homebrew/cask's name lists trimmed to 25 (8733 and 7828 as captured). The demo copy must stay byte-identical; the Intelbrew demo derives an illustrative list from it. |
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
through the queue, failures, pinned packages left out of Upgrade All and the menu bar,
Requested only, links, services through the queue, root services never reaching brew,
brew's sudo message, the typed confirmations, the revert plan, and its `cp`/`sed` lines run
for real on a temp file. The intel demo also lays the fresh receipts over its fixture, so
its dependency views are realistic.

**Scripted real runs.** `Scripts/e2e.sh SCENARIO...` (`--list`, `--steps`) drives the
real app (no demo) against this Mac's real brew, with a step script per phase
(`TANKARD_E2E=1` and `TANKARD_SCRIPT`; the vocabulary is in `ScriptRunner.swift`,
`ScriptSteps*.swift`). Settings go to a throwaway defaults suite and Tankard's files to
the run's output folder; it installs and removes only its own throwaway packages and taps,
and skips a scenario whose package or tap you already have. 0.8.3 adds the `prefetch`
scenario (two throwaway casks served by a throttled local HTTP server, upgraded through
one `brew fetch --cask`). `Scripts/e2e-selfupdate.sh --old OLD.app --new NEW.app --out
DIR` (0.8.3) runs the self-upgrade end to end on a throwaway tap
(`tankard-e2e-self/tap`, never d4rkwyng/tap): Check for Tankard Updates, Upgrade with
Homebrew and Relaunch with a sheet open, a same-build double launch, and a stale copy
with a sheet open, each passing only with exactly one Tankard left (running NEW after an
upgrade) and no new crash report. It refuses to start while Tankard runs or while
`/Applications/Tankard.app`, its tap or a `tankard` cask exists, and removes all of them
afterwards.
Its script runs set `TANKARD_E2E_SELFUPDATE=1` (the single-instance guard and the
relaunch treat the run as the real app) and `TANKARD_E2E_SELF_TAP` (the tap), with the
steps `check-updates`, `upgrade-self`, `expect-quiet`, `open-sheet` and `relaunch`.

**Opt-in real-brew checks (0.8.3)**, off unless the variable is set:
`TANKARD_REAL_CANCEL_CASK=font-inter Scripts/test.sh --filter V083QueueRobustRealTests`
(installs the cask and clicks Stop Now mid-download: nothing may be installed),
`TANKARD_REAL_LOCK_FORMULA=<tap>/<name>` with the same filter (a second brew holds the
lock on a throwaway outdated formula while Tankard upgrades it), and
`TANKARD_REAL_ENV=1 Scripts/test.sh --filter EnvironmentRealCanary` (a temporary
`~/.zshrc` with `HOMEBREW_NO_ANALYTICS` in a throwaway HOME reaches the real brew;
read-only).

**CI.** `.github/workflows/tests.yml` (0.8.3) runs `swift test` on `macos-15` for pushes
to main and `release-*` branches, pull requests and manual runs, with a read-only token
and no secrets. Changes to Markdown, `docs/` and LICENSE alone don't trigger it. The
release workflow runs the tests again.

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
