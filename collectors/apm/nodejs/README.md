# collectors/apm/nodejs: WhaTap Node.js APM agent collector

> **Status:** validated at `collect-apmnodejs.sh` 0.9.4 on 2026-09-28, lab `apm-nodejs`
> / `apm-nodejs-op` containers (real `whatap` npm agent 2.0.6 and the operator
> `apm-init-nodejs` copy; as root, as the app user and as another user, bash and `sh
> -s`; `validate.sh --report` pass).
> Not yet run on: an environment with a reachable collection server (no TCP session to
> :6600 seen). Owner: Global team until handover to the Node.js agent developers
> (CONTRACT rule 4).

Collects the hidden facts a remote WhaTap Node.js-agent developer repeatedly
asks a field engineer for. The fact list comes from a review of `#ask-dev-apm`
Node.js support threads (2025-06 .. 2026-08), checked against the `whatap` npm
package source (2.0.6 latest and 0.5.27 legacy), docs.whatap.io and the operator
`apm-init-nodejs` image (1.0.1).

**Why the agent generation is the first fact.** The two shipping lines have
different architectures, so the artifacts that *can* exist differ:

| | 0.5.x (legacy) | 1.x / 2.x (latest) |
|---|---|---|
| processes | app process only | app + `whatap_nodejs` master agent (spawned per home, daemonized on VMs, foreground in containers) |
| transport | app → collection server, direct TCP 6600 | app → master agent, connected UDP `127.0.0.1:<net_udp_port>` (default 6600, LLM base+100); master → server TCP 6600 |
| home artifacts | `whatap.conf`, `logs/whatap-YYYYMMDD.log` | + `whatap_nodejs` (symlink/copy), `agent-<id8>.pid`, `agent-<id8>.lock`, `whatap_nodejs.pid[.llm]`, `whatap_port_<pid>`, `run/`, `logs/whatap-hook-YYYYMMDD.log`, `logs/whatap-boot-*.log`, port registry `/tmp/whatap-nodejs.lock` |
| node engines | >= 16.4.0 | >= 17 |

The collector never loads the `whatap` module (a `require('whatap')` starts an
agent); package facts are read as text and the node binary is only ever
executed as `node --version`.

**"Install is healthy but no transactions/hitmap" cases** are answered by
reading three sections against each other: `[3]` what the installed agent
*can* hook (its bundled `lib/observers` list, differs per version), `[8]`
what the app *declares and has installed* (`package.json` dependencies,
`node_modules` names), and `[7]` what *actually engaged in this process*
(hook-log `XxxObserver starting!` / `unable to load <module>` lines). Whether
a gap between the three explains the missing data is the reader's judgment;
the report carries the facts for it.

## One field command

Run **where the Node.js application runs**:

```sh
# VM / bare metal
./collect-apmnodejs.sh --file          # -> whatap-apmnodejs-<host>-<UTC>.txt

# Kubernetes: pipe the script over stdin; nothing to copy into the pod,
# nothing written to a possibly read-only rootfs
kubectl exec -i <pod> -c <container> -- sh -s -- --stdout --quiet \
    < collect-apmnodejs.sh > report.txt

# Docker
docker exec -i <container> sh -s -- --stdout --quiet \
    < collect-apmnodejs.sh > report.txt
```

Paste or attach the entire output; container and Kubernetes delivery notes are in
[../README.md](../README.md), "Running a Linux apm collector". POSIX sh is enough
(verified under bash 5, dash and busybox ash).

## Facts collected (report sections)

| # | Section | Answers the recurring question |
| --- | --- | --- |
| 1 | Collection environment | which tools were available to this collection |
| 2 | Host / platform | OS, arch, `ls -l` of `/sys/class/dmi/id/product_uuid` and whether this run could read it (the value only when it could; see [../README.md](../README.md)), container markers (they decide daemon-vs-foreground master agent), cgroup CPU/memory limits (the agent reports host-view CPU from the Node `os` module, so container-vs-host metric questions need these) |
| 3 | Node.js runtimes and whatap package installs | every node binary with `--version`; every `whatap` install found via process cwds (pnpm symlinks resolved), NODE_PATH, `npm root -g` (run once), `<prefix>/lib/node_modules` of each node binary (found without npm), `/whatap-agent`, per install: package.json `version`/`releaseDate`/`engines` (the 0.5.x-vs-2.x fork), `build.txt` (master-agent build id), bundled `agent/<os>/<arch>/whatap_nodejs` binaries (none on the 0.5.x line, which has no master agent), **instrumentation surface** (`lib/observers` list, differs per version), conf template, `paramkey.txt` presence |
| 4 | Runtime processes | `whatap_nodejs` master agents (none on the 0.5.x line; 1.x/2.x spawn one per agent home) with cmdline (`-t 2 -d 1`, `--llm`), cwd, and env (`NODEJS_PARENT_APP_PID` links master → app; `APP_IDENTIFIER` is the `<id8>` in file names); node processes (matched by comm, argv0 or `/proc/<pid>/exe`, since pm2 and next-server rename the process title; whatap-marked ones detailed first) with `-r/--require` detection, `NODE_OPTIONS`/`WHATAP_*`/`POD_NAME`/PM2 env, and `cwd/node_modules/whatap` resolution; for each whatap-marked process, the **installed versions** of express, next, @nestjs/core, koa, fastify and whatap (see "Installed package versions" below) |
| 5 | Agent homes and configuration | every WHATAP_HOME candidate (env, port registry, process cwd/environ, `/whatap-agent`), and per home: `whatap.conf` verbatim **plus byte facts (size, CR 0x0D count, Windows-edited conf files are a recurring support case)**, alternate `WHATAP_CONF` names, `container.conf` (written by the k8s node agent), `whatap_nodejs` symlink resolution, pid-file liveness (`agent-<id8>.pid` vs legacy `whatap_nodejs.pid`, they differ by design after daemonization), lock files, `whatap_port_<pid>`, `run/`, `security.conf` / `paramkey.txt` presence and size, `logs/` inventory. A home that cannot be read says `path not found` or `permission denied` |
| 6 | Network endpoints and port registry | UDP sockets **including connected peers** (the 2.x app holds a connected UDP socket to `127.0.0.1:<net_udp_port>`, visible in `ss -uanp`) on 66xx/67xx plus the `net_udp_port` named in the readable conf files, that port + 100 (the LLM channel) and the ports in the registry, TCP sessions on 6600 plus the `whatap.server.port` / `whatap_server_port` named there (each port labelled by its source), plus every socket of a whatap- or node-named process; without `ss`/`netstat`, the raw `/proc/net/udp|tcp` tables (ports in hex, 6600 = `19C8`); `/tmp/whatap-nodejs.lock` contents (format: `udp-port<TAB>home:app-identifier`) |
| 7 | Agent logs | newest hook log (`*-hook-*.log`, 2.x) head+tail, **observer lines** (`XxxObserver starting!` / `unable to load <module>`, which hooks engaged, or could not engage, in this process), a `[WHATAP-*]` code frequency count, legacy `whatap-YYYYMMDD.log` (0.5.x), rotation-off `whatap.log`, master-agent `whatap-boot-*.log` head+tail with a `[WA*]` code count, reqlog presence, all bounded reads. The startup banner goes to the **app's stdout**, not to these files |
| 8 | Application and launcher facts | how the app is started decides how the agent attaches: pm2 daemon + its launcher config `ecosystem.config.*`, app `package.json` (name, whatap lines, scripts block, **dependencies block**), **`node_modules` top-level package names** (what the app actually has installed), Next.js `next.config.*` (`serverExternalPackages`) and `instrumentation.*` whatap lines, `.next`/standalone markers, pnpm store entries |
| 9 | Kubernetes / operator injection context | `/whatap-agent` volume as seeded by `apm-init-nodejs` (incl. the arch-resolved stable path `node_modules/whatap/agent/whatap_nodejs`), `WHATAP_NODEJS_AGENT_PATH` (symlink vs regular file), `POD_NAME`/`NODE_NAME`/`NODE_IP`/`WHATAP_OKIND`/`WHATAP_MICRO_ENABLED`, k8s markers |

## Installed package versions

The app `package.json` gives declared ranges (`"express": "^4.18.0"`); whether an
environment is in the supported range is decided by what is installed. For each
whatap-marked node process section 4 prints the `"version"` of express, next,
@nestjs/core, koa, fastify and whatap as `pkg: version (path)`, looked up from the
process cwd and each parent `node_modules`, then the process `NODE_PATH` entries
(`via NODE_PATH`). Only the top-level `"version"` string counts, so
`scripts.version` never stands in for it. A directory this uid cannot search is
named `permission denied`. When the process is in another mount namespace, the
files are read through `/proc/<pid>/root` and the printed path carries that prefix.

This is the order node uses for a module preloaded with `-r whatap` /
`NODE_OPTIONS=-r whatap`, which is resolved from the cwd, so the `whatap`
line names the package that preload loads. It can differ from the agent
installs listed in section 3: in the operator image `/app` has no
`node_modules/whatap`, and the line reads 2.0.3 from
`/whatap-agent/node_modules/whatap` via NODE_PATH, the same path
`require.resolve('whatap')` gives from `/app`. A `require()` in application
code resolves from the requiring file's directory instead, and node's other
fallbacks (`$HOME/.node_modules`, `$HOME/.node_libraries`, `<prefix>/lib/node`)
are not visited; for a process whose main script lives outside its cwd the
lines show the cwd's view. A loaded JavaScript file does not appear in
`/proc/<pid>/maps`, so the report does not show which file a running process
actually loaded.

## Collection status

Goals and their `na` / `missed` rules are those of
[../README.md](../README.md), "Agent goal". `agent` is obtained when a visible agent
home, a whatap package dir or a `whatap_nodejs` process exists; `npm root -g` giving
nothing also makes an absence `missed`. `conf` looks at every file name section 5
dumps (`whatap.conf` and each `WHATAP_CONF` value): obtained when one is readable,
`na` with `path not found` when none exists, `missed` with `permission denied` when
one exists but cannot be read.

## What the report can contain

The common items are in [../README.md](../README.md), "What every Linux apm report
can contain". Node.js specific:

- `whatap.conf`, the `WHATAP_CONF`-named conf files and `container.conf` of
  every agent home, verbatim (`license`, server addresses, any other key).
- The environment of node and `whatap_nodejs` processes: every `WHATAP_*`
  variable (the agent reads every conf key from a same-named variable too),
  `NODE_OPTIONS`, `NODE_PATH`, `NODE_ENV`, `APP_NAME`, `PM2_*`, `pm_id`,
  `name`, `instances`, `POD_NAME`, `NODE_NAME`, `NODE_IP`.
- Command lines of node, `whatap_nodejs` and pm2 processes and of pid 1
  (first 160-300 bytes, NULs, newlines and CRs as spaces).
- `ecosystem.config.js` / `.cjs` / `.json` / `ecosystem.json` of each app root,
  **verbatim**, first 120 lines: pm2 files commonly carry `env` blocks with
  database passwords and API keys.
- From the app `package.json`: `name`, every line naming whatap, the `scripts`
  block and the `dependencies` block (first 60 lines).
- Lines of `next.config.*` naming whatap / `serverExternalPackages` /
  `transpilePackages` / `externals`, and lines of `instrumentation.*` naming
  whatap / `register` / `NEXT_RUNTIME`.
- `node_modules` top-level and scoped package names, and the `version` of
  express, next, @nestjs/core, koa, fastify and whatap with their paths.
- Heads and tails of the hook, agent, boot and rotation-off logs.
- The collector's own environment: `WHATAP_NODEJS_AGENT_PATH`, `WHATAP_LICENSE`,
  `WHATAP_HOST`, `WHATAP_PORT`, `POD_NAME`, `NODE_NAME`, `NODE_IP`,
  `WHATAP_OKIND`, `WHATAP_ONODE`, `WHATAP_MICRO_ENABLED`, `APP_NAME`,
  `APP_PROCESS_NAME`.

## Load profile

Tier 0 only: read-only, bounded reads (`head`/`tail -n`, line-capped dumps, capped
process/binary detail), every external command capped at 15 s and the whole run at
`RUN_DEADLINE` (300 s); `/proc` is read in one pass for every pid (about 7 s on a
714-process host with 163 node processes). The only processes executed are standard
tools plus `node --version` and one `npm root -g`. The npm and pm2 versions are read
as text from the `package.json` of the package each command resolves to (the report
line names the file); `npm --version` / `pm2 --version` run only when no such file
gives the version. The whatap module is never loaded: every node this run starts
runs without `NODE_OPTIONS` (the operator injects `-r whatap`); `[1]` says whether
it was removed and whether it named whatap.

## Validate

```sh
tools/validate.sh collectors/apm/nodejs/collect-apmnodejs.sh
```
