#!/bin/bash
# run-collector.sh CONTAINER [collector args...]
#   Copies a collector into the DB container and runs it there the way the
#   XLSMART runbook section 6 has the operator run it: an option file
#   ~/.my.cnf (mode 600) with the application account, then
#   `sudo ./collect-collmysql.sh ... --defaults-file=$HOME/.my.cnf`, then the
#   option file is removed. The Ubuntu 8.0 containers have sudo and a user
#   `op` (NOPASSWD); the 5.7 image has no sudo, so there it runs as root.
# Environment:
#   COLLECTOR=PATH   collector to run (default: this repo's working tree
#                    collectors/collection-server/collect-collmysql.sh)
#   GGT_ACCOUNT=     app (default: whatap, ALL on account.* and notihub.*),
#                    mon (ggtmon: SELECT, PROCESS, REPLICATION CLIENT on *.*),
#                    wrong (app user, wrong password: the XLSMART shape),
#                    none (no option file: runbook section 3, first try)
#   GGT_OUT=DIR      where the report is copied back (default ./ggt-out)
# Example: ./run-collector.sh jjsong-ggt-mysql-primary --file --binlog
set -u
. "$(dirname "$0")/common.sh"
c="${1:-}"; [ -n "$c" ] || die "usage: $0 CONTAINER [collector args...]"; shift
[ $# -gt 0 ] || set -- --file
COLLECTOR="${COLLECTOR:-$FIX_DIR/../../../../collectors/collection-server/collect-collmysql.sh}"
[ -r "$COLLECTOR" ] || die "no collector at $COLLECTOR"
running "$c" || die "$c is not running (up.sh)"
load_secrets
acct="${GGT_ACCOUNT:-app}"
case "$acct" in
    app)   cnf="$(printf '[client]\nuser=%s\npassword=%s\n' "$APP_USER" "$APP_PASS")" ;;
    mon)   cnf="$(printf '[client]\nuser=%s\npassword=%s\n' "$MON_USER" "$MON_PASS")" ;;
    wrong) cnf="$(printf '[client]\nuser=%s\npassword=%s\n' "$APP_USER" "wrong-$(tr -dc a-z0-9 </dev/urandom | head -c 8)")" ;;
    none)  cnf="" ;;
    *) die "GGT_ACCOUNT: app | mon | wrong | none" ;;
esac

if docker exec "$c" sh -c 'command -v sudo >/dev/null && id op >/dev/null 2>&1'; then
    u=op; h=/home/op; sudo_=(sudo)
else
    u=root; h=/root; sudo_=()
fi
run="$h/ggt-run"; name="$(basename "$COLLECTOR")"
docker exec "$c" sh -c "rm -rf '$run' && mkdir -p '$run' && chown $u: '$run'" || die "prepare $run"
docker cp "$COLLECTOR" "$c:$run/$name" >/dev/null || die "copy collector"
docker exec "$c" sh -c "chown $u: '$run/$name' && chmod 755 '$run/$name'"

args=("$@")
if [ -n "$cnf" ]; then
    # the password travels on stdin, never on a command line
    printf '%s\n' "$cnf" | docker exec -i -u "$u" "$c" sh -c 'umask 077; cat > "$HOME/.my.cnf"' || die "write .my.cnf"
    args+=("--defaults-file=$h/.my.cnf")
fi
say "$c: $u${sudo_:+ via sudo}: ./$name ${args[*]}  (account: $acct)"
docker exec -u "$u" -w "$run" -e HOME="$h" "$c" "${sudo_[@]}" "./$name" "${args[@]}"
rc=$?
[ -n "$cnf" ] && docker exec -u "$u" "$c" rm -f "$h/.my.cnf"
out="${GGT_OUT:-./ggt-out}/$c-$acct-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out" && docker cp "$c:$run/." "$out/" >/dev/null && rm -f "$out/$name"
say "exit $rc; report(s) in $out"
grep -hE "^\s+(privilege|connection attempted with|mysql connection|status):" "$out"/*.txt >&2 2>/dev/null
exit $rc
