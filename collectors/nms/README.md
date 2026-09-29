# collectors/nms

> **Status:** validated at `collect-nms.sh` 0.7.5 on 2026-09-28 (the script's own
> `VERSION` is the current one) on the lab `nms` target (Rocky 9 + systemd, real
> `whatap-nms` 1.3.3 rpm, all four units running): COMPLETE, `validate.sh --report`
> pass. Also degrades to reasoned `n/a` on a host without the package. Owned, for
> now, by the Global team; handover moves ownership to the NMS development team
> (CONTRACT rule 4).

The **WhaTap NMS Control Manager** is the on-prem network-monitoring manager
(`whatap-nms` package, rpm on RHEL-family, deb on Debian-family): a Python
application (bundled venv at `<root>/vpyenv`, wheelhouse at `<root>/whlhouse`)
running three systemd services: `uvicorn.service` (manager UI/API, TCP 5000
HTTP / 8443 HTTPS), `nmscore.service` (SNMP polling engine),
`icmptcphealthd.service` (ICMP/TCP health-check daemon), that polls network
devices over SNMP (161/udp out), receives traps (162/udp) and syslog
(514/udp), and sends data to the WhaTap collection server (6600/tcp out).
Main config: `<root>/etc/nmscore.conf`; MIB module registry:
`<root>/etc/mibmods.toml`; logs: `/var/log/whatap-nms` (install) and
`/var/log/nmscore` (engine / MIB module loads).


The fact list was cross-checked against the official docs
([supported-spec](https://docs.whatap.io/nms/supported-spec),
[install-agent](https://docs.whatap.io/nms/install-agent), NMS FAQ).

## (a) Facts it collects

One `.txt` report, organized into MECE domains:

- **`[1]` Collection environment**: bash, uid, present/absent tools, resolved
  install root (from the rpm or dpkg manifest, then from the executable of a
  running nms process (its argv[0], or `/proc/<pid>/exe` for a relative one)
  when it lies under a `.../whatap-nms/` tree;
  `/usr/share/whatap-nms` only as an on-disk fallback), and whether `/proc` is
  mounted with `hidepid` (a non-root run then cannot see other users'
  processes, and "no process" is `missed`, not `na`).
- **A. Host & platform**: OS/kernel/arch, CPU/memory, virtualization, SELinux.
- **B. Time & clock synchronization**: `date -u`, timedatectl/chrony/ntpstat.
- **C. Python runtime**: system python3/pip3 versions and every `python3*`
  binary present (the manager's venv needs Python >= 3.9; RHEL 8 ships 3.6 by
  default).
- **D. Package & repository**: `rpm -qi` / `dpkg -s whatap-nms` (the dpkg
  `Status:` line distinguishes `installed` from `half-configured`), whatap
  repo definitions (yum `*.repo` and apt `sources.list*`), repo signing key
  presence, `exclude=` directives in dnf/yum config (a legacy installer wrote
  `exclude=whatap-nms*`) and apt holds, the package versions the configured
  repos actually offer (dnf/yum list available, `apt-cache policy`), and the
  **install/upgrade attempt history** (`dpkg.log` / apt `history.log` /
  `dnf history`), so a failed post-install step stays on record in the
  report even after the package was removed or purged.
- **E. Deployment layout**: install-root top-level listing, bundled venv
  python/pip versions, `whlhouse` wheel count, `requirements*` files, disk free.
- **F. Runtime services & processes**: unit state / enabled / restart count /
  ExecStart for `uvicorn`, `nmscore`, `icmptcphealthd` (and the pre-rename
  `icmphealthd`), plus a `/proc` scan that matches the executable only (argv[0]
  or `/proc/<pid>/exe` under a `whatap-nms` tree, or the daemon names). A process
  that only names a whatap-nms path as an argument, and the collector's own
  shell ancestry, are not counted.
- **G. Network endpoints**: listening TCP/UDP sockets, a filtered view of the
  ports of record (161/162/514/1514/5000/5141/6600/8443: a co-located WhaTap
  collection server also binds 514/udp and the later starter loses the bind;
  6600/tcp is the documented outbound data port), established outbound
  connections of nms processes and the :6600 sessions, filtered to the pids
  of the process scan only when the run is root; a non-root `ss -p` names
  only the run's own sockets, so a non-root run lists every established
  :6600 session labelled "owner not visible to uid N": resolver/route/proxy.
- **H. Outbound reachability**: two bounded HEAD requests (5s cap each) to
  `repo.whatap.io` and `pypi.org`, each with curl's `-w` line (`HTTP 000` on
  failure) and curl's exit code and its name when non-zero.
- **I. Configuration**: `wtinitset -v` (the official config viewer), then
  every discovered `*.conf`/`*.toml` (package manifest, `<root>`,
  `<root>/etc`, `/etc/whatap-nms`) dumped **verbatim**, including
  `etc/nmscore.conf` and the MIB module registry `etc/mibmods.toml`. A flat
  "keys of record" grep (web/HTTPS ports, `MAX_REPETITIONS`, ...) guards against
  dump caps.
- **J. Logs & recent events**: `/var/log/whatap-nms` inventory,
  `pkg-install-error.log` tail (the first artifact support asks for on an
  install failure), bounded tails of other logs, `/var/log/nmscore/nmscore.log`
  tail (the artifact the FAQ names for MIB module-load results), per-unit
  journal tails.
- **K. SNMP probe** *(Tier 2, opt-in, see below)*.

Goals in the status section: `install`, `conf` (every discovered `*.conf`,
and the directories `/etc/whatap-nms`, the install root, its `etc/` and
`conf/` readable; a permission-denied file or directory is `missed` with the
privilege gap), `logs` (the same for `/var/log/whatap-nms` and
`/var/log/nmscore`). When the install root is unknown because an input was
blocked (a failed manifest query, a hidden or cut-short process scan, a
process seen but not resolved), `install`, `conf` and `logs` are all
`missed` with that reason; and `snmp` only when `--snmp`
was given (a GET without a reply, or no `snmpget`, is `missed`).

An absent value is reported as `n/a (<why>)` (CONTRACT rule 2).

## (b) Delivery mechanism

A **host shell script** the field engineer runs on the NMS Control Manager
host: one command, hand over one file (CONTRACT rule 3):

```sh
./collect-nms.sh --file                       # -> whatap-nms-<host>-<UTC>.txt  (attach this)
./collect-nms.sh --stdout                     # same report to stdout
./collect-nms.sh --file --quiet               # no progress narration (for automation)
./collect-nms.sh --file --out /var/tmp        # the .txt in /var/tmp instead of the current dir
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
  time**. Never a walk. The manager polls with a ~seconds first-response
  timeout, so the answer-vs-arrival-time pair is the fact: a device that
  answers slowly collects nothing, while one that never answers points at
  device-side SNMP policy or filtering.

## What the report can contain

Config dumps are collected **verbatim, unmasked**: framework policy
([authoring-guide](../../docs/authoring-guide.md) step 3): a masked value
would destroy the fact it is supposed to carry. A secret can arrive from:

- **Configuration files** (section I): `wtinitset -v` output and every
  discovered `*.conf` / `*.toml` (`etc/nmscore.conf`, `etc/mibmods.toml`,
  `/etc/whatap-nms/*.conf`): the WhaTap access key, the server address, SNMP
  community strings or v3 credentials if the manager keeps them there, HTTPS
  settings.
- **Repository definitions** (section D): whatap `*.repo` / apt `*.list`
  files, whose `baseurl` / `deb` lines can carry `user:password@`.
- **Process command lines** (section F): `ps` args of nms processes, and the
  `ExecStart` of each unit.
- **Environment** (section G): proxy variables of the run's own environment
  and `/etc/environment`, which can carry `user:password@` proxy credentials.
- **Logs and journal** (section J): whatever the manager and the package
  post-install step wrote.
- **`--snmp`**: the community string is not printed in the report and is not
  put on `snmpget`'s command line (it reaches `snmpget` through a mode-600
  `snmp.conf` in the run's private directory, removed on exit, appended to the
  default net-snmp search path). A community holding whitespace, `#` or a
  quote cannot be carried there; the probe is then not sent and the goal is
  `missed`. It is on this
  collector's own command line, so it is in `ps` for the run and in the shell
  history.

It is one file leaving a customer network: move it over a trusted channel and
delete it when the case is closed.

## (c) Maintenance

Validate with `../../tools/validate.sh collect-nms.sh`. The shared helpers
`_classify_err`, `_proc_hidden` and `_self_tree` are the group block
`host: helpers` ([templates/groups/host.sh](../../templates/groups/host.sh)).

Not collected: per-device polling settings (SNMP version, interval; the store
is not named by the NMS team, and `etc/mibmods.toml` covers only the MIB module
registry) and the SaaS-side registration state (server-side, out of scope).

