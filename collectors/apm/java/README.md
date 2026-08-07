# collectors/apm/java — WhaTap Java APM agent collector

> **Status: SEEDED (v0).** `collect-apmjava.sh` is a working Tier-0 collector,
> plus an opt-in library detail pack (`--library` / `--class`) and two opt-in
> Tier-2 flags (`--threads` / `--jcmd`), seeded by the Global team (CONTRACT
> rule 4 — interim ownership). Ongoing ownership belongs to the Java agent
> developers once handed over.

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
| Config | env `WHATAP_CONFIG_FILE` > `-Dwhatap.config.file` > `-Dwhatap.home` (**default `"."`, the process working directory**) + `-Dwhatap.config` (default `whatap.conf`) | the home is a **per-process** fact, not a host fact; an operator-injected pod usually has no conf file at all and runs on environment values only, and the report shows exactly that |
| Overlay | the agent overlays environment variables and system properties onto the config file (`ConfigValueUtil.replaceSysProp`) | so the conf dump alone is not the effective setting — the whatap-related env of each process (names may contain dots: `license`, `whatap.server.host`) and every `-Dwhatap.*` argument are reported next to it |
| Version | the agent build fixes no version into the jar filename | version is read from **`whatap/v.properties` inside the jar** (`VERSION`/`BUILD`, the file `whatap.Version` itself reads), cross-checked by jar size/mtime/sha256 and by the `WhaTap Java v<version>` banner at the head of `logs/whatap.log` |

**Application libraries are enumerated from the application, never from the
agent jar.** The agent jar bundles the weaving-module markers, so a scan whose
input includes it reports the agent's own catalog (case 2026-06-16 saw
`spring-boot-2.1`…`4.0` matched at once in a single app). Section F therefore
builds its inventory from the target JVM's own `-cp`/`-classpath`, its `-jar`
(`BOOT-INF/lib`, `WEB-INF/lib`), `CLASSPATH`, the server directories derived
from its own `-D` properties (`catalina.base`/`home`, `jboss.home.dir`,
`jboss.server.base.dir`, `jeus.home`, `domain.home`) and its open jar file
descriptors — with the `-javaagent` jar excluded and the exclusion stated in
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
| the exact target class members | `--class FQCN` runs `javap -p` against the jar that contains it: field names and types, method signatures, superclass |
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
| 1 | Collection environment | which tools were available to this collection; whether Tier 2 was requested |
| 2 | A. Host / platform | OS, kernel, CPU/memory, **cgroup limits** (the JVM sizes heap and thread pools from them), container markers, and clock/NTP state (transaction timestamps) |
| 3 | B. Java runtimes discovered | every java binary from running processes, PATH, `JAVA_HOME` and `/usr/lib/jvm`: the `release` file (free) plus `-version` (a separate short-lived JVM, never the target process) |
| 4 | C. WhaTap agent artifacts on disk | every agent jar found via `-javaagent`, `WHATAP_JAVA_AGENT_PATH` and `/whatap-agent`, with size/mtime/sha256 and the in-jar `whatap/v.properties` (VERSION/BUILD); javahelper and other whatap files next to it |
| 5 | D. JVM processes and agent attachment | per JVM (WhaTap-attached first): verbatim cmdline, **count and list of every `-javaagent` reaching the JVM from all four argument sources** with per-path existence, `JAVA_TOOL_OPTIONS`/`_JAVA_OPTIONS`/`JDK_JAVA_OPTIONS`/`JAVA_OPTS`/`CATALINA_OPTS`, server markers (the same properties `ProcessTypeDetector` reads), program identity (main class / executable jar), uid, thread count, RSS, start time, cwd, and **where fd 1 / fd 2 point** — the boot banner and any SIGQUIT dump land there, not in the agent log |
| 6 | E. Agent home resolution and configuration | the resolution rule, then **per process**: the config path it resolves to and whether the file exists, `whatap.conf` verbatim plus byte facts (size, CR 0x0D count — Windows-edited conf files are a recurring case), the whatap-related environment of that process (dotted names included), `whatap.env`, every `-Dwhatap.*` argument, the home listing, `security.conf`/`paramkey.txt` presence, `container.conf` |
| 7 | F. Application libraries visible to the target JVMs | classpath entries, executable-jar contents (`BOOT-INF/lib`, `WEB-INF/lib`), `CLASSPATH`, server `lib`/`webapps/*/WEB-INF/lib`/`deploy`/`deployments` directories (exploded `*.ear/lib` and `*.war/WEB-INF/lib` included), and open jar file descriptors — **agent jar excluded, exclusion stated** |
| 8 | G. Agent instrumentation surface and weaving activation | **what this agent build can instrument**: the `weaving/<name>.jar` modules bundled in the installed jar and its built-in `whatap/agent/asm/*ASM` classes; the on-disk `<home>/weaving/` plugin directory (loaded whole-directory, independent of the weaving list); the weaving / `hook_service_*` / `hook_method_*` / `instrumentation_*` / `_enable_asm_*` settings in force, with a **per-entry check of the weaving list against that jar**; and the `Weaving` lines the running process wrote to the agent log (`Load <module>`, and the compiled-class-version `Warning`/`Error` that stops a module from applying) — bounded log window, never a whole-file grep |
| 9 | H. Application logging stack | logging `-D` properties, the logging libraries **filtered out of section F's inventory** (so a library that is present but not yet opened is still reported), logging config files in each working directory, the console destination and the server log directories with sizes — the on-disk volume and the collected volume are both facts a reader compares |
| 10 | I. WhaTap agent logs | `<home>/logs` inventory, `whatap.log` head (the `WhaTap Java v<version>` banner) and tail, the most recent rotated `whatap-YYYYMMDD.log`, and a `[WA*]` code frequency count — all bounded reads |
| 11 | J. Network endpoints | the `whatap.server.host`/`port` values reaching each JVM through env or `-D`, TCP sessions toward :6600, DNS resolvers, proxy variables |
| 12 | K. Kubernetes / operator injection context | `/whatap-agent` listing, `WHATAP_JAVA_AGENT_PATH`, `JAVA_TOOL_OPTIONS`, `POD_NAME`/`NODE_NAME`/`NODE_IP`/`OKIND`/`WHATAP_MICRO_ENABLED`, k8s markers |
| 13 | L. Tier 2 artifacts (opt-in) | `--threads[=N]`: N `jstack -l` dumps per attached JVM (cap 3 JVMs, 5000 lines per dump), falling back to `jcmd Thread.print -l` and then to SIGQUIT (whose output goes to the fd 1 target shown in section D). `--jcmd`: `VM.command_line`, `VM.system_properties`, `VM.flags`, `VM.version`. When neither flag is given the section states that no attach, signal or pause was applied |
| 14 | M. Library detail pack (opt-in) | `--library PAT` / `--library-all`: for every enumerated jar that matches — Maven coordinates from `META-INF/maven/*/pom.properties`, manifest version attributes, **class-file major version** (the number a weaving module has to be compiled against), package map (shading shows here), class count, multi-release/module/service entries; `--class FQCN` adds `javap -p` member signatures. Libraries packed inside an executable jar are extracted (bounded at 80 MB) and reported with an `origin:` entry line instead of a path; `--class` also resolves application classes out of `BOOT-INF/classes` |

## Security note

Framework policy: WhaTap configuration files (`whatap.conf`, `container.conf`)
are dumped **verbatim, never masked** — a mistyped license or server address
must be readable to be verified or refuted. The whatap-related environment
variables of running processes (including `license=`) are reported verbatim
for the same reason. Handle the report accordingly.

One data-scope exception (not masking): `security.conf` / `paramkey.txt` hold
the SQL-parameter **encryption key**; the report states presence and size only,
never content.

Note that a full JVM command line is dumped verbatim, so any credential passed
as a `-D` property by the customer's own launcher appears in the report.

## Load profile

Tier 0 is read-only and **never attaches to, signals, or pauses the target
JVM**: directory listings only (no recursive walk), bounded `head`/`tail`
reads, jar central-directory reads via `unzip`, per-probe timeout 15s. A run
completes in roughly 10–15s on a host with ~1000 processes. `java -version` is
executed only against discovered java **binaries**, never against a running
process.

The library detail pack (`--library` / `--library-all` / `--class`) is off by
default because it is targeted, not because it is risky: it reads jar central
directories and single entries, extracts a packed library to a temp file only
when one is requested, and never touches the running JVM. Roughly six `unzip`
reads per detailed jar, capped at 40 jars.

Tier 2 is off by default. Each flag prints its impact on stderr before running:
`--threads` pauses the target JVM at a safepoint for each dump, `--jcmd` uses
the JVM attach mechanism. `jmap` is not used at all — never `jmap -histo:live`
(it forces a full GC).

No `--bundle` tier yet; copy the bundle plumbing from `collect-collserver.sh`
if the domain team needs raw log artifacts.

## Validate

```sh
tools/validate.sh collectors/apm/java/collect-apmjava.sh
```
