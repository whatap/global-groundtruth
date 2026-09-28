# collectors/apm: language sub-family collectors

> **Status: SEEDED.** `java/` holds a working v0
> ([java/collect-apmjava.sh](java/collect-apmjava.sh), see
> [java/README.md](java/README.md)), `python/` holds a working v0
> ([python/collect-apmpython.sh](python/collect-apmpython.sh), see
> [python/README.md](python/README.md)), `nodejs/` holds a working v0
> ([nodejs/collect-apmnodejs.sh](nodejs/collect-apmnodejs.sh), see
> [nodejs/README.md](nodejs/README.md)), `php/` holds a working v0
> ([php/collect-apmphp.sh](php/collect-apmphp.sh), see
> [php/README.md](php/README.md)), and `dotnet/` holds a working v0
> for Windows hosts ([dotnet/collect-apmdotnet.ps1](dotnet/collect-apmdotnet.ps1),
> PowerShell 5.1+, see [dotnet/README.md](dotnet/README.md); Linux .NET hosts
> not covered yet). Each collector will be owned by its agent's developers
> (CONTRACT rule 4); until handover they are managed by the Global team.

## Note: this domain has language sub-families

APM is not one collector but a **family, one per language runtime**:
`nodejs`, `java`, `python`, `php`, `dotnet`. Each has its own attach mechanism
and its own hidden facts, so each gets its own collector script under this
directory (e.g. `apm/java/…`, `apm/nodejs/…`).

## (a) Hidden facts to collect

Per language runtime, the facts a remote WhaTap agent developer repeatedly asks
a field engineer for:

- **Runtime version**: JVM / Node / Python / PHP / .NET version and vendor.
- **How the agent is attached**: e.g. `-javaagent` on the JVM command line;
  Node `--require` / preload; Python `sitecustomize` / import hook; PHP
  extension (`.ini`); .NET profiler environment variables.
- **Agent version** actually loaded.
- **Agent config**: `whatap.conf` location and contents; relevant `WHATAP_*`
  environment variables.
- **App server / framework** hosting the process.

Discovered from the live process and its environment (CONTRACT rule 2); absent
values reported as `n/a`.

## (b) Delivery mechanism

A **per-language script** run **in-host or in-container** next to the target
process, one command, paste the output (CONTRACT rule 3). In containers, it is
run via `kubectl exec` / `docker exec` into the app container.

## Options the Linux collectors share

All four shell collectors (java, python, nodejs, php) take `--file`,
`--stdout`, `--quiet`, `--help` and `--out DIR` (the directory of the
`--file` report, default `.`; created when missing, and an unwritable one
ends the run with `the report was not written: output directory DIR is not
writable by uid N` before anything is collected, as collserver does).
The `--out` check is the group block `apm: output directory`
([templates/groups/apm.sh](../../templates/groups/apm.sh)). An option that
takes a value and is given none ends the run with exit 2.

## Facts the four Linux collectors print the same way

- **`/sys/class/dmi/id/product_uuid`**, once, in the host section: its
  `ls -l` line and `dmi product_uuid readable by uid N: yes`,
  `no (open failed: <reason>)` or `no (opened, read failed: <reason>)`, from
  an open and a read by the shell (sysfs mode bits alone do not say; one fork,
  the `ls`, when it reads). The value is
  printed, as read, only when it was read. In #ask-dev-apm (C08U55BRDLJ,
  threads p1755497006226229, p1780549458250729, p1781840924638839) a
  root-only `product_uuid` went with an agent that counted the host's CPU
  cores twice, and the file's mode was checked by hand with `docker run ... cat`.
  Group block `apm: report helpers` (`_product_uuid`).
- **Command lines and environ values** (`/proc/<pid>/cmdline`, `environ`) are
  NUL-separated, and an entry can itself hold a newline or a CR. Every one
  the collectors print or parse goes through `_proc_words` (the whole file on
  one line, each NUL, newline and CR as a space) or `_proc_lines` (one entry
  per line, a newline or CR inside an entry as a space); printed as read, a
  newline put the rest of an argument at column 0, where it read as a report
  line of its own (a crafted argument made a fake `[5] Collection status`).
  A cut (`first N bytes`) never ends inside a UTF-8 character: `_u8cut` and
  the awk function `u8cut` share one text. The same holds for a process's
  comm (`_comm`) and the exe, cwd and fd link targets (`_link_text`, `_oneline`),
  which the process also chose. The process table reads exe targets from one
  `ls -l`; a target holding a newline prints a second line that can pose as
  another pid's, so a line naming no `/proc/<pid>/exe`, or a pid named twice,
  makes it read the exe of the pids involved again with readlink. A cwd or an
  environ value (`WHATAP_HOME`) holding a newline or CR is an odd path, as in
  the python / nodejs / php list below: listed quoted, never followed. Group
  block `apm: text helpers`.

## Behaviour the Linux python / nodejs / php collectors share

Same situation, same outcome and the same words in all three:

- **Process matching** reads `/proc` in one pass (comm, argv0, exe for every
  pid) and matches a runtime by any of the three, so an app started from a
  shebang script or with a rewritten process title is still found.
  `environ` and `cwd` are read only for the matches, whatap-marked processes
  are listed first, and the interpreter/binary detail cap (8, 10 for php)
  takes their interpreters first.
- **Agent goal.** A candidate process whose `environ`/`cwd` the run cannot
  read, `hidepid` on `/proc`, or a home path behind a directory the run may
  not search makes an absence `missed` with the privilege hint, never
  `na` ([output-format.md](../../docs/output-format.md), "Three outcomes"). A home that does not
  exist is reported as `path not found`, one the run may not read as
  `permission denied`, in the sections and in the goal reason alike.
- **Port filters** for the socket listings always match the 66xx range
  (nodejs also 67xx) and TCP 6600, plus every port the readable agent
  configuration (`net_udp_port` / `whatap.net_udp_port`,
  `whatap.server.port`) and the port registry name; the report labels each
  port with its source.
- **Caps and timeouts.** The interpreter / PHP binary detail cap (python 8,
  php 10) is raised with `APM_INTERP_CAP=<n>` in the environment, and the
  per-command cap (15 s) with `CMD_TIMEOUT=<s>`. An interpreter over the cap
  that runs a live process makes the agent goal `missed`; one found only on
  disk or PATH is counted in the reason ("N of M probed").
- **Numbers from outside** (config and lock-file ports, `APM_INTERP_CAP`) are
  checked before use: a port must be 1..65535 (also after the nodejs +100),
  a cap 1..999999. A value that fails is reported as a fact ("ignored") and
  not used. Path lists are split on newlines only and never globbed; a
  relative path is never read against the collector's own cwd.
- **Odd paths.** A candidate path holding a newline, a CR or `|` is reported quoted
  and counted as not followed (`missed`), never split. A relative
  `WHATAP_HOME` is resolved against its process's cwd; when that cwd cannot be
  read the process is an unread input while it lives, and a fact once it has
  exited. Without `ss` and `netstat` the raw `/proc/net/udp` and
  `/proc/net/tcp` tables are printed instead; their addresses and ports are
  hex (port 6600 is `19C8`).
- **Key material** (`security.conf`, `paramkey.txt`) is reported per agent
  home as present with its size, or absent; the content is never collected.
- **Environment line** reads `shell: bash <version>` or
  `shell: POSIX sh (non-bash)`.

Each collector README lists what its report can contain under "What the
report can contain".

## (c) How to implement

Copy [../../templates/collector-skeleton/](../../templates/collector-skeleton/)
once per language, follow
[../../docs/authoring-guide.md](../../docs/authoring-guide.md), keep to facts
only, and validate each with `tools/validate.sh`.
