#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — NMS Control Manager collector (seeded v0)
# -----------------------------------------------------------------------------
# Gathers the environment facts that NMS support cases ask for over and over
# (fact list derived from the #nms-support channel history 2025-04 ~ 2026-07;
# see cases/2026-07-03-nms-support-channel-analysis/analysis.md in the analysis
# workspace for the question -> section traceability), cross-checked against
# the official docs:
#   https://docs.whatap.io/nms/supported-spec   (OS/python matrix, ports)
#   https://docs.whatap.io/nms/install-agent    (repo setup, wtinitset, units)
#
# Runs on the host where the WhaTap NMS Control Manager (whatap-nms package,
# rpm on RHEL-family / deb on Debian-family) is — or was supposed to be —
# installed.
#
# THE CONTRACT (../../CONTRACT.md):
#   1. Facts only. No diagnosis, no likely-cause, no recommendation, no fix.
#   2. Discover, never assume. The install root comes from rpm -ql, services
#      from systemd state, ports from ss/netstat/proc — never hardcoded guesses.
#      A value we cannot obtain is a fact with a reason (n/a (...)).
#   3. One field command -> paste. `./collect-nms.sh --file`, send the .txt.
#   4. Domain-team owned. Seeded v0 by the Global team (framework owner);
#      ongoing ownership belongs to the NMS development team.
#
# DESIGN (../../docs/collector-engineering.md):
#   * MECE sections [1]..[10] — every fact lives in exactly one place.
#   * Load-safe: Tier 0 default is read-only and near-instant. Log reads are
#     tail-bounded; no recursive du/find; the two outbound reachability probes
#     are single HEAD requests capped at 5s each (closed-network detection is
#     itself a recurring support question). The SNMP probe is Tier 2, opt-in,
#     single GET requests only — never a walk.
#   * Portable: bash 3.2+, /proc first, command chains with fallbacks,
#     no set -e / set -u.
#   * Reasoned absence: probe/read_proc/dump helpers classify every miss.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata ------------------------------------------------------
COLLECTOR_NAME="whatap-nms"
VERSION="0.3.0"
DOMAIN="nms"
TARGET="host/$(hostname 2>/dev/null || echo unknown)"

# ---- CLI harness -------------------------------------------------------------
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr
OPT_SNMP=0        # Tier 2: timed SNMP GET probe against one device
SNMP_HOST=""
SNMP_COMM=""
SNMP_PORT="161"

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Target: the WhaTap NMS Control Manager host (whatap-nms rpm).
Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")            print this help (no collection)
  $(basename "$0") --file     write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout   print the facts report to stdout
  $(basename "$0") --quiet    silence progress on stderr (add to --file / --stdout)

  Tier 2 (opt-in, sends 3 SNMP GET requests to the target device — announced
  on stderr before running; single GETs only, never a walk):
  $(basename "$0") --file --snmp <device-ip> <community> [port]
      SNMPv2c GET of sysDescr.0 / sysUpTime.0 / ifNumber.0 with per-request
      elapsed time (the manager polls with a first-response timeout, so the
      elapsed time next to a present/absent answer is a load-bearing fact).
EOF
}

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --file)    OPT_FILE=1 ;;
        --stdout)  OPT_STDOUT=1 ;;
        --quiet)   OPT_QUIET=1 ;;
        --snmp)
            OPT_SNMP=1
            if [ $# -lt 3 ]; then
                printf -- '--snmp needs: --snmp <device-ip> <community> [port]\n' >&2; exit 2
            fi
            SNMP_HOST="$2"; SNMP_COMM="$3"; shift 2
            case "${2:-}" in
                [0-9]*) SNMP_PORT="$2"; shift ;;
            esac
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---- emit helpers ------------------------------------------------------------
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

subsection() { printf '\n    -- %s --\n' "$1"; }

fact() { printf '    %s\n' "$1"; }

emit_footer() {
    printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'
}

progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }
warn() { printf '%s\n' "$*" >&2; }

# ---- reasoned-absence helpers --------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_timeout_bin=""
CMD_TIMEOUT=20
_init_probe() {
    _errfile="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.ggt.$$.err")"
    have timeout && _timeout_bin="$(command -v timeout)"
}
_end_probe() { [ -n "$_errfile" ] && rm -f "$_errfile" 2>/dev/null; }

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

# probe "label" CMD [ARGS...] -> output as facts, or "label: n/a (<why>)".
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

# probe_merged: like probe but folds stderr into stdout (python --version etc.).
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

# read_proc "label" PATH -> content of a /proc or /sys file, or a reason.
read_proc() {
    local label="$1" path="$2" out
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    out="$(cat "$path" 2>/dev/null)"
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# tail_file PATH N -> last N lines of a file (bounded read), or a reason.
tail_file() {
    local path="$1" n="${2:-60}"
    [ -e "$path" ] || { fact "n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "(empty file)"; return; }
    tail -n "$n" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# dump_file PATH [CAP] -> a file's content verbatim (line-capped), or a reason.
# Framework policy (docs/authoring-guide.md step 3): configuration is dumped
# verbatim, never masked — a value has to be readable to be verified or refuted
# against the other side (e.g. a community string compared with the device),
# and genuinely sensitive WhaTap material is stored encrypted anyway.
dump_file() {
    local path="$1" cap="${2:-400}"
    [ -e "$path" ] || { fact "n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "(empty file)"; return; }
    head -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do
        printf '        %s\n' "$_l"
    done
}

# file_meta PATH -> "bytes / mtime" one-liner for a file.
file_meta() {
    local path="$1"
    printf '%s bytes, mtime %s' \
        "$(wc -c < "$path" 2>/dev/null | tr -d ' ')" \
        "$(date -u -r "$path" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a)"
}

# now_s -> seconds (sub-second when the platform provides it) for elapsed-time
# measurement. %N is not universal; detect once and fall back to whole seconds.
_now_ns_ok=""
now_s() {
    if [ -z "$_now_ns_ok" ]; then
        case "$(date +%N 2>/dev/null)" in
            [0-9]*) _now_ns_ok=yes ;;
            *)      _now_ns_ok=no ;;
        esac
    fi
    if [ "$_now_ns_ok" = yes ]; then date +%s.%N; else date +%s; fi
}

elapsed_s() {  # elapsed_s START END -> "X.XXX" (awk does the float math)
    awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b-a}'
}

# systemd helper — avoid `--value` (unsupported on systemd < 230)
sd_show() { have systemctl && systemctl show -p "$1" "$2.service" 2>/dev/null | cut -d= -f2-; }

# ---- discovery ----------------------------------------------------------------
# Install root: resolved from the package manifest first (Contract rule 2) —
# rpm on RHEL-family, dpkg on Debian-family (both are official install paths,
# docs.whatap.io/nms/install-agent). The path seen in field sessions
# (/usr/share/whatap-nms) is only a fallback that is used when it exists on disk.
NMS_ROOT=""
NMS_PKG="whatap-nms"
discover_root() {
    # match a path whose component is the whatap-nms directory itself, and skip
    # documentation paths (/usr/share/doc/whatap-nms sorts before the real root
    # in the dpkg manifest — caught in live validation on Ubuntu 24.04)
    local p="" _mgrep='/whatap-nms\(/\|$\)'
    if have rpm; then
        p="$(rpm -ql "$NMS_PKG" 2>/dev/null | grep -v '/doc/' | grep -m1 "$_mgrep")"
    fi
    if [ -z "$p" ] && have dpkg; then
        p="$(dpkg -L "$NMS_PKG" 2>/dev/null | grep -v '/doc/' | grep -m1 "$_mgrep")"
    fi
    if [ -n "$p" ]; then
        # trim to the .../whatap-nms directory component
        NMS_ROOT="$(printf '%s\n' "$p" | sed 's#\(/whatap-nms\)/.*#\1#')"
        [ -d "$NMS_ROOT" ] || NMS_ROOT=""
    fi
    [ -z "$NMS_ROOT" ] && [ -d /usr/share/whatap-nms ] && NMS_ROOT=/usr/share/whatap-nms
}

NMS_UNITS="uvicorn nmscore icmptcphealthd icmphealthd"

# ---- report body ---------------------------------------------------------------
run_report() {
    emit_header

    # [1] capability preamble — pre-explains every downstream "command not found"
    section "Collection environment"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    fact "tools:"
    for t in systemctl journalctl ss netstat ip rpm dnf yum dpkg apt-cache apt-mark \
             wtinitset python3 pip3 snmpget snmpwalk timeout curl wget getenforce \
             timedatectl chronyc ntpstat; do
        if have "$t"; then printf '        %-14s present\n' "$t"
        else printf '        %-14s absent\n' "$t"; fi
    done
    discover_root
    if [ -n "$NMS_ROOT" ]; then fact "nms install root (resolved): $NMS_ROOT"
    else fact "nms install root: n/a (rpm manifest gave no path and /usr/share/whatap-nms not present)"; fi

    # [2] host & platform — asked as "OS 종류와" in field sessions (2026-01-20)
    section "A. Host & platform"
    probe "hostname" hostname
    read_proc "os-release" /etc/os-release
    probe "kernel" uname -smr
    probe "cpu count" nproc
    if [ -r /proc/meminfo ]; then
        fact "memory: $(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d MB total, %d MB available", t/1024, a/1024}' /proc/meminfo 2>/dev/null)"
    else
        fact "memory: n/a (path not found: /proc/meminfo)"
    fi
    probe "virtualization" systemd-detect-virt
    probe "selinux" getenforce

    # [3] time & clock — the backend rejects packs as "future data" when the
    # manager host clock drifts (observed delta ~3157s, 2026-06-18)
    section "B. Time & clock synchronization"
    fact "host clock (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    probe "timedatectl" timedatectl
    probe "chrony tracking" chronyc tracking
    probe "ntpstat" ntpstat

    # [4] python runtime — "python버전 알려주세요" (2026-01-20); the rpm %post
    # builds a venv with the system python and needs >= 3.9 (2026-07-02)
    section "C. Python runtime"
    probe_merged "python3 --version" python3 --version
    if have python3; then
        fact "python3 resolves to: $(readlink -f "$(command -v python3)" 2>/dev/null || command -v python3)"
    fi
    fact "python3* binaries on PATH dirs (/usr/bin, /usr/local/bin):"
    ls -1 /usr/bin/python3* /usr/local/bin/python3* 2>/dev/null | while IFS= read -r _p; do
        printf '        %s\n' "$_p"
    done
    [ -z "$(ls -1 /usr/bin/python3* /usr/local/bin/python3* 2>/dev/null)" ] && fact "    (none found)"
    probe_merged "pip3 --version" pip3 --version

    # [5] package & repository — exclude= lines and a repo missing the package
    # are both field-observed causes of "whatap-nms not found" (2026-06-04 / 07-02).
    # Both official install paths are covered: rpm/dnf (RHEL family) and
    # dpkg/apt (Debian family) — docs.whatap.io/nms/install-agent.
    section "D. Package & repository"
    if have rpm; then
        probe "rpm -qi $NMS_PKG" rpm -qi "$NMS_PKG"
    elif have dpkg; then
        probe "dpkg -s $NMS_PKG" dpkg -s "$NMS_PKG"
    else
        fact "installed package: n/a (command not found: rpm, dpkg)"
    fi
    subsection "whatap repo definitions"
    local _found_repo=0 _rf
    for _rf in /etc/yum.repos.d/*.repo; do
        [ -e "$_rf" ] || continue
        if grep -qi whatap "$_rf" 2>/dev/null; then
            _found_repo=1
            fact "$_rf ($(file_meta "$_rf")):"
            tail_file "$_rf" 40
        fi
    done
    for _rf in /etc/apt/sources.list.d/*.list /etc/apt/sources.list; do
        [ -e "$_rf" ] || continue
        if grep -qi whatap "$_rf" 2>/dev/null; then
            _found_repo=1
            fact "$_rf ($(file_meta "$_rf")):"
            tail_file "$_rf" 40
        fi
    done
    [ "$_found_repo" = 0 ] && fact "no yum/apt repo definition mentions whatap (/etc/yum.repos.d, /etc/apt/sources.list*)"
    subsection "repo signing key on disk"
    if [ -e /etc/apt/trusted.gpg.d/whatap-release.gpg ]; then
        fact "/etc/apt/trusted.gpg.d/whatap-release.gpg: present ($(file_meta /etc/apt/trusted.gpg.d/whatap-release.gpg))"
    elif have rpm; then
        probe "rpm gpg-pubkey packages" sh -c 'rpm -q gpg-pubkey --qf "%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n" 2>/dev/null | grep -i whatap; :'
    else
        fact "n/a (no apt key file at /etc/apt/trusted.gpg.d/whatap-release.gpg and command not found: rpm)"
    fi
    subsection "package-manager exclude / hold directives"
    probe "exclude lines (/etc/dnf/dnf.conf, /etc/yum.conf)" sh -c 'grep -Hn "^[[:space:]]*exclude" /etc/dnf/dnf.conf /etc/yum.conf 2>/dev/null; :'
    if have apt-mark; then
        probe "apt-mark showhold" sh -c 'apt-mark showhold 2>/dev/null; :'
    fi
    subsection "whatap packages visible to the package manager"
    if have dnf; then
        probe "dnf list available (whatap repos only)" dnf -q --disablerepo="*" --enablerepo="whatap*" list available --showduplicates
        probe "dnf list installed whatap*" dnf -q list installed "whatap*"
    elif have yum; then
        probe "yum list available (whatap repos only)" yum -q --disablerepo="*" --enablerepo="whatap*" list available
        probe "yum list installed whatap*" yum -q list installed "whatap*"
    elif have apt-cache; then
        probe "apt-cache policy $NMS_PKG" apt-cache policy "$NMS_PKG"
    else
        fact "n/a (command not found: dnf, yum, apt-cache)"
    fi
    # install/upgrade attempts and their outcomes stay on record even after a
    # failed or purged install — the package-manager logs are the durable trace
    # of a broken post-install step (bounded greps, current + one rotation)
    subsection "package install/upgrade history ($NMS_PKG)"
    if have dnf; then
        probe "dnf history" dnf -q history list "$NMS_PKG"
    fi
    probe "dpkg.log entries (last 20)" sh -c 'grep -h "whatap-nms" /var/log/dpkg.log /var/log/dpkg.log.1 2>/dev/null | tail -n 20; :'
    probe "apt history entries (last 30 lines)" sh -c 'grep -h -B2 -A4 "whatap-nms" /var/log/apt/history.log 2>/dev/null | tail -n 30; :'

    # [6] deployment layout — venv/wheelhouse state is where rpm %post pip
    # installs break (bcrypt case, 2025-05-30)
    section "E. Deployment layout (on-disk)"
    if [ -n "$NMS_ROOT" ]; then
        fact "root: $NMS_ROOT"
        subsection "top-level entries (shallow listing only)"
        probe "ls" ls -la "$NMS_ROOT"
        subsection "bundled virtualenv"
        if [ -x "$NMS_ROOT/vpyenv/bin/python3" ]; then
            probe_merged "vpyenv python" "$NMS_ROOT/vpyenv/bin/python3" --version
            probe_merged "vpyenv pip" "$NMS_ROOT/vpyenv/bin/python3" -m pip --version
        else
            fact "vpyenv/bin/python3: n/a (path not found: $NMS_ROOT/vpyenv/bin/python3)"
        fi
        if [ -d "$NMS_ROOT/whlhouse" ]; then
            fact "whlhouse wheel count: $(ls -1 "$NMS_ROOT"/whlhouse/*.whl 2>/dev/null | wc -l | tr -d ' ')"
        else
            fact "whlhouse: n/a (path not found: $NMS_ROOT/whlhouse)"
        fi
        subsection "requirements files"
        local _req _any_req=0
        for _req in "$NMS_ROOT"/requirements*; do
            [ -e "$_req" ] || continue
            _any_req=1
            fact "$_req: $(wc -l < "$_req" 2>/dev/null | tr -d ' ') lines, $(file_meta "$_req")"
        done
        [ "$_any_req" = 0 ] && fact "no requirements* file directly under $NMS_ROOT"
        subsection "filesystem free space at root"
        probe "df" df -h "$NMS_ROOT"
    else
        fact "n/a (install root not resolved — see section [1])"
    fi

    # [7] runtime services & processes — the three units and their start order
    # (uvicorn -> nmscore -> icmptcphealthd) are the standard field checklist
    # (2026-01-09); icmphealthd is the pre-rename unit (<= v0.42.x era)
    section "F. Runtime services & processes"
    if have systemctl; then
        local _u _ls
        for _u in $NMS_UNITS; do
            _ls="$(sd_show LoadState "$_u")"
            if [ "$_ls" = "loaded" ]; then
                fact "$_u.service: active=$(systemctl is-active "$_u.service" 2>/dev/null) enabled=$(systemctl is-enabled "$_u.service" 2>/dev/null) restarts=$(sd_show NRestarts "$_u")"
                fact "    since: $(sd_show ActiveEnterTimestamp "$_u")"
                fact "    unit file: $(sd_show FragmentPath "$_u")"
                fact "    ExecStart: $(sd_show ExecStart "$_u" | cut -c1-200)"
            else
                fact "$_u.service: n/a (LoadState=${_ls:-unknown} — unit not installed on this host)"
            fi
        done
    else
        fact "systemd: n/a (command not found: systemctl)"
    fi
    subsection "nms-related processes"
    if have ps; then
        # grep -v collect-nms: this collector's own command line contains
        # "whatap-nms" (script path / report name) — self-matches are excluded
        probe "ps (wtnms / icmptcphealthd / whatap-nms)" sh -c "ps -eo pid,ppid,rss,etime,args | grep -E 'wtnms|icmptcphealthd|whatap-nms' | grep -vE 'grep|collect-nms'; :"
    else
        local _pid _cl _hit=0
        for _pid in /proc/[0-9]*; do
            _cl="$(tr '\0' ' ' < "$_pid/cmdline" 2>/dev/null)"
            case "$_cl" in
                *wtnms*|*icmptcphealthd*|*whatap-nms*)
                    _hit=1; fact "pid ${_pid#/proc/}: $(printf '%s' "$_cl" | cut -c1-200)" ;;
            esac
        done
        [ "$_hit" = 0 ] && fact "no matching process found in /proc scan"
    fi

    # [8] network endpoints — UDP 514 (syslog) is shared territory: a co-located
    # WhaTap collection server binds it first and the manager then cannot
    # (2025-07-15); 162/udp is trap intake, 5000/tcp the manager UI
    section "G. Network endpoints"
    subsection "listening TCP sockets"
    if have ss; then probe "ss -ltnp" sh -c "ss -ltnp 2>/dev/null | head -n 40"
    elif have netstat; then probe "netstat -ltnp" sh -c "netstat -ltnp 2>/dev/null | head -n 40"
    else read_proc "/proc/net/tcp (raw, LISTEN rows are state 0A)" /proc/net/tcp; fi
    subsection "listening UDP sockets"
    if have ss; then probe "ss -lunp" sh -c "ss -lunp 2>/dev/null | head -n 40"
    elif have netstat; then probe "netstat -lunp" sh -c "netstat -lunp 2>/dev/null | head -n 40"
    else read_proc "/proc/net/udp (raw)" /proc/net/udp; fi
    subsection "ports of record (channel cases + docs: 161/162/514/1514/5000/5141/6600/8443)"
    if have ss; then
        probe "matching sockets" sh -c "ss -ltnup 2>/dev/null | awk '/:(161|162|514|1514|5000|5141|6600|8443)([[:space:]]|\$)/'; :"
    elif have netstat; then
        probe "matching sockets" sh -c "netstat -ltnup 2>/dev/null | awk '/:(161|162|514|1514|5000|5141|6600|8443)([[:space:]]|\$)/'; :"
    else
        fact "n/a (command not found: ss, netstat)"
    fi
    subsection "outbound connections of nms processes (manager -> WhaTap server)"
    if have ss; then
        probe "established (wtnms*)" sh -c "ss -tnp state established 2>/dev/null | grep -E 'wtnms|icmptcphealthd|uvicorn' | head -n 20; :"
        probe "established to :6600 (collection-server data port per docs)" sh -c "ss -tn state established 2>/dev/null | awk '\$4 ~ /:6600\$/ || \$5 ~ /:6600\$/' | head -n 10; :"
    else
        fact "n/a (command not found: ss)"
    fi
    subsection "name resolution / routing / proxy"
    probe "resolv.conf (comment lines omitted)" sh -c 'grep -Ev "^[[:space:]]*(#|$)" /etc/resolv.conf; :'
    probe "default route" sh -c "ip route show default 2>/dev/null | head -n 3"
    probe "proxy variables in current environment" sh -c "env | grep -i proxy; :"
    probe "proxy variables in /etc/environment" sh -c 'grep -i proxy /etc/environment 2>/dev/null; :'

    # [9] outbound reachability — closed networks break the rpm %post pip step
    # ("ResolutionImpossible", 2026-06-09); two bounded HEAD requests, 5s cap each
    section "H. Outbound reachability (2 bounded HEAD requests, 5s cap each)"
    local _url
    for _url in https://repo.whatap.io https://pypi.org; do
        if have curl; then
            probe "$_url" sh -c "curl -sI --max-time 5 -o /dev/null -w 'HTTP %{http_code} in %{time_total}s' $_url"
        elif have wget; then
            probe "$_url" sh -c "wget -q --spider -T 5 -t 1 $_url && echo reachable"
        else
            fact "$_url: n/a (command not found: curl, wget)"
        fi
    done

    # [10] configuration — nmscore.conf keys named in past cases:
    # MAX_REPETITIONS, IFX_32BIT_PPS_FALLBACK, ssl settings, syslog port.
    # wtinitset is the official configuration tool (docs.whatap.io/nms/
    # install-agent): -a sets the access key, -s the WhaTap server IP
    # (multi-IP "a/b" form exists), -v prints the current configuration.
    section "I. Configuration (verbatim)"
    subsection "wtinitset -v (official config viewer)"
    probe_merged "wtinitset -v" wtinitset -v
    subsection "discovered *.conf files"
    local _cfgs="" _cf
    if have rpm; then
        _cfgs="$(rpm -ql "$NMS_PKG" 2>/dev/null | grep '\.conf$' | head -n 20)"
    fi
    if [ -n "$NMS_ROOT" ]; then
        # etc/nmscore.conf is the documented location (FAQ: vi /usr/share/whatap-nms/etc/nmscore.conf);
        # etc/mibmods.toml is the MIB module registry (live-install observation)
        _cfgs="$(printf '%s\n%s\n%s\n%s\n%s\n' "$_cfgs" \
            "$(ls -1 "$NMS_ROOT"/*.conf 2>/dev/null)" \
            "$(ls -1 "$NMS_ROOT"/etc/*.conf 2>/dev/null)" \
            "$(ls -1 "$NMS_ROOT"/etc/*.toml 2>/dev/null)" \
            "$(ls -1 "$NMS_ROOT"/conf/*.conf 2>/dev/null)")"
    fi
    _cfgs="$(printf '%s\n' "$_cfgs" "$(ls -1 /etc/whatap-nms/*.conf 2>/dev/null)" | grep -v '^$' | sort -u)"
    if [ -n "$_cfgs" ]; then
        printf '%s\n' "$_cfgs" | while IFS= read -r _cf; do
            [ -e "$_cf" ] || { fact "$_cf: n/a (listed in package manifest, path not found on disk)"; continue; }
            fact "$_cf ($(file_meta "$_cf")):"
            dump_file "$_cf" 400
        done
        # keys of record, extracted flat in case a dump above hit its line cap:
        # MANAGER_WEB_PORT / MANAGER_HTTPS_* (UI port is configurable — FAQ),
        # MAX_REPETITIONS, IFX_32BIT_PPS_FALLBACK (named in past cases)
        subsection "keys of record across discovered conf files"
        probe "grep" sh -c "printf '%s\n' \"$_cfgs\" | while IFS= read -r f; do [ -e \"\$f\" ] && grep -HnE '^[[:space:]]*(MANAGER_WEB_PORT|MANAGER_HTTPS_ENABLED|MANAGER_HTTPS_WEB_PORT|MAX_REPETITIONS|IFX_32BIT_PPS_FALLBACK)' \"\$f\"; done; :"
    else
        fact "no *.conf discovered via package manifest, install root, or /etc/whatap-nms"
    fi

    # [11] logs & events — pkg-install-error.log is the first artifact support
    # asks for on an install failure (2026-06-09); /var/log/nmscore/nmscore.log
    # is the artifact the FAQ names for MIB module-load and engine issues
    section "J. Logs & recent events"
    local _logdir=/var/log/whatap-nms
    if [ -d "$_logdir" ]; then
        subsection "log inventory ($_logdir)"
        probe "ls" ls -la "$_logdir"
        subsection "pkg-install-error.log (last 60 lines)"
        tail_file "$_logdir/pkg-install-error.log" 60
        subsection "other *.log tails (last 25 lines each, first 8 files)"
        local _lf _cnt=0
        for _lf in "$_logdir"/*.log; do
            [ -e "$_lf" ] || continue
            [ "$_lf" = "$_logdir/pkg-install-error.log" ] && continue
            _cnt=$((_cnt + 1))
            [ "$_cnt" -gt 8 ] && { fact "(more *.log files not tailed — see inventory above)"; break; }
            fact "$_lf ($(file_meta "$_lf")):"
            tail_file "$_lf" 25
        done
        [ "$_cnt" = 0 ] && fact "no additional *.log file in $_logdir"
    else
        fact "$_logdir: n/a (path not found)"
    fi
    local _coredir=/var/log/nmscore
    if [ -d "$_coredir" ]; then
        subsection "nms engine log inventory ($_coredir)"
        probe "ls" ls -la "$_coredir"
        subsection "nmscore.log (last 80 lines — MIB module load results land here per FAQ)"
        tail_file "$_coredir/nmscore.log" 80
    else
        fact "$_coredir: n/a (path not found)"
    fi
    if have journalctl; then
        local _u2 _ls2
        for _u2 in $NMS_UNITS; do
            _ls2="$(sd_show LoadState "$_u2")"
            [ "$_ls2" = "loaded" ] || continue
            subsection "journal: $_u2.service (last 60 lines)"
            probe "journalctl" journalctl -u "$_u2.service" -n 60 --no-pager -q
        done
    else
        fact "journalctl: n/a (command not found: journalctl)"
    fi

    # [12] Tier 2 — timed SNMP probe (opt-in). Field debugging showed the answer
    # AND its arrival time both matter: a device answering in ~2-3s against a
    # manager first-response timeout of ~3s collects nothing, while no answer at
    # all points at device-side SNMP policy / filtering (2025-07-03 session).
    if [ "$OPT_SNMP" = 1 ]; then
        section "K. SNMP probe (opt-in) — target $SNMP_HOST:$SNMP_PORT, SNMPv2c"
        if have snmpget; then
            local _oid _name _t0 _t1 _out _rc
            for _oid in "sysDescr.0=1.3.6.1.2.1.1.1.0" "sysUpTime.0=1.3.6.1.2.1.1.3.0" "ifNumber.0=1.3.6.1.2.1.2.1.0"; do
                _name="${_oid%%=*}"
                warn "sending 1 SNMP GET ($_name) to $SNMP_HOST:$SNMP_PORT"
                _t0="$(now_s)"
                if [ -n "$_timeout_bin" ]; then
                    _out="$("$_timeout_bin" 15 snmpget -v2c -c "$SNMP_COMM" -t 10 -r 0 "$SNMP_HOST:$SNMP_PORT" "${_oid#*=}" 2>&1)"; _rc=$?
                else
                    _out="$(snmpget -v2c -c "$SNMP_COMM" -t 10 -r 0 "$SNMP_HOST:$SNMP_PORT" "${_oid#*=}" 2>&1)"; _rc=$?
                fi
                _t1="$(now_s)"
                fact "$_name: rc=$_rc elapsed=$(elapsed_s "$_t0" "$_t1")s"
                fact "    reply: $(printf '%s' "$_out" | head -n1 | cut -c1-160)"
            done
            fact "note: single GET requests only; this collector never walks a device"
        else
            fact "n/a (command not found: snmpget — net-snmp-utils not installed on this host)"
        fi
    fi

    emit_footer
}

# ---- main ----------------------------------------------------------------------
exec 3>&2

[ "$ARGC" -eq 0 ] && { usage; exit 0; }

if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
fi

if [ "$OPT_SNMP" = 1 ]; then
    warn "Tier 2 --snmp enabled: this run sends 3 SNMP GET requests to $SNMP_HOST:$SNMP_PORT (single GETs, no walk)."
fi

_init_probe
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
