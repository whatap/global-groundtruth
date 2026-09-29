# collectors/apm/java: WhaTap Java APM agent collector

> **Status:** validated at `collect-apmjava.sh` 0.15.2 on 2026-09-28, the lab
> `apm-java` / `apm-java-jto` containers (Temurin 21.0.12, real agent 2.2.77
> attached by `-javaagent` and by `JAVA_TOOL_OPTIONS`, JVM uid 1500); COMPLETE,
> `validate.sh --report` pass.
> Not yet run on: a running OpenJ9, WebLogic, JEUS, GlassFish/Payara server.
> Owner: Global team until handover to the Java agent developers (CONTRACT rule 4).

Collects the hidden facts a remote WhaTap Java-agent developer repeatedly asks
a field engineer for. The fact list was derived from the agent source
(`io.whatap.java/whatap.agent.tracer`, v2.2.76), the operator Java injector
(`internal/webhook/v2alpha1/injector_java.go`) and Global support cases (see
"Cases").

**Four things about the Java agent shape the report.**

| | Fact | Why the report is built around it |
|---|---|---|
| Attach | `-javaagent:` may arrive on the command line **or** through `JAVA_TOOL_OPTIONS` / `JDK_JAVA_OPTIONS` / `_JAVA_OPTIONS` | the operator injects it via `JAVA_TOOL_OPTIONS`, so it never appears in `/proc/<pid>/cmdline`; all four sources are read and **every** `-javaagent` reaching the JVM is listed with a count (a second profiler is then a visible fact) |
| Config | env `WHATAP_CONFIG_FILE` > `-Dwhatap.config.file` > `-Dwhatap.home` + `-Dwhatap.config` (default `whatap.conf`). When `-Dwhatap.home` is absent the agent sets it to the directory of its own jar before reading the file (`whatap.agent.boot.AgentBoot`, `JarUtil.getJarLocation`); `Configure`'s literal default `"."`, the process working directory, is reached only when no `-javaagent` jar location is known | the home is a **per-process** fact, not a host fact, and a relative home or config path is relative to **that JVM's** working directory, so the collector joins it to `/proc/<pid>/cwd` and reads an absolute one through `/proc/<pid>/root` when the JVM is in another mount namespace, or when it runs under a chroot (a working directory is taken off the root's path and resolved the same way); a JVM whose root this run cannot read at all (another user's, as non-root) has its paths reported as not readable, never read from the collector's own filesystem in their place; every path is resolved symlink component by component under that root (an absolute link target is re-rooted there and `..` stops at it), because the kernel resolves a link met below `/proc/<pid>/root` against the collector's own root and a container's `whatap.conf -> /etc/shadow` would otherwise read the host's file; an operator-injected pod usually has no conf file at all and runs on environment values only, and the report shows exactly that |
| Overlay | the agent overlays environment variables and system properties onto the config file (`ConfigValueUtil.replaceSysProp`) | so the conf dump alone is not the effective setting: the whatap-related env of each process (names may contain dots: `license`, `whatap.server.host`) and every `-Dwhatap.*` argument are reported next to it |
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
settled it, and, for an empty result, how many `/proc` entries were scanned
and which tests were applied, so "no JVM is running here" is distinguishable
from "the walk could not see one".

**A JVM found only by its mapping has its options nowhere in `/proc`**, so
sections E, F and G have nothing to read for it. `--jcmd` recovers them from
the running VM (`VM.command_line` `jvm_args`, `VM.system_properties`) and feeds
them into the same argument path every section already reads, so classpath,
`whatap.home`, server markers and the class index fill in. That is an attach on
a live process, Tier 2, so it happens only with the flag, and only for the
processes whose options are absent from `/proc` (cap 4). Without the flag the
report states, per such process, that the options are absent and that the VM
was not asked for them.

**Application libraries are enumerated from the application, never from the
agent jar.** The agent jar bundles the weaving-module markers, so a scan whose
input includes it reports the agent's own catalog (`spring-boot-2.1`…`4.0`
matched at once in a single app). Section F therefore
builds its inventory from the target JVM's own `-cp`/`-classpath`, its `-jar`
(`BOOT-INF/lib`, `WEB-INF/lib`), `CLASSPATH`, its own working directory, the
server directories derived from its own `-D` properties (`catalina.base`/`home`,
`jboss.home.dir`, `jboss.server.base.dir`, `jetty.base`/`home`, `jeus.home`,
`domain.home`) and its open jar file descriptors, with the `-javaagent` jar excluded and the exclusion stated in
the report.

## The common case: installed, healthy, but the hitmap stays empty

The most frequent Java support case is not a broken install; it is an install
whose application framework is not instrumented. Reading it needs **four facts
side by side**, and sections F and G are built to sit next to each other for
exactly that:

| leg | fact | where |
|---|---|---|
| 1. what the application carries | jar names **with their versions** from the classpath, the executable jar, the server lib/deploy directories and open file descriptors | `[7] F` |
| 2. what **this** agent build can instrument | the jar's raw `weaving/*` entry list (cap 200) and how many built-in `whatap/agent/asm/*ASM` classes, both read from the installed jar (leg 3) | `[8] G` |
| 3. what the configuration selects | the `weaving` / `weaving_reserved` list, `weaving_*_enabled`, `hook_service_*`, `hook_method_*`, `instrumentation_*`, `_enable_asm_*` lines of the config file, read in section E's verbatim dump; section G adds `-Dweaving*` / `-Dhook_*` / `-Dinstrumentation_*` arguments (the list itself stays in section E's dump; section G does not check it against the jar) | `[6] E`, `[8] G` |
| 4. what the process actually loaded | the agent log's `Weaving` lines: one `Load <module>` per module that engaged, and the `Warning`/`Error` lines where a module's compiled class version is above the target class version (the module then does not apply) | `[8] G` |

Two loading paths are reported separately because they behave differently:
the `weaving=` list pulls modules **out of the agent jar**, while every jar
dropped into `<whatap.home>/weaving/` is loaded **whole-directory**,
independent of that list (`weaving_plugin_enabled`, default true).

The entry-point variant of the same symptom: the agent instruments fine but
the transaction never starts, because the entry is not a servlet (JBoss
Remoting, a socket message gateway). It is read from `[5] D` (server markers
and program identity: a socket gateway has none of the servlet markers), the
`hook_service_*` settings in `[8] G`, and, when requested, the `[12] L` thread
dump that names the real entry-point method.

Whether these facts explain the missing transactions is the reader's judgment;
the report carries the evidence for it and states no conclusion.

## When a new weaving module has to be written

The other frequent outcome is that no module exists yet and the agent
developer has to write one. A `weaving@<lib>` module is compiled **against the
customer's own artifact** (`weaving@axis-1.4/lib/axis-1.4.jar` is literally on
its compile classpath), it **redeclares the target class's fields and the
method it intercepts with the same names and signatures**, and it must not be
compiled for a class-file version above the target's: `WeaveMain` logs
`weaving-class-ver(N) is higher then target-class-ver(M)` and the module does
not apply. A jar file name does not carry any of that.

`--library PATTERN` (repeatable) produces those inputs for the named library;
PATTERN is a literal, case-insensitive substring of the jar's path (no
wildcards), `--library '*'` for every enumerated jar (cap 40):

| input the module author needs | how the pack supplies it |
|---|---|
| the artifact itself, or coordinates to fetch it | `META-INF/maven/<groupId>/<artifactId>/pom.properties` verbatim: the definitive groupId/artifactId/version; when it is absent the report says so, which is the signal that the jar itself has to be sent |
| which class-file version to compile for | the major version read from the first class entry (bytes 6–7), with the Java feature release derived (`52 (Java 8)`) |
| the real class namespace | the class entry count here; with `--appclasses` the jar's classes enter the section N class list, where a shaded or relocated library shows its actual packages, not the ones the artifact name suggests |
| the exact target class members | `--class FQCN` runs `javap -p -s` against the jar that contains it: field names and types, method signatures **with the JVM descriptor of each member**, superclass |
| version identity for the module name and range | manifest `Implementation-Version` / `Bundle-Version` / `Build-Jdk`, plus size and sha256 to reproduce the exact artifact |
| whether the jar is multi-release or modular | `META-INF/versions/<n>` trees, `module-info.class`, `META-INF/services/*` |

**Spring Boot single (fat) jar.** The libraries are entries inside one jar, not
files on the host. Section F reports the executable jar's launcher manifest
(`Start-Class` is the real entry class, `Spring-Boot-Version` decides which
weaving module applies), the layer index and the count of the application's own
classes under `BOOT-INF/classes`. The detail pack extracts the requested
`BOOT-INF/lib/<lib>.jar` entry (bounded at 80 MB) and reports it with an
`origin:` line naming the entry and its container instead of a path, so "send
us the jar" means extracting that entry. `--class` also resolves application
classes out of `BOOT-INF/classes`.

## When the application's own entry point has to be found

When the application is the customer's own code, no weaving module covers it,
and the transaction has to be started by `hook_service_patterns=<class>.<method>`,
the class and method name come from the deployed artifact and the running JVM,
not from source:

| question | flag | section |
|---|---|---|
| which classes are the application's own, as opposed to its libraries | `--appclasses` | N: every class under `WEB-INF/classes`, `BOOT-INF/classes` and directory classpath entries, as a class count and the class list |
| which of them actually run when a request is served | `--threads=N` | L: N thread dumps, verbatim; the application frames that recur in every dump are read off the dumps themselves |
| the same, from a dump the field already holds (WhaTap console thread dump, a jstack file, `kill -3` output) | `--dump-file PATH` | L: the file is identified (path, size, line count, sha256) and included in full, it may exist only on the field host, next to the section N class list, without pausing any JVM |
| which of the indexed classes implement or call a given type (the Interfaces column of the console, from the artifact) | `--class-refs FQCN` (turns `--appclasses` on) | N: a byte scan of the same class files for the type in internal form. A class file carries every type it implements, extends, calls or references as a constant-pool entry, so the list is "names it", not "implements it" |
| what the exact signature of the chosen method is | `--class FQCN` (with `--library`) | M: `javap -p -s`, whose `descriptor:` line is the string `hook_service_patterns` needs to separate overloads |

Section N reads the artifact, never the JVM, so it can run against a
development instance before anything is applied in production.

## One field command

Run **where the target JVM runs**, as the same OS user where possible (`jstack`
and `jcmd` require it):

```sh
# VM / bare metal
./collect-apmjava.sh --file          # -> whatap-apmjava-<host>-<UTC>.txt

# Kubernetes: pipe the script over stdin; nothing to copy into the pod,
# nothing written to a possibly read-only rootfs
kubectl exec -i <pod> -c <container> -- sh -s -- --stdout --quiet \
    < collect-apmjava.sh > report.txt

# Docker
docker exec -i <container> sh -s -- --stdout --quiet \
    < collect-apmjava.sh > report.txt

# a thread dump the field already holds, included next to the application class index
./collect-apmjava.sh --file --appclasses --dump-file "/path/to/thread_dump.txt"
```

Paste or attach the entire output. No arguments prints usage; nothing runs by
accident. Options shared by the Linux apm collectors (`--file`, `--stdout`,
`--quiet`, `--out DIR`): [../README.md](../README.md).

`--class` reads member signatures from the jars `--library` details, so
`--class` without `--library` is named on stderr as not used. `--class-refs`
searches the class roots the `--appclasses` index reads and turns it on; the
environment section says `--appclasses=1 (turned on by --class-refs)`.

When the agent developer needs the detail of a specific library (a new weaving
module, an unexplained version) or of a specific class (a non-servlet entry
point), the same script answers it in one more run:

```sh
./collect-apmjava.sh --file --library acme-gateway --class com.acme.gateway.MessageDispatcher
./collect-apmjava.sh --file --library '*'          # when the library is not yet known
./collect-apmjava.sh --file --threads              # thread dump: which method the entry really is
```

Container notes:

- **POSIX sh is enough.**
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
| 1 | Collection environment | tools available to this run, privilege, host boot time, per-command cap and run deadline, opt-in flags given; the collector shell's own `JAVA_TOOL_OPTIONS` (as the shell had it, before its removal for the JVMs this run starts), `JAVA_HOME`, `WHATAP_JAVA_AGENT_PATH`, pod and node variables |
| 2 | A. Host / platform | OS, kernel, CPU/memory, `product_uuid` line and whether this run could read it (see [../README.md](../README.md)), **cgroup limits** (the JVM sizes heap and thread pools from them), container markers, Kubernetes secrets directory, `/etc/hostname`, clock/NTP state |
| 3 | B. Java runtimes discovered | the binary of every running JVM: the `release` file above it verbatim (for a `jre` parent, the JDK's `release` one level up), and `-version` (a separate short-lived JVM, never the target) only when `release` is absent or incomplete and only for a binary invoked and resolved as `java`. A launcher such as `vshell` or `jsvc`, and a JVM whose exe is marked `(deleted)`, is listed with the VM library it maps and never executed. A JVM whose exe this run cannot read is listed with its `argv[0]`; the java found through `JAVA_HOME` or `PATH` is labelled as not verified to be that JVM's binary |
| 4 | C. WhaTap agent artifacts on disk | every agent jar found via `-javaagent`, `WHATAP_JAVA_AGENT_PATH` and `/whatap-agent`, each resolved as its own JVM resolves it (working directory, mount namespace), with size/mtime/sha256 and the in-jar `whatap/v.properties`; an unreadable jar says why; javahelper files; `ls -ld /var/run/whatap` and `/var/run/whatap/agent` |
| 5 | D. JVM processes and agent attachment | the `/proc` walk itself (entries scanned and skipped, the tests applied, unreadable maps and `environ` counts), including the thread-name test for another user's process as non-root (see Design notes). Only a JVM confirmed by its `libjvm` / `libj9vm` mapping is ever attached to (`jcmd`, `jstack`) or signalled; a `sudo`/`timeout`/`nohup`/`env`/`setsid`/`nice`/`tini` wrapper is excluded. Per JVM: **which test identified it**, mount-namespace sharing, verbatim cmdline, whether `environ` was readable, options recovered via `--jcmd` or not asked for, **count and list of every `-javaagent` from all four sources** with per-path existence, the option variables, server markers, program identity (for a JNI-created VM the `java_command` the VM recorded), uid, threads, RSS, start time, cwd, **where fd 1 / fd 2 point** (the boot banner and any SIGQUIT dump land there), fds on a `(deleted)` agent jar, the **application server's version file** read as a file (Tomcat, JBoss/WildFly, WebLogic, JEUS, GlassFish/Payara), and `ls -l` of `hs_err_pid*.log` (content not read) in the working directory, the `-XX:ErrorFile` directory and `/tmp` |
| 6 | E. Agent home resolution and configuration | **per process** (cap 8): the config path and home it resolves to and where each came from, `whatap.conf` verbatim (first 400 lines) plus byte facts (size, CR count), whatap-related environment, `whatap.env`, every `-Dwhatap.*` argument, the home listing, `security.conf`/`paramkey.txt` presence and size, `container.conf`; then every home candidate with whether it was readable, and for an unresolved home its listing and `whatap.conf` under the assumed default name. Past the cap: `whatap.server.host`/`port` with source and the non-comment config lines |
| 7 | F. Application libraries visible to the target JVMs | classpath entries, executable-jar contents, `CLASSPATH`, server `lib` / `WEB-INF/lib` / `deploy` / `deployments` directories and open jar fds, **agent jar excluded, exclusion stated**. Every jar of a listed directory is recorded though only the first 120 are printed, so `--library` reaches one past the printed part. Unreadable fd links are stated, not reported as zero jars |
| 8 | G. Agent instrumentation surface and weaving activation | the jar's raw `weaving/*` entry list (cap 200) and count of built-in `*ASM` classes, the `<home>/weaving/` plugin directory and `<home>/plugin/*.x`, `-Dweaving*` / `-Dhook_*` / `-Dinstrumentation_*` arguments, and the `Weaving` lines the process wrote to the agent log (bounded window). The `weaving` list itself is in section E's config dump |
| 9 | H. Application logging stack | logging `-D` properties, logging libraries filtered out of section F, logging config files in each working directory, the console destination and the server log directories with sizes |
| 10 | I. WhaTap agent logs | per attached JVM, the log directory (`log_root`) and file name (`log_name`) with their source, or the stated assumed defaults; directory inventory, log head (the `WhaTap Java v<version>` banner) and tail, the latest rotated log; bounded reads |
| 11 | J. Network endpoints | one `ss` list: sessions to the server port(s) (`whatap.server.port` of the attached JVMs plus 6600), then other sessions of attached JVMs, each group capped at 60; `owner not visible to uid N` where the uid cannot see the owner; DNS resolvers, proxy variables |
| 12 | L. Tier 2 artifacts (opt-in) | `--threads[=N]`: N `jstack -l` dumps per attached JVM (cap 3 JVMs), falling back to `jcmd Thread.print -l`, then SIGQUIT. `--dump-file PATH` (repeatable) identifies (path, size, lines, sha256) and includes a dump taken elsewhere, contacting no JVM. `--jcmd`: `VM.command_line`, `VM.system_properties`, `VM.flags`, `VM.version` for attached JVMs and JVMs whose options are absent from `/proc` (cap 3). With no flag the section states that no attach, signal or pause was applied |
| 13 | M. Library detail pack (opt-in) | `--library PAT`: per matching jar (a byte-identical copy is named, not detailed twice), Maven coordinates, manifest versions, **class-file major version**, class count, multi-release/module/service entries; `--class FQCN` adds `javap -p -s` signatures with JVM descriptors. Libraries inside an executable jar are extracted (80 MB bound) and reported with `origin:` |
| 14 | N. Application class index (opt-in) | `--appclasses`: the application's own classes from every class root section F enumerated (`WEB-INF/classes`, `BOOT-INF/classes`, directory classpath entries, Tomcat `appBase`/`docBase`, Jetty, WebLogic staging and `config.xml` source paths, `jeus.home`/`domain.home`/GlassFish searches), as a class count and the class list (first 2000). The report states each search bound and marks a cut result partial; a root with no class file reports its sibling `lib` jar count. Libraries are section F |

## Collection status

The report ends with the goals it came for ([docs/output-format.md](../../../docs/output-format.md)). Two are always declared: **agent artifacts on disk** and
**agent configuration**. Each requested opt-in adds one: `--threads`, `--jcmd`,
`--dump-file`.

- *agent artifacts* is obtained only when an agent jar opened as an archive
  (an agent home counts only when no jar is named anywhere) and every JVM that
  names an agent had it read: one JVM's corrupt or unreadable jar blocks the
  goal. A JVM whose environment or VM options this run could not read blocks
  it too, because a `-javaagent` could arrive there; a JVM found by its VM
  library or thread names passed its options in memory and blocks it until
  `--jcmd` reads them back. With no whatap marker anywhere the goal is `na`
  only when every JVM's arguments and environment were read; a non-root run
  cannot read another user's `environ`, so it is blocked, with `run again with
  sudo`.
- *agent configuration* follows the same blocking rules and is obtained only
  when every attached JVM's config file was read; with no attached JVM it is
  `na` when every input was read.
- *thread dumps* and *jcmd VM data* are blocked by any dump or query that
  failed, was refused or timed out; a failed `jstack` is reported with its
  output and is not counted as a dump.

## What the report can contain

Framework policy: what the report quotes is not masked, so a mistyped license
or server address must be readable to be verified or refuted. So the report
can carry secrets from each of these places, and is handled as the
customer's configuration is:

| where | section | what it can carry |
|---|---|---|
| the agent config file (`whatap.conf` or the per-instance file `-Dwhatap.config` names) | E, G | `license`, `accesskey`, server addresses, any key the customer set |
| `container.conf` | E | the container id written by the node agent |
| the whatap-related environment of each JVM (`WHATAP_*`, `whatap.*`, `license=`, `accesskey=`, `whatap.env`) | E | license and access keys passed as environment |
| `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, `_JAVA_OPTIONS`, `JAVA_OPTS`, `CATALINA_OPTS`, `JAVA_OPTIONS`, `CLASSPATH` of each JVM | D, F | whatever the launcher passes there, `-D` credentials included |
| the full command line of each JVM (one argument per line, a newline or CR inside an argument as a space), and pid 1's (first 160 bytes) | A, D | `-D` passwords, keystore passwords, JDBC URLs with credentials |
| `/sys/class/dmi/id/product_uuid`, when this run can read it | A | the machine's DMI identifier |
| `jcmd VM.command_line` / `VM.system_properties` (`--jcmd`) | D, L | every system property of the VM, credentials the launcher passed included |
| thread dumps (`--threads`, `--dump-file`) | L | thread names and lock owners the application chose, which can embed user ids, SQL or URLs |
| agent log head and tail, rotated log tail | I | URLs, SQL text and error messages the agent logged |
| server log directory listings, deploy directories, WebLogic `<source-path>` entries | F, H | file and application names |
| fatal error log listings, fd lines of a deleted agent jar, `/var/run/whatap` listing | C, D | file names, owners, sizes and times (the hs_err content, which holds memory and environment excerpts, is not read) |
| jar manifests, Maven coordinates, `javap` member signatures (`--library`, `--class`) | M | build metadata, internal class and method names |
| the application class index (`--appclasses`) | N | the application's own class names |
| proxy variables of the collector shell | J | `http_proxy` may carry `user:password@` |
| `JAVA_TOOL_OPTIONS` and the other listed variables of the collector shell | 1 | whatever the shell inherited, `-D` credentials included |

`security.conf` and `paramkey.txt` hold the SQL-parameter **encryption key**;
the report states their presence and size only, never their content. The
collector itself puts no credential on any command line it runs.

## Load profile

Tier 0 is read-only and **never attaches to, signals, or pauses the target
JVM**. It reads directory listings, bounded `head`/`tail` windows of logs
(sizes come from the inode, never from counting lines), jar central
directories via `unzip`, and searches server directories for
`WEB-INF/classes` (bounded, and the report states the bound). Every external
command is capped (per-command 15 s, whole run 300 s; see
[docs/output-format.md](../../../docs/output-format.md), "The run deadline").
Process identification forks a fixed handful of commands for the whole `/proc`,
not one per process. `-version` is executed only against discovered binaries
named `java`, never against a running process. Every JVM the run starts
(`-version`, `javap`, `jcmd`, `jstack`) runs without `JAVA_TOOL_OPTIONS`,
`JDK_JAVA_OPTIONS` and `_JAVA_OPTIONS`: in an operator-injected pod the
`kubectl exec` shell inherits `JAVA_TOOL_OPTIONS=-javaagent:...`, and a JVM
started with it loads the WhaTap agent. `[1]` names the variables removed and
prints the value the shell had.

The library detail pack (`--library` / `--class`) is off by default because it
is targeted, not because it is risky: it reads jar central directories and
single entries, extracts a packed library to the run's private directory only
when one is requested, and never touches the running JVM. Capped at 40 jars.

The application class index (`--appclasses`) is off by default for the same
reason: one `find` per class root or one `unzip -Z1` per archive root, capped
at 12 roots, with no contact with the running JVM.

Tier 2 is off by default. Each flag prints its impact on the terminal before
running, also in `--file` mode: `--threads` pauses the target JVM at a
safepoint for each dump (cap 60s per dump), `--jcmd` uses the JVM attach
mechanism: once during discovery to recover the options of a JVM that has
none in `/proc` (cap 4 processes), and once in section L for the verbatim
`VM.*` output (cap 3). `jmap` is not used at all, never `jmap -histo:live`
(it forces a full GC). Temporary files live in the run's private directory,
removed on exit and on INT, TERM and HUP.

## Design notes

Kept short because the script's comments point here.

- **`_jvm_opt_val` known gap**: a bare, non-option application argument (no
  `-jar`, e.g. a main class followed by its own `-cp`) is not detected. The
  argument sources are concatenated with no marker for where the cmdline
  segment starts, so a bare token cannot be told apart from `argv[0]` or
  another source's value without risking cutting a legitimate option short.
- **`_find_jvms`**: the four tests are described under "A JVM is identified by
  what it maps". Their cost scales with the host, not per process: one `ls`
  for the exe links, one `grep -z` over every cmdline, one `awk` for comm and
  the verdicts, one `grep` over the maps of the processes the first three did
  not settle. The mapping is matched, not a name list of launchers (CONTRACT
  rule 2).
- **JVM thread-name detection** (when `/proc/<pid>/maps` is closed to us,
  e.g. another user's process as non-root): a JVM's own threads have fixed
  names in the world-readable `/proc/<pid>/task/*/comm` (cut at 15
  characters). Verified on HotSpot (OpenJDK 17): `VM Thread`,
  `Signal Dispatch`, `Reference Handl`, `VM Periodic Tas`, `C1`/`C2
  CompilerThre`, `GC Thread#<n>`. OpenJ9 names (`JIT Compilation`,
  `Signal Reporter`, `Finalizer maste`) are taken from its thread list and
  **not verified** on a running OpenJ9. A process is a candidate only when TWO
  distinct names match; a scan cut by its safety or time cap is reported as
  partial and blocks the goals.

## Cases

The kinds of support case behind parts of the collector (the script's comments
name the mechanism, not the case; the case that led to each feature is in the
entry of [CHANGELOG.md](CHANGELOG.md) that added it):

- A library scan that includes the agent jar reports the agent's own weaving
  catalog: the agent jar is excluded (F).
- A socket gateway whose entry is not a servlet: server markers and program
  identity (D), `hook_service_*` (G) and thread dumps (L).
- A console/JUL logging loop that fills events while the on-disk log stays
  small: logging stack (H).
- A native launcher (`vshell`) that no name test finds: the `libjvm.so`
  mapping test (D).
- An application shipped as hundreds of jars, a thread dump held by the field,
  Quartz job classes, the same jars in several units: F, L, N, M.
- A relative `-Dwhatap.home`: every path is resolved as the JVM that names it
  resolves it (the Config row).
- A `parent unwritable: /var/run/whatap/agent` log line (C) and JVM crashes
  with `hs_err_pid*.log` (D).
- A Zulu 7 `jre` parent directory (B) and an operator-injected pod ([1], Load
  profile).

## Validate

```sh
tools/validate.sh collectors/apm/java/collect-apmjava.sh
```
