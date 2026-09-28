# collectors/db — WhaTap DB-monitoring collector

> **Status: v0 implemented** (2026-07-16; validated at `collect-db.sh` 0.9.1
> on 2026-09-28 against the live `jjsong-ggt-postgres` container (DB host,
> PostgreSQL 16, no DBX agent installed there): COMPLETE, `validate.sh
> --report` pass — the mock-tree / DBX-agent-host path was not re-run this
> round, so it is still validated only at 0.9.0 (see "Verification status");
> the script's own `VERSION` is the current one;
> `collect-db-mssql.ps1` validated at 0.7.0 on Windows Server 2022). Owned by the DB domain team once
> handed over (CONTRACT rule 4); until then managed by the Global team.
> Scope grounded in a full read of #ext-db-모니터링-기술문의 (2025-04 → 2026-07,
> ~282 field questions) plus deep-reads of the four longest support threads.

## Why the layout looks like this

The DBX agent queries the monitored database **remotely over JDBC**, so the
facts live in three different places — and no single script can reach all of
them:

| Where the facts live | What lives there | Collected by |
|---|---|---|
| DBX agent host | agent versions (jar names), whatap.conf, agent logs (WA codes), network reachability, dmx/prx watchdog, dbxc | `collect-db.sh` |
| DB host (on-prem) | XOS + xos.conf, slow-query log files, DB server processes, port 3002 | `collect-db.sh` (same script, run there too) |
| Inside the DB engine | exact version/edition, monitoring-account grants, parameters, monitoring objects (pg_stat_statements, sys views, V$ access) | `sql/<engine>.sql` via the DB client — the **only** channel for managed cloud DBs (RDS etc.) |

`collect-db.sh` discovers which components are present on the host it runs on
(dbx / dmx / prx / xos / xcub / dbxc processes, plus DB server processes) and
emits the matching sections; what is absent is reported with its reason.
Its `_classify_err`, `_proc_hidden` and `_self_tree` are the group block
`host: helpers`, shared with collect-nms.sh and owned by
[templates/groups/host.sh](../../templates/groups/host.sh): edit them there
and run `tools/sync-shared-block.sh --apply`.

## Field procedure

1. On the **DBX agent host**: `./collect-db.sh --file` → send the `.txt`.
2. **Split topology** (agent host ≠ DB host, on-prem): run the same command on
   the DB host too (XOS / DB-server facts live there).
3. Run the **SQL pack** with the *monitoring account* and send its full output.
   Two ways — **(a) is the primary path**:
   - **(a) over JDBC, on the agent host — no DB client needed**:
     `./collect-db.sh --file --sql`
     The product is JDBC end-to-end: installing the agent never required a DB
     client, so none can be assumed anywhere. What IS guaranteed on the agent
     host is java (a DBX prerequisite) + the proven driver in `jdbc/` + network
     reachability — the runner reuses exactly those (jshell on JDK 9+, Nashorn
     jrunscript on JDK 8; UTF-8 output forced). The connection is built from
     the same `whatap.conf` the agent uses: `dbms`, `db_ip`, `db_port`,
     `db` (falling back to `plan_db`), `connect_option` — the one thing the
     conf cannot supply is credentials (stored encrypted by `uid.sh`; this
     script does not decrypt them). Those are asked on the terminal, or read
     from `WHATAP_GGT_USER` / `WHATAP_GGT_PW` for non-interactive runs. The
     prompt waits no longer than what is left of the run deadline
     (`RUN_DEADLINE`, 300 s); an unanswered prompt skips that instance, and
     the `sql` goal names the timeout.
     Announced on stderr before anything is sent (Tier 2, read-only,
     20s/statement, 200 rows/query caps).
   - **(b) through a DB client**, where the customer's DBA already has one:
     `sql/postgresql.sql` (psql -f) · `sql/mysql.sql` (mysql --force <) ·
     `sql/oracle.sql` (sqlplus @) · `windows/mssql.sql` (sqlcmd -i).
     The pack files are client-neutral (labels are SELECT literals; client
     directives are skipped by the JDBC runner), so the same file serves both.
4. **Windows (MSSQL)**: use `windows/collect-db-mssql.ps1` instead of the bash
   collector, plus `windows/mssql.sql` via sqlcmd (no JDBC runner for MSSQL in
   this version — its pack uses GO batches):

   ```
   .\collect-db-mssql.ps1 -File
   sqlcmd -S <db_ip>,<db_port> -U <monitoring_user> -i mssql.sql -o mssql-facts.txt
   ```

   Leave `-P` out so sqlcmd asks for the password; a `-P <password>` argument
   is visible in the process list. `-AgentHome <dir>` adds an install dir the
   process scan cannot see (`-Home`, `--home` and `--home=` too). `-Out <dir>`
   (the shell `--out`) writes the report into another directory, checked
   for writing before the run starts; `-Help` and `-h` print the usage. The shell spellings
   `--file`, `--stdout`, `--quiet`, `--help` and `--out` work; an unknown
   argument prints usage to stderr and exits 2. It has no opt-in.

   Send the `-File` report: it is UTF-8 without a BOM with LF line ends
   under either PowerShell. `-Stdout` hands the lines to the PowerShell host,
   which ends them with CRLF, converts them to the console code page and,
   under Windows PowerShell 5.1, writes a `>` redirection as UTF-16LE;
   `tools/validate.sh --report` rejects such a copy. Run it elevated: not
   elevated, another account's java command line is empty, so the DBX process
   is not found and the install goal is `missed` with the privilege hint. Over
   OpenSSH a non-administrator gets a network logon that WMI refuses
   ("Access denied" on every CIM read, after which the run stops asking);
   the same account in a local logon reads the process list.

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

Goals: `components` (a dbx/dmx/prx/xos process — a java process whose
arguments name the whatap.agent jar or class — or a dbxc/xcub binary; the
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

Reading the report: the collector prints raw output once and builds no view
on it (CONTRACT rule 1, "Derived views"). `whatap.conf` is in section D
verbatim, and sections G, H and K name only the target each probe used; to
see whether the DB is co-located, compare `db_ip` in D with `local ip
addresses` in G. A whatap.conf longer than the 400 lines D shows also gets
its later lines that are not blank or `#` comments. Sections F and H print
log lines with a count of what was read, not tables: over the newest agent
log's last 5000 lines, per pattern `label (M lines): <first matching line>`
(a `sample lines` pattern gives its first 3), and per WA code, in order of
first appearance, `WA123 (M occurrences): <first line holding it>`; F then
gives the last 200 lines verbatim, and H does the same for each instance's
log with that engine's patterns (ORA and JDBC codes one line per code),
naming the log with its `ls -l`. The 3 sample lines are printed whole; a
first line per code or per pattern is cut at 400 bytes on a UTF-8 boundary ("(first N of M bytes)"), and a line already printed in the
same list is named ("(the line shown for WA777)"). The labels and the extended regular expressions behind them (the
Windows collector's F uses the .NET forms in its own rows):

| Section / dbms | Label | Pattern |
|---|---|---|
| F | WA code lines (per code) | `[(]WA[0-9][0-9][0-9][)]` (Windows `\(WA\d{3}\)`) |
| F | exception lines | `Exception\|SQLException\|Error:` (Windows `Exception\|SQLException`, first 3 lines) |
| F (Linux) | exception sample lines (first 3) | `Exception\|SQLException` |
| F | connection error lines | `CONNECTION ERROR\|openConnection error\|Communications link failure` |
| F | activate/inactivate lines | `inactivated\|activated` |
| F (Windows only) | TLS/SSL/login lines | `TLS\|SSL\|Login failed` |
| H postgresql | PgStatements.process lines | `PgStatements[.]process` |
| H postgresql | PgObject.process lines | `PgObject[.]process` |
| H postgresql | timeout lines | `[Tt]imeout` |
| H postgresql | pg_stat_statements missing-relation lines | `pg_stat_statements.*does not exist` |
| H postgresql | authentication-type lines | `authentication type .* not supported` |
| H mysql/mariadb | WA310 lines | `WA310` |
| H mysql/mariadb | denied/permission lines | `command denied\|Access denied` |
| H mysql/mariadb | sys.innodb_lock_waits lines | `innodb_lock_waits` |
| H mysql/mariadb | replication warning lines | `Replication may have been broken\|replication` |
| H oracle | ORA code lines (per code) | `ORA-[0-9]+` |
| H oracle | timeout lines | `[Tt]ime[d]? out\|ORA-01013` |
| H mssql | TLS/SSL negotiation lines | `TLS\|SSL\|encrypt` |
| H mssql | login/permission lines | `Login failed\|permission` |
| H tibero | JDBC code lines (per code) | `JDBC-[0-9]+` |
| H tibero | read-timeout / connection-closed lines | `Read time.?out\|Connection closed` |
| H redis/valkey | jedis/pool error lines | `Jedis\|resource from the pool\|SocketTimeout` |
| H mongo* | mongo timeout/format lines | `MongoTimeout\|numberFormatException` |
| H cloud_watch / aws_arn set | AWS credential/role lines | `AssumeRole\|sts\|security token\|expired` |
| H cloud_watch / aws_arn set | AWS credential/role sample lines (first 3) | `AssumeRole\|sts\|security token.*expired` |
| I | lines with SQLSTATE prefix '00000:' | `00000:` |
| I | lines containing bytes outside printable ASCII | `[^ -~]` (C locale) |

The ms after
each section G `tcp connect` is the wall time of one bounded child bash that
opens the socket. Process start dominates it (about 10-130 ms measured to a
same-host container whose network round trip is under 1 ms), so it is not a
network latency figure: only a value far above that floor says the network or
the endpoint was slow. It is kept because it costs no extra call (it replaced
two `date` forks that gave whole seconds). `db round trip (runner VM clock)`
(`--sql`) is the JDBC login (`jdbc connect`) and one trivial query
(`SELECT 1`, `SELECT 1 FROM DUAL` on Oracle), timed inside the runner VM, so
JVM start-up is not in it. `SELECT 1` is the DB round-trip figure; the
first connect of a run also loads the driver classes. On a host with no xos
or DB server process, or with DB server processes but no DBX component, the
run prints a `!!` line on the terminal naming the other host to run it on.

## Engine coverage (v0)

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
live in four different places — the collector puts them side by side:

| # | Fact | Where it lives | Collected by |
|---|---|---|---|
| 1 | what the DB requires/offers (TLS versions, cert, `require_secure_transport`/`ssl`) | DB server | section K handshake probe (openssl s_client, `-starttls mysql/postgres`: its protocol, cipher, key size, verify lines verbatim, and openssl x509 subject, issuer, dates, sha256 fingerprint, SAN and signature algorithm per chain certificate) + SQL pack server variables |
| 2 | what the agent requests | `whatap.conf` | `connect_option` and `db_ssl` in section D verbatim (misspelled keys are silently ignored by drivers — the raw spelling IS the fact) |
| 3 | what the runtime permits | agent-host JDK + driver | `jdk.tls.disabledAlgorithms` from the runtime's `java.security` (per discovered java), JDBC driver jar name/version (defaults flip across versions) |
| 4 | what actually gets negotiated | the live session | SQL pack `[6b]`/`[3b]`: `pg_stat_ssl` / `Ssl_version` for THIS session — and since `--sql` reuses the agent's own `connect_option`, this measures the agent's negotiation, not an approximation |

Section K is part of every run (0.8.0; it was the opt-in `--tls`, which is now
refused with that message): one handshake per instance whose section G
connect succeeded, each capped at 15 s and all of them together at 30 s
(instances left after that say `n/a (not run: TLS probes stopped after 30s)`). It sends no credentials and nothing after
the handshake. Measured 2026-09-26 against PostgreSQL 16.15 (ssl on, and
ssl off) and MySQL 8.4.10 containers, the handshake leaves the same server
trace as the section G connect probe that every run already sent: nothing in
the default logs; with `log_connections=on` one `connection received` line
each; at MySQL `log_error_verbosity=3` one `Got an error reading
communication packets` note each; MySQL `Aborted_connects` +1 each, and the
handshake also adds 1 to `Ssl_accepts` / `Ssl_finished_accepts`; nothing in
the MySQL general log for either. A run therefore opens two connections per
TLS-probeable instance. Since 0.9.0 nothing is parsed out of the s_client
output: all of it (stdout and stderr) is printed verbatim but for the PEM
blocks and the per-connection random values (session ticket hex dump,
Session-ID, Session-ID-ctx, Master-Key, Resumption PSK, Start Time), openssl's own reasons included ("MySQL server does not support
SSL.", or the usage text of an openssl such as 1.0.2 or LibreSSL that
refuses `-starttls postgres`); an output identical to one printed for an
instance above is named instead. Each certificate of the chain (`-showcerts`) is given by `openssl x509 -noout
-subject -issuer -dates -fingerprint -sha256 -ext subjectAltName -text
-certopt ...` (the -certopt list leaves only the signature algorithm line
of -text; an openssl whose x509 refuses `-ext` is run without it and
prints every extension), output raw. The Windows collector's F patterns
are case-insensitive (as Select-String was); the shell's are not. A session exists only where openssl
names a protocol and a cipher (`New, TLSv1.3, Cipher is ...`); against a
server that negotiates no TLS
(PostgreSQL `ssl=off`, MySQL without TLS) openssl can still print
`Verify return code: 0 (ok)` with no certificate. Not probeable this way: MSSQL (TLS inside TDS
prelogin) and Oracle TCPS — noted as reasoned absence.

Collection-server-side facts (server version, metrics categories) belong to
`collectors/collection-server`, not here.

## Verification status

- `tools/validate.sh` passes; `bash -n` clean; targets bash 3.2+ (no arrays
  beyond indexed, no mapfile), no `set -e`.
- Exercised on a host with no agent (all sections reach the footer with
  reasoned absence) and on a mock install tree: 3 instances covering the
  co-located / remote / AWS-endpoint topologies, engine dispatch for
  postgresql·oracle·mysql, WA-code histogram, XOS slow-query file cross-check
  (SQLSTATE `00000:` prefix and non-ASCII locale detection).
- 0.9.0 (derived views removed) ran beside 0.8.4 on 2026-09-27 as root on
  the lab docker VM (jjsong-ggt-docker, Ubuntu 24.04, OpenSSL 3.0.13), with
  `--home` on a mock tree (a 6000-line agent log with WA/ORA/AWS lines before
  the tail, an instance log of 122 lines, instances for mysql → the
  jjsong-ggt-mysql-primary fixture 8.0.46, postgresql → jjsong-ggt-postgres
  16.15 with `ssl=on`, oracle → an unresolvable RDS name, an xos.conf
  slow-query file), and under `bash:3.2` (busybox awk, no openssl). A
  second run added a 210 kB log line, a 427-line whatap.conf, 17 newer
  files in the log dir, MariaDB 10.11 without TLS, PostgreSQL with
  `ssl=off`, MySQL 5.7, and the images `jjsong-ggt-dbv-ossl102:1` (OpenSSL
  1.0.2g, mawk) and `jjsong-ggt-dbv-libressl:1` (LibreSSL 3.7.3, busybox):
  per-code occurrences and line counts equal the 0.8.4 numbers, the F
  pattern lines are the same under gawk, mawk and busybox awk, the long line
  is cut on a UTF-8 boundary, D gives the keys after line 400, and K prints
  openssl's own reason or usage text (once per identical output). Every
  code the 0.8.4 histograms named (WA111, WA310, WA777, WA888 on one line;
  ORA-01013, ORA-12170) is printed with its line count and first line; the
  MySQL handshake gives both chain certificates (server and CA) and the
  PostgreSQL one its self-signed certificate through openssl x509; both
  reports pass `validate.sh --report`. `--sql` was not run (no java on that host).
- The TLS probe (then `--tls`) ran against a live SSL-enabled PostgreSQL 16 (self-signed cert:
  TLSv1.3/cipher/2048-bit key, cert dates, sha256 signature, verify-code 18
  all captured) and MySQL 8.4 (auto-generated cert captured); session-TLS
  measurement verified end-to-end: `--sql` with
  `connect_option=?ssl=true&sslmode=require` produced
  `pg_stat_ssl: t | TLSv1.3 | TLS_AES_256_GCM_SHA384` in the report.
- SQL packs: `postgresql.sql` ran against PostgreSQL 16 as a `pg_monitor`-only
  user through BOTH paths — the JDBC runner (`--sql`, jshell on JDK 17, real
  postgresql-42.7.4.jar; expected-error path verified: missing
  pg_stat_statements surfaces as `SQL-ERROR:` in the report) and psql — and
  `mysql.sql` against MySQL 8.4 via the client (the legacy `SHOW SLAVE STATUS`
  of the dual replication syntax errors there by design, `--force` continues).
  `oracle.sql` and `windows/mssql.sql` are syntax-reviewed only — first field
  runs double as their validation. The Nashorn (JDK 8 jrunscript) runner path
  was run on OpenJDK 1.8.0_504 (lab target `db-agent`, 2026-09-28) against
  PostgreSQL 16.15 and MySQL 8.0.46: `postgresql.sql` and `mysql.sql` returned
  real rows through jrunscript, the JDBC session to PostgreSQL over TLSv1.3.
- `collect-db-mssql.ps1`: validated at 0.7.0 (0.5.0 first) on Windows Server 2022 Standard
  Evaluation 10.0.20348 (lab VM jjsong-ggt-win) under Windows PowerShell
  5.1.20348.558 and pwsh 7.6.6, 2026-09-26: SQL Server 2022 Express
  16.0.1000.6 with two instances (`SQLEXPRESS` on 1433, `DBX2` on 14330) and
  a **simulated** DBX agent (a java process started from
  `C:\Program Files\WhaTap DBX\whatap.agent.dbx-2.63.06.jar`, two
  `whatap.conf` instances, a log with WA codes; the DBX package is not
  publicly downloadable). Elevated: COMPLETE, 7 s (5.1) / 6 s (7); agent
  stopped: both goals `na`, COMPLETE; not elevated in a local logon: the
  install goal `missed` with the privilege hint, 3 s; not elevated over
  OpenSSH: `missed` on the WMI refusal, 11-12 s; `-Home` / `--home` with a
  path with spaces, a missing `-Home` (`missed`), an unwritable current
  directory (the `!!` line and exit 1), `RUN_DEADLINE` / `CMD_TIMEOUT` and
  invalid values of them. Every `-File` report passes `validate.sh --report`.
  Before 0.3.0 it was not runnable (`-Home` clashed with `$HOME`).
  0.6.0 (2026-09-27, same host) was run beside 0.5.1 under both PowerShells,
  elevated, not elevated in a local logon and over OpenSSH: the only
  differences are the new section B lines, identical in every run
  (`Version=16.0.1000.6 PatchLevel=16.0.1000.6 Edition=Express Edition`,
  sqlservr.exe `FileVersion=2022.0160.1000.06 ((SQL22_RTM).221008-0913)`,
  32-bit view `none`); every report passes `validate.sh --report`.
  0.7.0 (2026-09-27, same host) was run beside 0.6.0 under both PowerShells,
  elevated: the differences are the removed lines and the new section F
  pattern lines. With an extra `-AgentHome` (a 702-line log holding
  `(wa310)` in lower case, `(WA999)(WA999)` on one line and a 210 kB line;
  a 426-line whatap.conf with db_ip/db_port after line 400) the per-code
  occurrences equal the 0.6.0 histogram (140, 70, 70, 2, 1) and the
  exception count its 142, the long line is cut at 400 bytes, and D gives
  the two keys past line 400; identical under both PowerShells. Every
  report passes `validate.sh --report`.
- `windows/mssql.sql` ran against both instances through `sqlcmd -S
  localhost,<port> -E -i mssql.sql` as a sysadmin and as a Windows login
  holding only VIEW SERVER STATE and VIEW ANY DEFINITION: every batch ran
  without an error. On that host `sqlcmd` on PATH is the classic ODBC sqlcmd
  16.0 (`Client SDK\ODBC\170\Tools\Binn`), not go-sqlcmd 1.10.0
  (`C:\ggt\sqlcmd`). Classic sqlcmd strips leading `[...]` groups from a
  PRINT message, so up to v0.2.0 the section labels
  (`[n] title`) arrived there as ` title`. Since v0.3.0 they read
  `==== [n] title ====`; at v0.3.0 (2026-09-27) the labels arrived intact
  through classic sqlcmd 16.0, go-sqlcmd 1.10.0 (stdout and `-o`) and
  `Invoke-Sqlcmd` of the SQLPS 16.0 module (verbose stream), on both
  instances. SSMS is not installed on that host (not run).

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
