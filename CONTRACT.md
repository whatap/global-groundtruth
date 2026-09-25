# CONTRACT

Every collector in this repository — in every domain, now and in the future —
**must** obey the four rules below. They are non-negotiable. A collector that
breaks any of them does not belong in `global-groundtruth`.

`tools/validate.sh` mechanically enforces the parts that can be checked by a
machine: on the source, Rule 1's vocabulary as a keyword list, the presence of
the header labels, the footer, the goals and the environment-section calls; on
a report (`--report`), the header, the numbering, the environment section, the
status arithmetic and the footer. A keyword list is not a reading of every sentence, so the rest of
Rule 1, and all of Rules 2 to 4, are enforced by review.

---

## 1. Facts only

No diagnosis. No "likely cause." No recommendation. No fix. No severity.

A collector reports **what is**, never **what it means**. **No report line may
state a conclusion.**

This rule binds **the script and its report — not people**. Field engineers,
partners, and customers can and do form judgments about a case; that is their
normal work. The collector's purpose is to gather the logs and facts that let
any such judgment be **verified or refuted**. Interpretation happens outside
the report — by the people reading it (typically a remote WhaTap agent
developer, but also the engineer on site).

> If a line could start with "so you should…", "this is probably…", or
> "the problem is…", it violates this rule. Delete the judgment; keep the fact.

A fact section holds **observed values only**. Two kinds of line that are not
judgments still do not belong there:

- **Explanation** — what a field means, how the product behaves, what a
  vendor's source says ("the 0.5.x line has no master agent"). It is true of
  the product, not observed on this host, and it goes in the collector's
  README.
- **Next steps** — "check binlog_format in section C", "rerun with --sql". The
  one next step a report may carry is *how to run this collector differently to
  obtain what it did not*, and it lives only in the `Collection status` section
  and on stderr, attached to the goal it would obtain (`run again with sudo`,
  `rerun with --sql`, `run it on the DB host`).

### Saying whether the collection worked

Rule 1 governs claims about **the environment**. It does not stop a collector
from stating facts about **its own run**.

`goal` / `got` / `missed` and the `Collection status` section exist for that.
`status: INCOMPLETE — module configs not obtained: uid 3103 cannot reach
/data/whatap` says nothing about the customer's system; it says what this
process did and did not read. A reader still draws every conclusion about the
environment themselves.

This is required rather than optional, because the alternative breaks rule 3. A
report full of `n/a (permission denied)` reads as finished to an operator whose
terminal only said `>> done.`; deciding whether the run is worth sending then
becomes interpretation, and rule 3 says the field is not asked to interpret.
The facts are on the host while the operator is still logged in, so the
collector says so there.

The wording stays inside rule 1's vocabulary: name what was not obtained and
why, never what it means or what to do about the system.

It also does not turn a normal environment into a failure. An absence is marked
`na` when it is itself the answer — no ZFS on a host that does not use ZFS, no
DBX component on a database host, no agent where the product is not installed
and every place it would show was read — and the run is still COMPLETE. Only a **blocked** value, one a different run
would obtain, makes it INCOMPLETE. A collector that reports an ordinary host as
INCOMPLETE teaches the field to ignore the line, and then it protects nothing.

The opposite mistake is worse, because nobody notices it: a run that could not
see reports "not there". So an absence is `na` only when **every input the
judgment rests on was read**. If any of them was unreadable, or the call that
would have shown it failed, was refused or timed out, the absence is `missed`.
"No agent process" from a non-root run that could not read other users'
`/proc/<pid>/environ` is `missed`; "no CR" from an API call that was forbidden
is `missed`; "no ZFS" from a host whose `/proc/spl` does not exist is `na`. See
[docs/output-format.md](docs/output-format.md), "Three outcomes, not two".

`validate.sh` fails any collector whose **source** contains the words
`likely`, `diagnos`, `recommend`, `should`, `root cause`, or `fix`
(case-insensitive) on a non-comment line. That is a keyword list, not a proof:
a judgment phrased in other words ("probably", "the problem is") passes it, and
a word inside a trailing comment fails it. It catches the common slip; review
catches the rest. See [tools/validate.sh](tools/validate.sh) for how comments and
the footer sentinel are excluded. Environment content **quoted verbatim** into
a report (a distro-shipped file, a vendor config comment) may happen to
contain these words; that is a fact being reported, not a judgment being made,
and the validator deliberately does not inspect runtime output.

## 2. Discover, never assume

Prefer **resolving** the environment over **hardcoding** it. Resolve symlinks,
read mounts, parse process arguments, and dump config — so that a new or exotic
environment produces correct facts **with no code change**.

> Example of the intent: to report where container logs actually live, resolve
> the symlink target of `/var/log/containers/*.log` rather than assuming a fixed
> path. A standard cluster and a Huawei CCE cluster then both report correctly
> from the same code. See [docs/coverage-kb/k8s-huawei-cce.md](docs/coverage-kb/k8s-huawei-cce.md).

When a value cannot be discovered, say so as a fact (`n/a`, `not found`) — never
substitute an assumed default silently.

## 3. One field command → paste output

The field engineer runs **one thing** and copies the **entire** result. That is
the whole interaction. They are not asked to interpret, edit, or select.

> A collector's delivery mechanism (a shell script, a Job manifest, a SQL dump)
> exists to make this true. If using it requires the field engineer to make a
> judgment call, the collector is not done.

## 4. Domain-team owned

The framework owner provides the contract, the shared format, the template, and
the validator — and, at most, a **v0** of a collector to seed a domain.

Until a domain team is ready to take a collector over, the framework owner is
its **interim owner** — it manages the stub and any seeded v0. Handover then
transfers **ongoing** ownership to the domain's developers.

**Ongoing ownership of each collector belongs to that domain's developers** —
the people who know which hidden facts their agent actually needs. A new
collector is added by copying the template and following
[docs/authoring-guide.md](docs/authoring-guide.md); the framework owner does not
have to write it.
