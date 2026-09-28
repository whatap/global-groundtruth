# collect-apmphp.sh: changelog

The version history of [`collect-apmphp.sh`](collect-apmphp.sh), newest first.
Every change to the script bumps its `VERSION` and adds one entry at the top
of this list (docs/authoring-guide.md, step 2); `tools/validate.sh` checks
that the newest entry is the script's `VERSION`.

- **0.8.9**: Run helpers (skeleton): the `--out` mkdir always gets the command
  cap (plus 1 s), so a second boundary crossed right after the deadline check
  no longer skips it and exits 1 with a false "not writable" message.
- **0.8.8**: Run helpers (skeleton): `_out_dir_check` makes the `--out`
  directory even when the run deadline is already spent (the mkdir gets the
  command cap alone), instead of exiting 1 with a false "not writable" message
  and no report. Main: with stderr closed, fd 3 opens on /dev/null instead of
  `exec 3>&2` ending dash before the report.
- **0.8.7**: Emit helpers (skeleton): `progress`, `warn` and `notice` return 0
  when their write fails, so a run whose stderr is closed or full no longer
  exits 1 after a complete report.
- **0.8.6**: _init_probe only sets the php -i file and is called by
  run_report; the shared main no longer calls it. Report unchanged.
- **0.8.5**: Run helpers (skeleton): `_why_124` and `_out_dir_check` move
  into the skeleton run helpers (the `--out` mkdir now runs under the command
  cap), and `_run_init` sets the probe error file and reads the uid once;
  `probe_merged` comes from the skeleton; the CLI harness banner loses "DO NOT
  EDIT"; no report change.
- **0.8.4**: The whatap_php.pid line gets an entry line (full mtime), state
  and ppid, and `permission denied` for an unreadable file (group
  `_pid_file_fact`). The module-name list is cut on a UTF-8 boundary. hidepid
  comes from a group helper, and exe/cwd lines from `_link_shown`, both
  unchanged in effect.
- **0.8.3**: Collection status (skeleton `_emit_time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table (sums largest first, time outside bounded calls) gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`); CONTRACT rule 1. `_run_init` sets its EXIT/INT/TERM/HUP traps before it creates the private directory: a signal in between left `ggt.*` behind.
- **0.8.2**: `_run_init` (skeleton) also takes the script as read from stdin when `$0` is the shell's own binary (`/bin/bash -s`, `$0 -ef /proc/$$/exe`): bash 3.2 under musl otherwise faulted in a loop at full CPU after `4<&0`.
- **0.8.1**: The host section adds `/sys/class/dmi/id/product_uuid`: its
  `ls -l` line and `dmi product_uuid readable by uid N:` (yes or no, from an
  open and a read of the file); the value follows only when it was read (group
  block `apm: report helpers`, `_product_uuid`). Command lines and environ
  entries go through the new group block `apm: text helpers`: `_proc_words`
  (NUL, newline and CR each a space) and `_proc_lines` (one entry per line, a
  newline or CR inside an entry a space). A newline in an argument or a value
  no longer puts the rest at column 0, where a crafted argument made a fake
  `[5] Collection status` and failed `validate.sh --report`. Cuts end on a
  UTF-8 boundary (`_u8cut`, the awk `u8cut`, one text in the block). Affected
  here: `_proc_cmd` (the cmdline of web, php and `whatap_php` processes, 300
  bytes), the `WHATAP_*` environ line, `_proc_env`, and pid 1's command line
  (`_pid1_cmd`, 160 bytes, one line). The process table (group block) turns CR
  into a space too, and a command line holding a newline (where `head -n 1`
  stopped) is read again whole, so argv0 and the words after the newline are
  kept. The same holds for comm (`_comm`, read builtin, six lines) and the exe
  and cwd lines. The process table read exe targets from `ls -l`, where a
  target holding a newline printed a second line that could pose as another
  pid's; a line naming no `/proc/<pid>/exe` or a pid named twice is detected.
  `_product_uuid` costs one fork (ls) when the file reads.
  `dmi product_uuid readable by uid N:` says `yes`,
  `no (open failed: <reason>)` or `no (opened, read failed: <reason>)`, the
  reason from `cat`'s stderr, which runs only then. The process table reads
  every comm in the same `head` pass as before (`head -n 16`, lines joined by
  a space), with no fork per pid, and re-reads with readlink only the exe of
  the pids a posing `ls -l` line involves. Goals unchanged.
- **0.8.0**: Derived views removed (CONTRACT rule 1, "Derived views"); every
  fact they carried is still in the report as read. Section 6 is "Tracer
  binding (module, ini, load state)" and no longer has one block per runtime:
  the "PHP x, SAPI y, PHP API z, Thread Safety w" line, the runtime's
  `extension_dir` and `ini scan dir`, "whatap.* directives registered: yes/no"
  and "dynamic-library load message" repeated the `php -i` lines of section 3
  (`PHP Version`, `Server API`, `PHP API`/`Thread Safety`, `extension_dir`,
  `Scan this dir`/`Additional .ini files parsed`, the `whatap.*` directive
  list) and the `php -v`/`php -m` output and stderr there. "it resolves to:
  whatap_X.so (name encodes: thread-safe build, PHP API)" decoded the module
  name; the name is now printed as read, with more than before: whatap.so is
  shown once per extension_dir with `ls -l`, sha256, symlink target,
  `readlink -f` and the resolved file's `ls -lL` (size, mtime). The
  "runtime-reported: yes/no" column (a join with section 3) is gone; the
  first source of each dir is printed. The per-runtime "scan dir: whatap ini"
  lines moved into "ini directories present and their whatap entries", which
  now also lists each absolute scan dir php -i named. Section 3 loses "other
  APM / profiler extensions among the loaded module lists above" (a filter of
  the `php -m` lists printed just above it). Run on apm-php-rocky and
  apm-php-alpine (tools/lab/run.sh --base HEAD): only these lines differ.
  Section 5 loses "php version -> PHP API map in this install.sh" (vendor
  source parsed out of install.sh; install.sh's ls and sha256 stay, and the
  README names its get_php_api_version()). In section 6, a relative scan dir no process
  cwd resolved is listed in the ini directory list as "n/a (relative scan dir of <bin>, not
  resolved)", as the per-runtime block printed it.
- **0.7.6**: `apm: file helpers`/`apm: conf bytes` (templates/groups/apm.sh):
  `wc -l`/`wc -c`/`tr -dc '\r'` reading an unreadable file no longer leak
  "Permission denied" to the operator's stderr (the `<` redirect ran before
  `2>/dev/null`, so its own failure was not yet silenced). Report content
  unchanged.
- **0.7.5**: Split the large functions (_rep_runtimes, _rep_binding,
  discover) into per-section helpers; /proc/\<pid>/environ reads no longer
  print Permission denied on stderr as root without CAP_SYS_PTRACE. Report
  content unchanged.
- **0.7.4**: Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  New apm blocks: report helpers (environment head, cgroup in section 2,
  container markers in the container section), machine arch, conf bytes;
  resolve_fs and _sock_list joined the path and file blocks. The machine arch
  line is read from probe's output (PROBE_OUT); its text is unchanged in every
  case the old parse handled. Report change: APM_INTERP_CAP is checked by
  _cap_or, so an ignored value is a `!!` line on the terminal instead of a
  fact line in section 3, and a leading zero (010) is ignored instead of read
  as 10. A value option without its value exits 2 without printing the usage
  after the message. Compared with 0.7.3 on this host and in
  jjsong-ggt-apm-php-rocky:1: reports equal but live values.
- **0.7.3**: [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.7.2**: A php-cgi binary's php -i (HTML: the CGI SAPI prints phpinfo() as a
  page) is read as the text form the CLI prints; it was matched as
  text, so php-cgi showed "PHP n/a, SAPI n/a", "ini scan dir: none
  configured" and "whatap.* directives registered: no" while it
  loads whatap.so from /etc/php.d (Rocky 9, whatap-php 2.14-2 rpm,
  2026-09-27). A service file reached by two paths (/lib ->
  usr/lib) is dumped once. Report: section 3 and 6 carry php-cgi's
  values; section 7 loses the second copy of the unit file.
- **0.7.1**: main is the apm group block `apm: main`; report unchanged. A --file run
  on a host without hostname(1) names the report after
  /proc/sys/kernel/hostname, else `uname -n`, and so does Target (both
  were: unknown, and validate.sh --report refused Target: host/unknown);
  the file name reuses the name Target resolved.
- **0.7.0**: --out DIR puts the --file report in DIR (an unwritable one ends the
  run before collecting); the help names APM_INTERP_CAP. A probe
  error line over 100 bytes keeps its start and its end; report
  otherwise unchanged.
- **0.6.1**: Shared helpers moved into the apm group block; report unchanged.
  The apm: blocks are copies of templates/groups/apm.sh.
- **0.6.0**: Section 4 reuses the `php-fpm -v` of section 3 also when section 3
  ran it under a name that resolves to the PATH php-fpm (a running
  php-fpm8.2 found before the php-fpm link to it); the machine arch is
  taken from the one `uname -srm` (no second `uname -m`).
- **0.5.4**: _proc_env compares the variable name literally; PATH lookups read
  their answer back from a file instead of a second lookup in a $(...).
- **0.5.3**: "ini directory trees present" prints "(no whatap entry)" for a tree
  without one (the column was blank) and names an unreadable tree;
  section 4 reuses the `php-fpm -v` section 3 ran on the same binary.
- **0.5.2**: A directory this uid can read but not enter lists its names again
  (the refactor's _names dropped them; ls did not).
- **0.5.1**: Readability refactor; report unchanged.
