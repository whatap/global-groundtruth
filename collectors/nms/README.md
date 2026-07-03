# collectors/nms

> **Status: SEEDED v0 (`collect-nms.sh` 0.2.0).** A working collector exists and
> is owned, for now, by the Global team (framework owner). Handover transfers
> ongoing ownership to the NMS development team (CONTRACT rule 4).
> **Live-validated on Ubuntu 24.04 with a real `whatap-nms` 1.0.2 (deb)
> install** — including a failed-postinst scenario, where the report captured
> the package state (`half-configured`), the `pkg-install-error.log` cause
> line, python/venv facts, and outbound reachability in one paste. Also
> verified to degrade gracefully (reasoned `n/a`) on a host without the
> package. Not yet run on a RHEL-family host or a fully-running manager.

The **WhaTap NMS Control Manager** is the on-prem network-monitoring manager
(`whatap-nms` package — rpm on RHEL-family, deb on Debian-family): a Python
application (bundled venv at `<root>/vpyenv`, wheelhouse at `<root>/whlhouse`)
running three systemd services — `uvicorn.service` (manager UI/API, TCP 5000
HTTP / 8443 HTTPS), `nmscore.service` (SNMP polling engine),
`icmptcphealthd.service` (ICMP/TCP health-check daemon) — that polls network
devices over SNMP (161/udp out), receives traps (162/udp) and syslog
(514/udp), and sends data to the WhaTap collection server (6600/tcp out).
Main config: `<root>/etc/nmscore.conf`; MIB module registry:
`<root>/etc/mibmods.toml`; logs: `/var/log/whatap-nms` (install) and
`/var/log/nmscore` (engine / MIB module loads).

The fact list was derived from every support thread in `#nms-support`
(2025-04 ~ 2026-07), cross-checked against the official docs
([supported-spec](https://docs.whatap.io/nms/supported-spec),
[install-agent](https://docs.whatap.io/nms/install-agent), NMS FAQ), and
confirmed by a live install. The traceability table (question → evidence →
section) lives in the analysis workspace at
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
- **D. Package & repository** — `rpm -qi` / `dpkg -s whatap-nms` (the dpkg
  `Status:` line distinguishes `installed` from `half-configured`), whatap
  repo definitions (yum `*.repo` and apt `sources.list*`), repo signing key
  presence, `exclude=` directives in dnf/yum config (a legacy installer wrote
  `exclude=whatap-nms*`) and apt holds, and the package versions the
  configured repos actually offer (dnf/yum list available, `apt-cache policy`).
- **E. Deployment layout** — install-root top-level listing, bundled venv
  python/pip versions, `whlhouse` wheel count, `requirements*` files, disk free.
  (The package post-install step builds the venv from the wheelhouse; the
  bcrypt case died here, and so did the live-validation install on Ubuntu
  24.04 — httptools vs `uvicorn[standard]==0.49.0` dependency conflict.)
- **F. Runtime services & processes** — unit state / enabled / restart count /
  ExecStart for `uvicorn`, `nmscore`, `icmptcphealthd` (and the pre-rename
  `icmphealthd`), plus a `wtnms*` process scan.
- **G. Network endpoints** — listening TCP/UDP sockets, a filtered view of the
  ports of record (161/162/514/1514/5000/5141/6600/8443 — a co-located WhaTap
  collection server also binds 514/udp and the later starter loses the bind;
  6600/tcp is the documented outbound data port), established outbound
  connections of nms processes and to :6600, resolver/route/proxy.
- **H. Outbound reachability** — two bounded HEAD requests (5s cap each) to
  `repo.whatap.io` and `pypi.org`. (Closed networks break the post-install pip
  step with `ResolutionImpossible`; whether the host can reach out is itself a
  recurring question.)
- **I. Configuration** — `wtinitset -v` (the official config viewer; key
  material masked), then every discovered `*.conf`/`*.toml` (package manifest,
  `<root>`, `<root>/etc`, `/etc/whatap-nms`) dumped with values of
  sensitive-looking keys (community/password/secret/token/key/credential)
  replaced by `<masked>` — this includes `etc/nmscore.conf` and the MIB module
  registry `etc/mibmods.toml`. A flat "keys of record" grep
  (`MANAGER_WEB_PORT`, `MANAGER_HTTPS_ENABLED`, `MANAGER_HTTPS_WEB_PORT`,
  `MAX_REPETITIONS`, `IFX_32BIT_PPS_FALLBACK`) guards against dump caps.
- **J. Logs & recent events** — `/var/log/whatap-nms` inventory,
  `pkg-install-error.log` tail (the first artifact support asks for on an
  install failure), bounded tails of other logs, `/var/log/nmscore/nmscore.log`
  tail (the artifact the FAQ names for MIB module-load results), per-unit
  journal tails.
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

- **Live-validated (2026-07-03, Ubuntu 24.04, whatap-nms 1.0.2 deb)**: install
  root resolves from the dpkg manifest (`/usr/share/whatap-nms`; a doc-path
  false match was caught and excluded), `etc/nmscore.conf` and
  `etc/mibmods.toml` are discovered and dumped, keys of record extract
  correctly, and a real failed postinst (`httptools` vs
  `uvicorn[standard]==0.49.0`, `ResolutionImpossible` with pypi reachable) was
  fully captured in one report. Sample report:
  `cases/2026-07-03-nms-support-channel-analysis/resources/` in the analysis
  workspace. **Still to do: one run on a RHEL-family host and one on a
  fully-running manager** (unit states, listening 5000/514/162, established
  :6600, `/var/log/nmscore` content, `wtinitset -v` output shape — mask
  patterns may need adjusting to its real format).
- **Per-device polling settings are not collected** (SNMP v1-vs-v2c per device,
  polling interval, ifTable+ifXTable double registration — all named in past
  cases as facts the developer needed). Where the manager persists them
  (file/SQLite/other) is still unnamed; `etc/mibmods.toml` covers the MIB
  module registry but not per-device polling. Add a section once the NMS team
  names the store.
- Manager-side registration state as seen by the SaaS front (manager list,
  Inactive-for-24h disappearance) is server-side and out of scope for a host
  collector.
- No `--bundle` tier yet; add one (size-capped log/config archive) if cases
  start needing full logs rather than tails.
