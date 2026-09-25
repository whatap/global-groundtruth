# WhaTap Groundtruth — Field Guide

> **Languages:** English (canonical) · [Bahasa Indonesia](FIELD-GUIDE.id.md) · [ไทย](FIELD-GUIDE.th.md) · [한국어](FIELD-GUIDE.ko.md)

This guide is for the **field engineer** — the person next to the customer's
system. It explains why WhaTap may ask you to run a *collector*, and exactly
how to run one. You do not need any WhaTap-internal knowledge, and you are
never asked to interpret the result.

## 1. Background — why you are asked to run this

When a support case reaches the WhaTap agent development team, the developer
who can interpret the symptom is remote — often in another time zone — and
needs facts about the environment: which runtime, where the logs actually
live, which flags the process runs with. Asking those one at a time over
email or chat costs a round-trip per question, and a case that needs ten
answers can lose two weeks to the back-and-forth.

A **collector** replaces that dialogue. You run one script; it writes one
report file; you send that file back. The report already contains the answers
the developer would have asked for — and the ones they would have asked next.

What the script is, and is not:

- **Read-only by default.** The default run changes no configuration, restarts
  nothing, and attaches to no process. It is designed to be safe even on a
  server that is already struggling.
- **Facts only — no diagnosis.** The report deliberately contains no
  conclusions or recommendations; its last line literally reads
  `==== END OF COLLECTION (no diagnosis by design) ====`. Interpretation
  happens on the WhaTap side.
- **Nothing for you to judge.** Lines like `n/a (permission denied: ...)` are
  normal — a value that could not be read is itself a useful fact. Do not try
  to "fix" them before sending.

## 2. Get the collector

The collectors live in a Git repository:

```sh
git clone https://github.com/whatap/global-groundtruth.git
```

To update a copy you already have:

```sh
cd global-groundtruth && git pull
```

If the target server has no internet access, clone on your workstation and
copy the single collector script to the server (scp/SFTP/file transfer — one
`.sh` file is all it needs).

## 3. Which collector, when

Your WhaTap contact will name the collector to run:

| WhaTap asks about | Script | Run it where |
|---|---|---|
| The **backend / collection server** (yard, proxy, gateway, ...) | `collectors/collection-server/collect-collserver.sh` | directly on the backend host |
| **ZFS** under a backend's data path (asked for separately) | `collectors/collection-server/collect-collzfs.sh` | directly on that backend host |
| The backend's **MySQL** (`account` / `notihub` metadata; asked for separately) | `collectors/collection-server/collect-collmysql.sh` | on the MySQL host, or any host whose `mysql` client reaches it |
| **Kubernetes** monitoring (operator, node agent, master agent, ...) | `collectors/k8s/collect-k8s.sh` | any machine where `kubectl` (or `oc`) reaches the cluster — a bastion or your workstation, **not** on a cluster node |
| The **NMS Control Manager** (network monitoring) | `collectors/nms/collect-nms.sh` | directly on the NMS Control Manager host |
| **Database monitoring** (DBX/XOS/DMX agents and the monitored DB) | `collectors/db/collect-db.sh` (Windows/MSSQL: `collectors/db/windows/collect-db-mssql.ps1`) | on the DB agent host; for a split install, once on each host |
| **Java** application monitoring | `collectors/apm/java/collect-apmjava.sh` | on the host or container where the Java application runs |
| **Python** application monitoring | `collectors/apm/python/collect-apmpython.sh` | on the host or container where the Python application runs |
| **Node.js** application monitoring | `collectors/apm/nodejs/collect-apmnodejs.sh` | on the host or container where the Node.js application runs |
| **PHP** application monitoring | `collectors/apm/php/collect-apmphp.sh` | on the host or container where the PHP application runs (Apache / PHP-FPM) |
| **.NET** application monitoring (Windows) | `collectors/apm/dotnet/collect-apmdotnet.ps1` | on the Windows host where the .NET application runs, in an elevated PowerShell |

## 4. Run it

Running a collector with **no arguments only prints help** — nothing starts by
accident. A collection always needs an explicit flag; the standard one is
`--file`.

### 4.1 Collection server (backend host)

```sh
cd global-groundtruth/collectors/collection-server
./collect-collserver.sh --file
# -> whatap-collserver-<host>-<timestamp>.txt
```

Send back the `.txt` file it names. If WhaTap asks for the **full bundle**
(real logs + configs, larger file):

```sh
./collect-collserver.sh --bundle
# -> whatap-collserver-<host>-<timestamp>.tar.gz
```

Notes:

- Root is **not required**. Run with the highest privilege your operations
  policy allows — with less privilege the report is still valid, just with
  more `n/a (permission denied)` lines.
- If the report shows the WhaTap home directory as `n/a`, re-run with
  `--home <path>`, e.g. `./collect-collserver.sh --file --home /whatap`.
- When the question is specifically about **ZFS** under the backend's data
  path, WhaTap will ask for the companion collector in the same directory
  (`./collect-collzfs.sh --file`) as well. It is a separate report; send both.
- When the question is about the backend's **MySQL**, run
  `./collect-collmysql.sh --file` on the MySQL host. If the database needs a
  login, give it with `--defaults-file <my.cnf>` or let the collector ask for
  the password on the terminal. Never type a password into the command line:
  other users of the host can read it there.

### 4.2 Kubernetes (bastion / workstation)

```sh
cd global-groundtruth/collectors/k8s
./collect-k8s.sh --file
# -> whatap-k8s-<host>-<timestamp>.txt
```

Send back the `.txt` file it names. If WhaTap asks for the **full bundle**
(YAML + logs, larger file):

```sh
./collect-k8s.sh --bundle
# -> whatap-k8s-<host>-<timestamp>.tar.gz
```

Notes:

- If your kubeconfig is restricted to specific namespaces, add
  `--namespace <whatap-namespace>`.
- On a bastion that reaches several clusters, add `--context <context-name>`.

### 4.3 NMS Control Manager (manager host)

```sh
cd global-groundtruth/collectors/nms
./collect-nms.sh --file
# -> whatap-nms-<host>-<timestamp>.txt
```

Send back the `.txt` file it names. (This collector has no bundle mode yet.)

### 4.4 Database monitoring (DB agent host)

```sh
cd global-groundtruth/collectors/db
./collect-db.sh --file
# -> whatap-db-<host>-<timestamp>.txt
```

Notes:

- For a **split install** (agent on one host, database on another) run it once
  on each host — one file per host.
- If WhaTap also asks for the facts that only the database itself can answer
  (grants, parameters, monitoring objects — the only channel for a managed
  cloud DB such as RDS), they will name the SQL pack for your engine under
  `sql/`, which you run with your usual DB client and send back as well.
- On Windows with MSSQL, use `windows/collect-db-mssql.ps1` instead.

### 4.5 Application monitoring (application host or container)

Run the collector for the application's language, **next to the application
process** — inside the container for a containerized app.

```sh
cd global-groundtruth/collectors/apm/java     # or python / nodejs / php
./collect-apmjava.sh --file
# -> whatap-apmjava-<host>-<timestamp>.txt
```

In Kubernetes or Docker, pipe the script in over stdin instead of copying it
into the container, and take the report on stdout:

```sh
kubectl exec -i <pod> -c <container> -- sh -s -- --stdout --quiet \
    < collect-apmjava.sh > report.txt

docker exec -i <container> sh -s -- --stdout --quiet \
    < collect-apmjava.sh > report.txt
```

On Windows, the .NET collector is a PowerShell script — run it in a **64-bit
elevated** PowerShell:

```powershell
cd global-groundtruth\collectors\apm\dotnet
.\collect-apmdotnet.ps1 -File
# -> whatap-apmdotnet-<HOST>-<UTC>.txt
```

Notes:

- Run as the **same OS user as the application process** where your policy
  allows. With a different user the report is still valid, just with more
  `n/a (permission denied)` lines.
- WhaTap may follow up with a second run carrying extra flags — for example
  `--library <name>` to detail one library, or `--threads` for a thread dump.
  Those are named explicitly; the plain `--file` run never touches the
  application process.

### 4.6 While it runs

- Progress lines starting with `>> ` appear on the terminal so you can see it
  working; they are not part of the report.
- A run takes seconds to a few minutes on a slow host. Let it finish — the
  report always ends with the `==== END OF COLLECTION ... ====` line.
- `n/a (...)` lines in the report are expected. Send the file as-is.
- The **last `>> status:` line** tells you whether the run got what it came for.
  - `status: COMPLETE` — send the file.
  - `status: INCOMPLETE` — the lines under it name what was blocked and how a
    different run would obtain it, for example `run again with sudo` or
    `rerun with --home <dir>`. Do that if your policy allows and send the new
    file. If it does not allow it, send the file as it is: the report says
    what it could not read, and WhaTap takes it from there.
- The Kubernetes, NMS, database and collection-server collectors need `bash`.
  Start them as shown (`./collect-...sh`); under `sh collect-...sh` they stop
  at once and say so.

## 5. Send it back

- Attach the **whole file** exactly as produced (`.txt`, or `.tar.gz` for a
  bundle). Do not edit, trim, rename, or paste fragments.
- Asked to collect from several hosts or clusters? One file per host — the
  filename already carries the hostname and a UTC timestamp, so files never
  collide.

## 6. Security notes

Reports and bundles quote what they read **verbatim** — no masking, by
framework policy: a value such as a license key or a community string must be
readable to be verified or refuted. So a report can carry secrets. Move files
over a trusted channel and delete your local copy when the case is closed.

Where a secret can come from, per collector (each collector's README has the
full list):

| Collector | Can carry |
|---|---|
| collection server | `conf/*.conf` (license, `admin.password`, access keys), `ps aux` in the bundle, heap dumps |
| MySQL | server variables and the process list; never the password you give it |
| ZFS | `zpool history` (the commands that were run on the pools) |
| Kubernetes | environment values of pods and workloads, `helm get values`, the operator's environment. Of Kubernetes Secrets it reads only the public `cert.pem` of the webhook, printed as a fingerprint |
| NMS | NMS configs (access key, SNMP communities), repository files that may carry `user:password@` |
| database | `whatap.conf` (license, `aws_secret_key`, `connect_option`), the JDBC URL, cron lines that mention WhaTap |
| Java / Python / Node.js / PHP / .NET | agent configs, the environment and command line of the application processes, process-manager configs (for example `ecosystem.config.js`) |

The collectors never put a credential you give them on a command line, and the
MySQL collector never writes the password into the report.

## 7. Languages

- This guide is maintained in English (canonical), Bahasa Indonesia, Thai, and
  Korean. If translations disagree, the English version wins.
- The **report output and all script messages are always English, by design** —
  tools parse the exact strings. Do not translate or edit any script output.

## 8. Questions

Anything unclear, or a collector fails to run: contact the WhaTap Global team
(your usual WhaTap support contact) with a screenshot or copy of the terminal
output — that output is itself useful evidence.
