# collectors/db: changelog

The version history of each collector in this directory, one section per
collector, newest first. Every change to a script bumps its `VERSION` and adds
one entry at the top of its section (docs/authoring-guide.md, step 2);
`tools/validate.sh` checks that the newest entry is the script's `VERSION`.

## collect-db.sh

- **0.9.8**: Run helpers (skeleton): the `--out` mkdir always gets the command
  cap (plus 1 s), so a second boundary crossed right after the deadline check
  no longer skips it and exits 1 with a false "not writable" message.
- **0.9.7**: Run helpers (skeleton): `_out_dir_check` makes the `--out`
  directory even when the run deadline is already spent (the mkdir gets the
  command cap alone), instead of exiting 1 with a false "not writable" message
  and no report. Main: with stderr closed, fd 3 opens on /dev/null instead of
  `exec 3>&2` ending dash before the report.
- **0.9.6**: Emit helpers (skeleton): `progress`, `warn` and `notice` return 0
  when their write fails, so a run whose stderr is closed or full no longer
  exits 1 after a complete report.
- **0.9.5**: Section K leaves out the TLS 1.3 post-handshake session tickets
  (and the "---" just before the first): they print only when a ticket lands
  before s_client exits, one or several, so K differed run to run. "DONE"
  after a ticket (openssl 1.1.1) is kept, and so is a last "---".
- **0.9.4**: Run helpers (skeleton): `_why_124` and `_out_dir_check` move
  into the skeleton run helpers (the `--out` mkdir now runs under the command
  cap), and `_run_init` sets the probe error file and reads the uid once; the
  local `probe_merged` is replaced by the skeleton's, so a failed
  `-version`/`--version` prints `(exit N)` with its output, or `n/a (empty
  output, exit N)`.
- **0.9.3**: Drop nslookup/crontab from the [1] tool row (never run on the
  host); split _rep_tls per-instance body into _rep_tls_inst; read
  dbms/db_ip/db_port/connect_option through one helper (_inst_conf) in each
  section.
- **0.9.2**: Collection status (skeleton `_emit_time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table (sums largest first, time outside bounded calls) gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`); CONTRACT rule 1. `_run_init` sets its EXIT/INT/TERM/HUP traps before it creates the private directory: a signal in between left `ggt.*` behind.
- **0.9.1**: `_run_init` (skeleton) also takes the script as read from stdin when `$0` is the shell's own binary (`/bin/bash -s`, `$0 -ef /proc/$$/exe`): bash 3.2 under musl otherwise faulted in a loop at full CPU after `4<&0`.
- **0.9.0**: Derived views removed (CONTRACT rule 1, "Derived views"); every
  fact they gave is in raw output or in a count of what was read. Sections
  F and H: the WA/ORA/JDBC code histograms become, per code in order of
  first appearance, `WA123 (M occurrences): <first line holding it>` (M
  counted as grep -o counted, over the same 5000-line window, so the
  numbers are the old ones); the line counts become `label (M lines): <first
  matching line>` (the old grep -c numbers); the old samples stay as the
  first 3 lines (`exception sample lines`, `Exception|SQLException`;
  `AWS credential/role sample lines`), printed whole as in 0.8.4. A new
  first line (per code, per pattern) is cut at 400 bytes on a UTF-8 boundary with "(first N of M bytes)", and a line already printed
  in the same list is named instead ("(the line shown for WA777)"). One awk
  pass per log window replaces a grep per pattern. F and H give `ls -l` of
  the log they read (the "log files (newest 15)" listing can leave it out);
  H names that log. "last log line" (the tail's last line) is gone.
  Section H: "engine-relevant conf lines" (whatap.conf is in section D) and
  the dmx/prx block (ps rss/etime is in section E, prx.conf rss_limit in D)
  are gone. Section D: a file longer than the 400 lines shown also gets its
  later lines that are not blank or `#` comments, with line numbers, so
  every key stays in D. Section K: the handshake summary, the "session:
  none negotiated" parse and the x509 parses give way to the whole
  `s_client -showcerts` output (stdout and stderr) verbatim but for its
  PEM blocks and its per-connection random values (the TLS session ticket
  hex dump, Session-ID, Session-ID-ctx, Master-Key, Resumption PSK, Start
  Time: 16 lines per TLS 1.2 handshake), including openssl's own reasons ("MySQL server does not
  support SSL.", the usage text of an openssl that refuses -starttls); an
  output identical to one printed for an instance above is named instead.
  Each chain certificate is given by the raw output of `openssl x509
  -noout -subject -issuer -dates -fingerprint -sha256 -ext subjectAltName
  -text -certopt ...` (-certopt leaves only the signature algorithm line of
  -text); an openssl whose x509 refuses -ext (1.0.2, LibreSSL 3.7) is run
  without it and prints every extension. Section G: the re-printed conf
  values (dbms, db_ip/db_port, whatap.server.host/port, connect_option,
  db_ssl; all in D), "connect_option keys", "db endpoint class" and "db
  endpoint domain" are gone; getent still runs for a DNS name, and an unset
  db_ip or whatap.server.host says so on the probe line. Section B: "host
  role by discovery" is gone and the title is "B. Component discovery".
  Section C: "orai18n jar" (in the jdbc drivers listing) is gone. Section I:
  the two counts over the slow-query file's last 200 lines become the same
  pattern lines. Measured on the lab mock tree (3 instances, MySQL 8.0 and
  PostgreSQL 16 with TLS): 570 lines / 28.3 kB -> 627 lines / 32.7 kB
  (section K 40 -> 118 lines, the s_client output); with a 210 kB log line
  in the window, 249 kB -> 50 kB (2026-09-27).
- **0.8.4**: Shortened the top-of-file comment block: kept the asymmetric
  agent-host/DB-host rationale, pointed the field-procedure and CONTRACT/secret
  detail at README.md instead of restating it. Comments only; report content
  unchanged.
- **0.8.3**: The per-instance body of _rep_sql moves to _rep_sql_inst. Report
  content unchanged.
- **0.8.2**: Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  _classify_err, _proc_hidden and _self_tree are the new host group block (db,
  nms; templates/groups/host.sh). Report change: a probe whose command exits
  non-zero with output prints that output under "label (exit N):" instead of
  "label: n/a (...)". OPT_HOME_ADDED, never read, removed. Compared with 0.8.1
  on this host: reports equal but live values.
- **0.8.1**: [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.8.0**: TLS facts are part of every run: section K (one handshake per
  instance whose section G connect succeeded) runs by default. Measured on
  PostgreSQL 16 and MySQL 8.4, the handshake leaves the same server log
  trace as the connect probe (one connection line with log_connections,
  one aborted-connection note at log_error_verbosity=3, nothing
  otherwise). --tls is refused, naming this; the tls goal is gone with
  the flag. The handshakes of one run share 30 s (each at most 15 s);
  instances left after that say so. The certificate parses are bounded. --out DIR (default .) and --home=DIR are accepted. An
  output directory that cannot be written stops the run before it
  collects (2026-09-26).
  A value option given nothing, or a value starting with '-', exits 2
  ("missing value for --out"); it took the next option as its value.
- **0.7.0**: Round trips in ms: each section G tcp connect states its time in ms
  (it was whole seconds, "0s"), and --sql states the JDBC connect time
  and one trivial query's time (SELECT 1; SELECT 1 FROM DUAL on Oracle)
  per instance, measured in the runner VM (2026-09-26).
- **0.6.0**: The architecture is taken from the one `uname -smr` (no second
  `uname -m`).
- **0.5.3**: Each (file, key) of a config is read once per run: sections G, H, J,
  K and L asked for the same keys again, 7 forks and 6 execs each
  (72 reads -> 40 for 3 instances with --tls). Report unchanged.
- **0.5.2**: Readability refactor; report unchanged.
- **0.5.1**: A CMD_TIMEOUT from the environment is used (it was overwritten by a
  fixed value after _run_init had checked it) (2026-09-26).
- **0.5.0**: Discovery reads each /proc/\<pid>/cmdline and comm with builtins, with
  no fork per process: `$(tr)`, `$(cat)` and `$(_db_kind_of_comm)` per
  pid made the scan cost about 15 ms per process (9.2 s -> 1.4 s on a
  720-process host, 38.7 s -> 2.0 s with 2000 more). The report is
  unchanged. The --sql terminal prompt waits no longer than what is
  left of RUN_DEADLINE; a prompt nobody answers skips that instance
  with the reason in the sql goal (2026-09-25).

## windows/collect-db-mssql.ps1

- **0.10.1**: In a parent process's command line, a quoted span or an
  unquoted token holding `<`, `>` or `|` is cut there and the path before it
  is kept (`cmd /c "C:\dbx1\start_service.bat > C:\log.txt"` gives
  `C:\dbx1`); 0.10.0 dropped the whole span or token, so a DBX started by another
  wrapper with a redirection or pipe was found only if a higher parent named
  its folder or `-Home` was given. A `whatap.conf` folder found under two
  install dir candidates in different case is listed once as an instance.
  Why: a review of 0.10.0.
  Validated 2026-10-07 on jjsong-ggt-win, elevated, Windows PowerShell 5.1 and
  pwsh 7, with three real DBX 2.64.03 installs of the same version: the two
  services as in 0.10.0, and `C:\whatap-dbx3` started by a scheduled task
  (SYSTEM, working dir `C:\whatap-dbx3`) as `cmd.exe /c
  "C:\whatap-dbx3\start_service.bat --service whatap.conf > C:\ggtf\dbx3.out
  2>&1"`, whose parent is the Task Scheduler's svchost.exe. 0.10.0: INCOMPLETE,
  `install dir of pid N: n/a` for the third; 0.10.1: COMPLETE, `found in
  C:\whatap-dbx3 (parent pid M cmd.exe)`, three instances. With `-Home C:\
  -Home c:\WHATAP-DBX2`, 0.10.0 in Windows PowerShell 5.1 listed
  `C:\WHATAP-DBX2` and `C:\whatap-dbx2` as two instances (6; pwsh 7 gave 5);
  0.10.1 gives 5 in both shells. Every report passes validate.sh --report. The
  VM was reverted to its pre-test snapshot.
- **0.10.0**: A DBX process whose command line names its jar without a folder
  is matched to the folders that hold that jar: first the folders its parent
  processes name (executable path, absolute command-line paths and their parent
  folders, also inside quotes, up to three levels up, stopping at a "parent"
  created after its child), then the `-Home` dirs. Every folder that holds the
  jar becomes an install dir candidate, and the report lists them with their
  source (`jar named without a folder by pid N: <jar> found in <dir>
  (<source>)[; <dir> (-Home)]`). Why: the real DBX 2.64.03 for MSSQL,
  registered as a Windows service with its own `install_WindowsService.bat`,
  runs `"java" ... -cp ".;.\jdbc\...;whatap.agent.dbx-2.64.03.jar"` from
  `nssm.exe` → `cmd.exe /c ""C:\whatap-dbx\start_service.bat" --service
  whatap.conf"`; 0.9.0 left it unresolved, so both goals were blocked, and
  passing `-Home <dir>` as the reason advised still left the install goal
  blocked. The simulated agent used so far had an absolute jar path, so the
  runs before did not show it.
  Validated 2026-10-07 on jjsong-ggt-win, elevated, Windows PowerShell 5.1 and
  pwsh 7, with the real DBX 2.64.03 (MSSQL package from
  service.whatap.io/download/dbx_agent, MS JDBC 12.8.1 in `jdbc\`, whatap.conf
  pointing at SQL Server on 127.0.0.1 and a collection server on 127.0.0.1, so
  nothing left the VM) running as the service `WhatapDBXAgent` (LocalSystem):
  0.9.0 INCOMPLETE (2 blocked), also with `-Home C:\whatap-dbx`; the change
  COMPLETE, the jar found in `C:\whatap-dbx` (parent pid of `cmd.exe`), and
  with `-Home` too; with the simulated agent running as well, 0.9.0 INCOMPLETE
  and the change COMPLETE with three instances. Every report passes
  validate.sh --report. The `-File` reports of the simulated agent's cp1252
  whatap.conf also pass (a verifier's failing copy came from its own
  redirection). That run searched `-Home` first and named the line `install
  dir of pid N`; a review then found a second install of the same version
  reported under the first one's dir as `(-Home)`, so the order became parents
  first and only the dirs given with `-Home` last, with the reused-pid stop and
  the paths inside quotes. The final code was run the same day on the same VM
  with two real DBX 2.64.03 services of the same version (`C:\whatap-dbx` as
  `WhatapDBXAgent`, `C:\whatap-dbx2` as `WhatapDBXAgent2`), both shells, all
  COMPLETE: each pid found in its own folder (parent pid of `cmd.exe`) and both
  folders listed as install dir candidates; with `-Home C:\whatap-dbx`, the
  second pid lists `C:\whatap-dbx2 (parent pid ... cmd.exe); C:\whatap-dbx
  (-Home)`; with one service, with and without `-Home`, one candidate. Every
  report passes validate.sh --report. The reused parent pid and `cmd /c "cd /d
  C:\whatap-dbx-2.64.03 && start.bat"` were checked in pwsh 7 with a mocked
  process table. The VM was reverted to its pre-test snapshot after each run.
  After that run, two changes that do not alter those results: a folder is
  listed once as an install dir candidate whatever its case or trailing `\`
  (`-Home c:\dbx1\` and a parent naming `C:\dbx1` gave two candidates), and a
  quoted span holding `<`, `>`, `|`, `*` or `?` (a redirection or pipe, not a
  path) is not tried as a folder; both checked with the mocked process table.
- **0.9.0**: `-AgentHome` is no longer an option: `-Home <dir>` (`--home`)
  did the same, and two options for one thing break the options convention
  (docs/collector-engineering.md). `-AgentHome`, and every prefix of it
  PowerShell bound to it (`-A` to `-AgentHom`, also with `:value`), exits 2 with
  `-AgentHome is no longer an option: use -Home <dir>`. The report lines that
  named it now name `-Home`: `-Home given: <dir> (exists: ...)`, the install dir
  n/a reasons `... and no -Home given`, and the install goal reasons `-Home path
  not found`, `(pass -Home <dir>)` and `... no -Home given`. The shared ps1
  run-helpers block drops `$PRIV_GAP` and `Priv-Hint`, which nothing called
  since 0.8.0.
  Validated 2026-10-07 on jjsong-dotnet-lab (no DBX agent), elevated, Windows
  PowerShell 5.1 and pwsh 7: the 0.8.0 and 0.9.0 reports differ only in digits
  and in the two `no -Home given` lines, all COMPLETE and passing validate.sh
  --report. `-AgentHome C:\x -File`, `-A C:\x`, `-agenthome:C:\x`,
  `--agenthome=C:\x` and `-Ag` exit 2 with the line above; `-Bogus` and a bare
  `-Home` exit 2, `-Help` 0. `-Home C:\nope` and `--home=C:\nope` give `-Home
  given: C:\nope (exists: False)` and `-Home path not found` (INCOMPLETE). The VM
  was reverted to its pre-test snapshot.
- **0.8.0**: The collector requires an elevated PowerShell
  (`#Requires -RunAsAdministrator`), as collect-apmdotnet.ps1 does since 0.10.0.
  A run that is not elevated is refused by PowerShell before any line executes,
  `-Help` included, and the script checks the same itself before reading its
  arguments, since PowerShell applies `#Requires` only to a script run as a
  file; either way it exits 1 and writes no report. Why: not elevated, Windows
  hides another account's java command line, so the DBX process went unfound;
  the operator's decision (2026-10-07) is to refuse such a run. Removed with it,
  as only a run that is not elevated reached them: the "none among the tasks
  this account can see (not elevated)" scheduled-task line, the install goal's
  "java process(es) with an unreadable command line" reason, the privilege gap
  appended to the install and instance goal reasons, and the non-elevated
  `$PRIV_GAP` value. The README, the help text and FIELD-GUIDE say elevation is
  required.
  Validated 2026-10-07 on jjsong-dotnet-lab (SQL Server Express instances
  SQLEXPRESS and DBX2 running, no DBX agent), Windows PowerShell 5.1 and pwsh 7:
  elevated, the 0.7.3 and 0.8.0 reports differ only in digits, all COMPLETE and
  passing validate.sh --report; not elevated (OpenSSH as ggtuser), `-File` is
  refused by `#Requires` and a scriptblock run prints `collect-db-mssql.ps1 must
  run in a PowerShell started with "Run as Administrator"; ...`, both exit 1.
  The DBX-agent paths (install and instance goals obtained) were not run; their
  elevated output is unchanged by the code (only `$isAdmin`-false terms and an
  empty Priv-Hint were removed). The VM was reverted to its pre-test snapshot.
- **0.7.3**: Comments only, in the shared ps1 blocks (templates/groups/ps1.ps1):
  versions, dates and lab measurements are replaced by the design reason they
  supported (the measurements are in collectors/apm/dotnet/CHANGELOG.md 0.5.0
  and in the 0.3.0 entry below). Checked with the PowerShell parser: apart from
  comments and line breaks, the 0.7.2 and 0.7.3 tokens differ only in the
  `VERSION` string.
- **0.7.2**: Move TcpProbe into the shared ps1 fact-helpers block
  (templates/groups/ps1.ps1); no behavior change.
- **0.7.1**: Collection status (ps1 group `Emit-Time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`), as the shell collectors print; CONTRACT rule 1.
- **0.7.0**: Derived views removed (CONTRACT rule 1): section F's WA code
  histogram becomes, per code in order of first appearance, `WA123 (M
  occurrences): <first line holding it>` (counted as -AllMatches counted,
  case-insensitive as Select-String is, so the numbers are the old ones),
  the exception count keeps its first 3 lines (the old sample), and the
  TLS/SSL/login count gives its first line. The 3 sample lines are printed
  whole as in 0.6.0; a new first line (per code, per pattern) is cut at 400
  UTF-8 bytes on a character boundary with "(first N of M bytes)", and a
  line already printed in the list is named instead. "last log line" (the
  tail's last line) is gone; "newest agent log" gives its size and mtime.
  Section D: a whatap.conf longer than the 400 lines shown also gets its
  later lines that are not blank or `#` comments. Section G no longer
  re-prints dbms, db_ip/db_port and whatap.server.host/port (whatap.conf is
  in section D); an unset db_ip/db_port or whatap.server.host says so on
  the probe line. Section B's title is "B. Component discovery". Run on
  the lab host beside 0.6.0 under both PowerShells, elevated: 177 -> 172
  lines; with a 210 kB log line, 237 kB -> 28 kB; every report passes
  validate.sh --report (2026-09-27).
- **0.6.0**: Section B gives, per SQL Server instance installed on this host,
  Version, PatchLevel and Edition from
  `HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\<instance id>\Setup` (ids
  from `...\Instance Names\SQL`, both registry views on a 64-bit OS) and
  the FileVersion of `<SQLBinRoot>\sqlservr.exe`, so the engine build is in
  the default run without mssql.sql. Read through the .NET registry API;
  the same lines not elevated and over OpenSSH (lab host, 2026-09-27).
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
  Scheduled tasks come from schtasks and IPv4 addresses from the .NET
  interface list (the cmdlets' module imports cost 1.4-5.5 s); sqlservr
  processes come from the process inventory with their instance
  argument; an empty service or task list says "none".
  `windows/mssql.sql` (v0.2.0 to v0.3.0, 2026-09-27): classic sqlcmd 16.0
  strips leading `[...]` groups from a PRINT message, so the section labels
  `[n] title` arrived as ` title`; they now read `==== [n] title ====` and
  arrive intact through classic sqlcmd 16.0, go-sqlcmd 1.10.0 (stdout and
  `-o`) and `Invoke-Sqlcmd` of the SQLPS 16.0 module, on both instances of
  the lab host; SSMS was not run. On 2026-09-26 the pack (v0.2.0) ran without
  an error on both instances as a sysadmin and as a login holding only VIEW
  SERVER STATE and VIEW ANY DEFINITION.
- **0.4.0**: The status gives the run time, and when a bounded call was slow (3s),
  capped or not run past the deadline, the host load at start and end
  and where the time went, as the shell collectors do. CIM queries go
  through Get-CimBounded; CMD_TIMEOUT and RUN_DEADLINE are read from the
  environment.
- **0.3.0**: Operator messages go to stderr through `[Console]::Error.WriteLine`,
  not Write-Host: run as `pwsh -File ... > out`, Write-Host reached stdout and
  13 `>>` progress lines landed in a report (found 2026-09-25).
