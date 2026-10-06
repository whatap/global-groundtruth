# collect-apmdotnet.ps1: changelog

The version history of [`collect-apmdotnet.ps1`](collect-apmdotnet.ps1),
newest first. Every change to the script bumps its `VERSION` and adds one
entry at the top of this list (docs/authoring-guide.md, step 2);
`tools/validate.sh` checks that the newest entry is the script's `VERSION`.

- **0.9.2**: Fixes from a deep verification of 0.9.1. The Windows Installer
  events are the newest 200 MsiInstaller events again: 0.9.1 took the newest 200
  events with ids 1033-1036 before picking the provider, and the ASP.NET Core
  Module logs id 1033 at every app shutdown, so on a busy IIS + ASP.NET Core host
  those filled the window and the MSI events were lost. The 32-bit module read
  escapes every quote PowerShell treats as a single quote (`’` too, not only `'`).
  Validated 2026-10-06 on jjsong-dotnet-lab, elevated, Windows PowerShell 5.1 and
  pwsh 7, 0.9.1 and 0.9.2 side by side, all reports COMPLETE and passing
  validate.sh --report. As found: both list the CLRIE 1.0.45 install event (1033
  2026-10-01 07:41:23). With 200 more ANCM id-1033 events and a
  `C:\Lab O’Curly\lab.xml` ConfigPath on Classic32: 0.9.1 printed none and, under
  5.1, n/a for Classic32's modules; 0.9.2 printed the CLRIE event and Classic32's
  clr.dll and aspnetcorev2.dll. The VM was reverted to its pre-test snapshot.
- **0.9.1**: Fixes from a deep verification of 0.8.0-0.9.0 on jjsong-dotnet-lab.
  An uninstall entry counts only when its `InstallLocation` is a folder holding
  the file (`C:\Foo\`, so `C:\FooBar` no longer matches); quotes and spaces
  around it are dropped, and a drive root or the Program Files / Windows folder
  itself never counts (an entry at `C:\` had made section D list every loaded
  module, 335 lines under 5.1). A profiler path containing `'` no longer breaks
  the 32-bit module read (a `C:\Lab O'Hook\lab.xml` ConfigPath had turned the
  32-bit w3wp's profiler and runtime modules into n/a). Section C also reads
  `applicationPoolDefaults` environment variables, as `pool=(defaults)`. The
  Windows Installer events are read by id and picked by provider afterwards: the
  provider-name filter failed for a non-elevated account ("There is not an event
  provider ... MsiInstaller"), and an XPath filter is refused to a non-elevated
  network logon; the label now says the Instrumentation Engine's events are
  always included, as they were in 0.9.0. An empty event log is told by the
  `NoMatchingEventsFound` error id, not the English message, here and in section I.
  Validated 2026-10-06 on jjsong-dotnet-lab, Windows PowerShell 5.1 and pwsh 7,
  0.9.0 and 0.9.1 side by side, every report passing validate.sh --report:
  elevated as found (both list the CLRIE 1.0.45 install event, 1033 2026-10-01
  07:41:23); elevated with entries at `C:\` and `C:\Program Files\Microsoft CLR`,
  the `'` ConfigPath on Classic32 and a defaults variable (0.9.1: neither entry
  listed, 3 loaded-module lines instead of 335/453, Classic32's clr.dll listed,
  the defaults variable shown); elevated after clearing the Application log
  (none); not elevated over OpenSSH (0.9.0: provider error; 0.9.1: "none ...
  among the events this account can read (not elevated)", COMPLETE; that logon
  reads no Application events at all). A non-elevated local logon was not run.
  The VM was reverted to its pre-test snapshot.
- **0.9.0**: Other profiler products are found from the configuration, not from
  a product name. Section C lists an uninstall entry when its `InstallLocation`
  holds a configured profiler DLL, a CLSID-registered DLL or a CLR Instrumentation
  Engine configuration file (the Instrumentation Engine itself still by name), and
  then prints the Windows Installer events (MsiInstaller 1033/1034/1035/1036) that
  name those products, to the second: the newest 20 matching among the newest 200,
  with the oldest event read, outside section I's 7-day window. Section D's loaded
  profiler modules also take every module under a profiler DLL path, CLRIE
  configuration folder or install folder found in section C; `secupi` leaves the
  vendor-name list. Why: to tell in what order WhaTap (its last run is
  `unins000.dat`'s mtime in section B) and another profiler product were installed or
  updated, next to the `Environment` they left (DOTNET-431), for any vendor.
  Validated 2026-10-06 on jjsong-dotnet-lab (real WhaTap .NET 2.5.7.0, CLRIE 1.0.45
  raw hook), elevated, Windows PowerShell 5.1 and pwsh 7: all COMPLETE and pass
  validate.sh --report. A fake product with no vendor word in its name, whose
  `InstallLocation` held the CLRIE configuration file set on an app pool, was listed;
  its MsiInstaller 1036 event and the real CLRIE 1.0.45 install event (1033,
  2026-10-01 07:41:23) were printed, and an event naming a product with no such
  entry was not. A copy of the WhaTap profiler DLL renamed `LabHook64.dll` in a
  lab folder, set as the raw-hook path, was listed among the w3wp's loaded modules.
  The VM was reverted to its pre-test snapshot.
- **0.8.0**: Section C reads a fourth environment scope, the per-app-pool
  `<environmentVariables>` of `applicationHost.config` (`app pool env: pool=<name>
  <var>=<value>`, the first 80 matching the environment filter). Those values join
  the profiler-path, CLSID and `MicrosoftInstrumentationEngine_ConfigPath*` probes, so
  a ConfigPath set on one pool gets its file facts and first 80 lines as one set in
  W3SVC/WAS does. The `applicationHost.config` line grep also takes
  `InstrumentationEngine`. Section D's loaded profiler-module pattern takes
  `InstrumentationEngine` and `secupi`. Why: a SecuPi + CLRIE case (DOTNET-431),
  where SecuPi set its CLRIE variables on the DefaultAppPool; 0.7.0 printed the
  pool's `COR_PROFILER` line but not its ConfigPath, and listed neither the CLRIE
  nor another vendor's DLL loaded in w3wp.
  Validated 2026-10-06 on jjsong-dotnet-lab (real WhaTap .NET 2.5.7.0, CLRIE 1.0.45
  raw hook), elevated, Windows PowerShell 5.1 and pwsh 7: all COMPLETE and pass
  validate.sh --report. With a ConfigPath variable on the ClassicApp pool, both
  printed the pool value, the file's facts and its content. With
  `MicrosoftInstrumentationEngine_UserBuffer=1` added and the pool serving HTTP 200,
  both listed `MicrosoftInstrumentationEngine_x64.dll` and `Whatap.ClrProfiler.dll`
  among the w3wp's loaded modules. Without it, the pool answered HTTP 500 and the
  w3wp the collector found had no profiler module loaded. The VM was reverted to
  its pre-test snapshot.
- **0.7.0**: Section C reads the CLR Instrumentation Engine (CLRIE) setup:
  `MicrosoftInstrumentationEngine_*` joins the environment filter; every CLSID
  named by `COR_PROFILER`, `CORECLR_PROFILER` or
  `MicrosoftInstrumentationEngine_RawProfilerHook` gets its InProcServer32 in both
  views and, when it is not a WhaTap CLSID, the registered DLL's facts and SHA256;
  raw-hook paths get file facts like the profiler paths; each
  `MicrosoftInstrumentationEngine_ConfigPath*` file is listed with its first 80
  lines; uninstall entries of other profiler products (the Instrumentation Engine by
  name, or an `InstallLocation` that holds a profiler DLL found above) are listed.
  Section G prints the newest native log's CLRIE and loader-injection lines (first
  20 of the last 5000). Section I's Application filter takes the ASP.NET Core Module
  provider. Why: a SecuPi + CLRIE case (DOTNET-431) needed which product holds which
  profiler slot, and 0.6.2 printed the service `Environment` but not the CLSIDs,
  files and versions it named.
  Validated 2026-10-01 on jjsong-dotnet-lab (real WhaTap .NET 2.5.7.0, CLRIE 1.0.45
  raw hook), elevated, Windows PowerShell 5.1 and pwsh 7: both COMPLETE and pass
  validate.sh --report. A third run with a temporary fake raw-hook CLSID, its DLL,
  an uninstall entry and a ConfigPath file (removed afterwards, service Environment
  restored and compared) printed each of them.
- **0.6.2**: Move TcpProbe into the shared ps1 fact-helpers block
  (templates/groups/ps1.ps1); no behavior change.
- **0.6.1**: Collection status (ps1 group `Emit-Time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`), as the shell collectors print; CONTRACT rule 1.
- **0.6.0**: The runtime each process actually loaded is in the default run:
  section D lists, per w3wp and per dotnet.exe (the first 10), the loaded
  clr.dll, coreclr.dll and aspnetcorev2*.dll with their FileVersion, from
  the module list already read for the profiler modules (a dotnet.exe
  whose list cannot be read now says so instead of printing nothing).
  Section J prints each web.config's `hostingModel` lines verbatim, as it
  does the targetFramework lines. Windows PowerShell 5.1 lists only the
  WOW64 layer of a 32-bit process, so the 32-bit Classic32 pool read "none"
  for its profiler modules while pwsh 7 listed its clr.dll (lab host,
  2026-09-27); such a process's list is now read by the 32-bit Windows
  PowerShell, one bounded call for all of them (about 1–3 s: 2.8 s and 0.8 s in two lab runs), and its lines
  say so.
  Validated 2026-09-27 on the same host: 0.5.1 and 0.6.0 run side by side under
  both PowerShells, elevated with all four worker processes up, not elevated
  in a local logon (scheduled task as ggtuser) and over OpenSSH; every -File
  report passes validate.sh --report. Elevated, 5.1 and 7 give the same
  runtime modules for every w3wp (Framework64 or Framework clr.dll 4.8.4420.0,
  aspnetcorev2.dll 18.0.26234.31, coreclr.dll 8.0.31 in CoreApp and the
  Kestrel dotnet.exe); 5.1 reaches Classic32's through the 32-bit read (0.8 to
  2.8 s across runs; the whole run 13-17 s against 14-15 s). Not elevated:
  n/a (module list not readable), goals as in 0.5.1.
- **0.5.1**: The shared blocks (templates/groups/ps1.ps1) are synced by
  tools/sync-shared-block.sh; report unchanged.
- **0.5.0**: First runs on a real Windows host (Windows Server 2022 Standard Eval
  20348, Windows PowerShell 5.1 and pwsh 7.6, elevated and not). The
  report file is UTF-8 without a BOM with LF line ends (5.1 wrote a BOM,
  both wrote CRLF, and validate.sh --report failed them). The host load
  reads raw CPU counters (Win32_Processor took 4-5 s and left every
  field n/a). One CIM probe with room for a refusal decides whether
  WMI refuses this logon; later refusals are per class. TCP probes are
  timed, deadline-bound and made once per endpoint. Timestamps have one
  format. Conf files are read as UTF-8 (in the culture's ANSI code
  page only when the bytes are not UTF-8). -Out DIR (the shell --out) writes the report elsewhere
  and is checked for writing before the run; -Help and -h print the
  usage; -Home DIR adds an install dir; the shell spellings
  --file/--stdout/--quiet/--help/--home/--out (and --x=DIR) work; an
  unknown argument or a --home/--out without a value prints usage to
  stderr and exits 2.
  Registry values are read through the .NET API (each absent key under
  HKLM:\SOFTWARE\Classes cost 1.3 s through the provider); port 6600 comes
  from one netstat -ano; a profiler path under core\x86 no longer makes
  core\ a second agent home; an unreadable w3wp says so instead of
  "64-bit path" and "none".
  An event message keeps the lines that name the failure (an ASP.NET
  1310 event's "Exception message") when it is cut at 400 characters.
  Validated on Windows Server 2022 Standard Evaluation 10.0.20348 (lab VM
  jjsong-ggt-win), Windows PowerShell 5.1.20348.558 and pwsh 7.6.6, with the
  agent simulated (install dir, uninstall entry, machine and W3SVC/WAS
  service environment, CLSID registration, ProgramData logs, a stopped
  service, a process holding UDP 6600) on IIS 10 with ASP.NET 4.8 pools (64-
  and 32-bit, one with a failing bindingRedirect), a .NET 8.0.31 in-process
  pool and a standalone dotnet.exe. Elevated: COMPLETE, 15 s (5.1) / 12 s
  (7), 7 s of it the two collection-server probes of the fixture conf (one
  refused, one unanswered at its 5 s cap); 0.4.0 took 24 s / 19 s on the
  same host. Not elevated, local logon: INCOMPLETE on agent configuration
  with the privilege hint, 7 s / 3 s. Not elevated over OpenSSH: the same,
  14 s / 12 s (36 s before the CIM fail-fast).
- **0.4.0**: The status gives the run time, and when a bounded call was slow (3s),
  capped or not run past the deadline, the host load at start and end
  and where the time went, as the shell collectors do. CIM queries go
  through Get-CimBounded; CMD_TIMEOUT and RUN_DEADLINE are read from the
  environment.
