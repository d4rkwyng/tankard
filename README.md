<p align="center"><img src="docs/images/tankard-logo.png" alt="Tankard logo: a pixel-art amber tankard" width="128" height="128"></p>

# Tankard

<p>
<a href="https://github.com/d4rkwyng/tankard/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/d4rkwyng/tankard?label=release"></a>
<a href="https://github.com/d4rkwyng/homebrew-tap/blob/main/Casks/tankard.rb"><img alt="Homebrew cask: d4rkwyng/tap/tankard" src="https://img.shields.io/badge/brew-d4rkwyng%2Ftap%2Ftankard-orange"></a>
<img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-blue">
<img alt="Universal: Intel and Apple silicon" src="https://img.shields.io/badge/universal-Intel%20%2B%20Apple%20silicon-lightgrey">
<img alt="Signed and notarized" src="https://img.shields.io/badge/signed-notarized-brightgreen">
<a href="LICENSE"><img alt="License: BSD-2-Clause" src="https://img.shields.io/github/license/d4rkwyng/tankard"></a>
</p>

A native macOS app for Homebrew: what you have installed, how it got there and what's
ready to upgrade, with brew run for you when you click. On a Mac with
[Intelbrew](https://github.com/d4rkwyng/intelbrew) (Homebrew with prebuilt Intel bottles),
it shows whose bottle each package came from.

<img src="docs/images/screenshot.png" alt="Tankard in its Tankard theme: the Installed list with bottle, built-from-source and cask badges, upgrades ready, a vulnerable openssl@3, self-updating apps marked with a circular arrow, the filter bar and the detail pane for google-chrome" width="1040">

## Features

- **Installed**: every formula and cask, badged by how it got there, with the brew command for each action.
- **Upgrades** with a live log, Stop, Retry, and a warning before anything compiles from source.
- **Discover**: search and install any formula or cask, bottles first.
- **Adopt Apps**: hand apps you installed yourself over to Homebrew.
- **Uninstall, Pin, Clean Up, Replace with Bottle**, services and taps (including Homebrew 7 trust).
- **Restore points** before every upgrade, and optional **automatic updates** (off by default).
- **Vulnerabilities** from `brew vulns`, Health, History and Brewfiles.
- **Casks that need your password** upgrade through a dialog; the password is never stored.
- **Menu-bar icon** with the upgrade count, and optional notifications.
- Five themes, and nine languages (machine-translated).

Everything in detail: [Tankard Help](docs/usage.md), also **Help ▸ Tankard Help** in the app.

## Install

```sh
brew trust --tap d4rkwyng/tap      # once: Homebrew 7 asks you to trust a third-party tap
brew install --cask d4rkwyng/tap/tankard
```

Or download `Tankard.zip` from [Releases](https://github.com/d4rkwyng/tankard/releases),
unzip it and move Tankard.app to Applications. Releases are signed and notarized. No
Homebrew yet? Tankard's welcome screen shows how to install it.

## What Tankard changes

Reading status never changes anything. Packages change only when you click, or when you
turn on automatic updates. Every button shows the brew command it runs; commands run one at
a time, never through a shell. Tankard never runs sudo itself: a cask installer's password
goes from a Tankard dialog straight to sudo, is never stored, and automatic updates skip
those casks. On its own, Tankard only runs a background `brew update`, which upgrades
nothing; Settings ▸ General turns it off. Full list: [What Tankard runs](docs/usage.md#what-tankard-runs).

## Privacy

No telemetry, no account. Tankard itself downloads Homebrew's public catalog and install
counts (whole files, so the site never learns which packages you look at), checks a cask's
download size, fetches Intelbrew build times in Intelbrew mode, and asks GitHub for a new
release only when you choose **Check for Tankard Updates…**. brew's own requests happen as
in Terminal; `brew vulns` sends formula names and versions to OSV.dev only when you scan
(or on every refresh, if you opt in). `HOMEBREW_NO_ANALYTICS` in your shell profile or
brew.env applies to the brew Tankard runs. Details: [Privacy and network](docs/usage.md#privacy-and-network).

## Build from source

Needs Swift 6.0 or later; the Command Line Tools are enough (`xcode-select --install`).

```sh
Scripts/test.sh                    # unit tests
Scripts/bundle-app.sh --universal  # dist/Tankard.app, ad-hoc signed, Intel + Apple silicon
open dist/Tankard.app
```

More: [architecture.md](docs/architecture.md). What changed: [CHANGELOG.md](CHANGELOG.md).

## Built with Claude

Claude Code agents wrote Tankard under Derek's direction, with review, tests and a real signed-app launch check before each release ([write-up](https://mindtricks.io/blog/20261117-intelbrew-tankard)).

## License

BSD-2-Clause, like Homebrew and Intelbrew; see [LICENSE](LICENSE). Dracula theme colors by
[Dracula Theme](https://draculatheme.com), MIT license. Tankard is an independent app, not
affiliated with or endorsed by the [Homebrew](https://brew.sh) project (© Homebrew
contributors, BSD-2-Clause).
