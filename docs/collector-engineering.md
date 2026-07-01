# Collector engineering guidelines

`CONTRACT.md` says **what** a collector must be (facts only; discover, never
assume; one command; domain-owned). This document says **how** to build one that
survives contact with a real, unknown, possibly-struggling production host.

These four guidelines are the accumulated design philosophy of the framework.
They are **advisory** (unlike the four contract rules, which `validate.sh`
enforces), but a collector that ignores them will eventually mislead a reader,
add load to a sick server, break on an OS its author never saw, or hide *why* a
value is missing. Follow them; the seed collector
[`collectors/collection-server/collect.sh`](../collectors/collection-server/collect.sh)
is the reference implementation of all four.

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

Prefix section titles so the structure is legible (`[0] Environment`,
`[A] Host`, `[B] Storage`, …). Put a **capability preamble first** (see §4).

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
- **Tier 2 — intrusive, opt-in** (`--threads`, `--heap`, `--du`, …). May pause a
  JVM or hit the data disk. **Off by default**, and print the target and the
  expected impact to **stderr before running** so the operator consents.

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

- A **capability preamble** (`[0]`) recording bash version, uid/root, and which
  tools are present/absent. Now every downstream `command not found` is
  pre-explained at the top of the report.
- A **`probe` helper** that wraps a command: `command -v` check → run under
  `timeout` (if available) → classify the exit code and stderr into one of the
  reasons above. And a **`dump_file` / `read_proc`** helper that distinguishes
  path-not-found from permission-denied from empty. See the helper block in
  [`collect.sh`](../collectors/collection-server/collect.sh).

Keep reason strings free of judgment words (`fix`, `should`, `likely`,
`recommend`, `diagnos`, `root cause`) so they pass `validate.sh` — describe the
mechanical cause, not what to do about it.

---

## Checklist (in addition to the authoring-guide checklist)

- [ ] Sections are MECE — each fact appears once, in one domain; domains are named.
- [ ] Default run is Tier 0: no JVM attach, no recursive `du`, no whole-log grep.
- [ ] Expensive work is opt-in and announces its impact on stderr first.
- [ ] `/proc`/`/sys` used where possible; external commands have fallbacks.
- [ ] bash 3.2+ only; no `set -e`/`set -u`; counter loops increment.
- [ ] Every absent value carries a classified reason; a `[0]` capability
      preamble is present.
- [ ] Reason/label strings contain no judgment words (`validate.sh` passes).
