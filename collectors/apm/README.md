# collectors/apm: language sub-family collectors

APM is a **family, one collector per language runtime**, each with its own
attach mechanism and hidden facts. Until handover to each agent's developers
(CONTRACT rule 4) they are managed by the Global team.

| Runtime | Script | README |
|---|---|---|
| Java | [java/collect-apmjava.sh](java/collect-apmjava.sh) | [java/README.md](java/README.md) |
| Python | [python/collect-apmpython.sh](python/collect-apmpython.sh) | [python/README.md](python/README.md) |
| Node.js | [nodejs/collect-apmnodejs.sh](nodejs/collect-apmnodejs.sh) | [nodejs/README.md](nodejs/README.md) |
| PHP | [php/collect-apmphp.sh](php/collect-apmphp.sh) | [php/README.md](php/README.md) |
| .NET (Windows, PowerShell 5.1+; Linux .NET hosts not covered) | [dotnet/collect-apmdotnet.ps1](dotnet/collect-apmdotnet.ps1) | [dotnet/README.md](dotnet/README.md) |

Per runtime, the facts a remote WhaTap agent developer repeatedly asks a field
engineer for: runtime version and vendor, how the agent is attached (`-javaagent`,
Node `--require`, Python `sitecustomize`, PHP extension `.ini`, .NET profiler
variables), the agent version actually loaded, the agent config (`whatap.conf`
and `WHATAP_*` variables), and the app server / framework hosting the process.
They are discovered from the live process and its environment (CONTRACT rule
2); absent values are `n/a`.

## Running a Linux apm collector

Run it **where the application runs**, in-host or in the container, and paste
or attach the entire output. Each README has its field commands. No arguments
prints usage; nothing runs by accident. Progress is narrated on stderr
(`--quiet` silences it).

- **Kubernetes and Docker**: pipe the script over stdin
  (`kubectl exec -i <pod> -c <container> -- sh -s -- --stdout --quiet < collect-<token>.sh > report.txt`),
  so nothing is copied into the pod or written to a possibly read-only rootfs.
- **Use `--stdout` in containers.** `--file` writes to the current directory,
  which fails on `readOnlyRootFilesystem` pods.
- **Distroless or no shell in the app container**: run the collector in an
  ephemeral debug container that shares the pod's process namespace
  (`kubectl debug <pod> -it --image=busybox:stable --target=<container> -- sh`).
  Paths not visible in its own mount namespace are read through
  `/proc/<pid>/root/...` of the discovered agent and app processes.

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

## What every Linux apm report can contain

Nothing is masked. Configuration is dumped verbatim, so a mistyped license or
server address can be verified or refuted. Each README lists the
language-specific places a secret can arrive from; these are common:

- `/sys/class/dmi/id/product_uuid`, when this run can read it.
- Command lines of the app, agent and pid 1 processes (python, nodejs, php:
  first 160-300 bytes, NULs, newlines and CRs as spaces): an argument carrying
  a secret appears as given.
- `WHATAP_*` variables of the app and agent processes, and the agent config
  files.
- Key material (`security.conf`, `paramkey.txt`) is presence and size only, per
  agent home; the content is never collected.

The collector itself puts no credential on a command line.
