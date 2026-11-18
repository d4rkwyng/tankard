#!/bin/bash
# 0.8.3: the self-upgrade end to end, on this Mac's real brew and
# /Applications, with two builds of this tree:
#
#   Scripts/e2e-selfupdate.sh --old OLD.app --new NEW.app --out DIR [--phases ABC]
#
# OLD and NEW: release builds (Scripts/bundle-app.sh) whose TankardVersion
# and CFBundleShortVersionString differ, NEW the newer (semver: 0.8.3 and
# 0.8.4-e2e.1). A throwaway local tap, tankard-e2e-self/tap (never
# d4rkwyng/tap), serves a cask `tankard` from file:// zips of them.
#
#   A  fixed build -> newer: install OLD with the cask, run it as a script
#      (TANKARD_E2E_SELFUPDATE=1: relaunch on, counted by the guard) through
#      Check for Tankard Updates, Upgrade with Homebrew, the quiet mode, a
#      sheet left open, then the alert's Relaunch. Pass: the old pid gone,
#      exactly one Tankard afterwards, running NEW.
#   B  same-build double launch: `open` then `open -n` the installed app.
#      Pass: the second activates the first and quits; one pid.
#   C  a stale copy with a sheet open (0.8.2's Relaunch opened the new copy
#      first): OLD runs with a sheet up, the shell upgrades the cask to NEW
#      and runs `open -n`. Pass: the new copy asks the old one to quit (and
#      alerts if the sheet refuses it); once the old one is gone, exactly
#      one Tankard, running NEW.
#
# --phases: run only these (default ABC). Without A, B installs NEW first
# (quarantine removed, as install_old does). Scripts/rc-selfupdate-signed.sh
# uses it when OLD is a release whose relaunch passes the script
# environment on (before 0.8.4), which phase A can't judge.
#
# Each phase: a 0.25 s process timeline, `log stream` of Tankard's
# subsystem, the app's stderr, and no new Tankard .ips in
# ~/Library/Logs/DiagnosticReports. Refuses to start if Tankard runs, if
# /Applications/Tankard.app exists, or if the tap or a tankard cask exists.
# Cleans up the cask, the tap, /Applications/Tankard.app and its processes.
set -uo pipefail
cd "$(dirname "$0")/.."
# step_result, step_logged, relaunch_logged, ran_tankard_code, no_instance_yield
# (0.8.4; `Scripts/e2e-selfupdate-checks.sh --self-test` checks them).
source Scripts/e2e-selfupdate-checks.sh

OLD= NEW= OUT= PHASES=ABC
while [ $# -gt 0 ]; do
    case "$1" in
        --old) OLD=${2%/}; shift ;;
        --new) NEW=${2%/}; shift ;;
        --out) OUT=$2; shift ;;
        --phases) PHASES=$2; shift ;;
        -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "e2e-selfupdate.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
[ -d "$OLD" ] && [ -d "$NEW" ] && [ -n "$OUT" ] || { echo "usage: --old OLD.app --new NEW.app --out DIR [--phases ABC]" >&2; exit 2; }
[[ $PHASES =~ ^[ABC]+$ ]] || { echo "e2e-selfupdate.sh: --phases takes letters from ABC, got '$PHASES'" >&2; exit 2; }
want() { [[ $PHASES == *$1* ]]; }
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
OLD=$(cd "$OLD" && pwd); NEW=$(cd "$NEW" && pwd)
VOLD=$(plutil -extract CFBundleShortVersionString raw "$OLD/Contents/Info.plist")
VNEW=$(plutil -extract CFBundleShortVersionString raw "$NEW/Contents/Info.plist")
TAP=tankard-e2e-self/tap
CASK=$TAP/tankard
APP=/Applications/Tankard.app
BREW=$(command -v brew)
qbrew() { HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" "$@"; }
# No `brew ... | grep -q` under pipefail: grep quits at the first match,
# brew can get SIGPIPE, and the pipeline then fails (141) on a match.
has_tap() { grep -qx "$TAP" <<<"$(qbrew tap 2>/dev/null)"; }
has_cask() { grep -qx tankard <<<"$(qbrew list --cask 2>/dev/null)"; }
SUITE=net.mindtricks.tankard.e2e.$$
RESULTS=()
record() { RESULTS+=("$1"); echo "==> $1" | tee -a "$OUT/summary.txt"; }
now() { date +%H:%M:%S; }
# Only the installed app's processes: other worktrees' builds (dist/, demo
# and e2e runs of parallel work) are never counted or touched.
pids() { pgrep -f '^/Applications/Tankard.app/Contents/MacOS/Tankard' | tr '\n' ' ' | sed 's/ $//'; }

# MARK: preconditions (never touch what isn't ours)
[ -z "$(pids)" ] || { echo "e2e-selfupdate.sh: Tankard is running (pids $(pids)); quit it first" >&2; exit 3; }
[ ! -e "$APP" ] || { echo "e2e-selfupdate.sh: $APP exists; this run installs its own and would remove it" >&2; exit 3; }
has_tap && { echo "e2e-selfupdate.sh: tap $TAP already exists" >&2; exit 3; }
has_cask && { echo "e2e-selfupdate.sh: a tankard cask is installed" >&2; exit 3; }
# The machine-wide e2e lock (Scripts/e2e.sh's): one run using brew and the app at a time.
LOCK=/tmp/net.mindtricks.tankard.e2e.lock
until mkdir "$LOCK" 2>/dev/null; do
    h=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$h" ] && ! kill -0 "$h" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
    echo "e2e-selfupdate.sh: waiting for the e2e lock (pid ${h:-?})" >&2; sleep 5
done
echo $$ > "$LOCK/pid"; echo "$(pwd) selfupdate" > "$LOCK/where"
MARK="$OUT/.start"; touch "$MARK"
: > "$OUT/summary.txt"

STARTED=()
cleanup() {
    echo "==> cleanup"
    for p in $(pids); do kill "$p" 2>/dev/null; done
    sleep 1
    for p in $(pids); do kill -9 "$p" 2>/dev/null; done
    [ -n "${SAMPLER:-}" ] && kill "$SAMPLER" 2>/dev/null
    [ -n "${LOGSTREAM:-}" ] && kill "$LOGSTREAM" 2>/dev/null
    has_cask && qbrew uninstall --cask "$CASK" >> "$OUT/brew.log" 2>&1
    has_tap && qbrew untap "$TAP" >> "$OUT/brew.log" 2>&1
    [ -e "$APP" ] && echo "cleanup: $APP still present" >&2
    defaults delete "$SUITE" >/dev/null 2>&1; rm -f ~/Library/Preferences/"$SUITE".plist
    # The relaunched copies' script folders (AppManagement.relaunchEnvironment):
    # their app is gone by now; the phase's verdict is already recorded.
    rm -rf "$OUT"/[ABC]/relaunched
    rm -rf "$LOCK"
    echo "after cleanup: pids=[$(pids)] app=$([ -e "$APP" ] && echo present || echo absent) tap=$(qbrew tap | grep -cx "$TAP")" | tee -a "$OUT/summary.txt"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# MARK: the tap and its cask
qbrew tap-new --no-git "$TAP" > "$OUT/brew.log" 2>&1 || { echo "tap-new failed" >&2; exit 1; }
TAPDIR=$(qbrew --repository "$TAP")
mkdir -p "$TAPDIR/Casks" "$OUT/zips"
for v in old new; do
    src=$OLD; [ $v = new ] && src=$NEW
    ditto -c -k --keepParent "$src" "$OUT/zips/tankard-$v.zip"
done
write_cask() { # old|new
    local v=$VOLD z="$OUT/zips/tankard-old.zip"
    [ "$1" = new ] && { v=$VNEW; z="$OUT/zips/tankard-new.zip"; }
    cat > "$TAPDIR/Casks/tankard.rb" <<RUBY
cask "tankard" do
  version "$v"
  sha256 "$(shasum -a 256 "$z" | cut -d' ' -f1)"
  url "file://$z"
  name "Tankard"
  desc "Tankard self-update e2e (throwaway)"
  homepage "https://github.com/d4rkwyng/tankard"
  app "Tankard.app"
end
RUBY
}
FEED="$OUT/feed.json"
printf '{"tag_name":"v%s","body":"e2e build","html_url":"https://github.com/d4rkwyng/tankard/releases/tag/v%s","draft":false,"prerelease":false}\n' "$VNEW" "$VNEW" > "$FEED"

install_old() {
    write_cask old
    qbrew install --cask "$CASK" >> "$OUT/brew.log" 2>&1 || { echo "install failed" >&2; return 1; }
    # An ad-hoc signed test build: no quarantine, as a notarized release wouldn't need.
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null
    [ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VOLD" ]
}
# --phases without A: B needs NEW installed (A would have left it there).
install_new() {
    write_cask new
    qbrew install --cask "$CASK" >> "$OUT/brew.log" 2>&1 || { echo "install failed" >&2; return 1; }
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null
    [ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VNEW" ]
}

start_watch() { # dir
    ( while true; do
        ts=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
        ps -axo pid=,ppid=,lstart=,command= | grep -E '[T]ankard.app/Contents/MacOS/Tankard|[k]ill -0|[o]pen -n' | sed "s/^/$ts /"
        echo "$ts --"
        sleep 0.25
      done ) > "$1/timeline.txt" 2>&1 &
    SAMPLER=$!
    /usr/bin/log stream --style compact --predicate 'subsystem == "net.mindtricks.tankard" OR (process == "logger") OR (process == "ReportCrash")' > "$1/logstream.txt" 2>&1 &
    LOGSTREAM=$!
    sleep 1
}
stop_watch() { kill "$SAMPLER" "$LOGSTREAM" 2>/dev/null; SAMPLER= LOGSTREAM=; }
wait_for() { # seconds, condition...
    local t=$1; shift
    local i=0
    while ! "$@" && [ $i -lt $((t * 4)) ]; do sleep 0.25; i=$((i + 1)); done
    "$@"
}
one_new_running() {
    local p; p=$(pids)
    [ -n "$p" ] && [ "$(echo "$p" | wc -w | tr -d ' ')" = 1 ] && [ "$p" != "${1:-}" ] \
        && [ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VNEW" ]
}
# Crash reports since the start for the installed app (not other builds).
ips_new() { find ~/Library/Logs/DiagnosticReports -name 'Tankard*.ips' -newer "$MARK" -exec grep -l 'Applications/Tankard.app' {} + 2>/dev/null | wc -l | tr -d ' '; }
quit_all() { for p in $(pids); do kill "$p" 2>/dev/null; done; wait_for 10 test -z "$(pids)" >/dev/null; }

script_env() { # dir
    echo TANKARD_E2E=1 TANKARD_E2E_SELFUPDATE=1 TANKARD_E2E_SELF_TAP=$TAP TANKARD_E2E_SUITE=$SUITE \
        TANKARD_SCRIPT=$1/steps.txt TANKARD_SCRIPT_OUT=$1 TANKARD_E2E_STATE=$1/state TANKARD_UPDATE_FEED=$FEED
}

# MARK: A  fixed build -> newer, sheet open at Relaunch
D=$OUT/A
if ! want A; then
    echo "$(now) A: skipped (--phases $PHASES)"
elif mkdir -p "$D" && echo "$(now) A: install $VOLD" | tee "$D/events.txt" && install_old; then
    write_cask new   # the tap now offers the newer build
    cat > "$D/steps.txt" <<STEPS
expect-ready
check-updates $VNEW brew
upgrade-self $VNEW
expect-quiet 5
open-sheet history
relaunch
STEPS
    start_watch "$D"
    env $(script_env "$D") "$APP/Contents/MacOS/Tankard" -ApplePersistenceIgnoreState YES > "$D/app.log" 2>&1 &
    OLDPID=$!
    echo "$(now) A: old pid $OLDPID" | tee -a "$D/events.txt"
    i=0; while kill -0 $OLDPID 2>/dev/null && [ $i -lt 900 ]; do sleep 1; i=$((i + 1)); done
    # 0: NSApp.terminate (the relaunch); a script that ran on exits 1.
    wait $OLDPID; OLDRC=$?
    echo "$(now) A: old pid $OLDPID exited, status $OLDRC" | tee -a "$D/events.txt"
    wait_for 20 one_new_running "$OLDPID"
    sleep 3   # a late second instance would show up here
    NEWPID=$(pids)
    echo "$(now) A: after: pids=[$NEWPID] bundle=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist") ips_new=$(ips_new)" | tee -a "$D/events.txt"
    [ -n "$NEWPID" ] && ps -o pid=,lstart=,command= -p "$NEWPID" | tee -a "$D/events.txt"
    stop_watch
    # 0.8.4: a pid count and the bundle's version aren't evidence on their
    # own (rc2 passed with a new pid that never logged a line). Also
    # required: steps 1-5 passed in the old copy (from its app.log: the
    # relaunched copy recreates results.jsonl), its relaunch helper and
    # terminate lines, no copy yielding to another, and a line from the new
    # pid itself.
    WHY=()
    for s in "1 expect-ready" "2 check-updates $VNEW brew" "3 upgrade-self $VNEW" "4 expect-quiet 5" "5 open-sheet history"; do
        r=$(step_logged "$D/app.log" "${s%% *}" "${s#* }") || WHY+=("step ${s%% *} ${s#* }: $r")
    done
    r=$(relaunch_logged "$D/logstream.txt" "$OLDPID") || WHY+=("relaunch: $r")
    r=$(no_instance_yield "$D/logstream.txt") || WHY+=("$r")
    NEWRAN=$(ran_tankard_code "$D/logstream.txt" "$NEWPID") || WHY+=("new pid: $NEWRAN")
    # 0.8.4: the new copy inherits no TANKARD_* variable but an idle e2e
    # identity, its output in $D/relaunched (its summary.json can take a
    # moment: the store starts first).
    wait_for 30 test -f "$D/relaunched/summary.json" >/dev/null
    r=$(relaunched_idle "$D") || WHY+=("relaunched copy: $r")
    [ "$OLDRC" = 0 ] || WHY+=("old pid exit status $OLDRC")
    one_new_running "$OLDPID" || WHY+=("not exactly one new Tankard running $VNEW: pids=[$(pids)]")
    [ "$(ips_new)" = 0 ] || WHY+=("ips_new=$(ips_new)")
    printf 'A evidence: %s\n' "${WHY[@]:-all present}" >> "$D/events.txt"
    if [ ${#WHY[@]} = 0 ]; then
        record "A fixed->newer relaunch: PASS (old $OLDPID: steps 1-5 passed, helper + terminate logged, gone; one Tankard $NEWPID running $VNEW, idle e2e copy, its log: ${NEWRAN#ok: }; no yield, no .ips)"
    else
        record "A fixed->newer relaunch: FAIL ($(IFS=';'; echo "${WHY[*]}"); see $D)"
    fi
else
    record "A: FAIL (install of $VOLD)"
fi

# MARK: B  same-build double launch
D=$OUT/B
if ! want B; then
    echo "$(now) B: skipped (--phases $PHASES)"
elif ! want A && ! install_new; then
    record "B: FAIL (install of $VNEW)"
else
mkdir -p "$D"
quit_all
start_watch "$D"
open "$APP"; wait_for 15 test -n "$(pids)"
FIRST=$(pids); sleep 4
echo "$(now) B: first pid $FIRST; open -n" | tee "$D/events.txt"
open -n "$APP"; sleep 6
echo "$(now) B: after: pids=[$(pids)]" | tee -a "$D/events.txt"
stop_watch
if [ "$(pids)" = "$FIRST" ] && grep -q "yield(to: $FIRST)" "$D/logstream.txt" && [ "$(ips_new)" = 0 ]; then
    record "B same-build double launch: PASS (second launch yielded to $FIRST and quit)"
else
    record "B same-build double launch: FAIL (pids=[$(pids)], first $FIRST; see $D)"
fi
quit_all
fi

# MARK: C  stale copy with a sheet open, 0.8.2-style open-first
D=$OUT/C
if ! want C; then
    echo "$(now) C: skipped (--phases $PHASES)"
elif mkdir -p "$D" && { ! has_cask || qbrew uninstall --cask "$CASK" >> "$OUT/brew.log" 2>&1; } \
    && echo "$(now) C: install $VOLD" | tee "$D/events.txt" && install_old; then
    cat > "$D/steps.txt" <<STEPS
expect-ready
open-sheet history
sleep 30
close-sheets
sleep 10
STEPS
    start_watch "$D"
    env $(script_env "$D") "$APP/Contents/MacOS/Tankard" -ApplePersistenceIgnoreState YES > "$D/app.log" 2>&1 &
    OLDPID=$!
    # 0.8.4: wait for step 2's result line (the screenshot alone was taken
    # as "sheet up", and the wait timing out went on regardless: rc2's C
    # said "has its sheet up" with no results.jsonl at all).
    sheet_done() { [ "$(step_result "$D/results.jsonl" 2 "open-sheet history")" != missing ] || ! kill -0 $OLDPID 2>/dev/null; }
    wait_for 180 sheet_done >/dev/null
    SHEET=$(step_result "$D/results.jsonl" 2 "open-sheet history")
    if [ "$SHEET" != ok ] || ! kill -0 $OLDPID 2>/dev/null; then
        echo "$(now) C: no sheet up in old pid $OLDPID (step 2: $SHEET; $(kill -0 $OLDPID 2>/dev/null && echo running || echo exited))" | tee -a "$D/events.txt"
        stop_watch
        record "C stale copy with sheet: FAIL (the sheet never came up: step 2 $SHEET; see $D)"
        quit_all
    else
    echo "$(now) C: old pid $OLDPID has its sheet up (step 2: ok); brew upgrade to $VNEW (no quit), then open -n" | tee -a "$D/events.txt"
    write_cask new
    HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 qbrew upgrade --cask "$CASK" >> "$OUT/brew.log" 2>&1
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null
    open -n "$APP"
    echo "$(now) C: opened new; pids=[$(pids)]" | tee -a "$D/events.txt"
    i=0; while kill -0 $OLDPID 2>/dev/null && [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done
    echo "$(now) C: old pid $OLDPID exited ($(kill -0 $OLDPID 2>/dev/null && echo NOT || echo yes))" | tee -a "$D/events.txt"
    sleep 3
    echo "$(now) C: after: pids=[$(pids)] ips_new=$(ips_new)" | tee -a "$D/events.txt"
    stop_watch
    ALERT=$(grep -c "alert" "$D/logstream.txt" || true)
    if ! kill -0 $OLDPID 2>/dev/null && one_new_running "$OLDPID" && grep -q "replaceStale" "$D/logstream.txt" && [ "$(ips_new)" = 0 ]; then
        record "C stale copy with sheet: PASS (new copy asked $OLDPID to quit; alert lines: $ALERT; one Tankard $(pids) running $VNEW)"
    else
        record "C stale copy with sheet: FAIL (pids=[$(pids)]; see $D)"
    fi
    fi
else
    record "C: FAIL (install of $VOLD)"
fi

echo
printf '%s\n' "${RESULTS[@]}"
grep -q FAIL <<<"$(printf '%s\n' "${RESULTS[@]}")" && exit 1
exit 0
