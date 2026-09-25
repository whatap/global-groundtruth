# collectors/apm/python — WhaTap Python APM agent collector

> **Status: SEEDED (v0).** `collect-apmpython.sh` is a working Tier-0
> collector seeded by the Global team (CONTRACT rule 4 — interim ownership).
> Ongoing ownership belongs to the Python agent developers once handed over.

Collects the hidden facts a remote WhaTap Python-agent developer repeatedly
asks a field engineer for. The fact list was derived from an exhaustive review
of `#ask-dev-apm` Python support threads (2025-02 .. 2026-07) and verified
against the `whatap-python` package source (2.1.2).

## One field command

Run **where the Python application runs**:

```sh
# VM / bare metal
./collect-apmpython.sh --file          # -> whatap-apmpython-<host>-<UTC>.txt

# Kubernetes — pipe the script over stdin; nothing to copy into the pod,
# nothing written to a possibly read-only rootfs
kubectl exec -i <pod> -c <container> -- sh -s -- --stdout --quiet \
    < collect-apmpython.sh > report.txt

# Docker
docker exec -i <container> sh -s -- --stdout --quiet \
    < collect-apmpython.sh > report.txt
```

Paste or attach the entire output. No arguments prints usage; nothing runs by
accident. Progress is narrated on stderr (`--quiet` silences it).

Container notes (all verified against real images):

- **POSIX sh is enough.** The script runs under bash, dash, and busybox ash
  (`alpine`, `python:*-slim` — no bash/ss/procps required; socket facts fall
  back to raw `/proc/net/udp|tcp`).
- **Use `--stdout` in containers.** `--file` writes to the current directory,
  which fails on `readOnlyRootFilesystem` pods.
- **Distroless / no shell in the app container**: attach an ephemeral debug
  container sharing the pod's process namespace
  (`kubectl debug <pod> -it --image=busybox:stable --target=<container> -- sh`)
  and run the collector there. Agent homes and package dirs that are not
  visible in the debug container's own mount namespace are read through
  `/proc/<pid>/root/...` of the discovered agent/app processes, and the
  whatap-python version is read from package metadata files without executing
  any interpreter.

## Facts collected (report sections)

| # | Section | Answers the recurring question |
| --- | --- | --- |
| 1 | Collection environment | which tools were available to this collection |
| 2 | Host / platform | OS, arch (amd64/arm64), container markers, cgroup CPU/memory limits (container-vs-host metric questions) |
| 3 | Python runtimes and whatap-python package | every interpreter (those of whatap-marked processes first, so the detail cap of 8 does not fill with unrelated ones) (multiple versions and **virtualenvs are kept distinct** — identity is the invocation path, not the resolved binary), whatap-python version/location per interpreter, the `whatap_python-*` metadata dirs next to the package (`.dist-info` = wheel install, `.egg-info`/`.egg` = setup.py-era install), `sys.prefix` / `base_prefix` (they differ inside a virtualenv), setuptools / `pkg_resources` import facts (Python 3.12 install issues), bundled Go module binaries per arch, `bootstrap/sitecustomize.py`, console scripts on PATH, **application library inventory** — `pip list` per interpreter (a missing pip module or a failing pip is reported with its error, not as empty output), plus a no-pip/no-exec fallback (dist-info/egg-info dir names per environment), plus the **instrumentation surface of the installed agent** (`trace/mod` tree, grouped: application/database/httpc/amqp/...) which differs across agent versions |
| 4 | Runtime processes | Go common module (`whatap_python`) processes with cwd/env; python app processes (matched by comm, argv0 or `/proc/<pid>/exe`, see below; whatap-marked ones first) with argv0, `PYTHONPATH contains whatap/bootstrap`, `VIRTUAL_ENV`, `WHATAP_*`, `OTEL_*` (co-instrumentation); **libraries the process actually loaded** — C-extension packages and the real `site-packages` path from `/proc/<pid>/maps` (pure-Python imports do not appear there) |
| 5 | Agent homes and configuration | every `WHATAP_HOME` candidate (env, port registry `/tmp/whatap-python.lock`, process cwd/environ, `/whatap-agent`), and per home: `whatap.conf` / `container.conf` verbatim, `whatap_python` symlink resolution, pid-file liveness, `security.conf` / `paramkey.txt` presence and size, `logs/` inventory, `run/`, LLM module dir. A home that cannot be read says `path not found` or `permission denied` |
| 6 | Network endpoints and port registry | UDP sockets on 66xx plus the `net_udp_port` of the readable `whatap.conf` files and the port registry, TCP sessions on 6600 plus the `whatap.server.port` named there (each port labelled by its source), plus every socket of a whatap-named process; port registry contents |
| 7 | Agent logs | `whatap-hook.log` head (banner + `successfully injected <module>` lines = which libraries the agent hooked in this process) and tail (recent), the newest `whatap-boot-YYYYMMDD.log` (Go side) head + tail — all bounded reads |
| 8 | Odoo application facts | odoo master/worker processes, Odoo version (`odoo/release.py`, read as text — no odoo code runs), `odoo.conf` (path from `-c`/`ODOO_RC`/packaged defaults; see "What the report can contain" below) with the `logfile` key resolved and the worker log tailed (with `logfile` unset, odoo writes to the process stdout/stderr, e.g. the container log) (the HTTP-worker traceback lives there, not in the master/startup log), listening sockets (8069/8072), systemd unit facts (`Environment=`/`ExecStart` visibility for `whatap-start-agent` PATH issues), `injected odoo` hook-evidence counts. Cheap no-op on non-Odoo hosts. Interpretation aid: the agent's Odoo support matrix (14–19 from agent 2.1.3; JSON-RPC errors return HTTP 200 and are not captured; WebSocket/Longpolling/Cron not instrumented) is maintained in the internal "Odoo 지원" Notion document |
| 9 | Kubernetes / operator injection context | `/whatap-agent` volume, `WHATAP_PYTHON_AGENT_PATH` (symlink vs regular file), k8s env facts |

## How each interpreter is asked

The lookups of section 3 (version, prefixes, whatap-python version and
location, metadata dirs, setuptools, `pkg_resources`, bundled binaries,
`sitecustomize.py`, `trace/mod`) run in **one** start of each interpreter,
not one `python -c` each: every snippet runs with fresh globals, its own
stdout, stderr and exit status, and an uncaught exception is printed by the
interpreter's own `sys.excepthook`, so each line and each `n/a (...)` reads
as a separate `python -c` would have made it. The `pkg_resources` import runs
last, as it rewires namespace packages. A snippet that hangs says `timed out`;
the snippets after it, and those after one that ends the process, never
started, so each is then run on its own under its own cap, as before (past the
run deadline they say `not run: ...` instead). When the interpreter cannot run
the combined script at all, every snippet is run on its own; when the cap
stops it before any snippet started, every snippet says `timed out`, as each
`python -c` would have. The marker lines that separate the snippets are random
per run and read in order, so output that imitates one stays output. `pip list`
stays a call of its own.

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

`agent` is obtained when a visible agent home, a whatap package dir, a
whatap package found by an interpreter, or a `whatap_python` process exists.
Its absence is `na` only when every input was read. When the run cannot read
the `environ`/`cwd` of a candidate process (other users' processes as
non-root), `/proc` is mounted with `hidepid`, a home path is behind a
directory it may not search, or an interpreter's package lookup fails, the
absence is `missed` and names those pids or paths. `conf` is obtained when a
`whatap.conf` in an agent home is readable; a home whose path does not exist
gives `na` with `path not found`, a home or file the run may not read gives
`missed` with `permission denied`.

## What the report can contain

Nothing is masked, with one omission: in `odoo.conf` the `db_password` and
`admin_passwd` lines are not collected (the report says how many were left
out). That is the only content the collector leaves out. Every place a secret
can arrive from:

- `whatap.conf` and `container.conf` of every agent home, verbatim
  (`license`, server addresses, any other key the operator put there).
- The environment of python and `whatap_python` processes: every `WHATAP_*`
  and `OTEL_*` variable (OTLP headers can carry tokens), `PYTHONPATH`,
  `VIRTUAL_ENV`, `PYTHONHOME`.
- Command lines of python, `whatap_python` and odoo processes and of pid 1
  (first 300 characters): an argument such as `--db_password=...` appears as
  given.
- `pip list` output and the installed-distribution names (package names only).
- `odoo.conf`, verbatim, **except** the `db_password` and `admin_passwd` lines,
  which are not collected (the report states how many were left out); the tail
  of the odoo `logfile`.
- `whatap-hook.log` and `whatap-boot-*.log` heads and tails, and
  `systemctl cat 'odoo*'` (an `Environment=` line can carry a secret).
- The collector's own environment: `WHATAP_PYTHON_AGENT_PATH`, `POD_NAME`,
  `NODE_NAME`, `POD_NAMESPACE`, `OKIND`, `ONAME`, `ONODE`.

`security.conf` and `paramkey.txt` in an agent home are reported by presence
and size only; their content is not collected.

The collector itself puts no credential on a command line.

## Load profile

Tier 0 only: read-only, bounded reads (`tail -n`, line-capped dumps, capped
process/interpreter detail), every external command capped at 15 s and the
whole run at `RUN_DEADLINE` (300 s). No `--bundle` tier yet;
copy the bundle plumbing from `collect-collserver.sh` if the domain team
needs raw log artifacts.

## Validate

```sh
tools/validate.sh collectors/apm/python/collect-apmpython.sh
```
