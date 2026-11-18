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

Scheduled checks (the background update, the new-upgrades notification check and
automatic updates) don't start while the Mac is asleep or has no network. After the Mac
wakes, Tankard waits for the network, then checks once. A scheduled `brew update` that
takes more than 15 minutes is stopped, and one that is running when the Mac goes to sleep
is stopped too. When a scheduled check can't finish (offline, another Homebrew command
running, sleep, too slow), History shows one gray line, such as "Scheduled check didn't
run: offline. Will retry.", instead of a red failure each time. Refresh and anything else
you start still report every failure in full.

## The Installed list at a glance

- **Toolbar:** Installed, Discover and Services (⌘1, ⌘2, ⌘3), Refresh (⌘R) and search.
  Search matches the name and description. You can paste a whole command such as
  `brew install wget` or `brew install --cask firefox` into either search field: Tankard
  searches for the package name. When nothing installed matches, the list offers **Search Discover for "wget"**,
  which opens Discover with the same search.
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

Each package is one line. A note after the name says what matters about it now: an
orange hammer when its upgrade compiles from source, a green box when a bottle could
replace a source build, or a short note such as "Tap has 1.5.7". In a narrow column the
words are cut short; hover over them for all of it.

**Mac Pro (Late 2013) on a newer macOS.** On a Mac Pro 6,1 running macOS 13 or later
through OpenCore Legacy Patcher, apps built with Electron (Visual Studio Code, Slack,
Discord and many more) can draw incorrectly on its AMD FirePro graphics: blank, black or
flickering windows, or garbled text. Tankard marks such installed apps with an orange ⓘ,
and the app's details explain it and show its Chromium version. Tankard only tells you; it
doesn't change the app. It checks for the Electron framework inside each installed cask's
app (`Contents/Frameworks/Electron Framework.framework`) and reads the Chromium version
from it only when you open that app's details. On any other Mac it checks nothing.

## Upgrade packages

**Upgrade everything:** click the green **Upgrade N** in the status bar, or **Upgrade All**
in the menu-bar icon.

**Upgrade one package:** select it and click **Upgrade <name>** in the detail pane, or
right-click it and choose **Upgrade <name>**.

The upgrade sheet shows each package, the exact command and brew's live output. Packages
upgrade one at a time; a failure doesn't stop the rest.

When several packages need downloading, one `brew fetch` downloads them all first, in
parallel ("Downloading 4 of 9 · 120.0 of 410.0 MB (29%)"); each upgrade then installs from brew's
cache. A download that fails there is tried again by that package's own upgrade, and
`HOMEBREW_DOWNLOAD_CONCURRENCY=1` makes brew download one at a time.

- **Stop Now** stops brew straight away, for one package or many. brew undoes the step it
  was in the middle of: an install stopped while pouring leaves nothing installed, and a
  stopped upgrade keeps the old version. While brew is changing a package (not while it
  downloads) Tankard asks first. History records the step as stopped.
- **Stop After Current** (several packages) lets the running package finish and skips the
  rest.
- **Retry** (one package) or **Retry Failed (N)** runs the failed steps again, with the
  same checks as the Upgrade and Install buttons; right-click a failed package for
  **Retry <name>**. Under the log, one line says what to do about a failure Tankard
  recognizes (another brew's lock, the network, a full disk, a checksum mismatch, folders
  brew can't write).
- **Quitting** while brew runs asks first: **Keep Running**, **Stop After Current and
  Quit**, or **Quit Now** (stops brew as Stop Now does). brew can't carry on after Tankard
  quits, so an interrupted run's remaining packages are offered at the next launch:
  **Upgrade the Remaining N Packages**.
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

**Long builds.** While a package builds from source, the sheet (and the small progress
window) shows how long it has been building: "Building from source… 4 min so far". brew
doesn't say how long a build will take, so the estimate comes from this Mac: once you have
built the same formula from source before, the line adds "(last time on this Mac: about 15
min)", the middle of the last three builds, rounded.

**Replace a source build with a bottle.** A package you built from source whose version
now has a bottle says **Bottle available** under its name and gets a **Replace with Bottle**
button.
The Bottle available filter has **Replace all**.

**Casks that need your password.** Some casks run a `.pkg` installer (Windows App,
Microsoft Office, drivers), and brew runs that installer with `sudo`. Before such an
upgrade starts, the sheet says "<name> needs your administrator password" and waits for you
to click **Upgrade**; the uninstall confirmation says the same. When brew's sudo asks,
Tankard shows a password dialog, "Tankard needs your password", with one line for what it
is for ("To upgrade windows-app.") and the brew command under **Details**. Type your Mac's
login password and click **OK**:

- The password goes from the dialog straight to sudo. Tankard doesn't keep it, log it or
  save it anywhere.
- **Cancel** stops that step. The sheet then shows the command to run in Terminal instead.
- While the dialog is up, the sheet says "Waiting for your password in the Tankard dialog"
  and shows the Terminal command. If you don't see the dialog, cancel it (or click
  **Stop Now**) and use Terminal.
- A wrong password brings the dialog back ("Wrong password, try again."); after three
  wrong tries sudo gives up and the sheet shows the Terminal command.
- Each brew command asks at most once: brew clears sudo's remembered password before its
  first sudo, and later sudo steps of the same command don't ask again. Upgrading two such
  casks asks twice.
- These casks show a small lock at the end of their row in the lists, in the upgrade plan and
  in the running upgrade ("Needs your password to upgrade"). Upgrade All runs them last, so
  the password dialogs come at the end instead of in the middle of the run (a cask that
  depends on one of them runs after it).
- The dialog closes by itself after 5 minutes, or when you click **Stop Now**.
- The dialog only ever answers Tankard's own brew commands. Run any other way (another
  program's sudo, Terminal), it refuses before showing anything, so it can't be used to
  ask you for your password on someone else's behalf.

Other cask installs, upgrades and uninstalls can ask too, when brew needs sudo to replace
or remove files it doesn't own; formulae never do.

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
  - Never a password prompt: a cask whose installer needs your administrator password is
    skipped ("needs your administrator password; upgrade it by hand"), and brew is told
    not to run sudo at all (`HOMEBREW_NO_SUDO=1`), so any other step that would need it
    fails with that reason instead of asking. The Auto-update log has **Upgrade Now** for
    those casks: a normal upgrade, which asks for your password.
  - Tankard doesn't upgrade itself this way. The menu-bar icon says when a new Tankard is
    available.
- **Terminal brew running, or quitting mid-run:** a step that finds brew busy waits for it
  quietly, as manual upgrades do (up to 15 minutes; logged), and is skipped as "Homebrew
  was busy" if it is still busy. Quitting Tankard during a step asks first; nothing is
  offered at the next launch: the interrupted run starts again after it, under the same
  conditions. Quitting during the run's `brew update` or download doesn't ask, and that
  run counts as done. That's harmless, since nothing has changed yet: the next scheduled
  run does the work.
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
  X (compiles)…**. Tankard asks before it starts.
- **Apps (casks) are turned off.** An Intelbrew Mac set up without casks can't install
  apps like Firefox: casks come from the homebrew/cask tap, which the Intelbrew installer
  adds only when you say yes. Discover then shows a banner; **Turn On Apps…** asks, then runs
  `brew tap homebrew/cask` (a one-time download of about 620 MB). The ✕ hides the banner;
  you can add the tap later from **Homebrew ▸ Taps…**.
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
- **Several versions of a formula** (after an upgrade with **Keep the previous version**, or
  a rollback): the confirmation says "Removes all installed versions of x (1.0, 1.1)", and
  Tankard runs `brew uninstall` once per version. Afterwards it checks what is still
  installed; anything left shows as "Uninstall incomplete" with the versions.

## Pin a package or skip a version

**Pin:** select the package and click **Pin** in the detail pane, or use the right-click
menu. A pinned package is never upgraded, by Tankard or by `brew upgrade`. **Unpin**
undoes it. The **Pinned** filter (in **More**) lists them.

**Skip one version:** click **Skip Version X** in the detail pane or the right-click
menu. Upgrade N, the menu-bar count and automatic updates
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

Apple's apps, App Store apps and apps Homebrew already manages aren't listed. That includes
apps a cask installed with an installer package (Microsoft Word, Teams, Windows App):
Tankard knows them from the package's install receipt and the cask's uninstall steps.

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

While **Keep the previous version after upgrades** is off, Restore Points says so at the
top, with **Keep Old Versions** to turn it on. An upgrade whose old version is gone says
"Old version removed by cleanup".

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
  the command; it never runs it. **Environment** lists your `HOMEBREW_*` settings, proxy
  variables and `XDG_CONFIG_HOME`: where each comes from, whether Tankard's brew gets it,
  and why not when it doesn't. A proxy's user name and password show as `•••`
  (`http://•••@proxy:8080`), here and in the `brew config` output. A brew.env setting that
  overrides one of Tankard's gets a warning sign and the reason, and the section opens by
  itself. See [Your HOMEBREW_* settings](#my-homebrew_-settings-from-zshrc).
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

Click an upgrade to open Tankard on it: the Installed tab, with the search and any More
filter cleared, and the package selected, so its details show **Upgrade** and any compile
warning. Click "N upgrades ready" for the Upgrades list, or the finished scan's line
("Scanned 11 · found 2") for the Vulnerable list. **Upgrade All** is the only thing the menu
runs itself.

**Upgrade All** (and **Upgrade** in a row's right-click menu) closes the menu and shows the
upgrade in a small window of its own, not the whole Tankard window: the packages, progress,
brew's output, the compile plan when something builds from source, and **Stop**. A password
dialog for a cask appears above it.

- **Show in Tankard** opens the Tankard window with the same run in its sheet.
- When everything upgraded, the window closes by itself after a moment, with a "Tankard
  upgraded N packages" notification (click it for History). If brew printed post-install
  notes, the window shows them instead and stays until you click **Done**.
- When something failed or you stopped it, the window stays open with what went wrong,
  **Retry** where it applies, and **Close**.
- Closing it while brew runs only hides it: the run goes on. The first time in a session
  Tankard says so and asks before closing. The menu's line then reads **Show Upgrade
  Progress** while brew runs, **Show Upgrade Results** once it has finished, and **Show
  Upgrade Plan** when a compile plan is waiting. It always brings the window to the front,
  even when other windows cover it.
- A hidden run that finishes posts a notification: "Tankard upgraded N packages" when all
  went well (the menu goes back to **Upgrade All**), or "The upgrade finished with
  problems" (or with notes to read), which opens the results.
- These notifications follow macOS's notification setting for Tankard (System Settings ▸
  Notifications), not Tankard's "new upgrades" setting: you started the run. With
  notifications off for Tankard, nothing is shown and everything else works the same.
- With the Tankard window already in front (Tankard active, you were last in its window,
  and the window not covered or on another Space), Upgrade All opens the usual sheet on it.
- The window is titled for what it shows ("Upgrading 3 packages", "Upgrade finished", "Upgrade
  finished with problems") and takes each page's size; a page taller than the screen scrolls.
- A menu-bar Upgrade while a plan or another sheet is up shows that first and starts nothing.
- The window opens in the middle of the screen you're on, then where you last left it
  until Tankard quits. It opens on the Space you are on, also over a full-screen app.
- While the window shows a run, its results or a plan, the Tankard window's own Upgrade,
  Uninstall, Install and Replace buttons wait, as they did behind the sheet; their help
  says why. The button at the bottom right of the Tankard window moves the run (or plan)
  into the window instead.

The Homebrew and File menus wait while this window is open, as they do for a sheet.

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
- **Click a notification** to open Tankard on **Installed ▸ Upgrades**. Its **Upgrade All…**
  action opens a sheet listing what would be upgraded; nothing runs until you click
  **Upgrade N** there. **Later** just dismisses it. Clicking an automatic-update
  notification opens the Auto-update log.

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

Items that run brew or open a sheet gray out while brew is busy (a run shown or hidden)
and while a sheet is open. **History…** and **Check for Tankard Updates…** stay available
during a hidden run.

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
- **Proxies:** `http_proxy`, `https_proxy`, `all_proxy`, `no_proxy` (and `ftp_proxy`, and
  the upper-case `HTTPS_PROXY`, `ALL_PROXY`, `FTP_PROXY`) set in your shell profile or in
  Tankard's own environment are passed to brew, so brew's downloads, `brew update` and git
  go through your proxy as they do in Terminal. brew itself ignores the upper-case
  `HTTP_PROXY` and `NO_PROXY`, so Tankard doesn't pass them either; use the lower-case
  names. A brew.env file can set the lower-case ones too.
- **Tankard's own requests** (Discover's catalog and install counts, cask download sizes,
  Check for Tankard Updates…) use the proxy in **System Settings ▸ Network ▸ Details… ▸
  Proxies**, like other Mac apps, not the shell variables above.

Links (homepages, release pages) open only when you click them.

## What Tankard runs

Reading your packages never changes anything. Your packages change only when you click,
or when automatic updates is on. Commands run one at a time. Tankard never runs sudo
itself; when a cask's installer needs your administrator password, a Tankard dialog passes
it straight to sudo (or you can run the command in Terminal). See below.

| you click | Tankard runs |
|---|---|
| Refresh (⌘R) or Check Now | `brew update` |
| Upgrade | `brew upgrade --formula\|--cask <tap>/<name>`, one per package; first, for two or more bottled formulae or two or more casks, one `brew fetch --formula\|--cask <tap>/<name>...` per kind |
| Install | `brew install --formula\|--cask <tap>/<name>`; installing a Brewfile's missing packages fetches first, as Upgrade does |
| Uninstall | `HOMEBREW_NO_AUTOREMOVE=1 brew uninstall --formula\|--cask <tap>/<name>` (once per installed version of a formula), then each dependency you chose to remove |
| Adopt | `brew install --cask --adopt <tap>/<name>`, one per app |
| Replace with Bottle | `brew reinstall --force-bottle --formula <tap>/<name>` |
| Pin / Unpin | `brew pin\|unpin --formula\|--cask <tap>/<name>` |
| Clean Up | `brew cleanup` |
| Remove Unused Dependencies | `brew autoremove` |
| Start / Stop / Restart a service | `brew services start\|stop\|restart -- <name>` |
| Add / Remove a tap | `brew tap <user/repo>` / `brew untap <user/repo>` |

The background `brew update` updates Homebrew and its package lists. It doesn't install or
upgrade any of your packages.

With **Don't quit running apps during upgrades** on, cask upgrades start with
`HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`. With **Keep the previous version after upgrades** on,
upgrades and installs start with `HOMEBREW_NO_INSTALL_CLEANUP=1`. The command shown in the
app always includes these.

Cask installs, upgrades, reinstalls, adopts and uninstalls (and a restore's cask steps) also
start with `SUDO_ASKPASS` set to Tankard's password dialog,
`Tankard.app/Contents/MacOS/tankard-askpass`, and `HOMEBREW_TANKARD_ASKPASS_CONTEXT` set to
the command, which the dialog names in one line ("To upgrade windows-app.") and shows in full
under Details. Homebrew then runs `sudo -A`, which asks the dialog instead
of a terminal. These two are left out of the command shown, because the copy you paste into
Terminal should ask in Terminal; the sheet's log says when a password may be asked for.
Formulae, `brew update`, cleanup, taps, services and every status read never get them.
Automatic updates get `HOMEBREW_NO_SUDO=1` instead.

Upgrades, installs, uninstalls and Replace with Bottle run with
`HOMEBREW_NO_AUTO_UPDATE=1`, so brew installs exactly the versions the list showed;
Refresh is where `brew update` runs. Every brew command also gets the `HOMEBREW_*`
settings Tankard passes on from your shell profile, such as `HOMEBREW_NO_ANALYTICS` and
`HOMEBREW_DOWNLOAD_CONCURRENCY` (see
[My `HOMEBREW_*` settings](#my-homebrew_-settings-from-zshrc)).

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

### "Waiting for another Homebrew command to finish…"

A brew in Terminal (or another app) holds brew's lock on what this step needs. Tankard
waits for it to finish and then runs the step again, by itself; the rest of the run
waits too. **Stop Now** ends the wait.

### "Another Homebrew command is running"

The other brew kept its lock for 15 minutes, so Tankard gave up on that step. Wait for
it to finish, then **Retry** in the sheet (or **Homebrew ▸ History…**).

### "A download didn't match its checksum"

The file brew downloaded isn't the one it expected: often an interrupted download, or a
package that changed upstream since brew last updated. Click **Refresh** (it runs
`brew update`), then **Retry**.

### "Waiting for brew update to finish…"

The background `brew update` is running. Your upgrade, install or uninstall starts as
soon as it is done.

### brew needs a password

For a cask, Tankard shows its password dialog when brew's sudo asks (see
[Casks that need your password](#upgrade-packages)). If you cancel it, type the wrong
password three times, or the step isn't a cask change (a `brew update` that needs sudo,
a service that runs as root), the sheet shows the command to run in Terminal instead.
Automatic updates never ask; they list the cask as skipped.

If the dialog doesn't appear, check the sheet's log for "sudo: a terminal is required":
that means this copy of Tankard has no `tankard-askpass` next to it (a build run with
`swift run`), so use the Terminal command.

### A download failed, or "Homebrew couldn't reach the network"

Check your internet connection, VPN or proxy, then retry. Tankard keeps showing the last
list it read.

### "Homebrew not found"

Tankard looks for brew at `/usr/local/bin/brew` and `/opt/homebrew/bin/brew`. Install
Homebrew from the welcome screen, then click **Check Again**.

### My `HOMEBREW_*` settings from `~/.zshrc`

Apps started from the Dock don't run your shell profile, so Tankard reads it (single
`export HOMEBREW_X=value` lines; values that need shell expansion are skipped) and passes
privacy and behavior settings on to brew: `HOMEBREW_NO_ANALYTICS`,
`HOMEBREW_NO_INSECURE_REDIRECT`, `HOMEBREW_CURL_RETRIES`, `HOMEBREW_FORCE_BREWED_CURL`,
`HOMEBREW_TEMP`, the `HOMEBREW_FORBIDDEN_*` lists, cleanup and download settings and a few
more. From `HOMEBREW_CASK_OPTS` only `--require-sha` and `--language=…` pass: `--appdir`
and the other `--*dir` options would move where apps go, which Adopt Apps and the App
Management check rely on, and options like `--force` would act on apps without asking.
**Homebrew ▸ Health… ▸ Environment** shows each one and what happened to it.

Not passed from a shell profile:

- anything that changes where brew lives or what it trusts: `HOMEBREW_PREFIX`, the
  `*_GIT_REMOTE`s, `HOMEBREW_DEVELOPER`, `HOMEBREW_NO_INSTALL_FROM_API`,
  `HOMEBREW_NO_VERIFY_ATTESTATIONS` and the like (Intelbrew mode sets its own remotes);
- `HOMEBREW_CACHE` and `HOMEBREW_LOGS` (download progress and Clean Up assume the default
  folders);
- mirrors (`*_DOMAIN`), tokens, and `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`;
- settings Tankard controls: color, verbose and debug output, and the greedy-upgrade
  switches (Tankard's self-updating apps setting decides those);
- any `HOMEBREW_*` name not on Tankard's list.

To use one of those anyway, put it in a `brew.env` file, such as `~/.homebrew/brew.env`.
brew reads that itself however it is started, and a brew.env value wins over anything
Tankard passes. So a `HOMEBREW_CASK_OPTS` with `--appdir` there applies to Tankard's
installs too; Health ▸ Environment warns about it, because Adopt Apps' location checks
assume `/Applications`. A brew.env that sets `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`
pauses automatic updates (their safe mode relies on that check); Settings and the menu bar
say so. Manual upgrades still run.

Health ▸ Environment warns about every brew.env setting that undoes one of Tankard's:

- `HOMEBREW_UPGRADE_GREEDY`, `HOMEBREW_UPGRADE_GREEDY_CASKS` or
  `HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS`: they override the self-updating apps setting;
- in Intelbrew mode, a `HOMEBREW_CORE_GIT_REMOTE` or `HOMEBREW_BREW_GIT_REMOTE` that isn't
  the fork, or an empty `HOMEBREW_NO_INSTALL_FROM_API`;
- `HOMEBREW_NO_AUTOREMOVE` set to `0` (or empty, `false`, `no`, `off`): Uninstall would
  also remove every other unused dependency, not just what it lists;
- `HOMEBREW_COLOR`, `HOMEBREW_VERBOSE`, `HOMEBREW_DEBUG`, or an empty `HOMEBREW_NO_COLOR`:
  they change brew's output, which Tankard reads;
- `SUDO_ASKPASS` set to anything but Tankard's own helper: brew would send the password
  prompt to that program. Tankard then never offers its password dialog: a cask step runs
  with `HOMEBREW_NO_SUDO=1` (brew stops before sudo, so that program never runs), and a
  step known to need the password (a `.pkg` installer), or every cask step if brew.env also
  sets `HOMEBREW_NO_SUDO=` empty, isn't run at all. The plan and the sheet say "brew.env
  sets its own password helper (path); run this step in Terminal" and show the command.
  Automatic updates skip cask upgrades while brew.env sets such a helper or clears
  `HOMEBREW_NO_SUDO`, and the Auto-update log says why;
- `HOMEBREW_CELLAR`, `HOMEBREW_CACHE`, `HOMEBREW_LOGS`, mirrors, and settings that change
  where brew gets code from or what it trusts.

brew has no command-line option that undoes these, so remove the line from brew.env if you
want Tankard's behavior.

A proxy's user name and password never appear in what Tankard shows or keeps: the commands
shown and copied don't include the environment, and `upgrade.log`, History, the Auto-update
log, the sheet's log and Health mask any `user:password@` in brew's output as `•••@`. Tokens in brew.env are fine and get no warning.

**Which brew.env.** brew reads `$XDG_CONFIG_HOME/homebrew/brew.env` when
`XDG_CONFIG_HOME` is set, otherwise `~/.homebrew/brew.env`. Tankard reads
`XDG_CONFIG_HOME` (and `HOMEBREW_XDG_CONFIG_HOME`) from its environment or your shell
profile (`export XDG_CONFIG_HOME="$HOME/.config"` and `~/.config` work), passes it to brew,
and shows the same file brew reads. Details are in
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

### "An older copy of Tankard is still running"

Only one Tankard runs at a time: opening it again brings the running one to the front.
After an update, the new Tankard asks the old copy to quit (it never forces it). If the
old copy can't quit, for example because a sheet is open in it, the new one says so;
click **Show Older Copy**, close what's open there and quit it. Updating from 0.8.1 or
0.8.2 can also leave a harmless "quit unexpectedly" report from the old copy. If two
Tankards stay open, quit both and open Tankard again.

### Open at login doesn't stick

If Settings says "Waiting for approval", allow Tankard in **System Settings ▸ General ▸
Login Items**. A build you made yourself may be refused.

### Something else

**Help ▸ Report an Issue…**. **Homebrew ▸ History…** and
`~/Library/Logs/Tankard/upgrade.log` show exactly what brew said.
