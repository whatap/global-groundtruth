# collect-apmdotnet.ps1 — changelog

The version history of [`collect-apmdotnet.ps1`](collect-apmdotnet.ps1),
newest first. Every change to the script bumps its `VERSION` and adds one
entry at the top of this list (docs/authoring-guide.md, step 2);
`tools/validate.sh` checks that the newest entry is the script's `VERSION`.

- **0.6.2** — Move TcpProbe into the shared ps1 fact-helpers block
  (templates/groups/ps1.ps1); no behavior change.
- **0.6.1** — Collection status (ps1 group `Emit-Time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`), as the shell collectors print; CONTRACT rule 1.
- **0.6.0** — The runtime each process actually loaded is in the default run:
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
- **0.5.1** — The shared blocks (templates/groups/ps1.ps1) are synced by
  tools/sync-shared-block.sh; report unchanged.
- **0.5.0** — First runs on a real Windows host (Windows Server 2022 Standard Eval
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
- **0.4.0** — The status gives the run time, and when a bounded call was slow (3s),
  capped or not run past the deadline, the host load at start and end
  and where the time went, as the shell collectors do. CIM queries go
  through Get-CimBounded; CMD_TIMEOUT and RUN_DEADLINE are read from the
  environment.
