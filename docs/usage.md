# Tankard Help

Tankard is a Mac app for [Homebrew](https://brew.sh). It shows what you have installed and
what's ready to upgrade, and runs brew for you when you click. This guide explains how to
use it. For what Tankard is, see the [README](../README.md). For how it is built, see
[architecture.md](architecture.md).

## Contents

- [Getting started](#getting-started)
- [The Installed list at a glance](#the-installed-list-at-a-glance)
- [Upgrade packages](#upgrade-packages)
- [Automatic updates](#automatic-updates)
- [Install from Discover](#install-from-discover)
- [Uninstall a package](#uninstall-a-package)
- [Pin a package or skip a version](#pin-a-package-or-skip-a-version)
- [Adopt apps you installed yourself](#adopt-apps-you-installed-yourself)
- [Apps that update themselves](#apps-that-update-themselves)
- [Restore points and rollback](#restore-points-and-rollback)
- [Vulnerability scan](#vulnerability-scan)
- [Taps](#taps)
- [Services](#services)
- [Health, History, Clean Up and Brewfiles](#health-history-clean-up-and-brewfiles)
- [The menu-bar icon](#the-menu-bar-icon) and [notifications](#notifications)
- [Settings reference](#settings-reference)
- [Menu reference](#menu-reference)
- [Privacy and network](#privacy-and-network)
- [What Tankard runs](#what-tankard-runs)
- [App Management](#app-management)
- [Troubleshooting](#troubleshooting)

## Getting started

### Install

```sh
brew install --cask d4rkwyng/tap/tankard
```

Or download `Tankard.zip` from
[Releases](https://github.com/d4rkwyng/tankard/releases), unzip it and move Tankard.app to
Applications. Tankard needs macOS 14 Sonoma or later, on Intel or Apple silicon.

### First launch

- **No Homebrew yet?** The window shows how to install it, with the exact command. On an
  Intel Mac it offers Intelbrew first (Homebrew with prebuilt Intel bottles), then standard
  Homebrew. On Apple silicon it offers standard Homebrew. Click **Open in Terminal**, enter
  your password when the installer asks, then come back and click **Check Again**.
- **Homebrew already installed?** A welcome sheet appears once, over the list:
  - **Allow App Management.** macOS asks before Tankard can install, update or remove
    apps. Click **Open System Settings**, turn on Tankard under Privacy & Security ▸ App
    Management, then click **Check**. If it still says "Not allowed yet", click **Relaunch
    Tankard**. See [App Management](#app-management).
  - **Adopt Apps.** Shown when Tankard finds apps you installed yourself that Homebrew can
    manage. See [Adopt apps you installed yourself](#adopt-apps-you-installed-yourself).
  - Click **Done** to close it for good.

Tankard runs `brew update` in the background so the upgrade counts stay current. It never
installs or upgrades anything on its own unless you turn on
[automatic updates](#automatic-updates). To stop the background update, untick
**Settings ▸ General ▸ Check for new versions in the background**.

## The Installed list at a glance

- **Toolbar:** Installed, Discover and Services (⌘1, ⌘2, ⌘3), Refresh (⌘R) and search. Search matches
  the name and description.
- **Filter bar:** the counts, and the filters **All** and **Upgrades**, then **Bottle
  available**, **From source** and **Newer** when anything matches (the one you're on stays
  until you leave it). The **More** menu next to them has **Vulnerable**, **Pinned**,
  **Installed by you** (packages you installed yourself, not ones pulled in as
  dependencies), **Has notes** and **Deprecated**, each with its count; empty ones are
  grayed out. It shows "N vulnerable" when a scan found something.
- **Table:** the package, the installed version, the available version (an ↑ when an
  upgrade is ready), the source badge and the size on disk. Click a column header to sort.
- **Detail pane:** everything about the selected package: versions, where it came from,
  what it depends on and what uses it, notes from brew, and the buttons for what you can
  do with it. Each button shows the exact brew command it runs.
- **Status bar:** when the list was last updated, and the green **Upgrade N** button.

**Source badges:**

| badge | meaning |
|---|---|
| Bottle (green) | Installed from a prebuilt bottle. In Intelbrew mode it says whose: **Intelbrew bottle** or **Homebrew bottle**. |
| Built from source (orange) | Built from source on this Mac. |
| Newer than tap (blue) | Newer than the version the tap has now (**Newer than Intelbrew** in Intelbrew mode). brew never downgrades it. |
| No bottle yet (gray) | There is no bottle for this Mac, so a reinstall or upgrade compiles. |
| Cask (purple) | An app or other cask. |

Other marks: `dep` means it was installed as a dependency. A blue "pinned" tag means
upgrades skip it. ⚠ means it has known vulnerabilities. ⟳ next to a cask means the app
updates itself.

## Upgrade packages

**Upgrade everything:** click the green **Upgrade N** in the status bar, or **Upgrade All**
in the menu-bar icon.

**Upgrade one package:** select it and click **Upgrade <name>** in the detail pane, or
right-click it and choose **Upgrade <name>**.

The upgrade sheet shows each package, the exact command and brew's live output. Packages
upgrade one at a time; a failure doesn't stop the rest.

- **Stop After Current** lets the running package finish and skips the rest. It then
  becomes **Stop Now**, which stops brew straight away.
- **Hide** keeps the run going in the background. A button in the status bar brings it
  back.
- The full log is saved to `~/Library/Logs/Tankard/upgrade.log`.
- After an upgrade or install, a **Post-install notes** sheet shows any notes brew printed
  for what changed.

**Skip compiling.** An upgrade with no bottle for your Mac is marked "No bottle: will
compile from source" before anything starts. When any selected upgrade would compile, the
sheet opens on a plan first: tick **Skip packages that would compile** to upgrade only the
bottled ones. The Upgrades filter offers the same thing as a **Skip packages that would
compile** button. In Intelbrew mode the warning also says how long the build took on the
Intelbrew builder; expect longer on an older Mac.

**Replace a source build with a bottle.** A package you built from source whose version
now has a bottle says **Bottle available** under its name and gets a **Replace with Bottle**
button.
The Bottle available filter has **Replace all**.

Pinned packages and skipped versions are left out of Upgrade N. See
[Pin a package or skip a version](#pin-a-package-or-skip-a-version).

## Automatic updates

**Turn it on:** **Settings ▸ Upgrades ▸ Upgrade packages automatically**. It is off by
default.

- **Schedule:** every day or every week, at a time you choose (03:00 by default). A time
  missed while the Mac slept or Tankard was closed runs once, at the next chance.
- **When it runs:** only while Tankard is running, on AC power, after 10 minutes without
  keyboard or mouse input, and never while brew is busy. Keep the menu-bar icon on, so
  Tankard keeps running after you close the window.
- **Safe mode, always on:**
  - `brew update` first, then one upgrade per package.
  - Bottles only. A package that would compile, or would make brew rebuild something
    from source, is skipped and stays in the Upgrades list for you to do by hand.
  - Pinned packages are skipped.
  - An app that is running is skipped, never quit.
  - Tankard doesn't upgrade itself this way. The menu-bar icon says when a new Tankard is
    available.
- **Automatically upgrade:** **All versions**, **Minor and patch only** or **Patch only**.
  Versions that can't be compared (dates, letters) upgrade only under All versions.
- **Snooze** pauses automatic updates for 1 day, 1 week, or until you turn them back on.
  It is in Settings and in the menu-bar icon. Manual upgrades still work.
- **Show Auto-update Log…** lists the last 20 runs: what was upgraded, what was skipped
  and why, and what failed. You also get a notification after a run that changed
  something.

## Install from Discover

1. Click **Discover** (⌘2) and search. Formulae with a bottle for your Mac come first.
2. Select a package. The detail pane shows its homepage, license, dependencies, install
   counts for the last 30, 90 and 365 days, and the exact command.
3. Click **Install <name>**.

The sheet shows brew's output and the download's progress, such as "Downloading
font-inter… 25.4 of 33.7 MB (75%)".

- A formula with no bottle for your Mac says so, and the button reads **Install
  (compiles)**. Tankard asks before it starts.
- The **Has bottle** filter (**Has Intel bottle** in Intelbrew mode) hides formulae that
  would compile. It is on by default in Intelbrew mode.
- A package you already have offers **Show in Installed** instead.

## Uninstall a package

1. Select the package and click **Uninstall <name>…** in the detail pane, or right-click it
   and choose **Uninstall…**.
2. Read the confirmation and click **Uninstall**.

- **Dependencies:** the sheet lists dependencies that nothing else would need afterwards,
  under "No longer needed by anything". **Also remove these** is on by default. Tankard
  checks each one again right before removing it, and keeps it if something now needs it.
  Other unused dependencies on your Mac are left alone; use **Homebrew ▸ Remove Unused
  Dependencies…** for those.
- **Needed by other packages:** uninstall is blocked, and the sheet lists what needs it.
- **Pinned:** the sheet offers **Unpin and Uninstall**.
- **Apps:** uninstalling a cask deletes its app.

## Pin a package or skip a version

**Pin:** select the package and click **Pin** in the detail pane, or use the right-click
menu. A pinned package is never upgraded, by Tankard or by `brew upgrade`. **Unpin**
undoes it. The **Pinned** filter (in **More**) lists them.

**Skip one version:** click **Skip This Version** in the detail pane, or choose **Skip
Version X** from the right-click menu. Upgrade N, the menu-bar count and automatic updates
leave that version out. You can still upgrade it by hand, and the next version clears the
skip.

**Dependencies:** the detail pane shows **Depends on** and **Used by**, with a dependency
tree below them. Click a name to jump to that package. The right-click menu has **Show
Dependencies** and **Show What Uses It**.

## Adopt apps you installed yourself

Apps you downloaded yourself can be handed to Homebrew, so `brew upgrade` keeps them up to
date.

1. Choose **Homebrew ▸ Adopt Apps…**. Tankard scans Applications and ~/Applications. The
   scan changes nothing.
2. Tick the apps to adopt. Each match says how sure it is: **Sure match**, **Likely match**
   or **Name only**. Name-only matches are never ticked for you.
3. For an app that updates itself, choose who updates it (see
   [Apps that update themselves](#apps-that-update-themselves)).
4. Click **Adopt** and confirm.

The apps are grouped:

- **Ready to adopt.**
- **Needs update first:** Homebrew adopts only the exact version the cask installs. Update
  the app with its own updater, then click **Scan Again**.
- **Can't adopt:** for example, the cask runs an installer package, or the app isn't where
  the cask puts it.
- **No cask.**

Apple's apps, App Store apps and apps Homebrew already manages aren't listed.

**After adopting, Homebrew owns the app.** It stays where it is, but `brew upgrade`
replaces it with the cask's version, and uninstalling the cask deletes the app.

Adopt Apps isn't available in Intelbrew mode, because it needs Homebrew's online cask list.

## Apps that update themselves

Many apps (casks) update themselves. By default brew doesn't list their upgrades, and
neither does Tankard. They show ⟳ next to the name.

- **For all apps:** turn on **Settings ▸ Upgrades ▸ Include self-updating apps** to list
  them as upgrades too.
- **For one app:** select it and use the **Updates** menu in the detail pane:
  - **Default**: follows the setting above. The menu says which way it goes now.
  - **App updates itself**: Tankard leaves its upgrades out. `brew upgrade` in Terminal
    can still upgrade it.
  - **Homebrew updates it**: every newer version is listed and upgraded.

**Running apps.** By default brew quits a running app before upgrading it, and reopens it
afterwards. To keep apps open, turn on **Settings ▸ Upgrades ▸ Don't quit running apps
during upgrades**.

## Restore points and rollback

Tankard saves a restore point (the versions you have installed) before every upgrade and
automatic update. It keeps the last 20.

**See or use them:** **Homebrew ▸ Restore Points…**. Each one shows what changed since it
was saved. **Save Now** saves one by hand. **Copy Brewfile** copies its taps, formulae and
casks as a Brewfile.

**Roll back an upgrade:**

1. Turn on **Settings ▸ Upgrades ▸ Keep the previous version after upgrades** before you
   upgrade. It uses disk space until Clean Up removes the old versions.
2. In Restore Points, choose a point and click **Restore…**. The plan shows every brew
   command first.
3. Leave **Pin rolled-back formulae** on, so the next upgrade doesn't undo it.

Only formulae whose old version is still installed can be rolled back. Casks, keg-only and
pinned formulae, HEAD builds and formulae other packages depend on can't. Tankard marks
those and shows the commands to do it by hand. A restore never uninstalls what was added
since.

## Vulnerability scan

Tankard can run `brew vulns` (Homebrew 7) to check your formulae against known
vulnerabilities on OSV.dev.

**Scan:** choose **Homebrew ▸ Scan for Vulnerabilities**, or **Scan Now** in the Vulnerable
filter or in **Settings ▸ Upgrades**. To scan after every refresh, turn on **Scan for
vulnerabilities when refreshing**. It is off by default, because brew sends your formula
names and versions to OSV.dev.

- A vulnerable formula gets a ⚠ tag with its severity. The detail pane lists each advisory,
  linked to OSV.dev, with the version that fixes it, if there is one.
- The **Vulnerable** filter lists them, with **Upgrade N** for those that have an upgrade.
  Pinned packages are left out.
- brew often reports a **partial scan**: it skips formulae it can't match to a source. Those
  say "Not checked by brew vulns". Casks aren't scanned.
- A scan stops after 60 seconds. **Stop** ends it sooner.
- **Show new vulnerabilities in the menu bar** adds a ⚠ to the menu-bar icon and a line in
  its menu when a scan finds something new.

## Taps

A tap is a source of formulae and casks. **Homebrew ▸ Taps…** lists yours, with how many
packages you installed from each.

- **Show Installed** filters the Installed list to one tap.
- **Add Tap…** takes `user/repo`, and optionally a git URL. Third-party taps run their
  authors' code; Tankard warns you first.
- **Remove…** runs `brew untap`. It is blocked while anything installed comes from the tap.
- **Trust…** and **Stop Trusting…** set Homebrew 7's trust for a third-party tap.

## Services

The **Services** tab (⌘3) lists `brew services`. Select one to see its details.

- **Start** starts it and registers it to start at login. **Stop** stops it and unregisters
  it. **Restart** restarts it.
- Services that run as root (started with `sudo`) get no buttons. Tankard shows the `sudo`
  command to run in Terminal instead.

## Health, History, Clean Up and Brewfiles

- **Homebrew ▸ Health…** runs `brew doctor`, `brew config` and `brew missing`. Known
  warnings are explained in plain English, with the command that fixes them. Tankard shows
  the command; it never runs it. **Environment** lists your `HOMEBREW_*` settings: where
  each comes from, whether Tankard's brew gets it, and why not when it doesn't. See
  [Your HOMEBREW_* settings](#my-homebrew_-settings-from-zshrc).
- **Homebrew ▸ History…** lists every brew command Tankard ran (the last 500), with its
  result. Failed ones have **Retry**.
- **Homebrew ▸ Clean Up…** shows what `brew cleanup` would remove and how much space it
  frees, then runs it when you click **Clean Up**.
- **Homebrew ▸ Remove Unused Dependencies…** shows what `brew autoremove` would remove
  before it runs.
- **File ▸ Export Brewfile…** saves a Brewfile of your taps, formulae and casks.
- **File ▸ Check Brewfile…** lists what a Brewfile needs that this Mac doesn't have.
  **Restore Plan…** then installs them one by one with **Install with Tankard**, or gives
  you the `brew bundle` command to copy.

Deprecated and disabled packages get a tag and a box in the detail pane with Homebrew's
reason and suggested replacement.

## The menu-bar icon

A mug in the menu bar with the number of upgrades ready. Click it for:

- the upgrades (up to 8; "and N more…" opens the list), and **Upgrade All**;
- **Open Tankard**, **Check Now** (the same as Refresh) and **Quit Tankard**;
- the scan's progress, a new-vulnerabilities notice, the last automatic update, and
  **Snooze**, when they apply.

With the icon on, closing the window keeps Tankard running. With **Hide Dock icon when the
window is closed** on (the default), Tankard then also leaves the Dock and ⌘-Tab. Click
**Open Tankard** to bring the window back.

### Notifications

**Turn them on:** **Settings ▸ General ▸ Notify me about new upgrades**. It is off by
default. macOS asks for permission the first time.

- Tankard runs `brew update` in the background every check interval, and posts a
  notification when upgrades appear that weren't there at the last check. The first check
  only records what is already outdated.
- **Refresh** (⌘R) and **Check Now** post a notification only when the Tankard window isn't
  in front. With the window in front, the status bar shows the result for a few seconds,
  such as "3 new upgrades" or "No new upgrades". Upgrades seen this way aren't announced
  again.
- With the setting off, the first Refresh that finds new upgrades adds a one-time hint:
  "Turn on notifications in Settings ▸ General".
- If notifications for Tankard are off in **System Settings ▸ Notifications**, the toggle
  stays off, or shows a warning, with an **Open Notification Settings** button.

**Show new vulnerabilities in the menu bar** (Settings ▸ Upgrades) is not a notification.
It adds a ⚠ next to the menu-bar icon and a line in its menu. A scan never posts a
notification.

## Settings reference

Open with **Tankard ▸ Settings…** (⌘,). Each setting has an ⓘ button with more detail.

**General**

| setting | default | what it does |
|---|---|---|
| Show Tankard in the menu bar | on | The mug icon. With it on, closing the window keeps Tankard running. |
| Hide Dock icon when the window is closed | on | Only with the menu-bar icon on. |
| Check for new versions in the background | on | Runs `brew update` at most once per check interval. Grayed out when `HOMEBREW_NO_AUTO_UPDATE` is set; Settings says where. |
| Notify me about new upgrades | off | A notification when new upgrades appear. See [Notifications](#notifications). |
| Check every | 6 hours | 1, 3, 6, 12, 24 or 48 hours. Used by the two settings above. |
| Open Tankard at login | off | Adds Tankard to Login Items. |

**Upgrades**

| setting | default | what it does |
|---|---|---|
| Include self-updating apps | off | Lists upgrades for apps that update themselves. |
| Don't quit running apps during upgrades | off | brew upgrades a running app without quitting it. |
| Keep the previous version after upgrades | off | Needed for rollback. Uses disk space. |
| Upgrade packages automatically | off | Schedule, version rule and Snooze. See [Automatic updates](#automatic-updates). |
| Automatically upgrade | All versions | Or Minor and patch only, or Patch only. |
| Scan for vulnerabilities when refreshing | off | Sends formula names and versions to OSV.dev. |
| Show new vulnerabilities in the menu bar | off | A notice in the menu-bar icon. |

**Appearance:** **Dark**, **Light**, **System** (the default, follows your Mac), **Tankard**
(purple and amber) and **Dracula**.

## Menu reference

- **Tankard:** About Tankard, **Check for Tankard Updates…**, Settings… (⌘,), Quit Tankard (⌘Q).
- **File:** **Check Brewfile…**, **Export Brewfile…**, Close (⌘W), Close All.
- **View:** **Installed** (⌘1), **Discover** (⌘2), **Services** (⌘3).
- **Homebrew:**
  - **Refresh** (⌘R), **Scan for Vulnerabilities**
  - **Health…**, **History…**
  - **Clean Up…**, **Remove Unused Dependencies…**
  - **Taps…**, **Adopt Apps…**, **Restore Points…**
  - **Revert to Standard Homebrew…** (Intelbrew mode only), **Uninstall Homebrew…**
- **Help:** **Tankard Help** (this page), **Tankard on GitHub**, **Report an Issue…**

Items that run brew gray out while brew is busy.

**Tankard ▸ Check for Tankard Updates…** asks GitHub for the latest release, only when you
choose it. If Homebrew installed Tankard, **Upgrade with Homebrew** upgrades it and offers
to relaunch. Otherwise **Download** opens the release page.

**Revert to Standard Homebrew…** and **Uninstall Homebrew…** never run inside Tankard. Each
shows exactly what will run and asks you to type a word (`revert` or `uninstall`). Then it
opens Terminal with the commands, and waits for you to press Return.

- **Revert** switches an Intelbrew Mac back to standard Homebrew. It backs up your shell
  startup files, removes the Intelbrew lines from them, points brew back at
  Homebrew/brew and runs `brew update`.
- **Uninstall Homebrew** runs Homebrew's official uninstaller. It removes every installed
  package.

**Right-click menus** on the Installed list, Discover and the menu-bar list offer the same
actions as the buttons, plus Copy Name, Copy Upgrade (or Install) Command, Open Homepage,
Open Release Page and Show in Finder.

## Privacy and network

<a id="how-it-behaves"></a>

Tankard has no telemetry and no account. Its own network requests:

- **Discover** (normal mode) downloads Homebrew's catalog from formulae.brew.sh the first
  time you open it, and keeps it for an hour. It also downloads Homebrew's public install
  counts (about 13 MB, for every package), and keeps them for a day. Because these are the
  files for every package, the site never learns which packages you look at. Adopt Apps uses
  the same catalog.
- **Download progress for a cask:** one request to the cask's own download server for the
  file size.
- **Check for Tankard Updates…:** one request to GitHub, only when you choose it.
- **Intelbrew mode:** Discover reads your local taps instead of formulae.brew.sh. When a
  compile warning is shown, Tankard downloads Intelbrew's build times from GitHub.

brew's own requests:

- `brew update` (Refresh, Check Now and the background update) fetches from GitHub and
  formulae.brew.sh, as it does in Terminal.
- `brew vulns` sends each formula's source repository and version to OSV.dev. It runs only
  when you scan, or on every refresh if you turn that on.
- Installing, upgrading and adopting download from where brew always does.
- **Analytics:** set `HOMEBREW_NO_ANALYTICS=1` in your shell profile or brew.env and the
  brew Tankard runs sends no Homebrew analytics, the same as in Terminal.
- **Mirrors:** `HOMEBREW_API_DOMAIN`, `HOMEBREW_BOTTLE_DOMAIN` and `HOMEBREW_ARTIFACT_DOMAIN`
  set in a shell profile are not applied by Tankard yet, and Discover still reads
  formulae.brew.sh. Set them in a brew.env file and brew uses them; Tankard's own catalog
  downloads don't.

Links (homepages, release pages) open only when you click them.

## What Tankard runs

Reading your packages never changes anything. Your packages change only when you click,
or when automatic updates is on. Commands run one at a time, never with sudo.

| you click | Tankard runs |
|---|---|
| Refresh (⌘R) or Check Now | `brew update` |
| Upgrade | `brew upgrade --formula\|--cask <tap>/<name>`, one per package |
| Install | `brew install --formula\|--cask <tap>/<name>` |
| Uninstall | `HOMEBREW_NO_AUTOREMOVE=1 brew uninstall --formula\|--cask <tap>/<name>`, then each dependency you chose to remove |
| Adopt | `brew install --cask --adopt <tap>/<name>`, one per app |
| Replace with Bottle | `brew reinstall --force-bottle --formula <tap>/<name>` |
| Pin / Unpin | `brew pin\|unpin --formula\|--cask <tap>/<name>` |
| Clean up | `brew cleanup` |
| Remove Unused Dependencies | `brew autoremove` |
| Start / Stop / Restart a service | `brew services start\|stop\|restart -- <name>` |
| Add / Remove a tap | `brew tap <user/repo>` / `brew untap <user/repo>` |

The background `brew update` updates Homebrew and its package lists. It doesn't install or
upgrade any of your packages.

With **Don't quit running apps during upgrades** on, cask upgrades start with
`HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`. With **Keep the previous version after upgrades** on,
upgrades and installs start with `HOMEBREW_NO_INSTALL_CLEANUP=1`. The command shown in the
app always includes these.

## App Management

macOS asks before one app installs, updates or deletes another. Tankard needs this
permission (**System Settings ▸ Privacy & Security ▸ App Management**) for anything that
changes an app: installing, upgrading, adopting or uninstalling a cask that has an app, a
restore point's cask reinstall, and automatic updates. Formulae, fonts and Replace with
Bottle don't need it.

**Allow it:**

1. Before the first app change, Tankard shows a sheet. Click **Open System Settings** and
   turn on Tankard under App Management.
2. Click **I've done this**, then **Relaunch Tankard**. macOS applies the permission only
   to an app started after you allowed it.
3. After the relaunch, Tankard offers **Run Again** for what you were doing. Nothing runs
   until you click it.

**Continue without relaunching** tries straight away instead. **Not now** carries on
without the permission.

When macOS blocks a change, the step fails with **"macOS blocked changing an app"**, and
Tankard offers the relaunch again. For automatic updates, you get a notification instead.

The permission is tied to the app's signature. Releases keep it across updates. A build
you made yourself needs it again after every rebuild.

## Troubleshooting

### "macOS blocked changing an app"

Tankard doesn't have App Management permission yet, or macOS hasn't applied it. See
[App Management](#app-management).

### "Another Homebrew command is running"

brew runs one command at a time. Wait for the other one (in Terminal or another app) to
finish, then try again. **Homebrew ▸ History…** has **Retry** for failed commands.

### "Waiting for brew update to finish…"

The background `brew update` is running. Your upgrade, install or uninstall starts as
soon as it is done.

### brew needs a password

Tankard never types a password or runs sudo. When brew needs one, Tankard shows the
command to run in Terminal.

### A download failed, or "Homebrew couldn't reach the network"

Check your internet connection, VPN or proxy, then retry. Tankard keeps showing the last
list it read.

### "Homebrew not found"

Tankard looks for brew at `/usr/local/bin/brew` and `/opt/homebrew/bin/brew`. Install
Homebrew from the welcome screen, then click **Check Again**.

### My `HOMEBREW_*` settings from `~/.zshrc`

Apps started from the Dock don't run your shell profile, so Tankard reads it (single
`export HOMEBREW_X=value` lines; values that need shell expansion are skipped) and passes
privacy and behaviour settings on to brew: `HOMEBREW_NO_ANALYTICS`,
`HOMEBREW_NO_INSECURE_REDIRECT`, `HOMEBREW_CURL_RETRIES`, `HOMEBREW_FORCE_BREWED_CURL`,
`HOMEBREW_TEMP`, the `HOMEBREW_FORBIDDEN_*` lists, cleanup and download settings and a few
more. From `HOMEBREW_CASK_OPTS` only `--require-sha` and `--language=…` pass: `--appdir`
and the other `--*dir` options would move where apps go, which Adopt Apps and the App
Management check rely on, and options like `--force` would act on apps without asking. **Homebrew ▸ Health… ▸ Environment** shows
each one and what happened to it.

Not passed from a shell profile:

- anything that changes where brew lives or what it trusts: `HOMEBREW_PREFIX`, the
  `*_GIT_REMOTE`s, `HOMEBREW_DEVELOPER`,
  `HOMEBREW_NO_INSTALL_FROM_API`, `HOMEBREW_NO_VERIFY_ATTESTATIONS` and the like (Intelbrew
  mode sets its own remotes);
- `HOMEBREW_CACHE` and `HOMEBREW_LOGS` (download progress and Clean Up assume the default
  folders);
- mirrors (`*_DOMAIN`), tokens, proxies, and `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`;
- settings Tankard controls: colour, verbose and debug output, and the greedy-upgrade
  switches (Tankard's self-updating apps setting decides those);
- any `HOMEBREW_*` name not on Tankard's list.

To use one of those anyway, put it in a `brew.env` file, such as `~/.homebrew/brew.env`.
brew reads that itself however it is started, and a brew.env value wins over anything
Tankard passes. So a `HOMEBREW_CASK_OPTS` with `--appdir` there applies to Tankard's
installs too; Health ▸ Environment warns about it, because Adopt Apps' location checks
assume `/Applications`. A brew.env that sets `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`
pauses automatic updates (their safe mode relies on that check); Settings and the menu bar
say so. Manual upgrades still run. Details are in
[architecture.md](architecture.md#intelbrew-detection-and-brews-environment).

### "Check for new versions in the background" is grayed out

`HOMEBREW_NO_AUTO_UPDATE` is set. Settings says where.

### The scan says "partial scan"

That is brew's own result: it couldn't check some formulae. The others are still
checked.

### The Dock icon disappears when I close the window

That is **Hide Dock icon when the window is closed**, on by default. Click the menu-bar
icon ▸ **Open Tankard**, or untick the setting.

### "Tankard can't be opened because Apple cannot check it"

Releases are signed and notarized, so this happens only with an unsigned or ad-hoc signed
build that was downloaded, such as a zip someone else built. On macOS 14, right-click
Tankard.app ▸ **Open** once. On macOS 15 and later, try to open it, then click **Open
Anyway** in **System Settings ▸ Privacy & Security**. Or run
`xattr -dr com.apple.quarantine Tankard.app`.

### Open at login doesn't stick

If Settings says "Waiting for approval", allow Tankard in **System Settings ▸ General ▸
Login Items**. A build you made yourself may be refused.

### Something else

**Help ▸ Report an Issue…**. **Homebrew ▸ History…** and
`~/Library/Logs/Tankard/upgrade.log` show exactly what brew said.
