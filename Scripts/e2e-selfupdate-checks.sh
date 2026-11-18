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
