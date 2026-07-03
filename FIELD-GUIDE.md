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

Your WhaTap contact will name the collector to run. Two exist today:

| WhaTap asks about | Script | Run it where |
|---|---|---|
| The **backend / collection server** (yard, proxy, gateway, ...) | `collectors/collection-server/collect-collserver.sh` | directly on the backend host |
| **Kubernetes** monitoring (operator, node agent, master agent, ...) | `collectors/k8s/collect-k8s.sh` | any machine where `kubectl` (or `oc`) reaches the cluster — a bastion or your workstation, **not** on a cluster node |

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

### 4.3 While it runs

- Progress lines starting with `>> ` appear on the terminal so you can see it
  working; they are not part of the report.
- A run takes seconds to a few minutes on a slow host. Let it finish — the
  report always ends with the `==== END OF COLLECTION ... ====` line.
- `n/a (...)` lines in the report are expected. Send the file as-is.

## 5. Send it back

- Attach the **whole file** exactly as produced (`.txt`, or `.tar.gz` for a
  bundle). Do not edit, trim, rename, or paste fragments.
- Asked to collect from several hosts or clusters? One file per host — the
  filename already carries the hostname and a UTC timestamp, so files never
  collide.

## 6. Security notes

- The **collection-server** report and bundle include configuration files
  **verbatim** — license keys, `secure.conf`, admin passwords. Transfer them
  only over the channel your WhaTap contact names (never a public chat), and
  delete your local copy when the case is closed.
- The **k8s** collector masks license/password/certificate values and never
  reads Kubernetes Secret contents — but its bundle still contains real logs.
  Handle it the same careful way.

## 7. Languages

- This guide is maintained in English (canonical), Bahasa Indonesia, Thai, and
  Korean. If translations disagree, the English version wins.
- The **report output and all script messages are always English, by design** —
  tools parse the exact strings. Do not translate or edit any script output.

## 8. Questions

Anything unclear, or a collector fails to run: contact the WhaTap Global team
(your usual WhaTap support contact) with a screenshot or copy of the terminal
output — that output is itself useful evidence.
