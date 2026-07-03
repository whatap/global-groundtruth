# collectors/nms

> **Status: SEEDED v0 (`collect-nms.sh` 0.1.0).** A working collector exists and
> is owned, for now, by the Global team (framework owner). Handover transfers
> ongoing ownership to the NMS development team (CONTRACT rule 4).
> **Not yet run against a host with whatap-nms installed** — this v0 was
> verified on a clean host (graceful reasoned-`n/a` degradation) and its fact
> list comes from 15 months of real support threads; validate once on a live
> NMS Control Manager before relying on it in the field.

The **WhaTap NMS Control Manager** is the on-prem network-monitoring manager
(`whatap-nms` rpm): a Python application (bundled venv at `<root>/vpyenv`)
running three systemd services — `uvicorn.service` (manager UI/API),
`nmscore.service` (SNMP polling engine), `icmptcphealthd.service` (ICMP/TCP
health-check daemon) — that polls network devices over SNMP (161/udp out),
receives traps (162/udp) and syslog (514/udp), and feeds the WhaTap front.

The fact list was derived from every support thread in `#nms-support`
(2025-04 ~ 2026-07): each section answers a question that a developer actually
asked a field engineer during a case. The traceability table (question →
evidence → section) lives in the analysis workspace at
`cases/2026-07-03-nms-support-channel-analysis/analysis.md`.

## (a) Facts it collects

One `.txt` report, organized into MECE domains:

- **`[1]` Collection environment** — bash, uid, present/absent tools, resolved
  install root (from the rpm manifest; `/usr/share/whatap-nms` only as an
  on-disk fallback).
- **A. Host & platform** — OS/kernel/arch, CPU/memory, virtualization, SELinux.
  (Asked verbatim in cases: "OS 종류와", RHEL 8 vs 9 vs Rocky.)
- **B. Time & clock synchronization** — `date -u`, timedatectl/chrony/ntpstat.
  (A drifted manager clock surfaced as backend `warning future data`,
  delta ~3157s.)
- **C. Python runtime** — system python3/pip3 versions and every `python3*`
  binary present. (Manager needs Python >= 3.9; RHEL 8 ships 3.6 by default.)
- **D. Package & repository** — `rpm -qi whatap-nms`, whatap `*.repo`
  definitions, `exclude=` directives in dnf/yum config (a legacy installer
  wrote `exclude=whatap-nms*`), and the package versions the configured repos
  actually offer (`dnf --disablerepo="*" --enablerepo="whatap*" list available`).
- **E. Deployment layout** — install-root top-level listing, bundled venv
  python/pip versions, `whlhouse` wheel count, `requirements*` files, disk free.
  (The rpm `%post` builds the venv from the wheelhouse; the bcrypt case died here.)
- **F. Runtime services & processes** — unit state / enabled / restart count /
  ExecStart for `uvicorn`, `nmscore`, `icmptcphealthd` (and the pre-rename
  `icmphealthd`), plus a `wtnms*` process scan.
- **G. Network endpoints** — listening TCP/UDP sockets, a filtered view of the
  ports named in past cases (161/162/514/1514/5000/5141 — a co-located WhaTap
  collection server also binds 514/udp and the later starter loses the bind),
  established outbound connections of nms processes, resolver/route/proxy.
- **H. Outbound reachability** — two bounded HEAD requests (5s cap each) to
  `repo.whatap.io` and `pypi.org`. (Closed networks break the `%post` pip step
  with `ResolutionImpossible`; whether the host can reach out is itself a
  recurring question.)
- **I. Configuration** — every discovered `*.conf` (rpm manifest, install root,
  `/etc/whatap-nms`) dumped with values of sensitive-looking keys
  (community/password/secret/token/key/credential) replaced by `<masked>`.
  Known keys of record: `MAX_REPETITIONS`, `IFX_32BIT_PPS_FALLBACK`, ssl, syslog port.
- **J. Logs & recent events** — `/var/log/whatap-nms` inventory,
  `pkg-install-error.log` tail (the first artifact support asks for on an
  install failure), bounded tails of other logs, per-unit journal tails.
- **K. SNMP probe** *(Tier 2, opt-in — see below)*.

Values are **discovered, not assumed**; an absent value is reported as
`n/a (<why>)` — `command not found`, `permission denied`, `path not found`,
`timed out`, `not applicable`, or `empty output`.

## (b) Delivery mechanism

A **host shell script** the field engineer runs on the NMS Control Manager
host — one command, hand over one file (CONTRACT rule 3):

```sh
./collect-nms.sh --file                       # -> whatap-nms-<host>-<UTC>.txt  (attach this)
./collect-nms.sh --stdout                     # same report to stdout
./collect-nms.sh --file --quiet               # no progress narration (for automation)
./collect-nms.sh                              # no arguments -> prints help (does not collect)
```

Progress is narrated on **stderr** (`>> ...`); the report itself stays clean.

### Collection-load tiers

- **Tier 0** (the default report) is read-only and near-instant: bounded log
  tails, shallow listings, no recursive walks. The only network activity is
  the two 5s-capped HEAD requests in section H.
- **Tier 2** (opt-in, announced on stderr first):

  ```sh
  ./collect-nms.sh --file --snmp <device-ip> <community> [port]
  ```

  Sends exactly **3 SNMPv2c GET requests** (sysDescr.0 / sysUpTime.0 /
  ifNumber.0) to one device and reports each reply next to its **elapsed
  time**. Never a walk — a field session established that walking a device
  from the manager is the wrong probe, and that the answer-vs-arrival-time
  pair is the load-bearing fact (the manager polls with a ~seconds
  first-response timeout, so a device that answers slowly collects nothing
  while a device that never answers points at device-side SNMP policy or
  filtering).

## (c) Security note

Config dumps mask values of sensitive-looking keys (`community`, `passw*`,
`secret`, `token`, `key`, `credential`) as `<masked>`. Masking is
pattern-based and intentionally over-broad; it is still one file leaving a
customer network — move it over a trusted channel and delete it when the case
is closed. The `--snmp` probe requires the operator to type the community
string on the command line; prefer running it from a root-only shell (shell
history caveat applies).

## (d) How it was built / how to maintain

Copied from [../../templates/collector-skeleton/](../../templates/collector-skeleton/),
following [../../docs/authoring-guide.md](../../docs/authoring-guide.md) and
[../../docs/collector-engineering.md](../../docs/collector-engineering.md)
(MECE domains, load tiers, portability, reasoned absence). Keep to facts only
and re-validate after edits:

```sh
../../tools/validate.sh collect-nms.sh
```

### Status notes / open items (for the NMS team at handover)

- **Validate on a live NMS Control Manager host** — this v0 has only run on a
  host without whatap-nms. Confirm: install-root resolution from `rpm -ql`,
  the actual conf file locations/names (`nmscore.conf` path was never stated
  in the channel), and log file names under `/var/log/whatap-nms` beyond
  `pkg-install-error.log`.
- **Per-device polling settings are not collected** (SNMP v1-vs-v2c per device,
  polling interval, ifTable+ifXTable double registration — all named in past
  cases as facts the developer needed). Where the manager persists them
  (file/SQLite/other) was never stated in the channel; add a section once the
  NMS team names the store.
- **Uploaded private MIB inventory is not collected** — storage path unknown
  (same reason).
- Manager-side registration state as seen by the SaaS front (manager list,
  Inactive-for-24h disappearance) is server-side and out of scope for a host
  collector.
- No `--bundle` tier yet; add one (size-capped log/config archive) if cases
  start needing full logs rather than tails.
