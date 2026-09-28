# collect-apmnodejs.sh: changelog

The version history of [`collect-apmnodejs.sh`](collect-apmnodejs.sh), newest
first. Every change to the script bumps its `VERSION` and adds one entry at
the top of this list (docs/authoring-guide.md, step 2); `tools/validate.sh`
checks that the newest entry is the script's `VERSION`.

- **0.9.9**: Emit helpers (skeleton): `progress`, `warn` and `notice` return 0
  when their write fails, so a run whose stderr is closed or full no longer
  exits 1 after a complete report.
- **0.9.8**: The shared main no longer calls _init_probe; _run_init sets
  _errfile, so the collector's one-line copy is gone. Report unchanged.
- **0.9.7**: Run helpers (skeleton): `_why_124` and `_out_dir_check` move
  into the skeleton run helpers (the `--out` mkdir now runs under the command
  cap), and `_run_init` sets the probe error file and reads the uid once;
  `probe_merged` comes from the skeleton; the CLI harness banner loses "DO NOT
  EDIT"; no report change.
- **0.9.6**: The install block's `version` line is read by the same top-level
  awk as section 4 (`_pkg_top_field`, `version: x (path)`; a nested "version"
  is no longer taken), and so are npm's and pm2's name and version. Pid files
  get an entry line (full mtime), state and ppid, and `permission denied` for
  an unreadable one (group `_pid_file_fact`). `build.txt` and `whatap_port_*`
  values are cut on a UTF-8 boundary. hidepid, Go-agent homes and
  `WHATAP_NODEJS_AGENT_PATH` come from group helpers, unchanged in effect.
- **0.9.5**: Collection status (skeleton `_emit_time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table (sums largest first, time outside bounded calls) gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`); CONTRACT rule 1. `_run_init` sets its EXIT/INT/TERM/HUP traps before it creates the private directory: a signal in between left `ggt.*` behind.
- **0.9.4**: `_run_init` (skeleton) also takes the script as read from stdin when `$0` is the shell's own binary (`/bin/bash -s`, `$0 -ef /proc/$$/exe`): bash 3.2 under musl otherwise faulted in a loop at full CPU after `4<&0`.
- **0.9.3**: The host section adds `/sys/class/dmi/id/product_uuid`: its
  `ls -l` line and `dmi product_uuid readable by uid N:` (yes or no, from an
  open and a read of the file); the value follows only when it was read (group
  block `apm: report helpers`, `_product_uuid`). Command lines and environ
  entries go through the new group block `apm: text helpers`: `_proc_words`
  (NUL, newline and CR each a space) and `_proc_lines` (one entry per line, a
  newline or CR inside an entry a space). A newline in an argument or a value
  no longer puts the rest at column 0, where a crafted argument made a fake
  `[5] Collection status` and failed `validate.sh --report`. Cuts end on a
  UTF-8 boundary (`_u8cut`, the awk `u8cut`, one text in the block). Affected
  here: the cmdline of `whatap_nodejs`, node and pm2 processes (300, 200
  bytes), their env lines (300, 200), the `-r/--require` test,
  `NODE_PATH`/`PM2_HOME` reads, and pid 1's command line (`_pid1_cmd`, 160
  bytes, one line). The process table (group block) turns CR into a space too,
  and a command line holding a newline (where `head -n 1` stopped) is read
  again whole, so argv0 and the words after the newline are kept. The same
  holds for comm (`_comm`, read builtin) and the exe and cwd lines
  (`_link_text`). The process table read exe targets from `ls -l`, where a
  target holding a newline printed a second line that could pose as another
  pid's (a crafted exe path made pid 1 read as a runtime); a line naming no
  `/proc/<pid>/exe` or a pid named twice is detected. `_product_uuid` costs
  one fork (ls) when the file reads. `dmi product_uuid readable by uid N:`
  says `yes`, `no (open failed: <reason>)` or
  `no (opened, read failed: <reason>)`, the reason from `cat`'s stderr, which
  runs only then. The process table reads every comm in the same `head` pass
  as before (`head -n 16`, lines joined by a space), with no fork per pid, and
  re-reads with readlink only the exe of the pids a posing `ls -l` line
  involves. A newline or CR inside an environ value is kept apart from the
  variable boundaries and given back by `_env_pick`, so a `WHATAP_HOME`
  holding one is listed quoted among the paths not followed (D_ODD, which now
  also takes CR and lists each path once) instead of being looked up with
  spaces. A node process cwd holding a newline or CR is not followed (listed
  with the odd paths; its `cwd:` and `installed packages:` lines say so), and
  NODE_PATH entries split on CR too. Goals unchanged.
- **0.9.2**: The version reader folds its input to 512-byte lines and keeps
  the first 256 bytes of each string; busybox awk spent 47-50 s per
  package.json holding one long single-line string inside the 256 KiB read,
  now under 2 s. A key written with `\u00XX` escapes (`ver\u0073ion`) is
  compared decoded, as JSON.parse does. Values read are otherwise unchanged
  (checked against node on the verifier's fixtures under bash, dash, bash
  3.2 and busybox).
- **0.9.1**: The version reader reads at most the first 262144 bytes of each
  package.json (busybox awk took minutes on a 1 MB single-line file); a file
  cut there without a version found says `in the first 262144 bytes`. The
  NODE_PATH walk stops at its cap of 50 instead of stepping through the rest
  for every package, and the entries past it are counted once per process
  (3000 entries x 20 processes cost +6.8 s in bash). Report otherwise
  unchanged.
- **0.9.0**: Section 4 prints, for each whatap-marked node process, the
  installed `version` of express, next, @nestjs/core, koa, fastify and whatap:
  the package.json that node's lookup from the process cwd reaches
  (`<dir>/node_modules/<pkg>` for the cwd and its parents, at most 32 dirs,
  then at most 50 NODE_PATH entries, labelled `via NODE_PATH`), as `pkg:
  version (path)` or `n/a (<why>)`. Only the top-level `"version"` string is
  read (one awk tracking brace depth, strings skipped), so a nested
  `scripts.version` / `publishConfig.version` is not taken; a non-string value
  says so. A node_modules dir this uid cannot search is named (`permission
  denied`), a marked process whose cwd is unreadable says `permission denied:
  /proc/<pid>/cwd`, and a process in another mount namespace is read through
  `/proc/<pid>/root`. Checked against node's own `require.resolve` and
  JSON reading on 17 fixture apps (bash, dash, bash 3.2). Until now the report carried only the declared
  dependency ranges of the app package.json. In the operator image the
  `whatap` line reads 2.0.3 from `/whatap-agent/node_modules/whatap` via
  NODE_PATH, the path `require.resolve('whatap')` gives from /app; with
  `require('whatap')` in the app it reads 2.0.6 from
  `/app/node_modules/whatap` (jjsong-ggt-apm-nodejs:1 and -op:1, 2026-09-27).
  Report otherwise unchanged.
- **0.8.6**: `apm: file helpers`/`apm: conf bytes` (templates/groups/apm.sh):
  `wc -l`/`wc -c`/`tr -dc '\r'` reading an unreadable file no longer leak
  "Permission denied" to the operator's stderr (the `<` redirect ran before
  `2>/dev/null`, so its own failure was not yet silenced). Report content
  unchanged.
- **0.8.5**: Split the large functions (_rep_runtimes, _rep_binding,
  discover) into per-section helpers; /proc/\<pid>/environ reads no longer
  print Permission denied on stderr as root without CAP_SYS_PTRACE. Report
  content unchanged.
- **0.8.4**: Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  New apm blocks: report helpers (environment head, cgroup, container
  markers), machine arch, conf bytes; resolve_fs, _sock_list and _scan_gaps
  joined the path, file and environ blocks. The machine arch line is read from
  probe's output (PROBE_OUT) instead of the indented fact line; its text is
  unchanged in every case the old parse handled. A value option without its
  value exits 2 without printing the usage after the message. Report unchanged
  otherwise (compared with 0.8.3 on this host and in jjsong-ggt-apm-nodejs:1).
- **0.8.3**: [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.8.2**: The node processes this run starts (node --version, npm root -g,
  npm/pm2 --version) run without NODE_OPTIONS. Run by kubectl exec in
  an operator-injected pod, the shell inherits NODE_OPTIONS=-r whatap,
  and npm root -g loaded the agent: it initialised, tried to rewrite
  whatap.conf, opened a UDP channel to the running whatap_nodejs and
  wrote its start-up to the pod's hook log, and its console lines
  became the "global node_modules" value (lab container, 2026-09-27).
  Report: [1] says whether NODE_OPTIONS was removed and whether it
  named whatap; section 3 gets the real npm root -g.
- **0.8.1**: main is the apm group block `apm: main`; report unchanged. A --file run
  on a host without hostname(1) names the report after
  /proc/sys/kernel/hostname, else `uname -n`, and so does Target (both
  were: unknown, and validate.sh --report refused Target: host/unknown);
  the file name reuses the name Target resolved.
- **0.8.0**: --out DIR puts the --file report in DIR (an unwritable one ends the
  run before collecting). A probe error line over 100 bytes keeps
  its start and its end; report otherwise unchanged.
- **0.7.1**: Shared helpers moved into the apm group block; report unchanged.
  The apm: blocks are copies of templates/groups/apm.sh.
- **0.7.0**: The npm and pm2 versions are read from the package.json next to the
  entry script each command resolves to (the line names the file);
  `npm/pm2 --version`, which starts node, runs only when that file gives
  none, and its line then names the command. A value read from the
  file does not show whether npm/pm2 can run. The machine arch is taken
  from the one `uname -srm` (no second `uname -m`).
- **0.6.2**: A directory this uid can read but not enter lists its names again
  (the refactor's _names dropped them; ls did not).
- **0.6.1**: Readability refactor; report unchanged.
- **0.6.0**: Less work per node process: _env_pick settles an absent name with one
  match and splits the environ with IFS instead of a read loop, NODE_PATH
  is split in the shell, the cwd each process resolved in discovery is
  reused by the report, and the detail list reads each environ once.
  The report is unchanged; 8.4 s -> 4.9 s on a host with 168 node
  processes, 18.3 s -> 9.5 s with 300 more (2026-09-25).
