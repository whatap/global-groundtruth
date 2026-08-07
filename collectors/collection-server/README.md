# collectors/collection-server

> **Status: SEEDED v0.** Two collectors live here, owned for now by the Global
> team (framework owner). Handover transfers ongoing ownership to the
> collection-server (backend) team (CONTRACT rule 4).
>
> | Entrypoint | Token | Scope | Status |
> | ---------- | ----- | ----- | ------ |
> | [`collect-collserver.sh`](collect-collserver.sh) 0.3.0 | `collserver` | the WhaTap backend itself | **not yet run against a live production yard** — validate once on a staging backend |
> | [`collect-collzfs.sh`](collect-collzfs.sh) 0.1.0 | `collzfs` | ZFS under the backend's data path | validated non-root on two live hosts (zfs 2.2.2 and 2.2.6), one of them a real collection server with `yardbase` on ZFS; `--zdb` and the root-only probes still unvalidated |
>
> Which one to run: `collect-collserver.sh` for anything about the backend
> (services, ports, configs, logs). `collect-collzfs.sh` when the question is
> about the ZFS filesystem under it — block sizing, allocation classes, the
> write path, free-space fragmentation. They are each self-contained; running
> both is fine and normal.

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
- **Tier 1** (`--bundle`) additionally copies real logs — current logs plus
  rotated ones from the last `--log-days` (default 14), capped per file by
  `--max-log-mb` (default 50) — configs, filesystem/ZFS/time snapshots, journal
  (`--hours`, default 24) and an OS snapshot. Still no JVM pause.
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

- Validate once on a **live/staging yard** (this v0 was verified on a host
  without a backend installed, plus a simulated JVM). Confirm module labels,
  yardbase/ZFS facts, and Tier 2 load impact there.
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
- **L. Pool events, errors & maintenance** — `zpool events`, `zpool history` per
  pool, the `fm` kstat, zfs-filtered `dmesg`, the `dbgmsg` ring, journal for
  zfs-* units, and scrub/trim/snapshot automation (systemd timers, cron, sanoid /
  syncoid / zrepl / zed presence).
- **M. WhaTap collection-server paths → dataset mapping** — for `WHATAP_HOME`,
  `yardbase`, `logs`, `conf`, `db`, `keeperbase`, `logsink`: which filesystem and
  which **dataset** each lives on, that dataset's full property set, and `df`.
  This is the only WhaTap-specific section; backend services, configs and logs
  are `collect-collserver.sh`'s job.
- **N. Deep block & metaslab statistics** — opt-in only (see tiers).

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
