# Coverage KB — JVMs started by a native JNI launcher (APM / Java)

**What this is:** a coverage knowledge-base entry. It records environment-specific
**facts** a real deployment exhibits, so a collector author knows what a
"discover, never assume" (CONTRACT rule 2) collector will surface here — and so
that no one is tempted to hardcode a product name. It is a reference, not a
branch in any script. Like every artifact in this repo, the entries below are
facts only — no diagnosis.

Environment: a **native launcher** that creates the JVM in its own process
through the JNI Invocation API (`JNI_CreateJavaVM`), instead of exec'ing the
`java` binary. Observed product: **Axway API Gateway** (`vshell`). The shape is
not specific to it — any program that links `libjvm` and calls
`JNI_CreateJavaVM` presents the same way.

---

## What such a process looks like in `/proc`

| file | what it holds |
|---|---|
| `/proc/<pid>/comm` | the launcher's own name (`vshell`), never `java` |
| `/proc/<pid>/exe` | the launcher binary, never a `java` / `jsvc` binary |
| `/proc/<pid>/cmdline` | the launcher's own arguments. **No JVM option at all** — the option array was built in memory and passed to `JNI_CreateJavaVM` |
| `/proc/<pid>/environ` | whatever the launcher was started with; the JVM options are not necessarily here either |
| `/proc/<pid>/maps` | `…/libjvm.so` (HotSpot and derivatives) or `…/libj9vm<ver>.so` (OpenJ9 / IBM J9) — the one trace every JVM leaves |

Consequence for a collector: identify a JVM by the **mapped VM shared library**,
not by a process name or a binary path, and not by a list of known launchers.
`collect-apmjava.sh` runs that test last, only for the processes its three
cheaper tests (`comm`, resolved `exe`, a JVM-only whole argument) did not
settle.

## Where the JVM options are, when they are in no `/proc` file

The running VM still holds them:

- `jcmd <pid> VM.command_line` → `jvm_args:` (the launcher's option array),
  `java_command:` (often `<unknown>` for a JNI-created VM), `java_class_path
  (initial):`, `Launcher Type: generic`
- `jcmd <pid> VM.system_properties` → `java.class.path`, `whatap.home`,
  `catalina.base` and every other property, in `Properties.store` format (`=`,
  `:`, `#`, `!` arrive backslash-escaped, in values as well as keys)

Reading these attaches to a live process, so `collect-apmjava.sh` does it only
under `--jcmd`, and only for the processes whose options are absent from
`/proc`.

## Field observation this entry comes from

Case **2026-09-11**, BAF (Bussan Auto Finance, Indonesia), host
`hqapimgmtdev1.bussan.co.id`, `collect-apmjava.sh` **0.3.0** run as `uid 0`:

- `[5] D. JVM processes: none found in /proc (this pid namespace)`
- `[11] J.` of the same run: `vshell` pid 1549923 and pid 1550737 in `ESTAB` to
  the collection server `172.16.0.6:6600`
- an hour earlier the same processes had accepted `jstack` 15 times

Sections C and E–L of that report all read `n/a`, behind the one empty result
in D. Closed in `collect-apmjava.sh` **0.4.0**.

## Reproducing the shape without the product

A ~60-line C program is enough: link against `libjvm`, build the option array
in `main`, call `JNI_CreateJavaVM`, then `FindClass` /
`GetStaticMethodID("main", "([Ljava/lang/String;)V")` / `CallStaticVoidMethod`.
Compile it inside a JDK image and name the binary anything but `java`:

```sh
gcc -o vshell vshell.c -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux" \
    -L"$JAVA_HOME/lib/server" -ljvm -Wl,-rpath,"$JAVA_HOME/lib/server"
./vshell /path/to/classes shop/Boot      # note: JNI class name, slashes
```

The running process then has `comm: vshell`, `exe: …/vshell`, a `cmdline` with
no JVM option on it, and `…/libjvm.so` in its `maps` — the same shape as the
field observation above. Renaming the same binary and re-running is the check
that the collector matched the mapping and not the name.
