#!/bin/zsh
# Runs the test suite. With full Xcode installed, plain `swift test` works;
# with only the Command Line Tools, the Swift Testing framework lives in a
# non-default location and needs explicit search/runtime paths.
# (Same approach as first-light's Scripts/test.sh.)
set -euo pipefail
cd "$(dirname "$0")/.."

# The tests' UserDefaults suites (Tests/TankardAppModelTests/Support.swift,
# TestDefaults): the test process lists each suite's name in this file, and
# once it has exited the suites are deleted here, `defaults delete` (so
# cfprefsd's view stays consistent) and then the plist, which cfprefsd
# keeps as an empty `{}` file for a deleted domain. Only the names this run
# listed, and only test-shaped ones: never the app's own
# net.mindtricks.tankard, never another, concurrent run's suites.
DEFAULTS_LIST=$(mktemp -t tankard-test-defaults)
export TANKARD_TEST_DEFAULTS_LIST=$DEFAULTS_LIST
cleanup_defaults() {
    local name n=0
    while IFS= read -r name; do
        [[ $name == net.mindtricks.tankard.tests.* || $name == tankard-test-* ]] || continue
        [[ $name == */* ]] && continue
        defaults delete "$name" >/dev/null 2>&1 || true
        rm -f ~/Library/Preferences/"$name".plist
        n=$((n + 1))
    done < "$DEFAULTS_LIST"
    rm -f "$DEFAULTS_LIST"
    [[ $n -gt 0 ]] && echo "test.sh: removed $n test defaults suites"
    # 0.8.5 (bug hunt L10): leftovers from earlier runs that never listed
    # them (before 0.8.4, AppStore(deps:) in a test made its own
    # net.mindtricks.tankard.ephemeral.<UUID>; ~400 had piled up). Only
    # that exact shape, with a full UUID, and only files untouched for an
    # hour, so a run going on at the same time keeps its suites. Never the
    # app's own domain, never the demo's plain net.mindtricks.tankard.ephemeral.
    local f base m=0
    local uuid='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
    for f in ~/Library/Preferences/net.mindtricks.tankard.ephemeral.*.plist(N.mm+60); do
        base=${f:t:r}
        [[ $base =~ "^net\.mindtricks\.tankard\.ephemeral\.${uuid}\$" ]] || continue
        defaults delete "$base" >/dev/null 2>&1 || true
        rm -f "$f"
        m=$((m + 1))
    done
    [[ $m -gt 0 ]] && echo "test.sh: removed $m leftover test defaults suites from earlier runs"
    return 0
}
trap cleanup_defaults EXIT

if xcode-select -p 2>/dev/null | grep -q "CommandLineTools"; then
    FWK=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
    # The swift-testing macro plugin isn't on the default plugin path under the CLT,
    # so a clean build fails with "plugin for module 'TestingMacros' not found".
    PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
    swift test \
        -Xswiftc -F"$FWK" \
        -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
        -Xlinker -F"$FWK" \
        -Xlinker -rpath -Xlinker "$FWK" \
        -Xlinker -rpath -Xlinker "$LIB" \
        "$@"
else
    swift test "$@"
fi
