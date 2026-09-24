# collectors/collection-server

> **Status: SEEDED v0.** Two collectors live here, owned for now by the Global
> team (framework owner). Handover transfers ongoing ownership to the
> collection-server (backend) team (CONTRACT rule 4).
>
> | Entrypoint | Token | Scope | Status |
> | ---------- | ----- | ----- | ------ |
> | [`collect-collserver.sh`](collect-collserver.sh) 0.4.1 | `collserver` | the WhaTap backend itself | run against three live production backends (Smartfren, 2026-09-23); log selection re-measured against that bundle's own log tree. Tier 2 probes still unvalidated |
> | [`collect-collzfs.sh`](collect-collzfs.sh) 0.4.1 | `collzfs` | ZFS under the backend's data path | validated non-root on two live hosts (zfs 2.2.2 and 2.2.6), one of them a real collection server with `yardbase` on ZFS; `--zdb` and the root-only probes still unvalidated |
> | [`collect-collmysql.sh`](collect-collmysql.sh) 0.4.0 | `collmysql` | the MySQL that holds the backend's `account` / `notihub` metadata | run end to end on MySQL 5.6.51, 5.7.32, 8.4.10 and MariaDB 10.11.19 under a scheduler-shaped write load; a replicating pair, section I on 8.4 and real `iostat` sampling are still unverified |
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

- **`[0]` Collection environment** — bash version, uid (root?), and which tools
  are present/absent — so every `n/a` below can be traced to a cause.
- **A. Host & platform** — OS/kernel/arch, memory, cgroup limits, load, `java -version`.
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
  RSS, start time; listening ports; systemd unit state.
- **F. Configuration** — every `conf/*.conf` dumped **raw** (see security note).
- **G. Logs & recent events** — log inventory, bounded ERROR/WARN/Exception
  counts, **a short tail of every base service log** (yard/proxy/gateway/keeper/
  … , newest-mtime first; rotated + `_self`/`_api`/`access` streams excluded),
  heap-dump files, journal errors.

Values are **discovered, not assumed**; an absent value is reported as
`n/a (<why>)` — `command not found`, `permission denied`, `path not found`,
`timed out`, `not applicable`, or `empty output`.

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

### (c) Security note

`--home`/`--bundle` collect configs **verbatim, unmasked** — including
`secure.conf` / `ksecure.conf`, `account.conf` license and `admin.password`,
and eureka credentials. This is intended for trusted on-prem/internal transfer.
Move the resulting `.txt` / `.tar.gz` over a trusted channel and delete it when
the case is closed.

### (d) How it was built / how to maintain

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
- `WHATAP_HOME` auto-resolution order: running-JVM `-Dwhatap.server.home` →
  systemd `WorkingDirectory` → script parent (if copied into `bin/`) → `n/a`.
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

One `.txt` report, MECE domains `[0]` + A..N:

- **`[0]` Collection environment** — bash, uid (root?), tool presence, whether the
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
- **C. Pool topology & allocation classes** — raw `zpool list -v`, plus a derived
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
  one or whether they ended two months ago. On XLSMART `web01-bsd` (2026-09-23)
  the buffer held 136,337 `deadman` events whose last one was 2026-07-29, and that
  last date is what decided the case. The per-event **detail** is a separate
  question and is bundled only for a recent window (`--event-days`, default 30),
  because the full `-v` dump of that buffer was 192MB.
- **M. WhaTap collection-server paths → dataset mapping** — for `WHATAP_HOME`,
  `yardbase`, `logs`, `conf`, `db`, `keeperbase`, `logsink`: which filesystem and
  which **dataset** each lives on, that dataset's full property set, and `df`.
  This is the only WhaTap-specific section; backend services, configs and logs
  are `collect-collserver.sh`'s job.
- **N. Deep block & metaslab statistics** — `zdb` is opt-in (see tiers). The
  **file-size histogram under `yardbase` is on by default** since 0.2.0: it reads
  metadata only (`find -printf '%s'`), and `recordsize` cannot be judged without
  knowing what size the workload actually writes. It was opt-in until 0.1.0 and so
  was missing from the runs that needed it. A walk that hits its bound
  (`--filesizes-secs`, default 300) is labelled `PARTIAL` instead of being passed
  off as a complete tree. `--no-filesizes` skips it.

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
unprivileged. The uid of the run is recorded in section `[0]`.

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
    `PATH`), by walking the tree. Metadata-only, `-xdev`, bounded to 600 s.

`dbufs` is never read, in any tier: it enumerates every dbuf in the ARC.

### (c) Security note — ZFS

The report carries no WhaTap credentials — it does not read `conf/*.conf`. It does
carry host identity (hostname, device serials via `lsblk`, dataset and pool names)
and, with `--bundle`, the journal for zfs units. Treat it as internal.

### (d) How it was built / how to maintain — ZFS

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

One `.txt` report, sections `[0]` and A..K:

- **`[0]` Collection environment** — bash, uid, tool presence, which mysql client
  was resolved, whether it could connect and why not, and which opt-in tiers this
  run enabled.
- **A. Server identity and version** — version, hostname, `server_id`,
  `server_uuid`, uptime, `read_only` / `super_read_only`, port, socket, datadir,
  the local `mysqld` process and the listening sockets.
- **B. HA and replication** — `binlog_format`, GTID mode, `SHOW REPLICA STATUS`
  and the older `SHOW SLAVE STATUS`, `SHOW MASTER STATUS`, connected replicas,
  Galera `wsrep_cluster_size`, Group Replication members, semi-sync status. It
  asks for all of them and reports the reason for each one that does not answer,
  so the topology is read off the server rather than assumed.
- **C. Binary log inventory and retention** — `log_bin`, basename and index,
  `max_binlog_size`, `binlog_expire_logs_seconds` and the older
  `expire_logs_days`, `binlog_row_image`, `sync_binlog`, `SHOW BINARY LOGS`,
  the binlog cache counters, and the on-disk file list with mtimes and sizes so
  growth over time can be read from one snapshot.
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
./collect-collmysql.sh --file                       # -> whatap-collection-server-mysql-<host>-<UTC>.txt
./collect-collmysql.sh --file --defaults-file ~/.my.cnf
./collect-collmysql.sh --file --mysql-args "-h 10.0.0.5 -u whatap -p"
./collect-collmysql.sh --file --binlog --sample     # add the two opt-in tiers
./collect-collmysql.sh                              # no arguments -> prints help
```

With neither `--defaults-file` nor `--mysql-args`, the mysql client is invoked
with no connection arguments and uses its own option files. A run without
credentials still produces the host-side facts; every SQL-backed line then reads
`n/a (<reason>)`.

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
  off by default. Start with `--binlog=1` on a host under pressure.

### (c) Security note

The report contains schema and table names, statement digests, the processlist
(including the `INFO` column, truncated to 120 characters) and a binary-log
event summary by table. It does not print row values or credentials, and it
never writes to the database. Section I prints table names and event counts, not
the decoded rows themselves. Move the file over a trusted channel and delete it
when the case is closed.

### (d) How it was built / how to maintain

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
