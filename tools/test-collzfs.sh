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

# The collector finds whatap JVMs with one `xargs grep` over /proc/*/cmdline.
# This xargs, first on PATH, passes on only the PIDs in ONLY_PIDS (empty: none),
# so a whatap-looking process elsewhere on the host (a parallel suite's fake
# JVM) cannot change what a test sees.
mkdir -p "$ROOT/only"
stub_write "$ROOT/only/xargs" <<EOF
#!$(type -P bash)
while IFS= read -r -d '' p; do
    q="\${p#/proc/}"; case " \${ONLY_PIDS:-} " in *" \${q%%/*} "*) printf '%s\\0' "\$p" ;; esac
done | exec $(type -P xargs) -r "\$@"
EOF
export PATH="$ROOT/only:$PATH" ONLY_PIDS=""

# A PATH of the ordinary tools and no zfs userland; each group adds its own
# zpool stub. ZPOOL_MODE picks what the stub does.
S="$ROOT/stub"; mkdir -p "$S"
for c in cat ls date wc tail head sed awk grep tr id hostname find sort mktemp cp rm mkdir chmod \
         tar uname stat df free ps sh bash dirname basename sleep cut uniq expr touch env timeout \
         readlink findmnt lsblk kill xargs; do
  p="$(type -P "$c" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$S/$c"
done
rm -f "$S/xargs"; stub_write "$S/xargs" < "$ROOT/only/xargs"
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
  out="$(PATH="$S0" "$C" --stdout </dev/null 2>/dev/null)"
  has "footer sentinel" "$out" "==== END OF COLLECTION (no diagnosis by design) ===="
  # 0.8.0: the time window is a goal of every run, n/a here too
  chk "three goals, all n/a" "goals: 3 declared, 0 obtained, 3 not applicable here, 0 blocked" "$(goals "$out")"
  has "the reason says what was read, not what the host is" "$out" "no zfs or zpool command and no /proc/spl/kstat/zfs on this host"
  has "[1] does not claim a window ran" "$out" "window=n/a (no ZFS on this host)"
  hasnt "stdout carries no narration" "$out" ">> "
else skip "the no-ZFS case (this machine has a kstat tree)"; fi

echo "== 2. zpool list refused: blocked, not 'none imported' =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(ZPOOL_MODE=denied PATH="$S" "$C" --stdout </dev/null 2>/dev/null)"
  # 0.5.x: "2 declared, 1 obtained, 1 not applicable here, 0 blocked" (none imported)
  chk "the refused list is the blocked goal" "goals: 4 declared, 1 obtained, 2 not applicable here, 1 blocked" "$(goals "$out")"
  has "the pools goal carries zpool's words" "$out" "pool topology and properties — zpool list failed for uid $(id -u) (exit 1): cannot open '/dev/zfs': Permission denied"
  has "section [1] says the list failed" "$out" "pools discovered: n/a (zpool list exit 1"
  has "per-pool lines say why no pool was asked about" "$out" "leaf device paths: n/a (not queried: zpool list exit 1: cannot open"
  err="$(ZPOOL_MODE=denied PATH="$S" "$C" --stdout --quiet </dev/null 2>&1 >/dev/null)"
  has "the gap reaches the terminal under --quiet" "$err" "status: INCOMPLETE"
else skip "the refused-list case (this machine runs ZFS)"; fi

echo "== 3. no kernel module and no kstat tree: n/a, still COMPLETE =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(ZPOOL_MODE=nomodule ZFS_MODE=nomodule PATH="$S" "$C" --stdout </dev/null 2>/dev/null)"
  chk "zfs present, pools and datasets n/a" "goals: 4 declared, 1 obtained, 3 not applicable here, 0 blocked" "$(goals "$out")"
  has "the reason names the module" "$out" "zfs kernel module not loaded (/proc/spl/kstat/zfs absent; zpool: The ZFS modules are not loaded.)"
else skip "the module-not-loaded case (this machine runs ZFS)"; fi

echo "== 4. zpool list and zfs get ran and listed nothing: n/a =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(PATH="$S" "$C" --stdout </dev/null 2>/dev/null)"
  chk "zfs present, pools and datasets n/a" "goals: 4 declared, 1 obtained, 3 not applicable here, 0 blocked" "$(goals "$out")"
  has "the reason says the list ran" "$out" "zpool list ran and listed no imported pool"
  has "[1] says the list ran and listed none" "$out" "pools discovered: 0 (zpool list ran and listed none)"
  has "per-pool lines say the list was empty" "$out" "zpool get all: n/a (zpool list ran and listed no pool)"
  has "an empty snapshot list is 'none', not 'nothing or timed out'" "$out" "snapshot detail: none (zfs list -t snapshot ran and listed no snapshot)"
else skip "the empty-list case (this machine runs ZFS)"; fi

echo "== 5. a zpool that hangs: the footer is reached, and later calls are skipped =="
if [ "$HAVE_ZFS" = 0 ]; then
  t0=$(date +%s)
  out="$(ZPOOL_MODE=hang CMD_TIMEOUT=3 RUN_DEADLINE=90 PATH="$S" "$C" --stdout </dev/null 2>/dev/null)"
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
  out="$(ZPOOL_MODE=onepool ZFS_MODE=hang CMD_TIMEOUT=1 RUN_DEADLINE=90 PATH="$S" "$C" --stdout </dev/null 2>/dev/null)"
  has "the dataset goal is blocked with the cap" "$out" "dataset properties and snapshots — zfs get did not answer within 4s"
  has "[1] does not count datasets it did not see" "$out" "filesystems+volumes discovered: n/a (zfs get did not answer within 4s)"
  hasnt "and no '0 discovered'" "$out" "filesystems+volumes discovered: 0"
  has "the snapshot detail says skipped, not 'nothing or timed out'" "$out" "snapshot detail: n/a (skipped: zfs hung earlier"
  has "INCOMPLETE" "$out" "status: INCOMPLETE"
  chk "no stub left running" "" "$(pgrep -f "$S/zfs" 2>/dev/null | head -1)"
else skip "the hanging-zfs case (this machine runs ZFS)"; fi

echo "== 5d. a snapshot list that fails carries zfs's own words =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(ZPOOL_MODE=onepool ZFS_MODE=snapfail PATH="$S" "$C" --stdout </dev/null 2>/dev/null)"
  has "the snapshot detail names zfs's first stderr line" "$out" "snapshot detail: n/a (zfs list -t snapshot exit 1: cannot iterate snapshots: permission denied)"
  has "and so does the blocked goal" "$out" "dataset properties and snapshots — zfs list -t snapshot failed (exit 1): cannot iterate snapshots: permission denied"
  has "and the snapshot count is n/a, not 0" "$out" "snapshot count (all pools): n/a (zfs list -t snapshot exit 1: cannot iterate snapshots: permission denied)"
else skip "the snapshot-failure case (this machine runs ZFS)"; fi

echo "== 5e. --zdb: the deadline grows per pool =="
if [ "$HAVE_ZFS" = 0 ]; then
  out="$(ZPOOL_MODE=twopools PATH="$S" "$C" --stdout --zdb </dev/null 2>/dev/null)"
  # 300 + 4000 for the first pool + 3720 for the second + the 15s window and 60s
  has "two pools: 300 + 4000 + 3720 + 75" "$out" "run deadline(s): 8095"
else skip "the --zdb deadline case (this machine runs ZFS)"; fi

echo "== 5c. a kstat tree but no zpool or zfs: blocked =="
K="$ROOT/kstat"; mkdir -p "$K"
out="$(COLLZFS_KSTAT_DIR="$K" PATH="$S0" "$C" --stdout </dev/null 2>/dev/null)"
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

echo "== 6b. the file-size walk is opt-in (Tier 2) =="
out="$(ZPOOL_MODE=empty PATH="$S" "$C" --stdout </dev/null 2>/dev/null)"
has "without --filesizes it is not requested" "$out" "not requested (--filesizes not given)"
has "and [1] says filesizes=off" "$out" "filesizes=off"

echo "== 7. options and output =="
o="$("$C" 2>/dev/null)"; rc=$?
has "help on stdout" "$o" "collect-collzfs.sh"; chk "help exits 0" "0" "$rc"
chk "bad argument exits 2" "2" "$("$C" --nonsense >/dev/null 2>&1; echo $?)"
for e in "EVENT_DAYS=abc|EVENT_DAYS=abc ignored" "JOURNAL_HOURS=1.5|JOURNAL_HOURS=1.5 ignored" "FILESIZES_SECS=-3|FILESIZES_SECS=-3 ignored"; do
  v="${e%%|*}"
  err="$(env "$v" PATH="$S" "$C" --stdout </dev/null 2>&1 >/dev/null)"
  has "$v is ignored with a warning" "$err" "${e#*|}"
done
out="$(EVENT_DAYS=0 JOURNAL_HOURS=48 PATH="$S" "$C" --stdout </dev/null 2>&1)"
hasnt "EVENT_DAYS=0 (keep everything) is accepted" "$out" "EVENT_DAYS=0 ignored"
if [ "$(id -u)" != 0 ]; then
  RO="$ROOT/ro"; mkdir -p "$RO"; chmod 555 "$RO"
  err="$("$C" --bundle --out "$RO" </dev/null 2>&1 >/dev/null)"; rc=$?
  chk "bundle into an unwritable --out exits 1" "1" "$rc"
  has "and says so" "$err" "is not writable by uid"
  chmod 755 "$RO"
else skip "the unwritable --out case (root writes anywhere)"; fi
B="$ROOT/b"; mkdir -p "$B"
( cd "$B" && "$C" --bundle --out . </dev/null >/dev/null 2>&1 ); rc=$?
t="$(ls "$B"/*.tar.gz 2>/dev/null)"
chk "a bundle exits 0" "0" "$rc"
if [ -n "$t" ]; then
  has "the bundle carries the report" "$(tar tzf "$t")" "./report.txt"
  has "and df -i, the file count without a walk" "$(tar tzf "$t")" "df-i.txt"
  chk "and leaves no work dir beside it" "1" "$(ls -A "$B" | wc -l | tr -d ' ')"
else bad "bundle written" "a .tar.gz" "none"; fi

echo "== 8. read from stdin (bash -s): the /proc scan still sees a JVM =="
H8="$ROOT/home8"; mkdir -p "$H8/conf"
( exec -a "java -Dwhatap.server.home=$H8 -jar whatap.server.yard.jar" sleep 60 ) >/dev/null 2>&1 </dev/null &
jvm=$!
sleep 1
out="$(ONLY_PIDS="$jvm" PATH="$S0" bash -s -- --stdout < "$C" 2>/dev/null)"
kill "$jvm" 2>/dev/null; wait "$jvm" 2>/dev/null
has "bash -s: WHATAP_HOME comes from a whatap JVM" "$out" "(-Dwhatap.server.home)"

echo "== 9. WHATAP_HOME from a whatap JVM's working directory =="
H9="$ROOT/home9"; mkdir -p "$H9/conf"; : >| "$H9/conf/yard.conf"
( cd "$H9" && exec -a "java -jar whatap.server.yard.jar" sleep 60 ) >/dev/null 2>&1 </dev/null &
jvm=$!
sleep 1
out="$(ONLY_PIDS="$jvm" PATH="$S0" "$C" --stdout </dev/null 2>/dev/null)"
kill "$jvm" 2>/dev/null; wait "$jvm" 2>/dev/null
has "the home is the JVM's cwd" "$out" "WHATAP_HOME: $H9"
has "and says so" "$out" "working directory"

echo "== 10. a whatap JVM whose cwd this uid cannot read: blocked, not n/a =="
if [ "$(id -u)" != 0 ] && sudo -n true 2>/dev/null; then
  sudo -n -u nobody bash -c 'cd /tmp && exec -a "java -jar whatap.server.yard.jar" sleep 60' >/dev/null 2>&1 </dev/null &
  sleep 1
  opid="$(pgrep -u nobody -f '^java -jar whatap.server.yard.jar' | head -1)"
  out="$(ONLY_PIDS="$opid" PATH="$S0" "$C" --stdout </dev/null 2>/dev/null)"
  [ -n "$opid" ] && sudo -n kill "$opid" 2>/dev/null; wait 2>/dev/null
  has "the cwd is said to be unreadable" "$out" "whatap JVM working directory: n/a (not readable by uid $(id -u): pid"
  has "and the paths goal is blocked with the privilege hint" "$out" "WhaTap path to dataset mapping — whatap JVM pid"
  has "which names the uid" "$out" "its cwd not readable by uid $(id -u) (not elevated: run again with sudo)"
  has "and the run is INCOMPLETE" "$out" "status: INCOMPLETE"
else skip "the unreadable-cwd case (needs a non-root account with passwordless sudo)"; fi

echo "== 11. only a java process that runs a server module counts =="
F11="$ROOT/f11"; mkdir -p "$F11"; : >| "$F11/whatap.server.log"
( cd "$F11" && exec -a "java -Dwhatap.server.host=10.0.0.1 -jar app.jar" sleep 60 ) >/dev/null 2>&1 </dev/null &
p1=$!
tail -f "$F11/whatap.server.log" >/dev/null 2>&1 </dev/null &
p2=$!
sleep 1
out="$(ONLY_PIDS="$p1 $p2" PATH="$S0" "$C" --stdout </dev/null 2>/dev/null)"
kill "$p1" "$p2" 2>/dev/null; wait "$p1" "$p2" 2>/dev/null
hasnt "an app JVM with the agent and a tail of a whatap log: no paths goal" "$out" "WhaTap path to dataset mapping"
has "and the host stays COMPLETE" "$out" "status: COMPLETE"

echo "== 12. the paths goal is declared whatever route resolved the home =="
H12="$ROOT/home12"; mkdir -p "$H12/conf"
( exec -a "java -Dwhatap.server.home=$H12 -jar whatap.server.yard.jar" sleep 60 ) >/dev/null 2>&1 </dev/null &
jvm=$!
sleep 1
out="$(ONLY_PIDS="$jvm" PATH="$S0" "$C" --stdout </dev/null 2>/dev/null)"
has "-Dwhatap.server.home: the goal is declared and obtained" "$out" "obtained: WhaTap path to dataset mapping"
out="$(ONLY_PIDS="$jvm" PATH="$S0" "$C" --stdout --home "$ROOT/home12" </dev/null 2>/dev/null)"
has "--home with a module running: declared too" "$out" "WhaTap path to dataset mapping"
kill "$jvm" 2>/dev/null; wait "$jvm" 2>/dev/null
( exec -a "java -Dwhatap.server.home=$ROOT/gone12 -jar whatap.server.yard.jar" sleep 60 ) >/dev/null 2>&1 </dev/null &
jvm=$!
sleep 1
out="$(ONLY_PIDS="$jvm" PATH="$S0" "$C" --stdout </dev/null 2>/dev/null)"
kill "$jvm" 2>/dev/null; wait "$jvm" 2>/dev/null
# na_block REPORT -> only the lines under "not applicable to this host"
na_block() { printf '%s\n' "$1" | awk '/not applicable to this host/ {f=1; next} f && /^        / {print; next} {f=0}'; }
nas="$(na_block "$out")"
has "a home that does not exist: n/a, path not found" "$nas" "WhaTap path to dataset mapping — WHATAP_HOME $ROOT/gone12 (via process $jvm (-Dwhatap.server.home)): path not found"
has "and the run stays COMPLETE" "$out" "status: COMPLETE"
# home12_case HOME -> the report with a module whose -D home is HOME
home12_case() {
    ( exec -a "java -Dwhatap.server.home=$1 -jar whatap.server.yard.jar" sleep 60 ) >/dev/null 2>&1 </dev/null &
    local j=$!
    sleep 1
    ONLY_PIDS="$j" PATH="$S0" "$C" --stdout </dev/null 2>/dev/null
    kill "$j" 2>/dev/null; wait "$j" 2>/dev/null
}
out="$(home12_case "$ROOT/nodata12/whatap")"
has "a missing parent too (a /data/whatap on a host without /data): path not found" \
    "$(na_block "$out")" "WHATAP_HOME $ROOT/nodata12/whatap (via process"
has "and COMPLETE" "$out" "status: COMPLETE"
ln -s "$ROOT/gone12b" "$ROOT/link12"
out="$(home12_case "$ROOT/link12")"
has "a dangling home link says so" "$out" "WHATAP_HOME $ROOT/link12 (via process"
has "as a dangling symlink, not applicable" "$(na_block "$out")" "dangling symlink to $ROOT/gone12b"
printf '%s' "$out" | grep -q "$ROOT/link12 (via process.*is not readable" && bad "not as unreadable" "absent" "present" || ok "not as unreadable"
if [ "$(id -u)" != 0 ]; then
    mkdir -p "$ROOT/locked12"; chmod 000 "$ROOT/locked12"
    out="$(home12_case "$ROOT/locked12")"
    has "an unlistable home: blocked with the uid and the hint" "$out" "WHATAP_HOME $ROOT/locked12 (via process"
    has "which names the uid" "$out" "is not readable by uid $(id -u) (not elevated: run again with sudo)"
    chmod 755 "$ROOT/locked12"
else skip "the unlistable-home case (root lists everything)"; fi

echo "== 13. the default report has df -i for every WhaTap path that exists =="
# 0.6.2 put the file count in df -i instead of a walk; the bundle test above
# covers df-i.txt, this the report.
H13="$ROOT/home13"; mkdir -p "$H13/conf" "$H13/logs" "$H13/yardbase"
out="$(PATH="$S0" "$C" --stdout --home "$H13" </dev/null 2>/dev/null)"
for p13 in "$H13" "$H13/yardbase" "$H13/logs" "$H13/conf"; do
  has "df -i $p13" "$out" "df -i $p13:"
done
hasnt "and none for a path that is not there" "$out" "df -i $H13/db"
chk "one df -i per distinct present path" "4" "$(printf '%s\n' "$out" | grep -c '^    df -i ')"

echo "== 14. 0.7.0: zpool list -v is asked once, for the raw lines and the bundle =="
S14="$ROOT/stub14"; stub_clone "$S" "$S14"; ZC14="$ROOT/zcalls14"; : >| "$ZC14"
p14="$(type -P gzip 2>/dev/null)" && [ -n "$p14" ] && ln -sf "$p14" "$S14/gzip"   # tar -z
stub_write "$S14/zpool" <<STUB
#!/bin/sh
echo "zpool \$*" >> "$ZC14"
case "\$*" in
  "list -H -o name") echo tank ;;
  "list -v")
    echo "NAME        SIZE  ALLOC   FREE  CKPOINT  EXPANDSZ   FRAG    CAP  DEDUP    HEALTH  ALTROOT"
    echo "tank       7.27T  5.10T  2.17T        -         -    41%    70%  1.00x    ONLINE  -"
    echo "  raidz2-0 7.27T  5.00T  2.27T        -         -    42%  68.7%      -    ONLINE"
    echo "    sda    1.82T      -      -        -         -      -      -      -    ONLINE"
    echo "    sdb    1.82T      -      -        -         -      -      -      -    ONLINE" ;;
esac
exit 0
STUB
out="$(PATH="$S14" "$C" --stdout </dev/null 2>/dev/null)"
chk "--stdout: one zpool list -v" "1" "$(grep -cx 'zpool list -v' "$ZC14")"
has "the raw lines are printed" "$out" "zpool list -v (raw):"
has "the raw lines carry the vdev" "$out" "raidz2-0"
hasnt "0.9.0: no derived class view beside them" "$out" "per-top-level-vdev usage by allocation class"
B14="$ROOT/b14"; mkdir -p "$B14"; : >| "$ZC14"
( cd "$B14" && PATH="$S14" "$C" --bundle --out . </dev/null >/dev/null 2>&1 )
chk "--bundle: still one zpool list -v" "1" "$(grep -cx 'zpool list -v' "$ZC14")"
t14="$(ls "$B14"/*.tar.gz 2>/dev/null | head -1)"
if [ -n "$t14" ]; then
  f14="$(tar -xOzf "$t14" --wildcards '*/zfs/zpool-list-v.txt' 2>/dev/null)"
  has "and zpool-list-v.txt holds the report's answer" "$f14" "  raidz2-0 7.27T"
else bad "a bundle is written" "one .tar.gz" "none"; fi

echo "== 14b. 0.9.0: the zevent ring, zfs get, the snapshot list and zdb are each read once =="
S14b="$ROOT/stub14b"; stub_clone "$S14" "$S14b"; ZC14b="$ROOT/zcalls14b"; : >| "$ZC14b"
stub_write "$S14b/zpool" <<STUB
#!/bin/sh
echo "zpool \$*" >> "$ZC14b"
case "\$*" in
  "list -H -o name") echo tank ;;
  events) echo "TIME                           CLASS"
          echo "Jul  3 2026 00:44:15.230790956 ereport.fs.zfs.deadman"
          echo "Sep 20 2026 01:00:00.000000000 sysevent.fs.zfs.history_event" ;;
  "events -v") echo "TIME                           CLASS"
          printf 'Jul  3 2026 00:44:15.230790956 ereport.fs.zfs.deadman\n        vdev_path = "/dev/sda1"\n\n'
          printf 'Sep 20 2026 01:00:00.000000000 sysevent.fs.zfs.history_event\n        history_hostname = "h"\n\n' ;;
  "iostat -v") echo "tank iostat-v-answer" ;;
esac
exit 0
STUB
stub_write "$S14b/zfs" <<STUB
#!/bin/sh
echo "zfs \$*" >> "$ZC14b"
case "\$*" in
  get*) printf 'tank\trecordsize\t131072\tlocal\ntank\tcompression\tlz4\tdefault\n' ;;
  "list -H -p -t snapshot"*) printf 'tank@a\t100\t200\t1780000000\t0\t5\t-\n' ;;
esac
exit 0
STUB
stub_write "$S14b/zdb" <<STUB
#!/bin/sh
echo "zdb \$*" >> "$ZC14b"
echo "zdb answer \$*"
STUB
out="$(PATH="$S14b" "$C" --stdout </dev/null 2>/dev/null)"
chk "--stdout: the ring is read once" "1" "$(grep -c '^zpool events' "$ZC14b")"
chk "in its short form" "1" "$(grep -cx 'zpool events' "$ZC14b")"
has "L gives each class with its count, first and last date" "$out" "ereport.fs.zfs.deadman                                1  2026-07-03  2026-07-03"
has "and the ring's event count" "$out" "# events in the ring buffer: 2"
has "and the last events from the same read" "$out" "Sep 20 2026 01:00:00.000000000 sysevent.fs.zfs.history_event"
has "E prints the zfs get rows with their source" "$out" "recordsize                 131072                 local"
B14b="$ROOT/b14b"; mkdir -p "$B14b"; : >| "$ZC14b"
( cd "$B14b" && PATH="$S14b" "$C" --bundle --zdb --out . </dev/null >/dev/null 2>&1 )
chk "--bundle: the ring is read once" "1" "$(grep -c '^zpool events' "$ZC14b")"
chk "with -v, for the detail" "1" "$(grep -cx 'zpool events -v' "$ZC14b")"
chk "zfs get all is asked once" "1" "$(grep -c '^zfs get' "$ZC14b")"
chk "the snapshot list once" "1" "$(grep -c '^zfs list -H -p -t snapshot' "$ZC14b")"
chk "zpool iostat -v once" "1" "$(grep -cx 'zpool iostat -v' "$ZC14b")"
for z in "-C tank" "-Lbbbs tank" "-mm tank"; do chk "zdb $z once" "1" "$(grep -cx -- "zdb $z" "$ZC14b")"; done
t14b="$(ls "$B14b"/*.tar.gz 2>/dev/null | head -1)"
if [ -n "$t14b" ]; then
  r14b="$(tar -xOzf "$t14b" ./report.txt 2>/dev/null)"
  has "N names the bundle file and its exit" "$r14b" "zdb -Lbbbs tank: zdb/zdb-Lbbbs-tank.txt, "
  has "the deadline adds the bundle's zdb once: 300 + 900 + 75 + 280 + 7500" "$r14b" "run deadline(s): 9055"
  has "the zdb file holds zdb's whole answer" "$(tar -xOzf "$t14b" ./zdb/zdb-Lbbbs-tank.txt 2>/dev/null)" "zdb answer -Lbbbs tank"
  has "the overview file is the one L printed" "$(tar -xOzf "$t14b" ./zfs/zpool-events-overview.tsv 2>/dev/null)" "# events in the ring buffer: 2"
  has "the vdev tally comes from the same -v read" "$(tar -xOzf "$t14b" ./zfs/zpool-events-tally.tsv 2>/dev/null)" "/dev/sda1"
  has "zfs-get-all-parsable.tsv is discovery's answer" "$(tar -xOzf "$t14b" ./zfs/zfs-get-all-parsable.tsv 2>/dev/null)" "recordsize"
  has "zpool-iostat-v.txt is the report's answer" "$(tar -xOzf "$t14b" ./zfs/zpool-iostat-v.txt 2>/dev/null)" "iostat-v-answer"
else bad "a bundle is written" "one .tar.gz" "none"; fi
stub_write "$S14b/zpool" <<'STUB'
#!/bin/sh
case "$*" in
  "list -H -o name") echo tank ;;
  events) echo "cannot get event: permission denied" >&2; exit 1 ;;
esac
exit 0
STUB
out="$(PATH="$S14b" "$C" --stdout </dev/null 2>/dev/null)"
has "a refused read says zpool's words" "$out" "zpool events: exit 1: cannot get event: permission denied"

echo "== 15. 0.7.0: a feature check or unit journal cut by the run deadline says so =="
# zpool iostat -r and journalctl never answer; systemctl says zfs-zed is loaded.
S15="$ROOT/stub15"; stub_clone "$S" "$S15"
stub_write "$S15/zpool" <<'STUB'
#!/bin/sh
case "$*" in
  "list -H -o name") echo tank ;;
  "iostat -r") exec sleep 600 ;;
esac
exit 0
STUB
stub_write "$S15/journalctl" <<'STUB'
#!/bin/sh
exec sleep 600
STUB
stub_write "$S15/systemctl" <<'STUB'
#!/bin/sh
case "$*" in
  show*) for a in "$@"; do case "$a" in *.service|*.target)
           printf 'Id=%s\n' "$a"; case "$a" in zfs-zed.service) echo LoadState=loaded ;; *) echo LoadState=not-found ;; esac; echo ;;
         esac; done ;;
esac
exit 0
STUB
t0=$(date +%s)
out="$(RUN_DEADLINE=6 CMD_TIMEOUT=30 PATH="$S15" "$C" --stdout </dev/null 2>/dev/null)"
t1=$(date +%s)
has "the feature check cut by the deadline says so" "$out" "zpool iostat -r (request-size histogram): n/a (run deadline reached: 6s)"
has "and so does the unit journal" "$out" "zfs-zed.service: n/a (run deadline reached: 6s)"
hasnt "neither says 'timed out: 30s'" "$out" "(timed out: 30s)"
[ $((t1 - t0)) -le 40 ] && ok "and the run ends ($((t1 - t0))s)" || bad "the run ends" "<= 40s" "$((t1 - t0))s"
out="$(CMD_TIMEOUT=2 PATH="$S15" "$C" --stdout </dev/null 2>/dev/null)"
has "its own cap is still 'timed out'" "$out" "zpool iostat -r (request-size histogram): n/a (timed out: 2s)"
has "for the journal too" "$out" "zfs-zed.service: n/a (timed out: 2s)"

echo "== 16. 0.8.0: --window keeps every txg of the window, merged across reads of the ring =="
# A fake kstat tree whose tank/txgs advances RATE txgs a second and keeps the
# last HIST rows, like the kernel's ring (the newest row open, the one below it
# syncing). No real ZFS is needed. zpool is a stub whose iostat answers.
S16="$ROOT/stub16"; stub_clone "$S" "$S16"
p16="$(type -P gzip 2>/dev/null)" && [ -n "$p16" ] && ln -sf "$p16" "$S16/gzip"   # tar -z
stub_write "$S16/zpool" <<'STUB'
#!/bin/sh
case "$*" in
  "list -H -o name") echo tank ;;
  iostat*-T*) [ -n "${IOLOG:-}" ] && echo "zpool $(date +%s%N) $*" >> "$IOLOG"
              [ "${ZIO_MODE:-}" = hang ] && exec sleep 600
              # interval and count are the last two arguments, as in zpool
              for iv in "$@"; do c="$iv_prev"; iv_prev="$iv"; done; iv="$c"; cnt="$iv_prev"
              n=0; while [ "$n" -lt "$cnt" ]; do echo "Sat Sep 26 20:46:10 WIB 2026"; echo "tank  1.27G  45.2G  0  6  3.30K  1.00M"; n=$((n + 1)); [ "$n" -lt "$cnt" ] && sleep "$iv"; done ;;
esac
exit 0
STUB
# iostat (sysstat): IOSTAT_MODE=noN refuses -N, hang never answers an interval
# run; IOLOG gets its start time (ns), S_TIME_FORMAT and arguments
stub_write "$S16/iostat" <<'STUB'
#!/bin/sh
case " $* " in *" -N "*) [ "${IOSTAT_MODE:-}" = noN ] && { echo "Usage: iostat [ options ]" >&2; exit 1; } ;; esac
case "$*" in *[0-9]) ;; *) echo "Device r/s"; exit 0 ;; esac   # the flag check: no interval
[ -n "${IOLOG:-}" ] && echo "iostat $(date +%s%N) S_TIME_FORMAT=${S_TIME_FORMAT:-} $*" >> "$IOLOG"
[ "${IOSTAT_MODE:-}" = hang ] && exec sleep 600
echo "2026-09-26T20:46:10+0700"; echo "Device r/s w/s w_await aqu-sz %util"; echo "vdd 0.00 9.80 0.29 0.00 0.40"
exit 0
STUB
# txgs_gen DIR RATE HIST SECS -> the fake ring, rewritten each second
txgs_gen() {
  local d="$1" rate="$2" hist="$3" secs="$4" txg=1 b=1000000000000 w=0 t lo end k
  mkdir -p "$d/tank"
  printf '16 1 0x01 13 3536 45081602222 588855183061\nname                            type data\ndmu_tx_assigned                 4    100\ndmu_tx_dirty_frees_delay        4    5\n' >| "$d/dmu_tx"
  printf '19 1 0x01 147 39984 45084514644 6029709809367\nname                            type data\nhits                            4    1000\nmisses                          4    9\n' >| "$d/arcstats"
  end=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$end" ]; do
    for ((k = 0; k < rate; k++)); do txg=$((txg + 1)); b=$((b + 1000000000 / rate)); done
    w=$((w + 37))
    { echo 'txg      birth            state ndirty       nread        nwritten     reads    writes   otime        qtime        wtime        stime       '
      lo=$((txg - hist + 1)); [ "$lo" -lt 1 ] && lo=1
      for ((t = lo; t <= txg; t++)); do
        if [ "$t" -eq "$txg" ]; then printf '%-8s %-16s O     0 0 0 0 0 0 0 0 0\n' "$t" "$((b - (txg - t) * 1000000000 / rate))"
        elif [ "$t" -eq $((txg - 1)) ]; then printf '%-8s %-16s S     %s 0 0 0 0 %s 5000 3000 0\n' "$t" "$((b - (txg - t) * 1000000000 / rate))" "$((t * 4096))" "$((1000000000 / rate))"
        else printf '%-8s %-16s C     %s 0 %s 0 %s %s 5000 3000 %s\n' "$t" "$((b - (txg - t) * 1000000000 / rate))" "$((t * 4096))" "$((t * 8192))" "$((t % 50))" "$((1000000000 / rate))" "$((20000000 + t * 1000))"; fi
      done; } >| "$d/tank/.txgs.tmp" && mv -f "$d/tank/.txgs.tmp" "$d/tank/txgs"
    printf '61 1 0x01 28 7872 75213806221 588860879419\nname                            type data\ndataset_name                    7    tank/data\nwrites                          4    %s\nnwritten                        4    %s\nreads                           4    0\n' "$w" "$((w * 512))" >| "$d/tank/.o.tmp" && mv -f "$d/tank/.o.tmp" "$d/tank/objset-0x36"
    sleep 1
  done
}
K16="$ROOT/k16"; txgs_gen "$K16" 2 20 40 & g16=$!
sleep 2
t0=$(date +%s)
out="$(COLLZFS_KSTAT_DIR="$K16" PATH="$S16" "$C" --stdout --window=12 </dev/null 2>/dev/null)"
t1=$(date +%s)
has "section O is there" "$out" "O. Time window (every run; --window sets its length)"
has "[1] names the window" "$out" "filesizes=off window=12s"
has "a ring that outlasts the interval: no txg unseen" "$out" "txgs never seen (left the ring between two reads): 0"
has "the reads are more than start and end" "$out" "pool tank: "
n16="$(printf '%s\n' "$out" | sed -n 's/.*pool tank: \([0-9]*\) reads.*/\1/p')"
[ "${n16:-0}" -ge 3 ] && ok "the ring is re-read inside the window ($n16 reads)" || bad "re-read inside the window" ">= 3 reads" "${n16:-none}"
hasnt "0.9.0: no percentile table beside the rows kept" "$out" "otime(ms)"
has "an objset counter's delta" "$out" "tank/objset-0x36 (tank/data):"
has "and an unchanged counter is named with its value" "$out" "unchanged: dmu_tx_assigned=100, dmu_tx_dirty_frees_delay=5"
has "zpool iostat -vlq ran over the window, 1s blocks for a 12s window" "$out" "zpool iostat -T d -vlq 1 13 (per vdev"
has "and iostat -x beside it, same interval and count" "$out" "iostat -x -N -t 1 13 (per device"
has "zpool iostat -r for the window" "$out" "zpool iostat -T d -r 12 2 (request-size histogram)"
has "zpool iostat -w for the window" "$out" "zpool iostat -T d -w 12 2 (latency histogram)"
has "arcstat absent: said, with where its counters are" "$out" "n/a (command not found: arcstat; the arcstats counters it reads are in the start/end table above)"
has "the start offset between the two is printed" "$out" "start offset: iostat -x started"
has "the goal is obtained" "$(printf '%s\n' "$out" | grep '^    obtained:')" "time window"
r16="$(printf '%s\n' "$out" | sed -n '/txgs rows kept/,/Collection status/p' | awk '$1 ~ /^[0-9]+$/ { print $1 }')"
chk "rows ascending, each txg once, no hole" "0" "$(printf '%s\n' "$r16" | awk 'NR > 1 && $1 != p + 1 { e++ } { p = $1 } END { print e + 0 }')"
[ $((t1 - t0)) -le 25 ] && ok "bounded ($((t1 - t0))s for a 12s window: the interval jobs end with it)" || bad "bounded" "<= 25s" "$((t1 - t0))s"
hasnt "no interval job was stopped at the window end" "$out" ": the window ended (output up to then below)"
hasnt "no double slash in a kstat path" "$out" "tank//"
has "the per-pool zil path is <pool>/zil" "$out" "zil: n/a (path not found: $K16/tank/zil)"
kill "$g16" 2>/dev/null; wait "$g16" 2>/dev/null

echo "== 17. 0.8.0: txgs that leave the ring between two reads are counted as gaps =="
K17="$ROOT/k17"; txgs_gen "$K17" 6 5 40 & g17=$!
sleep 2
out="$(COLLZFS_KSTAT_DIR="$K17" PATH="$S16" "$C" --stdout --window=10 </dev/null 2>/dev/null)"
kill "$g17" 2>/dev/null; wait "$g17" 2>/dev/null
g="$(printf '%s\n' "$out" | sed -n 's/.*txgs never seen (left the ring between two reads): \([0-9]*\).*/\1/p')"
[ "${g:-0}" -gt 0 ] && ok "gaps counted ($g txgs)" || bad "gaps counted" "> 0" "${g:-none}"
has "each gap range is listed" "$out" "missing from the read at"
has "the window goal is blocked with the count" "$out" "txgs left the ring unseen"
has "and the run is INCOMPLETE" "$out" "status: INCOMPLETE"
rows17="$(printf '%s\n' "$out" | sed -n '/txgs rows kept/,/Collection status/p' | awk '$1 ~ /^[0-9]+$/' | wc -l | tr -d ' ')"
kept17="$(printf '%s\n' "$out" | sed -n 's/.*rows kept: \([0-9]*\).*/\1/p')"
chk "the rows printed are the rows kept" "$kept17" "$rows17"

echo "== 18. 0.8.0: a signal ends the window early and the report is still written =="
K18="$ROOT/k18"; txgs_gen "$K18" 2 20 40 & g18=$!
sleep 2
O18="$ROOT/o18"; t0=$(date +%s)
COLLZFS_KSTAT_DIR="$K18" PATH="$S16" "$C" --stdout --window=60 </dev/null >| "$O18" 2>/dev/null & c18=$!
sleep 6; kill -TERM "$c18"; wait "$c18"; rc=$?
t1=$(date +%s)
out="$(cat "$O18")"
chk "TERM: exit 0" "0" "$rc"
has "TERM: the footer is reached" "$out" "==== END OF COLLECTION"
has "TERM: section O says it ended early" "$out" "ended early: SIGTERM after"
has "TERM: and the goal says so" "$out" "ended early by SIGTERM after"
[ $((t1 - t0)) -le 30 ] && ok "TERM: ends at once ($((t1 - t0))s of a 60s window)" || bad "TERM ends at once" "<= 30s" "$((t1 - t0))s"
chk "TERM: no zpool iostat left running" "" "$(pgrep -f "$S16/zpool" 2>/dev/null | head -1)"
if type -P perl >/dev/null 2>&1; then
  # a background job ignores SIGINT; perl puts the default back before exec
  COLLZFS_KSTAT_DIR="$K18" PATH="$S16" "$(type -P perl)" -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$C" --stdout --window=60 </dev/null >| "$O18" 2>/dev/null & c18=$!
  sleep 6; kill -INT "$c18"; wait "$c18"
  has "INT: section O says it ended early" "$(cat "$O18")" "ended early: SIGINT after"
else skip "the SIGINT case (needs perl to undo the background job's ignored SIGINT)"; fi
kill "$g18" 2>/dev/null; wait "$g18" 2>/dev/null

echo "== 19. 0.8.0: the options are checked before anything runs =="
for a in "--window=5" "--window=25h" "--window=1x" "--window" "--window="; do
  # shellcheck disable=SC2086
  err="$("$C" --stdout $a </dev/null 2>&1 >/dev/null)"; rc=$?
  chk "$a exits 2" "2" "$rc"
done
# 0.8.1: a value option with no value, or with the next option taken for it
for a in "--out" "--out=" "--home=" "--filesizes=" "--home --file" "--window --file" "--out -x"; do
  # shellcheck disable=SC2086
  err="$("$C" --stdout $a </dev/null 2>&1 >/dev/null)"; rc=$?
  chk "$a exits 2" "2" "$rc"
  has "$a names the option" "$err" "missing value for ${a%%[ =]*}"
done
out="$(PATH="$S" "$C" --stdout </dev/null 2>/dev/null)"
has "without --window: the default length" "$out" "length: 15s (default; --window=DUR sets it)"
# a zpool but no kstat tree: the window did not run, and [1] does not claim it
has "and [1] does not claim it ran" "$out" "window=not run (see section O)"

echo "== 20. 0.8.0: the window reads and never writes; the bundle keeps the merged rows =="
K20="$ROOT/k20"; txgs_gen "$K20" 2 20 3 >/dev/null 2>&1
sum20="$(cat "$K20"/tank/* "$K20"/dmu_tx | cksum)"
B20="$ROOT/b20"; mkdir -p "$B20"
( cd "$B20" && COLLZFS_KSTAT_DIR="$K20" PATH="$S16" "$C" --bundle --window=10 --out . </dev/null >/dev/null 2>&1 )
chk "the kstat files are unchanged" "$sum20" "$(cat "$K20"/tank/* "$K20"/dmu_tx | cksum)"
t20="$(ls "$B20"/*.tar.gz 2>/dev/null | head -1)"
if [ -n "$t20" ]; then
  l20="$(tar tzf "$t20")"
  has "the bundle has the merged rows" "$l20" "./window/txgs-tank.txt"
  has "the reads log" "$l20" "./window/reads-tank.tsv"
  has "the start counters" "$l20" "./window/start/dmu_tx"
  has "and the zpool iostat output" "$l20" "./window/zpool-iostat-vlq.txt"
  has "and the iostat -x output" "$l20" "./window/iostat-x.txt"
  has "and both start times" "$l20" "./window/io-start-ms.tsv"
  has "and the window's -r histogram" "$l20" "./window/zpool-iostat-r.txt"
  has "and the arcstats snapshots" "$l20" "./window/end/arcstats"
  has "a static ring: the window's one txg is kept" "$(tar -xOzf "$t20" ./report.txt)" "rows kept: 1"
else bad "a bundle is written" "one .tar.gz" "none"; fi

echo "== 21. 0.8.0: zpool iostat and iostat -x start together, with timestamps =="
K21="$ROOT/k21"; txgs_gen "$K21" 2 20 3 >/dev/null 2>&1
L21="$ROOT/iolog21"
# t21 LOG -> ms between the two jobs' own start times, or "none"
t21() { awk '{ t[$1] = $2 } END { if (("zpool" in t) && ("iostat" in t)) { d = (t["iostat"] - t["zpool"]) / 1e6; print (d < 0 ? -d : d) } else print "none" }' "$1"; }
for mode in 10s 14s; do
  : >| "$L21"
  a21="--window=$mode"
  out="$(IOLOG="$L21" COLLZFS_KSTAT_DIR="$K21" PATH="$S16" "$C" --stdout $a21 </dev/null 2>/dev/null)"
  d21="$(t21 "$L21")"
  if [ "$d21" != none ] && [ "${d21%.*}" -lt 1000 ]; then ok "$mode: both jobs started within 1s (${d21} ms apart, by their own clocks)"
  else bad "$mode: both jobs started within 1s" "< 1000 ms" "$d21"; fi
  has "$mode: zpool iostat asked for timestamps" "$(grep '^zpool' "$L21")" " -T d -vlq "
  has "$mode: iostat asked for timestamps, in ISO form" "$(grep '^iostat' "$L21")" "S_TIME_FORMAT=ISO -x -N -t "
  n21="$(printf '%s\n' "$out" | grep -c '^      started 20..-..-.. ..:..:..\....')"
  chk "$mode: each job's start time is printed to the ms (pair, -r, -w)" "4" "$n21"
done
has "a 14s window: 1s blocks, 15 of them" "$out" "iostat -x -N -t 1 15 (per device"
: >| "$L21"
out="$(IOSTAT_MODE=noN IOLOG="$L21" COLLZFS_KSTAT_DIR="$K21" PATH="$S16" "$C" --stdout --window=10 </dev/null 2>/dev/null)"
has "an iostat without -N: run without it, and said" "$out" "iostat flags: -x -t (this iostat refused -N"
t0=$(date +%s)
out="$(IOSTAT_MODE=hang IOLOG="$L21" COLLZFS_KSTAT_DIR="$K21" PATH="$S16" "$C" --stdout --window=10 </dev/null 2>/dev/null)"
t1=$(date +%s)
has "a hanging iostat is stopped at the window end and said" "$out" "iostat -x -N -t 1 11: stopped at"
has "the zpool job beside it still delivers" "$out" "tank  1.27G  45.2G"
hasnt "0.8.1: a stopped iostat -x does not block the window goal" "$(printf '%s\n' "$out" | grep -A3 'blocked (running')" "iostat -x"
S21n="$ROOT/stub21n"; stub_clone "$S16" "$S21n"; rm -f "$S21n/iostat"
out="$(COLLZFS_KSTAT_DIR="$K21" PATH="$S21n" "$C" --stdout --window=10 </dev/null 2>/dev/null)"
has "0.8.1: no sysstat: a fact line in section O" "$out" "not delivered: iostat -x: command not found (sysstat)"
hasnt "and not a reason of the window goal" "$(printf '%s\n' "$out" | grep -A3 'blocked (running')" "sysstat"
has "zpool iostat still runs over the window" "$out" "zpool iostat -T d -vlq 1 11 (per vdev"
[ $((t1 - t0)) -le 60 ] && ok "the run ends ($((t1 - t0))s)" || bad "the run ends" "<= 60s" "$((t1 - t0))s"
out="$(ZIO_MODE=hang IOLOG="$L21" COLLZFS_KSTAT_DIR="$K21" PATH="$S16" "$C" --stdout --window=10 </dev/null 2>/dev/null)"
has "window: a zpool iostat that outlives the window is stopped and said" "$out" ": the window ended (output up to then below)"
has "and the window goal names it" "$(printf '%s\n' "$out" | grep -A3 'blocked (running')" "zpool iostat -T d -vlq 1 11: stopped at"
has "while iostat -x beside it still delivers" "$out" "vdd 0.00 9.80 0.29"
chk "no stub job left running" "" "$(pgrep -f "$S16/(zpool|iostat)" 2>/dev/null | head -1)"

echo "== 22. 0.8.0: a pool whose txgs goes away mid-window; a caller's deadline; a second signal =="
K22="$ROOT/k22"; txgs_gen "$K22" 2 20 60 & g22=$!
sleep 2
O22="$ROOT/o22"
COLLZFS_KSTAT_DIR="$K22" PATH="$S16" "$C" --stdout --window=16 </dev/null >| "$O22" 2>/dev/null & c22=$!
sleep 8; kill "$g22" 2>/dev/null; wait "$g22" 2>/dev/null
last22="$(awk 'NR > 1 { t = $1 } END { print t }' "$K22/tank/txgs")"
rm -rf "$K22/tank"
wait "$c22"
out="$(cat "$O22")"
has "the time of the read that found it gone" "$out" "/tank/txgs: not found at the read of"
has "and of the last read that had rows" "$out" "the last read with rows was at"
has "the last read's newest txg is kept" "$out" "newest txg $last22; txgs after it are not in this report"
chk "with its last-seen state (open)" "1" "$(printf '%s\n' "$out" | sed -n '/txgs rows kept/,/Collection status/p' | grep -cE "^ +$last22 +[0-9]+ +O ")"
hasnt "no inference about why" "$out" "pool exported or destroyed"
err="$(RUN_DEADLINE=100 "$C" --stdout --window=60 </dev/null 2>&1 >/dev/null)"; rc=$?
chk "a caller's deadline that leaves under 10s exits 2" "2" "$rc"
has "and says so" "$err" "a window needs at least 10s"
K22b="$ROOT/k22b"; txgs_gen "$K22b" 2 20 3 >/dev/null 2>&1
err="$(RUN_DEADLINE=140 COLLZFS_KSTAT_DIR="$K22b" PATH="$S16" "$C" --stdout --window=60 </dev/null 2>&1 >/dev/null)"
has "one that cuts it says so at the start" "$err" "RUN_DEADLINE=140 cuts the window to about 20s of 60s"
COLLZFS_KSTAT_DIR="$K22b" PATH="$S16" "$C" --stdout --window=60 </dev/null >| "$O22" 2>/dev/null & c22=$!
# 1.5s apart: two TERMs that arrive while bash waits on one foreground child
# are one pending signal (the kernel does not queue them)
sleep 4; kill -TERM "$c22"; sleep 1.5; kill -TERM "$c22" 2>/dev/null; wait "$c22"; rc=$?
chk "a second TERM aborts (143)" "143" "$rc"
sleep 1
chk "and leaves no stub job running" "" "$(pgrep -f "$S16/(zpool|iostat)" 2>/dev/null | head -1)"

echo "== 23. 0.8.0: one window option; the removed ones name their replacement =="
for pair in "--sample|use --window=30s" "--sample=10|use --window=30s" "--window-start=02:00|start the run at that time (at, cron) with --window=DUR" \
            "--window-start 02:00|start the run at that time (at, cron) with --window=DUR" "--no-filesizes|runs only when --filesizes is given" \
            "--filesizes-secs 60|set FILESIZES_SECS=N in the environment" "--filesizes-secs=60|set FILESIZES_SECS=N in the environment" \
            "--event-days 90|set EVENT_DAYS=N in the environment" "--event-days=0|set EVENT_DAYS=N in the environment" \
            "--hours 48|set JOURNAL_HOURS=N in the environment" "--hours=48|set JOURNAL_HOURS=N in the environment"; do
  a="${pair%%|*}"; m="${pair#*|}"
  # shellcheck disable=SC2086
  err="$("$C" --stdout $a </dev/null 2>&1 >/dev/null)"; rc=$?
  chk "$a exits 2" "2" "$rc"
  has "$a names the replacement" "$err" "$m"
done
hh="$("$C" --help)"
for o in --sample --window-start --no-filesizes --filesizes-secs --event-days --hours; do hasnt "--help no longer lists $o" "$hh" "$o"; done
chk "--help lists 10 options" "--bundle --file --filesizes --help --home --out --quiet --stdout --window --zdb" "$(printf '%s\n' "$hh" | grep -oE -- '--[a-z-]+' | sort -u | tr '\n' ' ' | sed 's/ $//')"
for v in CMD_TIMEOUT RUN_DEADLINE FILESIZES_SECS EVENT_DAYS JOURNAL_HOURS; do has "--help's Environment block names $v" "$hh" "    $v=N"; done

echo "== 23b. 0.11.0: --window=DUR@START and a bare --filesizes stop, naming the replacement =="
# ignoring either would collect another span, or skip the walk that was asked for
for pair in "--window=2h@02:00|start the run at START (at, cron) with --window=DUR" \
            "--window 10@2026-01-01T00:00|start the run at START (at, cron) with --window=DUR" \
            "--window=10@|start the run at START (at, cron) with --window=DUR" \
            "--filesizes|use --filesizes=PATH"; do
  a="${pair%%|*}"; m="${pair#*|}"
  # shellcheck disable=SC2086
  err="$("$C" --stdout $a </dev/null 2>&1 >/dev/null)"; rc=$?
  chk "$a exits 2" "2" "$rc"
  has "$a names the replacement" "$err" "$m"
  chk "$a prints one line" "1" "$(printf '%s\n' "$err" | wc -l | tr -d ' ')"
done
hasnt "--help no longer shows DUR@START" "$hh" "@START"
hasnt "--help no longer shows a bare --filesizes" "$hh" "--filesizes  "
out="$(FILESIZES_SECS=abc PATH="$S" "$C" --stdout </dev/null 2>&1)"
has "FILESIZES_SECS that is not a number is ignored, and said" "$out" "FILESIZES_SECS=abc ignored"

echo "== 24. 0.8.0: the 15s window runs in every run; a caller's deadline that leaves it no time says so =="
K24="$ROOT/k24"; txgs_gen "$K24" 2 20 3 >/dev/null 2>&1
t0=$(date +%s)
out="$(COLLZFS_KSTAT_DIR="$K24" PATH="$S16" "$C" --stdout </dev/null 2>/dev/null)"
t1=$(date +%s)
has "no --window: the window ran" "$out" "zpool iostat -T d -vlq 1 16 (per vdev"
has "and its goal is obtained" "$(printf '%s\n' "$out" | grep '^    obtained:')" "time window"
has "and [1] names the default length" "$out" "window=15s (default)"
[ $((t1 - t0)) -ge 15 ] && ok "it took the 15s ($((t1 - t0))s)" || bad "took the 15s" ">= 15s" "$((t1 - t0))s"
out="$(RUN_DEADLINE=100 COLLZFS_KSTAT_DIR="$K24" PATH="$S16" "$C" --stdout </dev/null 2>/dev/null)"
has "a caller's deadline with no room: not run, and why" "$out" "window: not run (RUN_DEADLINE=100 leaves no time for the 15s window"
has "and the goal is blocked" "$out" "time window (every txg, counters, zpool iostat -vlq, -r/-w) — not run: RUN_DEADLINE=100"
out="$(RUN_DEADLINE=130 COLLZFS_KSTAT_DIR="$K24" PATH="$S16" "$C" --stdout </dev/null 2>/dev/null)"
has "one that cuts it: cut, and said" "$out" "ended early: the run deadline (130s, 120s kept for the report) cut it to"
K24e="$ROOT/k24e"; mkdir -p "$K24e"
out="$(COLLZFS_KSTAT_DIR="$K24e" PATH="$S0" "$C" --stdout </dev/null 2>/dev/null)"
has "a kstat tree with no pool: window n/a" "$out" "time window (every txg, counters, zpool iostat -vlq, -r/-w) — no <pool>/txgs under $K24e and no pool listed by zpool"

echo "== 25. 0.10.0: A has os-release and the kernel from /proc/sys/kernel =="
# the stub zpool/zfs of case 4 make section A run on a host without ZFS
if [ "$HAVE_ZFS" = 0 ]; then out="$(PATH="$S" "$C" --stdout </dev/null 2>/dev/null)"
else out="$("$C" --stdout </dev/null 2>/dev/null)"; fi
if [ -r /etc/os-release ] && [ -r /proc/sys/kernel/osrelease ]; then
    has "os-release is dumped raw" "$out" "$(head -n1 /etc/os-release)"
    has "kernel from /proc/sys/kernel" "$out" "kernel: $(cat /proc/sys/kernel/ostype) $(cat /proc/sys/kernel/osrelease)"
else skip "os-release / kernel (not readable here)"; fi

echo; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
