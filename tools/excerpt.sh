#!/usr/bin/env bash
# Print what a reviewer needs to read for a patch, instead of whole collectors.
#
# Usage:  tools/excerpt.sh [-C TREE] BASE
#   TREE  a git checkout with the change in its working tree or commits (default .)
#   BASE  the ref the change is compared against (e.g. origin/main, a commit)
#
# Output, per changed file:
#   1. the diff (git diff -U3 BASE)
#   2. the full new body of every top-level function a hunk touches
#      (sh: `name() {` ... `}` at column 0; ps1: `function Name {` ... `}`)
#   3. every line in the same file that calls one of those functions
#      (line: text). A synced block's copies in other collectors are checked
#      by tools/sync-shared-block.sh --check, not listed here.
# A hunk outside any function is listed as "top level" with 15 lines around it.
# Read the whole file only when the change needs it (shared blocks, signals,
# control flow across functions); see .claude/agents/README.md "Reading".
set -u
TREE=.
[ "${1-}" = -C ] && { TREE=$2; shift 2; }
[ $# -eq 1 ] || { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
BASE=$1
cd "$TREE" || exit 2

git diff --name-only "$BASE" -- '*.sh' '*.ps1' '*.md' | while IFS= read -r f; do
  printf '\n######## %s\n\n#### diff\n' "$f"
  git diff -U3 "$BASE" -- "$f"
  case $f in *.sh|*.ps1) ;; *) continue ;; esac
  [ -f "$f" ] || { printf '#### (file deleted)\n'; continue; }
  # new-file line numbers of changed hunks
  starts=$(git diff -U0 "$BASE" -- "$f" | sed -n 's/^@@ -[0-9,]* +\([0-9]*\)\(,\([0-9]*\)\)\{0,1\} @@.*/\1 \3/p')
  printf '%s\n' "$starts" | awk -v file="$f" '
    FNR==NR { if ($0 != "") { s[++n]=$1; c[n]=($2==""?1:$2) } ; next }
    { line[FNR]=$0; last=FNR }
    /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { name=$0; sub(/\(.*/,"",name); fs[FNR]=name }
    /^function [A-Za-z_][A-Za-z0-9_-]* *[({]?/ { name=$2; sub(/[({].*/,"",name); fs[FNR]=name }
    END {
      for (i=1;i<=n;i++) {
        hs=s[i]; he=s[i]+(c[i]>0?c[i]-1:0); found=0
        for (l=hs; l>=1; l--) if (l in fs) { found=l; break }
        if (found) {
          # end of that function: single-line def, or next "}" at column 0
          e=found; if (line[found] !~ /\}[ \t]*(#.*)?$/ || line[found] ~ /\{[ \t]*$/) for (e=found+1; e<=last && line[e] !~ /^\}/; e++) ;
          if (hs <= e) { if (!(found in done)) { done[found]=1; printf "#### function %s (%s:%d-%d)\n", fs[found], file, found, e; for (k=found;k<=e;k++) printf "%6d  %s\n", k, line[k]; print fs[found] > "/dev/stderr" } ; continue }
        }
        a=hs-15; if (a<1) a=1; b=he+15; if (b>last) b=last
        printf "#### top level (%s:%d-%d)\n", file, a, b
        for (k=a;k<=b;k++) printf "%6d  %s\n", k, line[k]
      }
    }' - "$f" 2>"${TMPDIR:-/tmp}/excerpt.$$"
  sort -u "${TMPDIR:-/tmp}/excerpt.$$" | while IFS= read -r fn; do
    printf '#### callers of %s\n' "$fn"
    grep -n -w -e "$fn" "$f" \
      | grep -v -E "^[0-9]+:(function +)?$fn *(\(\))? *\{" | head -40
  done
  rm -f "${TMPDIR:-/tmp}/excerpt.$$"
done
