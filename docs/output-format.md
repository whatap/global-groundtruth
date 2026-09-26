# Shared output format

Every collector, in every domain, emits the **same shape**: a header block, a
series of numbered fact sections, and one exact footer line. A reader who has
seen one report can read any report. `tools/validate.sh --report <file>`
checks a produced report against every rule on this page that a machine can
check (header order and values, numbering, the environment section, the status
arithmetic, the footer); `tools/validate.sh <collector>` checks the source.

**Scope.** This shape binds every **collector**: an entrypoint named
`collect-<token>.sh` or `collect-<token>.ps1`. The PowerShell pair carries a
port of the shared block and owes the same lines, streams and outcomes as a
shell collector. A **SQL pack** (`collectors/db/sql/*.sql`) is not a
collector: it is a part a collector or an operator runs against a database, it
produces its own result set, and it owes none of this shape.

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

Everything addressed to the operator goes to the terminal on **fd 3**, which
`main` saves from stderr before any redirection, so it reaches them in
`--file` mode too:

| helper | carries | `--quiet` |
|---|---|---|
| `progress` | run narration (`>> [3] C. Runtime`) | silenced |
| `warn` | what the operator must see: Tier 2 impact before it runs, a hard error, a skipped step (`!! …`) | **not** silenced |
| `notice` | the status roll-up and its gaps | **not** silenced |

The report body's own stderr (the stray messages of the commands it runs) is
discarded in `--file` mode; nothing meant for a person may rely on it. The
PowerShell pair writes the same three with `[Console]::Error.WriteLine`, never
`Write-Host`, which reaches stdout when the script is run as `pwsh -File`.

A run that cannot write its report (an unwritable directory, a full disk) says
so on fd 3 and exits non-zero. It never prints `report written` for a file
that is not there.

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

The five appear in this order, and `validate.sh --report` checks each value:

| Field            | Meaning                                                        | Example                    |
|------------------|----------------------------------------------------------------|----------------------------|
| `Collector:`     | `whatap-<token>`, where `collect-<token>.sh` is the entrypoint | `whatap-apmjava`           |
| `Version:`       | Collector version, `x.y.z`                                      | `0.1.0`                    |
| `Timestamp(UTC):`| Collection time in ISO-8601 **UTC** (`date -u`), ending in `Z` | `2026-07-01T06:30:00Z`     |
| `Domain:`        | One of `k8s`, `server`, `apm`, `db`, `nms`, `collection-server` | `apm`                      |
| `Target:`        | `<kind>/<name>[@<qualifier>]`, no spaces                        | `host/ip-10-0-1-23`        |

- **Domain is the top level only.** It names the directory under `collectors/`,
  not the path below it; `apm/java` is `apm`. What distinguishes the siblings
  is the `Collector:` name. A new domain adds its name to the list above and
  to `validate.sh` in the same change.
- **Target names *what* was inspected**, so that pasted reports from several
  places are told apart. `<kind>` is a lowercase word for the thing (`host`,
  `db-host`, `k8s-cluster`, `collection-server`); `<name>` is its identity;
  the optional `@<qualifier>` narrows it to one instance on that thing (an
  install path, a namespace, a pool list). It is an identity, never a
  judgment and never an outcome of the run: a qualifier that could not be
  discovered is left out, not written as `@unresolved` or as an error text.
  An outcome belongs in the status section.
- **The output file is named `whatap-<token>-<host>-<UTC>.txt`** (and
  `.tar.gz` for a bundle), so the entrypoint, the `Collector:` line and the
  file share one token.

## Fact sections

- Numbered from `[1]`, in order: `[1]`, `[2]`, `[3]`, … The shared `section`
  helper assigns the number; nothing else prints one. `[1]` is always the
  collection environment (see below) and the last section is always
  `Collection status`.
- Each has a short, factual **TITLE** (a noun phrase — "Container log paths",
  not "Log path problems").
- Section bodies contain **facts only** — observed values, resolved paths,
  command output. A value that could not be obtained is itself a fact: print
  `n/a` or `not found`, never a guess.
- No line states a cause, a severity, or an action. (Rule 1.)
- No line explains what a value means or how the product behaves, and no line
  tells the reader what to do next. Explanations go in the collector's README;
  the one kind of next step a report carries, how to run the collector
  differently, goes in the status section. (CONTRACT rule 1.)

> **Letter labels.** Collectors commonly prefix the titles of their MECE
> domains with stable letters — `[2] A. Host & platform`, `[3] B. Time &
> clock` — so prose (domain READMEs, case notes) can say "section B" without
> breaking when a new section is inserted and the automatic numbers shift.
> The letter is **part of the title**, chosen by the author; the `[n]` is
> emitted by the shared `section` helper and is purely positional. Both name
> the same section — when cross-referencing, prefer the letter.

## The collection environment (`[1]`)

The first section, `[1] Collection environment`, holds the facts about this run
rather than about the target: the shell, the uid, the privilege, the host boot
time, the tools present. Older prose calls it "section 0"; it is `[1]`.

It carries three lines that `validate.sh --report` requires, in this section
and nowhere else:

```
    privilege: not root (uid 3103)
    host boot(UTC): 2024-05-08T02:11:40Z
    host uptime(s): 75102322
```

The boot lines come from `_note_boot` in the shared block. Nearly everything a
collector reports is cumulative since boot, and without them those are sums
with no denominator.

### Privilege

The environment section carries one `privilege:` line.

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
`PRIV_WHY` and `PRIV_GAP` once, before the environment section reads them, and `_priv_hint`
appends the gap to the reason of any goal that privilege blocked — so the gap
reaches the operator's terminal on the same line as what it cost:

```
>>   mysql login — access denied (not elevated: run again with sudo)
```

Three rules for the author.

- **A collector never elevates itself.** The operator runs it with sudo when a
  goal needs root. Probing sudo logs a security event on a host whose account is
  not in sudoers, and doing it from a shell script (sudo -v, re-exec, a password
  hand-over) breaks in edge cases no test finds first.
- **The hint states the run was not elevated; it does not promise sudo helps.**
  Guessing from an error code whether root would succeed was wrong as often as
  right, so every goal a non-root run left blocked carries the same hint.
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
    run time: 64s of 300s allowed
    host load at start: load 7.90 6.12 5.01; psi avg10 (some/full) cpu 31.20/0.00 io 48.10/40.02 memory 0.00/0.00; mem available 812 of 7821 MiB; procs running 9, blocked 6
    host load at end:   load 9.40 6.80 5.30; psi avg10 (some/full) cpu 28.70/0.00 io 52.33/44.90 memory 0.00/0.00; mem available 790 of 7821 MiB; procs running 7, blocked 8
    bounded calls: 57; stopped at their cap or the deadline: 2; not run past the deadline: 0
    where the time went (every bounded call, summed per command, largest first):
          40.0s  find x2, 2 capped at 20s
          18.2s  (outside bounded calls: shell work and file reads)
           4.1s  du
           1.3s  systemctl show x3
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

**The rule a script can apply by itself.** Every absence rests on inputs: the
files, `/proc` entries, commands, queries or API calls whose empty answer is
the absence. The absence is `na` only when **every one of those inputs was
read and came back empty**. It is `missed` when any of them

- could not be read (permission, `hidepid`, a namespace the run cannot enter),
- was not run (the tool is absent, the run deadline had passed),
- failed, was refused, or timed out.

So a non-root run that finds no agent process but could not read other users'
`/proc/<pid>/environ` is `missed`, with `_priv_hint`; "no WhatapAgent CR" from
a forbidden or failed list call is `missed`; "no pools" from a `zpool list`
that exited non-zero is `missed`. A missing tool is `missed` only when the
thing it would inspect is there: no `zpool` binary on a host with no
`/proc/spl` is still `na`, because `/proc/spl` was read and it answers the
question.

Both directions are expensive. A collector that marks an ordinary environment
INCOMPLETE teaches the field to ignore the line. A collector that marks a
blind run COMPLETE sends a report that answers the question wrongly, and
nobody notices until the case has crossed a time zone. The rule above settles
the second without causing the first: an ordinary host reads its inputs and
finds them empty.

**Resolve once, and the helpers hold you to it.** A goal resolved twice with
different outcomes is counted as blocked and named as such in the status
(`resolved 2 times: missed, got`), because the second call usually hides the
first. A goal resolved but never declared is listed too. Resolve after the
last fallback has run, not at each attempt.

**Requested opt-ins are goals.** An opt-in flag the operator passed
(`--sql`, `--threads`, `--jcmd`, a binlog decode) is something they came for,
so the collector declares a goal for it when, and only when, the flag was
given. Its failure is `missed` and the run is INCOMPLETE. An opt-in that was
not requested declares nothing and does not appear in the status.

**The run deadline.** Every external command runs under a per-command cap
(`CMD_TIMEOUT`), and the whole run under `RUN_DEADLINE` (see
collector-engineering.md, guideline 2). Probes after the deadline are not run;
their facts say `n/a (run deadline reached: <N>s)`, the goals they would have
resolved are `missed`, and the status section says the deadline was reached.
The collector still reaches its footer.

**Where the time went, and why.** A `run deadline reached` or a `timed out`
says what was lost, not what ate the time. So every bounded call is timed (in
ms where the shell or `date` can), the status section always gives
`run time:`, and when any bounded call was slow (`SLOW_SEC`, 3s), stopped at
its cap, or not run past the deadline, it adds:

- `host load at start:` and `host load at end:` — load average, pressure stall
  (PSI avg10, some/full) for cpu, io and memory, available memory, and the
  processes running and blocked on I/O. Read from `/proc` only. The example
  above reads as an I/O-starved host (io PSI 48%, 6–8 blocked), which is why
  `find` hit its cap, not a collector fault.
- `where the time went:` — every bounded call summed per command, the ten
  largest, each with how many were capped or cut at the deadline; the time
  spent outside bounded calls (shell work, file reads); and every command
  that was not run past the deadline (`<cmd> xN not run (deadline)`), however
  many there are.

Only a command's name is kept, plus the subcommand word for tools built that
way (`kubectl get`, `zfs list`, `systemctl show`), never an argument, which
can hold a path or a credential. A name with unusual bytes is shown as `?`.
Collector-specific causes (the API server's latency, the database round trip)
belong in that collector's own facts, so a reader can set them against these
lines.

The same gaps are repeated on **stderr**, and that repetition is **not**
silenced by `--quiet`, so the operator sees them while still logged in to the
host. A report can be full of `n/a (...)` and still look finished to someone
whose console only said `>> done.`.

This is a fact about the run, not about the environment, so it does not cross
CONTRACT rule 1 — see CONTRACT.md, "Saying whether the collection worked".
`validate.sh` fails a collector that declares no goals or never calls
`emit_status` (`Emit-Status` in PowerShell), and `validate.sh --report` fails a
report whose `goals:` line does not add up or whose status line is missing.

Authors declare goals at the top of the report body and resolve each exactly
once:

```sh
goal   conf "module configs"
got    conf                                      # obtained
na     conf "no whatap home in any readable process, unit or install path" # still COMPLETE
missed conf "uid 3103 cannot reach /data/whatap"   # blocked; INCOMPLETE
```

In PowerShell the same three are `Set-Got`, `Set-Na` and `Set-Missed`.

Keep the list short. A goal is something whose absence makes the report not
worth sending — not every value the collector happens to print. Resolve goals
where the discovery variables are final, not inside a `| while` pipeline: that
runs in a subshell and the assignment does not survive.

The shared blocks (emit helpers, privilege, boot time, run helpers, completeness) are
identical in every shell collector and owned by the skeleton. Each runs from
its `# ---- <name> — DO NOT EDIT` banner to its `# ---- end <name>` line.
`tools/sync-shared-block.sh --check` reports drift; `--apply` re-copies them.
Other helpers a collector carries (`section`, `fact`, `probe`, the CLI) start
as copies of the skeleton and may be extended; the synced blocks may not.

A `na` reason says what the run read, not what the environment is: "no whatap
home in any readable process, unit or install path" rather than "WhaTap is not
installed". The reader draws the second from the first.

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
