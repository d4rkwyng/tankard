# Changelog

All notable changes to Tankard. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Tankard uses [semantic versioning](https://semver.org/). Each release's notes on GitHub
are its section below (`Scripts/changelog-section.sh`).

## [0.8.6] (unreleased)

### Added
- **Homebrew ▸ Upgrade All…** (⇧⌘U), which shows the plan first, and **Homebrew ▸ Upgrade <name>** (⌘U) for the package selected in Installed. Upgrading had no menu command or shortcut.
- **Settings ▸ General ▸ Show the number of upgrades in the menu bar** (on by default). Off, the menu bar shows only the tankard, full when upgrades are ready; the number stays in its tooltip and in the menu.

### Changed
- **Sheets fit the window.** Adopt Apps (620 points tall), Taps, Health, History, Restore Points, Clean Up and Remove Unused had fixed heights, taller than a small window, so their buttons could end up below its edge (Adopt's, even at the default size). Each is now its usual height when there is room and shorter when there isn't: the list scrolls, the buttons stay.
- **The list fits a narrow window.** At the smallest window size, sizes lost digits from the middle ("77…5") and a column header read "Grö". Below 900 points of width the details pane is narrower (224 instead of 272 points), and sizes are never cut.
- **VoiceOver and symbols.** The vulnerability tag reads "2 known vulnerabilities" (it read "Vulnerable: Vulnerable · 2"), "dep" reads "Installed as a dependency", History's ⓘ reads its hint, and the copy button's "Copied" is translated. "Can't uninstall: needed by…" shows a link symbol instead of the lock, which elsewhere means "needs your password". The toolbar tooltip names Services (⌘3).
- **Esc closes every sheet.** Health, History and Taps closed only with Return or Done, Adopt Apps' Done had no key at all; Esc now closes them all. Restore Points' **Restore…** no longer looks like the Return button (Return doesn't run it).
- **Discover finds packages from your own taps.** It used to search only Homebrew's main catalog (formulae.brew.sh), so a formula from a tap you added, even one added in Tankard a moment before, was "No matches". The formulae and casks of every tap outside `homebrew/` are now read from the tap on this Mac (in the background, and again only when a tap changes, including a tap added or removed in Terminal: Discover notices it when it opens, when the window comes to the front and on Refresh) and searched with the rest; their versions come from brew when you look at them. An empty search says where it looked, with **Taps…** to add the tap a package comes from.
- **The marks at the end of a row sit together.** The ⟳ for apps that update themselves moved from after the name to the end of the row, next to the password lock and the Electron ⓘ: always in that order, evenly spaced, the same size.
- **Package names no longer collapse to "…" next to their badges.** The name keeps at least its first 12 characters (all of it when it fits); "dep", "pinned", "Deprecated" and "Vulnerable · 4" shrink to their icons in a narrow column, and leave when even those don't fit. The name's tooltip lists them.
- **Tooltips come up faster**: after about a third of a second instead of 1.5 s, in Tankard only (set in memory at launch; nothing is written to your settings, and a delay you set yourself with `defaults write` still wins).

### Fixed
- **Discover says when an install will trust a tap.** Installing a formula from a tap you don't trust makes brew trust that formula ("Trusted formula steipete/tap/sonoscli"); Discover didn't mention it. Under the install command (and in the compile confirmation) it now says "Installing this trusts the tap steipete/tap for this formula." when brew has refused that tap or the Taps list marks it untrusted.
- **Discover tells a ready-made download from a build.** A formula from a third-party tap with no bottle was always "No bottle: compiles", and the result said "1 build from source", even when the formula downloads a finished program for macOS (steipete/tap/sonoscli installed in a second). Such a formula (a macOS or Mac-processor download, nothing built) now says **Downloads a ready-made program**, installs without the compile warning, and the result counts it as "1 ready-made program". Its version comes from the formula file when brew can't read the tap.
- **No Pin for a package Homebrew can't read, and a failed pin isn't a failed refresh.** Pin was offered for a package from an untrusted tap, `brew pin` failed ("Refusing to load formula…"), and the status bar then said "Last refresh failed" with "Showing the last data Tankard read", although the list was current. Pin and Unpin are no longer offered for such a package, and those two lines appear only when reading brew's status failed.
- **⌘Q quits while the Welcome sheet is open**, and Esc on it counts as Done. ⌘Q did nothing there (macOS doesn't quit an app with a sheet open), and Esc closed the Welcome without marking it done, so it came back at every launch. With no brew command running, Quit Tankard now closes any open sheet first; with one running, it asks as before.
- **A package brew upgraded no longer shows as failed because brew failed on the next package.** With a pinned dependency, `brew upgrade aws-c-auth` upgraded aws-c-auth, then refused a package that depends on it and exited 1; Tankard said "6 failed" (History "failed (exit 1)") when 4 of them were upgraded, and Retry Failed found only 2 to retry. After a run with failed steps, Tankard reads the installed versions again before it reports: a package that is now newer counts as upgraded, History says "upgraded (brew then exited 1 over another package)", and the summary, History and Retry Failed agree.
- **Stop Now stops a build from source within seconds.** brew builds in a session of its own, which the interrupt didn't reach; brew waited for the build, and Stop Now took about 16 seconds and ended with a forced stop that can cut brew's own clean-up short. The interrupt now reaches the build too.
- **A failed download and a failed build are told apart.** A download the server doesn't have (404) says "The download isn't on the server" and isn't offered for Retry (the same address fails the same way; Check Now may bring a new one); a failed build from source says "The build from source failed".
- **Restore Points keeps a point only for upgrades that changed something.** One was saved before every run, even one that failed or was stopped before it upgraded anything, so a morning of small runs left eight near-identical points.
- **"No bottle yet" for a formula from a third-party tap** promised a bottle that may never come; it now says "No bottle", and the details say its tap has none for this Mac.
- **Sizes are written one way, in your language's style.** The Clean Up sheet showed brew's "187.6MB", Tankard's "422,3 MB" and the list's "77.3 MB" side by side, with two different decimal marks in German. Every size now reads "77,3 MB" in German, "77.3 MB" in English.
- **The vulnerability scan's count matches the Vulnerable filter.** The status and menu bars said "Scanned 142 · found 13" beside a filter of "1 vulnerable": brew's findings include formulae upgraded since. The line now counts installed packages at the version brew checked, and says what it found: "Scanned 142 · 1 vulnerable".
- **The upgrade count agrees with the Upgrade button and the menu bar.** With pinned packages, the header said "5 upgrades ready" while the button said "Up to date". It now counts what Upgrade All takes, and adds "· 2 not included" for pinned packages, skipped versions and apps left to their own updater. Such a package's details say "Newer version: 3.54.0 → 3.54.1 (pinned: upgrades leave it)" instead of "Upgrade ready".
- **Translations:** the upgrade plan's "1 has no bottle…" put the English "has"/"have" into every language ("1 has keine Bottle … und werden"); it is now one whole sentence per count. Japanese and Korean "Installed as" read "install name"; now "インストール方法" / "설치 방식".
- **More whole sentences and local dates.** Discover's "Install … from source?" was four fragments glued together ("…brewがコンパイルします、および1個の依存関係"), the details' "Poured from … release" three; each is now one sentence per language. Japanese "Updated just now" read "updated 'just now'"; it now reads "更新: たった今". Automatic-update times use your language's date and clock style ("16. Nov., 06:04" in German, 12-hour where that's the norm), as History does. The "up to date" result of Check for Tankard Updates no longer repeats the version.
- **A failed run says "finished with problems" in its heading too**, as its window title and notification do (it said "finished with errors" there).
- **Changes made in Terminal show up when you come back.** Tankard re-read brew only when its last read was over an hour old, so a `brew install` in Terminal stayed invisible for up to an hour, and so did "The last upgrade didn't finish" after a crash. It now also reads again at launch and whenever the window comes to the front if brew's Cellar, Caskroom or opt folder changed since its last read (a few file-date checks; nothing is run), and at launch when an interrupted upgrade is waiting to be offered. That includes a cask upgraded in Terminal (its new version folder sits inside Caskroom/<cask>, so each cask's folder is checked too) and `brew pin`/`unpin`, which change only var/homebrew/pinned.
- **Tankard no longer takes credit for an upgrade done in Terminal.** When `brew upgrade` in Terminal held brew's lock, Tankard waited, ran again, got brew's "already installed", and said "Upgrade complete · 1 build from source", with "succeeded" in History. It now says **Already up to date (done elsewhere)**, counts such packages as "already up to date" rather than upgraded or built, and History says "no change (already up to date)".
- **"Include self-updating apps" off now leaves them out.** Homebrew 7 lists an app that updates itself (Chrome, VS Code, Cursor) as outdated whenever the app is older than the cask, so with the setting off, which says they are left out, Upgrade All still quit and replaced them. Off, they now show their newer version with ⟳ but stay out of Upgrade All, the counts, notifications and automatic updates; select one and click Upgrade to upgrade it anyway. "Homebrew updates it" for one app still wins. The setting's note says this.
- **"Allow Tankard to update apps" no longer starts the upgrade from "Not now".** The sheet that comes up before the first app change now has **Cancel** (runs nothing, and the sheet comes back next time), **Skip Apps, Upgrade N Others** (only the packages that don't change apps) and **Continue Without It** (everything, as "Not now" did), besides Open System Settings and I've done this.
- **Packages Homebrew can't read no longer vanish.** A formula from a tap you don't trust, or one its tap renamed (obsidian-cli, now notesmd-cli), is left out of what brew lists, so Tankard didn't show it, its tap read "0 installed" and Remove was offered (brew's own check misses it too). Tankard now finds it in the Cellar or Caskroom: it shows in Installed marked **can't be read**, with brew's reason in its details ("Refusing to load formula … from untrusted tap …") and in Health. The Taps sheet counts it, and Remove stays blocked with the reason.
- **Adopt Apps no longer matches a different app with the same name.** A "Copilot.app" that wasn't the one the copilot-money cask installs was offered for adopting as copilot-money. A cask that names app IDs (in what it quits, unloads or deletes, such as `~/Library/Containers/com.copilot.production`) now matches only an app with one of those IDs; any other app with the same name is listed under **No cask** as "possibly a different app, not offered", with both IDs. Each match says what matched: **Matched by app ID**, **Matched by name and website** or **Matched by name only — check before adopting** (never ticked for you).
- **Adopt Apps picks the right release line and ticks less.** From a check of every Homebrew cask: Firefox ESR, Thunderbird ESR, Parallels Desktop 18, Beyond Compare 4, Little Snitch 5, Godot 3, LibreOffice (still), Blender LTS and beta builds were matched to the main cask, ticked, and would have moved to another version line (sometimes a paid upgrade) on the next brew upgrade. Tankard now picks the cask whose version fits the app, and an app that several casks install is never ticked for you: the row says which one fits, and the confirmation names the others. The copyable `brew install --cask --force` shows only when one cask fits.
- **Apps that update themselves are adopted only on an app-ID match.** brew adopts them without comparing anything, so a name or developer match now shows under **Can't adopt** with the reason.
- **Shared ID prefixes no longer count as the same developer** (com.electron, com.todesktop, uk.co, jp.co and others), and a renamed app found by its ID is no longer matched through another cask's cleanup list (Microsoft Word to Bookends).
- **Hand-installed apps are no longer hidden as "already from Homebrew"** because another installed cask quits their ID (ChatGPT's cask quits Codex; Wondershare UniConverter's quits Chrome). A quit ID now counts only for an app with that cask's name.
- "Needs update first" on a name-only match says it may be a different app, not an older version.

## [0.8.5]

### Highlights
- Upgrade All from the menu bar runs in a small window of its own
- Builds from source show how long they have taken so far
- Apps that need your password show a lock and upgrade last
- Tankard warns before an upgrade closes apps you have open
- Clean Up keeps the old versions that Restore Points needs
- Calmer Health and History: no red alarms for harmless notes

### Added
- **Long builds show their time.** While a package builds from source, the upgrade sheet and the progress window say "Building from source… 4 min so far". After you have built the same formula from source on this Mac before, it adds an estimate: "(last time on this Mac: about 15 min)". brew doesn't estimate builds itself, so with no earlier build only the time so far shows.
- **Discover says when apps (casks) are turned off.** An Intelbrew Mac set up without casks can't install apps like Firefox or VLC. Discover now explains this in a banner, and **Turn On Apps…** runs `brew tap homebrew/cask` after asking, the same thing the Intelbrew installer does (a one-time download of about 620 MB). Close the banner to hide it.
- **A lock marks casks that need your password.** Casks whose installer asks for the administrator password show a small lock at the end of their row in Installed and Upgrades, in the upgrade plan and in the running upgrade (tooltip "Needs your password to upgrade").
- **Upgrade All runs password casks last**, so the password dialogs come at the end instead of in the middle of the run. A cask that depends on one of them moves with it; nothing else changes order.
- **Upgrade Now in the Auto-update log** for casks an automatic run skipped because they need your password: it starts a normal upgrade of those casks (the plan, then the password dialog).
- **Restore Points says when rollback can't work.** While "Keep the previous version after upgrades" is off, a banner at the top says rolling back needs the old version and Tankard isn't keeping them, with **Keep Old Versions** to turn the setting on. An upgrade whose old version is gone says "Old version removed by cleanup", and so does the confirmation's list of what it leaves out.
- **Electron apps on a Mac Pro (Late 2013).** On a Mac Pro 6,1 running macOS 13 or later (through OpenCore Legacy Patcher), installed apps built with Electron get an orange ⓘ in the list ("Electron app: may draw incorrectly on this Mac's graphics card"), and their details say why and show the app's Chromium version. Information only: Tankard doesn't change the app. Nothing is checked on any other Mac, and the Chromium version is read only when you open the app's details.
- **Upgrade warns before it closes open apps.** Upgrading an app that is open now (Google Chrome, VS Code) first shows the plan with "These apps will be closed during the upgrade and opened again afterwards: Google Chrome, Visual Studio Code. Save your work in them first." and **Upgrade** / **Cancel**, from the window and from the menu-bar panel. Formula-only upgrades, and upgrades with "Don't quit running apps during upgrades" on, don't ask.
- **Discover explains an empty search while apps are off.** With apps (casks) turned off, a search that finds nothing ("firefox") says the app may simply be in the app catalog that isn't turned on, with **Turn On Apps…**, even after the banner was closed. Nothing is looked up online.
- **Help ▸ Homebrew Words Explained** opens a new glossary in the guide: formula, cask, bottle, tap, keg, pinned, poured, build from source, dependency, Restore Point, Intelbrew and more, in plain words.

### Changed
- **Upgrade All in the menu-bar panel no longer opens the whole Tankard window.** The menu closes and the upgrade shows in a small window of its own, in the middle of the screen: the same list, progress, log, compile plan and Stop buttons as the sheet, plus **Show in Tankard** to move the run (the same one, nothing restarts) into the main window. A run that finishes cleanly closes it after a moment, with a "Tankard upgraded N packages" notification when notifications are on; a failure or a stop keeps it open with **Close**. The same goes for a row's Upgrade. With the Tankard window already in front, the sheet opens on it as before. Closing the small window while brew runs only hides it; **Show Upgrade Progress** in the menu-bar panel brings it back.
- **Scheduled checks wait for the Mac to be awake and online.** The background `brew update`, the new-upgrades check and automatic updates no longer start while the Mac sleeps or has no network; after a wake they wait for the network and check once. A scheduled `brew update` is stopped after 15 minutes, or when the Mac goes to sleep, and an automatic upgrade step after an hour (time the Mac spends asleep doesn't count).
- **Every row in Installed and Discover is one line, 30 points high.** What used to be a second line (a compile warning, a bottle on offer, a note such as "Tap has 1.5.7", Discover's description) now follows the name, cut short in a narrow column, with all of it in the tooltip.
- **Remove Unused Dependencies is safer.** Return no longer removes anything (no default button). Each package shows its description and a checkbox: untick one to keep it, and Tankard marks it as installed by you (`brew tab --installed-on-request`, Homebrew's own way), so later clean-ups leave it too. Tools people often use directly in Terminal (python, node, ruby…) carry a note.
- **Restore Points' confirmation is in words** ("Put wget back", "Return xz to 5.8.2 and pin it there"); the brew commands are under **Details**. The Terminal route for a removed old version is folded under **Advanced**, and the reasons a rollback can't run are plain sentences.
- **Health doesn't sound alarms for harmless notes.** Known harmless `brew doctor` notes (files Homebrew didn't install, an older Command Line Tools, broken links, deprecated packages…) show as neutral information; the rest, and unknown ones, in yellow, never red. Broken links get a **Clean Up…** button and an outdated Command Line Tools **Open Software Update**, with the command under Details.
- **Plainer words throughout.** Tooltips and setting notes say what happens instead of naming brew commands or `HOMEBREW_*` variables (the technical detail moved to the guide's Settings reference). The uninstall sheet's command is under **Details**; uninstalling an app says "Deletes Google Chrome from Applications. Your settings and data for it stay on this Mac.", with a red Uninstall button. The copy-command buttons have a VoiceOver label. The status bar says "Intelbrew is up to date" instead of "Fork: current".

### Fixed
- **Clean Up no longer removes the old versions Restore Points needs.** While "Keep the previous version after upgrades" is on, Clean Up leaves those formulae's old versions alone (it runs with `HOMEBREW_NO_CLEANUP_FORMULAE`, shown in the command) and says so. Old versions it would still remove are listed under "Removes old versions you could roll back to", and Return no longer runs it then. The sheet no longer says "Nothing you use is removed". When your brew.env sets its own `HOMEBREW_NO_CLEANUP_FORMULAE`, that list decides (Homebrew reads it last) and the sheet says so instead of promising to keep anything.
- **One History entry Tankard can't read no longer empties History.** Entries are read one by one: an unknown result shows as "result unknown", and a broken entry is skipped. A file with entries Tankard couldn't read is kept beside it (`history.json.unreadable-<date>`) before anything is written; the next command used to overwrite it (5,000 entries became 2). The Auto-update log works the same way.
- **Restoring a Brewfile keeps a tap's own URL.** For `tap "user/repo", "https://…"`, Add Tap… used to clone GitHub's default remote. The plan now shows the URL and Add Tap… uses it. **Install with Tankard** waits until the Brewfile's taps are added.
- **Discover says what went wrong when the catalog can't load**, in a sentence ("couldn't reach the network…"), with **Try Again** and the system's error under **Details**, instead of a page of error text.
- **Open Tankard in the menu bar brings back a minimized window** instead of opening a second one.
- **The Upgrades filter's skip button shows the plan first.** "Upgrade N with bottles" started at once, so it skipped the warning about open apps that will be closed and the password plan, and it counted apps (casks) as "with bottles". It is now **Upgrade N without building from source** and opens the upgrade plan with the packages that would build from source already skipped.
- **Smaller fixes:** a restore with nothing to run says why instead of "Run 0 brew commands?"; Remove Tap also stops trusting the tap (`brew untrust --tap`, then `brew untap`), so adding it again asks again; uninstalling a formula with two versions shows "bh-a 1.2" and "bh-a 1.0", not the name twice; a Discover search stops when you type the next letter, and only the first 256 characters are searched; the Services command box shows `brew services stop php`, without `--`.
- **No more stack of red failures in History after a night with the lid closed.** A scheduled check that couldn't finish (offline, another Homebrew command running, sleep, too slow) is one gray line, such as "Scheduled check didn't run: offline. Will retry. (3 times)", not a failure each time. A failed background update is no longer followed straight away by a second `brew update`, which then failed with "Another Homebrew command is running". Refresh and anything you start still report failures in full.
- **Adopt Apps no longer lists apps Homebrew already installed with an installer package** (Microsoft Word, Excel, Outlook, PowerPoint, Teams, Windows App). These casks name no app, so Tankard didn't see that the app was theirs and listed it under "Can't adopt". Now an app counts as Homebrew's when an installed cask's installer receipt put it there, its uninstall removes it, or its uninstall/zap names the app's bundle id and the app has the cask's name.
- **No more AppKit warning when the list changes a lot** ("Application performed a reentrant operation in its NSTableView delegate."), logged on every switch from a filter back to All (Upgrades → All), on clearing a search in a long list, and on some Discover searches. Rows of different heights made AppKit resize the table while it was still measuring rows; with one row height it measures none.
- **The Tankard window can't take over the small upgrade window's run.** While that window shows a run, its results or a compile plan, the Tankard window's Upgrade, Uninstall, Install and Replace buttons wait (their help says why), as they did behind the sheet. Before, an Uninstall started there replaced a failed run's results and ran out of sight, and a plan left open there did nothing when confirmed. The button at the bottom right of the Tankard window moves the run into it instead. A hidden run that failed and hasn't been looked at is kept the same way: the Homebrew and File menus wait, and Clean Up, Remove Unused, Restore, Taps, Brewfile, Adopt and Turn On Apps start nothing and say why, so its notification still opens its results.
- **Show Upgrade Progress always brings the upgrade window to the front**, also when other apps' windows cover it.
- **Post-install notes from a menu-bar upgrade show in the upgrade window**, which then stays open until you click Done. Before, they went to a Tankard window that might be closed, and the Homebrew and File menus stayed greyed out with nothing on screen.
- **"The Tankard window is in front" no longer counts a window covered by another app or on another Space**, nor one that is open only because the menu-bar click activated Tankard: Upgrade All then uses the small window.
- **Closing the upgrade window mid-run says that brew keeps going** (once per session), and a hidden run posts a notification when it finishes, done or with problems. The menu-bar line reads Show Upgrade Progress, Show Upgrade Results or Show Upgrade Plan, and goes back to Upgrade All once the results are closed.
- **The upgrade window remembers where you put it** until Tankard quits, opens on the screen you're using and on the current Space (also over a full-screen app).
- **The "Tankard upgraded N packages" notification follows macOS's notification setting for Tankard**, not the "new upgrades" setting.
- **The upgrade window fits each page.** It stayed 600×400 whatever it showed, so a run lost its title and its whole button row (Stop, Show in Tankard, Retry, Close): a failed menu-bar upgrade had no visible way out. It now takes each page's size (plan, run, results, notes), up to the screen's height, past which the page scrolls. `Scripts/panel-check.sh` renders every page and checks the title and buttons are inside the window.
- **The upgrade window is named for what it shows**: "Upgrading 3 packages", then "Upgrade finished" or "Upgrade finished with problems", not a second "Tankard".
- **A menu-bar Upgrade never starts a run behind a plan or another sheet**: it shows what is already up instead.
- **Uninstalling every version of a formula counts in plain words**: "2 uninstalled (4 versions)" beside "4 of 4 versions", and each step's chip names the version brew removed ("xz 5.8.3"; "xz (1 of 2)" until brew says).
- A lock-wait test that failed under a loaded test run now waits on the queue's events instead of a clock.
- **Remove Unused Dependencies removes nothing when keeping a package fails.** If marking an unticked package as installed by you (`brew tab`) fails, the removal no longer runs anyway (it would have removed that package): the sheet says "Nothing was removed because keeping python failed."
- **Check for Tankard Updates… shows the release notes as a short list**, not one long paragraph: the headings (Added, Changed, Fixed), one line per change, "…and N more", and **Full Release Notes** to open the release page.
- **Demo, snapshot and script runs no longer save the window frame into Tankard's real settings** (`NSWindow Frame main-AppWindow-1`, open since the 0.8.3 review).

## [0.8.4]

### Added
- **Automatic updates wait for brew and ask before quitting.** A step that finds a Terminal brew holding Homebrew's lock waits for it quietly (up to 15 minutes, logged) instead of failing, and is listed as skipped ("Homebrew was busy") if it is still busy. Quitting Tankard while an automatic run is upgrading asks first ("Tankard is upgrading xz automatically (3 of 7). Quit anyway?"); the steps not run are done by the next automatic run.
- **Your shell profile's proxy settings reach brew** (`http_proxy`, `https_proxy`, `all_proxy`, `no_proxy` and the forms brew keeps). Health ▸ Environment lists them with any password masked.
- **Health warns about brew.env settings that override Tankard**, one row each with the reason: the dependents check, the Intelbrew remotes, `HOMEBREW_NO_AUTOREMOVE`, `HOMEBREW_CASK_OPTS`, `SUDO_ASKPASS` and others.

### Changed
- **The password dialog is centered and shorter**, like a modern macOS alert: "Tankard needs your password", one line for what it's for ("To upgrade windows-app."), and the brew command under **Details**. A long list names two packages and the rest as a count ("To upgrade xz, wget and 7 more.").
- **A brew.env `SUDO_ASKPASS` that points to another program wins over Tankard's dialog**, so Tankard no longer offers its own: a step that needs your password says to run it in Terminal, with the command. Automatic updates skip cask steps that could ask for a password when brew.env sets another helper or clears `HOMEBREW_NO_SUDO`.
- **Tankard reads the brew.env brew reads**, including the one under `XDG_CONFIG_HOME` (or `HOMEBREW_XDG_CONFIG_HOME`), and passes those settings to brew.
- **Help ▸ Tankard Help opens the guide for your version** of Tankard, not the latest one.
- **The Discover header shows the search term**: '2 results for "wget"', not for the whole pasted `brew install wget`.

### Fixed
- **"Upgrade N with bottles" no longer cut off** in the Upgrades header at the default window width (German especially).
- **Proxy passwords are masked** in upgrade.log, History, the Auto-update Log and notifications.
- **Relaunch no longer carries debug settings over** to the new copy (demo, snapshot or script mode).
- **Uninstall removes every installed version.** With two versions of a formula (after an upgrade with "Keep the previous version", or a rollback), Uninstall and Unpin and Uninstall removed only the newest, said "Uninstall complete", and the older one came back unlinked as an upgrade. Now Tankard runs `brew uninstall` once per version (each with brew's usual checks), the confirmation says "Removes all installed versions of x (1.0, 1.1)", and after the run it checks what is still installed: anything left shows as "Uninstall incomplete" with the versions, never as complete.
- **The Homebrew and File menus wait while brew runs or a sheet is open.** Scan for Vulnerabilities, Health…, Taps…, Adopt Apps… and Restore Points… stayed enabled during an upgrade, and with a sheet such as History open every item was enabled, Clean Up… and Uninstall Homebrew… included. They are now greyed out until the run ends (shown or hidden) and the sheet closes; History… stays available during a hidden run.
- **No more AppKit warning at launch** ("Application performed a reentrant operation in its NSTableView delegate. This warning will become an assert in the future."), logged on every launch with a real package list; a future macOS may turn it into a crash. The Installed list now fills one screenful first and the rest a moment later.
- **A cask's detail says what it installs**: fonts, a command-line tool, an installer package or a plug-in, from the cask's artifacts. A font cask used to say "installs the vendor's app".
- **The menu-bar panel shows both versions** ("3.29.15 → 3.30.14"): a cask version's build or commit-hash suffix is left out (kept, shortened, when only it changes), a long package name gives way first, and a pair that still doesn't fit is cut in the middle, not from the front. The full versions are in the tooltip.
- **A sheet that finished with errors says what was done**, not the plan: a failed download no longer reads "1 build from source". When nothing finished it says why, if brew's output shows it.
- **No more orange "If brew needs sudo…" line on every cask upgrade.** The password note shows for casks that need it (the same rule as the plan and the dialog), or once brew's output says it runs sudo.
- **Wording**: About no longer splits "BSD-2-Clause" across two lines; context-menu items that open a confirmation end in "…" and name the package ("Install node-red (compiles)…"), and Skip Version reads the same in the detail pane and the context menu.
- **The menu-bar panel should no longer leave a gap** when rows disappear while it is open (an upgrade or install finished): it now shrinks to its content, staying under the menu bar. Not yet confirmed on a real Mac; tell us if you still see it.
- **A cask's "Installed on" date is no longer a day late in the evening** (west of Greenwich). brew reports a cask's install time as the UTC clock read as local time; Tankard now undoes that offset, only when the cask's install folder shows brew's value is shifted (so a fixed brew isn't corrected twice). Formula dates were already right.
- **Pinned rows say "pinned" once**: the badge next to the name stays; the grey "Pinned" line under it is gone, leaving that line for notes like "Bottle available".

### For contributors
- `Scripts/launch-check.sh` fails a run that logs the NSTableView reentrancy warning, and `--log DIR` keeps each run's output.
- The tests delete the UserDefaults suites they create; a run used to leave a few hundred plists in ~/Library/Preferences. The e2e and theme-geometry scripts no longer write the real settings domain, and `Scripts/e2e-selfupdate.sh` checks real evidence instead of passing on a pid count.
- Demo mode reads nothing from this Mac's brew: no Caskroom install-folder dates, no keg checks for Show in Finder, no Tankard cask check, no symlink resolution of profile paths. A test runs the demo against a stand-in prefix with decoys and checks it.
- Script runs (`TANKARD_E2E=1`) no longer save the window frame into the real `net.mindtricks.tankard` domain when they resize the window. `Scripts/e2e.sh` runs a re-signed copy with a bundle identifier of its own (`net.mindtricks.tankard.e2e.app.<pid>`), so the keys AppKit keeps there (window frame, menu-bar item) land in a throwaway domain, and the run fails if the real domain's plist changed (`--real-id` runs the app as given).

## [0.8.3]

### Added
- **Casks that need your administrator password install and upgrade from Tankard.** A cask whose `.pkg` installer brew runs with `sudo` (Windows App, for one) used to fail with "This step needs administrator rights, which Tankard can't ask for". Now Tankard shows a password dialog that names the cask and the command; the password goes straight to sudo and is never stored. **Cancel** (or three wrong passwords) leaves the step undone and the sheet shows the Terminal command, as before. The upgrade plan and the uninstall confirmation say "needs your administrator password" before anything starts. Tankard still never runs sudo itself: brew's sudo asks through `SUDO_ASKPASS`, set only for cask installs, upgrades, reinstalls, adopts and uninstalls.
- **Parallel downloads.** Upgrade All, an upgrade of a selection, a Brewfile's missing packages and automatic updates download their bottles and casks first, in parallel, with one `brew fetch`, then upgrade one at a time from the cache as before. The sheet shows "Downloading 4 of 9 · 120.0 of 410.0 MB". Your `HOMEBREW_DOWNLOAD_CONCURRENCY` is respected. A failed download fails no package by itself; each step downloads what's missing.
- **Stop Now on every running sheet**, not only multi-package runs. While brew may be changing a package it asks first; brew then undoes the unfinished step.
- **Waiting for another brew instead of failing.** When a brew in Terminal holds Homebrew's lock, the step waits ("Waiting for another Homebrew command to finish…") and runs once the lock is free, for up to 15 minutes. Stop Now ends the wait.
- **Quitting mid-run asks first** ("Homebrew is still upgrading xz (3 of 7). Quit anyway?") with Keep Running, Stop After Current and Quit, and Quit Now. Packages an upgrade run didn't reach because Tankard quit or crashed are offered at the next launch: **Upgrade the Remaining N Packages**, through the usual upgrade plan.
- **Retry in the sheet**: **Retry**, **Retry Failed (N)**, or Retry on a failed package, back through the usual plan. Under the log, one plain next step for a lock, the network, a full disk, folders brew can't write, or a checksum mismatch.
- **The menu-bar panel opens what you click**: a package row opens it in Tankard, selected and scrolled into view; "N upgrades ready" opens Upgrades, and the finished scan line opens Vulnerable.
- **Clicking an upgrades notification opens Installed ▸ Upgrades.** Its **Upgrade All…** action opens the upgrade plan (nothing runs until you confirm), and **Later** dismisses it.
- **Search**: a pasted brew command (`brew install foo`, also behind a `$` or a full path to brew) searches for the package. An Installed search with no match offers **Search Discover for "x"**.
- **Homebrew ▸ Health ▸ Environment** lists every `HOMEBREW_*` setting, where it comes from, and whether Tankard's brew gets it, with the reason when it doesn't. It warns when brew.env's `HOMEBREW_CASK_OPTS` has options Tankard would drop, since brew.env wins.
- **Automatic updates pause when a brew.env file turns off brew's dependents check** (`HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`), which their safe mode relies on. The menu bar, Settings and the Auto-update log say why; manual upgrades still run.

### Changed
- **Automatic updates never ask for a password.** Safe mode skips casks whose installer needs it ("needs your administrator password; upgrade it by hand"), and brew is told not to run sudo at all during an automatic run (`HOMEBREW_NO_SUDO=1`). If your Mac is set up for passwordless sudo, automatic updates used to upgrade those casks; now they are skipped and listed in the Auto-update Log, and you upgrade them by hand.
- **The password dialog answers only Tankard's own brew run.** It checks that it was started by the real `/usr/bin/sudo` under this copy of Tankard (and, in signed releases, Tankard's signature) and refuses anything else without showing a window.
- **`HOMEBREW_CASK_OPTS` passes only `--require-sha` and `--language=`.** `--appdir` and the other folder options would move apps out of where Adopt Apps and the App Management check look, so they are dropped; Health ▸ Environment lists each one.

### Fixed
- **Relaunch after Upgrade with Homebrew crashed the old Tankard** (EXC_BREAKPOINT): the completion handler of NSWorkspace's `openApplication` was isolated to the main actor, but LaunchServices called it on its own queue. Relaunch now closes any open sheet, quits, and then opens the new version, so two copies never run at once.
- **Upgrading from 0.8.1 or 0.8.2 with Check for Tankard Updates**: after the new version opens, the old one may show a "quit unexpectedly" report. It's harmless, and 0.8.3 fixes it. If two Tankards stay open, quit both and open Tankard again.
- **Only one Tankard runs.** An older copy still open after an update is asked to quit (never forced), and opening Tankard a second time brings the running one to the front.
- **Check for Tankard Updates offered Download instead of Upgrade with Homebrew** when Tankard's cached package list was still fresh but didn't include the Tankard cask yet.
- **Your `HOMEBREW_*` settings from a shell profile now reach brew.** Before, the brew Tankard runs saw none of them (only brew.env), so `HOMEBREW_NO_ANALYTICS=1` in `~/.zshrc` was dropped and installs from Tankard sent analytics you'd turned off. Privacy and behavior settings on an explicit list now pass; settings that change where brew installs or what it trusts, mirrors, tokens and unknown names don't.
- **Stop Now right after a step starts now stops it.** Pressed in the instant before brew had started, it sent no signal and the step ran to the end.
- **The Run Again offer after relaunching for App Management could be lost** when a status read was still running in the old window as it quit.
- **Stop Now gives brew time to undo the step.** Tankard interrupts brew as Ctrl-C does and waits 15 seconds before forcing it; before, brew was killed 2 seconds after being told to stop, which could cut its own rollback short.

### For contributors
- CI runs the tests (`.github/workflows/tests.yml`) on pushes to main and release branches and on pull requests that change code.
- `Scripts/e2e.sh prefetch`: two throwaway casks upgraded through one `brew fetch`, from a throttled local server. New e2e steps for the self-update (check-updates, upgrade-self, expect-quiet, open-sheet, relaunch), and `Scripts/e2e-selfupdate.sh` covers the Relaunch with a sheet open, a double launch and a stale copy on a throwaway local tap.
- Opt-in real-brew checks: `TANKARD_REAL_CANCEL_CASK` (Stop Now mid-download), `TANKARD_REAL_LOCK_FORMULA` (the lock wait) and `TANKARD_REAL_ENV=1` (the environment policy).

## [0.8.2]

### Changed
- **The filter bar shows what has something in it.** All and Upgrades are always there; **Bottle available**, **From source** and **Newer** appear only when a package matches (the one you're on stays until you leave it), and Bottle available sits next to Upgrades.
- **The More menu** lists **Vulnerable** first, shows a count on every item, and greys out the empty ones.
- **Requested only is now Installed by you**, and it means what it says: every package you installed yourself (brew's installed-on-request), including ones another package also needs. Before, those were left out.
- **Refresh and Check Now say what they found.** The status bar shows "N new upgrades" or "No new upgrades" for a few seconds. With **Notify me about new upgrades** on and the Tankard window not in front, they post a notification too; before, only the background check did. Upgrades seen this way aren't announced again.
- With notifications off, the first Refresh that finds new upgrades adds a one-time hint to turn them on in Settings ▸ General.
- Settings ▸ General warns when notifications are off for Tankard in System Settings, with **Open Notification Settings**.
- **Clearer wording** across the app: plainer explanations of bottles, keg-only, taps, pins and deprecation; title case on buttons (Check Again, Copy Command, Replace with Bottle…); **Upgrade All** named the same everywhere; **Untrust** is now **Stop Trusting**; US spelling.
- **The user guide** (Help ▸ Tankard Help) is rewritten as a task-based guide with a settings and menu reference; contributor detail moved to docs/architecture.md. The install help covers macOS 15's **Open Anyway** step.

### Fixed
- Notifications now show as banners while Tankard is the active app.
- German showed English inside a sentence ("A newer version ist verfügbar"), and used two words for "pinned".

## [0.8.1]

### Added
- **The Vulnerable filter offers the scan where the list is.** A header above the list shows the last scan ("Scanned 42 · found 2 · 5 min ago", or "Not scanned yet") with **Scan Now**; while a scan runs, its progress and **Stop**. An empty list says why ("No scan yet", "No known vulnerabilities", "Scan failed") with Scan Now. Before, the only ways to scan were the Homebrew menu and Settings. **Upgrade N** moved into that header too, so the summary strip keeps its text in narrow windows.
- **Tankard ▸ Check for Tankard Updates…**: asks GitHub once for the latest release, only when you choose it. A newer version shows its release notes and **Upgrade with Homebrew** (when the d4rkwyng/tap cask installed this copy; Tankard keeps running while brew replaces it, then offers to relaunch) or **Download**.
- **Download progress** in the install and upgrade sheet: "Downloading font-inter… 25.4 of 33.7 MB (75%)" with a bar, instead of sitting on "Fetching downloads" until the download is done (brew prints no progress when it isn't in a terminal). Tankard watches brew's downloads folder. A bottle's size comes from the manifest brew already fetched; for a cask, Tankard asks the cask's download server for the file size, with one HEAD request to the same URL brew downloads from. Without a size, the bytes so far and an indeterminate bar. Install, upgrade, reinstall, restore and adopt show it.
- **Welcome sheet** on first launch with a working Homebrew: an App Management card (Open System Settings, **Check**, Relaunch Tankard), an Adopt Apps card with the number of apps you installed yourself that Homebrew can manage (hidden when there are none), and a line about the background `brew update` and where to turn it off. Shown once, including once for people updating from 0.8.0; **Done** closes it for good.
- **Hide Dock icon when the window is closed** (Settings ▸ General). With every Tankard window closed, the Dock icon and the app menu go away and Tankard leaves ⌘-Tab; the menu-bar icon stays, and Open Tankard brings them back with the window. It is **on by default** when the menu-bar icon is on, so from 0.8.1 the Dock icon disappears when you close the window. To keep it, untick the option in Settings ▸ General (turning the menu-bar icon off also brings the Dock icon back).

### Changed
- **App Management covers every app change.** The macOS App Management explainer and the block detection now cover cask install (Discover, Brewfile, Health), adopt, reinstall, a restore's cask reinstall and auto-update, not just upgrade and uninstall. A block now reads **"macOS blocked changing an app"**, in the log and History, instead of the misleading "Homebrew couldn't write to its folders".
- After you grant the permission, **Relaunch Tankard** (macOS may apply the grant only to a newly started app) quits and reopens Tankard, which then offers **Run Again** for the blocked operation, with Cancel. It never runs by itself; Run Again goes through the usual confirmations. "Continue without relaunching" still retries in place.
- Auto-update notifies when macOS blocks a cask, saying to allow Tankard and relaunch.
- Font casks and other casks that install no app no longer get the App Management explainer when installed from Discover.
- **Settings ▸ Upgrades** is laid out in three sections, **When upgrading**, **Automatic updates** and **Vulnerability scan**, in one aligned column with notes that wrap instead of being cut off (German labels no longer run off the edge). **Keep the previous version** has an ⓘ button. The settings themselves are unchanged.
- Self-updating casks in the Installed list show a ⟳ symbol next to the name, with a tooltip, instead of an "Updates itself" line under it.
- **The per-app Updates menu says what Default does.** "Follow the setting" is now **Default (app updates itself)** or **Default (Homebrew updates it)**, depending on Settings ▸ Upgrades ▸ Include self-updating apps; the same in Adopt Apps and in the Installed list's symbol tooltip. The choice saved for each app is unchanged.
- **Menus reorganized** along Apple's menu bar guidelines. The View menu now holds only the tabs (Installed ⌘1, Discover ⌘2, Services ⌘3). **Refresh** (⌘R, unchanged) and **Clean Up…** moved from View to the **Homebrew** menu, which is grouped from the most used to the least: Refresh and Scan for Vulnerabilities; Health… and History…; Clean Up… and Remove Unused Dependencies…; Taps…, Adopt Apps… and Restore Points…; then Revert to Standard Homebrew… and Uninstall Homebrew… last (they were first).
- **Check Brewfile…** (was "Check a Brewfile…") and **Export Brewfile…** moved from the Homebrew menu to the **File** menu. With them the File menu is back, and with it **Close** (⌘W) and **Close All**; in 0.8.0 there was no File menu at all.
- The Help menu has **Tankard Help**, which opens the user guide on GitHub.
- The menu-bar icon's menu says **Upgrade All** and **Check Now** (title case, like other menu items).
- Refresh in the menu greys out while an upgrade runs, as the toolbar button already did; Clean Up… greys out whenever brew is busy, like Remove Unused Dependencies….

### For contributors
- `TANKARD_DEMO_SCAN=off` (demo only): no vulnerability scan at all, to show the Vulnerable filter before any scan.
- `TANKARD_MENU_DUMP=<file>` writes the main menu as a text outline (shortcuts, disabled items, separators) after `TANKARD_SNAPSHOT_DELAY`, for reviewing menus.

## [0.8.0]

### Added
- **Homebrew ▸ Adopt Apps…**: finds apps you installed by hand (in /Applications, one folder below it, and ~/Applications) that a Homebrew cask also installs, and hands the ones you tick to Homebrew with `brew install --cask --adopt <tap>/<name>`, through the queue with a live log, after a confirmation. brew downloads the cask and records it as installed; the app stays where it is. From then on Homebrew owns the app: `brew upgrade` replaces it with the cask's version, and uninstalling the cask, in Tankard or with `brew uninstall`, deletes the app. The confirmation says so.
- Adopt Apps groups the apps as Ready to adopt, Needs update first (brew adopts only the exact version the cask installs; update the app with its own updater and Scan Again), Can't adopt, and No cask. App Store apps, Apple's apps and apps Homebrew already manages aren't listed. Each match says how sure it is: the app's bundle id is one the cask names (sure), the vendor matches (likely), or only the name matches. Name-only matches are never ticked for you, and ticking one by hand brings a warning first; for a cask whose app updates itself, only a sure match is ticked.
- brew doesn't compare the download with the installed app for casks whose apps update themselves (`auto_updates`), so the confirmation lists those under "Adopted without a version check". The others are checked, and brew stops for an app whose download doesn't match.
- Adopt Apps doesn't offer casks that run an installer package (brew ignores `--adopt` for those and runs the installer again), apps in a suite folder, apps outside the cask's install location, disabled casks, apps with no version brew can compare, or symbolic links. A cask with two apps is adopted once. For Needs update first, the `brew install --cask --force` command that replaces the app is shown to copy, only for a sure match, and Tankard never runs it.
- **Who updates a self-updating app**, per cask: **Follow the setting** (as before), **App updates itself** (Tankard leaves its upgrades out of Upgrade all, the counts, notifications and auto-update; `brew upgrade` in Terminal can still upgrade it) or **Homebrew updates it** (every newer version is listed and upgraded, whatever "Include self-updating apps" says). In the detail pane of a cask that updates itself, and chosen at adoption (saved only for apps whose adopt succeeded). Uninstalling the cask through Tankard forgets the choice.
- **Install counts** in Discover's details: installs in the last 30, 90 and 365 days, from Homebrew's public analytics on formulae.brew.sh. Tankard downloads the bulk files for every package (about 13 MB together) once Discover's catalogue is ready, keeps them for a day and revalidates them with their ETag, so it never asks about a single package and the site doesn't learn which packages you look at. Nothing is downloaded in Intelbrew mode (the counts describe upstream Homebrew). The Installed details show the counts once Discover has loaded them, and Discover's search puts more-installed packages first among equally good matches.
- **Background `brew update`, on by default.** After the list is on screen, and from then on while Tankard runs, Tankard runs `brew update` at most once per check interval (Settings ▸ General ▸ Check every, 6 hours by default; any `brew update`, including one you run in Terminal, counts, and a longer `HOMEBREW_AUTO_UPDATE_SECS` wins), then re-reads the list so the upgrade counts are current. `brew update` updates Homebrew itself and its package lists (the taps and Homebrew's formula and cask data); it installs and upgrades none of your packages. It goes through the same queue as everything else, so it never runs beside another brew command, and the status bar shows "Checking for updates…" while it runs. A failure (offline) is logged to `~/Library/Logs/Tankard/upgrade.log`, not shown, and tried again at most once an hour. To turn it off, untick **Settings ▸ General ▸ Check for new versions in the background**, or set `HOMEBREW_NO_AUTO_UPDATE` (in the environment, your shell profile or brew.env): then Tankard doesn't run it, and Settings says where the variable is set.
- An upgrade, install or uninstall started while the background update runs waits for it, and its sheet says "Waiting for brew update to finish…".
- **Uninstall lists the dependencies nothing else would need** afterwards ("No longer needed by anything") with **Also remove these**, on by default. Only that package's own dependencies are listed (formulae installed as dependencies, not on request and not pinned); dependencies that were already unused before stay. Each listed one is checked again right before it is removed and kept if it has since been installed on request, pinned, or needed by something else; the log says why.
- Pinned packages can't be uninstalled silently: brew refuses a pinned package but still reports success, so the uninstall sheet says it is pinned and offers **Unpin and Uninstall**. A run whose output has brew's refusal is shown as failed.
- The Welcome screen mentions Adopt Apps.

### Changed
- **Faster loading**: the list appears as soon as `brew info` answers; sizes (and, with "Include self-updating apps" on, `brew outdated --greedy`) are read at the same time and fill in when they arrive.
- The macOS App Management explainer appears only for casks that install an app (or run an installer package), not for fonts and other casks that put nothing in /Applications.
- The command box in sheets wraps the whole command (up to 5 lines) instead of cutting it mid-word.

### Fixed
- Uninstalling a package no longer removes other unused dependencies across the Mac: brew 7 runs `brew autoremove` after every uninstall, although the confirmation said dependencies stay. Uninstall now runs with `HOMEBREW_NO_AUTOREMOVE=1` (shown in the command), and Homebrew ▸ Remove Unused Dependencies… is where autoremove runs.
- Uninstalling a pinned package said "Uninstall complete" while brew had refused and nothing changed.
- Status reads ran slower than they should: a brew or git process started while another read's output was open held that output open too, so quick reads (the git checks in every status read) waited for slow ones (about 650 ms instead of 20 ms).

### For contributors
- `Scripts/e2e.sh` runs scripted scenarios against the real app and the real brew (`TANKARD_E2E=1` with a step file in `TANKARD_SCRIPT`): welcome, formula, pinned, orphans, cask, security, settings, restore, adopt and background. Each run uses its own settings suite and state folder, and one run holds a machine-wide lock. It installs only small throwaway packages and removes them.
- `TANKARD_LOG_TIMING=1` prints launch milestones in milliseconds since process start.
- `Scripts/l10n.py compile` also writes `Localizable.stringsdict` for strings with plural forms, and the localization tests check it.

## [0.7.0]

### Added
- **Homebrew ▸ Taps…**: every tap from `brew tap-info --installed --json` with its remote, official or third-party, formula and cask counts, how many installed packages came from it, when it was last updated, and brew 7's trust. Click a tap, then **Show Installed**, to filter the Installed list to it (`tap:user/repo` in the search field).
- **Add a tap** (`user/repo`, optionally with a git URL), checked before anything runs. Third-party taps get a warning that they run their authors' code; `brew tap` then runs through the queue with a live log and lands in History.
- **Remove a tap** with `brew untap` (never `--force`), after a confirmation. Blocked, with the packages listed, while anything installed comes from it.
- **Trust / Untrust** a third-party tap (`brew trust --tap`, `brew untrust --tap`, Homebrew 7), after a confirmation.
- **Restore Points**: Tankard saves a restore point (your installed versions) before every upgrade and auto-update, and on **Save Now**. A restore point shows what changed since it was saved.
- **Roll back an upgrade** where Homebrew can: with **Keep the previous version after upgrades** on (Settings ▸ Upgrades, off by default), Restore removes the new version of a formula, links the old one and, with **Pin rolled-back formulae** (on by default), pins it so it isn't upgraded again straight away. Casks, versions brew has already cleaned up, keg-only and pinned formulae, HEAD builds and formulae other packages depend on can't be rolled back; Tankard marks them and shows the commands to do it by hand. Every restore is confirmed first and runs through the queue with a live log.
- Restore Points never uninstall a package down to nothing: Restore checks the Cellar again when you confirm, and once more right before each rollback's `brew uninstall`. If `brew cleanup` (run from Terminal, or brew's own periodic cleanup) removed the old version in the meantime, that package is left as it is, the other packages are still restored, and Tankard says which one was skipped and why.
- **Keep the previous version after upgrades** (Settings ▸ Upgrades) now covers every upgrade, install and reinstall Tankard runs, formulae and casks, by hand and by auto-update (`HOMEBREW_NO_INSTALL_CLEANUP=1`, shown in the command). Any of them can start brew's periodic cleanup, which removes the old versions of every formula, not only its own.
- The Brewfile restore plan's missing taps get an **Add Tap…** button (same confirmation) instead of a `brew tap` command to copy.
- **Localization**: Tankard follows the macOS language (System Settings ▸ General ▸ Language & Region, or per app) in German, French, Spanish, Japanese, Simplified Chinese, Portuguese (Brazil), Italian and Korean, besides English. The translations are machine translations and will read that way in places; corrections are welcome. Brew commands, package and tap names, and brew's own output stay as brew writes them.

### For contributors
- Every user-facing string lives in `Resources/Localizable.xcstrings`. `Scripts/l10n.py extract` adds new strings from the source, `Scripts/l10n.py compile` writes the `.lproj` files the app loads (the Command Line Tools can't compile a string catalog themselves), and a test fails if any string lacks a shipped language. `APP_LANG=de Scripts/layout-check.sh` runs the layout check in another language.

## [0.6.2]

### Fixed
- Long versions no longer lose their important part at the default window size: the Installed and Available columns are wider (the Source column gives up the room it didn't use), long versions are shortened in the middle rather than at the end, and hovering shows the full version.
- The Pin row in the details now wraps instead of cutting off "Keeps <version>; upgrades skip it".
- Discover descriptions wrap to two lines, with the full text on hover.
- The summary above the Installed list no longer cuts off when the More menu shows "2 vulnerable" or a scan is running: it drops its least important parts first ("1 newer", then the Intelbrew/Homebrew bottle split, then the upgrade detail), and hovering shows the full text.

## [0.6.1]

### Changed
- **ⓘ buttons** next to each setting in Settings (General, Upgrades, Automatic updates) show its explanation on click; the hover tooltips stay.
- **Scan Now** beside the vulnerability scan setting (Settings → Upgrades), and **Homebrew ▸ Scan for Vulnerabilities**, replace "Scan for Vulnerabilities Now" in the More menu.
- A running scan shows a spinner, "Scanning N formulae…", the elapsed time and **Stop** in the status bar and the menu-bar panel; afterwards "Scanned N · found M" (or a partial, stopped or timed-out note). Stop ends brew vulns; the 60-second limit still applies.

### Fixed
- After choosing a filter from the **More** menu (such as Has notes), the window could no longer be dragged by its toolbar until you switched to Discover and back. The More filters are now a standard pop-up menu, and dragging works.
- The toolbar's logo now moves the window when dragged, like the rest of the toolbar.
- Leaving the Installed tab clears a **More** filter (Has notes, Pinned…), so Installed comes back showing All.
- The About examples in the docs no longer name an old version.

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
- **Automatic updates** (Settings → Upgrades, off by default): upgrade packages every day or every week at a chosen time, while Tankard is running, on AC power and after 10 minutes without input. A missed time runs once at the next chance. No helper or launch agent: the menu-bar icon keeps Tankard running.
- **Safe mode**, always on and spelled out in Settings: `brew update` first; bottles only (formulae whose upgrade or outdated dependencies would compile are skipped, and so are formulae whose upgrade would make brew upgrade or rebuild an installed dependent that has no bottle: those stay in Upgrades to do by hand, since turning brew's dependents check off could leave that dependent linked to a removed library); pinned packages skipped; casks whose app is running skipped unless "Don't quit running apps" is on, and an automatic run never quits an app; Tankard itself left to brew.
- **Auto-update log**: the last 20 runs with what was upgraded, skipped (and why) and what failed; a notification after each run that changed something; "Last auto-update: …" in the menu-bar menu.
- The menu-bar menu shows "Tankard 0.x available" when brew lists an upgrade for Tankard's cask.

### Changed
- **Settings are shorter.** The long explanations under each checkbox are now tooltips; only the OSV.dev privacy note and a one-line safe-mode summary stay visible.
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

[0.8.3]: https://github.com/d4rkwyng/tankard/releases/tag/v0.8.3
[0.8.2]: https://github.com/d4rkwyng/tankard/releases/tag/v0.8.2
[0.8.1]: https://github.com/d4rkwyng/tankard/releases/tag/v0.8.1
[0.8.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.8.0
[0.7.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.7.0
[0.6.2]: https://github.com/d4rkwyng/tankard/releases/tag/v0.6.2
[0.6.1]: https://github.com/d4rkwyng/tankard/releases/tag/v0.6.1
[0.6.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.6.0
[0.5.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.5.0
[0.4.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.4.0
[0.3.1]: https://github.com/d4rkwyng/tankard/releases/tag/v0.3.1
[0.3.0]: https://github.com/d4rkwyng/tankard/tree/v0.3.0
[0.2.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.2.0
[0.1.1]: https://github.com/d4rkwyng/tankard/releases/tag/v0.1.1
[0.1.0]: https://github.com/d4rkwyng/tankard/releases/tag/v0.1.0
