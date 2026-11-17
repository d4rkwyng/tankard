#!/bin/bash
# Scripted real-run tests: drives the REAL app (no demo) through user flows
# against the REAL brew, with a step script per phase (TANKARD_E2E=1 +
# TANKARD_SCRIPT; see Sources/TankardApp/ScriptLaunch.swift and
# Sources/TankardAppModel/ScriptRunner.swift for the step vocabulary).
#
#   Scripts/e2e.sh [--no-build] [--app PATH] [--out DIR] [--wait] SCENARIO...
#   Scripts/e2e.sh all                 every scenario below
#   Scripts/e2e.sh --list              the scenarios
#   Scripts/e2e.sh --steps             the step vocabulary
#
# Scenarios:
#   welcome    no brew → the welcome screen; then a first launch with fresh
#              settings and no cache reads brew live, Refresh (runs brew
#              update), Discover search
#   formula    install `hello` from Discover, pin, unpin, uninstall
#   pinned     install `hello`, pin it; Uninstall is blocked (brew would
#              refuse a pinned formula and still exit 0); Unpin and Uninstall
#   orphans    install `luarocks` (needs `lua`, not installed beforehand),
#              uninstall with "Also remove these" on: both gone; again
#              with it off: lua stays, and `brew autoremove --dry-run` lists
#              exactly what the sheet listed; then uninstall lua
#   cask       install the font cask `font-press-start-2p` from Discover
#              (no app in /Applications), uninstall (App Management explainer)
#   security   Scan for Vulnerabilities (real brew vulns), then no leftover
#              `brew vulns` process, in the app or after it quit
#   settings   every Settings toggle on, relaunch: still on; off again
#   restore    a throwaway local tap (file:// git repo, made here): Add Tap,
#              Trust, Untrust, Trust, a probe formula 1.0 → 1.1 upgrade through the app,
#              post-install notes, a manual restore point, a real rollback to
#              1.0, pin/unpin, uninstall, Remove Tap
#   adopt      Adopt Apps: AnyBar 0.2.3 (cask anybar), downloaded from the
#              cask's own URL and sha256-checked, copied to /Applications by
#              hand; the scan, adopt it (brew install --cask --adopt), the
#              self-update choice, then uninstall the cask: the app is gone
#   progress   download progress in the sheet: install the font cask
#              `font-inter` (~34 MB zip, no app) with its cached download
#              removed first, so brew really downloads it; the sheet must
#              show "Downloading font-inter… x of y MB (n%)" (captured as
#              NN-install-mid-download.png); then uninstall
#   prefetch   0.8.3 parallel downloads: a throwaway local tap (file:// git)
#              with two casks whose zips come from a local, throttled HTTP
#              server on 127.0.0.1 (6 MB at ~3 MB/s each); 1.0 installed from
#              the shell, both upgraded to 1.1 in one session: one
#              `brew fetch --cask` downloads both at once (combined progress
#              captured as NN-...-prefetch.png), then the two upgrades pour
#              from the cache; then uninstall, untrust, untap
#   background the throttled background `brew update` on the real brew (a
#              seconds interval in the run's suite; FETCH_HEAD only read):
#              due -> exactly one update; a relaunch inside the interval
#              runs none; HOMEBREW_NO_AUTO_UPDATE=1 runs none; Upgrade on a
#              throwaway tap's probe (1.0 -> 1.1) clicked during an update:
#              the sheet says it waits for brew update, then upgrades
#
# Each phase writes OUT/<scenario>/<phase>/: NN-step.png per step,
# results.jsonl (one JSON line per step: pass/fail, checks, model state),
# summary.json and app.log. The summary at the end says PASS/FAIL per phase.
#
# Isolation: settings go to a defaults suite of this run's own,
# `net.mindtricks.tankard.e2e.<pid>` (emptied at the start of each scenario:
# a first launch; deleted at the end), Tankard's files to
# OUT/<scenario>/state: the status and insights caches, Discover's
# formulae.brew.sh cache (state/api), History, restore points, logs. Your
# own settings, caches, History and restore points are not read or written.
#
# One run at a time on this Mac: the scenarios share the real brew (and its
# packages), so a run holds the lock /tmp/net.mindtricks.tankard.e2e.lock
# (a directory with the holder's pid; a dead holder's lock is taken over).
# A second run refuses with the holder's pid, or with --wait waits for it.
#
# What it changes on this Mac: it installs and removes the scenario's own
# throwaway packages (hello, luarocks + lua, font-press-start-2p, font-inter, tankard-e2e-probe,
# tankard-e2e-pfetch-a/-b) and adds/removes its own taps (tankard-e2e/probe,
# tankard-e2e-pfetch/probe). Safety checks first:
#   - a scenario is skipped if its package is already installed (it would
#     uninstall yours) or its tap already exists;
#   - Tankard's uninstall sets HOMEBREW_NO_AUTOREMOVE=1 (only what the
#     sheet lists goes), but a scenario still refuses to start when
#     `brew autoremove --dry-run` already lists something: the orphans
#     cross-check needs a clean baseline, and a stray autoremove (an older
#     build, a manual brew uninstall meanwhile) would take your packages;
#   - installs run with "Keep the previous version" on, so brew's periodic
#     `brew cleanup` (which an install can trigger) doesn't run.
# Never runs brew upgrade/cleanup/autoremove on anything else. The welcome
# scenario's Refresh runs `brew update` (as the button does).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

APP=dist/Tankard.app
OUT=dist/e2e
BUILD=1
PHASE_TIMEOUT=${E2E_PHASE_TIMEOUT:-1200}
SCENARIOS=()
ALL=(welcome formula pinned orphans cask progress security settings restore adopt prefetch background)
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --app) APP=${2%/}; BUILD=0; shift ;;
        --out) OUT=$2; shift ;;
        --wait) WAIT_LOCK=1 ;;
        --list) printf '%s\n' "${ALL[@]}"; exit 0 ;;
        --steps) STEPS_HELP=1 ;;
        -h|--help) sed -n '2,77p' "$0"; exit 0 ;;
        all) SCENARIOS+=("${ALL[@]}") ;;
        -*) echo "e2e.sh: unknown option $1" >&2; exit 2 ;;
        *) SCENARIOS+=("$1") ;;
    esac
    shift
done

[ $BUILD = 1 ] && { Scripts/bundle-app.sh --out "$(dirname "$APP")" || exit 1; }
BIN="$APP/Contents/MacOS/Tankard"
[ -x "$BIN" ] || { echo "e2e.sh: no app at $APP" >&2; exit 1; }
BIN=$(cd "$(dirname "$BIN")" && pwd)/Tankard
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

if [ "${STEPS_HELP:-0}" = 1 ]; then
    # The vocabulary, from the app itself (an unknown verb lists it).
    tmp=$(mktemp -d)
    echo "help" > "$tmp/s"
    TANKARD_E2E=1 TANKARD_SCRIPT="$tmp/s" TANKARD_SCRIPT_OUT="$tmp/o" TANKARD_DEMO=intelbrew "$BIN" -ApplePersistenceIgnoreState YES 2>&1 >/dev/null | sed 's/^e2e: //'
    rm -rf "$tmp"
    exit 0
fi
[ ${#SCENARIOS[@]} -gt 0 ] || { echo "e2e.sh: name a scenario (--list), or all" >&2; exit 2; }

# MARK: one run at a time (machine-wide)

LOCK=/tmp/net.mindtricks.tankard.e2e.lock
lock_holder() { cat "$LOCK/pid" 2>/dev/null; }
release_lock() { [ "$(lock_holder)" = "$$" ] && rm -rf "$LOCK"; }
take_lock() {
    local waited=0 holder empty=0
    while ! mkdir "$LOCK" 2>/dev/null; do
        holder=$(lock_holder)
        if [ -z "$holder" ]; then
            # Another run made it a moment ago and is writing its pid; or a
            # crash left it empty. Take it over after a few seconds.
            empty=$((empty + 1))
            [ $empty -ge 5 ] && rm -rf "$LOCK"
            sleep 1
            continue
        fi
        empty=0
        if ! kill -0 "$holder" 2>/dev/null; then
            echo "e2e.sh: taking over a stale lock (pid $holder is gone)" >&2
            rm -rf "$LOCK"
        elif [ "${WAIT_LOCK:-0}" != 1 ]; then
            echo "e2e.sh: another e2e run (pid $holder, in $(cat "$LOCK/where" 2>/dev/null || echo '?')) is using brew and the app." >&2
            echo "        Wait for it to finish, or pass --wait to queue behind it. (Lock: $LOCK)" >&2
            exit 3
        else
            [ $((waited % 60)) = 0 ] && echo "e2e.sh: waiting for the e2e run pid $holder to finish ($LOCK)" >&2
            sleep 5
            waited=$((waited + 5))
        fi
    done
    echo $$ > "$LOCK/pid"
    echo "$ROOT" > "$LOCK/where"
    trap 'release_lock' EXIT
    trap 'release_lock; exit 130' INT TERM
}
take_lock

# This run's own settings suite (ScriptLaunch.swift accepts only names under
# net.mindtricks.tankard.e2e.), so even a stray parallel launch can't empty it.
SUITE=net.mindtricks.tankard.e2e.$$
delete_suite() {
    defaults delete "$SUITE" >/dev/null 2>&1 || true
    rm -f ~/Library/Preferences/"$SUITE".plist
}

BREW=$(command -v brew || true)
[ -n "$BREW" ] || { echo "e2e.sh: no brew on PATH" >&2; exit 1; }
# The shell's own brew calls: never update, never clean up, never autoremove.
qbrew() { HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" "$@"; }

RESULTS=()
record() { RESULTS+=("$1"); echo "==> $1"; }

fresh_state() { # scenario
    delete_suite
    rm -rf "${OUT:?}/$1"
    mkdir -p "$OUT/$1/state"
}

# run_phase SCENARIO PHASE [VAR=value...] <<'STEPS'
run_phase() {
    local sc=$1 ph=$2
    shift 2
    local dir="$OUT/$sc/$ph"
    mkdir -p "$dir"
    cat > "$dir/steps.txt"
    if pgrep -f "^$BIN" >/dev/null; then
        record "$sc/$ph: FAIL (another $APP is running; quit it first)"
        return 1
    fi
    env "$@" TANKARD_E2E=1 TANKARD_E2E_SUITE="$SUITE" TANKARD_SCRIPT="$dir/steps.txt" TANKARD_SCRIPT_OUT="$dir" \
        TANKARD_E2E_STATE="$OUT/$sc/state" "$BIN" -ApplePersistenceIgnoreState YES >"$dir/app.log" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && [ $waited -lt "$PHASE_TIMEOUT" ]; do
        # WATCH_RE: note this app's own matching descendants (security's
        # leftover check after quit looks only at these pids).
        [ -n "${WATCH_RE:-}" ] && descendants_matching "$pid" "$WATCH_RE" >> "$dir/watched-procs.txt"
        sleep 1; waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        record "$sc/$ph: FAIL (timed out after ${PHASE_TIMEOUT}s; see $dir/app.log)"
        return 1
    fi
    wait "$pid"
    local code=$?
    local line
    line=$(grep -h "^e2e: script" "$dir/app.log" | tail -1 | sed 's/^e2e: script [^:]*: //')
    if [ $code = 0 ]; then
        record "$sc/$ph: PASS ($line)"
    else
        record "$sc/$ph: FAIL (exit $code; ${line:-no summary}; see $dir/app.log)"
        grep -h "FAIL" "$dir/app.log" | head -5 | sed 's/^/      /'
        return 1
    fi
}

need_absent() { # kind name
    if qbrew list "--$1" "$2" >/dev/null 2>&1; then
        echo "    $2 is already installed: skipping (the scenario would uninstall it)" >&2
        return 1
    fi
}

autoremove_clean() {
    local would
    would=$(qbrew autoremove --dry-run 2>&1 | grep -v '^$' || true)
    if [ -n "$would" ]; then
        echo "    brew autoremove --dry-run already lists something; an uninstall would remove it:" >&2
        echo "$would" | sed 's/^/      /' >&2
        return 1
    fi
}

VULNS_RE='brew(\.rb)?[^|]* vulns'
vulns_procs() { ps -axww -o pid=,command= | grep -E "$VULNS_RE" | grep -v grep || true; }

# "pid command" of ROOT's descendants whose command matches the ERE.
descendants_matching() { # root regex
    ps -axww -o pid=,ppid=,command= | awk -v root="$1" -v re="$2" '
        { pid = $1; par[pid] = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); cmd[pid] = $0 }
        END {
            for (p in par) {
                q = par[p]; n = 0
                while (q != root && (q in par) && q > 1 && n < 64) { q = par[q]; n++ }
                if (q == root && cmd[p] ~ re && cmd[p] !~ /awk -v root/) print p, cmd[p]
            }
        }'
}

# Of the pids noted in FILE, those still running a matching command.
still_running() { # file regex
    [ -f "$1" ] || return 0
    local p
    for p in $(cut -d' ' -f1 "$1" | sort -u); do
        ps -p "$p" -o pid=,command= 2>/dev/null | grep -E "$2" || true
    done
}

# MARK: scenarios

scenario_welcome() {
    fresh_state welcome
    run_phase welcome 1-no-brew TANKARD_BREW=/nonexistent/tankard-e2e/bin/brew <<'STEPS'
expect-welcome
check-again
expect-welcome
STEPS
    run_phase welcome 2-first-launch <<'STEPS'
expect-fresh
expect-ready
refresh manual
expect no-error
discover hello formulae
tab installed
STEPS
}

scenario_formula() {
    need_absent formula hello || { record "formula: SKIP (hello already installed)"; return; }
    autoremove_clean || { record "formula: SKIP (autoremove would remove something)"; return; }
    fresh_state formula
    run_phase formula 1-hello <<'STEPS'
expect-ready
set keepPreviousVersion on
install formula hello
expect installed hello
pin hello
expect pinned hello
unpin hello
expect not-pinned hello
always uninstall formula hello
expect not-installed hello
STEPS
    qbrew list --formula hello >/dev/null 2>&1 && { echo "    cleanup: hello still installed, removing" >&2; qbrew uninstall --formula hello; }
}

scenario_pinned() {
    need_absent formula hello || { record "pinned: SKIP (hello already installed)"; return; }
    autoremove_clean || { record "pinned: SKIP (autoremove would remove something)"; return; }
    fresh_state pinned
    run_phase pinned 1-hello <<'STEPS'
expect-ready
set keepPreviousVersion on
install formula hello
pin hello
expect pinned hello
uninstall-blocked formula hello pinned
expect installed hello
expect pinned hello
unpin-uninstall formula hello
expect not-installed hello
always expect no-error
STEPS
    if qbrew list --formula hello >/dev/null 2>&1; then
        echo "    cleanup: hello still installed, unpinning and removing" >&2
        qbrew unpin hello >/dev/null 2>&1; qbrew uninstall --formula hello
    fi
}

scenario_orphans() {
    local f=luarocks d=lua
    need_absent formula $f || { record "orphans: SKIP ($f already installed)"; return; }
    need_absent formula $d || { record "orphans: SKIP ($d already installed: it wouldn't be an unneeded dependency)"; return; }
    autoremove_clean || { record "orphans: SKIP (autoremove would remove something)"; return; }
    fresh_state orphans
    run_phase orphans 1-remove-deps <<STEPS
expect-ready
set keepPreviousVersion on
install formula $f
expect installed $d
uninstall formula $f deps on $d
expect not-installed $f
expect not-installed $d
STEPS
    run_phase orphans 2-keep-deps <<STEPS
expect-ready cached
refresh
install formula $f
uninstall formula $f deps off $d
expect not-installed $f
expect installed $d
STEPS
    # Cross-check: what brew itself would now autoremove is exactly what
    # the sheet listed.
    local would
    would=$(qbrew autoremove --dry-run 2>/dev/null | grep -v '^==>' | tr -s ' \n' '\n' | grep -v '^$' | sort | tr '\n' ' ')
    if [ "$would" = "$d " ]; then record "orphans/autoremove-dry-run: PASS (brew would remove: $would)"
    else record "orphans/autoremove-dry-run: FAIL (brew would remove: '${would}', the sheet listed: $d)"; fi
    run_phase orphans 3-cleanup <<STEPS
expect-ready cached
refresh
uninstall formula $d
expect not-installed $d
STEPS
    for x in $f $d; do
        qbrew list --formula $x >/dev/null 2>&1 && { echo "    cleanup: $x still installed, removing" >&2; qbrew uninstall --formula $x; }
    done
}

scenario_cask() {
    local c=font-press-start-2p
    need_absent cask $c || { record "cask: SKIP ($c already installed)"; return; }
    autoremove_clean || { record "cask: SKIP (autoremove would remove something)"; return; }
    fresh_state cask
    run_phase cask 1-font <<STEPS
expect-ready
set keepPreviousVersion on
install cask $c
expect installed $c
always uninstall cask $c
expect not-installed $c
STEPS
    qbrew list --cask $c >/dev/null 2>&1 && { echo "    cleanup: $c still installed, removing" >&2; qbrew uninstall --cask $c; }
}

scenario_progress() {
    local c=font-inter
    need_absent cask $c || { record "progress: SKIP ($c already installed)"; return; }
    autoremove_clean || { record "progress: SKIP (autoremove would remove something)"; return; }
    # Only this cask's own cached download (brew --cache names it), so the
    # install has something to download. Nothing else in the cache is touched.
    local cached
    cached=$(qbrew --cache --cask $c 2>/dev/null)
    case "$cached" in
        */downloads/*) rm -f "$cached" "$cached.incomplete" ;;
    esac
    fresh_state progress
    run_phase progress 1-download <<STEPS
expect-ready
set keepPreviousVersion on
watch-downloads on
install cask $c
expect installed $c
watch-downloads off
always uninstall cask $c
expect not-installed $c
STEPS
    qbrew list --cask $c >/dev/null 2>&1 && { echo "    cleanup: $c still installed, removing" >&2; qbrew uninstall --cask $c; }
}

scenario_security() {
    fresh_state security
    local before
    before=$(vulns_procs)
    [ -n "$before" ] && echo "    note: brew vulns already running before the test (not ours, not counted): $before" >&2
    WATCH_RE=$VULNS_RE run_phase security 1-scan <<'STEPS'
expect-ready
scan-vulns
expect no-process " vulns --json"
set scanVulnerabilitiesOnRefresh on
refresh
sleep 2
snapshot scan-on-refresh
scan-vulns
expect no-process " vulns --json"
STEPS
    sleep 3
    # Only the scans this run's app started (seen under its pid while it
    # ran): another run's or the user's own `brew vulns` isn't ours.
    local f="$OUT/security/1-scan/watched-procs.txt" after seen=0 others
    [ -f "$f" ] && seen=$(cut -d' ' -f1 "$f" | sort -u | wc -l | tr -d ' ')
    after=$(still_running "$f" "$VULNS_RE")
    if [ -n "$after" ]; then record "security/after-quit: FAIL (the app's brew vulns still running: $after)"
    elif [ "$seen" = 0 ]; then record "security/after-quit: FAIL (no brew vulns process seen under the app: did the scans run?)"
    else record "security/after-quit: PASS (none of the app's $seen brew vulns processes left)"; fi
    others=$(vulns_procs)
    [ -n "$others" ] && echo "    note: other brew vulns processes on this Mac (not this run's): $others" >&2
}

scenario_settings() {
    fresh_state settings
    local s names=(keepPreviousVersion scanVulnerabilitiesOnRefresh includeSelfUpdatingApps dontQuitAppsDuringUpgrade notifyNewVulnerabilities notifyNewUpgrades appManagementExplained)
    # Not `{ ...; } | run_phase`: a pipe would run it in a subshell and lose its result.
    local f="$OUT/settings/steps.tmp"
    { echo "expect-fresh"; echo "expect-ready"; for s in "${names[@]}"; do echo "set $s on"; done; echo "set showMenuBarIcon off"; } > "$f"
    run_phase settings 1-on < "$f"
    # The relaunch is inside the status cache's hour: it shows the cache.
    { echo "expect-ready cached"; for s in "${names[@]}"; do echo "expect setting $s on"; echo "set $s off"; done
      echo "expect setting showMenuBarIcon off"; echo "set showMenuBarIcon on"; } > "$f"
    run_phase settings 2-relaunch < "$f"
    rm -f "$f"
}

scenario_restore() {
    local tap=tankard-e2e/probe f=tankard-e2e-probe
    local taps_dir
    taps_dir="$(qbrew --repository)/Library/Taps"
    if [ -e "$taps_dir/tankard-e2e" ]; then record "restore: SKIP ($taps_dir/tankard-e2e exists)"; return; fi
    need_absent formula $f || { record "restore: SKIP ($f installed)"; return; }
    autoremove_clean || { record "restore: SKIP (autoremove would remove something)"; return; }
    fresh_state restore
    local work="$OUT/restore/work"
    mkdir -p "$work/src" "$work/tap/Formula"
    # Two tarballs of a one-line script, and a tap (a local git repo) with
    # the formula at 1.0.
    for v in 1.0 1.1; do
        mkdir -p "$work/src/$f-$v"
        printf '#!/bin/sh\necho "tankard e2e probe %s"\n' "$v" > "$work/src/$f-$v/$f"
        chmod +x "$work/src/$f-$v/$f"
        tar -C "$work/src" -czf "$work/$f-$v.tar.gz" "$f-$v"
    done
    formula() { # version
        cat <<RUBY
class TankardE2eProbe < Formula
  desc "Throwaway formula for Tankard's e2e tests"
  homepage "https://github.com/d4rkwyng/tankard"
  url "file://$work/$f-$1.tar.gz"
  sha256 "$(shasum -a 256 "$work/$f-$1.tar.gz" | cut -d' ' -f1)"
  license "MIT"

  def install
    bin.install "$f"
  end

  def caveats
    "Tankard e2e probe $1: nothing to do."
  end

  test do
    system bin/"$f"
  end
end
RUBY
    }
    formula 1.0 > "$work/tap/Formula/$f.rb"
    git -C "$work/tap" init -q -b main && git -C "$work/tap" add -A \
        && git -C "$work/tap" -c user.name=e2e -c user.email=e2e@localhost commit -qm "probe 1.0"

    run_phase restore 1-tap <<STEPS
expect-ready
set keepPreviousVersion on
tap-add $tap file://$work/tap
expect tap $tap
expect tap-trusted $tap off
tap-trust $tap on
tap-trust $tap off
tap-trust $tap on
STEPS
    local ok=$?
    if [ $ok = 0 ]; then
        # The 1.0 install isn't something Discover can do here (formulae.brew.sh
        # lists only official taps), so it is set up from the shell; then the
        # tap moves to 1.1, as a `brew update` would bring it.
        if qbrew install "$tap/$f" >"$OUT/restore/install-1.0.log" 2>&1; then
            formula 1.1 > "$taps_dir/tankard-e2e/homebrew-probe/Formula/$f.rb"
            git -C "$taps_dir/tankard-e2e/homebrew-probe" -c user.name=e2e -c user.email=e2e@localhost commit -qam "probe 1.1"
            # A relaunch inside the status cache's hour shows the cache (no
            # brew call), which predates the shell install: refresh first.
            run_phase restore 2-upgrade-rollback <<STEPS
expect-ready cached
refresh
expect installed $f 1.0
save-restore-point
upgrade $f
notes $f
expect installed $f 1.1
expect kegs $f 2
restore latest rollback $f
expect installed $f 1.0
expect kegs $f 1
expect pinned $f
unpin $f
expect not-pinned $f
pin $f
expect pinned $f
unpin $f
always uninstall formula $f
always tap-trust $tap off
always tap-remove $tap
expect no-tap $tap
STEPS
        else
            record "restore/setup: FAIL (brew install $tap/$f; see $OUT/restore/install-1.0.log)"
        fi
    fi
    # Leave nothing behind, whatever happened.
    qbrew list --formula "$f" >/dev/null 2>&1 && { echo "    cleanup: removing $f" >&2; qbrew uninstall --force --formula "$f"; }
    # Untrust first: brew keeps a trust entry after untap, and `untrust --tap`
    # needs the tap to exist.
    [ -e "$taps_dir/tankard-e2e/homebrew-probe" ] && qbrew untrust --tap "$tap" >/dev/null 2>&1
    [ -e "$taps_dir/tankard-e2e/homebrew-probe" ] && { echo "    cleanup: untapping $tap" >&2; qbrew untap "$tap"; }
    grep -q "tankard-e2e" ~/.homebrew/trust.json 2>/dev/null && echo "    note: ~/.homebrew/trust.json still names tankard-e2e" >&2
}

scenario_adopt() {
    local c=anybar app=/Applications/AnyBar.app
    need_absent cask $c || { record "adopt: SKIP ($c already installed)"; return; }
    if [ -e "$app" ]; then record "adopt: SKIP ($app exists and isn't ours)"; return; fi
    autoremove_clean || { record "adopt: SKIP (autoremove would remove something)"; return; }
    fresh_state adopt
    local work="$OUT/adopt/work" url sha
    mkdir -p "$work"
    read -r url sha < <(qbrew info --cask --json=v2 $c | python3 -c 'import json,sys; k=json.load(sys.stdin)["casks"][0]; print(k["url"], k["sha256"])')
    if ! curl -fsSL -o "$work/anybar.zip" "$url" || [ "$(shasum -a 256 "$work/anybar.zip" | cut -d' ' -f1)" != "$sha" ]; then
        record "adopt/setup: FAIL (download of $url failed or sha256 isn't the cask's $sha)"
        return
    fi
    ditto -x -k "$work/anybar.zip" "$work/unzipped" && ditto "$work/unzipped/AnyBar.app" "$app" \
        || { record "adopt/setup: FAIL (couldn't place $app)"; return; }
    run_phase adopt 1-adopt <<STEPS
expect-ready
set keepPreviousVersion on
adopt-scan
adopt $app app
expect installed $c
self-update $c homebrew
self-update $c app
expect-app present $app
always uninstall cask $c
expect not-installed $c
expect-app absent $app
STEPS
    # Leave nothing behind: the cask if still installed, else our own copy
    # of the app (moved to the Trash, never deleted outright).
    if qbrew list --cask $c >/dev/null 2>&1; then echo "    cleanup: uninstalling $c" >&2; qbrew uninstall --cask $c
    elif [ -e "$app" ]; then echo "    cleanup: moving our $app to the Trash" >&2; mv "$app" ~/.Trash/AnyBar-e2e-$$.app; fi
}

# The throttled background `brew update` (0.8), on the real brew. The
# interval is seconds here (the run's suite: e2eBackgroundUpdateInterval),
# never brew's FETCH_HEAD: the shell only reads its mtime.
scenario_prefetch() {
    local tap=tankard-e2e-pfetch/probe taps_dir c
    taps_dir="$(qbrew --repository)/Library/Taps"
    if [ -e "$taps_dir/tankard-e2e-pfetch" ]; then record "prefetch: SKIP ($taps_dir/tankard-e2e-pfetch exists)"; return; fi
    for c in tankard-e2e-pfetch-a tankard-e2e-pfetch-b; do
        need_absent cask $c || { record "prefetch: SKIP ($c installed)"; return; }
    done
    fresh_state prefetch
    local work="$OUT/prefetch/work" port pid
    mkdir -p "$work/www" "$work/tap/Casks" "$work/bin" "$work/installed"
    # A file server that sends ~3 MB/s per download (Content-Length, HEAD,
    # 404 for anything else), so brew's downloads take a visible while.
    cat > "$work/bin/serve.py" <<'PY'
import http.server, os, sys, time
root, rate = sys.argv[2], float(sys.argv[3])
class H(http.server.BaseHTTPRequestHandler):
    def head(self):
        p = os.path.join(root, os.path.basename(self.path))
        if not os.path.isfile(p):
            self.send_error(404); return None
        self.send_response(200)
        self.send_header("Content-Length", str(os.path.getsize(p)))
        self.send_header("Content-Type", "application/zip")
        self.end_headers()
        return p
    def do_HEAD(self): self.head()
    def do_GET(self):
        p = self.head()
        if not p: return
        with open(p, "rb") as f:
            while chunk := f.read(65536):
                self.wfile.write(chunk); time.sleep(len(chunk) / rate)
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
    python3 -I "$work/bin/serve.py" "$work/port" "$work/www" 3000000 >"$work/serve.log" 2>&1 &
    pid=$!
    local waited=0
    while [ ! -s "$work/port" ] && [ $waited -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
    port=$(cat "$work/port" 2>/dev/null)
    if [ -z "$port" ]; then kill "$pid" 2>/dev/null; record "prefetch/setup: FAIL (no local HTTP server)"; return; fi
    # Two versions of each cask: a zip of 6 MB of random bytes.
    cask() { # name version
        local z="$work/www/$1-$2.zip"
        if [ ! -f "$z" ]; then
            head -c 6000000 /dev/urandom > "$work/payload.bin"
            (cd "$work" && zip -q "$z" payload.bin)
        fi
        cat <<RUBY
cask "$1" do
  version "$2"
  sha256 "$(shasum -a 256 "$z" | cut -d' ' -f1)"

  url "http://127.0.0.1:$port/$1-$2.zip"
  name "$1"
  desc "Throwaway cask for Tankard's e2e tests"
  homepage "https://github.com/d4rkwyng/tankard"

  artifact "payload.bin", target: "$work/installed/$1.bin"
end
RUBY
    }
    for c in tankard-e2e-pfetch-a tankard-e2e-pfetch-b; do cask $c 1.0 > "$work/tap/Casks/$c.rb"; done
    git -C "$work/tap" init -q -b main && git -C "$work/tap" add -A \
        && git -C "$work/tap" -c user.name=e2e -c user.email=e2e@localhost commit -qm "probes 1.0"
    if qbrew tap "$tap" "file://$work/tap" >"$OUT/prefetch/setup.log" 2>&1 \
        && qbrew trust --tap "$tap" >>"$OUT/prefetch/setup.log" 2>&1 \
        && qbrew install --cask "$tap/tankard-e2e-pfetch-a" "$tap/tankard-e2e-pfetch-b" >>"$OUT/prefetch/setup.log" 2>&1; then
        for c in tankard-e2e-pfetch-a tankard-e2e-pfetch-b; do cask $c 1.1 > "$work/tap/Casks/$c.rb"; done
        git -C "$work/tap" -c user.name=e2e -c user.email=e2e@localhost commit -qam "probes 1.1"
        git -C "$taps_dir/tankard-e2e-pfetch/homebrew-probe" pull -q --ff-only
        run_phase prefetch 1-upgrade <<STEPS
expect-ready
expect installed tankard-e2e-pfetch-a 1.0
expect installed tankard-e2e-pfetch-b 1.0
set keepPreviousVersion on
watch-downloads on
upgrade tankard-e2e-pfetch-a tankard-e2e-pfetch-b
watch-downloads off
expect installed tankard-e2e-pfetch-a 1.1
expect installed tankard-e2e-pfetch-b 1.1
always uninstall cask tankard-e2e-pfetch-a
always uninstall cask tankard-e2e-pfetch-b
expect not-installed tankard-e2e-pfetch-a
expect not-installed tankard-e2e-pfetch-b
STEPS
        # The upgrade log: one fetch, then each upgrade found its file in the cache.
        local ul="$OUT/prefetch/state/upgrade.log"
        if [ -f "$ul" ] && grep -q '^=== .* \$ brew fetch --cask' "$ul"; then
            record "prefetch/log: PASS ($(grep -c '^=== .* \$ brew fetch' "$ul") fetch, $(grep -c '^=== .* brew upgrade' "$ul") upgrades in $ul)"
        else
            record "prefetch/log: FAIL (no brew fetch in $ul)"
        fi
    else
        record "prefetch/setup: FAIL (tap/trust/install of the probes; see $OUT/prefetch/setup.log)"
    fi
    for c in tankard-e2e-pfetch-a tankard-e2e-pfetch-b; do
        qbrew list --cask "$c" >/dev/null 2>&1 && { echo "    cleanup: removing $c" >&2; qbrew uninstall --cask "$tap/$c"; }
    done
    # Only these casks' own downloads ("<sha256>--tankard-e2e-pfetch-a-1.0.zip").
    local dl
    dl="$(qbrew --cache)/downloads"
    find "$dl" -maxdepth 1 -name '*--tankard-e2e-pfetch-[ab]-1.[01].zip*' -delete 2>/dev/null
    [ -e "$taps_dir/tankard-e2e-pfetch/homebrew-probe" ] && qbrew untrust --tap "$tap" >/dev/null 2>&1
    [ -e "$taps_dir/tankard-e2e-pfetch/homebrew-probe" ] && { echo "    cleanup: untapping $tap" >&2; qbrew untap "$tap"; }
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

scenario_background() {
    local repo fh tap=tankard-e2e/probe f=tankard-e2e-probe taps_dir
    repo=$(qbrew --repository); fh="$repo/.git/FETCH_HEAD"
    taps_dir="$repo/Library/Taps"
    fetched() { stat -f %m "$fh" 2>/dev/null || echo 0; }
    fresh_state background
    # 1: due (brew's last fetch is older than the interval): exactly one
    # real `brew update`, and FETCH_HEAD moves. If someone fetched in the
    # last 2 minutes, wait until that is older than the interval.
    local iv=120 age m0 m1 m2 m3
    age=$(( $(date +%s) - $(fetched) ))
    if [ $age -lt $iv ]; then
        echo "    brew fetched ${age}s ago: waiting $((iv - age + 2))s so the update is due" >&2
        sleep $((iv - age + 2))
    fi
    defaults write "$SUITE" e2eBackgroundUpdateInterval -float $iv
    m0=$(fetched)
    run_phase background 1-due TANKARD_E2E_BACKGROUND=1 <<'STEPS'
expect-ready
wait-background-update
expect-background-updates 1 after 8
expect-background-decision not-due
STEPS
    m1=$(fetched)
    if [ "$m1" -gt "$m0" ]; then record "background/fetch-head: PASS (brew update fetched: FETCH_HEAD $(date -r "$m0" +%T) -> $(date -r "$m1" +%T))"
    else record "background/fetch-head: FAIL (FETCH_HEAD didn't move: no real brew update ran)"; fi
    # 2: a second launch inside the interval runs none.
    run_phase background 2-again TANKARD_E2E_BACKGROUND=1 <<'STEPS'
expect-ready cached
expect-background-updates 0 after 15
expect-background-decision not-due
STEPS
    m2=$(fetched)
    if [ "$m2" = "$m1" ]; then record "background/two-launches: PASS (exactly one brew update across both launches)"
    else record "background/two-launches: FAIL (FETCH_HEAD moved again: $(date -r "$m1" +%T) -> $(date -r "$m2" +%T))"; fi
    # 3: HOMEBREW_NO_AUTO_UPDATE=1 set: none, even with the update due.
    defaults write "$SUITE" e2eBackgroundUpdateInterval -float 5
    sleep 6
    run_phase background 3-opted-out TANKARD_E2E_BACKGROUND=1 HOMEBREW_NO_AUTO_UPDATE=1 <<'STEPS'
expect-ready cached
expect-background-decision opted-out
expect-background-updates 0 after 15
STEPS
    m3=$(fetched)
    if [ "$m3" = "$m2" ]; then record "background/opted-out: PASS (HOMEBREW_NO_AUTO_UPDATE=1: FETCH_HEAD untouched)"
    else record "background/opted-out: FAIL (FETCH_HEAD moved with HOMEBREW_NO_AUTO_UPDATE=1)"; fi

    # 4: Upgrade clicked while the update runs: a throwaway local tap's probe
    # 1.0 -> 1.1 (as in restore), the sheet waits for the update.
    if [ -e "$taps_dir/tankard-e2e" ]; then record "background/upgrade: SKIP ($taps_dir/tankard-e2e exists)"; return; fi
    need_absent formula $f || { record "background/upgrade: SKIP ($f installed)"; return; }
    autoremove_clean || { record "background/upgrade: SKIP (autoremove would remove something)"; return; }
    local work="$OUT/background/work"
    mkdir -p "$work/src" "$work/tap/Formula"
    for v in 1.0 1.1; do
        mkdir -p "$work/src/$f-$v"
        printf '#!/bin/sh\necho "tankard e2e probe %s"\n' "$v" > "$work/src/$f-$v/$f"
        chmod +x "$work/src/$f-$v/$f"
        tar -C "$work/src" -czf "$work/$f-$v.tar.gz" "$f-$v"
    done
    probe() { # version
        cat <<RUBY
class TankardE2eProbe < Formula
  desc "Throwaway formula for Tankard's e2e tests"
  homepage "https://github.com/d4rkwyng/tankard"
  url "file://$work/$f-$1.tar.gz"
  sha256 "$(shasum -a 256 "$work/$f-$1.tar.gz" | cut -d' ' -f1)"
  license "MIT"

  def install
    bin.install "$f"
  end
end
RUBY
    }
    probe 1.0 > "$work/tap/Formula/$f.rb"
    git -C "$work/tap" init -q -b main && git -C "$work/tap" add -A \
        && git -C "$work/tap" -c user.name=e2e -c user.email=e2e@localhost commit -qm "probe 1.0"
    if qbrew tap "$tap" "file://$work/tap" >"$OUT/background/setup.log" 2>&1 \
        && qbrew trust --tap "$tap" >>"$OUT/background/setup.log" 2>&1 \
        && qbrew install "$tap/$f" >>"$OUT/background/setup.log" 2>&1; then
        # 1.1 in the tap's origin, pulled into the tap: the update that
        # runs in the phase then finds nothing new there.
        probe 1.1 > "$work/tap/Formula/$f.rb"
        git -C "$work/tap" -c user.name=e2e -c user.email=e2e@localhost commit -qam "probe 1.1"
        git -C "$taps_dir/tankard-e2e/homebrew-probe" pull -q --ff-only
        # The first update at launch re-reads the list (it predates the
        # shell install); the second, 5 s later, is the one clicked into.
        run_phase background 4-upgrade-during-update TANKARD_E2E_BACKGROUND=1 <<STEPS
expect-ready cached
wait-background-update
expect installed $f 1.0
upgrade-during-update $f
expect installed $f 1.1
always uninstall formula $f
expect not-installed $f
STEPS
    else
        record "background/setup: FAIL (tap/trust/install of the probe; see $OUT/background/setup.log)"
    fi
    qbrew list --formula "$f" >/dev/null 2>&1 && { echo "    cleanup: removing $f" >&2; qbrew uninstall --force --formula "$f"; }
    [ -e "$taps_dir/tankard-e2e/homebrew-probe" ] && qbrew untrust --tap "$tap" >/dev/null 2>&1
    [ -e "$taps_dir/tankard-e2e/homebrew-probe" ] && { echo "    cleanup: untapping $tap" >&2; qbrew untap "$tap"; }
    grep -q "tankard-e2e" ~/.homebrew/trust.json 2>/dev/null && echo "    note: ~/.homebrew/trust.json still names tankard-e2e" >&2
}

for sc in "${SCENARIOS[@]}"; do
    if declare -f "scenario_$sc" >/dev/null; then
        echo "== $sc"
        "scenario_$sc"
    else
        record "$sc: FAIL (no such scenario; --list)"
    fi
done
delete_suite

echo
echo "e2e summary ($OUT):"
printf '  %s\n' "${RESULTS[@]}"
printf '%s\n' "${RESULTS[@]}" | grep -q ": FAIL" && exit 1
exit 0
