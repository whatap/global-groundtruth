# collect-apmpython.sh — changelog

The version history of [`collect-apmpython.sh`](collect-apmpython.sh), newest
first. Every change to the script bumps its `VERSION` and adds one entry at
the top of this list (docs/authoring-guide.md, step 2); `tools/validate.sh`
checks that the newest entry is the script's `VERSION`.

- **0.10.5** — Split the large functions (_rep_runtimes, _rep_binding,
  discover) into per-section helpers; /proc/\<pid>/environ reads no longer
  print Permission denied on stderr as root without CAP_SYS_PTRACE. Report
  content unchanged.
- **0.10.4** — Shared code in synced blocks (R2 refactor): the skeleton's emit
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
- **0.10.2** — The interpreters this run starts (the python -c lookups, pip list)
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
- **0.10.1** — main is the apm group block `apm: main`; report unchanged. A --file run
  on a host without hostname(1) names the report after
  /proc/sys/kernel/hostname, else `uname -n`, and so does Target (both
  were: unknown, and validate.sh --report refused Target: host/unknown);
  the file name reuses the name Target resolved.
- **0.10.0** — Fewer options (user decision, 2026-09-26): `pip list` runs in every
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
- **0.9.1** — Shared helpers moved into the apm group block; report unchanged.
  The apm: blocks are copies of templates/groups/apm.sh.
- **0.9.0** — Cheaper sources (decision 4). The Odoo release.py lookup joins the one
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
- **0.8.0** — Only candidates count (decision 1): with no whatap_python process on
  the host, a process whose environ this uid cannot read and whose
  command line does not name whatap is not counted as an unread input,
  and the na reason names it. A stock distribution's root python
  daemons no longer make a non-root run INCOMPLETE. conf is missed, not
  na, when homes were found without a whatap.conf while a candidate's
  environ/cwd was unread (its home is unknown) (2026-09-26).
- **0.7.5** — A directory this uid can read but not enter lists its names again
  (the refactor's _names dropped them; ls did not).
- **0.7.4** — Readability refactor; report unchanged.
- **0.7.3** — Only a first re-run that also times out stops the re-runs. Once a
  lookup run alone has answered, the interpreter still answers, so a later
  hang is that lookup's own and the ones after it are still run
  (two separate hangs lost the last answer in 0.7.2; 2026-09-25).
- **0.7.2** — When a lookup run alone after a hang also times out, the lookups
  after it are not run (each would wait a full cap for the same
  cause): a common hang costs about two caps per interpreter, not ten.
  A lookup cut short by the run deadline says so, not "timed out"
  (2026-09-25).
