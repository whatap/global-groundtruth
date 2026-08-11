# collectors/apm/php — WhaTap PHP APM agent collector

> **Status: SEEDED (v0.2).** `collect-apmphp.sh` is a working Tier-0 collector
> seeded by the Global team (CONTRACT rule 4 — interim ownership). Ongoing
> ownership belongs to the PHP agent developers once handed over.

Collects the hidden facts a remote WhaTap PHP-agent developer repeatedly asks a
field engineer for. The fact list was derived from an exhaustive review of
`#ask-dev-apm` PHP support threads (2025-06 .. 2026-08) and verified against the
shipped package itself — the RPM (`whatap-php-2.14-2.x86_64`) and the Alpine
tarball (`repo.whatap.io/alpine/x86_64/whatap-php.tar.gz`): `install.sh`, the
`whatap-php` service wrapper, `whatap-php.service`, `/etc/init.d/whatap-php`,
`template.ini`, `modules/`, the `whatap_php` Go binary and the `whatap*.so`
tracer modules — then exercised against three live installs, each performed
with the vendor `install.sh` (agent 2.14.2): Apache 2.4 prefork + mod_php 8.2;
Alpine musl + PHP-FPM 8.2 from the tarball; and a **multi-version** Debian host
carrying PHP 8.1 + 8.3 with the tracer bound to 8.1 only.

**Why the two halves are the first fact.** The PHP agent is installed as two
separate things, configured by one installer run:

| | tracer (`whatap.so`) | agent (`whatap_php`) |
|---|---|---|
| what it is | Zend extension loaded into every Apache / PHP-FPM / CLI worker | Go process (`whatap_php`, or `whatap_php_static` on musl/Alpine) |
| built per | PHP API version + thread safety — `whatap[_zts]_<API>.so`, one file per PHP 5.2 … 8.5 | one binary per libc |
| bound by | `extension=whatap.so` in an ini file, and a symlink `<extension_dir>/whatap.so` → `modules/<arch>/whatap[_zts]_<API>.so` | `whatap-php` wrapper / `whatap-php.service` / `/etc/init.d/whatap-php`, started with `-t=4` |
| configured by | `whatap.*` directives PHP parses at startup | the **same ini file**, located through `WHATAP_CONFIG_HOME` + `WHATAP_CONFIG` in its service file |
| channel | UDP to `127.0.0.1:<whatap.net_udp_port>` (default 6600) + SysV shared memory/semaphore (key 6600 = `0x19c8`) | TCP 6600 to the collection server |
| logs to | the web server error log (`WA…`-coded lines) | `<home>/logs/whatap-boot-YYYYMMDD.log` |

`install.sh` resolves the environment **once** (php binary → PHP API, thread
safety, `extension_dir`, ini scan dir) and writes what it found into every
service file it can find; `logs/whatap-install-YYYYMMDD.log` records that run.
Most support cases are a mismatch between what it resolved then and what runs
now, so the collector reports both sides and lets the reader compare:

- the running PHP's `PHP API` / `Thread Safety` vs the API and `_zts` marker
  encoded in the module filename the `whatap.so` symlink resolves to;
- the ini tree the installer wrote into vs the ini trees each SAPI reads
  (`cli`, `fpm` and `apache2` trees are separate — a file in one is not read by
  the others);
- what is configured on disk vs what is **actually mapped** into the live
  Apache/PHP-FPM workers (`/proc/<pid>/maps`);
- the `WHATAP_CONFIG_HOME` written into the unit/init file vs the `WHATAP_*`
  environment the running `whatap_php` actually has — started without it, the
  agent looks for `whatap.conf` and logs
  `[WA212] Not found config file, and not exists accesskey`, while the tracer
  keeps reading the ini it was given.

The collector executes the PHP binaries it finds with read-only flags only
(`-v`, `-m`, `-i`, `--ini`) — the same calls the vendor installer makes; no
application code runs. The agent binary is only ever executed with its
`version` argument (running it bare would start an agent).

**Several PHP versions on one host is the normal case.** `install.sh` binds the
tracer to exactly one of them — the one its `php` lookup resolved to — and each
version has its own `extension_dir`, its own ini scan dir, and often its own
FPM service. Section `[6]` therefore reports the binding **per runtime**, so
the split is visible at a glance:

```text
-- runtime: /usr/sbin/php-fpm8.1
   PHP 8.1.34, SAPI FPM/FastCGI, PHP API 20210902, Thread Safety disabled
   extension_dir: /usr/lib/php/20210902
   whatap.so there: ... -> /usr/whatap/php/modules/x64/whatap_20210902.so
   ini scan dir: /etc/php/8.1/fpm/conf.d
   whatap ini in that scan dir: n/a (no *whatap*.ini in /etc/php/8.1/fpm/conf.d)
   whatap.* directives registered in this runtime (module loaded at startup): no
-- runtime: /usr/bin/php8.1
   ...
   ini scan dir: /etc/php/8.1/cli/conf.d
   whatap ini in that scan dir: /etc/php/8.1/cli/conf.d/whatap.ini
   whatap.* directives registered in this runtime (module loaded at startup): yes
-- runtime: /usr/bin/php   (PHP 8.3.33, API 20230831)
   whatap.so there: n/a (path not found: /usr/lib/php/20230831/whatap.so)
```

Supporting facts for the same question: what `php` / `php-fpm` on PATH resolve
to and the `update-alternatives` entries (on a multi-version host `php -v` in a
shell is frequently a different version from the one serving traffic), the
per-version FPM units, and the module the live workers actually mapped. Binary
discovery covers the distro packages, Sury/ondrej, Remi, SCL, cPanel
EasyApache, Plesk, CloudLinux alt-php, LiteSpeed lsphp and source builds; ini
scan dirs are taken from each runtime's own `php -i` rather than from a path
list, so an unlisted layout still reports correctly.

## One field command

Run **where the PHP application runs**:

```sh
# VM / bare metal (as root, or as the web server user)
./collect-apmphp.sh --file          # -> whatap-apmphp-<host>-<UTC>.txt

# Kubernetes — pipe the script over stdin; nothing to copy into the pod,
# nothing written to a possibly read-only rootfs
kubectl exec -i <pod> -c <container> -- bash -s -- --stdout --quiet \
    < collect-apmphp.sh > report.txt

# Docker
docker exec -i <container> bash -s -- --stdout --quiet \
    < collect-apmphp.sh > report.txt
```

Paste or attach the entire output. No arguments prints usage; nothing runs by
accident. Progress is narrated on stderr (`--quiet` silences it).

Notes:

- **Run it as root where possible.** `/proc/<pid>/maps` and
  `/proc/<pid>/environ` of the web server workers are what prove the tracer is
  loaded and which configuration the agent really has; unreadable ones are
  reported as `permission denied`, not silently skipped.
- **Use `--stdout` in containers.** `--file` writes to the current directory,
  which fails on `readOnlyRootFilesystem` pods.
- Paths that are not visible in the collector's own mount namespace (ephemeral
  debug container) are read through `/proc/<pid>/root/...` of the discovered
  agent/web processes.

## Facts collected (report sections)

| # | Section | Answers the recurring question |
| --- | --- | --- |
| 1 | Collection environment | which tools were available to this collection |
| 2 | Host / platform | OS, kernel, arch, **libc** (glibc vs musl decides `whatap_php` vs `whatap_php_static`), cgroup limits, container markers, clock (agent time-sync questions) |
| 3 | PHP runtimes and SAPIs | every php / php-fpm / php-cgi binary found (PATH, per-version install paths of every common layout, running processes — detail cap 10): version, **SAPI**, **PHP API**, **Thread Safety**, build strings, `extension_dir`, the ini paths it parses, opcache/JIT settings, the **`whatap.*` directives as that binary actually resolves them (local => master)**, the loaded module list; plus **other APM/profiler extensions** present (newrelic, ddtrace, elastic, opentelemetry, tideways, blackfire, xdebug, …), what `php`/`php-fpm` on PATH resolve to, and the `update-alternatives` entries |
| 4 | Web server / application server layer | Apache binary + `-V` (**MPM prefork/worker/event** — decides whether a `_zts` module is required) and its php/mpm modules; php-fpm version, config and pool files; **per-version FPM systemd units**; nginx; every web/php process with cmdline, exe and uid; **persistent-worker runtimes** (Swoole/Laravel Octane, RoadRunner, FrankenPHP, Workerman, php-pm) whose request cycle is not the per-request PHP model the tracer hooks |
| 5 | WhaTap PHP agent installation on disk | agent home candidates and their source; home listing; `whatap_php` / `whatap_php_static` with size, mtime and **sha256**; `whatap_php version` (`ver <x.y.z.date>, buildno <commit>`); ChangeLog head (shipped version); `template.ini`; the **PHP-version → PHP API table read out of the installed `install.sh`**; the shipped tracer module inventory per arch; package manager records (rpm/dpkg/apk — the Alpine tarball leaves none by design) |
| 6 | Tracer binding per PHP runtime | **one block per runtime found in `[3]`**: its `extension_dir` and whether `whatap.so` is there with its **symlink target decoded** (thread-safe build yes/no, PHP API), its ini scan dir and whether a whatap ini sits in it, whether the `whatap.*` directives are registered in that runtime (i.e. the module loaded at startup), and any dynamic-library load message. Then: every `extension_dir` seen with its source and whether a runtime reported it (a dir only the service files name belongs to a PHP install no longer present); every `whatap.ini` found on disk; `php.ini` files carrying whatap lines (the installer's fallback when PHP reports no scan dir); which ini trees exist and whether each holds a whatap entry; **live load status from `/proc/<pid>/maps`** |
| 7 | Agent configuration (verbatim) | every `whatap.ini` dumped verbatim **plus byte facts (size, CR 0x0D count — Windows-edited ini files are a recurring support case)**; the service/unit/init files verbatim (they carry `WHATAP_CONFIG_HOME`, `WHATAP_PHP_EXT_HOME`, `WHATAP_PHP_EXT_SRC`, `WHATAP_PHP_BIN` as install.sh resolved them); the `WHATAP_*` environment of the live processes; `whatap.app_process_name` and how many processes match it right now (the process-memory metric is summed over that name); key-material files by presence only |
| 8 | Agent process, service state and channels | `whatap_php` processes (comm is capped at 15 chars, so the musl build shows as `whatap_php_stat`) with cmdline, cwd, uid, threads, RSS and start time; pid file vs live pid; systemd/sysv service state; UDP sockets on 66xx and TCP sessions toward :6600; **SysV shared memory and semaphore arrays** (the tracer↔agent pair uses key `0x19c8`, which `install.sh remove` deletes with `ipcrm -S 6600 -M 6600`) |
| 9 | Agent logs and web server error markers | `logs/` inventory; newest `whatap-boot-*.log` head (banner, `[WA214] Config: <path>` — the config file the agent actually read) and tail; newest `whatap-install-*.log` (exactly what install.sh resolved on this host); the last 300 lines of each known web server / php-fpm error log scanned for `whatap` / `WA###` lines written by the tracer |
| 10 | Container / Kubernetes context | container markers, cgroup path, `container.conf` in the agent home, `POD_NAME`/`NODE_NAME`/`OKIND`/`ONODE`, k8s service account mount, container hostname |

## Security note

Framework policy: WhaTap configuration is dumped **verbatim, never masked** —
`whatap.ini` (including `whatap.accesskey` and `whatap.server.host`), the
service/unit files, and the `WHATAP_*` environment of running processes. A
mistyped access key or server address must be readable to be verified or
refuted against the other side. Handle the report accordingly.

Data-scope exceptions (not masking — the content is never collected):

- `security.conf` / `paramkey.txt` in the agent home hold encryption key
  material; the report states presence, size and mtime only.
- Application source is never read; only web server / php-fpm **config** files
  and bounded tails of their error logs.

## Load profile

Tier 0 only: read-only, bounded reads (`head`/`tail -n`, line-capped dumps,
capped process and binary detail: 10 PHP binaries, 20 processes), per-probe
timeout 15s; ~5 s on a healthy host. Processes executed: standard tools,
`php -v/-m/-i`, `apachectl -V/-M`, `php-fpm -v`, `ipcs`, and
`whatap_php version`. No `--bundle` tier yet; copy the bundle plumbing from
`collect-collserver.sh` if the domain team needs raw log artifacts.

## Validate

```sh
tools/validate.sh collectors/apm/php/collect-apmphp.sh
```
