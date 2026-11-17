#!/bin/bash
# Prints one version's section of CHANGELOG.md (the lines between its
# "## [X.Y.Z]" heading and the next "## [" heading or the link list),
# without the heading. Exits 1 when the section is missing or empty, so a
# release never ships without notes.
#
#   Scripts/changelog-section.sh 0.3.0 [CHANGELOG.md]
#   Scripts/changelog-section.sh v0.3.0          (a leading "v" is dropped)
#   Scripts/changelog-section.sh --self-test     (checks the extraction)
set -euo pipefail

extract() { # version file
    awk -v v="$1" '
        BEGIN { want = "## [" v "]" }
        /^## \[/ { if (on) exit; if (index($0, want) == 1) { on = 1; next } }
        /^\[[^]]+\]: / { if (on) exit }
        on { print }
    ' "$2" | awk 'NF { blank = 0; started = 1 } !NF { blank++ } started && (NF || blank == 1) { buf = buf $0 "\n" } END { sub(/\n+$/, "", buf); if (buf != "") print buf }'
}

if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/c.md" <<'EOF'
# Changelog

## [1.1.0]

### Added
- two
- [link](https://x)

## [1.0.0]

- one

## [0.9.0]

[1.1.0]: https://example/1.1.0
EOF
    fail=0
    check() { if [ "$1" != "$2" ]; then echo "FAIL: $3: got [$1] want [$2]" >&2; fail=1; fi; }
    check "$(extract 1.1.0 "$tmp/c.md")" $'### Added\n- two\n- [link](https://x)' "middle section"
    check "$(extract 1.0.0 "$tmp/c.md")" "- one" "next section"
    check "$(extract 0.9.0 "$tmp/c.md")" "" "empty section stops at the link list"
    check "$(extract 2.0.0 "$tmp/c.md")" "" "missing section"
    check "$(extract 1.0 "$tmp/c.md")" "" "no prefix match"
    if "$0" 2.0.0 "$tmp/c.md" >/dev/null 2>&1; then echo "FAIL: missing section exits 0" >&2; fail=1; fi
    here=$(cd "$(dirname "$0")/.." && pwd)
    for v in $(grep -o '^## \[[0-9.]*\]' "$here/CHANGELOG.md" | tr -d '#[] '); do
        [ -n "$(extract "$v" "$here/CHANGELOG.md")" ] || { echo "FAIL: CHANGELOG.md section $v is empty" >&2; fail=1; }
    done
    [ $fail = 0 ] && echo "changelog-section: self-test passed"
    exit $fail
fi

version=${1:?usage: changelog-section.sh X.Y.Z [CHANGELOG.md]}
version=${version#v}
file=${2:-$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md}
out=$(extract "$version" "$file")
if [ -z "$out" ]; then
    echo "changelog-section: no notes for $version in $file (add a '## [$version]' section)" >&2
    exit 1
fi
printf '%s\n' "$out"
