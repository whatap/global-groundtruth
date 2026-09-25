#!/usr/bin/env bash
#
# test-collzfs.sh — behaviour tests for the collection-server ZFS collector.
# -----------------------------------------------------------------------------
# Usage:  tools/test-collzfs.sh [path/to/collect-collzfs.sh]
#
# validate.sh checks the SHAPE of a collector's source. This checks what this
# one DOES about the question it exists for: is there a pool, and did the run
# see it. "No pool" is an answer only when `zpool list` ran and listed none; a
# list that was refused or hung has not shown that, and 0.5.x reported both as
# "none imported", COMPLETE.
#
# The ZFS cases run against a stub `zpool` first on PATH, so they behave the
# same on a machine with no ZFS at all. They assume the machine has no real
# /proc/spl/kstat/zfs; a group that needs that says so rather than passing.
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
C="${1:-$(cd "$(dirname "$0")/.." && pwd)/collectors/collection-server/collect-collzfs.sh}"
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

# A PATH of the ordinary tools and no zfs userland; each group adds its own
# zpool stub. ZPOOL_MODE picks what the stub does.
S="$ROOT/stub"; mkdir -p "$S"
for c in cat ls date wc tail head sed awk grep tr id hostname find sort mktemp cp rm mkdir chmod \
         tar uname stat df free ps sh bash dirname basename sleep cut uniq expr touch env timeout \
         readlink findmnt lsblk kill xargs; do
  p="$(type -P "$c" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$S/$c"
done
stub_write "$S/zpool" <<'STUB'
#!/bin/sh
case "${ZPOOL_MODE:-empty}" in
  denied)   echo "cannot open '/dev/zfs': Permission denied" >&2; exit 1 ;;
  nomodule) echo "The ZFS modules are not loaded." >&2
            echo "Try running '/sbin/modprobe zfs' as root to load them." >&2; exit 1 ;;
  hang)     exec sleep 600 ;;
  onepool)  [ "$*" = "list -H -o name" ] && echo tank; exit 0 ;;
  twopools) [ "$*" = "list -H -o name" ] && printf 'tank\nsafe\n'; exit 0 ;;
  *)        exit 0 ;;
esac
STUB
# A zfs stub beside it, for the dataset goal. ZFS_MODE as above; "none" makes
# it absent from the stub PATH (see nozfs below).
stub_write "$S/zfs" <<'STUB'
#!/bin/sh
case "${ZFS_MODE:-empty}" in
  nomodule) echo "The ZFS modules are not loaded." >&2; exit 1 ;;
  snapfail) case "$*" in *snapshot*) echo "cannot iterate snapshots: permission denied" >&2; exit 1 ;; esac; exit 0 ;;
  hang)     exec sleep 600 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$S/zpool" "$S/zfs"
# The same PATH without any zfs userland, for the kstat-only case.
S0="$ROOT/stub0"; stub_clone "$S" "$S0"; rm -f "$S0/zpool" "$S0/zfs"
goals() { printf '%s' "$1" | grep -o 'goals: .*' | head -1; }
if [ -d /proc/spl/kstat/zfs ]; then
  echo "this machine runs ZFS; the stubbed groups assume it does not"
  HAVE_ZFS=1
else HAVE_ZFS=0; fi

echo "== 1. a host with no ZFS: COMPLETE, both goals n/a =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(PATH="$S0" "$C" --stdout --no-filesizes </dev/null 2>/dev/null)"
  has "footer sentinel" "$out" "==== END OF COLLECTION (no diagnosis by design) ===="
  chk "two goals, both n/a" "goals: 2 declared, 0 obtained, 2 not applicable here, 0 blocked" "$(goals "$out")"
  has "the reason says what was read, not what the host is" "$out" "no zfs or zpool command and no /proc/spl/kstat/zfs on this host"
  hasnt "stdout carries no narration" "$out" ">> "
else skip "the no-ZFS case (this machine has a kstat tree)"; fi

echo "== 2. zpool list refused: blocked, not 'none imported' =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(ZPOOL_MODE=denied PATH="$S" "$C" --stdout --no-filesizes </dev/null 2>/dev/null)"
  # 0.5.x: "2 declared, 1 obtained, 1 not applicable here, 0 blocked" (none imported)
  chk "the refused list is the blocked goal" "goals: 3 declared, 1 obtained, 1 not applicable here, 1 blocked" "$(goals "$out")"
  has "the pools goal carries zpool's words" "$out" "pool topology and properties — zpool list failed for uid $(id -u) (exit 1): cannot open '/dev/zfs': Permission denied"
  has "section [1] says the list failed" "$out" "pools discovered: n/a (zpool list exit 1"
  has "per-pool lines say why no pool was asked about" "$out" "leaf device paths: n/a (not queried: zpool list exit 1: cannot open"
  err="$(ZPOOL_MODE=denied PATH="$S" "$C" --stdout --no-filesizes --quiet </dev/null 2>&1 >/dev/null)"
  has "the gap reaches the terminal under --quiet" "$err" "status: INCOMPLETE"
else skip "the refused-list case (this machine runs ZFS)"; fi

echo "== 3. no kernel module and no kstat tree: n/a, still COMPLETE =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(ZPOOL_MODE=nomodule ZFS_MODE=nomodule PATH="$S" "$C" --stdout --no-filesizes </dev/null 2>/dev/null)"
  chk "zfs present, pools and datasets n/a" "goals: 3 declared, 1 obtained, 2 not applicable here, 0 blocked" "$(goals "$out")"
  has "the reason names the module" "$out" "zfs kernel module not loaded (/proc/spl/kstat/zfs absent; zpool: The ZFS modules are not loaded.)"
else skip "the module-not-loaded case (this machine runs ZFS)"; fi

echo "== 4. zpool list and zfs get ran and listed nothing: n/a =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(PATH="$S" "$C" --stdout --no-filesizes </dev/null 2>/dev/null)"
  chk "zfs present, pools and datasets n/a" "goals: 3 declared, 1 obtained, 2 not applicable here, 0 blocked" "$(goals "$out")"
  has "the reason says the list ran" "$out" "zpool list ran and listed no imported pool"
  has "[1] says the list ran and listed none" "$out" "pools discovered: 0 (zpool list ran and listed none)"
  has "per-pool lines say the list was empty" "$out" "zpool get all: n/a (zpool list ran and listed no pool)"
  has "an empty snapshot list is 'none', not 'nothing or timed out'" "$out" "snapshot detail: none (zfs list -t snapshot ran and listed no snapshot)"
else skip "the empty-list case (this machine runs ZFS)"; fi

echo "== 5. a zpool that hangs: the footer is reached, and later calls are skipped =="
if [ "$HAVE_ZFS" = 0 ]; then
  t0=$(date +%s)
  out="$(ZPOOL_MODE=hang CMD_TIMEOUT=3 RUN_DEADLINE=90 PATH="$S" "$C" --stdout --no-filesizes </dev/null 2>/dev/null)"
  t1=$(date +%s)
  has "the footer is reached" "$out" "==== END OF COLLECTION"
  has "the pools goal names the cap" "$out" "pool topology and properties — zpool list did not answer within 3s"
  has "later zpool calls say they were skipped" "$out" "n/a (skipped: zpool hung earlier (zpool list did not answer within 3s))"
  hasnt "and none of them claims its own timeout" "$out" "n/a (timed out: 3s)"
  has "[1] says why no pool was counted" "$out" "pools discovered: n/a (zpool list did not answer within 3s)"
  has "zpool history says it was not queried, and why" "$out" "zpool history: n/a (not queried: zpool list did not answer within 3s)"
  hasnt "no 'no vdev ... was parsed' after a skip" "$out" "no vdev in the logs allocation class was parsed"
  [ $((t1 - t0)) -le 30 ] && ok "well inside the deadline ($((t1 - t0))s for CMD_TIMEOUT=3)" \
    || bad "well inside the deadline" "<= 30s" "$((t1 - t0))s"
  chk "no stub left running" "" "$(pgrep -f "$S/zpool" 2>/dev/null | head -1)"
else skip "the hanging-zpool case (this machine runs ZFS)"; fi

echo "== 5b. a zfs that hangs: datasets blocked, not '0 discovered' =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(ZPOOL_MODE=onepool ZFS_MODE=hang CMD_TIMEOUT=1 RUN_DEADLINE=90 PATH="$S" "$C" --stdout --no-filesizes </dev/null 2>/dev/null)"
  has "the dataset goal is blocked with the cap" "$out" "dataset properties and snapshots — zfs get did not answer within 4s"
  has "[1] does not count datasets it did not see" "$out" "filesystems+volumes discovered: n/a (zfs get did not answer within 4s)"
  hasnt "and no '0 discovered'" "$out" "filesystems+volumes discovered: 0"
  has "the snapshot detail says skipped, not 'nothing or timed out'" "$out" "snapshot detail: n/a (skipped: zfs hung earlier"
  has "INCOMPLETE" "$out" "status: INCOMPLETE"
  chk "no stub left running" "" "$(pgrep -f "$S/zfs" 2>/dev/null | head -1)"
else skip "the hanging-zfs case (this machine runs ZFS)"; fi

echo "== 5d. a snapshot list that fails carries zfs's own words =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(ZPOOL_MODE=onepool ZFS_MODE=snapfail PATH="$S" "$C" --stdout --no-filesizes </dev/null 2>/dev/null)"
  has "the snapshot detail names zfs's first stderr line" "$out" "snapshot detail: n/a (zfs list -t snapshot exit 1: cannot iterate snapshots: permission denied)"
  has "and so does the blocked goal" "$out" "dataset properties and snapshots — zfs list -t snapshot failed (exit 1): cannot iterate snapshots: permission denied"
  has "and the snapshot count is n/a, not 0" "$out" "snapshot count (all pools): n/a (zfs list -t snapshot exit 1: cannot iterate snapshots: permission denied)"
else skip "the snapshot-failure case (this machine runs ZFS)"; fi

echo "== 5e. --zdb: the deadline grows per pool =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(ZPOOL_MODE=twopools PATH="$S" "$C" --stdout --no-filesizes --zdb </dev/null 2>/dev/null)"
  # 300 + 4000 for the first pool + 3720 for the second
  has "two pools: 300 + 4000 + 3720" "$out" "run deadline(s): 8020"
else skip "the --zdb deadline case (this machine runs ZFS)"; fi

echo "== 5c. a kstat tree but no zpool or zfs: blocked =="
K="$ROOT/kstat"; mkdir -p "$K"
out="$(COLLZFS_KSTAT_DIR="$K" PATH="$S0" "$C" --stdout --no-filesizes </dev/null 2>/dev/null)"
has "pools blocked: the tool is absent while the kernel side is there" "$out" "pool topology and properties — command not found: zpool (while $K exists)"
has "datasets blocked the same way" "$out" "dataset properties and snapshots — command not found: zfs"
has "[1] says zpool is absent, not '0 (none)'" "$out" "pools discovered: n/a (command not found: zpool)"

echo "== 6. a file-size walk that cannot read part of the tree is PARTIAL =="
if [ "$HAVE_ZFS" = 0 ] && [ "$(id -u)" != 0 ]; then
  T="$ROOT/tree"; mkdir -p "$T/ok" "$T/locked/deep"; head -c 5000 /dev/zero > "$T/ok/a"; : >| "$T/locked/deep/b"
  chmod 000 "$T/locked"
  out="$(ZPOOL_MODE=empty PATH="$S" "$C" --stdout --filesizes="$T" </dev/null 2>/dev/null)"
  has "the histogram says PARTIAL" "$out" "(PARTIAL: find exited 1; 1 directories or files could not be read by uid $(id -u)"
  has "and still carries the buckets it got" "$out" "<=8K"
  chmod 755 "$T/locked"
  out="$(ZPOOL_MODE=empty PATH="$S" "$C" --stdout --filesizes="$T" </dev/null 2>/dev/null)"
  hasnt "a readable tree is not PARTIAL" "$out" "PARTIAL"
else skip "the unreadable-subtree case (needs a non-root account on a machine without ZFS)"; fi

echo "== 7. options and output =="
o="$("$C" 2>/dev/null)"; rc=$?
has "help on stdout" "$o" "collect-collzfs.sh"; chk "help exits 0" "0" "$rc"
chk "bad argument exits 2" "2" "$("$C" --nonsense >/dev/null 2>&1; echo $?)"
for a in "--sample=x" "--hours 1.5" "--filesizes-secs -3" "--event-days abc"; do
  # shellcheck disable=SC2086
  err="$("$C" --stdout $a </dev/null 2>&1 >/dev/null)"; rc=$?
  chk "$a exits 2" "2" "$rc"
  has "$a names the option" "$err" "${a%%[ =]*} takes a non-negative integer"
done
if [ "$(id -u)" != 0 ]; then
  RO="$ROOT/ro"; mkdir -p "$RO"; chmod 555 "$RO"
  err="$("$C" --bundle --no-filesizes --out "$RO" </dev/null 2>&1 >/dev/null)"; rc=$?
  chk "bundle into an unwritable --out exits 1" "1" "$rc"
  has "and says so" "$err" "is not writable by uid"
  chmod 755 "$RO"
else skip "the unwritable --out case (root writes anywhere)"; fi
B="$ROOT/b"; mkdir -p "$B"
( cd "$B" && "$C" --bundle --no-filesizes --out . </dev/null >/dev/null 2>&1 ); rc=$?
t="$(ls "$B"/*.tar.gz 2>/dev/null)"
chk "a bundle exits 0" "0" "$rc"
if [ -n "$t" ]; then
  has "the bundle carries the report" "$(tar tzf "$t")" "./report.txt"
  chk "and leaves no work dir beside it" "1" "$(ls -A "$B" | wc -l | tr -d ' ')"
else bad "bundle written" "a .tar.gz" "none"; fi

echo "== 8. read from stdin (bash -s): the /proc scan still sees a JVM =="
H8="$ROOT/home8"; mkdir -p "$H8/conf"
( exec -a "java -Dwhatap.server.home=$H8 -jar whatap.server.yard.jar" sleep 60 ) >/dev/null 2>&1 </dev/null &
jvm=$!
sleep 1
out="$(PATH="$S0" bash -s -- --stdout --no-filesizes < "$C" 2>/dev/null)"
kill "$jvm" 2>/dev/null; wait "$jvm" 2>/dev/null
has "bash -s: WHATAP_HOME comes from a whatap JVM" "$out" "(-Dwhatap.server.home)"

echo; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
