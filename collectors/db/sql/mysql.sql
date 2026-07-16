-- WhaTap Global Groundtruth — DB collector SQL pack: MySQL / MariaDB
-- ---------------------------------------------------------------------------
-- Run with the SAME account the WhaTap DBX agent uses (read-only queries):
--
--   mysql --force --table -h <db_ip> -P <db_port> -u <monitoring_user> -p < mysql.sql > mysql-facts.txt 2>&1
--
-- --force keeps going after individual query errors; a printed error is
-- itself a fact (it shows what the monitoring account cannot do). Some
-- sections apply to only one of MySQL/MariaDB — the other errors, which is
-- expected and harmless. Paste the FULL output together with the
-- collect-db.sh report. Facts only — no interpretation in this script.
-- ---------------------------------------------------------------------------

SELECT '==== WhaTap Global Groundtruth — db/sql/mysql.sql v0.1.0 ====' AS banner;

SELECT '[1] server & session identity' AS section;
SELECT VERSION()          AS version,
       @@version_comment  AS version_comment,
       @@version_compile_os AS compile_os,
       @@hostname         AS hostname,
       CURRENT_USER()     AS current_user_effective,
       USER()             AS user_connected_as,
       NOW()              AS db_time_now;

SELECT '[2] grants of the monitoring account' AS section;
SHOW GRANTS FOR CURRENT_USER();

SELECT '[3] collection-relevant server variables' AS section;
SHOW GLOBAL VARIABLES WHERE Variable_name IN
  ('performance_schema','slow_query_log','slow_query_log_file','long_query_time',
   'log_output','general_log','require_secure_transport','have_ssl','tls_version',
   'default_authentication_plugin','authentication_policy',
   'max_connections','read_only','super_read_only','server_id',
   'gtid_mode','character_set_server','collation_server','version_compile_machine');

SELECT '[3b] TLS negotiation of THIS session (same connect path as the agent when run via --sql)' AS section;
SHOW SESSION STATUS LIKE 'Ssl_version';
SHOW SESSION STATUS LIKE 'Ssl_cipher';

SELECT '[4] sys schema objects the agent lock query uses (existence + definer)' AS section;
SELECT TABLE_SCHEMA, TABLE_NAME, 'table-or-view' AS object_type
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='sys' AND TABLE_NAME IN ('sys_config','innodb_lock_waits');
SELECT TABLE_NAME, DEFINER, SECURITY_TYPE
FROM information_schema.VIEWS
WHERE TABLE_SCHEMA='sys' AND TABLE_NAME='innodb_lock_waits';
SELECT ROUTINE_SCHEMA, ROUTINE_NAME, DEFINER, SECURITY_TYPE
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA='sys'
  AND ROUTINE_NAME IN ('format_statement','quote_identifier','sys_get_config');

SELECT '[5] sys.innodb_lock_waits readability test (an error here is the fact)' AS section;
SELECT count(*) AS innodb_lock_waits_rows FROM sys.innodb_lock_waits;

SELECT '[6] performance_schema statement consumers (SQL statistics prerequisites)' AS section;
SELECT * FROM performance_schema.setup_consumers WHERE NAME LIKE 'events_statements%';

SELECT '[7] replication status (MySQL 8.0.22+ syntax; older/MariaDB errors, then next query applies)' AS section;
SHOW REPLICA STATUS;
SHOW SLAVE STATUS;

SELECT '[8] authentication plugin of the monitoring account (may need SELECT on mysql.user)' AS section;
SELECT user, host, plugin
FROM mysql.user
WHERE user = SUBSTRING_INDEX(CURRENT_USER(), '@', 1);

SELECT '[9] sessions of this monitoring account (the agent connections)' AS section;
SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE
FROM information_schema.PROCESSLIST
WHERE USER = SUBSTRING_INDEX(CURRENT_USER(), '@', 1);

SELECT '==== END OF SQL PACK (no diagnosis by design) ====' AS footer;
