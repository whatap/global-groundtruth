# collectors/db — WhaTap DB-monitoring collector

> **Status: v0 implemented** (2026-07-16; validated at `collect-db.sh` 0.1.x
> on mock install trees and live PostgreSQL 16 / MySQL 8.4 — see "Verification
> status"; the script's own `VERSION` is the current one). Owned by the DB domain team once
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
   process scan cannot see (`-Home` still binds as an alias).

No agent process running, or one whose install dir the report says it could
not resolve? Point the collector at the install dir:
`./collect-db.sh --file --home /path/to/agent`.

## Report sections and goals

`collect-db.sh` sections, in emission order: `[1]` Collection environment,
A. Host & platform, B. Component discovery & host role, C. Agent home
inventory, D. Configuration (verbatim), E. Runtime processes, F. Agent logs,
G. Topology & network, H. Engine-specific facts, I. XOS / DB-host side facts,
J. SQL pack per instance, then the opt-ins K. TLS handshake probe (`--tls`)
and L. SQL pack over JDBC (`--sql`), and Collection status.

Goals: `components` (a dbx/dmx/prx/xos process — a java process whose
arguments name the whatap.agent jar or class — or a dbxc/xcub binary; the
collector's own shell ancestry is never counted), `home` (every component
process mapped to an install dir: its cwd or the dir of an absolute jar path;
a cwd that is deleted, cannot be entered, or is a system root such as `/` is
not taken), `conf` (every discovered `whatap.conf` / `xos.conf`, symlinks
included, readable, and the search under each home complete), plus `tls` and
`sql` only when `--tls` / `--sql` was given.

A `--home` resolves only the processes it matches: the process's cwd is the
home or under it, or its relative `-jar` path exists under the home. An
unrelated `--home` resolves nothing. As non-root, another user's
`/proc/<pid>/cwd` is unreadable, so a process started with a relative `-jar`
path has no resolvable home and `home` is `missed` with the privilege gap (the
gap is added only when privilege was the cause). With `/proc` mounted
`hidepid` (and the run not in its `gid=` group), "no component process" is
`missed`, not `na`; an unreadable mountinfo is reported as unknown visibility.
A requested `--sql` / `--tls` that could not run (no credentials, no driver,
no jshell/jrunscript, a connect error, no openssl, or an endpoint whose
section G connect probe failed) is `missed`. `--tls` is `got` only when
openssl reports a negotiated protocol and cipher.

Reading the report: `db endpoint class` says whether `db_ip` is loopback, an
address of this host, a DNS name, or none of this host's addresses; loopback
or a local address means the DB is co-located with the agent. On a host with
no xos or DB server process, or with DB server processes but no DBX
component, the run prints a `!!` line on the terminal naming the other host
to run it on.

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
| 1 | what the DB requires/offers (TLS versions, cert, `require_secure_transport`/`ssl`) | DB server | `--tls` handshake probe (openssl s_client, `-starttls mysql/postgres`; server TLS version, cipher, key size, cert dates + signature algorithm) + SQL pack server variables |
| 2 | what the agent requests | `whatap.conf` | `connect_option` verbatim + key-name breakdown (misspelled keys are silently ignored by drivers — the raw spelling IS the fact), `db_ssl` |
| 3 | what the runtime permits | agent-host JDK + driver | `jdk.tls.disabledAlgorithms` from the runtime's `java.security` (per discovered java), JDBC driver jar name/version (defaults flip across versions) |
| 4 | what actually gets negotiated | the live session | SQL pack `[6b]`/`[3b]`: `pg_stat_ssl` / `Ssl_version` for THIS session — and since `--sql` reuses the agent's own `connect_option`, this measures the agent's negotiation, not an approximation |

`--tls` is Tier 2 (one handshake per instance, announced on stderr). Not
probeable this way: MSSQL (TLS inside TDS prelogin) and Oracle TCPS — noted
as reasoned absence.

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
- `--tls` ran against a live SSL-enabled PostgreSQL 16 (self-signed cert:
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
  is untested on a live JDK 8.
- `collect-db-mssql.ps1`: `tools/validate.sh` parses it with pwsh and lints
  it; 0.3.0 runs to its footer under pwsh 7 on Linux and passes
  `tools/validate.sh --report` (Windows-only probes report n/a there). Not yet
  run on a Windows host. It was not runnable before 0.3.0: its `-Home`
  parameter clashed with the read-only `$HOME` and every run stopped with
  "Cannot overwrite variable Home".

## What the report can contain

Configuration and logs are quoted verbatim (framework policy: no masking). A
secret can arrive from:

- **`whatap.conf`** (section D, and key lines in G/H): the license key,
  `db_user`, `aws_access_key` / **`aws_secret_key`**, `aws_arn`, and
  `connect_option`, which is printed verbatim in section G and as part of the
  JDBC URL in section L; a driver option string can carry `password=` or a
  keystore password.
- **`dbx.conf`, `prx.conf`, dbxc `config.yaml`, `xos.conf`** (sections D and
  I), dumped verbatim.
- **Process command lines** (sections E and I, `ps ... args`): whatever the
  agent or the DB server was started with.
- **Cron entries** (section E): lines of `/etc/crontab` and `/etc/cron.d/*`
  that mention whatap, which can carry credentials passed to a job.
- **Agent logs** (section F, a 200-line tail and samples) and the
  **slow-query file** named by `xos.conf` (section I, last 3 lines): SQL text
  and bind values as the DB logged them.
- **SQL pack output** (section L): result rows of the monitoring views,
  including session and query text.
- **Credentials for `--sql`** are not printed (the user name is). They reach
  the JDBC runner through its environment only, never its command line.

Windows (`collect-db-mssql.ps1`): `whatap.conf` verbatim, agent process command
lines (first 180 characters), agent log tail.
