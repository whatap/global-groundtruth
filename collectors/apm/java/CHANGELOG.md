# collect-apmjava.sh — changelog

The version history of [`collect-apmjava.sh`](collect-apmjava.sh), newest
first. Every change to the script bumps its `VERSION` and adds one entry at
the top of this list (docs/authoring-guide.md, step 2); `tools/validate.sh`
checks that the newest entry is the script's `VERSION`.

- **0.14.0** — Report reduced to what confirms a cause; no flag added or
  removed. Section K (Kubernetes / operator injection context) is gone, so L,
  M and N are now `[12]`–`[14]` (letters kept): the collector shell's
  `JAVA_TOOL_OPTIONS` (0.13.2), `JAVA_HOME`, `WHATAP_JAVA_AGENT_PATH` and the
  pod variables are in `[1]` under "collector shell environment";
  `/var/run/secrets/kubernetes.io` and `/etc/hostname` are in A; the
  `/whatap-agent` listing is E's home listing (a home no attached JVM
  resolves is now listed there too), and E states `/whatap-agent: n/a (...)`
  when attached JVMs exist and it is absent. Section L no longer counts
  frames, thread states, thread-name shapes, dotted names or other APM
  agents' frames, and section N no longer joins its index to them: the dumps
  are the record, so a `--threads` dump is now printed in full (was the first
  5000 lines). A `--dump-file` is identified by path, size, line count and
  sha256 and included in full (it was counted before; the file may exist
  only on the field host).
  Section N drops the package histogram and the name-pattern index (count and
  class list stay); section M drops the package map of each detailed jar and
  of `BOOT-INF/classes` (class count stays; with `--appclasses` the classes
  are in N's list). Section G prints the count of bundled `weaving/*` and
  `whatap/agent/asm/*ASM` entries instead of listing up to 200 and 150 of
  them (weaving-list check against the jar and on-disk weaving directory
  stay) and no longer greps weaving / hook / instrumentation keys out of the
  config file, which section E dumps verbatim. For attached JVMs past E's cap
  of 8, E now prints `whatap.server.host`/`port` (with source) and the
  non-comment lines of the config file, and for a config file longer than
  the 400 printed lines, its non-comment lines past line 400 (J and G printed
  those facts for every JVM before). Section I drops the `[WA*]` code tally
  (the log tail is printed). Section J no longer re-derives
  `whatap.server.host`/`port` (E prints config file, whatap env and every
  `-Dwhatap.*`) and merges its two session lists into one from one `ss` call,
  each session once: first the sessions to the server port(s) and 6600 from
  any owner (where the 2026-09-11 BAF `vshell` sessions showed), then the
  other sessions of the attached JVMs, each group capped at 60 with "first N
  of M" when cut; an attached JVM of another uid is stated as `owner not
  visible to uid N`. Sessions of an unattached JVM to other ports are no
  longer listed. Section D, for a JVM without the WhaTap attach marker whose
  environ was read, prints pid, the detecting test, uid, start time, cwd,
  exe, program, cmdline and the VM options line, and drops comm, root and
  mount namespace, state and thread count, VmRSS, server markers, the
  `-javaagent` count, the JVM option variables and where fd 1 / fd 2 point; a
  JVM whose environ was not read keeps the full detail (its marker is not
  decided); the walk counts and tests are unchanged. Section B prints the
  `release` file of each running JVM's binary verbatim (was four keys) and
  runs `-version` only when that file is absent; java binaries on PATH,
  `JAVA_HOME` and the install-root globs that no running JVM uses are no
  longer searched for; a JVM whose `/proc/<pid>/exe` is not readable is
  listed with that fact and its absolute `argv[0]`, resolved as that JVM
  resolves it; when none resolves that way (`docker exec -u 0` without
  CAP_SYS_PTRACE, argv[0] `java`), the java the collector shell finds through
  `JAVA_HOME`, else `PATH`, is printed once and labelled as not verified to
  be that JVM's binary (0.13.7 reached it through its PATH/`JAVA_HOME`
  search). The usage text of `--library`, `--appclasses` and
  `--dump-file` says the same. On a development host with one attached and
  one unattached JVM the default run went from 646 to 464 lines.
- **0.14.0** (defects present in 0.13.7) — Section C: the in-jar
  `whatap/v.properties` of agent builds that ship it with CRLF put CR into
  the report (`validate.sh --report` fails on it); CR is removed. Section J:
  the port filter's `$(for ... case ... in ''|*[!0-9]*) ...)` was a syntax
  error under bash 3.2; the case patterns now carry a leading `(`.
- **0.13.7** — Comments only; report content unchanged. Shortened long
  comment runs in `_proc_env`, `_all_jvm_args`, `_jvm_opt_val`,
  `_jcmd_recover`, the path-resolution and `_nsresolve` header comments,
  `_find_jvms`, the JVM thread-name detection comment and
  `_appcls_strip_root`; the longer rationales moved to README "Design
  notes".
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
