# collect-apmphp.sh — changelog

The version history of [`collect-apmphp.sh`](collect-apmphp.sh), newest first.
Every change to the script bumps its `VERSION` and adds one entry at the top
of this list (docs/authoring-guide.md, step 2); `tools/validate.sh` checks
that the newest entry is the script's `VERSION`.

- **0.7.5** — Split the large functions (_rep_runtimes, _rep_binding,
  discover) into per-section helpers; /proc/\<pid>/environ reads no longer
  print Permission denied on stderr as root without CAP_SYS_PTRACE. Report
  content unchanged.
- **0.7.4** — Shared code in synced blocks (R2 refactor): the skeleton's emit
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
- **0.7.3** — [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.7.2** — A php-cgi binary's php -i (HTML: the CGI SAPI prints phpinfo() as a
  page) is read as the text form the CLI prints; it was matched as
  text, so php-cgi showed "PHP n/a, SAPI n/a", "ini scan dir: none
  configured" and "whatap.* directives registered: no" while it
  loads whatap.so from /etc/php.d (Rocky 9, whatap-php 2.14-2 rpm,
  2026-09-27). A service file reached by two paths (/lib ->
  usr/lib) is dumped once. Report: section 3 and 6 carry php-cgi's
  values; section 7 loses the second copy of the unit file.
- **0.7.1** — main is the apm group block `apm: main`; report unchanged. A --file run
  on a host without hostname(1) names the report after
  /proc/sys/kernel/hostname, else `uname -n`, and so does Target (both
  were: unknown, and validate.sh --report refused Target: host/unknown);
  the file name reuses the name Target resolved.
- **0.7.0** — --out DIR puts the --file report in DIR (an unwritable one ends the
  run before collecting); the help names APM_INTERP_CAP. A probe
  error line over 100 bytes keeps its start and its end; report
  otherwise unchanged.
- **0.6.1** — Shared helpers moved into the apm group block; report unchanged.
  The apm: blocks are copies of templates/groups/apm.sh.
- **0.6.0** — Section 4 reuses the `php-fpm -v` of section 3 also when section 3
  ran it under a name that resolves to the PATH php-fpm (a running
  php-fpm8.2 found before the php-fpm link to it); the machine arch is
  taken from the one `uname -srm` (no second `uname -m`).
- **0.5.4** — _proc_env compares the variable name literally; PATH lookups read
  their answer back from a file instead of a second lookup in a $(...).
- **0.5.3** — "ini directory trees present" prints "(no whatap entry)" for a tree
  without one (the column was blank) and names an unreadable tree;
  section 4 reuses the `php-fpm -v` section 3 ran on the same binary.
- **0.5.2** — A directory this uid can read but not enter lists its names again
  (the refactor's _names dropped them; ls did not).
- **0.5.1** — Readability refactor; report unchanged.
