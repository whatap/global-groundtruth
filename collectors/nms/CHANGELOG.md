# collect-nms.sh — changelog

The version history of [`collect-nms.sh`](collect-nms.sh), newest first. Every
change to the script bumps its `VERSION` and adds one entry at the top of this
list (docs/authoring-guide.md, step 2); `tools/validate.sh` checks that the
newest entry is the script's `VERSION`.

- **0.7.1** — [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.7.0** — --out DIR (default .) puts the --file report in DIR; a DIR that
  cannot be written stops the run before it collects (2026-09-26).
  A value option given nothing, or a value starting with '-', exits 2
  ("missing value for --out"); it took the next option as its value.
