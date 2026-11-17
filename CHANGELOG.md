# Changelog

All notable changes to Tankard. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Tankard uses [semantic versioning](https://semver.org/). Each release's notes on GitHub
are its section below (`Scripts/changelog-section.sh`).

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

[0.3.1]: https://github.com/d4rkwyng/tankard/releases/tag/v0.3.1
[0.3.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.3.0
[0.2.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.2.0
[0.1.1]: https://github.com/d4rkwyng/tankard/releases/tag/v0.1.1
[0.1.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.1.0
