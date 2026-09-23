#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — collection-server MySQL facts
# -----------------------------------------------------------------------------
# The WhaTap backend keeps its account/notihub metadata in MySQL. This collector
# reports that database's identity, HA/replication state, binary-log inventory
# and growth, storage and I/O counters, and the per-table attribution of binary
# log content. It reports measurements and the settings that govern them; the
# reader decides what they mean (CONTRACT rule 1).
#
# THE CONTRACT (../../CONTRACT.md):
#   1. Facts only. No emitted line states a conclusion.
#   2. Discover, never assume. Resolve datadir, log_bin_basename, the socket and
#      the replication role from the server itself, never from a hardcoded path.
#   3. One field command -> paste the whole output.
#   4. Domain-team owned.
#
# Binary-log attribution (section E) is the reason this collector exists: it
# decodes binary logs with mysqlbinlog and counts events per table, so a reader
# can tell which table produces the volume instead of inferring it. That probe
# reads log files and is therefore opt-in (--binlog), not part of the default
# report.
#
# NOTE: no `set -e`. A collector must always reach its footer.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata -----------------------------------------------------
COLLECTOR_NAME="whatap-collection-server-mysql"
VERSION="0.4.0"
DOMAIN="collection-server"
TARGET="collection-server-mysql/$(hostname 2>/dev/null || echo unknown)"

# ---- CLI harness ------------------------------------------------------------
OPT_FILE=0
OPT_STDOUT=0
OPT_QUIET=0
OPT_BINLOG=0          # decode binary logs and attribute events per table
BINLOG_FILES=2        # how many of the newest binary logs to decode
OPT_SAMPLE=0          # interval iostat/vmstat sampling
SAMPLE_SEC=5
SAMPLE_COUNT=6
BINLOG_TIMEOUT=300   # per-file cap for the mysqlbinlog decode
MYSQL_ARGS=""         # extra arguments handed to the mysql client
DEFAULTS_FILE=""

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")                     print this help (no collection)
  $(basename "$0") --file              write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout            print the facts report to stdout

  --defaults-file PATH   option file handed to the mysql client (credentials)
  --mysql-args "ARGS"    extra arguments for the mysql client, e.g. "-h 10.0.0.5 -P 3306 -u whatap -p..."
  --binlog[=N]           decode the N newest binary logs and count events per
                         table (default N=$BINLOG_FILES). Reads log files; off by default.
                         Each file is streamed once and capped at ${BINLOG_TIMEOUT}s
  --sample[=SEC]         add SEC-interval iostat/vmstat samples (default $SAMPLE_SEC s x $SAMPLE_COUNT)
  --quiet                silence progress on stderr

Connection: with neither --defaults-file nor --mysql-args, the mysql client is
invoked with no connection arguments, so it uses its own option files
(~/.my.cnf, /etc/my.cnf). Every section reports "n/a (<reason>)" when the client
cannot connect, so a run without credentials still produces the host-side facts.
EOF
}

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --file)    OPT_FILE=1 ;;
        --stdout)  OPT_STDOUT=1 ;;
        --quiet)   OPT_QUIET=1 ;;
        --binlog)  OPT_BINLOG=1 ;;
        --binlog=*) OPT_BINLOG=1; BINLOG_FILES="${1#*=}" ;;
        --sample)  OPT_SAMPLE=1 ;;
        --sample=*) OPT_SAMPLE=1; SAMPLE_SEC="${1#*=}" ;;
        --defaults-file) shift; DEFAULTS_FILE="${1:-}" ;;
        --defaults-file=*) DEFAULTS_FILE="${1#*=}" ;;
        --mysql-args) shift; MYSQL_ARGS="${1:-}" ;;
        --mysql-args=*) MYSQL_ARGS="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---- emit helpers -----------------------------------------------------------
_section_n=0

emit_header() {
    printf '==== WhaTap Global Groundtruth Collection ====\n'
    printf 'Collector:      %s\n' "$COLLECTOR_NAME"
    printf 'Version:        %s\n' "$VERSION"
    printf 'Timestamp(UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    printf 'Domain:         %s\n' "$DOMAIN"
    printf 'Target:         %s\n' "$TARGET"
    printf '===============================================\n'
}

section() {
    _section_n=$((_section_n + 1))
    printf '\n[%s] %s\n' "$1" "$2"
    progress "[$1] $2"
}

fact() { printf '    %s\n' "$1"; }
sub()  { printf '        %s\n' "$1"; }

emit_footer() { printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'; }

progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_timeout_bin=""
CMD_TIMEOUT=20
_init_probe() {
    _errfile="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.ggt.$$.err")"
    have timeout && _timeout_bin="$(command -v timeout)"
}

# ---- collection completeness — DO NOT EDIT ----------------------------------
# A collector knows, at the host, whether it obtained what it came for. Saying so
# is a fact about THIS COLLECTION RUN, not a claim about the environment, so it
# stays inside CONTRACT rule 1. (Rule 1 is spelled out for this case in
# CONTRACT.md, "Saying whether the collection worked".)
#
# Why it exists. A report full of `n/a (permission denied)` reads as finished to
# an operator whose terminal only said ">> done.". They package it and send it,
# and the gap surfaces days later in another time zone. Real case: two of three
# collection-server bundles came back carrying no conf/ at all, and nobody knew
# until the files had crossed a time zone (Smartfren, 2026-09-23). Every fact
# needed to catch that was already on the host while the operator was still
# logged in.
#
# It also serves rule 3 ("one field command → paste output"): deciding whether a
# run is worth sending is interpretation, and the field is not asked to do it.
#
# Usage, from the report body:
#     goal   conf "module configs"                    # what this run is for
#     got    conf                                     # obtained
#     missed conf "uid 3103 cannot reach /data/whatap" # not obtained, and why
#
# Declare a goal once, then resolve it exactly once with got/missed. A goal left
# unresolved counts as not obtained with reason "not reached", which is itself
# worth seeing: it means the run ended before that step.
_goal_keys='' _goal_labels='' _ok_keys='' _gap_keys='' _gap_reasons=''

goal()   { _goal_keys="$_goal_keys$1
"; _goal_labels="$_goal_labels$2
"; }
got()    { _ok_keys="$_ok_keys$1
"; }
missed() { _gap_keys="$_gap_keys$1
"; _gap_reasons="$_gap_reasons$2
"; }

# _label_of KEY -> the label declared for KEY (falls back to the key itself)
_label_of() {
    local i=1 k
    while IFS= read -r k; do
        [ "$k" = "$1" ] && { printf '%s' "$(printf '%s' "$_goal_labels" | sed -n "${i}p")"; return; }
        i=$((i + 1))
    done <<EOF
$_goal_keys
EOF
    printf '%s' "$1"
}

# _reason_of KEY -> the reason recorded for KEY, or empty
_reason_of() {
    local i=1 k
    while IFS= read -r k; do
        [ "$k" = "$1" ] && { printf '%s' "$(printf '%s' "$_gap_reasons" | sed -n "${i}p")"; return; }
        i=$((i + 1))
    done <<EOF
$_gap_keys
EOF
}

# notice: like progress, but NOT silenced by --quiet. Reserved for the
# completeness roll-up. --quiet exists to keep run narration out of automation
# logs; the one line that decides whether a run is worth sending is not
# narration, and an automated caller wants it most of all.
notice() { printf '>> %s\n' "$*" >&3 2>/dev/null; }

# emit_status -> the roll-up section. Call it immediately before emit_footer.
# Also repeats each gap on fd 3 so the operator sees it while still logged in.
emit_status() {
    [ -n "$_goal_keys" ] || return 0
    local k total=0 obtained=0 gaps='' oks=''
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        total=$((total + 1))
        if printf '%s' "$_ok_keys" | grep -qxF "$k"; then
            obtained=$((obtained + 1)); oks="$oks $(_label_of "$k"),"
        else
            local r; r="$(_reason_of "$k")"; [ -n "$r" ] || r='not reached'
            gaps="$gaps$(_label_of "$k") — $r
"
        fi
    done <<EOF
$_goal_keys
EOF
    section "Collection status"
    fact "goals: $total declared, $obtained obtained, $((total - obtained)) not obtained"
    [ -n "$oks" ] && fact "obtained:${oks%,}"
    if [ "$obtained" -eq "$total" ]; then
        fact "status: COMPLETE"
        notice "status: COMPLETE — $obtained of $total goals obtained"
    else
        fact "not obtained:"
        printf '%s' "$gaps" | while IFS= read -r l; do [ -n "$l" ] && fact "    $l"; done
        fact "status: INCOMPLETE"
        notice "status: INCOMPLETE — $((total - obtained)) of $total goals not obtained"
        printf '%s' "$gaps" | while IFS= read -r l; do [ -n "$l" ] && notice "  $l"; done
    fi
}
_end_probe() { [ -n "$_errfile" ] && rm -f "$_errfile" 2>/dev/null; }

_classify_err() {
    local txt=""
    [ -f "$_errfile" ] && txt="$(cat "$_errfile" 2>/dev/null)"
    case "$txt" in
        *"ccess denied"*)                                    echo "access denied"; return ;;
        *[Pp]"ermission denied"*|*"peration not permitted"*) echo "permission denied"; return ;;
        *"an't connect"*|*"onnection refused"*)              echo "cannot connect"; return ;;
        *"o such file"*|*"annot access"*|*"oes not exist"*)   echo "path not found"; return ;;
    esac
    # MariaDB's client echoes the statement between dashed rules before the
    # error, so the first line is often "--------------". Prefer the line that
    # actually carries the error.
    if [ -n "$txt" ]; then
        local line
        line="$(printf '%s\n' "$txt" | grep -m1 -E 'ERROR|error|denied|failed' 2>/dev/null)"
        [ -z "$line" ] && line="$(printf '%s\n' "$txt" | grep -m1 -vE '^[-[:space:]]*$' 2>/dev/null)"
        [ -z "$line" ] && line="$(printf '%s' "$txt" | head -n1)"
        printf 'error: %s' "$(printf '%s' "$line" | cut -c1-120)"
    else echo "nonzero exit"; fi
}

_emit_labeled() {
    local label="$1" body="$2" n
    n="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
    if [ "${n:-0}" -le 1 ]; then fact "$label: $body"
    else fact "$label:"; printf '%s\n' "$body" | while IFS= read -r _l || [ -n "$_l" ]; do sub "$_l"; done
    fi
}

probe() {
    local label="$1"; shift
    command -v "$1" >/dev/null 2>&1 || { fact "$label: n/a (command not found: $1)"; return; }
    local out rc
    if [ -n "$_timeout_bin" ]; then out="$("$_timeout_bin" "$CMD_TIMEOUT" "$@" 2>"$_errfile")"; rc=$?
    else out="$("$@" 2>"$_errfile")"; rc=$?; fi
    [ "$rc" -eq 124 ] && [ -n "$_timeout_bin" ] && { fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; }
    [ "$rc" -ne 0 ] && { fact "$label: n/a ($(_classify_err))"; return; }
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

read_proc() {
    local label="$1" path="$2" out
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    out="$(cat "$path" 2>/dev/null)"
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# ---- mysql client -----------------------------------------------------------
# Rule 2: the connection is discovered from the operator's option files unless
# arguments were given. _mysql_ok records once whether the client can connect,
# so every later section states a reason instead of failing silently.
MYSQL_BIN=""
MYSQL_OK=0
MYSQL_WHY="not attempted"

_mysql_base() {
    local args=""
    [ -n "$DEFAULTS_FILE" ] && args="--defaults-file=$DEFAULTS_FILE"
    printf '%s %s' "$args" "$MYSQL_ARGS"
}

# mysql_q "SQL" -> raw tab-separated rows on stdout, nonzero on failure
mysql_q() {
    [ -n "$MYSQL_BIN" ] || return 127
    # shellcheck disable=SC2086
    if [ -n "$_timeout_bin" ]; then
        "$_timeout_bin" "$CMD_TIMEOUT" "$MYSQL_BIN" $(_mysql_base) -N -B -e "$1" 2>"$_errfile"
    else
        "$MYSQL_BIN" $(_mysql_base) -N -B -e "$1" 2>"$_errfile"
    fi
}

# mysql_vertical "SQL" -> \G style output (for STATUS commands)
mysql_vertical() {
    [ -n "$MYSQL_BIN" ] || return 127
    # shellcheck disable=SC2086
    if [ -n "$_timeout_bin" ]; then
        "$_timeout_bin" "$CMD_TIMEOUT" "$MYSQL_BIN" $(_mysql_base) -e "$1\G" 2>"$_errfile"
    else
        "$MYSQL_BIN" $(_mysql_base) -e "$1\G" 2>"$_errfile"
    fi
}

# sql "label" "SQL" -> rows as facts, or a classified reason
sql() {
    local label="$1" q="$2" out rc
    if [ "$MYSQL_OK" != 1 ]; then fact "$label: n/a ($MYSQL_WHY)"; return; fi
    out="$(mysql_q "$q")"; rc=$?
    [ "$rc" -eq 124 ] && { fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; }
    [ "$rc" -ne 0 ] && { fact "$label: n/a ($(_classify_err))"; return; }
    [ -z "$out" ] && { fact "$label: none"; return; }
    _emit_labeled "$label" "$out"
}

sqlv() {
    local label="$1" q="$2" out rc
    if [ "$MYSQL_OK" != 1 ]; then fact "$label: n/a ($MYSQL_WHY)"; return; fi
    out="$(mysql_vertical "$q")"; rc=$?
    [ "$rc" -eq 124 ] && { fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; }
    [ "$rc" -ne 0 ] && { fact "$label: n/a ($(_classify_err))"; return; }
    [ -z "$out" ] && { fact "$label: none"; return; }
    _emit_labeled "$label" "$out"
}

# one scalar value, empty on failure (used for discovery, not for output)
mysql_val() {
    [ "$MYSQL_OK" = 1 ] || return 1
    mysql_q "$1" 2>/dev/null | head -n1 | awk '{print $NF}'
}

_resolve_mysql() {
    local c
    for c in mysql mariadb; do have "$c" && { MYSQL_BIN="$(command -v $c)"; break; }; done
    if [ -z "$MYSQL_BIN" ]; then MYSQL_WHY="command not found: mysql"; return; fi
    if mysql_q "SELECT 1" >/dev/null 2>&1; then MYSQL_OK=1; MYSQL_WHY="ok"
    else MYSQL_WHY="$(_classify_err)"; fi
}

# ---- report body ------------------------------------------------------------
run_report() {
    emit_header

    section 0 "Collection environment"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown)"
    fact "tools:"
    for t in mysql mysqlbinlog iostat vmstat ss findmnt lsblk timeout; do
        if have "$t"; then sub "$(printf '%-12s present' "$t")"
        else sub "$(printf '%-12s absent' "$t")"; fi
    done
    fact "mysql client: ${MYSQL_BIN:-n/a (command not found)}"
    fact "mysql connection: $MYSQL_WHY"
    fact "binlog decode tier: $([ "$OPT_BINLOG" = 1 ] && echo "on (newest $BINLOG_FILES files)" || echo "off")"
    fact "sampling tier: $([ "$OPT_SAMPLE" = 1 ] && echo "on (${SAMPLE_SEC}s x ${SAMPLE_COUNT})" || echo "off")"

    section A "Server identity and version"
    sql "version"        "SELECT VERSION()"
    sql "server host"    "SELECT @@hostname"
    sql "server_id"      "SELECT @@server_id"
    sql "server_uuid"    "SELECT @@server_uuid"
    sql "uptime(s)"      "SHOW GLOBAL STATUS LIKE 'Uptime'"
    # super_read_only arrived in 5.7; asking for both in one row loses read_only
    # on 5.6 and on MariaDB.
    sql "read_only"      "SELECT @@read_only"
    sql "super_read_only" "SELECT @@super_read_only"
    sql "port / socket"  "SELECT @@port, @@socket"
    sql "datadir"        "SELECT @@datadir"
    # pgrep -f would match this collector's own timeout wrapper, so filter the
    # process table instead and drop the matcher processes themselves.
    # `; true` would turn a missing ps into "empty output", which reads as
    # "no mysqld here". Fail loudly when the tool is absent; stay silent-but-
    # zero when the tool ran and simply matched nothing.
    probe "local mysqld process" sh -c \
        "command -v ps >/dev/null || { echo 'command not found: ps' >&2; exit 3; }; \
         ps -eo pid,user,args 2>/dev/null | grep -E '[m]ysqld|[m]ariadbd' | grep -v timeout; true"
    probe "listening sockets" sh -c \
        "command -v ss >/dev/null || command -v netstat >/dev/null || { echo 'command not found: ss, netstat' >&2; exit 3; }; \
         { ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null; } | grep -E ':3306|:33060'; true"

    section B "HA and replication"
    sql  "binlog_format"       "SELECT @@binlog_format"
    sql  "gtid_mode"           "SELECT @@gtid_mode"
    sql  "enforce_gtid_consistency" "SELECT @@enforce_gtid_consistency"
    sql  "log_replica_updates" "SHOW VARIABLES LIKE 'log_slave_updates'"
    sqlv "replica status"      "SHOW REPLICA STATUS"
    sqlv "slave status"        "SHOW SLAVE STATUS"
    # 8.4 removed SHOW MASTER STATUS; 5.7/8.0 do not know SHOW BINARY LOG
    # STATUS. Ask both so one of them always answers with the binlog position.
    sqlv "binary log status"   "SHOW BINARY LOG STATUS"
    sqlv "source status"       "SHOW MASTER STATUS"
    sql  "connected replicas"  "SHOW REPLICAS"
    sql  "connected slaves"    "SHOW SLAVE HOSTS"
    sql  "galera wsrep"        "SHOW STATUS LIKE 'wsrep_cluster_size'"
    # MEMBER_ROLE arrived in 8.0; naming it breaks the whole row on 5.7.
    sql  "group replication"   "SELECT MEMBER_HOST, MEMBER_STATE FROM performance_schema.replication_group_members"
    sql  "semi-sync"           "SHOW STATUS LIKE 'Rpl_semi_sync%_status'"

    section C "Binary log inventory and retention"
    sql "log_bin"                     "SELECT @@log_bin"
    sql "log_bin_basename"            "SELECT @@log_bin_basename"
    sql "log_bin_index"               "SELECT @@log_bin_index"
    sql "max_binlog_size"             "SELECT @@max_binlog_size"
    sql "binlog_expire_logs_seconds"  "SHOW VARIABLES LIKE 'binlog_expire_logs_seconds'"
    sql "expire_logs_days"            "SHOW VARIABLES LIKE 'expire_logs_days'"
    sql "binlog_row_image"            "SHOW VARIABLES LIKE 'binlog_row_image'"
    sql "binlog_rows_query_log_events" "SHOW VARIABLES LIKE 'binlog_rows_query_log_events'"
    sql "sync_binlog"                 "SELECT @@sync_binlog"
    # A host whose binary logs accumulate can hold thousands of files, and the
    # full listing would be the whole report. Report the inventory as totals
    # plus both ends; section I attributes the content.
    if [ "$MYSQL_OK" != 1 ]; then
        fact "binary logs: n/a ($MYSQL_WHY)"
    else
        _bl_rows="$(mysql_q "SHOW BINARY LOGS")"
        if [ -z "$_bl_rows" ]; then
            fact "binary logs: none"
        else
            fact "binary logs: $(printf '%s\n' "$_bl_rows" | wc -l | tr -d ' ') files, $(printf '%s\n' "$_bl_rows" | awk '{s+=$2} END {printf "%.0f", s+0}') bytes total (SHOW BINARY LOGS)"
            fact "binary logs (oldest 3, name bytes):"
            printf '%s\n' "$_bl_rows" | head -3 | while IFS= read -r _l; do sub "$_l"; done
            fact "binary logs (newest 20, name bytes):"
            printf '%s\n' "$_bl_rows" | tail -20 | while IFS= read -r _l; do sub "$_l"; done
        fi
    fi
    sql "binlog cache use / disk use" "SHOW GLOBAL STATUS LIKE 'Binlog_cache%'"
    sql "Binlog_bytes_written"        "SHOW GLOBAL STATUS LIKE 'Binlog%bytes%'"

    # Growth rate is measured from file mtimes, so it needs no second sample.
    BINLOG_DIR=""
    BINLOG_BASE="$(mysql_val "SELECT @@log_bin_basename" 2>/dev/null)"
    [ -n "$BINLOG_BASE" ] && BINLOG_DIR="$(dirname "$BINLOG_BASE" 2>/dev/null)"
    if [ -n "$BINLOG_DIR" ] && [ -d "$BINLOG_DIR" ] && [ -r "$BINLOG_DIR" ]; then
        fact "binlog directory: $BINLOG_DIR"
        probe "newest binlog files (mtime, bytes)" sh -c \
            "ls -l --time-style=+%Y-%m-%dT%H:%M:%SZ '$BINLOG_DIR' 2>/dev/null | grep -E '\\.[0-9]{6}\$' | tail -20"
        probe "binlog total bytes" sh -c \
            "du -sb '$BINLOG_DIR' 2>/dev/null | cut -f1"
    else
        fact "binlog directory: n/a (not resolved or not readable from this host)"
    fi

    section D "Storage and I/O"
    probe "df -hT" df -hT
    probe "mount points" sh -c "findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || mount"
    DATADIR="$(mysql_val "SELECT @@datadir" 2>/dev/null)"
    if [ -n "$DATADIR" ] && [ -d "$DATADIR" ]; then
        fact "datadir: $DATADIR"
        probe "datadir filesystem" sh -c "df -hT '$DATADIR' 2>/dev/null | tail -n +2"
    else
        fact "datadir: ${DATADIR:-n/a (not resolved)} (not present on this host)"
    fi
    read_proc "kernel diskstats" /proc/diskstats
    sql "Innodb_data counters"        "SHOW GLOBAL STATUS LIKE 'Innodb_data_%'"
    sql "Innodb_os_log counters"      "SHOW GLOBAL STATUS LIKE 'Innodb_os_log%'"
    sql "Innodb_buffer_pool reads"    "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read%'"
    sql "Innodb_buffer_pool pages"    "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_pages_%'"
    sql "Innodb_row operations"       "SHOW GLOBAL STATUS LIKE 'Innodb_rows_%'"
    sql "Com_ counters"               "SHOW GLOBAL STATUS WHERE Variable_name IN ('Com_select','Com_insert','Com_update','Com_delete','Com_commit','Queries')"

    section E "InnoDB configuration"
    sql "innodb_page_size"               "SELECT @@innodb_page_size"
    sql "innodb_buffer_pool_size"        "SELECT @@innodb_buffer_pool_size"
    sql "innodb_flush_log_at_trx_commit" "SELECT @@innodb_flush_log_at_trx_commit"
    sql "innodb_flush_method"            "SHOW VARIABLES LIKE 'innodb_flush_method'"
    sql "innodb_doublewrite"             "SELECT @@innodb_doublewrite"
    sql "innodb_io_capacity"             "SHOW VARIABLES LIKE 'innodb_io_capacity%'"
    sql "innodb_log_file settings"       "SHOW VARIABLES LIKE 'innodb_log_file%'"
    sql "innodb_redo_log_capacity"       "SHOW VARIABLES LIKE 'innodb_redo_log_capacity'"
    sqlv "engine status"                 "SHOW ENGINE INNODB STATUS"

    section F "Schema footprint"
    sql "schemas (name, tables, data MB, index MB)" \
        "SELECT table_schema, COUNT(*), ROUND(SUM(data_length)/1024/1024,1), ROUND(SUM(index_length)/1024/1024,1) FROM information_schema.tables GROUP BY table_schema ORDER BY SUM(data_length+index_length) DESC"
    sql "largest 25 tables (schema, table, rows, data MB, index MB)" \
        "SELECT table_schema, table_name, table_rows, ROUND(data_length/1024/1024,1), ROUND(index_length/1024/1024,1) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') ORDER BY data_length+index_length DESC LIMIT 25"
    sql "tables whose name contains lock/metering/event/audit" \
        "SELECT table_schema, table_name, table_rows FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') AND (table_name LIKE '%lock%' OR table_name LIKE '%meter%' OR table_name LIKE '%event%' OR table_name LIKE '%audit%') ORDER BY table_rows DESC"
    # A reader asking "is this query scanning?" needs the index the deployed
    # schema has, not the one the entity declares.
    sql "indexes of the 15 largest tables (schema, table, index, seq, column, cardinality)" \
        "SELECT s.TABLE_SCHEMA, s.TABLE_NAME, s.INDEX_NAME, s.SEQ_IN_INDEX, s.COLUMN_NAME, s.CARDINALITY FROM information_schema.statistics s JOIN (SELECT table_schema, table_name FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') ORDER BY data_length+index_length DESC LIMIT 15) t ON t.table_schema = s.TABLE_SCHEMA AND t.table_name = s.TABLE_NAME ORDER BY s.TABLE_SCHEMA, s.TABLE_NAME, s.INDEX_NAME, s.SEQ_IN_INDEX"
    sql "columns of DeniedIPAddress and ApmRegion" \
        "SELECT table_schema, table_name, column_name, is_nullable, column_type FROM information_schema.columns WHERE table_name IN ('DeniedIPAddress','ApmRegion') ORDER BY table_schema, table_name, ordinal_position"

    section G "Per-table I/O and index wait, from performance_schema"
    sql "performance_schema enabled" "SELECT @@performance_schema"
    sql "top 20 tables by I/O wait (schema, table, count, latency ns)" \
        "SELECT OBJECT_SCHEMA, OBJECT_NAME, COUNT_STAR, SUM_TIMER_WAIT FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA NOT IN ('mysql','performance_schema','information_schema') ORDER BY SUM_TIMER_WAIT DESC LIMIT 20"
    sql "top 20 tables by rows written (schema, table, inserts, updates, deletes)" \
        "SELECT OBJECT_SCHEMA, OBJECT_NAME, COUNT_INSERT, COUNT_UPDATE, COUNT_DELETE FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA NOT IN ('mysql','performance_schema','information_schema') ORDER BY COUNT_INSERT+COUNT_UPDATE+COUNT_DELETE DESC LIMIT 20"
    sql "top 15 statements by total latency (digest, count, latency ns, rows examined)" \
        "SELECT LEFT(DIGEST_TEXT,120), COUNT_STAR, SUM_TIMER_WAIT, SUM_ROWS_EXAMINED FROM performance_schema.events_statements_summary_by_digest ORDER BY SUM_TIMER_WAIT DESC LIMIT 15"
    sql "top 15 statements by rows examined (digest, count, rows examined, rows sent)" \
        "SELECT LEFT(DIGEST_TEXT,120), COUNT_STAR, SUM_ROWS_EXAMINED, SUM_ROWS_SENT FROM performance_schema.events_statements_summary_by_digest ORDER BY SUM_ROWS_EXAMINED DESC LIMIT 15"
    sql "file I/O by event (event, count read, bytes read, count write, bytes written)" \
        "SELECT EVENT_NAME, COUNT_READ, SUM_NUMBER_OF_BYTES_READ, COUNT_WRITE, SUM_NUMBER_OF_BYTES_WRITE FROM performance_schema.file_summary_by_event_name WHERE COUNT_STAR > 0 ORDER BY SUM_NUMBER_OF_BYTES_WRITE DESC LIMIT 15"

    section H "Current activity"
    sql "processlist"            "SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, LEFT(INFO,120) FROM information_schema.processlist ORDER BY TIME DESC LIMIT 30"
    sql "threads connected/running" "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Max_used_connections')"
    sql "max_connections"        "SELECT @@max_connections"

    section I "Binary log content attribution"
    if [ "$OPT_BINLOG" != 1 ]; then
        fact "n/a (not requested: pass --binlog to enable)"
    elif ! have mysqlbinlog; then
        fact "n/a (command not found: mysqlbinlog)"
    elif [ -z "$BINLOG_DIR" ] || [ ! -r "$BINLOG_DIR" ]; then
        fact "n/a (binary log directory not readable from this host)"
    else
        fact "decoding the $BINLOG_FILES newest binary logs under $BINLOG_DIR"
        _bl_list="$(ls -1t "$BINLOG_DIR" 2>/dev/null | grep -E '\.[0-9]{6}$' | head -n "$BINLOG_FILES")"
        if [ -z "$_bl_list" ]; then
            fact "n/a (no binary log files matched under $BINLOG_DIR)"
        else
            for _bl in $_bl_list; do
                _path="$BINLOG_DIR/$_bl"
                _bytes="$(ls -l "$_path" 2>/dev/null | awk '{print $5}')"
                fact "file: $_bl ($_bytes bytes)"
                # A production binary log is max_binlog_size (1 GiB by default),
                # and decoded row events run about 1.15x that. Holding it in a
                # shell variable and walking it six times costs gigabytes of RSS
                # on a host that is already short of I/O, so stream it once
                # through awk and keep only the counters.
                _sum="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.ggt.$$.bl")"
                if [ -n "$_timeout_bin" ]; then
                    "$_timeout_bin" "$BINLOG_TIMEOUT" mysqlbinlog --no-defaults \
                        --base64-output=DECODE-ROWS -v "$_path" 2>"$_errfile"
                else
                    mysqlbinlog --no-defaults --base64-output=DECODE-ROWS -v "$_path" 2>"$_errfile"
                fi | awk '
                    /^### INSERT INTO / { c["INSERT " $4]++; rows++; next }
                    /^### UPDATE /      { c["UPDATE " $3]++; rows++; next }
                    /^### DELETE FROM / { c["DELETE " $4]++; rows++; next }
                    # MySQL writes BEGIN; MariaDB writes START TRANSACTION
                    /^BEGIN/ || /^START TRANSACTION/ { begins++; next }
                    # Only the event header line, not the SET pseudo_thread_id it
                    # emits. MariaDB opens transactions with a GTID event instead,
                    # so this counts statement and DDL events, not transactions.
                    /^#[0-9]/ && /thread_id=/ { queries++ }
                    /^#[0-9][0-9][0-9][0-9][0-9][0-9] / {
                        if (first == "") first = $1 " " $2; last = $1 " " $2
                    }
                    END {
                        for (k in c) printf "T\t%d\t%s\n", c[k], k
                        printf "S\trows\t%d\n",    rows + 0
                        printf "S\tbegins\t%d\n",  begins + 0
                        printf "S\tqueries\t%d\n", queries + 0
                        printf "S\tfirst\t%s\n",   first
                        printf "S\tlast\t%s\n",    last
                    }' > "$_sum" 2>/dev/null
                _rc=$?
                if [ ! -s "$_sum" ]; then
                    sub "n/a ($(_classify_err))"
                    rm -f "$_sum" 2>/dev/null
                    continue
                fi
                [ "$_rc" -eq 124 ] && sub "note: decoding stopped at the ${BINLOG_TIMEOUT}s cap, counts below are partial"
                _rows="$(awk -F'\t' '$2=="rows"{print $3}' "$_sum")"
                if [ "${_rows:-0}" -eq 0 ]; then
                    sub "events per table: none (no row events decoded; check binlog_format in section C)"
                else
                    sub "events per table (count, table):"
                    awk -F'\t' '$1=="T"{printf "%12d %s\n", $2, $3}' "$_sum" \
                        | sort -rn | head -30 \
                        | while IFS= read -r _l; do printf '            %s\n' "$_l"; done
                fi
                sub "row events (count): ${_rows:-0}"
                sub "transactions (BEGIN count): $(awk -F'\t' '$2=="begins"{print $3}' "$_sum")"
                sub "statement and DDL events (Query, count): $(awk -F'\t' '$2=="queries"{print $3}' "$_sum")"
                sub "first event timestamp: $(awk -F'\t' '$2=="first"{print $3}' "$_sum")"
                sub "last event timestamp:  $(awk -F'\t' '$2=="last"{print $3}' "$_sum")"
                rm -f "$_sum" 2>/dev/null
            done
        fi
    fi

    section J "Interval samples"
    if [ "$OPT_SAMPLE" != 1 ]; then
        fact "n/a (not requested: pass --sample to enable)"
    else
        CMD_TIMEOUT=$(( SAMPLE_SEC * SAMPLE_COUNT + 30 ))
        probe "iostat -x" iostat -x "$SAMPLE_SEC" "$SAMPLE_COUNT"
        probe "vmstat" vmstat "$SAMPLE_SEC" "$SAMPLE_COUNT"
        CMD_TIMEOUT=20
    fi

    section K "MySQL error log"
    ERRLOG="$(mysql_val "SELECT @@log_error" 2>/dev/null)"
    if [ -n "$ERRLOG" ] && [ -r "$ERRLOG" ]; then
        fact "log_error: $ERRLOG"
        probe "last 60 lines" tail -n 60 "$ERRLOG"
    else
        fact "log_error: ${ERRLOG:-n/a (not resolved)} (not readable from this host)"
        probe "journal (mysql/mariadb, last 60)" sh -c \
            "journalctl -u mysql -u mysqld -u mariadb -n 60 --no-pager 2>/dev/null"
    fi

    emit_footer
}

# ---- main -------------------------------------------------------------------
exec 3>&2

[ "$ARGC" -eq 0 ] && { usage; exit 0; }

if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
fi

_init_probe
_resolve_mysql
TARGET="collection-server-mysql/$(hostname 2>/dev/null || echo unknown)@${MYSQL_WHY}"

if [ "$OPT_STDOUT" = 1 ]; then
    progress "collecting facts (read-only) -> stdout"
    run_report
    progress "done."
else
    HOST="$(hostname 2>/dev/null || echo unknown)"
    TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
    OUTFILE="./$COLLECTOR_NAME-$HOST-$TS.txt"
    progress "collecting facts (read-only) -> writing $OUTFILE"
    run_report > "$OUTFILE" 2>/dev/null
    progress "report written: $OUTFILE"
fi
_end_probe
