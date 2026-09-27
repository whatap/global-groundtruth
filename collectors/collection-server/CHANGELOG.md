# collectors/collection-server — changelog

The version history of each collector in this directory, one section per
collector, newest first. Every change to a script bumps its `VERSION` and adds
one entry at the top of its section (docs/authoring-guide.md, step 2);
`tools/validate.sh` checks that the newest entry is the script's `VERSION`.

## collect-collserver.sh

- **0.11.6** — Split run_report (439 lines) into one _rep_\<x> per section;
  the WHATAP_HOME na/missed ladder of D, F and G is _home_missed. Report
  content unchanged.
- **0.11.5** — Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  The systemd helpers (_sd, _sd_prefetch, sd_show, sd_state, unit_loaded) and
  resolve_yardbase are collection-server group blocks shared with collzfs;
  sd_show, sd_state and unit_loaded take the full unit name. Report unchanged
  (compared with 0.11.4 on this host).
- **0.11.4** — [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.11.3** — stderr stays quiet on an unreadable file: 2>/dev/null now covers the <
  redirect it followed, which failed before it took effect.
  _is_whatap_server steps past a token that holds the prefix
  again: one pass per token, not one per copy; report unchanged.
- **0.11.2** — _is_whatap_server moved into the collection-server process scan
  block, written with case patterns so the block parses under dash;
  report unchanged.
- **0.11.1** — Helpers moved into the collection-server group blocks; report
  unchanged. The blocks are copies of
  templates/groups/collection-server.sh.
- **0.11.0** — Fewer options. The log caps come from the environment: LOG_FILE_MB
  (default 5) and LOG_TOTAL_MB (default 100), whole numbers 1..999999
  (another value is ignored with a warning). --log-days rides on
  --with-rotated as --with-rotated=DAYS (default 14). Removed options
  exit 2 naming the replacement: --max-log-mb, --max-total-mb,
  --log-days. A bundle-only option (--threads, --histo, --heap, --du,
  --with-rotated) given without --bundle is named on the terminal
  instead of ignored silently, and no longer raises the run deadline.
  A value option with an empty value, or with the next option taken
  for it (`--out --file`), exits 2. Report unchanged; the bundle's
  SELECTION.txt and log warning name the new spellings.
- **0.10.0** — Section A reads hostname, kernel and arch from /proc/sys/kernel
  (hostname/uname only where a file is unreadable) and no longer
  prints the date and the timezone: section B has both, and its
  timezone falls back to date +%Z as A's did. The --time-ref curl is
  bounded and its Date header loses the trailing CR; a failure names
  curl's exit status. A call cut by the
  run deadline (java -version, journalctl, curl) says "run deadline
  reached", not "timed out".
- **0.9.2** — Readability refactor; report unchanged.
- **0.9.1** — No *.hprof found is "none", not "n/a (empty output)", and only when
  every directory searched could be listed (a symlink this uid cannot
  follow is not absent; a missing home is "path not found", a dangling
  symlink says so); otherwise n/a with the uid, also next to dumps
  found elsewhere. A process counts as a whatap module only when it is
  java and names a server/opslake jar or the yard boot class.
- **0.9.0** — An absence is `na` only when every input behind it was read (conf/,
  logs/, hidepid, cmdlines, the process scan, a JVM whose home was not
  found, unit files, install paths). WHATAP_HOME is also found from a
  JVM's cwd, $WHATAP_HOME and common install paths. Every external
  command is bounded (a hung systemctl is asked once); discovery is one
  grep over /proc and one `systemctl show`. The bundle is built in the
  private directory; bad numeric options exit 2, a failed write exits 1;
  output is handed back under sudo. Needs bash.

## collect-collzfs.sh

- **0.8.6** — Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  The systemd helpers and resolve_yardbase are collection-server group blocks
  shared with collserver, and probe is the skeleton's (zprobe skips a zpool or
  zfs that hung earlier). Behaviour change: after one systemctl call hits its
  cap the rest are skipped, with a `!!` line, as collserver does (each used to
  wait CMD_TIMEOUT; their values were empty either way). Report unchanged
  otherwise (compared with 0.8.5 on this host).
- **0.8.5** — [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.8.4** — stderr stays quiet on an unreadable file: 2>/dev/null now covers the <
  redirect it followed, which failed before it took effect.
  _is_whatap_server steps past a token that holds the prefix
  again: one pass per token, not one per copy; report unchanged.
- **0.8.3** — _is_whatap_server moved into the collection-server process scan
  block, written with case patterns so the block parses under dash;
  report unchanged.
- **0.8.2** — Helpers moved into the collection-server group blocks; report
  unchanged. The blocks are copies of
  templates/groups/collection-server.sh.
- **0.8.1** — --out, --home, --window and --filesizes= with an empty value, or
  with the next option taken for it (`--out --file`), exit 2 naming
  the option. iostat -x in the window only adds detail: absent (no
  sysstat), failed or stopped, it is a "not delivered:" fact line in
  section O and no longer blocks the window goal, whose inputs are the
  txgs, the kstat deltas and zpool iostat.
- **0.8.0** — A time window runs in every run (15s; --window=DUR[@START] sets its
  length and start) and replaces --sample. Section O keeps every txg of
  the window (the txgs ring re-read before it
  wraps, merged by txg number, gaps counted); the start, end and delta
  of dmu_tx, arcstats and each objset-* kstat; zpool iostat -vlq and
  iostat -x started together at the same interval, with timestamps;
  zpool iostat -r / -w for the window; arcstat when present. J's
  "interval sample (--sample)" subsection is gone, and [1]'s tiers
  line reads "... filesizes=off window=off" (no sample=). Removed
  options exit 2 naming the replacement: --sample, --window-start,
  --no-filesizes, and --filesizes-secs, --event-days, --hours, which are
  now FILESIZES_SECS, EVENT_DAYS and JOURNAL_HOURS in the environment
  (defaults 300, 30, 24). H's per-pool kstat paths no
  longer carry a double slash (yard//zil).
- **0.7.0** — zpool list -v runs once: the raw probe's output feeds the derived
  views of sections C and H and the bundle's zpool-list-v.txt (it was
  run a second time, capped at 20s, for the views, and a third time
  for the bundle). Report unchanged when the call answers; the views
  now follow the probe's CMD_TIMEOUT cap, not a fixed 20s. The zpool
  feature checks (section A) and the zfs-unit journal (L) say "run
  deadline reached" when the deadline cut them, not "timed out".
- **0.6.4** — A zpool status -vt that succeeds with no output (no pool imported) is
  one "empty output" line again, not a fallback to -v and -t (0.6.3).
- **0.6.3** — Readability refactor; report unchanged.
- **0.6.2** — The file-size walk is opt-in (Tier 2) again: on a yard of ~10^8 files
  it loads the special vdev and the ARC and cannot finish in its bound.
  df -i of every WhaTap path is in the report and df-i.txt in the
  bundle, so the file count is there without a walk.

## collect-collmysql.sh

- **0.10.5** — Split run_report (454 lines) into one _rep_\<x> per section;
  section I is split into select, decode and per-file parts, and
  _binlog_proc's network-namespace check is _bl_netns_owns. Report content
  unchanged.
- **0.10.4** — Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  Report change: a probe whose command exits non-zero with output prints that
  output under "label (exit N):" instead of "label: n/a (...)", as the other
  collectors do. The caps BINLOG_TIMEOUT, PROMPT_TIMEOUT, RUN_DEADLINE and
  CMD_TIMEOUT are checked by _cap_or: an ignored value is one `!!` line per
  variable ("NAME=V ignored (not a whole number 1..999999 without leading
  zeros), using D") instead of one combined line; the rule is unchanged. The
  last field of a line is cut without eval. Compared with 0.10.3 on this host:
  reports equal but live values.
  --help names BINLOG_TIMEOUT instead of printing its value, which is now
  checked after the options.
- **0.10.3** — [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
  The auto.cnf read of the pid-file check gets the same 2>/dev/null as
  0.10.2's loops: a mysqld that exits after the -r test printed the
  error to the operator's screen.
- **0.10.2** — stderr stays quiet on an unreadable file: 2>/dev/null now covers the <
  redirect it followed, which failed before it took effect; report
  unchanged.
- **0.10.1** — Helpers moved into the collection-server group blocks; report
  unchanged. The blocks are copies of
  templates/groups/collection-server.sh.
- **0.10.0** — Every run samples: section J runs iostat -x and vmstat together for
  a 15s window (6 reports each, at a fifth of the window), and
  --window=DUR (N, Ns, Nm or Nh, 10s .. 24h) sets its length. It
  replaces --sample, which ran the two one after the other for about
  50s. J is a goal of every run, blocked only when the deadline cut
  or skipped the window or every sampler present failed; an absent
  sampler (no sysstat) or one failure of two is a fact line, and
  with neither installed the goal is not declared. [1]'s "sampling tier:" line is now "window:".
  --out DIR is where --file writes (checked before collecting: an
  unwritable one exits 1). Removed options exit 2 naming the
  replacement: --no-sudo (it did nothing since 0.8.0), --sample. A
  value option with an empty value, or with the next option taken for
  it, exits 2; --mysql-args takes a value that starts with '-' (it is
  the client's arguments), but not an empty one or one of this
  collector's own options (either form, e.g. --defaults-file=/x).
  A signal during the window stops the samplers (none is left
  running) and the report is written with what they wrote ("ended
  early: SIG...").
- **0.9.0** — Binary log sizes come from SHOW BINARY LOGS only: section C lists
  the directory once for the mtimes (no du; the listing sums the files
  only when SHOW BINARY LOGS gave no list), and section I takes the
  newest files and their sizes from those rows, not from ls per file.
  A SQL call cut by the run deadline says "run deadline reached", not
  "timed out". A cut or refused SHOW BINARY LOGS is no list. The
  login check is the client's status, whose Connection line ([1]
  "connected to:") classifies the target: a TCP address neither this
  host nor a local mysqld's network namespace owns is a remote server
  (a gap, no local process looked at). SHOW BINARY LOG STATUS falls
  back to SHOW MASTER STATUS only on its syntax error (before 8.2,
  MariaDB) instead of asking both. Otherwise the
  binary logs are read only through the server's own process: the
  local mysqld/mariadbd whose pid file (@@pid_file through
  /proc/\<pid>/root, or here when that root cannot be entered) holds its
  pid and was written with the server's start (mtime against now -
  Uptime), whose auto.cnf holds @@server_uuid where readable, and whose
  binlog directory holds the server's newest log with nothing newer (a
  newer one: SHOW BINARY LOGS asked once more, and it must list it). Its /proc/\<pid>/root\<binlog dir> is read and a
  "binlog files: via pid ..." line says so. None (a remote server, a
  copied datadir), two, or an unreadable pid file is
  a gap with the reason. Paths come from a readable @@log_bin_index
  (logs in more than one directory; such a file is named by its
  path); a selected file that is not there, or a name listed twice
  with no index, is named and blocks the goal.
- **0.8.3** — @@log_bin, @@log_bin_basename and @@datadir are asked for once (the
  value shown is the value used), and one ps serves both the login
  reason and section A. Report unchanged.
- **0.8.2** — Readability refactor; report unchanged.
- **0.8.1** — --connect-expired-password passes through. An empty line or end of
  input at the -p prompt says so instead of "none given", next to the
  shared privilege hint on a failed login.
  A word after a bare -p (a database name to the client) is warned about.
- **0.8.0** — Never elevates or re-runs itself (--no-sudo warns it is not needed).
  No credential on a command line: a password in --mysql-args ends the
  run (exit 2); it comes from a bare -p, MYSQL_PWD or an option file and
  reaches the client in a mode-600 file. Every wait is bounded; refused
  SHOW BINARY LOGS, a failed or capped decode, a NULL log_bin_basename and
  no local mysqld without arguments are gaps with reasons. Needs bash.
