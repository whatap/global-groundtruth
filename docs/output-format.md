# Shared output format

Every collector, in every domain, emits the **same shape**: a header block, a
series of numbered fact sections, and one exact footer line. A reader who has
seen one report can read any report. `tools/validate.sh` enforces the header
fields and the footer line mechanically.

This shape is the contract's Rule 1 ("facts only") made concrete: sections hold
facts, and nothing else.

This shape is **stdout** (or the `.txt` / the bundle's `report.txt`). A collector's
run-progress narration is written to **stderr** and is **not** part of this shape —
stdout stays byte-for-byte the report so a reader or a script can parse it. (See
collector-engineering.md guideline 5.)

Help text is the one thing that shares stdout, and only when no collection runs:
with no arguments or `--help` a collector prints usage to **stdout** and exits,
the ordinary convention for a help request. Usage printed *because a run failed*
(an unknown argument) goes to **stderr** alongside the error.

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

> **Letter labels.** Collectors commonly prefix the titles of their MECE
> domains with stable letters — `[2] A. Host & platform`, `[3] B. Time &
> clock` — so prose (domain READMEs, case notes) can say "section B" without
> breaking when a new section is inserted and the automatic numbers shift.
> The letter is **part of the title**, chosen by the author; the `[n]` is
> emitted by the shared `section` helper and is purely positional. Both name
> the same section — when cross-referencing, prefer the letter.

## Privilege (section 0)

Section 0 carries one `privilege:` line, and `tools/validate.sh` requires it.

```
    uid: 3103
    privilege: not root (uid 3103)
```

What a collection can read is decided by the privilege it was given, so a report
that leaves it out gives the reader no way to tell an absent value from an
unreadable one. Three shapes on a shell collector, and the Windows pair ports
the same line with `elevated` / `not elevated (DOMAIN\user)`:

| Line | What it says |
|---|---|
| `privilege: root` | The run was root already |
| `privilege: root (elevated by sudo from uid 3103)` | It was reached through sudo |
| `privilege: not root (uid 3103)` | It was not, and `run again with sudo` is the gap |

The authoring side is the shared block in the skeleton. `_note_privilege` fills
`PRIV_WHY` and `PRIV_GAP` once, before section 0 reads them, and `_priv_hint`
appends the gap to the reason of any goal that privilege blocked — so the gap
reaches the operator's terminal on the same line as what it cost:

```
>>   mysql login — access denied (not elevated: sudo does not permit this account)
```

Three rules for the author.

- **A collector does not elevate itself, unless elevation is the whole job.**
  One does (`collect-collmysql.sh`: nearly every section is SQL, and a packaged
  MySQL admits root over the unix socket with no password). Everywhere else the
  operator decides, because probing sudo logs a security event on a host whose
  account is not in sudoers.
- **A collector that does elevate takes its reason from whatever refused it.**
  An account sudo does not permit and a run with no terminal to be asked on fail
  identically, and they are answered by different people. `sudo -n` cannot tell
  them apart — it answers "a password is required" to both.
- **The line speaks for the process, not for every authority the run needs.**
  A SQL login or a Kubernetes role is its own goal's business.

## Collection status (last section)

Every report ends, just before the footer, with a roll-up of what the run came
for and whether it got it:

```
[12] Collection status
    goals: 5 declared, 2 obtained, 1 not applicable here, 2 blocked
    obtained: running whatap modules, log inventory
    not applicable to this host (this is an answer, not a gap):
        yard data path — this host runs no yard
    blocked (running this differently would obtain these):
        WHATAP_HOME contents — uid 3103 cannot reach /data/whatap
        module configs — uid 3103 cannot reach /data/whatap
    status: INCOMPLETE
```

### Three outcomes, not two

The status answers one question for the operator: **send this, or change
something and run again?** So an absence is split.

| outcome | meaning | effect |
|---|---|---|
| `got` | obtained | — |
| `na` | legitimately absent. It IS the answer, and no re-run changes it | still COMPLETE |
| `missed` | this run was blocked. Running it differently would obtain the value | INCOMPLETE |

`na` covers the normal shape of a host: no ZFS on a host that does not use ZFS,
no DBX component on a database host, no binary logs when `log_bin` is off, no
agent on a machine where the product is not installed. `missed` covers a
permission, a missing tool, a timeout, an unreadable path.

**Getting this wrong in the `missed` direction is the expensive mistake.** A
collector that marks an ordinary environment INCOMPLETE teaches the field to
ignore the line, and then it protects nothing. When unsure, look at whether a
second run — as another user, with another flag, from another host — would
change the outcome. If not, it is `na`.

The same gaps are repeated on **stderr**, and that repetition is **not**
silenced by `--quiet`, so the operator sees them while still logged in to the
host. A report can be full of `n/a (...)` and still look finished to someone
whose console only said `>> done.`.

This is a fact about the run, not about the environment, so it does not cross
CONTRACT rule 1 — see CONTRACT.md, "Saying whether the collection worked".
`validate.sh` fails a collector that declares no goals or never calls
`emit_status` (`Emit-Status` in PowerShell).

Authors declare goals at the top of the report body and resolve each exactly
once:

```sh
goal   conf "module configs"
got    conf                                      # obtained
na     conf "WhaTap is not installed on this host" # the answer; still COMPLETE
missed conf "uid 3103 cannot reach /data/whatap"   # blocked; INCOMPLETE
```

In PowerShell the same three are `Set-Got`, `Set-Na` and `Set-Missed`.

Keep the list short. A goal is something whose absence makes the report not
worth sending — not every value the collector happens to print. Resolve goals
where the discovery variables are final, not inside a `| while` pipeline: that
runs in a subshell and the assignment does not survive.

The helper block is identical in every collector and owned by the skeleton.
`tools/sync-shared-block.sh --check` reports drift; `--apply` re-copies it.

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
