# collectors/db: WhaTap DB-monitoring collector

> **Status:** validated at `collect-db.sh` 0.9.1 on 2026-09-28, live
> `jjsong-ggt-postgres` container (DB host, PostgreSQL 16, no DBX agent installed
> there); COMPLETE, `validate.sh --report` pass.
> Validated at `collect-db-mssql.ps1` 0.7.0 on 2026-09-27, Windows Server 2022.
> Not yet run on: a real DBX agent host (the mock DBX tree was last run at 0.9.0).
> Owner: Global team until handover to the DB domain team (CONTRACT rule 4).

The fact list comes from a full read of #ext-db-모니터링-기술문의 (2025-04 to
2026-07, about 282 field questions) and deep reads of the four longest support
threads.

## Why the layout looks like this

The DBX agent queries the monitored database **remotely over JDBC**, so the
facts live in three different places, and no single script can reach all of
them:

| Where the facts live | What lives there | Collected by |
|---|---|---|
| DBX agent host | agent versions (jar names), whatap.conf, agent logs (WA codes), network reachability, dmx/prx watchdog, dbxc | `collect-db.sh` |
| DB host (on-prem) | XOS + xos.conf, slow-query log files, DB server processes, port 3002 | `collect-db.sh` (same script, run there too) |
| Inside the DB engine | exact version/edition, monitoring-account grants, parameters, monitoring objects (pg_stat_statements, sys views, V$ access) | `sql/<engine>.sql` via the DB client: the **only** channel for managed cloud DBs (RDS etc.) |

`collect-db.sh` discovers which components are present on the host it runs on
(dbx / dmx / prx / xos / xcub / dbxc processes, plus DB server processes) and
emits the matching sections; what is absent is reported with its reason.
Its shared helpers `_classify_err`, `_proc_hidden` and `_self_tree` are the group
block `host: helpers` ([templates/groups/host.sh](../../templates/groups/host.sh)).

## Field procedure

1. On the **DBX agent host**: `./collect-db.sh --file` → send the `.txt`.
2. **Split topology** (agent host ≠ DB host, on-prem): run the same command on
   the DB host too (XOS / DB-server facts live there).
3. Run the **SQL pack** with the *monitoring account* and send its full output.
   Two ways: **(a) is the primary path**:
   - **(a) over JDBC, on the agent host, no DB client needed**:
     `./collect-db.sh --file --sql`
     The runner reuses the agent host's java (a DBX prerequisite) and the proven
     driver in `jdbc/` (jshell on JDK 9+, Nashorn jrunscript on JDK 8; UTF-8
     output forced). The connection is built from the same `whatap.conf` the
     agent uses: `dbms`, `db_ip`, `db_port`, `db` (falling back to `plan_db`),
     `connect_option`. Credentials are not in the conf (stored encrypted by
     `uid.sh`; this script does not decrypt them): they are asked on the terminal,
     or read from `WHATAP_GGT_USER` / `WHATAP_GGT_PW` for non-interactive runs.
     The prompt waits no longer than what is left of the run deadline
     (`RUN_DEADLINE`, 300 s); an unanswered prompt skips that instance, and the
     `sql` goal names the timeout. Announced on stderr before anything is sent
     (Tier 2, read-only, 20s/statement, 200 rows/query caps).
   - **(b) through a DB client**, where the customer's DBA already has one:
     `sql/postgresql.sql` (psql -f) · `sql/mysql.sql` (mysql --force <) ·
     `sql/oracle.sql` (sqlplus @) · `windows/mssql.sql` (sqlcmd -i).
     The pack files are client-neutral (labels are SELECT literals; client
     directives are skipped by the JDBC runner), so the same file serves both.
4. **Windows (MSSQL)**: use `windows/collect-db-mssql.ps1` instead of the bash
   collector, plus `windows/mssql.sql` via sqlcmd (no JDBC runner for MSSQL in
   this version, its pack uses GO batches):

   ```
   .\collect-db-mssql.ps1 -File
   sqlcmd -S <db_ip>,<db_port> -U <monitoring_user> -i mssql.sql -o mssql-facts.txt
   ```

   Leave `-P` out so sqlcmd asks for the password; a `-P <password>` argument
   is visible in the process list. `-AgentHome <dir>` (or `-Home`, `--home`)
   adds an install dir the process scan cannot see; `-Out <dir>` writes the report
   elsewhere (checked for writing before the run); `-Help` / `-h` print the usage.
   The shell spellings `--file`, `--stdout`, `--quiet`, `--help` and `--out` work;
   an unknown argument prints usage to stderr and exits 2. It has no opt-in.

   Send the `-File` report: it is UTF-8 without a BOM with LF line ends under
   either PowerShell. `-Stdout` hands the lines to the PowerShell host (CRLF,
   console code page, UTF-16LE for a `>` redirection under 5.1), and
   `tools/validate.sh --report` rejects such a copy. Run it elevated: not
   elevated, another account's java command line is empty, so the DBX process is
   not found and the install goal is `missed` with the privilege hint. Over
   OpenSSH a non-administrator gets a network logon that WMI refuses ("Access
   denied" on every CIM read); the same account in a local logon reads the
   process list.

   Section B also gives each SQL Server instance installed on the host where
   it runs: `Version`, `PatchLevel` and `Edition` from
   `HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\<instance id>\Setup`
   (instance ids from `...\Instance Names\SQL`, in the 64-bit and the 32-bit
   registry view) and the FileVersion of `<SQLBinRoot>\sqlservr.exe`. Any
   account reads them, elevated or not, and no SQL login is used; a host
   without SQL Server says `none (registry key not found)`. `mssql.sql`
   still gives `@@VERSION` of the engine it connects to.

No agent process running, or one whose install dir the report says it could
not resolve? Point the collector at the install dir:
`./collect-db.sh --file --home /path/to/agent`.
`--out DIR` puts the `.txt` in DIR instead of the current directory; a DIR
that cannot be written stops the run before it collects.

## Report sections and goals

`collect-db.sh` sections, in emission order: `[1]` Collection environment,
A. Host & platform, B. Component discovery, C. Agent home
inventory, D. Configuration (verbatim), E. Runtime processes, F. Agent logs,
G. Topology & network, H. Engine-specific facts, I. XOS / DB-host side facts,
J. SQL pack per instance, K. TLS handshake probe, then the opt-in L. SQL pack
over JDBC (`--sql`), and Collection status.

Goals: `components` (a dbx/dmx/prx/xos process (a java process whose
arguments name the whatap.agent jar or class) or a dbxc/xcub binary; the
collector's own shell ancestry is never counted), `home` (every component
process mapped to an install dir: its cwd or the dir of an absolute jar path;
a cwd that is deleted, cannot be entered, or is a system root such as `/` is
not taken), `conf` (every discovered `whatap.conf` / `xos.conf`, symlinks
included, readable, and the search under each home complete), plus `sql`
only when `--sql` was given. Section K has no goal: its facts are part
of every run and carry their own reasons.

A `--home` resolves only the processes it matches: the process's cwd is the
home or under it, or its relative `-jar` path exists under the home. An
unrelated `--home` resolves nothing. As non-root, another user's
`/proc/<pid>/cwd` is unreadable, so a process started with a relative `-jar`
path has no resolvable home and `home` is `missed` with the privilege gap (the
gap is added only when privilege was the cause). With `/proc` mounted
`hidepid` (and the run not in its `gid=` group), "no component process" is
`missed`, not `na`; an unreadable mountinfo is reported as unknown visibility.
A requested `--sql` that could not run (no credentials, no driver, no
jshell/jrunscript, a connect error, or an endpoint whose section G connect
probe failed) is `missed`. Section K sends no handshake to an endpoint whose
section G connect probe failed and says so; without openssl it says that.

Reading the report: the collector prints raw output once and builds no view on it
(CONTRACT rule 1, "Derived views"). `whatap.conf` is in section D verbatim, and
sections G, H and K name only the target each probe used; to see whether the DB
is co-located, compare `db_ip` in D with `local ip addresses` in G. A whatap.conf
longer than the 400 lines D shows also gets its later lines that are not blank or
`#` comments. Sections F and H print log lines with a count of what was read: over
the newest agent log's last 5000 lines, per pattern `label (M lines): <first
matching line>` (a `sample lines` pattern gives its first 3) and per WA code
`WA123 (M occurrences): <first line>`, then the last 200 lines verbatim (H does
the same for each instance's log with that engine's patterns, naming the log with
its `ls -l`). First lines are cut at 400 bytes on a UTF-8 boundary ("(first N of M
bytes)"); a line already printed in the same list is named. The labels (the
Windows collector's F uses the .NET forms in its own rows; its patterns are
case-insensitive, the shell's are not; the regexes are in the scripts):

| Section / dbms | Label |
|---|---|
| F | WA code lines (per code) |
| F | exception lines |
| F (Linux) | exception sample lines (first 3) |
| F | connection error lines |
| F | activate/inactivate lines |
| F (Windows only) | TLS/SSL/login lines |
| H postgresql | PgStatements.process lines |
| H postgresql | PgObject.process lines |
| H postgresql | timeout lines |
| H postgresql | pg_stat_statements missing-relation lines |
| H postgresql | authentication-type lines |
| H mysql/mariadb | WA310 lines |
| H mysql/mariadb | denied/permission lines |
| H mysql/mariadb | sys.innodb_lock_waits lines |
| H mysql/mariadb | replication warning lines |
| H oracle | ORA code lines (per code) |
| H oracle | timeout lines |
| H mssql | TLS/SSL negotiation lines |
| H mssql | login/permission lines |
| H tibero | JDBC code lines (per code) |
| H tibero | read-timeout / connection-closed lines |
| H redis/valkey | jedis/pool error lines |
| H mongo* | mongo timeout/format lines |
| H cloud_watch / aws_arn set | AWS credential/role lines |
| H cloud_watch / aws_arn set | AWS credential/role sample lines (first 3) |
| I | lines with SQLSTATE prefix '00000:' |
| I | lines containing bytes outside printable ASCII |

The ms after each section G `tcp connect` is the wall time of one bounded child
bash that opens the socket. Process start dominates it (about 10-130 ms to a
same-host container), so it is not a network latency figure: only a value far above
that floor says the network or the endpoint was slow. `db round trip (runner VM
clock)` (`--sql`) is the JDBC login (`jdbc connect`) and one trivial query
(`SELECT 1`, `SELECT 1 FROM DUAL` on Oracle), timed inside the runner VM, so JVM
start-up is not in it; the first connect of a run also loads the driver classes.
On a host with no xos or DB server process, or with DB server processes but no
DBX component, the run prints a `!!` line on the terminal naming the other host to
run it on.

## Engine coverage

| Engine | Shell sections | SQL pack |
|---|---|---|
| PostgreSQL (incl. RDS/Aurora/EDB) | yes | `sql/postgresql.sql` |
| MySQL / MariaDB (incl. Aurora) | yes | `sql/mysql.sql` |
| Oracle (DPM + Oracle Pro dmx/prx) | yes | `sql/oracle.sql` |
| SQL Server (Windows) | `windows/collect-db-mssql.ps1` | `windows/mssql.sql` |
| Redis/Valkey, MongoDB, Tibero | log-pattern facts only | not yet |
| CUBRID | out of scope (common sections still apply) | not yet |
| others (`dbms=` unknown) | common sections + "not covered" fact | not yet |

Cloud (CloudWatch/dbxc/IAM): conf keys and credential-related log lines are
collected verbatim; console-side values (parameter groups, IAM policies) are
out of reach of any script here and stay with the field engineer.

## SSL/TLS connection cases

A frequent field pattern. The failure is a mismatch between four facts that
live in four different places: the collector puts them side by side:

| # | Fact | Where it lives | Collected by |
|---|---|---|---|
| 1 | what the DB requires/offers (TLS versions, cert, `require_secure_transport`/`ssl`) | DB server | section K handshake probe (openssl s_client, `-starttls mysql/postgres`: its protocol, cipher, key size, verify lines verbatim, and openssl x509 subject, issuer, dates, sha256 fingerprint, SAN and signature algorithm per chain certificate) + SQL pack server variables |
| 2 | what the agent requests | `whatap.conf` | `connect_option` and `db_ssl` in section D verbatim (misspelled keys are silently ignored by drivers: the raw spelling IS the fact) |
| 3 | what the runtime permits | agent-host JDK + driver | `jdk.tls.disabledAlgorithms` from the runtime's `java.security` (per discovered java), JDBC driver jar name/version (defaults flip across versions) |
| 4 | what actually gets negotiated | the live session | SQL pack `[6b]`/`[3b]`: `pg_stat_ssl` / `Ssl_version` for THIS session, and since `--sql` reuses the agent's own `connect_option`, this measures the agent's negotiation, not an approximation |

Section K is part of every run: one handshake per instance whose section G connect
succeeded, each capped at 15 s and all together at 30 s (instances left after that
say `n/a (not run: TLS probes stopped after 30s)`). It sends no credentials and
nothing after the handshake. Nothing is parsed out of the s_client output: all of
it (stdout and stderr) is printed verbatim but for the PEM blocks, the per-connection
random values (session ticket hex dump, Session-ID, Session-ID-ctx, Master-Key,
Resumption PSK, Start Time) and the TLS 1.3 post-handshake session tickets (they
arrive only when a ticket lands before s_client exits, so keeping them would make
the section differ run to run). openssl's own reasons are included ("MySQL server
does not support SSL.", or the usage text of an openssl such as 1.0.2 or LibreSSL
that refuses `-starttls postgres`); an output identical to one printed for an
instance above is named instead. Each certificate of the chain (`-showcerts`) is
given by `openssl x509 -noout` (subject, issuer, dates, sha256 fingerprint, SAN,
signature algorithm), raw. A session exists only where openssl names a protocol and
a cipher (`New, TLSv1.3, Cipher is ...`); against a server that negotiates no TLS
(PostgreSQL `ssl=off`, MySQL without TLS) openssl can still print `Verify return
code: 0 (ok)` with no certificate. Not probeable this way: MSSQL (TLS inside TDS
prelogin) and Oracle TCPS, noted as reasoned absence.

Server footprint of the handshake, measured against PostgreSQL 16.15 and MySQL
8.4.10 (2026-09-26): the same as the section G connect probe every run already
sends, so a run opens two connections per TLS-probeable instance. Nothing in the
default logs; with `log_connections=on` one `connection received` line each; MySQL
`Aborted_connects` +1 and `Ssl_accepts` / `Ssl_finished_accepts` +1 each, and at
`log_error_verbosity=3` one `Got an error reading communication packets` note
each; nothing in the MySQL general log.

Collection-server-side facts (server version, metrics categories) belong to
`collectors/collection-server`, not here.

## Validated on

- Bash collector: `tools/validate.sh` passes, targets bash 3.2+ (no arrays beyond
  indexed, no mapfile), no `set -e`. Run as root on the lab docker VM (Ubuntu
  24.04, OpenSSL 3.0.13) with `--home` on a mock install tree (co-located, remote and
  AWS-endpoint instances for mysql, postgresql and oracle; long log lines; a
  whatap.conf past 400 lines), against MySQL 5.7/8.0/8.4, MariaDB 10.11 and
  PostgreSQL 16 (`ssl=on` and `ssl=off`), under bash 3.2, gawk/mawk/busybox awk, and
  with OpenSSL 1.0.2g and LibreSSL 3.7.3. TLS probe, session-TLS measurement
  (`--sql` with `connect_option=?ssl=true&sslmode=require` shows `pg_stat_ssl: t |
  TLSv1.3 | ...`).
- SQL packs: `postgresql.sql` as a `pg_monitor`-only user through both the JDBC runner
  (jshell on JDK 17, and Nashorn jrunscript on OpenJDK 1.8.0_504) and psql;
  `mysql.sql` against MySQL 8.4 and 8.0.46 (the legacy `SHOW SLAVE STATUS` errors
  there by design, `--force` continues). `oracle.sql` was
  syntax-reviewed only; `windows/mssql.sql` ran against SQL Server 2022 as a
  sysadmin and as a login with only VIEW SERVER STATE and VIEW ANY DEFINITION.
- `collect-db-mssql.ps1`: Windows Server 2022 Standard Evaluation 10.0.20348, Windows
  PowerShell 5.1 and pwsh 7.6, SQL Server 2022 Express with two instances and a
  **simulated** DBX agent (a java process, two `whatap.conf` instances, a log with
  WA codes; the DBX package is not publicly downloadable): elevated, not elevated
  in a local logon, and over OpenSSH.

## What the report can contain

Configuration and logs are quoted verbatim (framework policy: no masking). A
secret can arrive from:

- **`whatap.conf`** (section D): the license key,
  `db_user`, `aws_access_key` / **`aws_secret_key`**, `aws_arn`, and
  `connect_option`, which is also printed as part of the JDBC URL in
  section L; a driver option string can carry `password=` or a
  keystore password.
- **`dbx.conf`, `prx.conf`, dbxc `config.yaml`, `xos.conf`** (sections D and
  I), dumped verbatim.
- **Process command lines** (sections E and I, `ps ... args`): whatever the
  agent or the DB server was started with.
- **Cron entries** (section E): lines of `/etc/crontab` and `/etc/cron.d/*`
  that mention whatap, which can carry credentials passed to a job.
- **Agent logs** (section F, a 200-line tail and the first 1 or 3 matching
  lines per pattern and the first line per WA code from the last 5000,
  first lines cut at 400 bytes, samples whole; section H, the same per instance log) and the
  **slow-query file** named by `xos.conf` (section I, last 3 lines and the
  first matching line per pattern from the last 200): SQL text and bind
  values as the DB logged them.
- **SQL pack output** (section L): result rows of the monitoring views,
  including session and query text.
- **Server certificates** (section K): subject, issuer and SAN of each
  certificate in the chain each DB endpoint presents, which name hosts and
  the organisation.
- **Credentials for `--sql`** are not printed (the user name is). They reach
  the JDBC runner through its environment only, never its command line.

Windows (`collect-db-mssql.ps1`): `whatap.conf` verbatim, agent process command
lines (first 180 characters), `sqlservr` command lines, the path and account of
services named whatap/dbx, the names of scheduled tasks named whatap/dbx, and
the agent log tail with the first matching lines per pattern and per WA code
from the last 5000 lines (first lines cut at 400 bytes, the 3 exception
sample lines whole).
