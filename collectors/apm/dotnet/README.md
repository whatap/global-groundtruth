# collectors/apm/dotnet: WhaTap .NET APM agent collector (Windows)

> **Status:** validated at `collect-apmdotnet.ps1` 0.9.3 on 2026-10-06, Windows Server
> 2022 (lab VM jjsong-dotnet-lab, real WhaTap .NET 2.5.7.0 under the CLR
> Instrumentation Engine 1.0.45 raw profiler hook; Windows PowerShell 5.1 and pwsh 7,
> elevated; `validate.sh --report` pass).
> Not elevated (0.9.1, OpenSSH as a local user): COMPLETE, each probe it cannot
> read says so. Not yet run on: Linux .NET hosts (not covered, see "Not covered"). Owner: Global team until handover to the .NET agent developers (CONTRACT
> rule 4).

Collects the hidden facts a remote WhaTap .NET-agent developer repeatedly asks
a field engineer for, from the Windows host where the instrumented application runs.
The fact list comes from a review of `#ask-dev-apm` .NET support threads (2025-06 ..
2026-08), checked against the `dotnet-apm` source repo (installer `release.iss`,
`Whatap.ClrProfiler`, `Whatap.Tracer`, `Whatap.Loader`, `Whatap.Startup`) and
docs.whatap.io (install-check, supported-spec).

**Why version identification is the first fact.** The agent's native and
managed DLLs ship with FileVersion pinned at `1.0.0.0` across product
releases, and the GAC folder names (`v4.0_1.0.0.0__…`) never change. The only
trustworthy product-version markers on a host are the uninstall registry
(`HKLM\...\Uninstall\WhaTap .NET_is1` → `DisplayVersion`) and the
mtime/SHA256 of the profiler DLL copies, so the collector captures all of
them, plus the version lines the agent writes into its own logs. Multiple
support threads hinged on "reported version ≠ version actually on disk".

**How the agent attaches (what the sections verify).** The installer writes
`WHATAP_*` keys to the machine environment, but the CLR injection variables
(`COR_ENABLE_PROFILING`, `COR_PROFILER`, `COR(ECLR)_PROFILER_PATH_32/64`,
`DOTNET_STARTUP_HOOKS`) go into the **W3SVC and WAS service registry
`Environment` (multi-sz)**: IIS worker processes only. The tracer sends
UDP to `127.0.0.1:6600` where the `WhaTap .NET` service (`whatap_dotnet.exe
-t 7`) relays TCP to the collection server on the same port number. Only the
IIS HTTP pipeline is instrumented (self-hosted Windows services are not), so
IIS topology and w3wp loaded-module facts close the loop between "configured"
and "actually attached".

## One field command

Run **on the Windows host where the application runs**, in a **64-bit
PowerShell started with "Run as Administrator"** (5.1+, the Windows Server 2016+
default). The collector is written for that; without
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

Paste or attach the entire output. No arguments prints usage; nothing runs by accident.
Progress goes to the console (`-Quiet` silences it); the report goes to the `.txt` (or
stdout with `-Stdout`). The shell collectors' spellings work too (`--file`, `--stdout`,
`--quiet`, `--help`, `--home <dir>`, `--out <dir>`, `--out=<dir>`); `-Help` and `-h` print
the usage; an unknown argument, or `--home`/`--out` without a directory, prints usage to
stderr and exits 2. There is no opt-in: every probe is Tier 0 and runs by default.

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
| 4 | C. Profiler registration & environment scopes | machine env registry vs **W3SVC/WAS service `Environment` (multi-sz, verbatim)** vs collector-process env vs **per-app-pool `environmentVariables` in `applicationHost.config`** (and `applicationPoolDefaults`, as `pool=(defaults)`); for every configured `*_PROFILER_PATH` / `DOTNET_STARTUP_HOOKS` / `MicrosoftInstrumentationEngine_RawProfilerHookPath*` value: does that exact file exist (+ its facts and SHA256); InProcServer32 in both registry views for WhaTap `{21CAE18A-…}`, legacy `{D76F1D76-…}` and **every CLSID named by `COR_PROFILER`, `CORECLR_PROFILER` or `MicrosoftInstrumentationEngine_RawProfilerHook`** (+ the registered DLL's facts for non-WhaTap CLSIDs); **CLR Instrumentation Engine configuration files** named by `MicrosoftInstrumentationEngine_ConfigPath*` (facts + first 80 lines); uninstall entries of other profiler products (the Instrumentation Engine by name, or an entry whose `InstallLocation` folder holds a profiler DLL, CLSID DLL or CLRIE configuration file found above; a drive root or the Program Files / Windows folder itself never counts) and **their and the Instrumentation Engine's Windows Installer install/update/remove events with timestamps** (newest 20 of the newest 200 MsiInstaller events with ids 1033-1036, any age; needs elevation); Fusion log settings (read-only); `applicationHost.config` lines naming COR/WHATAP/InstrumentationEngine variables |
| 5 | D. WhaTap service & runtime processes | `WhaTap .NET` service state/account/binpath/pid, whatap-named processes, per w3wp: pid ↔ app pool (from `-ap`), exe path bitness marker, **loaded profiler-related modules** (WhaTap and other APM vendors by name, plus any module under a profiler DLL path, CLRIE configuration folder or install folder found in section C; surfaces profiler-slot conflicts as facts), **loaded runtime modules** (`clr.dll`, `coreclr.dll`, `aspnetcorev2*.dll` with FileVersion: the runtime build actually running), dotnet.exe processes with their loaded runtime modules |
| 6 | E. IIS topology | app pools (state, CLR version, pipeline, `enable32BitAppOnWin64`, identity), sites/apps/vdirs with physical paths, ISAPI filters, via appcmd, WebAdministration, or applicationHost.config fallback |
| 7 | F. Agent configuration | `whatap.conf` verbatim per home **plus byte facts (first bytes/BOM, CR count)** |
| 8 | G. Agent logs | both log dirs (`C:\ProgramData\WhaTap\dotnet\logs` fixed + `<home>\logs` legacy): inventory with **file owners**, native `core-YYYYMMDD.log` banner+head+tail and its CLR Instrumentation Engine / loader-injection lines (first 20 of the last 5000), newest tracer log version/identity lines+head+tail, exception-line count, **PID-named log files cross-referenced against currently running PIDs** (PID-reuse leftovers owned by another pool's identity have caused w3wp CPU spins), audit dir presence/size only, `WT_TRACE_LOG_PATH` override |
| 9 | H. Network endpoints | `netstat -ano` lines on port 6600 with owning pids (local tracer→daemon UDP and daemon→server TCP), one live TCP probe per `whatap.server.host:whatap.server.port` endpoint named in any conf |
| 10 | I. Windows event logs | Application log (.NET Runtime / ASP.NET / ASP.NET Core Module / Application Error / WER / WhaTap) and System log (WAS/W3SVC/HTTP), bounded to last 7 days, capped counts |
| 11 | J. Application facts | per IIS app (≤10, capped with a note): `web.config` targetFramework lines and ASP.NET Core `hostingModel` lines + `<runtime>` assemblyBinding block verbatim, `bin\` facade assembly versions (`System.Net.Http` and friends, the assembly-binding case), `bin\Whatap.*` files, .NET Core markers (`*.runtimeconfig.json` dumped) |

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
- Under the CLR Instrumentation Engine (CLRIE), `COR_PROFILER` /
  `CORECLR_PROFILER` name the CLRIE CLSID `{324F817A-7420-4E6D-B3C1-143FBED6D855}`.
  A profiler that is not a CLRIE Instrumentation Method (WhaTap is not) can only sit
  in `MicrosoftInstrumentationEngine_RawProfilerHook`, one per process; Instrumentation
  Methods are listed in the files named by `MicrosoftInstrumentationEngine_ConfigPath*`.
  `COR_*` is read by .NET Framework processes and `CORECLR_*` by .NET (Core) ones.
- CLRIE passes IL of methods a raw-hook profiler defines to the CLR only when
  `MicrosoftInstrumentationEngine_UserBuffer` exists (any value; CLRIE commit
  `0d1cfa7`, in 1.0.43 and later tags; not in the CLRIE docs). Without it the WhaTap
  loader injection on .NET Framework repeats on every request.
- In WhaTap 2.5.7.0 under CLRIE, a native log line
  `JITCompilationStartedOnNetFramework() - LOADER INJECTION ... StartupHook.Initialize()`
  is the Framework loader injected into a .NET (Core) process; requests to that app
  fail. `AddIISPreStartInitFlags() failed` and `ILRewriter.Import() failed` appear under
  CLRIE on every start and do not stop collection (DOTNET-431).
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
- The status section closes with `run time` and, when a call was slow, capped or cut by
  the deadline, the host load and each such call in time-log order, as in the shell
  collectors. `CMD_TIMEOUT` and `RUN_DEADLINE` are read from the environment.

Goals: `agent` (a home or an uninstall entry; `missed` when the HKLM
uninstall registry could not be read) and `conf` (a readable `whatap.conf`;
an unreadable one is `missed` with the privilege gap).

Operator messages (`>>` progress, `!!` warnings, the status roll-up) go to stderr, so
`-Stdout > file` holds the report only.

## What the report can contain

Framework policy: configuration is dumped **verbatim, never masked**, so a
mistyped license or server address must be readable to be verified or
refuted. A secret can arrive from:

- **`whatap.conf`** (section F): the license key and anything else in it.
- **Environment values** (section C): machine environment registry, W3SVC /
  WAS service `Environment`, per-app-pool `environmentVariables`, and the
  collector's own process env, filtered to
  `WHATAP_*` / `COR_*` / `CORECLR_*` / `DOTNET_STARTUP_HOOKS` /
  `MicrosoftInstrumentationEngine_*`; the first 80 lines of each CLR Instrumentation
  Engine configuration file named there.
- **Process command lines** (section D): whatap-named processes, w3wp and
  dotnet.exe command lines (first 240 characters).
- **Uninstall registry** (section B): `UninstallString`, `InstallLocation`.
- **`applicationHost.config`** lines naming COR/WHATAP/InstrumentationEngine variables (section C),
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

Tier 0 only: read-only registry/file/process queries, bounded reads (`-TotalCount` /
`-Tail` caps, `-MaxEvents` caps, per-app and per-list caps with explicit "omitted"
notes). Nothing is written to the target: no registry value is set (Fusion settings are
only read), no app pool is recycled, no iisreset, no service restart. The only external
processes executed are `appcmd list ...`, `dotnet --list-runtimes` / `--list-sdks`,
`netstat -ano`, and, under Windows PowerShell 5.1 with a 32-bit w3wp running, one 32-bit
Windows PowerShell that lists that process's modules (about 1 to 3 s on the lab host).
Registry values are read through the .NET registry API and managed assemblies are
identified via metadata-only reflection (`AssemblyName.GetAssemblyName`); no assembly is
loaded for execution.

## Not covered

- **Linux .NET hosts**: different artifact set (`/usr/whatap/agent/dotnet/`,
  `whatap-dotnet.service` + `whatap.env`, `Whatap.ClrProfiler.so`,
  `CORECLR_PROFILER_PATH`, `VERSION` file, `/etc/profile.d/whatap-dotnet.sh`);
  needs a separate `collect-apmdotnet.sh` following the same fact map.
- **Per-process live environment of w3wp**: Windows exposes no supported
  read-only API for another process's environment block; the service-registry
  scope plus loaded-module facts cover the same question indirectly.

## Validate

```sh
tools/validate.sh collectors/apm/dotnet/collect-apmdotnet.ps1
tools/validate.sh --report whatap-apmdotnet-<host>-<UTC>.txt   # the -File report
```
