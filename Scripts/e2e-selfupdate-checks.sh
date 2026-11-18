#!/bin/bash
# 0.8.4: the evidence Scripts/e2e-selfupdate.sh asserts, factored out so the
# logic can be checked without installing anything:
#
#   Scripts/e2e-selfupdate-checks.sh --self-test
#
# Sourced by e2e-selfupdate.sh. Each check reads files a phase wrote
# (results.jsonl from the app's script runner, logstream.txt from
# `log stream --style compact`) and prints why it failed. The rc2 run had
# two false passes these replace: the "sheet up" wait went on when the sheet
# never appeared (no result line at all), and phase A passed on a pid count
# and the bundle version while the new pid had logged nothing.

# step_result RESULTS INDEX TEXT: prints "ok", "missing", "skipped", "wrong
# step: ..." or "failed: <error>" for step INDEX of a results.jsonl; true
# only for "ok" (that step, with that text, ran and passed).
step_result() {
    local results=$1 index=$2 text=$3
    [ -f "$results" ] || { echo "missing (no $results)"; return 1; }
    /usr/bin/python3 -I - "$results" "$index" "$text" <<'PY'
import json, sys
path, index, text = sys.argv[1], int(sys.argv[2]), sys.argv[3]
found = None
with open(path) as f:
    for line in f:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("index") == index:
            found = r
if found is None:
    print("missing"); sys.exit(1)
if found.get("step") != text:
    print("wrong step: %r" % found.get("step")); sys.exit(1)
if found.get("skipped"):
    print("skipped"); sys.exit(1)
if not found.get("ok"):
    print("failed: %s" % (found.get("error") or "?")); sys.exit(1)
print("ok")
PY
}

# step_logged APPLOG INDEX TEXT: the same verdict from the app's stderr
# ("e2e: step N (line L): TEXT" then "e2e:   -> PASS"). Phase A uses this:
# its app.log is the old pid's own, while results.jsonl is recreated (0
# bytes) when the relaunched copy starts, because it inherits the script
# environment through the relaunch helper (0.8.3 rc1 and the two earlier
# runs all ended with an empty results.jsonl, mtime = the new pid's start).
step_logged() {
    local log=$1 index=$2 text=$3
    [ -f "$log" ] || { echo "missing (no $log)"; return 1; }
    awk -v want="e2e: step $index (line " -v text="$text" '
        found == 0 && index($0, want) == 1 {
            rest = substr($0, length(want) + 1); sub(/^[0-9]+\): /, "", rest)
            if (rest == text) { found = 1; next }
            print "wrong step: " rest; bad = 1; exit
        }
        found == 1 && /^e2e:   -> / { v = substr($0, 11); found = 2; exit }
        END {
            if (bad) exit 1
            if (found == 0) { print "missing"; exit 1 }
            if (found == 1) { print "no verdict (the app stopped in the step)"; exit 1 }
            if (v == "PASS") { print "ok"; exit 0 }
            print (v == "SKIPPED" ? "skipped" : "failed: " substr(v, 7)); exit 1
        }' "$log"
}

# relaunched_idle PHASEDIR: the relaunched copy came up as an idle e2e run
# (0.8.4, AppManagement.relaunchEnvironment): its own empty step file in
# PHASEDIR/relaunched, a summary.json there with no step run, and the
# phase's own results.jsonl not recreated by it (not empty).
relaunched_idle() {
    local d=$1
    [ -s "$d/results.jsonl" ] || { echo "the phase's results.jsonl is empty or missing (recreated by the new copy?)"; return 1; }
    [ -f "$d/relaunched/steps.txt" ] || { echo "no $d/relaunched/steps.txt (the new copy got no e2e identity)"; return 1; }
    [ -s "$d/relaunched/steps.txt" ] && { echo "$d/relaunched/steps.txt is not empty"; return 1; }
    [ -f "$d/relaunched/summary.json" ] || { echo "no $d/relaunched/summary.json (the new copy didn't run as an e2e copy)"; return 1; }
    /usr/bin/python3 -I - "$d/relaunched/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
n = s.get("passed", 0) + s.get("failed", 0) + s.get("skipped", 0)
if n:
    print("the relaunched copy ran %d step(s)" % n); sys.exit(1)
print("ok")
PY
}

# relaunch_logged LOGSTREAM OLDPID: the relaunch helper started for OLDPID,
# OLDPID logged its terminate, and neither gave-up line is there.
relaunch_logged() {
    local log=$1 pid=$2
    [ -f "$log" ] || { echo "no $log"; return 1; }
    grep -Eq "Tankard\[$pid:[^]]*\].*relaunch: helper [0-9]+ waits for pid $pid\$" "$log" \
        || { echo "no 'relaunch: helper N waits for pid $pid' from $pid"; return 1; }
    grep -Eq "Tankard\[$pid:[^]]*\].*relaunch: terminate pid $pid\$" "$log" \
        || { echo "no 'relaunch: terminate pid $pid' from $pid"; return 1; }
    if grep -Eq "relaunch: (pid $pid is still running after two terminate|Tankard \(pid $pid\) still running, not reopening|helper didn't start)" "$log"; then
        echo "relaunch gave up: $(grep -E "relaunch: (pid $pid is still|Tankard \(pid $pid\) still|helper didn't)" "$log" | head -1)"
        return 1
    fi
    echo "ok"
}

# ran_tankard_code LOGSTREAM PID: PID logged at least one line in Tankard's
# subsystem (at launch every app bundle logs "authorization at launch"),
# so the process is Tankard running, not one stuck before main (a
# Gatekeeper prompt) or a different program.
ran_tankard_code() {
    local log=$1 pid=$2
    [ -n "$pid" ] || { echo "no pid"; return 1; }
    [ -f "$log" ] || { echo "no $log"; return 1; }
    if grep -Eq "Tankard\[$pid:[^]]*\] \[net\.mindtricks\.tankard:" "$log"; then
        echo "ok: $(grep -E "Tankard\[$pid:[^]]*\] \[net\.mindtricks\.tankard:" "$log" | head -1 | sed -E 's/^.*\] \[net\.mindtricks\.tankard:/[/')"
    else
        echo "pid $pid logged nothing in net.mindtricks.tankard"
        return 1
    fi
}

# no_instance_yield LOGSTREAM: no copy yielded to or replaced another (a
# relaunch that met a still-running old copy).
no_instance_yield() {
    local log=$1
    [ -f "$log" ] || { echo "no $log"; return 1; }
    if grep -Eq '(yield\(to:|replaceStale\()' "$log"; then
        echo "instance guard fired: $(grep -E '(yield\(to:|replaceStale\()' "$log" | head -1 | cut -c1-200)"
        return 1
    fi
    echo "ok"
}

# version_lt A B: semver A < B (pre-release before release).
version_lt() {
    /usr/bin/python3 -I - "$1" "$2" <<'PY'
import sys
def key(v):
    core, _, pre = v.partition("-")
    nums = tuple(int(x) for x in core.split("."))
    if not pre:
        return (nums, 1, ())
    return (nums, 0, tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split(".")))
try:
    sys.exit(0 if key(sys.argv[1]) < key(sys.argv[2]) else 1)
except ValueError:
    sys.exit(2)
PY
}

# real_defaults_diff BEFORE AFTER IGNORE_FRAMES: every key of the settings
# domain that differs between two plists (BEFORE may be "" for a domain
# that didn't exist), one line each: "added|removed|changed KEY". With
# IGNORE_FRAMES=1, keys matching exactly `NSWindow Frame *` are labelled
# "(ignored: known 0.8.3-as-old artifact)" and don't count. True when
# nothing counted differs.
real_defaults_diff() {
    /usr/bin/python3 -I - "$1" "$2" "$3" <<'PY'
import fnmatch, plistlib, sys
def load(p):
    if not p:
        return {}
    with open(p, "rb") as f:
        return plistlib.load(f)
before, after, ignore = load(sys.argv[1]), load(sys.argv[2]), sys.argv[3] == "1"
import datetime
def same(a, b):
    # Dates compared to the second: an XML plist keeps whole seconds only.
    if isinstance(a, datetime.datetime) and isinstance(b, datetime.datetime):
        return a.replace(microsecond=0) == b.replace(microsecond=0)
    return a == b
bad = 0
for k in sorted(set(before) | set(after)):
    if k in before and k in after and same(before[k], after[k]):
        continue
    kind = "added" if k not in before else "removed" if k not in after else "changed"
    if ignore and fnmatch.fnmatchcase(k, "NSWindow Frame *"):
        print("%s %s (ignored: known 0.8.3-as-old artifact)" % (kind, k))
    else:
        print("%s %s" % (kind, k)); bad += 1
sys.exit(1 if bad else 0)
PY
}

# MARK: self-test (fixtures shaped like the rc2 run's real files)
self_test() {
    local t fails=0
    t=$(mktemp -d -t tankard-selfupd-checks) || return 1
    expect() { # want(0|1) label command...
        local want=$1 label=$2; shift 2
        local out rc
        out=$("$@" 2>&1); rc=$?
        [ $rc -ne 0 ] && rc=1
        if [ "$rc" = "$want" ]; then echo "ok   $label ($out)"; else echo "FAIL $label: rc $rc, wanted $want ($out)"; fails=$((fails + 1)); fi
    }
    cat > "$t/results.jsonl" <<'J'
{"assertions":[],"index":1,"line":1,"ok":true,"skipped":false,"step":"expect-ready"}
{"assertions":[],"error":"check failed: sheet history","index":2,"line":2,"ok":false,"skipped":false,"step":"open-sheet history"}
{"assertions":[],"index":3,"line":3,"ok":false,"skipped":true,"step":"sleep 30"}
not json
{"assertions":[],"index":5,"line":5,"ok":true,"skipped":false,"step":"open-sheet history"}
J
    expect 0 "passed step" step_result "$t/results.jsonl" 1 "expect-ready"
    expect 1 "failed step" step_result "$t/results.jsonl" 2 "open-sheet history"
    expect 1 "skipped step" step_result "$t/results.jsonl" 3 "sleep 30"
    expect 1 "missing step (the rc2 C case)" step_result "$t/results.jsonl" 4 "open-sheet history"
    expect 1 "other step at that index" step_result "$t/results.jsonl" 1 "open-sheet history"
    expect 0 "passed step 5" step_result "$t/results.jsonl" 5 "open-sheet history"
    expect 1 "no results file" step_result "$t/none.jsonl" 1 "expect-ready"

    cat > "$t/app.log" <<'A'
2026-11-17 16:46:33.315 Tankard[40919:14233415] ApplePersistenceIgnoreState: Existing state will not be touched.
e2e: step 1 (line 1): expect-ready
snapshot: wrote /x/01-expect-ready.png (2200x1360)
e2e:   -> PASS
e2e: step 2 (line 2): check-updates 0.8.4-e2e.1 brew
e2e:   -> FAIL: check failed: Tankard 0.8.4-e2e.1 offered
e2e: step 3 (line 3): upgrade-self 0.8.4-e2e.1
e2e:   -> SKIPPED
e2e: step 5 (line 5): open-sheet history
e2e: step 6 (line 6): relaunch
A
    expect 0 "logged pass" step_logged "$t/app.log" 1 "expect-ready"
    expect 1 "logged fail" step_logged "$t/app.log" 2 "check-updates 0.8.4-e2e.1 brew"
    expect 1 "logged skip" step_logged "$t/app.log" 3 "upgrade-self 0.8.4-e2e.1"
    expect 1 "logged missing" step_logged "$t/app.log" 4 "expect-quiet 5"
    expect 1 "logged no verdict" step_logged "$t/app.log" 5 "open-sheet history"
    expect 1 "logged other step" step_logged "$t/app.log" 1 "open-sheet history"
    expect 1 "step 1 is not step 10" step_logged "$t/app.log" 10 "expect-ready"

    cat > "$t/good.txt" <<'L'
Filtering the log data using "subsystem == "net.mindtricks.tankard""
Timestamp               Ty Process[PID:TID]
2026-11-17 17:25:12.385 Df Tankard[64559:da834c] [net.mindtricks.tankard:notifications] authorization at launch: notDetermined
2026-11-17 17:25:35.405 Df Tankard[64559:da834c] [net.mindtricks.tankard:relaunch] relaunch: helper 65842 waits for pid 64559
2026-11-17 17:25:36.909 Df Tankard[64559:da834c] [net.mindtricks.tankard:relaunch] relaunch: terminate pid 64559
2026-11-17 17:25:38.101 Df Tankard[65875:db0001] [net.mindtricks.tankard:notifications] authorization at launch: notDetermined
L
    # rc2's real "PASS": the old pid relaunched, the new pid never logged.
    head -5 "$t/good.txt" > "$t/silent.txt"
    { head -4 "$t/good.txt"; tail -1 "$t/good.txt"; } > "$t/noterm.txt"
    { cat "$t/good.txt"; echo '2026-11-17 17:25:48.000 E  Tankard[64559:da834c] [net.mindtricks.tankard:relaunch] relaunch: pid 64559 is still running after two terminate attempts; the helper opens nothing'; } > "$t/gaveup.txt"
    { cat "$t/good.txt"; echo '2026-11-17 17:25:48.000 Df logger[1:2] relaunch: Tankard (pid 64559) still running, not reopening'; } > "$t/helpergaveup.txt"
    { cat "$t/good.txt"; echo '2026-11-17 17:25:39.000 Df Tankard[65999:dd] [net.mindtricks.tankard:instance] pid 65999: others 65875 launched ?; executable written ?; yield(to: 65875)'; } > "$t/yield.txt"
    mkdir -p "$t/ph/relaunched"
    echo '{"index":1}' > "$t/ph/results.jsonl"
    : > "$t/ph/relaunched/steps.txt"
    echo '{"failed":0,"failures":[],"passed":0,"script":"steps.txt","skipped":0}' > "$t/ph/relaunched/summary.json"
    expect 0 "relaunched copy idle" relaunched_idle "$t/ph"
    cp -R "$t/ph" "$t/ph2"; : > "$t/ph2/results.jsonl"
    expect 1 "results.jsonl recreated (0.8.3)" relaunched_idle "$t/ph2"
    cp -R "$t/ph" "$t/ph3"; rm -rf "$t/ph3/relaunched"
    expect 1 "no relaunched dir" relaunched_idle "$t/ph3"
    cp -R "$t/ph" "$t/ph4"; echo '{"failed":0,"passed":5,"skipped":0}' > "$t/ph4/relaunched/summary.json"
    expect 1 "relaunched copy ran steps" relaunched_idle "$t/ph4"
    cp -R "$t/ph" "$t/ph5"; rm "$t/ph5/relaunched/summary.json"
    expect 1 "relaunched copy never ran" relaunched_idle "$t/ph5"
    expect 0 "relaunch logged" relaunch_logged "$t/good.txt" 64559
    expect 1 "relaunch for another pid" relaunch_logged "$t/good.txt" 6455
    expect 1 "no terminate line" relaunch_logged "$t/noterm.txt" 64559
    expect 1 "app gave up" relaunch_logged "$t/gaveup.txt" 64559
    expect 1 "helper gave up" relaunch_logged "$t/helpergaveup.txt" 64559
    expect 0 "new pid ran Tankard code" ran_tankard_code "$t/good.txt" 65875
    expect 1 "new pid silent (the rc2 A case)" ran_tankard_code "$t/silent.txt" 65875
    expect 1 "pid prefix only" ran_tankard_code "$t/good.txt" 6587
    expect 1 "no pid" ran_tankard_code "$t/good.txt" ""
    expect 0 "no yield" no_instance_yield "$t/good.txt"
    expect 1 "a yield" no_instance_yield "$t/yield.txt"
    expect 0 "0.8.3 < 0.8.4" version_lt 0.8.3 0.8.4
    expect 0 "0.8.4-e2e.0 < 0.8.4" version_lt 0.8.4-e2e.0 0.8.4
    expect 1 "0.8.4 not < 0.8.4" version_lt 0.8.4 0.8.4
    expect 1 "0.8.10 not < 0.8.4" version_lt 0.8.10 0.8.4
    mk() { /usr/bin/python3 -I -c 'import plistlib,sys,json; plistlib.dump(json.loads(sys.argv[2]), open(sys.argv[1],"wb"))' "$@"; }
    mk "$t/p0.plist" '{"SUAutomatic": true, "theme": "tankard"}'
    mk "$t/p1.plist" '{"SUAutomatic": true, "theme": "tankard", "NSWindow Frame main-AppWindow-1": "1 2 3 4"}'
    mk "$t/p2.plist" '{"SUAutomatic": true, "theme": "dark", "NSWindow Frame main-AppWindow-1": "1 2 3 4"}'
    mk "$t/p3.plist" '{"SUAutomatic": true, "theme": "tankard", "NSWindow Framed": "x"}'
    expect 0 "same content" real_defaults_diff "$t/p0.plist" "$t/p0.plist" 0
    expect 0 "frame only, ignored" real_defaults_diff "$t/p0.plist" "$t/p1.plist" 1
    expect 1 "frame only, not ignored" real_defaults_diff "$t/p0.plist" "$t/p1.plist" 0
    expect 1 "frame + another key, ignored" real_defaults_diff "$t/p0.plist" "$t/p2.plist" 1
    expect 1 "lookalike key, ignored" real_defaults_diff "$t/p0.plist" "$t/p3.plist" 1
    mk "$t/p4.plist" '{"NSWindow Frame main-AppWindow-1": "1 2 3 4"}'
    expect 0 "domain created with only a frame, ignored" real_defaults_diff "" "$t/p4.plist" 1
    # rc3: a binary backup's sub-second date against an XML copy of the same domain.
    /usr/bin/python3 -I -c 'import plistlib,datetime,sys; d=datetime.datetime(2026,11,17,22,47,25,914896); plistlib.dump({"lastBrewUpdate": d}, open(sys.argv[1],"wb"), fmt=plistlib.FMT_BINARY); plistlib.dump({"lastBrewUpdate": d.replace(microsecond=0)}, open(sys.argv[2],"wb"), fmt=plistlib.FMT_XML); plistlib.dump({"lastBrewUpdate": d.replace(second=26)}, open(sys.argv[3],"wb"))' "$t/d0.plist" "$t/d1.plist" "$t/d2.plist"
    expect 0 "same date, binary vs XML precision" real_defaults_diff "$t/d0.plist" "$t/d1.plist" 1
    expect 1 "date really changed" real_defaults_diff "$t/d0.plist" "$t/d2.plist" 1
    expect 1 "domain created with more, ignored" real_defaults_diff "" "$t/p1.plist" 1
    rm -rf "$t"
    echo "self-test: $fails failed"
    [ $fails = 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --self-test) self_test; exit $? ;;
        *) echo "usage: $0 --self-test (otherwise sourced by e2e-selfupdate.sh)" >&2; exit 2 ;;
    esac
fi
