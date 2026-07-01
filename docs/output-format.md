# Shared output format

Every collector, in every domain, emits the **same shape**: a header block, a
series of numbered fact sections, and one exact footer line. A reader who has
seen one report can read any report. `tools/validate.sh` enforces the header
fields and the footer line mechanically.

This shape is the contract's Rule 1 ("facts only") made concrete: sections hold
facts, and nothing else.

This shape is **stdout** (or the `.txt` / the bundle's `report.txt`). A collector's
usage/help text and its run-progress narration are written to **stderr** and are
**not** part of this shape — stdout stays byte-for-byte the report so a reader or a
script can parse it. (See collector-engineering.md guideline 5.)

---

## The shape

```
==== WhaTap Global Groundtruth Collection ====
Collector:      <collector-name>
Version:        <x.y.z>
Timestamp(UTC): <ISO-8601 UTC, e.g. 2026-07-01T06:30:00Z>
Domain:         <k8s | server | apm | db | ...>
Target:         <identity of what was inspected>
===============================================

[1] <SECTION TITLE>
    <fact>
    <fact>

[2] <SECTION TITLE>
    <fact>

==== END OF COLLECTION (no diagnosis by design) ====
```

## Header block

The title line is literally `==== WhaTap Global Groundtruth Collection ====`.

Five fields follow, each on its own line. `validate.sh` requires the label of
each to appear in the collector's output:

| Field            | Meaning                                                        | Example                    |
|------------------|----------------------------------------------------------------|----------------------------|
| `Collector:`     | Name of the collector that produced this report                | `whatap-k8s-env`           |
| `Version:`       | Collector version (`x.y.z`)                                     | `0.1.0`                    |
| `Timestamp(UTC):`| Collection time in ISO-8601 **UTC** (`date -u`)                | `2026-07-01T06:30:00Z`     |
| `Domain:`        | The domain this collector belongs to                           | `k8s`                      |
| `Target:`        | Identity of what was inspected (node / host / service / db)    | `node/ip-10-0-1-23`        |

> `Target` names *what* was inspected so that pasted reports from several places
> are told apart. It is an identity, not a judgment.

## Fact sections

- Numbered from `[1]`, in order: `[1]`, `[2]`, `[3]`, …
- Each has a short, factual **TITLE** (a noun phrase — "Container log paths",
  not "Log path problems").
- Section bodies contain **facts only** — observed values, resolved paths,
  command output. A value that could not be obtained is itself a fact: print
  `n/a` or `not found`, never a guess.
- No line states a cause, a severity, or an action. (Rule 1.)

## Footer

The last line is **exactly**:

```
==== END OF COLLECTION (no diagnosis by design) ====
```

It is a fixed sentinel. It marks the end of the paste and states the design
stance in one line. Do not translate, reword, or decorate it — `validate.sh`
checks for this exact string.

---

## Producing it

Do not hand-format the header and footer in every collector. Copy
[templates/collector-skeleton/](../templates/collector-skeleton/), which emits
this shape for you and provides `section` / `fact` helpers. Then run
`tools/validate.sh` against your script. See
[docs/authoring-guide.md](authoring-guide.md).
