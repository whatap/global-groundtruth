-- WhaTap Global Groundtruth — DB collector SQL pack: PostgreSQL
-- ---------------------------------------------------------------------------
-- Run with the SAME account the WhaTap DBX agent uses (read-only queries):
--
--   psql -h <db_ip> -p <db_port> -U <monitoring_user> -d <db> -f postgresql.sql > postgresql-facts.txt 2>&1
--
-- Paste the FULL output together with the collect-db.sh report.
-- psql continues after individual query errors; an error message printed for
-- a section is itself a fact (it shows what the monitoring account cannot do).
-- Facts only — this script reports what is, never what it means.
-- ---------------------------------------------------------------------------
\pset pager off
SELECT '==== WhaTap Global Groundtruth — db/sql/postgresql.sql v0.1.0 ====' AS banner;

SELECT '[1] server & session identity' AS section;
SELECT version();
SELECT current_database() AS current_database,
       current_user       AS current_user,
       session_user       AS session_user,
       inet_server_addr() AS server_addr,
       inet_server_port() AS server_port,
       now()              AS db_time_now;

SELECT '[2] monitoring account roles (pg_monitor is the documented grant)' AS section;
SELECT pg_has_role(current_user, 'pg_monitor',           'member') AS has_pg_monitor,
       pg_has_role(current_user, 'pg_read_all_settings', 'member') AS has_pg_read_all_settings,
       pg_has_role(current_user, 'pg_read_all_stats',    'member') AS has_pg_read_all_stats,
       pg_has_role(current_user, 'pg_signal_backend',    'member') AS has_pg_signal_backend;
SELECT rolname, rolsuper, rolreplication, rolcanlogin, rolvaliduntil
FROM pg_roles WHERE rolname = current_user;

SELECT '[3] search_path of this session (pg_stat_statements visibility depends on it)' AS section;
SHOW search_path;

SELECT '[4] installed extensions and their schemas' AS section;
SELECT e.extname, e.extversion, n.nspname AS schema
FROM pg_extension e JOIN pg_namespace n ON e.extnamespace = n.oid
ORDER BY e.extname;

SELECT '[4b] agent-standard extension check (same query the product team uses)' AS section;
select /* WhaTap2N#1 */ extname from pg_extension;

SELECT '[5] server parameters relevant to collection (value + where it was set)' AS section;
SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN ('server_version','shared_preload_libraries',
               'log_min_duration_statement','log_line_prefix','log_error_verbosity',
               'log_destination','logging_collector','log_directory','log_filename',
               'lc_messages','server_encoding','TimeZone',
               'password_encryption','ssl',
               'ssl_min_protocol_version','ssl_max_protocol_version',
               'track_activities','track_counts','track_io_timing',
               'autovacuum','autovacuum_freeze_max_age','max_connections')
ORDER BY name;

SELECT '[6] pg_stat_statements readability test (an error here is the fact)' AS section;
SELECT count(*) AS pg_stat_statements_rows FROM pg_stat_statements;

SELECT '[6b] TLS negotiation of THIS session (same connect path as the agent when run via --sql)' AS section;
SELECT ssl, version AS tls_version, cipher
FROM pg_stat_ssl WHERE pid = pg_backend_pid();

SELECT '[7] replication role & peers' AS section;
SELECT pg_is_in_recovery() AS in_recovery;
SELECT count(*) AS replication_peers FROM pg_stat_replication;

SELECT '[8] database transaction-id age (top 5 — Age/Vacuum screens read this)' AS section;
SELECT datname, age(datfrozenxid) AS datfrozenxid_age
FROM pg_database ORDER BY 2 DESC LIMIT 5;

SELECT '[9] sessions of this monitoring account (the agent connections)' AS section;
SELECT pid, usename, application_name, client_addr, state,
       to_char(backend_start, 'YYYY-MM-DD HH24:MI:SS') AS backend_start
FROM pg_stat_activity
WHERE usename = current_user
ORDER BY backend_start;

SELECT '==== END OF SQL PACK (no diagnosis by design) ====' AS footer;
