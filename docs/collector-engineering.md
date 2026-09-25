# Collector engineering guidelines

`CONTRACT.md` says **what** a collector must be (facts only; discover, never
assume; one command; domain-owned). This document says **how** to build one that
survives contact with a real, unknown, possibly-struggling production host.

These five guidelines are the accumulated design philosophy of the framework.
They are enforced by review, as most of the contract is (`validate.sh` checks
only what a machine can; see CONTRACT.md). A collector that ignores them will
eventually mislead a reader, add load to a sick server, break on an OS its
author never saw, or hide *why* a value is missing. Follow them; the seed
collector
[`collectors/collection-server/collect-collserver.sh`](../collectors/collection-server/collect-collserver.sh)
is the reference implementation.

---

## 1. MECE sections — every fact in exactly one place

Organize the report into **M**utually **E**xclusive, **C**ollectively
**E**xhaustive domains. Each fact belongs to one domain and appears once.

- **Mutually exclusive** — do not report the JVM heap flag under both "process"
  and "JVM" sections; pick one home for it. Duplication makes a reader wonder
  which copy is authoritative and whether they differ.
- **Collectively exhaustive** — the domains together cover everything a reader
  needs. Name them up front so a gap is visible.

A cut that works for a server-side component (adapt per domain):

| Domain | Holds |
|--------|-------|
| Host / platform | OS, kernel, arch, CPU/mem, cgroup limits, clock |
| Storage / filesystem | data path, fstype, capacity, mount options |
| Deployment layout | install dir, versions, on-disk structure |
| Runtime processes | what's running now: pids, flags, ports, unit state |
| Configuration | declared settings (config files) |
| Logs / events | log inventory, error counts, recent tails |

Prefix section titles with a stable letter so the structure is legible and
prose can cite it: `[1] Collection environment`, `[2] A. Host`,
`[3] B. Storage`, …. The number comes from the shared `section` helper; the
letter is part of the title (output-format.md, "Fact sections"). Put the
**capability preamble first** (see §4).

## 2. Load-safe by tier — never make a sick server sicker

A collector often runs *because* something is wrong. The collection itself must
not be the thing that tips a loaded host over. Separate work into tiers and make
anything expensive **opt-in**:

- **Tier 0 — the default report.** Read-only, near-instant commands only.
  **Forbidden by default:** anything that pauses a JVM (`jstack`, and especially
  `jmap -histo:live` / `jmap -dump`, which trigger a full GC / long
  stop-the-world), walks a huge tree (`du -r`, deep `find`), or reads whole
  rotated logs. Prefer `df` over `du`; on ZFS prefer `zfs list` (instant) over
  walking files. Bound log reads (`tail -c <N>`, `tail -n <N>`), never
  whole-file `grep` across rotation history.
- **Tier 1 — bundle of real artifacts** (`--bundle`). Copies logs (size-capped),
  configs, snapshots. Sequential disk reads with caps; still no JVM pause.
  (The skeleton ships Tier 0 only — copy bundle plumbing from a seeded
  collector; see [authoring-guide.md](authoring-guide.md) step 4.)
- **Tier 2 — intrusive, opt-in** (`--threads`, `--heap`, `--du`, …). May pause a
  JVM or hit the data disk. **Off by default**, and print the target and the
  expected impact to **stderr before running** so the operator consents.
- **Every external command is bounded.** Run it through `probe` or
  `_bounded` (shared block), which apply `CMD_TIMEOUT` with `timeout(1)` when
  the host has it and with a shell watchdog when it does not. That includes
  the commands that are easy to forget: capability checks
  (`cmd --help >/dev/null`), version queries of a discovered runtime, bundle
  copies, `journalctl`, `helm`, `zpool`, a DB client. A command that can hang
  and is run bare is a collector that can hang.
- **Budget the whole run, not just each probe.** `RUN_DEADLINE` (300s by
  default) bounds the run: once it has passed, `_bounded` runs nothing more
  and returns as timed out, the facts say `n/a (run deadline reached)`, and
  the status names it, so a sick host still yields a report that reaches its
  footer. Aim for a Tier 0 run that finishes in about a minute on a healthy
  host. If your collector leans on network-dependent probes, fail fast: probe
  reachability once, and when it fails skip the calls that depend on it with
  that one reason instead of timing each of them out.
- **Scale with the host, not per process.** Discovery that forks a command for
  every pid in `/proc` takes seconds on a laptop and minutes on a busy node.
  Filter on what the kernel already gives you (`/proc/<pid>/comm`, `cmdline`)
  before forking anything.

> `jmap -histo:live` forces a full GC. Never use it. If you need a histogram,
> `jmap -histo` (without `:live`) and only under an opt-in flag.

## 3. Portable — assume nothing about the OS

You do not know the target: Ubuntu is common but the version, the container
base, whether systemd or root is present — all unknown. Write for the widest
reach:

- **Read `/proc` and `/sys` first.** `/proc/meminfo`, `/proc/loadavg`,
  `/proc/<pid>/cmdline`, `/proc/<pid>/status`, `/proc/self/mountinfo`,
  `/proc/spl/kstat/zfs/arcstats` need no external binary and no privilege.
  Reach for a command only as a richer alternative.
- **Fall back through command chains**, best-first:
  - ports: `ss -ltnp` → `netstat -ltnp` → parse `/proc/net/tcp{,6}`
  - fstype/mount: `findmnt` → `stat -f -c%T` → `/proc/self/mountinfo` + `df -T`
  - memory: `free` → `/proc/meminfo`
  - services: `systemctl` → process scan (and journal → `n/a` if absent)
- **Avoid non-portable flags.** e.g. `systemctl show --value` needs systemd ≥
  230 (not on Ubuntu 16.04) — parse `systemctl show -p X | cut -d= -f2-` instead.
  GNU-only flags: guard with a `have` check or a fallback.
- **Target bash 3.2+.** No associative arrays (`declare -A`), no `mapfile` /
  `readarray`, no `${var,,}`, no namerefs (`local -n`). Indexed arrays only.
  `export LC_ALL=C` for stable parsing.
- **Never `set -e` / `set -u`.** A collector must reach its footer even when
  every probe fails. Guard each step locally instead.
- **Loop hygiene.** A hand-written counter loop that forgets to increment its
  index is an infinite loop that fills the disk with a runaway report — the
  opposite of load-safe. Prefer `for x in …`; if you must use
  `while [ "$i" -lt "$n" ]`, put the `i=$((i+1))` on the line before `done` and
  re-read it. (This bit the collection-server v0 during development.)

## 4. Reasoned absence — a missing value carries its "why"

Contract rule 2 says report an absent value as a fact, never a guessed default.
Go one step further: say **why** it is absent, so the reader can tell "not
installed" from "we lacked permission" from "it timed out". A bare `n/a` sends
them back into twenty-questions.

Classify every miss:

```
n/a (command not found: <bin>)     the tool isn't on this host
n/a (permission denied: <path>)    we ran without the rights (often non-root)
n/a (path not found: <path>)       the file/dir doesn't exist here
n/a (timed out: <sec>s)            the command hung; we bounded it
n/a (not applicable: <why>)        e.g. "not ZFS", "not systemd"
n/a (empty output)                 the command ran clean but said nothing
```

Two mechanisms make this cheap and consistent — copy them from the reference
collector:

- A **capability preamble** (`[1]`) recording bash version, uid/root, and which
  tools are present/absent. Now every downstream `command not found` is
  pre-explained at the top of the report.
- A **`probe` helper** that wraps a command: `command -v` check → run under
  `timeout` (if available) → classify the exit code and stderr into one of the
  reasons above. And a **`dump_file` / `read_proc`** helper that distinguishes
  path-not-found from permission-denied from empty. See the helper block in
  [`collect-collserver.sh`](../collectors/collection-server/collect-collserver.sh).

Keep reason strings free of judgment words (`fix`, `should`, `likely`,
`recommend`, `diagnos`, `root cause`) so they pass `validate.sh` — describe the
mechanical cause, not what to do about it.

A reason on a fact line and the outcome of a goal must agree. A fact reason of
`permission denied`, `timed out`, `command not found` or a failed call means
the goal it feeds is `missed`, never `na`: the run did not see, so it cannot
say the thing is absent (output-format.md, "Three outcomes"). Test for the
failure explicitly: a glob over an unreadable directory returns the pattern
itself, `find` exits 1 on a denied subdirectory, and `awk`'s exit code is not
the exit code of the command piped into it.

## 5. Operable — the operator sees it working, and discovers how to run it

A collector is run by a field engineer, under stress, on a host they may not
know well. A few conventions keep that interaction unsurprising. The first two
are built into the skeleton (`usage`, `progress`, the `section` helper, the
`main` dispatch), so a collector that copies the skeleton gets them for free —
and every collector must keep them.

- **No arguments prints usage.** Running the collector bare prints its
  usage/help and exits `0` — it does **not** start a collection. A run is
  triggered by an explicit action flag (`--file` writes the `.txt`, `--stdout`
  prints it, `--bundle` adds artifacts). This makes the interface
  self-documenting, and stops an operator from kicking off a heavier-than-they-
  meant run — or waiting on a silent one — just by typing the script name. It
  does **not** weaken Contract rule 3 ("one command → paste"): the domain README
  still names the one exact command (`./collect-collserver.sh --file`), so the engineer
  runs one thing and copies the whole output.

- **One obvious, collision-free name.** The entrypoint is `collect-<token>.sh`,
  where `<token>` matches the collector's output-file prefix
  (`whatap-<token>-…`) — the seed is `collect-collserver.sh` → `whatap-collserver-…`.
  Never a bare `collect.sh`: collectors get copied into `$WHATAP_HOME/bin`, sit
  next to each other, and are named in support chats, so identical filenames
  collide or get run by mistake. See [authoring-guide.md](authoring-guide.md)
  step 2; `tools/validate.sh` enforces the `collect-*.sh` shape.

- **Progress on stderr, never in the report.** A collector often runs *because*
  a host is sick, and its journal/log/filesystem scans can take many seconds;
  silent output looks like a hang. Narrate each phase so the operator sees it
  working — but keep it **out of the report**, which must stay byte-for-byte the
  facts shape (a reader or a script parses stdout / the `.txt`). The mechanism:

  ```sh
  exec 3>&2   # in main, BEFORE any redirection: fd 3 = the terminal
  progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }
  ```

  fd 3 is saved from stderr *before* the report redirects stdout (and, in
  `--file` mode, stderr too), so progress still reaches the terminal while the
  report goes to the file. The shared `section` helper calls `progress` itself,
  so per-section progress is automatic; add explicit `progress` lines only for
  phases outside a section (discovery, artifact copy, "writing report to …").
  `--quiet` silences it for automation. Progress lines are facts about
  collection *state* and carry **no judgment words**, so `validate.sh` — which
  greps the whole file — still passes. Messages the operator *must* see
  regardless of `--quiet` (Tier 2 impact/consent, a hard error, a skipped step)
  go through `warn`, which writes `!! …` to fd 3 and ignores `--quiet`. Never
  write them to plain stderr: in `--file` mode the report body's stderr is
  discarded.

- **Leave nothing behind.** Put every temporary file under the run's own
  directory (`_tmp NAME` in the shared block returns a path in it). The shared
  block removes that directory on exit and on INT, TERM and HUP, so a Ctrl-C
  does not leave copies of configs or thread dumps in `/tmp`. Never build a
  temp path from `$$` under a shared directory; a root run writing to a
  predictable name follows whatever symlink is planted there.

---

## Checklist (in addition to the authoring-guide checklist)

- [ ] Sections are MECE — each fact appears once, in one domain; domains are named.
- [ ] Default run is Tier 0: no JVM attach, no recursive `du`, no whole-log grep.
- [ ] Every external command runs through `probe` / `_bounded`; the run
      reaches its footer on a host where every command hangs.
- [ ] Expensive work is opt-in and announces its impact on stderr first.
- [ ] `/proc`/`/sys` used where possible; external commands have fallbacks.
- [ ] bash 3.2+ only; no `set -e`/`set -u`; counter loops increment.
- [ ] Every absent value carries a classified reason; the `[1]` capability
      preamble is present.
- [ ] A goal is `na` only when every input behind it was read; a failed,
      refused, unreadable or timed-out input makes it `missed`.
- [ ] Reason/label strings contain no judgment words (`validate.sh` passes).
- [ ] No-args prints usage and exits 0; a run needs an explicit action flag
      (`--file` / `--stdout` / `--bundle`).
- [ ] Progress is narrated on stderr (fd 3), never into the report; `--quiet`
      suppresses it; progress strings carry no judgment words.
- [ ] Must-see messages use `warn` (fd 3, not silenced), never plain stderr.
- [ ] Temporary files live under `_tmp`; nothing is left after Ctrl-C.
