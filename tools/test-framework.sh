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
_timeout_bin=""
t0=$(date +%s); probe "slow grandchild" sh -c 'sleep 30'; echo "took-watchdog $(( $(date +%s) - t0 ))"
echo "piped: $(echo abc | _bounded tr a-z A-Z)"
echo "tmpdir: $_tmp_dir"
goal a "A"; goal a "A again"; goal b "B"; goal c "C"; goal d "D"; goal e "E"
got a; got a
missed b "refused"; got b
missed c "line one
line	two"; na c "none"
na d "empty"
got stray
emit_status
RUN_DEADLINE=1; sleep 2
probe "late" echo hi
emit_status | grep 'run deadline'
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
    check "the watchdog reaches a grandchild"               'printf "%s" "$out" | grep -Eq "took-watchdog [2-4]$"' \
          "an orphaned grandchild holds \$(...) open; took: $(printf '%s' "$out" | grep took-watchdog)"
    check "_bounded passes stdin through"                   'printf "%s" "$out" | grep -q "piped: ABC"'
    check "a duplicate goal counts once"                    'printf "%s" "$out" | grep -q "goals: 5 declared, 1 obtained, 1 not applicable here, 3 blocked"'
    check "missed then got is blocked, and says so"         'printf "%s" "$out" | grep -q "B — resolved 2 times: missed, got — refused"'
    check "a reason with newlines and tabs stays one line"  'printf "%s" "$out" | grep -q "C — resolved 2 times: missed, na — line one line two"'
    check "an undeclared resolution is listed"              'printf "%s" "$out" | grep -q "resolved but never declared: stray"'
    check "an unresolved goal is not reached"               'printf "%s" "$out" | grep -q "E — not reached"'
    check "past the deadline a probe does not run"          'printf "%s" "$out" | grep -q "late: n/a (run deadline reached: 1s)"'
    check "the status names the deadline"                   'printf "%s" "$out" | grep -q "run deadline: reached at 1s"'
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
LIB="$T/lib.sh" OUT="$T/intr.dir" bash "$T/intr.sh" 2>/dev/null &
ip=$!; sleep 1; kill -INT "$ip" 2>/dev/null; wait "$ip" 2>/dev/null
d="$(cat "$T/intr.dir" 2>/dev/null)"
check "INT removes the run's directory" '[ -n "$d" ] && [ ! -e "$d" ]' "left: $d"

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

# ---- 4. every collector, for real -------------------------------------------
echo "== 4. every shell collector, run here =="
if [ "$QUICK" = 1 ]; then
    skip "--quick: no collector runs"
else
    R="$T/runs"; mkdir -p "$R"
    for c in $(cd "$ROOT" && git ls-files 'collectors/*.sh'); do
        b="$(basename "$c" .sh)"; extra=""
        [ "$b" = collect-collmysql ] && extra=--no-sudo
        # shellcheck disable=SC2086
        (cd "$R" && timeout 400 bash "$ROOT/$c" --stdout $extra </dev/null > "$R/$b.txt" 2> "$R/$b.err")
        check "$b: the report passes --report" '"$V" --report "$R/$b.txt" >/dev/null' \
              "$("$V" --report "$R/$b.txt" 2>&1 | sed -n 2,4p | tr '\n' ' ')"
        case "$c" in collectors/apm/*)
            if command -v dash >/dev/null 2>&1; then
                (cd "$R" && timeout 400 dash -s -- --stdout < "$ROOT/$c" > "$R/$b.dash.txt" 2> "$R/$b.dash.err")
                check "$b: under dash too" '"$V" --report "$R/$b.dash.txt" >/dev/null && ! grep -q "Bad substitution" "$R/$b.dash.err"'
                (cd "$R" && timeout 400 bash -s -- --stdout < "$ROOT/$c" > "$R/$b.bashs.txt" 2> "$R/$b.bashs.err")
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
