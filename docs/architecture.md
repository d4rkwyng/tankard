# Architecture

[README](../README.md) · [Using Tankard](usage.md) · [Development](development.md) · **Architecture** · [Releasing](releasing.md)

## Layers

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

## How the app behaves

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
