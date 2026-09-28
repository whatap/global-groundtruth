# collect-apmjava.sh: changelog

The version history of [`collect-apmjava.sh`](collect-apmjava.sh), newest
first. Every change to the script bumps its `VERSION` and adds one entry at
the top of this list (docs/authoring-guide.md, step 2); `tools/validate.sh`
checks that the newest entry is the script's `VERSION`.

- **0.15.9**: Emit helpers (skeleton): `progress`, `warn` and `notice` return
  0 when their write fails, so a run whose stderr is closed or full no longer
  exits 1 after a complete report.
- **0.15.8**: Section B names each unexecuted binary's own case: "binary
  deleted since the JVM started" for an exe link marked (deleted), "not
  executable by uid N" for a binary that is there but not executable, "not
  found at this path" when it is not there; the binary of an unconfirmed
  process keeps ", binary deleted".
- **0.15.7**: `_jvm_maps_lib` reads the VM library path as the whole rest of
  the maps line (paths with spaces were cut at the first space) without a "
  (deleted)" suffix, and takes only a path ending in /libjvm.so or libj9vm*.so
  (a libjvm.so.debug no longer confirms a JVM).
- **0.15.6**: Section B: a JVM whose exe link is marked (deleted) is listed
  only, never run with -version, even when the path exists again (a JDK
  upgraded in place); its VM library comes from the maps, and when that
  library is deleted too the release file now at its path is not read. One
  invoked under another name keeps `, invoked as NAME`. The D_JAVA_OTHER
  header is reworded to hold for every entry. Section G's `weaving list check:
  n/a` becomes `weaving list: n/a`. The --class-without---library warning
  comes from run_report, right after the collecting-facts progress line (so
  not on a --file run stopped by a bad --out).
- **0.15.5**: Run helpers (skeleton): `_why_124` and `_out_dir_check` move
  into the skeleton run helpers (the `--out` mkdir now runs under the command
  cap), and `_run_init` sets the probe error file and reads the uid once;
  `probe_merged` comes from the skeleton; the CLI harness banner loses "DO NOT
  EDIT"; no report change.
- **0.15.4**: Section B lists a JVM whose binary was deleted after it
  started, or is not executable by this uid, among the binaries not run, with
  the reason `binary deleted or not executable`; it used to be dropped, so
  section B could say `java binaries: none` while section D listed the JVM.
  Section G again prints each agent jar's raw `weaving/*` entry list (cap 200)
  in place of the count, and no longer matches the config's weaving list
  against the jar (the list stays in the section E config dump). Report-value
  cuts go through `_u8cut`, so a cut no longer splits a UTF-8 character. The
  section J session lists and the directory listings run as shell functions
  instead of helper scripts written per run (checked under bash 5.2 `bash
  -s`); a slow or capped one is named by its function in the collection status
  instead of `sh`. Internal: helpers `_release_block`, `_conf_overflow`,
  `_zcat` and `_fd_ls` (one fd snapshot for sections D and F); `_rep_jvms`,
  `_rep_weaving` and `discover` are split into functions.
- **0.15.3**: Collection status (skeleton `_emit_time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table (sums largest first, time outside bounded calls) gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`); CONTRACT rule 1. `_run_init` sets its EXIT/INT/TERM/HUP traps before it creates the private directory: a signal in between left `ggt.*` behind.
- **0.15.2**: `_run_init` (skeleton) also takes the script as read from stdin when `$0` is the shell's own binary (`/bin/bash -s`, `$0 -ef /proc/$$/exe`): bash 3.2 under musl otherwise faulted in a loop at full CPU after `4<&0`.
- **0.15.1**: The host section adds `/sys/class/dmi/id/product_uuid`: its
  `ls -l` line and `dmi product_uuid readable by uid N:` (yes or no, from an
  open and a read of the file); the value follows only when it was read (group
  block `apm: report helpers`, `_product_uuid`). Command lines and environ
  entries go through the new group block `apm: text helpers`: `_proc_words`
  (NUL, newline and CR each a space) and `_proc_lines` (one entry per line, a
  newline or CR inside an entry a space). A newline in an argument or a value
  no longer puts the rest at column 0, where a crafted argument made a fake
  `[5] Collection status` and failed `validate.sh --report`. Affected here:
  the verbatim cmdline (one argument per line), argv[0], the JVM argument list
  read for `-javaagent` and `-D` (an argument holding a newline no longer
  reads as two), the whatap-related environ lines and `_proc_env`, and pid 1's
  command line (`_pid1_cmd`, shared: one line of 160 bytes instead of 160
  bytes of each of its lines). Cuts end on a UTF-8 boundary (`_u8cut`, the awk
  `u8cut`, one text in the block). The `program: main class` line and the
  environ lines (400) are cut that way instead of by `cut -c`. The same holds
  for the comm line (`_comm`, read builtin) and the exe, cwd and fd link
  targets (`_link_or_na` and the JVM binary via `_link_text`: a newline or CR
  as a space). The /proc walk read exe targets from `ls -l`, where a target
  holding a newline printed a second line that could pose as another pid's; a
  line naming no `/proc/<pid>/exe` or a pid named twice is detected (the
  common case stays one `ls` per xargs batch). `_product_uuid` costs one fork
  (ls) when the file reads. `dmi product_uuid readable by uid N:` says `yes`,
  `no (open failed: <reason>)` or `no (opened, read failed: <reason>)`, the
  reason from `cat`'s stderr, which runs only then. The /proc walk re-reads
  with readlink only the exe of the pids a posing `ls -l` line involves. A
  working directory holding a newline or CR is not followed: a relative path
  joined to it (config, logs, home, hs_err, the working-directory listings)
  reads
  `not followed: the working directory of pid N ... holds a newline or CR (<path with spaces>)`.
  Goals unchanged.
- **0.15.0**: The default run prints the version facts that place an
  environment in or out of the supported range; no flag added, goals
  unchanged. Section D, per attached JVM (and per JVM whose environ was not
  read): the application server's own version file, read as a file, never
  by running a server tool: Tomcat `org/apache/catalina/util/ServerInfo.properties`
  from `lib/catalina.jar` under `-Dcatalina.base`, else `-Dcatalina.home`
  (comment lines left out); JBoss/WildFly `<jboss.home.dir>/version.txt`, and
  `modules/system/layers/base/org/jboss/as/product/*/dir/META-INF/MANIFEST.MF`
  only when it is absent; WebLogic `Implementation-Version` /
  `Specification-Version` of `weblogic.jar` under `-Dweblogic.home` /
  `-Dwls.home` (`lib/` or `server/lib/`); JEUS the version attributes of
  `<jeus.home>/lib/system/jeus.jar`'s manifest; GlassFish/Payara
  `Bundle-Version` of `modules/glassfish.jar` or `common-util.jar` under
  `-Dcom.sun.aas.installRoot`; `n/a (home unknown: ...)` when the main class
  or another property names the server but no home is set. The ls -l line
  of every fd that points at a `whatap.agent*.jar` marked `(deleted)` (the
  agent jar replaced on disk after the JVM started; F leaves the agent jar
  out of its list). `ls -l` of the fatal error logs (content not read) in
  the working directory, in the `-XX:ErrorFile` directory with that file
  name pattern (`%p` as `*`, `%%` as `%`) and in `/tmp` (once per mount
  namespace), first 10 of N by name (Slack
  C08U55BRDLJ p1765421788557589, p1784696473992619: hs_err files pasted by
  hand). Section C: `ls -ld /var/run/whatap` and `/var/run/whatap/agent`
  once per run, in the collector's own view (Slack C08U55BRDLJ
  p1789716743920059: a batch host logged `parent unwritable:
  /var/run/whatap/agent`). Section B: when `<bin>/../release` is absent and
  that directory is a `jre`, the release file one level up is read (Zulu 7:
  `bin/java` links into `jre/`, and `/opt/zulu7/release` was missed; found
  by the java-zoo lab target); `-version` also runs when the release file
  read is that parent one or its `JAVA_VERSION` is `1.x` without an update
  (Zulu 7's holds `1.7.0` only, and the update and vendor build are in
  `-version`). Section F: a `/proc/<pid>/fd` whose links
  this run cannot read (root without CAP_SYS_PTRACE) is `open jar files: n/a
  (permission denied: ...)`; it was reported as 0 open jars. Verified on
  Tomcat 9.0.122 (Temurin 17, dash) and WildFly 41.0.1.Final (JDK 25, bash)
  with agent 2.2.77 attached by `-javaagent`, and on the java-zoo target;
  WebLogic, JEUS and GlassFish/Payara are not verified.
- **0.14.0**: Report reduced to what confirms a cause; no flag added or
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
- **0.14.0** (defects present in 0.13.7): Section C: the in-jar
  `whatap/v.properties` of agent builds that ship it with CRLF put CR into
  the report (`validate.sh --report` fails on it); CR is removed. Section J:
  the port filter's `$(for ... case ... in ''|*[!0-9]*) ...)` was a syntax
  error under bash 3.2; the case patterns now carry a leading `(`.
- **0.13.7**: Comments only; report content unchanged. Shortened long
  comment runs in `_proc_env`, `_all_jvm_args`, `_jvm_opt_val`,
  `_jcmd_recover`, the path-resolution and `_nsresolve` header comments,
  `_find_jvms`, the JVM thread-name detection comment and
  `_appcls_strip_root`; the longer rationales moved to README "Design
  notes".
- **0.13.6**: Section F: a `-cp`/`-classpath` directory entry ending in `/`
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
- **0.13.5**: Split _rep_libs, _rep_tier2, _rep_appclasses and _rep_conf into
  per-subsection functions; -jar/-cp extraction is _jvm_opt_val, /proc link
  reads are _link_or_na, the WEB-INF/classes search is _libs_classes_under.
  Report content unchanged.
- **0.13.4**: Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  The opening facts of the environment section, the cgroup facts and the
  container markers are the apm: report helpers block. A value option without
  its value (`--out` last) exits 2 with "missing value for --out" and no
  longer prints the usage after it. Report unchanged (compared with 0.13.3 on
  this host and in jjsong-ggt-apm-java:1).
- **0.13.3**: [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.13.2**: Every JVM this run starts (java -version, javap, jcmd, jstack) runs
  without JAVA_TOOL_OPTIONS, JDK_JAVA_OPTIONS and _JAVA_OPTIONS. Run
  by kubectl exec in an operator-injected pod, the shell inherits
  JAVA_TOOL_OPTIONS=-javaagent:..., and each java -version loaded the
  WhaTap agent: two "WhaTap Java v... / Start ..." banners and weaving
  lines in the pod's whatap.log per run, read back by section I as
  the agent's own (lab k8s, 2026-09-27). Report: [1] names the
  variables removed; B's -version loses the "Picked up
  JAVA_TOOL_OPTIONS" lines; K prints the value the shell had.
- **0.13.1**: main is the apm group block `apm: main`; report unchanged. The
  warning for --class without --library comes from _init_probe, right
  after the private temp directory is made (was: right before).
  Without hostname(1) and /proc, Target and the --file name take
  `uname -n` (was: unknown); the file name reuses Target's name.
- **0.13.0**: Fewer options (user decision, 2026-09-26): --library '*' details
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
- **0.12.6**: Shared helpers moved into the apm group block; report unchanged.
  The apm: blocks are copies of templates/groups/apm.sh.
