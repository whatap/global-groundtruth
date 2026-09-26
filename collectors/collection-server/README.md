# collectors/collection-server

> **Status: SEEDED v0.** Three collectors live here, owned for now by the Global
> team (framework owner). Handover transfers ongoing ownership to the
> collection-server (backend) team (CONTRACT rule 4).
>
> | Entrypoint | Token | Scope | validated at | Status |
> | ---------- | ----- | ----- | ------------ | ------ |
> | [`collect-collserver.sh`](collect-collserver.sh) | `collserver` | the WhaTap backend itself | 0.4.1 | run against three live production backends (Smartfren, 2026-09-23); log selection re-measured against that bundle's own log tree. Tier 2 probes still unvalidated. Later versions are tested against stubs and throwaway trees only (`tools/test-collserver.sh`) |
> | [`collect-collzfs.sh`](collect-collzfs.sh) | `collzfs` | ZFS under the backend's data path | 0.4.1 | validated non-root on two live hosts (zfs 2.2.2 and 2.2.6), one of them a real collection server with `yardbase` on ZFS; `--zdb` and the root-only probes still unvalidated. Later versions are tested against a stub `zpool` only (`tools/test-collzfs.sh`) |
> | [`collect-collmysql.sh`](collect-collmysql.sh) | `collmysql` | the MySQL that holds the backend's `account` / `notihub` metadata | 0.4.0 | run end to end on MySQL 5.6.51, 5.7.32, 8.4.10 and MariaDB 10.11.19 under a scheduler-shaped write load; a replicating pair, section I on 8.4 and real `iostat` sampling are still unverified. Later versions (0.8.0: no self-elevation, password sources) are tested against a stub client only (`tools/test-collmysql.sh`) |
>
> "validated at" is the last version run on a real environment, not the current
> `VERSION` in the script.
>
> Which one to run: `collect-collserver.sh` for anything about the backend
> (services, ports, configs, logs). `collect-collzfs.sh` when the question is
> about the ZFS filesystem under it — block sizing, allocation classes, the
> write path, free-space fragmentation. `collect-collmysql.sh` when the question
> is about the backend's own MySQL — replication and HA state, binary log growth
> and what is inside those logs, InnoDB I/O counters. They are each
> self-contained; running any combination is fine and normal.

The **collection server** is the WhaTap backend that receives agent data and
stores/aggregates it: `yard` (core store/aggregate), `proxy` (agent TCP
ingress), plus `gateway` / `keeper` / `account` / `notihub` / `eureka` /
`front` and others, usually co-located on one host.

---

## `collect-collserver.sh` — WhaTap backend facts

### (a) Facts it collects

One `.txt` report, organized into MECE domains (each fact in exactly one place):

- **`[1]` Collection environment** — bash version, uid, privilege, host boot
  time and uptime, and which tools are present/absent — so every `n/a` below can
  be traced to a cause.
- **A. Host & platform** — hostname, kernel and arch (read from
  `/proc/sys/kernel/{hostname,ostype,osrelease,arch}`, the strings `uname`
  prints; `hostname`/`uname` run only where a file is unreadable), OS release,
  memory, cgroup limits, load, `java -version`. The date and timezone are B's.
- **B. Time & clock synchronization** — a common root-cause axis: a skewed clock
  drops data into the wrong time buckets. Reports `timedatectl` (synchronized?
  NTP active? RTC/UTC/local), timezone, clocksource, virtualization, each
  server's JVM `-Duser.timezone`, and the **NTP daemon's own measured offset**
  (chrony/ntpd/timesyncd — no network call). `--time-ref` optionally compares
  against an external NTP/HTTP source (a network call; never sets the clock).
- **C. Storage & filesystem** — yardbase path, **its filesystem type (ZFS or
  not)** and, on ZFS, pool/dataset/ARC properties; capacity via `df` (never a
  recursive `du` in the report); `YARDB_LOCK`; partition range (shallow).
- **D. Deployment layout** — resolved `WHATAP_HOME` (and how it was resolved),
  directory tree, jar versions, conf file list.
- **E. Runtime processes** — per service: pid, jar/version, heap & GC flags,
  RSS, start time; listening ports; systemd unit state. The port list checks
  each module's **default** port number and is labelled that way
  (`port 6789 (keeper default): LISTEN`); it is not read from this host's conf,
  so a LISTEN there says a socket is open on that number, not which module owns
  it. `ss -ltnp` below it names the owning process.
- **F. Configuration** — every `conf/*.conf` dumped **raw** (see security note).
- **G. Logs & recent events** — log inventory, bounded ERROR/WARN/Exception
  counts, **a short tail of every base service log** (yard/proxy/gateway/keeper/
  … , newest-mtime first; rotated + `_self`/`_api`/`access` streams excluded),
  heap-dump files, journal errors.

Values are **discovered, not assumed**; an absent value is reported as
`n/a (<why>)` — `command not found`, `permission denied`, `path not found`,
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

### (b) Delivery mechanism

A **host shell script** the field engineer runs directly on the backend host —
one command, hand over one file (CONTRACT rule 3):

```sh
./collect-collserver.sh --file          # -> whatap-collserver-<host>-<UTC>.txt   (attach this)
./collect-collserver.sh --bundle        # -> whatap-collserver-<host>-<UTC>.tar.gz (report + artifacts)
./collect-collserver.sh --home /whatap  # force WHATAP_HOME if auto-resolution is n/a
./collect-collserver.sh --file --quiet  # same, but no progress narration (for automation)
./collect-collserver.sh                 # no arguments -> prints help (does not collect)
./collect-collserver.sh --help          # all options
```

While it runs, each phase is narrated on **stderr** (`>> ...`) so you can see it
working on a slow host; the report itself stays clean. A collection needs an
explicit action flag — running `./collect-collserver.sh` with no arguments just prints help,
so nothing starts by accident.

#### Collection-load tiers (safe on a struggling server)

- **Tier 0** (the `--file` / `--stdout` report) runs only read-only, near-instant
  commands. It never attaches to a JVM, never walks the data tree, never reads
  whole rotated logs. Safe to run any time.
- **Tier 1** (`--bundle`) additionally copies real logs, configs,
  filesystem/ZFS/time snapshots, the journal (`--hours`, default 24) and an OS
  snapshot. Still no JVM pause.

  Logs decide the size of a bundle, so they have their own rules. Current
  (non-rotated) logs are copied; rotated ones need `--with-rotated`. Each file is
  capped at `--max-log-mb` (default 5) and all of them together at
  `--max-total-mb` (default 100); a file over the per-file cap is tail-copied so
  its newest end survives. With `--with-rotated`, `--log-days` (default 14)
  bounds how far back to go.

  **Whatever is not copied is written down.** `logs/SELECTION.txt` lists every
  candidate with its state (`kept` / `truncated` / `dropped`), its size and the
  reason; the report's G section carries the totals. A log that is missing from a
  bundle must never read as a log that did not exist on the host.
- **Tier 2** (opt-in, may add load — announced on stderr first):
  `--threads[=N]` (jstack), `--histo` (`jmap -histo`, not `:live`), `--heap`
  (full heap dump), `--du` (recursive du of yardbase), `--time-ref` (external
  time comparison — a network call). Off by default.

**Cost on a busy host.** Discovery reads `/proc` with one bounded
`grep -l` over every `cmdline` (fed through `xargs`, so tens of thousands of
processes do not hit ARG_MAX) and asks `systemctl show` once for every unit.
Measured 2026-09-25 on a 739-process host: collserver 8.1 s -> 2.4 s, collzfs
5.2 s -> 0.5 s; with 2,000 more processes, 20.5 s -> 4.2 s and 17.2 s -> 0.8 s.
A scan that fails or hits its cap blocks the running-modules goal instead of
reading as "none running".

**Bounds.** Every external command runs under the shared `_bounded` cap
(`CMD_TIMEOUT`, 20 s; `systemctl` that hangs once is not asked again) and the
whole run under `RUN_DEADLINE` (300 s, raised for Tier 2: jstack is capped at
60 s, `jmap -histo` at 120 s, a heap dump at 900 s, `du` at 120 s). The bundle
journal keeps the newest 20,000 lines per unit. The bundle is assembled in the
run's private temp directory (removed on exit, Ctrl-C, hang-up), so an
interrupted run leaves no copy behind. Numeric options that are not
non-negative integers exit 2 before anything runs; an unwritable `--out` or a
failed `tar` exits 1 and says so. Under sudo, both the `.txt` and the
`.tar.gz` are handed back to the invoking user.

### (c) How it was built / how to maintain

Copied from [../../templates/collector-skeleton/](../../templates/collector-skeleton/),
following [../../docs/authoring-guide.md](../../docs/authoring-guide.md) and the
design guidelines in
[../../docs/collector-engineering.md](../../docs/collector-engineering.md)
(MECE domains, load tiers, portability, reasoned absence). Keep to facts only
and re-validate after edits:

```sh
../../tools/validate.sh collect-collserver.sh
```

#### Status notes / open items

- **Run on three live production backends (2026-09-23, v0.3.0).** Smartfren
  `sf-whatap-web01-bsd`, `web02-bsd`, `web01-sby`. Module labels, ports, systemd
  state, yardbase ZFS facts and the journal all came back correct. Two things
  came out of it:
  - The two `web01` bundles carried **no `conf/` at all** and returned
    `n/a (path not found or WHATAP_HOME not resolved)` for D/F/G. That reason
    was wrong, and it is what 0.4.1 fixes. The collector ran as uid 3103 on all
    three hosts and WhaTap is installed under uid 1001 (`whatap`); on
    `web02-bsd` uid 3103 could still reach `/data/whatap`, on both `web01` hosts
    it could not. So the answer was never root — it was the owning account. The
    report said "not resolved" two lines after printing the resolved path, which
    reads as a contradiction and sends the reader the wrong way.
  - **Run it as the account that owns the installation.** `--home` alone does
    not help when the process cannot traverse the path.
  - The `web02-bsd` bundle was **63,327,061 bytes** (393.3 MB unpacked, 180
    entries) and the field struggled to move it. Logs were 412,175,707 of those
    bytes against 220,834 for everything else, i.e. **99.95%**. The per-file cap
    worked exactly as designed (`access.log` was tail-cut to 50 MiB and carried
    its `.trunc` marker); there was simply no cap on the total.
- **Log selection re-measured (2026-09-23, v0.4.0).** Against that bundle's own
  log tree replayed as `WHATAP_HOME/logs` (127 files, 412,175,707 bytes):

  | run | tar.gz | logs in bundle | copied | left out |
  | --- | -----: | -------------: | -----: | -------: |
  | 0.3.0, as collected in the field | 63,327,061 | 412,175,707 | 127 | 0 |
  | 0.4.0 defaults | 532,099 | 12,963,143 | 17 | 110 |
  | 0.4.0 `--max-total-mb 5` | 260,084 | 3,310,276 | 15 | 112 |
  | 0.4.0 `--with-rotated` | 19,871,166 | 104,846,391 | 70 | 57 |
  | 0.4.0 `--with-rotated --max-total-mb 50` | 8,274,635 | 52,434,658 | 58 | 69 |

  Defaults cut the copied logs from 412 MB to 13 MB and the archive from 63.3 MB
  to 0.53 MB. The total cap binds where it should: with `--with-rotated` the
  copied logs stop at 104,838,469 bytes under the 100 MB cap. In every run the
  three numbers in `SELECTION.txt` add back up to 412,175,707.

  Only the log figures transfer; the non-log part of the replay is this
  workstation's, not a backend's.
- Validate the **Tier 2** probes (`--threads`, `--histo`, `--heap`, `--du`) on a
  live/staging yard. Those still have not been run against a real backend.
- `WHATAP_HOME` auto-resolution order: see "How `WHATAP_HOME` is found" in (a).
- Portability target: bash 3.2+, `/proc`+`/sys` first, command fallback chains;
  known to run on modern Ubuntu. Re-check on the oldest OS you must support.

---

## `collect-collzfs.sh` — ZFS facts

For a collection-server host whose data path (`yardbase` / `logs` / `db`) sits on
ZFS. It collects the measurements a reviewer needs in order to **verify or refute**
a judgment about ZFS behaviour — and stops there. It prints the measured value and
the tunable that governs it; the threshold, the target and the "good/bad" belong to
the reader (CONTRACT rule 1).

### (a) Facts it collects — ZFS

One `.txt` report, MECE domains `[1]` + A..N:

- **`[1]` Collection environment** — bash, uid, privilege, boot time, tool presence, whether the
  kstat tree and the module-parameter dir exist, pool/dataset/snapshot counts,
  which tiers this run enabled.
- **A. ZFS software & kernel module** — `zfs version`, userland vs `zfs-kmod`
  version, `modinfo`, package/DKMS state, kernel taint, ZFS systemd units,
  `zpool.cache`. Also **asks the installed binary which subcommands and flags it
  has** (`zfs rewrite`, `zpool iostat -r/-w`, `zpool status -t`) rather than
  inferring capability from a version string.
- **B. ZFS module parameters** — the tunables that govern allocation-class
  routing, block-size limits, the txg/dirty-data write throttle, the metaslab
  allocator, the ZIL, ARC/L2ARC, prefetch, aggregation and scrub/trim, each
  called out by name; then **every** file under `/sys/module/{zfs,spl}/parameters`
  as `name = value`; then the **persisted** values in `/etc/modprobe.d/*zfs*` and
  the kernel cmdline. Runtime and persisted values are reported separately
  because they can differ.
- **C. Pool topology & allocation classes** — raw `zpool list -v` (asked once:
  the same output feeds the derived views, section H and the bundle's
  `zpool-list-v.txt`), plus a derived
  **per-top-level-vdev view grouped by allocation class** (data / special / logs /
  cache / dedup) carrying SIZE/ALLOC/FREE/FRAG/CAP/HEALTH, and the redundancy
  shape per class (mirror / raidz / draid / single-device / indirect). `zpool
  status -vt`, `-x`, leaf device paths, and the `metaslab_stats` kstat.
- **D. Pool properties, features & capacity** — `zpool list`, `zpool get all` per
  pool (ashift, fragmentation, capacity, every `feature@*`), `zfs list -o space`.
- **E. Dataset block size & compression** — a matrix over every filesystem and
  volume with **`recordsize` and `special_small_blocks` adjacent**, plus
  compression/compressratio/logbias/sync/primarycache/atime/volblocksize. Each
  value carries its **property source** (`l` local, `d` default, `i` inherited) —
  a deliberately set value and an inherited one are different facts. Then the
  volume list (`volblocksize` is fixed at creation), every locally-set property,
  and the `zstd` runtime kstat.
- **F. Snapshots, clones & space accounting** — a matrix of where used space sits
  (`usedbysnapshots` / `usedbydataset` / `usedbychildren` / `usedbyrefreservation`
  / `written` / `logicalused` / quota / reservation / origin), snapshot counts per
  dataset, oldest/newest snapshot, snapshots under a user hold, **snapshots pinned
  by a clone**, and the `brtstats` block-cloning kstat.
- **G. ARC / L2ARC / memory** — `arcstats` verbatim, `arc_summary`, a 1s `arcstat`
  sample, `dbufstats` / `abdstats` / `zfetchstats` / `dnodestats`, and
  `/proc/meminfo` as the context those numbers are read against.
- **H. Write path: transaction groups & ZIL** — the **`txgs` ring buffer**
  (per-txg `ndirty`, `nwritten`, and time in each state — the per-transaction-group
  ingest measurement), `dmu_tx_assign`, `zil`, `state`, `iostats`, `reads`,
  `multihost` per pool, and SLOG vdev presence.
- **I. Per-dataset I/O counters** — the `objset-<id>` kstats: cumulative
  writes / bytes written / reads / bytes read / unlinks **per dataset**, which is
  the only per-dataset byte counter available without instrumenting the
  application. Plus an inventory of every kstat entry not inlined.
- **J. I/O request size & latency distribution** — `zpool iostat -v`, `-lv`,
  `-qv`, and the **`-r` request-size** and **`-w` latency histograms**,
  cumulative since boot (instant kstat reads). `--sample` adds interval samples
  so current behaviour can be read next to the whole-uptime average.
- **K. Underlying block devices** — `lsblk`, `/sys/block/*/queue/*`
  (rotational, scheduler, nr_requests, physical/logical block size, optimal_io_size,
  write_cache), `/dev/disk/by-id` links, `iostat -x`.
- **L. Pool events, errors & maintenance** — a **tally of `zpool events` over the
  whole ring buffer** (count, first date, last date per class), then the last 100
  events, `zpool history` per pool, the `fm` kstat, zfs-filtered `dmesg`, the
  `dbgmsg` ring, journal for zfs-* units, and scrub/trim/snapshot automation
  (systemd timers, cron, sanoid / syncoid / zrepl / zed presence).

  The tally covers the whole buffer on purpose. What that buffer answers is **when
  a class started and when it stopped**, and a recent-only view cannot answer it:
  a host with no `deadman` event this month reads identically whether it never had
  one or whether they ended two months ago. On one production pool the buffer
  held 136,337 `deadman` events, the last of them two months before the run, and
  that last date is what decided the case. The per-event **detail** is a separate
  question and is bundled only for a recent window (`--event-days`, default 30),
  because the full `-v` dump of that buffer was 192MB.
- **M. WhaTap collection-server paths → dataset mapping** — for `WHATAP_HOME`,
  `yardbase`, `logs`, `conf`, `db`, `keeperbase`, `logsink`: which filesystem and
  which **dataset** each lives on, that dataset's full property set, and `df`.
  This is the only WhaTap-specific section; backend services, configs and logs
  are `collect-collserver.sh`'s job.

  Reading `df -i` on ZFS: ZFS has no fixed inode table. `IUsed` is the number of
  objects in the dataset (files, directories and the like), so it is the file
  count without a walk. `Inodes` and `IFree` are derived from the free space and
  move with it; read them as estimates, not as a limit (추정 — to be checked on a
  real ZFS host).
- **N. Deep block & metaslab statistics** — `zdb` is opt-in (see tiers). The
  **file-size histogram is opt-in (`--filesizes`, Tier 2)** since 0.6.2. It walks
  the whole tree reading metadata (`find -printf '%s'`); on a yard of ~10^8 files
  that loads the device holding the metadata (a special vdev) and the ARC, and it
  cannot finish in its bound. Every run has `df -i` for each WhaTap path (the
  file count), and `--zdb` gives the block-size histogram. When the size
  distribution itself is needed, walk a narrow sample (`--filesizes=PATH`, e.g.
  one day's directory). A walk that hits its bound (`--filesizes-secs`, default
  300) is labelled `PARTIAL`.

Values are **discovered, not assumed**; an absent value is reported as
`n/a (<why>)`. A tunable that does not exist in the installed build is reported as
`not present in this zfs build` — a version fact, not a collection failure.

### (b) Delivery mechanism — ZFS

A **host shell script** the field engineer runs on the backend host — one command,
hand over one file (CONTRACT rule 3):

```sh
./collect-collzfs.sh --file                 # -> whatap-collzfs-<host>-<UTC>.txt   (attach this)
./collect-collzfs.sh --bundle               # -> whatap-collzfs-<host>-<UTC>.tar.gz (report + raw artifacts)
./collect-collzfs.sh --file --home /whatap  # force WHATAP_HOME if auto-resolution is n/a
./collect-collzfs.sh --file --quiet         # no progress narration (for automation)
./collect-collzfs.sh                        # no arguments -> prints help (does not collect)
./collect-collzfs.sh --help                 # all options
```

Run it as **root** when possible: `zpool history`, `zpool events` and
`/proc/spl/kstat/zfs/dbgmsg` return only a header (or `permission denied`) for an
unprivileged uid, and `zdb` cannot open the pool at all. Everything else works
unprivileged. The uid of the run is recorded in section `[1]`.

**When "no pool" is an answer.** The pools goal is `n/a` only when `zpool list`
ran, exited 0 and listed nothing, or when `zpool` says the kernel module is not
loaded and `/proc/spl/kstat/zfs` is absent. A `zpool list` that was refused
(`/dev/zfs: Permission denied`), failed or hit its cap is blocked, and so is a
host with the kstat tree but no `zpool` binary. A host with neither `zfs`,
`zpool` nor `/proc/spl/kstat/zfs` is `n/a` for both goals. A `zpool` or `zfs`
that hangs during discovery is not asked again: every later call says
`skipped: zpool hung earlier (...)`. A third goal, dataset properties and
snapshots, is declared wherever ZFS is found: it is blocked when `zfs get all`
or the snapshot list failed, was refused or hung, or when `zfs` is absent.

**Reading the report** (explanations that used to be `note:` lines in it):

- A tunable printed as `not present in this zfs build` is a version fact, not a
  collection failure.
- `clones` is a snapshot property, so which snapshot a clone pins is in F's
  snapshot inventory; the clone-origin list shows the filesystem side.
- The tunables that govern H (`zfs_txg_timeout`, `zfs_txg_history`,
  `zfs_dirty_data_*`, `zil_slog_bulk`) are in B.
- `/proc/spl/kstat/zfs/dbufs` is never read (it enumerates every ARC dbuf).
- L's event tally covers the whole ring buffer, whose depth is set by
  `zfs_zevent_len_max` (B). `zpool events` and `zpool history` read `/dev/zfs`,
  so their content depends on the uid in `[1]`.
- WhaTap `conf/*.conf`, JVM flags, ports and service logs are collected by
  `collect-collserver.sh`, not here.

#### Collection-load tiers — ZFS

- **Tier 0** (`--file` / `--stdout`) reads kstats, properties and
  cumulative-since-boot `zpool iostat` only — no pool traversal, no tree walk, no
  device wake-up. Measured at **~13 s** on a live 2.7 T pool. Safe to run any time.
- **Tier 1** — `--bundle` adds the raw artifacts (full property dumps, the whole
  kstat tree except `dbufs`, all module parameters, block-device settings, journal).
  Measured at **~34 s / 89 KB** on the same host. `--sample[=SEC]` (default 10)
  adds interval `zpool iostat -lqv` / `-r` / `-w` and `arcstat` samples: read-only,
  costs roughly `6 × SEC` seconds of wall-clock, not disk load.
- **Tier 2** (opt-in, announced on stderr before running):
  - `--zdb` — `zdb -C`, `zdb -Lbbbs` (block/psize/lsize histograms and **measured**
    compression), `zdb -mm` (metaslab free-space histograms). Traverses pool
    metadata: **minutes on a large pool, and it reads the data disks.**
  - `--filesizes[=PATH]` — power-of-two file-size histogram under `yardbase` (or
    `PATH`), by walking the tree. Metadata-only, `-xdev`, bounded to
    `--filesizes-secs` (default 300 s). A walk that hits the bound, or that
    could not read part of the tree (`find` exits 1 on a denied directory), is
    labelled `PARTIAL` with the reason.

**Bounds.** Every `zpool` / `zfs` / `zdb` / `journalctl` / `find` call runs
under the shared `_bounded` cap, and the run deadline (300 s) is raised to fit
the file-size walk, `--sample`, `--zdb` (per pool: 3,720 s in the report and
7,500 s more in the bundle) and the bundle unless `RUN_DEADLINE` is set. `[1]`
prints the deadline the run used. The bundle journal keeps the newest 20,000 lines per unit. The bundle
is assembled in the run's private temp directory. Numeric options that are not
non-negative integers exit 2; an unwritable `--out` or a failed `tar` exits 1.
Under sudo the `.txt` and the `.tar.gz` are handed back to the invoking user.

`dbufs` is never read, in any tier: it enumerates every dbuf in the ARC.

### (c) How it was built / how to maintain — ZFS

Same harness as `collect-collserver.sh` (shared `probe` / `read_proc` / `dump_file`
helpers, fd-3 progress, action-flag dispatch), following
[../../docs/authoring-guide.md](../../docs/authoring-guide.md) and
[../../docs/collector-engineering.md](../../docs/collector-engineering.md).
Re-validate after edits:

```sh
../../tools/validate.sh collect-collzfs.sh
```

Two habits worth keeping when extending it:

- **Ask the binary, do not infer from the version.** Flag and subcommand support
  is probed by running the command; a build that lacks a property simply omits it
  from `zfs get all`, and that omission is reported as a fact.
- **Parse by column name, not by position.** `zpool list -v` gained `CKPOINT` /
  `EXPANDSZ` / `DEDUP` columns over time, so the derived views locate columns from
  the header row.

#### Status notes / open items — ZFS

- **Validated** on two live ZFS hosts, both as a **non-root** uid:
  - a KVM host — Ubuntu 24.04, zfs **2.2.2**, pool 2.72 T, FRAG 56 %, 19 datasets,
    2 zvols, 2 clones, and a removed vdev leaving `indirect-0/1`. Tier 0 ~13 s,
    `--bundle` ~34 s / 89 KB, plus `--home`, `--sample`, `--filesizes`.
  - a **real WhaTap collection server** — Ubuntu 24.10, zfs **2.2.6**, pool
    `yardbase` 99.5 G / FRAG 30 %, 10 running `whatap.server` JVMs. Tier 0 ~10 s.
    Section M resolved `WHATAP_HOME` from a running JVM's
    `-Dwhatap.server.home`, and correctly reported the **mixed** layout — only
    `yardbase` on ZFS (`recordsize=64K` local, `compressratio 4.43x`), while
    `logs` / `conf` / `db` / `logsink` sit on the ext4 root. The `arcstat`
    sampling branch was exercised here (that binary is absent on the KVM host).
- **Not yet validated**: `--zdb`, and the *content* of the root-only probes.
  `zdb` cannot open a pool as a non-root uid (`can't open '<pool>':
  Permission denied`), `/proc/spl/kstat/zfs/dbgmsg` is `0600 root`, and
  `zpool history` / `zpool events` return `permission denied` — those absences
  are now reported with their reason, but the success path is unexercised.
  Run once as **root** on a small pool to close this.
- **Not yet seen**: a pool that actually has a **special** or **logs** vdev. The
  derived allocation-class view was exercised only on `data` (plus `indirect`).
  The `special_small_blocks` column is populated, but always from a `0` default.
- Portability target: bash 3.2+, `/proc`+`/sys` first, column-name parsing,
  command fallback chains. Verified on GNU awk 5.2 / bash 5.2; re-check `awk`
  user-function support and `find -printf` on the oldest OS you must support
  (`--filesizes` needs GNU `find`, and says so when it is absent).

---

## `collect-collmysql.sh` — the backend's MySQL

The WhaTap backend keeps `account` and `notihub` metadata in MySQL. When the
question is about that database rather than about yard, this is the collector.
It was written for a case where the binary logs kept growing and the disk I/O
was high for a service whose usage is low, so its centre of gravity is the write
path.

### (a) Facts it collects

One `.txt` report, sections `[1]` and A..K:

- **`[1]` Collection environment** — bash, uid, privilege, boot time, tool
  presence, which mysql client was resolved, what the connection was attempted
  with, where the password came from (never the password), whether it could
  connect and why not, and which opt-in tiers this run enabled.
- **A. Server identity and version** — version, hostname, `server_id`,
  `server_uuid`, uptime, `read_only` / `super_read_only`, port, socket, datadir,
  the local `mysqld` process and the listening sockets.
- **B. HA and replication** — `binlog_format`, GTID mode, `SHOW REPLICA STATUS`
  and the older `SHOW SLAVE STATUS`, `SHOW BINARY LOG STATUS` (MySQL 8.2+; on
  its syntax error, before 8.2 and on MariaDB, `SHOW MASTER STATUS` instead,
  labelled so), connected replicas,
  Galera `wsrep_cluster_size`, Group Replication members, semi-sync status. It
  asks for all of them and reports the reason for each one that does not answer,
  so the topology is read off the server rather than assumed.
- **C. Binary log inventory and retention** — `log_bin`, basename and index,
  `max_binlog_size`, `binlog_expire_logs_seconds` and the older
  `expire_logs_days`, `binlog_row_image`, `sync_binlog`, `SHOW BINARY LOGS`,
  the binlog cache counters, and the on-disk file list with mtimes and sizes so
  growth over time can be read from one snapshot. File sizes and the total come
  from `SHOW BINARY LOGS`; the directory is listed once, for the mtimes. Only
  when `SHOW BINARY LOGS` gives no list (refused, timed out) does that listing
  add a `total:` line summed over the `<basename>.NNNNNN` files. There is no
  `du`: with the logs in the datadir it would walk the whole datadir.
- **D. Storage and I/O** — `df -hT`, mounts, the datadir's filesystem,
  `/proc/diskstats`, and the `Innodb_data_*`, `Innodb_os_log*`,
  `Innodb_buffer_pool_*`, `Innodb_rows_*` and `Com_*` counters.
- **E. InnoDB configuration** — page size, buffer pool size,
  `innodb_flush_log_at_trx_commit`, flush method, doublewrite, I/O capacity, log
  file settings, and `SHOW ENGINE INNODB STATUS`.
- **F. Schema footprint** — per-schema table count and size, the 25 largest
  tables, the tables whose names contain `lock` / `meter` / `event` / `audit`,
  and the columns of `DeniedIPAddress` and `ApmRegion`.
- **G. Per-table I/O and statement digests, from `performance_schema`** — the
  tables with the most I/O wait, the tables with the most rows written, the
  statement digests with the most latency and the most rows examined, and file
  I/O by event name. This is what attributes load to a caller.
- **H. Current activity** — processlist, thread counters, `max_connections`.
- **I. Binary log content attribution** — opt-in, see below.
- **J. Interval samples** — opt-in `iostat -x` and `vmstat`.
- **K. MySQL error log** — the resolved `log_error` tail, or the journal.

### (b) Delivery mechanism

```sh
./collect-collmysql.sh --file                       # -> whatap-collmysql-<host>-<UTC>.txt
sudo ./collect-collmysql.sh --stdout                # root over the unix socket; root-only files
./collect-collmysql.sh --file --defaults-file ~/.my.cnf
./collect-collmysql.sh --file --mysql-args "-h 10.0.0.5 -u whatap -p"
./collect-collmysql.sh --file --binlog --sample     # add the two opt-in tiers
./collect-collmysql.sh                              # no arguments -> prints help
```

With no option file and no `--mysql-args`, the mysql client is invoked with no
connection arguments and uses its own option files. A run without credentials
still produces the host-side facts; every SQL-backed line then reads
`n/a (<reason>)`. The login goal is then blocked, not `n/a`, even when no local
`mysqld` is running: the backend's MySQL is often on another host, and
`--mysql-args "-h ..."` would reach it.

**Privilege.** The collector runs at the privilege it was started with and
never elevates or re-runs itself. `[1]` states that privilege. A packaged
MySQL often admits `root@localhost` over the unix socket with no password, and
the binary log directory is often readable by root only; the operator runs it
with sudo for those (`sudo ./collect-collmysql.sh --stdout`). A goal that root
would have obtained is blocked with the uid and what refused it
(`run as uid 1000; /var/lib/mysql is mysql:mysql 750 and not readable by this
uid (not elevated: run again with sudo)`); that hint appears only in the status
section and on the terminal, never in a fact line. On a failed login the hint only states that the
run was not elevated, as in every collector; it does not claim that sudo would
fix the login (a TCP login, or a password account, is decided by the server). Under sudo the `--file`
report is handed back to the invoking user. `--no-sudo`, which 0.6/0.7 needed,
is accepted and warns that it is no longer needed.

**Passwords never go on a command line.** A command line is readable by every
account in `ps` and `/proc/<pid>/cmdline`. So the collector hands the password
to the `mysql` client only through a mode-600 option file inside the run's
private temp directory (`--defaults-extra-file`, or `--defaults-file` with
`!include` of yours when you gave one), never on a child's argv or in its
environment. Three sources:

```sh
./collect-collmysql.sh --file --defaults-file ~/.my.cnf          # or --defaults-extra-file
./collect-collmysql.sh --file --mysql-args "-h 10.0.0.5 -u whatap -p"    # asked once, on the terminal
MYSQL_PWD='...' ./collect-collmysql.sh --file --mysql-args "-u whatap"   # read, then unset
```

`MYSQL_PWD` is unset before any child starts, but it stays in the collector's
own `/proc/<pid>/environ` for the run, readable by the same uid and by root,
and MySQL deprecates the variable; prefer an option file. A `MYSQL_PWD` holding
a newline is refused (exit 2): an option-file value ends at a newline.

A password written into `--mysql-args` ends the run with exit 2 before any
child starts: it is already on the collector's own command line (the
operator's choice), and the collector does not hand it on. Detection follows
the real clients, measured against the 5.6, 5.7.32, 8.0.46 and 8.4.10 clients
(2026-09-25): `-pX`, a short-option cluster holding `p` (`-BpX`), `--password=X`,
`--password1..3=X`, the prefixes `--pas=` .. `--passwor=` (5.6), any run of the
prefixes `loose-`, `maximum-`, `skip-`, `enable-`, `disable-` before them, with
`_` and `-` interchangeable (`--loose_password=X`), and any other option name
that spells password. A bare `-p` (or `--password`, or a cluster ending in `p`
such as `-Bp`) asks once. `-p X` with a space is not a password: the client
reads it as "ask", and `X` as a database name.

**Every wait ends within `RUN_DEADLINE`.** The `-p` prompt waits at most
`PROMPT_TIMEOUT` (60 s) or what is left of the run, whichever is less, so an
unanswered prompt does not spend the whole deadline; it restores the terminal
on every path, Ctrl-C included, and an unanswered one leaves the run without a
password with that reason in `[1]`. A bare `-p` with no terminal (`ssh host
'cmd'`, cron) is not passed to the client and the report says so. The caps
come from the environment only (`CMD_TIMEOUT`, `RUN_DEADLINE`, `BINLOG_TIMEOUT`,
`PROMPT_TIMEOUT`, whole numbers 1..999999); a bad value is dropped with a
warning. `--sample` raises the deadline by both samplers (2 x (SEC x 6 + 30));
`[1]` prints the deadline the run used.

The script needs bash and says so, exit 2, under `sh`. It runs from stdin
(`bash -s -- --stdout < collect-collmysql.sh`) like any other invocation.

Run it **on the MySQL host** when you can. Sections A, C, D and K read files and
the process table locally, and fall back to `n/a (...)` when run from elsewhere.

#### Collection-load tiers

- **Tier 0** (the default `--file` / `--stdout` report) runs `SHOW` statements,
  `information_schema` and `performance_schema` queries, and near-instant local
  reads. No table scan of user data, no log decode.
- **Tier 1** — `--sample[=SEC]` adds `iostat -x` and `vmstat` samples (default
  5 s x 6, so about 30 seconds of wall clock). Read-only.
- **Tier 2** — `--binlog[=N]` decodes the N newest binary logs (default 2) with
  `mysqlbinlog --base64-output=DECODE-ROWS` and counts row events per table.
  This reads whole log files, so it costs I/O proportional to their size and is
  off by default. Start with `--binlog=1` on a host under pressure. Each file
  is capped at `BINLOG_TIMEOUT` (300 s, settable in the environment) and the run
  deadline is raised to fit. The goal is obtained only when every selected file
  was decoded to its end: a file `mysqlbinlog` could not open (Errcode 13) or a
  decode stopped at the cap is blocked, with the file named. The newest files
  and their sizes are the last rows of `SHOW BINARY LOGS`, their paths those of
  `@@log_bin_index` when it is readable and lists the same names (logs in more
  than one directory), else `<binlog dir>/<name>`. A selected file that is not
  there, or a name listed twice with no readable index, is named as skipped and
  blocks the goal; a name the index places in two directories is printed with
  its path. First, where the client connected (the `Connection:` line of its
  own `status`, which is also the login check, so no extra call): a unix
  socket, loopback or an address this host owns (`/proc/net/fib_trie`) goes
  on; a TCP address this host does not own is the server being remote, a gap
  "the server is remote (connected to ...); run the collector on the database
  host", unless a local mysqld's own network namespace owns it (a container
  reached on its bridge address), and then only that mysqld is considered. A
  name is resolved with one `getent ahostsv4`; a name that does not resolve,
  or an IPv6 address, falls back to the rule below. `@@hostname` is not used
  (a container's differs from its host's). `[1]` prints `connected to:`. A
  Kubernetes Service ClusterIP typed directly (kube-proxy in iptables mode:
  no interface owns it) is classified remote; connect through the pod's own
  address, its socket, or `127.0.0.1` inside the pod instead. The
  files are read only through the server's own process, found with file
  reads. A local `mysqld`/`mariadbd` P (not a zombie) is the server
  when: the server's `@@pid_file` (relative: under `@@datadir`), read through
  `/proc/P/root`, holds P's pid in its own pid namespace (last `NSpid:` field
  of `/proc/P/status`) — or, when this uid may not enter `/proc/P/root` (a
  container without `CAP_SYS_PTRACE`), the pid file as the run sees it holds
  P's pid; that pid file was written at or after the server's start (its
  mtime against now minus `Uptime`, both wall clock so a clock step does not
  matter; 3 s early allowed) and at most 1800 s after it (mysqld writes it
  after InnoDB crash recovery, which can take that long; a longer recovery
  reads as another server); where readable, the `auto.cnf` under P's datadir
  holds `@@server_uuid`; and P's binlog directory holds the server's newest
  log (the last `SHOW BINARY LOGS` row) at no less than the listed size and
  nothing newer (a newer file makes it ask `SHOW BINARY LOGS` once more, which
  must then list it: a rotation in between). The logs are then read at
  `/proc/P/root<binlog dir>`, so a containerised,
  bind-mounted or pod mysqld works; a remote server, or a copy of its datadir
  running here, does not match once the server has written a log the copy
  lacks. A `binlog files: via pid P (...)` line says how they were found. No
  such process is a gap, "the server's process (pid file ...) is not on this
  host: ..." with what each local server failed (run the collector on the
  database host); a pid file this uid may not read is a gap with the
  privilege hint (a missing one is "pid file absent"); two matches are a gap.
  What is left: with the target unknown (an unresolvable name, IPv6), an idle
  server here started from the same image up to 1800 s after an idle remote
  target is taken for it; their logs then hold only the init. Without
  the `SHOW BINARY LOGS` list (refused, cut) the directory is listed by mtime
  instead. A
  `@@log_bin_basename` that is NULL or not an absolute path is "not resolved",
  never the working directory, and `@@log_bin = 0` is `n/a`. When section I
  finds no row events, `binlog_format` in section B says whether the server
  writes row events at all.

### (c) How it was built / how to maintain

Copied from [../../templates/collector-skeleton/](../../templates/collector-skeleton/).
Re-validate after edits:

```sh
../../tools/validate.sh collect-collmysql.sh
```

#### Status notes / open items

- **Verified against a live MySQL (2026-09-17, v0.2.0).** Run end to end on
  MySQL **5.7.32** and **8.4.10** containers seeded with a scheduler-shaped
  write load (a lock row updated in a loop, inserts and deletes on a second
  table). Every section returned rows or a reason; section I attributed the row
  events to the right tables on 5.7. Five defects found that way are fixed in
  0.2.0: the unbounded `SHOW BINARY LOGS` listing (647 files became 647 lines
  and two thirds of the report), the missing 8.4 binlog position, the group
  replication query that 5.7 rejects whole, a missing `ps`/`ss` reported as
  "empty output", and a delimiter count labelled "statement-format queries".
- **Scale-tested (2026-09-17, v0.3.0).** Decoding an 82 MB binary log produced
  95 MB of text (1.15x). v0.2.0 held that in a shell variable and walked it six
  times: 27 s for an 85 MB pair. At the default `max_binlog_size` of 1 GiB that
  is gigabytes of RSS on a host already short of I/O. 0.3.0 streams each file
  once through `awk` and keeps only counters: the same run takes 4 s. The decode
  is capped per file (`BINLOG_TIMEOUT`, 300 s) and says so when it truncates,
  and a log with no row events now states that instead of printing an empty
  list. Section F also reports the indexes of the 15 largest tables, so a reader
  can see the index a query actually has.
- **Version matrix (2026-09-17, v0.4.0).** Run end to end on MySQL **5.6.51**,
  **5.7.32**, **8.4.10** and **MariaDB 10.11.19**, each seeded with a
  scheduler-shaped write load. All four reach the footer and attribute binary
  log rows to the right tables (8.4 excepted: the `mysql:8` image ships no
  `mysqlbinlog`). 5.7 is the cleanest: the only reasoned absences are the 8.0+
  statements the collector issues on purpose alongside their older spelling.
  Three defects came out of this matrix and are fixed in 0.4.0: MariaDB opens
  transactions with `START TRANSACTION`, not `BEGIN`, so the transaction count
  read 0; `SELECT @@read_only, @@super_read_only` lost both values on 5.6 and
  MariaDB because the second variable does not exist there; and MariaDB echoes
  the statement between dashed rules before its error, so every reason read
  `error: --------------`.
- **Still unverified:** section I on 8.4 (the `mysql:8` image ships no
  `mysqlbinlog`), section J sampling against real `iostat` (absent in both
  images; `vmstat` was exercised on the collecting host), a replicating pair
  (both servers were standalone, so `replica status` only ever returned "none"),
  and any MariaDB build.
- `SHOW REPLICA STATUS` (8.0.22+) and `SHOW SLAVE STATUS` (older) are both
  issued on purpose; one of them always reports a reason instead of rows. The
  same applies to `SHOW REPLICAS` / `SHOW SLAVE HOSTS`.
- Section I parses `mysqlbinlog` text output. It assumes row-based events render
  as `### INSERT INTO`, `### UPDATE` and `### DELETE FROM`. A server running
  `binlog_format=STATEMENT` produces no such lines, and the section then reports
  only the transaction and statement counts. Confirm the parse on a live server.
- MariaDB is resolved as a client but the MariaDB-specific replication and
  `performance_schema` differences are unvalidated.

---

## What the report can contain

Every place a secret or sensitive value can arrive from, per collector.

### `collect-collserver.sh`

Nothing is masked. What can carry a secret:

- **`conf/*.conf`** (section F and the bundle's `conf/`) — verbatim, including
  `secure.conf` / `ksecure.conf`, the `account.conf` license and
  `admin.password`, database and eureka credentials.
- **Process arguments** — section E prints each WhaTap JVM's `-X`/`-XX` flags;
  the bundle's `os/ps-aux.txt` is `ps aux`, i.e. the **full command line of
  every process on the host**, including other software that takes a password
  as an argument.
- **Logs** — the tails in G and the copied `logs/` carry whatever the services
  logged (request URLs, account names, tokens a module chose to log).
- **The journal** — unit output for the last `--hours`.
- **Tier 2** — thread dumps carry stack locals' class names; a heap dump
  (`--heap`) carries **everything in the JVM's memory**, credentials included.

Move the resulting `.txt` / `.tar.gz` over a trusted channel and delete it when
the case is closed.

### `collect-collzfs.sh`

It does not read WhaTap `conf/*.conf`. What can carry something sensitive:

- **Host identity** — hostname, device serials and models (`lsblk`,
  `/dev/disk/by-id`), dataset, pool and mount names.
- **Process arguments** — L lists `zed` / `sanoid` / `syncoid` / `zrepl` /
  `zfs send|recv` processes with their full command lines, which for a
  replication job can include a remote host, a user and an ssh option.
- **`zpool history`** — every administrative `zpool` / `zfs` command ever run on
  the pool, with its arguments (a `zfs set` of a key location, a `zfs create`
  with properties).
- **Configuration files named in L** are reported as present/absent only; their
  content is not read.
- **`--bundle`** adds the journal of zfs units, `dmesg`, the kstat tree and
  `zpool events -v`.

Treat it as internal.

### `collect-collmysql.sh`

Nothing is masked, and nothing is written to the database. What can carry
something sensitive:

- **The processlist** (H) — the `INFO` column, truncated to 120 characters: a
  running statement's literal values, which can include a password in a
  `CREATE USER` / `SET PASSWORD` / application query.
- **Statement digests** (G) — normalized, so literals are replaced by `?`, but
  schema, table and column names are verbatim.
- **Schema footprint** (F) — every schema and table name, row counts.
- **The error log tail** (K) — whatever the server logged (failed logins with
  account and host names).
- **Section A/[1]** — the account name the connection was attempted with and the
  one the server matched, and the local `mysqld` command line from `ps`. `[1]`
  prints the whole `--mysql-args` string as the operator gave it (a password
  in it ends the run first; a word after a bare `-p` is printed, since the
  client takes it as a database name).
- **Section I** prints table names and event counts, not the decoded rows.

- **The password** this collector was given is never printed; `[1]` says only
  where it came from. It exists, for the run, in the mode-600 option file of the
  run's private temp directory, and, when it came from `MYSQL_PWD`, in the
  collector's own `/proc/<pid>/environ`.

Move the file over a trusted channel and delete it when the case
is closed.
