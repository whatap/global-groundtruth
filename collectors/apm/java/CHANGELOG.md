# collect-apmjava.sh — changelog

The version history of [`collect-apmjava.sh`](collect-apmjava.sh), newest
first. Every change to the script bumps its `VERSION` and adds one entry at
the top of this list (docs/authoring-guide.md, step 2); `tools/validate.sh`
checks that the newest entry is the script's `VERSION`.

- **0.13.6** — Section F: a `-cp`/`-classpath` directory entry ending in `/`
  (e.g. `/srv/cp app/classes/`) is used without the slash: its "directory
  root" line drops the trailing `/`, and section N no longer shows its class
  names as `.srv.cp app.classes.com.acme…`. `--class-path X` and
  `--class-path=X` are recognized alongside `-cp` and `-classpath` (was "-cp
  not set"). With `-jar app.jar -cp bogus` the `-cp` after the jar is the
  application's argument and is no longer read as the JVM's (`_jvm_opt_val`
  stops at `-jar`'s value; an application argument after a main class, with no
  `-jar`, is still not told apart: the merged argument sources carry no
  boundary). Section N (index and `--class-refs`): a class path nesting
  `WEB-INF/classes/` and `BOOT-INF/classes/`, in either order or the same one
  twice, loses both leading segments (`_appcls_strip_root`, shared by every
  root kind). It was `BOOT-INF.classes.p.X` for
  `WEB-INF/classes/BOOT-INF/classes/p/X` in dir, lib-jar and ref roots,
  `WEB-INF.classes.p.X` for `BOOT-INF/classes/WEB-INF/classes/p/X` in archive
  roots, and `BOOT-INF.classes.r.X` for a doubled segment. The size check of a
  jar before a --class-refs scan no longer prints an open error on stderr.
  Report content otherwise unchanged.
- **0.13.5** — Split _rep_libs, _rep_tier2, _rep_appclasses and _rep_conf into
  per-subsection functions; -jar/-cp extraction is _jvm_opt_val, /proc link
  reads are _link_or_na, the WEB-INF/classes search is _libs_classes_under.
  Report content unchanged.
- **0.13.4** — Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  The opening facts of the environment section, the cgroup facts and the
  container markers are the apm: report helpers block. A value option without
  its value (`--out` last) exits 2 with "missing value for --out" and no
  longer prints the usage after it. Report unchanged (compared with 0.13.3 on
  this host and in jjsong-ggt-apm-java:1).
- **0.13.3** — [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.13.2** — Every JVM this run starts (java -version, javap, jcmd, jstack) runs
  without JAVA_TOOL_OPTIONS, JDK_JAVA_OPTIONS and _JAVA_OPTIONS. Run
  by kubectl exec in an operator-injected pod, the shell inherits
  JAVA_TOOL_OPTIONS=-javaagent:..., and each java -version loaded the
  WhaTap agent: two "WhaTap Java v... / Start ..." banners and weaving
  lines in the pod's whatap.log per run, read back by section I as
  the agent's own (lab k8s, 2026-09-27). Report: [1] names the
  variables removed; B's -version loses the "Picked up
  JAVA_TOOL_OPTIONS" lines; K prints the value the shell had.
- **0.13.1** — main is the apm group block `apm: main`; report unchanged. The
  warning for --class without --library comes from _init_probe, right
  after the private temp directory is made (was: right before).
  Without hostname(1) and /proc, Target and the --file name take
  `uname -n` (was: unknown); the file name reuses Target's name.
- **0.13.0** — Fewer options (user decision, 2026-09-26): --library '*' details
  every enumerated jar (cap 40) and --library-all is refused with exit
  2 naming it. --class-refs turns on --appclasses (it searches the class
  roots that index reads; alone it did nothing), and [1] says so.
  --class without --library is named on the operator stream, not
  silently ignored. Report: [1] loses the field --library-all=N
  ("library detail flags: --library=\<patterns, * for all>
  --class=..."), and M says "not requested (--library absent)" and
  "patterns requested: * (every enumerated jar)". --out DIR puts the
  --file report in DIR. An option missing its value (last, empty after
  =, or followed by another option) ends the run with exit 2 under
  every shell; --threads=N takes a whole number 1..999999 only.
  --library patterns are matched with globbing off. A
  probe error line over 100 bytes keeps its start and its end.
- **0.12.6** — Shared helpers moved into the apm group block; report unchanged.
  The apm: blocks are copies of templates/groups/apm.sh.
