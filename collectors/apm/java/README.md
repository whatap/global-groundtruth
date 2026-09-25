# collectors/apm/java — WhaTap Java APM agent collector

> **Status: SEEDED (v0; validated at `collect-apmjava.sh` 0.6.0, the third
> live run at FIF on 2026-09-17; the script's own `VERSION` is the current
> one, and the changes after 0.6.0 have not met a real host yet).**
> `collect-apmjava.sh` is a working Tier-0 collector, plus an opt-in library
> detail pack (`--library` / `--class`) and two opt-in Tier-2 flags
> (`--threads` / `--jcmd`), seeded by the Global team (CONTRACT rule 4 —
> interim ownership). Ongoing ownership belongs to the Java agent developers
> once handed over.

Collects the hidden facts a remote WhaTap Java-agent developer repeatedly asks
a field engineer for. The fact list was derived from the agent source
(`io.whatap.java/whatap.agent.tracer`, v2.2.76 — `Configure`, `ConfLog`,
`ConfHook`, `ContainerConf`, `ProcessTypeDetector`, `Logger`), the operator
Java injector (`internal/webhook/v2alpha1/injector_java.go`), and the Global
support cases 2026-06-16 (JBoss 5.1 `eorder_uat`), 2026-06-24 (`KBANESCFServer`
socket gateway) and 2026-06-30 (keypro GlassFish console/JUL logging loop).

**Four things about the Java agent shape the report.**

| | Fact | Why the report is built around it |
|---|---|---|
| Attach | `-javaagent:` may arrive on the command line **or** through `JAVA_TOOL_OPTIONS` / `JDK_JAVA_OPTIONS` / `_JAVA_OPTIONS` | the operator injects it via `JAVA_TOOL_OPTIONS`, so it never appears in `/proc/<pid>/cmdline`; all four sources are read and **every** `-javaagent` reaching the JVM is listed with a count (a second profiler is then a visible fact) |
| Config | env `WHATAP_CONFIG_FILE` > `-Dwhatap.config.file` > `-Dwhatap.home` + `-Dwhatap.config` (default `whatap.conf`). When `-Dwhatap.home` is absent the agent sets it to the directory of its own jar before reading the file (`whatap.agent.boot.AgentBoot`, `JarUtil.getJarLocation`); `Configure`'s literal default `"."`, the process working directory, is reached only when no `-javaagent` jar location is known | the home is a **per-process** fact, not a host fact, and a relative home or config path is relative to **that JVM's** working directory, so the collector joins it to `/proc/<pid>/cwd` and reads an absolute one through `/proc/<pid>/root` when the JVM is in another mount namespace, or when it runs under a chroot (a working directory is taken off the root's path and resolved the same way); a JVM whose root this run cannot read at all (another user's, as non-root) has its paths reported as not readable, never read from the collector's own filesystem in their place; every path is resolved symlink component by component under that root (an absolute link target is re-rooted there and `..` stops at it), because the kernel resolves a link met below `/proc/<pid>/root` against the collector's own root and a container's `whatap.conf -> /etc/shadow` would otherwise read the host's file; an operator-injected pod usually has no conf file at all and runs on environment values only, and the report shows exactly that |
| Overlay | the agent overlays environment variables and system properties onto the config file (`ConfigValueUtil.replaceSysProp`) | so the conf dump alone is not the effective setting — the whatap-related env of each process (names may contain dots: `license`, `whatap.server.host`) and every `-Dwhatap.*` argument are reported next to it |
| Version | the agent build fixes no version into the jar filename | version is read from **`whatap/v.properties` inside the jar** (`VERSION`/`BUILD`, the file `whatap.Version` itself reads), cross-checked by jar size/mtime/sha256 and by the `WhaTap Java v<version>` banner at the head of `logs/whatap.log` |

**A JVM is identified by what it maps, not by what it is called.** Four tests
run in order against each `/proc` entry: `comm`, the resolved `/proc/<pid>/exe`,
a JVM-only whole argument in `/proc/<pid>/cmdline`, and last a `libjvm.so` /
`libj9vm*.so` mapping in `/proc/<pid>/maps`. The fourth exists for the **native
launcher** shape: a program that creates the VM in its own process through the
JNI Invocation API (`JNI_CreateJavaVM`) keeps its own `comm` and `exe` and
builds the JVM option array in memory, so nothing in `/proc` names java. Axway
API Gateway's `vshell` is one such launcher; the test names none of them and
matches the mapping instead, so an unseen launcher is reported from the same
code (CONTRACT rule 2). Section D prints, per process, which of the four tests
settled it, and — for an empty result — how many `/proc` entries were scanned
and which tests were applied, so "no JVM is running here" is distinguishable
from "the walk could not see one".

Case 2026-09-11 (BAF, `hqapimgmtdev1`) is why: run as root, section D reported
`JVM processes: none found in /proc` while section J of the same run listed two
`vshell` processes in `ESTAB` to the collection server on :6600. Sections C and
E–L all cascaded to `n/a` behind that one empty result.

**A JVM found only by its mapping has its options nowhere in `/proc`**, so
sections E, F and G have nothing to read for it. `--jcmd` recovers them from
the running VM (`VM.command_line` `jvm_args`, `VM.system_properties`) and feeds
them into the same argument path every section already reads, so classpath,
`whatap.home`, server markers and the class index fill in. That is an attach on
a live process — Tier 2 — so it happens only with the flag, and only for the
processes whose options are absent from `/proc` (cap 4). Without the flag the
report states, per such process, that the options are absent and that the VM
was not asked for them.

**Application libraries are enumerated from the application, never from the
agent jar.** The agent jar bundles the weaving-module markers, so a scan whose
input includes it reports the agent's own catalog (case 2026-06-16 saw
`spring-boot-2.1`…`4.0` matched at once in a single app). Section F therefore
builds its inventory from the target JVM's own `-cp`/`-classpath`, its `-jar`
(`BOOT-INF/lib`, `WEB-INF/lib`), `CLASSPATH`, its own working directory, the
server directories derived from its own `-D` properties (`catalina.base`/`home`,
`jboss.home.dir`, `jboss.server.base.dir`, `jetty.base`/`home`, `jeus.home`,
`domain.home`) and its open jar file descriptors — with the `-javaagent` jar excluded and the exclusion stated in
the report.

## The common case: installed, healthy, but the hitmap stays empty

The most frequent Java support case is not a broken install — it is an install
whose application framework is not instrumented. Reading it needs **four facts
side by side**, and sections F and G are built to sit next to each other for
exactly that:

| leg | fact | where |
|---|---|---|
| 1. what the application carries | jar names **with their versions** from the classpath, the executable jar, the server lib/deploy directories and open file descriptors | `[7] F` |
| 2. what **this** agent build can instrument | the `weaving/<name>.jar` modules bundled in the installed jar (2.2.76 carries 96) and its built-in `whatap/agent/asm/*ASM` classes — listed from the jar, so the catalog matches the deployed version instead of a hardcoded table | `[8] G` |
| 3. what the configuration selects | the `weaving` / `weaving_reserved` list, `weaving_*_enabled`, `hook_service_*`, `hook_method_*`, `instrumentation_*`, `_enable_asm_*` lines, **plus a per-entry check of the weaving list against that jar** (`bundled in this jar` / `no weaving/<name>.jar entry in this jar` — a mistyped module name becomes a stated fact) | `[8] G` |
| 4. what the process actually loaded | the agent log's `Weaving` lines: one `Load <module>` per module that engaged, and the `Warning`/`Error` lines where a module's compiled class version is above the target class version (the module then does not apply) | `[8] G` |

Two loading paths are reported separately because they behave differently:
the `weaving=` list pulls modules **out of the agent jar**, while every jar
dropped into `<whatap.home>/weaving/` is loaded **whole-directory**,
independent of that list (`weaving_plugin_enabled`, default true).

The entry-point variant of the same symptom — the agent is instrumenting fine
but the transaction never starts, because the entry is not a servlet (JBoss
Remoting in case 2026-06-16, a socket message gateway in 2026-06-24) — is read
from `[5] D` (server markers and program identity: a socket gateway has none
of the servlet markers), the `hook_service_*` settings in `[8] G`, and, when
requested, the `[13] L` thread dump that names the real entry-point method.

Whether these facts explain the missing transactions is the reader's judgment;
the report carries the evidence for it and states no conclusion.

## When a new weaving module has to be written

The other frequent outcome is that no module exists yet and the agent
developer has to write one. A `weaving@<lib>` module is compiled **against the
customer's own artifact** (`weaving@axis-1.4/lib/axis-1.4.jar` is literally on
its compile classpath), it **redeclares the target class's fields and the
method it intercepts with the same names and signatures**, and it must not be
compiled for a class-file version above the target's — `WeaveMain` logs
`weaving-class-ver(N) is higher then target-class-ver(M)` and the module does
not apply. A jar file name does not carry any of that.

`--library PATTERN` produces those inputs for the named library — repeatable,
`--library-all` for every enumerated jar (cap 40):

| input the module author needs | how the pack supplies it |
|---|---|
| the artifact itself, or coordinates to fetch it | `META-INF/maven/<groupId>/<artifactId>/pom.properties` verbatim — the definitive groupId/artifactId/version; when it is absent the report says so, which is the signal that the jar itself has to be sent |
| which class-file version to compile for | the major version read from the first class entry (bytes 6–7), with the Java feature release derived (`52 (Java 8)`) |
| the real class namespace | package map by class count — a shaded or relocated library shows its actual packages here, not the ones the artifact name suggests |
| the exact target class members | `--class FQCN` runs `javap -p -s` against the jar that contains it: field names and types, method signatures **with the JVM descriptor of each member**, superclass |
| version identity for the module name and range | manifest `Implementation-Version` / `Bundle-Version` / `Build-Jdk`, plus size and sha256 to reproduce the exact artifact |
| whether the jar is multi-release or modular | `META-INF/versions/<n>` trees, `module-info.class`, `META-INF/services/*` |

**Spring Boot single (fat) jar.** The libraries are then not files on the host
at all — they are entries inside one jar, so nothing on the classpath points at
them. The collector handles that shape directly: section F reports the
executable jar's launcher manifest (`Start-Class` names the real application
entry class, `Spring-Boot-Version` decides which weaving module applies), the
layer index, and the package map of the application's own classes under
`BOOT-INF/classes`; and the detail pack **extracts the requested
`BOOT-INF/lib/<lib>.jar` entry** (bounded at 80 MB) to read its coordinates,
class-file version and members exactly as for a loose jar. Such a library is
reported with an `origin:` line naming the entry and its container instead of a
path, because it has none of its own — which is also what makes it clear that
"send us the jar" means extracting that entry. `--class` also resolves
application classes out of `BOOT-INF/classes`, so the entry-point class of a
fat-jar application can be dumped without unpacking the deployment.

## When the application's own entry point has to be found

A third outcome has nothing to do with libraries: the application is the
customer's own code, no weaving module will ever cover it, and the transaction
has to be started by `hook_service_patterns=<class>.<method>`. Writing that
line needs a class and a method name that nobody has yet.

The reflex is to ask for the source. That request goes into a security review
and comes back in weeks, if at all, and the visit is over before it does. The
deployed artifact and the running JVM answer the same question, and three
parts of this collector carry the answer:

| question | flag | section |
|---|---|---|
| which classes are the application's own, as opposed to its libraries | `--appclasses` | N: every class under `WEB-INF/classes`, `BOOT-INF/classes` and directory classpath entries, as a package histogram, a name-pattern index, and the class list |
| which of them actually run when a request is served | `--threads=N` | L: N thread dumps **plus a frame-frequency count over them**, split into JDK frames, WhaTap frames, and everything else, so the application frames that recur in every dump are on one screen |
| the same, from a dump the field already holds (WhaTap console thread dump, a jstack file, `kill -3` output) | `--dump-file PATH` | L: the file enters the same frame count and the thread-level counts (states, name shapes, dotted class-like names inside thread names, other APM agents' frames and threads) without pausing any JVM. With `--appclasses`, section N adds the join: which classes of the index appear as frames in the counted dumps, **0 stated as 0** when the dump was taken while no application code was on any stack |
| which of the indexed classes implement or call a given type (the Interfaces column of the console, from the artifact) | `--class-refs FQCN` | N: a byte scan of the same class files for the type in internal form. A class file carries every type it implements, extends, calls or references as a constant-pool entry, so the list is "names it", not "implements it" |
| what the exact signature of the chosen method is | `--class FQCN` | M: `javap -p -s`, whose `descriptor:` line is the string `hook_service_patterns` needs to separate overloads |

The name-pattern index in section N matches a fixed list of name fragments
(`Controller`, `Action`, `Servlet`, `Service`, `Facade`, `Job`, ...). The list
is printed verbatim in the report with the counts, and the classes matching
none of them are counted too, so the reader sees the whole population and not
only the part the list happened to catch.

Section N reads the artifact, never the JVM, so it can run against a
development instance long before anything is applied in production.

## One field command

Run **where the target JVM runs**, as the same OS user where possible (`jstack`
and `jcmd` require it):

```sh
# VM / bare metal
./collect-apmjava.sh --file          # -> whatap-apmjava-<host>-<UTC>.txt

# Kubernetes — pipe the script over stdin; nothing to copy into the pod,
# nothing written to a possibly read-only rootfs
kubectl exec -i <pod> -c <container> -- sh -s -- --stdout --quiet \
    < collect-apmjava.sh > report.txt

# Docker
docker exec -i <container> sh -s -- --stdout --quiet \
    < collect-apmjava.sh > report.txt

# a thread dump the field already holds, counted with the application index
./collect-apmjava.sh --file --appclasses --dump-file "/path/to/thread_dump.txt"
```

Paste or attach the entire output. No arguments prints usage; nothing runs by
accident. Progress is narrated on stderr (`--quiet` silences it).

When the agent developer needs the detail of a specific library (a new weaving
module, an unexplained version) or of a specific class (a non-servlet entry
point), the same script answers it in one more run:

```sh
./collect-apmjava.sh --file --library acme-gateway --class com.acme.gateway.MessageDispatcher
./collect-apmjava.sh --file --library-all          # when the library is not yet known
./collect-apmjava.sh --file --threads              # thread dump: which method the entry really is
```

Container notes:

- **POSIX sh is enough.** Verified byte-identical under bash 5 and dash.
- **Use `--stdout` in containers.** `--file` writes to the current directory,
  which fails on `readOnlyRootFilesystem` pods.
- **Distroless / no shell in the app container**: attach an ephemeral debug
  container sharing the pod's process namespace
  (`kubectl debug <pod> -it --image=busybox:stable --target=<container> -- sh`)
  and run the collector there. Homes and jars not visible in the debug
  container's own mount namespace are read through `/proc/<pid>/root/...` of
  the discovered JVMs.

## Facts collected (report sections)

| # | Section | Answers the recurring question |
| --- | --- | --- |
| 1 | Collection environment | which tools were available to this collection, the privilege and host boot time, the per-command cap and run deadline, and which opt-in flags were given |
| 2 | A. Host / platform | OS, kernel, CPU/memory, **cgroup limits** (the JVM sizes heap and thread pools from them), container markers, and clock/NTP state (transaction timestamps) |
| 3 | B. Java runtimes discovered | every java binary from running processes, PATH, `JAVA_HOME` and the install-root globs: the `release` file (free) plus `-version` (a separate short-lived JVM, never the target process). `-version` runs **only when both the name the binary was found or invoked under (PATH name, `argv[0]`) and the file it resolves to are named `java`**: any other JVM binary (an embedding launcher such as `vshell`, `jsvc`, or a symlink named `vshell` that points at `java`) is listed with the VM library it maps and the `release` file found above that library, and is never executed, because what it does with `-version` is its own business |
| 4 | C. WhaTap agent artifacts on disk | every agent jar found via `-javaagent`, `WHATAP_JAVA_AGENT_PATH` and `/whatap-agent`, each resolved as its own JVM resolves it (relative to that JVM's working directory, through its root when it is in another mount namespace), with size/mtime/sha256 and the in-jar `whatap/v.properties` (VERSION/BUILD); a jar that could not be read says why (`permission denied: …` / `path not found: …`); javahelper and other whatap files next to it |
| 5 | D. JVM processes and agent attachment | the `/proc` walk itself (entries scanned, entries skipped because their cmdline was unreadable while the process still existed, the four tests applied in order, how many processes the maps test could not read, which JVMs' `environ` this run could not read), a fifth test for the processes whose maps this run cannot read (another user's, as non-root): the VM's own thread names in the world-readable `/proc/<pid>/task/*/comm` (HotSpot `VM Thread`, `Signal Dispatch`, `Reference Handl`, `VM Periodic Tas`, `C1`/`C2 CompilerThre`, `GC Thread#<n>`, verified on OpenJDK 17; OpenJ9 `JIT Compilation`, `Signal Reporter`, `Finalizer maste`, not verified on a running OpenJ9; one glob of every thread's comm file and one grep; a process is a candidate only when two distinct VM thread names match, and a scan that hits its safety cap or time cap is reported as partial and blocks the goals). Only a **confirmed** JVM — a libjvm / libj9vm mapping read in its maps — is ever attached to (`jcmd`, `jstack`) or signalled (SIGQUIT); a JVM found only by its comm, an argument or its thread names is reported and counted, never attached. A wrapper that runs java as a child (`sudo`, `timeout`, `nohup`, `env`, `setsid`, `nice`, `tini`, …) is excluded by its comm even though its argv carries the JVM options. Then per JVM (WhaTap-attached first): **which test identified it as a JVM**, whether it shares the collector's mount namespace, verbatim cmdline, whether its `environ` was readable (when it was not, `JAVA_TOOL_OPTIONS` and the other injected options were not read), for a JVM found by its `libjvm.so` mapping whether its options were recovered from the VM via `--jcmd` or not asked for, **count and list of every `-javaagent` reaching the JVM from all four argument sources** with per-path existence as that JVM resolves the path, `JAVA_TOOL_OPTIONS`/`_JAVA_OPTIONS`/`JDK_JAVA_OPTIONS`/`JAVA_OPTS`/`CATALINA_OPTS`, server markers (the same properties `ProcessTypeDetector` reads), program identity (main class / executable jar; for a JNI-created VM the `java_command` the VM recorded, never a token off the launcher's own argv), uid, thread count, RSS, start time (from `/proc/<pid>/stat` and `btime`, which busybox `ps` cannot print), cwd, and **where fd 1 / fd 2 point** — the boot banner and any SIGQUIT dump land there, not in the agent log |
| 6 | E. Agent home resolution and configuration | the resolution this collector applies (the Config row above), then **per process** (cap 8): the config path and home it resolves to and where each came from (an assumed default file name is named as such), `whatap.conf` verbatim plus byte facts (size, CR 0x0D count — Windows-edited conf files are a recurring case), the whatap-related environment of that process (dotted names included), `whatap.env` (a properties text the agent applies over the config), every `-Dwhatap.*` argument, the home listing, `security.conf`/`paramkey.txt` presence and size (they hold the SQL-parameter encryption key, whose content is not collected), `container.conf` (the container id the k8s node agent writes). Then every home candidate with whether it was readable, and for a home no attached JVM resolves (collector-shell `WHATAP_HOME`, `/whatap-agent`) its `whatap.conf` under the assumed default name |
| 7 | F. Application libraries visible to the target JVMs | every jar of a listed directory is recorded even though only the first 120 are printed, so `--library` reaches one that sorts past the printed part; classpath entries, executable-jar contents (`BOOT-INF/lib`, `WEB-INF/lib`), `CLASSPATH`, server `lib`/`webapps/*/WEB-INF/lib`/`deploy`/`deployments` directories (exploded `*.ear/lib` and `*.war/WEB-INF/lib` included), and open jar file descriptors — **agent jar excluded, exclusion stated** |
| 8 | G. Agent instrumentation surface and weaving activation | **what this agent build can instrument**: the `weaving/<name>.jar` modules bundled in the installed jar and its built-in `whatap/agent/asm/*ASM` classes; the on-disk `<home>/weaving/` plugin directory (loaded whole-directory, independent of the weaving list) and the `<home>/plugin/*.x` script plugins (size, mtime); the weaving / `hook_service_*` / `hook_method_*` / `instrumentation_*` / `_enable_asm_*` settings in force, with a **per-entry check of the weaving list against that jar**; and the `Weaving` lines the running process wrote to the agent log (`Load <module>`, and the compiled-class-version `Warning`/`Error` that stops a module from applying) — bounded log window, never a whole-file grep |
| 9 | H. Application logging stack | logging `-D` properties, the logging libraries **filtered out of section F's inventory** (so a library that is present but not yet opened is still reported), logging config files in each working directory, the console destination and the server log directories with sizes — the on-disk volume and the collected volume are both facts a reader compares |
| 10 | I. WhaTap agent logs | per attached JVM, the log directory from `log_root` and the file name from `log_name` (read from `-D`, env or the config file, and the source named); when neither is set, `<home>/logs` and `whatap`, stated as the assumed defaults; then the directory inventory, the log head (the `WhaTap Java v<version>` banner) and tail, the most recent rotated `<log_name>-*.log` by mtime, and a `[WA*]` code frequency count over the last 500 lines — all bounded reads, sizes from the inode instead of a line count |
| 11 | J. Network endpoints | the `whatap.server.host`/`port` values reaching each JVM through `-D`, env or its config file (source named); the TCP sessions owned by the JVM processes (matched on the pid `ss -p` / `netstat -p` prints; as non-root these name the owner only of this uid's sockets, so another user's JVM is reported as `owner not visible to uid N` rather than as having no session); the TCP sessions to the configured server port(s) and to 6600 (the assumed default, which other WhaTap agents on the host use too) from any owner, where the process column is empty for a socket whose owner the uid cannot see; DNS resolvers, proxy variables |
| 12 | K. Kubernetes / operator injection context | `/whatap-agent` listing, `WHATAP_JAVA_AGENT_PATH`, `JAVA_TOOL_OPTIONS`, `POD_NAME`/`NODE_NAME`/`NODE_IP`/`OKIND`/`WHATAP_MICRO_ENABLED`, k8s markers |
| 13 | L. Tier 2 artifacts (opt-in) | `--threads[=N]`: N `jstack -l` dumps per attached JVM (cap 3 JVMs, 5000 lines per dump), falling back to `jcmd Thread.print -l` and then to SIGQUIT (whose output goes to the fd 1 target shown in section D), **followed by a frame-frequency count over the dumps just taken** — every `at <class>.<method>` line, counted and sorted, in three buckets defined by the package prefixes printed with them (JDK/vendor, `whatap.`, everything else). `--dump-file PATH` (repeatable) adds a dump taken elsewhere to the same counts without contacting any JVM. After the frame buckets: thread header count, thread states counted, thread name shapes (digit runs collapsed), dotted class-like names carried inside thread names with their package roots, and the frames and thread names of other APM agents on the same JVM against a fixed prefix list printed verbatim. `--jcmd`: `VM.command_line`, `VM.system_properties`, `VM.flags`, `VM.version` — for every WhaTap-attached JVM **and** every JVM whose options are absent from `/proc` (cap 3), since for the latter this is the only verbatim record of what it runs. When none of the flags is given the section states that no attach, signal or pause was applied |
| 14 | M. Library detail pack (opt-in) | `--library PAT` / `--library-all`: for every enumerated jar that matches, a byte-identical copy being named rather than detailed twice (several deployment units of one application carry the same jar, and detailing each copy spends the 40-jar cap on identical content), and the package histogram left out for a jar whose class names section N already prints — Maven coordinates from `META-INF/maven/*/pom.properties`, manifest version attributes, **class-file major version** (the number a weaving module has to be compiled against), package map (shading shows here), class count, multi-release/module/service entries; `--class FQCN` adds `javap -p -s` member signatures, JVM descriptor included. Libraries packed inside an executable jar are extracted (bounded at 80 MB) and reported with an `origin:` entry line instead of a path; `--class` also resolves application classes out of `BOOT-INF/classes` |
| 15 | N. Application class index (opt-in) | `--appclasses`: the classes the application itself ships, from every class root section F enumerated — directory classpath entries (a relative one resolved through the JVM's own working directory), the JVM's working directory itself when it carries `BOOT-INF/classes`, `WEB-INF/classes`, `classes` or a top-level class file, every configured Tomcat `appBase` and `docBase` rather than `<instance>/webapps` alone, a Jetty base's `webapps`, `WEB-INF/classes` of deployment units, `WEB-INF/classes` directories found under `jeus.home`/`domain.home`/`com.sun.aas.instanceRoot` (GlassFish, Payara) (depth 10; the WebLogic staging area depth 7; each search stops descending at every `WEB-INF`, visits at most 20000 directories and runs under the per-command cap, and the report states those bounds and marks the result partial when one was hit; first 12), a WebLogic domain located from `-Dweblogic.Name` plus the process working directory or its `DOMAIN_HOME` (the stock start scripts set no `domain.home`): `servers/<name>/tmp/_WL_user/**/WEB-INF/classes` and the `<source-path>` entries of `config/config.xml`, and `WEB-INF/classes`/`BOOT-INF/classes` read in place inside a war/ear/executable jar (cap 12 roots, 20000 class files per root). A `BOOT-INF/classes` or `WEB-INF/classes` segment at the head of a path inside a root is a layout artifact and is not printed as part of the class name. Reported as a class count, a package histogram, a name-pattern index over a fixed pattern list printed with it, a count of the classes matching none of those patterns, and the class list (first 2000). A class root that yields no class file also reports the jar count of its sibling `lib` directory, because a deployment unit can ship the application's own code as jars rather than as class files (name those jars with `--library` to get their class lists from section M). Then the join with section L: the frames of every counted dump whose class is in this index, with a stated 0 when there is none. Libraries are section F; this section is the application's own code |

## Collection status

The report ends with the goals it came for. Two are always declared: **agent
artifacts on disk** and **agent configuration**. Each requested opt-in adds
one: `--threads`, `--jcmd`, `--dump-file`.

- *agent artifacts* is obtained only when an agent jar opened as an archive
  (an agent home counts only when no jar is named anywhere), and only when
  every JVM that names an agent had it read: one JVM's corrupt or unreadable
  jar blocks the goal whatever the other JVMs show. Any JVM whose
  environment or VM options this run could not read blocks it, even when
  another JVM's agent was read: a `-javaagent` could arrive there. A JVM
  found by its VM library or thread names passed its options in memory, so it
  blocks the goal until `--jcmd` reads them back. The same holds for *agent
  configuration*. A jar or home that a JVM names but this run could not read is
  blocked. With no whatap marker anywhere, it is `na` only when the argument
  list and environment of every JVM were read; a non-root run that cannot read
  another user's `/proc/<pid>/environ` cannot see a `-javaagent` injected
  through `JAVA_TOOL_OPTIONS`, so it is blocked, with `run again with sudo`.
- *agent configuration* is obtained only when every attached JVM's config
  file was read. A config path that does not exist, or cannot be read, for
  any attached JVM blocks it, whatever the other JVMs show; with no attached
  JVM it is `na` when every input was read.
- *thread dumps* and *jcmd VM data* are blocked by any dump or query that
  failed, was refused or timed out; a failed `jstack` is reported with its
  output and is not counted as a dump.

## What the report can contain

Framework policy: what the report quotes is not masked — a mistyped license
or server address must be readable to be verified or refuted. So the report
can carry secrets from each of these places, and is handled as the
customer's configuration is:

| where | section | what it can carry |
|---|---|---|
| the agent config file (`whatap.conf` or the per-instance file `-Dwhatap.config` names) | E, G, J | `license`, `accesskey`, server addresses, any key the customer set |
| `container.conf` | E | the container id written by the node agent |
| the whatap-related environment of each JVM (`WHATAP_*`, `whatap.*`, `license=`, `accesskey=`, `whatap.env`) | E, J | license and access keys passed as environment |
| `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, `_JAVA_OPTIONS`, `JAVA_OPTS`, `CATALINA_OPTS`, `JAVA_OPTIONS`, `CLASSPATH` of each JVM | D, F | whatever the launcher passes there, `-D` credentials included |
| the full command line of each JVM, and pid 1's | A, D | `-D` passwords, keystore passwords, JDBC URLs with credentials |
| `jcmd VM.command_line` / `VM.system_properties` (`--jcmd`) | D, L | every system property of the VM, credentials the launcher passed included |
| thread dumps (`--threads`, `--dump-file`) | L | thread names and lock owners the application chose, which can embed user ids, SQL or URLs |
| agent log head and tail, rotated log tail | I | URLs, SQL text and error messages the agent logged |
| server log directory listings, deploy directories, WebLogic `<source-path>` entries | F, H | file and application names |
| jar manifests, Maven coordinates, `javap` member signatures (`--library`, `--class`) | M | build metadata, internal class and method names |
| the application class index (`--appclasses`) | N | the application's own class names |
| proxy variables of the collector shell | J | `http_proxy` may carry `user:password@` |

`security.conf` and `paramkey.txt` hold the SQL-parameter **encryption key**;
the report states their presence and size only, never their content. The
collector itself puts no credential on any command line it runs.

## Load profile

Tier 0 is read-only and **never attaches to, signals, or pauses the target
JVM**. It reads directory listings, bounded `head`/`tail` windows of logs
(sizes come from the inode, never from counting lines), jar central
directories via `unzip`, and searches server directories for
`WEB-INF/classes` (depth 7 under a WebLogic staging area, 10 under `jeus.home` / `domain.home` / `com.sun.aas.instanceRoot`, stopping at each `WEB-INF`, at most 20000 directories visited). Every
external command runs under `_bounded` (per-command cap 15s, whole run 300s,
`RUN_DEADLINE`), with or without `timeout(1)`. Process identification forks
a fixed handful of commands for the whole `/proc` (one `ls` of the exe links,
one `grep -z` over every cmdline, one `awk` for comm and the verdicts, one
`grep` over the maps of the processes the first three tests did not settle),
not one per process: 0.11.1 took 16.7s at 704 processes on a development
host, 0.12.0 took 4–7s at about 720 on the same host. `-version` is executed
only against discovered binaries named `java`, never against a running
process.

The library detail pack (`--library` / `--library-all` / `--class`) is off by
default because it is targeted, not because it is risky: it reads jar central
directories and single entries, extracts a packed library to a file under the
run's private directory only when one is requested, and never touches the
running JVM. Capped at 40 jars.

The application class index (`--appclasses`) is off by default for the same
reason: one `find` per class root (bounded at 20000 files) or one `unzip -Z1`
per archive root, capped at 12 roots, with no contact with the running JVM.

Tier 2 is off by default. Each flag prints its impact on the terminal before
running, also in `--file` mode: `--threads` pauses the target JVM at a
safepoint for each dump (cap 60s per dump), `--jcmd` uses the JVM attach
mechanism — once during discovery to recover the options of a JVM that has
none in `/proc` (cap 4 processes), and once in section L for the verbatim
`VM.*` output (cap 3). `jmap` is not used at all — never `jmap -histo:live`
(it forces a full GC).

Temporary files (jar listings, extracted nested jars, thread dumps, the
class-ref scan) live in the run's private directory, removed on exit and on
INT, TERM and HUP.

No `--bundle` tier yet; copy the bundle plumbing from `collect-collserver.sh`
if the domain team needs raw log artifacts.

## Validate

```sh
tools/validate.sh collectors/apm/java/collect-apmjava.sh
```
