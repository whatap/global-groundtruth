#!/bin/bash
# load.sh CONTAINER [ROUNDS] -> ROUNDS (default 300) more scheduler-like write
# rounds (load.sql.sh), so the newest binary log has fresh row events.
set -u
. "$(dirname "$0")/common.sh"
c="${1:-}"; n="${2:-300}"; [ -n "$c" ] || die "usage: $0 CONTAINER [ROUNDS]"
[ "$c" = "$REPLICA" ] && die "$REPLICA is super_read_only; load $PRIMARY and it replicates"
bash "$FIX_DIR/load.sql.sh" "$n" | root_sql "$c" && say "$c: $n rounds written"
