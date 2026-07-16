-- WhaTap Global Groundtruth — DB collector SQL pack: Oracle
-- ---------------------------------------------------------------------------
-- Run with the SAME account the WhaTap DBX / Oracle Pro agent uses
-- (read-only queries):
--
--   sqlplus <monitoring_user>/<password>@//<db_ip>:<db_port>/<service> @oracle.sql > oracle-facts.txt 2>&1
--
-- WHENEVER SQLERROR CONTINUE keeps the script going after individual errors;
-- a printed ORA- error is itself a fact (it shows what the monitoring account
-- cannot read — e.g. missing SELECT ANY DICTIONARY surfaces here). Paste the
-- FULL output together with the collect-db.sh report. Facts only.
-- ---------------------------------------------------------------------------
WHENEVER SQLERROR CONTINUE
SET PAGESIZE 200 LINESIZE 220 TRIMSPOOL ON TAB OFF
SET ECHO OFF FEEDBACK ON

SELECT '==== WhaTap Global Groundtruth — db/sql/oracle.sql v0.1.0 ====' AS banner FROM dual;

SELECT '[1] server & session identity' AS section FROM dual;
SELECT banner FROM v$version;
SELECT instance_name, host_name, version, status, database_status, startup_time
FROM v$instance;
SELECT name, open_mode, log_mode, database_role, cdb FROM v$database;
SELECT USER AS connected_as, sys_context('USERENV','CON_NAME') AS container,
       sys_context('USERENV','SERVICE_NAME') AS service,
       TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') AS db_time_now
FROM dual;

SELECT '[2] privileges of the monitoring account (SELECT ANY DICTIONARY appears here when granted)' AS section FROM dual;
SELECT privilege FROM session_privs ORDER BY privilege;
SELECT granted_role, admin_option, default_role FROM user_role_privs;

SELECT '[3] monitoring account status' AS section FROM dual;
SELECT username, account_status, lock_date, expiry_date, profile
FROM user_users;

SELECT '[4] collection-relevant instance parameters (sessions/processes size the agent memory)' AS section FROM dual;
SELECT name, value
FROM v$parameter
WHERE name IN ('sessions','processes','cpu_count','memory_target','memory_max_target',
               'sga_target','sga_max_size','pga_aggregate_target','compatible',
               'instance_name','service_names','statistics_level','audit_trail')
ORDER BY name;

SELECT '[5] SGA summary' AS section FROM dual;
SELECT * FROM v$sga;

SELECT '[6] character set / NLS (query-text encoding depends on these)' AS section FROM dual;
SELECT parameter, value
FROM nls_database_parameters
WHERE parameter IN ('NLS_CHARACTERSET','NLS_NCHAR_CHARACTERSET','NLS_LANGUAGE','NLS_TERRITORY');

SELECT '[7] RAC topology (single row = single instance)' AS section FROM dual;
SELECT inst_id, instance_name, host_name, status FROM gv$instance;

SELECT '[8] archive log mode detail' AS section FROM dual;
SELECT dest_id, status, destination FROM v$archive_dest WHERE status <> 'INACTIVE' AND ROWNUM <= 5;

SELECT '[9] sessions of this monitoring account (the agent connections)' AS section FROM dual;
SELECT sid, serial#, username, status, program, machine,
       TO_CHAR(logon_time,'YYYY-MM-DD HH24:MI:SS') AS logon_time
FROM v$session
WHERE username = USER;

SELECT '==== END OF SQL PACK (no diagnosis by design) ====' AS section FROM dual;
EXIT
