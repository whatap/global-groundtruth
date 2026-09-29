# `collect-collserver.sh`: WhaTap backend facts

> **Status:** validated at `collect-collserver.sh` 0.15.0 on 2026-09-28, the lab
> `collsrv` VM (jjsong-ggt-collsrv, on-prem `whatap_multi` install, Ubuntu
> `openjdk-17-jre-headless`; `--stdout`, `--bundle`, and `--bundle --jvm` as the
> `whatap` user: a thread dump and a histo of each of the 8 server JVMs through
> `java -m jdk.jcmd`), COMPLETE, `validate.sh --report` pass.
> Not yet run on: a production host at this version; `--du` anywhere. Owner: Global
> team until handover to the collection-server (backend) team (CONTRACT rule 4).

Part of the [collection-server family](README.md). For anything about the
backend itself: services, ports, configs, logs.

## (a) Facts it collects

One `.txt` report, organized into MECE domains (each fact in exactly one place):

- **`[1]` Collection environment**: bash version, uid, privilege, host boot
  time and uptime, and which tools are present/absent, so every `n/a` below can
  be traced to a cause.
- **A. Host & platform**: hostname, kernel and arch (read from
  `/proc/sys/kernel/{hostname,ostype,osrelease,arch}`; `hostname`/`uname` run
  only where a file is unreadable), OS release, memory, load, cgroup limits, and
  the JVM runtime.
  - cgroup: this run's `/proc/self/cgroup` and the limit files at the
    `/sys/fs/cgroup` root it sees, then per distinct `/proc/<pid>/cgroup` of the
    WhaTap server JVMs their pids and that cgroup's `memory.max` / `cpu.max`
    (v2) or `memory.limit_in_bytes` / `cpu.cfs_quota_us` / `cpu.cfs_period_us`
    (v1).
  - JVM runtime: per distinct executable (`readlink /proc/<pid>/exe`) and mount
    namespace of the server JVMs, its pids, the JDK `release` file next to it and
    `ls -A <home>/bin` (a JRE has no jstack or jmap; at most 60 entries), read
    through `/proc/<pid>/root` so a sidecar or host run reads the JVM's own file.
    Without a release file, that executable's `-version` (only in the run's own
    mount namespace, only while the executable is not deleted), then PATH's
    `java -version`, labelled as PATH's. A deleted executable (a JDK replaced in
    place) gets `release now at <path>; the running executable was replaced`,
    since that file may no longer describe the running JVM.
  - Every JVM the run starts (`java -version`, `jstack`, `jmap`, `jcmd`) runs
    without `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS` and `_JAVA_OPTIONS`, so an
    injected `-javaagent` is not loaded; `[1]` names the ones that were set.
  - The date and timezone are B's.
- **B. Time & clock synchronization**: a common root-cause axis: a skewed clock
  drops data into the wrong time buckets. Reports `timedatectl` (synchronized?
  NTP active? RTC/UTC/local), timezone, clocksource, virtualization, each
  server's JVM `-Duser.timezone`, and the **NTP daemon's own measured offset**
  (chrony/ntpd/timesyncd: no network call; the run queries no external time
  source).
- **C. Storage & filesystem**: yardbase path, **its filesystem type (ZFS or
  not)** and, on ZFS, pool/dataset/ARC properties; capacity via `df` (never a
  recursive `du` in the report); the yard lock file under both names it
  has had, `YARDB_LOCK` and `.lock` (3.1.8), each present with its mtime or
  absent; partition range (shallow).
  The account service's H2 database: `h2.file.path` from `conf/account.conf`
  (the package ships `./db`, taken relative to `WHATAP_HOME`), its mount point
  and whether yardbase shares it, its files, and the daily SQL dumps under
  `db/backup` (count, how many are 0 bytes, newest 10). A full disk corrupts
  this file, and it fills with yardbase when both are on one filesystem;
  a dump the backup could not write is left at 0 bytes.
- **D. Deployment layout**: resolved `WHATAP_HOME` (and how it was resolved),
  directory tree, jar versions, conf file list, and a `VERSION*` / `version*`
  file at the top level dumped raw when there is one (3.1.8 ships none; the
  module versions are then the jar names here and in E).
- **E. Runtime processes**: per service: pid, jar/version, heap & GC flags,
  RSS, start time; listening ports; systemd unit state. The port list checks
  each module's **default** port number and is labelled that way
  (`port 6789 (keeper default): LISTEN`); it is not read from this host's conf,
  so a LISTEN there says a socket is open on that number, not which module owns
  it. `ss -ltnp` below it names the owning process.
- **F. Configuration**: every `conf/*.conf` dumped **raw** (see security note).
- **G. Logs & recent events**: log inventory, bounded ERROR/WARN/Exception
  counts, **a short tail of every base service log** (yard/proxy/gateway/keeper/
  … , newest-mtime first; rotated + `_self`/`_api`/`access` streams excluded),
  heap-dump files, journal errors, and the host system log. OOM kills, I/O
  errors, hung tasks and clock steps are recorded there, not in a unit
  journal. From a persistent system journal this account can read: kernel
  lines at warning and above, and all entries at err and above (newest 50
  each, newest first, last `--hours`). Otherwise the last 100 lines of
  `/var/log/messages` or `/var/log/syslog` (not limited to the window), and,
  only when neither file exists, a journal kept under `/run` (current boot).

Values are **discovered, not assumed**; an absent value is reported as
`n/a (<why>)`: `command not found`, `permission denied`, `path not found`,
`timed out`, `not applicable`, or `empty output`.

**How `WHATAP_HOME` is found, and when "not here" is an answer.** In order: a
running JVM's `-Dwhatap.server.home`, a running JVM's working directory,
`WorkingDirectory` of a loaded whatap systemd unit, the script's own parent
(when copied into `bin/`), `$WHATAP_HOME` of the shell, and the common install
paths `/whatap /data/whatap /opt/whatap /app/whatap /home/whatap
/usr/local/whatap /whatap/server /data/whatap/server` (a path counts only when
it holds a module `conf/<module>.conf` or a `lib/whatap.server.*.jar`, so a
host-agent directory is not taken for a backend). The goals are `n/a` ("no
whatap home in any readable process, unit or install path") only when all of
that was read: a `/proc` mounted `hidepid`, an unreadable
`/proc/<pid>/cmdline`, a failed `systemctl list-unit-files`, an installed
whatap unit file, or an install path this uid cannot list makes them blocked
instead. A `conf/` or `logs/` that exists but cannot be listed is blocked, not
empty. `--home DIR` always wins.

**Reading the report.** `journalctl` does not fail for an account that cannot
read the system journal: it narrows to that account's own entries and prints
`-- No entries --`, which is why the journal goal checks readability of
`system.journal` itself. `systemd-detect-virt` is printed raw: `none` is that
tool's answer when it detects no hypervisor. `gc log: absent` means no
`logs/gc*.log`; whether GC logging is configured is in the JVM flags of E.

## (b) Delivery mechanism

A **host shell script** the field engineer runs directly on the backend host:
one command, hand over one file (CONTRACT rule 3):

```sh
./collect-collserver.sh --file          # -> whatap-collserver-<host>-<UTC>.txt   (attach this)
./collect-collserver.sh --bundle        # -> whatap-collserver-<host>-<UTC>.tar.gz (report + artifacts)
./collect-collserver.sh --home /whatap  # force WHATAP_HOME if auto-resolution is n/a
./collect-collserver.sh --file --quiet  # same, but no progress narration (for automation)
./collect-collserver.sh                 # no arguments -> prints help (does not collect)
./collect-collserver.sh --help          # all options
```

A value option with no value, or with the next option taken for it
(`--out --file`), exits 2.

| option | what it does |
|---|---|
| `--home DIR` | forces `WHATAP_HOME` (else auto-resolved, see (a)) |
| `--out DIR` | where `--file` / `--bundle` write (default `.`); checked before collecting, an unwritable one exits 1 |
| `--hours N` | journal window in hours (default 24): the report's journal errors and host system log (G) and the bundle's journal |
| `--with-rotated[=DAYS]` | bundle: also copy rotated logs from the last DAYS days (default 14) |
| `--jvm` | Tier 2, bundle only: one `jstack -l` and one `jmap -histo` of each server JVM (below) |
| `--du` | Tier 2, bundle only: recursive `du --max-depth=1` of yardbase (below) |

`--jvm`, `--du` and `--with-rotated` work on the bundle only. Given without
`--bundle` they are not run, and the terminal names them (`!! not run: --jvm
--du (bundle only; add --bundle to collect them)`); the run deadline is not
raised for them.

**Environment** (whole numbers 1..999999; another value is ignored with a
warning, and the default is used):

| variable | default | what it bounds |
|---|---|---|
| `CMD_TIMEOUT` | 20 | each external command, seconds |
| `RUN_DEADLINE` | 300 | the whole run, seconds; raised by 420 for `--jvm` and 120 for `--du` unless set |
| `LOG_FILE_MB` | 5 | bundle: each copied log, MB (a larger file is tail-copied) |
| `LOG_TOTAL_MB` | 100 | bundle: all copied logs together, MB |

`WHATAP_HOME` in the environment is one of the candidates `--home` overrides.

**Run it as the account that owns the installation.** `--home` alone does not
help when the process cannot traverse the path: a `conf/` or `logs/` the uid
cannot list is blocked, not empty.

While it runs, each phase is narrated on **stderr** (`>> ...`) so you can see it
working on a slow host; the report itself stays clean. A collection needs an
explicit action flag: `./collect-collserver.sh` with no arguments just prints
help, so nothing starts by accident.

### Collection-load tiers (safe on a struggling server)

- **Tier 0** (the `--file` / `--stdout` report) runs only read-only, near-instant
  commands. It never attaches to a JVM, never walks the data tree, never reads
  whole rotated logs. Safe to run any time.
- **Tier 1** (`--bundle`) additionally copies real logs, configs,
  filesystem/ZFS/time snapshots, the journal (`--hours`, default 24) and an OS
  snapshot. Still no JVM pause.

  Logs decide the size of a bundle, so they have their own rules. Current
  (non-rotated) logs are copied; rotated ones need `--with-rotated`. Each file is
  capped at `LOG_FILE_MB` (default 5) and all of them together at
  `LOG_TOTAL_MB` (default 100), both from the environment; a file over the
  per-file cap is tail-copied so its newest end survives. `--with-rotated=DAYS`
  (default 14) bounds how far back to go.

  **Whatever is not copied is written down.** `logs/SELECTION.txt` lists every
  candidate with its state (`kept` / `truncated` / `dropped`), its size and the
  reason; the report's G section carries the totals. A log that is missing from a
  bundle must never read as a log that did not exist on the host.
- **Tier 2** (opt-in, may add load, announced on stderr first):
  `--jvm` writes one `jstack -l` and one `jmap -histo` (not `:live`, so no
  full GC; the first 200 lines) of each server JVM to the bundle's `jvm/`.
  Both stop the JVM at a safepoint. Per JVM the tool is the first that exists:
  the JVM's own `<home>/bin/jstack` / `jmap`; its own `bin/java -m
  jdk.jcmd/sun.tools.jstack.JStack` / `sun.tools.jmap.JMap` when
  `<home>/release` lists `jdk.jcmd` (a JRE such as Ubuntu's
  `openjdk-17-jre-headless`, whose `bin/` holds no jstack); both only for a
  JVM in the run's mount namespace; then `jstack` / `jmap` in `PATH`. With
  none, jstack becomes SIGQUIT to the JVM (`.sigquit.txt`): the JVM writes
  the dump to its own fd 1, which the note gives raw (`readlink
  /proc/<pid>/fd/1`; WhaTap's `bin/control.sh` starts modules with
  `>> /dev/null 2>&1`, so there the dump is lost); a refused signal (another
  uid) is written `kill -3: exit N: <stderr> (not sent)`. Each file's first
  line is `command: <the command run>`; a tool that exits non-zero ends its
  file with `(exit N)`, and a cut dump ends with `(stopped at the 60s cap)`,
  `(stopped at the run deadline, Ns)` or `(not run: ...)`.
  `--du` writes a recursive `du --max-depth=1 -h` of yardbase (the per-pcode
  sizes; it reads the metadata of the whole data tree) to `fs/yardbase-du.txt`.
  Off by default.

**Cost on a busy host.** Discovery reads `/proc` with one bounded `grep -l`
over every `cmdline` (fed through `xargs`, so tens of thousands of processes do
not hit ARG_MAX) and asks `systemctl show` once for every unit. A scan that
fails or hits its cap blocks the running-modules goal instead of reading as
"none running".

**Bounds.** Every external command runs under the shared `_bounded` cap
(`CMD_TIMEOUT`; a `systemctl` that hangs once is not asked again) and the whole
run under `RUN_DEADLINE`, raised for Tier 2 (jstack is capped at 60 s,
`jmap -histo` at 120 s, `du` at 120 s). The bundle journal keeps the newest
20,000 lines per unit. The bundle is assembled in the run's private temp
directory (removed on exit, Ctrl-C, hang-up), so an interrupted run leaves no
copy behind. A bad numeric option (`--with-rotated=DAYS`: 1..999999, no leading
zero) exits 2 before anything runs; an unwritable `--out` or a failed `tar`
exits 1 and says so. Under sudo, both the `.txt` and the `.tar.gz` are handed
back to the invoking user.

## What the report can contain

Every place a secret or sensitive value can arrive from.

Nothing is masked. What can carry a secret:

- **`conf/*.conf`** (section F and the bundle's `conf/`): verbatim, including
  `secure.conf` / `ksecure.conf`, the `account.conf` license and
  `admin.password`, database and eureka credentials.
- **Process arguments**: section E prints each WhaTap JVM's `-X`/`-XX` flags;
  the bundle's `os/ps-aux.txt` is `ps aux`, i.e. the **full command line of
  every process on the host**, including other software that takes a password
  as an argument.
- **Logs**: the tails in G and the copied `logs/` carry whatever the services
  logged (request URLs, account names, tokens a module chose to log).
- **The journal**: unit output for the last `--hours`.
- **Tier 2**: `--jvm`'s thread dumps carry thread names and lock owners'
  class names, and its class histogram carries class names.

Move the resulting `.txt` / `.tar.gz` over a trusted channel and delete it when
the case is closed.
