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
# A block runs from its banner comment to the closing brace of its last function,
# both named in BLOCKS below. Everything between is owned by the skeleton; an
# edit made inside a collector is overwritten, which is what "DO NOT EDIT" means.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKELETON="$ROOT/templates/collector-skeleton/collector-skeleton.sh"

# name|banner regex|last function in the block
BLOCKS=(
    'completeness|^# ---- collection completeness|^emit_status[(][)]'
)

# block_range <file> <banner-re> <lastfn-re> -> "START END" on stdout, empty if absent
block_range() {
    local f="$1" banner="$2" lastfn="$3" s e
    s="$(grep -nE "$banner" "$f" | head -1 | cut -d: -f1)"
    [ -n "$s" ] || return 1
    e="$(awk -v start="$s" -v fn="$lastfn" '
        NR >= start && $0 ~ fn { inside = 1 }
        inside && /^}$/ { print NR; exit }
    ' "$f")"
    [ -n "$e" ] || return 1
    printf '%s %s\n' "$s" "$e"
}

mode="${1:---check}"
case "$mode" in --check|--apply) ;; *) echo "usage: $0 --check|--apply" >&2; exit 2 ;; esac

rc=0
for spec in "${BLOCKS[@]}"; do
    IFS='|' read -r name banner lastfn <<EOF
$spec
EOF
    sr="$(block_range "$SKELETON" "$banner" "$lastfn")" || {
        echo "FAIL  block '$name' not found in the skeleton" >&2; exit 2; }
    # shellcheck disable=SC2086
    set -- $sr
    src="$(sed -n "$1,$2p" "$SKELETON")"

    while IFS= read -r f; do
        [ "$f" = "$SKELETON" ] && continue
        short="${f#"$ROOT"/}"
        r="$(block_range "$f" "$banner" "$lastfn")" || {
            printf 'MISSING  %-52s (block %s)\n' "$short" "$name"; rc=1; continue; }
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
