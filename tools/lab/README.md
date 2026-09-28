# tools/lab — before/after collector runs in permanent lab targets

One command replaces the hand-built fixtures (fake `ss`, throwaway JVMs and
containers) and the hand comparison of `git show HEAD:<collector>` against
the working tree:

```sh
tools/lab/run.sh java-zoo                       # HEAD vs working tree, apmjava edge cases
tools/lab/run.sh --base origin/main apm-php-rocky apm-php-alpine
tools/lab/run.sh --only 'collect-coll' local    # this host, collection-server collectors only
tools/lab/run.sh --list                         # targets, what they cover
tools/lab/run.sh --status                       # state, uptime, memory, health of every target
```

For each target, `run.sh` brings it up if it is not running (and reuses it
when it is), runs every collector that applies — once from `--base` (default
`HEAD`, taken with `git archive`) and once from the working tree — with the
target's argument sets, and writes masked stdout / stderr / rc, plus the
**unmasked** stdout, to `--out DIR` (default `$TMPDIR/ggtlab-out/<UTC>/`) as
`<target>/{base,new}/<collector>.<argset>.{out,err,rc,raw}` plus
`<target>/diff.txt`. Masking and the diff are `mask()` and `compare()` of
[`../capture-compare.sh`](../capture-compare.sh), read from that file at run
time, so the two tools mask the same way (the diff itself only ever looks at
the masked files, not `.raw`). Then the target's checks (facts that must
appear) are run on both trees, and `tools/validate.sh --report` is run on
every `.raw` file whose argument set actually produces a report — every set
except `help` and `badarg` — on both trees; masking replaces versions and
timestamps with tokens that `validate.sh` does not expect, which is why it
reads `.raw`, not `.out`. The summary per target:

```
== java-zoo (jjsong-ggt-java-zoo running since …, mem 310MiB / 23.47GiB)
   files 21, differ 0, checks 14/14 (base 14/14)
   report PASS 14/14 (base 14/14)
   rc new: collect-apmjava.app-bash=0 … collect-apmjava.badarg=2 …
```

Exit 0 when nothing differs, every check passes, and `validate.sh --report`
passes on the working tree's own reports; 1 otherwise, 2 on usage, 3 when a
target cannot be brought up or is not healthy. A `validate.sh --report`
failure on the base is printed (`base n/m`) but does not affect the exit
status — it is pre-existing, not caused by the change under test. A
difference is not a verdict: live state (pids, sessions, the deadline mode
`dl` under load) moves between two runs. Run the base twice (`--base HEAD`
with a clean tree) to see the noise floor, as with capture-compare.

## Lab rules

- Targets are **permanent**. `run.sh` never tears one down; `--up` is the
  first start (or restart), `--down` only a manual escape hatch.
  Containers run with `--restart unless-stopped`.
- Docker targets run on the lab VM **jjsong-ggt-docker** (ssh alias
  `ggt-docker`, see `~/.claude/lab-environment.md`): `run.sh` uses
  `DOCKER_HOST` when set, else `ssh://ggt-docker` when it answers, else the
  local daemon with a warning. The analysis machine is short of memory:
  build or debug locally with `LAB_DOCKER=local`, then `--down` what you
  started there.
- Containers, images and VMs are named `jjsong-ggt-*` (the `jjsong-`
  prefix is the lab rule; other people's VMs are not touched).
- Images carry no agent binary or license from this repo: each Dockerfile
  fetches the agent from its public source and uses the dummy license
  `ggt-lab-dummy-license` with server 127.0.0.1, so no agent reaches a real
  collection server.

## Targets

| target | image / host | covers |
|---|---|---|
| `local` | this host | every shell collector in the capture-compare modes (help, bad argument, `--stdout` as a file, deadline, `dash`/`dash -s`/`bash -s` for apm, `sh` for collection-server) |
| `apm-java` | `jjsong-ggt-apm-java:1` | Temurin 21, Java agent 2.2.77 via `-javaagent`, JVM uid 1500; image without `unzip` (v.properties and weaving list are `n/a`) |
| `apm-java-jto` | same image | the operator shape: agent only in `JAVA_TOOL_OPTIONS`, nothing on the command line |
| `apm-java-bash52` | `jjsong-ggt-apm-java-bash52:1` | the only target on Ubuntu 24.04 noble's shells (bash 5.2.21, dash 0.5.12-6ubuntu5) — everything else here is jammy/bookworm; a JVM whose JDK copy dir is deleted after it starts (section B "binary deleted since the JVM started") and a `-javaagent` JVM whose `whatap.conf` weaving list names a real module (`spring-boot-3.0`) and a bogus one (`nonexistent-9.9`); section G lists the jar's raw `weaving/*` entries |
| `apm-nodejs` | `jjsong-ggt-apm-nodejs:1` | Node 22, npm `whatap@2.0.6` required by the app, user `node` |
| `apm-nodejs-op` | `jjsong-ggt-apm-nodejs-op:1` | agent from `apm-init-nodejs` in `/whatap-agent`, `NODE_OPTIONS=-r whatap` |
| `apm-python` | `jjsong-ggt-apm-python:1` | Python 3.12 venv, PyPI `whatap-python==2.2.0`, `whatap-start-agent gunicorn` |
| `apm-python-op` | `jjsong-ggt-apm-python-op:1` | agent from `apm-init-python` (2.1.2), `PYTHONPATH` bootstrap |
| `apm-php-rocky` | `jjsong-ggt-apm-php-rocky:1` | Rocky 9 with systemd as PID 1, php-fpm 8.2 + nginx, whatap-php 2.14-2 rpm |
| `apm-php-alpine` | `jjsong-ggt-apm-php-alpine:1` | Alpine (musl), php-fpm 8.3 + nginx, WhaTap PHP 2.14.2 Alpine tarball, PID 1 `sleep` |
| `apm-payara` | `jjsong-ggt-apm-payara:1` | `payara/server-full:6.2025.10` (GlassFish lineage), Zulu 11, Java agent 2.2.77 baked into domain1's `domain.xml` `<jvm-options>` (no asadmin restart cycle needed, see the image's Dockerfile), JVM uid 1000 `payara` |
| `java-zoo` | `jjsong-ggt-java-zoo:1` | the apmjava edge cases below |
| `db-agent` | `jjsong-ggt-db-agent:1` | collect-db.sh's JDK 8 JDBC runner (jrunscript/Nashorn, no jshell on JDK 8) against the real, permanent `jjsong-ggt-postgres` (TLS on) and `jjsong-ggt-mysql-primary`; mock DBX-agent host, no real agent jar needed for the runner |
| `zfs` | `jjsong-ggt-zfs` (ssh) | collzfs against the real zpool `yard`; root over sudo -n |
| `collsrv` | `jjsong-ggt-collsrv` (ssh) | collserver + collmysql against a real on-prem install; collmysql's `--binlog` argset runs as root (unix-socket auth, binlog files are mode 640 owner mysql) |
| `k8sproxy` | `jjsong-ggt-k8sproxy` (local + ssh) | collect-k8s.sh against the MEA 2026-08-18 webhook-fail-open repro, once from this machine (bastion shape, `KUBECONFIG=~/.kube/config-ggt-k8sproxy`) and once from inside the VM (the serving-chain probe needs a route to the pod/service CIDR) |
| `k8s-lab` | jjsong-k8s cluster (local, default kubeconfig) | collect-k8s.sh, read-only, against the real cluster with real operator-injected APM pods in `coursematerials` |

Every apm container target runs the same argument sets (`apm_argsets` in
`lib.sh`): `help`, `badarg`, `app-sh` / `app-bash` (script on stdin as the
application's uid, the `kubectl exec … sh -s` shape), `root-sh` (root without
CAP_SYS_PTRACE, so other uids' `/proc/<pid>/environ` stays closed),
`app-file` (the script copied in and run as a file), `dl`
(`RUN_DEADLINE=2 CMD_TIMEOUT=1`).

### java-zoo

Twelve JVMs in one container (`images/java-zoo/start.sh`), each started with
`-Xmx32m -XX:+UseSerialGC` (OpenJ9: `-Xgcpolicy:optthruput`); about 300-450 MiB
for the whole container. The collector runs as uid 1500.

| JVM | what it exercises |
|---|---|
| Temurin 21, `-javaagent`, `whatap.conf` of 451 lines | the 400-line cap of the verbatim config dump |
| Temurin 17 whose `release` file is removed | `release file: n/a (path not found …)` |
| Temurin 8 | JDK 8 layout (`jre/lib/amd64/server/libjvm.so`) |
| IBM Semeru 8 (OpenJ9) | a non-HotSpot VM and its `release` |
| Zulu 7, `-Dwhatap.home` only | an older JDK the agent jar (Java 8 bytecode) cannot attach to; `bin/java` is a symlink into `jre/` |
| `/opt/axway/apigateway/platform/bin/vshell` | a launcher not named java (a copy of the java launcher, as Axway ships `vshell`) |
| uid 1600, agent only in `JAVA_TOOL_OPTIONS` | another uid's environ is unreadable: the JVM is counted, its injection is not visible |
| `whatap.server.port=6700`, one session to 6700 and 70 to 7070 | a non-default server port in the session list, and the 60-row cap (`first 60 of 70 sessions`) |
| three marker-only sleepers | more than 8 attached JVMs (`remaining N attached JVMs … (cap: 8)`) |
| uid 1700 listener on 6600/6700/7070 | stands in for the collection server |

The agent jar is the real 2.2.77 from `apm-init-java`, whose
`whatap/v.properties` has CRLF line ends; the check
`^ +VERSION = 2\.[0-9.]+$` fails if a CR reaches the report. Under the dummy
license the agent opens no TCP session of its own, so the port-6700 JVM opens
its session itself (`Zoo sess`).

## Add a target

A target is one file, `targets/<name>.sh`, sourced by `run.sh`:

```bash
# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
DESC="one line for --list"
COLLECTORS="apm/java/collect-apmjava.sh"          # paths under collectors/
docker_target jjsong-ggt-<name> jjsong-ggt-<name>:1 [docker run options...]
#   or: ssh_target whatap@192.168.122.231   (a VM that is already up)
#   or: local_target
apm_argsets app          # or ARGSETS=( "name|user|shell|ENV=v ...|args" ... )
t_health() { t_sh 0 'pgrep -f java >/dev/null && echo "JVM up"'; }   # optional
CHECKS=( "apmjava|app-sh|some ERE that must appear" "apmjava|app-sh|!an ERE that must not" )
```

- `docker_target` builds the image from `images/<name>/` (or `IMAGE_DIR`)
  when the daemon does not have it; `RUN_CMD=(…)` sets arguments after the
  image. `run.sh --build <name>` rebuilds on purpose.
- An argument set is `name|user|shell|ENV|args`. `shell` `sh -s`, `bash -s`,
  `dash -s` feed the script on stdin; `sh`, `bash`, `dash` run it as a file.
  `user` is a uid or name inside a container, `-` for the login user of a
  local or ssh target, `0` for root (sudo -n over ssh). An `ssh_target` only
  runs collectors on stdin (`sh -s`/`bash -s`/`dash -s`; a bare shell name
  errors out) — the collector itself needs bash (e.g. collzfs, collserver,
  collmysql), so give it `bash -s`, not `sh -s`.
- A target that needs different sets per collector defines `argsets()`
  printing them (see `targets/local.sh`, `targets/collsrv.sh`).
- A check is `collector-ERE|argset-ERE|ERE`, searched in the masked stdout
  of both trees; the summary shows new and base counts, so a check that
  only the working tree passes is a new fact, and one only the base passes
  is a regression.
- A target that must run the same collector on two different hosts (e.g.
  `k8sproxy`: this machine as a bastion, and inside the VM for the
  serving-chain probe) is not one of the three kinds: call `local_target` (or
  `ssh_target`) for its `t_up`/`t_down`/`t_status`, then override `t_exec`
  yourself, dispatching on the argset's `user` field. `_ssh` (from
  `ssh_target`) and the `$LAB_WORK` scratch dir (from `local_target`) are
  plain global functions/variables after the helper has run, so the override
  can still use them. See `targets/k8sproxy.sh`.
- ssh targets are permanent VMs the lab does not start or stop: `t_up` only
  checks they answer, and a `--bundle`/`--file` argset's output file is left
  on the VM (send `--out /tmp` so it ages out with the VM's own tmpfiles
  policy, rather than the login home).

## Not covered yet

- `mask()` stays in `capture-compare.sh` and is read from there; moving it
  to a shared file would touch that tool.
- `compare()` never sees `.raw` files (`run_target` links everything else
  into two scratch dirs first): comparing them too would just repeat the
  `.out` diff through a coarser, blanket digit-masking pass of its own.
- `DOCKER_HOST=ssh://…` opens one ssh connection per docker call; a
  `ControlMaster` entry for `ggt-docker` in `~/.ssh/config` makes runs faster.
