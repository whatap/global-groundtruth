# collect-apmpython.sh: changelog

The version history of [`collect-apmpython.sh`](collect-apmpython.sh), newest
first. Every change to the script bumps its `VERSION` and adds one entry at
the top of this list (docs/authoring-guide.md, step 2); `tools/validate.sh`
checks that the newest entry is the script's `VERSION`.

- **0.11.11**: Pid file line (apm group): a comm, state or ppid that cannot be
  read (/proc/\<pid> hidden by hidepid) says `n/a (not readable: ...)` instead
  of an empty value, and the state keeps its whole text (`D (disk sleep)`, not
  `D (disk`).
- **0.11.10**: Run helpers (skeleton): the `--out` mkdir always gets the
  command cap (plus 1 s), so a second boundary crossed right after the
  deadline check no longer skips it and exits 1 with a false "not writable"
  message.
- **0.11.9**: Run helpers (skeleton): `_out_dir_check` makes the `--out`
  directory even when the run deadline is already spent (the mkdir gets the
  command cap alone), instead of exiting 1 with a false "not writable" message
  and no report. Main: with stderr closed, fd 3 opens on /dev/null instead of
  `exec 3>&2` ending dash before the report.
- **0.11.8**: Emit helpers (skeleton): `progress`, `warn` and `notice` return
  0 when their write fails, so a run whose stderr is closed or full no longer
  exits 1 after a complete report.
- **0.11.7**: The shared main no longer calls _init_probe; _run_init sets
  _errfile, so the collector's one-line copy is gone. Report unchanged.
- **0.11.6**: Run helpers (skeleton): `_why_124` and `_out_dir_check` move
  into the skeleton run helpers (the `--out` mkdir now runs under the command
  cap), and `_run_init` sets the probe error file and reads the uid once;
  `probe_merged` comes from the skeleton; the CLI harness banner loses "DO NOT
  EDIT"; no report change.
- **0.11.5**: `_disc_go`'s Go-process read (`_go_rows`) is kept in a
  variable, not a file under `_tmp`: with no private temp directory it lost
  every Go-module pid (homes, `D_UNREAD` split, `resolve_fs` order). A timeout
  of that read records its reason (deadline vs command timeout) once, at read
  time, so section 4 and the goal-gap text agree.
- **0.11.4**: Discovery takes the Go module pids from the same
  `/proc/\<pid>/stat` read as section 4 (`_disc_go`; zombies are listed but
  not followed, and a timeout of that read is a goal gap). The section 4 line
  drops the per-state tally. `run/` is listed from one glob walk. `_rep_odoo`
  is split into three helpers, and hidepid, Go-agent homes, pid files and
  `WHATAP_PYTHON_AGENT_PATH` come from group helpers, all unchanged in effect.
- **0.11.3**: Collection status (skeleton `_emit_time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table (sums largest first, time outside bounded calls) gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`); CONTRACT rule 1. `_run_init` sets its EXIT/INT/TERM/HUP traps before it creates the private directory: a signal in between left `ggt.*` behind.
- **0.11.2**: `_run_init` (skeleton) also takes the script as read from stdin when `$0` is the shell's own binary (`/bin/bash -s`, `$0 -ef /proc/$$/exe`): bash 3.2 under musl otherwise faulted in a loop at full CPU after `4<&0`.
- **0.11.1**: The host section adds `/sys/class/dmi/id/product_uuid`: its
  `ls -l` line and `dmi product_uuid readable by uid N:` (yes or no, from an
  open and a read of the file); the value follows only when it was read (group
  block `apm: report helpers`, `_product_uuid`). Command lines and environ
  entries go through the new group block `apm: text helpers`: `_proc_words`
  (NUL, newline and CR each a space) and `_proc_lines` (one entry per line, a
  newline or CR inside an entry a space). A newline in an argument or a value
  no longer puts the rest at column 0, where a crafted argument made a fake
  `[5] Collection status` and failed `validate.sh --report`. `_u8cut` and
  `_pid1_cmd` moved from this file into the group blocks unchanged in effect
  (text helpers, report helpers), so all four members cut the same way.
  Affected here: the cmdline and env lines of `whatap_python`, python and odoo
  processes, the odoo `-c`/`ODOO_RC` read, and pid 1. The process table cuts
  its cmdline on a UTF-8 boundary (it cut inside a character with `substr`,
  and the report failed `validate.sh --report`), turns CR into a space, and
  reads a command line holding a newline (where `head -n 1` stopped) again
  whole. The same holds for comm (`_comm`, read builtin) and the exe and cwd
  lines (`_link_text`). The process table read exe targets from `ls -l`, where
  a target holding a newline printed a second line that could pose as another
  pid's (a crafted exe path made pid 1 a python process); a line naming no
  `/proc/<pid>/exe` or a pid named twice is detected. `_product_uuid` costs
  one fork (ls) when the file reads. `dmi product_uuid readable by uid N:`
  says `yes`, `no (open failed: <reason>)` or
  `no (opened, read failed: <reason>)`, the reason from `cat`'s stderr, which
  runs only then. The process table reads every comm in the same `head` pass
  as before (`head -n 16`, lines joined by a space), with no fork per pid, and
  re-reads with readlink only the exe of the pids a posing `ls -l` line
  involves. A newline or CR inside an environ value is kept apart from the
  variable boundaries and given back by `_env_pick`, so a `WHATAP_HOME`
  holding one is listed quoted among the paths not followed (D_ODD, which now
  also takes CR and lists each path once) instead of being looked up with
  spaces. A relative argv0 is not joined to a cwd holding a newline or CR,
  PYTHONPATH entries split on CR too, and the python environ lines are cut
  with `u8cut` in the awk that builds them. Goals unchanged.
- **0.11.0**: Section 4 lists the Go module (`whatap_python`) processes
  from one read of `/proc/<pid>/stat`, so a zombie is listed too (its
  cmdline is empty, and the process table skipped it: in
  jjsong-ggt-apm-python:1 with 20,000 unreaped `whatap_python` children,
  0.10.7 listed only the live one). The line gives the count found and the
  count per state; the first 20 are detailed, state Z last, each with its
  ppid (`-- pid N (ppid M)`); a zombie's detail is its uid/state line and
  `cmdline, cwd, environ: n/a (state Z)`; the rest is
  `-- remaining N whatap_python processes not detailed (cap: 20)`. With
  2,000 live ones 0.10.7 detailed all 2,005 (10,353 report lines), 0.11.0
  prints 493. Section 5 adds an entry line for each pid file next to its
  content (mode, links, owner, size, full mtime and name from `stat -c`;
  `ls -l`, minute precision, where stat gives nothing), the state and ppid of
  the process it names, `permission denied` for an unreadable pid file (it
  read `empty`), and lists `run/` the same way (first 40 of M entries, dot
  files first and counted; `present, 0 entries` when empty) instead of
  `present`. Command lines (pid 1, python, Go module, odoo processes) and the
  environ lines of python processes are cut at a byte count that never ends
  inside a UTF-8 sequence (`cut -c` and `substr` count bytes under
  `LC_ALL=C`; a cut Korean argument made the report invalid UTF-8 on this
  host). `WHATAP_*` environ lines stay uncut.
- **0.10.7**: Comments only; report content unchanged. Shortened long
  comment runs in `_pyrun`, `_pyreport` and the process-scan comment; the
  batching rationale now points to README "How each interpreter is asked".
- **0.10.6**: `apm: file helpers` (templates/groups/apm.sh): `wc -l` reading
  an unreadable file no longer leaks "Permission denied" to the operator's
  stderr (the `<` redirect ran before `2>/dev/null`, so its own failure was
  not yet silenced). Report content unchanged.
- **0.10.5**: Split the large functions (_rep_runtimes, _rep_binding,
  discover) into per-section helpers; /proc/\<pid>/environ reads no longer
  print Permission denied on stderr as root without CAP_SYS_PTRACE. Report
  content unchanged.
- **0.10.4**: Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  New apm blocks: report helpers (environment head, cgroup, container markers)
  and machine arch; resolve_fs, _sock_list and _scan_gaps joined the path,
  file and environ blocks. Report changes: the machine arch line comes from
  probe's output instead of a temp file, so when uname timed out, hit the
  deadline or failed it gives that reason (it said "no machine field in the
  uname -srm output"), and a non-zero exit with output reads "machine arch
  (exit N): ..."; the normal line is unchanged. APM_INTERP_CAP is checked by
  _cap_or: an ignored value is a `!!` line on the terminal instead of a fact
  line in the runtime section, and a leading zero (08) is ignored instead of
  read as 8. A value option without its value exits 2 without printing the
  usage after the message. Compared with 0.10.3 on this host and in
  jjsong-ggt-apm-python:1: reports equal but live values.
- **0.10.3**: [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.10.2**: The interpreters this run starts (the python -c lookups, pip list)
  run without the whatap/bootstrap entries of PYTHONPATH. Run by
  kubectl exec in an operator-injected pod, the shell inherits
  PYTHONPATH=/whatap-agent:/whatap-agent/whatap/bootstrap; its
  sitecustomize.py calls whatap.agent() in every interpreter, and one
  collector run killed the application's whatap_python Go module and
  left orphaned copies that outlived the run (lab container, 2026-09-27).
  Report: [1] names the entries removed; section 3 loses the agent's
  start-up lines ("WHATAP: AGENT UP!") that were added to each lookup.
  Each whatap package dir seen in process environ also gets the
  version and release_date lines of its build.py ("build.py: version
  = '2.1.2' release_date = '20260722'"): the operator's copy has no
  dist-info, so its version was n/a everywhere in section 3.
  Validated 2026-09-27 against real whatap-python agents: 2.2.0 from PyPI in
  a virtualenv under whatap-start-agent gunicorn, and the operator's
  apm-init-python copy (2.1.2, PYTHONPATH=/whatap-agent:/whatap-agent/whatap/bootstrap)
  under plain gunicorn; as root, as the app's user and as another user, bash
  and sh -s; no collection server was reachable, so the Go module opened no
  UDP listener and no TCP session.
- **0.10.1**: main is the apm group block `apm: main`; report unchanged. A --file run
  on a host without hostname(1) names the report after
  /proc/sys/kernel/hostname, else `uname -n`, and so does Target (both
  were: unknown, and validate.sh --report refused Target: host/unknown);
  the file name reuses the name Target resolved.
- **0.10.0**: Fewer options (user decision, 2026-09-26): `pip list` runs in every
  run again (it starts each detailed interpreter once more and reads
  what the default inventory reads, so it is not an opt-in by the load
  rule); --pip is refused with exit 2. It declares no goal: the library
  inventory of section [3] already answers the question, so an
  interpreter without a working pip is a fact line, not a blocked run.
  pip list is not started in an interpreter whose lookups did not
  answer within the cap. --out DIR puts the --file report in DIR; the
  help names APM_INTERP_CAP. An error reason over 100 bytes (probe)
  or 140 (interpreter lookups) keeps both its start (the error kind)
  and its end (where "No module named pip" is after a long path).
  On the validation host (8 detailed interpreters, 2026-09-26) a default run
  took 5.1-5.4 s with 0.9.1 and 6.7-7.1 s with 0.10.0, the same as 0.9.1
  with --pip (6.9-7.3 s).
- **0.9.1**: Shared helpers moved into the apm group block; report unchanged.
  The apm: blocks are copies of templates/groups/apm.sh.
- **0.9.0**: Cheaper sources (decision 4). The Odoo release.py lookup joins the one
  interpreter start of section [3] instead of a start of its own per
  interpreter; one that did not answer is named in section [8]. The
  library inventory is the dist-info/egg-info/egg/egg-link names in
  every sys.path directory, listed by that same start; `pip list` runs
  only with --pip, which then declares the goal `pip`. The machine arch
  is taken from the one `uname -srm` call. Inventory names and paths are
  escaped (control characters, undecodable bytes, characters the
  stdout encoding lacks), so one odd name cannot break a line or lose
  the list; a sys.path directory that cannot be stat'ed says why
  (2026-09-26).
- **0.8.0**: Only candidates count (decision 1): with no whatap_python process on
  the host, a process whose environ this uid cannot read and whose
  command line does not name whatap is not counted as an unread input,
  and the na reason names it. A stock distribution's root python
  daemons no longer make a non-root run INCOMPLETE. conf is missed, not
  na, when homes were found without a whatap.conf while a candidate's
  environ/cwd was unread (its home is unknown) (2026-09-26).
- **0.7.5**: A directory this uid can read but not enter lists its names again
  (the refactor's _names dropped them; ls did not).
- **0.7.4**: Readability refactor; report unchanged.
- **0.7.3**: Only a first re-run that also times out stops the re-runs. Once a
  lookup run alone has answered, the interpreter still answers, so a later
  hang is that lookup's own and the ones after it are still run
  (two separate hangs lost the last answer in 0.7.2; 2026-09-25).
- **0.7.2**: When a lookup run alone after a hang also times out, the lookups
  after it are not run (each would wait a full cap for the same
  cause): a common hang costs about two caps per interpreter, not ten.
  A lookup cut short by the run deadline says so, not "timed out"
  (2026-09-25).
