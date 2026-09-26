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
# MYSQL_SLEEP -> the login check (SELECT 1) sleeps that long, so a test can
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
[ -n "${MYSQL_SLEEP:-}" ] && [ "$q" = "SELECT 1" ] && sleep "$MYSQL_SLEEP"
if [ -n "${MYSQL_FAIL:-}" ]; then
    # MYSQL_ERRMSG replaces the refusal, to test what each error earns.
    echo "${MYSQL_ERRMSG:-ERROR 1045 (28000): Access denied for user 'x'@'localhost' (using password: YES)}" >&2
    exit 1
fi
for a in "$@"; do q="$a"; done
case "$q" in
    "SHOW BINARY LOGS") if [ -n "${MYSQL_BL_DENY:-}" ]; then
            echo "ERROR 1227 (42000) at line 1: Access denied; you need (at least one of) the SUPER, REPLICATION CLIENT privilege(s) for this operation" >&2; exit 1
        fi; echo "mysql-bin.000001	100"; exit 0 ;;
    *log_bin_basename*) [ -n "${BINLOG_BASE_ANS:-}" ] && echo "$BINLOG_BASE_ANS"; exit 0 ;;
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
    has "the goal names the uid, the owner and the mode" "$out" "binary log content attribution — run as uid $UID_NOW; $D is $(id -un):$(id -gn) 0 and not readable by this uid (not elevated: run again with sudo)"
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

echo; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
