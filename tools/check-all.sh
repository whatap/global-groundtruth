#!/usr/bin/env bash
# Run the fixed check list on changed files and print a short summary.
#
# Usage:  tools/check-all.sh [-C TREE] [--framework] [--log DIR] BASE
#   TREE         a git checkout with the change (default .)
#   BASE         ref to diff against; the changed files are the checked ones
#   --framework  also run tools/test-framework.sh (about 10 minutes)
#   --log DIR    where full outputs go (default: a mktemp dir, printed)
#
# Checks: bash -n; dash -n (collectors/apm/*.sh and templates/*.sh);
# `shellcheck -S warning`; tools/sync-shared-block.sh --check;
# tools/validate.sh per changed collector; tools/test-<token>.sh matching a
# changed collector.
# One line per check (PASS/FAIL), and for a FAIL the first 20 lines of its
# output. Full outputs stay in the log dir: read them only for a FAIL.
# Exit status: the number of failed checks (0 = all passed).
set -u
TREE=. FW=0 LOG=
while [ $# -gt 1 ]; do
  case $1 in
    -C) TREE=$2; shift 2 ;;
    --framework) FW=1; shift ;;
    --log) LOG=$2; shift 2 ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
BASE=$1
cd "$TREE" || exit 2
[ -n "$LOG" ] || LOG=$(mktemp -d "${TMPDIR:-/tmp}/check-all.XXXXXX")
mkdir -p "$LOG"
FAILS=0 N=0

run() {  # run NAME CMD...
  local name=$1 out rc; shift
  N=$((N + 1)); out="$LOG/$N.log"
  "$@" >"$out" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then
    printf 'PASS  %s\n' "$name"
  else
    FAILS=$((FAILS + 1))
    printf 'FAIL  %s  (exit %s, full: %s)\n' "$name" "$rc" "$out"
    head -20 "$out" | sed 's/^/      /'
  fi
}

mapfile -t FILES < <(git diff --name-only "$BASE" -- '*.sh' '*.ps1' | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done)
printf 'tree %s, base %s, %d changed script(s), logs %s\n' "$PWD" "$BASE" "${#FILES[@]}" "$LOG"

for f in "${FILES[@]}"; do
  case $f in *.sh) ;; *) continue ;; esac
  run "bash -n $f" bash -n "$f"
  if case $f in collectors/apm/*|templates/*) true ;; *) false ;; esac; then
    run "dash -n $f" dash -n "$f"
  fi
  run "shellcheck $f" shellcheck -S warning "$f"
done
run "sync-shared-block --check" tools/sync-shared-block.sh --check

TOKENS=
for f in "${FILES[@]}"; do
  case $f in collectors/*/collect-*)
    run "validate $f" tools/validate.sh "$f"
    t=${f##*/collect-}; t=${t%.*}
    case " $TOKENS " in *" $t "*) ;; *) TOKENS="$TOKENS $t" ;; esac ;;
  esac
done
for t in $TOKENS; do
  [ -x "tools/test-$t.sh" ] && run "test-$t" "tools/test-$t.sh"
done
[ "$FW" = 1 ] && run "test-framework" timeout 1800 tools/test-framework.sh

printf '%d check(s), %d failed\n' "$N" "$FAILS"
exit "$FAILS"
