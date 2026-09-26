#!/usr/bin/env bash
#
# test-framework.sh — behaviour tests for the shared blocks, the sync tool and
# the report validator, plus one real run of every shell collector.
# -----------------------------------------------------------------------------
# Usage:  tools/test-framework.sh [--quick]
#
# test-collserver.sh and test-collmysql.sh test one collector each. This tests
# what every collector inherits, so a change to the skeleton is checked against
# all of them at once:
#
#   1. the shared helpers, under bash AND dash. The apm collectors are piped into
#      `sh -s` in containers, and the first draft of the run-helpers block used
#      three bash-only constructs that dash rejected at run time (2026-09-25).
#   2. sync-shared-block.sh keeps collector code a one-line function would have
#      let it delete.
#   3. validate.sh --report fails each broken shape it is meant to catch, and
#      passes the skeleton's own report.
#   4. every shell collector, run on this machine, produces a report that
#      validate.sh --report passes, under bash and (apm) under dash, and a
#      --file run into an unwritable directory exits non-zero and says so.
#
# --quick skips group 4, which runs every collector (a few minutes).
#
# Everything runs under a mktemp root. Nothing here writes into the repo.
# -----------------------------------------------------------------------------

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/templates/collector-skeleton/collector-skeleton.sh"
V="$ROOT/tools/validate.sh"
QUICK=0; [ "${1:-}" = --quick ] && QUICK=1

T="$(mktemp -d "${TMPDIR:-/tmp}/ggt-test.XXXXXX")" || exit 2
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

PASS=0 FAIL=0 SKIP=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else no "$1" "${3:-}"; fi; }

# The skeleton's helpers without its main, sourced by the group 1 scripts.
sed '/^# ---- main — DO NOT EDIT/,$d' "$SK" > "$T/lib.sh"

# ---- 1. shared helpers ------------------------------------------------------
cat > "$T/helpers.sh" <<'EOF'
set -- --stdout
. "$LIB"
exec 3>&2
_run_init; _init_probe
myfn() { echo from-fn; }
slowfn() { sleep 30; echo never; }
CMD_TIMEOUT=2
section "probes"
probe "fn" myfn
probe "exit3" sh -c 'echo inactive; exit 3'
probe "missing" no-such-command-ggt
t0=$(date +%s); probe "slow file" sleep 30;           echo "took-file $(( $(date +%s) - t0 ))"
t0=$(date +%s); probe "slow fn" slowfn;               echo "took-fn $(( $(date +%s) - t0 ))"
t0=$(date +%s); probe "deaf to TERM" sh -c 'trap "" TERM; sleep 30'; echo "took-noterm $(( $(date +%s) - t0 )) k=${_timeout_k:-none}"
_timeout_bin=""
t0=$(date +%s); probe "slow grandchild" sh -c 'sleep 30'; echo "took-watchdog $(( $(date +%s) - t0 ))"
echo "piped: $(echo abc | _bounded tr a-z A-Z)"
echo "tmpdir: $_tmp_dir"
goal a "A"; goal a "A again"; goal b "B"; goal c "C"; goal d "D"; goal e "E"; goal f "F"; goal g "G"
got a; got a
missed b "refused"; got b
missed c "line one
line	two"; na c "none"
na d "empty"
missed f "r1"; missed f "r2"
na g "x"; na g "y"
got stray
emit_status
RUN_DEADLINE=1; sleep 2
probe "late" echo hi
probe "late too" echo hi
emit_status | grep -E 'run deadline|not run|host load|run time'
EOF

for sh in bash dash; do
    echo "== 1. shared helpers under $sh =="
    command -v "$sh" >/dev/null 2>&1 || { skip "$sh not installed"; continue; }
    out="$(LIB="$T/lib.sh" "$sh" "$T/helpers.sh" 2>&1)"
    # shellcheck disable=SC2034  # read inside check's eval
    tmpd="$(printf '%s\n' "$out" | sed -n 's/^tmpdir: //p')"
    check "a shell function runs under probe"               'printf "%s" "$out" | grep -q "fn: from-fn"'
    check "a non-zero exit keeps its output"                'printf "%s" "$out" | grep -q "exit3 (exit 3): inactive"'
    check "a missing command is named"                      'printf "%s" "$out" | grep -q "missing: n/a (command not found"'
    check "timeout(1) caps a file command"                  'printf "%s" "$out" | grep -Eq "took-file [23]$"'
    check "the watchdog caps a function"                    'printf "%s" "$out" | grep -Eq "took-fn [2-4]$"'
    # timeout(1) without -k sends TERM once and waits: a command that ignores
    # it ran its full 30s (2026-09-25). With -k 5 it is killed at 2+5s.
    if timeout -k 1 5 true </dev/null >/dev/null 2>&1; then
        check "timeout(1) kills a command that ignores TERM" 'printf "%s" "$out" | grep -Eq "took-noterm [6-8] k=5"' \
              "$(printf '%s' "$out" | grep took-noterm)"
    else
        skip "timeout(1) here takes no -k"
    fi
    check "the watchdog reaches a grandchild"               'printf "%s" "$out" | grep -Eq "took-watchdog [2-4]$"' \
          "an orphaned grandchild holds \$(...) open; took: $(printf '%s' "$out" | grep took-watchdog)"
    check "_bounded passes stdin through"                   'printf "%s" "$out" | grep -q "piped: ABC"'
    check "a duplicate goal counts once"                    'printf "%s" "$out" | grep -q "goals: 7 declared, 1 obtained, 2 not applicable here, 4 blocked"'
    check "missed then got is blocked, and says so"         'printf "%s" "$out" | grep -q "B — resolved 2 times: missed, got — refused"'
    check "a reason with newlines and tabs stays one line"  'printf "%s" "$out" | grep -q "C — resolved 2 times: missed, na — line one line two"'
    check "missed twice is blocked with both reasons"       'printf "%s" "$out" | grep -q "^ *F — r1; r2$"'
    check "na twice is not applicable, first reason"        'printf "%s" "$out" | grep -q "^ *G — x$"'
    check "an undeclared resolution is listed"              'printf "%s" "$out" | grep -q "resolved but never declared: stray"'
    check "an unresolved goal is not reached"               'printf "%s" "$out" | grep -q "E — not reached"'
    check "past the deadline a probe does not run"          'printf "%s" "$out" | grep -q "late: n/a (run deadline reached: 1s)"'
    check "the status names the deadline"                   'printf "%s" "$out" | grep -q "run deadline: reached at 1s"'
    # where the time went, and the load it ran under (2026-09-25)
    check "the status gives the run time"                   'printf "%s" "$out" | grep -Eq "run time: [0-9]+s of [0-9]+s allowed"'
    check "a capped call is named with its cap"             'printf "%s" "$out" | grep -Eq "^ +[0-9]+\.[0-9]s  sleep, 1 capped at 2s$"'
    check "one command's calls are summed, capped ones counted" 'printf "%s" "$out" | grep -Eq "^ +[0-9]+\.[0-9]s  sh x3, 2 capped at 2s$"' \
          "$(printf '%s' "$out" | grep -E '^ +[0-9]+\.[0-9]s  ')"
    check "fast calls are timed in ms, not rounded to 0"    'printf "%s" "$out" | grep -Eq "^ +0\.[0-9]s  tr$|^ +0\.[0-9]s  myfn"'
    check "the time outside bounded calls is given"         'printf "%s" "$out" | grep -q "(outside bounded calls: shell work and file reads)"' 
    check "calls not run past the deadline are counted"     'printf "%s" "$out" | grep -q "echo x2 not run (deadline)"'
    check "the host load is given at start and end"         'printf "%s" "$out" | grep -q "host load at start: load " && printf "%s" "$out" | grep -q "host load at end:   load "'
    check "no argument of a logged call is kept"            '! printf "%s" "$out" | grep -Eq "^ +[0-9]+\.[0-9]s  .*(30|TERM|trap)"'
    check "the private directory is gone after exit"        '[ -n "$tmpd" ] && [ ! -e "$tmpd" ]'
    [ "$sh" = dash ] && check "no bash-only construct in the blocks" '! printf "%s" "$out" | grep -q "Bad substitution\|Syntax error"'
done

# The same helpers when the shell reads the script from stdin, as
# `kubectl exec ... sh -s` does. bash 5.2 kills a $(...) subshell that
# duplicates fd 0 in that mode, which turned every bounded function into
# "nonzero exit" (2026-09-25); and a bounded command that reads stdin would eat
# the rest of the script.
cat > "$T/stdin-tail.sh" <<'EOF'
exec 3>&2
_run_init; _init_probe
myfn() { echo from-fn; }
CMD_TIMEOUT=2
probe "fn" myfn
printf 'a\nb\n' > "$(_tmp in.txt)"
echo "in: $(_bounded_in "$(_tmp in.txt)" wc -l | tr -d ' ')"
_timeout_bin=""
probe "fn-watchdog" myfn
probe "reads stdin" cat
echo "END-REACHED"
EOF
for sh in bash dash; do
    echo "== 1c. shared helpers under $sh -s (script on stdin) =="
    command -v "$sh" >/dev/null 2>&1 || { skip "$sh not installed"; continue; }
    out="$(cat "$T/lib.sh" "$T/stdin-tail.sh" | "$sh" -s -- --stdout 2>&1)"
    check "a function under probe"                 'printf "%s" "$out" | grep -q "    fn: from-fn"'
    check "a function under the watchdog"          'printf "%s" "$out" | grep -q "fn-watchdog: from-fn"'
    check "_bounded_in feeds its file"             'printf "%s" "$out" | grep -q "in: 2"'
    check "a command reading stdin does not eat the script" 'printf "%s" "$out" | grep -q "END-REACHED"'
done
if command -v dash >/dev/null 2>&1; then
    mkdir -p "$T/ro-dash" && chmod 555 "$T/ro-dash"
    (cd "$T/ro-dash" && dash -s -- --file < "$SK" > "$T/ro-dash.out" 2> "$T/ro-dash.err")
    # shellcheck disable=SC2034  # read inside check's eval
    drc=$?
    check "dash: an unwritable --file warns and exits 1" '[ "$drc" = 1 ] && grep -q "^!! the report was not written" "$T/ro-dash.err"'
fi

echo "== 1d. caps from the environment, and no private directory =="
cat > "$T/caps.sh" <<'EOF'
set -- --stdout
. "$LIB"
exec 3>&2
CMD_TIMEOUT="$CT"; RUN_DEADLINE="$RD"
_run_init
echo "CT=$CMD_TIMEOUT RD=$RUN_DEADLINE dir=${_tmp_dir:-none}"
probe "fn" true
EOF
for sh in bash dash; do
    command -v "$sh" >/dev/null 2>&1 || continue
    out="$(LIB="$T/lib.sh" CT=abc RD=99999999999999999999 "$sh" "$T/caps.sh" 2>&1)"
    check "$sh: a non-numeric CMD_TIMEOUT is replaced, and said"  'printf "%s" "$out" | grep -q "CMD_TIMEOUT=abc ignored" && printf "%s" "$out" | grep -q "CT=20 "'
    check "$sh: an oversized RUN_DEADLINE is replaced, and said"   'printf "%s" "$out" | grep -q "RD=300 "'
    check "$sh: no shell arithmetic error"                         '! printf "%s" "$out" | grep -qi "illegal number\|integer expression"'
    # the private directory removed under a running collector (a tmp cleaner):
    # the time log must not print the failed redirect on every call
    out="$(LIB="$T/lib.sh" CT=5 RD=60 "$sh" -c '. "$LIB"; exec 3>&2; _run_init; rm -rf "$_tmp_dir"; _bounded true; _bounded true; echo rc=$?' 2>&1)"
    check "$sh: a vanished private directory is silent in the time log" '[ "$out" = rc=0 ]' "$out"
    out="$(LIB="$T/lib.sh" CT=5 RD=60 TMPDIR=/nonexistent/ggt "$sh" "$T/caps.sh" 2>&1)"
    check "$sh: a missing private directory is said"               'printf "%s" "$out" | grep -q "no private temp directory could be made" && printf "%s" "$out" | grep -q "dir=none"'
done

echo "== 1e. where the time went =="
cat > "$T/tl.sh" <<'EOF'
set -- --stdout
. "$LIB"
exec 3>&2
_run_init; _init_probe
echo "ms_date=$_ms_date"
d=$_tmp_dir; i=0
while [ "$i" -lt 300 ]; do _bounded true; [ -d "$d" ] || break; i=$((i + 1)); done
echo "dir-survived=$i"
: > "$_tmp_dir/time.log"
goal a "A"; got a
for c in c01 c02 c03 c04 c05 c06 c07 c08 c09 c10 c11; do _time_log 1 ran "$c"; done
_time_log 3000 "capped at 3s" sleep 9; _time_log 2000 "cut at the deadline" sleep 9
_time_log 0 "not run" lostcmd x
_time_log 10 ran echo hunter2; _time_log 10 ran kubectl --request-timeout=1s get pods
_time_log 10 ran kubectl --token secret get
_time_log 10 ran "$(printf 'we\nird')"
emit_status
EOF
mkdir -p "$T/nodate-ns" && printf '#!/bin/sh\ncase "$1" in +%%s%%N) exec /bin/date +%%s ;; esac\nexec /bin/date "$@"\n' > "$T/nodate-ns/date" && chmod +x "$T/nodate-ns/date"
for sh in bash dash; do
    command -v "$sh" >/dev/null 2>&1 || continue
    out="$(LIB="$T/lib.sh" "$sh" "$T/tl.sh" 2>&1)"
    # the watchdog's TERM ran the inherited trap and removed the directory
    # within 1..176 calls under bash (2026-09-25)
    check "$sh: 300 bounded builtins keep the private directory" 'printf "%s" "$out" | grep -q "dir-survived=300"' "$(printf '%s' "$out" | grep dir-survived)"
    check "$sh: not-run rows are listed past the top 10"   'printf "%s" "$out" | grep -q "lostcmd x1 not run (deadline)"'
    check "$sh: mixed outcomes of one command are each counted" 'printf "%s" "$out" | grep -Eq "sleep x2, 1 capped at 3s, 1 cut at the deadline$"'
    check "$sh: an argument of a plain command is never kept" '! printf "%s" "$out" | grep -q hunter2'
    check "$sh: a subcommand tool keeps its subcommand"     'printf "%s" "$out" | grep -Eq "  kubectl get$"' "$(printf '%s' "$out" | grep kubectl)"
    check "$sh: an option before it hides the subcommand, never the value" 'printf "%s" "$out" | grep -Eq "  kubectl$" && ! printf "%s" "$out" | grep -q secret'
    check "$sh: a name with odd bytes is ?"                 'printf "%s" "$out" | grep -Eq "  \?$" && ! printf "%s" "$out" | grep -q ird'
    [ "$sh" = dash ] && check "dash: a date that drops %N is not taken for ms" \
        '[ "$(PATH="$T/nodate-ns:$PATH" LIB="$T/lib.sh" dash "$T/tl.sh" 2>&1 | sed -n "s/^ms_date=//p")" = 0 ]'
done

# A TERM to a run that is between two short bounded calls: a flag set around
# the fork skipped the cleanup when the signal landed inside it (6 of 70 bash
# runs leaked the directory, 2026-09-26).
cat > "$T/loop.sh" <<'EOF'
set -- --stdout
. "$LIB"
exec 3>&2
_run_init
f() { :; }
echo "$_tmp_dir" > "$OUT"
while :; do _bounded f; done
EOF
for sh in bash dash; do
    command -v "$sh" >/dev/null 2>&1 || continue
    leak=0; n=0
    for dl in 0.3 0.45 0.6 0.75 0.9 1.05 1.2 1.35; do
        rm -f "$T/loop.dir"
        LIB="$T/lib.sh" OUT="$T/loop.dir" "$sh" "$T/loop.sh" >/dev/null 2>&1 &
        lp=$!; sleep "$dl"; kill -TERM "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
        d="$(cat "$T/loop.dir" 2>/dev/null)"; n=$((n + 1))
        [ -n "$d" ] && [ -e "$d" ] && { leak=$((leak + 1)); rm -rf "$d"; }
    done
    check "$sh: a TERM between short bounded calls leaves no directory ($n runs)" '[ "$leak" = 0 ]' "leaked $leak of $n"
done
# dash: a bounded function used to cost ~1s on 10-15% of calls
if command -v dash >/dev/null 2>&1; then
    t0=$(date +%s)
    LIB="$T/lib.sh" dash -c '. "$LIB"; exec 3>&2; _run_init; f() { :; }; i=0; while [ $i -lt 40 ]; do _bounded f; i=$((i + 1)); done' >/dev/null 2>&1
    took=$(( $(date +%s) - t0 ))
    check "dash: 40 bounded functions take under 5s" '[ "$took" -lt 5 ]' "took ${took}s"
fi

echo "== 1b. Ctrl-C leaves nothing behind =="
cat > "$T/intr.sh" <<'EOF'
set -- --stdout
. "$LIB"
exec 3>&2
_run_init
echo "$_tmp_dir" > "$OUT"
echo secret > "$(_tmp copy.conf)"
sleep 30
EOF
# Under set -m, as a terminal's Ctrl-C does. A job started with & from a
# non-interactive shell inherits SIGINT ignored, and a trap cannot catch what
# was ignored at start, so the old form of this test passed after sleep 30
# ended by itself (found 2026-09-25). The time check says the trap ran.
# bash runs its EXIT trap when a signal kills it and dash does not, so only
# dash shows a missing INT trap.
for sh in bash dash; do
    command -v "$sh" >/dev/null 2>&1 || { skip "$sh not installed"; continue; }
    rm -f "$T/intr.dir"
    set -m
    LIB="$T/lib.sh" OUT="$T/intr.dir" "$sh" "$T/intr.sh" 2>/dev/null &
    ip=$!
    set +m
    i=0; while [ ! -s "$T/intr.dir" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    t0=$(date +%s); kill -INT -- "-$ip" 2>/dev/null; wait "$ip" 2>/dev/null
    irc=$?; took=$(( $(date +%s) - t0 ))
    d="$(cat "$T/intr.dir" 2>/dev/null)"
    check "$sh: INT ends the run at once, with 130" '[ "$irc" = 130 ] && [ "$took" -le 3 ]' "rc=$irc took=${took}s"
    check "$sh: INT removes the run's directory" '[ -n "$d" ] && [ ! -e "$d" ]' "left: $d"
done

# ---- 2. sync-shared-block ---------------------------------------------------
echo "== 2. sync-shared-block =="
check "--check passes on the repo" '"$ROOT/tools/sync-shared-block.sh" --check >/dev/null'
M="$T/mini"; mkdir -p "$M/tools" "$M/templates/collector-skeleton" "$M/collectors/x"
cp "$ROOT/tools/sync-shared-block.sh" "$M/tools/"
cp "$SK" "$M/templates/collector-skeleton/"
cp "$SK" "$M/collectors/x/collect-x.sh"
# a one-line function right after the completeness block, and drift inside it
sed -i 's/^# ---- end collection completeness$/&\nkeepme() { echo keep; }/' "$M/collectors/x/collect-x.sh"
sed -i 's/^_flat() {/# drift\n&/' "$M/collectors/x/collect-x.sh"
check "drift is reported"                 '! "$M/tools/sync-shared-block.sh" --check >/dev/null'
"$M/tools/sync-shared-block.sh" --apply >/dev/null
check "--apply removes the drift"         '"$M/tools/sync-shared-block.sh" --check >/dev/null'
check "--apply keeps a one-line function" 'grep -qx "keepme() { echo keep; }" "$M/collectors/x/collect-x.sh"'
# a collector without the run helpers block gets it inserted
sed -i '/^# ---- run helpers — DO NOT EDIT/,/^# ---- end run helpers$/d' "$M/collectors/x/collect-x.sh"
check "a missing block is reported"       '"$M/tools/sync-shared-block.sh" --check | grep -q "^MISSING .*block run"'
"$M/tools/sync-shared-block.sh" --apply >/dev/null
check "--apply inserts a missing block"   '"$M/tools/sync-shared-block.sh" --check >/dev/null && bash -n "$M/collectors/x/collect-x.sh"'

# ---- 3. validate.sh --report ------------------------------------------------
echo "== 3. validate.sh --report =="
(cd "$T" && bash "$SK" --stdout > "$T/good.txt" 2>/dev/null)
check "the skeleton's report passes" '"$V" --report "$T/good.txt" >/dev/null' "$("$V" --report "$T/good.txt" 2>&1 | tail -n +2)"
mut() {   # mut NAME SED-EXPR -> expect FAIL
    mf="$T/bad-$(printf '%s' "$1" | tr -c 'a-z0-9' '-').txt"
    sed "$2" "$T/good.txt" > "$mf"
    check "fails: $1" '! "$V" --report "$mf" >/dev/null'
}
mut "header fields out of order"     '3{h;d};4{G}'
mut "a Domain below the top level"   's/^Domain: .*/Domain:         apm\/java/'
mut "a Target with an outcome"       's/^Target: .*/Target:         host\/x@unresolved/'
mut "a Target with spaces"           's/^Target: .*/Target:         host\/x@command not found: mysql/'
mut "a version that is not x.y.z"    's/^Version: .*/Version:        1.2/'
mut "a gap in the numbering"         's/^\[3\] /[4] /'
mut "an environment with no privilege line" '/^    privilege: /d'
mut "an environment with no boot line"      '/^    host boot(UTC): /d'
mut "goals that do not add up"       's/1 obtained, 0 not applicable here, 1 blocked/1 obtained, 0 not applicable here, 2 blocked/'
mut "COMPLETE with a blocked goal"   's/^    status: INCOMPLETE/    status: COMPLETE/'
mut "no footer"                      '$d'
mut "text after the footer"          '$a\trailing'
cp "$T/good.txt" "$T/whatap-other-host-20260101T000000Z.txt"
check "fails: a file name with another token" '! "$V" --report "$T/whatap-other-host-20260101T000000Z.txt" >/dev/null'

# a pipe into _bounded is refused at the source; `||` is not a pipe
sed 's/^COLLECTOR_NAME=.*/COLLECTOR_NAME="whatap-pipetest"/' "$SK" > "$T/collect-pipetest.sh"
printf 'y() { printf a | _bounded cat; }\nz() { _bounded true || _bounded false; }\n' >> "$T/collect-pipetest.sh"
check "validate: a pipe into _bounded fails, and names the line" '"$V" "$T/collect-pipetest.sh" 2>&1 | grep -q "a pipe into _bounded (line [0-9]*)"'
check "validate: || _bounded is not taken for a pipe" '[ "$("$V" "$T/collect-pipetest.sh" 2>&1 | grep -c "a pipe into _bounded (line [0-9]*)")" = 1 ] && ! "$V" "$T/collect-pipetest.sh" 2>&1 | grep -q "line [0-9]* [0-9]"'

sed -e 's/^COLLECTOR_NAME=.*/COLLECTOR_NAME="whatap-cttest"/' -e 's/^CMD_TIMEOUT=.*/CMD_TIMEOUT=20/' "$SK" > "$T/collect-cttest.sh"
check "validate: a fixed CMD_TIMEOUT=N is refused" '"$V" "$T/collect-cttest.sh" 2>&1 | grep -q "CMD_TIMEOUT is set to a fixed number"'
out="$(CMD_TIMEOUT=7 sh -c 'set -- --stdout; . "$0" >/dev/null 2>&1; echo "ct=$CMD_TIMEOUT"' "$T/lib.sh")"
check "the skeleton keeps a CMD_TIMEOUT from the environment" '[ "$out" = ct=7 ]' "$out"

# ---- 4. every collector, for real -------------------------------------------
echo "== 4. every shell collector, run here =="
if [ "$QUICK" = 1 ]; then
    skip "--quick: no collector runs"
else
    R="$T/runs"; mkdir -p "$R"
    # The runs are independent, so they run at once and are checked after: one
    # after another they took 130s, most of it k8s alone.
    cols="$(cd "$ROOT" && git ls-files 'collectors/*.sh')"
    for c in $cols; do
        b="$(basename "$c" .sh)"; extra=""
        [ "$b" = collect-collmysql ] && extra=--no-sudo
        # shellcheck disable=SC2086
        (cd "$R" && timeout 400 bash "$ROOT/$c" --stdout $extra </dev/null > "$R/$b.txt" 2> "$R/$b.err") &
        case "$c" in collectors/apm/*)
            if command -v dash >/dev/null 2>&1; then
                (cd "$R" && timeout 400 dash -s -- --stdout < "$ROOT/$c" > "$R/$b.dash.txt" 2> "$R/$b.dash.err") &
                (cd "$R" && timeout 400 bash -s -- --stdout < "$ROOT/$c" > "$R/$b.bashs.txt" 2> "$R/$b.bashs.err") &
            fi ;;
        esac
    done
    wait
    for c in $cols; do
        b="$(basename "$c" .sh)"
        check "$b: the report passes --report" '"$V" --report "$R/$b.txt" >/dev/null' \
              "$("$V" --report "$R/$b.txt" 2>&1 | sed -n 2,4p | tr '\n' ' ')"
        case "$c" in collectors/apm/*)
            if command -v dash >/dev/null 2>&1; then
                check "$b: under dash too" '"$V" --report "$R/$b.dash.txt" >/dev/null && ! grep -q "Bad substitution" "$R/$b.dash.err"'
                check "$b: under bash -s too" '"$V" --report "$R/$b.bashs.txt" >/dev/null'
            fi ;;
        esac
    done
    # --file into a directory the run cannot write: says so, exits non-zero
    mkdir -p "$R/ro" && chmod 555 "$R/ro"
    for c in collectors/nms/collect-nms.sh collectors/apm/python/collect-apmpython.sh; do
        (cd "$R/ro" && timeout 400 bash "$ROOT/$c" --file </dev/null > "$R/ro.out" 2> "$R/ro.err")
        # shellcheck disable=SC2034  # read inside check's eval
        rc=$?
        check "$(basename "$c" .sh): an unwritable --file exits non-zero and says so" \
              '[ "$rc" -ne 0 ] && grep -q "^!! the report was not written" "$R/ro.err" && ! grep -q "report written" "$R/ro.err"'
    done
fi

echo
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
