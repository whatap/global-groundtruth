# `collect-collzfs.sh`: ZFS facts

> **Status.** Owned for now by the Global team (framework owner); handover to
> the collection-server (backend) team follows CONTRACT rule 4. Validated at
> **0.12.0**: run on 2026-09-28 as root on the lab `zfs` VM (jjsong-ggt-zfs,
> zpool `yard`; `--stdout`, `--bundle`): COMPLETE, `validate.sh --report` pass.
> Earlier versions were run as root on the same VM (Ubuntu 26.04, zfs 2.4.1,
> pool with a special vdev; the time window idle and under an append load, a
> forced ring wrap, signals) and non-root on two live hosts (zfs 2.2.2 and
> 2.2.6, one a real collection server with `yardbase` on ZFS). Not yet
> validated: `--zdb`; the content of the root-only probes (`zdb`,
> `zpool history`, `zpool events`, `dbgmsg`) on a production host, since a
> non-root run only reports their absence with the reason; a pool with a
> **logs** vdev. Stub tests: `tools/test-collzfs.sh`.

Part of the [collection-server family](README.md).

For a collection-server host whose data path (`yardbase` / `logs` / `db`) sits on
ZFS. It collects the measurements a reviewer needs in order to **verify or refute**
a judgment about ZFS behaviour, and stops there. It prints the measured value and
the tunable that governs it; the threshold, the target and the "good/bad" belong to
the reader (CONTRACT rule 1).

It reports ZFS only and does not look for WhaTap. Which
filesystem and dataset the yardbase is on is in `collect-collserver.sh`
section C (fstype, `findmnt` SOURCE, `df`, `zfs get` of that dataset,
`YARDB_LOCK`); runbooks run both, and this report's D, E and F have every
dataset's rows, so the two join on the dataset name.

## (a) Facts it collects: ZFS

One `.txt` report, MECE domains `[1]` + A..L, N, O (the WhaTap paths and
their dataset are in [collect-collserver.md](collect-collserver.md) section C):

- **`[1]` Collection environment**: bash, uid, privilege, boot time, tool presence, whether the
  kstat tree and the module-parameter dir exist, pool/dataset/snapshot counts,
  which tiers this run enabled and the time window's length.
- **A. ZFS software & kernel module**: `zfs version`, userland vs `zfs-kmod`
  version, `modinfo`, the kernel (`/proc/sys/kernel/{ostype,osrelease}`) and
  `/etc/os-release` (raw), package/DKMS state, kernel taint, ZFS systemd units,
  `zpool.cache`. Also **asks the installed binary which subcommands and flags it
  has** (`zfs rewrite`, `zpool iostat -r/-w`, `zpool status -t`) rather than
  inferring capability from a version string.
- **B. ZFS module parameters**: **every** file under
  `/sys/module/{zfs,spl}/parameters` as `name = value` (the tunables of
  allocation-class routing, block-size limits, the txg/dirty-data write
  throttle, the metaslab allocator, the ZIL, ARC/L2ARC, prefetch, aggregation
  and scrub/trim are rows of it; a tunable this build lacks is absent from it),
  then the **persisted** values in `/etc/modprobe.d/*zfs*` and the kernel
  cmdline. Runtime and persisted values are reported separately because they
  can differ.
- **C. Pool topology & allocation classes**: raw `zpool list -v` (asked once:
  the same output is the bundle's `zpool-list-v.txt`). Its lines carry each
  top-level vdev's SIZE/ALLOC/FREE/FRAG/CAP/HEALTH, the allocation class it sits
  under (a `special` / `logs` / `cache` / `dedup` line; none means data) and its
  shape in its name (`mirror-N`, `raidzP-N`, `draid*`, `indirect-N`; a bare
  device is a single-device vdev). `zpool status -vt`, `-x`, leaf device paths,
  and the `metaslab_stats` kstat.
- **D. Pool properties, features & capacity**: `zpool list`, `zpool get all` per
  pool (ashift, fragmentation, capacity, every `feature@*`), `zfs list -o space`,
  and `df -i -t zfs`, the file count of every mounted dataset. Reading `df -i`
  on ZFS: ZFS has no fixed inode table. `IUsed` is the number of
  objects in the dataset (files, directories and the like), so it is the file
  count without a walk. `Inodes` and `IFree` are derived from the free space and
  move with it; read them as estimates, not as a limit (추정, to be checked on a
  real ZFS host).
- **E. Dataset block size, compression, cache and mount**: the `zfs get` rows
  (NAME PROPERTY VALUE SOURCE) of `type`, `recordsize`, `special_small_blocks`,
  `volblocksize`, `compression`, `compressratio`, `logbias`, `sync`,
  `primarycache`, `atime`, `mounted`, `canmount`, `secondarycache`, `relatime`,
  `dedup`, `checksum`, `copies`, `reservation`, `refreservation` and `snapdir`
  for every filesystem and volume, from discovery's one `zfs get -Hp all`: exact
  values, each with its **property source** (`local`, `default`, `inherited
  from X`): a deliberately set value and an inherited one are different facts.
  Then the volume list (`volblocksize` is fixed at creation), every locally-set
  property, and the `zstd` runtime kstat.
- **F. Snapshots, clones & space accounting**: where used space sits: `used`,
  `avail` and `usedby*` are D's `zfs list -o space`, and F adds the `zfs get`
  rows of `referenced`, `logicalused`, `logicalreferenced`, `written`, `quota`
  and `refquota`; `origin` is the clone-origin list. Then snapshot counts per
  dataset, oldest/newest snapshot, snapshots under a user hold, **snapshots
  pinned by a clone**, and the `brtstats` block-cloning kstat. The snapshot
  summaries stay: the snapshot list itself is only in the bundle
  (`zfs-list-snapshots.tsv`).
- **G. ARC / L2ARC / memory**: `arcstats` verbatim, `arc_summary`, a 1s `arcstat`
  sample, `dbufstats` / `abdstats` / `zfetchstats` / `dnodestats`, and
  `/proc/meminfo` as the context those numbers are read against.
- **H. Write path: transaction groups & ZIL**: the **`txgs` ring buffer**
  (per-txg `ndirty`, `nwritten`, and time in each state, the per-transaction-group
  ingest measurement), `dmu_tx_assign`, `zil`, `state`, `iostats`, `reads`,
  `multihost` per pool.
- **I. Per-dataset I/O counters**: every `objset-<id>` kstat verbatim
  (`dataset_name`, cumulative writes / bytes written / reads / bytes read /
  unlinks, the `zil_*` counters) **per dataset**, which is the only per-dataset
  byte counter available without instrumenting the application. Plus an
  inventory of every kstat entry not inlined.
- **J. I/O request size & latency distribution**: `zpool iostat -v`, `-lv`,
  `-qv`, and the **`-r` request-size** and **`-w` latency histograms**,
  cumulative since boot (instant kstat reads). The same views over a span of
  time are in O.
- **K. Underlying block devices**: `lsblk`, `/sys/block/*/queue/*`
  (rotational, scheduler, nr_requests, physical/logical block size, optimal_io_size,
  write_cache), `/dev/disk/by-id` links, `iostat -x`.
- **L. Pool events, errors & maintenance**: a **tally of `zpool events` over the
  whole ring buffer** (count, first date, last date per class), then the last 100
  events, both from **one read of the ring** (`zpool events` in a report run,
  `zpool events -v` in a bundle run, whose files `zfs/zpool-events-*` are the
  same read), `zpool history` per pool, the `fm` kstat, zfs-filtered `dmesg`, the
  `dbgmsg` ring, journal for zfs-* units, and scrub/trim/snapshot automation
  (systemd timers, cron, sanoid / syncoid / zrepl / zed presence).

  The tally covers the whole buffer on purpose. What that buffer answers is **when
  a class started and when it stopped**, and a recent-only view cannot answer it:
  a host with no `deadman` event this month reads identically whether it never had
  one or whether they ended two months ago. On one production pool the buffer
  held 136,337 `deadman` events, the last of them two months before the run, and
  that last date is what decided the case. The per-event **detail** is a separate
  question and is bundled only for a recent window (`EVENT_DAYS` in the
  environment, default 30),
  because the full `-v` dump of that buffer was 192MB.
- **N. Deep block & metaslab statistics**: `zdb` is opt-in (see tiers). Each
  zdb call runs once: in a report run N prints its first 400-500 lines; in a
  bundle run its whole output goes to `zdb/zdb-<C|Lbbbs|mm>-<pool>.txt` and N
  names each file with its size and exit status. The
  **file-size histogram is opt-in (`--filesizes`, Tier 2)**. It walks
  the whole tree reading metadata (`find -printf '%s'`); on a yard of ~10^8 files
  that loads the device holding the metadata (a special vdev) and the ARC, and it
  cannot finish in its bound. Every run has `df -i` of every mounted dataset
  in D (the file count), and `--zdb` gives the block-size histogram. When the size
  distribution itself is needed, walk a narrow sample (`--filesizes=PATH`, e.g.
  one day's directory; a PATH is required and the whole yardbase
  is not walked). A walk that hits its bound (`FILESIZES_SECS` in the
  environment, default 300) is labelled `PARTIAL`.
- **O. Time window**: in every run, 15 s by default (`--window=DUR` sets the
  length, 10 s to 24 h): every txg of the window, start/end/delta counters,
  `zpool iostat` beside `iostat -x` over the same span, and `-r` / `-w`
  histograms. See "The time window (section O)" below.

Values are **discovered, not assumed**; an absent value is reported as
`n/a (<why>)`. A tunable that does not exist in the installed build is reported as
`not present in this zfs build`: a version fact, not a collection failure.

### The time window (section O)

The question it serves: after a tunable changes (for example `zfs_txg_timeout`
5 -> 10), how long each txg stayed open, how much each one carried, and what the
write counters did, over a span of wall-clock time (for example a two-hour run
started at 02:00 local time). **Every run** includes a window: 15 s by default, because it
reads kstat files and takes interval samples, which costs wall-clock and puts no
load on the pool. It answers "is the device busy now"; every other interval
number in the report is an average since boot or import. `--window` only
changes its length; for a later span, start the run then (`at`, `cron`). Section O of the report holds:

- **Every txg of the window** from `/proc/spl/kstat/zfs/<pool>/txgs`, one row per
  txg (`txg birth state ndirty nread nwritten reads writes otime qtime wtime stime`,
  the kernel's own columns, unchanged), from the txg open when the window starts
  to the txg open when it ends.
- How many rows were seen completed (state `C`). The rows themselves are
  printed in full below it.
- **Counters at start and end, and the delta**: the global `dmu_tx` kstat
  (`dmu_tx_assigned`, `dmu_tx_delay`, `dmu_tx_dirty_delay`, `dmu_tx_dirty_over_max`,
  `dmu_tx_dirty_frees_delay`, ...) and every dataset's `objset-*` kstat (`writes`,
  `nwritten`, `reads`, `nread`, `nunlinks`, the `zil_*` counters). Changed counters
  get a row. Unchanged ones are listed with their value.
- **`zpool iostat -T d -vlq I N` and `iostat -x -N -t I N`, started together**
  over the window. They are two bounded background jobs with the same interval
  `I` (the window divided by 120, between 1 s and 60 s: a 30 s window gets 1 s
  blocks and a 2 h window 60 s blocks) and the same count, so
  the vdev view and the block-device view describe the same seconds:
  - zpool: per vdev operations, bandwidth, `total_wait`, `disk_wait`,
    `syncq_wait`, `asyncq_wait` and queue depths
  - iostat: per device `r/s`, `w/s`, `rkB/s`, `wkB/s`, `r_await`, `w_await`,
    `aqu-sz` and `%util`

  Each job's start time is printed to the ms (taken just before its fork),
  together with the offset between them (6-8 ms on the VM). Each block also
  carries its own timestamp: zpool uses `-T d`, and iostat uses `-t` with
  `S_TIME_FORMAT=ISO`. The first block of each is cumulative (zpool: since pool
  import; iostat: since boot).

  `-N` (device-mapper names) and `-t` are checked once against this iostat; a
  flag it refuses is dropped and the report says which. A job capped by its
  bound, or still running when the window ended (it is then stopped), keeps
  what it wrote, and the report names the cut job.
- **`zpool iostat -T d -r DUR 2` and `-w DUR 2`**: the request-size and latency
  histograms, with one cumulative block and one block for the whole window.
- **ARC**: the `arcstats` kstat at start and end with deltas (the counters
  `arcstat` reads, the cheaper source). The `arcstat I N` series is added when
  `arcstat` is installed; its absence is stated and does not block the goal.
- `zfs_txg_history` and `zfs_txg_timeout` as read at the start and at the end.

All interval jobs start together, as bounded background jobs.

**How the txgs ring is read.** `txgs` is a ring of the last `zfs_txg_history` txgs (default 100). OpenZFS
`module/zfs/spa_stats.c`, `spa_txg_history_add`, adds a row when the previous txg
begins to quiesce (`txg.c`, `txg_quiesce`) and drops the oldest row once the ring
holds more than `zfs_txg_history` rows. The ring therefore spans about
`zfs_txg_history x txg interval`: at 100 rows and 5 s txgs that is about 500 s,
and at 1 s txgs under load about 100 s.

- **Interval.** The next read comes after half the span the ring covered at the
  last read (the `birth` of the oldest row to the newest; `birth` is `gethrtime()`
  in ns, and only differences of it are used). With more than one pool, the
  shortest span sets it. The interval stays between 2 s and 300 s. At a steady txg
  rate, every txg appears in at least two reads.
- **Merge.** Rows are merged by txg number. A txg is kept once: at its first
  sighting in state `C`. If it left the ring before any read saw it completed, the
  last state that was seen is kept, and the report counts these rows. At the end,
  the rows still open, quiescing or syncing are kept with their state.
- **Gaps.** A txg number that is in neither of two consecutive reads left the ring
  between them. Each such range is listed with its count and the read that found it
  missing. Nothing is filled in. A gap blocks the goal, and the reason names
  `zfs_txg_history`. The collector never changes a tunable. Raising
  `zfs_txg_history` (e.g. `echo 1000 > /sys/module/zfs/parameters/zfs_txg_history`)
  is the operator's decision.
- **Cap.** 20,000 rows per pool are kept. Rows past the cap are counted and the
  goal is blocked.
- **Never written.** Writing to `txgs` clears the ring
  (`spa_txg_history_clear`). The window only reads.
- **A read cut by the ring moving.** The Linux `procfs_list` reader
  (`module/os/linux/spl/spl-procfs-list.c`, `procfs_list_seq_start`) returns
  `EIO` when the row a multi-`read()` pass stopped at has been dropped before the
  next `read()`. It never skips rows silently. Such a read is retried once at once,
  and a read that fails twice is counted as failed.

**On txg numbers "skipping" in section H.** One `cat` of `txgs` cannot have a hole
in the middle. Rows are added at the tail and dropped at the head only, and a
reader whose place was dropped gets `EIO`, not a jump. Section H prints the file
in one read when it has up to 150 lines. Past 150 lines it prints the header,
an explicit `... (N earlier records omitted ...)` line and the tail. The rows of
one txg ring are therefore contiguous in H. Before the ring is full, its first row is
the first txg recorded after the pool was imported or created (txg 5 in the VM
test report), not txg 1.

**Where the rows go.**

- The report prints every kept row, per pool, after the counters. At 5-10 s txgs,
  a 2 h window is 720-1,440 rows (about 150 bytes each). `zpool iostat` output is
  printed up to 6,000 lines.
- `--bundle` adds `window/`:
  - `txgs-<pool>.txt`: the merged rows, with the kernel's column header
  - `reads-<pool>.tsv`: one line per read: epoch, rows, oldest, newest, span, gaps so far
  - `gaps-<pool>.tsv` (only when there was a gap): from, to, count, epoch of the read that found the gap
  - `zpool-iostat-vlq.txt`, `iostat-x.txt`, `zpool-iostat-r.txt`, `zpool-iostat-w.txt`
    and `arcstat.txt` (when present), with `io-start-ms.tsv` (the pair's starts, ms since the epoch)
  - `start/` and `end/`: epoch, the two parameters, `dmu_tx`, `arcstats` and every `objset-*` as read

**Counter caveats in the delta table.**

- A kstat recreated during the window (its `crtime`, field 6 of line 1, changed,
  e.g. a dataset remounted) gets no delta. The table says the kstat was recreated.
- A counter lower at the end than at the start is printed as
  `went down (end < start)`.
- An `objset-*` present only at the start, or only at the end, is named as such.
  So is a pool whose `txgs` disappeared during the window (export). The rows of the
  last read that had rows are merged as final (still-open rows are kept with their
  state). The report gives the time of that read and its newest txg, and says that
  txgs after it are not in the report. How many there were cannot be known.

## (b) Delivery mechanism: ZFS

A **host shell script** the field engineer runs on the backend host: one command,
hand over one file (CONTRACT rule 3):

```sh
./collect-collzfs.sh --file                 # -> whatap-collzfs-<host>-<UTC>.txt   (attach this; includes a 15 s window)
./collect-collzfs.sh --bundle               # -> whatap-collzfs-<host>-<UTC>.tar.gz (report + raw artifacts)
./collect-collzfs.sh --file --window=2h     # a 2 h window from now
./collect-collzfs.sh --file --quiet         # no progress narration (for automation)
./collect-collzfs.sh                        # no arguments -> prints help (does not collect)
./collect-collzfs.sh --help                 # all options
```

**Options**: `--file`, `--stdout`, `--bundle`, `--quiet`, `--out DIR`,
`--window=DUR`, `--filesizes=PATH`, `--zdb`, `--help`. `--out`, `--window` and
`--filesizes=` with no value, or with the next option taken for it (`--out --file`), exit 2 naming the option.

**Environment** (whole numbers; another value is ignored with a warning, and the
default is used):

| variable | default | what it bounds |
|---|---|---|
| `CMD_TIMEOUT` | 20 | each external command, seconds |
| `RUN_DEADLINE` | 300 | the whole run, seconds; raised for the window, `--zdb`, `--filesizes` and `--bundle` unless set |
| `FILESIZES_SECS` | 300 | the `--filesizes` walk, seconds |
| `EVENT_DAYS` | 30 | the `zpool events -v` detail window, days; 0 keeps every event |
| `JOURNAL_HOURS` | 24 | the zfs unit journal window, hours |

**The window, run by run.**

- `--window=DUR` sets the window's length. `DUR` is `N` (seconds), `Ns`, `Nm`
  or `Nh`, from 10 s to 24 h. The window starts when the run does: for a window
  at a later time, start the run then (`at`, `cron`). One window per run: for
  two windows, start two runs.
- The run exits 2 before anything runs when `--window` has no value or `DUR` is
  out of range. The run deadline grows by the window's length and 60 s, unless
  the caller set `RUN_DEADLINE`; the window never runs into the last 120 s of the
  deadline, which are left for the rest of the report (they come out of the base
  300 s). A caller's `RUN_DEADLINE` is not raised:
  - with `--window`, one that leaves the window under 10 s exits 2, and one that
    cuts it says so at the start;
  - for the default window, one that leaves it no time means the window is not
    run, and one that leaves it less than 15 s cuts it. Either way section O and
    the status say so, and the goal is blocked.
- The window goal is declared in every run. It is not applicable on a host with
  no ZFS, or with no `<pool>/txgs` and no pool listed by `zpool`.
- The window runs **before** the rest of the report, so the Tier 0 sections
  record the state at the window's end. Keep the session open for the whole
  window (`nohup`, `tmux`, `screen`).
- **Ending early.** A first `INT`, `TERM` or `HUP` during the window ends it. The report is still written: section O says `ended early: SIG... after
  X of Y` and gives what was collected, and the goal is blocked with the same
  words. A second signal, also during the last reads, aborts the run as in any
  other run and stops both iostat jobs. (Under `bash` a lost signal is described in
  [collector-engineering.md](../../docs/collector-engineering.md); send it again.)
- Every read goes through `_bounded` (`cat` of kstat files, 10 s cap each). The
  `zpool iostat` and `iostat` jobs start first, at the window's start, and end
  with it whatever the interval `I` is; if the length is not a multiple of `I`,
  the last `length mod I` seconds are covered by the txgs, the counters and
  `-r`/`-w`, not by a pair block. After the window each job gets 5 s for its
  last block; an early end (signal, deadline) stops them at once.
- The window goal's inputs are the txgs, the kstat deltas and `zpool iostat`;
  a missing `zpool` blocks it. `iostat -x` only adds the block-device view:
  an absent (no sysstat), failed or stopped `iostat` is a fact line
  in section O (`not delivered: iostat -x: command not found (sysstat)`) and
  does not block the goal (docs/output-format.md, "A tool that only adds
  detail").

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

**Reading the report** (explanations that are not printed in it):

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
- WhaTap `conf/*.conf`, JVM flags, ports, service logs and which dataset the
  yardbase is on (its section C) are collected by `collect-collserver.sh`, not
  here.

### Collection-load tiers: ZFS

- **Tier 0** (`--file` / `--stdout`) reads kstats, properties and
  cumulative-since-boot `zpool iostat`, plus the 15 s time window (kstat file
  reads and interval samples): no pool traversal, no tree walk, no device
  wake-up. Measured at about 13 s on a live 2.7 T pool without the window; the window
  adds about 17 s.
  Safe to run any time.
- **Tier 1**: `--bundle` adds the raw artifacts (full property dumps, the whole
  kstat tree except `dbufs`, all module parameters, block-device settings, journal).
  Measured at **~34 s / 89 KB** on the same host. `--window=DUR`
  (10 s to 24 h, default 15 s) sets the length of the time window:
  read-only, it costs the window's wall-clock, not disk load.
- **Tier 2** (opt-in, announced on stderr before running):
  - `--zdb`: `zdb -C`, `zdb -Lbbbs` (block/psize/lsize histograms and **measured**
    compression), `zdb -mm` (metaslab free-space histograms). Traverses pool
    metadata: **minutes on a large pool, and it reads the data disks.**
  - `--filesizes=PATH`: power-of-two file-size histogram under `PATH`, by
    walking the tree. Metadata-only, `-xdev`, bounded to
    `FILESIZES_SECS` (environment, default 300 s). A walk that hits the bound, or that
    could not read part of the tree (`find` exits 1 on a denied directory), is
    labelled `PARTIAL` with the reason.

**Bounds.** Every `zpool` / `zfs` / `zdb` / `journalctl` / `find` call runs
under the shared `_bounded` cap. Unless `RUN_DEADLINE` is set, the run deadline
(300 s) is raised to fit the time window (its length plus 60 s; the 120 s the
window leaves for the rest of the report come out of the base 300 s), the
file-size walk, `--zdb` (280 s plus, per pool, 3,720 s in a report run or 7,500 s
in a bundle run; zdb runs once, in one or the other) and the bundle. `[1]`
prints the deadline the run used. The bundle journal keeps the newest 20,000
lines per unit, and the bundle is assembled in the run's private temp directory.
An unwritable `--out` or a failed `tar` exits 1; under sudo the `.txt` and the
`.tar.gz` are handed back to the invoking user.

`dbufs` is never read, in any tier: it enumerates every dbuf in the ARC.

## Design notes

**Question -> report section**, for a reader who knows what they want to check
but not which section has it:

| question | sections |
|---|---|
| allocation-class routing | B (`zfs_special_class_metadata_reserve_pct`), C (`zpool list -v`: usage per vdev under its class), E (`recordsize` and `special_small_blocks` rows per dataset) |
| block sizing | E (`zfs get` rows with property source), J (request-size histograms), N (`zdb -Lbbbs`) |
| append / txg behaviour | B (`zfs_txg_timeout`, dirty-data throttle), H (txgs ring buffer, ZIL kstats), I (per-dataset objset write counters), O (every txg of a time window, `--window`) |
| free-space fragmentation | C/D (FRAG, CAP per vdev and per pool), B (`metaslab_*` parameters), N (`zdb -mm`) |
| rewrite / send-receive path | A (whether the rewrite subcommand exists), F (snapshot and clone space accounting) |

## What the report can contain

Every place a secret or sensitive value can arrive from.

It does not read WhaTap `conf/*.conf`. What can carry something sensitive:

- **Host identity**: hostname, device serials and models (`lsblk`,
  `/dev/disk/by-id`), dataset, pool and mount names.
- **Process arguments**: L lists `zed` / `sanoid` / `syncoid` / `zrepl` /
  `zfs send|recv` processes with their full command lines, which for a
  replication job can include a remote host, a user and an ssh option.
- **`zpool history`**: every administrative `zpool` / `zfs` command ever run on
  the pool, with its arguments (a `zfs set` of a key location, a `zfs create`
  with properties).
- **Configuration files named in L** are reported as present/absent only; their
  content is not read.
- **`--bundle`** adds the journal of zfs units, `dmesg`, the kstat tree,
  `zpool events -v` and, with `--zdb`, zdb's whole output.
- **Section O (the time window)** adds dataset and pool names (from
  `objset-*`), txg numbers and counters, the `zpool iostat` vdev names and the
  `iostat -x` device names. It reads no file content, no configuration and no
  command line.

Treat it as internal.
