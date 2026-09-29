# collectors/collection-server: changelog

The version history of each collector in this directory, one section per
collector, newest first. Every change to a script bumps its `VERSION` and adds
one entry at the top of its section (docs/authoring-guide.md, step 2);
`tools/validate.sh` checks that the newest entry is the script's `VERSION`.

## collect-collserver.sh

- **0.15.8**: Run helpers (skeleton): the `--out` mkdir always gets the
  command cap (plus 1 s), so a second boundary crossed right after the
  deadline check no longer skips it and exits 1 with a false "not writable"
  message.
- **0.15.7**: Run helpers (skeleton): `_out_dir_check` makes the `--out`
  directory even when the run deadline is already spent (the mkdir gets the
  command cap alone), instead of exiting 1 with a false "not writable" message
  and no report. Main: with stderr closed, fd 3 opens on /dev/null instead of
  `exec 3>&2` ending dash before the report.
- **0.15.6**: Emit helpers (skeleton): `progress`, `warn` and `notice` return
  0 when their write fails, so a run whose stderr is closed or full no longer
  exits 1 after a complete report.
- **0.15.5**: Internal: `_need_int` lives in a group block for collmysql and
  collserver only (collzfs never called it).
- **0.15.4**: Run helpers (skeleton): `_why_124` and `_out_dir_check` move
  into the skeleton run helpers (the `--out` mkdir now runs under the command
  cap), and `_run_init` sets the probe error file and reads the uid once; the
  local `probe_merged` goes, so a failed `-version` prints `(exit N)` with its
  output, or `n/a (empty output, exit N)`. The path helpers and process scan
  are plain collserver code, no longer group blocks.
- **0.15.3**: Split collect_logs and _rep_a_jvm_runtime into smaller helpers
  (_logsel_candidates/_logsel_drop/_logsel_summary, _jvm_bin_ls); a removed
  option that is ignored (`--time-ref`) prints its `!!` note when it is read
  instead of after the option loop.
- **0.15.2**: Collection status (skeleton `_emit_time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table (sums largest first, time outside bounded calls) gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`); CONTRACT rule 1. `_run_init` sets its EXIT/INT/TERM/HUP traps before it creates the private directory: a signal in between left `ggt.*` behind. Group blocks: `file helpers` is split into `file helpers` (`dump_file`) and `path helpers` (`fstype_of`, `source_of`, `_dir_ok`, `_path_state`, `resolve_yardbase`), code unchanged, so collzfs carries only `dump_file`.
- **0.15.1**: C adds `df -i` of the yardbase next to its `df -h`: inode
  exhaustion on an ext4/xfs yardbase was in no default report once collzfs
  0.12.0 dropped its per-path `df -i`.
- **0.15.0**: `--jvm` picks the tool per JVM, first that exists: the
  JVM's own `<home>/bin/jstack` / `jmap`; its own `bin/java -m
  jdk.jcmd/sun.tools.jstack.JStack -l` / `sun.tools.jmap.JMap -histo` when
  `<home>/release` lists `jdk.jcmd` (both only in the run's mount
  namespace, the rule A keeps for `-version`); `PATH`'s jstack / jmap; for
  jstack, SIGQUIT. On a JRE (Ubuntu `openjdk-17-jre-headless`: `bin/` is
  java, jpackage, keytool, rmiregistry) the SIGQUIT went to fd 1, which
  WhaTap's `control.sh` sends to `/dev/null`; the `.sigquit.txt` now gives
  `readlink /proc/<pid>/fd/1` raw. Every `jvm/` file starts with `command:
  <what ran>`. Fixed: a `jmap -histo` stopped at its cap left an empty file
  with no mark (`| head` hid exit 124); a dump cut by `RUN_DEADLINE` was
  labelled as the 60 s cap. Both now say which (`stopped at the Ns cap`,
  `stopped at the run deadline, Ns`, `not run: ...`); a tool that exits
  non-zero ends its file with `(exit N)`. A refused SIGQUIT (another uid)
  is written `kill -3: exit N: <stderr> (not sent)`, with no fd 1 line. A
  adds `ls -A <home>/bin` per server JVM, read through `/proc/<pid>/root`
  like the release file, at most 60 entries then `(N more)`; not run for
  a home taken from argv0 or an executable not named java.
- **0.14.0**: Options 14 -> 11 (10 without `--help`). `--threads[=N]` and
  `--histo` are merged into `--jvm` (bundle only): one `jstack -l` and one
  `jmap -histo` of each server JVM; the N dumps of `--threads=N` were taken
  back to back, with no interval, so N added nothing a second run does not.
  `--heap` is removed: the collector takes no heap dump. `--time-ref` (a
  network query from the server) is removed with no default-run
  replacement: B keeps the NTP daemon's own offset. `--threads`, `--histo`
  and `--heap` exit 2 naming `--jvm` or the hand command; `--time-ref` is
  named on stderr and ignored. `--du` stays as it was (an analyst asked for
  the per-pcode sizes in a field case, and no load-free source gives them).
  The run deadline is raised by 420 s for `--jvm` (was 120 s for
  `--threads` plus 300 s for `--histo`). Bundle file names lose the dump
  number: `jvm/<mod>-<pid>.jstack.txt`, `.sigquit.txt` (were `.jstack.1.txt`,
  `.sigquit.1.txt`).
- **0.13.1**: `_run_init` (skeleton) also takes the script as read from stdin when `$0` is the shell's own binary (`/bin/bash -s`, `$0 -ef /proc/$$/exe`): bash 3.2 under musl otherwise faulted in a loop at full CPU after `4<&0`.
- **0.13.0**: A reads the cgroup of the WhaTap server JVMs, not only the
  root the run sees: per distinct `/proc/<pid>/cgroup` of the server JVMs, its
  content, the pids in it, and that cgroup's `memory.max` / `cpu.max` (v2) or
  `memory.limit_in_bytes` / `cpu.cfs_quota_us` / `cpu.cfs_period_us` (v1).
  The root reads stay, labelled `(/sys/fs/cgroup root)`, next to
  `/proc/self/cgroup`. A prints, per distinct `readlink /proc/<pid>/exe` of
  the server JVMs and its mount namespace, the JDK `release` file next to it
  read through `/proc/<pid>/root` (the JVM's view, not the run's: a sidecar
  with `--pid container:` read its own JDK 21 for a JDK 17 JVM, and the host
  run found nothing). Without one, that executable's `-version`, run only in
  the run's own mount namespace, for an executable that is still there and
  named java. A deleted (replaced in place) executable's release is labelled
  `release now at <path>; the running executable was replaced`. A mount
  namespace other than the run's is printed; the PATH `java -version` is labelled as PATH's, with where PATH's
  java resolves. Every JVM the run starts runs without JAVA_TOOL_OPTIONS,
  JDK_JAVA_OPTIONS and _JAVA_OPTIONS, and `[1]` names the ones that were
  set (as apmjava 0.13.2). C reports both yard lock names, `YARDB_LOCK` and
  `.lock`, present with mtime or absent. D dumps a `VERSION*` / `version*`
  file at the top of WHATAP_HOME, or says there is none. Lab
  jjsong-ggt-collsrv (WhaTap 3.1.8, 2026-09-27): the lock is
  `yardbase/.lock` and `YARDB_LOCK: absent` was the only lock line; the
  eight server JVMs run in `system.slice/cron.service` while A read the
  root; PATH's java was the only JVM version in the report; the package
  ships no version file (the module versions are the jar names in D and E).

- **0.12.0**: C reports the account H2 database: `h2.file.path` from
  `conf/account.conf` (`./db` when unset), the db path's mount point and
  whether it is yardbase's, a depth-1 listing of the db, and the SQL dumps
  under `db/backup` (count, 0-byte count, newest 10 by mtime). The
  `db dir: present` line is replaced by it. Field case 2026-09-16 (MEA): a
  full `/whatap` corrupted `account.mv.db`, yardbase (428G) and the db shared
  the filesystem, and the dumps of the day the disk filled were 0 bytes;
  none of the three was in the report.
- **0.11.7**: collect_logs' cap comment no longer tells the field incident
  (a per-file cap alone once gave a 393 MB bundle, 99.95% logs) behind the
  two log caps. Comments only; report content unchanged.
- **0.11.6**: Split run_report (439 lines) into one _rep_\<x> per section;
  the WHATAP_HOME na/missed ladder of D, F and G is _home_missed. Report
  content unchanged.
- **0.11.5**: Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  The systemd helpers (_sd, _sd_prefetch, sd_show, sd_state, unit_loaded) and
  resolve_yardbase are collection-server group blocks shared with collzfs;
  sd_show, sd_state and unit_loaded take the full unit name. Report unchanged
  (compared with 0.11.4 on this host).
- **0.11.4**: [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.11.3**: stderr stays quiet on an unreadable file: 2>/dev/null now covers the <
  redirect it followed, which failed before it took effect.
  _is_whatap_server steps past a token that holds the prefix
  again: one pass per token, not one per copy; report unchanged.
- **0.11.2**: _is_whatap_server moved into the collection-server process scan
  block, written with case patterns so the block parses under dash;
  report unchanged.
- **0.11.1**: Helpers moved into the collection-server group blocks; report
  unchanged. The blocks are copies of
  templates/groups/collection-server.sh.
- **0.11.0**: Fewer options. The log caps come from the environment: LOG_FILE_MB
  (default 5) and LOG_TOTAL_MB (default 100), whole numbers 1..999999
  (another value is ignored with a warning). --log-days rides on
  --with-rotated as --with-rotated=DAYS (default 14). Removed options
  exit 2 naming the replacement: --max-log-mb, --max-total-mb,
  --log-days. A bundle-only option (--threads, --histo, --heap, --du,
  --with-rotated) given without --bundle is named on the terminal
  instead of ignored silently, and no longer raises the run deadline.
  A value option with an empty value, or with the next option taken
  for it (`--out --file`), exits 2. Report unchanged; the bundle's
  SELECTION.txt and log warning name the new spellings.
- **0.10.0**: Section A reads hostname, kernel and arch from /proc/sys/kernel
  (hostname/uname only where a file is unreadable) and no longer
  prints the date and the timezone: section B has both, and its
  timezone falls back to date +%Z as A's did. The --time-ref curl is
  bounded and its Date header loses the trailing CR; a failure names
  curl's exit status. A call cut by the
  run deadline (java -version, journalctl, curl) says "run deadline
  reached", not "timed out".
- **0.9.2**: Readability refactor; report unchanged.
- **0.9.1**: No *.hprof found is "none", not "n/a (empty output)", and only when
  every directory searched could be listed (a symlink this uid cannot
  follow is not absent; a missing home is "path not found", a dangling
  symlink says so); otherwise n/a with the uid, also next to dumps
  found elsewhere. A process counts as a whatap module only when it is
  java and names a server/opslake jar or the yard boot class.
- **0.9.0**: An absence is `na` only when every input behind it was read (conf/,
  logs/, hidepid, cmdlines, the process scan, a JVM whose home was not
  found, unit files, install paths). WHATAP_HOME is also found from a
  JVM's cwd, $WHATAP_HOME and common install paths. Every external
  command is bounded (a hung systemctl is asked once); discovery is one
  grep over /proc and one `systemctl show`. The bundle is built in the
  private directory; bad numeric options exit 2, a failed write exits 1;
  output is handed back under sudo. Needs bash. Measured 2026-09-25 on a
  739-process host: 8.1 s -> 2.4 s; with 2,000 more processes, 20.5 s -> 4.2 s.
- **0.4.1**: An unreadable `conf/` is no longer reported as "n/a (path not found
  or WHATAP_HOME not resolved)". Found on three live production backends
  (Smartfren, 2026-09-23): the collector ran as uid 3103 while WhaTap is
  installed under uid 1001 (`whatap`); on `web02-bsd` uid 3103 could still
  reach `/data/whatap`, on both `web01` hosts it could not, so the two `web01`
  bundles carried no `conf/` and the reason printed two lines after the
  resolved path read as a contradiction. The answer was never root but the
  owning account, so the run should be started as that account.
- **0.4.0**: Log selection for the bundle: a total cap (then the
  `--max-total-mb` option, now `LOG_TOTAL_MB`) beside the per-file one. The
  `web02-bsd` bundle of 0.3.0 was 63,327,061 bytes (393.3 MB unpacked, 180
  entries), of which logs were 412,175,707 (99.95%); `access.log` was tail-cut
  to 50 MiB as designed, but there was no cap on the total. Replaying that log
  tree (127 files, 412,175,707 bytes) as `WHATAP_HOME/logs`: defaults gave a
  532,099-byte archive (17 files copied, 110 left out, 12,963,143 bytes of
  logs); `--max-total-mb 5` 260,084 bytes (15 copied, 112 left out, 3,310,276 bytes of
  logs); `--with-rotated` 19,871,166 bytes (70 copied, 57 left out,
  104,846,391 bytes of logs in the bundle; copied logs stopped at 104,838,469
  bytes under the 100 MB cap); `--with-rotated --max-total-mb 50` 8,274,635
  bytes (58 copied, 69 left out, 52,434,658 bytes of logs). Only the log
  figures transfer; the non-log part of the replay is this workstation's. In every run
  the three numbers in `SELECTION.txt` added back up to 412,175,707.
- **0.3.0**: Run on three live production backends (Smartfren, 2026-09-23):
  module labels, ports, systemd state, yardbase ZFS facts and the journal came
  back correct.

## collect-collzfs.sh

- **0.12.8**: Comments that point at the documentation name
  `collect-collzfs.md` (the collector's own doc next to the script) instead of
  README.md; report unchanged.
- **0.12.7**: Run helpers (skeleton): the `--out` mkdir always gets the
  command cap (plus 1 s), so a second boundary crossed right after the
  deadline check no longer skips it and exits 1 with a false "not writable"
  message.
- **0.12.6**: Run helpers (skeleton): `_out_dir_check` makes the `--out`
  directory even when the run deadline is already spent (the mkdir gets the
  command cap alone), instead of exiting 1 with a false "not writable" message
  and no report. Main: with stderr closed, fd 3 opens on /dev/null instead of
  `exec 3>&2` ending dash before the report.
- **0.12.5**: Emit helpers (skeleton): `progress`, `warn` and `notice` return
  0 when their write fails, so a run whose stderr is closed or full no longer
  exits 1 after a complete report.
- **0.12.4**: Internal: the unused `_need_int` helper is gone.
- **0.12.3**: Run helpers (skeleton): `_why_124` and `_out_dir_check` move
  into the skeleton run helpers (the `--out` mkdir now runs under the command
  cap), and `_run_init` sets the probe error file and reads the uid once; no
  report change.
- **0.12.2**: Split window_run's planning into _win_plan; define the zfs-*
  unit lists once (ZFS_UNITS/ZFS_JOURNAL_UNITS); drop the stat/nproc/free
  rows, never run, from the [1] tools list; `--home` prints its `!!` ignored
  note when it is read instead of after the option loop.
- **0.12.1**: Collection status (skeleton `_emit_time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table (sums largest first, time outside bounded calls) gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`); CONTRACT rule 1. `_run_init` sets its EXIT/INT/TERM/HUP traps before it creates the private directory: a signal in between left `ggt.*` behind. Group blocks: collzfs leaves `process scan` (the block and the `CMDLINE_SCAN_WHY` reference are gone; nothing here called it), and `file helpers` holds only `dump_file` (the yard path helpers are the new block `path helpers`, collserver only).
- **0.12.0**: ZFS only: the collector no longer looks for WhaTap. E now lists
  `mounted canmount secondarycache relatime dedup checksum copies reservation
  refreservation snapdir` for every dataset (M printed them for the WhaTap
  paths' datasets only; the values come from the one `zfs get all`). Section M
  goes (WHATAP_HOME and yardbase resolution from whatap JVMs, their cwd, systemd
  WorkingDirectory or the script's parent; each path's fstype, dataset and pool;
  those datasets' `zfs get` rows again; `df -h` / `df -i`
  of each path; `YARDB_LOCK` and the yardbase listing), and with it the `paths`
  goal and the bundle's `whatap/` directory. `collect-collserver.sh` section C
  has the yardbase's fstype, dataset, `df`, `zfs get` of that dataset and
  `YARDB_LOCK`; runbooks run both. The file count, which came from `df -i` of
  the WhaTap paths, is now `df -i -t zfs` in D, for every mounted dataset. The
  bundle's whole-host `df-h.txt` / `df-i.txt` moved to `host/`. `--home DIR` is
  named in one `!!` line and ignored (no ZFS fact depended on it). The other
  letters are unchanged (no M). The process-scan and file-helper group blocks
  stay (their members line is shared with collserver); their WhaTap helpers are
  unused here.
- **0.11.0**: Fewer options. `--window=DUR@START` goes: `--window=DUR` sets
  the length only, and a window at a later time is a run started then (at,
  cron). A bare `--filesizes` no longer walks the whole yardbase: the walk
  needs `--filesizes=PATH`. Both exit 2 with one line naming the
  replacement, because collecting DUR from now, or no walk, is not what was
  asked for. `--window-start`'s message now names the same replacement.
  The default run's report is unchanged; section O's title reads "--window
  sets its length" (was "its length and start").
- **0.10.1**: `_run_init` (skeleton) also takes the script as read from stdin when `$0` is the shell's own binary (`/bin/bash -s`, `$0 -ef /proc/$$/exe`): bash 3.2 under musl otherwise faulted in a loop at full CPU after `4<&0`.
- **0.10.0**: A prints `/etc/os-release` raw, and the kernel from
  `/proc/sys/kernel/{ostype,osrelease}` (`uname -sr` only where they are
  unreadable); the line reads as before. Lab jjsong-ggt-zfs, 2026-09-27.

- **0.9.0**: Views that re-summarised raw output in the same report go, and
  calls made twice are made once. No fact is lost; each is read where it
  now stands:
  - B: the list of about 70 named tunables is gone; each is a row of the
    full `/sys/module/{zfs,spl}/parameters` dump that followed it (a
    tunable this build lacks is absent from the dump).
  - C: the per-class vdev view and the shape count go, and so does H's
    SLOG line; the class, shape and SIZE..HEALTH of every vdev are C's raw
    `zpool list -v` lines.
  - E, F, M: the block-size matrix, the space matrix and M's per-dataset
    property loop become `zfs get` rows (NAME PROPERTY VALUE SOURCE)
    filtered from discovery's one `zfs get all`, which is now `-Hp` (exact
    values; "local" / "inherited from X" in place of l/i). F keeps the
    properties `zfs list -o space` (D) lacks; M keeps those not in D, E, F.
  - I: the one-line objset view becomes each `objset-*` kstat verbatim.
  - O: the p50/p90/p99 table goes; the txgs rows it summarised are printed.
  - L: the zevent ring is read once (zevents_split, in every run): L's own
    tally and `tail -100` calls go, and L prints the overview and the last
    100 events of that read, with zpool's exit status and stderr. A report
    run reads `zpool events`; a bundle run reads `zpool events -v` once and
    its zfs/zpool-events-* files are that read. EVENT_DAYS unchanged.
  - N: with `--bundle --zdb`, zdb runs once, into zdb/ (whole output,
    stderr kept), and N names each file with its size and exit status;
    before, it ran in N and again in the bundle. The deadline adds zdb once
    (280 s + per pool 3,720 s, or 7,500 s in a bundle): 12,775 s became
    9,055 s for one pool with `--bundle --zdb`.
  - Bundle: `zfs-get-all-parsable.tsv` and `zfs-list-snapshots.tsv` are
    discovery's files (the snapshot list now has `referenced`, `written`
    and `clones`), `zpool-iostat-{v,lv,qv,r,w}.txt` and `host/iostat-x.txt`
    are the report's answers; `zfs-get-all.tsv` (human-readable) is gone.
  The snapshot summaries in F stay: the snapshot list is not in the report.

- **0.8.8**: The header's question-to-section map, and the write-path window's
  ring/merge/gap rationale and interval-job rationale (repeated near
  \_rep_l, zevents_split and the window's interval-job start), now point
  to README.md's "Design notes" and "The time window (section O)"
  instead of restating them. Comments only; report content unchanged.
- **0.8.7**: Split _rep_o into txgs, counters and io parts; section B's named
  parameters are one loop per subsection. Report content unchanged.
- **0.8.6**: Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  The systemd helpers and resolve_yardbase are collection-server group blocks
  shared with collserver, and probe is the skeleton's (zprobe skips a zpool or
  zfs that hung earlier). Behaviour change: after one systemctl call hits its
  cap the rest are skipped, with a `!!` line, as collserver does (each used to
  wait CMD_TIMEOUT; their values were empty either way). Report unchanged
  otherwise (compared with 0.8.5 on this host).
- **0.8.5**: [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.8.4**: stderr stays quiet on an unreadable file: 2>/dev/null now covers the <
  redirect it followed, which failed before it took effect.
  _is_whatap_server steps past a token that holds the prefix
  again: one pass per token, not one per copy; report unchanged.
- **0.8.3**: _is_whatap_server moved into the collection-server process scan
  block, written with case patterns so the block parses under dash;
  report unchanged.
- **0.8.2**: Helpers moved into the collection-server group blocks; report
  unchanged. The blocks are copies of
  templates/groups/collection-server.sh.
- **0.8.1**: --out, --home, --window and --filesizes= with an empty value, or
  with the next option taken for it (`--out --file`), exit 2 naming
  the option. iostat -x in the window only adds detail: absent (no
  sysstat), failed or stopped, it is a "not delivered:" fact line in
  section O and no longer blocks the window goal, whose inputs are the
  txgs, the kstat deltas and zpool iostat.
- **0.8.0**: A time window runs in every run (15s; --window=DUR[@START] sets its
  length and start) and replaces --sample. Section O keeps every txg of
  the window (the txgs ring re-read before it
  wraps, merged by txg number, gaps counted); the start, end and delta
  of dmu_tx, arcstats and each objset-* kstat; zpool iostat -vlq and
  iostat -x started together at the same interval, with timestamps;
  zpool iostat -r / -w for the window; arcstat when present. J's
  "interval sample (--sample)" subsection is gone, and [1]'s tiers
  line reads "... filesizes=off window=off" (no sample=). Removed
  options exit 2 naming the replacement: --sample, --window-start,
  --no-filesizes, and --filesizes-secs, --event-days, --hours, which are
  now FILESIZES_SECS, EVENT_DAYS and JOURNAL_HOURS in the environment
  (defaults 300, 30, 24). H's per-pool kstat paths no
  longer carry a double slash (yard//zil).
  Validated as root on a ZFS VM (Ubuntu 26.04, zfs 2.4.1, TZ Asia/Jakarta,
  pool `yard` with a special vdev, 200k small files): the default run; windows
  idle and under an append load; a forced ring wrap (`zfs_txg_history` set to 10
  and put back, with a `zpool sync` burst: gaps counted, the read interval went
  from 23 s down to 2 s); `@START` waits; INT and TERM; `--bundle`. The
  allocation-class view showed `class=special`. A default `--file` run took
  33.2-34.9 s against 15.7-15.8 s at 0.7.0 (the 15 s window plus about 2.5 s
  for the interval jobs' last block). Before the txgs ring was full, H's
  first row was txg 5, not txg 1.
- **0.7.0**: zpool list -v runs once: the raw probe's output feeds the derived
  views of sections C and H and the bundle's zpool-list-v.txt (it was
  run a second time, capped at 20s, for the views, and a third time
  for the bundle). Report unchanged when the call answers; the views
  now follow the probe's CMD_TIMEOUT cap, not a fixed 20s. The zpool
  feature checks (section A) and the zfs-unit journal (L) say "run
  deadline reached" when the deadline cut them, not "timed out".
- **0.6.4**: A zpool status -vt that succeeds with no output (no pool imported) is
  one "empty output" line again, not a fallback to -v and -t (0.6.3).
- **0.6.3**: Readability refactor; report unchanged.
- **0.6.2**: The file-size walk is opt-in (Tier 2) again: on a yard of ~10^8 files
  it loads the special vdev and the ARC and cannot finish in its bound.
  df -i of every WhaTap path is in the report and df-i.txt in the
  bundle, so the file count is there without a walk.
- **0.6.0**: Discovery of the running processes is one bounded `grep` over
  `/proc` instead of one fork per process (the collserver 0.9.0 change). Measured
  2026-09-25 on a 739-process host: 5.2 s -> 0.5 s; with 2,000 more processes,
  17.2 s -> 0.8 s. A `zpool` / `zfs` that fails or hangs is reported with its
  reason, not as "no pool", and the snapshot count is `n/a`.
- **0.2.0**: `zpool events` is read once and split three ways: a tally (class x
  date x vdev) and a per-class overview (count, first, last) over the whole
  ring buffer, and per-event detail only for the `--event-days` window
  (default 30). Cut to a recent window, the buffer loses what it answers, when a class
  started and stopped: a host with no `deadman` event this month reads the same
  whether it never had one or they ended two months ago. Case (XLSMART web01-bsd,
  bundles of 2026-09-23): the `zpool events` dump was 192 MB because
  `zfs_zevent_len_max` was INT_MAX; the buffer held 136,337 `deadman` events,
  the last on 2026-07-29, and that date decided the judgment. Measured: 192 MB
  became 224 KB with the last date kept. L carries the same tally.
- **0.1.0**: Validated non-root on two live ZFS hosts: a KVM host (Ubuntu
  24.04, zfs 2.2.2, pool 2.72 T, FRAG 56 %, 19 datasets, 2 zvols, 2 clones, a
  removed vdev leaving `indirect-0/1`; Tier 0 about 13 s, `--bundle` about 34 s /
  89 KB), and a real WhaTap collection server (Ubuntu 24.10, zfs 2.2.6, pool
  `yardbase` 99.5 G / FRAG 30 %, 10 running `whatap.server` JVMs; Tier 0 about
  10 s), which resolved `WHATAP_HOME` from a running JVM's
  `-Dwhatap.server.home` and reported the mixed layout: only `yardbase` on ZFS
  (`recordsize=64K` local, `compressratio 4.43x`), while `logs` / `conf` / `db` /
  `logsink` sat on the ext4 root. The `arcstat` sampling branch was exercised
  there (that binary is absent on the KVM host). The status rows of later
  versions (0.2.0, 0.4.1) carried this validation forward; no later run on
  those hosts is recorded.

## collect-collmysql.sh

- **0.12.7**: Run helpers (skeleton): the `--out` mkdir always gets the
  command cap (plus 1 s), so a second boundary crossed right after the
  deadline check no longer skips it and exits 1 with a false "not writable"
  message.
- **0.12.6**: Run helpers (skeleton): `_out_dir_check` makes the `--out`
  directory even when the run deadline is already spent (the mkdir gets the
  command cap alone), instead of exiting 1 with a false "not writable" message
  and no report. Main: with stderr closed, fd 3 opens on /dev/null instead of
  `exec 3>&2` ending dash before the report.
- **0.12.5**: Emit helpers (skeleton): `progress`, `warn` and `notice` return
  0 when their write fails, so a run whose stderr is closed or full no longer
  exits 1 after a complete report.
- **0.12.4**: Internal: `_need_int` lives in a group block for collmysql and
  collserver only (collzfs never called it).
- **0.12.3**: Run helpers (skeleton): `_why_124` and `_out_dir_check` move
  into the skeleton run helpers (the `--out` mkdir now runs under the command
  cap), and `_run_init` sets the probe error file and reads the uid once; no
  report change.
- **0.12.2**: Split _binlog_proc's identity checks into _bl_check, and
  _window's sampler start/wait/trap-restore into _win_run_samplers; drop the
  lsblk row, never run, from the [1] tools list.
- **0.12.1**: Collection status (skeleton `_emit_time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table (sums largest first, time outside bounded calls) gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`); CONTRACT rule 1. `_run_init` sets its EXIT/INT/TERM/HUP traps before it creates the private directory: a signal in between left `ggt.*` behind.
- **0.12.0**: The password prompt is removed. A bare `-p` in
  `--mysql-args` (`--password`, `-Bp`, `-p X`) exits 2 before any child
  starts, with one line naming `--defaults-extra-file`; the password comes
  from an option file (`--defaults-extra-file` / `--defaults-file`, the
  client's own files) or `MYSQL_PWD`. `PROMPT_TIMEOUT` is no longer read. A
  password written into `--mysql-args` still exits 2, and its message now
  names `--defaults-extra-file`. `--help` and the README show the three-line
  option file with `chmod 600`. A run without `-p` reports as before.
- **0.11.1**: `_run_init` (skeleton) also takes the script as read from stdin when `$0` is the shell's own binary (`/bin/bash -s`, `$0 -ef /proc/$$/exe`): bash 3.2 under musl otherwise faulted in a loop at full CPU after `4<&0`.
- **0.11.0**: F's tables whose name contains lock/meter/event/audit are
  matched on `LOWER(table_name)`: on MySQL 8.0 the match was case-sensitive,
  and `MeteringDaily`, `MeteringHourly`, `AuditLog` and `ReserveEvent` were
  missed (5.7 listed all seven; lab mysql-ha, 2026-09-27: 8.0.46 now lists
  the same seven). A prints this host's `/etc/os-release` raw and the kernel
  from `/proc/sys/kernel/{ostype,osrelease}` (`uname -sr` only as a
  fallback).

- **0.10.5**: Split run_report (454 lines) into one _rep_\<x> per section;
  section I is split into select, decode and per-file parts, and
  _binlog_proc's network-namespace check is _bl_netns_owns. Report content
  unchanged.
- **0.10.4**: Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  Report change: a probe whose command exits non-zero with output prints that
  output under "label (exit N):" instead of "label: n/a (...)", as the other
  collectors do. The caps BINLOG_TIMEOUT, PROMPT_TIMEOUT, RUN_DEADLINE and
  CMD_TIMEOUT are checked by _cap_or: an ignored value is one `!!` line per
  variable ("NAME=V ignored (not a whole number 1..999999 without leading
  zeros), using D") instead of one combined line; the rule is unchanged. The
  last field of a line is cut without eval. Compared with 0.10.3 on this host:
  reports equal but live values.
  --help names BINLOG_TIMEOUT instead of printing its value, which is now
  checked after the options.
- **0.10.3**: [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
  The auto.cnf read of the pid-file check gets the same 2>/dev/null as
  0.10.2's loops: a mysqld that exits after the -r test printed the
  error to the operator's screen.
- **0.10.2**: stderr stays quiet on an unreadable file: 2>/dev/null now covers the <
  redirect it followed, which failed before it took effect; report
  unchanged.
- **0.10.1**: Helpers moved into the collection-server group blocks; report
  unchanged. The blocks are copies of
  templates/groups/collection-server.sh.
- **0.10.0**: Every run samples: section J runs iostat -x and vmstat together for
  a 15s window (6 reports each, at a fifth of the window), and
  --window=DUR (N, Ns, Nm or Nh, 10s .. 24h) sets its length. It
  replaces --sample, which ran the two one after the other for about
  50s. J is a goal of every run, blocked only when the deadline cut
  or skipped the window or every sampler present failed; an absent
  sampler (no sysstat) or one failure of two is a fact line, and
  with neither installed the goal is not declared. [1]'s "sampling tier:" line is now "window:".
  --out DIR is where --file writes (checked before collecting: an
  unwritable one exits 1). Removed options exit 2 naming the
  replacement: --no-sudo (it did nothing since 0.8.0), --sample. A
  value option with an empty value, or with the next option taken for
  it, exits 2; --mysql-args takes a value that starts with '-' (it is
  the client's arguments), but not an empty one or one of this
  collector's own options (either form, e.g. --defaults-file=/x).
  A signal during the window stops the samplers (none is left
  running) and the report is written with what they wrote ("ended
  early: SIG...").
- **0.9.0**: Binary log sizes come from SHOW BINARY LOGS only: section C lists
  the directory once for the mtimes (no du; the listing sums the files
  only when SHOW BINARY LOGS gave no list), and section I takes the
  newest files and their sizes from those rows, not from ls per file.
  A SQL call cut by the run deadline says "run deadline reached", not
  "timed out". A cut or refused SHOW BINARY LOGS is no list. The
  login check is the client's status, whose Connection line ([1]
  "connected to:") classifies the target: a TCP address neither this
  host nor a local mysqld's network namespace owns is a remote server
  (a gap, no local process looked at). SHOW BINARY LOG STATUS falls
  back to SHOW MASTER STATUS only on its syntax error (before 8.2,
  MariaDB) instead of asking both. Otherwise the
  binary logs are read only through the server's own process: the
  local mysqld/mariadbd whose pid file (@@pid_file through
  /proc/\<pid>/root, or here when that root cannot be entered) holds its
  pid and was written with the server's start (mtime against now -
  Uptime), whose auto.cnf holds @@server_uuid where readable, and whose
  binlog directory holds the server's newest log with nothing newer (a
  newer one: SHOW BINARY LOGS asked once more, and it must list it). Its /proc/\<pid>/root\<binlog dir> is read and a
  "binlog files: via pid ..." line says so. None (a remote server, a
  copied datadir), two, or an unreadable pid file is
  a gap with the reason. Paths come from a readable @@log_bin_index
  (logs in more than one directory; such a file is named by its
  path); a selected file that is not there, or a name listed twice
  with no index, is named and blocks the goal.
- **0.8.3**: @@log_bin, @@log_bin_basename and @@datadir are asked for once (the
  value shown is the value used), and one ps serves both the login
  reason and section A. Report unchanged.
- **0.8.2**: Readability refactor; report unchanged.
- **0.8.1**: --connect-expired-password passes through. An empty line or end of
  input at the -p prompt says so instead of "none given", next to the
  shared privilege hint on a failed login.
  A word after a bare -p (a database name to the client) is warned about.
- **0.8.0**: Never elevates or re-runs itself (--no-sudo warns it is not needed).
  No credential on a command line: a password in --mysql-args ends the
  run (exit 2); it comes from a bare -p, MYSQL_PWD or an option file and
  reaches the client in a mode-600 file. Every wait is bounded; refused
  SHOW BINARY LOGS, a failed or capped decode, a NULL log_bin_basename and
  no local mysqld without arguments are gaps with reasons. Needs bash. The
  password notations were checked against the real 5.6, 5.7.32, 8.0.46 and
  8.4.10 clients (2026-09-25).
- **0.4.0**: Run end to end on MySQL 5.6.51, 5.7.32, 8.4.10 and MariaDB 10.11.19
  (2026-09-17), each seeded with a scheduler-shaped write load; all four reach
  the footer and attribute binary log rows to the right tables (8.4 excepted:
  the `mysql:8` image ships no `mysqlbinlog`). Three defects fixed: MariaDB
  opens transactions with `START TRANSACTION`, not `BEGIN`, so the transaction
  count read 0; `SELECT @@read_only, @@super_read_only` lost both values on 5.6
  and MariaDB because the second variable does not exist there; MariaDB echoes
  the statement between dashed rules before its error, so every reason read
  `error: --------------`.
- **0.3.0**: The binlog decode streams each file once through `awk` and keeps
  only counters: an 82 MB binary log decoded to 95 MB of text (1.15x), which
  0.2.0 held in a shell variable and walked six times (27 s for an 85 MB pair;
  gigabytes of RSS at the default 1 GiB `max_binlog_size`); the same run takes
  4 s. The decode is capped per file (`BINLOG_TIMEOUT`, 300 s) and says so when
  it truncates; a log with no row events states that instead of an empty list.
  Section F also reports the indexes of the 15 largest tables.
- **0.2.0**: Run end to end on MySQL 5.7.32 and 8.4.10 containers (2026-09-17)
  seeded with a scheduler-shaped write load (a lock row updated in a loop,
  inserts and deletes on a second table); section I attributed row events to the
  right tables on 5.7. Five defects fixed: the unbounded `SHOW BINARY LOGS`
  listing (647 files became 647 lines and two thirds of the report), the
  missing 8.4 binlog position, the group replication query that 5.7 rejects
  whole, a missing `ps`/`ss` reported as "empty output", and a delimiter count
  labelled "statement-format queries".
