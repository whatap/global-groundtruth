# collector-skeleton

The starter for a new collector. It already emits the shared report shape
(header → numbered fact sections → footer) defined in
[../../docs/output-format.md](../../docs/output-format.md) and carries the
[CONTRACT](../../CONTRACT.md) as a comment block, so you only add facts.

## Use it

1. Copy the script into your domain:

   ```sh
   cp templates/collector-skeleton/collector-skeleton.sh \
      collectors/<domain>/collect-<token>.sh
   ```

   Name it `collect-<token>.sh` (never a bare `collect.sh`) — `<token>` matches
   the output-file prefix `whatap-<token>-…`, so no two collectors collide when
   copied side by side. `validate.sh` enforces this; see
   [../../docs/authoring-guide.md](../../docs/authoring-guide.md) step 2.

2. Set the four metadata variables at the top: `COLLECTOR_NAME`
   (`whatap-<token>`), `VERSION` (`x.y.z`), `DOMAIN` (the top-level directory
   name), `TARGET` (`<kind>/<name>[@<qualifier>]`, never an outcome).

3. Replace the placeholder sections with your domain's facts, using the helpers:

   | Helper                 | Emits                                                          |
   |------------------------|----------------------------------------------------------------|
   | `section "TITLE"`      | the next numbered section header (`[1]`, `[2]`, …)             |
   | `fact "text"`          | one fact line under the current section                        |
   | `try CMD [ARGS]`       | the command's output as fact lines, or a bare `n/a`            |
   | `probe "label" CMD…`   | output as facts, or `label: n/a (<why>)` — the reasoned form   |
   | `read_proc "label" P`  | a `/proc` or `/sys` file's content, or a classified reason     |
   | `_bounded CMD…`        | runs CMD under `CMD_TIMEOUT` and `RUN_DEADLINE`; 124 on a cap  |
   | `_bounded_in FILE CMD…`| the same, with FILE as CMD's stdin (never `< FILE` on `_bounded`) |
   | `SLOW_SEC`             | a bounded call this long or longer is named in the status (3s) |
   | `warn "text"`          | `!! text` to the terminal (fd 3), not silenced by `--quiet`   |
   | `_tmp NAME`            | a path in the run's private directory, removed on exit/Ctrl-C  |
   | `goal` / `got` / `na` / `missed` | declare and resolve what the run came for      |

   Keep to **facts only** (Contract rule 1) and **discover, don't assume**
   (Contract rule 2 — resolve symlinks/mounts/config; when a value is absent,
   report `n/a` rather than a default). Prefer `probe`/`read_proc` over `try`
   so a missing value carries *why* it is missing (guideline 4).

   Run every external command through `probe` or `_bounded`: that is also how
   the status learns where the time went (see output-format.md, "Where the time
   went, and why"). A command run outside them is neither capped nor counted.
   Never pipe into `_bounded`: when the script is read from stdin its stdin is
   /dev/null, so write the input to `_tmp` and use `_bounded_in`. Resolve a
   goal `na` only when every input behind it was read (output-format.md,
   "Three outcomes").

4. Validate before committing, the source and a report it produced:

   ```sh
   tools/validate.sh collectors/<domain>/collect-<token>.sh
   collectors/<domain>/collect-<token>.sh --stdout > /tmp/r.txt
   tools/validate.sh --report /tmp/r.txt
   ```

Full walkthrough: [../../docs/authoring-guide.md](../../docs/authoring-guide.md).
Design guidelines (MECE, load tiers, portability, reasoned absence):
[../../docs/collector-engineering.md](../../docs/collector-engineering.md).

## Do not edit

`emit_header`, `section`, `fact`, `try`, and `emit_footer` produce the shared
format that `validate.sh` and every reader depend on. Add your sections **inside
`run_report()`**; leave the helpers alone. The script intentionally does **not**
use `set -e` — a collector must always run to completion and emit its footer.

The **CLI harness** (`usage`, argument parsing and the `main`
dispatch) and the `run_report()` wrapper are shared boilerplate too — leave them
alone and edit only the four metadata variables and the fact sections. It gives
every collector the behavior guideline 5 requires: running the script **bare
prints usage** (a collection needs an explicit `--file` / `--stdout`), and it
**narrates progress on stderr** so the operator sees it working. `section` calls
`progress` for you, so per-section progress is automatic; `--quiet` suppresses it.
`--out DIR` writes the `--file` report into DIR, checked before anything is
collected. Add your collector's own options to it by the option conventions of
guideline 5 (one opt-in per feature, caps through the environment).

The `probe` / `read_proc` reasoned-absence helpers below them are recommended
but optional — keep, trim, or extend them for your domain. See guideline 4.

Five blocks are **synced**, not just copied: emit helpers, privilege, boot
time, run helpers and collection completeness. Each runs from its `# ---- <name> — DO NOT EDIT`
banner to its `# ---- end <name>` line, and `tools/sync-shared-block.sh
--apply` overwrites whatever a collector changed between them. Change them
here, in the skeleton, and run `--apply`; `--check` reports drift.
Helpers only some collectors share are **group blocks**, owned by
`../groups/<group>.sh` (banner `# ---- <group>: <name> — DO NOT EDIT`, a
`# members:` line, end `# ---- end <group>: <name>`); the same tool syncs them
into the members it names and nowhere else. Then run
`tools/test-framework.sh`: it tests the blocks under bash and dash, and runs
every collector through `validate.sh --report`.
