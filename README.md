<p align="center"><img src="docs/images/tankard-logo.png" alt="Tankard logo: a pixel-art amber tankard" width="128" height="128"></p>

# Tankard

A native macOS app for Homebrew, for macOS 14 Sonoma and later. Intel comes first; an
arm64 build follows. When the Mac uses [Intelbrew](https://github.com/d4rkwyng/intelbrew)
(Homebrew with prebuilt Intel bottles), Tankard shows whose bottle each package came from
and whether Homebrew is on the Intelbrew forks.

## Status

**Step 2 of 2: the SwiftUI app.** `TankardCore` reads brew's JSON and works out each
package's status; the `tankard` CLI prints it (step 1). **Tankard.app** shows the same data
in a window and runs `brew update` and `brew upgrade` for you (step 2).

**v0.2** adds **Discover** (search every formula and cask, install), **Uninstall**, a
**welcome screen** when Homebrew isn't installed, and **themes** (Dark, Light, System,
Tankard).

The CLI and the app's status reads never change your Homebrew: they run with
`HOMEBREW_NO_AUTO_UPDATE=1`. Only four things in the app change it, and only when you click:
the refresh button (`brew update`), the Upgrade buttons (`brew upgrade`), Install in
Discover (`brew install`) and Uninstall after its confirmation (`brew uninstall`).

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

## The app

### Build and run

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

A release signed with a Developer ID and notarized (below) doesn't need this.

### What it shows

- **Toolbar:** the logo depends on the mode: the Intelbrew "i" mug with "Intelbrew" and
  "Intel bottles for macOS 14+" in Intelbrew mode (the Dock icon switches to the same mug),
  Tankard's amber tankard with "Tankard" and "Homebrew" otherwise. The Installed | Discover
  switch (⌘1, ⌘2), Refresh (⌘R), and search (name, full name, description; in Discover it
  searches Homebrew).
- **Summary strip:** the counts, the upgrades-ready line, and the All / Upgrades / From
  source / Newer filter with counts.
- **Table:** package (with a `dep` tag for dependencies and a second line when there is
  something to say: pinned, deprecated, "upgrade builds from source", "tap has X" for
  newer, "updates itself" for casks), installed version, available version (↑ in blue when
  brew calls it outdated), and the source badge: green bottle ("Intelbrew bottle" or
  "Homebrew bottle" in Intelbrew mode, from `bottleOrigin`; "Bottle" otherwise), orange
  built from source, blue newer, grey no bottle yet, purple cask. A package whose installed
  version is older than the tap's shows plain "Bottle": receipts don't record which bottle
  was poured, so Tankard doesn't guess whose it was.
- **Detail pane:** versions, kegs, bottle tag, bottle origin, requested or dependency,
  install date, tap, where it came from, the exact upgrade command with a copy button, and
  "Open release page" for bottles on GitHub releases (the Intelbrew fork). ghcr.io bottles
  have no page, so there is no link. **Uninstall…** opens a confirmation with the exact
  `brew uninstall --formula|--cask <tap>/<name>` command. When other installed packages
  need it (from their receipts' runtime dependencies, or a cask's `depends_on`), uninstall
  is blocked and the pane and dialog list them. brew refuses such an uninstall too.
- **Status bar:** the fork status in Intelbrew mode (green: core and brew on the forks and
  brew on its newest tag; orange: brew on upstream or behind; red: core not on the fork),
  "Updated N min ago" (hover for the time, and whether it came from the cache), and
  "Upgrade N".
- **Upgrade sheet:** progress, a chip per package, the exact command running, the live log
  (monospace; `\r` progress redraws collapse into one line), "Stop After Current" (lets
  the running package finish and skips the rest; it then becomes "Stop Now", which stops
  the running brew and everything it started), and "Hide" (the run continues; the status
  bar has a button to bring it back). The full log is appended to
  `~/Library/Logs/Tankard/upgrade.log`.
- **Discover:** search every formula and cask (debounced, ranked: exact name, then name
  prefix, other names, name contains, description). Each row has the name, description,
  version, kind, an "installed" mark, and a bottle badge: "Bottle for your Mac", "Intelbrew
  bottle ✓" (Intelbrew mode, bottle on d4rkwyng/intelbrew-core) or "Builds from source".
  The detail pane has the homepage, licence, dependencies (installed ones ticked), the exact
  `brew install --formula|--cask <tap>/<name>` command with a copy button, and Install,
  which runs through the same queue and live-log sheet as upgrades. Where the data comes
  from depends on the mode; see *Network* below.
- **Welcome screen:** when no brew is found (or brew is there but `brew --version` fails,
  with what it printed), the window shows what Homebrew is and how to install it. On an
  Intel Mac (`uname -m` x86_64, not translated by Rosetta, `hw.optional.arm64` 0) the first
  option is Intelbrew, then standard Homebrew; on Apple silicon only Homebrew. Each shows
  the exact one-liner (copyable). "Open in Terminal" writes it to a temporary `.command`
  file and opens that, because the installers ask for a password and wait for Return;
  nothing is run inside the app. "Check again", or bringing the window to the front,
  looks for brew again.
- **Themes:** Settings (⌘,) → Appearance: **Dark** (the default), Light, System (follows
  macOS), and **Tankard**: deep purples from the icon plate (#1f0d3d to #4a2580), amber
  (#f2a93b) for buttons, progress, the segmented pickers and the table selection,
  foam-white text, striped rows, a purple column header, badges re-tinted. Every Tankard
  text colour pair is checked against WCAG AA (4.5:1) by a test, and the version columns
  against 7:1 (installed) and 5.5:1 (unchanged available) in Tankard, Dark and Light.
  Saved in UserDefaults (`appearance`), applied app-wide including sheets.

### How it behaves

- **Cache first.** The last report is kept in
  `~/Library/Caches/net.mindtricks.tankard/status.json`. On launch the window shows it at
  once; if it is older than an hour, Tankard asks brew again in the background
  (stale-while-revalidate), and again when the window comes back to the front. If a
  refresh fails, the data on screen stays and a banner says what went wrong.
- **Refresh runs `brew update` first**, then re-reads status. Automatic revalidation
  never runs `brew update`.
- **Upgrades** run one `brew upgrade --formula <tap>/<name>` (or `--cask`) per package,
  fully qualified so a formula and a cask with the same name can't be confused. They run
  with `HOMEBREW_NO_AUTO_UPDATE=1`, so you get exactly the versions the list showed (the
  refresh button is where `brew update` happens). Failures don't stop the rest. After the
  run, Tankard re-reads status rather than assuming what changed.
- **sudo.** Tankard can't type a password (brew's stdin is `/dev/null`). When brew's output
  shows it needed sudo, the app says so and gives the exact command to run in Terminal.
- **One queue.** `brew update` and every `brew upgrade` go through one strict FIFO queue,
  so two brews never run at once. Status reads stay off the queue.
- **Network: one call of its own, only when you open Discover in normal mode; no
  telemetry.** Everything else comes from brew and git on this Mac. The links out are ones
  you click (release pages, homepages).
  - *Normal mode:* Discover fetches `https://formulae.brew.sh/api/formula.json` and
    `cask.json` (about 32 MB and 19 MB, gzip on the wire) the first time it is opened,
    never at launch. They are kept in `~/Library/Caches/net.mindtricks.tankard/api/` with
    their ETag. Within an hour Tankard uses that copy without asking; after an hour it
    revalidates with `If-None-Match` (a 304 costs no download). If the request fails, the
    saved copy is used and a banner says so. No other host is contacted. Search is in
    memory.
  - *Intelbrew mode:* formulae.brew.sh is never used, because it describes upstream
    Homebrew, not the fork this Mac installs from. Discover lists the local taps
    (`<repository>/Library/Taps/*/*`: file names, the `desc` line, Aliases) and asks
    `brew info --json=v2 --formula <tap>/<name>…` for versions, bottles and licences in
    batches of up to 40, for the rows on screen and the selection. brew 7 refuses
    `--eval-all` and won't evaluate every formula of an untrusted tap, so
    `brew search --desc` can't do this; reading the files is also faster. Measured on the
    Intel macOS 14 VM (8,732 formulae, debug build): index 0.41 s once per Discover open,
    search 27 ms, `brew info` for the top 30 rows 0.6 s, for one row 0.54 s. For
    comparison, one `brew search --formula python` takes 0.56 s and returns names only. If
    homebrew/cask isn't tapped, Discover says "Casks aren't enabled: run `brew tap
    homebrew/cask` (about 620 MB)".

### Demo mode and screenshots

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

### Architecture

```
TankardCore      (step 1) brew JSON, status classification, versions, Intelbrew detection,
                 the Discover catalogue (CatalogEntry, ranking, bottle badges), the tap
                 index, dependents,
                 brew's environment, ProcessRunner, and StreamingProcessRunner (merged
                 stdout/stderr in chunks, same no-shell / clean-env / process-group rules)
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
  Appearance       themes, their UserDefaults persistence, the Tankard palette and its
                   WCAG contrast check
  Demo             fake runners and the bundled fixture copies
  PackageDisplay   badge labels, sub-lines, release-page URLs, commands, summary text,
                   fork summary, sudo detection
TankardApp       the SwiftUI views (App lifecycle), resources (the logo), snapshots
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
`--skip-notarize` stops after signing.

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

## Usage

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
| `bottle` | Poured from a bottle. In Intelbrew mode the label shows whose bottle it was: **Intelbrew bottle** (URL on `github.com/d4rkwyng/intelbrew-core`) or **Homebrew bottle** (`ghcr.io/v2/homebrew/core`, which the fork keeps for `all` bottles and the formulae it hasn't rebuilt). |
| `source` | Built from source (`poured_from_bottle: false`), or a HEAD install. |
| `newer` | The installed version is newer than the tap's current version, and brew doesn't call it outdated. This usually means it was installed from Homebrew's API before core was switched to the fork. brew never downgrades. |
| `noBottle` | The current version has no bottle this Mac can pour, so a reinstall or upgrade would compile. This beats `source`: a source build whose formula has no bottle shows as `noBottle`. |
| `cask` | A cask. Casks have no bottles. A cask can also be `newer`. |

Other fields (see the JSON schema below) cover: upgrade available, whether that upgrade
has a bottle, requested or dependency, pinned, keg-only, and formula or cask.

**Upgrade available** is brew's own `outdated` flag from `brew info --json=v2
--installed`. Tankard never decides that a package is outdated by comparing versions
itself. On the arm64 Mac (23 outdated) and the Intel VM (none), the flag listed exactly
the same packages as `brew outdated --json=v2`, so Tankard skips that second brew call. One consequence: a
cask with `auto_updates true` that is behind the tap is not outdated, which is brew's
rule. `upgradeHasBottle` is whether the current version has a pourable bottle.

**Can this Mac pour the bottle?** Tankard follows brew's own matching rules:

1. Use the exact tag: `sonoma` on Intel, `arm64_sonoma` on Apple silicon.
2. Otherwise use `all`.
3. Otherwise use the newest bottle built for an older macOS on the same CPU. This is how
   an OpenCore Legacy Patcher Mac running Sequoia pours the fork's Sonoma bottles.
4. Finally, the bottle's Cellar must be `:any`, `:any_skip_relocation`, or this
   install's own Cellar. Otherwise brew compiles.

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
      "caskDependencies": []                       // 0.2+, casks only: depends_on casks
    }
  ],
  "timingsMs": { "detect": 13, "info": 623, "git": 26, "total": 637 },   // Intel VM, 20 formulae
  "warnings": []
}
```

Formula versions include the `_N` revision. `bottleOrigin` is only set when the installed
version equals the current one. Receipts don't record which bottle URL was poured, so for
an older keg Tankard can't know.

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

## Licence

BSD-2-Clause, the same licence as Homebrew and Intelbrew. See [LICENSE](LICENSE).
