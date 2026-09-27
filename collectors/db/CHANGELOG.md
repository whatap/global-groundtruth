# collectors/db — changelog

The version history of each collector in this directory, one section per
collector, newest first. Every change to a script bumps its `VERSION` and adds
one entry at the top of its section (docs/authoring-guide.md, step 2);
`tools/validate.sh` checks that the newest entry is the script's `VERSION`.

## collect-db.sh

- **0.8.3** — The per-instance body of _rep_sql moves to _rep_sql_inst. Report
  content unchanged.

- **0.8.2** — Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  _classify_err, _proc_hidden and _self_tree are the new host group block (db,
  nms; templates/groups/host.sh). Report change: a probe whose command exits
  non-zero with output prints that output under "label (exit N):" instead of
  "label: n/a (...)". OPT_HOME_ADDED, never read, removed. Compared with 0.8.1
  on this host: reports equal but live values.
- **0.8.1** — [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.8.0** — TLS facts are part of every run: section K (one handshake per
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
- **0.7.0** — Round trips in ms: each section G tcp connect states its time in ms
  (it was whole seconds, "0s"), and --sql states the JDBC connect time
  and one trivial query's time (SELECT 1; SELECT 1 FROM DUAL on Oracle)
  per instance, measured in the runner VM (2026-09-26).
- **0.6.0** — The architecture is taken from the one `uname -smr` (no second
  `uname -m`).
- **0.5.3** — Each (file, key) of a config is read once per run: sections G, H, J,
  K and L asked for the same keys again, 7 forks and 6 execs each
  (72 reads -> 40 for 3 instances with --tls). Report unchanged.
- **0.5.2** — Readability refactor; report unchanged.
- **0.5.1** — A CMD_TIMEOUT from the environment is used (it was overwritten by a
  fixed value after _run_init had checked it) (2026-09-26).
- **0.5.0** — Discovery reads each /proc/\<pid>/cmdline and comm with builtins, with
  no fork per process: `$(tr)`, `$(cat)` and `$(_db_kind_of_comm)` per
  pid made the scan cost about 15 ms per process (9.2 s -> 1.4 s on a
  720-process host, 38.7 s -> 2.0 s with 2000 more). The report is
  unchanged. The --sql terminal prompt waits no longer than what is
  left of RUN_DEADLINE; a prompt nobody answers skips that instance
  with the reason in the sql goal (2026-09-25).

## windows/collect-db-mssql.ps1

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
  Scheduled tasks come from schtasks and IPv4 addresses from the .NET
  interface list (the cmdlets' module imports cost 1.4-5.5 s); sqlservr
  processes come from the process inventory with their instance
  argument; an empty service or task list says "none".
- **0.4.0** — The status gives the run time, and when a bounded call was slow (3s),
  capped or not run past the deadline, the host load at start and end
  and where the time went, as the shell collectors do. CIM queries go
  through Get-CimBounded; CMD_TIMEOUT and RUN_DEADLINE are read from the
  environment.
