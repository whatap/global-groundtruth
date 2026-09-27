# collect-apmnodejs.sh — changelog

The version history of [`collect-apmnodejs.sh`](collect-apmnodejs.sh), newest
first. Every change to the script bumps its `VERSION` and adds one entry at
the top of this list (docs/authoring-guide.md, step 2); `tools/validate.sh`
checks that the newest entry is the script's `VERSION`.

- **0.8.3** — [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.8.2** — The node processes this run starts (node --version, npm root -g,
  npm/pm2 --version) run without NODE_OPTIONS. Run by kubectl exec in
  an operator-injected pod, the shell inherits NODE_OPTIONS=-r whatap,
  and npm root -g loaded the agent: it initialised, tried to rewrite
  whatap.conf, opened a UDP channel to the running whatap_nodejs and
  wrote its start-up to the pod's hook log, and its console lines
  became the "global node_modules" value (lab container, 2026-09-27).
  Report: [1] says whether NODE_OPTIONS was removed and whether it
  named whatap; section 3 gets the real npm root -g.
- **0.8.1** — main is the apm group block `apm: main`; report unchanged. A --file run
  on a host without hostname(1) names the report after
  /proc/sys/kernel/hostname, else `uname -n`, and so does Target (both
  were: unknown, and validate.sh --report refused Target: host/unknown);
  the file name reuses the name Target resolved.
- **0.8.0** — --out DIR puts the --file report in DIR (an unwritable one ends the
  run before collecting). A probe error line over 100 bytes keeps
  its start and its end; report otherwise unchanged.
- **0.7.1** — Shared helpers moved into the apm group block; report unchanged.
  The apm: blocks are copies of templates/groups/apm.sh.
- **0.7.0** — The npm and pm2 versions are read from the package.json next to the
  entry script each command resolves to (the line names the file);
  `npm/pm2 --version`, which starts node, runs only when that file gives
  none, and its line then names the command. A value read from the
  file does not show whether npm/pm2 can run. The machine arch is taken
  from the one `uname -srm` (no second `uname -m`).
- **0.6.2** — A directory this uid can read but not enter lists its names again
  (the refactor's _names dropped them; ls did not).
- **0.6.1** — Readability refactor; report unchanged.
- **0.6.0** — Less work per node process: _env_pick settles an absent name with one
  match and splits the environ with IFS instead of a read loop, NODE_PATH
  is split in the shell, the cwd each process resolved in discovery is
  reused by the report, and the detail list reads each environ once.
  The report is unchanged; 8.4 s -> 4.9 s on a host with 168 node
  processes, 18.3 s -> 9.5 s with 300 more (2026-09-25).
