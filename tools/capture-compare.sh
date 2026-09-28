#!/usr/bin/env bash
# Compare what every collector prints, before and after a change.
#
#   tools/capture-compare.sh capture TREE OUT   run each collector of TREE in each mode,
#                                               store masked stdout / stderr / rc under OUT
#   tools/capture-compare.sh compare BASE NEW   per-file diffs of two OUTs; exit 1 on any
#
# Modes: help (no args), badarg, --stdout, dl (RUN_DEADLINE=2 CMD_TIMEOUT=1), and
# dash / dash -s / bash -s for apm, sh for collection-server. ONLY=REGEX limits the
# collectors (matched against collectors/<dir>/collect-<name>.sh).
# capture masks versions, timestamps, temp names and timing lines; compare also turns
# digit runs into '#' and squeezes blanks, so live counters and column widths drop out.
# Live host state still differs between runs: capture BASE twice and treat what
# differs base-vs-base as noise. The dl mode flips with host load.
set -u

mask() {
    sed -E -e 's/^(Version: +).*/\1VER/' -e 's/(whatap-[a-z]+ )[0-9]+\.[0-9]+\.[0-9]+/\1VER/g' \
        -e 's/[0-9]{4}-?[0-9]{2}-?[0-9]{2}T?[ ]?[0-9]{2}:?[0-9]{2}:?[0-9]{2}Z?/TS/g' \
        -e 's/ggt\.[A-Za-z0-9]{6}/ggt.X/g' -e 's/rfcap\.[A-Za-z0-9]{6}/rfcap.X/g' \
        -e '/^    (run time|host load at|bounded calls|where the time went)/d' \
        -e '/^ {8,}[0-9]+\.[0-9]s  /d' -e '/^ {8,}-   .* not run \(deadline\)$/d' \
        -e '/^ {8,}[0-9]+ ms  /d' -e '/^ {8,}\([0-9]+ more in this run\)$/d'
}

capture() {
    local tree out run f n p
    tree="$(cd "$1" && pwd)" out="$2"
    mkdir -p "$out"
    run="$(mktemp -d "${TMPDIR:-/tmp}/rfcap.XXXXXX")"
    one() {  # name mode cmd...
        local n="$1" m="$2"; shift 2
        (cd "$run" && timeout 400 "$@" </dev/null >"$run/o" 2>"$run/e"; echo "$?" >"$run/rc")
        mask <"$run/o" >"$out/$n.$m.out"; mask <"$run/e" >"$out/$n.$m.err"; cp "$run/rc" "$out/$n.$m.rc"
    }
    for p in "$tree"/collectors/*/collect-*.sh "$tree"/collectors/*/*/collect-*.sh; do
        f="${p#"$tree"/}"
        [ -e "$p" ] && printf '%s\n' "$f" | grep -qE "${ONLY:-.}" || continue
        n="$(basename "$f" .sh)"
        one "$n" help   bash "$p"
        one "$n" badarg bash "$p" --no-such-arg
        one "$n" stdout bash "$p" --stdout
        one "$n" dl     env RUN_DEADLINE=2 CMD_TIMEOUT=1 bash "$p" --stdout
        case "$f" in
            collectors/apm/*)
                one "$n" dash  dash "$p" --stdout
                one "$n" dashs sh -c 'dash -s -- --stdout < "$0"' "$p"
                one "$n" bashs sh -c 'bash -s -- --stdout < "$0"' "$p" ;;
            collectors/collection-server/*)
                one "$n" sh    sh "$p" --stdout ;;
        esac
    done
    rm -rf "$run"
}

compare() {
    local b="$1" n="$2" f g d rc=0
    norm() { sed -E 's/[0-9]+/#/g; s/[ \t]+/ /g' "$1"; }
    for f in "$b"/*; do
        g="$n/$(basename "$f")"
        [ -e "$g" ] || { echo "MISSING $(basename "$f")"; rc=1; continue; }
        d="$(diff <(norm "$f") <(norm "$g"))" || { echo "== $(basename "$f")"; printf '%s\n' "$d" | head -20; rc=1; }
    done
    for g in "$n"/*; do [ -e "$b/$(basename "$g")" ] || { echo "EXTRA $(basename "$g")"; rc=1; }; done
    return $rc
}

case "${1:-}" in
    capture) [ $# -eq 3 ] || { echo "usage: $0 capture TREE OUT" >&2; exit 2; }; capture "$2" "$3" ;;
    compare) [ $# -eq 3 ] || { echo "usage: $0 compare BASE NEW" >&2; exit 2; }; compare "$2" "$3" ;;
    *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
