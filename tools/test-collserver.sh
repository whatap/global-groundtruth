#!/usr/bin/env bash
#
# test-collserver.sh — behaviour tests for the collection-server collector.
# -----------------------------------------------------------------------------
# Usage:  tools/test-collserver.sh [path/to/collect-collserver.sh]
#
# validate.sh checks the SHAPE of a collector's source: the header, the footer,
# rule 1's vocabulary, the entrypoint name. This checks what the collector DOES:
# that the completeness roll-up adds up, that the log caps bind, that a blocked
# goal names the account problem, and that stdout stays the report.
#
# Everything runs against throwaway trees under a mktemp root. Nothing here
# reads or writes a real WhaTap installation.
#
# Two groups need more than an ordinary shell, and say so rather than passing
# quietly when they cannot run (the same rule validate.sh follows for pwsh):
#   * the sudo group              — needs passwordless sudo
#   * the unreadable-journal group — needs sudo to become an account that is
#                                    not in systemd-journal or adm
#
# Some tests put a stub `systemctl` first on PATH, so the journal goal can be
# exercised on a machine that runs no WhaTap unit. The stub answers only
# LoadState and list-unit-files.
#
# Build stub PATHs with `type -P`, never `command -v`: in an interactive shell
# `command -v grep` can answer with an alias, and a symlink built from that
# answer points at itself. That cost an hour on 2026-09-24 and looked exactly
# like a collector bug.
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
# Default to the collector beside this checkout. Resolve whatever we end up
# with to an absolute path: the tests cd into throwaway directories, so a
# relative path would stop resolving after the first one.
C="${1:-$(cd "$(dirname "$0")/.." && pwd)/collectors/collection-server/collect-collserver.sh}"
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
mkhome() {
  local h="$1"; mkdir -p "$h/conf" "$h/logs" "$h/lib"
  printf 'yard_v4_start=20240101\n' > "$h/conf/yard.conf"; printf 'x=1\n' > "$h/conf/proxy.conf"
  head -c 300000 /dev/urandom | base64 > "$h/logs/yard.log"
  head -c 300000 /dev/urandom | base64 > "$h/logs/proxy.log"
  head -c 900000 /dev/urandom | base64 > "$h/logs/yard.20260901.1.log"
  printf 'ERROR boom\n' >> "$h/logs/yard.log"
}
mkstub() {
  local s="$ROOT/stub"; mkdir -p "$s"; local c p
  for c in cat ls date wc tail head sed awk grep egrep fgrep tr id hostname find sort mktemp cp rm \
           mkdir chmod tar uname stat df free ps sh bash getent readlink dirname basename sleep cut \
           uniq xargs expr touch env tee timeout du; do
    p="$(type -P "$c" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$s/$c"
  done
  rm -f "$s/xargs"; stub_write "$s/xargs" < "$ROOT/only/xargs"
  stub_write "$s/systemctl" <<'EOF'
#!/bin/sh
case "$*" in *list-unit-files*) echo "yard.service enabled enabled"; exit 0 ;; esac
case "$*" in *"-p LoadState"*yard*) echo "LoadState=loaded"; exit 0 ;; esac
exit 0
EOF
  chmod +x "$s/systemctl"; printf '%s' "$s"
}
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
echo "== 1. a host with no WhaTap: COMPLETE, every goal n/a =="
out="$("$C" --stdout 2>/dev/null)"
has "footer sentinel" "$out" "==== END OF COLLECTION (no diagnosis by design) ===="
has "COMPLETE" "$out" "status: COMPLETE"
hasnt "nothing blocked" "$out" "blocked (running this differently"
status_adds_up "$out" "status adds up"
for f in "Collector:" "Version:" "Timestamp(UTC):" "Domain:" "Target:"; do has "header $f" "$out" "$f"; done
hasnt "stdout carries no narration" "$out" ">> "
echo "== 2. an unreachable WHATAP_HOME =="
P="$ROOT/blocked"; mkdir -p "$P/parent/whatap/conf"; chmod 000 "$P/parent"
out="$("$C" --home "$P/parent/whatap" --stdout 2>/dev/null)"
has "INCOMPLETE" "$out" "status: INCOMPLETE"
has "reason names sudo" "$out" "run with sudo or as the account that owns the installation"
hasnt "not 'path not found'" "$out" "path not found or WHATAP_HOME not resolved"
status_adds_up "$out" "status adds up"
err="$("$C" --home "$P/parent/whatap" --stdout --quiet 2>&1 >/dev/null)"
has "--quiet keeps the verdict on stderr" "$err" "status:"
hasnt "--quiet drops the narration" "$err" ">> [1] Collection environment"
chmod 755 "$P/parent"
echo "== 3. a normal tree =="
H="$ROOT/home"; mkhome "$H"
out="$("$C" --home "$H" --stdout 2>/dev/null)"
has "COMPLETE" "$out" "status: COMPLETE"
has "configs obtained" "$out" "module configs"
hasnt "nothing blocked" "$out" "blocked (running this differently"
status_adds_up "$out" "status adds up"
echo "== 4. the bundle, its caps, and SELECTION.txt =="
B="$ROOT/b1"; mkdir -p "$B"; ( cd "$B" && "$C" --home "$H" --bundle --out . >/dev/null 2>&1 )
t="$(ls "$B"/*.tar.gz 2>/dev/null)"
if [ -n "$t" ]; then
  sel="$(tar xzf "$t" -O ./logs/SELECTION.txt 2>/dev/null)"
  src="$(printf '%s' "$sel" | awk -F'\t' 'NR>3 && NF>=3 {s+=$3} END{print s+0}')"
  real=$(( $(wc -c < "$H/logs/yard.log") + $(wc -c < "$H/logs/proxy.log") + $(wc -c < "$H/logs/yard.20260901.1.log") ))
  chk "SELECTION source bytes match the tree" "$real" "$src"
  has "rotated excluded by default" "$sel" "rotated log, --with-rotated not given"
  chk "no rotated log in the bundle" "0" "$(tar tzf "$t" | grep -c '20260901')"
  chk "both configs in the bundle" "2" "$(tar tzf "$t" | grep -c '/conf/.*\.conf$')"
else bad "bundle written" "a .tar.gz" "none"; fi
B2="$ROOT/b2"; mkdir -p "$B2"; ( cd "$B2" && "$C" --home "$H" --bundle --with-rotated --out . >/dev/null 2>&1 )
chk "--with-rotated includes it" "1" "$(tar tzf "$B2"/*.tar.gz 2>/dev/null | grep -c '20260901')"
# 0.11.0: the caps come from the environment (LOG_TOTAL_MB, LOG_FILE_MB)
B3="$ROOT/b3"; mkdir -p "$B3"; ( cd "$B3" && LOG_TOTAL_MB=1 "$C" --home "$H" --bundle --with-rotated --out . >/dev/null 2>&1 )
has "the total cap (LOG_TOTAL_MB=1) binds" "$(tar xzf "$B3"/*.tar.gz -O ./logs/SELECTION.txt 2>/dev/null)" "total cap 1MB reached"
B3b="$ROOT/b3b"; mkdir -p "$B3b"; ( cd "$B3b" && LOG_FILE_MB=1 "$C" --home "$H" --bundle --with-rotated=30 --out . >/dev/null 2>&1 )
has "the per-file cap (LOG_FILE_MB=1) binds" "$(tar xzf "$B3b"/*.tar.gz -O ./logs/SELECTION.txt 2>/dev/null)" "per-file cap 1MB, tail kept"
has "--with-rotated=DAYS sets the window" "$(tar xzf "$B3b"/*.tar.gz -O ./logs/SELECTION.txt 2>/dev/null)" "included (last 30d)"
B3c="$ROOT/b3c"; mkdir -p "$B3c"
err="$( cd "$B3c" && LOG_TOTAL_MB=0 LOG_FILE_MB=x "$C" --home "$H" --bundle --out . 2>&1 >/dev/null )"
has "LOG_TOTAL_MB=0 is named and the default used" "$err" "LOG_TOTAL_MB=0 ignored (not a whole number 1..999999 without leading zeros), using 100"
has "LOG_FILE_MB=x is named and the default used" "$err" "LOG_FILE_MB=x ignored (not a whole number 1..999999 without leading zeros), using 5"
has "and the bundle keeps the default caps" "$(tar xzf "$B3c"/*.tar.gz -O ./logs/SELECTION.txt 2>/dev/null)" "caps: 5MB per file, 100MB total"
echo "== 5. a log filename containing a space =="
H2="$ROOT/home2"; mkhome "$H2"; cp "$H2/logs/yard.log" "$H2/logs/my service.log"
has "listed in the inventory" "$("$C" --home "$H2" --stdout 2>/dev/null)" "my service.log"
B4="$ROOT/b4"; mkdir -p "$B4"; ( cd "$B4" && "$C" --home "$H2" --bundle --out . >/dev/null 2>&1 )
chk "copied into the bundle" "1" "$(tar tzf "$B4"/*.tar.gz 2>/dev/null | grep -c 'my service.log')"
echo "== 6. help on stdout, errors on stderr =="
o="$("$C" 2>/dev/null)"; rc=$?
has "help on stdout" "$o" "collect-collserver.sh"; chk "help exits 0" "0" "$rc"
has "bad argument on stderr" "$("$C" --nonsense 2>&1 >/dev/null; true)" "unknown argument"
chk "bad argument exits 2" "2" "$("$C" --nonsense >/dev/null 2>&1; echo $?)"
echo "== 7. the journal goal (stub systemctl reports one loaded unit) =="
S="$(mkstub)"
if type -P journalctl >/dev/null 2>&1; then
  ln -sf "$(type -P journalctl)" "$S/journalctl"
  out="$(PATH="$S" "$C" --stdout 2>/dev/null)"
  has "journal goal declared" "$out" "systemd journal for whatap units"
  has "readable but empty is n/a" "$out" "the system journal is readable and holds no entries"
  status_adds_up "$out" "status adds up"
  rm -f "$S/journalctl"
else skip "the readable-journal case (journalctl absent)"; fi
out="$(PATH="$S" "$C" --stdout 2>/dev/null)"
has "no journalctl is a blocked goal" "$out" "systemd journal for whatap units — command not found: journalctl"
has "and the run is INCOMPLETE" "$out" "status: INCOMPLETE"
echo "== 8. an account that cannot read the system journal =="
if sudo -n true 2>/dev/null && type -P journalctl >/dev/null 2>&1; then
  ln -sf "$(type -P journalctl)" "$S/journalctl"
  cp "$C" "$ROOT/c.sh"; chmod -R a+rX "$ROOT" 2>/dev/null
  out="$(sudo -u nobody env PATH="$S" HOME=/tmp TMPDIR=/tmp bash "$ROOT/c.sh" --stdout 2>/dev/null)"
  if printf '%s' "$out" | grep -q 'cannot read /.*system.journal'; then
    ok "the reason names the file and the groups"
    has "and the gap says how to obtain it" "$out" "(not elevated: run again with sudo)"
    has "and the run is INCOMPLETE" "$out" "status: INCOMPLETE"
  else skip "the unreadable-journal case (this account can read the journal)"; fi
  rm -f "$S/journalctl"
else skip "the unreadable-journal case (needs passwordless sudo)"; fi
echo "== 9. under sudo: the bundle comes back to the caller =="
if sudo -n true 2>/dev/null; then
  B5="$ROOT/b5"; mkdir -p "$B5"; ( cd "$B5" && sudo "$C" --home "$H" --bundle --out . >/dev/null 2>&1 )
  t5="$(ls "$B5"/*.tar.gz 2>/dev/null)"
  if [ -n "$t5" ]; then
    chk "the tarball is owned by the caller" "$(id -un)" "$(stat -c %U "$t5")"
    has "the header records the sudo origin" "$(tar xzf "$t5" -O ./report.txt)" "via sudo from $(id -un)"
  else bad "bundle written under sudo" "a .tar.gz" "none"; fi
  sudo rm -rf "$B5" 2>/dev/null
else skip "the sudo group (needs passwordless sudo)"; fi
echo "== 10. conf/ and logs/ that exist but cannot be listed =="
# An unreadable directory hands its glob back literally, and 0.8.x read that as
# "conf/ is readable and holds no *.conf": COMPLETE for a run that saw nothing.
if [ "$(id -u)" != 0 ]; then
  H3="$ROOT/home3"; mkhome "$H3"; chmod 000 "$H3/conf" "$H3/logs"
  out="$("$C" --home "$H3" --stdout 2>/dev/null)"
  has "INCOMPLETE" "$out" "status: INCOMPLETE"
  has "configs are blocked, not absent" "$out" "module configs — uid $(id -u) cannot read $H3/conf"
  has "logs are blocked, not absent" "$out" "log inventory — uid $(id -u) cannot read $H3/logs"
  hasnt "no 'holds no *.conf'" "$out" "holds no *.conf"
  has "and the gap names sudo" "$out" "(not elevated: run again with sudo)"
  status_adds_up "$out" "status adds up"
  chmod 755 "$H3/conf" "$H3/logs"
  chmod 000 "$H3/conf/proxy.conf"
  out="$("$C" --home "$H3" --stdout 2>/dev/null)"
  has "one unreadable conf file blocks the goal" "$out" "module configs — uid $(id -u) cannot read proxy.conf"
  chmod 644 "$H3/conf/proxy.conf"
else skip "the unreadable-directory cases (this account is root, which reads them)"; fi
echo "== 11. numeric options are checked before the run =="
# each case: the arguments, then (after |) what stderr must say
for o in "--hours x1|--hours takes a non-negative integer" \
         "--with-rotated=1e3|--with-rotated=DAYS takes a non-negative integer" \
         "--with-rotated=0|--with-rotated=DAYS takes a whole number of days, 1..999999 without leading zeros" \
         "--with-rotated=010|--with-rotated=DAYS takes a whole number of days, 1..999999 without leading zeros" \
         "--threads=two|--threads takes a non-negative integer" \
         "--hours -1|missing value for --hours" \
         "--out|missing value for --out" "--out=|missing value for --out" \
         "--home --file|missing value for --home" "--threads=|missing value for --threads=" \
         "--time-ref=|missing value for --time-ref=" "--with-rotated=|missing value for --with-rotated=" \
         "--max-log-mb 1|--max-log-mb is no longer an option: set LOG_FILE_MB=N in the environment" \
         "--max-total-mb=1|--max-total-mb is no longer an option: set LOG_TOTAL_MB=N in the environment" \
         "--log-days 3|--log-days was merged into --with-rotated: use --with-rotated=DAYS"; do
  a="${o%%|*}"; want="${o#*|}"
  B6="$ROOT/b6"; T6="$ROOT/t6"; rm -rf "$B6" "$T6"; mkdir -p "$B6" "$T6"
  # shellcheck disable=SC2086
  err="$( cd "$B6" && TMPDIR="$T6" "$C" --home "$H" --bundle --out . $a 2>&1 >/dev/null )"; rc=$?
  chk "$a exits 2" "2" "$rc"
  has "$a names the option" "$err" "$want"
  # 0.8.1 left its mktemp work dir behind in TMPDIR when the arithmetic aborted.
  chk "$a leaves nothing behind, in --out or in TMPDIR" "" "$(find "$B6" "$T6" -mindepth 1 2>/dev/null | head -3)"
done
echo "== 11b. 0.11.0: a bundle-only option without --bundle is named, not ignored =="
err="$("$C" --home "$H" --stdout --threads=2 --du --with-rotated </dev/null 2>&1 >/dev/null)"; rc=$?
chk "the run still completes" "0" "$rc"
has "the terminal names what was not run" "$err" "!! not run: --threads --du --with-rotated (bundle only; add --bundle to collect them)"
out="$("$C" --home "$H" --stdout --heap </dev/null 2>/dev/null)"
has "and the deadline is not raised for it" "$out" "s of 300s allowed"
err="$("$C" --home "$H" --stdout --time-ref=127.0.0.1 --quiet </dev/null 2>&1 >/dev/null)"
hasnt "--time-ref is not bundle only" "$err" "not run:"
echo "== 12. an output directory that cannot be written =="
if [ "$(id -u)" != 0 ]; then
  RO="$ROOT/ro"; mkdir -p "$RO"; chmod 555 "$RO"
  T12="$ROOT/t12"; mkdir -p "$T12"
  err="$(TMPDIR="$T12" "$C" --home "$H" --bundle --out "$RO" 2>&1 >/dev/null)"; rc=$?
  chk "bundle into an unwritable --out fails with exit 1" "1" "$rc"
  has "and says so" "$err" "is not writable by uid"
  # 0.8.1 exited 0 and left "artifacts left under" a work dir in TMPDIR.
  chk "and leaves no work dir with the configs in TMPDIR" "" "$(ls -A "$T12")"
  err="$("$C" --home "$H" --file --out "$RO" 2>&1 >/dev/null)"; rc=$?
  # Fail fast: checked before the host is walked, not after.
  if [ "$rc" = 1 ] && ! printf '%s' "$err" | grep -qF ">> discovering"; then
    ok "--file into an unwritable --out fails before any collection"
  else bad "--file into an unwritable --out fails before any collection" "exit 1, no discovery" "exit $rc: $(printf '%s' "$err" | head -1)"; fi
  chmod 755 "$RO"
else skip "the unwritable --out case (root writes anywhere)"; fi
echo "== 13. discovery and labels =="
out="$(WHATAP_HOME="$H" "$C" --stdout 2>/dev/null)"
has "WHATAP_HOME from the environment is a source" "$out" "WHATAP_HOME resolved by: environment WHATAP_HOME"
has "and the configs come back" "$out" "obtained: WHATAP_HOME contents, module configs, log inventory"
out="$("$C" --stdout 2>/dev/null)"
has "ports are labelled as module defaults" "$out" "port 6789 (keeper default):"
hasnt "no module-named port line" "$out" "keeper (6789):"
has "no yardbase and no home: the filesystem is n/a" "$out" "yardbase filesystem type: n/a (neither yardbase nor WHATAP_HOME resolved)"
hasnt "and nothing resolved that was never declared" "$out" "resolved but never declared"
echo "== 14. a hung systemctl is asked once, not once per unit =="
# The stub counts its calls. Without the fail-fast every unit_loaded, is-active
# and show would each wait CMD_TIMEOUT; with it, the first cap stops the rest.
S2="$ROOT/stub2"; stub_clone "$S" "$S2"
stub_write "$S2/systemctl" <<'EOF'
#!/bin/sh
echo x >> "$SDCALLS"
exec sleep 600
EOF
chmod +x "$S2/systemctl"; export SDCALLS="$ROOT/sdcalls"; : >| "$SDCALLS"
t0=$(date +%s); out="$(PATH="$S2" CMD_TIMEOUT=2 RUN_DEADLINE=120 "$C" --stdout 2>/dev/null)"; t1=$(date +%s)
has "the footer is reached" "$out" "==== END OF COLLECTION"
n="$(wc -l < "$SDCALLS" | tr -d ' ')"
[ "$n" -le 2 ] && ok "systemctl was called $n time(s)" || bad "systemctl called at most twice" "<= 2" "$n"
[ $((t1 - t0)) -le 30 ] && ok "and the run took $((t1 - t0))s, not RUN_DEADLINE" || bad "the run is not stretched to the deadline" "<= 30s" "$((t1 - t0))s"
unset SDCALLS

echo "== 15. a whatap JVM whose home was not found is blocked, never n/a =="
# A process whose cmdline names a whatap module, started in a directory that
# holds no conf, and without -Dwhatap.server.home.
N="$ROOT/nothome"; mkdir -p "$N"
# One process (exec -a names it), so killing it leaves no orphan holding this
# suite's stdout open, and its own output goes nowhere.
( cd "$N" && exec -a "java -jar whatap.server.yard.boot" sleep 60 ) >/dev/null 2>&1 </dev/null &
jvm=$!
sleep 1
out="$(ONLY_PIDS="$jvm" "$C" --stdout 2>/dev/null)"
kill "$jvm" 2>/dev/null; wait "$jvm" 2>/dev/null
has "the module is seen" "$out" "obtained: running whatap modules"
has "home is blocked, naming the JVM" "$out" "WHATAP_HOME contents — WHATAP_HOME not resolved; pass --home DIR; whatap JVM pid"
has "configs are blocked too" "$out" "module configs — WHATAP_HOME not resolved; pass --home DIR; whatap JVM pid"
hasnt "and nothing reads 'no whatap home'" "$out" "no whatap home in any readable process"

echo "== 16. a /proc mounted hidepid: the empty process table is not an answer =="
if sudo -n true 2>/dev/null && type -P unshare >/dev/null 2>&1 && type -P setpriv >/dev/null 2>&1; then
  # nobody must reach the copy, and $ROOT may sit under a mode-700 TMPDIR, so
  # the copy lives in a directory of its own directly under /tmp.
  HP="$(mktemp -d /tmp/ggt-test16.XXXXXX)"; chmod 711 "$HP"
  cp "$C" "$HP/c16.sh"; chmod 755 "$HP/c16.sh"
  out="$(sudo -n unshare -pfm --propagation private sh -c \
      'mount -t proc -o hidepid=2 proc /proc && grep -q hidepid /proc/mounts && echo NS_HIDEPID_OK && exec setpriv --reuid=65534 --regid=65534 --clear-groups env PATH=/usr/bin:/bin HOME=/tmp TMPDIR=/tmp bash "$1" --stdout' \
      sh "$HP/c16.sh" 2>/dev/null)"
  case "$HP" in /tmp/ggt-test16.*) rm -rf "$HP" ;; esac
  if printf '%s' "$out" | grep -qx 'NS_HIDEPID_OK'; then
    has "running modules are blocked, naming hidepid" "$out" "running whatap modules — /proc is mounted with hidepid"
    hasnt "and not n/a" "$out" "no whatap JVM in any of the"
  else skip "the hidepid case (the namespace could not be set up: $(printf '%s' "$out" | head -c 80))"; fi
else skip "the hidepid case (needs passwordless sudo, unshare and setpriv)"; fi
echo "== 17. under sh: a sentence, not a syntax error =="
o="$(sh "$C" --stdout 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$o" | grep -qF "collect-collserver.sh needs bash" \
  && ok "exit 2, saying it needs bash" || bad "exit 2, saying it needs bash" "rc 2 + message" "rc $rc: $(printf '%s' "$o" | head -1)"
echo "== 18. round 4: one systemctl show for every unit; a failed process scan is not 'no JVM' =="
# A systemctl that answers multi-unit show the way systemd does (blocks, the
# properties in its own order) and counts its calls. yard is loaded, with a
# WorkingDirectory that is a home.
S3="$ROOT/stub3"; stub_clone "$S" "$S3"
stub_write "$S3/systemctl" <<EOF
#!/bin/sh
echo x >> "$ROOT/sd3.calls"
case "\$1" in
  show) shift; first=1; props=" "; units=""
        while [ \$# -gt 0 ]; do
          if [ "\$1" = -p ]; then props="\$props\$2 "; shift 2; else units="\$units \$1"; shift; fi
        done
        for a in \$units; do
          [ "\$first" = 1 ] || echo; first=0
          if [ "\$a" = yard.service ]; then wd="$H"; ls=loaded; else wd=""; ls=not-found; fi
          for p in NRestarts WorkingDirectory Id LoadState; do
            case "\$props" in *" \$p "*) ;; *) continue ;; esac
            case "\$p" in NRestarts) echo "NRestarts=0" ;; WorkingDirectory) echo "WorkingDirectory=\$wd" ;;
                           Id) echo "Id=\$a" ;; LoadState) echo "LoadState=\$ls" ;; esac
          done
        done ;;
  is-active) echo active ;;
  is-enabled) echo enabled ;;
  list-unit-files) echo "yard.service enabled enabled" ;;
esac
exit 0
EOF
chmod +x "$S3/systemctl"; : >| "$ROOT/sd3.calls"
out="$(PATH="$S3" "$C" --stdout 2>/dev/null)"
has "the home comes from the prefetched WorkingDirectory" "$out" "WHATAP_HOME resolved by: systemd yard.service WorkingDirectory"
has "and the unit state line is there" "$out" "yard.service: active=active enabled=enabled restarts=0"
n="$(wc -l < "$ROOT/sd3.calls" | tr -d ' ')"
[ "$n" -le 8 ] && ok "systemctl was called $n times, not once per unit and property" || bad "systemctl called at most 8 times" "<= 8" "$n"
# An xargs that cannot run grep: the scan failed, so no JVM is not an answer.
S4="$ROOT/stub4"; stub_clone "$S" "$S4"
rm -f "$S4/xargs"   # a symlink to the real one: never write through it
printf '#!/bin/sh\necho "xargs: grep: Argument list too long" >&2\nexit 126\n' | stub_write "$S4/xargs"
rm -f "$S4/systemctl"
out="$(PATH="$S4" "$C" --stdout 2>/dev/null)"
has "a failed /proc scan blocks the modules goal" "$out" "running whatap modules — the /proc/<pid>/cmdline scan failed (xargs/grep exit 126)"
hasnt "and is not read as none running" "$out" "no whatap JVM in any of the"

echo "== 19. read from stdin (bash -s): the /proc scan still sees a JVM =="
N19="$ROOT/nothome19"; mkdir -p "$N19"
( cd "$N19" && exec -a "java -jar whatap.server.yard.boot" sleep 60 ) >/dev/null 2>&1 </dev/null &
jvm=$!
sleep 1
out="$(ONLY_PIDS="$jvm" bash -s -- --stdout < "$C" 2>/dev/null)"
kill "$jvm" 2>/dev/null; wait "$jvm" 2>/dev/null
has "bash -s: the module is seen" "$out" "obtained: running whatap modules"
hasnt "and not read as none running" "$out" "no whatap JVM in any of the"

echo "== 20. no heap dump found is 'none' =="
out="$("$C" --home "$H" --stdout 2>/dev/null)"
has "*.hprof: none" "$out" "*.hprof: none (no *.hprof in $H or $H/logs)"
hasnt "not 'empty output'" "$out" "*.hprof: n/a (empty output)"

echo "== 21. heap dumps in a directory this uid cannot list: n/a, not none =="
if [ "$(id -u)" != 0 ]; then
  H21="$ROOT/home21"; mkhome "$H21"; : >| "$H21/logs/java_pid1.hprof"; chmod 000 "$H21/logs"
  out="$("$C" --home "$H21" --stdout 2>/dev/null)"
  has "the unlistable logs/ makes it n/a" "$out" "*.hprof: n/a (not every directory searched was read)"
  has "and names it with the uid" "$out" "*.hprof in $H21/logs: n/a (uid $(id -u) cannot list)"
  hasnt "and not none" "$out" "*.hprof: none"
  : >| "$H21/java_pid2.hprof"
  out="$("$C" --home "$H21" --stdout 2>/dev/null)"
  has "a dump found at the top is listed" "$out" "java_pid2.hprof"
  has "and the unlistable logs/ is said next to it" "$out" "*.hprof in $H21/logs: n/a (uid $(id -u) cannot list)"
  chmod 755 "$H21/logs"; rm -f "$H21/java_pid2.hprof"
  if sudo -n true 2>/dev/null; then
    # logs/ is a symlink into a directory only root can enter: -e fails, and
    # that is not "absent".
    RD="$(sudo -n mktemp -d /tmp/ggt-test21.XXXXXX)"; sudo -n touch "$RD/java_pid3.hprof"
    H21b="$ROOT/home21b"; mkhome "$H21b"; rm -rf "$H21b/logs"; ln -s "$RD" "$H21b/logs"
    out="$("$C" --home "$H21b" --stdout 2>/dev/null)"
    has "logs/ -> a root-only directory: n/a with the uid, not none" "$out" "*.hprof in $H21b/logs: n/a (uid $(id -u) cannot list)"
    hasnt "and not none" "$out" "*.hprof: none"
    case "$RD" in /tmp/ggt-test21.*) sudo -n rm -rf "$RD" ;; esac
  else skip "the root-only symlink case (needs passwordless sudo)"; fi
  H21c="$ROOT/home21c"; mkhome "$H21c"; rm -rf "$H21c/logs"; : >| "$H21c/logs"
  out="$("$C" --home "$H21c" --stdout 2>/dev/null)"
  has "logs as a regular file: not a directory" "$out" "*.hprof in $H21c/logs: n/a (not a directory)"
else skip "the unlistable-logs case (root lists everything)"; fi

echo "== 22. only a java process that runs a server module counts =="
F22="$ROOT/f22"; mkdir -p "$F22"; : >| "$F22/whatap.server.log"
( exec -a "java -Dwhatap.server.host=10.0.0.1 -javaagent:whatap.agent.jar -jar app.jar" sleep 60 ) >/dev/null 2>&1 </dev/null &
p1=$!
tail -f "$F22/whatap.server.log" >/dev/null 2>&1 </dev/null &
p2=$!
sleep 1
out="$(ONLY_PIDS="$p1 $p2" "$C" --stdout 2>/dev/null)"
kill "$p1" "$p2" 2>/dev/null; wait "$p1" "$p2" 2>/dev/null
has "an app JVM with the WhaTap agent and a tail of a whatap log: no module" "$out" "running whatap modules — no whatap JVM in any of the"
has "and the host stays COMPLETE" "$out" "status: COMPLETE"

echo "== 23. a home that is not there, and a dangling logs link =="
out="$("$C" --home "$ROOT/nohome" --stdout 2>/dev/null)"
has "a missing home: path not found" "$out" "*.hprof in $ROOT/nohome: n/a (path not found)"
hasnt "not 'cannot list'" "$out" "nohome: n/a (uid"
out="$( cd "$ROOT" && "$C" --home relmissing --stdout 2>/dev/null )"
has "a relative missing --home: path not found" "$out" "*.hprof in relmissing: n/a (path not found)"
H23="$ROOT/home23"; mkhome "$H23"; rm -rf "$H23/logs"; ln -s "$ROOT/gone23" "$H23/logs"
out="$("$C" --home "$H23" --stdout 2>/dev/null)"
has "a dangling logs link says so" "$out" "*.hprof in $H23/logs: n/a (dangling symlink to $ROOT/gone23)"

echo "== 24. 0.10.0: uname strings from /proc, the time once, deadline wording =="
# hostname and uname stubs log every call; with /proc/sys/kernel readable
# section A must not run either.
S24="$ROOT/stub24"; stub_clone "$S" "$S24"; UNLOG="$ROOT/uname.log"; : >| "$UNLOG"
for c in hostname uname; do
    stub_write "$S24/$c" <<EOF
#!/bin/sh
echo "$c \$*" >> "$UNLOG"
exec "$(type -P "$c")" "\$@"
EOF
done
out="$(PATH="$S24" "$C" --stdout </dev/null 2>/dev/null)"
if [ -r /proc/sys/kernel/hostname ] && [ -r /proc/sys/kernel/osrelease ]; then
    has "hostname from /proc/sys/kernel" "$out" "hostname: $(cat /proc/sys/kernel/hostname)"
    has "kernel from ostype + osrelease" "$out" "kernel: $(cat /proc/sys/kernel/ostype) $(cat /proc/sys/kernel/osrelease)"
    hasnt "no uname -sr" "$(cat "$UNLOG")" "uname -sr"
    [ -r /proc/sys/kernel/arch ] && has "arch from /proc/sys/kernel/arch" "$out" "arch: $(cat /proc/sys/kernel/arch)"
    [ -r /proc/sys/kernel/arch ] && hasnt "and no uname -m" "$(cat "$UNLOG")" "uname -m"
else skip "the /proc/sys/kernel cases (not readable here)"; fi
chk "the timezone is printed once" "1" "$(printf '%s\n' "$out" | grep -cE '^    (system )?timezone:')"
hasnt "no date(UTC) line next to section B's UTC time" "$out" "date(UTC):"
has "section B keeps the UTC time" "$out" "UTC time:"
stub_write "$S24/java" <<'EOF'
#!/bin/sh
exec sleep 30
EOF
t0=$(date +%s)
out="$(RUN_DEADLINE=3 PATH="$S24" "$C" --stdout </dev/null 2>/dev/null)"
t1=$(date +%s)
has "java -version cut by the run deadline says so" "$out" "java -version (the java on PATH: $S24/java -> "
has "with the deadline as the reason" "$out" "): n/a (run deadline reached: 3s)"
[ $((t1 - t0)) -le 30 ] && ok "and the run ends ($((t1 - t0))s)" || bad "the run ends" "<= 30s" "$((t1 - t0))s"
rm -f "$S24/java"
stub_write "$S24/curl" <<'EOF'
#!/bin/sh
exec sleep 30
EOF
rm -f "$S24/ntpdate" "$S24/sntp"
t0=$(date +%s)
out="$(CMD_TIMEOUT=2 PATH="$S24" "$C" --stdout --time-ref </dev/null 2>/dev/null)"
t1=$(date +%s)
has "a curl that never answers is capped" "$out" "external time: n/a (timed out: 2s)"
[ $((t1 - t0)) -le 60 ] && ok "and the run ends ($((t1 - t0))s)" || bad "the curl cap binds" "<= 60s" "$((t1 - t0))s"
stub_write "$S24/curl" <<'EOF'
#!/bin/sh
echo "curl: (7) Failed to connect to www.google.com port 443" >&2; exit 7
EOF
out="$(PATH="$S24" "$C" --stdout --time-ref </dev/null 2>/dev/null)"
has "a failed curl names its exit status" "$out" "external time: n/a (curl exit 7: "

echo "== 25. the account H2 database and its dumps =="
H25="$ROOT/h25"; mkhome "$H25"; mkdir -p "$H25/yardbase" "$H25/data/h2/backup"
printf 'h2.file.path=./data/h2\n' > "$H25/conf/account.conf"
: > "$H25/data/h2/account.mv.db"; echo x > "$H25/data/h2/backup/account_20260901.sql"
: > "$H25/data/h2/backup/account_20260902.sql"
out="$("$C" --home "$H25" --stdout 2>/dev/null)"
has "h2.file.path is read from account.conf" "$out" "h2.file.path (conf/account.conf): ./data/h2"
has "and resolved against WHATAP_HOME" "$out" "db path: $H25/data/h2 (present)"
has "a db on yardbase's filesystem says so" "$out" "(the same as yardbase's)"
has "the db files are listed" "$out" "account.mv.db"
has "dumps are counted, 0-byte ones apart" "$out" "backup files in $H25/data/h2/backup: 2 (of them 0 bytes: 1)"
hasnt "the old db line is gone" "$out" "db dir: present"
rm -f "$H25/conf/account.conf"; rm -rf "$H25/data"
out="$("$C" --home "$H25" --stdout 2>/dev/null)"
has "no account.conf: the packaged ./db is checked" "$out" "checking ./db, the packaged value"
has "and an absent db stops there" "$out" "db path: $H25/db (absent)"
hasnt "without a mount line" "$out" "db mount point:"

# A db behind a symlink, with spaces in its path, is followed, not listed as a link.
mkdir -p "$H25/moved db/backup"; ln -s "$H25/moved db" "$H25/dblink"
printf 'h2.file.path = ./dblink \r\n' > "$H25/conf/account.conf"
: > "$H25/moved db/account.mv.db"; : > "$H25/moved db/backup/a.sql"; echo x > "$H25/moved db/backup/b.sql"
out="$("$C" --home "$H25" --stdout 2>/dev/null)"
has "the value is trimmed at its ends only" "$out" "db path: $H25/dblink (present)"
has "a symlinked backup dir is followed" "$out" "backup files in $H25/dblink/backup: 2 (of them 0 bytes: 1)"
has "and a symlinked db is listed through" "$out" "account.mv.db"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$H25/conf/account.conf"
  out="$("$C" --home "$H25" --stdout 2>/dev/null)"
  has "an unreadable account.conf is not 'not set'" "$out" "h2.file.path (conf/account.conf): n/a (permission denied:"
  chmod 644 "$H25/conf/account.conf"
else skip "the unreadable account.conf case (root reads anything)"; fi
# A find that never answers makes the count n/a, never 0.
S25="$ROOT/stub25"; stub_clone "$S" "$S25"; rm -f "$S25/find"
stub_write "$S25/find" <<'EOF2'
#!/bin/sh
exec sleep 30
EOF2
out="$(PATH="$S25" CMD_TIMEOUT=2 "$C" --home "$H25" --stdout 2>/dev/null)"
has "a capped find is n/a, not 0" "$out" "backup files in $H25/dblink/backup: n/a (timed out: 2s)"

echo "== 26. 0.13.0: both yard lock names, the server JVMs' cgroup and runtime, JAVA_TOOL_OPTIONS =="
H26="$ROOT/h26"; mkhome "$H26"; mkdir -p "$H26/yardbase/1"; : > "$H26/yardbase/.lock"
out="$("$C" --home "$H26" --stdout 2>/dev/null)"
has "3.1.8's .lock is reported" "$out" ".lock: present ("
has "and YARDB_LOCK as absent" "$out" "YARDB_LOCK: absent"
has "no version file is said once" "$out" "version file (VERSION*, version* at the top level): none"
printf '3.1.8-7014\n' > "$H26/VERSION"
out="$("$C" --home "$H26" --stdout 2>/dev/null)"
has "a version file is dumped raw" "$out" "        3.1.8-7014"
# A JVM whose executable is a JDK's bin/java with a release file next to it,
# and one whose executable is not java at all.
J26="$ROOT/jdk26"; mkdir -p "$J26/bin"; cp "$(type -P sleep)" "$J26/bin/java"
printf 'JAVA_VERSION="17.0.99"\n' > "$J26/release"
( cd "$H26" && exec -a "java -jar whatap.server.yard.boot" "$J26/bin/java" 60 ) >/dev/null 2>&1 </dev/null &
j1=$!
( cd "$H26" && exec -a "java -jar whatap.server.proxy.boot.whatap.server.proxy-1.jar" sleep 60 ) >/dev/null 2>&1 </dev/null &
j2=$!
sleep 1
out="$(ONLY_PIDS="$j1 $j2" JAVA_TOOL_OPTIONS=-Dggt=1 "$C" --home "$H26" --stdout 2>/dev/null)"
has "the JVM's executable is read from /proc" "$out" "exe (pid $j1): $J26/bin/java"
has "and its JDK's release file printed" "$out" 'JAVA_VERSION="17.0.99"'
has "an executable not named java is not run" "$out" "-version not run: the executable is sleep, not java"
has "the JVMs' cgroup is read from /proc/<pid>/cgroup" "$out" "whatap server JVM cgroup (pid $j1 $j2)"
has "the run's own cgroup is labelled" "$out" "this run's cgroup (/proc/self/cgroup)"
if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
    cg="$(sed -n 's/^0:://p' "/proc/$j1/cgroup")"; cg="${cg%/}"
    has "and that cgroup's memory.max" "$out" "memory.max (/sys/fs/cgroup$cg)"
else skip "the cgroup v2 limit file (no unified hierarchy here)"; fi
has "JAVA_TOOL_OPTIONS is named as removed" "$out" "JVM option variables removed from the JVMs this run starts: JAVA_TOOL_OPTIONS"
kill "$j1" "$j2" 2>/dev/null; wait "$j1" "$j2" 2>/dev/null
# the JDK replaced in place under a running JVM: the release there is not its own
( cd "$H26" && exec -a "java -jar whatap.server.yard.boot" "$J26/bin/java" 60 ) >/dev/null 2>&1 </dev/null &
j1=$!; sleep 1
cp "$J26/bin/java" "$J26/bin/java.new"; mv -f "$J26/bin/java.new" "$J26/bin/java"
out="$(ONLY_PIDS="$j1" "$C" --home "$H26" --stdout 2>/dev/null)"
has "a replaced executable's release is labelled so" "$out" "release now at $J26/release; the running executable was replaced"
has "and no -version is run" "$out" "-version: not run (the running executable is deleted)"
hasnt "the same namespace prints no namespace line" "$out" "mount namespace:"
kill "$j1" 2>/dev/null; wait "$j1" 2>/dev/null
S26="$ROOT/stub26"; stub_clone "$S" "$S26"
stub_write "$S26/java" <<'EOF2'
#!/bin/sh
echo "JTO=[${JAVA_TOOL_OPTIONS:-}]" >&2
EOF2
out="$(PATH="$S26" JAVA_TOOL_OPTIONS=-javaagent:/x.jar "$C" --home "$H26" --stdout 2>/dev/null)"
has "java -version runs without JAVA_TOOL_OPTIONS" "$out" "JTO=[]"

echo; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
