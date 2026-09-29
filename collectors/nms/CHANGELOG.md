# collect-nms.sh: changelog

The version history of [`collect-nms.sh`](collect-nms.sh), newest first. Every
change to the script bumps its `VERSION` and adds one entry at the top of this
list (docs/authoring-guide.md, step 2); `tools/validate.sh` checks that the
newest entry is the script's `VERSION`.

- **0.7.10**: Run helpers (skeleton): the `--out` mkdir always gets the
  command cap (plus 1 s), so a second boundary crossed right after the
  deadline check no longer skips it and exits 1 with a false "not writable"
  message.
- **0.7.9**: Run helpers (skeleton): `_out_dir_check` makes the `--out`
  directory even when the run deadline is already spent (the mkdir gets the
  command cap alone), instead of exiting 1 with a false "not writable" message
  and no report. Main: with stderr closed, fd 3 opens on /dev/null instead of
  `exec 3>&2` ending dash before the report.
- **0.7.8**: Emit helpers (skeleton): `progress`, `warn` and `notice` return 0
  when their write fails, so a run whose stderr is closed or full no longer
  exits 1 after a complete report.
- **0.7.7**: Run helpers (skeleton): `_why_124` and `_out_dir_check` move
  into the skeleton run helpers (the `--out` mkdir now runs under the command
  cap), and `_run_init` sets the probe error file and reads the uid once;
  `probe_merged` comes from the skeleton; no report change.
- **0.7.6**: Collection status (skeleton `_emit_time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table (sums largest first, time outside bounded calls) gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`); CONTRACT rule 1. `_run_init` sets its EXIT/INT/TERM/HUP traps before it creates the private directory: a signal in between left `ggt.*` behind.
- **0.7.5**: `_run_init` (skeleton) also takes the script as read from stdin when `$0` is the shell's own binary (`/bin/bash -s`, `$0 -ef /proc/$$/exe`): bash 3.2 under musl otherwise faulted in a loop at full CPU after `4<&0`.
- **0.7.4**: Shortened the top-of-file comment block: pointed the
  #nms-support traceability, docs cross-check and section detail at
  README.md instead of restating it. Comments only; report content unchanged.
- **0.7.3**: Split run_report (426 lines) into one _rep_\<letter> per section;
  the yum and apt repo loops are one loop. Report content unchanged.
- **0.7.2**: Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  _classify_err, _proc_hidden and _self_tree are the new host group block (db,
  nms; templates/groups/host.sh). Report unchanged (compared with 0.7.1 on
  this host).
- **0.7.1**: [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.7.0**: --out DIR (default .) puts the --file report in DIR; a DIR that
  cannot be written stops the run before it collects (2026-09-26).
  A value option given nothing, or a value starting with '-', exits 2
  ("missing value for --out"); it took the next option as its value.
- **0.3.0**: Validated on Ubuntu 24.04 with the whatap-nms 1.0.2 deb (2026-07-03):
  the install root resolved from the dpkg manifest (a doc-path false match was
  caught and excluded), and a real failed postinst (`httptools` vs
  `uvicorn[standard]==0.49.0`, `ResolutionImpossible` with pypi reachable, dpkg
  `half-configured`) was captured in one report.
