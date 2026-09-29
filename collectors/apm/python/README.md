# collectors/apm/python: WhaTap Python APM agent collector

> **Status:** validated at `collect-apmpython.sh` 0.11.2 on 2026-09-28, lab `apm-python`
> / `apm-python-op` containers (real `whatap-python` agents: 2.2.0 from PyPI in a
> virtualenv under `whatap-start-agent gunicorn`, and the operator `apm-init-python`
> copy 2.1.2 with `PYTHONPATH=/whatap-agent:/whatap-agent/whatap/bootstrap` under plain
> gunicorn; as root, as the app user and as another user, bash and `sh -s`; `validate.sh
> --report` pass).
> Not yet run on: an environment with a reachable collection server (the Go module
> opened no UDP listener and no TCP session). Owner: Global team until handover to the
> Python agent developers (CONTRACT rule 4).

Collects the hidden facts a remote WhaTap Python-agent developer repeatedly
asks a field engineer for. The fact list comes from a review of `#ask-dev-apm`
Python support threads (2025-02 .. 2026-07), checked against the `whatap-python`
package source (2.1.2).

## One field command

Run **where the Python application runs**:

```sh
# VM / bare metal
./collect-apmpython.sh --file          # -> whatap-apmpython-<host>-<UTC>.txt

# Kubernetes: pipe the script over stdin; nothing to copy into the pod,
# nothing written to a possibly read-only rootfs
kubectl exec -i <pod> -c <container> -- sh -s -- --stdout --quiet \
    < collect-apmpython.sh > report.txt

# Docker
docker exec -i <container> sh -s -- --stdout --quiet \
    < collect-apmpython.sh > report.txt
```

Paste or attach the entire output; delivery notes for containers and Kubernetes are in
[../README.md](../README.md), "Running a Linux apm collector". Every run also runs
`python -m pip list` in each detailed interpreter (one more start each).

Notes:

- **POSIX sh is enough.** The script runs under bash, dash, and busybox ash
  (`alpine`, `python:*-slim`; no bash/ss/procps required, socket facts fall back to
  raw `/proc/net/udp|tcp`).
- From a debug container the whatap-python version is read from package metadata
  files without executing any interpreter.

## Facts collected (report sections)

| # | Section | Answers the recurring question |
| --- | --- | --- |
| 1 | Collection environment | which tools were available to this collection |
| 2 | Host / platform | OS, arch (amd64/arm64), `ls -l` of `/sys/class/dmi/id/product_uuid` and whether this run could read it (the value only when it could; see [../README.md](../README.md)), container markers, cgroup CPU/memory limits (container-vs-host metric questions) |
| 3 | Python runtimes and whatap-python package | every interpreter (those of whatap-marked processes first, so the detail cap of 8 does not fill with unrelated ones) (multiple versions and **virtualenvs are kept distinct**: identity is the invocation path, not the resolved binary), whatap-python version/location per interpreter, the `whatap_python-*` metadata dirs next to the package (`.dist-info` = wheel install, `.egg-info`/`.egg` = setup.py-era install), `sys.prefix` / `base_prefix` (they differ inside a virtualenv), setuptools / `pkg_resources` import facts (Python 3.12 install issues), bundled Go module binaries per arch, `bootstrap/sitecustomize.py`, console scripts on PATH, **application library inventory**: the `.dist-info`/`.egg-info`/`.egg`/`.egg-link` names in every `sys.path` directory of each interpreter (see "Library inventory" below; then `pip list` per interpreter), plus a no-exec fallback (the same names next to each whatap package dir seen in process environ), plus the **instrumentation surface of the installed agent** (`trace/mod` tree, grouped: application/database/httpc/amqp/...) which differs across agent versions |
| 4 | Runtime processes | Go common module (`whatap_python`) processes, zombies included, read from the one `/proc/<pid>/stat` scan discovery already did (`_disc_go`): the count found, then the first 20 (state Z last) with ppid, uid/state and cwd/env; python app processes (matched by comm, argv0 or `/proc/<pid>/exe`, see below; whatap-marked ones first) with argv0, `PYTHONPATH contains whatap/bootstrap`, `VIRTUAL_ENV`, `WHATAP_*`, `OTEL_*` (co-instrumentation); **libraries the process actually loaded**: C-extension packages and the real `site-packages` path from `/proc/<pid>/maps` (pure-Python imports do not appear there) |
| 5 | Agent homes and configuration | every `WHATAP_HOME` candidate (env, port registry `/tmp/whatap-python.lock`, process cwd/environ, `/whatap-agent`), and per home: `whatap.conf` / `container.conf` verbatim, `whatap_python` symlink resolution, pid files (entry with the full mtime from `stat -c`, else `ls -l`; content, and whether that pid exists, with its state and ppid), `security.conf` / `paramkey.txt` presence and size, `logs/` inventory, `run/` listing (one `stat -c` line per entry with the full mtime, else `ls -la`; first 40 entries and the count), LLM module dir. A home that cannot be read says `path not found` or `permission denied` |
| 6 | Network endpoints and port registry | UDP sockets on 66xx plus the `net_udp_port` of the readable `whatap.conf` files and the port registry, TCP sessions on 6600 plus the `whatap.server.port` named there (each port labelled by its source), plus every socket of a whatap-named process; port registry contents |
| 7 | Agent logs | `whatap-hook.log` head (banner + `successfully injected <module>` lines = which libraries the agent hooked in this process) and tail (recent), the newest `whatap-boot-YYYYMMDD.log` (Go side) head + tail, all bounded reads |
| 8 | Odoo application facts | odoo master/worker processes, Odoo version (`odoo/release.py`, read as text, no odoo code runs), `odoo.conf` (path from `-c`/`ODOO_RC`/packaged defaults; see "What the report can contain" below) with the `logfile` key resolved and the worker log tailed (with `logfile` unset, odoo writes to the process stdout/stderr, e.g. the container log) (the HTTP-worker traceback lives there, not in the master/startup log), listening sockets (8069/8072), systemd unit facts (`Environment=`/`ExecStart` visibility for `whatap-start-agent` PATH issues), `injected odoo` hook-evidence counts. On non-Odoo hosts it starts no interpreter: where each interpreter would import `odoo` from is looked up in the one start of section 3, and an interpreter whose lookup did not answer is named here. Interpretation aid: the agent's Odoo support matrix (14–19 from agent 2.1.3; JSON-RPC errors return HTTP 200 and are not captured; WebSocket/Longpolling/Cron not instrumented) is maintained in the internal "Odoo 지원" Notion document |
| 9 | Kubernetes / operator injection context | `/whatap-agent` volume, `WHATAP_PYTHON_AGENT_PATH` (symlink vs regular file), k8s env facts |

## How each interpreter is asked

Every interpreter this run starts gets `PYTHONPATH` without its
`*/whatap/bootstrap` entries. That directory holds the agent's `sitecustomize.py`,
which calls `whatap.agent()` in any interpreter that finds it; the operator puts it on
the container's `PYTHONPATH` and the `kubectl exec` shell inherits it, so an interpreter
started by the run would start an agent and kill the application's `whatap_python` Go
module. The other entries stay, so a package found through them (`/whatap-agent`) is
still found. `[1]` names the entries removed.

The lookups of section 3 (version, prefixes, whatap-python version and location,
metadata dirs, setuptools, `pkg_resources`, bundled binaries, `sitecustomize.py`,
`trace/mod`, the library inventory, and the `odoo` location section 8 reads) run in
**one** start of each interpreter; each line and each `n/a (...)` reads as a separate
`python -c` would have made it. A snippet that hangs says `timed out`, and the snippets
that never started are re-run one by one under their own cap (past the run deadline
they say `not run: ...`). `pip list` is a call of its own and is not started in an
interpreter whose lookups did not answer within the cap.

## Library inventory

The inventory is the names of the metadata entries (`*.dist-info`, `*.egg-info`,
`*.egg`, `*.egg-link`) in each directory on the interpreter's `sys.path`, listed by that
interpreter start; nothing is imported and pip is not needed (uv-made environments have
no pip module). These are the entries `pip list` reads, so names and versions agree.
What `pip list` adds (it runs in every run):

- the version of an `.egg-info` entry whose name carries none (from its `PKG-INFO`),
  and names normalised from the metadata;
- one entry per distribution: where the same distribution sits in two `sys.path`
  directories, pip shows the first, the listing shows both;
- whether pip itself runs in that interpreter.

A legacy editable install (`setup.py develop`) shows as `<name>.egg-link` and its source
directory is listed with its `<name>.egg-info`; a PEP 660 editable install has an
ordinary `.dist-info`. `pip list` declares no goal: an interpreter without a working pip
(no module, an error, a timeout) is a fact line with its reason, and the run stays
COMPLETE on that account.

## How python processes are found

A process is a python process when its `comm`, its `argv0` or its
`/proc/<pid>/exe` names a python interpreter. `comm` alone is not enough: an
app started from a shebang script (`gunicorn`, `uvicorn`, `celery`,
`odoo-bin`, `whatap-start-agent`) is named after the script by the kernel,
which puts the interpreter from the `#!` line into `argv0`. `exe` covers an
`argv0` rewritten by setproctitle, for the processes the run may resolve. The
whole of `/proc` is read in one pass; `environ` and `cwd` are read only for
the matches.

## Collection status

Goals and their `na` / `missed` rules are those of
[../README.md](../README.md), "Agent goal". `agent` is obtained when a visible agent home,
a whatap package dir, a whatap package found by an interpreter, or a `whatap_python`
process exists; an interpreter's package lookup failing also makes an absence `missed`.
A process whose environ the run cannot read counts as an unread input only when its
command line names whatap or a `whatap_python` process runs on the host, so the root
python daemons of a stock distribution (`networkd-dispatcher`, `unattended-upgrades`)
alone do not make a non-root run `missed` on a host without the agent; their count and
pids are named in the `na` reason. An app whose whatap marker is only in its environ and
whose `whatap_python` process has exited is then seen only by a root run. `conf` is
obtained when a `whatap.conf` in an agent home is readable; a home whose path does not
exist gives `na` with `path not found`, a home or file the run may not read gives
`missed` with `permission denied`, and no `whatap.conf` in the homes found while a
candidate's `environ`/`cwd` was unread is `missed` (that candidate's home is unknown).

## What the report can contain

The common items are in [../README.md](../README.md), "What every Linux apm report can
contain". Python specific: `odoo.conf` is dumped without its `db_password` and
`admin_passwd` lines (the report says how many were left out), the only content this
collector omits besides key material. Every place a secret can arrive from:

- `whatap.conf` and `container.conf` of every agent home, verbatim
  (`license`, server addresses, any other key the operator put there).
- The environment of python and `whatap_python` processes: every `WHATAP_*`
  and `OTEL_*` variable (OTLP headers can carry tokens), `PYTHONPATH`,
  `VIRTUAL_ENV`, `PYTHONHOME`.
- Command lines of python, `whatap_python` and odoo processes and of pid 1: an argument
  such as `--db_password=...` appears as given.
- The installed-distribution names (package names and versions), and the
  `pip list` output.
- `odoo.conf` verbatim except those two lines; the tail of the odoo `logfile`.
- `whatap-hook.log` and `whatap-boot-*.log` heads and tails, and
  `systemctl cat 'odoo*'` (an `Environment=` line can carry a secret).
- The collector's own environment: `WHATAP_PYTHON_AGENT_PATH`, `POD_NAME`,
  `NODE_NAME`, `POD_NAMESPACE`, `OKIND`, `ONAME`, `ONODE`.

## Load profile

Tier 0 only: read-only, bounded reads (`tail -n`, line-capped dumps, capped
process/interpreter detail: 20 `whatap_python` processes, 20 python processes, 8
interpreters), every external command capped at 15 s and the whole run at
`RUN_DEADLINE` (300 s). Each detailed interpreter is started once for all twelve lookups
and once more for `-m pip list` (a default run takes about 7 s with 8 detailed
interpreters). The kernel and machine come from one `uname -srm`.

## Validate

```sh
tools/validate.sh collectors/apm/python/collect-apmpython.sh
```
