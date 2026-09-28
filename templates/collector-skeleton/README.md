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
   name), `TARGET` (`<kind>/<name>[@<qualifier>]`, never an outcome). Start
   `collectors/<domain>/CHANGELOG.md` next to the README with the first entry,
   `- **<VERSION>** — First version.`; the script keeps only the pointer line
   `# History: CHANGELOG.md (next to this file).` above `VERSION`. Every later
   change bumps `VERSION` and adds an entry at the top of that list
   ([../../docs/authoring-guide.md](../../docs/authoring-guide.md) step 2).

3. Replace the placeholder sections with your domain's facts, using the helpers:

   | Helper                 | Emits                                                          |
   |------------------------|----------------------------------------------------------------|
   | `section "TITLE"`      | the next numbered section header (`[1]`, `[2]`, …)             |
   | `fact "text"`          | one fact line under the current section                        |
   | `probe "label" CMD…`   | output as facts, or `label: n/a (<why>)` — the reasoned form   |
   | `probe_merged "label" CMD…` | the same with stderr folded into stdout (tools that answer on stderr) |
   | `read_proc "label" P`  | a `/proc` or `/sys` file's content, or a classified reason     |
   | `_emit_labeled L BODY` | `L: BODY`, or `L:` and BODY's lines indented under it         |
   | `_tool_rows [--path] T…` | the `[1]` tool table rows: `present` (with its path) / `absent` |
   | `… \| _indent PREFIX`  | stdin with PREFIX before each line                             |
   | `_bounded CMD…`        | runs CMD under `CMD_TIMEOUT` and `RUN_DEADLINE`; 124 on a cap  |
   | `_bounded_in FILE CMD…`| the same, with FILE as CMD's stdin (never `< FILE` on `_bounded`) |
   | `SLOW_SEC`             | a bounded call this long or longer is named in the status (3s) |
   | `warn "text"`          | `!! text` to the terminal (fd 3), not silenced by `--quiet`   |
   | `_tmp NAME`            | a path in the run's private directory, removed on exit/Ctrl-C  |
   | `goal` / `got` / `na` / `missed` | declare and resolve what the run came for      |

   Keep to **facts only** (Contract rule 1) and **discover, don't assume**
   (Contract rule 2 — resolve symlinks/mounts/config; when a value is absent,
   report `n/a` rather than a default). Use `probe`/`read_proc` so a missing
   value carries *why* it is missing (guideline 4).

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

`emit_header`, `section`, `fact`, and `emit_footer` produce the shared
format that `validate.sh` and every reader depend on. Add your sections **inside
`run_report()`**; leave the helpers alone. The script intentionally does **not**
use `set -e` — a collector must always run to completion and emit its footer.

The **CLI harness** (`usage`, argument parsing and the `main`
dispatch) and the `run_report()` wrapper are copies you extend, not blocks left
alone: edit only the four metadata variables and the fact sections in
`run_report()`, but the option loop and `main` dispatch are where you add your
collector's own options. It gives every collector the behavior guideline 5
requires: running the script **bare prints usage** (a collection needs an
explicit `--file` / `--stdout`), and it **narrates progress on stderr** so the
operator sees it working. `section` calls `progress` for you, so per-section
progress is automatic; `--quiet` suppresses it. `--out DIR` writes the
`--file` report into DIR, checked before anything is collected. Add your
collector's own options to it by the option conventions of guideline 5 (one
opt-in per feature, caps through the environment).

`probe`, `probe_merged` and `read_proc` are in the synced run helpers, and
`_run_init` sets the error file they write and reads the uid once; the
`_classify_err` they rely on is the collector's own, or its group's (the
reasoned-absence helpers below them): keep, trim, or extend it for your
domain. See guideline 4. The emit helpers come before the CLI harness, because the option
loop calls `_optval`: in every collector the emit block must end before the
first `ARGC=$#` line, where option parsing starts. `sync-shared-block.sh
--apply` inserts a missing emit block just before that line and moves one
found after it; `--check` reports that one OUT OF PLACE. Keep `ARGC=$#` as
the first line of your option parsing.

Five blocks are **synced**, not just copied: emit helpers, privilege, boot
time, run helpers and collection completeness. Change them here, in the
skeleton, and run `tools/sync-shared-block.sh --apply`; `--check` reports
drift. Helpers only some collectors share are **group blocks**, owned by
`../groups/<group>.sh` (or `../groups/<group>.ps1` for the `collect-<stem>.ps1`
collectors — `ps1.ps1` holds the PowerShell port of these blocks): the apm
collectors' `main` is one, `apm: main`, owned by `../groups/apm.sh`; the other
collectors' mains start as copies of the one here and carry their own steps.
The block format itself (banner, end line, `# members:`, STRAY, `place: end`)
is defined once, in
[../../tools/sync-shared-block.sh](../../tools/sync-shared-block.sh). Then run
`tools/test-framework.sh`: it tests the blocks under bash and dash, and runs
every collector through `validate.sh --report`.
