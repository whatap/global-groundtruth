#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — DB monitoring collector
# -----------------------------------------------------------------------------
# Collects facts about a WhaTap DB-monitoring installation. The DBX agent
# queries the monitored database over JDBC, so the agent host and the DB host
# are often DIFFERENT machines (and the DB itself may be a managed cloud
# service with no reachable host at all). This collector therefore discovers
# what is present on the host it runs on and adapts:
#
#   * DBX-side components found (dbx / dmx / prx / dbxc)  -> agent-host sections
#   * XOS / xcub / DB server processes found              -> DB-host sections
#   * neither                                             -> that fact itself
#
# Field procedure (see README.md):
#   1. run on the DBX agent host:      ./collect-db.sh --file
#   2. on-prem split topology: run the same command on the DB host too
#   3. run the matching sql/<engine>.sql through the DB client with the
#      monitoring account, and paste its output together with the reports
#
# THE CONTRACT (../../CONTRACT.md):
#   1. Facts only — no conclusions in any emitted line.
#   2. Discover, never assume — resolve processes/config; absent = "n/a (why)".
#   3. One field command -> paste output.
#   4. Domain-team owned (interim: Global team).
#
# NOTE: no `set -e` by design — the collector must reach its footer even when
# every probe fails. Config files are dumped verbatim (framework policy:
# genuinely sensitive material is stored encrypted, masking destroys facts).
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata ------------------------------------------------------
COLLECTOR_NAME="whatap-db"
VERSION="0.1.0"
DOMAIN="db"
TARGET="db-host/$(hostname 2>/dev/null || echo unknown)"

# ---- CLI harness ---------------------------------------------------------------
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr
OPT_HOMES=""      # newline-separated extra agent homes from --home
OPT_SQL=0         # Tier 2: run the SQL pack over JDBC (agent's own java + driver)
OPT_TLS=0         # Tier 2: one TLS handshake per instance against the DB endpoint

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Target: a WhaTap DB-monitoring host — the DBX agent host, the monitored DB
host (XOS side), or both when co-located. The script discovers which
components are present and reports the matching fact sections.
Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")                  print this help (no collection)
  $(basename "$0") --file           write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout         print the facts report to stdout
  $(basename "$0") --quiet ..       silence progress on stderr (add to --file / --stdout)
  $(basename "$0") --home <dir> ..  add an agent install dir the process scan cannot see
                                    (repeatable; useful when no agent process is running)

  Tier 2 (opt-in — each is announced on stderr before anything is sent):
  $(basename "$0") --file --sql   run the read-only SQL pack over JDBC using the
                                  agent's own java + jdbc/ driver (no DB client
                                  needed); asks for the monitoring account on
                                  the terminal, or reads WHATAP_GGT_USER /
                                  WHATAP_GGT_PW from the environment
  $(basename "$0") --file --tls   one TLS handshake per instance to the DB
                                  endpoint (openssl s_client): server TLS
                                  version, cipher, certificate dates/signature

The same SQL packs can also be run through a DB client where one exists:
  sql/postgresql.sql (psql)  sql/mysql.sql (mysql)  sql/oracle.sql (sqlplus)
  windows/mssql.sql (sqlcmd)
EOF
}

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --file)    OPT_FILE=1 ;;
        --stdout)  OPT_STDOUT=1 ;;
        --quiet)   OPT_QUIET=1 ;;
        --sql)     OPT_SQL=1 ;;
        --tls)     OPT_TLS=1 ;;
        --home)
            if [ $# -lt 2 ]; then printf -- '--home needs a directory argument\n' >&2; exit 2; fi
            OPT_HOMES="$OPT_HOMES$2
"
            shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---- emit helpers -------------------------------------------------------------
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
    printf '\n[%d] %s\n' "$_section_n" "$1"
    progress "[$_section_n] $1"
}

subsection() {
    printf '\n    -- %s --\n' "$1"
}

fact() {
    printf '    %s\n' "$1"
}

emit_footer() {
    printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'
}

progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

# warn: Tier-2 announcements — always shown, even with --quiet (guideline 2:
# anything that touches the monitored DB is announced before it runs).
warn() { printf '!! %s\n' "$*" >&3 2>/dev/null; }

# ---- reasoned-absence helpers --------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_timeout_bin=""
CMD_TIMEOUT=20
NET_TIMEOUT=5
_init_probe() {
    _errfile="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.ggt.$$.err")"
    have timeout && _timeout_bin="$(command -v timeout)"
}
_end_probe() { [ -n "$_errfile" ] && rm -f "$_errfile" "$_logwin" 2>/dev/null; }

_classify_err() {
    local txt=""
    [ -f "$_errfile" ] && txt="$(cat "$_errfile" 2>/dev/null)"
    case "$txt" in
        *[Pp]"ermission denied"*|*"peration not permitted"*) echo "permission denied"; return ;;
        *"o such file"*|*"annot access"*|*"oes not exist"*)   echo "path not found";    return ;;
    esac
    if [ -n "$txt" ]; then printf 'error: %s' "$(printf '%s' "$txt" | head -n1 | cut -c1-100)"
    else echo "nonzero exit"; fi
}

_emit_labeled() {
    local label="$1" body="$2" n
    n="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
    if [ "${n:-0}" -le 1 ]; then
        fact "$label: $body"
    else
        fact "$label:"
        printf '%s\n' "$body" | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
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

# probe_merged: like probe but folds stderr into stdout (java -version etc.).
probe_merged() {
    local label="$1"; shift
    local bin="$1"
    command -v "$bin" >/dev/null 2>&1 || { fact "$label: n/a (command not found: $bin)"; return; }
    local out rc
    if [ -n "$_timeout_bin" ]; then out="$("$_timeout_bin" "$CMD_TIMEOUT" "$@" 2>&1)"; rc=$?
    else out="$("$@" 2>&1)"; rc=$?; fi
    [ "$rc" -eq 124 ] && [ -n "$_timeout_bin" ] && { fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; }
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

# java_tls_policy LABEL JAVA_EXE -> the runtime's jdk.tls.disabledAlgorithms
# property. TLS-version and certificate-algorithm rejections seen in agent
# logs originate here as often as in the DB, and the value differs per JDK.
_TLSP_SEEN=""
java_tls_policy() {
    local label="$1" exe="$2" jh sec f prop
    [ -n "$exe" ] || { fact "$label: n/a (java path unknown)"; return; }
    exe="$(readlink -f "$exe" 2>/dev/null || printf '%s' "$exe")"
    jh="$(dirname "$(dirname "$exe")")"
    case " $_TLSP_SEEN " in *" $jh "*) fact "$label: same runtime as above ($jh)"; return ;; esac
    _TLSP_SEEN="$_TLSP_SEEN $jh"
    sec=""
    for f in "$jh/conf/security/java.security" "$jh/lib/security/java.security" "$jh/jre/lib/security/java.security"; do
        [ -f "$f" ] && { sec="$f"; break; }
    done
    [ -z "$sec" ] && { fact "$label: n/a (java.security not found under $jh)"; return; }
    fact "$label: $sec"
    prop="$(awk '/^jdk\.tls\.disabledAlgorithms=/{p=1} p{print; if ($0 !~ /\\$/) exit}' "$sec" 2>/dev/null)"
    if [ -n "$prop" ]; then _emit_labeled "jdk.tls.disabledAlgorithms" "$prop"
    else fact "jdk.tls.disabledAlgorithms: n/a (property not found in $sec)"; fi
}

# dump_file "label" PATH [MAXLINES] -> verbatim file content (framework policy:
# no masking), or a classified reason. Caps at MAXLINES (default 400).
dump_file() {
    local label="$1" path="$2" max="${3:-400}" total
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label (verbatim, $total lines$( [ "${total:-0}" -gt "$max" ] && printf ', first %s shown' "$max" )):"
    head -n "$max" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# conf_get FILE KEY -> value of the last non-comment "KEY=..." line, trimmed.
conf_get() {
    grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | grep -v '^[[:space:]]*#' \
        | tail -n1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# tcp_probe "label" HOST PORT -> single bounded TCP connect attempt (load-safe:
# one attempt, NET_TIMEOUT cap, skipped when no timeout binary exists).
tcp_probe() {
    local label="$1" host="$2" port="$3" rc t0 t1
    [ -n "$host" ] && [ -n "$port" ] || { fact "$label: n/a (not applicable: host/port not set)"; return; }
    if [ -z "$_timeout_bin" ]; then
        fact "$label: n/a (not applicable: timeout binary absent, connect probe skipped)"
        return
    fi
    t0="$(date +%s 2>/dev/null)"
    "$_timeout_bin" "$NET_TIMEOUT" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
    rc=$?
    t1="$(date +%s 2>/dev/null)"
    if [ "$rc" -eq 0 ]; then
        fact "$label: tcp connect to $host:$port succeeded ($((t1 - t0))s)"
    elif [ "$rc" -eq 124 ]; then
        fact "$label: tcp connect to $host:$port timed out (${NET_TIMEOUT}s)"
    else
        fact "$label: tcp connect to $host:$port did not connect (rc=$rc, $((t1 - t0))s)"
    fi
}

# ---- discovery (run once) ------------------------------------------------------
# Parallel arrays of discovered processes and install dirs (bash 3.2 safe).
AG_PIDS=(); AG_KINDS=()      # whatap components: dbx dmx prx xos xcub dbxc
DBP_PIDS=(); DBP_KINDS=()    # database server processes on this host
HOME_DIRS=(); HOME_SRCS=()   # agent install dir candidates + how each was found
INST_DIRS=()                 # dirs containing a whatap.conf (one per agent instance)
XOS_CONFS=()                 # xos.conf files found under homes

cmdline_of() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }

_kind_of_cmdline() {
    case "$1" in
        *whatap.agent.dbx*)  echo dbx ;;
        *whatap.agent.dmx*)  echo dmx ;;
        *whatap.agent.prx*)  echo prx ;;
        *whatap.agent.xos*)  echo xos ;;
        *dbxc*)              echo dbxc ;;
        *xcub*)              echo xcub ;;
        *)                   echo "" ;;
    esac
}

_db_kind_of_comm() {
    case "$1" in
        postgres|postmaster)      echo postgresql ;;
        mysqld|mariadbd)          echo mysql/mariadb ;;
        ora_pmon*|oracle*)        echo oracle ;;
        tbsvr*)                   echo tibero ;;
        redis-server|valkey-serv*) echo redis/valkey ;;
        mongod)                   echo mongodb ;;
        sqlservr)                 echo mssql ;;
        db2sysc)                  echo db2 ;;
        cub_master|cub_server|cub_broker) echo cubrid ;;
        *)                        echo "" ;;
    esac
}

add_home() { # DIR SRC — dedupe on DIR
    local d="$1" s="$2" i=0
    [ -n "$d" ] && [ -d "$d" ] || return
    d="$(cd "$d" 2>/dev/null && pwd)" || return
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        [ "${HOME_DIRS[$i]}" = "$d" ] && return
        i=$((i + 1))
    done
    HOME_DIRS[${#HOME_DIRS[@]}]="$d"
    HOME_SRCS[${#HOME_SRCS[@]}]="$s"
}

add_inst() { # DIR — dedupe
    local d="$1" i=0
    [ -n "$d" ] && [ -d "$d" ] || return
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        [ "${INST_DIRS[$i]}" = "$d" ] && return
        i=$((i + 1))
    done
    INST_DIRS[${#INST_DIRS[@]}]="$d"
}

discover() {
    local d pid cl kind comm jarpath cwd h

    # 1) process scan — /proc when available, `ps` otherwise (AIX / HP-UX etc.)
    if [ -d /proc/1 ]; then
        for d in /proc/[0-9]*; do
            [ -r "$d/cmdline" ] || continue
            pid="${d#/proc/}"
            cl="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
            [ -n "$cl" ] || continue
            kind="$(_kind_of_cmdline "$cl")"
            if [ -n "$kind" ]; then
                AG_PIDS[${#AG_PIDS[@]}]="$pid"
                AG_KINDS[${#AG_KINDS[@]}]="$kind"
                cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
                add_home "$cwd" "cwd of $kind process $pid"
                jarpath="$(printf '%s\n' "$cl" | tr ' ' '\n' | grep -E '^/.*whatap\.agent\.[a-z]+.*\.jar$' | head -n1)"
                [ -n "$jarpath" ] && add_home "$(dirname "$jarpath")" "jar path of $kind process $pid"
                continue
            fi
            comm="$(cat "$d/comm" 2>/dev/null)"
            kind="$(_db_kind_of_comm "$comm")"
            if [ -n "$kind" ]; then
                DBP_PIDS[${#DBP_PIDS[@]}]="$pid"
                DBP_KINDS[${#DBP_KINDS[@]}]="$kind"
            fi
        done
    else
        # non-Linux fallback: parse `ps`, derive homes from absolute jar paths
        ps -ef 2>/dev/null | while IFS= read -r _l; do :; done   # capability check only
        for pid in $(ps -ef 2>/dev/null | awk '/whatap\.agent\.|dbxc|xcub/ && !/awk/ {print $2}'); do
            cl="$(ps -o args= -p "$pid" 2>/dev/null)"
            kind="$(_kind_of_cmdline "$cl")"
            [ -n "$kind" ] || continue
            AG_PIDS[${#AG_PIDS[@]}]="$pid"
            AG_KINDS[${#AG_KINDS[@]}]="$kind"
            jarpath="$(printf '%s\n' "$cl" | tr ' ' '\n' | grep -E '^/.*whatap\.agent\.[a-z]+.*\.jar$' | head -n1)"
            [ -n "$jarpath" ] && add_home "$(dirname "$jarpath")" "jar path of $kind process $pid (ps)"
        done
    fi

    # 2) homes given on the command line
    if [ -n "$OPT_HOMES" ]; then
        printf '%s' "$OPT_HOMES" > "${TMPDIR:-/tmp}/.ggt.$$.homes" 2>/dev/null
        while IFS= read -r h; do
            [ -n "$h" ] && add_home "$h" "option --home"
        done < "${TMPDIR:-/tmp}/.ggt.$$.homes"
        rm -f "${TMPDIR:-/tmp}/.ggt.$$.homes" 2>/dev/null
    fi

    # 3) instances = dirs holding a whatap.conf under each home (depth-capped);
    #    xos.conf files are recorded the same way
    local i=0 f
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        h="${HOME_DIRS[$i]}"
        for f in $(find "$h" -maxdepth 2 -name whatap.conf -type f 2>/dev/null | head -n 20); do
            add_inst "$(dirname "$f")"
        done
        for f in $(find "$h" -maxdepth 2 -name xos.conf -type f 2>/dev/null | head -n 20); do
            XOS_CONFS[${#XOS_CONFS[@]}]="$f"
        done
        i=$((i + 1))
    done

    # 4) watched ports = defaults (6600 collection server, 3002 xos->dbx)
    #    extended by whatap.server.port / xos_port values found in the confs
    local p ports="6600 3002"
    i=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        for p in "$(conf_get "${INST_DIRS[$i]}/whatap.conf" 'whatap\.server\.port')" \
                 "$(conf_get "${INST_DIRS[$i]}/whatap.conf" xos_port)"; do
            case "$p" in [0-9]*) ports="$ports $p" ;; esac
        done
        i=$((i + 1))
    done
    WATCH_PORTS="$(printf '%s\n' $ports | sort -un | tr '\n' ' ' | sed 's/ $//')"
    WATCH_PORTS_RE="$(printf '%s\n' $ports | sort -un | tr '\n' '|' | sed 's/|$//')"
}
WATCH_PORTS="6600 3002"
WATCH_PORTS_RE="6600|3002"

# counts of discovered component kinds (computed after discover)
_count_kind() {
    local want="$1" i=0 n=0
    while [ "$i" -lt "${#AG_KINDS[@]}" ]; do
        [ "${AG_KINDS[$i]}" = "$want" ] && n=$((n + 1))
        i=$((i + 1))
    done
    echo "$n"
}

# ---- JDBC SQL-pack runner (Tier 2, --sql) --------------------------------------
# The DBX agent works over JDBC end-to-end: installing it never needed a DB
# client, so a client cannot be assumed anywhere. The one guaranteed path to
# the DB is the agent host itself — java (a DBX prerequisite) + the proven
# driver in jdbc/ + network reachability. This runner reuses exactly those.
# JDK 9+ -> jshell; JDK 8 -> jrunscript (Nashorn). Read-only; each statement
# capped at 20s, rows at 200; a SQL error prints as a fact and the run goes on.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
_JBIN=""
_JDBC_MODE=""

_write_runner_jsh() {
    cat > "$1" <<'JSHEOF'
import java.sql.*;
import java.nio.file.*;
import java.util.*;
String pack = System.getenv("WHATAP_GGT_PACK");
String url  = System.getenv("WHATAP_GGT_URL");
String usr  = System.getenv("WHATAP_GGT_USER");
String pw   = System.getenv("WHATAP_GGT_PW");
List<String> stmts = new ArrayList<>();
StringBuilder cur = new StringBuilder();
for (String line : Files.readAllLines(Paths.get(pack))) {
    String t = line.trim();
    if (t.isEmpty() || t.startsWith("--") || t.startsWith("\\")
        || t.matches("(?i)^(SET|WHENEVER|PROMPT|EXIT|GO|USE)\\b.*")) continue;
    cur.append(line).append('\n');
    if (t.endsWith(";")) {
        String s = cur.toString().trim();
        stmts.add(s.substring(0, s.length() - 1));
        cur.setLength(0);
    }
}
DriverManager.setLoginTimeout(10);
try (Connection c = DriverManager.getConnection(url, usr, pw)) {
    for (String s : stmts) {
        try (Statement st = c.createStatement()) {
            st.setQueryTimeout(20);
            boolean has = st.execute(s);
            if (has) {
                try (ResultSet rs = st.getResultSet()) {
                    ResultSetMetaData md = rs.getMetaData();
                    int n = md.getColumnCount();
                    StringBuilder h = new StringBuilder();
                    for (int i = 1; i <= n; i++) { if (i > 1) h.append(" | "); h.append(md.getColumnLabel(i)); }
                    System.out.println(h);
                    int rows = 0;
                    while (rs.next() && rows < 200) {
                        StringBuilder r = new StringBuilder();
                        for (int i = 1; i <= n; i++) { if (i > 1) r.append(" | "); String v = rs.getString(i); r.append(v == null ? "NULL" : v); }
                        System.out.println(r);
                        rows++;
                    }
                    if (rows >= 200) System.out.println("(truncated at 200 rows)");
                    System.out.println("(" + rows + " rows)");
                    System.out.println();
                }
            } else { System.out.println("(ok)"); }
        } catch (SQLException e) {
            System.out.println("SQL-ERROR: " + e.getMessage().split("\n")[0]);
            System.out.println();
        }
    }
} catch (SQLException e) {
    System.out.println("CONNECT-ERROR: " + e.getMessage().split("\n")[0]);
}
/exit
JSHEOF
}

_write_runner_js() {
    cat > "$1" <<'JSEOF'
var Files = java.nio.file.Files, Paths = java.nio.file.Paths, Sys = java.lang.System;
var pack = Sys.getenv("WHATAP_GGT_PACK"), url = Sys.getenv("WHATAP_GGT_URL");
var usr = Sys.getenv("WHATAP_GGT_USER"), pw = Sys.getenv("WHATAP_GGT_PW");
var text = new java.lang.String(Files.readAllBytes(Paths.get(pack)), "UTF-8");
var stmts = [], cur = "";
text.split("\n").forEach(function (line) {
    var t = line.trim();
    if (t === "" || t.indexOf("--") === 0 || t.indexOf("\\") === 0
        || /^(SET|WHENEVER|PROMPT|EXIT|GO|USE)\b/i.test(t)) return;
    cur += line + "\n";
    if (/;\s*$/.test(t)) { stmts.push(cur.replace(/;\s*$/m, "")); cur = ""; }
});
java.sql.DriverManager.setLoginTimeout(10);
var conn;
try { conn = java.sql.DriverManager.getConnection(url, usr, pw); }
catch (e) { print("CONNECT-ERROR: " + ("" + e.message).split("\n")[0]); }
if (conn) {
    stmts.forEach(function (s) {
        var st;
        try {
            st = conn.createStatement(); st.setQueryTimeout(20);
            if (st.execute(s)) {
                var rs = st.getResultSet(), md = rs.getMetaData(), n = md.getColumnCount();
                var h = []; for (var i = 1; i <= n; i++) h.push(md.getColumnLabel(i)); print(h.join(" | "));
                var rows = 0;
                while (rs.next() && rows < 200) {
                    var r = []; for (var j = 1; j <= n; j++) { var v = rs.getString(j); r.push(v === null ? "NULL" : v); }
                    print(r.join(" | ")); rows++;
                }
                if (rows >= 200) print("(truncated at 200 rows)");
                print("(" + rows + " rows)"); print("");
            } else { print("(ok)"); }
            st.close();
        } catch (e) { print("SQL-ERROR: " + ("" + e.message).split("\n")[0]); print(""); if (st) st.close(); }
    });
    conn.close();
}
JSEOF
}

_pick_java_bindir() {
    _JBIN=""; _JDBC_MODE=""
    local i=0 exe
    while [ "$i" -lt "${#AG_PIDS[@]}" ]; do
        exe="$(readlink "/proc/${AG_PIDS[$i]}/exe" 2>/dev/null)"
        case "$exe" in */java) _JBIN="$(dirname "$exe")"; break ;; esac
        i=$((i + 1))
    done
    [ -z "$_JBIN" ] && have java && _JBIN="$(dirname "$(command -v java)")"
    [ -n "$_JBIN" ] || return 1
    if [ -x "$_JBIN/jshell" ]; then _JDBC_MODE="jshell"
    elif [ -x "$_JBIN/jrunscript" ] && "$_JBIN/jrunscript" -e 'print(1)' >/dev/null 2>&1; then _JDBC_MODE="jrunscript"
    else return 1; fi
    return 0
}

_find_jdbc_jar() { # GLOB... -> first matching jar under any home/instance jdbc dir
    local d g j
    for d in "${HOME_DIRS[@]}" "${INST_DIRS[@]}"; do
        for g in "$@"; do
            for j in "$d"/jdbc/$g; do
                [ -f "$j" ] && { printf '%s' "$j"; return 0; }
            done
        done
    done
    return 1
}

CRED_USER=""; CRED_PW=""
_get_creds() { # LABEL -> 0 with CRED_USER/CRED_PW set, 1 = skip (with reason fact)
    CRED_USER="${WHATAP_GGT_USER:-}"; CRED_PW="${WHATAP_GGT_PW:-}"
    [ -n "$CRED_USER" ] && { fact "credentials: from WHATAP_GGT_USER env"; return 0; }
    if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        fact "credentials: n/a (no terminal and WHATAP_GGT_USER unset — instance skipped)"
        return 1
    fi
    printf '!! monitoring account user for %s (empty = skip this instance): ' "$1" > /dev/tty
    IFS= read -r CRED_USER < /dev/tty
    [ -z "$CRED_USER" ] && { fact "credentials: none entered — instance skipped"; return 1; }
    printf '!! password for %s: ' "$CRED_USER" > /dev/tty
    IFS= read -rs CRED_PW < /dev/tty
    printf '\n' > /dev/tty
    fact "credentials: entered on terminal (user=$CRED_USER)"
    return 0
}

_run_jdbc_pack() { # PACKFILE URL JAR -> runner output on stdout
    local rfile out
    # UTF-8 is forced on the runner VM: the report must carry DB text (Korean
    # query text etc.) byte-true even though the collector itself runs LC_ALL=C
    if [ "$_JDBC_MODE" = "jshell" ]; then
        rfile="${TMPDIR:-/tmp}/.ggt.$$.runner.jsh"
        _write_runner_jsh "$rfile"
        if [ -n "$_timeout_bin" ]; then
            WHATAP_GGT_PACK="$1" WHATAP_GGT_URL="$2" WHATAP_GGT_USER="$CRED_USER" WHATAP_GGT_PW="$CRED_PW" \
                "$_timeout_bin" 120 "$_JBIN/jshell" -q -J-Dfile.encoding=UTF-8 -R-Dfile.encoding=UTF-8 --class-path "$3" "$rfile" 2>&1
        else
            WHATAP_GGT_PACK="$1" WHATAP_GGT_URL="$2" WHATAP_GGT_USER="$CRED_USER" WHATAP_GGT_PW="$CRED_PW" \
                "$_JBIN/jshell" -q -J-Dfile.encoding=UTF-8 -R-Dfile.encoding=UTF-8 --class-path "$3" "$rfile" 2>&1
        fi
    else
        rfile="${TMPDIR:-/tmp}/.ggt.$$.runner.js"
        _write_runner_js "$rfile"
        if [ -n "$_timeout_bin" ]; then
            WHATAP_GGT_PACK="$1" WHATAP_GGT_URL="$2" WHATAP_GGT_USER="$CRED_USER" WHATAP_GGT_PW="$CRED_PW" \
                "$_timeout_bin" 120 "$_JBIN/jrunscript" -J-Dfile.encoding=UTF-8 -cp "$3" "$rfile" 2>&1
        else
            WHATAP_GGT_PACK="$1" WHATAP_GGT_URL="$2" WHATAP_GGT_USER="$CRED_USER" WHATAP_GGT_PW="$CRED_PW" \
                "$_JBIN/jrunscript" -J-Dfile.encoding=UTF-8 -cp "$3" "$rfile" 2>&1
        fi
    fi
    rm -f "$rfile" 2>/dev/null
}

# ---- log window helpers --------------------------------------------------------
LOG_TAIL_LINES=200      # verbatim tail of the newest agent log
LOG_SCAN_LINES=5000     # bounded window for pattern counting (never whole logs)
_logwin="${TMPDIR:-/tmp}/.ggt.$$.logwin"

newest_matching() { # DIR GLOB -> newest matching file path (mtime), or empty
    ls -1t "$1"/$2 2>/dev/null | head -n1
}

load_logwin() { # FILE -> fills $_logwin with its last LOG_SCAN_LINES lines
    : > "$_logwin" 2>/dev/null
    [ -n "$1" ] && [ -r "$1" ] && tail -n "$LOG_SCAN_LINES" "$1" > "$_logwin" 2>/dev/null
}

count_in_win() { # LABEL ERE
    local n
    n="$(grep -cE "$2" "$_logwin" 2>/dev/null)"
    fact "$1: ${n:-0} line(s) in last $LOG_SCAN_LINES log lines"
}

sample_in_win() { # LABEL ERE [N] -> first N matching lines, verbatim
    local out
    out="$(grep -E "$2" "$_logwin" 2>/dev/null | head -n "${3:-3}")"
    if [ -n "$out" ]; then _emit_labeled "$1 (sample)" "$out"; else fact "$1 (sample): n/a (no matching lines)"; fi
}

# ---- report body ----------------------------------------------------------------
run_report() {
    emit_header

    # [1] capability preamble — makes downstream "command not found" self-evident
    section "Collection environment"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    fact "tools:"
    for t in ps ss netstat ip getent nslookup java systemctl crontab timeout find readlink; do
        if have "$t"; then printf '        %-12s present\n' "$t"
        else printf '        %-12s absent\n' "$t"; fi
    done
    [ -z "$_timeout_bin" ] && fact "note: timeout binary absent — network connect probes are skipped"

    # [2] host & platform — arch and Java repeatedly needed in field threads
    section "A. Host & platform"
    probe "hostname" hostname
    read_proc "os-release" /etc/os-release
    probe "kernel" uname -smr
    probe "architecture" uname -m
    probe "cpu count" nproc
    if [ -r /proc/meminfo ]; then
        fact "memory: $(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d MB total, %d MB available", t/1024, a/1024}' /proc/meminfo 2>/dev/null)"
    else
        fact "memory: n/a (path not found: /proc/meminfo)"
    fi
    if [ -f /.dockerenv ]; then fact "container: /.dockerenv present"
    elif [ -r /proc/1/cgroup ] && grep -qE 'docker|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
        fact "container: container hint in /proc/1/cgroup"
    else fact "container: no container marker found"; fi
    fact "system time: $(date '+%Y-%m-%d %H:%M:%S %Z(%z)' 2>/dev/null || echo unknown)"
    fact "system time (UTC): $(date -u '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
    read_proc "locale (LANG)" /etc/locale.conf 2>/dev/null || true
    fact "LANG env: ${LANG:-unset}"
    probe_merged "java on PATH" java -version
    if have java; then java_tls_policy "java on PATH security file" "$(command -v java)"; fi

    # [3] discovery result & host role
    section "B. Component discovery & host role"
    local i n_dbx n_dmx n_prx n_xos n_xcub n_dbxc
    n_dbx="$(_count_kind dbx)"; n_dmx="$(_count_kind dmx)"; n_prx="$(_count_kind prx)"
    n_xos="$(_count_kind xos)"; n_xcub="$(_count_kind xcub)"; n_dbxc="$(_count_kind dbxc)"
    fact "whatap component processes: dbx=$n_dbx dmx=$n_dmx prx=$n_prx xos=$n_xos xcub=$n_xcub dbxc=$n_dbxc"
    i=0
    while [ "$i" -lt "${#AG_PIDS[@]}" ]; do
        fact "process: pid=${AG_PIDS[$i]} kind=${AG_KINDS[$i]}"
        i=$((i + 1))
    done
    fact "database server processes on this host: ${#DBP_PIDS[@]}"
    i=0
    while [ "$i" -lt "${#DBP_PIDS[@]}" ]; do
        [ "$i" -ge 20 ] && { fact "(more DB processes not listed: $(( ${#DBP_PIDS[@]} - 20 )))"; break; }
        fact "db process: pid=${DBP_PIDS[$i]} engine=${DBP_KINDS[$i]} comm=$(cat "/proc/${DBP_PIDS[$i]}/comm" 2>/dev/null || echo n/a)"
        i=$((i + 1))
    done
    # role statement, derived only from what was found
    local role_agent="no" role_dbhost="no"
    [ $((n_dbx + n_dmx + n_prx + n_dbxc)) -gt 0 ] && role_agent="yes"
    { [ $((n_xos + n_xcub)) -gt 0 ] || [ "${#DBP_PIDS[@]}" -gt 0 ]; } && role_dbhost="yes"
    fact "host role by discovery: dbx-agent-side=$role_agent db-host-side=$role_dbhost"
    if [ "${#HOME_DIRS[@]}" -eq 0 ]; then
        fact "agent install dir: n/a (no whatap component process found and no --home given)"
    fi
    i=0
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        fact "install dir candidate: ${HOME_DIRS[$i]} (via ${HOME_SRCS[$i]})"
        i=$((i + 1))
    done
    fact "agent instances (dir with whatap.conf): ${#INST_DIRS[@]}"
    i=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        fact "instance: ${INST_DIRS[$i]}"
        i=$((i + 1))
    done

    # [4] per-home inventory: layout, jars (= version facts), helper scripts
    section "C. Agent home inventory & component versions"
    if [ "${#HOME_DIRS[@]}" -eq 0 ]; then
        fact "n/a (no install dir discovered)"
    fi
    i=0
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        local h="${HOME_DIRS[$i]}"
        subsection "home: $h"
        probe "top-level (depth 1)" ls -1 "$h"
        # component jar/binary file names carry version + build
        local jars
        jars="$(ls -l "$h"/whatap.agent.*.jar "$h"/whatap.agent.xos* "$h"/xos/whatap.agent.xos* 2>/dev/null)"
        if [ -n "$jars" ]; then _emit_labeled "whatap component files (name=version, with mtime)" "$jars"
        else fact "whatap component files: n/a (no whatap.agent.* under $h at depth 1)"; fi
        if [ -d "$h/jdbc" ]; then
            probe "jdbc drivers" ls -1 "$h/jdbc"
            if ls "$h/jdbc"/orai18n* >/dev/null 2>&1; then fact "orai18n jar: present in jdbc/"
            else fact "orai18n jar: not present in jdbc/"; fi
        else
            fact "jdbc drivers: n/a (path not found: $h/jdbc)"
        fi
        local f
        for f in uid.sh db.user start.sh startd.sh stop.sh prx.conf dbx.conf; do
            if [ -e "$h/$f" ]; then
                fact "$f: present ($(ls -l "$h/$f" 2>/dev/null | awk '{print $5" bytes, "$6" "$7" "$8}'))"
            else
                fact "$f: not present at $h"
            fi
        done
        local pidf
        for pidf in "$h"/*.pid "$h"/dbx "$h"/xcub-*.whatap; do
            [ -e "$pidf" ] && fact "pid file: $pidf ($(cat "$pidf" 2>/dev/null | head -n1 | cut -c1-40))"
        done
        probe "dbxc-ctl version" "$h/dbxc-ctl" version
        i=$((i + 1))
    done

    # [5] configuration — verbatim by framework policy (no masking)
    section "D. Configuration (verbatim)"
    if [ "${#INST_DIRS[@]}" -eq 0 ]; then
        fact "whatap.conf: n/a (no instance dir discovered)"
    fi
    i=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        local idir="${INST_DIRS[$i]}"
        subsection "instance: $idir"
        dump_file "whatap.conf" "$idir/whatap.conf"
        [ -f "$idir/dbx.conf" ] && dump_file "dbx.conf" "$idir/dbx.conf"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        local h="${HOME_DIRS[$i]}"
        [ -f "$h/prx.conf" ] && { subsection "oracle-pro watchdog conf: $h"; dump_file "prx.conf" "$h/prx.conf"; }
        local y
        for y in "$h"/dbxc*/config.yaml "$h"/config.yaml; do
            [ -f "$y" ] && { subsection "dbxc config: $y"; dump_file "config.yaml" "$y"; }
        done
        i=$((i + 1))
    done

    # [6] runtime processes
    section "E. Runtime processes"
    if [ "${#AG_PIDS[@]}" -eq 0 ]; then
        fact "no whatap component process found on this host"
    fi
    i=0
    while [ "$i" -lt "${#AG_PIDS[@]}" ]; do
        local pid="${AG_PIDS[$i]}" kind="${AG_KINDS[$i]}"
        subsection "$kind pid=$pid"
        probe "ps" ps -o user=,pid=,ppid=,etime=,rss=,args= -p "$pid"
        if [ -r "/proc/$pid/exe" ]; then
            local exe; exe="$(readlink "/proc/$pid/exe" 2>/dev/null)"
            fact "exe: ${exe:-n/a}"
            case "$exe" in
                *java*)
                    probe_merged "java runtime of pid $pid" "$exe" -version
                    java_tls_policy "security file of pid $pid runtime" "$exe"
                    ;;
            esac
        fi
        i=$((i + 1))
    done
    subsection "service registration & listeners"
    if have systemctl; then
        probe "systemd units matching whatap/dbx/xos" sh -c "systemctl list-units --all --no-legend 2>/dev/null | grep -iE 'whatap|dbx|xos' | head -n 10"
    else
        fact "systemd: n/a (command not found: systemctl)"
    fi
    probe "cron entries mentioning whatap" sh -c "cat /etc/crontab /etc/cron.d/* 2>/dev/null | grep -i whatap | head -n 10"
    fact "watched ports (defaults + conf whatap.server.port/xos_port): $WATCH_PORTS"
    if have ss; then
        probe "sockets on watched ports" sh -c "ss -tunap 2>/dev/null | grep -E ':($WATCH_PORTS_RE)[[:space:]]' | head -n 20"
    elif have netstat; then
        probe "sockets on watched ports" sh -c "netstat -an 2>/dev/null | grep -E '[.:]($WATCH_PORTS_RE)[[:space:]]' | head -n 20"
    else
        fact "sockets: n/a (command not found: ss/netstat)"
    fi

    # [7] agent logs — bounded window, never whole rotated logs
    section "F. Agent logs"
    local logged=0
    i=0
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        local h="${HOME_DIRS[$i]}" ldir=""
        for ldir in "$h/logs" "$h"; do
            ls "$ldir"/whatap*.log >/dev/null 2>&1 && break
            ldir=""
        done
        if [ -z "$ldir" ]; then i=$((i + 1)); continue; fi
        logged=1
        subsection "log dir: $ldir"
        probe "log files (newest 15)" sh -c "ls -lt '$ldir' 2>/dev/null | head -n 16"
        local nlog; nlog="$(newest_matching "$ldir" 'whatap*.log')"
        if [ -n "$nlog" ]; then
            fact "newest agent log: $nlog"
            fact "newest agent log mtime: $(ls -l "$nlog" 2>/dev/null | awk '{print $6" "$7" "$8}')"
            fact "last log line (verbatim): $(tail -n1 "$nlog" 2>/dev/null | cut -c1-200)"
            fact "system time at collection: $(date '+%Y-%m-%d %H:%M:%S %Z(%z)' 2>/dev/null)"
            load_logwin "$nlog"
            local wa
            wa="$(grep -oE '\(WA[0-9]{3}\)' "$_logwin" 2>/dev/null | sort | uniq -c | sort -rn | head -n 15)"
            if [ -n "$wa" ]; then _emit_labeled "WA code histogram (last $LOG_SCAN_LINES lines)" "$wa"
            else fact "WA code histogram: n/a (no WA codes in last $LOG_SCAN_LINES lines)"; fi
            count_in_win "exception lines" 'Exception|SQLException|Error:'
            sample_in_win "exception lines" 'Exception|SQLException' 3
            count_in_win "connection error lines" 'CONNECTION ERROR|openConnection error|Communications link failure'
            count_in_win "activate/inactivate transitions" 'inactivated|activated'
            subsection "verbatim tail ($LOG_TAIL_LINES lines): $nlog"
            tail -n "$LOG_TAIL_LINES" "$nlog" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
        fi
        local plog; plog="$(newest_matching "$ldir" 'prx*.log')"
        if [ -n "$plog" ]; then
            subsection "oracle-pro prx log: $plog"
            fact "prx log mtime: $(ls -l "$plog" 2>/dev/null | awk '{print $6" "$7" "$8}')"
            probe "prx rss / restart lines (last 30 matches)" sh -c "tail -n $LOG_SCAN_LINES '$plog' 2>/dev/null | grep -iE 'rss|restart|start' | tail -n 30"
        fi
        i=$((i + 1))
    done
    [ "$logged" = 0 ] && fact "agent logs: n/a (no whatap*.log under discovered homes)"

    # [8] topology & network — the agent host and DB host are often different
    section "G. Topology & network (per instance)"
    local myips
    myips="$(hostname -I 2>/dev/null || ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"
    fact "local ip addresses: ${myips:-n/a (hostname -I and ip unavailable)}"
    if [ "${#INST_DIRS[@]}" -eq 0 ]; then
        fact "n/a (no instance dir discovered)"
    fi
    i=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        local idir="${INST_DIRS[$i]}" cf="${INST_DIRS[$i]}/whatap.conf"
        subsection "instance: $idir"
        local dbms dbip dbport whost wport
        dbms="$(conf_get "$cf" dbms)"
        dbip="$(conf_get "$cf" db_ip)"
        dbport="$(conf_get "$cf" db_port)"
        whost="$(conf_get "$cf" 'whatap\.server\.host')"
        wport="$(conf_get "$cf" 'whatap\.server\.port')"
        fact "dbms: ${dbms:-n/a (key not set in whatap.conf)}"
        fact "db_ip: ${dbip:-n/a (key not set)}   db_port: ${dbport:-n/a (key not set)}"
        fact "whatap.server.host: ${whost:-n/a (key not set)}   whatap.server.port: ${wport:-not set (default 6600)}"
        # connection options, verbatim + key names split out — misspelled keys
        # are silently ignored by JDBC drivers, so the raw spelling is the fact
        local copt3 dbssl3
        copt3="$(conf_get "$cf" connect_option)"
        dbssl3="$(conf_get "$cf" db_ssl)"
        if [ -n "$copt3" ]; then
            fact "connect_option (verbatim): $copt3"
            fact "connect_option keys: $(printf '%s' "${copt3#\?}" | tr '&' '\n' | cut -d= -f1 | tr '\n' ',' | sed 's/,$//;s/,/, /g')"
        else
            fact "connect_option: not set"
        fi
        [ -n "$dbssl3" ] && fact "db_ssl: $dbssl3"
        # classify db_ip: loopback / one of this host's addresses / remote / DNS name
        if [ -n "$dbip" ]; then
            case "$dbip" in
                127.*|localhost|::1)
                    fact "db endpoint class: loopback (DB co-located with agent)" ;;
                *[a-zA-Z]*)
                    fact "db endpoint class: DNS name"
                    probe "db endpoint resolution" getent hosts "$dbip"
                    case "$dbip" in
                        *rds.amazonaws.com|*docdb.amazonaws.com|*cache.amazonaws.com|*redshift.amazonaws.com)
                            fact "db endpoint domain: AWS managed endpoint pattern ($dbip)" ;;
                        *database.azure.com|*windows.net)
                            fact "db endpoint domain: Azure managed endpoint pattern ($dbip)" ;;
                        *rds.aliyuncs.com|*ncloud.com|*ntruss.com)
                            fact "db endpoint domain: managed-cloud endpoint pattern ($dbip)" ;;
                    esac ;;
                *)
                    if [ -n "$myips" ] && printf '%s' " $myips " | grep -q " $dbip "; then
                        fact "db endpoint class: local address of this host (DB co-located with agent)"
                    else
                        fact "db endpoint class: remote address (agent host and DB host differ)"
                    fi ;;
            esac
            tcp_probe "db reachability" "$dbip" "${dbport:-}"
        fi
        if [ -n "$whost" ]; then
            local wh
            for wh in $(printf '%s' "$whost" | tr '/,' '  '); do
                tcp_probe "collection server reachability" "$wh" "${wport:-6600}"
            done
        fi
        i=$((i + 1))
    done
    fact "proxy env: http_proxy=${http_proxy:-unset} https_proxy=${https_proxy:-unset} no_proxy=${no_proxy:-unset}"

    # TLS handshake probe — opt-in: shows what the SERVER offers (TLS version,
    # cipher, certificate dates and signature algorithm), the counterpart to
    # the runtime policy in section A/E and the connect_option in section G
    if [ "$OPT_TLS" = 1 ]; then
        section "T. TLS handshake probe (opt-in)"
        if ! have openssl; then
            fact "n/a (command not found: openssl)"
        elif [ "${#INST_DIRS[@]}" -eq 0 ]; then
            fact "n/a (no instance dir discovered)"
        else
            fact "openssl: $(openssl version 2>/dev/null)"
            i=0
            while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
                local idir="${INST_DIRS[$i]}" cf="${INST_DIRS[$i]}/whatap.conf"
                local dbms dbip dbport dbssl copt st out certinfo sig
                dbms="$(conf_get "$cf" dbms)"
                dbip="$(conf_get "$cf" db_ip)"
                dbport="$(conf_get "$cf" db_port)"
                dbssl="$(conf_get "$cf" db_ssl)"
                copt="$(conf_get "$cf" connect_option)"
                subsection "instance: $idir (dbms=${dbms:-unset}, target ${dbip:-?}:${dbport:-?})"
                if [ -z "$dbip" ] || [ -z "$dbport" ]; then
                    fact "n/a (not applicable: db_ip/db_port not set)"
                    i=$((i + 1)); continue
                fi
                st=""
                case "$dbms" in
                    mysql|mariadb)  st="-starttls mysql" ;;
                    postgres*|pg)   st="-starttls postgres" ;;
                    redis|valkey)
                        case "$dbssl$copt" in
                            *true*|*ssl*) st="" ;;
                            *) fact "n/a (not applicable: db_ssl/ssl option not set — plain protocol)"
                               i=$((i + 1)); continue ;;
                        esac ;;
                    mssql)  fact "n/a (not applicable: TLS runs inside the TDS prelogin — not probeable with openssl s_client)"
                            i=$((i + 1)); continue ;;
                    oracle) fact "n/a (not applicable: TCPS/native negotiation not probed in this version)"
                            i=$((i + 1)); continue ;;
                    *)      fact "n/a (not applicable: dbms=${dbms:-unset})"
                            i=$((i + 1)); continue ;;
                esac
                warn "sending 1 TLS handshake to $dbip:$dbport ($dbms)"
                if [ -n "$_timeout_bin" ]; then
                    out="$(printf '' | "$_timeout_bin" 15 openssl s_client $st -connect "$dbip:$dbport" 2>&1)"
                else
                    fact "handshake: n/a (not applicable: timeout binary absent, probe skipped)"
                    i=$((i + 1)); continue
                fi
                _emit_labeled "handshake summary" "$(printf '%s\n' "$out" \
                    | grep -aE '^New, |Protocol *:|Cipher *(is|:)|Server public key|Verification|Verify return code|verify error|error|alert ' \
                    | head -n 10)"
                certinfo="$(printf '%s\n' "$out" | openssl x509 -noout -subject -issuer -dates 2>/dev/null)"
                if [ -n "$certinfo" ]; then
                    _emit_labeled "server certificate" "$certinfo"
                    sig="$(printf '%s\n' "$out" | openssl x509 -noout -text 2>/dev/null | grep -m1 'Signature Algorithm' | sed 's/^ *//')"
                    [ -n "$sig" ] && fact "certificate signature: $sig"
                else
                    fact "server certificate: n/a (no certificate in handshake output)"
                fi
                i=$((i + 1))
            done
        fi
    fi

    # [9] engine-specific facts, driven by dbms= of each instance
    section "H. Engine-specific facts (per instance)"
    if [ "${#INST_DIRS[@]}" -eq 0 ]; then
        fact "n/a (no instance dir discovered)"
    fi
    i=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        local idir="${INST_DIRS[$i]}" cf="${INST_DIRS[$i]}/whatap.conf"
        local dbms nlog2 ldir2=""
        dbms="$(conf_get "$cf" dbms)"
        subsection "instance: $idir (dbms=${dbms:-unset})"
        # engine-relevant conf keys, verbatim lines (value + spelling as-is)
        probe "engine-relevant conf lines" sh -c "grep -E '^[[:space:]]*(statements|statements_min_row|min_row|slow_query_log|connect_option|db_ssl|metalock|deadlock_interval|conn_fail_count|replication_name|skip_user|skip_whatap_session|cloud_watch|cloud_watch_metrics|cloud_watch_instance|aws_arn|aws_access_key|aws_secret_key|redis_autoscale|mslog|oname|whatap\.name|db=|db_user|plan_db|xos=|xos_port)' '$cf' 2>/dev/null"
        # locate this instance's log window (instance logs/ first, then home)
        for ldir2 in "$idir/logs" "$idir" "$(dirname "$idir")/logs"; do
            ls "$ldir2"/whatap*.log >/dev/null 2>&1 && break
            ldir2=""
        done
        nlog2=""
        [ -n "$ldir2" ] && nlog2="$(newest_matching "$ldir2" 'whatap*.log')"
        if [ -n "$nlog2" ]; then load_logwin "$nlog2"; else : > "$_logwin" 2>/dev/null; fi
        case "$dbms" in
            postgres*|pg)
                count_in_win "PgStatements.process lines" 'PgStatements\.process'
                count_in_win "PgObject.process lines" 'PgObject\.process'
                count_in_win "timeout lines" '[Tt]imeout'
                count_in_win "pg_stat_statements missing-relation lines" 'pg_stat_statements.*does not exist'
                count_in_win "authentication-type lines" 'authentication type .* not supported'
                ;;
            mysql|mariadb)
                count_in_win "WA310 lines" 'WA310'
                count_in_win "denied/permission lines" 'command denied|Access denied'
                count_in_win "sys.innodb_lock_waits lines" 'innodb_lock_waits'
                count_in_win "replication warning lines" 'Replication may have been broken|replication'
                ;;
            oracle)
                local oh
                oh="$(grep -oE 'ORA-[0-9]+' "$_logwin" 2>/dev/null | sort | uniq -c | sort -rn | head -n 10)"
                if [ -n "$oh" ]; then _emit_labeled "ORA code histogram (last $LOG_SCAN_LINES lines)" "$oh"
                else fact "ORA code histogram: n/a (no ORA codes in window)"; fi
                count_in_win "timeout lines" '[Tt]ime[d]? out|ORA-01013'
                ;;
            mssql)
                count_in_win "TLS/SSL negotiation lines" 'TLS|SSL|encrypt'
                count_in_win "login/permission lines" 'Login failed|permission'
                ;;
            tibero)
                local th
                th="$(grep -oE 'JDBC-[0-9]+' "$_logwin" 2>/dev/null | sort | uniq -c | sort -rn | head -n 10)"
                if [ -n "$th" ]; then _emit_labeled "JDBC code histogram (last $LOG_SCAN_LINES lines)" "$th"
                else fact "JDBC code histogram: n/a (no JDBC codes in window)"; fi
                count_in_win "read-timeout / connection-closed lines" 'Read time.?out|Connection closed'
                ;;
            redis|valkey)
                count_in_win "jedis/pool error lines" 'Jedis|resource from the pool|SocketTimeout'
                ;;
            mongo*)
                count_in_win "mongo timeout/format lines" 'MongoTimeout|numberFormatException'
                ;;
            cubrid)
                fact "engine-specific facts: not covered (cubrid) — common sections above still apply"
                ;;
            "")
                fact "engine-specific facts: n/a (dbms key not set in whatap.conf)"
                ;;
            *)
                fact "engine-specific facts: not covered for dbms=$dbms — common sections above still apply"
                ;;
        esac
        # cloud overlay: CloudWatch / IAM traces regardless of engine
        local cw
        cw="$(conf_get "$cf" cloud_watch)"
        if [ -n "$cw" ] || [ -n "$(conf_get "$cf" aws_arn)" ]; then
            count_in_win "AWS credential/role lines" 'AssumeRole|sts|security token|expired'
            sample_in_win "AWS credential/role lines" 'AssumeRole|sts|security token.*expired' 3
        fi
        i=$((i + 1))
    done
    # oracle-pro watchdog pair (dmx/prx) — process-level, not per instance
    if [ "$(_count_kind dmx)" -gt 0 ] || [ "$(_count_kind prx)" -gt 0 ]; then
        subsection "oracle-pro dmx/prx pair"
        i=0
        while [ "$i" -lt "${#AG_PIDS[@]}" ]; do
            case "${AG_KINDS[$i]}" in
                dmx|prx) probe "${AG_KINDS[$i]} rss/etime" ps -o pid=,rss=,etime=,args= -p "${AG_PIDS[$i]}" ;;
            esac
            i=$((i + 1))
        done
        i=0
        while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
            [ -f "${HOME_DIRS[$i]}/prx.conf" ] && fact "prx.conf rss_limit: $(conf_get "${HOME_DIRS[$i]}/prx.conf" rss_limit)"
            i=$((i + 1))
        done
    fi

    # [10] XOS / DB-host side — present only when this host runs the DB or XOS
    section "J. XOS / DB-host side facts"
    local xosseen=0
    if [ "$(_count_kind xos)" -gt 0 ] || [ "$(_count_kind xcub)" -gt 0 ] || [ "${#XOS_CONFS[@]}" -gt 0 ] || [ "${#DBP_PIDS[@]}" -gt 0 ]; then
        xosseen=1
    fi
    if [ "$xosseen" = 0 ]; then
        fact "n/a (not applicable: no xos/xcub process, xos.conf, or DB server process on this host)"
    else
        i=0
        while [ "$i" -lt "${#XOS_CONFS[@]}" ]; do
            local xc="${XOS_CONFS[$i]}"
            subsection "xos.conf: $xc"
            dump_file "xos.conf" "$xc"
            local sq
            sq="$(conf_get "$xc" slow_query)"
            if [ -n "$sq" ]; then
                fact "slow_query target: $sq"
                if [ -r "$sq" ]; then
                    fact "slow_query target file: readable ($(ls -l "$sq" 2>/dev/null | awk '{print $5" bytes, mtime "$6" "$7" "$8}'))"
                    probe "slow_query target last 3 lines (verbatim)" tail -n 3 "$sq"
                    fact "lines with SQLSTATE prefix '00000:' in last 200: $(tail -n 200 "$sq" 2>/dev/null | grep -c '00000:' 2>/dev/null)"
                    fact "lines containing non-ASCII bytes in last 200: $(tail -n 200 "$sq" 2>/dev/null | grep -c '[^ -~]' 2>/dev/null)"
                elif [ -e "$sq" ]; then
                    fact "slow_query target file: n/a (permission denied: $sq)"
                else
                    fact "slow_query target file: n/a (path not found: $sq)"
                fi
            else
                fact "slow_query key: not set in $xc"
            fi
            i=$((i + 1))
        done
        # udp xos->dbx channel (xos_port, default 3002) — a known port-collision spot
        if have ss; then
            probe "udp sockets on watched ports" sh -c "ss -ulnap 2>/dev/null | grep -E ':($WATCH_PORTS_RE)' | head -n 5"
        fi
        # DB server processes: version / datadir / config paths, from the processes themselves
        i=0
        while [ "$i" -lt "${#DBP_PIDS[@]}" ]; do
            [ "$i" -ge 5 ] && { fact "(more DB processes not detailed: $(( ${#DBP_PIDS[@]} - 5 )))"; break; }
            local dpid="${DBP_PIDS[$i]}" dkind="${DBP_KINDS[$i]}" dexe
            subsection "db server process: $dkind pid=$dpid"
            probe "ps" ps -o user=,pid=,etime=,args= -p "$dpid"
            dexe="$(readlink "/proc/$dpid/exe" 2>/dev/null)"
            fact "exe: ${dexe:-n/a (readlink /proc/$dpid/exe unavailable)}"
            case "$dkind" in
                postgresql)     [ -n "$dexe" ] && probe_merged "server version" "$dexe" --version ;;
                mysql/mariadb)  [ -n "$dexe" ] && probe_merged "server version" "$dexe" --version ;;
                mongodb)        [ -n "$dexe" ] && probe_merged "server version" "$dexe" --version ;;
                redis/valkey)   [ -n "$dexe" ] && probe_merged "server version" "$dexe" --version ;;
                *)              fact "server version: n/a (not probed for $dkind — see sql pack)" ;;
            esac
            i=$((i + 1))
        done
    fi

    # [11] what to run next — completes CONTRACT rule 3 for DB-side facts
    section "I. Companion steps for DB-side facts"
    fact "the sections above cover host-side facts only; DB-internal facts (grants,"
    fact "parameters, monitoring views) come from the SQL pack. Two ways to run it:"
    fact "(1) preferred — rerun with --sql: uses the agent's own java + jdbc/ driver,"
    fact "    no DB client needed (asks for the monitoring account on the terminal)"
    fact "(2) through a DB client where one exists (psql / mysql / sqlplus / sqlcmd)"
    i=0
    local said=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        local dbms
        dbms="$(conf_get "${INST_DIRS[$i]}/whatap.conf" dbms)"
        case "$dbms" in
            postgres*|pg)   fact "instance ${INST_DIRS[$i]}: sql/postgresql.sql"; said=1 ;;
            mysql|mariadb)  fact "instance ${INST_DIRS[$i]}: sql/mysql.sql"; said=1 ;;
            oracle)         fact "instance ${INST_DIRS[$i]}: sql/oracle.sql"; said=1 ;;
            mssql)          fact "instance ${INST_DIRS[$i]}: windows/mssql.sql (sqlcmd only in this version)"; said=1 ;;
            "")             ;;
            *)              fact "instance ${INST_DIRS[$i]}: no SQL pack for dbms=$dbms in this version"; said=1 ;;
        esac
        i=$((i + 1))
    done
    [ "$said" = 0 ] && fact "no instance with a dbms= key was discovered on this host"
    if [ "${#AG_PIDS[@]}" -gt 0 ] && [ "$(_count_kind xos)" -eq 0 ] && [ "${#DBP_PIDS[@]}" -eq 0 ]; then
        fact "split topology note: if the DB host is a reachable on-prem server,"
        fact "run this same script there as well (XOS / DB server facts live there)"
    fi
    if [ "${#AG_PIDS[@]}" -eq 0 ] && [ "${#DBP_PIDS[@]}" -gt 0 ]; then
        fact "split topology note: the DBX agent host is elsewhere — run this same"
        fact "script on the agent host as well"
    fi

    # [12] Tier 2, opt-in: SQL pack over JDBC — the agent-native path
    if [ "$OPT_SQL" = 1 ]; then
        section "K. SQL pack over JDBC (opt-in)"
        if [ "${#INST_DIRS[@]}" -eq 0 ]; then
            fact "n/a (no instance dir discovered)"
        elif ! _pick_java_bindir; then
            fact "n/a (no usable jshell/jrunscript found — JDK 9+ has jshell, JDK 8 has Nashorn jrunscript)"
        else
            fact "runner: $_JDBC_MODE from $_JBIN"
            i=0
            while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
                local idir="${INST_DIRS[$i]}" cf="${INST_DIRS[$i]}/whatap.conf"
                local dbms dbip dbport dbname copt pack jar url alturl out
                # everything the agent itself uses to connect is reused from
                # whatap.conf (rule 2) — only credentials cannot come from it
                # (stored encrypted by uid.sh; this script does not decrypt)
                dbms="$(conf_get "$cf" dbms)"
                dbip="$(conf_get "$cf" db_ip)"
                dbport="$(conf_get "$cf" db_port)"
                dbname="$(conf_get "$cf" 'db')"
                [ -z "$dbname" ] && dbname="$(conf_get "$cf" plan_db)"
                copt="$(conf_get "$cf" connect_option)"
                case "$copt" in ""|\?*) ;; *) copt="?$copt" ;; esac
                subsection "instance: $idir (dbms=${dbms:-unset})"
                pack=""; jar=""; url=""; alturl=""
                case "$dbms" in
                    postgres*|pg)
                        pack="$SCRIPT_DIR/sql/postgresql.sql"
                        jar="$(_find_jdbc_jar 'postgresql*.jar')"
                        url="jdbc:postgresql://$dbip:$dbport/${dbname:-postgres}$copt" ;;
                    mysql|mariadb)
                        pack="$SCRIPT_DIR/sql/mysql.sql"
                        jar="$(_find_jdbc_jar 'mysql-connector*.jar' 'mariadb*.jar')"
                        url="jdbc:mysql://$dbip:$dbport/${dbname}$copt"
                        case "$jar" in *mariadb*) url="jdbc:mariadb://$dbip:$dbport/${dbname}$copt" ;; esac ;;
                    oracle)
                        pack="$SCRIPT_DIR/sql/oracle.sql"
                        jar="$(_find_jdbc_jar 'ojdbc*.jar')"
                        url="jdbc:oracle:thin:@//$dbip:$dbport/$dbname"
                        alturl="jdbc:oracle:thin:@$dbip:$dbport:$dbname" ;;
                    *)
                        fact "n/a (not applicable: no JDBC pack for dbms=${dbms:-unset} in this version)"
                        i=$((i + 1)); continue ;;
                esac
                if [ ! -f "$pack" ]; then
                    fact "n/a (path not found: $pack — keep the sql/ dir next to this script)"
                    i=$((i + 1)); continue
                fi
                if [ -z "$jar" ]; then
                    fact "n/a (no matching driver jar under any discovered jdbc/ dir)"
                    i=$((i + 1)); continue
                fi
                fact "driver jar: $jar"
                fact "jdbc url: $url"
                if ! _get_creds "$idir"; then i=$((i + 1)); continue; fi
                warn "sending read-only SQL pack $(basename "$pack") to $dbip:$dbport as $CRED_USER over JDBC"
                out="$(_run_jdbc_pack "$pack" "$url" "$jar")"
                if [ -n "$alturl" ] && printf '%s' "$out" | grep -q '^CONNECT-ERROR'; then
                    fact "first URL form did not connect; retrying SID form"
                    fact "jdbc url (retry): $alturl"
                    warn "retrying with SID-form URL $alturl"
                    out="$out
--- retry with $alturl ---
$(_run_jdbc_pack "$pack" "$alturl" "$jar")"
                fi
                if [ -n "$out" ]; then
                    fact "pack output (verbatim):"
                    printf '%s\n' "$out" | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
                else
                    fact "pack output: n/a (empty output)"
                fi
                CRED_PW=""
                i=$((i + 1))
            done
        fi
    fi

    emit_footer
}

# ---- main -----------------------------------------------------------------------
exec 3>&2

[ "$ARGC" -eq 0 ] && { usage; exit 0; }

if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
fi

_init_probe
progress "discovering whatap DB components / DB server processes ..."
discover
progress "components: dbx=$(_count_kind dbx) dmx=$(_count_kind dmx) prx=$(_count_kind prx) xos=$(_count_kind xos) xcub=$(_count_kind xcub) dbxc=$(_count_kind dbxc); homes=${#HOME_DIRS[@]}; instances=${#INST_DIRS[@]}; db-procs=${#DBP_PIDS[@]}"

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
