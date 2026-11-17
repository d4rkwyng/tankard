# Changelog

All notable changes to Tankard. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Tankard uses [semantic versioning](https://semver.org/). Each release's notes on GitHub
are its section below (`Scripts/changelog-section.sh`).

## [0.7.0]

### Added
- **Homebrew ▸ Taps…**: every tap from `brew tap-info --installed --json` with its remote, official or third-party, formula and cask counts, how many installed packages came from it, when it was last updated, and brew 7's trust. Click a tap, then **Show Installed**, to filter the Installed list to it (`tap:user/repo` in the search field).
- **Add a tap** (`user/repo`, optionally with a git URL), checked before anything runs. Third-party taps get a warning that they run their authors' code; `brew tap` then runs through the queue with a live log and lands in History.
- **Remove a tap** with `brew untap` (never `--force`), after a confirmation. Blocked, with the packages listed, while anything installed comes from it.
- **Trust / Untrust** a third-party tap (`brew trust --tap`, `brew untrust --tap`, Homebrew 7), after a confirmation.
- **Restore Points** never uninstall a package down to nothing: Restore checks the Cellar again when you confirm, and once more right before each rollback's `brew uninstall`. If `brew cleanup` (run from Terminal, or brew's own periodic cleanup) removed the old version in the meantime, that package is left as it is, the other packages are still restored, and Tankard says which one was skipped and why.
- The Brewfile restore plan's missing taps get an **Add Tap…** button (same confirmation) instead of a `brew tap` command to copy.
- **Localization**: Tankard follows the macOS language (System Settings ▸ General ▸ Language & Region, or per app) in German, French, Spanish, Japanese, Simplified Chinese, Portuguese (Brazil), Italian and Korean, besides English. The translations are machine translations and will read that way in places; corrections are welcome. Brew commands, package and tap names, and brew's own output stay as brew writes them.
- For contributors: every user-facing string lives in `Resources/Localizable.xcstrings`. `Scripts/l10n.py extract` adds new strings from the source, `Scripts/l10n.py compile` writes the `.lproj` files the app loads (the Command Line Tools can't compile a string catalog themselves), and a test fails if any string lacks a shipped language. `APP_LANG=de Scripts/layout-check.sh` runs the layout check in another language.

## [0.6.2]

### Fixed
- Long versions no longer lose their important part at the default window size: the Installed and Available columns are wider (the Source column gives up the room it didn't use), long versions are shortened in the middle rather than at the end, and hovering shows the full version.
- The Pin row in the details now wraps instead of cutting off "Keeps <version>; upgrades skip it".
- Discover descriptions wrap to two lines, with the full text on hover.
- The summary above the Installed list no longer cuts off when the More menu shows "2 vulnerable" or a scan is running: it drops its least important parts first ("1 newer", then the Intelbrew/Homebrew bottle split, then the upgrade detail), and hovering shows the full text.

## [0.6.1]

### Fixed
- After choosing a filter from the **More** menu (such as Has notes), the window could no longer be dragged by its toolbar until you switched to Discover and back. The More filters are now a standard pop-up menu, and dragging works.
- The toolbar's logo now moves the window when dragged, like the rest of the toolbar.
- Leaving the Installed tab clears a **More** filter (Has notes, Pinned…), so Installed comes back showing All.
- The About examples in the docs no longer name an old version.

### Changed
- **ⓘ buttons** next to each setting in Settings (General, Upgrades, Automatic updates) show its explanation on click; the hover tooltips stay.
- **Scan Now** beside the vulnerability scan setting (Settings → Upgrades), and **Homebrew ▸ Scan for Vulnerabilities**, replace "Scan for Vulnerabilities Now" in the More menu.
- A running scan shows a spinner, "Scanning N formulae…", the elapsed time and **Stop** in the status bar and the menu-bar panel; afterwards "Scanned N · found M" (or a partial, stopped or timed-out note). Stop ends brew vulns; the 60-second limit still applies.

## [0.6.0]

### Added
- **Deprecated and disabled packages** get a tag in the list and a box in the details with brew's date, reason and replacement, and an "Install <replacement>" button (the normal install flow). A **Deprecated** filter in the More menu. Formulae also show whether they're keg-only (with brew's reason) or not linked.
- **Homebrew ▸ Health…**: runs `brew doctor`, `brew config` and `brew missing` (read-only). Known doctor warnings get a plain-English title, an explanation and the command that fixes them, shown and never run; brew's text stays one click away. When brew says its warnings are for Homebrew maintainers, Tankard says so.
- **Homebrew ▸ History…**: every brew command Tankard runs (installs, upgrades, uninstalls, pins, services, clean up, auto-update) with its time, result and duration, filterable, with **Retry** on failures. Kept in Application Support, the last 500.
- **Homebrew ▸ Remove Unused Dependencies…**: shows what `brew autoremove --dry-run` would remove, and the `brew tab --installed-on-request` command that keeps one, before running `brew autoremove`.
- **Skip this version** (detail pane and right-click menu): Upgrade all, the menu-bar count and auto-update leave that exact version out; a manual Upgrade still works, and a newer version clears the skip.
- **Snooze automatic updates** for 1 day, 1 week or until turned back on, from Settings → Upgrades and the menu bar.
- **Bump rules** (Settings → Upgrades): automatically upgrade all versions, minor and patch only, or patch only. Packages that don't qualify are skipped and logged ("2.4 → 3.0: major version; upgrade by hand"); versions that can't be compared (dates, letters) upgrade automatically only under All versions. Safe mode is unchanged and still applies first.
- **Export Brewfile…** (Homebrew menu): saves `brew bundle dump` where you choose and shows how many taps, formulae and casks it holds. VS Code extensions and Mac App Store apps are left out.
- **Check a Brewfile…**: lists what a Brewfile needs that this Mac lacks, or says everything is installed. Its **restore plan** marks formulae that would compile and casks that ask for an administrator password (pkg installers), then either installs them one by one through Tankard's queue and log, or shows the `brew bundle install --no-upgrade` command to copy. Taps are shown as `brew tap` commands. Tankard never runs a shell or reads the Brewfile itself.
- Brewfile dump and check stop after 60 seconds with a message instead of hanging.

### Changed
- **Clearer errors**: when brew fails because another brew is running (its lock), there's no network, the disk is full or a folder isn't writable, Tankard says so in words above brew's own output.

## [0.5.0]

### Added
- **Settings are shorter:** the long explanations under each checkbox are now tooltips; only the OSV.dev privacy note and a one-line safe-mode summary stay visible.
- **Automatic updates** (Settings → Upgrades, off by default): upgrade packages every day or every week at a chosen time, while Tankard is running, on AC power and after 10 minutes without input. A missed time runs once at the next chance. No helper or launch agent: the menu-bar icon keeps Tankard running.
- **Safe mode**, always on and spelled out in Settings: `brew update` first; bottles only (formulae whose upgrade or outdated dependencies would compile are skipped, and so are formulae whose upgrade would make brew upgrade or rebuild an installed dependent that has no bottle: those stay in Upgrades to do by hand, since turning brew's dependents check off could leave that dependent linked to a removed library); pinned packages skipped; casks whose app is running skipped unless "Don't quit running apps" is on, and an automatic run never quits an app; Tankard itself left to brew.
- **Auto-update log**: the last 20 runs with what was upgraded, skipped (and why) and what failed; a notification after each run that changed something; "Last auto-update: …" in the menu-bar menu.
- The menu-bar menu shows "Tankard 0.x available" when brew lists an upgrade for Tankard's cask.

### Changed
- One timer runs both the update notifications (still off by default, a separate setting) and automatic updates.
- `tankard status --json` cask entries gain `appPaths` and `quitBundleIDs` (from `brew info`'s artifacts; schema version 1, added fields).
- The menu-bar menu lists at most 8 upgrades (was 12); "and N more…" opens Tankard on the Upgrades list. The menu-bar count shows "99+" above 99.

## [0.4.0]

### Added
- **Pin and Unpin** (`brew pin` / `brew unpin --formula|--cask <tap>/<name>`, through the queue) in the detail pane and the right-click menu, replacing v0.3's placeholder. Pinned packages get a "pinned" badge, a box in the detail pane with the exact command, and a **Pinned** filter. Upgrade all, the menu-bar count and upgrade notifications leave pinned packages out, and the status bar says so ("1 pinned upgrade not included (sqlite)"); a pinned package's own Upgrade button is disabled until it is unpinned.
- **Requested only** filter: packages you installed yourself that nothing installed needs (`brew leaves --installed-on-request`, plus casks). Pinned, Requested only, Vulnerable and Has notes are in a menu next to the segmented filter.
- **Depends on and Used by** in the detail pane, as links that select that package, from the `brew info` receipts Tankard already reads (no extra brew calls). Used by matches `brew uses --installed` exactly on both test Macs; Depends on matches `brew deps --installed` or lists a little more (linkage brew doesn't declare).
- **Dependency tree**: an expandable `brew deps --tree` in the detail pane, from the receipts' `declared_directly` entries in brew's order.
- **Services** tab (⌘3): `brew services list --json` with status, user, exit code and plist, and `brew services info --json` for the selected service (label, PID, logs, the command it runs). Start, Stop and Restart run through the queue with the exact command shown. Services that run as root (started with sudo) are never touched: Tankard shows the `sudo brew services …` command to run in Terminal, and turns brew's own "started as `root`" error into the same advice.
- **Homebrew menu**: **Revert to Standard Homebrew…** (Intelbrew mode only) and **Uninstall Homebrew…**. Each opens a sheet with every command it will run, needs the word typed ("revert", "uninstall"), and then opens Terminal with a `.command` script that lists the commands again and waits for Return. Revert follows Intelbrew's README: it removes the three `HOMEBREW_*` lines from the zsh and bash startup files (each backed up first; a symlinked file, as in a dotfiles repo, is edited at its real path; a bash file where removing a line would leave an empty `if` or loop body is left for you to edit, with a warning), points Homebrew/brew's origin back to upstream and runs `brew update`. Uninstall runs Homebrew's official uninstaller with `--path` set to the prefix Tankard shows, so on a Mac with both /usr/local and /opt/homebrew only that one is removed; the uninstaller asks once more. Neither runs inside the app.
- **Vulnerability scan** with Homebrew 7's `brew vulns`: vulnerable formulae get a ⚠ tag with the severity, the detail pane lists each advisory (linked to OSV.dev) with "fixed in", a Vulnerable filter, and "Upgrade vulnerable packages" through the normal upgrade path (pinned packages left out). Runs on demand (Scan for Vulnerabilities Now) and, if you turn on "Scan for vulnerabilities when refreshing" (off by default, because brew sends your installed formula names and versions to OSV.dev), after each refresh, cached for an hour. A scan that runs longer than a minute is stopped and shown as timed out; when brew couldn't check every formula, Tankard says "partial scan" and why. brew itself sends each formula's source repository and version to OSV.dev; casks aren't scanned.
- Optional **menu-bar notice for new vulnerabilities** (off by default).
- **Notes from brew** (caveats) in the detail pane, a "Has notes" filter, and a one-time "Post-install notes" sheet after an install or upgrade.
- **Size on disk**: a sortable Size column and the total in the summary strip, from `brew info --sizes`, measured in the background.
- **Include self-updating apps** setting (off by default): also lists casks that update themselves, as `brew outdated --greedy` does.
- **Don't quit running apps during upgrades** setting (off by default): cask upgrades run with `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`, shown in the command and included by Copy Upgrade Command.
- Settings → Upgrades for these options.

### Changed
- **System is the default theme** (it follows the Mac's light or dark setting); a theme you already chose is kept.
- The menu-bar icon is a pixel tankard (handle on the left, like the logo), with foam only when upgrades are waiting.
- **Clean Up** is in the View menu only; the toolbar trash button is gone (it read as "delete").
- The About panel's copyright line reads "© 2026 d4rkwyng".
- One rule for what "upgrade everything" means: Upgrade all, the menu-bar count, upgrade notifications and Upgrade vulnerable packages all leave pinned packages out. With "Include self-updating apps" on, those casks count as upgrades everywhere too, unless pinned.
- `tankard status --json` packages gain `directDependencies` (formulae; schema version 1, an added field).

### Fixed
- Choosing the Tankard or Dracula theme no longer moves the text around. The toolbar's Installed/Discover/Services labels and the filter labels used a different control, font size and segment widths in those themes (the filter labels moved by up to 113 points, the toolbar buttons by a few); every theme now uses the same control and sizes, and only the colours change.
- Switching from Tankard or Dracula back to Dark or Light no longer leaves some table rows in the old theme's colour, and a switch no longer makes the table drop and redraw its rows.
- Includes 0.3.1's fix for the launch crash in 0.3.0. The new Homebrew menu, the Services menu item and the Settings → Upgrades options follow the same rules, so they can't bring it back.

## [0.3.1]

### Fixed
- Tankard 0.3.0 could crash at launch (on about half of all launches, with a Dark, Light, Tankard or Dracula theme). The app's scene description re-ran in a loop when the menu-bar setting was written back unchanged, until it ran out of stack.

## [0.3.0]

### Added
- **Menu-bar icon**: a mug with the number of upgrades ready, and a menu with the list, Upgrade all, Open Tankard, Check now and Quit. On by default; Settings → General can hide it. With it on, closing the window keeps Tankard running.
- **Notifications for new upgrades** (off by default): when turned on, Tankard runs `brew update` in the background every few hours (6 by default) and shows a notification only when new upgrades appear. macOS asks for permission when you turn it on.
- **Open at login** setting (off by default).
- **Compile warnings**: upgrades with no bottle for your Mac are marked "No bottle: will compile from source" in orange, in the list and in the upgrade sheet before it starts, with "Skip packages that would compile". In Intelbrew mode they also say how long the formula took on the Intelbrew builder ("at least ~N min"), from Intelbrew's build-time data, fetched only when such a warning is shown and cached for a day.
- **Discover shows what compiles**: in Intelbrew mode, a "Has Intel bottle" filter (on by default, with a count) hides formulae that would compile; bottled formulae rank first; formulae without a bottle say "No bottle: compiles", warn in the detail pane (including dependencies that also compile), and ask before installing. Normal mode has the same marks, with the filter off by default.
- **Clean up**: shows what `brew cleanup` would remove and how much space it frees (from `brew cleanup -n`), plus the size of Homebrew's download cache, then runs `brew cleanup` with the live log.
- **Replace with bottle**: a package built from source whose version has a bottle for your Mac gets a "Bottle available" badge (or "Intelbrew bottle available") and a button that runs `brew reinstall --force-bottle`. A "Bottle available" filter has Replace all.
- **App Management help**: before Tankard first upgrades or removes an app, and whenever macOS blocks it, a short guide explains how to allow Tankard under Privacy & Security → App Management, with a button that opens the right page. After you allow it, Tankard retries once.
- **About Tankard** shows the version, links to the project and to Intelbrew, and the licence. Help menu: "Tankard on GitHub" and "Report an Issue…".
- **Right-click menus** on Installed rows (Upgrade, Replace with Bottle, Uninstall…, copy the name or command, open the homepage or release page, Show in Finder, show dependencies or what uses it), Discover rows (Install, copy, open the homepage) and the menu-bar list (Upgrade, Copy Name).
- **Dracula theme**, a fifth option in Settings → Appearance.

### Changed
- Brighter version columns in every theme, so installed and available versions are easier to read.
- Primary buttons (Upgrade, Install, Replace with bottle, Clean up, Done) are green in every theme. With nothing to upgrade, the Upgrade button reads "Up to date".
- Tankard theme: amber segmented pickers, striped rows and a purple column header.
- About shows "Version 0.3.0" without a build number.

### Fixed
- Switching theme no longer rebuilds the window: the list keeps its scroll position, column widths and selection.
- The finished upgrade sheet said "5 upgradeed"; it now says "5 upgraded".

## [0.2.0]

### Added
- **Discover**: search every formula and cask, see version, licence, dependencies and bottle availability, and install with the exact `brew install` command shown first.
- **Uninstall**, with a confirmation; blocked while other installed packages depend on it, and those packages are listed.
- **Themes** in Settings (⌘,): Dark (default), Light, System, and Tankard (purple and amber).
- **Welcome screen** when Homebrew isn't installed: recommends Intelbrew on Intel Macs and standard Homebrew on Apple silicon, and opens the installer in Terminal.
- **Mode-aware logos**: the Tankard mark normally, the Intelbrew mug when Intelbrew is detected (including the Dock icon).
- New app icon.

### Notes
- Discover's only network request is Homebrew's catalogue (formulae.brew.sh), fetched when you open Discover and cached for an hour. In Intelbrew mode it reads your local taps instead.

## [0.1.1]

### Changed
- App icon (it had none in 0.1.0).
- The logo now shows in the toolbar in every mode, and in the upgrade sheet header.
- Licence: BSD-2-Clause.

## [0.1.0]

First release.

### Added
- Installed list with a badge for how each package got there: bottle (Intelbrew or Homebrew), built from source, newer than the tap, or no bottle yet.
- Filters: All, Upgrades, From source, Newer. Search.
- Detail pane: versions, bottle tag, where it was poured from, and the exact upgrade command.
- Upgrades one package at a time with a live log, "Stop After Current" and "Stop Now".
- Intelbrew mode: detects the Intelbrew fork and shows fork status.
- Opens instantly from a cache; no telemetry; runs brew with a clean environment.
- `tankard status` command-line tool (table or JSON).

[0.4.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.4.0
[0.3.1]: https://github.com/d4rkwyng/tankard/releases/tag/v0.3.1
[0.3.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.3.0
[0.2.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.2.0
[0.1.1]: https://github.com/d4rkwyng/tankard/releases/tag/v0.1.1
[0.1.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.1.0
