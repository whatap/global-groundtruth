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
#     A group block may say `# place: end` on the line after `# members:`: it
#     is then the last lines of every member (the apm collectors' main, which
#     runs the collector and must come after every function it calls). --apply
#     inserts a missing one at the end of the file and moves one found
#     elsewhere to the end, one blank line after the text before it; --check
#     reports the latter OUT OF PLACE and says what follows the block (blank
#     lines count too), and a block that ends the file without a final newline
#     NO EOL (--apply adds the newline).
#     The owner file is the only list of the blocks and of their members;
#     nothing here names them. A collector that is not a member but carries the
#     banner is reported STRAY and left unchanged.
#   * PowerShell group blocks: the same, owned by templates/groups/<group>.ps1,
#     for the .ps1 collectors (members collectors/**/collect-<stem>.ps1). The
#     skeleton blocks are shell and reach no .ps1 file; ps1.ps1 carries their
#     port. After a change a .ps1 is parsed by pwsh when pwsh is installed.
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
#
# A skeleton block may also name, as a fourth BLOCKS field, a line it must come
# before: the emit helpers hold `_optval`, which the option loop calls while the
# file is still being read, so they must precede the first `^ARGC=$#` line (the
# start of option parsing, in the skeleton and every collector; the `# ---- CLI
# harness` banner is not in all of them). --apply inserts a missing emit block
# just before that line, not before the privilege block (which follows the
# loop: the collector then died with `_optval: command not found`), and moves
# one found after it there; --check reports the latter OUT OF PLACE. A file
# without such a line is not checked for it.
#
# Collectors are LF. A file with a CRLF line is reported CRLF for each block and
# left unchanged by --apply: its end lines match no end regex, so every block
# would otherwise read BROKEN.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKELETON="$ROOT/templates/collector-skeleton/collector-skeleton.sh"
GROUPS_DIR="$ROOT/templates/groups"

# name|banner regex|end regex[|regex of the line the block must come before],
# in skeleton order
BLOCKS=(
    'emit|^# ---- emit helpers — DO NOT EDIT|^# ---- end emit helpers$|^ARGC=\$#'
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
ALL_PS1="$(find "$ROOT/collectors" -type f -name 'collect-*.ps1' | sort)"
rc=0

# syntax_ok FILE -> the file still parses: bash -n for a .sh, the PowerShell
# parser for a .ps1 (when pwsh is installed; without it the check is skipped)
syntax_ok() {
    case "$1" in
        *.ps1) command -v pwsh >/dev/null 2>&1 || return 0
               PS1_FILE="$1" pwsh -NoProfile -NonInteractive -Command '$e = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile($env:PS1_FILE, [ref]$null, [ref]$e); if ($e.Count) { exit 1 }' </dev/null >/dev/null 2>&1 ;;
        *) bash -n "$1" 2>/dev/null ;;
    esac
}
# trim_tail [FILE] -> FILE (or stdin) without its trailing blank lines, every
# line ending in a newline; a block put at the end then follows one blank line,
# as the owner separates its blocks
trim_tail() { awk '{ l[NR] = $0 } /[^[:space:]]/ { n = NR } END { for (i = 1; i <= n; i++) print l[i] }' "$@"; }
# upto N FILE -> lines 1..N of FILE, nothing when N is 0. `sed -n 1,0p` is not
# empty: GNU sed prints line 1 when the range end is below the start, so a block
# inserted at, or synced from, line 1 doubled that line (found 2026-09-27)
upto() { [ "$1" -gt 0 ] || return 0; sed -n "1,$1p" "$2"; }
# replace FILE: FILE.tmp becomes FILE; a shell collector stays executable
replace() { mv "$1.tmp" "$1" && case "$1" in *.sh) chmod +x "$1" ;; esac; }

# sync_block NAME BANNER ENDRE OWNER NEXT PREV FILE... -> check, or re-copy from
# OWNER, one block in each FILE. NEXT: regex of the later blocks' banners (a
# missing block goes before the first one found); PREV: regex of the earlier
# blocks' end lines (else it goes after the last one found). PLACE_END=1: the
# block must end the file (inserted, or moved, there). PLACE_BEFORE=REGEX: the
# block must end before the first line matching REGEX (inserted, or moved, there)
PLACE_END=0 PLACE_BEFORE=""
sync_block() {
    local name="$1" banner="$2" endre="$3" owner="$4" nextbanner="$5" prevend="$6" sr src f short r at after pb
    shift 6
    sr="$(block_range "$owner" "$banner" "$endre")" || {
        echo "FAIL  block '$name' not found (once) in ${owner#"$ROOT"/}" >&2; exit 2; }
    src="$(sed -n "${sr% *},${sr#* }p" "$owner")"

    for f in "$@"; do
        [ "$f" = "$owner" ] && continue
        short="${f#"$ROOT"/}"
        pb=""
        [ -n "$PLACE_BEFORE" ] && pb="$(grep -nE "$PLACE_BEFORE" "$f" | head -1 | cut -d: -f1)"
        # a CRLF file matches no end line; say so instead of BROKEN, change nothing
        if grep -q "$(printf '\r')\$" "$f"; then
            printf 'CRLF     %-52s (block %s) — convert to LF first\n' "$short" "$name"; rc=1; continue
        fi
        if ! r="$(block_range "$f" "$banner" "$endre")"; then
            if grep -qE "$banner|$endre" "$f"; then
                printf 'BROKEN   %-52s (block %s) — banner or end line missing or repeated\n' "$short" "$name"; rc=1; continue
            fi
            if [ "$PLACE_END" = 1 ] && [ "$mode" = --apply ]; then
                { trim_tail "$f"; printf '\n%s\n' "$src"; } > "$f.tmp" && replace "$f"
                if syntax_ok "$f"; then printf 'inserted %-52s (block %s, at the end)\n' "$short" "$name"
                else printf 'BROKEN   %-52s (block %s) — syntax error after insert\n' "$short" "$name"; rc=1; fi
                continue
            fi
            at=""
            [ -n "$nextbanner" ] && at="$(grep -nE "$nextbanner" "$f" | head -1 | cut -d: -f1)"
            [ -n "$pb" ] && { [ -z "$at" ] || [ "$pb" -lt "$at" ]; } && at="$pb"
            after=""
            [ -z "$at" ] && [ -n "$prevend" ] && after="$(grep -nE "$prevend" "$f" | tail -1 | cut -d: -f1)"
            if [ "$mode" = --check ] || [ -z "$at$after" ]; then
                printf 'MISSING  %-52s (block %s)\n' "$short" "$name"; rc=1; continue
            fi
            if [ -n "$at" ]; then
                { upto $((at - 1)) "$f"; printf '%s\n\n' "$src"; sed -n "$at,\$p" "$f"; } > "$f.tmp"
            else
                { upto "$after" "$f"; printf '\n%s\n' "$src"; sed -n "$((after + 1)),\$p" "$f"; } > "$f.tmp"
            fi && replace "$f"
            if syntax_ok "$f"; then printf 'inserted %-52s (block %s)\n' "$short" "$name"
            else printf 'BROKEN   %-52s (block %s) — syntax error after insert\n' "$short" "$name"; rc=1; fi
            continue
        fi
        # the block starts after the line it must precede: move it before that line,
        # with the blank line that followed it (a PLACE_BEFORE line inside the block
        # is drift, synced below)
        if [ -n "$pb" ] && [ "${r% *}" -gt "$pb" ]; then
            if [ "$mode" = --check ]; then
                printf 'OUT OF PLACE %-48s (block %s) — must come before line %s (the first %s), ends at line %s\n' \
                    "$short" "$name" "$pb" "$PLACE_BEFORE" "${r#* }"; rc=1; continue
            fi
            { upto $((pb - 1)) "$f"; printf '%s\n\n' "$src"
              sed -n "$pb,\$p" "$f" | awk -v s=$((${r% *} - pb + 1)) -v e=$((${r#* } - pb + 1)) \
                  'NR >= s && NR <= e { next } NR == e + 1 && $0 == "" { next } { print }'; } > "$f.tmp" && replace "$f"
            if syntax_ok "$f"; then printf 'moved    %-52s (block %s, before line %s)\n' "$short" "$name" "$pb"
            else printf 'BROKEN   %-52s (block %s) — syntax error after move\n' "$short" "$name"; rc=1; fi
            continue
        fi
        # awk counts a last line that has no newline; wc -l would not
        if [ "$PLACE_END" = 1 ] && [ "${r#* }" -ne "$(awk 'END { print NR }' "$f")" ]; then
            if [ "$mode" = --check ]; then
                after="$(awk -v e="${r#* }" 'NR > e && /[^[:space:]]/ { print "other text at line " NR; t = 1; exit }
                    END { if (!t) print NR - e " blank line(s)" }' "$f")"
                printf 'OUT OF PLACE %-48s (block %s) — not the last lines of the file: followed by %s\n' "$short" "$name" "$after"; rc=1; continue
            fi
            { sed "${r% *},${r#* }d" "$f" | trim_tail; printf '\n%s\n' "$src"; } > "$f.tmp" && replace "$f"
            if syntax_ok "$f"; then printf 'moved    %-52s (block %s, to the end)\n' "$short" "$name"
            else printf 'BROKEN   %-52s (block %s) — syntax error after move\n' "$short" "$name"; rc=1; fi
            continue
        fi
        # the block ends the file, but its last line has no newline
        if [ "$PLACE_END" = 1 ] && [ -n "$(tail -c 1 "$f")" ]; then
            if [ "$mode" = --check ]; then
                printf 'NO EOL   %-52s (block %s) — no newline at the end of the file\n' "$short" "$name"; rc=1; continue
            fi
            printf '\n' >> "$f"
            printf 'fixed    %-52s (block %s, added the newline at the end of the file)\n' "$short" "$name"
        fi
        if [ "$(sed -n "${r% *},${r#* }p" "$f")" = "$src" ]; then
            printf 'ok       %-52s (block %s)\n' "$short" "$name"
            continue
        fi
        if [ "$mode" = --check ]; then
            printf 'DRIFT    %-52s (block %s)\n' "$short" "$name"; rc=1; continue
        fi
        { upto $((${r% *} - 1)) "$f"; printf '%s\n' "$src"; sed -n "$((${r#* } + 1)),\$p" "$f"; } > "$f.tmp" \
            && replace "$f"
        if syntax_ok "$f"; then
            printf 'synced   %-52s (block %s)\n' "$short" "$name"
        else
            printf 'BROKEN   %-52s (block %s) — syntax error after sync\n' "$short" "$name"; rc=1
        fi
    done
}

# ---- skeleton blocks: every collector
# shellcheck disable=SC2086  # $ALL: one path per line, no spaces in repo paths
for bi in "${!BLOCKS[@]}"; do
    IFS='|' read -r name banner endre PLACE_BEFORE <<EOF
${BLOCKS[$bi]}
EOF
    # the banner of the next block, where a missing block is inserted
    nextbanner=""
    [ $((bi + 1)) -lt ${#BLOCKS[@]} ] && nextbanner="$(printf '%s' "${BLOCKS[$((bi + 1))]}" | cut -d'|' -f2)"
    sync_block "$name" "$banner" "$endre" "$SKELETON" "$nextbanner" "" $ALL
done

# ---- group blocks: the members each block names, among the collectors of the
# owner's language (.sh or .ps1)
for owner in "$GROUPS_DIR"/*.sh "$GROUPS_DIR"/*.ps1; do
    [ -f "$owner" ] || continue
    ext="${owner##*.}"
    group="$(basename "$owner" ".$ext")"
    pool="$ALL"; [ "$ext" = ps1 ] && pool="$ALL_PS1"
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
        PLACE_END=0 PLACE_BEFORE=""
        [ "$(sed -n "$((s + 2))p" "$owner")" = "# place: end" ] && PLACE_END=1
        members=() others="$pool"
        for stem in ${mline#"# members: "}; do
            m="$(printf '%s\n' "$pool" | grep -E "/collect-$stem\.$ext\$")"
            [ -n "$m" ] && [ "$(printf '%s\n' "$m" | wc -l)" -eq 1 ] || {
                echo "FAIL  block '$group: $name': member '$stem' is not exactly one collectors/**/collect-$stem.$ext" >&2; exit 2; }
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
