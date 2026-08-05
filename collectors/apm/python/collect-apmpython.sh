#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — APM Python agent collector
# -----------------------------------------------------------------------------
# Gathers the hidden facts a remote WhaTap Python-agent developer repeatedly
# asks a field engineer for, from the host or container where a Python
# application (and the whatap-python agent) runs. Derived from an exhaustive
# review of #ask-dev-apm support threads (2025-02 .. 2026-07) and the
# whatap-python package source (2.1.2).
#
# Recurring field questions this report answers with facts:
#   * Which Python interpreter runs the app, and which whatap-python version
#     is installed where (wheel/dist-info vs legacy egg)?
#   * Is the Go common module (process name: whatap_python) actually running,
#     and from which WHATAP_HOME?
#   * Does WHATAP_HOME map to the whatap.conf the operator thinks it does?
#     What does whatap.conf / container.conf actually contain?
#   * Do whatap-hook.log (Python side) and whatap-boot-YYYYMMDD.log (Go side)
#     both exist, and what do their recent lines say?
#   * Is the UDP channel (net_udp_port, default 6600) listening, and is there
#     a TCP session toward the collection server?
#   * Is OpenTelemetry auto-instrumentation present in the same process
#     (co-instrumentation), and which WHATAP_* variables reached the process?
#   * Kubernetes/operator artifacts: /whatap-agent volume,
#     WHATAP_PYTHON_AGENT_PATH (symlink vs regular file), container.conf.
#
# THE CONTRACT (../../../CONTRACT.md):
#   1. Facts only. No conclusion is stated on any emitted line.
#   2. Discover, never assume. Resolve symlinks, process args, env, config.
#   3. One field command -> paste the whole output.
#   4. Domain-team owned. Seed v0 by the Global team; ownership transfers to
#      the APM/Python agent developers.
#
# DESIGN GUIDELINES (../../../docs/collector-engineering.md): MECE sections,
# Tier-0 load-safe defaults (bounded reads, no whole-log grep), bash 3.2+,
# reasoned absence for every missing value.
#
# NOTE: no `set -e` — a collector must reach its footer even when every probe
# fails. Failures are handled locally by the helpers.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata ------------------------------------------------------
COLLECTOR_NAME="whatap-apmpython"
VERSION="0.2.0"
DOMAIN="apm/python"
TARGET="host/$(hostname 2>/dev/null || echo unknown)"

# ---- CLI harness — DO NOT EDIT ----------------------------------------------
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Collects Python APM agent facts from the host or container where the Python
application runs (run it inside the container for containerized apps, e.g.
kubectl exec / docker exec).

Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")            print this help (no collection)
  $(basename "$0") --file     write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout   print the facts report to stdout
  $(basename "$0") --quiet .. silence progress on stderr (add to --file / --stdout)
EOF
}

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --file)    OPT_FILE=1 ;;
        --stdout)  OPT_STDOUT=1 ;;
        --quiet)   OPT_QUIET=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---- emit helpers — DO NOT EDIT ---------------------------------------------
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

fact() {
    printf '    %s\n' "$1"
}

emit_footer() {
    printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'
}

progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }
warn() { printf '%s\n' "$*" >&2; }

# ---- reasoned-absence helpers -------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_timeout_bin=""
CMD_TIMEOUT=15
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

# read_proc "label" PATH -> content of a /proc or /sys file, or a reason.
read_proc() {
    local label="$1" path="$2" out
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    out="$(cat "$path" 2>/dev/null)"
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# dump_file "label" PATH [CAP] -> the file's content verbatim (line-capped),
# or a classified reason. Framework policy: configuration is dumped verbatim,
# never masked (see collectors/apm/python/README.md security note).
dump_file() {
    local label="$1" path="$2" cap="${3:-400}" total
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label (first $cap of ${total:-?} lines):"
    head -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# tail_file "label" PATH [CAP] -> the file's LAST lines (bounded read).
tail_file() {
    local label="$1" path="$2" cap="${3:-200}" total
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label (last $cap of ${total:-?} lines):"
    tail -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# head_file "label" PATH [CAP] -> the file's FIRST lines (bounded read).
head_file() {
    local label="$1" path="$2" cap="${3:-120}" total
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label (first $cap of ${total:-?} lines):"
    head -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# pyprobe "label" PY_EXE CODE -> run a short python -c snippet under timeout.
# Never imports the `whatap` package itself (importing it has side effects);
# only importlib/pkg metadata lookups are used.
pyprobe() {
    local label="$1" py="$2" code="$3" out rc
    [ -x "$py" ] || { fact "$label: n/a (not executable: $py)"; return; }
    if [ -n "$_timeout_bin" ]; then out="$("$_timeout_bin" "$CMD_TIMEOUT" "$py" -c "$code" 2>"$_errfile")"; rc=$?
    else out="$("$py" -c "$code" 2>"$_errfile")"; rc=$?; fi
    [ "$rc" -eq 124 ] && [ -n "$_timeout_bin" ] && { fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; }
    if [ "$rc" -ne 0 ]; then
        local err
        err="$(grep -E 'Error|Exception' "$_errfile" 2>/dev/null | tail -n1 | cut -c1-140)"
        [ -z "$err" ] && err="$(_classify_err)"
        fact "$label: n/a ($err)"
        return
    fi
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# ---- discovery (internal; emits nothing) --------------------------------------
# Populates:
#   D_PY_EXES   distinct python interpreter paths (PATH + running processes)
#   D_GO_PIDS   pids of the Go common module (comm: whatap_python)
#   D_APP_PIDS  pids of python processes (excluding this collector's children)
#   D_HOMES     distinct WHATAP_HOME candidates with their discovery source
D_PY_EXES=""
D_GO_PIDS=""
D_APP_PIDS=""
D_HOMES=""          # newline-joined "path|source" records
D_PKG_DIRS=""       # newline-joined whatap package dirs seen in process environ
D_LOCK_FILE="${WHATAP_LOCK_FILE:-/tmp/whatap-python.lock}"
D_LLM_LOCK_FILE="/tmp/whatap-python-llm.lock"

# resolve_fs PATH -> prints a readable filesystem view of PATH: the path itself
# if it exists here, otherwise the same path seen through the root of a
# discovered agent/app process (/proc/<pid>/root<PATH>). Empty if neither is
# visible. This lets the collector run from a kubectl-debug ephemeral container
# (or any different mount namespace) and still read the target's files.
resolve_fs() {
    local p="$1" pid
    [ -e "$p" ] && { printf '%s\n' "$p"; return; }
    for pid in $D_GO_PIDS $D_APP_PIDS; do
        [ -e "/proc/$pid/root$p" ] && { printf '%s\n' "/proc/$pid/root$p"; return; }
    done
    return 1
}

_add_pkg_dir() {
    local d="$1"
    [ -n "$d" ] || return
    case "$D_PKG_DIRS" in *"$d"*) return ;; esac
    if [ -n "$D_PKG_DIRS" ]; then D_PKG_DIRS="$D_PKG_DIRS
$d"; else D_PKG_DIRS="$d"; fi
}

_add_home() {  # _add_home PATH SOURCE
    local p="$1" s="$2"
    [ -n "$p" ] || return
    case "$D_HOMES" in *"$p|"*) return ;; esac
    if [ -n "$D_HOMES" ]; then D_HOMES="$D_HOMES
$p|$s"; else D_HOMES="$p|$s"; fi
}

# Identity is the INVOCATION path, not its readlink target: a virtualenv's
# bin/python usually symlinks to the base interpreter, but sys.prefix (and so
# site-packages, where whatap-python lives) is derived from the path used to
# invoke it. Collapsing to the resolved binary would hide the venv install.
# Dedup key: dirname + resolved target (so bin/python and bin/python3 of the
# same env collapse, while base and venv interpreters stay distinct).
D_PY_KEYS=""
_add_py() {
    local p="$1" k
    [ -n "$p" ] || return
    [ -x "$p" ] || return
    case "$p" in *-config|*-dbg|*-coverage) return ;; esac   # not interpreters
    k="$(dirname "$p" 2>/dev/null)|$(readlink -f "$p" 2>/dev/null || echo "$p")"
    case "$D_PY_KEYS" in *"|$k|"*) return ;; esac
    D_PY_KEYS="$D_PY_KEYS|$k|"
    D_PY_EXES="$D_PY_EXES $p"
}

discover() {
    progress "discovery: interpreters, processes, agent homes"
    local c p pid comm exe cwd envh

    # process scan (reads only comm/exe per pid; environ/cwd only for matches).
    # Runs FIRST so the interpreters of live application processes take the
    # detail slots before PATH/system interpreters when the cap applies.
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        [ "$pid" = "$$" ] && continue
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
        case "$comm" in
            whatap_python*) D_GO_PIDS="$D_GO_PIDS $pid" ;;
            python*)
                D_APP_PIDS="$D_APP_PIDS $pid"
                # argv0 keeps the venv invocation path; /proc/<pid>/exe is
                # already symlink-resolved by the kernel and would lose it.
                # A relative argv0 is resolved against the process's cwd.
                exe="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -n1)"
                case "$exe" in
                    /*python*) : ;;
                    *python*)
                        cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"
                        exe="${exe#./}"
                        if [ -n "$cwd" ] && [ -x "$cwd/$exe" ]; then exe="$cwd/$exe"
                        else exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"; fi
                        ;;
                    *) exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)" ;;
                esac
                [ -n "$exe" ] && _add_py "$exe"
                ;;
        esac
    done

    # interpreters on PATH
    for c in python3 python; do
        p="$(command -v "$c" 2>/dev/null)"
        [ -n "$p" ] && _add_py "$p"
    done

    # multiple interpreter versions commonly coexist on one VM — enumerate the
    # usual install locations (shallow globs only, no directory walk)
    for p in /usr/bin/python2* /usr/bin/python3* /usr/local/bin/python2* /usr/local/bin/python3* /opt/python*/bin/python3*; do
        [ -x "$p" ] && _add_py "$p"
    done

    # agent home candidates
    [ -n "${WHATAP_HOME:-}" ] && _add_home "$WHATAP_HOME" "env WHATAP_HOME (collector shell)"
    [ -n "${WHATAP_HOME_BATCH:-}" ] && _add_home "$WHATAP_HOME_BATCH" "env WHATAP_HOME_BATCH (collector shell)"
    if [ -r "$D_LOCK_FILE" ]; then
        # lock file records "port<TAB>home" per agent home
        while IFS= read -r _l || [ -n "$_l" ]; do
            p="$(printf '%s\n' "$_l" | awk '{print $2}')"
            [ -n "$p" ] && _add_home "$p" "port registry $D_LOCK_FILE"
        done < "$D_LOCK_FILE"
    fi
    for pid in $D_GO_PIDS; do
        cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"
        [ -n "$cwd" ] && _add_home "$cwd" "cwd of whatap_python pid $pid"
        envh="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep '^WHATAP_HOME=' | head -n1 | cut -d= -f2-)"
        [ -n "$envh" ] && _add_home "$envh" "environ of whatap_python pid $pid"
    done
    for pid in $D_APP_PIDS; do
        envh="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep '^WHATAP_HOME=' | head -n1 | cut -d= -f2-)"
        [ -n "$envh" ] && _add_home "$envh" "environ of python pid $pid"
        # whatap package dir derived from the process's PYTHONPATH bootstrap
        # entry — usable even when the interpreter cannot be executed
        envh="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep '^PYTHONPATH=' | head -n1 | cut -d= -f2- | tr ':' '\n' | grep '/whatap/bootstrap$' | head -n1)"
        [ -n "$envh" ] && _add_pkg_dir "$(dirname "$envh")"
    done
    # operator auto-injection default mount
    [ -d /whatap-agent ] && _add_home "/whatap-agent" "operator injection volume /whatap-agent"
}

# ---- report body ---------------------------------------------------------------
run_report() {
    emit_header

    # [0] capability preamble: every downstream "command not found" is
    # pre-explained here.
    section "Collection environment"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    fact "collector cwd: $(pwd 2>/dev/null || echo unknown)"
    fact "tools:"
    for t in python3 python pip3 ss netstat readlink timeout file stat awk tr; do
        if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present (%s)\n' "$t" "$(command -v "$t")"
        else printf '        %-12s absent\n' "$t"; fi
    done

    discover

    # [1] host / platform
    section "Host / platform"
    probe "kernel" uname -srm
    probe "machine arch" uname -m
    read_proc "os-release" /etc/os-release
    probe "cpu count (nproc)" nproc
    fact "memory:"
    grep -E '^(MemTotal|MemAvailable)' /proc/meminfo 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
    # container / cgroup context — memory and cpu limits as the container sees
    # them (facts behind container-vs-host metric questions)
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        fact "cgroup: v2 (unified)"
        read_proc "cgroup memory.max" /sys/fs/cgroup/memory.max
        read_proc "cgroup cpu.max" /sys/fs/cgroup/cpu.max
    elif [ -d /sys/fs/cgroup/memory ]; then
        fact "cgroup: v1"
        read_proc "cgroup memory.limit_in_bytes" /sys/fs/cgroup/memory/memory.limit_in_bytes
        read_proc "cgroup cpu cfs_quota_us" /sys/fs/cgroup/cpu/cpu.cfs_quota_us
        read_proc "cgroup cpu cfs_period_us" /sys/fs/cgroup/cpu/cpu.cfs_period_us
    else
        fact "cgroup: n/a (path not found: /sys/fs/cgroup)"
    fi
    fact "container markers:"
    for m in /.dockerenv /run/.containerenv; do
        if [ -e "$m" ]; then printf '        %-22s present\n' "$m"; else printf '        %-22s absent\n' "$m"; fi
    done
    if [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
        printf '        %-22s %s\n' "KUBERNETES_SERVICE_HOST" "$KUBERNETES_SERVICE_HOST"
    else
        printf '        %-22s not set\n' "KUBERNETES_SERVICE_HOST"
    fi
    probe "self cgroup (first 5 lines)" sh -c "head -n 5 /proc/self/cgroup"
    probe "local time" date
    probe "pid 1 command" sh -c "tr '\0' ' ' < /proc/1/cmdline | cut -c1-160"

    # [2] python runtimes + whatap-python package (per distinct interpreter)
    section "Python runtimes and whatap-python package"
    if [ -z "$D_PY_EXES" ]; then
        fact "python interpreters: n/a (none found on PATH or among running processes)"
    fi
    local _pycount=0 py
    for py in $D_PY_EXES; do
        _pycount=$((_pycount + 1))
        if [ "$_pycount" -gt 8 ]; then
            fact "-- more interpreters found but not detailed (cap: 8): $(echo $D_PY_EXES | tr ' ' '\n' | tail -n +9 | tr '\n' ' ')"
            break
        fi
        fact "-- interpreter: $py"
        fact "   resolves to: $(readlink -f "$py" 2>/dev/null || echo "$py")"
        pyprobe "version" "$py" 'import sys; print(sys.version.replace(chr(10)," "))'
        pyprobe "sys.prefix / base_prefix (differ = virtualenv)" "$py" 'import sys; print(sys.prefix); print(getattr(sys,"base_prefix",sys.prefix))'
        pyprobe "whatap-python version" "$py" 'import importlib.metadata as m; print(m.version("whatap-python"))'
        pyprobe "whatap package location" "$py" 'import importlib.util as u; s=u.find_spec("whatap"); print(s.origin if s and s.origin else "not found")'
        pyprobe "install format (dist-info=wheel, egg=setup.py era)" "$py" '
import importlib.util as u, os, glob
s=u.find_spec("whatap")
if not (s and s.origin): print("not found")
else:
    sp=os.path.dirname(os.path.dirname(s.origin))
    hits=glob.glob(os.path.join(sp,"whatap_python-*"))
    print("\n".join(os.path.basename(h) for h in hits) if hits else "no whatap_python-* metadata dir in "+sp)'
        pyprobe "setuptools version" "$py" 'import importlib.metadata as m; print(m.version("setuptools"))'
        pyprobe "import pkg_resources" "$py" 'import pkg_resources; print("ok")'
        # Go module binaries shipped inside the package, vs this machine arch
        pyprobe "bundled Go module binaries" "$py" '
import importlib.util as u, os
s=u.find_spec("whatap")
if not (s and s.origin): print("not found")
else:
    d=os.path.join(os.path.dirname(s.origin),"agent")
    if not os.path.isdir(d): print("no agent dir: "+d)
    else:
        for root,_,files in os.walk(d):
            for f in files:
                p=os.path.join(root,f)
                print("%s  %d bytes  exec=%s" % (p, os.path.getsize(p), os.access(p,os.X_OK)))'
        pyprobe "bootstrap/sitecustomize.py present" "$py" '
import importlib.util as u, os
s=u.find_spec("whatap")
print(os.path.exists(os.path.join(os.path.dirname(s.origin),"bootstrap","sitecustomize.py")) if s and s.origin else "not found")'
        # hook surface of the INSTALLED agent version (trace/mod tree) — this
        # differs between agent versions, so it is reported per install
        pyprobe "instrumentation modules bundled in installed agent (trace/mod)" "$py" '
import importlib.util as u, os
s=u.find_spec("whatap")
if not (s and s.origin): print("not found")
else:
    base=os.path.join(os.path.dirname(s.origin),"trace","mod")
    if not os.path.isdir(base): print("no trace/mod dir: "+base)
    else:
        groups={}
        for root,dirs,files in os.walk(base):
            rel=os.path.relpath(root,base)
            cat="core" if rel=="." else rel.replace(os.sep,"/")
            for f in sorted(files):
                if f.endswith(".py") and f not in ("__init__.py","util.py"):
                    groups.setdefault(cat,[]).append(f[:-3])
        for k in sorted(groups): print(k+": "+", ".join(sorted(groups[k])))'
        probe "installed packages ($py -m pip list, first 200)" sh -c "PIP_DISABLE_PIP_VERSION_CHECK=1 '$py' -m pip list --format=freeze 2>/dev/null | head -n 200"
    done
    fact "console scripts on PATH:"
    for c in whatap-start-agent whatap-stop-agent whatap-setting-config whatap-llm-setting-config whatap-start-batch-agent; do
        p="$(command -v "$c" 2>/dev/null)"
        if [ -n "$p" ]; then printf '        %-28s %s\n' "$c" "$p"
        else printf '        %-28s not on PATH\n' "$c"; fi
    done
    # fallback that needs no interpreter execution (e.g. distroless images
    # inspected from a kubectl-debug ephemeral container): package dirs derived
    # from the PYTHONPATH of running processes, version read from metadata files
    if [ -n "$D_PKG_DIRS" ]; then
        fact "whatap package dirs seen in process environ (no interpreter execution):"
        printf '%s\n' "$D_PKG_DIRS" | while IFS= read -r d; do
            [ -n "$d" ] || continue
            fsd="$(resolve_fs "$d")"
            if [ -z "$fsd" ]; then printf '        -- %s: n/a (path not visible from this mount namespace)\n' "$d"; continue; fi
            if [ "$fsd" != "$d" ]; then printf '        -- %s (read via %s)\n' "$d" "$fsd"
            else printf '        -- %s\n' "$d"; fi
            sp="$(dirname "$fsd")"
            meta="$(ls "$sp"/whatap_python-*.dist-info/METADATA "$sp"/whatap_python-*.egg-info/PKG-INFO "$sp"/EGG-INFO/PKG-INFO 2>/dev/null | head -n1)"
            if [ -n "$meta" ]; then
                printf '           metadata: %s\n' "$meta"
                printf '           %s\n' "$(grep -m1 '^Version:' "$meta" 2>/dev/null || echo 'Version: n/a (no Version line in metadata)')"
            else
                printf '           metadata: n/a (no whatap_python-* dist-info/egg-info next to %s)\n' "$fsd"
            fi
            if [ -d "$fsd/agent" ]; then printf '           agent binaries dir: present\n'
            else printf '           agent binaries dir: absent\n'; fi
            # library inventory of this environment, from metadata dir names —
            # needs neither pip nor a runnable interpreter
            _dists="$(ls "$sp" 2>/dev/null | grep -E '\.dist-info$|\.egg-info$|\.egg$' | sed 's/\.dist-info$//; s/\.egg-info$//')"
            if [ -n "$_dists" ]; then
                printf '           installed distributions in %s (%s total, first 200):\n' "$sp" "$(printf '%s\n' "$_dists" | wc -l | tr -d ' ')"
                printf '%s\n' "$_dists" | head -n 200 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
            else
                printf '           installed distributions: n/a (no dist-info/egg-info entries in %s)\n' "$sp"
            fi
            # hook surface of this install (shell glob; two levels, no walk)
            _mods="$(for f in "$fsd"/trace/mod/*.py "$fsd"/trace/mod/*/*.py; do [ -f "$f" ] && basename "$f" .py; done 2>/dev/null | grep -vE '^(__init__|util)$' | sort -u | tr '\n' ' ')"
            if [ -n "$_mods" ]; then printf '           instrumentation modules bundled in installed agent: %s\n' "$_mods"
            else printf '           instrumentation modules: n/a (no trace/mod entries under %s)\n' "$fsd"; fi
        done
    fi

    # [3] runtime processes
    section "Runtime processes"
    local pid n
    if [ -z "$D_GO_PIDS" ]; then
        fact "Go common module (whatap_python) processes: none found in /proc"
    else
        fact "Go common module (whatap_python) processes:"
        for pid in $D_GO_PIDS; do
            printf '        -- pid %s\n' "$pid"
            printf '           cmdline: %s\n' "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-300)"
            printf '           cwd: %s\n' "$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo "n/a (permission denied or gone)")"
            printf '           uid/state: %s\n' "$(awk '/^Uid:/{u=$2} /^State:/{s=$2" "$3} END{print u" / "s}' "/proc/$pid/status" 2>/dev/null)"
            if [ -r "/proc/$pid/environ" ]; then
                tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -E '^(WHATAP_HOME|WHATAP_VERSION|whatap\.port|python\.version)=' | while IFS= read -r _l; do printf '           env %s\n' "$_l"; done
            else
                printf '           env: n/a (permission denied: /proc/%s/environ)\n' "$pid"
            fi
        done
    fi
    n="$(echo $D_APP_PIDS | wc -w | tr -d ' ')"
    if [ "${n:-0}" -eq 0 ]; then
        fact "python processes: none found in /proc"
    else
        fact "python processes found: $n (detailing first 20)"
        local shown=0
        for pid in $D_APP_PIDS; do
            shown=$((shown + 1))
            [ "$shown" -gt 20 ] && { fact "-- remaining $((n - 20)) python processes not detailed (cap: 20)"; break; }
            printf '        -- pid %s (ppid %s)\n' "$pid" "$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
            printf '           exe: %s\n' "$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo n/a)"
            printf '           cmdline: %s\n' "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-300)"
            if [ -r "/proc/$pid/environ" ]; then
                if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q '^PYTHONPATH=.*whatap/bootstrap'; then
                    printf '           PYTHONPATH contains whatap/bootstrap: yes\n'
                else
                    printf '           PYTHONPATH contains whatap/bootstrap: no\n'
                fi
                # which python environment this process actually runs in
                tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -E '^(VIRTUAL_ENV|PYTHONPATH|PYTHONHOME)=' | cut -c1-300 | while IFS= read -r _l; do printf '           env %s\n' "$_l"; done
                tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -E '^WHATAP_' | while IFS= read -r _l; do printf '           env %s\n' "$_l"; done
                tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -E '^OTEL_' | cut -c1-200 | while IFS= read -r _l; do printf '           env %s\n' "$_l"; done
            else
                printf '           environ: n/a (permission denied: /proc/%s/environ)\n' "$pid"
            fi
            # libraries the process has ACTUALLY loaded, from its memory map.
            # Only C-extension packages appear here (pure-Python imports are
            # not memory-mapped); it also reveals which site-packages the
            # live process really loads from.
            if cat "/proc/$pid/maps" >/dev/null 2>&1; then
                _so="$(awk '$NF ~ /site-packages\/.*\.so/ {print $NF}' "/proc/$pid/maps" 2>/dev/null | sort -u)"
                if [ -n "$_so" ]; then
                    printf '           site-packages in use (from loaded C extensions):\n'
                    printf '%s\n' "$_so" | sed 's#\(.*/site-packages\)/.*#\1#' | sort -u | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
                    printf '           loaded C-extension packages (pure-Python imports do not appear in maps):\n'
                    printf '%s\n' "$_so" | sed 's#.*/site-packages/##' | sed 's#/.*##' | sed 's#\.cpython.*##; s#\.so.*##' | sort -u | head -n 40 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
                else
                    printf '           loaded C-extension packages: none in maps (pure-Python imports do not appear in maps)\n'
                fi
            else
                printf '           maps: n/a (permission denied: /proc/%s/maps)\n' "$pid"
            fi
        done
    fi

    # [4] agent homes and configuration
    section "Agent homes and configuration"
    fact "env WHATAP_HOME (collector shell): ${WHATAP_HOME:-not set}"
    fact "env WHATAP_HOME_BATCH (collector shell): ${WHATAP_HOME_BATCH:-not set}"
    fact "env WHATAP_LOCK_FILE (collector shell): ${WHATAP_LOCK_FILE:-not set}"
    if [ -z "$D_HOMES" ]; then
        fact "agent home candidates: none discovered (env, port registry, process scan all empty)"
    else
        fact "agent home candidates discovered:"
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r _p _s; do printf '        %s   <- %s\n' "$_p" "$_s"; done
        printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r home; do
            [ -n "$home" ] || continue
            fact "-- home: $home"
            fshome="$(resolve_fs "$home")"
            if [ -z "$fshome" ]; then fact "   n/a (path not visible from this mount namespace: $home)"; continue; fi
            [ "$fshome" != "$home" ] && fact "   filesystem view: $fshome (read through a process root)"
            dump_file "   whatap.conf" "$fshome/whatap.conf" 400
            dump_file "   container.conf" "$fshome/container.conf" 200
            if [ -e "$fshome/whatap_python" ]; then
                fact "   whatap_python entry: $(ls -l "$fshome/whatap_python" 2>/dev/null | head -n1)"
                fact "   whatap_python resolved: $(readlink -f "$fshome/whatap_python" 2>/dev/null || echo 'n/a (unresolvable)')"
            else
                fact "   whatap_python entry: n/a (path not found: $fshome/whatap_python)"
            fi
            for pf in whatap_python.pid whatap_python.pid.llm whatap_python.pid.batch; do
                if [ -f "$fshome/$pf" ]; then
                    _pid="$(cat "$fshome/$pf" 2>/dev/null | tr -d ' \n')"
                    if [ -n "$_pid" ] && [ -d "/proc/$_pid" ]; then
                        fact "   $pf: $_pid (process exists; comm: $(cat "/proc/$_pid/comm" 2>/dev/null))"
                    else
                        fact "   $pf: ${_pid:-empty} (no process with this pid in this pid namespace)"
                    fi
                fi
            done
            if [ -d "$fshome/logs" ]; then
                probe "   logs dir listing" sh -c "ls -la '$fshome/logs' 2>/dev/null | head -n 100"
            else
                fact "   logs dir: n/a (path not found: $fshome/logs)"
            fi
            [ -d "$fshome/run" ] && fact "   run dir (agent sockets): present" || fact "   run dir (agent sockets): absent"
            [ -d "$fshome/whatap-python-llm" ] && fact "   whatap-python-llm dir (LLM Go module): present" || fact "   whatap-python-llm dir (LLM Go module): absent"
        done
    fi

    # [5] network endpoints + port registry
    section "Network endpoints and port registry"
    if have ss; then
        probe "udp sockets (whatap_python or ports 66xx)" sh -c "ss -ulnp 2>/dev/null | awk 'NR==1 || /whatap/ || /:66[0-9][0-9] /' | head -n 50"
        probe "tcp sessions (whatap_python or port 6600)" sh -c "ss -tnp 2>/dev/null | awk 'NR==1 || /whatap/ || /:6600/' | head -n 50"
    elif have netstat; then
        probe "udp sockets (whatap_python or ports 66xx)" sh -c "netstat -ulnp 2>/dev/null | awk 'NR<=2 || /whatap/ || /:66[0-9][0-9] /' | head -n 50"
        probe "tcp sessions (whatap_python or port 6600)" sh -c "netstat -tnp 2>/dev/null | awk 'NR<=2 || /whatap/ || /:6600/' | head -n 50"
    else
        fact "socket listing: n/a (command not found: ss, netstat); raw tables follow"
        probe "raw /proc/net/udp (first 30 lines, ports in hex)" sh -c "head -n 30 /proc/net/udp"
        probe "raw /proc/net/tcp (first 30 lines, ports in hex)" sh -c "head -n 30 /proc/net/tcp"
    fi
    dump_file "port registry (format: port<TAB>home)" "$D_LOCK_FILE" 50
    dump_file "LLM port registry" "$D_LLM_LOCK_FILE" 50

    # [6] agent logs (bounded tails only; never a whole-log grep)
    section "Agent logs"
    if [ -z "$D_HOMES" ]; then
        fact "no agent home discovered; no log locations to read"
    else
        printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r home; do
            [ -n "$home" ] || continue
            fact "-- home: $home"
            fshome="$(resolve_fs "$home")"
            if [ -z "$fshome" ]; then fact "   n/a (path not visible from this mount namespace: $home)"; continue; fi
            # hook log: the banner and the "successfully injected <module>"
            # lines (= which libraries the agent hooked in THIS process) are at
            # the START of the file, so read its head as well as its tail
            _hook="$fshome/logs/whatap-hook.log"
            head_file "   whatap-hook.log (first lines: banner + injected modules)" "$_hook" 120
            tail_file "   whatap-hook.log (recent lines)" "$_hook" 80
            if [ -r "$_hook" ]; then
                fact "   'successfully injected' lines in whatap-hook.log (first 400 lines): $(head -n 400 "$_hook" 2>/dev/null | grep -c 'successfully injected' 2>/dev/null)"
            fi
            # newest Go-side boot log only (flat dir; ls -t, no deep find)
            _boot="$(ls -t "$fshome"/logs/whatap-boot-*.log 2>/dev/null | head -n 1)"
            if [ -n "$_boot" ]; then
                head_file "   $(basename "$_boot") (Go-side boot log, first lines)" "$_boot" 60
                tail_file "   $(basename "$_boot") (Go-side boot log, recent lines)" "$_boot" 120
            else
                fact "   whatap-boot-*.log: n/a (no such file in $fshome/logs)"
            fi
        done
    fi

    # [7] kubernetes / operator injection artifacts
    section "Kubernetes / operator injection context"
    if [ -d /whatap-agent ]; then
        probe "/whatap-agent listing (operator injection volume)" sh -c "ls -la /whatap-agent 2>/dev/null | head -n 50"
    else
        fact "/whatap-agent: n/a (path not found — operator injection volume absent)"
    fi
    if [ -n "${WHATAP_PYTHON_AGENT_PATH:-}" ]; then
        fact "env WHATAP_PYTHON_AGENT_PATH: $WHATAP_PYTHON_AGENT_PATH"
        if [ -L "$WHATAP_PYTHON_AGENT_PATH" ]; then
            fact "WHATAP_PYTHON_AGENT_PATH file type: symlink -> $(readlink -f "$WHATAP_PYTHON_AGENT_PATH" 2>/dev/null)"
        elif [ -e "$WHATAP_PYTHON_AGENT_PATH" ]; then
            fact "WHATAP_PYTHON_AGENT_PATH file type: regular file"
        else
            fact "WHATAP_PYTHON_AGENT_PATH file type: n/a (path not found)"
        fi
    else
        fact "env WHATAP_PYTHON_AGENT_PATH: not set (collector shell)"
    fi
    for v in POD_NAME NODE_NAME POD_NAMESPACE OKIND ONAME ONODE; do
        eval "_val=\${$v:-}"
        [ -n "$_val" ] && fact "env $v: $_val"
    done
    [ -d /var/run/secrets/kubernetes.io ] && fact "/var/run/secrets/kubernetes.io: present" || fact "/var/run/secrets/kubernetes.io: absent"
    read_proc "container hostname (/etc/hostname)" /etc/hostname

    emit_footer
}

# ---- main — DO NOT EDIT --------------------------------------------------------
exec 3>&2

[ "$ARGC" -eq 0 ] && { usage; exit 0; }

if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
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
