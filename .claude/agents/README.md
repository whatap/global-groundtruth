# Model routing for collector work

Sub-agents here are split by difficulty, so each piece of work gets the
cheapest model that does it reliably. The caller (the main session) grades
the task, picks the agent, and passes only the task-specific part in the
prompt; the shared procedure lives in the agent file.

## Tiers

| Tier | Agent | Model | Use for |
|---|---|---|---|
| R (run) | `gg-check-runner` | haiku | Run a fixed list of checks and report numbers: `bash -n`, `dash -n`, shellcheck, `sync --check`, `validate.sh`, `tools/test-*.sh`, capture compare (`tools/capture-compare.sh`). No judgement beyond pass/fail and diff lines. |
| M (mechanical) | `gg-verify-mech` | sonnet | Verify a change that should not alter behaviour and is checkable line by line: moved or split functions, CHANGELOG/doc moves, comment edits, helper extraction with identical bodies. |
| A (additive) | `gg-verify-mech` | sonnet | Verify a change that only adds raw facts: a new `cat`/`ls`/`head`/version-file read or a raw command output inside an existing section, with no line removed from any report. Checked by the lab diff (`tools/lab/run.sh`), which must show added lines only. |
| D (deep) | `gg-verify-deep` | opus | Verify anything where behaviour can differ subtly: signals, traps, timeouts, subshells, races; shared skeleton/group blocks (all collectors); parsing of untrusted input; report-changing logic; privilege or security paths; the sync tool itself. |

Authoring follows the same grading: mechanical edits (moves, splits, CHANGELOG
entries) and A-tier additions are written by a sonnet agent; design or D-tier
changes are written by the main session or an opus agent.

## Work that is not a collector change

Lab, reading and survey work is graded the same way: by what a wrong answer
costs, not by how long the task is.

| Work | Agent | Model | Use for |
|---|---|---|---|
| Lab targets | `gg-lab-builder` | sonnet | Build or repair a permanent lab target (VM, docker image/container on `jjsong-ggt-docker`, fixture) and prove it with a collector run. |
| Reading | `gg-reader` | sonnet | Read Slack channels, case folders or docs and return a candidate table, each candidate grepped against the current collectors. |
| Design audit | general-purpose | opus | A survey whose answer is a trade-off (what to cut, what a rule should say), not a list of facts. |
| Report-changing authoring | general-purpose | opus | Writing a D-tier change (see Grading). Mechanical edits and A-tier additions: general-purpose with `model: sonnet`. |

A grep-style coverage audit ("which collector prints X") is Reading, not a
design audit.

## Grading a change

Take the highest tier that any part of the change hits.

- **D** if the diff touches: `trap`, `kill`, `wait`, `&`, `_bounded`, `timeout`,
  `RUN_DEADLINE`, a synced skeleton block, the sync tool, anything under
  `privilege`, redirections of fds other than 1/2, `eval`, or a parser of
  command output whose result decides a goal outcome; or when the report is
  meant to change in any way other than A below: a line or section removed or
  reworded (fact-loss risk, the most frequent defect of 2026-09-27), untrusted
  input parsed into fields (package.json, Secret data, SQL result columns),
  or anything touching credentials that are not WhaTap's.
- **A** if the change only adds raw facts (a file read, a version file, a raw
  command output) inside an existing section, bounded like its neighbours,
  and the lab diff on every target that reaches the new code shows added
  lines only. Until five A verifications have also been run blind by
  `gg-verify-deep` and logged below, each one is; a miss moves A back into D.
- **M** if the change is a refactor that keeps the report byte-identical and
  the author claims it moves code without rewriting it.
- **R** only for re-running checks on an already-verified patch (e.g. after a
  rebase or a one-line fix the caller made).

## Escalation and spot checks

- An M verifier that finds anything it cannot explain, or cannot exercise a
  path it changed, says `ESCALATE: <why>` instead of a verdict; the caller then
  runs `gg-verify-deep` on that part.
- Every fifth M verification (and any M verification of a patch over ~500
  diff lines) is also run by `gg-verify-deep`; a miss moves that kind of
  change to D. Record the outcome in the table below.

## Moving up a model when quality drops

The model in an agent file is the default, not a ceiling. The caller re-runs
the same task one tier up (Agent tool `model: opus`, or `sonnet` for a haiku
task) when any of these happens, and logs it in the table below:

- the agent answers `ESCALATE: <why>`, or says it could not exercise a path it
  was asked to cover;
- a later step contradicts it: a verifier, a check, a collector run or the
  user finds something the agent reported as done, present or safe;
- its output fails the task's own acceptance (a lab target whose collector run
  is not COMPLETE, a candidate table without the grep evidence per row);
- the same task needed a second round with the same model.

Two logged misses of one kind of task at a tier move that kind of task up for
good: change the default here and in the agent file. Going back down needs a
blind calibration like the ones below.

## Waiting for background work

A wait loop must be able to end. `until ! pgrep -f "tools/lab/run.sh …"; do sleep 5; done`
never does: the loop's own shell carries the pattern in its command line, so
pgrep always finds it (three such loops ran for 8–12 h on 2026-09-27). Wait on
the PID you started (`wait $pid`, or `while kill -0 $pid; do sleep 5; done`)
or on the output file, and bound every wait (`timeout 3600 …`). If a pattern
match is unavoidable, bracket one character so the pattern cannot match itself
(`pgrep -f "[t]ools/lab/run.sh"`).

## Calibration log

| Date | Patch | Known defect (found by opus) | Model | Caught? | Note |
|---|---|---|---|---|---|
| 2026-09-27 | r2-shared.patch (skeleton/group consolidation, D) | P1 collmysql --help prints unchecked BINLOG_TIMEOUT; P2 sync inserts a missing emit block after the options loop | haiku | no / no | Verdict "safe to commit" although the prompt named both areas; read base-vs-base deadline noise as "refactored code hits deadline sooner". Not a verifier. |
| 2026-09-27 | r2-shared.patch (D) | P1 / P2 as above | sonnet | no / no | Much more thorough than haiku (traced _cap_or timing, _sd call sites, zprobe) and tested the hinted areas, but chose RUN_DEADLINE/CMD_TIMEOUT for --help (not BINLOG_TIMEOUT) and stripped the emit block from apmjava, where the insert happens to land correctly (the defect shows on k8s). Misses come from choosing one representative case where the defect needs the specific one. |
| 2026-09-27 | fu-skel.patch (_bounded USR1 watchdog, D) | trap's `kill "$!"` (TERM) lost before exec → ~6% of bash watchdog calls +1 s | sonnet | contaminated | Verdict "fix first" for the right line, but found it by diffing against main, where the fix was already committed — not by testing. Its own latency test (best-of-5 totals over 300 calls) saw "no regression": a total/best-of hides a 6% tail. Lesson for every tier: count slow calls (≥500 ms), don't compare totals. |

**Outcome (2026-09-27):** haiku = R only. sonnet = M only, with the exhaustive rule (gg-verify-mech step 7); in both D calibrations it missed the defect by sampling one representative case. opus = D. Re-run a blind calibration when a new model is considered.

**A tier added (2026-09-28):** on 2026-09-27, 35 of 40 sub-agent runs were opus, because "the report is meant to change" put every collector addition in D. About half of those changes only added raw reads (nodejs framework versions, dotnet/mssql version facts, the python pid cap, apmjava version/perm facts). The lab runner now shows such a change as added lines only, which sonnet can check exhaustively; removals, parsers and shared blocks stay D.
