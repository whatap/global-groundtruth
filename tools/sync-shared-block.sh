#!/usr/bin/env bash
#
# sync-shared-block.sh — keep the DO-NOT-EDIT blocks identical across collectors.
# -----------------------------------------------------------------------------
# Collectors are deliberately self-contained: a field engineer copies one file to
# a host and runs it (CONTRACT rule 3). That means the shared helper blocks are
# duplicated, once per collector, and duplication rots. This script is the
# antidote: each block has one owner file, and this copies it outward.
#
# Usage:
#   tools/sync-shared-block.sh --check    report drift, change nothing (exit 1 on drift)
#   tools/sync-shared-block.sh --apply    rewrite each collector's blocks from their owners
#
# Two kinds of block:
#   * skeleton blocks: owned by templates/collector-skeleton/collector-skeleton.sh
#     and carried by EVERY collector (the five named in BLOCKS below).
#   * group blocks: owned by templates/groups/<group>.sh and carried only by the
#     collectors the block names. Banner `# ---- <group>: <name> — DO NOT EDIT`,
#     end line `# ---- end <group>: <name>`, and the line right after the banner
#     is `# members: <stem> ...`, where a member is collectors/**/collect-<stem>.sh.
#     The owner file is the only list of the blocks and of their members;
#     nothing here names them. A collector that is not a member but carries the
#     banner is reported STRAY and left unchanged.
#
# A block runs from its banner comment to its end line. Everything between is
# owned by the owner file; an edit made inside a collector is overwritten, which
# is what "DO NOT EDIT" means.
#
# The end is an explicit line, not "the first closing brace after the last
# function". That rule read a one-line `f() { ...; }` as having no end, ran on to
# the next function's brace, and --apply would have deleted the collector code in
# between (found 2026-09-25).
#
# A collector that lacks a block entirely is reported MISSING; --apply inserts it
# just before the first later block (in owner order) the collector carries, so a
# new shared block reaches every collector in one run. A group block with no
# later one in the collector goes after the last earlier one it carries, or
# after the skeleton's last block (group helpers come after the skeleton's).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKELETON="$ROOT/templates/collector-skeleton/collector-skeleton.sh"
GROUPS_DIR="$ROOT/templates/groups"

# name|banner regex|end regex, in skeleton order
BLOCKS=(
    'emit|^# ---- emit helpers — DO NOT EDIT|^# ---- end emit helpers$'
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

ALL="$(find "$ROOT/collectors" -type f -name 'collect-*.sh' | sort)"
rc=0

# sync_block NAME BANNER ENDRE OWNER NEXT PREV FILE... -> check, or re-copy from
# OWNER, one block in each FILE. NEXT: regex of the later blocks' banners (a
# missing block goes before the first one found); PREV: regex of the earlier
# blocks' end lines (else it goes after the last one found)
sync_block() {
    local name="$1" banner="$2" endre="$3" owner="$4" nextbanner="$5" prevend="$6" sr src f short r at after
    shift 6
    sr="$(block_range "$owner" "$banner" "$endre")" || {
        echo "FAIL  block '$name' not found (once) in ${owner#"$ROOT"/}" >&2; exit 2; }
    src="$(sed -n "${sr% *},${sr#* }p" "$owner")"

    for f in "$@"; do
        [ "$f" = "$owner" ] && continue
        short="${f#"$ROOT"/}"
        if ! r="$(block_range "$f" "$banner" "$endre")"; then
            if grep -qE "$banner|$endre" "$f"; then
                printf 'BROKEN   %-52s (block %s) — banner or end line missing or repeated\n' "$short" "$name"; rc=1; continue
            fi
            at=""
            [ -n "$nextbanner" ] && at="$(grep -nE "$nextbanner" "$f" | head -1 | cut -d: -f1)"
            after=""
            [ -z "$at" ] && [ -n "$prevend" ] && after="$(grep -nE "$prevend" "$f" | tail -1 | cut -d: -f1)"
            if [ "$mode" = --check ] || [ -z "$at$after" ]; then
                printf 'MISSING  %-52s (block %s)\n' "$short" "$name"; rc=1; continue
            fi
            if [ -n "$at" ]; then
                { sed -n "1,$((at - 1))p" "$f"; printf '%s\n\n' "$src"; sed -n "$at,\$p" "$f"; } > "$f.tmp"
            else
                { sed -n "1,${after}p" "$f"; printf '\n%s\n' "$src"; sed -n "$((after + 1)),\$p" "$f"; } > "$f.tmp"
            fi && mv "$f.tmp" "$f" && chmod +x "$f"
            if bash -n "$f" 2>/dev/null; then printf 'inserted %-52s (block %s)\n' "$short" "$name"
            else printf 'BROKEN   %-52s (block %s) — syntax error after insert\n' "$short" "$name"; rc=1; fi
            continue
        fi
        if [ "$(sed -n "${r% *},${r#* }p" "$f")" = "$src" ]; then
            printf 'ok       %-52s (block %s)\n' "$short" "$name"
            continue
        fi
        if [ "$mode" = --check ]; then
            printf 'DRIFT    %-52s (block %s)\n' "$short" "$name"; rc=1; continue
        fi
        { sed -n "1,$((${r% *} - 1))p" "$f"; printf '%s\n' "$src"; sed -n "$((${r#* } + 1)),\$p" "$f"; } > "$f.tmp" \
            && mv "$f.tmp" "$f" && chmod +x "$f"
        if bash -n "$f" 2>/dev/null; then
            printf 'synced   %-52s (block %s)\n' "$short" "$name"
        else
            printf 'BROKEN   %-52s (block %s) — syntax error after sync\n' "$short" "$name"; rc=1
        fi
    done
}

# ---- skeleton blocks: every collector
# shellcheck disable=SC2086  # $ALL: one path per line, no spaces in repo paths
for bi in "${!BLOCKS[@]}"; do
    IFS='|' read -r name banner endre <<EOF
${BLOCKS[$bi]}
EOF
    # the banner of the next block, where a missing block is inserted
    nextbanner=""
    [ $((bi + 1)) -lt ${#BLOCKS[@]} ] && nextbanner="$(printf '%s' "${BLOCKS[$((bi + 1))]}" | cut -d'|' -f2)"
    sync_block "$name" "$banner" "$endre" "$SKELETON" "$nextbanner" "" $ALL
done

# ---- group blocks: the members each block names
for owner in "$GROUPS_DIR"/*.sh; do
    [ -f "$owner" ] || continue
    group="$(basename "$owner" .sh)"
    # block names in owner order; a name is letters, digits, spaces and dashes
    names="$(sed -n "s/^# ---- $group: \([A-Za-z0-9 -]*[A-Za-z0-9]\) — DO NOT EDIT.*/\1/p" "$owner")"
    [ -n "$names" ] || { echo "FAIL  no '# ---- $group: <name> — DO NOT EDIT' banner in ${owner#"$ROOT"/}" >&2; exit 2; }
    gnames=()
    while IFS= read -r name; do gnames+=("$name"); done <<EOF
$names
EOF
    for gi in "${!gnames[@]}"; do
        name="${gnames[$gi]}"
        banner="^# ---- $group: $name — DO NOT EDIT"
        endre="^# ---- end $group: $name\$"
        # where a missing block goes: before a later block, else after an earlier one
        next="" prev='^# ---- end collection completeness$'
        for gj in "${!gnames[@]}"; do
            if [ "$gj" -gt "$gi" ]; then next="${next:+$next|}^# ---- $group: ${gnames[$gj]} — DO NOT EDIT"
            elif [ "$gj" -lt "$gi" ]; then prev="$prev|^# ---- end $group: ${gnames[$gj]}\$"; fi
        done
        s="$(grep -nE "$banner" "$owner" | head -1 | cut -d: -f1)"
        mline="$(sed -n "$((s + 1))p" "$owner")"
        case "${mline#"# members: "}" in *[!\ ]*) ;; *) mline="" ;; esac
        case "$mline" in "# members: "?*) ;; *)
            echo "FAIL  block '$group: $name' in ${owner#"$ROOT"/}: the line after the banner is not '# members: <stem> ...'" >&2
            exit 2 ;;
        esac
        members=() others="$ALL"
        for stem in ${mline#"# members: "}; do
            m="$(printf '%s\n' "$ALL" | grep -E "/collect-$stem\.sh\$")"
            [ -n "$m" ] && [ "$(printf '%s\n' "$m" | wc -l)" -eq 1 ] || {
                echo "FAIL  block '$group: $name': member '$stem' is not exactly one collectors/**/collect-$stem.sh" >&2; exit 2; }
            members+=("$m")
            others="$(printf '%s\n' "$others" | grep -vxF "$m")"
        done
        sync_block "$group: $name" "$banner" "$endre" "$owner" "$next" "$prev" "${members[@]}"
        # a collector outside the member list must not carry the block
        for f in $others; do
            grep -qE "$banner|$endre" "$f" || continue
            printf 'STRAY    %-52s (block %s) — not a member; left unchanged\n' "${f#"$ROOT"/}" "$group: $name"; rc=1
        done
    done
done

exit $rc
