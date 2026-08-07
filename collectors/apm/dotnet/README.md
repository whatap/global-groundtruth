# collectors/apm/dotnet — WhaTap .NET APM agent collector (Windows)

> **Status: SEEDED (v0).** `collect-apmdotnet.ps1` is a working Tier-0
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
elevation the IIS/event-log/module probes degrade to reasoned `n/a` lines.

```powershell
# PowerShell (administrator)
.\collect-apmdotnet.ps1 -File     # -> whatap-apmdotnet-<HOST>-<UTC>.txt

# if script execution is blocked by policy
powershell -ExecutionPolicy Bypass -File .\collect-apmdotnet.ps1 -File

# extra install dir the discovery cannot see
.\collect-apmdotnet.ps1 -File -AgentHome "D:\WhaTap .NET"
```

Paste or attach the entire output. No arguments prints usage; nothing runs by
accident. Progress is narrated on the console (`-Quiet` silences it); the
report itself goes to the `.txt` (or stdout with `-Stdout`).

## Facts collected (report sections)

| # | Section | Answers the recurring question |
| --- | --- | --- |
| 1 | Collection environment | PowerShell version, user, admin role, 32/64-bit process (WOW64 registry redirection warning), which query tools exist |
| 2 | A. Host & platform | OS build, memory, boot time, clock+timezone, IIS version, .NET Framework `NDP\v4\Full` Release/Version, `dotnet --list-runtimes` / `--list-sdks` |
| 3 | B. Agent installation on disk | uninstall registry entries (**DisplayVersion** = the product version), agent-home candidates from every discovery source with existence+marker flags, per-home inventory (`core\`, `net461\`, `net6.0\` with sizes/mtimes/FileVersions), **native profiler DLL mtime+SHA256**, net461 facade assembly versions, `VERSION` file, GAC_MSIL inventory of the 9 installer-set assemblies, machine `Path` leftovers, ISAPI filter dll presence |
| 4 | C. Profiler registration & environment scopes | machine env registry vs **W3SVC/WAS service `Environment` (multi-sz, verbatim)** vs collector-process env; for every configured `*_PROFILER_PATH` / `DOTNET_STARTUP_HOOKS` value: does that exact file exist (+ its facts); CLSID `{21CAE18A-…}` and legacy `{D76F1D76-…}` InProcServer32 in both registry views; Fusion log settings (read-only); `applicationHost.config` lines naming COR/WHATAP variables |
| 5 | D. WhaTap service & runtime processes | `WhaTap .NET` service state/account/binpath/pid, whatap-named processes, per w3wp: pid ↔ app pool (from `-ap`), exe path bitness marker, **loaded profiler-related modules** (WhaTap and other APM vendors — surfaces profiler-slot conflicts as facts), dotnet.exe processes |
| 6 | E. IIS topology | app pools (state, CLR version, pipeline, `enable32BitAppOnWin64`, identity), sites/apps/vdirs with physical paths, ISAPI filters — via appcmd, WebAdministration, or applicationHost.config fallback |
| 7 | F. Agent configuration | conf search order (mirrors `ConfigObserver.cs`), `whatap.conf` verbatim per home **plus byte facts (first bytes/BOM, CR count)** |
| 8 | G. Agent logs | both log dirs (`C:\ProgramData\WhaTap\dotnet\logs` fixed + `<home>\logs` legacy): inventory with **file owners**, native `core-YYYYMMDD.log` banner+head+tail, newest tracer log version/identity lines+head+tail, exception-line count, **PID-named log files cross-referenced against currently running PIDs** (PID-reuse leftovers owned by another pool's identity have caused w3wp CPU spins), audit dir presence/size only, `WT_TRACE_LOG_PATH` override |
| 9 | H. Network endpoints | TCP/UDP endpoints on port 6600 with owning pids (local tracer→daemon UDP and daemon→server TCP), live TCP probe to `whatap.server.host:whatap.server.port` from each conf |
| 10 | I. Windows event logs | Application log (.NET Runtime / ASP.NET / Application Error / WER / WhaTap) and System log (WAS/W3SVC/HTTP), bounded to last 7 days, capped counts |
| 11 | J. Application facts | per IIS app (≤10, capped with a note): `web.config` targetFramework lines + `<runtime>` assemblyBinding block verbatim, `bin\` facade assembly versions (`System.Net.Http` and friends — the assembly-binding case), `bin\Whatap.*` files, .NET Core markers (`*.runtimeconfig.json` dumped) |

## Security note

Framework policy: WhaTap configuration (`whatap.conf`) is dumped **verbatim,
never masked** — a mistyped license or server address must be readable to be
verified or refuted. Registry `Environment` values and `WHATAP_*` variables
are reported verbatim for the same reason. Handle the report accordingly.

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
`appcmd list …`, `dotnet --list-runtimes` / `--list-sdks`, and `netstat -ano`
(fallback). Managed assemblies are identified via metadata-only reflection
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
```
