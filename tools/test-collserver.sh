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
has()  { printf '%s' "$2" | grep -qF "$3" && ok "$1" || bad "$1" "contains: $3" "absent"; }
hasnt(){ printf '%s' "$2" | grep -qF "$3" && bad "$1" "absent: $3" "present" || ok "$1"; }
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
  cat > "$s/systemctl" <<'EOF'
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
B3="$ROOT/b3"; mkdir -p "$B3"; ( cd "$B3" && "$C" --home "$H" --bundle --max-total-mb 0 --out . >/dev/null 2>&1 )
has "the total cap binds" "$(tar xzf "$B3"/*.tar.gz -O ./logs/SELECTION.txt 2>/dev/null)" "total cap"
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
    has "and says how to obtain it" "$out" "run with sudo"
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
echo; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
