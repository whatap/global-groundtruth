#!/usr/bin/env bash
#
# test-collmysql.sh — behaviour tests for the collection-server MySQL collector.
# -----------------------------------------------------------------------------
# Usage:  tools/test-collmysql.sh [path/to/collect-collmysql.sh]
#
# validate.sh checks the SHAPE of a collector's source. This checks what this
# one DOES: that it never elevates or re-runs itself (a stub sudo on PATH logs
# any call, and the log must stay empty), that no credential reaches a child's
# command line or environment, that every wait ends within the deadline, and
# that a goal root would have obtained says so in its reason. One group uses
# real passwordless sudo, the way an operator runs it, and says so when it
# cannot run, rather than passing quietly.
#
# Build stub PATHs with `type -P`, never `command -v`: in an interactive shell
# `command -v grep` can answer with an alias, and a symlink built from that
# answer points at itself (tools/test-collserver.sh, 2026-09-24).
# -----------------------------------------------------------------------------

set -u
set -o noclobber
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
         uname stat df free ps sh bash dirname basename sleep cut uniq expr touch env timeout rmdir \
         readlink kill stty; do
    p="$(type -P "$c" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$S/$c"
done
# A sudo that must never run: it logs, and the log must stay empty.
export STUBLOG="$ROOT/sudo.log"; : >| "$STUBLOG"
stub_write "$S/sudo" <<'EOF'
#!/bin/sh
[ -n "${STUBLOG:-}" ] && echo "sudo $*" >> "$STUBLOG"
exit 1
EOF
stub_write "$S/mysql" <<'EOF'
#!/bin/sh
# MYSQL_FAIL=1 -> every statement is refused. BINLOG_BASE_ANS -> the answer to
# SELECT @@log_bin_basename. Everything else answers 1, which is all the
# sections under test read. STUBARGS -> each call's arguments, one per line,
# and "pwseen" when an option file it was handed holds the pattern in STUB_PWFILE
# (a file, so the password is in no environment of the run).
# MYSQL_BL_ROWS -> the SHOW BINARY LOGS rows (printf %b: \t and \n), default
# one file of 100 bytes; MYSQL_BL_PARTIAL -> rows printed, then a lost
# connection (exit 1). DATADIR_ANS / BINLOG_INDEX_ANS / PIDFILE_ANS ->
# @@datadir, @@log_bin_index, @@pid_file. SRV_START -> the server's start
# (epoch): Uptime is now minus it. CONN_ANS -> the status Connection line.
# OLD_SERVER -> SHOW BINARY LOG STATUS is a syntax error (before 8.2, MariaDB);
# MASTERLOG -> a line per SHOW MASTER STATUS asked.
# MYSQL_SLEEP -> the login check (status) sleeps that long, so a test can
# look at the process table while the collector is running.
if [ -n "${STUBARGS:-}" ]; then
    { echo "-- call"; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$STUBARGS"
    for a in "$@"; do
        case "$a" in --defaults-extra-file=*|--defaults-file=*)
            f="${a#*=}"; [ -n "${STUB_PWFILE:-}" ] && grep -qF -f "$STUB_PWFILE" "$f" 2>/dev/null && echo pwseen >> "$STUBARGS" ;;
        esac
    done
fi
# ENVSEEN: the password pattern turned up in this child's environment.
[ -n "${STUBARGS:-}" ] && [ -n "${STUB_PWFILE:-}" ] && env | grep -qF -f "$STUB_PWFILE" && echo envseen >> "$STUBARGS"
for a in "$@"; do q="$a"; done
[ -n "${MYSQL_SLEEP:-}" ] && [ "$q" = "status" ] && sleep "$MYSQL_SLEEP"
if [ -n "${MYSQL_FAIL:-}" ]; then
    # MYSQL_ERRMSG replaces the refusal, to test what each error earns.
    echo "${MYSQL_ERRMSG:-ERROR 1045 (28000): Access denied for user 'x'@'localhost' (using password: YES)}" >&2
    exit 1
fi
for a in "$@"; do q="$a"; done
case "$q" in
    "SHOW BINARY LOGS") if [ -n "${MYSQL_BL_DENY:-}" ]; then
            echo "ERROR 1227 (42000) at line 1: Access denied; you need (at least one of) the SUPER, REPLICATION CLIENT privilege(s) for this operation" >&2; exit 1
        fi
        if [ -n "${MYSQL_BL_PARTIAL:-}" ]; then
            printf '%b\n' "$MYSQL_BL_PARTIAL"; echo "ERROR 2013 (HY000): Lost connection to MySQL server during query" >&2; exit 1
        fi
        # MYSQL_BL_ROWS2: the answer from the second call on (a rotation between)
        if [ -n "${MYSQL_BL_ROWS2:-}" ] && [ -n "${BLCOUNT:-}" ]; then
            echo x >> "$BLCOUNT"
            [ "$(wc -l < "$BLCOUNT")" -gt 1 ] && { printf '%b\n' "$MYSQL_BL_ROWS2"; exit 0; }
        fi; printf '%b\n' "${MYSQL_BL_ROWS:-mysql-bin.000001\t100}"; exit 0 ;;
    *log_bin_basename*) [ -n "${BINLOG_BASE_ANS:-}" ] && echo "$BINLOG_BASE_ANS"; exit 0 ;;
    *log_bin_index*) [ -n "${BINLOG_INDEX_ANS:-}" ] && echo "$BINLOG_INDEX_ANS"; exit 0 ;;
    *@@datadir*) echo "${DATADIR_ANS:-1}"; exit 0 ;;
    "SHOW BINARY LOG STATUS\\G") [ -n "${OLD_SERVER:-}" ] && { echo "ERROR 1064 (42000) at line 1: You have an error in your SQL syntax" >&2; exit 1; }
        printf 'File: mysql-bin.000002\nPosition: 7\n'; exit 0 ;;
    "SHOW MASTER STATUS\\G") [ -n "${MASTERLOG:-}" ] && echo "master $*" >> "$MASTERLOG"; printf 'File: mysql-bin.000002\nPosition: 7\n'; exit 0 ;;
    status) printf 'mysql  Ver 8.0\n--------------\nConnection:\t\t%s\n' "${CONN_ANS:-Localhost via UNIX socket}"; exit 0 ;;
    *@@pid_file*) [ -n "${PIDFILE_ANS:-}" ] && echo "$PIDFILE_ANS"; exit 0 ;;
    *"'Uptime'"*) [ -n "${SRV_START:-}" ] && { printf 'Uptime\t%s\n' "$(( $(date +%s) - SRV_START ))"; exit 0; }; echo 1; exit 0 ;;
    *) echo 1; exit 0 ;;
esac
EOF
stub_write "$S/mysqlbinlog" <<'EOF'
#!/bin/sh
# MYSQLBINLOG_MODE: ok (two row events), fail (mysqlbinlog's own words for a
# file it may not open), hang (never returns).
for a in "$@"; do f="$a"; done
case "${MYSQLBINLOG_MODE:-ok}" in
    fail) echo "mysqlbinlog: [ERROR] Could not open log file '$f' (Errcode: 13 - Permission denied)" >&2; exit 1 ;;
    mixed) case "$f" in *.000002) echo "mysqlbinlog: [ERROR] Could not open log file '$f' (Errcode: 13 - Permission denied)" >&2; exit 1 ;; esac ;;
    hang) exec sleep 600 ;;
esac
echo "#260925 10:00:00 server id 1  end_log_pos 100 CRC32 0x0 Query thread_id=1 exec_time=0"
echo "BEGIN"
echo "### INSERT INTO \`acct\`.\`lock\`"
echo "### UPDATE \`acct\`.\`lock\`"
EOF
chmod +x "$S/mysql" "$S/mysqlbinlog"
# A fake /proc (COLLMYSQL_PROC): mkproc PID NSPID STARTSEC ROOT [COMM] makes a
# process whose root is ROOT; the host has been up 1000 s and the server (Uptime
# 1) started at 999 s. Pid 4242, root /, is the server of every test below
# unless a test says otherwise: its pid file holds 4242.
FP="$ROOT/proc"; mkdir -p "$FP"; printf '1000.50 2000.00\n' >| "$FP/uptime"
mkproc() {
    local d="$FP/$1"; mkdir -p "$d"; printf '%s\n' "${5:-mysqld}" >| "$d/comm"
    printf 'Name:\t%s\nNSpid:\t%s\n' "${5:-mysqld}" "$1${2:+	$2}" >| "$d/status"
    printf '%s (%s) S 1 1 1 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 1 0 %s 1 1\n' "$1" "${5:-mysqld}" "$(( $3 * 100 ))" >| "$d/stat"
    rm -rf "$d/root"; ln -s "$4" "$d/root"
}
mkproc 4242 "" 999 /
# nt TEXT: the pid-file times in TEXT as N / T / S, for assertions that must
# not hang on a second (the run's clock and the stub's can tick apart)
nt() { printf '%s' "$1" | sed -E 's/written -?[0-9]+s after/written Ns after/g; s/written at [0-9]+, the server started at [0-9]+/written at T, the server started at S/g'; }
# pidf FILE PID [OFFSET]: a pid file written OFFSET s after the server's start
SRV_START="$(( $(date +%s) - 60 ))"
pidf() { printf '%s\n' "$2" >| "$1"; touch -d "@$(( SRV_START + ${3:-0} ))" "$1"; }
mkdir -p "$ROOT/run"; pidf "$ROOT/run/mysqld.pid" 4242
export COLLMYSQL_PROC="$FP" PIDFILE_ANS="$ROOT/run/mysqld.pid" SRV_START
# this host's addresses: loopback and 10.9.9.9
mkdir -p "$FP/net"; printf 'Local:\n  +-- 0.0.0.0/0 3 0 5\n     |-- 127.0.0.1\n        /32 host LOCAL\n     |-- 10.9.9.9\n        /32 host LOCAL\n     |-- 10.9.9.255\n        /32 link BROADCAST\n' >| "$FP/net/fib_trie"
UID_NOW="$(id -u)"
SETSID="$(type -P setsid 2>/dev/null)"
PY="$(type -P python3 2>/dev/null)"
PW="S3cr3t-$$-pw"; A="$ROOT/args.log"; : >| "$A"; printf '%s\n' "$PW" > "$ROOT/pw.pat"

echo "== 1. the collector never elevates or re-runs itself =="
out="$(PATH="$S" bash "$C" --stdout --mysql-args "-u x" </dev/null 2>/dev/null)"
has "[1] states the privilege it was started with" "$out" "privilege: not root (uid $UID_NOW)"
chk "sudo is never executed" "" "$(cat "$STUBLOG")"
err="$(PATH="$S" bash "$C" --stdout --no-sudo --mysql-args "-u x" </dev/null 2>&1 >/dev/null)"
has "--no-sudo is accepted, and warns that it is no longer needed" "$err" "--no-sudo is no longer needed: the collector never elevates"
for o in "--mysql-pwfd 0" "--mysql-pwsrc terminal" "--mysql-pwfile /etc/hostname" "--run-marker /x/ggt.y/started" "--env CMD_TIMEOUT=5"; do
    # shellcheck disable=SC2086
    chk "$o is gone (unknown, exit 2)" "2" "$(PATH="$S" bash "$C" --stdout $o </dev/null >/dev/null 2>&1; echo $?)"
done
chk "and still no sudo" "" "$(cat "$STUBLOG")"

echo "== 2. the reason reaches the operator, not only the file =="
err="$(MYSQL_FAIL=1 MYSQL_ERRMSG="ERROR 1698 (28000): Access denied for user 'root'@'localhost'" PATH="$S" bash "$C" --stdout --mysql-args "-u root" </dev/null 2>&1 >/dev/null)"
has "the blocked line carries the refusal" "$err" "mysql login — access denied"
has "and the privilege that would have answered it" "$err" "(not elevated: run again with sudo)"
has "and the run is INCOMPLETE" "$err" "status: INCOMPLETE"
out="$(MYSQL_FAIL=1 PATH="$S" bash "$C" --stdout --mysql-args "-u x" </dev/null 2>/dev/null)"
hasnt "the notices stay off stdout, which is the report" "$out" "status: INCOMPLETE —"
hasnt "no how-to-run text in a fact line" "$(printf '%s' "$out" | sed -n '/^\[1\]/,/Collection status/p')" "run again with sudo"

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

echo "== 4. a fact root would read: blocked, with the uid and the owner =="
out="$(BINLOG_BASE_ANS='' PATH="$S" bash "$C" --stdout --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
has "no path from the server: not resolved" "$out" "binary log directory not resolved"
D="$ROOT/binlogs"; mkdir -p "$D"; : >| "$D/mysql-bin.000001"
if [ "$UID_NOW" != 0 ]; then
    chmod 000 "$D"
    out="$(BINLOG_BASE_ANS="$D/mysql-bin" PATH="$S" bash "$C" --stdout --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
    has "the fact says what was read" "$out" "not readable by uid $UID_NOW"
    has "the goal names the uid, the owner and the mode" "$out" "binary log content attribution — run as uid $UID_NOW; $FP/4242/root$D is $(id -un):$(id -gn) 0 and not readable by this uid (not elevated: run again with sudo)"
    chmod 755 "$D"
else skip "the unreadable-directory case (this account is root, which reads it)"; fi

echo "== 5. run with sudo by the operator =="
if sudo -n true 2>/dev/null; then
    out="$(sudo -n bash "$C" --stdout </dev/null 2>/dev/null)"
    has "the run reports itself as root" "$out" "privilege: root (elevated by sudo from uid $UID_NOW)"
    W="$ROOT/w"; mkdir -p "$W"
    ( cd "$W" && sudo -n bash "$C" --file </dev/null >/dev/null 2>&1 )
    f="$(ls "$W"/whatap-collmysql-*.txt 2>/dev/null | head -1)"
    if [ -n "$f" ]; then chk "the report comes back to the caller" "$(id -un)" "$(stat -c %U "$f")"
    else bad "a report written under sudo" "one .txt" "none"; fi
    sudo -n rm -rf "$W" 2>/dev/null
else skip "the real-sudo group (needs passwordless sudo)"; fi

echo "== 6. the binlog decode is obtained only when every file decoded =="
# Each assertion here fails on 0.7.1, which read awk's exit status instead of
# mysqlbinlog's and resolved the goal as obtained before decoding anything.
D2="$ROOT/binlogs2"; mkdir -p "$D2"; : >| "$D2/mysql-bin.000001"; : >| "$D2/mysql-bin.000002"
export MYSQL_BL_ROWS='mysql-bin.000001\t0\nmysql-bin.000002\t0'
out="$(MYSQLBINLOG_MODE=mixed BINLOG_BASE_ANS="$D2/mysql-bin" PATH="$S" bash "$C" --stdout --no-sudo --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
if printf '%s' "$out" | grep -qF "row events (count): 2" \
   && printf '%s' "$out" | grep -qF "binary log content attribution — mysql-bin.000002: mysqlbinlog exit 1, permission denied"; then
    ok "one file decoded, one refused: the decoded one is counted and the refused one blocks the goal"
else bad "one file decoded, one refused: counted, and blocked by the refused one" "both" "$(printf '%s' "$out" | grep -m2 'row events\|binary log content attribution —')"; fi
out="$(MYSQLBINLOG_MODE=fail BINLOG_BASE_ANS="$D2/mysql-bin" PATH="$S" bash "$C" --stdout --no-sudo --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
has "every file refused: INCOMPLETE" "$out" "status: INCOMPLETE"
hasnt "and not obtained" "$out" "obtained: mysql login, host-side facts (process, sockets, disk), binary log content attribution"
t0=$(date +%s)
out="$(MYSQLBINLOG_MODE=hang BINLOG_TIMEOUT=2 BINLOG_BASE_ANS="$D2/mysql-bin" PATH="$S" bash "$C" --stdout --no-sudo --binlog=1 --mysql-args "-u x" </dev/null 2>/dev/null)"
t1=$(date +%s)
has "a decode at its cap is partial and blocked" "$out" "decode stopped at the 2s cap (partial)"
[ $((t1 - t0)) -le 30 ] && ok "and the cap binds ($((t1 - t0))s)" || bad "the cap binds" "<= 30s" "$((t1 - t0))s"
out="$(BINLOG_BASE_ANS=NULL PATH="$S" bash "$C" --stdout --no-sudo --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
has "a NULL basename is unresolved, not the cwd" "$out" "binary log directory not resolved: @@log_bin_basename is NULL"
hasnt "and nothing is decoded" "$out" "decoding the"
out="$(MYSQL_FAIL=1 PATH="$S" bash "$C" --stdout --no-sudo --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
has "no login: the basename was not queried, and says so" "$out" "binlog directory: n/a (not queried: access denied)"
unset MYSQL_BL_ROWS

# scan_procs FIELD PATFILE -> pids of this account whose /proc/<pid>/FIELD
# (cmdline or environ) holds the pattern. The pattern comes from a file: a grep
# given the password as an argument would itself be a process carrying it.
scan_procs() {
    local f hits=""
    for f in /proc/[0-9]*/"$1"; do
        { tr '\0' '\n' < "$f"; } 2>/dev/null | grep -qF -f "$2" && hits="$hits ${f#/proc/}"
    done
    printf '%s' "$hits"
}

echo "== 7. no credential on a child's command line or in its environment =="
for spell in "-p$PW" "-Bp$PW" "--password=$PW" "--loose_password=$PW" "--skip-loose-password=$PW" "--skip-password=$PW" "--pass=$PW"; do
    : >| "$A"
    err="$(STUBARGS="$A" PATH="$S" bash "$C" --stdout --mysql-args "-u x $spell" </dev/null 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" = 2 ] && printf '%s' "$err" | grep -qF "is refused: no credential goes on a command line" && [ ! -s "$A" ] \
       && ! printf '%s' "$err" | grep -qF -f "$ROOT/pw.pat"; then
        ok "${spell%%"$PW"*}SECRET in --mysql-args: exit 2, no child ever started, the value not repeated"
    else bad "${spell%%"$PW"*}SECRET in --mysql-args: exit 2 before any child" "rc 2, no stub call" "rc $rc, $(wc -l < "$A") stub lines"; fi
done
: >| "$A"
MYSQL_PWD="$PW" STUBARGS="$A" STUB_PWFILE="$ROOT/pw.pat" PATH="$S" bash "$C" --stdout --mysql-args "-u x" </dev/null >"$ROOT/pwe.out" 2>/dev/null
has "MYSQL_PWD reaches the client in the option file" "$(cat "$A")" "pwseen"
hasnt "and in no child's environment" "$(cat "$A")" "envseen"
hasnt "and on no child's command line" "$(grep -vx 'pwseen\|envseen' "$A")" "$PW"
has "the report names the source, not the value" "$(cat "$ROOT/pwe.out")" "password: from MYSQL_PWD, handed to the client in a mode-600 option file"
hasnt "and never prints the value" "$(cat "$ROOT/pwe.out")" "$PW"
err="$(MYSQL_PWD="$(printf 'a\nb')" PATH="$S" bash "$C" --stdout --mysql-args "-u x" </dev/null 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$err" | grep -qF "MYSQL_PWD holds a newline" \
    && ok "MYSQL_PWD with a newline is refused, saying why" || bad "MYSQL_PWD with a newline is refused" "exit 2 + reason" "exit $rc"
DX="$ROOT/extra.cnf"; printf '[client]\nuser=x\n' > "$DX"; : >| "$A"
MYSQL_PWD="$PW" STUBARGS="$A" STUB_PWFILE="$ROOT/pw.pat" PATH="$S" bash "$C" --stdout --defaults-extra-file "$DX" </dev/null >/dev/null 2>&1
if grep -qx pwseen "$A" && grep -q -- '--defaults-extra-file=' "$A" && ! grep -qxF -- "--defaults-extra-file=$DX" "$A"; then
    ok "--defaults-extra-file is included from the private option file that carries the password"
else bad "--defaults-extra-file with MYSQL_PWD" "the private file, pwseen" "$(grep -- '--defaults' "$A" | head -2 | tr '\n' ' ')"; fi
if [ -n "$SETSID" ]; then
    : >| "$A"
    out="$(STUBARGS="$A" PATH="$S" "$SETSID" bash "$C" --stdout --mysql-args "-u x -Bp" </dev/null 2>/dev/null)"
    has "a bare -p with no terminal says so" "$out" "password: n/a (-p given and this run has no terminal to ask for the password on)"
    if grep -qx -- '-B' "$A" && ! grep -qx -- '-Bp' "$A" && ! grep -qx -- '-p' "$A"; then ok "-Bp is -B plus a prompt, and the client never gets p"
    else bad "-Bp is -B plus a prompt" "-B kept, p gone" "$(grep -x -- '-B.*\|-p' "$A" | head -2 | tr '\n' ' ')"; fi
else skip "the no-terminal -p case (setsid absent)"; fi

echo "== 8. read from stdin (bash -s) and under sh =="
err="$(PATH="$S" bash -s -- --stdout --mysql-args "-u x -p$PW" < "$C" 2>&1 >/dev/null)"; rc=$?
chk "-pSECRET under bash -s is refused" "2" "$rc"
out="$(PATH="$S" bash -s -- --stdout < "$C" 2>/dev/null)"
has "without a password it runs to its footer" "$out" "==== END OF COLLECTION"
out="$(sh "$C" --stdout 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -qF "collect-collmysql.sh needs bash" \
    && ok "under sh: exit 2, saying it needs bash" || bad "under sh: exit 2, saying it needs bash" "rc 2 + message" "rc $rc: $(printf '%s' "$out" | head -1)"
chk "no sudo in any of it" "" "$(cat "$STUBLOG")"

echo "== 9. waits, caps and deadlines =="
err="$(CMD_TIMEOUT=abc PATH="$S" bash "$C" --stdout --mysql-args "-u x" </dev/null 2>&1 >/dev/null)"
has "a bad CMD_TIMEOUT is warned about and the run goes on" "$err" "(not a whole number 1..999999 without leading zeros): CMD_TIMEOUT=abc"
err="$(CMD_TIMEOUT=0030 PATH="$S" bash "$C" --stdout --mysql-args "-u x" </dev/null 2>&1 >/dev/null)"
has "a leading zero is refused, and the warning says why" "$err" "(not a whole number 1..999999 without leading zeros): CMD_TIMEOUT=0030"
out="$(MYSQL_SLEEP=5 RUN_DEADLINE=2 PATH="$S" bash "$C" --stdout --mysql-args "-u x" </dev/null 2>/dev/null)"
has "a login cut by the run deadline says so, not 'timed out: 20s'" "$out" "mysql connection: run deadline reached (2s) before the login"
out="$(PATH="$S" bash "$C" --stdout --sample=1 </dev/null 2>/dev/null)"
has "--sample: the deadline covers both samplers" "$out" "run deadline(s): 372"
out="$(MYSQL_BL_DENY=1 MYSQLBINLOG_MODE=ok BINLOG_BASE_ANS="$D2/mysql-bin" PATH="$S" bash "$C" --stdout --no-sudo --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
if printf '%s' "$out" | grep -qF "binary logs: n/a (SHOW BINARY LOGS: access denied)" \
   && printf '%s' "$out" | grep -qF "binary log content attribution — SHOW BINARY LOGS: access denied"; then
    ok "ERROR 1227 on SHOW BINARY LOGS is n/a with the error, and blocks the binlog goal"
else bad "ERROR 1227 on SHOW BINARY LOGS is n/a and blocks the goal" "n/a + blocked" "$(printf '%s' "$out" | grep -m2 'binary logs\|binary log content')"; fi
if [ -n "$SETSID" ] && [ -n "$PY" ]; then
    cat > "$ROOT/ptydrive.py" <<'EOF'
import os, sys, subprocess, termios, time, fcntl, select
# ptydrive LIMIT KEY CMD... : run CMD on a new pty with nobody typing; with
# KEY=ctrlc, send ^C once the prompt is up. Prints elapsed, whether it ended,
# whether the footer came, and whether the terminal still echoes.
m, s = os.openpty()
def ctty():
    os.setsid(); fcntl.ioctl(0, termios.TIOCSCTTY, 0)
t0 = time.time()
p = subprocess.Popen(sys.argv[3:], stdin=s, stdout=s, stderr=s, preexec_fn=ctty)
limit = float(sys.argv[1]); key = sys.argv[2]; buf = b""; sent = False
while time.time() - t0 < limit:
    r, _, _ = select.select([m], [], [], 0.3)
    if r:
        try: buf += os.read(m, 65536)
        except OSError: break
    if key in ("ctrlc", "enter", "eof") and not sent and b"MySQL password" in buf:
        time.sleep(0.5); os.write(m, {"ctrlc": b"\x03", "enter": b"\n", "eof": b"\x04"}[key]); sent = True
    if p.poll() is not None:
        time.sleep(0.3)
        try:
            while select.select([m], [], [], 0.2)[0]: buf += os.read(m, 65536)
        except OSError: pass
        break
done = p.poll() is not None
if not done: p.kill(); p.wait()
echo = bool(termios.tcgetattr(s)[3] & termios.ECHO)
print("elapsed=%d done=%s footer=%s echo=%s" % (time.time() - t0, done, b"END OF COLLECTION" in buf, echo))
sys.stdout.write(buf.decode("utf-8", "replace"))
EOF
    T11="$ROOT/tmp11"; mkdir -p "$T11"
    res="$(TMPDIR="$T11" PROMPT_TIMEOUT=3 RUN_DEADLINE=40 PATH="$S" "$PY" "$ROOT/ptydrive.py" 30 none bash "$C" --stdout --mysql-args "-u x -p" 2>&1)"
    e="$(printf '%s' "$res" | head -1 | sed 's/elapsed=\([0-9]*\).*/\1/')"
    if [ "${e:-99}" -le 15 ] && printf '%s' "$res" | head -1 | grep -q 'footer=True echo=True' \
       && printf '%s' "$res" | grep -qF "password: n/a (password prompt not answered within 3s)" && ! printf '%s' "$res" | grep -qF "run deadline reached"; then
        ok "an unanswered -p prompt waits PROMPT_TIMEOUT, echo is back, the rest is collected (${e}s)"
    else bad "an unanswered -p prompt waits PROMPT_TIMEOUT only" "<= 15s, footer, echo, no deadline" "$(printf '%s' "$res" | head -1)"; fi
    res="$(TMPDIR="$T11" RUN_DEADLINE=6 PATH="$S" "$PY" "$ROOT/ptydrive.py" 30 none bash "$C" --stdout --mysql-args "-u x -p" 2>&1)"
    e="$(printf '%s' "$res" | head -1 | sed 's/elapsed=\([0-9]*\).*/\1/')"
    [ "${e:-99}" -le 12 ] && printf '%s' "$res" | head -1 | grep -q 'done=True footer=True' \
        && ok "and within RUN_DEADLINE=6 when that is less (${e}s)" || bad "the prompt ends within RUN_DEADLINE" "<= 12s, footer" "$(printf '%s' "$res" | head -1)"
    res="$(TMPDIR="$T11" PATH="$S" "$PY" "$ROOT/ptydrive.py" 30 ctrlc bash "$C" --stdout --mysql-args "-u x -p" 2>&1)"
    if printf '%s' "$res" | grep -q 'MySQL password'; then
        chk "Ctrl-C at the password prompt leaves the terminal echoing" "echo=True" "$(printf '%s' "$res" | head -1 | grep -o 'echo=[A-Za-z]*')"
    else skip "the Ctrl-C-at-the-prompt case (no prompt appeared on the pty)"; fi
    res="$(TMPDIR="$T11" PATH="$S" "$PY" "$ROOT/ptydrive.py" 30 enter bash "$C" --stdout --mysql-args "-u x -p" 2>&1)"
    has "an empty line at the prompt is said as such" "$res" "password: n/a (prompt answered with an empty line)"
    res="$(MYSQL_FAIL=1 MYSQL_ERRMSG="ERROR 1698 (28000): Access denied for user 'root'@'localhost'" TMPDIR="$T11" PATH="$S" "$PY" "$ROOT/ptydrive.py" 30 enter bash "$C" --stdout --mysql-args "-u x -p" 2>&1)"
    has "a socket login after an empty answer: the reason carries both" "$res" "mysql login — access denied; prompt answered with an empty line (not elevated: run again with sudo)"
    res="$(TMPDIR="$T11" PATH="$S" "$PY" "$ROOT/ptydrive.py" 30 eof bash "$C" --stdout --mysql-args "-u x -p" 2>&1)"
    has "Ctrl-D at the prompt is said as such" "$res" "password: n/a (prompt answered with end of input)"
    chk "the prompt runs leave no ggt.* directory" "" "$(ls -A "$T11")"
else skip "the prompt cases (setsid or python3 absent)"; fi
chk "and no sudo was run by any case above" "" "$(cat "$STUBLOG")"

echo "== 10. client arguments are words, not a string to re-split =="
DF="$ROOT/my dir/my.cnf"; mkdir -p "$ROOT/my dir"; printf '[client]\nuser=x\n' > "$DF"
W="$ROOT/globdir"; mkdir -p "$W"; : >| "$W/xa"; : >| "$W/xb"; : >| "$A"
( cd "$W" && STUBARGS="$A" PATH="$S" bash "$C" --stdout --no-sudo --defaults-file "$DF" --mysql-args "-u x*" </dev/null >/dev/null 2>&1 )
chk "a --defaults-file path with a space is one argument" "1" "$(grep -cxF -- "--defaults-file=$DF" "$A" | awk '{print ($1>0)}')"
chk "a glob character is not expanded against the cwd" "1" "$(grep -cxF -- 'x*' "$A" | awk '{print ($1>0)}')"
hasnt "no cwd file name arrives as an argument" "$(cat "$A")" "xa"

echo "== 11. nowhere to log in is blocked, not an answer =="
if ! ps -eo args 2>/dev/null | grep -qE '[m]ysqld|[m]ariadbd'; then
    out="$(MYSQL_FAIL=1 PATH="$S" bash "$C" --stdout --no-sudo </dev/null 2>/dev/null)"
    has "the reason names --mysql-args" "$out" "mysql login — no local mysqld found and no --mysql-args given"
    has "and the run is INCOMPLETE" "$out" "status: INCOMPLETE"
else skip "the no-local-mysqld case (a mysqld runs on this machine)"; fi
chk "a bad --binlog count exits 2" "2" "$(PATH="$S" bash "$C" --stdout --no-sudo --binlog=two </dev/null >/dev/null 2>&1; echo $?)"

echo "== 12. round 7: a no-value flag, TCP logins, a word after -p =="
: >| "$A"
STUBARGS="$A" PATH="$S" bash "$C" --stdout --mysql-args "-u x --connect-expired-password" </dev/null >/dev/null 2>&1
grep -qx -- "--connect-expired-password" "$A" && ok "--connect-expired-password reaches the client unchanged" || bad "--connect-expired-password passes through" "in the client argv" "absent"
: >| "$A"
STUBARGS="$A" PATH="$S" bash "$C" --stdout --mysql-args "-u x --connect-expired-password=1" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qx -- "--connect-expired-password=1" "$A" && ok "--connect-expired-password=1 too, not refused" || bad "--connect-expired-password=1 passes through" "rc 0, in argv" "rc $rc"
err="$(MYSQL_FAIL=1 PATH="$S" bash "$C" --stdout --mysql-args "-h 10.0.0.5 -u x" </dev/null 2>&1 >/dev/null)"
has "a TCP login refused: blocked with the server's words" "$err" "mysql login — access denied"
has "and the shared hint that the run was not elevated" "$err" "mysql login — access denied (not elevated: run again with sudo)"
if [ -n "$SETSID" ]; then
    err="$(PATH="$S" "$SETSID" bash "$C" --stdout --mysql-args "-u x -p $PW" </dev/null 2>&1 >/dev/null)"
    has "a word after a bare -p is warned about as a database name" "$err" "is taken as a database name by the client; if it is a password, use the prompt"
    hasnt "and the warning does not repeat it" "$(printf '%s' "$err" | grep 'database name')" "$PW"
else skip "the word-after--p case (setsid absent)"; fi

echo "== 13. round 10: the shared privilege hint, whatever the error =="
for e in "ERROR 1045 (28000): Access denied for user 'op'@'localhost' (using password: NO)" \
         "ERROR 1698 (28000): Access denied for user 'root'@'localhost'" \
         "ERROR 2002 (HY000): Can't connect to local MySQL server through socket '/x.sock' (2)"; do
    err="$(MYSQL_FAIL=1 MYSQL_ERRMSG="$e" PATH="$S" bash "$C" --stdout </dev/null 2>&1 >/dev/null)"
    has "non-root, '${e%% (*}', no arguments: the hint is there" "$(printf '%s' "$err" | grep 'mysql login —')" "(not elevated: run again with sudo)"
done
if sudo -n true 2>/dev/null; then
    out="$(sudo -n env PATH="$S" MYSQL_FAIL=1 bash "$C" --stdout --mysql-args "-u x" </dev/null 2>/dev/null)"
    if printf '%s' "$out" | grep -q 'mysql login —' && ! printf '%s' "$out" | grep 'mysql login —' | grep -qF '(not elevated'; then
        ok "a root run's failed login carries no privilege hint"
    else bad "a root run carries no privilege hint" "no hint" "$(printf '%s' "$out" | grep -m1 'mysql login —')"; fi
else skip "the root-run case (needs passwordless sudo)"; fi

echo "== 14. 0.9.0: binlog sizes come from SHOW BINARY LOGS, not from ls per file =="
# A logging ls counts the listings. With the server's list, one listing (the
# mtimes in section C) serves the run however many files are decoded.
S14="$ROOT/stub14"; stub_clone "$S" "$S14"; LSLOG="$ROOT/ls.log"; : >| "$LSLOG"
REAL_LS="$(type -P ls)"
stub_write "$S14/ls" <<EOF
#!/bin/sh
echo "ls \$*" >> "$LSLOG"
exec "$REAL_LS" "\$@"
EOF
D3="$ROOT/binlogs3"; mkdir -p "$D3"; : >| "$D3/mysql-bin.000001"; printf 'abcdefg' >| "$D3/mysql-bin.000002"
out="$(MYSQL_BL_ROWS='mysql-bin.000001\t100\nmysql-bin.000002\t5' BINLOG_BASE_ANS="$D3/mysql-bin" PATH="$S14" bash "$C" --stdout --no-sudo --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
has "the decoded file's size is the server's" "$out" "file: mysql-bin.000002 (5 bytes)"
has "and the older one's too, newest first" "$out" "file: mysql-bin.000001 (100 bytes)"
[ "$(printf '%s' "$out" | grep -n 'file: mysql-bin.00000[12]' | head -1 | grep -c 000002)" = 1 ] \
    && ok "the newest file is decoded first" || bad "the newest file is decoded first" "000002 first" "$(printf '%s' "$out" | grep 'file: mysql-bin')"
chk "one directory listing for the whole run" "1" "$(grep -c . "$LSLOG")"
hasnt "no directory total next to the server's" "$out" "(directory listing)"
has "the listing still carries the mtimes" "$out" "newest binlog files (mtime, bytes):"
: >| "$LSLOG"
out="$(MYSQL_BL_DENY=1 BINLOG_BASE_ANS="$D3/mysql-bin" PATH="$S14" bash "$C" --stdout --no-sudo --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
has "SHOW BINARY LOGS refused: the listing sums the files" "$out" "total: 2 files, 7 bytes (directory listing)"
has "and the decode's sizes come from the directory" "$out" "file: mysql-bin.000002 (7 bytes)"
out="$(MYSQL_BL_ROWS='mysql-bin.000008\t5\nmysql-bin.000009\t5' BINLOG_BASE_ANS="$D3/mysql-bin" PATH="$S14" bash "$C" --stdout --no-sudo --binlog --mysql-args "-u x" </dev/null 2>/dev/null)"
has "the server's newest log is not in the process's directory: not the server, blocked" "$out" "binary log content attribution — the server's process (pid file $ROOT/run/mysqld.pid) is not on this host: no local mysqld/mariadbd is it: 4242(no mysql-bin.000009, the server's newest log)"

echo "== 15. 0.9.0: every selected file is decoded, or named; another host's files are not the server's =="
out="$(MYSQL_BL_ROWS='mysql-bin.000000\t300\nmysql-bin.000001\t100\nmysql-bin.000002\t5' BINLOG_BASE_ANS="$D3/mysql-bin" PATH="$S" bash "$C" --stdout --no-sudo --binlog=3 --mysql-args "-u x" </dev/null 2>/dev/null)"
R3="$FP/4242/root$D3"
has "a selected file that is not there is named in the section" "$out" "skipped: mysql-bin.000000 (listed by SHOW BINARY LOGS; $R3/mysql-bin.000000 is not a file on this host)"
has "and blocks the goal, though the others decoded" "$out" "binary log content attribution — mysql-bin.000000: not a file at $R3/mysql-bin.000000 on this host"
has "the others are still decoded" "$out" "file: mysql-bin.000002 (5 bytes)"
D4="$ROOT/binlogs4"; mkdir -p "$D4"; : >| "$D4/mysql-bin.000001"
out="$(MYSQL_BL_ROWS='mysql-bin.000001\t0\nmysql-bin.000001\t0' BINLOG_BASE_ANS="$D4/mysql-bin" BINLOG_INDEX_ANS="$ROOT/noindex" PATH="$S" bash "$C" --stdout --no-sudo --binlog=2 --mysql-args "-u x" </dev/null 2>/dev/null)"
has "a name listed twice with no index: said, and blocked" "$out" "binary log content attribution — none of the 2 newest files SHOW BINARY LOGS lists was decoded: mysql-bin.000001: listed 2 times, no readable index to tell them apart"
printf '%s\n' "$D3/mysql-bin.000001" "$D4/mysql-bin.000001" >| "$ROOT/index15"
out="$(MYSQL_BL_ROWS='mysql-bin.000001\t0\nmysql-bin.000001\t0' BINLOG_BASE_ANS="$D4/mysql-bin" BINLOG_INDEX_ANS="$ROOT/index15" PATH="$S" bash "$C" --stdout --no-sudo --binlog=2 --mysql-args "-u x" </dev/null 2>/dev/null)"
has "with a readable index both are decoded, each named by its path" "$out" "file: $FP/4242/root$D4/mysql-bin.000001 (0 bytes)"
has "the other too" "$out" "file: $R3/mysql-bin.000001 (0 bytes)"
has "and the goal is obtained" "$out" "obtained: mysql login, host-side facts (process, sockets, disk), binary log content attribution"
echo "  -- 0.9.0: the files are the server process's, found through /proc/<pid>/root --"
BL2='mysql-bin.000001\t0\nmysql-bin.000002\t7'
run15() { MYSQL_BL_ROWS="$BL2" BINLOG_BASE_ANS="$D3/mysql-bin" PATH="$S" bash "$C" --stdout --no-sudo --binlog=2 --mysql-args "-u x" </dev/null 2>/dev/null; }
out="$(run15)"
has "the server's process: one fact says how the files were found" "$(nt "$out")" "binlog files: via pid 4242 (connection local (Localhost via UNIX socket); pid file $ROOT/run/mysqld.pid, read through $FP/4242/root, holds its pid 4242, written Ns after the server started, holds the newest log mysql-bin.000002), $FP/4242/root$D3"
has "and they are decoded" "$out" "obtained: mysql login, host-side facts (process, sockets, disk), binary log content attribution"
echo "  -- 0.9.0: SHOW MASTER STATUS only where SHOW BINARY LOG STATUS is unknown --"
ML="$ROOT/master.log"; : >| "$ML"
out="$(MASTERLOG="$ML" run15)"
has "a server that knows SHOW BINARY LOG STATUS: its answer" "$out" "binary log status:"
chk "and SHOW MASTER STATUS is not asked" "0" "$(wc -l < "$ML" | tr -d ' ')"
out="$(MASTERLOG="$ML" OLD_SERVER=1 run15)"
has "a syntax error on it: SHOW MASTER STATUS answers, labelled so" "$out" "binary log status (SHOW MASTER STATUS):"
chk "asked once" "1" "$(wc -l < "$ML" | tr -d ' ')"
hasnt "and the syntax error is not a fact" "$out" "You have an error in your SQL syntax"
echo "  -- 0.9.0: where the client connected --"
out="$(CONN_ANS='203.0.113.7 via TCP/IP' run15)"
has "-h a remote address: missed, the server is remote" "$out" "binary log content attribution — the server is remote (connected to 203.0.113.7 via TCP/IP, 203.0.113.7 not an address of this host, nor of a local mysqld's network namespace); run the collector on the database host to read its binary logs"
hasnt "and the local mysqld is not taken for it" "$out" "binlog files: via pid"
hasnt "the section fact carries no how-to-run advice" "$(printf '%s\n' "$out" | grep -E '^    (n/a|binlog directory)')" "run the collector on the database host"
out="$(CONN_ANS='127.0.0.1 via TCP/IP' run15)"
has "-h 127.0.0.1: the process rule, saying so" "$out" "binlog files: via pid 4242 (connection local (127.0.0.1 via TCP/IP);"
out="$(run15)"
has "a unix socket: the process rule" "$out" "binlog files: via pid 4242 (connection local (Localhost via UNIX socket);"
out="$(CONN_ANS='10.9.9.9 via TCP/IP' run15)"
has "-h an address of this host: the process rule" "$out" "binlog files: via pid 4242 (connection local (10.9.9.9 via TCP/IP, 10.9.9.9 is an address of this host);"
hasnt "-h an address of this host: its fib_trie broadcast is no address" "$(CONN_ANS='10.9.9.255 via TCP/IP' run15)" "binlog files: via pid"
out="$(CONN_ANS='dbhost-x via TCP/IP' run15)"
has "a name that does not resolve here: the process rule, saying so" "$out" "binlog files: via pid 4242 (connection not known (dbhost-x did not resolve here);"
# a containerised mysqld reached on its bridge address from the host
mkdir -p "$FP/4242/net"; printf 'Local:\n     |-- 172.30.0.2\n        /32 host LOCAL\n' >| "$FP/4242/net/fib_trie"
out="$(CONN_ANS='172.30.0.2 via TCP/IP' run15)"
has "an address a local mysqld's network namespace owns: the process rule" "$out" "binlog files: via pid 4242 (connection 172.30.0.2 via TCP/IP, 172.30.0.2 not an address of this host, owned by its network namespace;"
rm -rf "$FP/4242/net"
# a containerised mysqld: host pid 4243, pid 1 in its namespace, its own root
CR="$ROOT/ctr"; mkdir -p "$CR/run" "$CR$D3"; pidf "$CR/run/mysqld.pid" 1
cp "$D3"/mysql-bin.00000* "$CR$D3/"
mv "$FP/4242" "$ROOT/p4242"; mkproc 4243 1 999 "$CR"
out="$(PIDFILE_ANS=/run/mysqld.pid run15)"
has "a containerised mysqld: found by its namespaced pid" "$(nt "$out")" "binlog files: via pid 4243 (connection local (Localhost via UNIX socket); pid file /run/mysqld.pid, read through $FP/4243/root, holds its pid 1, written Ns after the server started, holds the newest log mysql-bin.000002), $FP/4243/root$D3"
has "and decoded through its root" "$out" "obtained: mysql login, host-side facts (process, sockets, disk), binary log content attribution"
# a relative pid file resolves against @@datadir, inside the process's root
mkdir -p "$CR/data"; pidf "$CR/data/h.pid" 1
out="$(PIDFILE_ANS=h.pid DATADIR_ANS=/data/ run15)"
has "a relative @@pid_file is read under @@datadir" "$out" "binlog files: via pid 4243 (connection local (Localhost via UNIX socket); pid file /data/h.pid, read through $FP/4243/root, holds its pid 1"
rm -rf "$FP/4243"
# no mysqld here at all: a remote server
out="$(run15)"
has "no local mysqld: the server's process is not on this host" "$out" "binary log content attribution — the server's process (pid file $ROOT/run/mysqld.pid) is not on this host: no mysqld or mariadbd process runs here"
hasnt "and nothing is decoded" "$out" "file: mysql-bin.000002"
has "section C lists no directory" "$out" "binlog directory: $D3 (not listed: the server's process"
# a local mysqld that is another server (a copied datadir, its own pid file)
mkproc 4244 "" 999 / mariadbd; pidf "$ROOT/run/other.pid" 999
out="$(run15)"
has "a local mariadbd whose pid file is not its pid: not the server" "$out" "no local mysqld/mariadbd is it: 4244(pid file holds 4242)"
pidf "$ROOT/run/mysqld.pid" 4244
mkproc 4244 "" 400 / mariadbd
out="$(run15)"
has "a sole match started at another time since boot (a clock step) is still the server" "$out" "binlog files: via pid 4244"
# the pid file time is what decides: another server's is older, or far newer
pidf "$ROOT/run/mysqld.pid" 4244 -100
out="$(run15)"
has "a pid file written before the server started: not the server" "$(nt "$out")" "4244(pid file written at T, the server started at S)"
pidf "$ROOT/run/mysqld.pid" 4244 4000
out="$(run15)"
has "a pid file written long after the server started: not it" "$(nt "$out")" "4244(pid file written at T, the server started at S)"
pidf "$ROOT/run/mysqld.pid" 4244 900
out="$(run15)"
w900="$(printf '%s' "$out" | sed -nE 's/.*written ([0-9]+)s after the server started.*/\1/p' | head -n1)"
[ "${w900:-0}" -ge 899 ] && [ "${w900:-0}" -le 901 ] && ok "within 1800 s after the start (InnoDB recovery): it is (${w900}s)" \
    || bad "within 1800 s after the start: it is" "written 899..901s after" "${w900:-none}"
mkproc 4245 "" 999 /
pidf "$ROOT/run/p2.pid" 4245
out="$(PIDFILE_ANS="$ROOT/run/p2.pid" run15)"
has "the pid file picks the one of two that holds it" "$out" "binlog files: via pid 4245"
rm -rf "$FP/4244" "$FP/4245"
# two with the pid file and logs: the pid file time tells them apart
T2="$ROOT/tie"; mkdir -p "$T2$ROOT/run" "$T2$D3"; cp "$D3"/mysql-bin.00000* "$T2$D3/"; pidf "$T2$ROOT/run/mysqld.pid" 1
pidf "$ROOT/run/mysqld.pid" 4242; mv "$ROOT/p4242" "$FP/4242"
mkproc 4248 1 1500 "$T2"; touch -d "@$(( SRV_START - 50 ))" "$T2$ROOT/run/mysqld.pid"
out="$(run15)"
has "two alike, one pid file older than the server: the other is it" "$out" "binlog files: via pid 4242"
touch -d "@$SRV_START" "$T2$ROOT/run/mysqld.pid"
out="$(run15)"
has "two alike in every respect: a gap, not a guess" "$out" "more than one local mysqld/mariadbd has the server's pid file $ROOT/run/mysqld.pid"
rm -rf "$FP/4248"
# a missing pid file through an enterable root is absent, not unreadable
out="$(PIDFILE_ANS="$ROOT/run/none.pid" run15)"
has "a pid file that is not there: said so" "$out" "4242(pid file absent)"
hasnt "and no privilege hint" "$(printf '%s' "$out" | grep 'binary log content attribution —')" "(not elevated"
if [ "$UID_NOW" != 0 ]; then
    mkdir -p "$ROOT/run700"; pidf "$ROOT/run700/mysqld.pid" 4242; chmod 000 "$ROOT/run700"
    out="$(PIDFILE_ANS="$ROOT/run700/mysqld.pid" run15)"
    has "a pid file in a directory this uid cannot search: unreadable, with the hint" "$out" "the server's pid file $ROOT/run700/mysqld.pid could not be read for mysqld/mariadbd pid 4242 by uid $UID_NOW (not elevated: run again with sudo)"
    hasnt "not 'absent'" "$out" "4242(pid file absent)"
    chmod 755 "$ROOT/run700"
else skip "the unsearchable pid-file directory (root searches every directory)"; fi
# a zombie mysqld is no candidate
mv "$FP/4242" "$ROOT/p4242"; mkproc 4249 "" 999 /; sed -i 's/) S /) Z /' "$FP/4249/stat"; pidf "$ROOT/run/mysqld.pid" 4249
out="$(run15)"
has "a zombie mysqld is not a candidate" "$out" "no mysqld or mariadbd process runs here"
rm -rf "$FP/4249"; pidf "$ROOT/run/mysqld.pid" 4242; mv "$ROOT/p4242" "$FP/4242"
# a rotation between SHOW BINARY LOGS and the listing: asked once more
: >| "$D3/mysql-bin.000003"; BLC="$ROOT/blcount"; : >| "$BLC"
out="$(BLCOUNT="$BLC" MYSQL_BL_ROWS2='mysql-bin.000001\t0\nmysql-bin.000002\t7\nmysql-bin.000003\t0' MYSQL_BL_ROWS="$BL2" BINLOG_BASE_ANS="$D3/mysql-bin" PATH="$S" bash "$C" --stdout --no-sudo --binlog=1 --mysql-args "-u x" </dev/null 2>/dev/null)"
has "a log newer than the listed newest, listed when asked again: the server" "$out" "binlog files: via pid 4242"
has "and the new newest is the one decoded" "$out" "file: mysql-bin.000003 (0 bytes)"
chk "SHOW BINARY LOGS asked twice" "2" "$(wc -l < "$BLC" | tr -d ' ')"
: >| "$BLC"
out="$(BLCOUNT="$BLC" MYSQL_BL_ROWS2="$BL2" MYSQL_BL_ROWS="$BL2" BINLOG_BASE_ANS="$D3/mysql-bin" PATH="$S" bash "$C" --stdout --no-sudo --binlog=1 --mysql-args "-u x" </dev/null 2>/dev/null)"
has "still not listed when asked again: not the server, with the fresh newest" "$out" "4242(holds mysql-bin.000003, which SHOW BINARY LOGS does not list (asked again; its newest: mysql-bin.000002))"
# rotated again between the listing and the second ask: the listing's newest is listed, not last
: >| "$D3/mysql-bin.000003"; : >| "$BLC"
out="$(BLCOUNT="$BLC" MYSQL_BL_ROWS2='mysql-bin.000001\t0\nmysql-bin.000002\t7\nmysql-bin.000003\t0\nmysql-bin.000004\t0' MYSQL_BL_ROWS="$BL2" BINLOG_BASE_ANS="$D3/mysql-bin" PATH="$S" bash "$C" --stdout --no-sudo --binlog=1 --mysql-args "-u x" </dev/null 2>/dev/null)"
has "the listing's newest listed among newer ones: the server" "$out" "binlog files: via pid 4242"
rm -f "$D3/mysql-bin.000003"
mv "$FP/4242" "$ROOT/p4242"
# two servers started together from one image: the same pid (1), pid file
# path and start; only the server's own files tell them apart
TW="$ROOT/twin"; mkdir -p "$TW/run" "$TW$D3"; pidf "$TW/run/mysqld.pid" 1; : >| "$TW$D3/mysql-bin.000001"
mkproc 4247 1 999 "$TW" mariadbd
out="$(PIDFILE_ANS=/run/mysqld.pid run15)"
has "a twin without the server's newest log: not the server" "$out" "4247(no mysql-bin.000002, the server's newest log)"
printf 'abc' >| "$TW$D3/mysql-bin.000002"
out="$(PIDFILE_ANS=/run/mysqld.pid run15)"
has "a twin whose newest log is shorter than the server's: not it" "$out" "4247(mysql-bin.000002 is 3 bytes, the server's 7)"
printf 'abcdefgh' >| "$TW$D3/mysql-bin.000002"; : >| "$TW$D3/mysql-bin.000003"
out="$(PIDFILE_ANS=/run/mysqld.pid run15)"
has "a twin with a log newer than the server's newest: not it" "$out" "4247(holds mysql-bin.000003, which SHOW BINARY LOGS does not list"
rm -f "$TW$D3/mysql-bin.000003"; mkdir -p "$TW/data"; printf '[auto]\nserver-uuid=twin-uuid\n' >| "$TW/data/auto.cnf"
out="$(PIDFILE_ANS=/run/mysqld.pid DATADIR_ANS=/data/ run15)"
has "a MySQL twin whose auto.cnf is another server's: not it" "$out" "4247(auto.cnf server-uuid twin-uuid, the server's 1)"
rm -f "$TW/data/auto.cnf"
out="$(PIDFILE_ANS=/run/mysqld.pid run15)"
has "the same files as the server's (still growing): the server" "$out" "binlog files: via pid 4247"
rm -rf "$FP/4247"; pidf "$ROOT/run/mysqld.pid" 4242; mv "$ROOT/p4242" "$FP/4242"
if [ "$UID_NOW" != 0 ]; then
    mkdir -p "$ROOT/lockedroot"; mkproc 4246 "" 999 "$ROOT/lockedroot"; chmod 000 "$ROOT/lockedroot"
    mv "$FP/4242" "$ROOT/p4242"
    out="$(PIDFILE_ANS="$ROOT/run/none.pid" run15)"
    has "a root this uid cannot enter, and no pid file here: absent, said so" "$out" "4246(pid file absent here; /proc/4246/root not enterable by uid $UID_NOW)"
    hasnt "and no privilege hint for an absent file" "$(printf '%s' "$out" | grep 'binary log content attribution —')" "(not elevated"
    pidf "$ROOT/run/locked.pid" 4246; chmod 000 "$ROOT/run/locked.pid"
    out="$(PIDFILE_ANS="$ROOT/run/locked.pid" run15)"
    has "a pid file here this uid may not read: blocked with the privilege hint" "$out" "binary log content attribution — the server's pid file $ROOT/run/locked.pid could not be read for mysqld/mariadbd pid 4246 by uid $UID_NOW (not elevated: run again with sudo)"
    chmod 644 "$ROOT/run/locked.pid"
    # a container without CAP_SYS_PTRACE: the pid file here holds P's own pid
    pidf "$ROOT/run/here.pid" 4246
    out="$(PIDFILE_ANS="$ROOT/run/here.pid" run15)"
    has "a root this uid cannot enter, the pid file here holds P's pid: read at the plain path" "$(nt "$out")" "binlog files: via pid 4246 (connection local (Localhost via UNIX socket); pid file $ROOT/run/here.pid, read here, holds its pid 4246, written Ns after the server started, holds the newest log mysql-bin.000002), $D3"
    has "and decoded" "$out" "obtained: mysql login, host-side facts (process, sockets, disk), binary log content attribution"
    chmod 755 "$ROOT/lockedroot"; rm -rf "$FP/4246"; mv "$ROOT/p4242" "$FP/4242"
else skip "the unreadable-root cases (root enters every root)"; fi
out="$(MYSQL_BL_PARTIAL='mysql-bin.000001\t100' BINLOG_BASE_ANS="$D3/mysql-bin" PATH="$S" bash "$C" --stdout --no-sudo --mysql-args "-u x" </dev/null 2>/dev/null)"
has "a failed SHOW BINARY LOGS is n/a" "$out" "binary logs: n/a (SHOW BINARY LOGS: "
has "and its partial rows are not used: the listing sums the files" "$out" "total: 2 files, 7 bytes (directory listing)"

echo; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
