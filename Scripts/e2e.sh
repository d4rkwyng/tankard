#!/bin/bash
# Scripted real-run tests: drives the REAL app (no demo) through user flows
# against the REAL brew, with a step script per phase (TANKARD_E2E=1 +
# TANKARD_SCRIPT; see Sources/TankardApp/ScriptLaunch.swift and
# Sources/TankardAppModel/ScriptRunner.swift for the step vocabulary).
#
#   Scripts/e2e.sh [--no-build] [--app PATH] [--out DIR] SCENARIO...
#   Scripts/e2e.sh all                 every scenario below
#   Scripts/e2e.sh --list              the scenarios
#   Scripts/e2e.sh --steps             the step vocabulary
#
# Scenarios:
#   welcome    no brew → the welcome screen; then a first launch with fresh
#              settings and no cache reads brew live, Refresh (runs brew
#              update), Discover search
#   formula    install `hello` from Discover, pin, unpin, uninstall
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
#
# Each phase writes OUT/<scenario>/<phase>/: NN-step.png per step,
# results.jsonl (one JSON line per step: pass/fail, checks, model state),
# summary.json and app.log. The summary at the end says PASS/FAIL per phase.
#
# Isolation: settings go to the `net.mindtricks.tankard.e2e` defaults suite
# (deleted at the start of each scenario: a first launch), Tankard's files
# to OUT/<scenario>/state. Your own settings, cache, History and restore
# points are not read or written.
#
# What it changes on this Mac: it installs and removes the scenario's own
# throwaway packages (hello, font-press-start-2p, tankard-e2e-probe) and
# adds/removes its own tap (tankard-e2e/probe). Safety checks first:
#   - a scenario is skipped if its package is already installed (it would
#     uninstall yours) or its tap already exists;
#   - uninstall runs brew's autoremove (Homebrew's default), so it refuses
#     to start when `brew autoremove --dry-run` already lists something;
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
ALL=(welcome formula cask security settings restore adopt)
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --app) APP=${2%/}; BUILD=0; shift ;;
        --out) OUT=$2; shift ;;
        --list) printf '%s\n' "${ALL[@]}"; exit 0 ;;
        --steps) STEPS_HELP=1 ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
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

BREW=$(command -v brew || true)
[ -n "$BREW" ] || { echo "e2e.sh: no brew on PATH" >&2; exit 1; }
# The shell's own brew calls: never update, never clean up, never autoremove.
qbrew() { HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" "$@"; }

RESULTS=()
record() { RESULTS+=("$1"); echo "==> $1"; }

fresh_state() { # scenario
    defaults delete net.mindtricks.tankard.e2e >/dev/null 2>&1 || true
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
    env "$@" TANKARD_E2E=1 TANKARD_SCRIPT="$dir/steps.txt" TANKARD_SCRIPT_OUT="$dir" \
        TANKARD_E2E_STATE="$OUT/$sc/state" "$BIN" -ApplePersistenceIgnoreState YES >"$dir/app.log" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && [ $waited -lt "$PHASE_TIMEOUT" ]; do sleep 2; waited=$((waited + 2)); done
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

vulns_procs() { ps -axww -o pid=,command= | grep -E 'brew(\.rb)?[^|]* vulns' | grep -v grep || true; }

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

scenario_security() {
    fresh_state security
    local before
    before=$(vulns_procs)
    [ -n "$before" ] && echo "    note: brew vulns already running before the test: $before" >&2
    run_phase security 1-scan <<'STEPS'
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
    local after
    after=$(vulns_procs)
    if [ -n "$after" ]; then record "security/after-quit: FAIL (brew vulns still running: $after)"
    else record "security/after-quit: PASS (no brew vulns process left)"; fi
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

for sc in "${SCENARIOS[@]}"; do
    if declare -f "scenario_$sc" >/dev/null; then
        echo "== $sc"
        "scenario_$sc"
    else
        record "$sc: FAIL (no such scenario; --list)"
    fi
done
defaults delete net.mindtricks.tankard.e2e >/dev/null 2>&1 || true

echo
echo "e2e summary ($OUT):"
printf '  %s\n' "${RESULTS[@]}"
printf '%s\n' "${RESULTS[@]}" | grep -q ": FAIL" && exit 1
exit 0
