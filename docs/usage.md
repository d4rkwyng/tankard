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
  is blocked and the pane and dialog list them. brew refuses such an uninstall too. A
  pinned package is blocked too (brew refuses it but still reports success); the dialog
  offers **Unpin and Uninstall**. Dependencies that nothing else would need afterwards
  are listed ("No longer needed by anything") with **Also remove these** (on by
  default, as brew's own uninstall would remove them): Tankard uninstalls exactly those
  by name, with brew's autoremove off, so packages that were already unused stay. Each
  one is checked again (`brew info`) right before it goes, and kept if it has since been
  installed on request, pinned, or needed by something else; the log says why. An
  upgrade that compiles is flagged here too, with the Intelbrew build time when known, and
  a source build whose version has a bottle gets the *Replace with bottle* box.
- **Vulnerabilities (0.4):** on **Scan Now** (Settings → Upgrades) or **Homebrew ▸ Scan for
  Vulnerabilities**, or after each status
  read once "Scan for vulnerabilities when refreshing" is on, Tankard runs `brew vulns --json`
  (Homebrew 7; reads stdout only, because brew prints its warnings on stderr). A formula
  with open advisories gets a ⚠ tag in the Package column ("High · 3"; "Vulnerable" when
  OSV gives no severity). The detail pane lists each advisory: its id linked to
  `osv.dev/vulnerability/<id>`, the severity, brew's summary, and "Fixed in X" (a
  release), "Fixed upstream in commit abc1234" (OSV only knows a commit; brew's formula
  may not have a release with it yet) or "No fix listed". brew marks a scan incomplete
  (`"complete": false`) when it skipped any formula (no source repository it can match,
  an untrusted tap, an old keg without an SBOM): Tankard says "partial scan", with the
  reasons, in Settings → Upgrades and the detail pane. A formula brew skipped says "Not
  checked by brew vulns". Casks aren't scanned. Findings only apply while the installed
  version is the one brew checked; after an upgrade the next scan decides.
  - While a scan runs, the status bar and the menu-bar panel show a spinner, "Scanning N
    formulae…", the elapsed time and **Stop** (which stops brew vulns); afterwards
    "Scanned N · found M" (or "partial scan", "Scan stopped", "Scan timed out").
  - The More pop-up next to the segments (⚠ and the count when anything is vulnerable)
    has **Pinned**, **Requested only**, **Vulnerable**, **Has notes** and **Deprecated**. In Vulnerable,
    the green **Upgrade N** (in the filter's header) runs the normal upgrade (plan sheet, queue) for the vulnerable
    packages that have an upgrade; pinned ones are left out. Its tooltip names the ones
    with no upgrade yet. A header above the list shows the last scan ("Scanned 42 · found 2
    · 5 min ago", or "Not scanned yet") with **Scan Now**, or, while a scan runs, its
    progress and **Stop**. When the list is empty it says why ("No scan yet", "No known
    vulnerabilities", "Scan failed") and offers Scan Now there too. It is the same scan as
    Homebrew ▸ Scan for Vulnerabilities, and greys out when that does.
  - The scan is cached for an hour (`insights.json` next to `status.json`) and, with the
    setting on, runs again after a manual refresh and after every install, upgrade or
    uninstall. A scan still running after 60 seconds is stopped (brew's whole process
    group) and the strip says "Scan timed out". A failed or timed-out scan keeps the last
    result. On a brew without `vulns` the menu says so.
  - Settings → Upgrades: "Scan for vulnerabilities when refreshing" (off: brew sends your
    installed formula names and versions to OSV.dev, so it waits for you to opt in) and "Show new
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
  In normal mode the detail pane also shows **Installs**: the 30, 90 and 365-day counts
  from Homebrew's public analytics (the Installed detail pane shows them too once Discover
  has loaded them), and search puts more-installed packages first among equally good
  matches. Not in Intelbrew mode.
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
ready. Its menu lists the upgrades (a hammer on ones that compile), then **Upgrade All**
(opens the window and the upgrade sheet), **Open Tankard**, **Check Now** (`brew update`
and a re-read, the same as ⌘R) and **Quit**. It reads the same store, cache and refresh
as the window.

Settings → General → "Show Tankard in the menu bar" (on by default). With it on, closing
the window keeps Tankard running, with the icon and background checks.

## Background brew update (0.8)

On by default. Settings → General → "Check for new versions in the background".

- After the list is on screen (at least 3 seconds after launch), and from then on while
  Tankard runs, Tankard runs `brew update` when one is due, then re-reads status (without
  measuring sizes again) so the upgrade counts are current. Selection, filter and search
  stay as they are.
- It is due once per check interval: Settings → General → Check every (1 to 48 hours, 6 by
  default), or `HOMEBREW_AUTO_UPDATE_SECS` when that is longer. Any `brew update` counts,
  including one run in Terminal (Tankard reads when the brew repository last fetched, as
  brew's own throttle does).
- `brew update` updates Homebrew and its package lists (taps, formula and cask data). It
  installs and upgrades none of your packages.
- It runs through the queue, so never beside another brew command; while something else
  uses brew it waits. An upgrade, install or uninstall started meanwhile waits for it, and
  its sheet says "Waiting for brew update to finish…". The status bar shows "Checking for
  updates…".
- A failure (offline, brew's lock) is not shown: it goes to the system log and
  `~/Library/Logs/Tankard/upgrade.log`, and the next try is at most an hour later.
- Off when `HOMEBREW_NO_AUTO_UPDATE` is set (in the environment, a shell startup file or
  brew.env; Settings says where, and the toggle is disabled). Never in demo or snapshot
  runs. Notifications for new upgrades use the same update.

## Notifications for new upgrades

Off by default. Turning on "Notify me about new upgrades" (or, 0.5, automatic updates) is
the only time Tankard asks macOS for notification permission; if macOS says no, this
toggle turns back off and the pane says where to change it.

- A check is `brew update` through the queue, then the normal status read. It is due every
  N hours (1 to 48, default 6), never sooner than 2 minutes after launch; a check missed
  during sleep runs at the next wake-up, and one that meets a running upgrade or refresh
  retries in 15 minutes.
- The first check after turning notifications on only records what is outdated. After
  that, a notification appears only when a new upgrade appears (a package, or a newer
  version of one already waiting); a list that only shrinks posts nothing. The baseline is
  kept in UserDefaults (`notifiedUpgrades`) and not changed by a failed check.
- Under `swift run` (no app bundle) notifications are skipped.

## Automatic updates (0.5)

Settings → Upgrades → "Upgrade packages automatically". **Off by default.** It is
separate from the notifications above (both can be on, and that one stays off by default
too); they share one timer.

- **Schedule**: every day or every week (pick the weekday), at a time (default 03:00).
  Each scheduled time runs once. Turning it on, or changing the schedule, never runs a
  time that has already passed today; a time missed because the Mac slept or Tankard
  wasn't open runs once, at the next chance, until the next scheduled time replaces it.
- **When**: only while Tankard runs (the menu-bar icon keeps it running after the window
  closes; with the icon off, nothing runs once the window is closed). Only on AC power
  (IOKit's power source: a battery or UPS waits), only after 10 minutes without keyboard
  or mouse input (IOKit's `HIDIdleTime`), never in the first 5 minutes after launch, and
  never while brew is busy. There is no helper or launch agent.
- **Safe mode, always** (Settings lists these rules):
  - `brew update` first, then one `brew upgrade --formula|--cask <tap>/<name>` per
    package through the same queue as everything else (no sheet opens). Each runs with
    `HOMEBREW_NO_AUTO_UPDATE=1` and `HOMEBREW_NO_ASK=1`.
  - Bottles only: a formula with no bottle is skipped, and so is one whose outdated
    dependencies (which brew would upgrade with it) have none. After an upgrade, brew
    also upgrades (or rebuilds) outdated dependents; when one of those (or anything that
    chain would reach) has no bottle, the formula is skipped too, logged as "upgrading X
    would need Y rebuilt from source; upgrade by hand", and stays in the Upgrades list.
    brew's installed-dependents check is never turned off: doing so could leave Y linked
    to the old keg's library after a library bump.
  - Pinned packages are skipped (the 0.4 rule), and so are packages with a pinned
    outdated dependency.
  - Casks never quit an app: a cask whose app is running is skipped (matched by the app
    path and the bundle ids from `brew info`'s artifacts). With "Don't quit running apps"
    on it is upgraded instead, and every automatic cask upgrade runs with
    `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`, so an app opened mid-run isn't quit either.
    Self-updating casks count only when "Include self-updating apps" is on.
  - Tankard's own cask is never upgraded automatically. When brew lists an upgrade for it,
    the menu-bar menu shows "Tankard 0.x available" (`brew upgrade --cask tankard`).
- **Reporting**: a notification after a run that upgraded or failed something (with the
  notification permission above; nothing when there was nothing to do or everything was
  skipped), the
  **Auto-update log** (Settings → Upgrades → Show Auto-update Log…, or click the menu-bar
  line): the last 20 runs, each with the time, what was upgraded (old → new), what was
  skipped and why, and failures. It is kept in
  `~/Library/Application Support/net.mindtricks.tankard/auto-update-log.json`; brew's
  full output goes to `~/Library/Logs/Tankard/upgrade.log` as for any upgrade. The
  menu-bar menu shows "Last auto-update: today 03:04 · 4 upgraded".
- Testing hook: `defaults write net.mindtricks.tankard autoUpdateDryRun -bool true` makes a
  due run plan and log what it would do without running any brew command.
  `defaults write net.mindtricks.tankard autoUpdateOnly -array xz` limits a run to the
  named packages (everything else is out of scope); `defaults delete … autoUpdateOnly`
  removes the limit.

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
  was given. Turning it off takes them out at once. They count like any other upgrade
  (Upgrade all, the menu-bar number, notifications for new upgrades), except a pinned one.
- **Don't quit running apps during upgrades.** By default brew 7 quits a running app
  before upgrading its cask (when the cask lists it to quit) and opens it again
  afterwards. With this on, cask upgrades get `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`, brew's
  variable for its `--no-quit` switch (`man brew`), and the command shown in the detail
  pane and the upgrade sheet, and the one Copy Upgrade Command copies, starts with it.

**Per app (0.8).** The detail pane of a cask that updates itself has an **Updates**
choice, also offered in Adopt Apps:

- **Follow the setting** (the default): as above.
- **App updates itself**: Tankard leaves its upgrades out of Upgrade all, the counts,
  notifications and auto-update. `brew upgrade` in Terminal can still upgrade it.
- **Homebrew updates it**: every newer version is listed and upgraded, with "Include
  self-updating apps" on or off.

The choice is kept per cask (tap included) and forgotten when the cask is uninstalled
through Tankard.

## Adopt Apps (0.8)

Homebrew ▸ Adopt Apps… scans /Applications (and one folder below it) and ~/Applications
for apps you installed by hand, and matches them to casks in Homebrew's cask list
(formulae.brew.sh's `cask.json`, the copy Discover caches). Apple's apps, App Store apps
and apps Homebrew already manages aren't listed. The scan changes nothing.

- **Ready to adopt**: the installed version is the one the cask installs, or the app
  updates itself (brew doesn't compare those).
- **Needs update first**: brew adopts only the exact version the cask installs. Update the
  app with its own updater, then Scan Again. For a sure match the `brew install --cask
  --force` command that would replace the app is shown to copy; Tankard never runs it.
- **Can't adopt**: the cask runs an installer package (brew ignores `--adopt` for those
  and runs the installer again), the app is part of a suite folder, it isn't where the cask
  installs it, the cask is disabled, the app has no version brew can compare, or it is a
  symbolic link.
- **No cask**.

Each match says how sure it is: **Sure match** (the app's bundle id is one the cask
names), **Likely match** (same vendor) or **Name only**. Name-only matches are never ticked
for you; for a cask whose app updates itself, only a sure match is. When several casks
fit one app, you pick the cask.

**Adopt** shows a confirmation first: brew downloads each cask and records it as installed,
and the app stays where it is. For apps that don't update themselves, brew checks the
download against the installed app and stops for that app if it doesn't match; apps that
update themselves are listed as adopted without a version check. From then on Homebrew
owns the app: `brew upgrade` replaces it with the cask's version, and uninstalling the cask
(in Tankard or with `brew uninstall`) deletes the app. A name-only match you ticked gets a
warning. Then `brew install --cask --adopt <tap>/<name>` runs once per cask through the
queue with a live log, and the self-update choices are saved for the apps whose adopt
succeeded.

Adopt Apps needs formulae.brew.sh's cask list, so it isn't available in Intelbrew mode or
with `HOMEBREW_NO_INSTALL_FROM_API` set; the sheet says so.

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

Homebrew ▸ Clean Up… opens a sheet that runs `brew cleanup -n`
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

## Welcome sheet (0.8.1)

The first time Tankard opens with a working Homebrew, a welcome sheet shows over the list
(once; **Done** closes it for good). It has two cards:

- **Allow App Management**: Open System Settings, **Check**, and Relaunch Tankard. Check
  does what Homebrew itself does before changing an app (cask/quarantine.rb): it creates an
  empty `.tankard-write-test` file at the top of an app that an installed cask put in
  Applications, and deletes it at once. It never touches an app Homebrew doesn't manage, and
  runs only when you click it. "Not allowed yet" means macOS refused the write; the attempt
  is also what makes macOS list Tankard in App Management and show its notice.
- **Adopt Apps**, once the Adopt scan (run in the background; the sheet doesn't wait)
  finds apps you installed yourself that a cask can manage. Adopt Apps… opens that sheet.
  The card stays hidden when the scan finds none or fails (Intelbrew mode has no scan).

A line says that brew update runs in the background and that Settings → General turns it
off. The welcome never shows in demo, script, e2e or snapshot runs
(`TANKARD_DEMO_ONBOARDING=1|check` shows it in the demo).

## App Management

macOS asks before one app installs, updates or deletes another (System Settings → Privacy &
Security → App Management). Since 0.8.1 every action that writes into an Applications
folder counts: installing a cask (from Discover, a Brewfile, a Health replacement), Adopt
Apps (`brew install --cask --adopt` changes the app you already have), upgrades,
uninstalls, a restore point's cask reinstall, and auto-update. Formulae, fonts and other
casks with no app, and Replace with bottle never need it.

- Before the first such action, a sheet explains this, with a button that opens the App
  Management pane (falling back to Privacy & Security). "Not now" remembers that you've
  seen it and carries on.
- "I've done this" turns the sheet to **Relaunch Tankard**: macOS applies the permission to
  a process started after it (its own dialog says an app "will not be able to update or
  delete other applications until it is quit"). Relaunching quits Tankard and starts it
  again; once the package list has loaded, the activity sheet offers **Run again** for the
  operation, if it is less than 15 minutes old. Nothing runs until you click it, and then it
  goes the normal way: an upgrade through the compile plan and pins, an uninstall through its
  confirmation (which works out the unused dependencies again and rechecks each). Only the
  casks that change apps are kept (for an uninstall, the package you chose). An upgrade
  whose available version or bottle-or-compile answer has changed since, or anything already
  done, is left out, and the sheet says so. "Continue without relaunching" runs it straight
  away instead.
  Relaunch is offered only from Tankard.app (not `swift run`) and not while brew runs.
- When brew's output shows the block (brew's "does not have App Management permissions",
  macOS's "prevented from modifying apps", or "Operation not permitted" on an Applications
  path), the step's failure says "macOS blocked changing an app", in the sheet and in
  History, and the sheet comes back with the same relaunch offer. A restore's blocked step
  is explained without a retry: run the restore again from Restore Points.
- Auto-update has no sheet: a blocked cask counts as failed with that reason, the
  notification says to allow Tankard and relaunch it, and the explainer shows again before
  the next cask change you make.
- The permission is tied to the code signature: an ad-hoc build needs it again after every
  rebuild, a Developer ID build keeps it across updates.

## Pins (0.4)

- **Pin** in the detail pane or the right-click menu runs `brew pin --formula|--cask
  <tap>/<name>` through the queue, then re-reads status; **Unpin** runs `brew unpin`. brew
  7.0.14 pins casks too. The command is shown (and copyable) in the pin box.
- A pinned package has a blue "pinned" tag in the table and a box in the detail pane. Its
  own Upgrade button is disabled ("Pinned: unpin it first") and the right-click menu shows
  "Upgrade x (pinned)", greyed out: `brew upgrade` won't upgrade a pinned package.
- **Upgrade all** (the status bar, the menu bar, notifications) and **Upgrade vulnerable
  packages** leave pinned packages out, as `brew upgrade` does. The Upgrades filter still
  lists them, and the status bar says "N pinned upgrades not included (…)".
- The **Pinned** filter is in the menu next to the segmented filter.

## Requested only, Depends on, Used by and the tree (0.4)

All from the `brew info --json=v2 --installed` data Tankard already reads; no extra brew
calls.

- **Requested only** (the filter menu): installed on request, and nothing installed needs
  it. For formulae that is `brew leaves --installed-on-request`; casks nothing depends on
  count too. Checked against `brew leaves` and `brew leaves -r` on the Intel VM and the
  arm64 Mac.
- **Depends on (N)**: every installed package it needs, from its receipt (recursive, what
  it was linked against). On the Intel VM this equals `brew deps --installed` for every
  formula; on the arm64 Mac it does for 183 of 202 formulae, and the other 19 list a few
  more (linkage the formula doesn't declare, such as p11-kit under gnutls, which brew deps
  leaves out). Never fewer.
- **Used by (N)**: installed packages whose receipts list it. Equals
  `brew uses --installed` for every formula on both Macs.
- Each name is a link: clicking it selects that package (clearing a filter or search that
  would hide it).
- **Dependency tree**: collapsed under the links; open it for `brew deps --tree
  --installed`, built from the receipts' `declared_directly` entries in brew's order. Each
  row expands, and a dependency already above in its branch is marked instead of repeated.
  For a report cached by an older Tankard (no `declared_directly`), the tree uses the
  recursive list minus what its members bring in.

## Services (0.4)

The Services tab (⌘3) runs `brew services list --json` when opened (a read, off the queue),
and `brew services info --json -- <name>` for the selected service. **Reload** reads the list
again. The toolbar search filters by name.

- The table: name, status (Running, Scheduled, Stopped, Error with its exit code, Not
  running, Unknown, Other), user, exit code and plist path.
- The pane: user, PID, exit code, launchd label, plist, log and error log paths, and the
  command it runs, then the actions with their exact commands. A service that isn't loaded
  gets **Start** (which also registers it to launch at login); a loaded one gets **Stop**
  (which also unregisters it) and **Restart**. They run through the queue, then the list is
  read again.
- **Only your own services.** A service that runs as another user (root, after `sudo brew
  services start`) or from /Library/LaunchDaemons gets no buttons: the pane shows the `sudo
  brew services …` commands to run in Terminal and an Open Terminal button (which only opens
  Terminal). If brew answers "Service `x` is started as `root`. Try: sudo brew services …",
  or sudo asks for a password, Tankard shows the same advice.

## Homebrew menu (0.4)

The Homebrew menu holds everything that runs brew or looks at the Homebrew install, in
groups from the most used to the least:

- **Refresh** (⌘R, the same as the toolbar button) and **Scan for Vulnerabilities**;
- **Health…** and **History…**;
- **Clean Up…** and **Remove Unused Dependencies…** (both show what they remove first);
- **Taps…**, **Adopt Apps…** and **Restore Points…**;
- **Revert to Standard Homebrew…** (Intelbrew mode only) and **Uninstall Homebrew…**, last.

Brewfiles are in the File menu (**Check Brewfile…**, **Export Brewfile…**), the tabs in
the View menu (Installed ⌘1, Discover ⌘2, Services ⌘3).

Revert and Uninstall Homebrew each open a sheet that shows exactly what will run, need a word typed, and then write
a `.command` script and open it in Terminal. The script lists the commands again and waits
for Return; nothing runs inside the app. Demo mode opens nothing.

- **Revert to Standard Homebrew…** (only in Intelbrew mode) follows d4rkwyng/intelbrew's
  README ("How do I go back to upstream Homebrew?"). Type `revert`. The script:
  1. for each zsh or bash startup file with an Intelbrew line (`~/.zshenv`,
     `$ZDOTDIR/.zshenv`, `.zprofile`, `.zshrc`, `.zlogin`, `~/.bash_profile`,
     `.bash_login`, `.profile`, `.bashrc`): `cp -p` it to `<file>.tankard-backup-<date>`,
     then deletes the lines that assign `HOMEBREW_NO_INSTALL_FROM_API`,
     `HOMEBREW_CORE_GIT_REMOTE` or `HOMEBREW_BREW_GIT_REMOTE` (with BSD sed; the sheet lists
     the exact lines first);
  2. unsets those three variables (the README says to open a new terminal here; the script
     runs in a shell that read the old profile);
  3. `git -C <repository> remote set-url origin https://github.com/Homebrew/brew`;
  4. `brew update`.

  brew.env files that set an Intelbrew variable are reported, not edited (the installer
  never writes them). The README's optional `brew untap homebrew/core` is mentioned, not
  run.
- **Uninstall Homebrew…** warns that it removes every installed package, needs
  `uninstall` typed, then runs Homebrew's official uninstaller, verbatim from the
  Homebrew/install README:
  `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"`.
  It asks once more itself. In Intelbrew mode the sheet notes that the profile lines stay.

## About and Help

Tankard → About Tankard shows "Version <x.y.z>" (e.g. "Version 0.6.1"; no build number), "Made by d4rkwyng", links
to the project and to Intelbrew (in Intelbrew mode, "Intelbrew bottles from
d4rkwyng/intelbrew"), the licence, and that Tankard is an independent app for
[Homebrew](https://brew.sh), not affiliated with or endorsed by the Homebrew project. The
Help menu has "Tankard Help" (this guide, on GitHub), "Tankard on GitHub" and "Report an
Issue…".

## How it behaves

- **Cache first.** The last report is kept in
  `~/Library/Caches/net.mindtricks.tankard/status.json`. On launch the window shows it at
  once; if it is older than an hour, Tankard asks brew again in the background
  (stale-while-revalidate), and again when the window comes back to the front. If a
  refresh fails, the data on screen stays and a banner says what went wrong.
- **Refresh runs `brew update` first**, then re-reads status. Revalidating the cache
  never runs `brew update`; the background update (on by default, see *Background brew
  update*) is the one that runs on its own.
- **Upgrades** run one `brew upgrade --formula <tap>/<name>` (or `--cask`) per package,
  fully qualified so a formula and a cask with the same name can't be confused. They run
  with `HOMEBREW_NO_AUTO_UPDATE=1`, so you get exactly the versions the list showed (the
  refresh button and the background update are where `brew update` happens). Failures don't stop the rest. After the
  run, Tankard re-reads status rather than assuming what changed.
- **sudo.** Tankard can't type a password (brew's stdin is `/dev/null`). When brew's output
  shows it needed sudo, the app says so and gives the exact command to run in Terminal.
- **One queue.** `brew update` and every command that changes Homebrew (upgrade,
  install, uninstall, reinstall, cleanup, pin, unpin, services start/stop/restart) go through one strict FIFO queue, so two brews
  never run at once. Status reads stay off the queue.
- **Network: Tankard's own requests are below, each only in one mode and only when
  needed; no telemetry.** `brew update` (Refresh, Check Now and the background update)
  and an adopt's cask download are brew's own requests. Everything else comes from brew
  and git on this Mac. The links out are ones
  you click (release pages, homepages, the About panel).
  - *Normal mode:* Discover fetches `https://formulae.brew.sh/api/formula.json` and
    `cask.json` (about 32 MB and 19 MB, gzip on the wire) the first time it is opened,
    never at launch. They are kept in `~/Library/Caches/net.mindtricks.tankard/api/` with
    their ETag. Within an hour Tankard uses that copy without asking; after an hour it
    revalidates with `If-None-Match` (a 304 costs no download). If the request fails, the
    saved copy is used and a banner says so. Search is in memory. Adopt Apps reads the
    same cached `cask.json`, fetching it the same way if it isn't there yet.
  - *Normal mode, install counts:* once the catalogue is ready, without holding up
    Discover, Tankard fetches Homebrew's bulk analytics files,
    `formulae.brew.sh/api/analytics/install/{30d,90d,365d}.json` and
    `analytics/cask-install/{30d,90d,365d}.json` (about 13 MB together), into the same
    cache with their ETag, kept for a day. They cover every package, so no request names
    a package. No other host is contacted.
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
