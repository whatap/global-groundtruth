# collectors/apm/php: WhaTap PHP APM agent collector

> **Status:** `collect-apmphp.sh` 0.8.2 validated at 2026-09-28 on the lab targets
> `apm-php-rocky` / `apm-php-alpine` (real whatap-php 2.14-2 rpm on Rocky 9 with PHP 8.2
> php-fpm + nginx under systemd, and the Alpine tarball on `php:8.3-fpm-alpine`; web user
> and root without CAP_SYS_PTRACE, `sh -s`, `bash -s`, file), `validate.sh --report`
> pass; no collection server was reachable. Tier 0, seeded by the Global team; ownership
> passes to the PHP agent developers (CONTRACT rule 4).

Collects the hidden facts a remote WhaTap PHP-agent developer repeatedly asks a
field engineer for. The fact list comes from a review of `#ask-dev-apm` PHP support
threads (2025-06 .. 2026-08), checked against the shipped package itself: the RPM
(`whatap-php-2.14-2.x86_64`) and the Alpine tarball (`install.sh`, the `whatap-php`
service wrapper, `whatap-php.service`, `template.ini`, `modules/`, the `whatap_php`
Go binary and the `whatap*.so` tracer modules).

**Why the two halves are the first fact.** The PHP agent is installed as two
separate things, configured by one installer run:

| | tracer (`whatap.so`) | agent (`whatap_php`) |
|---|---|---|
| what it is | Zend extension loaded into every Apache / PHP-FPM / CLI worker | Go process (`whatap_php`, or `whatap_php_static` on musl/Alpine) |
| built per | PHP API version + thread safety: `whatap[_zts]_<API>.so`, one file per PHP 5.2 … 8.5 | one binary per libc |
| bound by | `extension=whatap.so` in an ini file, and a symlink `<extension_dir>/whatap.so` → `modules/<arch>/whatap[_zts]_<API>.so` | `whatap-php` wrapper / `whatap-php.service` / `/etc/init.d/whatap-php`, started with `-t=4` |
| configured by | `whatap.*` directives PHP parses at startup | the **same ini file**, located through `WHATAP_CONFIG_HOME` + `WHATAP_CONFIG` in its service file |
| channel | UDP to `127.0.0.1:<whatap.net_udp_port>` (default 6600) + SysV shared memory/semaphore (key 6600 = `0x19c8`) | TCP 6600 to the collection server |
| logs to | the web server error log (`WA…`-coded lines) | `<home>/logs/whatap-boot-YYYYMMDD.log` |

`install.sh` resolves the environment **once** (php binary → PHP API, thread
safety, `extension_dir`, ini scan dir) and writes what it found into every
service file it can find; `logs/whatap-install-YYYYMMDD.log` records that run.
Most support cases are a mismatch between what it resolved then and what runs
now, so the collector reports both sides and lets the reader compare:

- the running PHP's `PHP API` / `Thread Safety` vs the API and `_zts` marker in the
  module filename the `whatap.so` symlink resolves to;
- the ini tree the installer wrote into vs the ini trees each SAPI reads (`cli`, `fpm`
  and `apache2` trees are separate);
- what is configured on disk vs what is **actually mapped** into the live workers
  (`/proc/<pid>/maps`);
- the `WHATAP_CONFIG_HOME` in the unit/init file vs the `WHATAP_*` environment the
  running `whatap_php` has (started without it, the agent logs
  `[WA212] Not found config file, and not exists accesskey`, while the tracer keeps
  reading the ini it was given).

**Several PHP versions on one host is the normal case.** `install.sh` binds the tracer
to exactly one of them, the one its `php` lookup resolved to, and each version has its
own `extension_dir`, ini scan dir and often FPM service. Section `[3]` prints each
runtime's own `php -i` lines (`PHP API`, `Thread Safety`, `extension_dir`, the scan dir
and ini files parsed, its `whatap.*` directives) and section `[6]` prints `whatap.so`
once per `extension_dir` (ls, sha256, symlink target, the file it resolves to), so the
split is read by matching the two. The collector does not decode the module name or
rebuild a per-runtime table. `php -v` in a shell is frequently a different version from
the one serving traffic, so the `php` / `php-fpm` on PATH and the `update-alternatives`
entries are printed too. `php-cgi -i` prints phpinfo() as HTML; its table rows are read
as the `name => value` lines the CLI prints.

## One field command

Run **where the PHP application runs**:

```sh
# VM / bare metal (as root, or as the web server user)
./collect-apmphp.sh --file          # -> whatap-apmphp-<host>-<UTC>.txt

# Kubernetes: pipe the script over stdin; nothing to copy into the pod,
# nothing written to a possibly read-only rootfs
kubectl exec -i <pod> -c <container> -- bash -s -- --stdout --quiet \
    < collect-apmphp.sh > report.txt

# Docker
docker exec -i <container> bash -s -- --stdout --quiet \
    < collect-apmphp.sh > report.txt
```

Paste or attach the entire output; container and Kubernetes delivery notes are in
[../README.md](../README.md), "Running a Linux apm collector". **Run it as root where
possible.** `/proc/<pid>/maps` and `/proc/<pid>/environ` of the web server workers prove
the tracer is loaded and which configuration the agent really has; unreadable ones are
reported as `permission denied` with their pids, and when nothing else shows an
installation they make the status INCOMPLETE (see "Collection status").

## Facts collected (report sections)

| # | Section | Answers the recurring question |
| --- | --- | --- |
| 1 | Collection environment | which tools were available to this collection |
| 2 | Host / platform | OS, kernel, arch, **libc** (glibc vs musl decides `whatap_php` vs `whatap_php_static`), `ls -l` of `/sys/class/dmi/id/product_uuid` and whether this run could read it (the value only when it could; see [../README.md](../README.md)), cgroup limits, container markers, clock (agent time-sync questions) |
| 3 | PHP runtimes and SAPIs | every php / php-fpm / php-cgi binary found (PATH, per-version install paths of every common layout, running processes, detail cap 10): version, **SAPI**, **PHP API**, **Thread Safety**, build strings, `extension_dir`, the ini paths it parses, opcache/JIT settings, the **`whatap.*` directives as that binary actually resolves them (local => master)**, the loaded module list (`php -m`: co-resident APM/profiler extensions such as newrelic, ddtrace, opentelemetry, xdebug are read there), what `php`/`php-fpm` on PATH resolve to, and the `update-alternatives` entries |
| 4 | Web server / application server layer | Apache binary + `-V` (**MPM prefork/worker/event**: decides whether a `_zts` module is required) and its php/mpm modules; php-fpm version, config and pool files; **per-version FPM systemd units**; nginx; every web/php process (matched by comm, argv0 or `/proc/<pid>/exe`, so a script started from `#!/usr/bin/php` and `lsphp` count) with cmdline, exe and uid; **persistent-worker runtimes** (Swoole/Laravel Octane, RoadRunner, FrankenPHP, Workerman, php-pm) whose request cycle is not the per-request PHP model the tracer hooks, so per-request extension hooks do not bound it the same way. They are matched on the executable (`frankenphp`, `rr`, `roadrunner`), or on the command line of a PHP executable (`octane`, `swoole`, `workerman`, `php-pm`, `artisan queue|horizon`), an editor or `tail` naming swoole is not one |
| 5 | WhaTap PHP agent installation on disk | agent home candidates and their source; home listing; `whatap_php` / `whatap_php_static` with size, mtime and **sha256**; `whatap_php version` (`ver <x.y.z.date>, buildno <commit>`); ChangeLog head (shipped version); `template.ini`; `install.sh` (ls, sha256, its `get_php_api_version()` holds the PHP-version → PHP API table the installer used; read it in the package of that sha256); the shipped tracer module inventory per arch; package manager records (rpm/dpkg/apk, the Alpine tarball leaves none by design) |
| 6 | Tracer binding | **`whatap.so` once per `extension_dir` seen** (a runtime's `php -i` or `WHATAP_PHP_EXT_HOME` in a service file; the first source is named): its `ls -l`, **sha256**, symlink target, the file it resolves to and that file's `ls -lL` (size, mtime); every whatap ini found on disk (ls -l); `php.ini` files carrying whatap lines (the installer's fallback when PHP reports no scan dir); the ini directories present: the known tree paths and every absolute scan dir a runtime's `php -i` named (one line per entry of a colon-separated `PHP_INI_SCAN_DIR`, read through a process root when not visible here; a relative entry is resolved against the cwd of a live process of that binary; when none can be read it is listed as `n/a (relative scan dir of <bin>, not resolved)`), with the whatap entries each holds; **live load status from `/proc/<pid>/maps`**, with the pids whose maps could not be read. Which runtime uses which dir, its PHP API and thread safety, whether its `whatap.*` directives are registered and any "Unable to load dynamic library" line are the `php -i` / `php -v` lines of `[3]` |
| 7 | Agent configuration (verbatim) | every `whatap.ini` dumped verbatim **plus byte facts (size, CR 0x0D count, Windows-edited ini files are a recurring support case)**; the service/unit/init files verbatim (they carry `WHATAP_CONFIG_HOME`, `WHATAP_PHP_EXT_HOME`, `WHATAP_PHP_EXT_SRC`, `WHATAP_PHP_BIN` as install.sh resolved them); the `WHATAP_*` environment of the live processes; `whatap.app_process_name` and how many processes match it right now (the process-memory metric is summed over that name); `security.conf` / `paramkey.txt` of every agent home by presence and size only |
| 8 | Agent process, service state and channels | `whatap_php` processes (comm is capped at 15 chars, so the musl build shows as `whatap_php_stat`) with cmdline, cwd, uid, threads, RSS and start time; pid file vs live pid; systemd/sysv service state; UDP sockets on 66xx plus the `whatap.net_udp_port`, TCP sessions on 6600 plus the `whatap.server.port` named in the readable whatap ini files (each port labelled by its source), plus every socket of a whatap-named process; **SysV shared memory and semaphore arrays** (the tracer↔agent pair uses key `0x19c8`, which `install.sh remove` deletes with `ipcrm -S 6600 -M 6600`) |
| 9 | Agent logs and web server error markers | `logs/` inventory; newest `whatap-boot-*.log` head (banner, `[WA214] Config: <path>`, the config file the agent actually read) and tail; newest `whatap-install-*.log` (exactly what install.sh resolved on this host); the last 300 lines of each known web server / php-fpm error log scanned for `whatap` / `WA###` lines written by the tracer |
| 10 | Container / Kubernetes context | container markers, cgroup path, `container.conf` in the agent home, `POD_NAME`/`NODE_NAME`/`OKIND`/`ONODE`, k8s service account mount, container hostname |

## Collection status

Goals and their `na` / `missed` rules are those of
[../README.md](../README.md), "Agent goal". `agent` is obtained when any part of an
installation is seen: a visible agent home, a `whatap.so` in an `extension_dir`, a
whatap ini, a `php.ini` carrying whatap lines, a service/unit file, or a `whatap_php`
process. An absence is also `missed` when the run cannot read the `exe` of a
`whatap_php` process or the `/proc/<pid>/maps` of a web/php process, or a `php -i` did
not run (its ini scan dir and `extension_dir` are then unknown).

`conf` is the whatap ini that the tracer and the agent both read (section 7),
not a `whatap.conf`: obtained when a discovered whatap ini is readable or a
`php.ini` carries whatap lines, `missed` when one exists but cannot be read
or when the search had the gaps above, `na` when none exists.

## What the report can contain

The common items are in [../README.md](../README.md), "What every Linux apm report can
contain". PHP specific:

- Every whatap ini found, verbatim (`whatap.license` / `whatap.accesskey`,
  `whatap.server.host`, every other directive), and the whatap lines of each
  `php.ini`; the `whatap.*` directives as each PHP binary resolves them
  (`php -i`).
- The installer's `template.ini` in the agent home, first 60 lines.
- The service / unit / init files `install.sh` wrote, verbatim (first 120
  lines): they carry `WHATAP_CONFIG_HOME` and any `Environment=` line.
- The `WHATAP_*` environment of `whatap_php`, web and php processes.
- Command lines of web, php, persistent-worker and `whatap_php` processes: an argument
  carrying a secret appears as given.
- php-fpm `www.conf` pool settings without comments (first 60 lines):
  `env[...]` entries can carry secrets.
- The last 300 lines of each known web server / php-fpm error log, filtered to
  whatap / `WA###` lines; heads and tails of `whatap-boot-*.log` and
  `whatap-install-*.log`; `container.conf` of each agent home.
- The collector's own environment: `POD_NAME`, `NODE_NAME`, `POD_NAMESPACE`,
  `OKIND`, `ONAME`, `ONODE`.

Not collected: application source (only web server / php-fpm config files and bounded
error-log tails are read).

## Load profile

Tier 0 only: read-only, bounded reads (`head`/`tail -n`, line-capped dumps, capped
process and binary detail: 10 PHP binaries, 20 processes), every external command capped
at 15 s and the whole run at `RUN_DEADLINE` (300 s); `/proc` is read in one pass for every
pid; about 5 s on a healthy host. Processes executed: standard tools, `php -v/-m/-i`
(once each per binary, the same read-only calls the vendor installer makes; no
application code runs), `apachectl -V/-M`, `php-fpm -v` (only when section 3 did not
already run it on the file the PATH `php-fpm` resolves to), `ipcs`, and `whatap_php
version` (the agent binary is never run bare, which would start an agent).

## Validate

```sh
tools/validate.sh collectors/apm/php/collect-apmphp.sh
```
