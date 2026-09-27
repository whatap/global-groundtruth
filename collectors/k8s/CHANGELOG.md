# collect-k8s.sh — changelog

The version history of [`collect-k8s.sh`](collect-k8s.sh), newest first. Every
change to the script bumps its `VERSION` and adds one entry at the top of this
list (docs/authoring-guide.md, step 2); `tools/validate.sh` checks that the
newest entry is the script's `VERSION`.

- **0.11.1** — [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.11.0** — The Tier 0 log lines per container come from the environment,
  LOG_TAIL_LINES (default 200, 1..999999; another value is named in a
  !! line and 200 is used). --tail is refused, naming LOG_TAIL_LINES.
  The help shows -n for --namespace. An --out directory that cannot be
  written stops the run before it collects (2026-09-26).
  A value option given nothing, or a value starting with '-', exits 2
  ("missing value for --out"); it took the next option as its value.
- **0.10.0** — Section [1] states the API round trip: the time of the one
  reachability call (get --raw /version) in ms, no extra call
  (2026-09-26).
- **0.9.0** — The whatap namespace, the whatap workloads and the node-agent pods are
  goals: a refused, failed or timed-out list behind them is missed and
  the run INCOMPLETE (it was COMPLETE). The operator log tail is cut from
  the 4000-line read when that read holds it (one call instead of two).
- **0.8.6** — --apm-exec reads the runtime versions without JAVA_TOOL_OPTIONS and the
  other agent variables: the JVM loaded the WhaTap agent, which wrote a
  Start block to the app's whatap.log on every run.
- **0.8.5** — Readability refactor; report unchanged. Fewer API calls, same
  answers: section J reads each workload and each pod in one call
  (14 -> 1 per pod), the operator deployment and operator pod list reads
  of section D are merged, and section A counts namespaces from the list
  section J prints (3 --apm-target, lab cluster: 111 s -> 75 s).
- **0.8.4** — A CMD_TIMEOUT from the environment is used (it was overwritten by a
  fixed value after _run_init had checked it) (2026-09-26).
