# WhaTap Global Groundtruth

> **Languages:** English (canonical) · [Bahasa Indonesia](README.id.md) · [ไทย](README.th.md) · [한국어](README.ko.md)
>
> **Field engineer?** You do not need this whole page. Read the
> **[Field Guide](FIELD-GUIDE.md)**
> ([Bahasa Indonesia](FIELD-GUIDE.id.md) · [ไทย](FIELD-GUIDE.th.md) · [한국어](FIELD-GUIDE.ko.md))
> — the background, the exact commands, and what to send back.

A multi-domain **diagnostic collector framework** for WhaTap support.

Each *collector* gathers the hidden environment facts a remote WhaTap agent
developer needs, so a field engineer runs **one command** and hands back a
**complete report**. This eliminates the diagnostic back-and-forth — the
"twenty-questions" problem — that slows support cases across the K8s, server,
APM, and DB domains.

## Background

A remote support case usually stalls on environment facts, not on analysis.
The developer who can interpret a symptom sits far from the system that shows
it; the engineer next to the system cannot know in advance which of a thousand
facts the developer will need. So the case proceeds as a question-per-day
dialogue — "which runtime?", "where do the logs actually live?", "which flags
is the JVM running with?" — stretched further by time zones and chat relays.
Ten questions can cost two weeks of calendar time for one hour of real work.

A collector replaces that dialogue with a single artifact: the field engineer
runs one script and sends back one file that already answers the questions the
developer would have asked — and the ones they would have asked next. The name
states the goal: every report is **ground truth** about the environment —
observed facts, no interpretation.

## Why a framework

The diagnostic pattern generalizes across domains; the collection **code** does
not. So this repository is a shared **contract + format + template + validator**,
plus **per-domain implementations** that domain teams own. One field engineer,
one command, one paste — and the reader (the agent developer) gets ground-truth
facts instead of a questionnaire.

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
├── README.md                     # this charter (.id/.th/.ko translations alongside)
├── FIELD-GUIDE.md                # field-engineer guide (.id/.th/.ko translations alongside)
├── CONTRACT.md                   # the 4 non-negotiable rules
├── docs/
│   ├── output-format.md          # shared report format spec
│   ├── authoring-guide.md        # how to add a collector
│   ├── collector-engineering.md  # design guidelines: MECE, load tiers, portability, reasoned absence
│   └── coverage-kb/              # environment-specific facts (discover, don't hardcode)
│       └── k8s-huawei-cce.md     # seed entry: Huawei CCE
├── collectors/
│   ├── k8s/                      # SEEDED v0 — cluster-level collector (operator/CR/agents)
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
| `k8s`               | SEEDED v0       | bastion-run cluster collector; see `collectors/k8s/` |
| `server`            | NOT IMPLEMENTED | host shell script; see `collectors/server/`          |
| `apm`               | NOT IMPLEMENTED | per-language family; see `collectors/apm/`            |
| `db`                | NOT IMPLEMENTED | SQL + agent-config dump; see `collectors/db/`         |
| `collection-server` | SEEDED v0       | backend host script; see `collectors/collection-server/` |

This repository ships the **framework** (contract, format, template, validator,
docs), per-domain **stubs**, and two **seeded v0** collectors
(`collection-server`, `k8s`) that the Global team owns until handover.
Collectors are authored and then owned by their domain teams.

## Run a collector (field engineer)

Start with the **[Field Guide](FIELD-GUIDE.md)** — it names the exact command
per collector. The shape is always the same: run one thing, send back the whole
output. No interpretation is required of you. Per-collector detail lives in
`collectors/<domain>/README.md`.

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

## Documentation language policy

- **Scripts are English only** — code, comments, usage/help text, progress
  narration, and every line of report output. Reports are parsed by tools and
  read by developers across regions; `tools/validate.sh` and the fixed footer
  sentinel depend on the exact English strings. Never translate report output.
- **Field-facing documents** — [FIELD-GUIDE.md](FIELD-GUIDE.md) and this
  README — are maintained in four languages: English plus Bahasa Indonesia
  (`.id.md`), Thai (`.th.md`), and Korean (`.ko.md`).
- **English is canonical.** If a translation lags or disagrees, the English
  file wins. Whoever edits the English file updates the three translations in
  the same change — these documents are deliberately short to keep that cheap.
- Developer documents ([CONTRACT.md](CONTRACT.md), everything under
  [docs/](docs/), collector READMEs) are English only.
