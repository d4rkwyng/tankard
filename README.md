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

A native macOS app for Homebrew, for macOS 14 Sonoma and later, Intel and Apple silicon.
It shows what you have installed, how each package got there, and what's ready to
upgrade, and runs brew for you when you click. When the Mac uses
[Intelbrew](https://github.com/d4rkwyng/intelbrew) (Homebrew with prebuilt Intel
bottles), Tankard shows whose bottle each package came from and whether Homebrew is on
the Intelbrew forks.

<img src="docs/images/screenshot.png" alt="Tankard's Installed list: packages with bottle and source badges, five upgrades ready, and the detail pane for python@3.15" width="1040">

## What it does

- **Installed**: every formula and cask with a badge for how it got there (Intelbrew or
  Homebrew bottle, built from source, newer than the tap, no bottle yet, cask), filters,
  search, and the exact brew command for each action.
- **Upgrades** one package at a time with a live log, Stop After Current and Stop Now.
  Upgrades with no bottle for your Mac are marked "will compile from source" before
  anything starts, with an option to skip them; in Intelbrew mode they say how long the
  build took on the Intelbrew builder.
- **Discover**: search every formula and cask and install. Formulae with a bottle for
  your Mac come first; ones that would compile say so and ask before installing. The
  details show Homebrew's public install counts for the last 30, 90 and 365 days.
- **Adopt Apps** (Homebrew menu): apps you installed by hand that a cask also installs
  can be handed to Homebrew (`brew install --cask --adopt`), so brew keeps them up to
  date. Tankard says how sure each match is, ticks only good matches, and says before
  anything runs that uninstalling the cask afterwards deletes the app.
- **Clean up**: see what `brew cleanup` would remove and how much space it frees, then
  run it.
- **Replace with bottle**: a package you built from source whose version has a bottle
  gets swapped for the bottle in one click.
- **Uninstall**, blocked (with the reasons listed) while other packages need it, or
  while it is pinned (**Unpin and Uninstall** does both). Dependencies that nothing else
  would need afterwards are listed, with **Also remove these** (on by default).
- **Pin** packages so upgrades skip them, filter by **Pinned** or **Requested only**, and
  follow **Depends on**, **Used by** and the dependency tree from package to package.
- **Services**: see `brew services` status and start, stop or restart your own services.
- **Homebrew menu**: revert from Intelbrew to standard Homebrew, or uninstall the Homebrew
  Tankard shows (its prefix only),
  both in Terminal after showing every command.
- **Vulnerabilities** from `brew vulns` (Homebrew 7): a ⚠ tag with severity, the advisory
  ids linked to OSV.dev, "fixed in", a Vulnerable filter and "Upgrade vulnerable
  packages". Scans run when you ask, or on every refresh if you opt in (brew sends your
  formula names and versions to OSV.dev). brew reports most scans as partial, and Tankard
  says so.
- **Notes from brew** (caveats) in each package's details, a "Has notes" filter, and a
  one-time "Post-install notes" sheet after an install or upgrade.
- **Size on disk** per package (a sortable column) and in total, from `brew info --sizes`.
- **Self-updating apps** (optional, off by default): also list casks that update
  themselves, as `brew outdated --greedy` does, or choose per app whether the app or
  Homebrew updates it. Another setting keeps running apps open during cask upgrades.
- **Right-click menus** on Installed, Discover and the menu-bar list.
- **Menu-bar icon** with the number of upgrades ready, and optional **notifications**
  when new upgrades appear (off by default).
- **Themes**: System (default, follows your Mac), Dark, Light, Tankard (purple and amber)
  and Dracula.

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
Your packages change only when you ask; the one thing Tankard runs on its own is a
throttled `brew update` in the background, on by default and described below the table.

| you click | Tankard runs |
|---|---|
| Refresh (⌘R) or Check Now | `brew update` |
| Upgrade | `brew upgrade --formula\|--cask <tap>/<name>`, one per package |
| Install | `brew install --formula\|--cask <tap>/<name>` |
| Uninstall (after a confirmation) | `HOMEBREW_NO_AUTOREMOVE=1 brew uninstall --formula\|--cask <tap>/<name>`, then the no-longer-needed dependencies the sheet lists, one by one, when "Also remove these" is on |
| Adopt (Adopt Apps, after a confirmation) | `brew install --cask --adopt <tap>/<name>`, one per app |
| Clean up | `brew cleanup` |
| Replace with bottle | `brew reinstall --force-bottle --formula <tap>/<name>` |
| Pin / Unpin | `brew pin\|unpin --formula\|--cask <tap>/<name>` |
| Start / Stop / Restart (Services) | `brew services start\|stop\|restart -- <name>` |

Reads that change nothing also run with each status read (side by side with `brew info`;
the list appears first and sizes fill in; cached for an hour like status): `brew info --sizes`, `brew vulns --json` (only once you turn on
"Scan for vulnerabilities when refreshing" in Settings → Upgrades, off by default; "Scan
for Vulnerabilities Now" is always there; a scan is stopped after a minute), and, with
"Include self-updating apps" on, `brew outdated --greedy --cask --json=v2`. With "Don't
quit running apps during upgrades" on, cask upgrades run with
`HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`, and the command shown says so.

**Background `brew update` (on by default).** After the list is on screen, and then while
Tankard runs, Tankard runs `brew update` at most once per check interval (Settings →
General → Check every, 6 hours by default; longer if `HOMEBREW_AUTO_UPDATE_SECS` says so;
any `brew update`, Terminal's too, counts), then re-reads the upgrade counts. `brew update`
updates Homebrew and its package lists (taps, formula and cask data); it installs or
upgrades none of your packages. Turn off Settings → General → "Check for new versions in
the background" to stop it; it is also off when `HOMEBREW_NO_AUTO_UPDATE` is set. It waits
while another brew command runs, and a failure (offline) is only logged. Notifications use the same update. Commands run one at a time, never with a shell, and never with
sudo (services that run as root are left alone): when brew needs a password, Tankard gives you the command to run in Terminal.
Upgrading or removing an app (a cask that installs one) needs macOS's App Management permission; Tankard
explains how to allow it the first time. The Homebrew menu's Revert and Uninstall never run
in the app: after you type the confirmation word, they open Terminal with the commands.

## Network and privacy

No telemetry. Tankard's own requests, each in one mode only:

- **Normal mode:** Discover downloads Homebrew's catalogue from formulae.brew.sh the first
  time you open it, and keeps it for an hour. Right after, without holding up the search, it
  downloads Homebrew's public install counts (the 30, 90 and 365-day files under
  `formulae.brew.sh/api/analytics/`, about 13 MB together) and keeps them for a day. These are
  the bulk files for every package, so the site never learns which packages you look at.
  Adopt Apps reads the same cached cask list (and downloads it if Discover hasn't).
- **Any mode, only when you ask:** Tankard ▸ Check for Tankard Updates… sends one request to
  GitHub's API for Tankard's latest release (`api.github.com/repos/d4rkwyng/tankard/releases/latest`;
  no account, no identifiers beyond the `Tankard/<version>` User-Agent). Never automatic.
- **Intelbrew mode:** when a compile warning is shown, Tankard reads Intelbrew's build
  times (`build-times.json` from the intelbrew-core releases on GitHub) and keeps them for
  a day. Discover reads your local taps instead of formulae.brew.sh.

**brew's own request: `brew vulns`.** The vulnerability scan is brew's command, not
Tankard's code: brew sends the source repository URL and version tag of each installed
formula to OSV.dev (`api.osv.dev/v1/querybatch`, then `api.osv.dev/v1/vulns/<id>` for
details). Tankard runs it only when you ask: Scan Now (Settings → Upgrades) or Homebrew ▸ Scan for Vulnerabilities, or after each
refresh once you turn that on in Settings → Upgrades (off by default). It reads only what
brew prints. Casks aren't scanned.

**brew's own request: `brew update`.** The background update (on by default, see above),
Refresh and Check Now run `brew update`, which fetches from GitHub and formulae.brew.sh
as it does in Terminal. Adopting an app makes brew download its cask.

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
