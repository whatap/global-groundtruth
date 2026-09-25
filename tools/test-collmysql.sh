#!/usr/bin/env bash
#
# test-collmysql.sh — behaviour tests for the collection-server MySQL collector.
# -----------------------------------------------------------------------------
# Usage:  tools/test-collmysql.sh [path/to/collect-collmysql.sh]
#
# validate.sh checks the SHAPE of a collector's source. This checks what this
# one DOES, and most of it is about one decision: whether the run reaches root.
# Nearly every section of this report comes from SQL, a packaged MySQL lets root
# in over the unix socket, and root is also what reads the binary log directory,
# so the elevation carries the collector. The ways it can fall short are the
# thing worth pinning down.
#
# The sudo cases run against a stub `sudo` on PATH rather than the real one, so
# they behave the same on every machine and need no privilege. The stub answers
# the way a host with a password-protected sudo does: `-n` cannot run, `-v` asks
# and does not authenticate. A separate group uses real passwordless sudo and
# says so when it cannot run, rather than passing quietly.
#
# Build stub PATHs with `type -P`, never `command -v`: in an interactive shell
# `command -v grep` can answer with an alias, and a symlink built from that
# answer points at itself (tools/test-collserver.sh, 2026-09-24).
# -----------------------------------------------------------------------------

set -u
C="${1:-$(cd "$(dirname "$0")/.." && pwd)/collectors/collection-server/collect-collmysql.sh}"
[ -f "$C" ] || { echo "not found: $C" >&2; exit 2; }
C="$(cd "$(dirname "$C")" && pwd)/$(basename "$C")"
ROOT="$(mktemp -d)"; PASS=0; FAIL=0; SKIP=0
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '  ~ not checked: %s\n' "$1"; }
chk()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has()  { printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || bad "$1" "contains: $3" "absent"; }
hasnt(){ printf '%s' "$2" | grep -qF -- "$3" && bad "$1" "absent: $3" "present" || ok "$1"; }

S="$ROOT/stub"; mkdir -p "$S"
for c in cat ls date wc tail head sed awk grep tr id hostname find sort mktemp cp rm mkdir chmod \
         uname stat df free ps sh bash dirname basename sleep cut uniq expr touch env timeout; do
    p="$(type -P "$c" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$S/$c"
done
mkstub_sudo() {
    cat > "$S/sudo" <<'EOF'
#!/bin/sh
# A sudo that refuses, in sudo's own words. SUDO_STATE picks which refusal.
# The wording is copied from a real sudo 1.9.13 on debian bookworm, measured
# 2026-09-24, because the collector classifies on exactly these strings.
#
# Note what -n answers: the same line for both states. That is the reason the
# collector reads -v instead, and a test that stubbed only -n would not notice
# if it went back.
[ -n "${STUBLOG:-}" ] && echo "sudo $*" >> "$STUBLOG"
case "$1" in
    -n) echo "sudo: a password is required" >&2; exit 1 ;;
    -v) case "${SUDO_STATE:-notty}" in
            nosudoers) echo "Sorry, user tester may not run sudo on testhost." >&2 ;;
            *)         echo "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper" >&2 ;;
        esac
        exit 1 ;;
esac
exit 1
EOF
    chmod +x "$S/sudo"
}
mkstub_sudo
cat > "$S/mysql" <<'EOF'
#!/bin/sh
# MYSQL_FAIL=1 -> every statement is refused. BINLOG_BASE_ANS -> the answer to
# SELECT @@log_bin_basename. Everything else answers 1, which is all the
# sections under test read.
if [ -n "${MYSQL_FAIL:-}" ]; then
    echo "ERROR 1045 (28000): Access denied for user 'x'@'localhost' (using password: YES)" >&2
    exit 1
fi
for a in "$@"; do q="$a"; done
case "$q" in
    *log_bin_basename*) [ -n "${BINLOG_BASE_ANS:-}" ] && echo "$BINLOG_BASE_ANS"; exit 0 ;;
    *) echo 1; exit 0 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$S/mysqlbinlog"
chmod +x "$S/mysql" "$S/mysqlbinlog"
UID_NOW="$(id -u)"

echo "== 1. the four ways a run stays unelevated, each named for what it is =="
export STUBLOG="$ROOT/sudo.log"; : > "$STUBLOG"
out="$(SUDO_STATE=notty PATH="$S" bash "$C" --stdout </dev/null 2>/dev/null)"
has "no terminal to ask on: the reason names the terminal" "$out" \
    "privilege: not root (uid $UID_NOW): sudo found no terminal to ask for a password on"
has "and sudo was asked anyway, rather than skipped on a test of stdin" \
    "$(cat "$STUBLOG")" "sudo -v"

# The regression that made this file worth writing: 0.6.1 chose between these
# two by testing /dev/tty, so an account sudo does not permit was reported as a
# missing terminal on every run that had none, and the guide then sent the
# operator to `ssh -t`, which that account cannot be helped by.
out="$(SUDO_STATE=nosudoers PATH="$S" bash "$C" --stdout </dev/null 2>/dev/null)"
has "not in sudoers, same absent terminal: the reason names the account" "$out" \
    "privilege: not root (uid $UID_NOW): sudo does not permit this account"

out="$(PATH="$S" bash "$C" --stdout --no-sudo </dev/null 2>/dev/null)"
has "--no-sudo: the reason is the flag" "$out" \
    "privilege: not root (uid $UID_NOW): --no-sudo given"
: > "$STUBLOG"; PATH="$S" bash "$C" --stdout --no-sudo </dev/null >/dev/null 2>&1
chk "--no-sudo: sudo is not invoked at all" "0" "$(wc -l < "$STUBLOG")"

rm -f "$S/sudo"
out="$(PATH="$S" bash "$C" --stdout </dev/null 2>/dev/null)"
has "no sudo on the host: the reason says so" "$out" \
    "privilege: not root (uid $UID_NOW): command not found: sudo"
mkstub_sudo

echo "== 2. the reason reaches the operator, not only the file =="
err="$(MYSQL_FAIL=1 PATH="$S" bash "$C" --stdout --mysql-args "-u x" </dev/null 2>&1 >/dev/null)"
has "the blocked line carries the refusal" "$err" "mysql login"
has "and names it" "$err" "access denied"
has "and the privilege that would have answered it, in sudo's words" "$err" \
    "(not elevated: sudo found no terminal to ask for a password on)"
has "and the run is INCOMPLETE" "$err" "status: INCOMPLETE"
out="$(MYSQL_FAIL=1 PATH="$S" bash "$C" --stdout --mysql-args "-u x" </dev/null 2>/dev/null)"
hasnt "the notices stay off stdout, which is the report" "$out" "status: INCOMPLETE —"
has "the report carries the same roll-up" "$out" "status: INCOMPLETE"

echo "== 3. the roll-up adds up and the report is whole =="
line="$(printf '%s' "$out" | grep -o 'goals: .*')"
if [ -n "$line" ]; then
    d="$(echo "$line" | sed 's/goals: \([0-9]*\).*/\1/')"
    g="$(echo "$line" | sed 's/.*declared, \([0-9]*\) obtained.*/\1/')"
    n="$(echo "$line" | sed 's/.*obtained, \([0-9]*\) not applicable.*/\1/')"
    b="$(echo "$line" | sed 's/.*here, \([0-9]*\) blocked.*/\1/')"
    chk "obtained + not applicable + blocked = declared" "$d" "$((g + n + b))"
else bad "a goals: line" "one" "none"; fi
has "the report reaches its footer" "$out" "==== END OF COLLECTION"
has "section 0 states the privilege" "$out" "privilege:"

echo "== 4. the binary log reason separates the two questions =="
out="$(BINLOG_BASE_ANS='' PATH="$S" bash "$C" --stdout --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
has "no path from the server: not resolved" "$out" "binary log directory not resolved"
D="$ROOT/binlogs"; mkdir -p "$D"; : > "$D/mysql-bin.000001"
if [ "$UID_NOW" != 0 ]; then
    chmod 000 "$D"
    out="$(BINLOG_BASE_ANS="$D/mysql-bin" PATH="$S" bash "$C" --stdout --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
    has "a path this uid cannot read: not readable" "$out" "not readable by uid $UID_NOW"
    err="$(BINLOG_BASE_ANS="$D/mysql-bin" PATH="$S" bash "$C" --stdout --binlog --mysql-args "-u x" </dev/null 2>&1 >/dev/null)"
    has "and the blocked line says why the run is not root" "$err" "(not elevated:"
    chmod 755 "$D"
else skip "the unreadable-directory case (this account is root, which reads it)"; fi

echo "== 5. under real sudo: the elevation and what it leaves behind =="
if sudo -n true 2>/dev/null; then
    out="$(bash "$C" --stdout </dev/null 2>/dev/null)"
    has "the run reports itself as root" "$out" "privilege: root (elevated by sudo from uid $UID_NOW)"
    W="$ROOT/w"; mkdir -p "$W"
    ( cd "$W" && bash "$C" --file </dev/null >/dev/null 2>&1 )
    f="$(ls "$W"/whatap-collmysql-*.txt 2>/dev/null | head -1)"
    if [ -n "$f" ]; then
        chk "the report comes back to the caller" "$(id -un)" "$(stat -c %U "$f")"
    else bad "a report written under sudo" "one .txt" "none"; fi
    sudo rm -rf "$W" 2>/dev/null
else skip "the real-sudo group (needs passwordless sudo)"; fi

echo; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
