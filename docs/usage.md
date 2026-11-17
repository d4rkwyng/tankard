# Using Tankard

The details behind the [README](../README.md): what each part of the window does, how
Tankard runs brew, and the command-line tool. Building, the code and releases are in
[architecture.md](architecture.md).

## What the window shows

- **Toolbar:** the logo depends on the mode: the Intelbrew "i" mug with "Intelbrew" and
  "Intel bottles for macOS 14+" in Intelbrew mode (the Dock icon switches to the same mug),
  Tankard's amber tankard with "Tankard" and "Homebrew" otherwise. The Installed | Discover
  switch (⌘1, ⌘2), Refresh (⌘R), and search (name, full name, description; in Discover it
  searches Homebrew).
- **Summary strip:** the counts, the upgrades-ready line, and the All / Upgrades / From
  source / Newer / Bottle available filter with counts. Upgrades has "Skip packages that
  would compile (N with bottles)" when some would; Bottle available has "Replace all".
- **Table:** package (with a `dep` tag for dependencies and a second line when there is
  something to say: pinned, deprecated, "upgrade builds from source", "tap has X" for
  newer, "updates itself" for casks), installed version, available version (↑ in blue when
  brew calls it outdated), and the source badge: green bottle ("Intelbrew bottle" or
  "Homebrew bottle" in Intelbrew mode, from `bottleOrigin`; "Bottle" otherwise), orange
  built from source, blue newer, grey no bottle yet, purple cask. A package whose installed
  version is older than the tap's shows plain "Bottle": receipts don't record which bottle
  was poured, so Tankard doesn't guess whose it was. Upgrades with no bottle for this Mac
  are marked "No bottle: will compile from source" in orange.
- **Detail pane:** versions, kegs, bottle tag, bottle origin, requested or dependency,
  install date, tap, where it came from, the exact upgrade command with a copy button, and
  "Open release page" for bottles on GitHub releases (the Intelbrew fork). ghcr.io bottles
  have no page, so there is no link. **Uninstall…** opens a confirmation with the exact
  `brew uninstall --formula|--cask <tap>/<name>` command. When other installed packages
  need it (from their receipts' runtime dependencies, or a cask's `depends_on`), uninstall
  is blocked and the pane and dialog list them. brew refuses such an uninstall too. An
  upgrade that compiles is flagged here too, with the Intelbrew build time when known, and
  a source build whose version has a bottle gets the *Replace with bottle* box.
- **Vulnerabilities (0.4):** after each status read Tankard runs `brew vulns --json`
  (Homebrew 7; reads stdout only, because brew prints its warnings on stderr). A formula
  with open advisories gets a ⚠ tag in the Package column ("High · 3"; "Vulnerable" when
  OSV gives no severity). The detail pane lists each advisory: its id linked to
  `osv.dev/vulnerability/<id>`, the severity, brew's summary, and "Fixed in X" (a
  release), "Fixed upstream in commit abc1234" (OSV only knows a commit; brew's formula
  may not have a release with it yet) or "No fix listed". brew marks a scan incomplete
  (`"complete": false`) when it skipped any formula (no source repository it can match,
  an untrusted tap, an old keg without an SBOM): Tankard says "partial scan", with the
  reasons, in the filter menu and the detail pane. A formula brew skipped says "Not
  checked by brew vulns". Casks aren't scanned. Findings only apply while the installed
  version is the one brew checked; after an upgrade the next scan decides.
  - The filter menu next to the segments (⚠ and the count when anything is vulnerable)
    has **Vulnerable**, **Has notes** and **Scan for Vulnerabilities Now**. In Vulnerable,
    the green **Upgrade N** runs the normal upgrade (plan sheet, queue) for the vulnerable
    packages that have an upgrade; pinned ones are left out. Its tooltip names the ones
    with no upgrade yet.
  - The scan is cached for an hour (`insights.json` next to `status.json`) and runs again
    after a manual refresh and after every install, upgrade or uninstall. A failed scan
    keeps the last result. On a brew without `vulns` the menu says so.
  - Settings → Upgrades: "Scan for vulnerabilities when refreshing" (on) and "Show new
    vulnerabilities in the menu bar" (off). With the notice on, the menu-bar menu shows
    "New vulnerabilities: …" when a scan finds an advisory that wasn't there at the last
    look (the first scan is the baseline); **Show** opens the Vulnerable list and marks
    them seen.
- **Notes from brew (0.4):** the caveats from `brew info --installed --json=v2`, shown in
  the detail pane under "Notes from brew" (collapsible, copyable), with brew's
  `$HOMEBREW_PREFIX` replaced by this Mac's prefix. The **Has notes** filter lists the
  packages that have them. After an install or upgrade, once the status is re-read, a
  **Post-install notes** sheet lists the notes of what just changed (after the activity
  sheet closes); it appears once per run.
- **Size (0.4):** the Size column (sortable) and "· N GB on disk" in the summary strip
  come from `brew info --sizes`: brew's own measurement (kegs, and each cask's Caskroom
  folder followed to the app), decimal units rounded to 0.1, so a row can be off by
  0.05 of a unit. It runs in the background after a status read and is cached like the
  scan; "On disk" is also in the detail pane.
- **Status bar:** the fork status in Intelbrew mode (green: core and brew on the forks and
  brew on its newest tag; orange: brew on upstream or behind; red: core not on the fork),
  "Updated N min ago" (hover for the time, and whether it came from the cache), and the
  green **Upgrade N** button ("Up to date", muted, when there is nothing to upgrade).
- **Upgrade sheet:** when any selected upgrade compiles, it opens on a plan page first
  (see *Compile warnings*); otherwise it starts at once. Then: progress, a chip per package, the exact command running, the live log
  (monospace; `\r` progress redraws collapse into one line), "Stop After Current" (lets
  the running package finish and skips the rest; it then becomes "Stop Now", which stops
  the running brew and everything it started), and "Hide" (the run continues; the status
  bar has a button to bring it back). The full log is appended to
  `~/Library/Logs/Tankard/upgrade.log`. When it finishes, the status line reads "5 upgraded,
  1 failed" and so on.
- **Discover:** search every formula and cask (debounced, ranked: exact name, then name
  prefix, other names, name contains, description). Each row has the name, description,
  version, kind, an "installed" mark, and a bottle badge: "Bottle for your Mac", "Intelbrew
  bottle ✓" (Intelbrew mode, bottle on d4rkwyng/intelbrew-core) or "Builds from source".
  The detail pane has the homepage, licence, dependencies (installed ones ticked), the exact
  `brew install --formula|--cask <tap>/<name>` command with a copy button, and Install,
  which runs through the same queue and live-log sheet as upgrades. A formula that would
  compile says so, and Install becomes "Install (compiles)" and asks first (see *Discover:
  bottled first*). Where the data comes from depends on the mode; see *Network* under *How it behaves*.
- **Right-click menus.** Installed rows: Upgrade (or "Upgrade (compiles)", through the
  same plan sheet), Replace with Bottle when eligible, Uninstall… (disabled with "needed
  by …" when blocked), Copy Name, Copy Upgrade/Install Command, Open Homepage, Open
  Release Page, Show in Finder (the keg or Caskroom folder), Show Dependencies and Show
  What Uses It (these put a `deps:`/`uses:` token in the search field; clear it to get the
  list back). Discover rows: Install (or "Install (compiles)"), or Show in Installed; Copy
  Name, Copy Install Command, Open Homepage. Menu-bar rows: Upgrade and Copy Name. The
  menus only call what the buttons already do; there is no other way to run brew.
- **Welcome screen:** when no brew is found (or brew is there but `brew --version` fails,
  with what it printed), the window shows what Homebrew is and how to install it. On an
  Intel Mac (`uname -m` x86_64, not translated by Rosetta, `hw.optional.arm64` 0) the first
  option is Intelbrew, then standard Homebrew; on Apple silicon only Homebrew. Each shows
  the exact one-liner (copyable). "Open in Terminal" writes it to a temporary `.command`
  file and opens that, because the installers ask for a password and wait for Return;
  nothing is run inside the app. "Check again", or bringing the window to the front,
  looks for brew again.
- **Themes:** Settings (⌘,) → Appearance: **Dark** (the default), Light, System (follows
  macOS), **Tankard** and **Dracula**. **Tankard**: deep purples from the icon plate
  (#1f0d3d to #4a2580), amber (#f2a93b) for progress, the segmented pickers and the table
  selection, foam-white text, striped rows, a purple column header, badges re-tinted.
  **Dracula**: the [Dracula](https://draculatheme.com) colours (MIT licence): charcoal
  backgrounds, purple accent, Dracula's badge colours, with Tankard's amber kept for
  upgrades. Theme colours by Dracula Theme, used under the MIT licence.
  - The version columns are brighter in every theme: a test holds the installed version
    at 7:1 and an unchanged available version at 5.5:1 against their backgrounds, in
    Tankard, Dracula, Dark and Light.
  - The primary action (Upgrade, Install, Install (compiles), Replace with bottle, Clean
    up, the plan's "Upgrade N", Done) is a green button in every theme: Dark #30d158 with
    dark text, Light #1a7f37 with white text (5.1:1), Tankard #3fb950, Dracula #50fa7b.
    Every text pair is checked at WCAG AA (4.5:1) and the green against the status bar at
    3:1. Cancel, Stop and Uninstall keep the system style.
  - Switching theme keeps the window as it is: the table isn't rebuilt, so the scroll
    position, column widths and selection stay (`Scripts/layout-check.sh` checks this).
  - Saved in UserDefaults (`appearance`), applied app-wide including sheets, Settings and
    the menu-bar menu.

## Menu-bar icon

A mug in the menu bar (`mug` / `mug.fill`, a template image) with the number of upgrades
ready. Its menu lists the upgrades (a hammer on ones that compile), then **Upgrade all**
(opens the window and the upgrade sheet), **Open Tankard**, **Check now** (`brew update`
and a re-read, the same as ⌘R) and **Quit**. It reads the same store, cache and refresh
as the window.

Settings → General → "Show Tankard in the menu bar" (on by default). With it on, closing
the window keeps Tankard running, with the icon and background checks.

## Notifications for new upgrades

Off by default. Turning on "Notify me about new upgrades" is the only time Tankard asks
macOS for notification permission; if macOS says no, the toggle turns back off and the
pane says where to change it.

- A check is `brew update` through the queue, then the normal status read. It is due every
  N hours (1 to 48, default 6), never sooner than 2 minutes after launch; a check missed
  during sleep runs at the next wake-up, and one that meets a running upgrade or refresh
  retries in 15 minutes.
- The first check after turning notifications on only records what is outdated. After
  that, a notification appears only when a new upgrade appears (a package, or a newer
  version of one already waiting); a list that only shrinks posts nothing. The baseline is
  kept in UserDefaults (`notifiedUpgrades`) and not changed by a failed check.
- Under `swift run` (no app bundle) notifications are skipped.

## Open at login

Settings → General, off by default (`SMAppService.mainApp`). The toggle shows the real
state, including "Waiting for approval in System Settings → General → Login Items". The
login item is tied to the code signature, so it is reliable with a Developer ID build; an
ad-hoc build may be refused or forgotten. Not tested end to end.

## Self-updating apps and running apps

Settings → Upgrades (0.4), both off by default:

- **Include self-updating apps.** brew's `outdated` flag skips casks with `auto_updates
  true` and `version :latest`, because those apps usually update themselves. With this
  on, each status read also runs `brew outdated --greedy --cask --json=v2` and lists those
  casks as upgrades too (their row still says "Updates itself"). They upgrade with the
  same `brew upgrade --cask <tap>/<token>`: brew upgrades a named cask as if `--greedy`
  was given. Turning it off takes them out at once.
- **Don't quit running apps during upgrades.** By default brew 7 quits a running app
  before upgrading its cask (when the cask lists it to quit) and opens it again
  afterwards. With this on, cask upgrades get `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`, brew's
  variable for its `--no-quit` switch (`man brew`), and the command shown in the detail
  pane and the upgrade sheet starts with it.

## Compile warnings

One classification ("bottle or compile?") is shared by the upgrade list, the upgrade
sheet, the menu bar and Discover.

- When any selected upgrade compiles, the upgrade sheet opens on a plan page: every
  package marked bottle or "No bottle: will compile from source", with "Skip packages that
  would compile" and a green **Upgrade N** button. When nothing compiles it starts at
  once.
- In Intelbrew mode a warning also says how long the formula took on the Intelbrew
  builder: the median (else the last build), rounded **up**, "at least ~24 min on the
  Intelbrew builder" (hours from 90 minutes). A formula with no data has no estimate,
  never zero. Expect longer on an older Mac.

## Discover: bottled first

- In Intelbrew mode, indexing the local taps also reads each formula's `bottle do` block
  and `depends_on` lines (no Ruby is run), so every formula's bottle is known before any
  `brew info`. On the Intel macOS 14 VM: 5,344 of 8,732 formulae have a bottle that Mac
  can pour (554 on intelbrew-core, the rest Homebrew's bottles that the fork keeps; both
  count as "Has Intel bottle"). The scan adds about 50 ms; the whole index takes about
  0.35 to 0.40 s in a release build.
- The **Has Intel bottle (X of Y)** chip is on by default in Intelbrew mode and hides
  formulae known to compile (unknown ones and casks stay). Normal mode has "Has bottle",
  off by default.
- Within one relevance tier, bottled ranks before unknown before compiles; relevance still
  wins.
- The detail pane warns "No Intelbrew bottle yet. Installing compiles from source…" and
  lists dependencies that would also compile ("+N dependencies also compile: …"). Install
  becomes **Install (compiles)** and asks first, with the exact command.

## Clean up

The toolbar's trash button (or View → Clean Up…) opens a sheet that runs `brew cleanup -n`
(a dry run, read-only), `brew --cache` and `du -sk` on the cache, and shows what would be
removed, how much space it frees and the download cache's size. **Clean up** then runs
`brew cleanup` through the queue with the live log. When brew prints no total (it exits
with an error on a Mac whose core tap brew 7 calls untrusted), Tankard shows its own sum
of the items, labelled as such, with brew's error.

## Replace with bottle

A formula built from source (`poured_from_bottle: false`) whose installed version is the
current one, with no upgrade pending, not HEAD, and a bottle this Mac can pour, gets a
**Bottle available** badge ("Intelbrew bottle available" when the bottle is on
intelbrew-core) and a **Replace with bottle** button in the detail pane. It runs
`brew reinstall --force-bottle --formula <tap>/<name>`; brew fails cleanly if there turns
out to be no bottle. The Bottle available filter has **Replace all**.

## App Management

macOS asks before one app updates or deletes another (System Settings → Privacy &
Security → App Management). Only cask upgrades and cask uninstalls need it; formulae,
installs and Replace with bottle never do.

- Before the first cask upgrade or uninstall, a sheet explains this, with a button that
  opens the App Management pane (falling back to Privacy & Security). "I've done this" or
  "Not now" both remember that you've seen it and carry on.
- When brew's output shows the block ("does not have App Management permissions",
  "prevented from modifying apps", or "Operation not permitted" on an /Applications path),
  the sheet comes back and offers one retry through the queue.
- The permission is tied to the code signature: an ad-hoc build needs it again after every
  rebuild, a Developer ID build keeps it across updates.

## About and Help

Tankard → About Tankard shows "Version 0.3.0" (no build number), "Made by d4rkwyng", links
to the project and to Intelbrew (in Intelbrew mode, "Intelbrew bottles from
d4rkwyng/intelbrew"), the licence, and that Tankard is an independent app for
[Homebrew](https://brew.sh), not affiliated with or endorsed by the Homebrew project. The
Help menu has "Tankard on GitHub" and "Report an Issue…".

## How it behaves

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
- **One queue.** `brew update` and every command that changes Homebrew (upgrade,
  install, uninstall, reinstall, cleanup) go through one strict FIFO queue, so two brews
  never run at once. Status reads stay off the queue.
- **Network: two requests of its own, each only in one mode and only when needed; no
  telemetry.** Everything else comes from brew and git on this Mac. The links out are ones
  you click (release pages, homepages, the About panel).
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
  - *Intelbrew mode, build times:* when a compile warning is shown (upgrade plan, the
    Upgrades list, the detail pane, Discover's detail), Tankard reads
    `https://github.com/d4rkwyng/intelbrew-core/releases/download/metadata/build-times.json`
    and caches it for 24 hours in `~/Library/Caches/net.mindtricks.tankard/build-times.json`.
    Never in normal mode. A 404, any error, bad JSON, another schema, an empty table or a
    response over 5 MB means "no new data": the cached copy stays in use, and Tankard asks
    again at most once an hour (30 s timeout).

## Command-line tool

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

Other fields (see the [JSON schema](architecture.md#json-output-tankard-status---json-schema-version-1)) cover: upgrade available, whether that upgrade
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
