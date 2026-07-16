-- WhaTap Global Groundtruth — DB collector SQL pack: SQL Server (T-SQL)
-- ---------------------------------------------------------------------------
-- Run with the SAME account the WhaTap DBX agent uses (read-only queries):
--
--   sqlcmd -S <db_ip>,<db_port> -U <monitoring_user> -P <password> -i mssql.sql -o mssql-facts.txt
--
-- sqlcmd continues to the next batch after an error; a printed error is
-- itself a fact (it shows what the monitoring account cannot do — e.g. a
-- missing VIEW SERVER STATE or xp_readerrorlog EXECUTE surfaces here).
-- Paste the FULL output together with the collect-db-mssql.ps1 report.
-- Facts only — this script reports what is, never what it means.
-- ---------------------------------------------------------------------------

PRINT '==== WhaTap Global Groundtruth — db/windows/mssql.sql v0.1.0 ====';
GO

PRINT '[1] server & session identity';
SELECT @@VERSION AS version;
SELECT @@SERVERNAME                        AS server_name,
       SERVERPROPERTY('Edition')           AS edition,
       SERVERPROPERTY('ProductVersion')    AS product_version,
       SERVERPROPERTY('ProductLevel')      AS product_level,
       SERVERPROPERTY('IsClustered')       AS is_clustered,
       SERVERPROPERTY('IsHadrEnabled')     AS is_hadr_enabled,
       SYSDATETIMEOFFSET()                 AS db_time_now;
SELECT SUSER_NAME() AS connected_as, DB_NAME() AS current_database;
GO

PRINT '[2] server-level permissions of the monitoring account';
SELECT IS_SRVROLEMEMBER('sysadmin') AS is_sysadmin;
SELECT permission_name, state_desc
FROM sys.server_permissions p
JOIN sys.server_principals  s ON p.grantee_principal_id = s.principal_id
WHERE s.name = SUSER_NAME();
SELECT * FROM fn_my_permissions(NULL, 'SERVER');
GO

PRINT '[3] xp_readerrorlog EXECUTE permission (checked in master — grantable only there)';
USE master;
SELECT HAS_PERMS_BY_NAME('sys.xp_readerrorlog', 'OBJECT', 'EXECUTE') AS has_xp_readerrorlog_execute;
GO

PRINT '[4] databases visible to the monitoring account';
SELECT name, state_desc, recovery_model_desc, is_read_only
FROM sys.databases ORDER BY name;
GO

PRINT '[5] AlwaysOn availability state (errors when HADR is off — that is the fact)';
SELECT ag.name AS ag_name, rs.role_desc, rs.connected_state_desc, rs.synchronization_health_desc
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_groups ag ON rs.group_id = ag.group_id;
GO

PRINT '[6] connection encryption of this session';
SELECT session_id, encrypt_option, auth_scheme, protocol_type
FROM sys.dm_exec_connections WHERE session_id = @@SPID;
GO

PRINT '[7] sessions of this monitoring account (the agent connections)';
SELECT session_id, login_name, host_name, program_name, status, login_time
FROM sys.dm_exec_sessions WHERE login_name = SUSER_NAME();
GO

PRINT '==== END OF SQL PACK (no diagnosis by design) ====';
GO
