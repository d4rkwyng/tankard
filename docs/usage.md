# Using Tankard

[README](../README.md) · **Using Tankard** · [Development](development.md) · [Architecture](architecture.md) · [Releasing](releasing.md)

Tankard has two parts. `TankardCore` reads brew's JSON and works out each package's
status; the `tankard` CLI prints it (step 1). **Tankard.app** shows the same data in a
window and runs `brew update` and `brew upgrade` for you (step 2). v0.2 added Discover,
Uninstall, the welcome screen and themes.

## What changes your Homebrew

The CLI and the app's status reads never change your Homebrew: they run with
`HOMEBREW_NO_AUTO_UPDATE=1`. Only four things in the app change it, and only when you click:
the refresh button (`brew update`), the Upgrade buttons (`brew upgrade`), Install in
Discover (`brew install`) and Uninstall after its confirmation (`brew uninstall`).

## The window

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
  from depends on the mode; see *Network* in [architecture.md](architecture.md#how-the-app-behaves).
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
  (#f2a93b) for buttons, progress and the table selection, foam-white text, badges
  re-tinted. Every Tankard text colour pair is checked against WCAG AA (4.5:1) by a test.
  Saved in UserDefaults (`appearance`), applied app-wide including sheets.

Settings and runtime switches for demos and screenshots are in
[development.md](development.md#demo-mode-and-screenshots). How the app caches, queues
and talks to the network is in [architecture.md](architecture.md#how-the-app-behaves).

## The CLI

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

The JSON format is documented in [architecture.md](architecture.md#json-output-tankard-status---json-schema-version-1).

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
