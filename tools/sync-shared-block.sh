#!/usr/bin/env bash
#
# sync-shared-block.sh — keep the DO-NOT-EDIT blocks identical across collectors.
# -----------------------------------------------------------------------------
# Collectors are deliberately self-contained: a field engineer copies one file to
# a host and runs it (CONTRACT rule 3). That means the shared helper blocks are
# duplicated, once per collector, and duplication rots. This script is the
# antidote: the skeleton is the single source, and this copies it outward.
#
# Usage:
#   tools/sync-shared-block.sh --check    report drift, change nothing (exit 1 on drift)
#   tools/sync-shared-block.sh --apply    rewrite each collector's block from the skeleton
#
# A block runs from its banner comment to its end line, both named in BLOCKS
# below. Everything between is owned by the skeleton; an edit made inside a
# collector is overwritten, which is what "DO NOT EDIT" means.
#
# The end is an explicit line, not "the first closing brace after the last
# function". That rule read a one-line `f() { ...; }` as having no end, ran on to
# the next function's brace, and --apply would have deleted the collector code in
# between (found 2026-09-25).
#
# A collector that lacks a block entirely is reported MISSING; --apply inserts it
# just before the block that follows it in the skeleton, so a new shared block
# reaches every collector in one run.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKELETON="$ROOT/templates/collector-skeleton/collector-skeleton.sh"

# name|banner regex|end regex, in skeleton order
BLOCKS=(
    'privilege|^# ---- privilege — DO NOT EDIT|^# ---- end privilege$'
    'boot|^# ---- boot time — DO NOT EDIT|^# ---- end boot time$'
    'run|^# ---- run helpers — DO NOT EDIT|^# ---- end run helpers$'
    'completeness|^# ---- collection completeness — DO NOT EDIT|^# ---- end collection completeness$'
)

# block_range <file> <banner-re> <end-re> -> "START END" on stdout; fails when the
# banner or the end is absent, or either appears more than once
block_range() {
    local f="$1" banner="$2" endre="$3" s e
    [ "$(grep -cE "$banner" "$f")" = 1 ] || return 1
    [ "$(grep -cE "$endre" "$f")" = 1 ] || return 1
    s="$(grep -nE "$banner" "$f" | cut -d: -f1)"
    e="$(grep -nE "$endre" "$f" | cut -d: -f1)"
    [ "$e" -gt "$s" ] || return 1
    printf '%s %s\n' "$s" "$e"
}

mode="${1:---check}"
case "$mode" in --check|--apply) ;; *) echo "usage: $0 --check|--apply" >&2; exit 2 ;; esac

rc=0
for bi in "${!BLOCKS[@]}"; do
    spec="${BLOCKS[$bi]}"
    IFS='|' read -r name banner endre <<EOF
$spec
EOF
    # the banner of the next block, where a missing block is inserted
    nextbanner=""
    [ $((bi + 1)) -lt ${#BLOCKS[@]} ] && nextbanner="$(printf '%s' "${BLOCKS[$((bi + 1))]}" | cut -d'|' -f2)"
    sr="$(block_range "$SKELETON" "$banner" "$endre")" || {
        echo "FAIL  block '$name' not found in the skeleton" >&2; exit 2; }
    # shellcheck disable=SC2086
    set -- $sr
    src="$(sed -n "$1,$2p" "$SKELETON")"

    while IFS= read -r f; do
        [ "$f" = "$SKELETON" ] && continue
        short="${f#"$ROOT"/}"
        if ! r="$(block_range "$f" "$banner" "$endre")"; then
            if grep -qE "$banner|$endre" "$f"; then
                printf 'BROKEN   %-52s (block %s) — banner or end line missing or repeated\n' "$short" "$name"; rc=1; continue
            fi
            at=""
            [ -n "$nextbanner" ] && at="$(grep -nE "$nextbanner" "$f" | head -1 | cut -d: -f1)"
            if [ "$mode" = --check ] || [ -z "$at" ]; then
                printf 'MISSING  %-52s (block %s)\n' "$short" "$name"; rc=1; continue
            fi
            { sed -n "1,$((at - 1))p" "$f"; printf '%s\n\n' "$src"; sed -n "$at,\$p" "$f"; } > "$f.tmp" \
                && mv "$f.tmp" "$f" && chmod +x "$f"
            if bash -n "$f" 2>/dev/null; then printf 'inserted %-52s (block %s)\n' "$short" "$name"
            else printf 'BROKEN   %-52s (block %s) — syntax error after insert\n' "$short" "$name"; rc=1; fi
            continue
        fi
        # shellcheck disable=SC2086
        set -- $r
        if [ "$(sed -n "$1,$2p" "$f")" = "$src" ]; then
            printf 'ok       %-52s (block %s)\n' "$short" "$name"
            continue
        fi
        if [ "$mode" = --check ]; then
            printf 'DRIFT    %-52s (block %s)\n' "$short" "$name"; rc=1; continue
        fi
        { sed -n "1,$(($1 - 1))p" "$f"; printf '%s\n' "$src"; sed -n "$(($2 + 1)),\$p" "$f"; } > "$f.tmp" \
            && mv "$f.tmp" "$f" && chmod +x "$f"
        if bash -n "$f" 2>/dev/null; then
            printf 'synced   %-52s (block %s)\n' "$short" "$name"
        else
            printf 'BROKEN   %-52s (block %s) — syntax error after sync\n' "$short" "$name"; rc=1
        fi
    done < <(find "$ROOT/collectors" -type f -name 'collect-*.sh' | sort)
done

exit $rc
