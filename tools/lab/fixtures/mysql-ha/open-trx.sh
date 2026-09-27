#!/bin/bash
# open-trx.sh CONTAINER [SECONDS] -> in the background, hold one transaction
# open for SECONDS (default 120): a row lock on account.shedlock and an
# uncommitted MeteringDaily upsert, so section H (processlist) and the InnoDB
# status in section E show an open transaction. Primary and 5.7 only (the
# replica is super_read_only).
set -u
. "$(dirname "$0")/common.sh"
c="${1:-}"; s="${2:-120}"; [ -n "$c" ] || die "usage: $0 CONTAINER [SECONDS]"
[ "$c" = "$REPLICA" ] && die "$REPLICA is super_read_only; use $PRIMARY"
case "$s" in *[!0-9]*|'') die "SECONDS must be a whole number" ;; esac
sqltxt="BEGIN; UPDATE account.shedlock SET locked_by='ggt-open-trx' WHERE name='AccountCleaner'; INSERT INTO account.MeteringDaily (pcode,day,agents,txcount) VALUES (9999,CURDATE(),1,1) ON DUPLICATE KEY UPDATE txcount=txcount+1; SELECT SLEEP($s); ROLLBACK;"
if is57 "$c"; then cli="mysql --defaults-extra-file=/root/.ggt-root.cnf"; else cli=mysql; fi
docker exec -d "$c" sh -c "$cli -e \"$sqltxt\"" && say "$c: transaction open for ${s}s (rolled back at the end)"
