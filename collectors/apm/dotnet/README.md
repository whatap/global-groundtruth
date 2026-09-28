# collectors/apm/dotnet — WhaTap .NET APM agent collector (Windows)

> **Status: SEEDED (v0; validated at: 0.6.0 on Windows Server 2022 Standard
> Evaluation 10.0.20348 under Windows PowerShell 5.1.20348.558 and pwsh 7.6.6,
> elevated and not elevated, with a simulated agent, 2026-09-26; see
> "Validation" below).**
> `collect-apmdotnet.ps1` is a working Tier-0
> collector seeded by the Global team (CONTRACT rule 4 — interim ownership).
> Ongoing ownership belongs to the .NET agent developers once handed over.
> Linux .NET hosts are **not covered yet** (see "Not covered" below).

Collects the hidden facts a remote WhaTap .NET-agent developer repeatedly asks
a field engineer for, from the Windows host where the instrumented application
runs. The fact list was derived from an exhaustive review of `#ask-dev-apm`
.NET support threads (2025-06 .. 2026-08), verified against the `dotnet-apm`
source repo (installer `release.iss`, `Whatap.ClrProfiler`, `Whatap.Tracer`,
`Whatap.Loader`, `Whatap.Startup`) and docs.whatap.io (install-check,
supported-spec).

**Why version identification is the first fact.** The agent's native and
managed DLLs ship with FileVersion pinned at `1.0.0.0` across product
releases, and the GAC folder names (`v4.0_1.0.0.0__…`) never change. The only
trustworthy product-version markers on a host are the uninstall registry
(`HKLM\...\Uninstall\WhaTap .NET_is1` → `DisplayVersion`) and the
mtime/SHA256 of the profiler DLL copies — so the collector captures all of
them, plus the version lines the agent writes into its own logs. Multiple
support threads hinged on "reported version ≠ version actually on disk".

**How the agent attaches (what the sections verify).** The installer writes
`WHATAP_*` keys to the machine environment, but the CLR injection variables
(`COR_ENABLE_PROFILING`, `COR_PROFILER`, `COR(ECLR)_PROFILER_PATH_32/64`,
`DOTNET_STARTUP_HOOKS`) go into the **W3SVC and WAS service registry
`Environment` (multi-sz)** — IIS worker processes only. The tracer sends
UDP to `127.0.0.1:6600` where the `WhaTap .NET` service (`whatap_dotnet.exe
-t 7`) relays TCP to the collection server on the same port number. Only the
IIS HTTP pipeline is instrumented (self-hosted Windows services are not), so
IIS topology and w3wp loaded-module facts close the loop between "configured"
and "actually attached".

## One field command

Run **on the Windows host where the application runs**, in a **64-bit
elevated** PowerShell (5.1+, the Windows Server 2016+ default). Without
elevation the IIS/event-log/module probes degrade to reasoned `n/a` lines, and
a `whatap.conf` the account cannot read makes the run INCOMPLETE with the hint
`not elevated: run PowerShell as Administrator`.

```powershell
# PowerShell (administrator)
.\collect-apmdotnet.ps1 -File     # -> whatap-apmdotnet-<HOST>-<UTC>.txt

# if script execution is blocked by policy
powershell -ExecutionPolicy Bypass -File .\collect-apmdotnet.ps1 -File

# extra install dir the discovery cannot see (-AgentHome works too)
.\collect-apmdotnet.ps1 -File -Home "D:\WhaTap .NET"

# write the report into another directory (checked before the run starts)
.\collect-apmdotnet.ps1 -File -Out "D:\case files"
```

Paste or attach the entire output. No arguments prints usage; nothing runs by
accident. Progress is narrated on the console (`-Quiet` silences it); the
report itself goes to the `.txt` (or stdout with `-Stdout`). The shell
collectors' spellings work too (`--file`, `--stdout`, `--quiet`, `--help`,
`--home <dir>`, `--out <dir>`, `--out=<dir>`); `-Help` and `-h` print the
usage; an unknown argument, or `--home`/`--out` without a directory, prints
usage to stderr and exits 2. `-Out` is checked for writing before the run. There is no opt-in: every probe is
Tier 0 and runs by default.

**Send the `-File` report.** It is written as UTF-8 without a BOM with LF line
ends, the bytes a shell collector writes, whichever PowerShell ran it.
`-Stdout` hands the lines to the PowerShell host, which ends them with CRLF,
converts them to the console code page (non-ASCII text in a verbatim
`whatap.conf` arrives as `?`), and under Windows PowerShell 5.1 writes a `>`
redirection as UTF-16LE; `tools/validate.sh --report` rejects such a copy.

## Facts collected (report sections)

| # | Section | Answers the recurring question |
| --- | --- | --- |
| 1 | Collection environment | PowerShell version, user, `privilege:` (elevated / not elevated), host boot time and uptime, 32/64-bit OS and process, which query tools exist |
| 2 | A. Host & platform | OS build, memory, clock+timezone, IIS version, .NET Framework `NDP\v4\Full` Release/Version, `dotnet --list-runtimes` / `--list-sdks` |
| 3 | B. Agent installation on disk | uninstall registry entries (**DisplayVersion** = the product version), agent-home candidates from every discovery source with existence+marker flags, per-home inventory (`core\`, `net461\`, `net6.0\` with sizes/mtimes/FileVersions), **native profiler DLL mtime+SHA256**, net461 facade assembly versions, `VERSION` file, GAC_MSIL inventory of the 9 installer-set assemblies, machine `Path` (registry) leftovers, ISAPI filter dll presence |
| 4 | C. Profiler registration & environment scopes | machine env registry vs **W3SVC/WAS service `Environment` (multi-sz, verbatim)** vs collector-process env; for every configured `*_PROFILER_PATH` / `DOTNET_STARTUP_HOOKS` value: does that exact file exist (+ its facts); CLSID `{21CAE18A-…}` and legacy `{D76F1D76-…}` InProcServer32 in both registry views; Fusion log settings (read-only); `applicationHost.config` lines naming COR/WHATAP variables |
| 5 | D. WhaTap service & runtime processes | `WhaTap .NET` service state/account/binpath/pid, whatap-named processes, per w3wp: pid ↔ app pool (from `-ap`), exe path bitness marker, **loaded profiler-related modules** (WhaTap and other APM vendors — surfaces profiler-slot conflicts as facts), **loaded runtime modules** (`clr.dll`, `coreclr.dll`, `aspnetcorev2*.dll` with FileVersion: the runtime build actually running), dotnet.exe processes with their loaded runtime modules |
| 6 | E. IIS topology | app pools (state, CLR version, pipeline, `enable32BitAppOnWin64`, identity), sites/apps/vdirs with physical paths, ISAPI filters — via appcmd, WebAdministration, or applicationHost.config fallback |
| 7 | F. Agent configuration | `whatap.conf` verbatim per home **plus byte facts (first bytes/BOM, CR count)** |
| 8 | G. Agent logs | both log dirs (`C:\ProgramData\WhaTap\dotnet\logs` fixed + `<home>\logs` legacy): inventory with **file owners**, native `core-YYYYMMDD.log` banner+head+tail, newest tracer log version/identity lines+head+tail, exception-line count, **PID-named log files cross-referenced against currently running PIDs** (PID-reuse leftovers owned by another pool's identity have caused w3wp CPU spins), audit dir presence/size only, `WT_TRACE_LOG_PATH` override |
| 9 | H. Network endpoints | `netstat -ano` lines on port 6600 with owning pids (local tracer→daemon UDP and daemon→server TCP), one live TCP probe per `whatap.server.host:whatap.server.port` endpoint named in any conf |
| 10 | I. Windows event logs | Application log (.NET Runtime / ASP.NET / Application Error / WER / WhaTap) and System log (WAS/W3SVC/HTTP), bounded to last 7 days, capped counts |
| 11 | J. Application facts | per IIS app (≤10, capped with a note): `web.config` targetFramework lines and ASP.NET Core `hostingModel` lines + `<runtime>` assemblyBinding block verbatim, `bin\` facade assembly versions (`System.Net.Http` and friends — the assembly-binding case), `bin\Whatap.*` files, .NET Core markers (`*.runtimeconfig.json` dumped) |

## Reading the report (explanations kept out of the report)

- The agent's DLL FileVersions are pinned at `1.0.0.0` across product
  releases; the uninstall registry `DisplayVersion` and the file mtime/SHA256
  in section B identify the installed build.
- A 32-bit collector process on a 64-bit OS sees WOW64-redirected
  `HKLM\SOFTWARE` and Program Files views; section [1] states both bitnesses.
- whatap.conf resolution order in the managed tracer (`ConfigObserver.cs`):
  `%WHATAP_DOTNET_HOME%\whatap.conf`, then the grandparent of
  `COR_PROFILER_PATH`, then the default install dirs (`WhaTap .NET Debug` if
  present, else `WhaTap .NET`).
- `WT_TRACE_LOG_PATH`, when set, is where the tracer writes instead of
  `C:\ProgramData\WhaTap\dotnet\logs`.
- Reading IIS configuration through appcmd needs elevation; section J says
  whether the run was elevated when appcmd returned no vdir lines.
- Windows PowerShell 5.1 (.NET Framework) lists only the WOW64 layer of a
  32-bit process (ntdll, wow64*.dll). For a 32-bit w3wp (an app pool with
  `enable32BitAppOnWin64`) the collector then reads the module list again
  through the 32-bit Windows PowerShell (`SysWOW64\WindowsPowerShell`), one
  bounded call for all such processes, and those lines end with `(32-bit
  process: listed by the 32-bit Windows PowerShell)`. pwsh 7 lists them
  itself. `clr.dll` is .NET Framework 4.x, `coreclr.dll` .NET (Core),
  `aspnetcorev2.dll` the ASP.NET Core Module and
  `aspnetcorev2_inprocess.dll` its in-process handler.
- Not elevated, Windows hides another account's process details: a w3wp line
  then reads `apppool=n/a (command line not readable)` and `exe=n/a (not
  readable)`, and its module lists `n/a (module list not readable)`.
- Over OpenSSH a non-administrator gets a network logon, and WMI refuses every
  CIM read of such a logon ("Access denied"): the boot time, OS, memory,
  process and service facts are then `n/a`. The same account logged on
  locally (console, RDP, a scheduled task) reads them. After the first
  refusal the run stops asking WMI.
- A collection-server endpoint is probed once; a second conf naming it shows
  the first answer with `(probed once above)`. Windows retries a refused
  connect, so a refused probe takes about 2 s, an unanswered one its 5 s cap.
- `run time` and, when a call was slow, capped or cut by the deadline, the
  host load (CPU busy over a 250 ms sample, processor and disk queue, free
  memory) and each slow, stopped or not-run call in time-log order
  (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`)
  close the status section, as in the shell collectors. `CMD_TIMEOUT` and `RUN_DEADLINE` are read from the
  environment.

Goals: `agent` (a home or an uninstall entry; `missed` when the HKLM
uninstall registry could not be read) and `conf` (a readable `whatap.conf`;
an unreadable one is `missed` with the privilege gap).

Operator messages (`>>` progress, `!!` warnings, the status roll-up) go to
stderr through `[Console]::Error.WriteLine`, so `-Stdout > file` holds the
report only. The script is saved as UTF-8 with a BOM and its emitted strings
are ASCII, so Windows PowerShell 5.1 and pwsh 7 read it the same way.

## What the report can contain

Framework policy: configuration is dumped **verbatim, never masked** — a
mistyped license or server address must be readable to be verified or
refuted. A secret can arrive from:

- **`whatap.conf`** (section F) — the license key and anything else in it.
- **Environment values** (section C): machine environment registry, W3SVC /
  WAS service `Environment`, and the collector's own process env filtered to
  `WHATAP_*` / `COR_*` / `CORECLR_*` / `DOTNET_STARTUP_HOOKS`.
- **Process command lines** (section D): whatap-named processes, w3wp and
  dotnet.exe command lines (first 240 characters).
- **Uninstall registry** (section B): `UninstallString`, `InstallLocation`.
- **`applicationHost.config`** lines naming COR/WHATAP variables (section C),
  its `<applicationPools>` section when WebAdministration is absent
  (section E; app pool identities, and a `password` attribute if one is
  stored there), and appcmd output.
- **`web.config` `<runtime>` block and `*.runtimeconfig.json`** (section J).
- **Logs and event log messages** (sections G and I).

Two data-scope exceptions (not masking):

- `C:\ProgramData\WhaTap\dotnet\audit\` holds **db-audit files with customer
  SQL data**; the report states file count/size/owner only, never content.
- `web.config` is a **customer-owned** file; the report extracts only the
  whatap-relevant facts (targetFramework lines and the `<runtime>`
  assemblyBinding block), not the whole file.

## Load profile

Tier 0 only: read-only registry/file/process queries, bounded reads
(`-TotalCount` / `-Tail` caps, `-MaxEvents` caps, per-app and per-list caps
with explicit "omitted" notes). Nothing is written to the target: no registry
value is set (Fusion settings are only read), no app pool is recycled, no
iisreset, no service restart. The only external processes executed are
`appcmd list …`, `dotnet --list-runtimes` / `--list-sdks`, `netstat -ano`,
and, under Windows PowerShell 5.1 with a 32-bit w3wp running, one 32-bit
Windows PowerShell that lists that process's modules (about 1–3 s on the lab host).
Registry values are read through the .NET registry API, which answers an
absent key at once where the PowerShell registry provider took 1.2-1.5 s per
absent key under `HKLM:\SOFTWARE\Classes`. Managed assemblies are identified via metadata-only reflection
(`AssemblyName.GetAssemblyName`) — no assembly is loaded for execution.

## Not covered (v0)

- **Linux .NET hosts** — different artifact set (`/usr/whatap/agent/dotnet/`,
  `whatap-dotnet.service` + `whatap.env`, `Whatap.ClrProfiler.so`,
  `CORECLR_PROFILER_PATH`, `VERSION` file, `/etc/profile.d/whatap-dotnet.sh`);
  needs a separate `collect-apmdotnet.sh` following the same fact map.
- **Per-process live environment of w3wp** — Windows exposes no supported
  read-only API for another process's environment block; the service-registry
  scope plus loaded-module facts cover the same question indirectly.
- No `--bundle` tier yet; copy the bundle plumbing from
  `collect-collserver.sh` if the domain team needs raw log artifacts.

## Validate

```sh
tools/validate.sh collectors/apm/dotnet/collect-apmdotnet.ps1
tools/validate.sh --report whatap-apmdotnet-<host>-<UTC>.txt   # the -File report
```

## Validation

| version | where | how | result |
|---|---|---|---|
| 0.6.0 | same host, 2026-09-27 | 0.5.1 and 0.6.0 run side by side under both PowerShells, elevated with all four worker processes up, not elevated in a local logon (scheduled task as `ggtuser`) and over OpenSSH | every `-File` report passes `validate.sh --report`; the only differences are the new lines. Elevated, 5.1 and 7 give the same runtime modules for every w3wp (Framework64 or Framework `clr.dll` 4.8.4420.0, `aspnetcorev2.dll` 18.0.26234.31, `coreclr.dll` 8.0.31 in CoreApp and the Kestrel dotnet.exe); 5.1 reaches Classic32's through the 32-bit read (0.8–2.8 s across runs; the whole run 13–17 s against 14–15 s). Not elevated: `n/a (module list not readable)`, goals as in 0.5.1. |
| 0.5.0 | Windows Server 2022 Standard Evaluation 10.0.20348 (lab VM jjsong-ggt-win), Windows PowerShell 5.1.20348.558 and pwsh 7.6.6 | IIS 10 with ASP.NET 4.8 pools (64- and 32-bit, one app with a failing `bindingRedirect`), a .NET 8.0.31 in-process pool (ANCM) and a standalone `dotnet.exe`; the WhaTap .NET agent **simulated** as this README describes (install dir, uninstall entry `WhaTap .NET_is1`, machine and W3SVC/WAS service environment, CLSID registration, ProgramData logs, a stopped `WhaTap .NET` service, a `whatap_dotnet.exe` holding UDP 6600), since no installer is publicly downloadable. Elevated (Administrator over OpenSSH), not elevated in a local logon (scheduled task as a Users-only account) and not elevated over OpenSSH; `-File`, `-Stdout`, `--help`, an unknown argument, `RUN_DEADLINE`/`CMD_TIMEOUT`, a clean host without IIS or agent | every `-File` report passes `validate.sh --report`. Elevated: COMPLETE, 15 s (5.1) / 12 s (7), 7 s of it the two collection-server probes of the fixture conf (one refused, one unanswered at its 5 s cap); the same host under 0.4.0 took 24 s / 19 s and its status explained none of it. Not elevated, local logon: INCOMPLETE on `agent configuration` with the privilege hint (the fixture `whatap.conf` is readable by Administrators, SYSTEM and IIS_IUSRS only), 7 s / 3 s. Not elevated over OpenSSH: the same, 14 s / 12 s (was 36 s before the CIM fail-fast). |

