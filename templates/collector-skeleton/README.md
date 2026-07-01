# collector-skeleton

The starter for a new collector. It already emits the shared report shape
(header → numbered fact sections → footer) defined in
[../../docs/output-format.md](../../docs/output-format.md) and carries the
[CONTRACT](../../CONTRACT.md) as a comment block, so you only add facts.

## Use it

1. Copy the script into your domain:

   ```sh
   cp templates/collector-skeleton/collector-skeleton.sh \
      collectors/<domain>/<collector-name>.sh
   ```

2. Set the four metadata variables at the top: `COLLECTOR_NAME`, `VERSION`,
   `DOMAIN`, `TARGET`.

3. Replace the placeholder sections with your domain's facts, using the helpers:

   | Helper            | Emits                                                        |
   |-------------------|-------------------------------------------------------------|
   | `section "TITLE"` | the next numbered section header (`[1]`, `[2]`, …)           |
   | `fact "text"`     | one fact line under the current section                     |
   | `try CMD [ARGS]`  | the command's output as fact lines, or `n/a` if it fails    |

   Keep to **facts only** (Contract rule 1) and **discover, don't assume**
   (Contract rule 2 — resolve symlinks/mounts/config; when a value is absent,
   report `n/a` rather than a default).

4. Validate before committing:

   ```sh
   tools/validate.sh collectors/<domain>/<collector-name>.sh
   ```

Full walkthrough: [../../docs/authoring-guide.md](../../docs/authoring-guide.md).

## Do not edit

`emit_header`, `section`, `fact`, `try`, and `emit_footer` produce the shared
format that `validate.sh` and every reader depend on. Add sections; leave the
helpers alone. The script intentionally does **not** use `set -e` — a collector
must always run to completion and emit its footer.
