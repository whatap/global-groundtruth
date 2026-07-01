# collectors/collection-server

> **Status: SEEDED v0 (`collect.sh` 0.2.0).** A working collector exists and is
> owned, for now, by the Global team (framework owner). Handover transfers
> ongoing ownership to the collection-server (backend) team (CONTRACT rule 4).
> **Not yet run against a live production yard** — validate once on a staging
> backend before relying on it in the field (see Status notes below).

The **collection server** is the WhaTap backend that receives agent data and
stores/aggregates it: `yard` (core store/aggregate), `proxy` (agent TCP
ingress), plus `gateway` / `keeper` / `account` / `notihub` / `eureka` /
`front` and others, usually co-located on one host.

## (a) Facts it collects

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
  counts, tails, heap-dump files, journal errors.

Values are **discovered, not assumed**; an absent value is reported as
`n/a (<why>)` — `command not found`, `permission denied`, `path not found`,
`timed out`, `not applicable`, or `empty output`.

## (b) Delivery mechanism

A **host shell script** the field engineer runs directly on the backend host —
one command, hand over one file (CONTRACT rule 3):

```sh
./collect.sh --file          # -> whatap-collserver-<host>-<UTC>.txt   (attach this)
./collect.sh --bundle        # -> whatap-collserver-<host>-<UTC>.tar.gz (report + artifacts)
./collect.sh --home /whatap  # force WHATAP_HOME if auto-resolution is n/a
./collect.sh --file --quiet  # same, but no progress narration (for automation)
./collect.sh                 # no arguments -> prints help (does not collect)
./collect.sh --help          # all options
```

While it runs, each phase is narrated on **stderr** (`>> ...`) so you can see it
working on a slow host; the report itself stays clean. A collection needs an
explicit action flag — running `./collect.sh` with no arguments just prints help,
so nothing starts by accident.

### Collection-load tiers (safe on a struggling server)

- **Tier 0** (the `--file` / `--stdout` report) runs only read-only, near-instant
  commands. It never attaches to a JVM, never walks the data tree, never reads
  whole rotated logs. Safe to run any time.
- **Tier 1** (`--bundle`) additionally copies real logs (capped by
  `--max-log-mb`, default 50), configs, filesystem/ZFS snapshots, journal
  (`--hours`, default 24) and an OS snapshot. Still no JVM pause.
- **Tier 2** (opt-in, may add load — announced on stderr first):
  `--threads[=N]` (jstack), `--histo` (`jmap -histo`, not `:live`), `--heap`
  (full heap dump), `--du` (recursive du of yardbase), `--time-ref` (external
  time comparison — a network call). Off by default.

## (c) Security note

`--home`/`--bundle` collect configs **verbatim, unmasked** — including
`secure.conf` / `ksecure.conf`, `account.conf` license and `admin.password`,
and eureka credentials. This is intended for trusted on-prem/internal transfer.
Move the resulting `.txt` / `.tar.gz` over a trusted channel and delete it when
the case is closed.

## (d) How it was built / how to maintain

Copied from [../../templates/collector-skeleton/](../../templates/collector-skeleton/),
following [../../docs/authoring-guide.md](../../docs/authoring-guide.md) and the
design guidelines in
[../../docs/collector-engineering.md](../../docs/collector-engineering.md)
(MECE domains, load tiers, portability, reasoned absence). Keep to facts only
and re-validate after edits:

```sh
../../tools/validate.sh collect.sh
```

### Status notes / open items

- Validate once on a **live/staging yard** (this v0 was verified on a host
  without a backend installed, plus a simulated JVM). Confirm module labels,
  yardbase/ZFS facts, and Tier 2 load impact there.
- `WHATAP_HOME` auto-resolution order: running-JVM `-Dwhatap.server.home` →
  systemd `WorkingDirectory` → script parent (if copied into `bin/`) → `n/a`.
- Portability target: bash 3.2+, `/proc`+`/sys` first, command fallback chains;
  known to run on modern Ubuntu. Re-check on the oldest OS you must support.
