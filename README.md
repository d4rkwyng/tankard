<p align="center"><img src="docs/images/tankard-logo.png" alt="Tankard logo: a pixel-art amber tankard" width="128" height="128"></p>

# Tankard

A native Homebrew app for macOS 14+, made for Intel Macs too.

![Tankard's Installed list in Intelbrew mode: packages with Intelbrew and Homebrew bottle badges, and the detail pane for python@3.15 with its upgrade command](docs/images/screenshot.png)

## Install

```sh
brew install --cask d4rkwyng/tap/tankard
```

Or download `Tankard.zip` from [Releases](https://github.com/d4rkwyng/tankard/releases).
Signed and notarized; macOS 14 Sonoma or later; Intel and Apple silicon.

## Features

- **Installed list** with a badge for how each package got there: bottle, built from
  source, newer than the tap, no bottle yet, or cask. Filter by upgrades, from source or
  newer.
- **Upgrades with a live log**: one package at a time, with "Stop After Current" and
  "Stop Now". The log is also saved to `~/Library/Logs/Tankard/upgrade.log`.
- **Discover**: search every formula and cask, see dependencies and licence, and install.
- **Uninstall with a dependency check**: blocked while other installed packages need it.
- **Themes**: Dark (default), Light, System, and Tankard (amber on deep purple).
- **Intelbrew extras** when Intelbrew is detected (see below).
- **Welcome screen** when Homebrew isn't installed, with the right installer for your Mac.
- **The exact brew command** for every action, with a copy button. Tankard changes your
  Homebrew only when you click Refresh, Upgrade, Install or Uninstall.

See [docs/usage.md](docs/usage.md) for the full tour of the window and what each status
means.

## Command line

A `tankard` CLI prints the same report as the app, read-only, as a table or as JSON
(build it with `swift build -c release`; it lands in `.build/release/tankard`):

```
tankard status [--json] [--filter upgrades|source|newer|nobottle|casks]
               [--remote] [--timings] [--brew PATH]
```

Example output and exit codes: [docs/usage.md](docs/usage.md#the-cli). JSON schema:
[docs/architecture.md](docs/architecture.md#json-output-tankard-status---json-schema-version-1).

## Intelbrew

[Intelbrew](https://github.com/d4rkwyng/intelbrew) is Homebrew with prebuilt bottles for
Intel Macs on macOS 14 and later. When Tankard detects it, each bottle is labelled
"Intelbrew bottle" or "Homebrew bottle", the status bar shows whether core and brew are on
the Intelbrew forks, Discover reads your local taps instead of formulae.brew.sh, and the
logo and Dock icon switch to the Intelbrew mug.

## Privacy

No telemetry. Tankard's only network request of its own is the Homebrew catalogue from
formulae.brew.sh, fetched in normal mode the first time you open Discover and then cached.
It runs brew directly, without a shell, in a clean environment it builds itself.
Details: [docs/architecture.md](docs/architecture.md#how-the-app-behaves).

## Build from source

Needs the Command Line Tools (`xcode-select --install`); Xcode isn't required.

```sh
git clone https://github.com/d4rkwyng/tankard.git && cd tankard
Scripts/bundle-app.sh
open dist/Tankard.app
```

Tests, universal builds, demo mode and screenshots: [docs/development.md](docs/development.md).
How it works: [docs/architecture.md](docs/architecture.md).
Signing and releases: [docs/releasing.md](docs/releasing.md).

## Licence

BSD-2-Clause, the same licence as Homebrew and Intelbrew. See [LICENSE](LICENSE).
