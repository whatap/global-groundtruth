# CONTRACT

Every collector in this repository — in every domain, now and in the future —
**must** obey the four rules below. They are non-negotiable. A collector that
breaks any of them does not belong in `global-groundtruth`.

`tools/validate.sh` mechanically enforces the parts that can be checked by a
machine (Rule 1's vocabulary, the required header, the exact footer). The rest
is enforced by review.

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

`validate.sh` fails any collector whose **source** contains the words
`likely`, `diagnos`, `recommend`, `should`, `root cause`, or `fix`
(case-insensitive) on a non-comment line — that is, in any string the script
could emit. See [tools/validate.sh](tools/validate.sh) for how comments and
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
