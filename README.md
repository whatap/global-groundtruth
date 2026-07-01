# WhaTap Global Groundtruth

A multi-domain **diagnostic collector framework** for WhaTap support.

Each *collector* gathers the hidden environment facts a remote WhaTap agent
developer needs, so a field engineer runs **one command** and pastes a
**complete report**. This eliminates the diagnostic back-and-forth — the
"twenty-questions" problem — that slows support cases across the K8s, server,
APM, and DB domains.

## Why a framework

The diagnostic pattern generalizes across domains; the collection **code** does
not. So this repository is a shared **contract + format + template + validator**,
plus **per-domain implementations** that domain teams own. One field engineer,
one command, one paste — and the reader (the agent developer) gets ground-truth
facts instead of a questionnaire.

The name says the goal: every report is **ground truth** about the environment —
observed facts, no interpretation.

## The contract in one breath

Read [CONTRACT.md](CONTRACT.md) — it is four rules and non-negotiable:

1. **Facts only** — no diagnosis, no likely-cause, no recommendation, no fix.
2. **Discover, never assume** — resolve symlinks/mounts/config; a new
   environment needs no code change.
3. **One field command → paste output** — the engineer runs one thing, copies all.
4. **Domain-team owned** — the framework owner provides the bones; each collector
   belongs to its domain's developers.

Every report shares one shape (header → numbered fact sections → a fixed
footer): [docs/output-format.md](docs/output-format.md).

## Repository layout

```
global-groundtruth/
├── README.md                     # this charter
├── CONTRACT.md                   # the 4 non-negotiable rules
├── docs/
│   ├── output-format.md          # shared report format spec
│   ├── authoring-guide.md        # how to add a collector
│   ├── collector-engineering.md  # design guidelines: MECE, load tiers, portability, reasoned absence
│   └── coverage-kb/              # environment-specific facts (discover, don't hardcode)
│       └── k8s-huawei-cce.md     # seed entry: Huawei CCE
├── collectors/
│   ├── k8s/                      # STUB (README only)
│   ├── server/                   # STUB (README only)
│   ├── apm/                      # STUB (README only) — one per language: nodejs/java/python/php/dotnet
│   ├── db/                       # STUB (README only)
│   └── collection-server/        # SEEDED v0 — WhaTap backend (yard/proxy/...) collector
├── templates/
│   └── collector-skeleton/       # copy this to start a collector
└── tools/
    └── validate.sh               # lint: enforces facts-only + header + footer
```

## Collector status

| Domain   | Status          | Notes                                              |
|----------|-----------------|----------------------------------------------------|
| `k8s`               | NOT IMPLEMENTED | facts & delivery described in `collectors/k8s/`      |
| `server`            | NOT IMPLEMENTED | host shell script; see `collectors/server/`          |
| `apm`               | NOT IMPLEMENTED | per-language family; see `collectors/apm/`            |
| `db`                | NOT IMPLEMENTED | SQL + agent-config dump; see `collectors/db/`         |
| `collection-server` | SEEDED v0       | backend host script; see `collectors/collection-server/` |

This repository ships the **framework** (contract, format, template, validator,
docs), per-domain **stubs**, and one **seeded v0** collector
(`collection-server`) that the Global team owns until handover. Collectors are
authored and then owned by their domain teams.

## Run a collector (field engineer)

Each collector's `collectors/<domain>/README.md` gives the exact command. The
shape is always the same: run one thing, paste the whole output. No
interpretation required of you.

## Add a collector (domain developer)

1. Copy [templates/collector-skeleton/](templates/collector-skeleton/) into
   `collectors/<domain>/`.
2. Fill in the facts, obeying [CONTRACT.md](CONTRACT.md) and
   [docs/output-format.md](docs/output-format.md).
3. Validate:
   ```sh
   tools/validate.sh collectors/<domain>/<your-collector>.sh
   ```

Full walkthrough: [docs/authoring-guide.md](docs/authoring-guide.md). For a
robust collector — MECE sections, load-safe tiers, portability across unknown
hosts, and reasoned `n/a` — follow
[docs/collector-engineering.md](docs/collector-engineering.md).
