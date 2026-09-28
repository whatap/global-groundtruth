# tools/test-lib.sh — helpers the collector behaviour tests share.
# -----------------------------------------------------------------------------
# Sourced, not run: each tools/test-<collector>.sh sources it by its own
# directory, so a test still runs from any cwd. The caller sets PASS, FAIL and
# SKIP to 0 and `set -o noclobber` before using these.
# -----------------------------------------------------------------------------
# shellcheck shell=bash disable=SC2034  # PASS/FAIL/SKIP are the caller's

# Stubs are written only through stub_write, and stub dirs are copied only
# through stub_clone. A stub dir is a farm of symlinks to the real tools, and a
# `>` onto one of them writes the real tool (as root, /usr/bin/xargs itself).
# noclobber makes any other `>` onto an existing file an error; `>|` is used
# only on files this suite created as regular files.
stub_write() { rm -f "$1" && cat > "$1" && chmod +x "$1"; }   # content on stdin
stub_clone() {                                                # SRC DST: links stay links
    local f; mkdir -p "$2"
    for f in "$1"/*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        if [ -L "$f" ]; then ln -s "$(readlink "$f")" "$2/${f##*/}"
        else rm -f "$2/${f##*/}"; cp "$f" "$2/${f##*/}"; fi
    done
}

# ok NAME / bad NAME EXPECTED ACTUAL / skip NAME -> count and print one result;
# chk NAME EXPECTED ACTUAL, has NAME TEXT NEEDLE, hasnt NAME TEXT NEEDLE -> test
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '  ~ not checked: %s\n' "$1"; }
chk()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has()  { printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || bad "$1" "contains: $3" "absent"; }
hasnt(){ printf '%s' "$2" | grep -qF -- "$3" && bad "$1" "absent: $3" "present" || ok "$1"; }

# status_adds_up REPORT NAME -> the Collection status goals line adds up
status_adds_up() {
  local line d g n b
  line="$(printf '%s' "$1" | grep -o 'goals: .*')"
  [ -n "$line" ] || { bad "$2" "a goals: line" "none"; return; }
  d="$(echo "$line" | sed 's/goals: \([0-9]*\).*/\1/')"
  g="$(echo "$line" | sed 's/.*declared, \([0-9]*\) obtained.*/\1/')"
  n="$(echo "$line" | sed 's/.*obtained, \([0-9]*\) not applicable.*/\1/')"
  b="$(echo "$line" | sed 's/.*here, \([0-9]*\) blocked.*/\1/')"
  chk "$2 ($line)" "$d" "$((g + n + b))"
}
