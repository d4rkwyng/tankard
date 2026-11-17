<p align="center"><img src="docs/images/tankard-logo.png" alt="Tankard logo: a pixel-art amber tankard" width="128" height="128"></p>

# Tankard

A native macOS app for Homebrew, for macOS 14 Sonoma and later, Intel and Apple silicon.
It shows what you have installed, how each package got there, and what's ready to
upgrade, and runs brew for you when you click. When the Mac uses
[Intelbrew](https://github.com/d4rkwyng/intelbrew) (Homebrew with prebuilt Intel
bottles), Tankard shows whose bottle each package came from and whether Homebrew is on
the Intelbrew forks.

## What it does

- **Installed**: every formula and cask with a badge for how it got there (Intelbrew or
  Homebrew bottle, built from source, newer than the tap, no bottle yet, cask), filters,
  search, and the exact brew command for each action.
- **Upgrades** one package at a time with a live log, Stop After Current and Stop Now.
  Upgrades with no bottle for your Mac are marked "will compile from source" before
  anything starts, with an option to skip them; in Intelbrew mode they say how long the
  build took on the Intelbrew builder.
- **Discover**: search every formula and cask and install. Formulae with a bottle for
  your Mac come first; ones that would compile say so and ask before installing.
- **Clean up**: see what `brew cleanup` would remove and how much space it frees, then
  run it.
- **Replace with bottle**: a package you built from source whose version has a bottle
  gets swapped for the bottle in one click.
- **Uninstall**, blocked (with the reasons listed) while other packages need it.
- **Pin** packages so upgrades skip them, filter by **Pinned** or **Requested only**, and
  follow **Depends on**, **Used by** and the dependency tree from package to package.
- **Services**: see `brew services` status and start, stop or restart your own services.
- **Homebrew menu**: revert from Intelbrew to standard Homebrew, or uninstall Homebrew,
  both in Terminal after showing every command.
- **Right-click menus** on Installed, Discover and the menu-bar list.
- **Menu-bar icon** with the number of upgrades ready, and optional **notifications**
  when new upgrades appear (off by default).
- **Themes**: Dark, Light, System, Tankard (purple and amber) and Dracula, with green
  primary buttons in every theme.

More detail, including the command-line tool `tankard status`, is in
[docs/usage.md](docs/usage.md).

## Install

```sh
brew install --cask d4rkwyng/tap/tankard     # later: brew upgrade --cask tankard
```

Or download `Tankard.zip` from [Releases](https://github.com/d4rkwyng/tankard/releases),
unzip it and move Tankard.app to Applications. Releases are signed with a Developer ID and
notarized.

A build you made yourself, or an ad-hoc signed one, is blocked by Gatekeeper the first
time. Right-click → Open once, or:

```sh
xattr -dr com.apple.quarantine Tankard.app
```

If Homebrew isn't installed yet, Tankard's welcome screen shows how: Intelbrew first on
an Intel Mac, standard Homebrew on Apple silicon.

## What Tankard changes, and when

Reading status never changes your Homebrew (brew runs with `HOMEBREW_NO_AUTO_UPDATE=1`).
brew only changes things when you ask:

| you click | Tankard runs |
|---|---|
| Refresh (⌘R) or Check now | `brew update` |
| Upgrade | `brew upgrade --formula\|--cask <tap>/<name>`, one per package |
| Install | `brew install --formula\|--cask <tap>/<name>` |
| Uninstall (after a confirmation) | `brew uninstall --formula\|--cask <tap>/<name>` |
| Clean up | `brew cleanup` |
| Replace with bottle | `brew reinstall --force-bottle --formula <tap>/<name>` |
| Pin / Unpin | `brew pin\|unpin --formula\|--cask <tap>/<name>` |
| Start / Stop / Restart (Services) | `brew services start\|stop\|restart <name>` |

With notifications turned on, Tankard also runs `brew update` in the background every few
hours (6 by default). Commands run one at a time, never with a shell, and never with
sudo (services that run as root are left alone): when brew needs a password, Tankard gives you the command to run in Terminal.
Upgrading or removing an app (a cask) needs macOS's App Management permission; Tankard
explains how to allow it the first time. The Homebrew menu's Revert and Uninstall never run
in the app: after you type the confirmation word, they open Terminal with the commands.

## Network and privacy

No telemetry. Tankard makes two requests of its own, each in one mode only:

- **Normal mode:** Discover downloads Homebrew's catalogue from formulae.brew.sh the first
  time you open it, and keeps it for an hour.
- **Intelbrew mode:** when a compile warning is shown, Tankard reads Intelbrew's build
  times (`build-times.json` from the intelbrew-core releases on GitHub) and keeps them for
  a day. Discover reads your local taps instead of formulae.brew.sh.

Everything else comes from brew and git on your Mac. Details:
[docs/usage.md](docs/usage.md#how-it-behaves).

## Build from source

The Command Line Tools are enough (`xcode-select --install`); Xcode is not required.
Swift 6.0 or later.

```sh
Scripts/test.sh                    # unit tests
Scripts/bundle-app.sh              # dist/Tankard.app for this Mac, ad-hoc signed
Scripts/bundle-app.sh --universal  # Intel + Apple silicon
open dist/Tankard.app
```

How it's put together, demo mode, screenshots, signing and releases:
[docs/architecture.md](docs/architecture.md). What changed in each version:
[CHANGELOG.md](CHANGELOG.md).

## Licence

BSD-2-Clause, the same licence as Homebrew and Intelbrew. See [LICENSE](LICENSE). The
Dracula theme's colours are by [Dracula Theme](https://draculatheme.com), used under the
MIT licence.

Tankard is an independent app for [Homebrew](https://brew.sh). Homebrew is © Homebrew
contributors, BSD-2-Clause. Tankard is not affiliated with or endorsed by the Homebrew
project.
