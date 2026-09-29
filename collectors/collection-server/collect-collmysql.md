# `collect-collmysql.sh`: the backend's MySQL

> **Status:** validated at `collect-collmysql.sh` 0.11.1 on 2026-09-28, the lab
> `collsrv` VM's own MySQL 8.4.11 (`--stdout`, `--binlog` as root), COMPLETE,
> `validate.sh --report` pass.
> Not yet run on: a replicating pair, section I on 8.4 (the `mysql:8` image ships no
> `mysqlbinlog`), section J against a real `iostat` (absent in the test images), the
> MariaDB-specific replication and `performance_schema` differences. Owner: Global
> team until handover to the collection-server (backend) team (CONTRACT rule 4).

Part of the [collection-server family](README.md).

The WhaTap backend keeps `account` and `notihub` metadata in MySQL. When the
question is about that database rather than about yard, this is the collector.
Its centre of gravity is the write path: binary log growth and disk I/O.

## (a) Facts it collects

One `.txt` report, sections `[1]` and A..K:

- **`[1]` Collection environment**: bash, uid, privilege, boot time, tool
  presence, which mysql client was resolved, what the connection was attempted
  with, where the password came from (never the password), whether it could
  connect and why not, and which opt-in tiers this run enabled.
- **A. Server identity and version**: version, hostname, `server_id`,
  `server_uuid`, uptime, `read_only` / `super_read_only`, port, socket, datadir,
  the local `mysqld` process and the listening sockets, and this host's
  `/etc/os-release` (raw) and kernel (`/proc/sys/kernel/{ostype,osrelease}`).
- **B. HA and replication**: `binlog_format`, GTID mode, `SHOW REPLICA STATUS`
  and the older `SHOW SLAVE STATUS`, `SHOW BINARY LOG STATUS` (MySQL 8.2+; on
  its syntax error, before 8.2 and on MariaDB, `SHOW MASTER STATUS` instead,
  labelled so), connected replicas,
  Galera `wsrep_cluster_size`, Group Replication members, semi-sync status. It
  asks for all of them and reports the reason for each one that does not answer,
  so the topology is read off the server rather than assumed.
- **C. Binary log inventory and retention**: `log_bin`, basename and index,
  `max_binlog_size`, `binlog_expire_logs_seconds` and the older
  `expire_logs_days`, `binlog_row_image`, `sync_binlog`, `SHOW BINARY LOGS`,
  the binlog cache counters, and the on-disk file list with mtimes and sizes so
  growth over time can be read from one snapshot. File sizes and the total come
  from `SHOW BINARY LOGS`; the directory is listed once, for the mtimes. Only
  when `SHOW BINARY LOGS` gives no list (refused, timed out) does that listing
  add a `total:` line summed over the `<basename>.NNNNNN` files. There is no
  `du`: with the logs in the datadir it would walk the whole datadir.
- **D. Storage and I/O**: `df -hT`, mounts, the datadir's filesystem,
  `/proc/diskstats`, and the `Innodb_data_*`, `Innodb_os_log*`,
  `Innodb_buffer_pool_*`, `Innodb_rows_*` and `Com_*` counters.
- **E. InnoDB configuration**: page size, buffer pool size,
  `innodb_flush_log_at_trx_commit`, flush method, doublewrite, I/O capacity, log
  file settings, and `SHOW ENGINE INNODB STATUS`.
- **F. Schema footprint**: per-schema table count and size, the 25 largest
  tables, the tables whose names contain `lock` / `meter` / `event` / `audit`
  in any case (`LOWER(table_name)`, so `MeteringDaily`, `AuditLog` and
  `ReserveEvent` match),
  and the columns of `DeniedIPAddress` and `ApmRegion`.
- **G. Per-table I/O and statement digests, from `performance_schema`**: the
  tables with the most I/O wait, the tables with the most rows written, the
  statement digests with the most latency and the most rows examined, and file
  I/O by event name. This is what attributes load to a caller.
- **H. Current activity**: processlist, thread counters, `max_connections`.
- **I. Binary log content attribution**: opt-in, see below.
- **J. Interval samples**: every run: `iostat -x` and `vmstat` started
  together over a 15 s window (`--window=DUR` sets it), six reports each. The
  first report of each is the average since boot, the other five cover the
  window.
- **K. MySQL error log**: the resolved `log_error` tail, or the journal.

## (b) Delivery mechanism

```sh
./collect-collmysql.sh --file                       # -> whatap-collmysql-<host>-<UTC>.txt
sudo ./collect-collmysql.sh --stdout                # root over the unix socket; root-only files
./collect-collmysql.sh --file --defaults-file ~/.my.cnf
./collect-collmysql.sh --file --defaults-extra-file ~/ggt-mysql.cnf --mysql-args "-h 10.0.0.5"
./collect-collmysql.sh --file --binlog --window=60s # the binlog decode, a 60 s window
./collect-collmysql.sh --file --out /tmp/case       # write the report under /tmp/case
./collect-collmysql.sh                              # no arguments -> prints help
```

**Options**: `--file`, `--stdout`, `--quiet`, `--out DIR`, `--defaults-file PATH`,
`--defaults-extra-file PATH`, `--mysql-args "ARGS"`, `--binlog[=N]`,
`--window=DUR`, `--help`.

| option | what it does |
|---|---|
| `--out DIR` | where `--file` writes (default `.`); made if missing, checked before collecting, an unwritable one exits 1 |
| `--defaults-file PATH`, `--defaults-extra-file PATH` | option files for the mysql client (credentials) |
| `--mysql-args "ARGS"` | the client's own arguments (`-h`, `-P`, `-u`); no password, not even a bare `-p` (below) |
| `--binlog[=N]` | Tier 2: decode the N newest binary logs (default 2) |
| `--window=DUR` | the length of section J's window: `N` (seconds), `Ns`, `Nm` or `Nh`, 10 s .. 24 h (default 15 s) |

A value option with no value, or with the next option taken for it
(`--out --file`, `--window --file`), exits 2 before anything runs.
`--mysql-args` is the exception to the leading-dash rule, because its value
is the client's arguments and starts with `-` (`--mysql-args "-h 10.0.0.5 -u
whatap"`, or `--mysql-args="-h 10.0.0.5"`). It still exits 2 when the value is empty
or is exactly one of this collector's own options (`--mysql-args --file`: the
client arguments were forgotten). Quote the client arguments as one word.

**Environment** (whole numbers 1..999999; another value is ignored with a
warning, and the default is used):

| variable | default | what it bounds |
|---|---|---|
| `CMD_TIMEOUT` | 20 | each external command, seconds |
| `RUN_DEADLINE` | 300 | the whole run, seconds; raised by the window + 30 s and by the `--binlog` decode unless set |
| `BINLOG_TIMEOUT` | 300 | the `--binlog` decode of one file, seconds |

`MYSQL_PWD` is a password source (below), not a cap.

**There is no password prompt.** A bare `-p` in `--mysql-args`
(or `--password`, or a cluster ending in `p` such as `-Bp`) does not ask for
the password on the terminal. It exits 2 before any child starts, with one line
naming `--defaults-extra-file`: a run that went on would log in without the
password the operator meant to give.

With no option file and no `--mysql-args`, the mysql client is invoked with no
connection arguments and uses its own option files. A run without credentials
still produces the host-side facts; every SQL-backed line then reads
`n/a (<reason>)`. The login goal is then blocked, not `n/a`, even when no local
`mysqld` is running: the backend's MySQL is often on another host, and
`--mysql-args "-h ..."` would reach it.

**Privilege.** The collector runs at the privilege it was started with and
never elevates or re-runs itself. `[1]` states that privilege. A packaged
MySQL often admits `root@localhost` over the unix socket with no password, and
the binary log directory is often readable by root only; the operator runs it
with sudo for those (`sudo ./collect-collmysql.sh --stdout`). A goal that root
would have obtained is blocked with the uid and what refused it
(`run as uid 1000; /var/lib/mysql is mysql:mysql 750 and not readable by this
uid (not elevated: run again with sudo)`); that hint appears only in the status
section and on the terminal, never in a fact line. On a failed login the hint only states that the
run was not elevated, as in every collector; it does not claim that sudo would
fix the login (a TCP login, or a password account, is decided by the server). Under sudo the `--file`
report is handed back to the invoking user.

**Passwords never go on a command line.** A command line is readable by every
account in `ps` and `/proc/<pid>/cmdline`. So the collector hands the password
to the `mysql` client only through a mode-600 option file inside the run's
private temp directory (`--defaults-extra-file`, or `--defaults-file` with
`!include` of yours when you gave one), never on a child's argv or in its
environment. There is no prompt. Two sources: an option file (preferred), or
`MYSQL_PWD`.

Write the option file with an editor, not with `echo` or `printf` (the
password would stay in the shell history), make it readable by you only, and
pass it:

```ini
[client]
user=whatap
password="SECRET"
```

```sh
chmod 600 ~/ggt-mysql.cnf
./collect-collmysql.sh --file --defaults-extra-file ~/ggt-mysql.cnf --mysql-args "-h 10.0.0.5"
./collect-collmysql.sh --file --defaults-file ~/.my.cnf                   # instead of the client's own files
MYSQL_PWD='...' ./collect-collmysql.sh --file --mysql-args "-u whatap"   # read, then unset
```

`--defaults-extra-file` is read after the client's own option files
(`/etc/my.cnf`, `~/.my.cnf`); `--defaults-file` replaces them.

`MYSQL_PWD` is unset before any child starts, but it stays in the collector's
own `/proc/<pid>/environ` for the run, readable by the same uid and by root,
and MySQL deprecates the variable; prefer an option file. A `MYSQL_PWD` holding
a newline is refused (exit 2): an option-file value ends at a newline.

A password written into `--mysql-args` ends the run with exit 2 before any
child starts: it is already on the collector's own command line (the
operator's choice), and the collector does not hand it on. Detection follows
the real clients (5.6, 5.7.32, 8.0.46 and 8.4.10 checked): `-pX`, a
short-option cluster holding `p` (`-BpX`), `--password[1..3]=X`, the abbreviated
and `loose-` / `maximum-` / `skip-` / `enable-` / `disable-` prefixed
spellings, with `_` and `-` interchangeable. A bare `-p` (or `--password`, or
`-p X` with a space) exits 2 too: there is no prompt.

The script needs bash and says so, exit 2, under `sh`. It runs from stdin
(`bash -s -- --stdout < collect-collmysql.sh`) like any other invocation.

Run it **on the MySQL host** when you can. Sections A, C, D and K read files and
the process table locally, and fall back to `n/a (...)` when run from elsewhere.

### Collection-load tiers

- **Tier 0** (the default `--file` / `--stdout` report) runs `SHOW` statements,
  `information_schema` and `performance_schema` queries, and near-instant local
  reads. No table scan of user data, no log decode.
- **The window** (every run, section J): it puts no load on the server, only
  wall clock, so it is in the default run. `iostat -x` and `vmstat` start
  together as bounded background jobs, six reports each at a fifth of the
  window (15 s: 3 s intervals). The samplers only add detail, so one
  that is absent (`iostat -x 3 6: n/a (command not found: iostat, sysstat)`) or
  fails is a fact line in J; the goal is blocked only when the deadline cuts or
  skips the window or when every sampler present failed. With neither installed
  the goal is not declared and `[1]` says `window: not run (no sampler
  installed)`. A caller's `RUN_DEADLINE` that would cut the window shortens it
  (30 s are kept for section K and the status) and says so in J, on the terminal
  and in the status, with the real length (whole intervals of a fifth); one that
  leaves it under 10 s means it is not run. A first `INT`, `TERM` or `HUP`
  during the window stops both samplers and the report is still written: J says
  `ended early: SIG... after Xs of Ys`, keeps what the samplers had written, and
  the goal is blocked with the same words. A second signal aborts the run.
- **Tier 2**: `--binlog[=N]` decodes the N newest binary logs (default 2) with
  `mysqlbinlog --base64-output=DECODE-ROWS` and counts row events per table.
  This reads whole log files, so it costs I/O proportional to their size and is
  off by default; start with `--binlog=1` on a host under pressure. Each file is
  capped at `BINLOG_TIMEOUT` (300 s) and the run deadline is raised to fit. The
  goal is obtained only when every selected file was decoded to its end: a file
  `mysqlbinlog` could not open (Errcode 13) or a decode stopped at the cap is
  blocked, with the file named. A selected file that is not there, or a name
  listed twice with no readable index, is named as skipped and blocks the goal.

  The newest files and their sizes are the last rows of `SHOW BINARY LOGS`;
  their paths are those of `@@log_bin_index` when it is readable and lists the
  same names, else `<binlog dir>/<name>`. The files are read only through the
  server's own process, so the collector first decides where the server is:
  - The `Connection:` line of the client's own `status` (also the login check):
    a unix socket, loopback or an address this host owns (`/proc/net/fib_trie`)
    is local. A TCP address this host does not own is a remote server, a gap
    "the server is remote (connected to ...); run the collector on the database
    host", unless a local mysqld's own network namespace owns it (a container on
    its bridge address). A name is resolved with one `getent ahostsv4`; a name
    that does not resolve, or an IPv6 address, falls back to the process rule
    below. `[1]` prints `connected to:`. A Kubernetes Service ClusterIP typed
    directly is classified remote: connect through the pod's own address, its
    socket, or `127.0.0.1` inside the pod instead.
  - A local `mysqld`/`mariadbd` process is taken as the server when its pid file
    (`@@pid_file`, read through `/proc/P/root`) holds its pid and was written
    between the server's start (3 s early allowed) and 1800 s after it (mysqld
    writes it after InnoDB crash recovery; a longer recovery reads as another
    server), its `auto.cnf` holds `@@server_uuid` where
    readable, and its binlog directory holds the server's newest log at no less
    than the listed size and nothing newer. The logs are then read at
    `/proc/P/root<binlog dir>`, so a containerised, bind-mounted or pod mysqld
    works; a `binlog files: via pid P (...)` line says how they were found. No
    matching process, a pid file this uid may not read (with the privilege
    hint), or two matches is a gap naming what each candidate failed. A remote
    server, or a copy of its datadir running here, does not match once the
    server has written a log the copy lacks. With the target unknown (an
    unresolvable name, IPv6), an idle local server started from the same image
    up to 1800 s after an idle remote target can be taken for it; their logs then
    hold only the init.
  - Without the `SHOW BINARY LOGS` list (refused, cut) the directory is listed
    by mtime instead. A `@@log_bin_basename` that is NULL or not an absolute
    path is "not resolved", never the working directory, and `@@log_bin = 0` is
    `n/a`. When section I finds no row events, `binlog_format` in section B says
    whether the server writes row events at all.

### Reading the report

- `SHOW REPLICA STATUS` (8.0.22+) and `SHOW SLAVE STATUS` (older) are both
  issued on purpose; one of them always reports a reason instead of rows. The
  same applies to `SHOW REPLICAS` / `SHOW SLAVE HOSTS`.
- Section I parses `mysqlbinlog` text output and assumes row-based events render
  as `### INSERT INTO`, `### UPDATE` and `### DELETE FROM`. A server running
  `binlog_format=STATEMENT` produces no such lines, and the section then reports
  only the transaction and statement counts.

## What the report can contain

Every place a secret or sensitive value can arrive from.

Nothing is masked, and nothing is written to the database. What can carry
something sensitive:

- **The processlist** (H): the `INFO` column, truncated to 120 characters: a
  running statement's literal values, which can include a password in a
  `CREATE USER` / `SET PASSWORD` / application query.
- **Statement digests** (G): normalized, so literals are replaced by `?`, but
  schema, table and column names are verbatim.
- **Schema footprint** (F): every schema and table name, row counts.
- **The error log tail** (K): whatever the server logged (failed logins with
  account and host names).
- **Section A/[1]**: the account name the connection was attempted with and the
  one the server matched, and the local `mysqld` command line from `ps`. `[1]`
  prints the whole `--mysql-args` string as the operator gave it (a password
  or a bare `-p` in it ends the run first).
- **Section I** prints table names and event counts, not the decoded rows.
- **Section J** prints the block device names `iostat -x` lists.

- **The password** this collector was given is never printed; `[1]` says only
  where it came from. It exists, for the run, in the mode-600 option file of the
  run's private temp directory, and, when it came from `MYSQL_PWD`, in the
  collector's own `/proc/<pid>/environ`.

Move the file over a trusted channel and delete it when the case
is closed.
