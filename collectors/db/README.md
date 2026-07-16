# collectors/db — WhaTap DB-monitoring collector

> **Status: v0 implemented** (2026-07-16). Owned by the DB domain team once
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
     from `WHATAP_GGT_USER` / `WHATAP_GGT_PW` for non-interactive runs.
     Announced on stderr before anything is sent (Tier 2, read-only,
     20s/statement, 200 rows/query caps).
   - **(b) through a DB client**, where the customer's DBA already has one:
     `sql/postgresql.sql` (psql -f) · `sql/mysql.sql` (mysql --force <) ·
     `sql/oracle.sql` (sqlplus @) · `windows/mssql.sql` (sqlcmd -i).
     The pack files are client-neutral (labels are SELECT literals; client
     directives are skipped by the JDBC runner), so the same file serves both.
4. **Windows (MSSQL)**: use `windows/collect-db-mssql.ps1` instead of the bash
   collector, plus `windows/mssql.sql` via sqlcmd (no JDBC runner for MSSQL in
   this version — its pack uses GO batches).

No agent process running? Point the collector at the install dir:
`./collect-db.sh --file --home /path/to/agent`.

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
- `collect-db-mssql.ps1` is not covered by `tools/validate.sh` (bash-only);
  CONTRACT conformance is by review.
