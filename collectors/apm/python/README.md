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
| 3 | Python runtimes and whatap-python package | every interpreter (multiple versions and **virtualenvs are kept distinct** — identity is the invocation path, not the resolved binary), whatap-python version/location per interpreter, wheel(dist-info) vs legacy egg install, setuptools / `pkg_resources` import facts (Python 3.12 install issues), bundled Go module binaries per arch, `bootstrap/sitecustomize.py`, console scripts on PATH, **application library inventory** — `pip list` per interpreter, plus a no-pip/no-exec fallback (dist-info/egg-info dir names per environment), plus the **instrumentation surface of the installed agent** (`trace/mod` tree, grouped: application/database/httpc/amqp/...) which differs across agent versions |
| 4 | Runtime processes | Go common module (`whatap_python`) processes with cwd/env; python app processes with argv0, `PYTHONPATH contains whatap/bootstrap`, `VIRTUAL_ENV`, `WHATAP_*`, `OTEL_*` (co-instrumentation); **libraries the process actually loaded** — C-extension packages and the real `site-packages` path from `/proc/<pid>/maps` (pure-Python imports do not appear there) |
| 5 | Agent homes and configuration | every `WHATAP_HOME` candidate (env, port registry `/tmp/whatap-python.lock`, process cwd/environ, `/whatap-agent`), and per home: `whatap.conf` / `container.conf` verbatim, `whatap_python` symlink resolution, pid-file liveness, `logs/` inventory, `run/`, LLM module dir |
| 6 | Network endpoints and port registry | UDP sockets (net_udp_port), TCP sessions toward :6600, port registry contents |
| 7 | Agent logs | `whatap-hook.log` head (banner + `successfully injected <module>` lines = which libraries the agent hooked in this process) and tail (recent), the newest `whatap-boot-YYYYMMDD.log` (Go side) head + tail — all bounded reads |
| 8 | Kubernetes / operator injection context | `/whatap-agent` volume, `WHATAP_PYTHON_AGENT_PATH` (symlink vs regular file), k8s env facts |

## Security note

Framework policy: configuration files (`whatap.conf`, `container.conf`) are
dumped **verbatim, never masked** — a mistyped license or server address must
be readable to be verified or refuted. `OTEL_*` variables of app processes
are also reported verbatim. Handle the report accordingly.

## Load profile

Tier 0 only: read-only, bounded reads (`tail -n`, line-capped dumps, capped
process/interpreter detail), per-probe timeout 15s. No `--bundle` tier yet;
copy the bundle plumbing from `collect-collserver.sh` if the domain team
needs raw log artifacts.

## Validate

```sh
tools/validate.sh collectors/apm/python/collect-apmpython.sh
```
