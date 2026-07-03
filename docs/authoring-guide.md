# Authoring guide — add a collector

This guide is for a **domain developer** adding or maintaining a collector. The
framework owner does not have to write it for you (CONTRACT rule 4). If you can
copy a file and answer "what hidden facts does my agent keep asking the field
engineer for?", you can author a collector.

Read [CONTRACT.md](../CONTRACT.md) and [output-format.md](output-format.md)
first. They are short and they are the whole spec. Then read
[collector-engineering.md](collector-engineering.md) — the design guidelines
(MECE sections, load-safe tiers, portability, reasoned absence) that keep a
collector from misleading readers, overloading a sick host, or breaking on an
unfamiliar OS.

---

## Steps

### 1. Decide the facts

Write down the questions your agent's support cases ask over and over — "where
do the logs actually live?", "which runtime?", "what's the DB parameter X?".
Each recurring question is a fact your collector should surface. That list is
your section list. **Stop at facts** — "which runtime" is a fact; "is the
runtime misconfigured" is a judgment and does not belong here.

### 2. Copy the skeleton

```sh
cp templates/collector-skeleton/collector-skeleton.sh \
   collectors/<domain>/collect-<token>.sh
```

Set `COLLECTOR_NAME`, `VERSION`, `DOMAIN`, `TARGET` at the top.

**Name the entrypoint `collect-<token>.sh`** — never a bare `collect.sh`. The
`<token>` is this collector's unique short id, the **same token that prefixes its
output filename** (`whatap-<token>-<host>-<UTC>.txt`); the seed collector is
`collect-collserver.sh` → `whatap-collserver-…`. Two reasons: (1) the script name
and its deliverable share one identifier, and (2) collectors are copied around —
into `$WHATAP_HOME/bin`, next to each other, cited by name in support chats — and
identical `collect.sh` files would collide or be run by mistake. A domain with
per-language collectors (apm) gives each its own token (`collect-apmjava.sh`,
`collect-apmpython.sh`). `tools/validate.sh` enforces the `collect-*.sh` shape.

### 3. Write the sections — obey the two hard rules

- **Facts only** (rule 1). No line may say what a fact *means*. If you catch
  yourself writing "likely", "should", "recommend", "root cause", "fix", or any
  form of "diagnose" in output, delete the judgment and keep the observation.
  The reader interprets.
- **Discover, never assume** (rule 2). Resolve the environment instead of
  hardcoding it: follow symlinks (`readlink -f`), read mounts (`findmnt`), parse
  process arguments (`/proc/<pid>/cmdline`), dump config as-is. A value you
  cannot obtain is a fact too — emit `n/a` via the `try` helper, never a
  fabricated default. This is what lets one collector work in an environment its
  author never saw (see [coverage-kb/](coverage-kb/)).
- **Dump configuration verbatim — do not mask.** Framework policy: WhaTap
  config files carry no plaintext secrets worth masking (genuinely sensitive
  material is stored encrypted), and a masked value destroys the very fact a
  reader needs — a mistyped community string or a wrong server address must be
  readable to be verified or refuted against the other side. If your domain
  ever does hold a plaintext secret, state it in your
  `collectors/<domain>/README.md` security note rather than silently altering
  the report.

Use `section`, `fact`, and `try`; do not hand-format the header or footer.

### 4. Make it one command → paste (rule 3)

The field engineer must run **one** thing and copy **all** of the output. Decide
your delivery mechanism and document it in `collectors/<domain>/README.md`:

- **server / on-node**: a shell script they run directly.
- **apm**: a per-language script run in-host or in-container.
- **db**: a SQL script plus an agent-config dump.
- **in-cluster (k8s)**: a Job manifest whose logs are the report.

The skeleton's CLI harness already makes that "one command" explicit and visible:
running it **bare prints usage** (a collection needs an action flag — `--file` /
`--stdout`), and it **narrates progress on stderr** so the engineer sees it
working on a slow host. Keep both — the exact one command goes in your README.
See [collector-engineering.md](collector-engineering.md) guideline 5.

### 5. Validate

```sh
tools/validate.sh collectors/<domain>/collect-<token>.sh
```

It fails on judgment words in emitted lines, a missing header field, or a
missing/edited footer. Fix the **collector** until it passes — never edit the
validator to make a collector pass.

### 6. Own it

Add or update `collectors/<domain>/README.md`: what facts it collects, how the
field engineer runs it, and its status. From here the collector belongs to your
team.

---

## Checklist

- [ ] Copied from the skeleton; four metadata variables set.
- [ ] Every section is facts only — no cause, no severity, no action.
- [ ] Values are discovered (symlinks/mounts/args/config resolved), not hardcoded.
- [ ] Absent values print `n/a` / `not found`, never a guessed default.
- [ ] One command produces the whole paste.
- [ ] Everything in the script is English — code, comments, usage/help text,
      progress narration, report output. Tools parse the exact strings; see
      the language policy in the root [README.md](../README.md).
- [ ] No-args prints usage; a run needs an explicit action flag; progress is
      narrated on stderr (`--quiet` to suppress). (engineering guideline 5)
- [ ] `tools/validate.sh` passes.
- [ ] `collectors/<domain>/README.md` describes facts, delivery, and status.
- [ ] [collector-engineering.md](collector-engineering.md) checklist met (MECE,
      load tiers, portability, reasoned `n/a`).
