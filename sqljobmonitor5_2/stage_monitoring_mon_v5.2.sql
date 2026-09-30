/*
================================================================================
    MON  -  SQL Server Operational Monitoring & Change-Only Email Delivery
    Target : MS-APP-STG  (Amazon RDS for SQL Server, 2016 SP2 or later)
    Home   : [OPS] database, schema [mon]  (nothing is created in any other schema)
    Author : DBA team / generated with Claude
    Rev    : 5.1   (successor of OPS.monitor Rev 4 - runs side-by-side with it)
             5.1 adds: check matrix with checkboxes (mon.DatabaseCheck / mon.ServerCheck),
                       audit of every change (mon.CheckChangeLog), backup retention &
                       inventory grid (mon.vw_BackupRetention, daily mon.BackupInventoryDaily),
                       usp_SetCheck / usp_ShowChecks / usp_ShowBackupRetention, and an
                       SSMS custom report (MON_Checks_and_Retention.rdl).
================================================================================

WHAT IS NEW COMPARED WITH OPS.monitor REV 4
  1. Everything lives in the new [mon] schema. OPS.monitor and its two
     "OPS - ..." Agent jobs are NOT touched (they keep running in parallel).
  2. Issue engine with a lifecycle instead of "fire every cycle":
        OPENED -> (ESCALATED / DEESCALATED) -> RESOLVED | EXPIRED
     - state issues resolve only after a grace period (anti-flapping)
     - event issues (deadlock, job failure, error-log entry) expire silently
     - mute rules (mon.IssueMute) for maintenance windows / known issues
  3. CHANGE-ONLY EMAIL
     - Alert mail: sent only when something was OPENED / ESCALATED at or above
       the alert severity, or when an alerted issue RESOLVED. No change = no mail.
     - Daily digest (08:00 Eastern, DST-aware): sent only when at least one
       issue changed since the last digest. Otherwise the decision is logged as
       DIGEST_SKIPPED. Every Monday an "all quiet" HEARTBEAT digest is sent even
       when nothing changed, proving the monitor itself is alive.
     - Outbox semantics: if sp_send_dbmail fails, the changes stay pending and
       are re-sent on the next cycle; nothing is silently lost.
  4. BLOCKING > 10 MINUTES
     - Sampler every 30 seconds (inside the looping engine job), captures the
       full chain: head blocker login/host/program/status, open transaction
       age, head SQL + input buffer, blocked statements, wait resource.
     - Episodes are tracked per head-blocker connection. CRITICAL alert when an
       episode reaches 10 minutes, RESOLVED mail with the final duration when it
       clears. Detects the classic "sleeping session with open transaction".
     - Never kills anything.
  5. New checks: long-running requests, idle/open transactions, Agent jobs
     running far longer than their 30-day median, database configuration drift
     (baseline + accept procedure), auto_close / auto_shrink / page_verify,
     last known good CHECKDB, VLF count, files near MAXSIZE, % autogrowth,
     Query Store forced READ_ONLY, CPU (ring buffer), memory grants pending,
     tempdb / version store, I/O latency per file (hourly delta), top waits
     (hourly delta, benign waits filtered), failed-login bursts, Database Mail
     failures, restarts/failovers, and monitor self-health (watchdog).
  6. Transaction-log backup verification now also uses sys.dm_db_log_stats
     (log_backup_time), which sees RDS automated log backups even when
     msdb/backupset and rds_fn_list_tlog_backup_metadata do not.
  7. Email design built for Outlook desktop (Word engine), OWA, Gmail, mobile:
     table layout, inline styles + bgcolor attributes, no flexbox, no <style>
     dependency, per-CELL anomaly highlighting, row caps to stay under
     Gmail's ~102 KB clipping limit.
  8. All timestamps stored in UTC; displayed in America/New_York.
  9. Agent history friendly: one looping engine job (~24 history rows/day)
     instead of a 1-minute job that would flush msdb job history on RDS.

JOBS CREATED (in msdb, the only objects outside OPS.mon)
  MON - Engine              every minute; the job loops ~55 min internally
                            (Agent skips starts while it is running):
                              - blocking sampler every 30 s
                              - full collection + issue evaluation + alert
                                mail every 5 min
  MON - Digest & Watchdog   hourly; sends the digest when due, purges history,
                            and raises an alert if the engine stopped beating.

HOW TO RUN
  Execute this entire file in SSMS as the RDS master login (SQLCMD mode not
  required). Idempotent: re-running preserves all settings, policies, mutes,
  baselines, and history. No email is sent by the installer.

QUICK REFERENCE (after install)
  EXEC OPS.mon.usp_SendDailyDigest @Force = 1;              -- send a digest now
  EXEC OPS.mon.usp_SendDailyDigest @Force = 1, @PreviewOnly = 1;  -- HTML only
  SELECT * FROM OPS.mon.vw_ActiveIssues;                    -- what is open
  SELECT * FROM OPS.mon.vw_BlockingNow;                     -- live chains
  EXEC OPS.mon.usp_ShowChecks;                              -- everything that is checked (matrix)
  EXEC OPS.mon.usp_SetCheck @Database = N'DWH_Stage', @Check = 'LOG', @Enabled = 0;
  EXEC OPS.mon.usp_ShowBackupRetention;                     -- retention / inventory grid
  EXEC OPS.mon.usp_MuteIssue @KeyPattern = N'LONGQ:%', @Hours = 4, @Reason = N'ETL';
  EXEC OPS.mon.usp_AcceptConfigBaseline @DatabaseName = N'MyDb';
  UPDATE OPS.mon.Setting SET setting_value = N'15' WHERE setting_name = 'blocking_alert_minutes';
  UPDATE OPS.mon.Setting SET setting_value = N'0'  WHERE setting_name = 'engine_enabled'; -- stop
================================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO

/* ---------- Pre-flight: SQL Server 2016 SP2 (13.0.5026) or later ---------- */
IF CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) < 13
   OR (CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) = 13
       AND CONVERT(int, PARSENAME(CONVERT(varchar(32), SERVERPROPERTY('ProductVersion')), 2)) < 5026)
BEGIN
    RAISERROR(N'MON requires SQL Server 2016 SP2 or later (sys.dm_db_log_stats, dm_exec_input_buffer). Install aborted.', 16, 1);
    SET NOEXEC ON;
END;
GO

IF DB_ID(N'OPS') IS NULL
    CREATE DATABASE [OPS];
GO

USE [OPS];
GO

IF CONVERT(sysname, DATABASEPROPERTYEX(N'OPS', 'Collation')) <> CONVERT(sysname, SERVERPROPERTY('Collation'))
    PRINT N'WARNING: OPS collation differs from the server collation. Temp tables use COLLATE DATABASE_DEFAULT; '
        + N'if you see error 468 (collation conflict) create OPS with the server collation.';

IF SCHEMA_ID(N'mon') IS NULL
    EXEC(N'CREATE SCHEMA mon AUTHORIZATION dbo;');
GO

/* =============================================================================
   SECTION 1  -  CONFIGURATION
   ============================================================================= */

IF OBJECT_ID(N'mon.Setting', N'U') IS NULL
BEGIN
    CREATE TABLE mon.Setting
    (
        setting_name    varchar(64)     NOT NULL CONSTRAINT PK_mon_Setting PRIMARY KEY,
        setting_value   nvarchar(4000)  NOT NULL,
        value_type      varchar(10)     NOT NULL,
        category        varchar(30)     NOT NULL,
        description     nvarchar(1000)  NOT NULL,
        modified_utc    datetime2(0)    NOT NULL CONSTRAINT DF_mon_Setting_Mod DEFAULT SYSUTCDATETIME(),
        modified_by     sysname         NOT NULL CONSTRAINT DF_mon_Setting_By  DEFAULT ORIGINAL_LOGIN(),
        CONSTRAINT CK_mon_Setting_Type CHECK (value_type IN ('int','decimal','bit','text'))
    );
END;
GO

/*
   Seed. force_update = 1 rows are deployment identity values that this
   installer re-applies every time; everything else is inserted only when
   missing, so DBA overrides survive re-installation.
*/
;WITH Seed AS
(
    SELECT * FROM (VALUES
    /* name                            value                              type      category     force  description */
     ('server_label',                  N'MS-APP-STG',                     'text',   'identity',   1, N'Display name used in subjects and headers.')
    ,('mail_profile',                  N'Notifications',                  'text',   'identity',   1, N'Database Mail profile.')
    ,('alert_recipients',              N'aleksey_kokit@miopartners.com',  'text',   'identity',   1, N'Recipients of immediate alert mail (semicolon separated).')
    ,('report_recipients',             N'aleksey_kokit@miopartners.com',  'text',   'identity',   1, N'Recipients of the daily digest / weekly heartbeat.')
    ,('display_time_zone',             N'Eastern Standard Time',          'text',   'identity',   0, N'Windows time-zone name used for display and the digest hour (DST aware).')
    ,('display_time_zone_label',       N'ET',                             'text',   'identity',   0, N'Short label printed after local times.')
    ,('blocking_sample_retention_days',N'30',                             'int',    'issues',     0, N'Retention for mon.BlockingSample chain rows (bulky).')
    ,('engine_enabled',                N'1',                              'bit',    'engine',     0, N'0 = the engine loop exits at the next iteration (graceful stop).')
    ,('engine_loop_minutes',           N'55',                             'int',    'engine',     0, N'How long one MON - Engine job execution loops before exiting.')
    ,('sample_interval_seconds',       N'30',                             'int',    'engine',     0, N'Blocking sampler interval inside the engine loop.')
    ,('collect_interval_minutes',      N'5',                              'int',    'engine',     0, N'Full collection + evaluation + alert interval.')
    ,('errorlog_interval_minutes',     N'15',                             'int',    'engine',     0, N'How often the RDS error log is read.')
    ,('send_immediate_alerts',         N'1',                              'bit',    'email',      0, N'Master switch for alert mail.')
    ,('send_daily_digest',             N'1',                              'bit',    'email',      0, N'Master switch for the digest.')
    ,('report_hour_local',             N'8',                              'int',    'email',      0, N'Digest hour in display_time_zone. If missed (outage) it is sent later the same day.')
    ,('heartbeat_weekday',             N'1',                              'int',    'email',      0, N'ISO weekday (1=Mon..7=Sun) on which a digest is sent even with no changes. 0 = never.')
    ,('alert_min_severity',            N'CRITICAL',                       'text',   'email',      0, N'CRITICAL or WARNING. Changes below this go to the digest only.')
    ,('alert_on_resolve',              N'1',                              'bit',    'email',      0, N'Send a RESOLVED mail for issues that were alerted.')
    ,('reminder_minutes',              N'0',                              'int',    'email',      0, N'Re-send still-active CRITICAL issues after N minutes. 0 = off (pure change-only).')
    ,('realert_suppress_minutes',      N'60',                             'int',    'email',      0, N'Do not re-alert an escalation of an issue that was alerted CRITICAL within N minutes.')
    ,('email_max_rows_per_section',    N'40',                             'int',    'email',      0, N'Row cap per digest section (keeps mail under Gmail 102 KB clipping).')
    ,('resolve_grace_minutes',         N'10',                             'int',    'issues',     0, N'A state issue must be absent this long before it is RESOLVED (anti-flap).')
    ,('event_lookback_hours',          N'24',                             'int',    'issues',     0, N'Event issues (deadlock, job failure, error log) stay open this long, then EXPIRE silently.')
    ,('history_retention_days',        N'90',                             'int',    'issues',     0, N'Retention for all mon history tables.')
    ,('deadlock_severity',             N'WARNING',                        'text',   'issues',     0, N'Severity of a single deadlock (CRITICAL to alert on every deadlock).')
    ,('deadlock_storm_per_hour',       N'10',                             'int',    'issues',     0, N'Deadlocks in the last hour that raise a CRITICAL DEADLOCK_STORM.')
    ,('full_max_age_minutes',          N'1440',                           'int',    'backup',     0, N'Default FULL SLA for newly discovered databases.')
    ,('diff_max_age_minutes',          N'360',                            'int',    'backup',     0, N'Default DIFF/effective data backup SLA for new databases.')
    ,('log_max_age_minutes',           N'30',                             'int',    'backup',     0, N'Default LOG SLA for new FULL-recovery databases.')
    ,('checkdb_max_age_days',          N'8',                              'int',    'backup',     0, N'Default last-known-good CHECKDB SLA for new databases.')
    ,('rds_task_stuck_hours',          N'4',                              'int',    'backup',     0, N'RDS native backup task CREATED/IN_PROGRESS longer than this = stuck.')
    ,('blocking_capture_min_seconds',  N'15',                             'int',    'blocking',   0, N'Blocked waits shorter than this are ignored by the sampler.')
    ,('blocking_alert_minutes',        N'10',                             'int',    'blocking',   0, N'Blocking episode duration that raises a CRITICAL alert.')
    ,('blocking_max_sample_rows',      N'200',                            'int',    'blocking',   0, N'Max blocked-session rows stored per sample.')
    ,('long_query_warn_minutes',       N'30',                             'int',    'workload',   0, N'Request elapsed time -> WARNING.')
    ,('long_query_crit_minutes',       N'120',                            'int',    'workload',   0, N'Request elapsed time -> CRITICAL.')
    ,('long_query_exclude_agent',      N'1',                              'bit',    'workload',   0, N'Ignore SQL Agent job steps in the long-query check (covered by job duration check).')
    ,('open_tran_warn_minutes',        N'15',                             'int',    'workload',   0, N'Open transaction age -> WARNING.')
    ,('open_tran_crit_minutes',        N'60',                             'int',    'workload',   0, N'Open transaction age -> CRITICAL.')
    ,('job_duration_factor',           N'2.0',                            'decimal','jobs',       0, N'Running job elapsed > factor x 30-day median -> WARNING (2 x factor -> CRITICAL).')
    ,('job_duration_min_minutes',      N'15',                             'int',    'jobs',       0, N'Ignore job duration anomalies below this elapsed time.')
    ,('job_duration_baseline_days',    N'30',                             'int',    'jobs',       0, N'Window for the job duration median.')
    ,('log_used_warn_pct',             N'80',                             'int',    'capacity',   0, N'Transaction log used % -> WARNING.')
    ,('log_used_crit_pct',             N'90',                             'int',    'capacity',   0, N'Transaction log used % -> CRITICAL.')
    ,('storage_free_warn_pct',         N'15',                             'int',    'capacity',   0, N'Volume free % -> WARNING.')
    ,('storage_free_crit_pct',         N'10',                             'int',    'capacity',   0, N'Volume free % -> CRITICAL.')
    ,('file_near_max_pct',             N'90',                             'int',    'capacity',   0, N'File size vs MAXSIZE % -> CRITICAL.')
    ,('vlf_warn_count',                N'1000',                           'int',    'capacity',   0, N'VLF count -> WARNING.')
    ,('tempdb_used_warn_pct',          N'80',                             'int',    'capacity',   0, N'tempdb used % of allocated -> WARNING.')
    ,('cpu_warn_pct',                  N'85',                             'int',    'perf',       0, N'Average SQL CPU over the last 15 minutes -> WARNING.')
    ,('cpu_crit_pct',                  N'95',                             'int',    'perf',       0, N'Average SQL CPU over the last 15 minutes -> CRITICAL.')
    ,('io_latency_warn_ms',            N'50',                             'int',    'perf',       0, N'Average read or write latency per file over the last hour -> WARNING.')
    ,('io_latency_min_ios',            N'1000',                           'int',    'perf',       0, N'Minimum I/Os in the hour before latency is judged.')
    ,('failed_login_warn_per_hour',    N'25',                             'int',    'security',   0, N'Failed logins in the last hour -> WARNING.')
    ,('collector_stale_minutes',       N'15',                             'int',    'self',       0, N'No successful full cycle for N minutes -> CRITICAL (watchdog).')
    ) AS v(setting_name, setting_value, value_type, category, force_update, description)
)
MERGE mon.Setting AS t
USING Seed AS s ON t.setting_name = s.setting_name
WHEN NOT MATCHED BY TARGET THEN
    INSERT (setting_name, setting_value, value_type, category, description)
    VALUES (s.setting_name, s.setting_value, s.value_type, s.category, s.description)
WHEN MATCHED AND (s.force_update = 1 OR t.description <> s.description OR t.category <> s.category) THEN
    UPDATE SET setting_value = CASE WHEN s.force_update = 1 THEN s.setting_value ELSE t.setting_value END,
               description   = s.description,
               category      = s.category,
               modified_utc  = SYSUTCDATETIME(),
               modified_by   = ORIGINAL_LOGIN();
GO

IF OBJECT_ID(N'mon.DatabasePolicy', N'U') IS NULL
BEGIN
    CREATE TABLE mon.DatabasePolicy
    (
        database_name           sysname        NOT NULL CONSTRAINT PK_mon_DatabasePolicy PRIMARY KEY,
        is_monitored            bit            NOT NULL CONSTRAINT DF_mon_DBP_Mon   DEFAULT (1),
        require_full            bit            NOT NULL CONSTRAINT DF_mon_DBP_Full  DEFAULT (1),
        require_diff            bit            NOT NULL CONSTRAINT DF_mon_DBP_Diff  DEFAULT (1),
        require_log             bit            NOT NULL CONSTRAINT DF_mon_DBP_Log   DEFAULT (1),
        require_checkdb         bit            NOT NULL CONSTRAINT DF_mon_DBP_Chk   DEFAULT (1),
        full_max_age_minutes    int            NOT NULL,
        diff_max_age_minutes    int            NOT NULL,
        log_max_age_minutes     int            NOT NULL,
        checkdb_max_age_days    int            NOT NULL,
        notes                   nvarchar(1000) NULL,
        added_utc               datetime2(0)   NOT NULL CONSTRAINT DF_mon_DBP_Added DEFAULT SYSUTCDATETIME(),
        CONSTRAINT CK_mon_DBP_Ages CHECK (full_max_age_minutes > 0 AND diff_max_age_minutes > 0
                                          AND log_max_age_minutes > 0 AND checkdb_max_age_days > 0)
    );
END;
GO

IF OBJECT_ID(N'mon.JobPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE mon.JobPolicy
    (
        job_id                  uniqueidentifier NOT NULL CONSTRAINT PK_mon_JobPolicy PRIMARY KEY,
        job_name                sysname          NOT NULL,
        job_type                varchar(30)      NOT NULL,
        is_monitored            bit              NOT NULL CONSTRAINT DF_mon_JP_Mon  DEFAULT (1),
        max_hours_since_success decimal(9,2)     NOT NULL,
        auto_discovered         bit              NOT NULL CONSTRAINT DF_mon_JP_Auto DEFAULT (1),
        last_seen_utc           datetime2(0)     NOT NULL CONSTRAINT DF_mon_JP_Seen DEFAULT SYSUTCDATETIME(),
        notes                   nvarchar(1000)   NULL,
        CONSTRAINT CK_mon_JP_Age CHECK (max_hours_since_success > 0)
    );
END;
GO

IF OBJECT_ID(N'mon.WaitTypeIgnore', N'U') IS NULL
BEGIN
    CREATE TABLE mon.WaitTypeIgnore
    (
        wait_type nvarchar(60) NOT NULL CONSTRAINT PK_mon_WaitTypeIgnore PRIMARY KEY
    );
END;
GO

/* Benign / idle waits (SQLskills list, trimmed to what matters on 2016-2022 + RDS). */
INSERT mon.WaitTypeIgnore(wait_type)
SELECT v.w
FROM (VALUES
 (N'BROKER_EVENTHANDLER'),(N'BROKER_RECEIVE_WAITFOR'),(N'BROKER_TASK_STOP'),(N'BROKER_TO_FLUSH'),
 (N'BROKER_TRANSMITTER'),(N'CHECKPOINT_QUEUE'),(N'CHKPT'),(N'CLR_AUTO_EVENT'),(N'CLR_MANUAL_EVENT'),
 (N'CLR_SEMAPHORE'),(N'CXCONSUMER'),(N'DBMIRROR_DBM_EVENT'),(N'DBMIRROR_EVENTS_QUEUE'),(N'DBMIRROR_WORKER_QUEUE'),
 (N'DBMIRRORING_CMD'),(N'DIRTY_PAGE_POLL'),(N'DISPATCHER_QUEUE_SEMAPHORE'),(N'EXECSYNC'),(N'FSAGENT'),
 (N'FT_IFTS_SCHEDULER_IDLE_WAIT'),(N'FT_IFTSHC_MUTEX'),(N'HADR_CLUSAPI_CALL'),(N'HADR_FILESTREAM_IOMGR_IOCOMPLETION'),
 (N'HADR_LOGCAPTURE_WAIT'),(N'HADR_NOTIFICATION_DEQUEUE'),(N'HADR_TIMER_TASK'),(N'HADR_WORK_QUEUE'),
 (N'KSOURCE_WAKEUP'),(N'LAZYWRITER_SLEEP'),(N'LOGMGR_QUEUE'),(N'MEMORY_ALLOCATION_EXT'),(N'ONDEMAND_TASK_QUEUE'),
 (N'PARALLEL_REDO_DRAIN_WORKER'),(N'PARALLEL_REDO_LOG_CACHE'),(N'PARALLEL_REDO_TRAN_LIST'),(N'PARALLEL_REDO_WORKER_SYNC'),
 (N'PARALLEL_REDO_WORKER_WAIT_WORK'),(N'PREEMPTIVE_OS_FLUSHFILEBUFFERS'),(N'PREEMPTIVE_XE_GETTARGETSTATE'),
 (N'PVS_PREALLOCATE'),(N'PWAIT_ALL_COMPONENTS_INITIALIZED'),(N'PWAIT_DIRECTLOGCONSUMER_GETNEXT'),
 (N'PWAIT_EXTENSIBILITY_CLEANUP_TASK'),(N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'),(N'QDS_ASYNC_QUEUE'),
 (N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP'),(N'QDS_SHUTDOWN_QUEUE'),(N'REDO_THREAD_PENDING_WORK'),
 (N'REQUEST_FOR_DEADLOCK_SEARCH'),(N'RESOURCE_QUEUE'),(N'SERVER_IDLE_CHECK'),(N'SLEEP_BPOOL_FLUSH'),
 (N'SLEEP_DBSTARTUP'),(N'SLEEP_DCOMSTARTUP'),(N'SLEEP_MASTERDBREADY'),(N'SLEEP_MASTERMDREADY'),
 (N'SLEEP_MASTERUPGRADED'),(N'SLEEP_MSDBSTARTUP'),(N'SLEEP_SYSTEMTASK'),(N'SLEEP_TASK'),(N'SLEEP_TEMPDBSTARTUP'),
 (N'SNI_HTTP_ACCEPT'),(N'SOS_WORK_DISPATCHER'),(N'SP_SERVER_DIAGNOSTICS_SLEEP'),(N'SQLTRACE_BUFFER_FLUSH'),
 (N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP'),(N'SQLTRACE_WAIT_ENTRIES'),(N'UCS_SESSION_REGISTRATION'),
 (N'VDI_CLIENT_OTHER'),(N'WAIT_FOR_RESULTS'),(N'WAITFOR'),(N'WAITFOR_TASKSHUTDOWN'),(N'WAIT_XTP_RECOVERY'),
 (N'WAIT_XTP_HOST_WAIT'),(N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG'),(N'WAIT_XTP_CKPT_CLOSE'),(N'XE_DISPATCHER_JOIN'),
 (N'XE_DISPATCHER_WAIT'),(N'XE_TIMER_EVENT'),(N'XE_LIVE_TARGET_TVF'),(N'BACKUPIO'),(N'BACKUPBUFFER'),
 (N'BACKUPTHREAD')  /* backup waits: RDS log backups every 5 min would dominate the list otherwise */
) AS v(w)
WHERE NOT EXISTS (SELECT 1 FROM mon.WaitTypeIgnore AS i WHERE i.wait_type = v.w);
GO

/* =============================================================================
   SECTION 2  -  COLLECTED STATE & HISTORY  (all *_utc columns are UTC)
   ============================================================================= */

IF OBJECT_ID(N'mon.RdsTask', N'U') IS NULL
BEGIN
    CREATE TABLE mon.RdsTask
    (
        task_id             int            NOT NULL CONSTRAINT PK_mon_RdsTask PRIMARY KEY,
        task_type           nvarchar(128)  NULL,
        database_name       sysname        NULL,
        percent_complete    decimal(9,2)   NULL,
        duration_minutes    int            NULL,
        lifecycle           nvarchar(40)   NULL,
        task_info           nvarchar(max)  NULL,
        last_updated_utc    datetime2(0)   NULL,
        created_utc         datetime2(0)   NULL,
        s3_object_arn       nvarchar(4000) NULL,
        first_collected_utc datetime2(0)   NOT NULL CONSTRAINT DF_mon_RdsTask_F DEFAULT SYSUTCDATETIME(),
        last_collected_utc  datetime2(0)   NOT NULL CONSTRAINT DF_mon_RdsTask_L DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_mon_RdsTask_Db ON mon.RdsTask(database_name, task_type, last_updated_utc DESC);
END;
GO

IF OBJECT_ID(N'mon.TlogBackup', N'U') IS NULL
BEGIN
    CREATE TABLE mon.TlogBackup
    (
        database_name        sysname        NOT NULL,
        rds_backup_seq_id    int            NOT NULL,
        backup_file_time_utc datetime2(0)   NOT NULL,
        starting_lsn         numeric(25,0)  NULL,
        ending_lsn           numeric(25,0)  NULL,
        is_log_chain_broken  bit            NULL,
        file_size_bytes      bigint         NULL,
        collected_utc        datetime2(0)   NOT NULL CONSTRAINT DF_mon_Tlog_C DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_mon_TlogBackup PRIMARY KEY (database_name, rds_backup_seq_id)
    );
    CREATE INDEX IX_mon_TlogBackup_Time ON mon.TlogBackup(database_name, backup_file_time_utc DESC);
END;
GO

IF OBJECT_ID(N'mon.BackupStatus', N'U') IS NULL
BEGIN
    CREATE TABLE mon.BackupStatus
    (
        database_name     sysname        NOT NULL CONSTRAINT PK_mon_BackupStatus PRIMARY KEY,
        collected_utc     datetime2(0)   NOT NULL,
        full_finish_utc   datetime2(0)   NULL,
        full_duration_s   int            NULL,
        full_size_bytes   bigint         NULL,
        full_source       varchar(20)    NULL,
        full_location     nvarchar(1000) NULL,
        diff_finish_utc   datetime2(0)   NULL,
        diff_duration_s   int            NULL,
        diff_size_bytes   bigint         NULL,
        diff_source       varchar(20)    NULL,
        log_finish_utc    datetime2(0)   NULL,
        log_size_bytes    bigint         NULL,
        log_source        varchar(20)    NULL,
        log_chain_broken  bit            NULL,
        note              nvarchar(1000) NULL
    );
END;
GO

IF OBJECT_ID(N'mon.DatabaseStatus', N'U') IS NULL
BEGIN
    CREATE TABLE mon.DatabaseStatus
    (
        database_name            sysname        NOT NULL CONSTRAINT PK_mon_DatabaseStatus PRIMARY KEY,
        database_id              int            NULL,
        is_present               bit            NOT NULL,
        collected_utc            datetime2(0)   NOT NULL,
        state_desc               nvarchar(60)   NULL,
        user_access_desc         nvarchar(60)   NULL,
        is_read_only             bit            NULL,
        recovery_model           nvarchar(60)   NULL,
        compatibility_level      tinyint        NULL,
        owner_name               sysname        NULL,
        page_verify              nvarchar(60)   NULL,
        is_auto_close_on         bit            NULL,
        is_auto_shrink_on        bit            NULL,
        is_rcsi_on               bit            NULL,
        snapshot_isolation       nvarchar(60)   NULL,
        log_reuse_wait_desc      nvarchar(60)   NULL,
        create_date_utc          datetime2(0)   NULL,
        data_size_mb             decimal(19,2)  NULL,
        data_used_mb             decimal(19,2)  NULL,
        log_size_mb              decimal(19,2)  NULL,
        log_used_pct             decimal(9,2)   NULL,
        vlf_total                int            NULL,
        vlf_active               int            NULL,
        log_since_backup_mb      decimal(19,2)  NULL,
        dmv_log_backup_utc       datetime2(0)   NULL,
        last_checkdb_utc         datetime2(0)   NULL,
        qs_desired_state         nvarchar(60)   NULL,
        qs_actual_state          nvarchar(60)   NULL,
        qs_readonly_reason       int            NULL,
        pct_growth_files         int            NULL,
        max_file_pct_of_maxsize  decimal(9,2)   NULL,
        max_file_name            sysname        NULL,
        collection_error         nvarchar(1000) NULL
    );
END;
GO

IF OBJECT_ID(N'mon.DatabaseConfigBaseline', N'U') IS NULL
BEGIN
    CREATE TABLE mon.DatabaseConfigBaseline
    (
        database_name   sysname        NOT NULL,
        property_name   varchar(40)    NOT NULL,
        baseline_value  nvarchar(256)  NULL,
        accepted_utc    datetime2(0)   NOT NULL CONSTRAINT DF_mon_Base_Acc DEFAULT SYSUTCDATETIME(),
        accepted_by     sysname        NOT NULL CONSTRAINT DF_mon_Base_By  DEFAULT ORIGINAL_LOGIN(),
        CONSTRAINT PK_mon_DatabaseConfigBaseline PRIMARY KEY (database_name, property_name)
    );
END;
GO

IF OBJECT_ID(N'mon.AgentJobRun', N'U') IS NULL
BEGIN
    CREATE TABLE mon.AgentJobRun
    (
        job_id          uniqueidentifier NOT NULL,
        instance_id     int              NOT NULL,
        job_name        sysname          NOT NULL,
        run_status      tinyint          NOT NULL,   /* 0 fail, 1 ok, 2 retry, 3 cancel */
        run_start_utc   datetime2(0)     NOT NULL,
        duration_s      int              NOT NULL,
        message         nvarchar(4000)   NULL,
        imported_utc    datetime2(0)     NOT NULL CONSTRAINT DF_mon_AJR_Imp DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_mon_AgentJobRun PRIMARY KEY (job_id, instance_id)
    );
    CREATE INDEX IX_mon_AgentJobRun_Start ON mon.AgentJobRun(job_id, run_start_utc DESC) INCLUDE (run_status, duration_s);
END;
GO

IF OBJECT_ID(N'mon.AgentFailure', N'U') IS NULL
BEGIN
    CREATE TABLE mon.AgentFailure
    (
        job_id            uniqueidentifier NOT NULL,
        instance_id       int              NOT NULL,
        job_name          sysname          NOT NULL,
        run_status        tinyint          NOT NULL,
        run_start_utc     datetime2(0)     NOT NULL,
        duration_s        int              NOT NULL,
        failed_step_id    int              NULL,
        failed_step_name  sysname          NULL,
        message           nvarchar(4000)   NULL,
        collected_utc     datetime2(0)     NOT NULL CONSTRAINT DF_mon_AF_C DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_mon_AgentFailure PRIMARY KEY (job_id, instance_id)
    );
    CREATE INDEX IX_mon_AgentFailure_Time ON mon.AgentFailure(run_start_utc DESC);
END;
GO

IF OBJECT_ID(N'mon.Deadlock', N'U') IS NULL
BEGIN
    CREATE TABLE mon.Deadlock
    (
        deadlock_hash     binary(32)     NOT NULL CONSTRAINT PK_mon_Deadlock PRIMARY KEY,
        event_utc         datetime2(3)   NOT NULL,
        database_name     sysname        NULL,
        process_count     int            NULL,
        victim_login      sysname        NULL,
        victim_host       nvarchar(128)  NULL,
        victim_app        nvarchar(256)  NULL,
        victim_sql        nvarchar(2000) NULL,
        survivor_sql      nvarchar(2000) NULL,
        objects           nvarchar(1000) NULL,
        deadlock_xml      xml            NOT NULL,
        collected_utc     datetime2(0)   NOT NULL CONSTRAINT DF_mon_DL_C DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_mon_Deadlock_Time ON mon.Deadlock(event_utc DESC);
END;
GO

IF OBJECT_ID(N'mon.ErrorLogEvent', N'U') IS NULL
BEGIN
    CREATE TABLE mon.ErrorLogEvent
    (
        event_hash      binary(32)     NOT NULL CONSTRAINT PK_mon_ErrorLogEvent PRIMARY KEY,
        log_utc         datetime2(0)   NOT NULL,
        process_info    nvarchar(100)  NULL,
        error_number    int            NULL,
        severity        varchar(10)    NOT NULL,
        message         nvarchar(4000) NOT NULL,
        collected_utc   datetime2(0)   NOT NULL CONSTRAINT DF_mon_ELE_C DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_mon_ErrorLogEvent_Time ON mon.ErrorLogEvent(log_utc DESC);
END;
GO

IF OBJECT_ID(N'mon.LoginFailure', N'U') IS NULL
BEGIN
    CREATE TABLE mon.LoginFailure
    (
        hour_utc        datetime2(0)   NOT NULL,
        login_name      nvarchar(128)  NOT NULL,
        client_address  nvarchar(64)   NOT NULL,
        reason          nvarchar(200)  NOT NULL,
        failures        int            NOT NULL,
        CONSTRAINT PK_mon_LoginFailure PRIMARY KEY (hour_utc, login_name, client_address, reason)
    );
END;
GO

IF OBJECT_ID(N'mon.PerfSample', N'U') IS NULL
BEGIN
    CREATE TABLE mon.PerfSample
    (
        sample_utc               datetime2(0)  NOT NULL CONSTRAINT PK_mon_PerfSample PRIMARY KEY,
        ple_sec                  bigint        NULL,
        memory_grants_pending    int           NULL,
        batch_requests_total     bigint        NULL,
        user_connections         int           NULL,
        target_mem_mb            bigint        NULL,
        total_mem_mb             bigint        NULL,
        tempdb_size_mb           decimal(19,2) NULL,
        tempdb_used_mb           decimal(19,2) NULL,
        tempdb_version_store_mb  decimal(19,2) NULL,
        tempdb_user_obj_mb       decimal(19,2) NULL,
        tempdb_internal_obj_mb   decimal(19,2) NULL,
        sqlserver_start_utc      datetime2(0)  NULL
    );
END;
GO

IF OBJECT_ID(N'mon.CpuSample', N'U') IS NULL
BEGIN
    CREATE TABLE mon.CpuSample
    (
        sample_utc      datetime2(0) NOT NULL CONSTRAINT PK_mon_CpuSample PRIMARY KEY,
        sql_cpu_pct     tinyint      NOT NULL,
        other_cpu_pct   tinyint      NOT NULL
    );
END;
GO

IF OBJECT_ID(N'mon.StorageSample', N'U') IS NULL
BEGIN
    CREATE TABLE mon.StorageSample
    (
        sample_utc          datetime2(0)  NOT NULL,
        volume_mount_point  nvarchar(256) NOT NULL,
        total_bytes         bigint        NULL,
        available_bytes     bigint        NULL,
        CONSTRAINT PK_mon_StorageSample PRIMARY KEY (sample_utc, volume_mount_point)
    );
END;
GO

IF OBJECT_ID(N'mon.WaitStatsSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE mon.WaitStatsSnapshot
    (
        snapshot_utc    datetime2(0)  NOT NULL,
        wait_type       nvarchar(60)  NOT NULL,
        waiting_tasks   bigint        NOT NULL,
        wait_ms         bigint        NOT NULL,
        signal_ms       bigint        NOT NULL,
        CONSTRAINT PK_mon_WaitStatsSnapshot PRIMARY KEY (snapshot_utc, wait_type)
    );
END;
GO

IF OBJECT_ID(N'mon.FileStatsSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE mon.FileStatsSnapshot
    (
        snapshot_utc       datetime2(0)  NOT NULL,
        database_id        int           NOT NULL,
        file_id            int           NOT NULL,
        database_name      sysname       NULL,
        logical_name       sysname       NULL,
        type_desc          nvarchar(60)  NULL,
        num_reads          bigint        NOT NULL,
        io_stall_read_ms   bigint        NOT NULL,
        num_writes         bigint        NOT NULL,
        io_stall_write_ms  bigint        NOT NULL,
        bytes_read         bigint        NOT NULL,
        bytes_written      bigint        NOT NULL,
        CONSTRAINT PK_mon_FileStatsSnapshot PRIMARY KEY (snapshot_utc, database_id, file_id)
    );
END;
GO

/* ---------- Blocking ---------- */

IF OBJECT_ID(N'mon.BlockingEpisode', N'U') IS NULL
BEGIN
    CREATE TABLE mon.BlockingEpisode
    (
        episode_id           bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_mon_BlockingEpisode PRIMARY KEY,
        head_session_id      smallint       NOT NULL,
        head_login_time      datetime       NOT NULL,   /* identifies the connection */
        blocked_since_utc    datetime2(0)   NOT NULL,   /* earliest wait start seen */
        first_sample_utc     datetime2(0)   NOT NULL,
        last_seen_utc        datetime2(0)   NOT NULL,
        ended_utc            datetime2(0)   NULL,
        is_open              bit            NOT NULL,
        sample_count         int            NOT NULL,
        max_blocked_count    int            NOT NULL,
        max_wait_ms          bigint         NOT NULL,
        head_status          nvarchar(30)   NULL,
        head_login           nvarchar(128)  NULL,
        head_host            nvarchar(128)  NULL,
        head_program         nvarchar(256)  NULL,
        head_database        sysname        NULL,
        head_open_tran_count int            NULL,
        head_tran_begin_utc  datetime2(0)   NULL,
        head_command         nvarchar(32)   NULL,
        head_wait_type       nvarchar(60)   NULL,
        head_sql             nvarchar(4000) NULL,
        head_input_buffer    nvarchar(4000) NULL,
        top_wait_type        nvarchar(60)   NULL,
        top_wait_resource    nvarchar(256)  NULL,
        blocked_sql_sample   nvarchar(2000) NULL,
        databases_affected   nvarchar(1000) NULL
    );
    CREATE INDEX IX_mon_BlockingEpisode_Open ON mon.BlockingEpisode(is_open, head_session_id, head_login_time);
    CREATE INDEX IX_mon_BlockingEpisode_Time ON mon.BlockingEpisode(last_seen_utc DESC);
END;
GO

IF OBJECT_ID(N'mon.BlockingSample', N'U') IS NULL
BEGIN
    CREATE TABLE mon.BlockingSample
    (
        sample_utc           datetime2(0)   NOT NULL,
        episode_id           bigint         NOT NULL,
        session_id           smallint       NOT NULL,
        blocking_session_id  smallint       NOT NULL,
        chain_level          tinyint        NOT NULL,
        wait_type            nvarchar(60)   NULL,
        wait_ms              bigint         NULL,
        wait_resource        nvarchar(256)  NULL,
        database_name        sysname        NULL,
        login_name           nvarchar(128)  NULL,
        host_name            nvarchar(128)  NULL,
        program_name         nvarchar(256)  NULL,
        statement_text       nvarchar(2000) NULL,
        CONSTRAINT PK_mon_BlockingSample PRIMARY KEY (sample_utc, session_id)
    );
    CREATE INDEX IX_mon_BlockingSample_Episode ON mon.BlockingSample(episode_id, sample_utc);
END;
GO

/* =============================================================================
   SECTION 3  -  ISSUE ENGINE, MUTES, NOTIFICATIONS, SELF-HEALTH
   ============================================================================= */

IF OBJECT_ID(N'mon.Issue', N'U') IS NULL
BEGIN
    CREATE TABLE mon.Issue
    (
        issue_id          bigint          IDENTITY(1,1) NOT NULL CONSTRAINT PK_mon_Issue PRIMARY KEY,
        issue_key         nvarchar(400)   NOT NULL,
        category          varchar(40)     NOT NULL,
        severity          varchar(10)     NOT NULL,
        is_event          bit             NOT NULL,
        database_name     sysname         NULL,
        title             nvarchar(400)   NOT NULL,
        detail            nvarchar(4000)  NULL,
        ref_id            bigint          NULL,
        event_utc         datetime2(0)    NULL,
        first_seen_utc    datetime2(0)    NOT NULL,
        last_seen_utc     datetime2(0)    NOT NULL,
        last_critical_utc datetime2(0)    NULL,
        resolved_utc      datetime2(0)    NULL,
        close_type        varchar(10)     NULL,
        is_active         bit             NOT NULL,
        is_muted          bit             NOT NULL CONSTRAINT DF_mon_Issue_Muted DEFAULT (0),
        alert_sent_utc    datetime2(0)    NULL,
        alert_severity    varchar(10)     NULL,
        last_reminder_utc datetime2(0)    NULL,
        CONSTRAINT CK_mon_Issue_Sev CHECK (severity IN ('CRITICAL','WARNING'))
    );
    CREATE UNIQUE INDEX UX_mon_Issue_ActiveKey ON mon.Issue(issue_key) WHERE is_active = 1;
    CREATE INDEX IX_mon_Issue_Active ON mon.Issue(is_active, category) INCLUDE (severity, issue_key, last_seen_utc);
    CREATE INDEX IX_mon_Issue_Resolved ON mon.Issue(resolved_utc) WHERE resolved_utc IS NOT NULL;
END;
GO

IF OBJECT_ID(N'mon.IssueChange', N'U') IS NULL
BEGIN
    CREATE TABLE mon.IssueChange
    (
        change_id        bigint        IDENTITY(1,1) NOT NULL CONSTRAINT PK_mon_IssueChange PRIMARY KEY,
        issue_id         bigint        NOT NULL,
        change_type      varchar(12)   NOT NULL,
        old_severity     varchar(10)   NULL,
        new_severity     varchar(10)   NULL,
        change_utc       datetime2(0)  NOT NULL,
        alert_status     varchar(10)   NULL,        /* NULL = pending, SENT, SKIPPED */
        alert_utc        datetime2(0)  NULL,
        notification_id  bigint        NULL,
        CONSTRAINT CK_mon_IssueChange_Type CHECK (change_type IN ('OPENED','ESCALATED','DEESCALATED','RESOLVED','EXPIRED'))
    );
    CREATE INDEX IX_mon_IssueChange_Pending ON mon.IssueChange(change_id) INCLUDE (issue_id, change_type) WHERE alert_status IS NULL;
    CREATE INDEX IX_mon_IssueChange_Time ON mon.IssueChange(change_utc) INCLUDE (issue_id, change_type);
END;
GO

IF OBJECT_ID(N'mon.IssueMute', N'U') IS NULL
BEGIN
    CREATE TABLE mon.IssueMute
    (
        mute_id       int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_mon_IssueMute PRIMARY KEY,
        key_pattern   nvarchar(400)  NOT NULL,     /* LIKE pattern on issue_key, e.g. N'LONGQ:%' */
        until_utc     datetime2(0)   NOT NULL,
        reason        nvarchar(400)  NOT NULL,
        created_utc   datetime2(0)   NOT NULL CONSTRAINT DF_mon_Mute_C  DEFAULT SYSUTCDATETIME(),
        created_by    sysname        NOT NULL CONSTRAINT DF_mon_Mute_By DEFAULT ORIGINAL_LOGIN()
    );
END;
GO

IF OBJECT_ID(N'mon.Notification', N'U') IS NULL
BEGIN
    CREATE TABLE mon.Notification
    (
        notification_id    bigint          IDENTITY(1,1) NOT NULL CONSTRAINT PK_mon_Notification PRIMARY KEY,
        notification_type  varchar(20)     NOT NULL,   /* ALERT, DIGEST, HEARTBEAT, DIGEST_SKIPPED, WATCHDOG */
        created_utc        datetime2(0)    NOT NULL,
        report_date_local  date            NULL,
        subject            nvarchar(255)   NULL,
        recipients         nvarchar(4000)  NULL,
        mailitem_id        int             NULL,
        send_ok            bit             NULL,
        error_message      nvarchar(2000)  NULL,
        change_count       int             NULL,
        active_critical    int             NULL,
        active_warning     int             NULL,
        body_kb            int             NULL,
        last_change_id     bigint          NULL
    );
    CREATE INDEX IX_mon_Notification_Type ON mon.Notification(notification_type, created_utc DESC);
END;
GO

IF COL_LENGTH(N'mon.Notification', N'last_change_id') IS NULL
    ALTER TABLE mon.Notification ADD last_change_id bigint NULL;
GO

IF OBJECT_ID(N'mon.ComponentStatus', N'U') IS NULL
BEGIN
    CREATE TABLE mon.ComponentStatus
    (
        component_name        varchar(40)    NOT NULL CONSTRAINT PK_mon_ComponentStatus PRIMARY KEY,
        last_attempt_utc      datetime2(3)   NOT NULL,
        last_success_utc      datetime2(3)   NULL,
        last_duration_ms      int            NULL,
        consecutive_failures  int            NOT NULL CONSTRAINT DF_mon_CS_Fail DEFAULT (0),
        last_error_number     int            NULL,
        last_error_message    nvarchar(2000) NULL,
        watermark_utc         datetime2(3)   NULL
    );
END;
GO

IF OBJECT_ID(N'mon.EngineRun', N'U') IS NULL
BEGIN
    CREATE TABLE mon.EngineRun
    (
        engine_run_id      bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_mon_EngineRun PRIMARY KEY,
        started_utc        datetime2(0)   NOT NULL,
        last_heartbeat_utc datetime2(0)   NOT NULL,
        ended_utc          datetime2(0)   NULL,
        iterations         int            NOT NULL CONSTRAINT DF_mon_ER_It DEFAULT (0),
        full_cycles        int            NOT NULL CONSTRAINT DF_mon_ER_Fc DEFAULT (0),
        end_reason         nvarchar(400)  NULL
    );
END;
GO

/* =============================================================================
   SECTION 3b  -  CHECK MATRIX (what is monitored) + BACKUP INVENTORY    [rev 5.1]
   mon.DatabaseCheck  : one row per database, one bit column per check.
                        Edit in SSMS: right-click table > Edit Top 200 Rows,
                        or EXEC mon.usp_SetCheck. Source of truth for on/off.
   mon.ServerCheck    : instance-level checks (one row per check).
   mon.CheckCatalog   : what every check does, which issue keys it owns.
   mon.CheckChangeLog : audit of every change (who / when / old -> new).
   mon.BackupInventoryDaily : daily retention/inventory snapshot per DB/type.
   mon.DatabasePolicy keeps the SLA minutes only; its require_* / is_monitored
   flags are migrated once into mon.DatabaseCheck and no longer read.
   ============================================================================= */

INSERT mon.Setting(setting_name, setting_value, value_type, category, description)
SELECT v.n, v.v, v.t, v.c, v.d
FROM (VALUES
    ('backup_retention_target_days', N'7', 'int', 'backup',
     N'Default number of days of backup history each database must have (per-DB override: mon.DatabaseCheck.retention_days).')
) AS v(n, v, t, c, d)
WHERE NOT EXISTS (SELECT 1 FROM mon.Setting AS s WHERE s.setting_name = v.n);
GO

IF OBJECT_ID(N'mon.CheckCatalog', N'U') IS NULL
BEGIN
    CREATE TABLE mon.CheckCatalog
    (
        check_code     varchar(20)    NOT NULL CONSTRAINT PK_mon_CheckCatalog PRIMARY KEY,
        scope          varchar(10)    NOT NULL,          /* DATABASE | SERVER */
        column_name    sysname        NULL,              /* column in mon.DatabaseCheck (DATABASE scope) */
        key_pattern    nvarchar(100)  NULL,              /* LIKE pattern on mon.Issue.issue_key it owns */
        display_name   nvarchar(60)   NOT NULL,
        description    nvarchar(1000) NOT NULL,
        threshold_info nvarchar(400)  NULL,              /* which mon.Setting rows tune it */
        sort_order     int            NOT NULL,
        CONSTRAINT CK_mon_CheckCatalog_Scope CHECK (scope IN ('DATABASE', 'SERVER'))
    );
END;
GO

;WITH Seed AS
(
    SELECT * FROM (VALUES
    /* code            scope       column                   key pattern          display                  sort description / thresholds */
     ('MONITORED',     'DATABASE', 'monitored',             NULL,                N'Monitored',             10, N'Master switch. OFF = the database is ignored by every check and its open issues are closed silently.', NULL)
    ,('FULL',          'DATABASE', 'full_backup',           N'BACKUP:FULL:%',    N'Full backup',           20, N'Last FULL backup age vs SLA (msdb, RDS native task).', N'DatabasePolicy.full_max_age_minutes')
    ,('DIFF',          'DATABASE', 'diff_backup',           N'BACKUP:DIFF:%',    N'Diff backup',           30, N'Last DIFF or FULL (effective data backup) age vs SLA.', N'DatabasePolicy.diff_max_age_minutes')
    ,('LOG',           'DATABASE', 'log_backup',            N'BACKUP:LOG:%',     N'Log backup',            40, N'Last LOG backup age vs SLA, broken log chain. Not applicable to SIMPLE recovery.', N'DatabasePolicy.log_max_age_minutes')
    ,('RETENTION',     'DATABASE', 'backup_retention',      N'RETENTION:%',      N'Backup retention',      50, N'Backup history depth (days) vs target, no backups of an enabled type, gaps in the chain.', N'DatabaseCheck.retention_days / setting backup_retention_target_days')
    ,('CHECKDB',       'DATABASE', 'checkdb',               N'CHECKDB:%',        N'CHECKDB',               60, N'Last known good DBCC CHECKDB age.', N'DatabasePolicy.checkdb_max_age_days')
    ,('LOGUSED',       'DATABASE', 'log_used',              N'LOGUSED:%',        N'Log used %',            70, N'Transaction log fullness with log_reuse_wait explanation.', N'log_used_warn_pct / log_used_crit_pct')
    ,('VLF',           'DATABASE', 'vlf_count',             N'VLF:%',            N'VLF count',             80, N'Too many virtual log files.', N'vlf_warn_count')
    ,('FILEMAX',       'DATABASE', 'file_near_max',         N'FILEMAX:%',        N'File near MAXSIZE',     90, N'Data/log file close to its MAXSIZE.', N'file_near_max_pct')
    ,('DRIFT',         'DATABASE', 'config_drift',          N'DRIFT:%',          N'Config drift',         100, N'Recovery model, compat level, owner, page verify, RCSI, read-only... changed vs accepted baseline.', N'EXEC mon.usp_AcceptConfigBaseline')
    ,('CONFIG',        'DATABASE', 'config_best_practice',  N'CONFIG:%',         N'Best-practice config', 110, N'AUTO_CLOSE / AUTO_SHRINK ON, PAGE_VERIFY not CHECKSUM.', NULL)
    ,('QSTORE',        'DATABASE', 'query_store',           N'QSTORE:%',         N'Query Store',          120, N'Query Store forced to READ_ONLY (e.g. size limit reached).', NULL)
    ,('BLOCKING',      'DATABASE', 'blocking',              N'BLOCKING:%',       N'Blocking',             130, N'Blocking episode longer than the alert threshold (sampled every 30 s).', N'blocking_alert_minutes')
    ,('LONGQ',         'DATABASE', 'long_queries',          N'LONGQ:%',          N'Long queries',         140, N'Requests running longer than the thresholds.', N'long_query_warn_minutes / long_query_crit_minutes')
    ,('OPENTRAN',      'DATABASE', 'open_trans',            N'OPENTRAN:%',       N'Open transactions',    150, N'Idle or long open transactions (locks, log truncation).', N'open_tran_warn_minutes / open_tran_crit_minutes')
    ,('DEADLOCK',      'DATABASE', 'deadlocks',             N'DEADLOCK:%',       N'Deadlocks',            160, N'Each deadlock from system_health.', N'deadlock_severity')
    ,('IOLAT',         'DATABASE', 'io_latency',            N'IOLAT:%',          N'I/O latency',          170, N'Average read/write latency per file over the last hour.', N'io_latency_warn_ms / io_latency_min_ios')
    ,('DB_STATE',      'SERVER',   NULL,                    N'DBSTATE:%',        N'Database state',       200, N'Database not ONLINE, SINGLE_USER, or dropped.', NULL)
    ,('AGENT_FAIL',    'SERVER',   NULL,                    N'JOBFAIL:%',        N'Agent job failures',   210, N'Any SQL Agent job failed or was cancelled.', N'event_lookback_hours')
    ,('JOB_SLA',       'SERVER',   NULL,                    N'JOBSLA:%',         N'Maintenance job SLA',  220, N'Ola Hallengren / RDS backup jobs: hours since last success, disabled, missing.', N'mon.JobPolicy.max_hours_since_success')
    ,('JOB_LONG',      'SERVER',   NULL,                    N'JOBLONG:%',        N'Job duration anomaly', 230, N'Running job far longer than its 30-day median.', N'job_duration_factor / job_duration_min_minutes')
    ,('RDS_TASKS',     'SERVER',   NULL,                    N'RDS%',             N'RDS native tasks',     240, N'RDS native backup task failed, cancelled or stuck.', N'rds_task_stuck_hours')
    ,('ERRORLOG',      'SERVER',   NULL,                    N'ERRLOG:%',         N'SQL error log',        250, N'High-signal error log entries (823/824/825, 9002, 17883, sev 20+...).', NULL)
    ,('LOGIN_FAIL',    'SERVER',   NULL,                    N'LOGINFAIL',        N'Failed logins',        260, N'Burst of failed logins.', N'failed_login_warn_per_hour')
    ,('DEADLOCK_STORM','SERVER',   NULL,                    N'DEADLOCK_STORM',   N'Deadlock storm',       270, N'Many deadlocks in one hour.', N'deadlock_storm_per_hour')
    ,('CPU',           'SERVER',   NULL,                    N'CPU',              N'CPU',                  280, N'SQL Server CPU 15-minute average.', N'cpu_warn_pct / cpu_crit_pct')
    ,('MEMGRANTS',     'SERVER',   NULL,                    N'MEMGRANTS',        N'Memory grants',        290, N'Memory grants pending in consecutive samples.', NULL)
    ,('TEMPDB',        'SERVER',   NULL,                    N'TEMPDB',           N'tempdb',               300, N'tempdb used % of allocated.', N'tempdb_used_warn_pct')
    ,('STORAGE',       'SERVER',   NULL,                    N'STORAGE:%',        N'Storage',              310, N'SQL-visible volume free space.', N'storage_free_warn_pct / storage_free_crit_pct')
    ,('RESTART',       'SERVER',   NULL,                    N'RESTART:%',        N'Restart / failover',   320, N'SQL Server restarted or failed over.', NULL)
    ,('MAIL',          'SERVER',   NULL,                    N'MAIL:%',           N'Database Mail',        330, N'Database Mail items failed / stuck unsent.', NULL)
    ) AS v(check_code, scope, column_name, key_pattern, display_name, sort_order, description, threshold_info)
)
MERGE mon.CheckCatalog AS t
USING Seed AS s ON t.check_code = s.check_code
WHEN MATCHED THEN UPDATE SET scope = s.scope, column_name = s.column_name, key_pattern = s.key_pattern,
     display_name = s.display_name, description = s.description, threshold_info = s.threshold_info, sort_order = s.sort_order
WHEN NOT MATCHED THEN INSERT (check_code, scope, column_name, key_pattern, display_name, description, threshold_info, sort_order)
     VALUES (s.check_code, s.scope, s.column_name, s.key_pattern, s.display_name, s.description, s.threshold_info, s.sort_order);
GO

SET XACT_ABORT ON;
DECLARE @first_install bit = CASE WHEN OBJECT_ID(N'mon.DatabaseCheck', N'U') IS NULL THEN 1 ELSE 0 END;

IF @first_install = 1
BEGIN
    BEGIN TRANSACTION;   /* create + migrate atomically: a failed migration leaves no empty table behind */
    CREATE TABLE mon.DatabaseCheck
    (
        database_name         sysname        NOT NULL CONSTRAINT PK_mon_DatabaseCheck PRIMARY KEY,
        monitored             bit            NOT NULL CONSTRAINT DF_mon_DC_mon   DEFAULT (1),
        full_backup           bit            NOT NULL CONSTRAINT DF_mon_DC_full  DEFAULT (1),
        diff_backup           bit            NOT NULL CONSTRAINT DF_mon_DC_diff  DEFAULT (1),
        log_backup            bit            NOT NULL CONSTRAINT DF_mon_DC_log   DEFAULT (1),
        backup_retention      bit            NOT NULL CONSTRAINT DF_mon_DC_ret   DEFAULT (1),
        retention_days        int            NULL,     /* NULL = setting backup_retention_target_days */
        checkdb               bit            NOT NULL CONSTRAINT DF_mon_DC_chk   DEFAULT (1),
        log_used              bit            NOT NULL CONSTRAINT DF_mon_DC_logu  DEFAULT (1),
        vlf_count             bit            NOT NULL CONSTRAINT DF_mon_DC_vlf   DEFAULT (1),
        file_near_max         bit            NOT NULL CONSTRAINT DF_mon_DC_fmax  DEFAULT (1),
        config_drift          bit            NOT NULL CONSTRAINT DF_mon_DC_drift DEFAULT (1),
        config_best_practice  bit            NOT NULL CONSTRAINT DF_mon_DC_cfg   DEFAULT (1),
        query_store           bit            NOT NULL CONSTRAINT DF_mon_DC_qs    DEFAULT (1),
        blocking              bit            NOT NULL CONSTRAINT DF_mon_DC_blk   DEFAULT (1),
        long_queries          bit            NOT NULL CONSTRAINT DF_mon_DC_lq    DEFAULT (1),
        open_trans            bit            NOT NULL CONSTRAINT DF_mon_DC_ot    DEFAULT (1),
        deadlocks             bit            NOT NULL CONSTRAINT DF_mon_DC_dl    DEFAULT (1),
        io_latency            bit            NOT NULL CONSTRAINT DF_mon_DC_io    DEFAULT (1),
        notes                 nvarchar(400)  NULL,
        modified_utc          datetime2(0)   NOT NULL CONSTRAINT DF_mon_DC_mod   DEFAULT SYSUTCDATETIME(),
        modified_by           sysname        NOT NULL CONSTRAINT DF_mon_DC_by    DEFAULT ORIGINAL_LOGIN(),
        CONSTRAINT CK_mon_DC_Retention CHECK (retention_days IS NULL OR retention_days BETWEEN 1 AND 3650)
    );

    /* One-time migration of the rev 5.0 flags from mon.DatabasePolicy. */
    INSERT mon.DatabaseCheck(database_name, monitored, full_backup, diff_backup, log_backup, checkdb, notes)
    SELECT p.database_name, p.is_monitored, p.require_full, p.require_diff,
           CASE WHEN EXISTS (SELECT 1 FROM sys.databases AS d
                             WHERE d.name = p.database_name AND d.recovery_model_desc <> N'FULL')
                THEN 1 ELSE p.require_log END,   /* SIMPLE today: keep ON so a later switch to FULL is watched */
           p.require_checkdb, LEFT(p.notes, 400)
    FROM mon.DatabasePolicy AS p;
    COMMIT;
END;
GO

IF COL_LENGTH(N'mon.DatabaseCheck', N'storage_retention_days') IS NULL
    ALTER TABLE mon.DatabaseCheck ADD storage_retention_days int NULL;   /* declared file lifecycle on storage (days) [5.2] */
GO

IF OBJECT_ID(N'mon.ServerCheck', N'U') IS NULL
BEGIN
    CREATE TABLE mon.ServerCheck
    (
        check_code    varchar(20)   NOT NULL CONSTRAINT PK_mon_ServerCheck PRIMARY KEY,
        display_name  nvarchar(60)  NOT NULL,
        is_enabled    bit           NOT NULL CONSTRAINT DF_mon_SC_en  DEFAULT (1),
        notes         nvarchar(400) NULL,
        modified_utc  datetime2(0)  NOT NULL CONSTRAINT DF_mon_SC_mod DEFAULT SYSUTCDATETIME(),
        modified_by   sysname       NOT NULL CONSTRAINT DF_mon_SC_by  DEFAULT ORIGINAL_LOGIN()
    );
END;
GO

INSERT mon.ServerCheck(check_code, display_name)
SELECT c.check_code, c.display_name
FROM mon.CheckCatalog AS c
WHERE c.scope = 'SERVER'
  AND NOT EXISTS (SELECT 1 FROM mon.ServerCheck AS s WHERE s.check_code = c.check_code);

UPDATE s SET s.display_name = c.display_name
FROM mon.ServerCheck AS s JOIN mon.CheckCatalog AS c ON c.check_code = s.check_code
WHERE s.display_name <> c.display_name;
GO

IF OBJECT_ID(N'mon.CheckChangeLog', N'U') IS NULL
BEGIN
    CREATE TABLE mon.CheckChangeLog
    (
        change_log_id  bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_mon_CheckChangeLog PRIMARY KEY,
        changed_utc    datetime2(0)   NOT NULL CONSTRAINT DF_mon_CCL_utc DEFAULT SYSUTCDATETIME(),
        changed_by     sysname        NOT NULL CONSTRAINT DF_mon_CCL_by  DEFAULT ORIGINAL_LOGIN(),
        host_name      nvarchar(128)  NULL     CONSTRAINT DF_mon_CCL_host DEFAULT HOST_NAME(),
        object_name    varchar(40)    NOT NULL,     /* DatabaseCheck | ServerCheck | Setting | DatabasePolicy */
        item_name      nvarchar(128)  NOT NULL,     /* database name, check code or setting name */
        property_name  nvarchar(128)  NOT NULL,
        old_value      nvarchar(4000) NULL,
        new_value      nvarchar(4000) NULL
    );
    CREATE INDEX IX_mon_CheckChangeLog_Time ON mon.CheckChangeLog(changed_utc DESC);
END;
GO

IF OBJECT_ID(N'mon.BackupInventoryDaily', N'U') IS NULL
BEGIN
    CREATE TABLE mon.BackupInventoryDaily
    (
        snapshot_date     date           NOT NULL,
        database_name     sysname        NOT NULL,
        backup_type       varchar(4)     NOT NULL,     /* FULL | DIFF | LOG */
        status            varchar(10)    NOT NULL,     /* OK | GAPS | SHORT | NONE | OFF | N/A */
        source_name       varchar(20)    NULL,
        backup_count      int            NOT NULL,
        oldest_utc        datetime2(0)   NULL,
        newest_utc        datetime2(0)   NULL,
        retention_days    decimal(9,1)   NULL,
        target_days       int            NULL,
        gaps              int            NULL,
        avg_interval_min  int            NULL,
        avg_bytes         bigint         NULL,
        total_bytes       bigint         NULL,
        captured_utc      datetime2(0)   NOT NULL CONSTRAINT DF_mon_BID_c DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_mon_BackupInventoryDaily PRIMARY KEY (snapshot_date, database_name, backup_type)
    );
END;
GO

/* ---------- Audit triggers: every checkbox / setting change is logged ---------- */

CREATE OR ALTER TRIGGER mon.trg_DatabaseCheck_Audit
ON mon.DatabaseCheck
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF TRIGGER_NESTLEVEL(@@PROCID) > 1 RETURN;

    INSERT mon.CheckChangeLog(object_name, item_name, property_name, old_value, new_value)
    SELECT 'DatabaseCheck', i.database_name, v.col, v.old_v, v.new_v
    FROM inserted AS i
    JOIN deleted AS d ON d.database_name = i.database_name
    CROSS APPLY (VALUES
        (N'monitored',            CONVERT(nvarchar(20), d.monitored),            CONVERT(nvarchar(20), i.monitored)),
        (N'full_backup',          CONVERT(nvarchar(20), d.full_backup),          CONVERT(nvarchar(20), i.full_backup)),
        (N'diff_backup',          CONVERT(nvarchar(20), d.diff_backup),          CONVERT(nvarchar(20), i.diff_backup)),
        (N'log_backup',           CONVERT(nvarchar(20), d.log_backup),           CONVERT(nvarchar(20), i.log_backup)),
        (N'backup_retention',     CONVERT(nvarchar(20), d.backup_retention),     CONVERT(nvarchar(20), i.backup_retention)),
        (N'retention_days',       CONVERT(nvarchar(20), d.retention_days),       CONVERT(nvarchar(20), i.retention_days)),
        (N'storage_retention_days', CONVERT(nvarchar(20), d.storage_retention_days), CONVERT(nvarchar(20), i.storage_retention_days)),
        (N'checkdb',              CONVERT(nvarchar(20), d.checkdb),              CONVERT(nvarchar(20), i.checkdb)),
        (N'log_used',             CONVERT(nvarchar(20), d.log_used),             CONVERT(nvarchar(20), i.log_used)),
        (N'vlf_count',            CONVERT(nvarchar(20), d.vlf_count),            CONVERT(nvarchar(20), i.vlf_count)),
        (N'file_near_max',        CONVERT(nvarchar(20), d.file_near_max),        CONVERT(nvarchar(20), i.file_near_max)),
        (N'config_drift',         CONVERT(nvarchar(20), d.config_drift),         CONVERT(nvarchar(20), i.config_drift)),
        (N'config_best_practice', CONVERT(nvarchar(20), d.config_best_practice), CONVERT(nvarchar(20), i.config_best_practice)),
        (N'query_store',          CONVERT(nvarchar(20), d.query_store),          CONVERT(nvarchar(20), i.query_store)),
        (N'blocking',             CONVERT(nvarchar(20), d.blocking),             CONVERT(nvarchar(20), i.blocking)),
        (N'long_queries',         CONVERT(nvarchar(20), d.long_queries),         CONVERT(nvarchar(20), i.long_queries)),
        (N'open_trans',           CONVERT(nvarchar(20), d.open_trans),           CONVERT(nvarchar(20), i.open_trans)),
        (N'deadlocks',            CONVERT(nvarchar(20), d.deadlocks),            CONVERT(nvarchar(20), i.deadlocks)),
        (N'io_latency',           CONVERT(nvarchar(20), d.io_latency),           CONVERT(nvarchar(20), i.io_latency)),
        (N'notes',                CONVERT(nvarchar(400), d.notes),               CONVERT(nvarchar(400), i.notes))
    ) AS v(col, old_v, new_v)
    WHERE ISNULL(v.old_v, N'~') <> ISNULL(v.new_v, N'~');

    UPDATE t SET modified_utc = SYSUTCDATETIME(), modified_by = ORIGINAL_LOGIN()
    FROM mon.DatabaseCheck AS t JOIN inserted AS i ON i.database_name = t.database_name;
END;
GO

CREATE OR ALTER TRIGGER mon.trg_ServerCheck_Audit
ON mon.ServerCheck
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF TRIGGER_NESTLEVEL(@@PROCID) > 1 RETURN;

    INSERT mon.CheckChangeLog(object_name, item_name, property_name, old_value, new_value)
    SELECT 'ServerCheck', i.check_code, v.col, v.old_v, v.new_v
    FROM inserted AS i
    JOIN deleted AS d ON d.check_code = i.check_code
    CROSS APPLY (VALUES
        (N'is_enabled', CONVERT(nvarchar(20), d.is_enabled), CONVERT(nvarchar(20), i.is_enabled)),
        (N'notes',      CONVERT(nvarchar(400), d.notes),     CONVERT(nvarchar(400), i.notes))
    ) AS v(col, old_v, new_v)
    WHERE ISNULL(v.old_v, N'~') <> ISNULL(v.new_v, N'~');

    UPDATE t SET modified_utc = SYSUTCDATETIME(), modified_by = ORIGINAL_LOGIN()
    FROM mon.ServerCheck AS t JOIN inserted AS i ON i.check_code = t.check_code;
END;
GO

CREATE OR ALTER TRIGGER mon.trg_Setting_Audit
ON mon.Setting
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT mon.CheckChangeLog(object_name, item_name, property_name, old_value, new_value)
    SELECT 'Setting', i.setting_name, N'setting_value', d.setting_value, i.setting_value
    FROM inserted AS i
    JOIN deleted AS d ON d.setting_name = i.setting_name
    WHERE d.setting_value <> i.setting_value;
END;
GO

CREATE OR ALTER TRIGGER mon.trg_DatabasePolicy_Audit
ON mon.DatabasePolicy
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT mon.CheckChangeLog(object_name, item_name, property_name, old_value, new_value)
    SELECT 'DatabasePolicy', i.database_name, v.col, v.old_v, v.new_v
    FROM inserted AS i
    JOIN deleted AS d ON d.database_name = i.database_name
    CROSS APPLY (VALUES
        (N'full_max_age_minutes', CONVERT(nvarchar(20), d.full_max_age_minutes), CONVERT(nvarchar(20), i.full_max_age_minutes)),
        (N'diff_max_age_minutes', CONVERT(nvarchar(20), d.diff_max_age_minutes), CONVERT(nvarchar(20), i.diff_max_age_minutes)),
        (N'log_max_age_minutes',  CONVERT(nvarchar(20), d.log_max_age_minutes),  CONVERT(nvarchar(20), i.log_max_age_minutes)),
        (N'checkdb_max_age_days', CONVERT(nvarchar(20), d.checkdb_max_age_days), CONVERT(nvarchar(20), i.checkdb_max_age_days))
    ) AS v(col, old_v, new_v)
    WHERE ISNULL(v.old_v, N'~') <> ISNULL(v.new_v, N'~');
END;
GO

/* Flat (unpivoted) view of the matrix: one row per database and check. */
CREATE OR ALTER VIEW mon.vw_DatabaseCheckFlat
AS
SELECT c.database_name, c.monitored, v.check_code, v.is_enabled
FROM mon.DatabaseCheck AS c
CROSS APPLY (VALUES
    ('FULL', c.full_backup), ('DIFF', c.diff_backup), ('LOG', c.log_backup), ('RETENTION', c.backup_retention),
    ('CHECKDB', c.checkdb), ('LOGUSED', c.log_used), ('VLF', c.vlf_count), ('FILEMAX', c.file_near_max),
    ('DRIFT', c.config_drift), ('CONFIG', c.config_best_practice), ('QSTORE', c.query_store),
    ('BLOCKING', c.blocking), ('LONGQ', c.long_queries), ('OPENTRAN', c.open_trans),
    ('DEADLOCK', c.deadlocks), ('IOLAT', c.io_latency)
) AS v(check_code, is_enabled);
GO

/* Is the check that owns this issue key enabled for this database / instance? */
CREATE OR ALTER FUNCTION mon.fn_IsCheckEnabled(@issue_key nvarchar(400), @database_name sysname)
RETURNS bit
AS
BEGIN
    DECLARE @code varchar(20), @scope varchar(10);

    SELECT TOP (1) @code = c.check_code, @scope = c.scope
    FROM mon.CheckCatalog AS c
    WHERE c.key_pattern IS NOT NULL AND @issue_key LIKE c.key_pattern
    ORDER BY LEN(c.key_pattern) DESC;

    IF @code IS NULL RETURN 1;                        /* self-health etc.: never switchable */

    /* An unmonitored database produces nothing at all - database AND server-level issues about it. */
    IF @database_name IS NOT NULL
       AND EXISTS (SELECT 1 FROM mon.DatabaseCheck AS d WHERE d.database_name = @database_name AND d.monitored = 0)
        RETURN 0;

    IF @scope = 'SERVER'
        RETURN ISNULL((SELECT s.is_enabled FROM mon.ServerCheck AS s WHERE s.check_code = @code), 1);

    RETURN ISNULL((SELECT f.is_enabled FROM mon.vw_DatabaseCheckFlat AS f
                   WHERE f.database_name = @database_name AND f.check_code = @code), 1);
END;
GO

/* =============================================================================
   SECTION 3c  -  OLA HALLENGREN COMMANDLOG + BACKUP FILE / STORAGE TRACKING  [rev 5.2]
   ============================================================================= */

INSERT mon.Setting(setting_name, setting_value, value_type, category, description)
SELECT v.n, v.v, v.t, v.c, v.d
FROM (VALUES
    ('ola_commandlog_database', N'', 'text', 'ola',
     N'Database that holds Ola Hallengren dbo.CommandLog. Empty = auto-discover (every online database + master, re-checked hourly).'),
    ('ola_initial_load_days', N'35', 'int', 'ola',
     N'How many days of CommandLog history are imported on the first run.'),
    ('backup_storage_retention_days', N'', 'text', 'backup',
     N'DECLARED lifecycle of backup files on storage (S3 lifecycle rule / Ola @CleanupTime in days). Empty = not declared. Per-DB override: mon.DatabaseCheck.storage_retention_days. Used to estimate how many files are still on storage.')
) AS v(n, v, t, c, d)
WHERE NOT EXISTS (SELECT 1 FROM mon.Setting AS s WHERE s.setting_name = v.n);
GO

IF COL_LENGTH(N'mon.TlogBackup', N'last_seen_utc') IS NULL
    ALTER TABLE mon.TlogBackup ADD last_seen_utc datetime2(0) NULL;       /* last time RDS still listed the file */
GO
IF COL_LENGTH(N'mon.BackupInventoryDaily', N'files_total') IS NULL
    ALTER TABLE mon.BackupInventoryDaily ADD files_total int NULL, files_24h int NULL, files_on_storage int NULL,
                                             storage_days int NULL, storage_basis varchar(20) NULL;
GO
IF COL_LENGTH(N'mon.DatabaseStatus', N'checkdb_source') IS NULL
    ALTER TABLE mon.DatabaseStatus ADD checkdb_source varchar(20) NULL;   /* DBPROPERTY | DBINFO */
GO

MERGE mon.CheckCatalog AS t
USING (VALUES ('OLA_LOG', 'SERVER', CONVERT(sysname, NULL), N'OLAFAIL:%', N'Ola CommandLog errors', 245,
               N'Failed commands in Ola Hallengren dbo.CommandLog (backup, DBCC CHECKDB, index/statistics maintenance, cleanup).',
               N'ola_commandlog_database')) AS s(check_code, scope, column_name, key_pattern, display_name, sort_order, description, threshold_info)
ON t.check_code = s.check_code
WHEN MATCHED THEN UPDATE SET scope = s.scope, key_pattern = s.key_pattern, display_name = s.display_name,
     sort_order = s.sort_order, description = s.description, threshold_info = s.threshold_info
WHEN NOT MATCHED THEN INSERT (check_code, scope, column_name, key_pattern, display_name, description, threshold_info, sort_order)
     VALUES (s.check_code, s.scope, s.column_name, s.key_pattern, s.display_name, s.description, s.threshold_info, s.sort_order);

INSERT mon.ServerCheck(check_code, display_name)
SELECT c.check_code, c.display_name FROM mon.CheckCatalog AS c
WHERE c.scope = 'SERVER' AND NOT EXISTS (SELECT 1 FROM mon.ServerCheck AS s WHERE s.check_code = c.check_code);
GO

IF OBJECT_ID(N'mon.OlaSource', N'U') IS NULL
BEGIN
    CREATE TABLE mon.OlaSource
    (
        database_name   sysname       NOT NULL CONSTRAINT PK_mon_OlaSource PRIMARY KEY,
        last_id         bigint        NOT NULL CONSTRAINT DF_mon_OlaSrc_Id DEFAULT (0),
        discovered_utc  datetime2(0)  NOT NULL CONSTRAINT DF_mon_OlaSrc_D  DEFAULT SYSUTCDATETIME(),
        last_read_utc   datetime2(0)  NULL,
        is_active       bit           NOT NULL CONSTRAINT DF_mon_OlaSrc_A  DEFAULT (1)
    );
END;
GO

IF OBJECT_ID(N'mon.OlaCommand', N'U') IS NULL
BEGIN
    CREATE TABLE mon.OlaCommand
    (
        source_db        sysname        NOT NULL,
        ola_id           bigint         NOT NULL,
        database_name    sysname        NULL,
        command_type     nvarchar(60)   NOT NULL,
        object_name      nvarchar(300)  NULL,
        index_name       sysname        NULL,
        statistics_name  sysname        NULL,
        command          nvarchar(4000) NULL,
        backup_type      varchar(4)     NULL,      /* FULL | DIFF | LOG for BACKUP_* commands */
        backup_file      nvarchar(1000) NULL,      /* first target file / URL */
        file_count       int            NULL,      /* number of DISK= / URL= targets */
        start_utc        datetime2(0)   NOT NULL,
        end_utc          datetime2(0)   NULL,
        duration_s       int            NULL,
        error_number     int            NULL,
        error_message    nvarchar(2000) NULL,
        collected_utc    datetime2(0)   NOT NULL CONSTRAINT DF_mon_OlaCmd_C DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_mon_OlaCommand PRIMARY KEY (source_db, ola_id)
    );
    CREATE INDEX IX_mon_OlaCommand_Type ON mon.OlaCommand(command_type, start_utc DESC) INCLUDE (database_name, error_number, end_utc);
    CREATE INDEX IX_mon_OlaCommand_Db   ON mon.OlaCommand(database_name, command_type, end_utc DESC) INCLUDE (error_number);
END;
GO

/* =============================================================================
   SECTION 4  -  HELPER FUNCTIONS  (formatting, time, HTML building blocks)
   All HTML is inline-styled and table-based for Outlook desktop (Word engine),
   Outlook web/mobile, Gmail and Apple Mail. The file is pure ASCII on purpose:
   special characters are emitted as HTML entities.
   ============================================================================= */

CREATE OR ALTER FUNCTION mon.fn_Setting(@name varchar(64))
RETURNS nvarchar(4000)
AS
BEGIN
    RETURN (SELECT s.setting_value FROM mon.Setting AS s WHERE s.setting_name = @name);
END;
GO

CREATE OR ALTER FUNCTION mon.fn_SettingInt(@name varchar(64))
RETURNS int
AS
BEGIN
    RETURN (SELECT TRY_CONVERT(int, s.setting_value) FROM mon.Setting AS s WHERE s.setting_name = @name);
END;
GO

CREATE OR ALTER FUNCTION mon.fn_ServerToUtc(@dt datetime2(3))
RETURNS datetime2(3)
AS
BEGIN
    /* Server-local (GETDATE-based) value -> UTC using the current server offset.
       RDS instances run in UTC unless a time zone was chosen at creation. */
    RETURN CASE WHEN @dt IS NULL THEN NULL
                ELSE DATEADD(MINUTE, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), @dt) END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_UtcToLocal(@utc datetime2(3), @tz nvarchar(100))
RETURNS datetime2(0)
AS
BEGIN
    RETURN CASE WHEN @utc IS NULL THEN NULL
                ELSE CONVERT(datetime2(0), (@utc AT TIME ZONE 'UTC') AT TIME ZONE @tz) END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_FmtLocal(@utc datetime2(3), @tz nvarchar(100))
RETURNS nvarchar(20)
AS
BEGIN
    /* 'MM-DD HH:MM' in the display time zone. */
    RETURN CASE WHEN @utc IS NULL THEN N'never'
                ELSE SUBSTRING(CONVERT(nvarchar(16), mon.fn_UtcToLocal(@utc, @tz), 120), 6, 11) END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Duration(@seconds bigint)
RETURNS nvarchar(20)
AS
BEGIN
    IF @seconds IS NULL RETURN N'-';
    IF @seconds < 0 SET @seconds = 0;
    RETURN CASE
        WHEN @seconds < 60    THEN CONCAT(@seconds, N's')
        WHEN @seconds < 3600  THEN CONCAT(@seconds / 60, N'm')
        WHEN @seconds < 86400 THEN CONCAT(@seconds / 3600, N'h ', RIGHT(CONCAT(N'0', (@seconds % 3600) / 60), 2), N'm')
        ELSE CONCAT(@seconds / 86400, N'd ', RIGHT(CONCAT(N'0', (@seconds % 86400) / 3600), 2), N'h')
    END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_HtmlEncode(@value nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    IF @value IS NULL RETURN N'';
    SET @value = REPLACE(@value, N'&', N'&amp;');
    SET @value = REPLACE(@value, N'<', N'&lt;');
    SET @value = REPLACE(@value, N'>', N'&gt;');
    SET @value = REPLACE(@value, N'"', N'&quot;');
    SET @value = REPLACE(@value, N'''', N'&#39;');
    RETURN @value;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_OneLine(@value nvarchar(max), @max_len int)
RETURNS nvarchar(max)
AS
BEGIN
    /* Collapse whitespace of SQL text / messages and truncate, then HTML-encode. */
    IF @value IS NULL RETURN N'';
    SET @value = REPLACE(REPLACE(REPLACE(@value, NCHAR(13), N' '), NCHAR(10), N' '), NCHAR(9), N' ');
    WHILE CHARINDEX(N'  ', @value) > 0 SET @value = REPLACE(@value, N'  ', N' ');
    SET @value = LTRIM(RTRIM(@value));
    RETURN mon.fn_HtmlEncode(LEFT(@value, @max_len))
         + CASE WHEN LEN(@value) > @max_len THEN N'&#8230;' ELSE N'' END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_SevLevel(@severity varchar(10))
RETURNS varchar(4)
AS
BEGIN
    RETURN CASE @severity WHEN 'CRITICAL' THEN 'CRIT' WHEN 'WARNING' THEN 'WARN' ELSE 'INFO' END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Pill(@text nvarchar(200), @level varchar(4))
RETURNS nvarchar(max)
AS
BEGIN
    /* Colored status badge. Levels: CRIT, WARN, OK, INFO, NA, MUTE */
    DECLARE @bg varchar(7), @fg varchar(7);
    SELECT @bg = CASE @level WHEN 'CRIT' THEN '#DC2626' WHEN 'WARN' THEN '#F59E0B' WHEN 'OK' THEN '#16A34A'
                              WHEN 'INFO' THEN '#2563EB' WHEN 'MUTE' THEN '#9CA3AF' ELSE '#E5E7EB' END,
           @fg = CASE @level WHEN 'WARN' THEN '#111827' WHEN 'NA' THEN '#374151' ELSE '#FFFFFF' END;
    RETURN CONCAT(N'<span style="display:inline-block;padding:1px 7px;border-radius:9px;font-size:10px;',
                  N'font-weight:700;letter-spacing:.3px;white-space:nowrap;background:', @bg, N';color:', @fg, N'">',
                  mon.fn_HtmlEncode(@text), N'</span>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Td(@html nvarchar(max), @level varchar(4))
RETURNS nvarchar(max)
AS
BEGIN
    /* Table cell. Base style comes from the td.c class in the email <style> block (keeps the
       digest under Gmail's ~102 KB clipping limit); anomalies add bgcolor (Outlook) + inline tint. */
    DECLARE @bg varchar(7) = CASE @level WHEN 'CRIT' THEN '#FEE2E2' WHEN 'WARN' THEN '#FEF3C7'
                                         WHEN 'OK' THEN '#F0FDF4' ELSE NULL END;
    IF @bg IS NULL
        RETURN CONCAT(CONVERT(nvarchar(max), N'<td class="c" valign="top">'), @html, N'</td>');
    RETURN CONCAT(CONVERT(nvarchar(max), N'<td class="c" valign="top" bgcolor="'), @bg, N'" style="background:', @bg,
                  N';color:', CASE @level WHEN 'CRIT' THEN '#7F1D1D' WHEN 'WARN' THEN '#78350F' ELSE '#14532D' END,
                  N'">', @html, N'</td>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Small(@html nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    RETURN CONCAT(CONVERT(nvarchar(max), N'<span style="font-size:11px;font-weight:400;color:#6B7280">'), @html, N'</span>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Nw(@html nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    /* no-wrap wrapper for short values (times, sizes) */
    RETURN CONCAT(CONVERT(nvarchar(max), N'<span style="white-space:nowrap">'), @html, N'</span>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Section(@title nvarchar(200), @subtitle nvarchar(1000), @header_cells nvarchar(max), @rows nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    /* One titled table section of the email. @header_cells = pipe separated column names. */
    DECLARE @th nvarchar(max) = N'', @rest nvarchar(max) = @header_cells + N'|', @pos int, @col nvarchar(200);
    /* Ordered split without STRING_SPLIT (order not guaranteed, needs compat 130). */
    SET @pos = CHARINDEX(N'|', @rest);
    WHILE @pos > 0
    BEGIN
        SET @col = LTRIM(RTRIM(LEFT(@rest, @pos - 1)));
        SET @rest = SUBSTRING(@rest, @pos + 1, 4000);
        SET @th += N'<th class="h" align="left" bgcolor="#1E3A5F" style="color:#FFFFFF">' + mon.fn_HtmlEncode(@col) + N'</th>';
        SET @pos = CHARINDEX(N'|', @rest);
    END;

    RETURN CONCAT(
        N'<tr><td style="padding:18px 24px 4px 24px">',
        N'<div style="font-size:15px;font-weight:700;color:#0F172A;margin:0">', mon.fn_HtmlEncode(@title), N'</div>',
        CASE WHEN @subtitle IS NOT NULL AND @subtitle <> N''
             THEN CONCAT(N'<div style="font-size:11px;color:#6B7280;margin:2px 0 6px 0">', @subtitle, N'</div>')
             ELSE N'<div style="height:6px;line-height:6px;font-size:6px">&nbsp;</div>' END,
        N'<table role="presentation" width="100%" cellpadding="5" cellspacing="0" border="0" ',
        N'style="border-collapse:collapse;border:1px solid #E5E7EB;font-family:Segoe UI,Arial,Helvetica,sans-serif">',
        N'<tr>', @th, N'</tr>', @rows, N'</table></td></tr>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_EmptyRow(@colspan int, @text nvarchar(400))
RETURNS nvarchar(max)
AS
BEGIN
    RETURN CONCAT(CONVERT(nvarchar(max), N'<tr><td colspan="'), @colspan, N'" bgcolor="#F0FDF4" style="padding:8px;font-size:12px;color:#166534;background:#F0FDF4">',
                  N'&#10003; ', mon.fn_HtmlEncode(@text), N'</td></tr>');
END;
GO

/* =============================================================================
   SECTION 5  -  COMPONENT STATUS (self-monitoring of every collector)
   ============================================================================= */

CREATE OR ALTER PROCEDURE mon.usp_SetComponentStatus
    @Component    varchar(40),
    @Succeeded    bit,
    @StartedUtc   datetime2(3) = NULL,
    @ErrorNumber  int = NULL,
    @ErrorMessage nvarchar(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(3) = SYSUTCDATETIME();
    DECLARE @ms int = CASE WHEN @StartedUtc IS NULL THEN NULL ELSE DATEDIFF(MILLISECOND, @StartedUtc, @now) END;

    UPDATE mon.ComponentStatus
       SET last_attempt_utc     = @now,
           last_success_utc     = CASE WHEN @Succeeded = 1 THEN @now ELSE last_success_utc END,
           last_duration_ms     = @ms,
           consecutive_failures = CASE WHEN @Succeeded = 1 THEN 0 ELSE consecutive_failures + 1 END,
           last_error_number    = CASE WHEN @Succeeded = 1 THEN NULL ELSE @ErrorNumber END,
           last_error_message   = CASE WHEN @Succeeded = 1 THEN NULL ELSE LEFT(@ErrorMessage, 2000) END
     WHERE component_name = @Component;

    IF @@ROWCOUNT = 0
        INSERT mon.ComponentStatus(component_name, last_attempt_utc, last_success_utc, last_duration_ms,
                                   consecutive_failures, last_error_number, last_error_message)
        VALUES (@Component, @now, CASE WHEN @Succeeded = 1 THEN @now END, @ms,
                CASE WHEN @Succeeded = 1 THEN 0 ELSE 1 END,
                CASE WHEN @Succeeded = 0 THEN @ErrorNumber END,
                CASE WHEN @Succeeded = 0 THEN LEFT(@ErrorMessage, 2000) END);
END;
GO

/* =============================================================================
   SECTION 6  -  COLLECTORS
   Every collector is independent, runs with LOCK_TIMEOUT + DEADLOCK_PRIORITY LOW,
   records its own success/failure in mon.ComponentStatus and never throws to
   the engine. Version/RDS-specific objects are referenced through dynamic SQL
   so a missing object is a catchable runtime error, not a compile failure.
   ============================================================================= */

CREATE OR ALTER PROCEDURE mon.usp_SyncPolicies
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    BEGIN TRY
        /* New user databases get default policy; existing rows are never overwritten. */
        INSERT mon.DatabasePolicy
            (database_name, require_log, full_max_age_minutes, diff_max_age_minutes,
             log_max_age_minutes, checkdb_max_age_days)
        SELECT d.name,
               CASE WHEN d.recovery_model_desc = N'FULL' THEN 1 ELSE 0 END,
               ISNULL(mon.fn_SettingInt('full_max_age_minutes'), 1440),
               ISNULL(mon.fn_SettingInt('diff_max_age_minutes'), 360),
               ISNULL(mon.fn_SettingInt('log_max_age_minutes'), 30),
               ISNULL(mon.fn_SettingInt('checkdb_max_age_days'), 8)
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.name <> N'rdsadmin'
          AND d.source_database_id IS NULL
          AND NOT EXISTS (SELECT 1 FROM mon.DatabasePolicy AS p WHERE p.database_name = d.name);

        /* Check matrix row for every new database: all checks ON (edit mon.DatabaseCheck to opt out). */
        INSERT mon.DatabaseCheck(database_name)
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.name <> N'rdsadmin'
          AND d.source_database_id IS NULL
          AND NOT EXISTS (SELECT 1 FROM mon.DatabaseCheck AS c WHERE c.database_name = d.name);

        /* Standard Ola Hallengren + RDS native backup job discovery. Overrides preserved. */
        ;WITH J AS
        (
            SELECT j.job_id, j.name,
                   CASE
                       WHEN j.name LIKE N'DatabaseBackup%LOG%'        THEN 'BACKUP_LOG'
                       WHEN j.name LIKE N'DatabaseBackup%DIFF%'       THEN 'BACKUP_DIFF'
                       WHEN j.name LIKE N'DatabaseBackup%FULL%'       THEN 'BACKUP_FULL'
                       WHEN j.name LIKE N'DatabaseIntegrityCheck%'    THEN 'INTEGRITY_CHECK'
                       WHEN j.name LIKE N'IndexOptimize%'             THEN 'INDEX_OPTIMIZE'
                       WHEN j.name = N'DBMaintenance - Daily Backups' THEN 'RDS_NATIVE_BACKUP'
                       ELSE 'CLEANUP'
                   END AS job_type,
                   CONVERT(decimal(9,2),
                   CASE
                       WHEN j.name LIKE N'DatabaseBackup%LOG%'        THEN 0.5
                       WHEN j.name LIKE N'DatabaseBackup%DIFF%'       THEN 6
                       WHEN j.name LIKE N'DatabaseBackup%FULL%'       THEN 24
                       WHEN j.name = N'DBMaintenance - Daily Backups' THEN 24
                       ELSE 192
                   END) AS max_hours
            FROM msdb.dbo.sysjobs AS j
            WHERE j.name LIKE N'DatabaseBackup%'
               OR j.name LIKE N'DatabaseIntegrityCheck%'
               OR j.name LIKE N'IndexOptimize%'
               OR j.name = N'DBMaintenance - Daily Backups'
               OR j.name IN (N'CommandLog Cleanup', N'Output File Cleanup',
                             N'sp_delete_backuphistory', N'sp_purge_jobhistory')
        )
        INSERT mon.JobPolicy(job_id, job_name, job_type, max_hours_since_success)
        SELECT J.job_id, J.name, J.job_type, J.max_hours
        FROM J
        WHERE NOT EXISTS (SELECT 1 FROM mon.JobPolicy AS p WHERE p.job_id = J.job_id);

        UPDATE p
           SET p.job_name = j.name, p.last_seen_utc = SYSUTCDATETIME()
        FROM mon.JobPolicy AS p
        JOIN msdb.dbo.sysjobs AS j ON j.job_id = p.job_id;

        EXEC mon.usp_SetComponentStatus 'POLICY_SYNC', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'POLICY_SYNC', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------------
   Database state: inventory, sizes, log usage, VLFs, CHECKDB, Query Store,
   configuration baseline.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectDatabaseState
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME(),
            @now datetime2(0) = SYSUTCDATETIME(),
            @errors nvarchar(2000) = NULL;

    BEGIN TRY
        CREATE TABLE #Db
        (
            database_name sysname COLLATE DATABASE_DEFAULT PRIMARY KEY, database_id int, state_desc nvarchar(60),
            user_access_desc nvarchar(60), is_read_only bit, recovery_model nvarchar(60),
            compatibility_level tinyint, owner_name sysname NULL, page_verify nvarchar(60),
            is_auto_close_on bit, is_auto_shrink_on bit, is_rcsi_on bit, snapshot_isolation nvarchar(60),
            log_reuse_wait_desc nvarchar(60), create_date_utc datetime2(0),
            data_size_mb decimal(19,2), data_used_mb decimal(19,2) NULL, log_size_mb decimal(19,2),
            log_used_pct decimal(9,2) NULL, vlf_total int NULL, vlf_active int NULL,
            log_since_backup_mb decimal(19,2) NULL, dmv_log_backup_utc datetime2(0) NULL,
            last_checkdb_utc datetime2(0) NULL, qs_desired_state nvarchar(60) NULL,
            qs_actual_state nvarchar(60) NULL, qs_readonly_reason int NULL,
            pct_growth_files int NULL, max_file_pct_of_maxsize decimal(9,2) NULL,
            max_file_name sysname NULL, collection_error nvarchar(1000) NULL, checkdb_source varchar(20) NULL
        );
        CREATE TABLE #DbInfo(ParentObject nvarchar(255), [Object] nvarchar(255), Field nvarchar(255), [Value] nvarchar(255));

        INSERT #Db(database_name, database_id, state_desc, user_access_desc, is_read_only, recovery_model,
                   compatibility_level, owner_name, page_verify, is_auto_close_on, is_auto_shrink_on,
                   is_rcsi_on, snapshot_isolation, log_reuse_wait_desc, create_date_utc,
                   data_size_mb, log_size_mb, pct_growth_files, last_checkdb_utc)
        SELECT d.name, d.database_id, d.state_desc, d.user_access_desc, d.is_read_only, d.recovery_model_desc,
               d.compatibility_level, SUSER_SNAME(d.owner_sid), d.page_verify_option_desc,
               d.is_auto_close_on, d.is_auto_shrink_on, d.is_read_committed_snapshot_on,
               d.snapshot_isolation_state_desc, d.log_reuse_wait_desc,
               mon.fn_ServerToUtc(d.create_date),
               mf.data_mb, mf.log_mb, mf.pct_growth_files,
               CASE WHEN d.state_desc = N'ONLINE' THEN
                    mon.fn_ServerToUtc(NULLIF(TRY_CONVERT(datetime2(3),
                        DATABASEPROPERTYEX(d.name, 'LastGoodCheckDbTime')), '19000101'))
               END
        FROM sys.databases AS d
        OUTER APPLY
        (
            SELECT SUM(CASE WHEN f.type = 0 THEN CONVERT(bigint, f.size) END) * 8 / 1024.0 AS data_mb,
                   SUM(CASE WHEN f.type = 1 THEN CONVERT(bigint, f.size) END) * 8 / 1024.0 AS log_mb,
                   SUM(CASE WHEN f.is_percent_growth = 1 AND f.growth > 0 THEN 1 ELSE 0 END) AS pct_growth_files
            FROM sys.master_files AS f
            WHERE f.database_id = d.database_id
        ) AS mf
        WHERE d.database_id > 4
          AND d.name <> N'rdsadmin'
          AND d.source_database_id IS NULL;

        UPDATE #Db SET checkdb_source = 'DBPROPERTY' WHERE last_checkdb_utc IS NOT NULL;

        /* Files closest to MAXSIZE (max_size -1 = unlimited, 0 = no growth). */
        ;WITH F AS
        (
            SELECT DB_NAME(f.database_id) AS database_name, f.name,
                   CONVERT(decimal(9,2), f.size * 100.0 / NULLIF(f.max_size, 0)) AS pct,
                   ROW_NUMBER() OVER (PARTITION BY f.database_id ORDER BY f.size * 1.0 / NULLIF(f.max_size, 0) DESC) AS rn
            FROM sys.master_files AS f
            WHERE f.database_id > 4 AND f.max_size > 0 AND f.growth > 0
              AND f.max_size <> 268435456   /* 2 TB log default = effectively unlimited */
        )
        UPDATE d SET d.max_file_pct_of_maxsize = F.pct, d.max_file_name = F.name
        FROM #Db AS d JOIN F ON F.database_name = d.database_name AND F.rn = 1;

        /* Log utilization (cheap, instance wide). */
        BEGIN TRY
            CREATE TABLE #LogSpace(database_name sysname COLLATE DATABASE_DEFAULT, log_size_mb decimal(19,2), log_used_pct decimal(9,2), status_code int);
            INSERT #LogSpace EXEC (N'DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS;');
            UPDATE d SET d.log_used_pct = l.log_used_pct
            FROM #Db AS d JOIN #LogSpace AS l ON l.database_name = d.database_name;
        END TRY
        BEGIN CATCH
            SET @errors = CONCAT(@errors, N' LOGSPACE: ', ERROR_MESSAGE());
        END CATCH;

        /* VLFs + last log backup as seen by the engine itself (includes RDS automated log backups). */
        BEGIN TRY
            CREATE TABLE #LogStats(database_id int PRIMARY KEY, total_vlf int, active_vlf int,
                                   since_mb decimal(19,2), log_backup_time datetime2(3) NULL);
            INSERT #LogStats
            EXEC sys.sp_executesql N'
                SELECT d.database_id, ls.total_vlf_count, ls.active_vlf_count,
                       ls.log_since_last_log_backup_mb, NULLIF(ls.log_backup_time, ''19000101'')
                FROM sys.databases AS d
                CROSS APPLY sys.dm_db_log_stats(d.database_id) AS ls
                WHERE d.database_id > 4 AND d.state_desc = N''ONLINE'' AND d.is_in_standby = 0
                  AND d.source_database_id IS NULL;';
            UPDATE d SET d.vlf_total = s.total_vlf, d.vlf_active = s.active_vlf,
                         d.log_since_backup_mb = s.since_mb,
                         d.dmv_log_backup_utc = mon.fn_ServerToUtc(s.log_backup_time)
            FROM #Db AS d JOIN #LogStats AS s ON s.database_id = d.database_id;
        END TRY
        BEGIN CATCH
            SET @errors = CONCAT(@errors, N' dm_db_log_stats: ', ERROR_MESSAGE());
        END CATCH;

        /* Per-database context: data space used + Query Store state. */
        DECLARE @dbinfo_denied bit = 0;
        DECLARE @db sysname, @proc nvarchar(300), @du decimal(19,2), @qd nvarchar(60), @qa nvarchar(60), @qr int;
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT database_name FROM #Db WHERE state_desc = N'ONLINE' AND user_access_desc <> N'SINGLE_USER';
        OPEN c;
        FETCH NEXT FROM c INTO @db;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SELECT @du = NULL, @qd = NULL, @qa = NULL, @qr = NULL;
                SET @proc = QUOTENAME(@db) + N'.sys.sp_executesql';
                EXEC @proc N'
                    SELECT @du = SUM(CONVERT(bigint, FILEPROPERTY(name, ''SpaceUsed''))) * 8 / 1024.0
                    FROM sys.database_files WHERE type = 0;
                    SELECT @qd = desired_state_desc, @qa = actual_state_desc, @qr = readonly_reason
                    FROM sys.database_query_store_options;',
                    N'@du decimal(19,2) OUTPUT, @qd nvarchar(60) OUTPUT, @qa nvarchar(60) OUTPUT, @qr int OUTPUT',
                    @du = @du OUTPUT, @qd = @qd OUTPUT, @qa = @qa OUTPUT, @qr = @qr OUTPUT;
                UPDATE #Db SET data_used_mb = @du, qs_desired_state = @qd, qs_actual_state = @qa,
                               qs_readonly_reason = @qr
                WHERE database_name = @db;

                /* CHECKDB fallback when DATABASEPROPERTYEX('LastGoodCheckDbTime') is not available on this build:
                   read dbi_dbccLastKnownGood from the boot page (DBCC DBINFO). Ola CommandLog is a third source (view). */
                IF @dbinfo_denied = 0 AND EXISTS (SELECT 1 FROM #Db WHERE database_name = @db AND last_checkdb_utc IS NULL)
                BEGIN
                    BEGIN TRY
                        TRUNCATE TABLE #DbInfo;
                        INSERT #DbInfo EXEC @proc N'DBCC DBINFO WITH TABLERESULTS, NO_INFOMSGS;';
                        UPDATE #Db
                           SET last_checkdb_utc = mon.fn_ServerToUtc(NULLIF(TRY_CONVERT(datetime2(3),
                                   (SELECT TOP (1) i.[Value] FROM #DbInfo AS i WHERE i.Field = N'dbi_dbccLastKnownGood')), '19000101')),
                               checkdb_source = 'DBINFO'
                         WHERE database_name = @db;
                        UPDATE #Db SET checkdb_source = NULL WHERE database_name = @db AND last_checkdb_utc IS NULL;
                    END TRY
                    BEGIN CATCH
                        SET @dbinfo_denied = 1;   /* not permitted (RDS: not sysadmin) - stop trying this run; Ola CommandLog remains */
                    END CATCH;
                END;
            END TRY
            BEGIN CATCH
                UPDATE #Db SET collection_error = LEFT(ERROR_MESSAGE(), 1000) WHERE database_name = @db;
            END CATCH;
            FETCH NEXT FROM c INTO @db;
        END;
        CLOSE c;
        DEALLOCATE c;

        /* Upsert current state; databases no longer present are flagged, not deleted. */
        MERGE mon.DatabaseStatus AS t
        USING #Db AS s ON t.database_name = s.database_name
        WHEN MATCHED THEN UPDATE SET
            database_id = s.database_id, is_present = 1, collected_utc = @now, state_desc = s.state_desc,
            user_access_desc = s.user_access_desc, is_read_only = s.is_read_only, recovery_model = s.recovery_model,
            compatibility_level = s.compatibility_level, owner_name = s.owner_name, page_verify = s.page_verify,
            is_auto_close_on = s.is_auto_close_on, is_auto_shrink_on = s.is_auto_shrink_on, is_rcsi_on = s.is_rcsi_on,
            snapshot_isolation = s.snapshot_isolation, log_reuse_wait_desc = s.log_reuse_wait_desc,
            create_date_utc = s.create_date_utc, data_size_mb = s.data_size_mb, data_used_mb = s.data_used_mb,
            log_size_mb = s.log_size_mb, log_used_pct = s.log_used_pct, vlf_total = s.vlf_total,
            vlf_active = s.vlf_active, log_since_backup_mb = s.log_since_backup_mb,
            dmv_log_backup_utc = s.dmv_log_backup_utc, last_checkdb_utc = s.last_checkdb_utc,
            qs_desired_state = s.qs_desired_state, qs_actual_state = s.qs_actual_state,
            qs_readonly_reason = s.qs_readonly_reason, pct_growth_files = s.pct_growth_files,
            max_file_pct_of_maxsize = s.max_file_pct_of_maxsize, max_file_name = s.max_file_name,
            collection_error = s.collection_error, checkdb_source = s.checkdb_source
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (database_name, database_id, is_present, collected_utc, state_desc, user_access_desc, is_read_only,
             recovery_model, compatibility_level, owner_name, page_verify, is_auto_close_on, is_auto_shrink_on,
             is_rcsi_on, snapshot_isolation, log_reuse_wait_desc, create_date_utc, data_size_mb, data_used_mb,
             log_size_mb, log_used_pct, vlf_total, vlf_active, log_since_backup_mb, dmv_log_backup_utc,
             last_checkdb_utc, qs_desired_state, qs_actual_state, qs_readonly_reason, pct_growth_files,
             max_file_pct_of_maxsize, max_file_name, collection_error, checkdb_source)
        VALUES
            (s.database_name, s.database_id, 1, @now, s.state_desc, s.user_access_desc, s.is_read_only,
             s.recovery_model, s.compatibility_level, s.owner_name, s.page_verify, s.is_auto_close_on,
             s.is_auto_shrink_on, s.is_rcsi_on, s.snapshot_isolation, s.log_reuse_wait_desc, s.create_date_utc,
             s.data_size_mb, s.data_used_mb, s.log_size_mb, s.log_used_pct, s.vlf_total, s.vlf_active,
             s.log_since_backup_mb, s.dmv_log_backup_utc, s.last_checkdb_utc, s.qs_desired_state,
             s.qs_actual_state, s.qs_readonly_reason, s.pct_growth_files, s.max_file_pct_of_maxsize,
             s.max_file_name, s.collection_error, s.checkdb_source)
        WHEN NOT MATCHED BY SOURCE AND t.is_present = 1 THEN UPDATE SET
            is_present = 0, collected_utc = @now, state_desc = N'NOT_FOUND';

        /* Configuration baseline: first observation of every property is accepted automatically. */
        ;WITH P AS
        (
            SELECT s.database_name, v.property_name, v.property_value
            FROM mon.DatabaseStatus AS s
            CROSS APPLY (VALUES
                ('recovery_model',      CONVERT(nvarchar(256), s.recovery_model)),
                ('compatibility_level', CONVERT(nvarchar(256), s.compatibility_level)),
                ('owner_name',          CONVERT(nvarchar(256), s.owner_name)),
                ('page_verify',         CONVERT(nvarchar(256), s.page_verify)),
                ('auto_close',          CONVERT(nvarchar(256), s.is_auto_close_on)),
                ('auto_shrink',         CONVERT(nvarchar(256), s.is_auto_shrink_on)),
                ('read_only',           CONVERT(nvarchar(256), s.is_read_only)),
                ('rcsi',                CONVERT(nvarchar(256), s.is_rcsi_on)),
                ('snapshot_isolation',  CONVERT(nvarchar(256), s.snapshot_isolation)),
                ('user_access',         CONVERT(nvarchar(256), s.user_access_desc))
            ) AS v(property_name, property_value)
            WHERE s.is_present = 1 AND s.state_desc = N'ONLINE'
        )
        INSERT mon.DatabaseConfigBaseline(database_name, property_name, baseline_value)
        SELECT P.database_name, P.property_name, P.property_value
        FROM P
        WHERE NOT EXISTS (SELECT 1 FROM mon.DatabaseConfigBaseline AS b
                          WHERE b.database_name = P.database_name AND b.property_name = P.property_name);

        IF @errors IS NULL
            EXEC mon.usp_SetComponentStatus 'DATABASE_STATE', 1, @started;
        ELSE
            EXEC mon.usp_SetComponentStatus 'DATABASE_STATE', 0, @started, 50001, @errors;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'DATABASE_STATE', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------------
   Backups: msdb history, RDS native task status, RDS log-backup metadata and
   sys.dm_db_log_stats. Latest evidence per database/type -> mon.BackupStatus.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectBackups
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME(), @now datetime2(0) = SYSUTCDATETIME(),
            @note nvarchar(1000) = NULL, @task_error bit = 0;

    BEGIN TRY
        /* 1. RDS native backup/restore task status (asynchronous tasks). */
        CREATE TABLE #RdsTasks
        (
            task_id int, task_type nvarchar(128) COLLATE DATABASE_DEFAULT, database_name sysname COLLATE DATABASE_DEFAULT NULL,
            percent_complete_text nvarchar(100), duration_minutes_text nvarchar(100),
            lifecycle nvarchar(40), task_info nvarchar(max), last_updated datetime, created_at datetime,
            s3_object_arn nvarchar(max), overwrite_s3_backup_file nvarchar(100),
            kms_master_key_arn nvarchar(max), filepath nvarchar(max), overwrite_file nvarchar(100)
        );
        BEGIN TRY
            INSERT #RdsTasks EXEC msdb.dbo.rds_task_status;
        END TRY
        BEGIN CATCH
            SET @note = CONCAT(N'rds_task_status unavailable: ', LEFT(ERROR_MESSAGE(), 300));
            SET @task_error = 1;
        END CATCH;

        MERGE mon.RdsTask AS t
        USING (SELECT task_id, task_type, database_name,
                      TRY_CONVERT(decimal(9,2), REPLACE(percent_complete_text, N'%', N'')) AS pct,
                      TRY_CONVERT(int, duration_minutes_text) AS dur,
                      lifecycle, task_info,
                      mon.fn_ServerToUtc(last_updated) AS last_updated_utc,
                      mon.fn_ServerToUtc(created_at) AS created_utc,
                      LEFT(s3_object_arn, 4000) AS arn
               FROM #RdsTasks) AS s
        ON t.task_id = s.task_id
        WHEN MATCHED THEN UPDATE SET
            task_type = s.task_type, database_name = s.database_name, percent_complete = s.pct,
            duration_minutes = s.dur, lifecycle = s.lifecycle, task_info = s.task_info,
            last_updated_utc = s.last_updated_utc, created_utc = s.created_utc,
            s3_object_arn = s.arn, last_collected_utc = @now
        WHEN NOT MATCHED THEN INSERT
            (task_id, task_type, database_name, percent_complete, duration_minutes, lifecycle, task_info,
             last_updated_utc, created_utc, s3_object_arn)
        VALUES (s.task_id, s.task_type, s.database_name, s.pct, s.dur, s.lifecycle, s.task_info,
                s.last_updated_utc, s.created_utc, s.arn);

        /* 2. RDS automated transaction-log backup metadata (requires T-log backup access feature). */
        CREATE TABLE #Tlog
        (
            db_name sysname COLLATE DATABASE_DEFAULT, db_id int, family_guid uniqueidentifier, rds_backup_seq_id int,
            backup_file_epoch bigint, backup_file_time_utc datetime, starting_lsn numeric(25,0),
            ending_lsn numeric(25,0), is_log_chain_broken bit, file_size_bytes bigint, error_message varchar(4000)
        );
        DECLARE @db sysname, @tlog_errors int = 0, @since datetime,
                @full_scan bit = CASE WHEN EXISTS (SELECT 1 FROM mon.ComponentStatus WHERE component_name = 'TLOG_FULL_SCAN'
                                                   AND last_success_utc > DATEADD(HOUR, -24, SYSUTCDATETIME())) THEN 0 ELSE 1 END;
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT p.database_name
            FROM mon.DatabaseCheck AS p
            JOIN sys.databases AS d ON d.name = p.database_name
            WHERE p.monitored = 1 AND (p.log_backup = 1 OR p.backup_retention = 1)
              AND d.state_desc = N'ONLINE' AND d.recovery_model_desc = N'FULL';
        OPEN c;
        FETCH NEXT FROM c INTO @db;
        WHILE @@FETCH_STATUS = 0 AND @tlog_errors < 2   /* feature disabled -> stop probing after 2 errors */
        BEGIN
            /* first time for this database: load the whole RDS retention window (for the retention grid) */
            /* Full RDS retention window on first contact and once a day (marks which files RDS still has);
               otherwise only the last 2 days. */
            SET @since = CASE WHEN @full_scan = 1 OR NOT EXISTS (SELECT 1 FROM mon.TlogBackup WHERE database_name = @db)
                              THEN '20000101' ELSE DATEADD(DAY, -2, SYSUTCDATETIME()) END;
            BEGIN TRY
                INSERT #Tlog
                EXEC sys.sp_executesql N'
                    SELECT db_name, db_id, family_guid, rds_backup_seq_id, backup_file_epoch,
                           backup_file_time_utc, starting_lsn, ending_lsn, is_log_chain_broken,
                           file_size_bytes, [Error]
                    FROM msdb.dbo.rds_fn_list_tlog_backup_metadata(@p_db)
                    WHERE backup_file_time_utc >= @p_since;',
                    N'@p_db sysname, @p_since datetime', @p_db = @db, @p_since = @since;
            END TRY
            BEGIN CATCH
                SET @tlog_errors += 1;
            END CATCH;
            FETCH NEXT FROM c INTO @db;
        END;
        CLOSE c;
        DEALLOCATE c;

        INSERT mon.TlogBackup(database_name, rds_backup_seq_id, backup_file_time_utc, starting_lsn,
                              ending_lsn, is_log_chain_broken, file_size_bytes, last_seen_utc)
        SELECT m.db_name, m.rds_backup_seq_id, m.backup_file_time_utc, m.starting_lsn, m.ending_lsn,
               m.is_log_chain_broken, m.file_size_bytes, @now
        FROM #Tlog AS m
        WHERE m.rds_backup_seq_id IS NOT NULL AND m.backup_file_time_utc IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM mon.TlogBackup AS t
                          WHERE t.database_name = m.db_name AND t.rds_backup_seq_id = m.rds_backup_seq_id);

        /* Files RDS still lists = still on storage. */
        UPDATE t SET t.last_seen_utc = @now
        FROM mon.TlogBackup AS t
        JOIN #Tlog AS m ON m.db_name = t.database_name AND m.rds_backup_seq_id = t.rds_backup_seq_id;

        IF @full_scan = 1   /* once a day, whatever the outcome (a failing DB must not force a full scan every cycle) */
            EXEC mon.usp_SetComponentStatus 'TLOG_FULL_SCAN', 1, NULL;

        /* 3. Candidate evidence from every source, normalized to UTC. */
        CREATE TABLE #Cand
        (
            database_name sysname COLLATE DATABASE_DEFAULT, backup_type char(1), finish_utc datetime2(0), duration_s int NULL,
            size_bytes bigint NULL, source_name varchar(20), location nvarchar(1000) NULL, chain_broken bit NULL
        );

        ;WITH B AS
        (
            SELECT b.database_name, b.type, b.backup_start_date, b.backup_finish_date,
                   COALESCE(b.compressed_backup_size, b.backup_size) AS size_bytes, b.media_set_id,
                   ROW_NUMBER() OVER (PARTITION BY b.database_name, b.type ORDER BY b.backup_finish_date DESC) AS rn
            FROM msdb.dbo.backupset AS b
            WHERE b.type IN ('D', 'I', 'L')
              AND EXISTS (SELECT 1 FROM mon.DatabasePolicy AS p WHERE p.database_name = b.database_name)
        )
        INSERT #Cand
        SELECT B.database_name, B.type, mon.fn_ServerToUtc(B.backup_finish_date),
               DATEDIFF(SECOND, B.backup_start_date, B.backup_finish_date), B.size_bytes, 'MSDB',
               LEFT(mf.physical_device_name, 1000), NULL
        FROM B
        OUTER APPLY (SELECT TOP (1) f.physical_device_name
                     FROM msdb.dbo.backupmediafamily AS f
                     WHERE f.media_set_id = B.media_set_id
                     ORDER BY f.family_sequence_number) AS mf
        WHERE B.rn = 1;

        INSERT #Cand
        SELECT r.database_name, CASE WHEN r.task_type = N'BACKUP_DB' THEN 'D' ELSE 'I' END,
               r.last_updated_utc, r.duration_minutes * 60, NULL, 'RDS_TASK', LEFT(r.s3_object_arn, 1000), NULL
        FROM mon.RdsTask AS r
        WHERE r.lifecycle = N'SUCCESS'
          AND r.task_type IN (N'BACKUP_DB', N'BACKUP_DB_DIFFERENTIAL')
          AND r.last_updated_utc IS NOT NULL
          AND r.database_name IS NOT NULL;

        INSERT #Cand
        SELECT t.database_name, 'L', t.backup_file_time_utc, NULL, t.file_size_bytes, 'RDS_TLOG', NULL, t.is_log_chain_broken
        FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.database_name ORDER BY t.backup_file_time_utc DESC) AS rn
              FROM mon.TlogBackup AS t) AS t
        WHERE t.rn = 1;

        INSERT #Cand
        SELECT s.database_name, 'L', s.dmv_log_backup_utc, NULL, NULL, 'DMV_LOG_STATS', NULL, NULL
        FROM mon.DatabaseStatus AS s
        WHERE s.is_present = 1 AND s.dmv_log_backup_utc IS NOT NULL AND s.recovery_model = N'FULL';

        ;WITH L AS
        (
            SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.database_name, c.backup_type
                                           ORDER BY c.finish_utc DESC, c.source_name) AS rn
            FROM #Cand AS c
        )
        SELECT * INTO #Latest FROM L WHERE rn = 1;

        MERGE mon.BackupStatus AS t
        USING
        (
            SELECT p.database_name,
                   f.finish_utc AS full_finish_utc, f.duration_s AS full_duration_s, f.size_bytes AS full_size_bytes,
                   f.source_name AS full_source, f.location AS full_location,
                   i.finish_utc AS diff_finish_utc, i.duration_s AS diff_duration_s, i.size_bytes AS diff_size_bytes,
                   i.source_name AS diff_source,
                   l.finish_utc AS log_finish_utc, l.size_bytes AS log_size_bytes, l.source_name AS log_source,
                   (SELECT MAX(CONVERT(tinyint, t.is_log_chain_broken)) FROM mon.TlogBackup AS t
                    WHERE t.database_name = p.database_name
                      AND t.backup_file_time_utc >= DATEADD(HOUR, -24, @now)) AS chain_broken
            FROM mon.DatabasePolicy AS p
            LEFT JOIN #Latest AS f ON f.database_name = p.database_name AND f.backup_type = 'D'
            LEFT JOIN #Latest AS i ON i.database_name = p.database_name AND i.backup_type = 'I'
            LEFT JOIN #Latest AS l ON l.database_name = p.database_name AND l.backup_type = 'L'
        ) AS s
        ON t.database_name = s.database_name
        WHEN MATCHED THEN UPDATE SET
            collected_utc = @now, full_finish_utc = s.full_finish_utc, full_duration_s = s.full_duration_s,
            full_size_bytes = s.full_size_bytes, full_source = s.full_source, full_location = s.full_location,
            diff_finish_utc = s.diff_finish_utc, diff_duration_s = s.diff_duration_s,
            diff_size_bytes = s.diff_size_bytes, diff_source = s.diff_source,
            log_finish_utc = s.log_finish_utc, log_size_bytes = s.log_size_bytes, log_source = s.log_source,
            log_chain_broken = s.chain_broken, note = @note
        WHEN NOT MATCHED THEN INSERT
            (database_name, collected_utc, full_finish_utc, full_duration_s, full_size_bytes, full_source,
             full_location, diff_finish_utc, diff_duration_s, diff_size_bytes, diff_source, log_finish_utc,
             log_size_bytes, log_source, log_chain_broken, note)
        VALUES
            (s.database_name, @now, s.full_finish_utc, s.full_duration_s, s.full_size_bytes, s.full_source,
             s.full_location, s.diff_finish_utc, s.diff_duration_s, s.diff_size_bytes, s.diff_source,
             s.log_finish_utc, s.log_size_bytes, s.log_source, s.chain_broken, @note)
        WHEN NOT MATCHED BY SOURCE THEN DELETE;

        IF @task_error = 0
            EXEC mon.usp_SetComponentStatus 'BACKUPS', 1, @started;
        ELSE
            EXEC mon.usp_SetComponentStatus 'BACKUPS', 0, @started, 50003, @note;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'BACKUPS', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------------
   SQL Agent: every job outcome (for SLA + duration baselines, and to outlive
   the small msdb history limit) and every failed/cancelled job run with the
   step that actually failed.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectAgent
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    BEGIN TRY
        DECLARE @since_int int = CONVERT(int, CONVERT(char(8), DATEADD(DAY, -35, GETDATE()), 112));

        INSERT mon.AgentJobRun(job_id, instance_id, job_name, run_status, run_start_utc, duration_s, message)
        SELECT h.job_id, h.instance_id, j.name, h.run_status,
               mon.fn_ServerToUtc(DATETIMEFROMPARTS(h.run_date / 10000, (h.run_date / 100) % 100, h.run_date % 100,
                                                    h.run_time / 10000, (h.run_time / 100) % 100, h.run_time % 100, 0)),
               (h.run_duration / 10000) * 3600 + ((h.run_duration / 100) % 100) * 60 + h.run_duration % 100,
               LEFT(h.message, 4000)
        FROM msdb.dbo.sysjobhistory AS h
        JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
        WHERE h.step_id = 0
          AND h.run_date >= @since_int
          AND NOT EXISTS (SELECT 1 FROM mon.AgentJobRun AS x WHERE x.job_id = h.job_id AND x.instance_id = h.instance_id);

        INSERT mon.AgentFailure(job_id, instance_id, job_name, run_status, run_start_utc, duration_s,
                                failed_step_id, failed_step_name, message)
        SELECT r.job_id, r.instance_id, r.job_name, r.run_status, r.run_start_utc, r.duration_s,
               st.step_id, st.step_name, COALESCE(st.message, r.message)
        FROM mon.AgentJobRun AS r
        OUTER APPLY
        (
            /* The failing step of this execution: last failed step row before the outcome row. */
            SELECT TOP (1) s.step_id, s.step_name, LEFT(s.message, 4000) AS message
            FROM msdb.dbo.sysjobhistory AS s
            WHERE s.job_id = r.job_id AND s.step_id > 0 AND s.run_status = 0
              AND s.instance_id < r.instance_id
              AND s.instance_id > ISNULL((SELECT MAX(p.instance_id)
                                          FROM msdb.dbo.sysjobhistory AS p
                                          WHERE p.job_id = r.job_id AND p.step_id = 0
                                            AND p.instance_id < r.instance_id), 0)
            ORDER BY s.instance_id DESC
        ) AS st
        WHERE r.run_status IN (0, 3)
          AND r.run_start_utc >= DATEADD(DAY, -7, SYSUTCDATETIME())
          AND NOT EXISTS (SELECT 1 FROM mon.AgentFailure AS f WHERE f.job_id = r.job_id AND f.instance_id = r.instance_id);

        EXEC mon.usp_SetComponentStatus 'AGENT', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'AGENT', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------------
   Events: deadlocks (system_health ring buffer), high-signal error-log entries,
   failed logins (aggregated per hour/login/client/reason).
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectEvents
    @ReadErrorLog bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();

    /* ---- Deadlocks ---- */
    BEGIN TRY
        DECLARE @rb xml;
        SELECT @rb = TRY_CAST(t.target_data AS xml)
        FROM sys.dm_xe_session_targets AS t
        JOIN sys.dm_xe_sessions AS s ON s.address = t.event_session_address
        WHERE s.name = N'system_health' AND t.target_name = N'ring_buffer';

        ;WITH D AS
        (
            SELECT TRY_CONVERT(datetime2(3), n.value('@timestamp', 'nvarchar(50)')) AS event_utc,
                   n.query('(data/value/deadlock)[1]') AS dx
            FROM @rb.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS x(n)
        ), S AS
        (
            SELECT D.event_utc, D.dx,
                   HASHBYTES('SHA2_256', CONVERT(varbinary(max), CONVERT(nvarchar(max), D.dx))) AS h,
                   D.dx.value('(/deadlock/victim-list/victimProcess/@id)[1]', 'nvarchar(100)') AS victim_id,
                   D.dx.value('count(/deadlock/process-list/process)', 'int') AS pc
            FROM D
            WHERE D.event_utc IS NOT NULL AND D.dx.exist('/deadlock') = 1
        )
        INSERT mon.Deadlock(deadlock_hash, event_utc, database_name, process_count, victim_login, victim_host,
                            victim_app, victim_sql, survivor_sql, objects, deadlock_xml)
        SELECT S.h, S.event_utc,
               COALESCE(NULLIF(v.p.value('@currentdbname', 'nvarchar(128)'), N''),
                        DB_NAME(v.p.value('@currentdb', 'int'))),
               S.pc,
               v.p.value('@loginname', 'nvarchar(128)'),
               v.p.value('@hostname', 'nvarchar(128)'),
               v.p.value('@clientapp', 'nvarchar(256)'),
               LEFT(LTRIM(v.p.value('(inputbuf)[1]', 'nvarchar(max)')), 2000),
               LEFT(LTRIM(S.dx.value('(/deadlock/process-list/process[@id != sql:column("S.victim_id")]/inputbuf)[1]', 'nvarchar(max)')), 2000),
               LEFT(o.objects, 1000),
               S.dx
        FROM S
        OUTER APPLY S.dx.nodes('(/deadlock/process-list/process[@id = sql:column("S.victim_id")])[1]') AS v(p)
        OUTER APPLY
        (
            SELECT STUFF((
                SELECT DISTINCT N', ' + r.value('@objectname', 'nvarchar(256)')
                FROM S.dx.nodes('/deadlock/resource-list/*') AS rr(r)
                WHERE r.value('@objectname', 'nvarchar(256)') IS NOT NULL
                FOR XML PATH(''), TYPE).value('(./text())[1]', 'nvarchar(max)'), 1, 2, N'') AS objects
        ) AS o
        WHERE NOT EXISTS (SELECT 1 FROM mon.Deadlock AS x WHERE x.deadlock_hash = S.h);

        EXEC mon.usp_SetComponentStatus 'DEADLOCKS', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en1 int = ERROR_NUMBER(), @em1 nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'DEADLOCKS', 0, @started, @en1, @em1;
    END CATCH;

    /* ---- Error log + failed logins ---- */
    IF @ReadErrorLog = 1
    BEGIN
        SET @started = SYSUTCDATETIME();
        BEGIN TRY
            DECLARE @wm datetime2(3) =
                ISNULL((SELECT watermark_utc FROM mon.ComponentStatus WHERE component_name = 'ERRORLOG'),
                       DATEADD(DAY, -1, SYSUTCDATETIME()));
            DECLARE @is_rds bit = 1;

            CREATE TABLE #EL
            (
                row_id int IDENTITY(1,1) PRIMARY KEY, log_idx tinyint NULL,
                LogDate datetime, ProcessInfo nvarchar(100) COLLATE DATABASE_DEFAULT, [Text] nvarchar(max) COLLATE DATABASE_DEFAULT
            );

            BEGIN TRY
                INSERT #EL(LogDate, ProcessInfo, [Text]) EXEC rdsadmin.dbo.rds_read_error_log @index = 0, @type = 1;
            END TRY
            BEGIN CATCH
                SET @is_rds = 0;   /* not RDS: fall back to the standard reader */
                INSERT #EL(LogDate, ProcessInfo, [Text]) EXEC sys.xp_readerrorlog 0, 1;
            END CATCH;
            UPDATE #EL SET log_idx = 0 WHERE log_idx IS NULL;

            /* Previous log only when the current one starts after our watermark (restart / recycle). */
            IF mon.fn_ServerToUtc((SELECT MIN(LogDate) FROM #EL)) > @wm
            BEGIN
                BEGIN TRY
                    IF @is_rds = 1
                        INSERT #EL(LogDate, ProcessInfo, [Text]) EXEC rdsadmin.dbo.rds_read_error_log @index = 1, @type = 1;
                    ELSE
                        INSERT #EL(LogDate, ProcessInfo, [Text]) EXEC sys.xp_readerrorlog 1, 1;
                    UPDATE #EL SET log_idx = 1 WHERE log_idx IS NULL;
                END TRY
                BEGIN CATCH
                    /* previous log may not exist on a new instance */
                END CATCH;
            END;

            ;WITH R AS
            (
                SELECT e.row_id, mon.fn_ServerToUtc(e.LogDate) AS log_utc, e.ProcessInfo, e.[Text],
                       LEAD(e.[Text]) OVER (PARTITION BY e.log_idx ORDER BY e.row_id) AS next_text,
                       LAG(e.[Text])  OVER (PARTITION BY e.log_idx ORDER BY e.row_id) AS prev_text
                FROM #EL AS e
            ), C AS
            (
                SELECT R.*,
                       CASE WHEN R.[Text] LIKE N'Error: %, Severity: %'
                            THEN TRY_CONVERT(int, SUBSTRING(R.[Text], 8, CHARINDEX(N',', R.[Text]) - 8)) END AS err_no,
                       CASE WHEN R.[Text] LIKE N'Error: %, Severity: %'
                            THEN TRY_CONVERT(int, REPLACE(SUBSTRING(R.[Text], CHARINDEX(N'Severity: ', R.[Text]) + 10, 2), N',', N'')) END AS sev
                FROM R
                WHERE R.log_utc > DATEADD(MINUTE, -10, @wm)
            ), K AS
            (
                SELECT C.*,
                       CASE
                           WHEN C.err_no IN (17806, 17830, 17832, 17835, 17836, 18456) THEN NULL   /* scanners / logins */
                           WHEN C.err_no IN (605, 701, 802, 823, 824, 825, 829, 832, 845, 1105, 3041, 3313, 3314,
                                             3414, 3624, 9001, 9002, 17883, 17884, 17888, 18204, 18210) THEN 'CRITICAL'
                           WHEN C.err_no IN (833, 1204, 5144, 5145, 17890) THEN 'WARNING'
                           WHEN C.sev >= 20 THEN 'CRITICAL'
                           WHEN C.err_no IS NULL AND ISNULL(C.prev_text, N'') NOT LIKE N'Error: %, Severity: %'
                                AND (C.[Text] LIKE N'%SQL Server Assertion%' OR C.[Text] LIKE N'%Stack Signature%'
                                     OR C.[Text] LIKE N'%non-yielding%' OR C.[Text] LIKE N'%deadlocked schedulers%'
                                     OR C.[Text] LIKE N'%stack dump%') THEN 'CRITICAL'
                           WHEN C.err_no IS NULL AND ISNULL(C.prev_text, N'') NOT LIKE N'Error: %, Severity: %'
                                AND (C.[Text] LIKE N'%I/O requests taking longer than 15 seconds%'
                                     OR C.[Text] LIKE N'FlushCache: cleaned up%'
                                     OR C.[Text] LIKE N'%significant part of sql server process memory has been paged out%') THEN 'WARNING'
                       END AS sev_level
                FROM C
            ), H AS
            (
                SELECT K.log_utc, K.ProcessInfo, K.err_no, K.sev_level,
                       LEFT(CASE WHEN K.err_no IS NOT NULL
                                 THEN CONCAT(K.next_text, N'  [', K.[Text], N']')
                                 ELSE K.[Text] END, 4000) AS message
                FROM K
                WHERE K.sev_level IS NOT NULL
            )
            INSERT mon.ErrorLogEvent(event_hash, log_utc, process_info, error_number, severity, message)
            SELECT DISTINCT
                   HASHBYTES('SHA2_256', CONVERT(varbinary(max), CONCAT(CONVERT(nvarchar(23), H.log_utc, 121), N'|',
                             H.ProcessInfo, N'|', H.message))),
                   H.log_utc, H.ProcessInfo, H.err_no, H.sev_level, H.message
            FROM H
            WHERE NOT EXISTS (SELECT 1 FROM mon.ErrorLogEvent AS x
                              WHERE x.event_hash = HASHBYTES('SHA2_256', CONVERT(varbinary(max),
                                    CONCAT(CONVERT(nvarchar(23), H.log_utc, 121), N'|', H.ProcessInfo, N'|', H.message))));

            /* Failed logins newer than the watermark, aggregated per hour. */
            ;WITH L AS
            (
                SELECT mon.fn_ServerToUtc(e.LogDate) AS log_utc, e.[Text] AS t
                FROM #EL AS e
                WHERE e.[Text] LIKE N'Login failed for user %'
                  AND mon.fn_ServerToUtc(e.LogDate) > @wm
            ), P AS
            (
                SELECT L.log_utc, L.t,
                       CHARINDEX(N'''', L.t) AS q1,
                       CHARINDEX(N'''', L.t, CHARINDEX(N'''', L.t) + 1) AS q2,
                       CHARINDEX(N'Reason: ', L.t) AS r1,
                       CHARINDEX(N'[CLIENT: ', L.t) AS c1
                FROM L
            ), V AS
            (
                SELECT CONVERT(datetime2(0), DATEADD(HOUR, DATEDIFF(HOUR, CONVERT(datetime2(0), '19000101'), P.log_utc),
                               CONVERT(datetime2(0), '19000101'))) AS hour_utc,
                       LEFT(CASE WHEN P.q1 > 0 AND P.q2 > P.q1 THEN SUBSTRING(P.t, P.q1 + 1, P.q2 - P.q1 - 1) ELSE N'?' END, 128) AS login_name,
                       LEFT(CASE WHEN P.c1 > 0 THEN REPLACE(SUBSTRING(P.t, P.c1 + 9, 64), N']', N'') ELSE N'?' END, 64) AS client_address,
                       LEFT(CASE WHEN P.r1 > 0
                                 THEN LTRIM(RTRIM(SUBSTRING(P.t, P.r1 + 8,
                                          CASE WHEN P.c1 > P.r1 THEN P.c1 - P.r1 - 8 ELSE 400 END)))
                                 ELSE N'(no reason)' END, 200) AS reason
                FROM P
            )
            MERGE mon.LoginFailure AS t
            USING (SELECT hour_utc, login_name, LTRIM(RTRIM(client_address)) AS client_address, reason, COUNT(*) AS n
                   FROM V GROUP BY hour_utc, login_name, LTRIM(RTRIM(client_address)), reason) AS s
            ON t.hour_utc = s.hour_utc AND t.login_name = s.login_name
               AND t.client_address = s.client_address AND t.reason = s.reason
            WHEN MATCHED THEN UPDATE SET failures = t.failures + s.n
            WHEN NOT MATCHED THEN INSERT (hour_utc, login_name, client_address, reason, failures)
                                  VALUES (s.hour_utc, s.login_name, s.client_address, s.reason, s.n);

            DECLARE @new_wm datetime2(3) = mon.fn_ServerToUtc((SELECT MAX(LogDate) FROM #EL));
            EXEC mon.usp_SetComponentStatus 'ERRORLOG', 1, @started;
            UPDATE mon.ComponentStatus
               SET watermark_utc = CASE WHEN @new_wm > ISNULL(watermark_utc, '19000101') THEN @new_wm ELSE watermark_utc END
             WHERE component_name = 'ERRORLOG';
        END TRY
        BEGIN CATCH
            DECLARE @en2 int = ERROR_NUMBER(), @em2 nvarchar(2000) = ERROR_MESSAGE();
            EXEC mon.usp_SetComponentStatus 'ERRORLOG', 0, @started, @en2, @em2;
        END CATCH;
    END;
END;
GO

/* ---------------------------------------------------------------------------
   Performance & capacity: CPU (ring buffer), counters, tempdb, storage, and
   hourly cumulative snapshots of wait stats and file I/O stats.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectPerf
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME(),
            @now datetime2(0) = SYSUTCDATETIME(),
            @errors nvarchar(2000) = NULL;

    /* CPU history: one record per minute kept by SQLOS for ~4 hours. */
    BEGIN TRY
        DECLARE @ms_ticks bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);
        DECLARE @last_cpu datetime2(0) = ISNULL((SELECT MAX(sample_utc) FROM mon.CpuSample), '19000101');

        ;WITH RB AS
        (
            SELECT r.[timestamp] AS ts, CONVERT(xml, r.record) AS rec
            FROM sys.dm_os_ring_buffers AS r
            WHERE r.ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
              AND r.record LIKE N'%<SystemHealth>%'
              AND @ms_ticks - r.[timestamp] < 2000000000
        ), V AS
        (
            SELECT CONVERT(datetime2(0), DATEADD(MILLISECOND, -CONVERT(int, @ms_ticks - RB.ts), SYSUTCDATETIME())) AS sample_utc,
                   RB.rec.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS sql_cpu,
                   RB.rec.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS idle
            FROM RB
        )
        INSERT mon.CpuSample(sample_utc, sql_cpu_pct, other_cpu_pct)
        SELECT V.sample_utc, V.sql_cpu,
               CASE WHEN 100 - ISNULL(V.idle, 100) - V.sql_cpu < 0 THEN 0 ELSE 100 - ISNULL(V.idle, 100) - V.sql_cpu END
        FROM V
        WHERE V.sample_utc > DATEADD(SECOND, 30, @last_cpu)
          AND V.sql_cpu BETWEEN 0 AND 100;
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' CPU: ', ERROR_MESSAGE());
    END CATCH;

    /* Counters + tempdb. */
    BEGIN TRY
        INSERT mon.PerfSample(sample_utc, ple_sec, memory_grants_pending, batch_requests_total, user_connections,
                              target_mem_mb, total_mem_mb, tempdb_size_mb, tempdb_used_mb, tempdb_version_store_mb,
                              tempdb_user_obj_mb, tempdb_internal_obj_mb, sqlserver_start_utc)
        SELECT @now, pc.ple, pc.grants, pc.batch, pc.conns, pc.target_kb / 1024, pc.total_kb / 1024,
               tf.size_mb, tf.used_mb, tf.vs_mb, tf.uo_mb, tf.io_mb,
               (SELECT mon.fn_ServerToUtc(sqlserver_start_time) FROM sys.dm_os_sys_info)
        FROM
        (
            SELECT MAX(CASE WHEN RTRIM(counter_name) = N'Page life expectancy' AND object_name LIKE N'%Buffer Manager%' THEN cntr_value END) AS ple,
                   MAX(CASE WHEN RTRIM(counter_name) = N'Memory Grants Pending' THEN cntr_value END) AS grants,
                   MAX(CASE WHEN RTRIM(counter_name) = N'Batch Requests/sec' THEN cntr_value END) AS batch,
                   MAX(CASE WHEN RTRIM(counter_name) = N'User Connections' THEN cntr_value END) AS conns,
                   MAX(CASE WHEN RTRIM(counter_name) = N'Target Server Memory (KB)' THEN cntr_value END) AS target_kb,
                   MAX(CASE WHEN RTRIM(counter_name) = N'Total Server Memory (KB)' THEN cntr_value END) AS total_kb
            FROM sys.dm_os_performance_counters
            WHERE counter_name IN (N'Page life expectancy', N'Memory Grants Pending', N'Batch Requests/sec',
                                   N'User Connections', N'Target Server Memory (KB)', N'Total Server Memory (KB)')
        ) AS pc
        CROSS JOIN
        (
            SELECT SUM(total_page_count) / 128.0 AS size_mb,
                   SUM(total_page_count - unallocated_extent_page_count) / 128.0 AS used_mb,
                   SUM(version_store_reserved_page_count) / 128.0 AS vs_mb,
                   SUM(user_object_reserved_page_count) / 128.0 AS uo_mb,
                   SUM(internal_object_reserved_page_count) / 128.0 AS io_mb
            FROM tempdb.sys.dm_db_file_space_usage
        ) AS tf
        WHERE NOT EXISTS (SELECT 1 FROM mon.PerfSample WHERE sample_utc = @now);
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' Counters: ', ERROR_MESSAGE());
    END CATCH;

    /* SQL-visible storage (CloudWatch FreeStorageSpace stays authoritative on RDS). */
    BEGIN TRY
        INSERT mon.StorageSample(sample_utc, volume_mount_point, total_bytes, available_bytes)
        SELECT @now, COALESCE(NULLIF(v.volume_mount_point, N''), N'(RDS volume)'),
               MAX(v.total_bytes), MIN(v.available_bytes)
        FROM sys.master_files AS f
        CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.file_id) AS v
        GROUP BY COALESCE(NULLIF(v.volume_mount_point, N''), N'(RDS volume)')
        HAVING NOT EXISTS (SELECT 1 FROM mon.StorageSample AS x WHERE x.sample_utc = @now);
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' Storage: ', ERROR_MESSAGE());
    END CATCH;

    /* Hourly cumulative snapshots; deltas are computed at report / evaluation time. */
    IF NOT EXISTS (SELECT 1 FROM mon.WaitStatsSnapshot WHERE snapshot_utc > DATEADD(MINUTE, -55, @now))
    BEGIN
        BEGIN TRY
            INSERT mon.WaitStatsSnapshot(snapshot_utc, wait_type, waiting_tasks, wait_ms, signal_ms)
            SELECT @now, w.wait_type, w.waiting_tasks_count, w.wait_time_ms, w.signal_wait_time_ms
            FROM sys.dm_os_wait_stats AS w
            WHERE w.waiting_tasks_count > 0
              AND w.wait_type NOT LIKE N'SLEEP[_]%'
              AND w.wait_type NOT LIKE N'PREEMPTIVE[_]HADR%'
              AND NOT EXISTS (SELECT 1 FROM mon.WaitTypeIgnore AS i WHERE i.wait_type = w.wait_type);

            INSERT mon.FileStatsSnapshot(snapshot_utc, database_id, file_id, database_name, logical_name, type_desc,
                                         num_reads, io_stall_read_ms, num_writes, io_stall_write_ms, bytes_read, bytes_written)
            SELECT @now, vfs.database_id, vfs.file_id, DB_NAME(vfs.database_id), mf.name, mf.type_desc,
                   vfs.num_of_reads, vfs.io_stall_read_ms, vfs.num_of_writes, vfs.io_stall_write_ms,
                   vfs.num_of_bytes_read, vfs.num_of_bytes_written
            FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
            LEFT JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id;
        END TRY
        BEGIN CATCH
            SET @errors = CONCAT(@errors, N' Hourly snapshots: ', ERROR_MESSAGE());
        END CATCH;
    END;

    IF @errors IS NULL
        EXEC mon.usp_SetComponentStatus 'PERF', 1, @started;
    ELSE
        EXEC mon.usp_SetComponentStatus 'PERF', 0, @started, 50002, @errors;
END;
GO

/* ---------------------------------------------------------------------------
   BLOCKING SAMPLER  (called every sample_interval_seconds by the engine)
   Builds blocking trees from one consistent DMV snapshot, keeps one episode
   per head-blocker connection (session_id + login_time), and stores the
   chain details of every sample for forensics.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CaptureBlocking
    @OpenEpisodes int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 2000;
    SET DEADLOCK_PRIORITY LOW;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE @started datetime2(3) = SYSUTCDATETIME(),
            @now datetime2(0) = SYSUTCDATETIME(),
            @min_ms bigint = ISNULL(mon.fn_SettingInt('blocking_capture_min_seconds'), 15) * 1000,
            @max_rows int = ISNULL(mon.fn_SettingInt('blocking_max_sample_rows'), 200);

    BEGIN TRY
        /* Fast path: nothing blocked -> just close open episodes. */
        /* dm_os_waiting_tasks (not dm_exec_requests) so blocked PARALLEL queries are seen too:
           their request row shows CXPACKET/CXCONSUMER while a worker task waits on the lock. */
        IF NOT EXISTS (SELECT 1 FROM sys.dm_os_waiting_tasks
                       WHERE blocking_session_id > 0 AND blocking_session_id <> session_id)
        BEGIN
            UPDATE mon.BlockingEpisode SET is_open = 0, ended_utc = last_seen_utc WHERE is_open = 1;
            SET @OpenEpisodes = 0;
            EXEC mon.usp_SetComponentStatus 'BLOCKING', 1, @started;
            RETURN;
        END;

        /* One consistent snapshot of all requests, one row per session (MARS can return several). */
        ;WITH R AS
        (
            SELECT r.session_id, r.blocking_session_id, r.wait_type, CONVERT(bigint, r.wait_time) AS wait_ms,
                   r.wait_resource, r.database_id, r.command, r.status, r.start_time,
                   r.sql_handle, r.statement_start_offset, r.statement_end_offset,
                   ROW_NUMBER() OVER (PARTITION BY r.session_id
                                      ORDER BY CASE WHEN r.blocking_session_id > 0 THEN 0 ELSE 1 END, r.wait_time DESC) AS rn
            FROM sys.dm_exec_requests AS r
            WHERE r.session_id <> @@SPID
        )
        SELECT session_id, blocking_session_id, wait_type, wait_ms, wait_resource, database_id, command, status,
               start_time, sql_handle, statement_start_offset, statement_end_offset
        INTO #Req
        FROM R WHERE rn = 1;

        /* Blocked edges from waiting tasks: one blocker per session (longest wait), self-waits excluded. */
        ;WITH W AS
        (
            SELECT wt.session_id, wt.blocking_session_id, CONVERT(bigint, wt.wait_duration_ms) AS wait_ms,
                   ROW_NUMBER() OVER (PARTITION BY wt.session_id ORDER BY wt.wait_duration_ms DESC) AS rn
            FROM sys.dm_os_waiting_tasks AS wt
            WHERE wt.session_id > 0
              AND wt.blocking_session_id > 0
              AND wt.blocking_session_id <> wt.session_id
              AND wt.session_id <> @@SPID
        )
        SELECT session_id, blocking_session_id, wait_ms
        INTO #Edge
        FROM W WHERE rn = 1;

        ;WITH Heads AS
        (
            SELECT DISTINCT e.blocking_session_id AS head
            FROM #Edge AS e
            WHERE NOT EXISTS (SELECT 1 FROM #Edge AS x WHERE x.session_id = e.blocking_session_id)
        ), Tree AS
        (
            SELECT h.head, e.session_id, e.blocking_session_id, e.wait_ms, CONVERT(int, 1) AS lvl
            FROM Heads AS h JOIN #Edge AS e ON e.blocking_session_id = h.head
            UNION ALL
            SELECT t.head, e.session_id, e.blocking_session_id, e.wait_ms, t.lvl + 1
            FROM Tree AS t JOIN #Edge AS e ON e.blocking_session_id = t.session_id
            WHERE t.lvl < 50
        )
        SELECT head, session_id, blocking_session_id, wait_ms, lvl
        INTO #Tree
        FROM Tree
        OPTION (MAXRECURSION 60);

        /* Qualifying heads: something in the tree has waited at least the capture threshold. */
        SELECT t.head,
               COUNT(*) AS blocked_count,
               MAX(t.wait_ms) AS max_wait_ms,
               /* start = longest DIRECT wait on this head (a new head must not inherit an older chain's age) */
               DATEADD(SECOND, -CONVERT(int, ISNULL(MAX(CASE WHEN t.lvl = 1 THEN t.wait_ms END), MAX(t.wait_ms)) / 1000), @now) AS blocked_since_utc
        INTO #Head
        FROM #Tree AS t
        GROUP BY t.head
        HAVING MAX(t.wait_ms) >= @min_ms;

        /* Head details (session may be sleeping with an open transaction: no request row). */
        SELECT h.head, h.blocked_count, h.max_wait_ms, h.blocked_since_utc,
               s.login_time, s.status AS head_status, s.login_name, s.host_name, s.program_name,
               DB_NAME(s.database_id) AS head_database, s.open_transaction_count,
               hr.command AS head_command, hr.wait_type AS head_wait_type,
               LEFT(COALESCE(
                    CASE WHEN hr.sql_handle IS NOT NULL THEN
                        SUBSTRING(ht.text, hr.statement_start_offset / 2 + 1,
                                  (CASE hr.statement_end_offset WHEN -1 THEN DATALENGTH(ht.text)
                                        ELSE hr.statement_end_offset END - hr.statement_start_offset) / 2 + 1) END,
                    ct.text), 4000) AS head_sql,
               LEFT(ib.event_info, 4000) AS head_input_buffer,
               tr.tran_begin_utc,
               w.top_wait_type, w.top_wait_resource, w.blocked_sql, w.dbs
        INTO #HeadInfo
        FROM #Head AS h
        JOIN sys.dm_exec_sessions AS s ON s.session_id = h.head
        LEFT JOIN #Req AS hr ON hr.session_id = h.head
        OUTER APPLY sys.dm_exec_sql_text(hr.sql_handle) AS ht
        LEFT JOIN sys.dm_exec_connections AS c ON c.session_id = h.head AND c.parent_connection_id IS NULL
        OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS ct
        OUTER APPLY sys.dm_exec_input_buffer(h.head, NULL) AS ib
        OUTER APPLY
        (
            SELECT mon.fn_ServerToUtc(MIN(at.transaction_begin_time)) AS tran_begin_utc
            FROM sys.dm_tran_session_transactions AS st
            JOIN sys.dm_tran_active_transactions AS at ON at.transaction_id = st.transaction_id
            WHERE st.session_id = h.head
        ) AS tr
        OUTER APPLY
        (
            SELECT TOP (1) q.wait_type AS top_wait_type, q.wait_resource AS top_wait_resource,
                   LEFT(SUBSTRING(qt.text, q.statement_start_offset / 2 + 1,
                                  (CASE q.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text)
                                        ELSE q.statement_end_offset END - q.statement_start_offset) / 2 + 1), 2000) AS blocked_sql,
                   STUFF((SELECT DISTINCT N', ' + DB_NAME(q2.database_id)
                          FROM #Tree AS t2 JOIN #Req AS q2 ON q2.session_id = t2.session_id
                          WHERE t2.head = h.head
                          FOR XML PATH(''), TYPE).value('(./text())[1]', 'nvarchar(1000)'), 1, 2, N'') AS dbs
            FROM #Tree AS t
            JOIN #Req AS q ON q.session_id = t.session_id
            OUTER APPLY sys.dm_exec_sql_text(q.sql_handle) AS qt
            WHERE t.head = h.head
            ORDER BY t.wait_ms DESC
        ) AS w;

        /* Episode upsert: same head connection = same episode. */
        UPDATE e
           SET e.last_seen_utc        = @now,
               e.sample_count         = e.sample_count + 1,
               e.blocked_since_utc    = CASE WHEN i.blocked_since_utc < e.blocked_since_utc THEN i.blocked_since_utc ELSE e.blocked_since_utc END,
               e.max_blocked_count    = CASE WHEN i.blocked_count > e.max_blocked_count THEN i.blocked_count ELSE e.max_blocked_count END,
               e.max_wait_ms          = CASE WHEN i.max_wait_ms > e.max_wait_ms THEN i.max_wait_ms ELSE e.max_wait_ms END,
               e.head_status          = i.head_status,
               e.head_database        = i.head_database,
               e.head_open_tran_count = i.open_transaction_count,
               e.head_tran_begin_utc  = COALESCE(i.tran_begin_utc, e.head_tran_begin_utc),
               e.head_command         = i.head_command,
               e.head_wait_type       = i.head_wait_type,
               e.head_sql             = COALESCE(i.head_sql, e.head_sql),
               e.head_input_buffer    = COALESCE(i.head_input_buffer, e.head_input_buffer),
               e.top_wait_type        = COALESCE(i.top_wait_type, e.top_wait_type),
               e.top_wait_resource    = COALESCE(i.top_wait_resource, e.top_wait_resource),
               e.blocked_sql_sample   = COALESCE(e.blocked_sql_sample, i.blocked_sql),
               e.databases_affected   = COALESCE(i.dbs, e.databases_affected)
        FROM mon.BlockingEpisode AS e
        JOIN #HeadInfo AS i ON i.head = e.head_session_id AND i.login_time = e.head_login_time
        WHERE e.is_open = 1;

        INSERT mon.BlockingEpisode
            (head_session_id, head_login_time, blocked_since_utc, first_sample_utc, last_seen_utc, is_open,
             sample_count, max_blocked_count, max_wait_ms, head_status, head_login, head_host, head_program,
             head_database, head_open_tran_count, head_tran_begin_utc, head_command, head_wait_type, head_sql,
             head_input_buffer, top_wait_type, top_wait_resource, blocked_sql_sample, databases_affected)
        SELECT i.head, i.login_time, i.blocked_since_utc, @now, @now, 1,
               1, i.blocked_count, i.max_wait_ms, i.head_status, i.login_name, i.host_name, i.program_name,
               i.head_database, i.open_transaction_count, i.tran_begin_utc, i.head_command, i.head_wait_type, i.head_sql,
               i.head_input_buffer, i.top_wait_type, i.top_wait_resource, i.blocked_sql, i.dbs
        FROM #HeadInfo AS i
        WHERE i.login_time IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM mon.BlockingEpisode AS e
                          WHERE e.is_open = 1 AND e.head_session_id = i.head AND e.head_login_time = i.login_time);

        /* Close episodes whose head is no longer blocking anybody long enough. */
        UPDATE e SET e.is_open = 0, e.ended_utc = e.last_seen_utc
        FROM mon.BlockingEpisode AS e
        WHERE e.is_open = 1
          AND NOT EXISTS (SELECT 1 FROM #HeadInfo AS i
                          WHERE i.head = e.head_session_id AND i.login_time = e.head_login_time);

        /* Chain details for forensics. */
        INSERT mon.BlockingSample(sample_utc, episode_id, session_id, blocking_session_id, chain_level, wait_type,
                                  wait_ms, wait_resource, database_name, login_name, host_name, program_name, statement_text)
        SELECT TOP (@max_rows) @now, e.episode_id, t.session_id, t.blocking_session_id, t.lvl, q.wait_type, t.wait_ms,
               q.wait_resource, DB_NAME(q.database_id), s.login_name, s.host_name, s.program_name,
               LEFT(SUBSTRING(qt.text, q.statement_start_offset / 2 + 1,
                              (CASE q.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text)
                                    ELSE q.statement_end_offset END - q.statement_start_offset) / 2 + 1), 2000)
        FROM #Tree AS t
        JOIN #HeadInfo AS i ON i.head = t.head
        JOIN mon.BlockingEpisode AS e ON e.is_open = 1 AND e.head_session_id = i.head AND e.head_login_time = i.login_time
        JOIN #Req AS q ON q.session_id = t.session_id
        LEFT JOIN sys.dm_exec_sessions AS s ON s.session_id = t.session_id
        OUTER APPLY sys.dm_exec_sql_text(q.sql_handle) AS qt
        WHERE NOT EXISTS (SELECT 1 FROM mon.BlockingSample AS b WHERE b.sample_utc = @now AND b.session_id = t.session_id)
        ORDER BY t.wait_ms DESC;

        SET @OpenEpisodes = (SELECT COUNT(*) FROM mon.BlockingEpisode WHERE is_open = 1);
        EXEC mon.usp_SetComponentStatus 'BLOCKING', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'BLOCKING', 0, @started, @en, @em;
        SET @OpenEpisodes = NULL;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------------
   OLA HALLENGREN COMMANDLOG COLLECTOR   [rev 5.2]
   Finds dbo.CommandLog (setting ola_commandlog_database, or auto-discovery in every
   online database + master), imports new rows incrementally and re-reads rows that
   were still running (EndTime NULL) so their outcome is captured.
   Parses BACKUP commands: backup type (FULL/DIFF/LOG), target file and number of files.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectOlaCommandLog
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;   /* never block Ola while it writes its log */

    DECLARE @started datetime2(3) = SYSUTCDATETIME(), @now datetime2(0) = SYSUTCDATETIME(),
            @cfg sysname = NULLIF(LTRIM(RTRIM(mon.fn_Setting('ola_commandlog_database'))), N''),
            @init_days int = ISNULL(mon.fn_SettingInt('ola_initial_load_days'), 35),
            @db sysname, @from_id bigint, @sql nvarchar(max), @errors nvarchar(2000) = NULL;

    BEGIN TRY
        /* ---- discovery (hourly, or immediately when configured explicitly) ---- */
        IF @cfg IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM mon.OlaSource WHERE database_name = @cfg)
                INSERT mon.OlaSource(database_name) VALUES (@cfg);
            UPDATE mon.OlaSource SET is_active = CASE WHEN database_name = @cfg THEN 1 ELSE 0 END;
        END
        ELSE
            UPDATE mon.OlaSource SET is_active = 0
            WHERE database_name NOT IN (SELECT name FROM sys.databases WHERE state_desc = N'ONLINE');

        IF @cfg IS NULL AND NOT EXISTS (SELECT 1 FROM mon.ComponentStatus WHERE component_name = 'OLA_DISCOVERY'
                            AND last_success_utc > DATEADD(HOUR, -1, SYSUTCDATETIME()))
        BEGIN
            DECLARE d CURSOR LOCAL FAST_FORWARD FOR
                SELECT name FROM sys.databases
                WHERE state_desc = N'ONLINE' AND (database_id > 4 OR name = N'master')
                  AND name NOT IN (N'rdsadmin', N'tempdb', N'model') AND source_database_id IS NULL;
            OPEN d;
            FETCH NEXT FROM d INTO @db;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF OBJECT_ID(QUOTENAME(@db) + N'.dbo.CommandLog', N'U') IS NOT NULL
                   AND COL_LENGTH(QUOTENAME(@db) + N'.dbo.CommandLog', N'CommandType') IS NOT NULL
                BEGIN
                    IF NOT EXISTS (SELECT 1 FROM mon.OlaSource WHERE database_name = @db)
                        INSERT mon.OlaSource(database_name) VALUES (@db);
                    ELSE
                        UPDATE mon.OlaSource SET is_active = 1 WHERE database_name = @db;
                END
                ELSE
                    UPDATE mon.OlaSource SET is_active = 0 WHERE database_name = @db;
                FETCH NEXT FROM d INTO @db;
            END;
            CLOSE d;
            DEALLOCATE d;
            EXEC mon.usp_SetComponentStatus 'OLA_DISCOVERY', 1, NULL;
        END;

        /* ---- incremental import ---- */
        CREATE TABLE #C
        (
            ola_id bigint PRIMARY KEY, database_name sysname COLLATE DATABASE_DEFAULT NULL,
            command_type nvarchar(60) COLLATE DATABASE_DEFAULT, object_name nvarchar(300) COLLATE DATABASE_DEFAULT NULL,
            index_name sysname COLLATE DATABASE_DEFAULT NULL, statistics_name sysname COLLATE DATABASE_DEFAULT NULL,
            command nvarchar(max) COLLATE DATABASE_DEFAULT NULL, start_time datetime2(3), end_time datetime2(3) NULL,
            error_number int NULL, error_message nvarchar(2000) COLLATE DATABASE_DEFAULT NULL
        );

        DECLARE s CURSOR LOCAL FAST_FORWARD FOR SELECT database_name FROM mon.OlaSource WHERE is_active = 1;
        OPEN s;
        FETCH NEXT FROM s INTO @db;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                TRUNCATE TABLE #C;
                /* restart point: oldest still-running command of the last 2 days, else the high-water mark */
                SET @from_id = ISNULL((SELECT MIN(ola_id) - 1 FROM mon.OlaCommand
                                       WHERE source_db = @db AND end_utc IS NULL
                                         AND start_utc > DATEADD(DAY, -2, @now)),
                                      (SELECT last_id FROM mon.OlaSource WHERE database_name = @db));

                SET @sql = N'
                    SELECT c.ID, c.DatabaseName, c.CommandType,
                           CASE WHEN c.ObjectName IS NOT NULL THEN CONCAT(c.SchemaName, N''.'', c.ObjectName) END,
                           c.IndexName, c.StatisticsName, c.Command, c.StartTime, c.EndTime, c.ErrorNumber,
                           LEFT(c.ErrorMessage, 2000)
                    FROM ' + QUOTENAME(@db) + N'.dbo.CommandLog AS c
                    WHERE c.ID > @from_id
                      AND c.StartTime >= DATEADD(DAY, -@init_days, GETDATE());';
                INSERT #C EXEC sys.sp_executesql @sql, N'@from_id bigint, @init_days int', @from_id = @from_id, @init_days = @init_days;

                ;WITH P AS
                (
                    SELECT c.*,
                           UPPER(REPLACE(REPLACE(REPLACE(c.command, NCHAR(13), N' '), NCHAR(10), N' '), NCHAR(9), N' ')) AS u
                    FROM #C AS c
                ), Q AS
                (
                    SELECT P.*,
                           CASE WHEN P.command_type LIKE N'BACKUP[_]LOG%' OR P.u LIKE N'%BACKUP LOG%' THEN 'LOG'
                                WHEN P.command_type LIKE N'BACKUP%' AND P.u LIKE N'%DIFFERENTIAL%' THEN 'DIFF'
                                WHEN P.command_type LIKE N'BACKUP%' THEN 'FULL' END AS btype,
                           CHARINDEX(N'DISK = N''', P.u) AS p_disk,
                           CHARINDEX(N'URL = N''', P.u) AS p_url,
                           (LEN(P.u) - LEN(REPLACE(P.u, N'DISK = N''', N''))) / 9
                         + (LEN(P.u) - LEN(REPLACE(P.u, N'URL = N''', N''))) / 8 AS n_files
                    FROM P
                )
                MERGE mon.OlaCommand AS t
                USING
                (
                    SELECT Q.ola_id, Q.database_name, Q.command_type, Q.object_name, Q.index_name, Q.statistics_name,
                           LEFT(Q.command, 4000) AS command,
                           CASE WHEN Q.command_type LIKE N'BACKUP%' THEN Q.btype END AS backup_type,
                           CASE WHEN Q.command_type LIKE N'BACKUP%' AND (Q.p_disk > 0 OR Q.p_url > 0) THEN
                                LEFT(SUBSTRING(Q.command,
                                               CASE WHEN Q.p_disk > 0 THEN Q.p_disk + 9 ELSE Q.p_url + 8 END,
                                               ISNULL(NULLIF(CHARINDEX(N'''', Q.command,
                                                   CASE WHEN Q.p_disk > 0 THEN Q.p_disk + 9 ELSE Q.p_url + 8 END), 0), LEN(Q.command) + 1)
                                               - CASE WHEN Q.p_disk > 0 THEN Q.p_disk + 9 ELSE Q.p_url + 8 END), 1000) END AS backup_file,
                           CASE WHEN Q.command_type LIKE N'BACKUP%' THEN NULLIF(Q.n_files, 0) END AS file_count,
                           CONVERT(datetime2(0), mon.fn_ServerToUtc(Q.start_time)) AS start_utc,
                           CONVERT(datetime2(0), mon.fn_ServerToUtc(Q.end_time)) AS end_utc,
                           DATEDIFF(SECOND, Q.start_time, Q.end_time) AS duration_s,
                           Q.error_number, Q.error_message
                    FROM Q
                ) AS x
                ON t.source_db = @db AND t.ola_id = x.ola_id
                WHEN MATCHED AND (t.end_utc IS NULL OR ISNULL(t.error_number, -1) <> ISNULL(x.error_number, -1)) THEN UPDATE SET
                    end_utc = x.end_utc, duration_s = x.duration_s, error_number = x.error_number,
                    error_message = x.error_message, collected_utc = @now
                WHEN NOT MATCHED THEN INSERT
                    (source_db, ola_id, database_name, command_type, object_name, index_name, statistics_name, command,
                     backup_type, backup_file, file_count, start_utc, end_utc, duration_s, error_number, error_message)
                VALUES
                    (@db, x.ola_id, x.database_name, x.command_type, x.object_name, x.index_name, x.statistics_name, x.command,
                     x.backup_type, x.backup_file, x.file_count, x.start_utc, x.end_utc, x.duration_s, x.error_number, x.error_message);

                UPDATE mon.OlaSource
                   SET last_id = CASE WHEN (SELECT MAX(ola_id) FROM #C) > last_id THEN (SELECT MAX(ola_id) FROM #C) ELSE last_id END,
                       last_read_utc = @now
                 WHERE database_name = @db;
            END TRY
            BEGIN CATCH
                SET @errors = LEFT(CONCAT(@errors, N' ', @db, N': ', ERROR_MESSAGE()), 2000);
            END CATCH;
            FETCH NEXT FROM s INTO @db;
        END;
        CLOSE s;
        DEALLOCATE s;

        IF @errors IS NULL
            EXEC mon.usp_SetComponentStatus 'OLA_COMMANDLOG', 1, @started;
        ELSE
            EXEC mon.usp_SetComponentStatus 'OLA_COMMANDLOG', 0, @started, 50004, @errors;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'OLA_COMMANDLOG', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* Ola maintenance overview for SSMS. */
CREATE OR ALTER PROCEDURE mon.usp_ShowOlaLog
    @Hours    int = 24,
    @Database sysname = N'%'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @since datetime2(0) = DATEADD(HOUR, -@Hours, SYSUTCDATETIME()),
            @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');

    /* 1. Summary per command type */
    SELECT o.command_type AS [Command type], COUNT(*) AS [Commands],
           SUM(CASE WHEN ISNULL(o.error_number, 0) <> 0 THEN 1 ELSE 0 END) AS [Failed],
           SUM(CASE WHEN o.end_utc IS NULL THEN 1 ELSE 0 END) AS [Running / unfinished],
           mon.fn_Duration(SUM(CONVERT(bigint, o.duration_s))) AS [Total time],
           mon.fn_Duration(MAX(o.duration_s)) AS [Longest],
           COUNT(DISTINCT o.database_name) AS [Databases],
           SUM(ISNULL(o.file_count, 0)) AS [Backup files],
           mon.fn_UtcToLocal(MAX(o.start_utc), @tz) AS [Last start (local)]
    FROM mon.OlaCommand AS o
    WHERE o.start_utc >= @since AND ISNULL(o.database_name, N'') LIKE @Database
    GROUP BY o.command_type
    ORDER BY [Failed] DESC, o.command_type;

    /* 2. Failures */
    SELECT mon.fn_UtcToLocal(o.start_utc, @tz) AS [Start (local)], o.database_name AS [Database], o.command_type AS [Type],
           o.object_name AS [Object], o.index_name AS [Index], o.error_number AS [Error], o.error_message AS [Message],
           o.command AS [Command], o.source_db AS [CommandLog in]
    FROM mon.OlaCommand AS o
    WHERE o.start_utc >= @since AND ISNULL(o.error_number, 0) <> 0 AND ISNULL(o.database_name, N'') LIKE @Database
    ORDER BY o.start_utc DESC;

    /* 3. Last successful CHECKDB / FULL / DIFF / LOG per database according to Ola */
    SELECT o.database_name AS [Database],
           mon.fn_UtcToLocal(MAX(CASE WHEN o.command_type = N'DBCC_CHECKDB' THEN o.end_utc END), @tz) AS [Last CHECKDB ok],
           mon.fn_Duration(MAX(CASE WHEN o.command_type = N'DBCC_CHECKDB' THEN o.duration_s END)) AS [Longest CHECKDB],
           mon.fn_UtcToLocal(MAX(CASE WHEN o.backup_type = 'FULL' THEN o.end_utc END), @tz) AS [Last FULL ok],
           mon.fn_UtcToLocal(MAX(CASE WHEN o.backup_type = 'DIFF' THEN o.end_utc END), @tz) AS [Last DIFF ok],
           mon.fn_UtcToLocal(MAX(CASE WHEN o.backup_type = 'LOG'  THEN o.end_utc END), @tz) AS [Last LOG ok],
           SUM(CASE WHEN o.command_type IN (N'ALTER_INDEX') THEN 1 ELSE 0 END) AS [Index ops],
           SUM(CASE WHEN o.command_type IN (N'UPDATE_STATISTICS') THEN 1 ELSE 0 END) AS [Stats updates]
    FROM mon.OlaCommand AS o
    WHERE ISNULL(o.error_number, 0) = 0 AND o.end_utc IS NOT NULL AND o.database_name LIKE @Database
    GROUP BY o.database_name
    ORDER BY o.database_name;

    /* 4. Where the CommandLog was found */
    SELECT database_name AS [CommandLog database], is_active AS [Active], last_id AS [Last ID read],
           mon.fn_UtcToLocal(last_read_utc, @tz) AS [Last read (local)]
    FROM mon.OlaSource;
END;
GO

/* =============================================================================
   SECTION 7  -  HEALTH VIEWS
   ============================================================================= */

CREATE OR ALTER VIEW mon.vw_BackupHealth
AS
WITH B AS
(
    SELECT p.database_name,
           ISNULL(dc.monitored, 1) AS is_monitored,       /* on/off flags come from the check matrix */
           ISNULL(dc.full_backup, 1) AS require_full, ISNULL(dc.diff_backup, 1) AS require_diff,
           ISNULL(dc.log_backup, 1) AS require_log, ISNULL(dc.checkdb, 1) AS require_checkdb,
           p.full_max_age_minutes, p.diff_max_age_minutes, p.log_max_age_minutes, p.checkdb_max_age_days,
           ISNULL(s.is_present, 0) AS is_present, s.state_desc, s.recovery_model, s.create_date_utc,
           /* CHECKDB: newest of DATABASEPROPERTYEX / DBCC DBINFO (DatabaseStatus) and Ola CommandLog DBCC_CHECKDB */
           CASE WHEN oc.last_ok_utc > ISNULL(s.last_checkdb_utc, '19000101') THEN oc.last_ok_utc ELSE s.last_checkdb_utc END AS last_checkdb_utc,
           CASE WHEN oc.last_ok_utc > ISNULL(s.last_checkdb_utc, '19000101') THEN 'OLA' ELSE s.checkdb_source END AS checkdb_source,
           ol.start_utc AS checkdb_last_attempt_utc, ol.duration_s AS checkdb_last_duration_s,
           ol.error_number AS checkdb_last_error, ol.error_message AS checkdb_last_error_message,
           s.data_size_mb, s.data_used_mb, s.log_size_mb, s.log_used_pct, s.vlf_total,
           s.log_reuse_wait_desc,
           b.full_finish_utc, b.full_duration_s, b.full_size_bytes, b.full_source, b.full_location,
           b.diff_finish_utc, b.diff_duration_s, b.diff_size_bytes, b.diff_source,
           b.log_finish_utc, b.log_size_bytes, b.log_source, b.log_chain_broken,
           CASE WHEN b.full_finish_utc IS NULL OR b.diff_finish_utc > b.full_finish_utc
                THEN b.diff_finish_utc ELSE b.full_finish_utc END AS effective_data_utc,
           CONVERT(datetime2(0), SYSUTCDATETIME()) AS now_utc,
           cd.checkdb_supported
    FROM mon.DatabasePolicy AS p
    LEFT JOIN mon.DatabaseCheck  AS dc ON dc.database_name = p.database_name
    LEFT JOIN mon.DatabaseStatus AS s ON s.database_name = p.database_name
    LEFT JOIN mon.BackupStatus   AS b ON b.database_name = p.database_name
    OUTER APPLY (SELECT MAX(o.end_utc) AS last_ok_utc FROM mon.OlaCommand AS o
                 WHERE o.database_name = p.database_name AND o.command_type = N'DBCC_CHECKDB'
                   AND ISNULL(o.error_number, 0) = 0 AND o.end_utc IS NOT NULL) AS oc
    OUTER APPLY (SELECT TOP (1) o.start_utc, o.duration_s, o.error_number, o.error_message FROM mon.OlaCommand AS o
                 WHERE o.database_name = p.database_name AND o.command_type = N'DBCC_CHECKDB'
                 ORDER BY o.start_utc DESC) AS ol
    CROSS JOIN (SELECT CASE WHEN COUNT(last_checkdb_utc) > 0
                              OR EXISTS (SELECT 1 FROM mon.OlaCommand WHERE command_type = N'DBCC_CHECKDB') THEN 1 ELSE 0 END AS checkdb_supported
                FROM mon.DatabaseStatus) AS cd
)
SELECT B.*,
       DATEDIFF(MINUTE, B.full_finish_utc, B.now_utc)    AS full_age_min,
       DATEDIFF(MINUTE, B.effective_data_utc, B.now_utc) AS diff_age_min,
       DATEDIFF(MINUTE, B.log_finish_utc, B.now_utc)     AS log_age_min,
       DATEDIFF(HOUR, B.last_checkdb_utc, B.now_utc)     AS checkdb_age_hours,
       CASE
           WHEN B.is_monitored = 0 THEN 'NOT_MONITORED'
           WHEN B.is_present = 0 THEN 'NOT_FOUND'
           WHEN B.state_desc <> N'ONLINE' THEN 'NOT_ONLINE'
           WHEN B.require_full = 0 THEN 'NOT_REQUIRED'
           WHEN B.full_finish_utc IS NULL AND B.create_date_utc > DATEADD(MINUTE, -B.full_max_age_minutes, B.now_utc) THEN 'PENDING'
           WHEN B.full_finish_utc IS NULL THEN 'MISSING'
           WHEN DATEDIFF(MINUTE, B.full_finish_utc, B.now_utc) > B.full_max_age_minutes THEN 'OVERDUE'
           ELSE 'OK'
       END AS full_status,
       CASE
           WHEN B.is_monitored = 0 THEN 'NOT_MONITORED'
           WHEN B.is_present = 0 THEN 'NOT_FOUND'
           WHEN B.state_desc <> N'ONLINE' THEN 'NOT_ONLINE'
           WHEN B.require_diff = 0 THEN 'NOT_REQUIRED'
           WHEN B.full_finish_utc IS NULL AND B.diff_finish_utc IS NULL THEN 'NEEDS_FULL'   /* one cause, one alert (FULL) */
           WHEN B.effective_data_utc IS NULL AND B.create_date_utc > DATEADD(MINUTE, -B.full_max_age_minutes, B.now_utc) THEN 'PENDING'
           WHEN B.effective_data_utc IS NULL THEN 'MISSING'
           WHEN DATEDIFF(MINUTE, B.effective_data_utc, B.now_utc) > B.diff_max_age_minutes THEN 'OVERDUE'
           ELSE 'OK'
       END AS diff_status,
       CASE
           WHEN B.is_monitored = 0 THEN 'NOT_MONITORED'
           WHEN B.is_present = 0 THEN 'NOT_FOUND'
           WHEN B.state_desc <> N'ONLINE' THEN 'NOT_ONLINE'
           WHEN B.require_log = 0 OR B.recovery_model <> N'FULL' THEN 'NOT_REQUIRED'
           WHEN B.log_chain_broken = 1 THEN 'CHAIN_BROKEN'
           WHEN B.log_finish_utc IS NULL
                AND (B.full_finish_utc IS NULL OR B.create_date_utc > DATEADD(MINUTE, -B.log_max_age_minutes, B.now_utc)) THEN 'PENDING'
           WHEN B.log_finish_utc IS NULL THEN 'MISSING'
           WHEN DATEDIFF(MINUTE, B.log_finish_utc, B.now_utc) > B.log_max_age_minutes THEN 'OVERDUE'
           ELSE 'OK'
       END AS log_status,
       CASE
           WHEN B.is_monitored = 0 THEN 'NOT_MONITORED'
           WHEN B.is_present = 0 OR B.state_desc <> N'ONLINE' THEN 'NOT_ONLINE'
           WHEN B.require_checkdb = 0 THEN 'NOT_REQUIRED'
           WHEN B.checkdb_supported = 0 THEN 'UNKNOWN'
           WHEN B.last_checkdb_utc IS NULL AND B.create_date_utc > DATEADD(DAY, -B.checkdb_max_age_days, B.now_utc) THEN 'PENDING'
           WHEN B.last_checkdb_utc IS NULL THEN 'NEVER'
           WHEN DATEDIFF(HOUR, B.last_checkdb_utc, B.now_utc) > B.checkdb_max_age_days * 24 THEN 'OVERDUE'
           ELSE 'OK'
       END AS checkdb_status
FROM B;
GO

CREATE OR ALTER VIEW mon.vw_JobDurationBaseline
AS
SELECT DISTINCT r.job_id,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY r.duration_s) OVER (PARTITION BY r.job_id) AS median_s,
       COUNT(*) OVER (PARTITION BY r.job_id) AS successful_runs
FROM mon.AgentJobRun AS r
WHERE r.run_status = 1
  AND r.run_start_utc >= DATEADD(DAY, -ISNULL(mon.fn_SettingInt('job_duration_baseline_days'), 30), SYSUTCDATETIME());
GO

CREATE OR ALTER VIEW mon.vw_JobHealth
AS
SELECT p.job_id, p.job_name, p.job_type, p.max_hours_since_success, p.is_monitored,
       j.enabled AS agent_enabled,
       lr.run_status AS last_run_status, lr.run_start_utc AS last_run_utc, lr.duration_s AS last_duration_s,
       lr.message AS last_message, ls.last_success_utc, bl.median_s, bl.successful_runs,
       CASE
           WHEN j.job_id IS NULL THEN 'NOT_FOUND'
           WHEN p.is_monitored = 0 THEN 'NOT_MONITORED'
           WHEN j.enabled = 0 THEN 'DISABLED'
           WHEN lr.run_status IN (0, 3) THEN 'FAILED'
           WHEN ls.last_success_utc IS NULL THEN 'NEVER_SUCCEEDED'
           WHEN DATEDIFF(MINUTE, ls.last_success_utc, SYSUTCDATETIME()) > p.max_hours_since_success * 60 THEN 'OVERDUE'
           ELSE 'OK'
       END AS health_status
FROM mon.JobPolicy AS p
LEFT JOIN msdb.dbo.sysjobs AS j ON j.job_id = p.job_id
OUTER APPLY (SELECT TOP (1) r.run_status, r.run_start_utc, r.duration_s, r.message
             FROM mon.AgentJobRun AS r WHERE r.job_id = p.job_id
             ORDER BY r.run_start_utc DESC, r.instance_id DESC) AS lr
OUTER APPLY (SELECT MAX(r.run_start_utc) AS last_success_utc
             FROM mon.AgentJobRun AS r WHERE r.job_id = p.job_id AND r.run_status = 1) AS ls
LEFT JOIN mon.vw_JobDurationBaseline AS bl ON bl.job_id = p.job_id;
GO

CREATE OR ALTER VIEW mon.vw_ActiveIssues
AS
SELECT i.issue_id, i.severity, i.category, i.database_name, i.title, i.detail, i.issue_key,
       i.is_event, i.is_muted, i.first_seen_utc, i.last_seen_utc,
       DATEDIFF(MINUTE, i.first_seen_utc, SYSUTCDATETIME()) AS open_minutes,
       i.alert_sent_utc, i.alert_severity
FROM mon.Issue AS i
WHERE i.is_active = 1;
GO

CREATE OR ALTER VIEW mon.vw_RecentChanges
AS
SELECT c.change_id, c.change_utc, c.change_type, c.old_severity, c.new_severity, c.alert_status,
       i.category, i.database_name, i.title, i.issue_key, i.is_event
FROM mon.IssueChange AS c
JOIN mon.Issue AS i ON i.issue_id = c.issue_id
WHERE c.change_utc >= DATEADD(DAY, -7, SYSUTCDATETIME());
GO

CREATE OR ALTER VIEW mon.vw_BlockingNow
AS
SELECT e.episode_id, e.head_session_id, e.head_login, e.head_host, e.head_program, e.head_status,
       e.head_open_tran_count, e.head_tran_begin_utc,
       DATEDIFF(SECOND, e.blocked_since_utc, e.last_seen_utc) AS duration_s,
       e.max_blocked_count, e.top_wait_type, e.top_wait_resource, e.databases_affected,
       e.head_sql, e.head_input_buffer, e.blocked_sql_sample,
       s.session_id AS blocked_session_id, s.blocking_session_id, s.chain_level, s.wait_type, s.wait_ms,
       s.wait_resource, s.login_name, s.host_name, s.program_name, s.statement_text
FROM mon.BlockingEpisode AS e
LEFT JOIN mon.BlockingSample AS s
       ON s.episode_id = e.episode_id
      AND s.sample_utc = (SELECT MAX(x.sample_utc) FROM mon.BlockingSample AS x WHERE x.episode_id = e.episode_id)
WHERE e.is_open = 1;
GO

/* =============================================================================
   SECTION 8  -  ISSUE ENGINE
   @Scope = 'ALL'       every check (full cycle, every 5 min)
          = 'BLOCKING'  blocking only (every sample, 30 s)
          = 'WATCHDOG'  engine heartbeat only (digest job, hourly)
   A category is auto-resolved only when its check ran successfully in this
   pass AND the collector feeding it succeeded on its last attempt, so a
   broken collector never produces false "RESOLVED" mail.
   ============================================================================= */
CREATE OR ALTER PROCEDURE mon.usp_EvaluateIssues
    @Scope varchar(10) = 'ALL'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @now datetime2(0) = SYSUTCDATETIME(), @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @tz nvarchar(100)   = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time'),
            @grace int          = ISNULL(mon.fn_SettingInt('resolve_grace_minutes'), 10),
            @lookback int       = ISNULL(mon.fn_SettingInt('event_lookback_hours'), 24),
            @blk_min int        = ISNULL(mon.fn_SettingInt('blocking_alert_minutes'), 10),
            @lq_warn int        = ISNULL(mon.fn_SettingInt('long_query_warn_minutes'), 30),
            @lq_crit int        = ISNULL(mon.fn_SettingInt('long_query_crit_minutes'), 120),
            @lq_ex_agent bit    = ISNULL(mon.fn_SettingInt('long_query_exclude_agent'), 1),
            @ot_warn int        = ISNULL(mon.fn_SettingInt('open_tran_warn_minutes'), 15),
            @ot_crit int        = ISNULL(mon.fn_SettingInt('open_tran_crit_minutes'), 60),
            @jd_factor decimal(9,2) = ISNULL(TRY_CONVERT(decimal(9,2), mon.fn_Setting('job_duration_factor')), 2.0),
            @jd_min int         = ISNULL(mon.fn_SettingInt('job_duration_min_minutes'), 15),
            @log_warn int       = ISNULL(mon.fn_SettingInt('log_used_warn_pct'), 80),
            @log_crit int       = ISNULL(mon.fn_SettingInt('log_used_crit_pct'), 90),
            @st_warn int        = ISNULL(mon.fn_SettingInt('storage_free_warn_pct'), 15),
            @st_crit int        = ISNULL(mon.fn_SettingInt('storage_free_crit_pct'), 10),
            @fmax int           = ISNULL(mon.fn_SettingInt('file_near_max_pct'), 90),
            @vlf int            = ISNULL(mon.fn_SettingInt('vlf_warn_count'), 1000),
            @tdb int            = ISNULL(mon.fn_SettingInt('tempdb_used_warn_pct'), 80),
            @cpu_warn int       = ISNULL(mon.fn_SettingInt('cpu_warn_pct'), 85),
            @cpu_crit int       = ISNULL(mon.fn_SettingInt('cpu_crit_pct'), 95),
            @io_ms int          = ISNULL(mon.fn_SettingInt('io_latency_warn_ms'), 50),
            @io_min int         = ISNULL(mon.fn_SettingInt('io_latency_min_ios'), 1000),
            @login_warn int     = ISNULL(mon.fn_SettingInt('failed_login_warn_per_hour'), 25),
            @dl_sev varchar(10) = ISNULL(NULLIF(mon.fn_Setting('deadlock_severity'), N''), 'WARNING'),
            @dl_storm int       = ISNULL(mon.fn_SettingInt('deadlock_storm_per_hour'), 10),
            @stuck_h int        = ISNULL(mon.fn_SettingInt('rds_task_stuck_hours'), 4),
            @stale int          = ISNULL(mon.fn_SettingInt('collector_stale_minutes'), 15);

    IF @dl_sev NOT IN ('CRITICAL', 'WARNING') SET @dl_sev = 'WARNING';

    CREATE TABLE #Issue
    (
        issue_key     nvarchar(400)  NOT NULL PRIMARY KEY,
        category      varchar(40)    NOT NULL,
        severity      varchar(10)    NOT NULL,
        is_event      bit            NOT NULL,
        database_name sysname        NULL,
        title         nvarchar(400)  NOT NULL,
        detail        nvarchar(4000) NULL,
        ref_id        bigint         NULL,
        event_utc     datetime2(0)   NULL,
        first_seen    datetime2(0)   NULL,          /* optional: real start (e.g. blocking episode start) */
        is_muted      bit            NOT NULL DEFAULT (0)
    );
    CREATE TABLE #Scope(category varchar(40) NOT NULL PRIMARY KEY);
    CREATE TABLE #EvalError(check_name varchar(40), error_message nvarchar(2000));

    /* Components whose LAST attempt succeeded. */
    SELECT component_name INTO #CompOk
    FROM mon.ComponentStatus
    WHERE last_success_utc IS NOT NULL AND last_success_utc >= last_attempt_utc;

    /* ======================= BLOCKING ======================= */
    IF @Scope IN ('ALL', 'BLOCKING')
    BEGIN
    BEGIN TRY
        INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail, ref_id, first_seen)
        SELECT CONCAT(N'BLOCKING:', e.episode_id), 'BLOCKING', 'CRITICAL', 0, e.head_database,
               LEFT(CONCAT(N'Blocking ', mon.fn_Duration(DATEDIFF(SECOND, e.blocked_since_utc, e.last_seen_utc)),
                      N' - session ', e.head_session_id, N' (', ISNULL(e.head_login, N'?'), N') blocking ',
                      e.max_blocked_count, N' session(s)',
                      CASE WHEN e.databases_affected IS NOT NULL THEN CONCAT(N' in ', e.databases_affected) END), 400),
               LEFT(CONCAT(
                   CASE WHEN e.head_status = N'sleeping' AND ISNULL(e.head_open_tran_count, 0) > 0
                        THEN N'DIAGNOSIS: head blocker is IDLE inside an open transaction (application did not COMMIT/ROLLBACK). ' END,
                   N'Head: status=', ISNULL(e.head_status, N'?'),
                   N', open_tran=', ISNULL(CONVERT(nvarchar(10), e.head_open_tran_count), N'?'),
                   CASE WHEN e.head_tran_begin_utc IS NOT NULL
                        THEN CONCAT(N' since ', mon.fn_FmtLocal(e.head_tran_begin_utc, @tz),
                                    N' (', mon.fn_Duration(DATEDIFF(SECOND, e.head_tran_begin_utc, @now)), N')') END,
                   N', host=', ISNULL(e.head_host, N'?'), N', program=', ISNULL(e.head_program, N'?'),
                   N' | Wait: ', ISNULL(e.top_wait_type, N'?'), N' on ', ISNULL(e.top_wait_resource, N'?'),
                   N', longest wait ', mon.fn_Duration(e.max_wait_ms / 1000),
                   N' | Head SQL: ', LEFT(COALESCE(e.head_input_buffer, e.head_sql, N'(not available)'), 1200),
                   N' | Blocked SQL: ', LEFT(ISNULL(e.blocked_sql_sample, N'(not available)'), 800)), 4000),
               e.episode_id, e.blocked_since_utc
        FROM mon.BlockingEpisode AS e
        WHERE e.is_open = 1
          AND DATEDIFF(SECOND, e.blocked_since_utc, e.last_seen_utc) >= @blk_min * 60;

        IF EXISTS (SELECT 1 FROM #CompOk WHERE component_name = 'BLOCKING')
            INSERT #Scope VALUES ('BLOCKING');
    END TRY
    BEGIN CATCH
        INSERT #EvalError VALUES ('BLOCKING', ERROR_MESSAGE());
    END CATCH;
    END;

    /* ======================= WATCHDOG ======================= */
    IF @Scope IN ('ALL', 'WATCHDOG')
    BEGIN
    BEGIN TRY
        DECLARE @last_cycle datetime2(3) = (SELECT last_success_utc FROM mon.ComponentStatus WHERE component_name = 'ENGINE_CYCLE');
        IF @Scope = 'WATCHDOG'
           AND (@last_cycle IS NULL OR @last_cycle < DATEADD(MINUTE, -@stale, @now))
            INSERT #Issue(issue_key, category, severity, is_event, title, detail)
            VALUES (N'ENGINE_STALE', 'ENGINE', 'CRITICAL', 0,
                    N'Monitoring engine is not running (no successful cycle)',
                    CONCAT(N'Last successful full cycle: ', ISNULL(mon.fn_FmtLocal(@last_cycle, @tz), N'never'),
                           N'. Check SQL Agent job "MON - Engine" (history, owner, enabled) and mon.EngineRun.'));
        INSERT #Scope VALUES ('ENGINE');
    END TRY
    BEGIN CATCH
        INSERT #EvalError VALUES ('WATCHDOG', ERROR_MESSAGE());
    END CATCH;
    END;

    IF @Scope = 'ALL'
    BEGIN
        /* ======================= DATABASE STATE / CAPACITY / CONFIG ======================= */
        BEGIN TRY
            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'DBSTATE:', s.database_name), 'DATABASE',
                   CASE WHEN s.is_present = 0 THEN 'WARNING'
                        WHEN s.state_desc <> N'ONLINE' THEN 'CRITICAL' ELSE 'WARNING' END, 0, s.database_name,
                   CASE WHEN s.is_present = 0 THEN CONCAT(N'Database ', s.database_name, N' no longer exists')
                        WHEN s.state_desc <> N'ONLINE' THEN CONCAT(N'Database ', s.database_name, N' is ', s.state_desc)
                        ELSE CONCAT(N'Database ', s.database_name, N' is in ', s.user_access_desc, N' mode') END,
                   CASE WHEN s.is_present = 0
                        THEN CONCAT(N'Dropped or renamed. If intentional: EXEC OPS.mon.usp_SetCheck @Database = N''', s.database_name, N''', @Check = ''MONITORED'', @Enabled = 0;')
                        ELSE CONCAT(N'recovery=', s.recovery_model, N', log_reuse_wait=', ISNULL(s.log_reuse_wait_desc, N'?')) END
            FROM mon.DatabaseStatus AS s
            JOIN mon.DatabaseCheck AS p ON p.database_name = s.database_name AND p.monitored = 1
            WHERE s.is_present = 0 OR s.state_desc <> N'ONLINE' OR s.user_access_desc = N'SINGLE_USER';

            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'LOGUSED:', s.database_name), 'CAPACITY',
                   CASE WHEN s.log_used_pct >= @log_crit THEN 'CRITICAL' ELSE 'WARNING' END, 0, s.database_name,
                   CONCAT(N'Transaction log ', CONVERT(decimal(9,1), s.log_used_pct), N'% full in ', s.database_name),
                   CONCAT(N'Log size ', CONVERT(decimal(19,1), s.log_size_mb / 1024.0), N' GB; log_reuse_wait=',
                          ISNULL(s.log_reuse_wait_desc, N'?'), N'; generated since last log backup ',
                          ISNULL(CONVERT(nvarchar(30), CONVERT(decimal(19,0), s.log_since_backup_mb)), N'?'), N' MB.',
                          CASE s.log_reuse_wait_desc
                               WHEN N'ACTIVE_TRANSACTION' THEN N' Look for a long open transaction (see OPEN_TRAN issues).'
                               WHEN N'LOG_BACKUP' THEN N' Log backups are not keeping up.'
                               WHEN N'REPLICATION' THEN N' Replication/CDC log reader is behind.' ELSE N'' END)
            FROM mon.DatabaseStatus AS s
            WHERE s.is_present = 1 AND s.state_desc = N'ONLINE' AND s.log_used_pct >= @log_warn;

            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'VLF:', s.database_name), 'CAPACITY', 'WARNING', 0, s.database_name,
                   CONCAT(N'High VLF count (', s.vlf_total, N') in ', s.database_name),
                   N'Slow recovery/restore and log backups. Fix: shrink the log in a quiet window and regrow in large fixed increments (e.g. 8 GB).'
            FROM mon.DatabaseStatus AS s
            WHERE s.is_present = 1 AND s.vlf_total >= @vlf;

            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'FILEMAX:', s.database_name), 'CAPACITY', 'CRITICAL', 0, s.database_name,
                   CONCAT(N'File ', s.max_file_name, N' is at ', s.max_file_pct_of_maxsize, N'% of MAXSIZE (', s.database_name, N')'),
                   N'The file will stop growing at MAXSIZE -> error 1105/9002. Raise MAXSIZE or free space.'
            FROM mon.DatabaseStatus AS s
            WHERE s.is_present = 1 AND s.max_file_pct_of_maxsize >= @fmax;

            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CASE WHEN v.prop = N'query_store' THEN CONCAT(N'QSTORE:', s.database_name)
                        ELSE CONCAT(N'CONFIG:', s.database_name, N':', v.prop) END, 'CONFIG', 'WARNING', 0, s.database_name,
                   CONCAT(s.database_name, N': ', v.msg), v.fix
            FROM mon.DatabaseStatus AS s
            CROSS APPLY (VALUES
                (N'auto_close',  CASE WHEN s.is_auto_close_on = 1 THEN N'AUTO_CLOSE is ON' END,
                                 N'ALTER DATABASE ... SET AUTO_CLOSE OFF;'),
                (N'auto_shrink', CASE WHEN s.is_auto_shrink_on = 1 THEN N'AUTO_SHRINK is ON' END,
                                 N'ALTER DATABASE ... SET AUTO_SHRINK OFF;'),
                (N'page_verify', CASE WHEN s.page_verify <> N'CHECKSUM' THEN CONCAT(N'PAGE_VERIFY is ', s.page_verify) END,
                                 N'ALTER DATABASE ... SET PAGE_VERIFY CHECKSUM; (protects only pages written afterwards)'),
                (N'query_store', CASE WHEN s.qs_desired_state = N'READ_WRITE' AND s.qs_actual_state = N'READ_ONLY'
                                      THEN CONCAT(N'Query Store forced READ_ONLY (reason ', s.qs_readonly_reason, N')') END,
                                 N'Reason 65536 = MAX_STORAGE_SIZE_MB reached: raise the limit or purge, then SET QUERY_STORE (OPERATION_MODE = READ_WRITE).')
            ) AS v(prop, msg, fix)
            WHERE s.is_present = 1 AND s.state_desc = N'ONLINE' AND v.msg IS NOT NULL;

            /* Drift against the accepted baseline. */
            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'DRIFT:', b.database_name, N':', b.property_name), 'CONFIG', 'WARNING', 0, b.database_name,
                   LEFT(CONCAT(b.database_name, N': ', b.property_name, N' changed from ', ISNULL(b.baseline_value, N'NULL'),
                          N' to ', ISNULL(c.property_value, N'NULL')), 400),
                   CONCAT(N'Baseline accepted ', mon.fn_FmtLocal(b.accepted_utc, @tz), N' by ', b.accepted_by,
                          N'. If intended: EXEC OPS.mon.usp_AcceptConfigBaseline @DatabaseName = N''', b.database_name, N''';')
            FROM mon.DatabaseConfigBaseline AS b
            JOIN mon.DatabaseStatus AS s ON s.database_name = b.database_name AND s.is_present = 1 AND s.state_desc = N'ONLINE'
            CROSS APPLY (SELECT CASE b.property_name
                                    WHEN 'recovery_model'      THEN CONVERT(nvarchar(256), s.recovery_model)
                                    WHEN 'compatibility_level' THEN CONVERT(nvarchar(256), s.compatibility_level)
                                    WHEN 'owner_name'          THEN CONVERT(nvarchar(256), s.owner_name)
                                    WHEN 'page_verify'         THEN CONVERT(nvarchar(256), s.page_verify)
                                    WHEN 'auto_close'          THEN CONVERT(nvarchar(256), s.is_auto_close_on)
                                    WHEN 'auto_shrink'         THEN CONVERT(nvarchar(256), s.is_auto_shrink_on)
                                    WHEN 'read_only'           THEN CONVERT(nvarchar(256), s.is_read_only)
                                    WHEN 'rcsi'                THEN CONVERT(nvarchar(256), s.is_rcsi_on)
                                    WHEN 'snapshot_isolation'  THEN CONVERT(nvarchar(256), s.snapshot_isolation)
                                    WHEN 'user_access'         THEN CONVERT(nvarchar(256), s.user_access_desc)
                                END AS property_value) AS c
            WHERE ISNULL(b.baseline_value, N'~') <> ISNULL(c.property_value, N'~');

            IF EXISTS (SELECT 1 FROM #CompOk WHERE component_name = 'DATABASE_STATE')
                INSERT #Scope VALUES ('DATABASE'), ('CONFIG');
        END TRY
        BEGIN CATCH
            INSERT #EvalError VALUES ('DATABASE', ERROR_MESSAGE());
        END CATCH;

        /* ======================= BACKUPS / CHECKDB / RDS TASKS ======================= */
        BEGIN TRY
            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'BACKUP:', v.btype, N':', h.database_name), 'BACKUP', v.sev, 0, h.database_name,
                   CONCAT(v.btype, N' backup ', v.st, N': ', h.database_name,
                          CASE WHEN v.age_min IS NOT NULL THEN CONCAT(N' (last ', mon.fn_Duration(v.age_min * 60), N' ago)') END),
                   CONCAT(N'SLA ', mon.fn_Duration(v.sla_min * 60), N'; last ', ISNULL(mon.fn_FmtLocal(v.last_utc, @tz), N'never'),
                          N' via ', ISNULL(v.src, N'-'), N'; recovery=', ISNULL(h.recovery_model, N'?'),
                          CASE WHEN v.st = 'CHAIN_BROKEN' THEN N'. Log chain broken: take a FULL (or DIFF) backup now to restart the chain.' END)
            FROM mon.vw_BackupHealth AS h
            CROSS APPLY (VALUES
                ('FULL', h.full_status, h.full_age_min, h.full_max_age_minutes, h.full_finish_utc, h.full_source,
                 CASE WHEN h.full_status IN ('MISSING', 'OVERDUE') THEN 'CRITICAL' END),
                ('DIFF', h.diff_status, h.diff_age_min, h.diff_max_age_minutes, h.effective_data_utc, h.diff_source,
                 CASE WHEN h.diff_status IN ('MISSING', 'OVERDUE') THEN 'CRITICAL' END),
                ('LOG',  h.log_status, h.log_age_min, h.log_max_age_minutes, h.log_finish_utc, h.log_source,
                 CASE WHEN h.log_status IN ('MISSING', 'OVERDUE', 'CHAIN_BROKEN') THEN 'CRITICAL' END)
            ) AS v(btype, st, age_min, sla_min, last_utc, src, sev)
            WHERE v.sev IS NOT NULL;

            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'CHECKDB:', h.database_name), 'BACKUP', 'WARNING', 0, h.database_name,
                   CONCAT(N'No clean CHECKDB ', CASE WHEN h.checkdb_status = 'NEVER' THEN N'ever recorded'
                          ELSE CONCAT(N'for ', mon.fn_Duration(h.checkdb_age_hours * 3600)) END, N': ', h.database_name),
                   CONCAT(N'SLA ', h.checkdb_max_age_days, N' days; last known good ', ISNULL(mon.fn_FmtLocal(h.last_checkdb_utc, @tz), N'never'),
                          N'. Check the DatabaseIntegrityCheck job.')
            FROM mon.vw_BackupHealth AS h
            WHERE h.checkdb_status IN ('NEVER', 'OVERDUE');

            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail, event_utc)
            SELECT CONCAT(N'RDSTASK:', r.task_id), 'BACKUP', 'CRITICAL', 1, r.database_name,
                   CONCAT(N'RDS native ', r.task_type, N' task ', r.task_id, N' ', r.lifecycle, N': ', ISNULL(r.database_name, N'?')),
                   LEFT(CONCAT(N'Created ', mon.fn_FmtLocal(r.created_utc, @tz), N'; S3=', ISNULL(r.s3_object_arn, N'-'),
                               N'; info: ', ISNULL(r.task_info, N'')), 4000),
                   r.created_utc
            FROM mon.RdsTask AS r
            WHERE r.task_type IN (N'BACKUP_DB', N'BACKUP_DB_DIFFERENTIAL')
              AND r.lifecycle IN (N'ERROR', N'CANCELLED')
              AND r.created_utc >= DATEADD(HOUR, -@lookback, @now);

            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'RDSSTUCK:', r.task_id), 'BACKUP', 'WARNING', 0, r.database_name,
                   CONCAT(N'RDS ', r.task_type, N' task ', r.task_id, N' stuck ', mon.fn_Duration(DATEDIFF(SECOND, r.created_utc, @now)),
                          N': ', ISNULL(r.database_name, N'?')),
                   CONCAT(N'lifecycle=', r.lifecycle, N'; ', ISNULL(CONVERT(nvarchar(20), r.percent_complete), N'?'), N'% complete')
            FROM mon.RdsTask AS r
            WHERE r.lifecycle IN (N'CREATED', N'IN_PROGRESS')
              AND r.created_utc < DATEADD(HOUR, -@stuck_h, @now);

            /* Retention / inventory (from the latest daily snapshot - cheap). */
            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'RETENTION:', r.backup_type, N':', r.database_name), 'BACKUP', 'WARNING', 0, r.database_name,
                   CASE r.status
                        WHEN 'NONE'  THEN CONCAT(N'No ', r.backup_type, N' backups recorded: ', r.database_name)
                        WHEN 'SHORT' THEN CONCAT(r.backup_type, N' backup history only ', r.retention_days, N' of ', r.target_days,
                                                 N' days: ', r.database_name)
                        WHEN 'POLICY' THEN CONCAT(r.backup_type, N' storage lifecycle (', r.storage_days, N' d) is shorter than required retention (',
                                                  r.target_days, N' d): ', r.database_name)
                        ELSE CONCAT(r.gaps, N' gap(s) in ', r.backup_type, N' backup chain: ', r.database_name) END,
                   CONCAT(N'Snapshot ', CONVERT(nvarchar(10), r.snapshot_date, 120), N': ', r.backup_count, N' backups, oldest ',
                          ISNULL(mon.fn_FmtLocal(r.oldest_utc, @tz), N'-'), N', newest ', ISNULL(mon.fn_FmtLocal(r.newest_utc, @tz), N'-'),
                          N', source ', ISNULL(r.source_name, N'-'),
                          N'. Target: mon.DatabaseCheck.retention_days (default setting backup_retention_target_days).')
            FROM mon.BackupInventoryDaily AS r
            WHERE r.snapshot_date = (SELECT MAX(snapshot_date) FROM mon.BackupInventoryDaily)
              AND r.status IN ('NONE', 'SHORT', 'GAPS', 'POLICY');

            IF EXISTS (SELECT 1 FROM #CompOk WHERE component_name = 'BACKUPS')
               AND EXISTS (SELECT 1 FROM #CompOk WHERE component_name = 'DATABASE_STATE')
                INSERT #Scope VALUES ('BACKUP');
        END TRY
        BEGIN CATCH
            INSERT #EvalError VALUES ('BACKUP', ERROR_MESSAGE());
        END CATCH;

        /* ======================= SQL AGENT ======================= */
        BEGIN TRY
            /* Failures: active while the job's LAST outcome failed, or it failed in the last 30 min
               (guarantees a fail-then-succeed between two cycles is still reported once). */
            ;WITH F AS
            (
                SELECT f.job_id, f.job_name, f.run_status, f.run_start_utc, f.failed_step_id, f.failed_step_name, f.message,
                       ROW_NUMBER() OVER (PARTITION BY f.job_id ORDER BY f.run_start_utc DESC, f.instance_id DESC) AS rn,
                       COUNT(*) OVER (PARTITION BY f.job_id) AS fails
                FROM mon.AgentFailure AS f
                WHERE f.run_start_utc >= DATEADD(HOUR, -@lookback, @now)
            )
            INSERT #Issue(issue_key, category, severity, is_event, title, detail, event_utc)
            SELECT CONCAT(N'JOBFAIL:', F.job_id), 'AGENT', 'CRITICAL', 0,
                   LEFT(CONCAT(N'Job ', CASE WHEN F.run_status = 3 THEN N'cancelled' ELSE N'failed' END, N': ', F.job_name,
                          CASE WHEN F.fails > 1 THEN CONCAT(N' (', F.fails, N' failures in ', @lookback, N'h)') END), 400),
                   LEFT(CONCAT(N'Last failure ', mon.fn_FmtLocal(F.run_start_utc, @tz),
                               N'; step ', ISNULL(CONVERT(nvarchar(10), F.failed_step_id), N'?'), N' "', ISNULL(F.failed_step_name, N'(job outcome)'),
                               N'": ', ISNULL(F.message, N'')), 4000),
                   F.run_start_utc
            FROM F
            OUTER APPLY (SELECT TOP (1) r.run_status FROM mon.AgentJobRun AS r
                         WHERE r.job_id = F.job_id ORDER BY r.run_start_utc DESC, r.instance_id DESC) AS last_run
            WHERE F.rn = 1
              AND (last_run.run_status IN (0, 3) OR F.run_start_utc >= DATEADD(MINUTE, -30, @now));

            INSERT #Issue(issue_key, category, severity, is_event, title, detail)
            SELECT CONCAT(N'JOBSLA:', j.job_id), 'AGENT',
                   CASE WHEN j.health_status IN ('OVERDUE', 'NEVER_SUCCEEDED') THEN 'CRITICAL' ELSE 'WARNING' END, 0,
                   CONCAT(N'Maintenance job ', j.health_status, N': ', j.job_name),
                   CONCAT(N'Type ', j.job_type, N'; SLA ', j.max_hours_since_success, N'h; last success ',
                          ISNULL(mon.fn_FmtLocal(j.last_success_utc, @tz), N'never'), N'; last run ',
                          ISNULL(mon.fn_FmtLocal(j.last_run_utc, @tz), N'never'))
            FROM mon.vw_JobHealth AS j
            WHERE j.is_monitored = 1
              AND j.health_status IN ('OVERDUE', 'NEVER_SUCCEEDED', 'DISABLED', 'NOT_FOUND');

            /* Running jobs vs 30-day median. sysjobactivity first, session parsing as fallback. */
            CREATE TABLE #Running(job_id uniqueidentifier, start_utc datetime2(0));
            BEGIN TRY
                INSERT #Running
                EXEC sys.sp_executesql N'
                    SELECT ja.job_id, mon.fn_ServerToUtc(ja.start_execution_date)
                    FROM msdb.dbo.sysjobactivity AS ja
                    WHERE ja.session_id = (SELECT MAX(s.session_id) FROM msdb.dbo.syssessions AS s)
                      AND ja.start_execution_date IS NOT NULL
                      AND ja.stop_execution_date IS NULL;';
            END TRY
            BEGIN CATCH
                INSERT #Running
                SELECT TRY_CONVERT(uniqueidentifier, TRY_CONVERT(binary(16),
                           SUBSTRING(s.program_name, CHARINDEX(N'(Job 0x', s.program_name) + 5, 34), 1)),
                       mon.fn_ServerToUtc(MIN(s.login_time))
                FROM sys.dm_exec_sessions AS s
                WHERE s.program_name LIKE N'SQLAgent - TSQL JobStep (Job 0x%'
                GROUP BY SUBSTRING(s.program_name, CHARINDEX(N'(Job 0x', s.program_name) + 5, 34);
            END CATCH;

            INSERT #Issue(issue_key, category, severity, is_event, title, detail)
            SELECT CONCAT(N'JOBLONG:', r.job_id, N':', CONVERT(nvarchar(19), r.start_utc, 126)), 'AGENT',
                   CASE WHEN DATEDIFF(SECOND, r.start_utc, @now) > b.median_s * @jd_factor * 2 THEN 'CRITICAL' ELSE 'WARNING' END, 0,
                   CONCAT(N'Job running long: ', j.name, N' (', mon.fn_Duration(DATEDIFF(SECOND, r.start_utc, @now)),
                          N' vs median ', mon.fn_Duration(CONVERT(bigint, b.median_s)), N')'),
                   CONCAT(N'Started ', mon.fn_FmtLocal(r.start_utc, @tz), N'; median of ', b.successful_runs,
                          N' successful runs; threshold ', @jd_factor, N'x median. Possibly hung or blocked (see BLOCKING).')
            FROM #Running AS r
            JOIN msdb.dbo.sysjobs AS j ON j.job_id = r.job_id
            JOIN mon.vw_JobDurationBaseline AS b ON b.job_id = r.job_id AND b.successful_runs >= 3
            WHERE j.name NOT LIKE N'MON - %'
              AND DATEDIFF(SECOND, r.start_utc, @now) >= @jd_min * 60
              AND DATEDIFF(SECOND, r.start_utc, @now) > b.median_s * @jd_factor;

            /* Ola Hallengren CommandLog failures (one issue per failed command, event). */
            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail, event_utc)
            SELECT CONCAT(N'OLAFAIL:', o.source_db, N':', o.ola_id), 'OLA',
                   CASE WHEN o.command_type LIKE N'BACKUP%' OR o.command_type LIKE N'DBCC%' OR o.command_type LIKE N'RESTORE%'
                        THEN 'CRITICAL' ELSE 'WARNING' END, 1, o.database_name,
                   LEFT(CONCAT(N'Ola ', o.command_type, N' failed: ', ISNULL(o.database_name, N'?'),
                               CASE WHEN o.object_name IS NOT NULL THEN CONCAT(N'.', o.object_name) END,
                               CASE WHEN o.index_name IS NOT NULL THEN CONCAT(N' (', o.index_name, N')') END,
                               N' - error ', o.error_number), 400),
                   LEFT(CONCAT(N'Started ', mon.fn_FmtLocal(o.start_utc, @tz), N', ran ', mon.fn_Duration(o.duration_s),
                               N' | Error ', o.error_number, N': ', ISNULL(o.error_message, N''),
                               N' | Command: ', ISNULL(o.command, N''), N' | Source: ', o.source_db, N'.dbo.CommandLog ID ', o.ola_id), 4000),
                   o.start_utc
            FROM mon.OlaCommand AS o
            WHERE ISNULL(o.error_number, 0) <> 0
              AND o.start_utc >= DATEADD(HOUR, -@lookback, @now);

            IF EXISTS (SELECT 1 FROM #CompOk WHERE component_name = 'OLA_COMMANDLOG')
                INSERT #Scope VALUES ('OLA');

            IF EXISTS (SELECT 1 FROM #CompOk WHERE component_name = 'AGENT')
                INSERT #Scope VALUES ('AGENT');
        END TRY
        BEGIN CATCH
            INSERT #EvalError VALUES ('AGENT', ERROR_MESSAGE());
        END CATCH;

        /* ======================= WORKLOAD (live) ======================= */
        BEGIN TRY
            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'LONGQ:', r.session_id, N':', r.request_id, N':', CONVERT(nvarchar(19), r.start_time, 126)), 'WORKLOAD',
                   CASE WHEN r.total_elapsed_time >= @lq_crit * 60000 THEN 'CRITICAL' ELSE 'WARNING' END, 0,
                   DB_NAME(r.database_id),
                   CONCAT(N'Long-running request ', mon.fn_Duration(r.total_elapsed_time / 1000), N' - session ', r.session_id,
                          N' (', s.login_name, N') in ', DB_NAME(r.database_id)),
                   LEFT(CONCAT(N'command=', r.command, N', status=', r.status, N', wait=', ISNULL(r.wait_type, N'-'),
                               N', cpu=', mon.fn_Duration(r.cpu_time / 1000), N', reads=', r.logical_reads,
                               N', host=', s.host_name, N', program=', s.program_name,
                               CASE WHEN r.percent_complete > 0 THEN CONCAT(N', ', CONVERT(decimal(5,1), r.percent_complete), N'% complete') END,
                               N' | SQL: ', SUBSTRING(t.text, r.statement_start_offset / 2 + 1,
                                   (CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END
                                    - r.statement_start_offset) / 2 + 1)), 4000)
            FROM sys.dm_exec_requests AS r
            JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
            OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
            WHERE s.is_user_process = 1
              AND r.session_id <> @@SPID
              AND r.total_elapsed_time >= @lq_warn * 60000
              AND r.command NOT IN (N'WAITFOR', N'BACKUP DATABASE', N'BACKUP LOG', N'RESTORE DATABASE', N'RESTORE LOG')
              AND s.login_name NOT IN (N'rdsa', N'NT AUTHORITY\SYSTEM')
              AND ISNULL(s.program_name, N'') NOT LIKE N'%MON - Engine%'
              AND (@lq_ex_agent = 0 OR ISNULL(s.program_name, N'') NOT LIKE N'SQLAgent - TSQL JobStep%')
              AND ISNULL(r.wait_type, N'') NOT IN (N'SP_SERVER_DIAGNOSTICS_SLEEP', N'BROKER_RECEIVE_WAITFOR', N'WAITFOR');

            /* Open transactions: idle-in-transaction, or a multi-statement transaction older than its current request. */
            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'OPENTRAN:', x.session_id, N':', x.transaction_id), 'WORKLOAD',
                   CASE WHEN x.age_s >= @ot_crit * 60 THEN 'CRITICAL' ELSE 'WARNING' END, 0, x.dbname,
                   CONCAT(N'Open transaction ', mon.fn_Duration(x.age_s), N' - session ', x.session_id, N' (', x.login_name, N')',
                          CASE WHEN x.status = N'sleeping' THEN N' IDLE' END),
                   LEFT(CONCAT(N'Transaction "', x.tran_name, N'" began ', mon.fn_FmtLocal(x.begin_utc, @tz),
                               N'; log used ', CONVERT(decimal(19,1), x.log_bytes / 1048576.0), N' MB in ', ISNULL(x.dbname, N'?'),
                               N'; status=', x.status, N', host=', x.host_name, N', program=', x.program_name,
                               N'. Holds locks and prevents log truncation. | Last SQL: ', ISNULL(x.last_sql, N'')), 4000)
            FROM
            (
                SELECT st.session_id, at.transaction_id, at.name AS tran_name, s.status, s.login_name, s.host_name, s.program_name,
                       mon.fn_ServerToUtc(at.transaction_begin_time) AS begin_utc,
                       at.transaction_begin_time AS begin_local,
                       DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) AS age_s,
                       (SELECT SUM(dt.database_transaction_log_bytes_used) FROM sys.dm_tran_database_transactions AS dt
                        WHERE dt.transaction_id = at.transaction_id AND dt.database_id <> 32767) AS log_bytes,
                       (SELECT TOP (1) DB_NAME(dt.database_id) FROM sys.dm_tran_database_transactions AS dt
                        WHERE dt.transaction_id = at.transaction_id AND dt.database_id <> 32767 AND dt.database_id <> 2
                        ORDER BY dt.database_transaction_log_bytes_used DESC) AS dbname,
                       (SELECT LEFT(ib.event_info, 1500) FROM sys.dm_exec_input_buffer(st.session_id, NULL) AS ib) AS last_sql,
                       r.req_start
                FROM sys.dm_tran_session_transactions AS st
                JOIN sys.dm_tran_active_transactions AS at ON at.transaction_id = st.transaction_id
                JOIN sys.dm_exec_sessions AS s ON s.session_id = st.session_id
                OUTER APPLY (SELECT MIN(rq.start_time) AS req_start FROM sys.dm_exec_requests AS rq
                             WHERE rq.session_id = st.session_id) AS r
                WHERE s.is_user_process = 1
                  AND st.session_id <> @@SPID
                  AND s.login_name NOT IN (N'rdsa', N'NT AUTHORITY\SYSTEM')
                  AND ISNULL(s.program_name, N'') NOT LIKE N'SQLAgent - TSQL JobStep%'
                  AND at.transaction_begin_time < DATEADD(MINUTE, -@ot_warn, GETDATE())
            ) AS x
            WHERE x.req_start IS NULL                                  /* idle in transaction */
               OR x.req_start > DATEADD(SECOND, 60, x.begin_local);       /* multi-statement transaction */

            INSERT #Scope VALUES ('WORKLOAD');
        END TRY
        BEGIN CATCH
            INSERT #EvalError VALUES ('WORKLOAD', ERROR_MESSAGE());
        END CATCH;

        /* ======================= EVENTS: deadlocks, error log, logins, restarts, mail ======================= */
        BEGIN TRY
            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail, event_utc)
            SELECT CONCAT(N'DEADLOCK:', CONVERT(varchar(64), d.deadlock_hash, 2)), 'DEADLOCK', @dl_sev, 1, d.database_name,
                   LEFT(CONCAT(N'Deadlock in ', ISNULL(d.database_name, N'?'), N' - victim ', ISNULL(d.victim_login, N'?'),
                               N' (', ISNULL(d.victim_app, N'?'), N')'), 400),
                   LEFT(CONCAT(N'Objects: ', ISNULL(d.objects, N'?'), N' | Victim SQL: ', ISNULL(d.victim_sql, N''),
                               N' | Survivor SQL: ', ISNULL(d.survivor_sql, N''), N' | XML in OPS.mon.Deadlock'), 4000),
                   d.event_utc
            FROM mon.Deadlock AS d
            WHERE d.event_utc >= DATEADD(HOUR, -@lookback, @now);

            DECLARE @dl_count int, @dl_top sysname;
            SELECT @dl_count = COUNT(*) FROM mon.Deadlock WHERE event_utc >= DATEADD(HOUR, -1, @now);
            IF @dl_count >= @dl_storm
            BEGIN
                SELECT TOP (1) @dl_top = database_name FROM mon.Deadlock
                WHERE event_utc >= DATEADD(HOUR, -1, @now)
                GROUP BY database_name ORDER BY COUNT(*) DESC;
                INSERT #Issue(issue_key, category, severity, is_event, title, detail)
                VALUES (N'DEADLOCK_STORM', 'DEADLOCK', 'CRITICAL', 0,
                        CONCAT(@dl_count, N' deadlocks in the last hour'),
                        CONCAT(N'Most affected database: ', ISNULL(@dl_top, N'?'),
                               N'. Review victim/survivor SQL in the digest or OPS.mon.Deadlock.'));
            END;

            INSERT #Issue(issue_key, category, severity, is_event, title, detail, event_utc)
            SELECT CONCAT(N'ERRLOG:', CONVERT(varchar(64), e.event_hash, 2)), 'ERRORLOG', e.severity, 1,
                   LEFT(CONCAT(N'SQL error log', CASE WHEN e.error_number IS NOT NULL THEN CONCAT(N' error ', e.error_number) END,
                               N': ', e.message), 160),
                   LEFT(CONCAT(N'Logged ', mon.fn_FmtLocal(e.log_utc, @tz), N' by ', ISNULL(e.process_info, N'?'), N': ', e.message), 4000),
                   e.log_utc
            FROM mon.ErrorLogEvent AS e
            WHERE e.log_utc >= DATEADD(HOUR, -@lookback, @now);

            DECLARE @lf_count int, @lf_top nvarchar(max);
            DECLARE @lf_since datetime2(0) = DATEADD(HOUR, DATEDIFF(HOUR, CONVERT(datetime2(0), '19000101'), @now) - 1, CONVERT(datetime2(0), '19000101'));
            SELECT @lf_count = SUM(failures) FROM mon.LoginFailure WHERE hour_utc >= @lf_since;
            IF @lf_count >= @login_warn
            BEGIN
                SET @lf_top = (SELECT TOP (3) CONCAT(x.login_name, N'@', x.client_address, N' x', SUM(x.failures),
                                                     N' (', MAX(x.reason), N'); ')
                               FROM mon.LoginFailure AS x WHERE x.hour_utc >= @lf_since
                               GROUP BY x.login_name, x.client_address ORDER BY SUM(x.failures) DESC
                               FOR XML PATH(''), TYPE).value('(./text())[1]', 'nvarchar(max)');
                INSERT #Issue(issue_key, category, severity, is_event, title, detail)
                VALUES (N'LOGINFAIL', 'SECURITY', 'WARNING', 0,
                        CONCAT(@lf_count, N' failed logins since ', mon.fn_FmtLocal(@lf_since, @tz)),
                        LEFT(CONCAT(N'Top sources: ', @lf_top), 4000));
            END;

            INSERT #Issue(issue_key, category, severity, is_event, title, detail, event_utc)
            SELECT TOP (1) CONCAT(N'RESTART:', CONVERT(nvarchar(16), p.sqlserver_start_utc, 126)), 'SERVER', 'WARNING', 1,
                   CONCAT(N'SQL Server restarted / failed over at ', mon.fn_FmtLocal(p.sqlserver_start_utc, @tz)),
                   N'Check the RDS event log (reboot, Multi-AZ failover, maintenance window, scaling).',
                   p.sqlserver_start_utc
            FROM mon.PerfSample AS p
            WHERE p.sqlserver_start_utc >= DATEADD(HOUR, -@lookback, @now)
            ORDER BY p.sample_utc DESC;

            /* Database Mail failures (RDS function first, standard view as fallback). */
            CREATE TABLE #Mail(mailitem_id int, sent_status nvarchar(20), send_request_utc datetime2(0), subject nvarchar(255), recipients nvarchar(max));
            BEGIN TRY
                INSERT #Mail EXEC sys.sp_executesql N'
                    SELECT mailitem_id, sent_status, mon.fn_ServerToUtc(send_request_date), LEFT(subject, 255), recipients
                    FROM msdb.dbo.rds_fn_sysmail_allitems()
                    WHERE send_request_date >= DATEADD(HOUR, -@h, GETDATE()) AND sent_status IN (N''failed'', N''unsent'');',
                    N'@h int', @h = @lookback;
            END TRY
            BEGIN CATCH
                BEGIN TRY
                    INSERT #Mail EXEC sys.sp_executesql N'
                        SELECT mailitem_id, sent_status, mon.fn_ServerToUtc(send_request_date), LEFT(subject, 255), recipients
                        FROM msdb.dbo.sysmail_allitems
                        WHERE send_request_date >= DATEADD(HOUR, -@h, GETDATE()) AND sent_status IN (N''failed'', N''unsent'');',
                        N'@h int', @h = @lookback;
                END TRY
                BEGIN CATCH
                    /* no access to mail status: ignored */
                END CATCH;
            END CATCH;

            INSERT #Issue(issue_key, category, severity, is_event, title, detail, event_utc)
            SELECT CONCAT(N'MAIL:', m.mailitem_id), 'SELF', 'WARNING', 1,
                   LEFT(CONCAT(N'Database Mail item ', m.mailitem_id, N' ', m.sent_status, N': ', m.subject), 400),
                   CONCAT(N'Requested ', mon.fn_FmtLocal(m.send_request_utc, @tz),
                          N'. Check msdb.dbo.rds_fn_sysmail_event_log() and the SES/SMTP account.'),
                   m.send_request_utc
            FROM #Mail AS m
            WHERE m.sent_status = N'failed'
               OR (m.sent_status = N'unsent' AND m.send_request_utc < DATEADD(MINUTE, -15, @now));

            IF EXISTS (SELECT 1 FROM #CompOk WHERE component_name = 'DEADLOCKS')
                INSERT #Scope VALUES ('DEADLOCK');
            IF EXISTS (SELECT 1 FROM #CompOk WHERE component_name = 'ERRORLOG')
                INSERT #Scope VALUES ('ERRORLOG'), ('SECURITY');
            INSERT #Scope VALUES ('SERVER');
        END TRY
        BEGIN CATCH
            INSERT #EvalError VALUES ('EVENTS', ERROR_MESSAGE());
        END CATCH;

        /* ======================= PERFORMANCE / STORAGE ======================= */
        BEGIN TRY
            INSERT #Issue(issue_key, category, severity, is_event, title, detail)
            SELECT N'CPU', 'PERF', CASE WHEN AVG(c.sql_cpu_pct * 1.0) >= @cpu_crit THEN 'CRITICAL' ELSE 'WARNING' END, 0,
                   CONCAT(N'High CPU: SQL Server averaged ', CONVERT(int, AVG(c.sql_cpu_pct * 1.0)), N'% over 15 minutes'),
                   CONCAT(N'Peak ', MAX(c.sql_cpu_pct), N'%, other processes avg ', CONVERT(int, AVG(c.other_cpu_pct * 1.0)),
                          N'%. Check top CPU queries in Query Store / sys.dm_exec_query_stats.')
            FROM mon.CpuSample AS c
            WHERE c.sample_utc >= DATEADD(MINUTE, -15, @now)
            HAVING COUNT(*) >= 5 AND AVG(c.sql_cpu_pct * 1.0) >= @cpu_warn;

            INSERT #Issue(issue_key, category, severity, is_event, title, detail)
            SELECT N'MEMGRANTS', 'PERF', 'WARNING', 0,
                   CONCAT(N'Memory grants pending (', MIN(p.memory_grants_pending), N'+) in consecutive samples'),
                   CONCAT(N'Queries are waiting for workspace memory (RESOURCE_SEMAPHORE). PLE now ',
                          MAX(CASE WHEN p.rn = 1 THEN p.ple_sec END), N' s.')
            FROM (SELECT TOP (2) ps.memory_grants_pending, ps.ple_sec, ROW_NUMBER() OVER (ORDER BY ps.sample_utc DESC) AS rn
                  FROM mon.PerfSample AS ps WHERE ps.sample_utc >= DATEADD(MINUTE, -15, @now)
                  ORDER BY ps.sample_utc DESC) AS p
            HAVING COUNT(*) = 2 AND MIN(p.memory_grants_pending) >= 1;

            INSERT #Issue(issue_key, category, severity, is_event, title, detail)
            SELECT TOP (1) N'TEMPDB', 'CAPACITY', 'WARNING', 0,
                   CONCAT(N'tempdb ', CONVERT(int, p.tempdb_used_mb * 100.0 / NULLIF(p.tempdb_size_mb, 0)), N'% used'),
                   CONCAT(N'Used ', CONVERT(decimal(19,1), p.tempdb_used_mb / 1024.0), N' GB of ', CONVERT(decimal(19,1), p.tempdb_size_mb / 1024.0),
                          N' GB; version store ', CONVERT(decimal(19,1), p.tempdb_version_store_mb / 1024.0), N' GB; user objects ',
                          CONVERT(decimal(19,1), p.tempdb_user_obj_mb / 1024.0), N' GB; internal ',
                          CONVERT(decimal(19,1), p.tempdb_internal_obj_mb / 1024.0), N' GB.')
            FROM mon.PerfSample AS p
            WHERE p.sample_utc >= DATEADD(MINUTE, -10, @now)
              AND p.tempdb_used_mb * 100.0 / NULLIF(p.tempdb_size_mb, 0) >= @tdb
            ORDER BY p.sample_utc DESC;

            ;WITH S AS
            (
                SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.volume_mount_point ORDER BY s.sample_utc DESC) AS rn
                FROM mon.StorageSample AS s WHERE s.sample_utc >= DATEADD(MINUTE, -30, @now)
            )
            INSERT #Issue(issue_key, category, severity, is_event, title, detail)
            SELECT CONCAT(N'STORAGE:', S.volume_mount_point), 'CAPACITY',
                   CASE WHEN S.available_bytes * 100.0 / NULLIF(S.total_bytes, 0) <= @st_crit THEN 'CRITICAL' ELSE 'WARNING' END, 0,
                   CONCAT(N'Low storage on ', S.volume_mount_point, N': ',
                          CONVERT(decimal(9,1), S.available_bytes * 100.0 / NULLIF(S.total_bytes, 0)), N'% free'),
                   CONCAT(CONVERT(decimal(19,1), S.available_bytes / 1073741824.0), N' GB free of ',
                          CONVERT(decimal(19,1), S.total_bytes / 1073741824.0), N' GB. RDS: enable storage autoscaling or modify allocated storage.')
            FROM S
            WHERE S.rn = 1 AND S.available_bytes * 100.0 / NULLIF(S.total_bytes, 0) < @st_warn;

            /* I/O latency over the last hourly interval. */
            DECLARE @s1 datetime2(0) = (SELECT MAX(snapshot_utc) FROM mon.FileStatsSnapshot);
            DECLARE @s0 datetime2(0) = (SELECT MAX(snapshot_utc) FROM mon.FileStatsSnapshot WHERE snapshot_utc < @s1);
            IF @s1 >= DATEADD(MINUTE, -90, @now) AND @s0 >= DATEADD(MINUTE, -150, @s1)
                INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
                SELECT CONCAT(N'IOLAT:', b.database_id, N':', b.file_id), 'PERF', 'WARNING', 0, b.database_name,
                       CONCAT(N'Slow I/O on ', b.database_name, N' (', b.logical_name, N'): read ',
                              ISNULL(CONVERT(nvarchar(20), d.rd_ms), N'-'), N' ms, write ', ISNULL(CONVERT(nvarchar(20), d.wr_ms), N'-'), N' ms'),
                       CONCAT(N'Last hour: ', d.rd, N' reads, ', d.wr, N' writes on ', b.type_desc,
                              N' file. Check RDS ReadLatency/WriteLatency, EBS throughput/IOPS limits and burst balance.')
                FROM mon.FileStatsSnapshot AS b
                JOIN mon.FileStatsSnapshot AS a ON a.snapshot_utc = @s0 AND a.database_id = b.database_id AND a.file_id = b.file_id
                CROSS APPLY (SELECT b.num_reads - a.num_reads AS rd, b.num_writes - a.num_writes AS wr,
                                    CONVERT(decimal(9,1), (b.io_stall_read_ms - a.io_stall_read_ms) * 1.0 / NULLIF(b.num_reads - a.num_reads, 0)) AS rd_ms,
                                    CONVERT(decimal(9,1), (b.io_stall_write_ms - a.io_stall_write_ms) * 1.0 / NULLIF(b.num_writes - a.num_writes, 0)) AS wr_ms) AS d
                WHERE b.snapshot_utc = @s1
                  AND d.rd >= 0 AND d.wr >= 0
                  AND ((d.rd >= @io_min AND d.rd_ms >= @io_ms) OR (d.wr >= @io_min AND d.wr_ms >= @io_ms));

            IF EXISTS (SELECT 1 FROM #CompOk WHERE component_name = 'PERF')
                INSERT #Scope VALUES ('PERF');
            IF EXISTS (SELECT 1 FROM #CompOk WHERE component_name = 'PERF')
               AND EXISTS (SELECT 1 FROM #CompOk WHERE component_name = 'DATABASE_STATE')
               AND NOT EXISTS (SELECT 1 FROM #EvalError WHERE check_name = 'DATABASE')
                INSERT #Scope VALUES ('CAPACITY');
        END TRY
        BEGIN CATCH
            INSERT #EvalError VALUES ('PERF', ERROR_MESSAGE());
        END CATCH;

        /* ======================= SELF-HEALTH ======================= */
        BEGIN TRY
            INSERT #Issue(issue_key, category, severity, is_event, title, detail)
            SELECT CONCAT(N'COMPONENT:', c.component_name), 'SELF', 'WARNING', 0,
                   CONCAT(N'Monitoring collector failing: ', c.component_name, N' (', c.consecutive_failures, N'x)'),
                   LEFT(CONCAT(N'Error ', ISNULL(CONVERT(nvarchar(20), c.last_error_number), N''), N': ',
                               ISNULL(c.last_error_message, N''), N'; last success ', ISNULL(mon.fn_FmtLocal(c.last_success_utc, @tz), N'never')), 4000)
            FROM mon.ComponentStatus AS c
            WHERE c.consecutive_failures >= 3 AND c.component_name NOT IN ('ENGINE_CYCLE');

            INSERT #Issue(issue_key, category, severity, is_event, title, detail)
            SELECT CONCAT(N'EVALFAIL:', e.check_name), 'SELF', 'WARNING', 0,
                   CONCAT(N'Issue check failed: ', e.check_name), LEFT(e.error_message, 4000)
            FROM #EvalError AS e
            WHERE NOT EXISTS (SELECT 1 FROM #Issue AS i WHERE i.issue_key = CONCAT(N'EVALFAIL:', e.check_name));

            INSERT #Scope VALUES ('SELF');
        END TRY
        BEGIN CATCH
            /* never fail the evaluation because of self-health reporting */
        END CATCH;
    END;

    /* =====================================================================
       MERGE the candidate set into the issue lifecycle.
       ===================================================================== */
    DECLARE @lock int;
    BEGIN TRY
        /* Engine (30 s / 5 min) and watchdog (hourly) may merge concurrently: serialize. */
        EXEC @lock = sys.sp_getapplock @Resource = N'mon_IssueMerge', @LockMode = 'Exclusive',
                                       @LockOwner = 'Session', @LockTimeout = 60000;
        IF @lock < 0 RAISERROR(N'Could not acquire mon_IssueMerge applock (%d).', 16, 1, @lock);

        /* Check matrix: drop candidates whose check is switched off (mon.DatabaseCheck / mon.ServerCheck)... */
        DELETE i FROM #Issue AS i WHERE mon.fn_IsCheckEnabled(i.issue_key, i.database_name) = 0;

        UPDATE i SET is_muted = 1
        FROM #Issue AS i
        WHERE EXISTS (SELECT 1 FROM mon.IssueMute AS m WHERE m.until_utc > @now AND i.issue_key LIKE m.key_pattern);

        DECLARE @chg TABLE(issue_id bigint, old_sev varchar(10), new_sev varchar(10));

        /* ...and close already-open issues of switched-off checks SILENTLY (no RESOLVED mail). */
        UPDATE t
           SET t.is_active = 0, t.resolved_utc = @now, t.close_type = 'DISABLED'
        OUTPUT inserted.issue_id, deleted.severity, 'E' INTO @chg(issue_id, old_sev, new_sev)
        FROM mon.Issue AS t
        WHERE t.is_active = 1 AND mon.fn_IsCheckEnabled(t.issue_key, t.database_name) = 0;

        INSERT mon.IssueChange(issue_id, change_type, old_severity, new_severity, change_utc, alert_status, alert_utc)
        SELECT c.issue_id, 'EXPIRED', c.old_sev, NULL, @now, 'SKIPPED', @now FROM @chg AS c;
        DELETE @chg;

        /* 1. Refresh still-present active issues. */
        UPDATE t
           SET t.last_seen_utc     = @now,
               t.title             = s.title,
               t.detail            = s.detail,
               t.ref_id            = s.ref_id,
               t.database_name     = s.database_name,
               t.is_muted          = s.is_muted,
               t.last_critical_utc = CASE WHEN s.severity = 'CRITICAL' THEN @now ELSE t.last_critical_utc END
        FROM mon.Issue AS t
        JOIN #Issue AS s ON s.issue_key = t.issue_key
        WHERE t.is_active = 1;

        /* 2. Severity changes: escalate at once, de-escalate only after the grace period. */
        UPDATE t
           SET t.severity = s.severity
        OUTPUT inserted.issue_id, deleted.severity, inserted.severity INTO @chg(issue_id, old_sev, new_sev)
        FROM mon.Issue AS t
        JOIN #Issue AS s ON s.issue_key = t.issue_key
        WHERE t.is_active = 1
          AND t.severity <> s.severity
          AND (s.severity = 'CRITICAL' OR t.last_critical_utc IS NULL
               OR t.last_critical_utc < DATEADD(MINUTE, -@grace, @now));

        INSERT mon.IssueChange(issue_id, change_type, old_severity, new_severity, change_utc)
        SELECT c.issue_id, CASE WHEN c.new_sev = 'CRITICAL' THEN 'ESCALATED' ELSE 'DEESCALATED' END,
               c.old_sev, c.new_sev, @now
        FROM @chg AS c;
        DELETE @chg;

        /* 3. New issues. */
        INSERT mon.Issue(issue_key, category, severity, is_event, database_name, title, detail, ref_id, event_utc,
                         first_seen_utc, last_seen_utc, last_critical_utc, is_active, is_muted)
        OUTPUT inserted.issue_id, NULL, inserted.severity INTO @chg(issue_id, old_sev, new_sev)
        SELECT s.issue_key, s.category, s.severity, s.is_event, s.database_name, s.title, s.detail, s.ref_id, s.event_utc,
               ISNULL(s.first_seen, @now), @now, CASE WHEN s.severity = 'CRITICAL' THEN @now END, 1, s.is_muted
        FROM #Issue AS s
        WHERE NOT EXISTS (SELECT 1 FROM mon.Issue AS t WHERE t.issue_key = s.issue_key AND t.is_active = 1)
          /* an event that already expired never re-opens */
          AND NOT (s.is_event = 1 AND EXISTS (SELECT 1 FROM mon.Issue AS t WHERE t.issue_key = s.issue_key));

        INSERT mon.IssueChange(issue_id, change_type, old_severity, new_severity, change_utc)
        SELECT c.issue_id, 'OPENED', NULL, c.new_sev, @now FROM @chg AS c;
        DELETE @chg;

        /* 4. Resolve (state) / expire (event) issues that disappeared - only for categories evaluated cleanly. */
        UPDATE t
           SET t.is_active = 0, t.resolved_utc = @now,
               t.close_type = CASE WHEN t.is_event = 1 THEN 'EXPIRED' ELSE 'RESOLVED' END
        OUTPUT inserted.issue_id, deleted.severity, CASE WHEN inserted.is_event = 1 THEN 'E' ELSE 'R' END
          INTO @chg(issue_id, old_sev, new_sev)
        FROM mon.Issue AS t
        WHERE t.is_active = 1
          AND t.category IN (SELECT category FROM #Scope)
          AND NOT EXISTS (SELECT 1 FROM #Issue AS s WHERE s.issue_key = t.issue_key)
          AND (t.is_event = 1
               OR t.category = 'BLOCKING'
               OR t.last_seen_utc <= DATEADD(MINUTE, -@grace, @now));

        INSERT mon.IssueChange(issue_id, change_type, old_severity, new_severity, change_utc)
        SELECT c.issue_id, CASE WHEN c.new_sev = 'E' THEN 'EXPIRED' ELSE 'RESOLVED' END, c.old_sev, NULL, @now
        FROM @chg AS c;

        /* Resolved blocking: stamp the final duration into the title. */
        UPDATE i
           SET i.resolved_utc = e.last_seen_utc,   /* close at the last blocked sample, not the next cycle */
               i.title = LEFT(CONCAT(N'Blocking ', mon.fn_Duration(DATEDIFF(SECOND, e.blocked_since_utc, e.last_seen_utc)),
                                     N' - session ', e.head_session_id, N' (', ISNULL(e.head_login, N'?'), N') blocked ',
                                     e.max_blocked_count, N' session(s)',
                                     CASE WHEN e.databases_affected IS NOT NULL THEN CONCAT(N' in ', e.databases_affected) END), 400)
        FROM mon.Issue AS i
        JOIN @chg AS c ON c.issue_id = i.issue_id
        JOIN mon.BlockingEpisode AS e ON e.episode_id = i.ref_id
        WHERE i.category = 'BLOCKING';

        /* Expired events are never mailed. */
        UPDATE mon.IssueChange SET alert_status = 'SKIPPED', alert_utc = @now
        WHERE alert_status IS NULL AND change_type = 'EXPIRED';

        EXEC sys.sp_releaseapplock @Resource = N'mon_IssueMerge', @LockOwner = 'Session';
        EXEC mon.usp_SetComponentStatus 'EVALUATE', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        IF APPLOCK_MODE('public', N'mon_IssueMerge', 'Session') <> 'NoLock'
            EXEC sys.sp_releaseapplock @Resource = N'mon_IssueMerge', @LockOwner = 'Session';
        EXEC mon.usp_SetComponentStatus 'EVALUATE', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* =============================================================================
   SECTION 8b  -  BACKUP RETENTION / INVENTORY + CHECK MATRIX TOOLS   [rev 5.1]
   ============================================================================= */

/*
   Live retention per database and backup type.
   Evidence: msdb.backupset, RDS native task history (mon.RdsTask, ~36 days kept by AWS)
   and RDS automated log backups (mon.TlogBackup from rds_fn_list_tlog_backup_metadata).
   Per database/type the source with the most rows is used (avoids double counting a
   native backup that appears in both msdb and the RDS task list).
   NOTE: S3 lifecycle rules are invisible to T-SQL; "oldest" = oldest backup still recorded.
*/
CREATE OR ALTER VIEW mon.vw_BackupRetention
AS
WITH Cfg AS
(
    SELECT c.database_name, c.monitored, c.full_backup, c.diff_backup, c.log_backup, c.backup_retention,
           ISNULL(c.retention_days, ISNULL(mon.fn_SettingInt('backup_retention_target_days'), 7)) AS target_days,
           /* declared lifecycle of files on storage (S3 rule / Ola @CleanupTime); NULL = not declared */
           COALESCE(c.storage_retention_days, TRY_CONVERT(int, NULLIF(mon.fn_Setting('backup_storage_retention_days'), N''))) AS storage_days,
           ISNULL(p.full_max_age_minutes, 1440) AS full_sla, ISNULL(p.log_max_age_minutes, 30) AS log_sla,
           s.recovery_model, ISNULL(s.is_present, 0) AS is_present, s.create_date_utc
    FROM mon.DatabaseCheck AS c
    LEFT JOIN mon.DatabasePolicy AS p ON p.database_name = c.database_name
    LEFT JOIN mon.DatabaseStatus AS s ON s.database_name = c.database_name
), Ev AS
(
    /* msdb history: one row per backup, files = media families (striped backups count every file) */
    SELECT b.database_name COLLATE DATABASE_DEFAULT AS database_name,
           CONVERT(varchar(4), CASE b.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' ELSE 'LOG' END) AS btype,
           CONVERT(varchar(20), 'MSDB') AS src,
           CONVERT(datetime2(0), mon.fn_ServerToUtc(b.backup_finish_date)) AS t,
           CONVERT(bigint, COALESCE(b.compressed_backup_size, b.backup_size)) AS bytes,
           ISNULL(mf.n, 1) AS files, CONVERT(int, NULL) AS on_storage
    FROM msdb.dbo.backupset AS b
    LEFT JOIN (SELECT media_set_id, COUNT(*) AS n FROM msdb.dbo.backupmediafamily GROUP BY media_set_id) AS mf
           ON mf.media_set_id = b.media_set_id
    WHERE b.type IN ('D', 'I', 'L')
      AND b.backup_finish_date >= DATEADD(DAY, -400, GETDATE())
    UNION ALL
    /* RDS native backup to S3 (task history kept ~36 days by AWS) */
    SELECT r.database_name, CASE WHEN r.task_type = N'BACKUP_DB' THEN 'FULL' ELSE 'DIFF' END, 'RDS_TASK',
           r.last_updated_utc, CONVERT(bigint, NULL), 1, CONVERT(int, NULL)
    FROM mon.RdsTask AS r
    WHERE r.lifecycle = N'SUCCESS' AND r.task_type IN (N'BACKUP_DB', N'BACKUP_DB_DIFFERENTIAL')
      AND r.database_name IS NOT NULL AND r.last_updated_utc IS NOT NULL
    UNION ALL
    /* RDS automated log backups: on_storage = RDS still lists the file (daily full scan) */
    SELECT t.database_name, 'LOG', 'RDS_TLOG', t.backup_file_time_utc, t.file_size_bytes, 1,
           CASE WHEN t.last_seen_utc >= DATEADD(HOUR, -26, SYSUTCDATETIME()) THEN 1 ELSE 0 END
    FROM mon.TlogBackup AS t
    WHERE t.backup_file_time_utc >= DATEADD(DAY, -35, SYSUTCDATETIME())
    UNION ALL
    /* Ola Hallengren DatabaseBackup (dbo.CommandLog) */
    SELECT o.database_name, o.backup_type, 'OLA', o.end_utc, CONVERT(bigint, NULL), ISNULL(o.file_count, 1), CONVERT(int, NULL)
    FROM mon.OlaCommand AS o
    WHERE o.backup_type IS NOT NULL AND ISNULL(o.error_number, 0) = 0 AND o.end_utc IS NOT NULL AND o.database_name IS NOT NULL
), Src AS
(
    SELECT Ev.database_name, Ev.btype, Ev.src,
           ROW_NUMBER() OVER (PARTITION BY Ev.database_name, Ev.btype ORDER BY COUNT(*) DESC, Ev.src) AS rn
    FROM Ev
    GROUP BY Ev.database_name, Ev.btype, Ev.src
), E AS
(
    SELECT Ev.database_name, Ev.btype, Ev.src, Ev.t, Ev.bytes, Ev.files, Ev.on_storage,
           LAG(Ev.t) OVER (PARTITION BY Ev.database_name, Ev.btype ORDER BY Ev.t) AS prev_t
    FROM Ev
    JOIN Src ON Src.database_name = Ev.database_name AND Src.btype = Ev.btype AND Src.src = Ev.src AND Src.rn = 1
)
SELECT c.database_name, bt.btype AS backup_type,
       a.source_name, ISNULL(a.backup_count, 0) AS backup_count, a.oldest_utc, a.newest_utc,
       CONVERT(decimal(9,1), DATEDIFF(MINUTE, a.oldest_utc, SYSUTCDATETIME()) / 1440.0) AS retention_days,
       c.target_days, a.gaps, a.avg_interval_min, a.avg_bytes, a.total_bytes,
       ISNULL(a.files_total, 0) AS files_total, ISNULL(a.files_24h, 0) AS files_24h,
       CASE WHEN a.source_name = 'RDS_TLOG' THEN NULL ELSE c.storage_days END AS storage_days,   /* RDS log files follow RDS retention */
       CASE WHEN a.source_name = 'RDS_TLOG' THEN a.files_listed
            WHEN c.storage_days IS NOT NULL THEN a.files_in_policy END AS files_on_storage,
       CASE WHEN a.source_name = 'RDS_TLOG' THEN 'RDS list'
            WHEN c.storage_days IS NOT NULL THEN 'estimated'
            ELSE 'not declared' END AS storage_basis,
       CASE
           WHEN c.monitored = 0 OR c.backup_retention = 0 OR c.is_present = 0 THEN 'OFF'
           WHEN bt.btype = 'FULL' AND c.full_backup = 0 THEN 'OFF'
           WHEN bt.btype = 'DIFF' AND c.diff_backup = 0 THEN 'OFF'
           WHEN bt.btype = 'LOG'  AND (c.log_backup = 0 OR ISNULL(c.recovery_model, N'') <> N'FULL') THEN 'N/A'
           /* no DIFF rows at all = the database uses FULL (+LOG) only; DIFF age is covered by the DIFF check */
           WHEN bt.btype = 'DIFF' AND ISNULL(a.backup_count, 0) = 0 THEN 'N/A'
           WHEN ISNULL(a.backup_count, 0) = 0 THEN 'NONE'
           WHEN a.oldest_utc > DATEADD(DAY, -c.target_days, SYSUTCDATETIME())
                AND ISNULL(c.create_date_utc, '19000101') < DATEADD(DAY, -c.target_days, SYSUTCDATETIME()) THEN 'SHORT'
           /* declared storage lifecycle deletes files before the required retention */
           WHEN c.storage_days IS NOT NULL AND c.storage_days < c.target_days AND ISNULL(a.source_name, '') <> 'RDS_TLOG' THEN 'POLICY'
           WHEN a.gaps > 0 THEN 'GAPS'
           ELSE 'OK'
       END AS status
FROM Cfg AS c
CROSS JOIN (VALUES ('FULL'), ('DIFF'), ('LOG')) AS bt(btype)
OUTER APPLY
(
    SELECT MAX(E.src) AS source_name, COUNT(*) AS backup_count, MIN(E.t) AS oldest_utc, MAX(E.t) AS newest_utc,
           AVG(CONVERT(bigint, DATEDIFF(MINUTE, E.prev_t, E.t))) AS avg_interval_min,
           AVG(E.bytes) AS avg_bytes, SUM(E.bytes) AS total_bytes,
           SUM(E.files) AS files_total,
           SUM(CASE WHEN E.t >= DATEADD(HOUR, -24, SYSUTCDATETIME()) THEN E.files ELSE 0 END) AS files_24h,
           SUM(CASE WHEN E.on_storage = 1 THEN E.files ELSE 0 END) AS files_listed,
           SUM(CASE WHEN c.storage_days IS NOT NULL AND E.t >= DATEADD(DAY, -c.storage_days, SYSUTCDATETIME()) THEN E.files ELSE 0 END) AS files_in_policy,
           /* gaps inside the target window: interval longer than 1.25 x SLA (FULL and LOG only) */
           CASE WHEN bt.btype = 'DIFF' THEN NULL ELSE
               SUM(CASE WHEN E.prev_t IS NOT NULL
                         AND E.t >= DATEADD(DAY, -c.target_days, SYSUTCDATETIME())
                         AND DATEDIFF(MINUTE, E.prev_t, E.t) > 1.25 * CASE bt.btype WHEN 'FULL' THEN c.full_sla ELSE c.log_sla END
                        THEN 1 ELSE 0 END) END AS gaps
    FROM E
    WHERE E.database_name = c.database_name AND E.btype = bt.btype
) AS a;
GO

/* Daily snapshot (called by the hourly job; idempotent per day). Also feeds RETENTION issues. */
CREATE OR ALTER PROCEDURE mon.usp_SnapshotBackupInventory
    @Force bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 10000;
    SET DEADLOCK_PRIORITY LOW;
    DECLARE @today date = CONVERT(date, SYSUTCDATETIME()), @started datetime2(3) = SYSUTCDATETIME();
    BEGIN TRY
        IF @Force = 0 AND EXISTS (SELECT 1 FROM mon.BackupInventoryDaily WHERE snapshot_date = @today) RETURN;
        DELETE FROM mon.BackupInventoryDaily WHERE snapshot_date = @today;
        INSERT mon.BackupInventoryDaily(snapshot_date, database_name, backup_type, status, source_name, backup_count,
                                        oldest_utc, newest_utc, retention_days, target_days, gaps, avg_interval_min,
                                        avg_bytes, total_bytes, files_total, files_24h, files_on_storage,
                                        storage_days, storage_basis)
        SELECT @today, r.database_name, r.backup_type, r.status, r.source_name, r.backup_count,
               r.oldest_utc, r.newest_utc, r.retention_days, r.target_days, r.gaps, r.avg_interval_min,
               r.avg_bytes, r.total_bytes, r.files_total, r.files_24h, r.files_on_storage,
               r.storage_days, r.storage_basis
        FROM mon.vw_BackupRetention AS r;
        EXEC mon.usp_SetComponentStatus 'BACKUP_INVENTORY', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'BACKUP_INVENTORY', 0, @started, @en, @em;
    END CATCH;
END;
GO

/*
   Switch a check ON/OFF.
     @Database : exact name or LIKE pattern (N'%' = all databases). Ignored for server checks.
     @Check    : check code (FULL, LOG, LONGQ, CPU, ...), column name (long_queries), or 'ALL'
                 (= every database-level check except MONITORED).
   Examples:
     EXEC mon.usp_SetCheck @Database = N'DWH_Stage', @Check = 'LOG', @Enabled = 0;
     EXEC mon.usp_SetCheck @Database = N'%',         @Check = 'LONGQ', @Enabled = 0;
     EXEC mon.usp_SetCheck @Database = N'TestRestore', @Check = 'MONITORED', @Enabled = 0;
     EXEC mon.usp_SetCheck @Check = 'CPU', @Enabled = 0;                      -- server level
     EXEC mon.usp_SetCheck @Database = N'MioCore', @Check = 'RETENTION', @Enabled = 1, @RetentionDays = 14;
*/
CREATE OR ALTER PROCEDURE mon.usp_SetCheck
    @Database      sysname = N'%',
    @Check         varchar(40),
    @Enabled       bit,
    @RetentionDays int = NULL,
    @Notes         nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @code varchar(20), @scope varchar(10), @col sysname, @sql nvarchar(max), @n int;

    IF @Check = 'ALL'
        SET @code = 'ALL';
    ELSE
        SELECT @code = c.check_code, @scope = c.scope, @col = c.column_name
        FROM mon.CheckCatalog AS c
        WHERE c.check_code = @Check OR c.column_name = @Check;
    /* exact name first (names may contain LIKE wildcards such as _ ) */
    IF EXISTS (SELECT 1 FROM mon.DatabaseCheck WHERE database_name = @Database)
        SET @Database = REPLACE(REPLACE(REPLACE(@Database, N'[', N'[[]'), N'_', N'[_]'), N'%', N'[%]');

    IF @code IS NULL
    BEGIN
        RAISERROR(N'Unknown check "%s". Valid codes: SELECT check_code, scope, display_name FROM OPS.mon.CheckCatalog;', 16, 1, @Check);
        RETURN;
    END;

    IF @scope = 'SERVER'
    BEGIN
        UPDATE mon.ServerCheck SET is_enabled = @Enabled, notes = COALESCE(@Notes, notes) WHERE check_code = @code;
        SELECT check_code, display_name, is_enabled, notes, modified_utc, modified_by FROM mon.ServerCheck WHERE check_code = @code;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM mon.DatabaseCheck WHERE database_name LIKE @Database)
    BEGIN
        RAISERROR(N'No database in OPS.mon.DatabaseCheck matches "%s".', 16, 1, @Database);
        RETURN;
    END;

    IF @code = 'ALL'
        SET @sql = N'UPDATE mon.DatabaseCheck SET '
                 + STUFF((SELECT N', ' + QUOTENAME(c.column_name) + N' = @e'
                          FROM mon.CheckCatalog AS c
                          WHERE c.scope = 'DATABASE' AND c.column_name IS NOT NULL AND c.check_code <> 'MONITORED'
                          ORDER BY c.sort_order
                          FOR XML PATH(''), TYPE).value('(./text())[1]', 'nvarchar(max)'), 1, 2, N'')
                 + N' WHERE database_name LIKE @db;';
    ELSE
        SET @sql = N'UPDATE mon.DatabaseCheck SET ' + QUOTENAME(@col) + N' = @e WHERE database_name LIKE @db;';

    SELECT @n = COUNT(*) FROM mon.DatabaseCheck WHERE database_name LIKE @Database;
    EXEC sys.sp_executesql @sql, N'@e bit, @db sysname', @e = @Enabled, @db = @Database;

    IF @RetentionDays IS NOT NULL
        UPDATE mon.DatabaseCheck SET retention_days = NULLIF(@RetentionDays, 0) WHERE database_name LIKE @Database;
    IF @Notes IS NOT NULL
        UPDATE mon.DatabaseCheck SET notes = @Notes WHERE database_name LIKE @Database;

    PRINT CONCAT(N'Updated ', @n, N' database(s). Takes effect at the next 5-minute cycle; open issues of a disabled check close silently.');
    EXEC mon.usp_ShowChecks @Database = @Database;
END;
GO

/*
   Everything that is checked on this server, in one call (SSMS grid friendly):
     1) database matrix with check marks   2) server-level checks
     3) catalog: what each check does + which setting tunes it   4) last 50 changes (audit)
*/
CREATE OR ALTER PROCEDURE mon.usp_ShowChecks
    @Database sysname = N'%'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @y nchar(1) = NCHAR(10004), @na nvarchar(3) = N'n/a', @def int = ISNULL(mon.fn_SettingInt('backup_retention_target_days'), 7);

    SELECT c.database_name AS [Database],
           ISNULL(s.recovery_model, N'?') AS [Recovery],
           CASE WHEN c.monitored = 1 THEN @y ELSE N'' END AS [Monitored],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.full_backup = 1 THEN @y ELSE N'' END AS [Full],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.diff_backup = 1 THEN @y ELSE N'' END AS [Diff],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN ISNULL(s.recovery_model, N'FULL') <> N'FULL' THEN @na
                WHEN c.log_backup = 1 THEN @y ELSE N'' END AS [Log],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.backup_retention = 1 THEN @y ELSE N'' END AS [Retention],
           CONCAT(ISNULL(c.retention_days, @def), N'd', CASE WHEN c.retention_days IS NULL THEN N' (default)' END) AS [Retention target],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.checkdb = 1 THEN @y ELSE N'' END AS [CHECKDB],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.log_used = 1 THEN @y ELSE N'' END AS [Log used],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.vlf_count = 1 THEN @y ELSE N'' END AS [VLF],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.file_near_max = 1 THEN @y ELSE N'' END AS [File max],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.config_drift = 1 THEN @y ELSE N'' END AS [Drift],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.config_best_practice = 1 THEN @y ELSE N'' END AS [Config],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.query_store = 1 THEN @y ELSE N'' END AS [Query Store],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.blocking = 1 THEN @y ELSE N'' END AS [Blocking],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.long_queries = 1 THEN @y ELSE N'' END AS [Long queries],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.open_trans = 1 THEN @y ELSE N'' END AS [Open trans],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.deadlocks = 1 THEN @y ELSE N'' END AS [Deadlocks],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.io_latency = 1 THEN @y ELSE N'' END AS [I/O latency],
           CONCAT(p.full_max_age_minutes, N' / ', p.diff_max_age_minutes, N' / ', p.log_max_age_minutes, N' min') AS [SLA full/diff/log],
           c.notes AS [Notes],
           CASE WHEN ISNULL(s.is_present, 1) = 0 THEN N'DROPPED' ELSE N'' END AS [State],
           c.modified_utc AS [Modified UTC], c.modified_by AS [Modified by]
    FROM mon.DatabaseCheck AS c
    LEFT JOIN mon.DatabaseStatus AS s ON s.database_name = c.database_name
    LEFT JOIN mon.DatabasePolicy AS p ON p.database_name = c.database_name
    WHERE c.database_name LIKE @Database
    ORDER BY c.monitored DESC, c.database_name;

    SELECT s.check_code AS [Code], s.display_name AS [Server-level check],
           CASE WHEN s.is_enabled = 1 THEN @y ELSE N'' END AS [Enabled],
           k.description AS [What it checks], k.threshold_info AS [Tuned by], s.notes AS [Notes],
           s.modified_utc AS [Modified UTC], s.modified_by AS [Modified by]
    FROM mon.ServerCheck AS s
    JOIN mon.CheckCatalog AS k ON k.check_code = s.check_code
    ORDER BY k.sort_order;

    SELECT k.check_code AS [Code], k.scope AS [Scope], k.display_name AS [Check], k.column_name AS [DatabaseCheck column],
           k.description AS [What it checks], k.threshold_info AS [Tuned by], k.key_pattern AS [Issue key pattern]
    FROM mon.CheckCatalog AS k
    ORDER BY k.sort_order;

    SELECT TOP (50) l.changed_utc AS [Changed UTC], l.changed_by AS [By], l.host_name AS [Host], l.object_name AS [Object],
           l.item_name AS [Item], l.property_name AS [Property], l.old_value AS [Old], l.new_value AS [New]
    FROM mon.CheckChangeLog AS l
    ORDER BY l.change_log_id DESC;
END;
GO

/* Retention grid for SSMS (live) - @Live = 0 reads today's snapshot (fast). */
CREATE OR ALTER PROCEDURE mon.usp_ShowBackupRetention
    @Database sysname = N'%',
    @Live     bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');

    IF @Live = 1
        SELECT r.database_name AS [Database], r.backup_type AS [Type], r.status AS [Status], r.backup_count AS [Count],
               mon.fn_UtcToLocal(r.oldest_utc, @tz) AS [Oldest (local)], mon.fn_UtcToLocal(r.newest_utc, @tz) AS [Newest (local)],
               r.retention_days AS [Retention days], r.target_days AS [Target days], r.gaps AS [Gaps],
               mon.fn_Duration(r.avg_interval_min * 60) AS [Avg interval],
               CONVERT(decimal(19,2), r.avg_bytes / 1073741824.0) AS [Avg GB], CONVERT(decimal(19,2), r.total_bytes / 1073741824.0) AS [Total GB],
               r.files_total AS [Files made], r.files_24h AS [Files 24h], r.files_on_storage AS [Files on storage],
               r.storage_basis AS [On-storage basis], r.storage_days AS [Storage policy days],
               r.source_name AS [Source]
        FROM mon.vw_BackupRetention AS r
        WHERE r.database_name LIKE @Database
        ORDER BY CASE r.status WHEN 'NONE' THEN 0 WHEN 'SHORT' THEN 1 WHEN 'POLICY' THEN 2 WHEN 'GAPS' THEN 3 WHEN 'OK' THEN 4 ELSE 5 END,
                 r.database_name, CASE r.backup_type WHEN 'FULL' THEN 1 WHEN 'DIFF' THEN 2 ELSE 3 END;
    ELSE
        SELECT r.snapshot_date AS [Snapshot], r.database_name AS [Database], r.backup_type AS [Type], r.status AS [Status],
               r.backup_count AS [Count], mon.fn_UtcToLocal(r.oldest_utc, @tz) AS [Oldest (local)],
               mon.fn_UtcToLocal(r.newest_utc, @tz) AS [Newest (local)], r.retention_days AS [Retention days],
               r.target_days AS [Target days], r.gaps AS [Gaps], CONVERT(decimal(19,2), r.total_bytes / 1073741824.0) AS [Total GB],
               r.files_total AS [Files made], r.files_24h AS [Files 24h], r.files_on_storage AS [Files on storage],
               r.storage_basis AS [On-storage basis], r.storage_days AS [Storage policy days],
               r.source_name AS [Source]
        FROM mon.BackupInventoryDaily AS r
        WHERE r.snapshot_date = (SELECT MAX(snapshot_date) FROM mon.BackupInventoryDaily)
          AND r.database_name LIKE @Database
        ORDER BY CASE r.status WHEN 'NONE' THEN 0 WHEN 'SHORT' THEN 1 WHEN 'GAPS' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
                 r.database_name, r.backup_type;

    /* Totals per backup type: files made / still on storage / policy. */
    SELECT r.backup_type AS [Type], COUNT(*) AS [Databases], SUM(r.backup_count) AS [Backups recorded],
           SUM(r.files_total) AS [Files made], SUM(r.files_24h) AS [Files last 24h],
           SUM(r.files_on_storage) AS [Files on storage (known)],
           SUM(CASE WHEN r.storage_basis = 'not declared' THEN 1 ELSE 0 END) AS [DBs without declared storage policy],
           CONVERT(decimal(19,1), SUM(r.total_bytes) / 1073741824.0) AS [Total GB],
           MIN(r.oldest_utc) AS [Oldest UTC], MAX(r.newest_utc) AS [Newest UTC]
    FROM mon.vw_BackupRetention AS r
    WHERE r.status NOT IN ('OFF', 'N/A') AND r.database_name LIKE @Database
    GROUP BY r.backup_type
    ORDER BY CASE r.backup_type WHEN 'FULL' THEN 1 WHEN 'DIFF' THEN 2 ELSE 3 END;

    /* Trend: count and total size per day for the last 30 snapshots. */
    SELECT r.snapshot_date AS [Snapshot], r.backup_type AS [Type], SUM(r.backup_count) AS [Backups],
           SUM(r.files_on_storage) AS [Files on storage],
           CONVERT(decimal(19,1), SUM(r.total_bytes) / 1073741824.0) AS [Total GB],
           SUM(CASE WHEN r.status IN ('NONE', 'SHORT', 'GAPS', 'POLICY') THEN 1 ELSE 0 END) AS [Databases with problems]
    FROM mon.BackupInventoryDaily AS r
    WHERE r.snapshot_date >= DATEADD(DAY, -30, CONVERT(date, SYSUTCDATETIME()))
      AND r.database_name LIKE @Database
    GROUP BY r.snapshot_date, r.backup_type
    ORDER BY r.snapshot_date DESC, r.backup_type;
END;
GO

/* ---------- Datasets for the SSMS custom report (MON_Checks_and_Retention.rdl) ---------- */

CREATE OR ALTER PROCEDURE mon.usp_ReportChecks
AS
BEGIN
    SET NOCOUNT ON;
    /* Long format: one row per database x check; the report pivots it into a matrix. */
    SELECT c.database_name, k.check_code, k.display_name, k.sort_order,
           CASE WHEN k.check_code = 'MONITORED' THEN CASE WHEN c.monitored = 1 THEN 'ON' ELSE 'OFF' END
                WHEN c.monitored = 0 THEN 'NA'
                WHEN k.check_code = 'LOG' AND ISNULL(s.recovery_model, N'FULL') <> N'FULL' THEN 'NA'
                WHEN f.is_enabled = 1 THEN 'ON' ELSE 'OFF' END AS state,
           ISNULL(s.recovery_model, N'?') AS recovery_model, c.notes
    FROM mon.DatabaseCheck AS c
    CROSS JOIN mon.CheckCatalog AS k
    LEFT JOIN mon.vw_DatabaseCheckFlat AS f ON f.database_name = c.database_name AND f.check_code = k.check_code
    LEFT JOIN mon.DatabaseStatus AS s ON s.database_name = c.database_name
    WHERE k.scope = 'DATABASE'
    UNION ALL
    SELECT N'(server)', s.check_code, s.display_name, k.sort_order,
           CASE WHEN s.is_enabled = 1 THEN 'ON' ELSE 'OFF' END, N'', s.notes
    FROM mon.ServerCheck AS s JOIN mon.CheckCatalog AS k ON k.check_code = s.check_code;
END;
GO

CREATE OR ALTER PROCEDURE mon.usp_ReportRetention
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');
    SELECT r.database_name, r.backup_type, r.status, r.backup_count,
           CONVERT(nvarchar(16), mon.fn_UtcToLocal(r.oldest_utc, @tz), 120) AS oldest_local,
           CONVERT(nvarchar(16), mon.fn_UtcToLocal(r.newest_utc, @tz), 120) AS newest_local,
           r.retention_days, r.target_days, ISNULL(r.gaps, 0) AS gaps,
           mon.fn_Duration(r.avg_interval_min * 60) AS avg_interval,
           CONVERT(decimal(19,2), r.avg_bytes / 1073741824.0) AS avg_gb,
           CONVERT(decimal(19,2), r.total_bytes / 1073741824.0) AS total_gb,
           r.source_name,
           CASE r.status WHEN 'NONE' THEN 0 WHEN 'SHORT' THEN 1 WHEN 'POLICY' THEN 2 WHEN 'GAPS' THEN 3 WHEN 'OK' THEN 4 ELSE 5 END AS sort_key,
           r.files_total, r.files_24h, r.files_on_storage, r.storage_basis, r.storage_days
    FROM mon.vw_BackupRetention AS r
    WHERE r.status <> 'OFF';
END;
GO

/* =============================================================================
   SECTION 9  -  EMAIL BUILDING BLOCKS
   ============================================================================= */

CREATE OR ALTER FUNCTION mon.fn_SevRank(@severity varchar(10))
RETURNS int
AS
BEGIN
    RETURN CASE @severity WHEN 'CRITICAL' THEN 2 WHEN 'WARNING' THEN 1 ELSE 0 END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_EmailShell
(
    @banner_color varchar(7),
    @eyebrow      nvarchar(200),
    @title        nvarchar(300),
    @subtitle     nvarchar(1000),
    @body_rows    nvarchar(max),
    @footer_html  nvarchar(max)
)
RETURNS nvarchar(max)
AS
BEGIN
    /* 1000px centered card; MSO conditional wrapper pins the width in Outlook desktop. */
    RETURN CONCAT(CONVERT(nvarchar(max), N'<!DOCTYPE html><html><head>'),
        N'<meta http-equiv="Content-Type" content="text/html; charset=utf-8">',
        N'<meta name="viewport" content="width=device-width, initial-scale=1">',
        N'<meta name="x-apple-disable-message-reformatting"><title>', mon.fn_HtmlEncode(@title), N'</title>',
        N'<style>td.c{padding:6px 8px;border-bottom:1px solid #E5E7EB;font-size:12px;line-height:16px;vertical-align:top;',
        N'color:#1F2937;font-family:Segoe UI,Arial,Helvetica,sans-serif}',
        N'th.h{padding:7px 8px;font-size:11px;font-weight:700;color:#FFFFFF;background:#1E3A5F;text-align:left;',
        N'text-transform:uppercase;letter-spacing:.4px;white-space:nowrap;font-family:Segoe UI,Arial,Helvetica,sans-serif}',
        N'code{font-family:Consolas,Menlo,monospace;font-size:11px;color:#374151}</style></head>',
        N'<body style="margin:0;padding:0;background:#F3F4F6;-webkit-text-size-adjust:100%">',
        N'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#F3F4F6" style="background:#F3F4F6">',
        N'<tr><td align="center" style="padding:16px 8px">',
        N'<!--[if mso]><table role="presentation" width="1000" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->',
        N'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#FFFFFF" ',
        N'style="max-width:1000px;background:#FFFFFF;border:1px solid #E5E7EB;font-family:Segoe UI,Arial,Helvetica,sans-serif;color:#1F2937">',
        N'<tr><td bgcolor="', @banner_color, N'" style="padding:18px 24px;background:', @banner_color, N';color:#FFFFFF">',
        N'<div style="font-size:11px;letter-spacing:1.2px;text-transform:uppercase;color:#FFFFFF">', mon.fn_HtmlEncode(@eyebrow), N'</div>',
        N'<div style="font-size:22px;line-height:28px;font-weight:700;color:#FFFFFF;margin-top:2px">', mon.fn_HtmlEncode(@title), N'</div>',
        N'<div style="font-size:12px;color:#FFFFFF;margin-top:4px">', @subtitle, N'</div>',
        N'</td></tr>',
        @body_rows,
        N'<tr><td style="padding:18px 24px 22px 24px;border-top:1px solid #E5E7EB;font-size:11px;line-height:16px;color:#6B7280">',
        @footer_html, N'</td></tr>',
        N'</table>',
        N'<!--[if mso]></td></tr></table><![endif]-->',
        N'</td></tr></table></body></html>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Kpi(@value nvarchar(60), @label nvarchar(60), @sub nvarchar(100), @level varchar(4))
RETURNS nvarchar(max)
AS
BEGIN
    DECLARE @bg varchar(7) = CASE @level WHEN 'CRIT' THEN '#FEE2E2' WHEN 'WARN' THEN '#FEF3C7' WHEN 'OK' THEN '#F0FDF4' ELSE '#F9FAFB' END,
            @fg varchar(7) = CASE @level WHEN 'CRIT' THEN '#B91C1C' WHEN 'WARN' THEN '#B45309' WHEN 'OK' THEN '#15803D' ELSE '#111827' END;
    RETURN CONCAT(CONVERT(nvarchar(max), N'<td align="center" valign="top" bgcolor="'), @bg,
        N'" style="padding:10px 6px;background:', @bg, N';border:1px solid #FFFFFF">',
        N'<div style="font-size:22px;line-height:26px;font-weight:700;color:', @fg, N'">', mon.fn_HtmlEncode(@value), N'</div>',
        N'<div style="font-size:10px;line-height:13px;color:#374151;text-transform:uppercase;letter-spacing:.5px;font-weight:600">',
        mon.fn_HtmlEncode(@label), N'</div>',
        CASE WHEN @sub IS NOT NULL THEN CONCAT(N'<div style="font-size:10px;color:#6B7280">', mon.fn_HtmlEncode(@sub), N'</div>') END,
        N'</td>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_KpiRow(@cells nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    RETURN CONCAT(CONVERT(nvarchar(max), N'<tr><td style="padding:14px 24px 0 24px">'),
        N'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;table-layout:fixed"><tr>',
        @cells, N'</tr></table></td></tr>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_BackupLevel(@status varchar(20))
RETURNS varchar(4)
AS
BEGIN
    RETURN CASE
        WHEN @status IN ('MISSING', 'OVERDUE', 'CHAIN_BROKEN', 'NOT_ONLINE', 'NOT_FOUND') THEN 'CRIT'
        WHEN @status IN ('NEVER', 'UNKNOWN') THEN 'WARN'
        ELSE NULL END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_BackupCell
(
    @status varchar(20), @finish_utc datetime2(0), @age_min int, @source varchar(20), @tz nvarchar(100)
)
RETURNS nvarchar(max)
AS
BEGIN
    IF @status = 'NOT_REQUIRED'  RETURN mon.fn_Small(N'n/a');
    IF @status = 'NOT_MONITORED' RETURN mon.fn_Pill(N'NOT MONITORED', 'MUTE');
    IF @status IN ('NOT_ONLINE', 'NOT_FOUND') RETURN mon.fn_Small(N'-');
    RETURN CONCAT(CONVERT(nvarchar(max), N''),
        CASE WHEN @status <> 'OK'
             THEN CONCAT(mon.fn_Pill(REPLACE(@status, '_', ' '),
                         CASE WHEN @status = 'PENDING' THEN 'INFO' WHEN @status = 'NEEDS_FULL' THEN 'NA'
                              ELSE ISNULL(mon.fn_BackupLevel(@status), 'WARN') END), N'<br>') END,
        CASE WHEN @finish_utc IS NOT NULL
             THEN CONCAT(mon.fn_Nw(CONCAT(N'<b>', mon.fn_Duration(CONVERT(bigint, @age_min) * 60), N' ago</b>')), N'<br>',
                         mon.fn_Small(mon.fn_Nw(CONCAT(mon.fn_FmtLocal(@finish_utc, @tz), N' &middot; ',
                                             REPLACE(REPLACE(REPLACE(ISNULL(@source, ''), 'DMV_LOG_STATS', 'dmv'),
                                                     'RDS_TASK', 'rds&nbsp;task'), 'RDS_TLOG', 'rds&nbsp;log')))))
             ELSE mon.fn_Small(N'never') END);
END;
GO

CREATE OR ALTER FUNCTION mon.fn_WaitHint(@wait nvarchar(60))
RETURNS nvarchar(200)
AS
BEGIN
    RETURN CASE
        WHEN @wait LIKE N'PAGEIOLATCH%'        THEN N'Reading data pages from storage: memory pressure or missing indexes / scans'
        WHEN @wait = N'WRITELOG'               THEN N'Transaction log write latency or chatty commits'
        WHEN @wait LIKE N'LCK[_]M[_]%'         THEN N'Lock waits: blocking (see blocking section)'
        WHEN @wait IN (N'CXPACKET', N'CXSYNC_PORT', N'CXSYNC_CONSUMER') THEN N'Parallelism: check MAXDOP / cost threshold'
        WHEN @wait = N'SOS_SCHEDULER_YIELD'    THEN N'CPU pressure / spinning scans'
        WHEN @wait = N'RESOURCE_SEMAPHORE'     THEN N'Queries waiting for memory grants'
        WHEN @wait = N'ASYNC_NETWORK_IO'       THEN N'Client not consuming results fast enough (RBAR app / network)'
        WHEN @wait LIKE N'PAGELATCH%'          THEN N'In-memory page contention (tempdb allocation or last-page insert)'
        WHEN @wait = N'THREADPOOL'             THEN N'Worker thread exhaustion - serious'
        WHEN @wait IN (N'HADR_SYNC_COMMIT', N'DBMIRROR_SEND') THEN N'Multi-AZ synchronous commit to the standby'
        WHEN @wait LIKE N'IO[_]COMPLETION'     THEN N'Non-data I/O (sort/hash spills, backups)'
        WHEN @wait = N'OLEDB'                  THEN N'Linked server / DMV calls'
        WHEN @wait LIKE N'PREEMPTIVE%'         THEN N'External OS calls'
        WHEN @wait = N'LATCH_EX' OR @wait = N'LATCH_SH' THEN N'Non-page latch contention'
        ELSE N'' END;
END;
GO

/* =============================================================================
   SECTION 10  -  IMMEDIATE ALERTS  (change-only)
   Mail is produced ONLY when there is at least one:
     - OPENED or ESCALATED issue at/above alert_min_severity (not muted)
     - RESOLVED issue that had been alerted
     - optional reminder (reminder_minutes > 0)
   Nothing new -> no mail. Failed sends stay pending and are retried.
   ============================================================================= */
CREATE OR ALTER PROCEDURE mon.usp_SendAlertsCore
    @PreviewOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    DECLARE @now datetime2(0) = SYSUTCDATETIME(), @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @enabled bit       = ISNULL(mon.fn_SettingInt('send_immediate_alerts'), 1),
            @profile sysname   = mon.fn_Setting('mail_profile'),
            @recipients nvarchar(4000) = mon.fn_Setting('alert_recipients'),
            @server nvarchar(128) = ISNULL(mon.fn_Setting('server_label'), @@SERVERNAME),
            @tz nvarchar(100)  = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time'),
            @min_rank int      = mon.fn_SevRank(ISNULL(mon.fn_Setting('alert_min_severity'), N'CRITICAL')),
            @on_resolve bit    = ISNULL(mon.fn_SettingInt('alert_on_resolve'), 1),
            @reminder int      = ISNULL(mon.fn_SettingInt('reminder_minutes'), 0),
            @suppress int      = ISNULL(mon.fn_SettingInt('realert_suppress_minutes'), 60);

    /* High-water mark: only changes committed before this point are handled in this pass,
       so a change merged concurrently by another session is never marked SKIPPED unseen. */
    DECLARE @hwm bigint = ISNULL((SELECT MAX(change_id) FROM mon.IssueChange), 0);

    BEGIN TRY
        IF @PreviewOnly = 0
        BEGIN
            /* Outbox reconciliation: sp_send_dbmail only QUEUES mail. If Database Mail later reports
               the item as failed, re-open its changes so they are re-sent (once per failed item). */
            BEGIN TRY
                CREATE TABLE #FailedMail(mailitem_id int PRIMARY KEY);
                INSERT #FailedMail EXEC sys.sp_executesql N'
                    SELECT mailitem_id FROM msdb.dbo.rds_fn_sysmail_allitems()
                    WHERE sent_status = N''failed'' AND send_request_date >= DATEADD(DAY, -1, GETDATE());';
            END TRY
            BEGIN CATCH
                BEGIN TRY
                    INSERT #FailedMail EXEC sys.sp_executesql N'
                        SELECT mailitem_id FROM msdb.dbo.sysmail_allitems
                        WHERE sent_status = N''failed'' AND send_request_date >= DATEADD(DAY, -1, GETDATE());';
                END TRY
                BEGIN CATCH
                END CATCH;
            END CATCH;

            IF OBJECT_ID(N'tempdb..#FailedMail') IS NOT NULL
            BEGIN
                DECLARE @failed_nid TABLE(notification_id bigint PRIMARY KEY);
                UPDATE n SET send_ok = 0, error_message = N'Database Mail reported the item as failed; changes re-queued.'
                OUTPUT inserted.notification_id INTO @failed_nid
                FROM mon.Notification AS n
                JOIN #FailedMail AS f ON f.mailitem_id = n.mailitem_id
                WHERE n.notification_type = 'ALERT' AND n.send_ok = 1 AND n.created_utc >= DATEADD(DAY, -1, @now);

                UPDATE c SET alert_status = NULL, alert_utc = NULL, notification_id = NULL
                FROM mon.IssueChange AS c JOIN @failed_nid AS f ON f.notification_id = c.notification_id;
            END;

            IF @enabled = 0
            BEGIN
                UPDATE mon.IssueChange SET alert_status = 'SKIPPED', alert_utc = @now
                WHERE alert_status IS NULL AND change_id <= @hwm;
                RETURN;
            END;
            /* Never mail stale history (e.g. after a long mail outage) - the digest covers it. */
            UPDATE mon.IssueChange SET alert_status = 'SKIPPED', alert_utc = @now
            WHERE alert_status IS NULL AND change_id <= @hwm AND change_utc < DATEADD(HOUR, -24, @now);
        END;

        CREATE TABLE #A
        (
            change_id bigint NULL, issue_id bigint NOT NULL, kind varchar(12) NOT NULL,
            severity varchar(10) NOT NULL, change_utc datetime2(0) NOT NULL
        );

        INSERT #A(change_id, issue_id, kind, severity, change_utc)
        SELECT c.change_id, c.issue_id, c.change_type, ISNULL(c.new_severity, c.old_severity), c.change_utc
        FROM mon.IssueChange AS c
        JOIN mon.Issue AS i ON i.issue_id = c.issue_id
        WHERE c.alert_status IS NULL
          AND c.change_id <= @hwm
          AND i.is_muted = 0
          AND i.issue_key NOT LIKE N'MAIL:%'      /* never mail about mail failures (feedback loop) */
          AND (
                (c.change_type = 'OPENED' AND i.is_active = 1 AND mon.fn_SevRank(c.new_severity) >= @min_rank)
             OR (c.change_type = 'ESCALATED' AND i.is_active = 1 AND mon.fn_SevRank(c.new_severity) >= @min_rank
                 AND (i.alert_sent_utc IS NULL OR ISNULL(i.alert_severity, '') <> 'CRITICAL'
                      OR i.alert_sent_utc < DATEADD(MINUTE, -@suppress, @now)))
             OR (c.change_type = 'RESOLVED' AND @on_resolve = 1 AND i.alert_sent_utc IS NOT NULL)
              );

        IF @reminder > 0
            INSERT #A(change_id, issue_id, kind, severity, change_utc)
            SELECT NULL, i.issue_id, 'REMINDER', i.severity, @now
            FROM mon.Issue AS i
            WHERE i.is_active = 1 AND i.is_muted = 0 AND i.is_event = 0 AND i.severity = 'CRITICAL'
              AND i.alert_sent_utc IS NOT NULL
              AND COALESCE(i.last_reminder_utc, i.alert_sent_utc) < DATEADD(MINUTE, -@reminder, @now)
              AND NOT EXISTS (SELECT 1 FROM #A AS a WHERE a.issue_id = i.issue_id);

        IF @PreviewOnly = 0
            UPDATE c SET alert_status = 'SKIPPED', alert_utc = @now
            FROM mon.IssueChange AS c
            WHERE c.alert_status IS NULL
              AND c.change_id <= @hwm
              AND NOT EXISTS (SELECT 1 FROM #A AS a WHERE a.change_id = c.change_id);

        IF NOT EXISTS (SELECT 1 FROM #A)
        BEGIN
            IF @PreviewOnly = 1 SELECT N'(no pending alert changes - no mail would be sent)' AS preview;
            RETURN;   /* <<< CHANGE-ONLY: nothing new, nothing sent */
        END;

        DECLARE @n_new int = (SELECT COUNT(*) FROM #A WHERE kind = 'OPENED'),
                @n_esc int = (SELECT COUNT(*) FROM #A WHERE kind = 'ESCALATED'),
                @n_res int = (SELECT COUNT(*) FROM #A WHERE kind = 'RESOLVED'),
                @n_rem int = (SELECT COUNT(*) FROM #A WHERE kind = 'REMINDER'),
                @total int = (SELECT COUNT(*) FROM #A);
        DECLARE @worst varchar(10) =
            CASE WHEN EXISTS (SELECT 1 FROM #A WHERE kind <> 'RESOLVED' AND severity = 'CRITICAL') THEN 'CRITICAL'
                 WHEN EXISTS (SELECT 1 FROM #A WHERE kind <> 'RESOLVED') THEN 'WARNING'
                 ELSE 'RESOLVED' END;
        DECLARE @top_title nvarchar(400) =
            (SELECT TOP (1) i.title FROM #A AS a JOIN mon.Issue AS i ON i.issue_id = a.issue_id
             ORDER BY CASE WHEN a.kind = 'RESOLVED' THEN 1 ELSE 0 END, mon.fn_SevRank(a.severity) DESC, a.change_utc DESC);
        DECLARE @active_crit int = (SELECT COUNT(*) FROM mon.Issue WHERE is_active = 1 AND severity = 'CRITICAL' AND is_muted = 0),
                @active_warn int = (SELECT COUNT(*) FROM mon.Issue WHERE is_active = 1 AND severity = 'WARNING' AND is_muted = 0);

        DECLARE @subject nvarchar(255) = LEFT(CONCAT(N'[', @server, N'] ', @worst, N': ', @top_title,
                                              CASE WHEN @total > 1 THEN CONCAT(N' (+', @total - 1, N' more)') END), 255);

        DECLARE @rows_open nvarchar(max), @rows_res nvarchar(max), @rows_ctx nvarchar(max), @body_rows nvarchar(max) = N'';

        SET @rows_open =
        (
            SELECT CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_Pill(a.severity, mon.fn_SevLevel(a.severity)), mon.fn_SevLevel(a.severity)),
                   mon.fn_Td(mon.fn_Pill(CASE a.kind WHEN 'OPENED' THEN N'NEW' ELSE a.kind END, 'INFO'), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(i.category), NULL),
                   mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(i.title), N'</b><br>',
                                    mon.fn_Small(REPLACE(mon.fn_OneLine(i.detail, 1200), N' | ', N'<br>')),
                                    N'<br>', mon.fn_Small(CONCAT(N'key: ', mon.fn_HtmlEncode(i.issue_key)))), mon.fn_SevLevel(a.severity)),
                   mon.fn_Td(mon.fn_HtmlEncode(ISNULL(i.database_name, N'-')), NULL),
                   mon.fn_Td(CONCAT(mon.fn_Nw(mon.fn_FmtLocal(i.first_seen_utc, @tz)), N'<br>',
                                    mon.fn_Small(CONCAT(N'open ', mon.fn_Duration(DATEDIFF(SECOND, i.first_seen_utc, @now))))), NULL),
                   N'</tr>')
            FROM #A AS a JOIN mon.Issue AS i ON i.issue_id = a.issue_id
            WHERE a.kind <> 'RESOLVED'
            ORDER BY mon.fn_SevRank(a.severity) DESC, a.change_utc DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');

        SET @rows_res =
        (
            SELECT CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_Pill(N'RESOLVED', 'OK'), 'OK'),
                   mon.fn_Td(mon.fn_HtmlEncode(i.category), NULL),
                   mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(i.title), N'</b>',
                                    CASE WHEN i.category = 'BLOCKING' AND e.episode_id IS NOT NULL
                                         THEN CONCAT(N'<br>', mon.fn_Small(CONCAT(N'Final: blocked ',
                                              mon.fn_Duration(DATEDIFF(SECOND, e.blocked_since_utc, e.last_seen_utc)),
                                              N', max ', e.max_blocked_count, N' blocked session(s), head ', e.head_session_id,
                                              N' (', mon.fn_HtmlEncode(ISNULL(e.head_login, N'?')), N')'))) END), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(ISNULL(i.database_name, N'-')), NULL),
                   mon.fn_Td(mon.fn_Duration(DATEDIFF(SECOND, i.first_seen_utc, i.resolved_utc)), NULL),
                   mon.fn_Td(mon.fn_Nw(mon.fn_FmtLocal(i.resolved_utc, @tz)), NULL),
                   N'</tr>')
            FROM #A AS a
            JOIN mon.Issue AS i ON i.issue_id = a.issue_id
            LEFT JOIN mon.BlockingEpisode AS e ON i.category = 'BLOCKING' AND e.episode_id = i.ref_id
            WHERE a.kind = 'RESOLVED'
            ORDER BY a.change_utc DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');

        SET @rows_ctx =
        (
            SELECT TOP (15) CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_Pill(i.severity, mon.fn_SevLevel(i.severity)), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(i.category), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(i.title), NULL),
                   mon.fn_Td(mon.fn_Duration(DATEDIFF(SECOND, i.first_seen_utc, @now)), NULL),
                   N'</tr>')
            FROM mon.Issue AS i
            WHERE i.is_active = 1 AND i.is_muted = 0
              AND NOT EXISTS (SELECT 1 FROM #A AS a WHERE a.issue_id = i.issue_id)
            ORDER BY mon.fn_SevRank(i.severity) DESC, i.first_seen_utc
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');

        IF @rows_open IS NOT NULL
            SET @body_rows += mon.fn_Section(N'New / escalated', N'Opened or worsened since the last alert.',
                                             N'Severity|Change|Category|Issue|Database|First seen', @rows_open);
        IF @rows_res IS NOT NULL
            SET @body_rows += mon.fn_Section(N'Resolved', N'Previously alerted issues that cleared.',
                                             N'Status|Category|Issue|Database|Open for|Resolved', @rows_res);
        IF @rows_ctx IS NOT NULL
            SET @body_rows += mon.fn_Section(N'Still active (context)', N'Already alerted or below the alert threshold - no action from this mail.',
                                             N'Severity|Category|Issue|Open for', @rows_ctx);

        DECLARE @body nvarchar(max) = mon.fn_EmailShell(
            CASE @worst WHEN 'CRITICAL' THEN '#B91C1C' WHEN 'WARNING' THEN '#B45309' ELSE '#15803D' END,
            CONCAT(@server, N' - SQL Server alert'),
            CASE @worst WHEN 'RESOLVED' THEN N'Resolved' ELSE CONCAT(@worst, N' alert') END,
            CONCAT(@n_new, N' new &middot; ', @n_esc, N' escalated &middot; ', @n_res, N' resolved',
                   CASE WHEN @n_rem > 0 THEN CONCAT(N' &middot; ', @n_rem, N' reminder') END,
                   N' &nbsp;|&nbsp; now active: ', @active_crit, N' critical, ', @active_warn, N' warning',
                   N' &nbsp;|&nbsp; ', mon.fn_FmtLocal(@now, @tz), N' ', ISNULL(mon.fn_Setting('display_time_zone_label'), N'ET')),
            @body_rows,
            CONCAT(N'<b>Change-only alerting.</b> You get mail only when an issue opens, escalates or resolves. ',
                   N'Mute a known issue: <code>EXEC OPS.mon.usp_MuteIssue @KeyPattern = N''&lt;key&gt;'', @Hours = 8, @Reason = N''...'';</code><br>',
                   N'Live view: <code>SELECT * FROM OPS.mon.vw_ActiveIssues;</code> &middot; blocking chains: <code>OPS.mon.vw_BlockingNow</code><br>',
                   N'Generated ', CONVERT(nvarchar(19), @now, 120), N' UTC by OPS.mon on ', mon.fn_HtmlEncode(@@SERVERNAME), N'.'));

        IF @PreviewOnly = 1
        BEGIN
            SELECT @subject AS subject, @body AS html_body;
            RETURN;
        END;

        DECLARE @mailitem_id int, @nid bigint, @sent bit = 0,
                @importance varchar(6) = CASE WHEN @worst = 'CRITICAL' THEN 'High' ELSE 'Normal' END;
        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail
                 @profile_name = @profile, @recipients = @recipients,
                 @subject = @subject, @body = @body, @body_format = 'HTML',
                 @importance = @importance,
                 @mailitem_id = @mailitem_id OUTPUT;
            SET @sent = 1;
        END TRY
        BEGIN CATCH
            DECLARE @em nvarchar(2000) = ERROR_MESSAGE(), @en int = ERROR_NUMBER();
            INSERT mon.Notification(notification_type, created_utc, subject, recipients, send_ok, error_message, change_count)
            VALUES ('ALERT', @now, @subject, @recipients, 0, @em, @total);
            EXEC mon.usp_SetComponentStatus 'ALERT_MAIL', 0, @started, @en, @em;
            /* changes stay pending -> retried next cycle */
        END CATCH;

        IF @sent = 1
        BEGIN
            /* Queued: bookkeeping must never cause a duplicate send, so each step is independent. */
            BEGIN TRY
                INSERT mon.Notification(notification_type, created_utc, subject, recipients, mailitem_id, send_ok,
                                        change_count, active_critical, active_warning, body_kb)
                VALUES ('ALERT', @now, @subject, @recipients, @mailitem_id, 1, @total, @active_crit, @active_warn, DATALENGTH(@body) / 2048);
                SET @nid = SCOPE_IDENTITY();
            END TRY
            BEGIN CATCH
                SET @nid = NULL;
            END CATCH;

            UPDATE c SET alert_status = 'SENT', alert_utc = @now, notification_id = @nid
            FROM mon.IssueChange AS c JOIN #A AS a ON a.change_id = c.change_id;

            UPDATE i SET alert_sent_utc = @now, alert_severity = i.severity
            FROM mon.Issue AS i JOIN #A AS a ON a.issue_id = i.issue_id
            WHERE a.kind IN ('OPENED', 'ESCALATED');

            UPDATE i SET last_reminder_utc = @now
            FROM mon.Issue AS i JOIN #A AS a ON a.issue_id = i.issue_id
            WHERE a.kind = 'REMINDER';

            EXEC mon.usp_SetComponentStatus 'ALERT_MAIL', 1, @started;
        END;
    END TRY
    BEGIN CATCH
        DECLARE @em2 nvarchar(2000) = ERROR_MESSAGE(), @en2 int = ERROR_NUMBER();
        EXEC mon.usp_SetComponentStatus 'ALERT_MAIL', 0, @started, @en2, @em2;
    END CATCH;
END;
GO

/* =============================================================================
   SECTION 11  -  DAILY DIGEST / WEEKLY HEARTBEAT  (change-only)
   Due from report_hour_local (DST aware) once per local day. Sent only if at
   least one issue OPENED / ESCALATED / DEESCALATED / RESOLVED since the last
   digest; otherwise logged as DIGEST_SKIPPED. On heartbeat_weekday a digest is
   sent even without changes. @Force = 1 sends now; @PreviewOnly = 1 returns HTML.
   ============================================================================= */
CREATE OR ALTER PROCEDURE mon.usp_SendDailyDigest
    @Force       bit = 0,
    @PreviewOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 10000;

    DECLARE @now datetime2(0) = SYSUTCDATETIME(), @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @enabled bit       = ISNULL(mon.fn_SettingInt('send_daily_digest'), 1),
            @profile sysname   = mon.fn_Setting('mail_profile'),
            @recipients nvarchar(4000) = mon.fn_Setting('report_recipients'),
            @server nvarchar(128) = ISNULL(mon.fn_Setting('server_label'), @@SERVERNAME),
            @tz nvarchar(100)  = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time'),
            @tzl nvarchar(20)  = ISNULL(mon.fn_Setting('display_time_zone_label'), N'ET'),
            @hour int          = ISNULL(mon.fn_SettingInt('report_hour_local'), 8),
            @hb_day int        = ISNULL(mon.fn_SettingInt('heartbeat_weekday'), 1),
            @cap int           = ISNULL(mon.fn_SettingInt('email_max_rows_per_section'), 40),
            @lookback int      = ISNULL(mon.fn_SettingInt('event_lookback_hours'), 24),
            @retention int     = ISNULL(mon.fn_SettingInt('history_retention_days'), 90),
            @blk_min int       = ISNULL(mon.fn_SettingInt('blocking_alert_minutes'), 10),
            @log_warn int      = ISNULL(mon.fn_SettingInt('log_used_warn_pct'), 80),
            @log_crit int      = ISNULL(mon.fn_SettingInt('log_used_crit_pct'), 90),
            @vlf int           = ISNULL(mon.fn_SettingInt('vlf_warn_count'), 1000),
            @io_ms int         = ISNULL(mon.fn_SettingInt('io_latency_warn_ms'), 50),
            @st_warn int       = ISNULL(mon.fn_SettingInt('storage_free_warn_pct'), 15),
            @st_crit int       = ISNULL(mon.fn_SettingInt('storage_free_crit_pct'), 10),
            @jd_factor decimal(9,2) = ISNULL(TRY_CONVERT(decimal(9,2), mon.fn_Setting('job_duration_factor')), 2.0),
            @jd_min int        = ISNULL(mon.fn_SettingInt('job_duration_min_minutes'), 15);

    DECLARE @local_now datetime2(0) = mon.fn_UtcToLocal(@now, @tz);
    DECLARE @today date = CONVERT(date, @local_now);
    DECLARE @iso_wd int = (DATEPART(WEEKDAY, @local_now) + @@DATEFIRST - 2) % 7 + 1;   /* 1 = Monday */
    DECLARE @since datetime2(0) = (SELECT MAX(created_utc) FROM mon.Notification
                                   WHERE notification_type IN ('DIGEST', 'HEARTBEAT') AND send_ok = 1);
    DECLARE @window_start datetime2(0) = DATEADD(HOUR, -@lookback, @now);
    /* change_id watermarks (not timestamps): a change merged while a digest is being built is never lost. */
    DECLARE @since_id bigint = (SELECT MAX(last_change_id) FROM mon.Notification
                                WHERE notification_type IN ('DIGEST', 'HEARTBEAT') AND send_ok = 1);
    DECLARE @hwm bigint = ISNULL((SELECT MAX(change_id) FROM mon.IssueChange), 0);
    IF @since_id IS NULL   /* first digest ever (or upgraded install): last 24 hours */
        SET @since_id = ISNULL((SELECT MAX(change_id) FROM mon.IssueChange WHERE change_utc <= DATEADD(HOUR, -24, @now)), 0);

    BEGIN TRY
        /* ---------------- due / change-only decision ---------------- */
        IF @Force = 0 AND @PreviewOnly = 0
        BEGIN
            IF @enabled = 0 RETURN;
            IF DATEPART(HOUR, @local_now) < @hour RETURN;
            IF EXISTS (SELECT 1 FROM mon.Notification
                       WHERE report_date_local = @today
                         AND ((notification_type IN ('DIGEST', 'HEARTBEAT') AND send_ok = 1)
                              OR notification_type = 'DIGEST_SKIPPED'))
                RETURN;
        END;

        DECLARE @ch_open int, @ch_res int, @ch_esc int, @ch_total int;
        SELECT @ch_open  = SUM(CASE WHEN change_type = 'OPENED' THEN 1 ELSE 0 END),
               @ch_res   = SUM(CASE WHEN change_type = 'RESOLVED' THEN 1 ELSE 0 END),
               @ch_esc   = SUM(CASE WHEN change_type IN ('ESCALATED', 'DEESCALATED') THEN 1 ELSE 0 END),
               @ch_total = COUNT(*)
        FROM mon.IssueChange
        WHERE change_id > @since_id AND change_id <= @hwm
          AND change_type <> 'EXPIRED';
        SELECT @ch_open = ISNULL(@ch_open, 0), @ch_res = ISNULL(@ch_res, 0), @ch_esc = ISNULL(@ch_esc, 0);

        DECLARE @is_hb_day bit = CASE WHEN @iso_wd = @hb_day THEN 1 ELSE 0 END;
        /* DBA changes to the check matrix / settings also count as a change worth a digest. */
        DECLARE @cfg_changes int = (SELECT COUNT(*) FROM mon.CheckChangeLog
                                    WHERE changed_utc > ISNULL(@since, DATEADD(HOUR, -24, @now)));
        SET @ch_total += @cfg_changes;

        IF @Force = 0 AND @PreviewOnly = 0 AND @ch_total = 0 AND @since IS NOT NULL AND @is_hb_day = 0
        BEGIN
            INSERT mon.Notification(notification_type, created_utc, report_date_local, change_count)
            VALUES ('DIGEST_SKIPPED', @now, @today, 0);     /* <<< CHANGE-ONLY: nothing changed, nothing sent */
            RETURN;
        END;

        DECLARE @kind varchar(20) = CASE WHEN @ch_total = 0 AND @since IS NOT NULL THEN 'HEARTBEAT' ELSE 'DIGEST' END;

        /* ---------------- KPIs ---------------- */
        DECLARE @db_total int, @db_online int, @bk_total int, @bk_ok int, @crit int, @warn int, @muted int,
                @blk_n int, @blk_max bigint, @dl_n int, @jf_n int, @cpu_avg int, @cpu_max int, @cpu_p95 int,
                @ple bigint, @grants_max int, @tdb_max decimal(19,1), @vs_max decimal(19,1), @skipped int;

        SELECT @db_total = COUNT(*), @db_online = SUM(CASE WHEN state_desc = N'ONLINE' THEN 1 ELSE 0 END)
        FROM mon.DatabaseStatus WHERE is_present = 1;

        SELECT @bk_total = COUNT(*),
               @bk_ok = SUM(CASE WHEN full_status IN ('OK', 'NOT_REQUIRED', 'PENDING')
                                  AND diff_status IN ('OK', 'NOT_REQUIRED', 'PENDING')
                                  AND log_status  IN ('OK', 'NOT_REQUIRED', 'PENDING') THEN 1 ELSE 0 END)
        FROM mon.vw_BackupHealth WHERE is_monitored = 1 AND is_present = 1;

        SELECT @crit  = SUM(CASE WHEN severity = 'CRITICAL' AND is_muted = 0 THEN 1 ELSE 0 END),
               @warn  = SUM(CASE WHEN severity = 'WARNING'  AND is_muted = 0 THEN 1 ELSE 0 END),
               @muted = SUM(CASE WHEN is_muted = 1 THEN 1 ELSE 0 END)
        FROM mon.Issue WHERE is_active = 1;

        SELECT @blk_n = SUM(CASE WHEN DATEDIFF(SECOND, blocked_since_utc, last_seen_utc) >= @blk_min * 60 THEN 1 ELSE 0 END),
               @blk_max = MAX(DATEDIFF(SECOND, blocked_since_utc, last_seen_utc))
        FROM mon.BlockingEpisode WHERE last_seen_utc >= @window_start;

        SELECT @dl_n = COUNT(*) FROM mon.Deadlock WHERE event_utc >= @window_start;
        SELECT @jf_n = COUNT(*) FROM mon.AgentFailure WHERE run_start_utc >= @window_start;
        SELECT @cpu_avg = AVG(sql_cpu_pct * 1), @cpu_max = MAX(sql_cpu_pct) FROM mon.CpuSample WHERE sample_utc >= @window_start;
        SELECT TOP (1) @cpu_p95 = CONVERT(int, PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY sql_cpu_pct) OVER ())
        FROM mon.CpuSample WHERE sample_utc >= @window_start;
        SELECT TOP (1) @ple = ple_sec FROM mon.PerfSample ORDER BY sample_utc DESC;
        SELECT @grants_max = MAX(memory_grants_pending), @tdb_max = MAX(tempdb_used_mb) / 1024.0,
               @vs_max = MAX(tempdb_version_store_mb) / 1024.0
        FROM mon.PerfSample WHERE sample_utc >= @window_start;
        SELECT @skipped = COUNT(*) FROM mon.Notification
        WHERE notification_type = 'DIGEST_SKIPPED' AND created_utc > ISNULL(@since, '19000101');

        SELECT @crit = ISNULL(@crit, 0), @warn = ISNULL(@warn, 0), @muted = ISNULL(@muted, 0),
               @blk_n = ISNULL(@blk_n, 0), @bk_ok = ISNULL(@bk_ok, 0), @db_online = ISNULL(@db_online, 0);

        DECLARE @overall varchar(10) = CASE WHEN @crit > 0 THEN 'CRITICAL' WHEN @warn > 0 THEN 'WARNING' ELSE 'HEALTHY' END;

        DECLARE @body nvarchar(max) = N'', @rows nvarchar(max), @n int;

        /* ---------------- KPI tiles ---------------- */
        SET @body += mon.fn_KpiRow(CONCAT(CONVERT(nvarchar(max), N''),
            mon.fn_Kpi(CONCAT(@db_online, N'/', @db_total), N'Databases online', NULL, CASE WHEN @db_online < @db_total THEN 'CRIT' ELSE 'OK' END),
            mon.fn_Kpi(CONCAT(@bk_ok, N'/', @bk_total), N'Backups compliant', NULL, CASE WHEN @bk_ok < @bk_total THEN 'CRIT' ELSE 'OK' END),
            mon.fn_Kpi(CONVERT(nvarchar(10), @crit), N'Critical issues', CASE WHEN @muted > 0 THEN CONCAT(@muted, N' muted') END, CASE WHEN @crit > 0 THEN 'CRIT' ELSE 'OK' END),
            mon.fn_Kpi(CONVERT(nvarchar(10), @warn), N'Warnings', NULL, CASE WHEN @warn > 0 THEN 'WARN' ELSE 'OK' END),
            mon.fn_Kpi(CONVERT(nvarchar(10), @blk_n), CONCAT(N'Blocking > ', @blk_min, N'm'), CONCAT(N'max ', mon.fn_Duration(@blk_max)), CASE WHEN @blk_n > 0 THEN 'CRIT' ELSE 'OK' END),
            mon.fn_Kpi(CONVERT(nvarchar(10), @dl_n), N'Deadlocks', CONCAT(@lookback, N'h'), CASE WHEN @dl_n > 0 THEN 'WARN' ELSE 'OK' END),
            mon.fn_Kpi(CONVERT(nvarchar(10), @jf_n), N'Job failures', CONCAT(@lookback, N'h'), CASE WHEN @jf_n > 0 THEN 'CRIT' ELSE 'OK' END),
            mon.fn_Kpi(ISNULL(CONCAT(@cpu_avg, N'%'), N'-'), N'CPU avg', CONCAT(N'p95 ', ISNULL(CONVERT(nvarchar(5), @cpu_p95), N'-'), N'% / max ', ISNULL(CONVERT(nvarchar(5), @cpu_max), N'-'), N'%'),
                       CASE WHEN @cpu_p95 >= 90 THEN 'CRIT' WHEN @cpu_p95 >= 75 THEN 'WARN' ELSE NULL END)));

        /* ---------------- 1. What changed ---------------- */
        SELECT @n = COUNT(*) FROM mon.IssueChange
        WHERE change_id > @since_id AND change_id <= @hwm AND change_type <> 'EXPIRED';
        SET @rows =
        (
            SELECT TOP (@cap) CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_Nw(mon.fn_FmtLocal(c.change_utc, @tz)), NULL),
                   mon.fn_Td(mon.fn_Pill(c.change_type,
                             CASE c.change_type WHEN 'RESOLVED' THEN 'OK' WHEN 'DEESCALATED' THEN 'WARN'
                                                WHEN 'ESCALATED' THEN 'CRIT' ELSE mon.fn_SevLevel(c.new_severity) END), NULL),
                   mon.fn_Td(mon.fn_Pill(ISNULL(c.new_severity, c.old_severity), mon.fn_SevLevel(ISNULL(c.new_severity, c.old_severity))), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(i.category), NULL),
                   mon.fn_Td(CONCAT(mon.fn_HtmlEncode(i.title),
                                    CASE WHEN i.is_muted = 1 THEN CONCAT(N' ', mon.fn_Pill(N'MUTED', 'MUTE')) END),
                             CASE WHEN c.change_type IN ('OPENED', 'ESCALATED') AND i.is_active = 1 THEN mon.fn_SevLevel(c.new_severity) END),
                   mon.fn_Td(CASE WHEN c.change_type = 'RESOLVED'
                                  THEN mon.fn_Nw(CONCAT(N'open ', mon.fn_Duration(DATEDIFF(SECOND, i.first_seen_utc, i.resolved_utc))))
                                  WHEN i.is_active = 1 THEN N'still&nbsp;open' ELSE N'closed' END, NULL),
                   N'</tr>')
            FROM mon.IssueChange AS c
            JOIN mon.Issue AS i ON i.issue_id = c.issue_id
            WHERE c.change_id > @since_id AND c.change_id <= @hwm AND c.change_type <> 'EXPIRED'
            ORDER BY c.change_utc DESC, c.change_id DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(N'What changed since the last report',
            CONCAT(ISNULL(CONCAT(N'Since ', mon.fn_FmtLocal(@since, @tz), N' ', @tzl), N'Last 24 hours'), N' &middot; ',
                   @ch_open, N' opened, ', @ch_res, N' resolved, ', @ch_esc, N' severity change(s)',
                   CASE WHEN @n > @cap THEN CONCAT(N' &middot; showing ', @cap, N' of ', @n, N' (see OPS.mon.vw_RecentChanges)') END),
            N'When|Change|Severity|Category|Issue|State',
            ISNULL(@rows, mon.fn_EmptyRow(6, N'No changes - everything is exactly as in the previous report.')));

        /* ---------------- 2. Active issues ---------------- */
        SELECT @n = COUNT(*) FROM mon.Issue WHERE is_active = 1;
        SET @rows =
        (
            SELECT TOP (@cap) CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_Pill(i.severity, CASE WHEN i.is_muted = 1 THEN 'MUTE' ELSE mon.fn_SevLevel(i.severity) END),
                             CASE WHEN i.is_muted = 0 THEN mon.fn_SevLevel(i.severity) END),
                   mon.fn_Td(mon.fn_HtmlEncode(i.category), NULL),
                   mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(i.title), N'</b>',
                                    CASE WHEN i.is_muted = 1 THEN CONCAT(N' ', mon.fn_Pill(N'MUTED', 'MUTE')) END,
                                    N'<br>', mon.fn_Small(REPLACE(mon.fn_OneLine(i.detail, 600), N' | ', N'<br>')),
                                    N'<br>', mon.fn_Small(CONCAT(N'key: ', mon.fn_HtmlEncode(i.issue_key)))),
                             CASE WHEN i.is_muted = 0 THEN mon.fn_SevLevel(i.severity) END),
                   mon.fn_Td(mon.fn_HtmlEncode(ISNULL(i.database_name, N'-')), NULL),
                   mon.fn_Td(CONCAT(mon.fn_Duration(DATEDIFF(SECOND, i.first_seen_utc, @now)), N'<br>',
                                    mon.fn_Small(CONCAT(N'since ', mon.fn_FmtLocal(i.first_seen_utc, @tz)))), NULL),
                   N'</tr>')
            FROM mon.Issue AS i
            WHERE i.is_active = 1
            ORDER BY i.is_muted, mon.fn_SevRank(i.severity) DESC, i.category, i.first_seen_utc
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(N'Open issues',
            CONCAT(@crit, N' critical &middot; ', @warn, N' warning', CASE WHEN @muted > 0 THEN CONCAT(N' &middot; ', @muted, N' muted') END,
                   CASE WHEN @n > @cap THEN CONCAT(N' &middot; showing ', @cap, N' of ', @n, N' (OPS.mon.vw_ActiveIssues)') END),
            N'Severity|Category|Issue|Database|Open for',
            ISNULL(@rows, mon.fn_EmptyRow(5, N'No open issues.')));

        /* ---------------- 3. Database inventory & backups (every database) ---------------- */
        SELECT @n = COUNT(*) FROM mon.vw_BackupHealth;
        SET @rows =
        (
            SELECT TOP (250) CONCAT(N'<tr>',
                   mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(h.database_name), N'</b><br>',
                                    mon.fn_Small(mon.fn_Nw(CONCAT(ISNULL(h.recovery_model, N'?'), N' &middot; compat ', ISNULL(CONVERT(nvarchar(5), s.compatibility_level), N'?'))))),
                             NULL),
                   mon.fn_Td(CASE WHEN h.is_monitored = 0 THEN mon.fn_Pill(N'NOT MONITORED', 'MUTE')
                                  WHEN h.is_present = 0 THEN mon.fn_Pill(N'DROPPED', 'WARN')
                                  WHEN h.state_desc = N'ONLINE' AND ISNULL(s.user_access_desc, N'MULTI_USER') = N'MULTI_USER'
                                       THEN CONCAT(N'ONLINE', CASE WHEN s.is_read_only = 1 THEN mon.fn_Small(N'<br>read-only') END)
                                  ELSE mon.fn_Pill(CONCAT(h.state_desc, CASE WHEN s.user_access_desc <> N'MULTI_USER' THEN CONCAT(N' ', s.user_access_desc) END), 'CRIT') END,
                             CASE WHEN h.is_monitored = 1 AND (h.is_present = 0 OR h.state_desc <> N'ONLINE') THEN 'CRIT'
                                  WHEN s.user_access_desc = N'SINGLE_USER' THEN 'WARN' END),
                   mon.fn_Td(CONCAT(mon.fn_Nw(CONCAT(ISNULL(CONVERT(nvarchar(20), CONVERT(decimal(19,1), h.data_size_mb / 1024.0)), N'-'), N' / ',
                                    ISNULL(CONVERT(nvarchar(20), CONVERT(decimal(19,1), h.log_size_mb / 1024.0)), N'-'), N' GB')),
                                    CASE WHEN s.data_used_mb IS NOT NULL AND h.data_size_mb > 0
                                         THEN mon.fn_Small(CONCAT(N'<br>data ', CONVERT(int, s.data_used_mb * 100.0 / h.data_size_mb), N'% used')) END),
                             NULL),
                   mon.fn_Td(CONCAT(ISNULL(CONCAT(CONVERT(decimal(9,1), h.log_used_pct), N'%'), N'-'),
                                    CASE WHEN h.log_reuse_wait_desc NOT IN (N'NOTHING', N'LOG_BACKUP', N'CHECKPOINT')
                                         THEN mon.fn_Small(CONCAT(N'<br>', h.log_reuse_wait_desc)) END),
                             CASE WHEN h.log_used_pct >= @log_crit THEN 'CRIT' WHEN h.log_used_pct >= @log_warn THEN 'WARN' END),
                   mon.fn_Td(mon.fn_BackupCell(h.full_status, h.full_finish_utc, h.full_age_min, h.full_source, @tz), mon.fn_BackupLevel(h.full_status)),
                   mon.fn_Td(mon.fn_BackupCell(h.diff_status, h.effective_data_utc, h.diff_age_min,
                                               CASE WHEN h.effective_data_utc = h.diff_finish_utc THEN h.diff_source ELSE CONCAT(h.full_source, '/full') END, @tz),
                             mon.fn_BackupLevel(h.diff_status)),
                   mon.fn_Td(mon.fn_BackupCell(h.log_status, h.log_finish_utc, h.log_age_min, h.log_source, @tz), mon.fn_BackupLevel(h.log_status)),
                   mon.fn_Td(CONCAT(CONVERT(nvarchar(max), N''),
                                  CASE WHEN ISNULL(h.checkdb_last_error, 0) <> 0
                                       THEN CONCAT(mon.fn_Pill(CONCAT(N'LAST RUN FAILED ', h.checkdb_last_error), 'CRIT'), N'<br>') END,
                                  CASE h.checkdb_status
                                  WHEN 'OK'      THEN mon.fn_Nw(CASE WHEN h.checkdb_age_hours < 48 THEN CONCAT(h.checkdb_age_hours, N'h ago')
                                                                     ELSE CONCAT(h.checkdb_age_hours / 24, N'd ago') END)
                                  WHEN 'OVERDUE' THEN CONCAT(mon.fn_Pill(N'OVERDUE', 'WARN'), N'<br>', h.checkdb_age_hours / 24, N'd ago')
                                  WHEN 'NEVER'   THEN mon.fn_Pill(N'NEVER', 'WARN')
                                  WHEN 'PENDING' THEN mon.fn_Pill(N'PENDING', 'INFO')
                                  WHEN 'UNKNOWN' THEN mon.fn_Small(N'no source')
                                  ELSE mon.fn_Small(N'-') END,
                                  CASE WHEN h.last_checkdb_utc IS NOT NULL AND h.is_monitored = 1
                                       THEN mon.fn_Small((CONCAT(N'<br>', mon.fn_FmtLocal(h.last_checkdb_utc, @tz), N' &middot; ',
                                                 LOWER(ISNULL(h.checkdb_source, N'?')),
                                                 CASE WHEN h.checkdb_last_duration_s IS NOT NULL THEN CONCAT(N' &middot; ', mon.fn_Duration(h.checkdb_last_duration_s)) END))) END),
                             CASE WHEN ISNULL(h.checkdb_last_error, 0) <> 0 THEN 'CRIT'
                                  WHEN h.checkdb_status IN ('OVERDUE', 'NEVER') THEN 'WARN' END),
                   mon.fn_Td(ISNULL(CONVERT(nvarchar(10), h.vlf_total), N'-'), CASE WHEN h.vlf_total >= @vlf THEN 'WARN' END),
                   mon.fn_Td(CONCAT(CONVERT(nvarchar(max), N''),
                                    CASE WHEN s.is_auto_close_on = 1  THEN CONCAT(mon.fn_Pill(N'AUTO_CLOSE', 'WARN'), N' ') END,
                                    CASE WHEN s.is_auto_shrink_on = 1 THEN CONCAT(mon.fn_Pill(N'AUTO_SHRINK', 'WARN'), N' ') END,
                                    CASE WHEN s.page_verify <> N'CHECKSUM' THEN CONCAT(mon.fn_Pill(CONCAT(N'VERIFY ', s.page_verify), 'WARN'), N' ') END,
                                    CASE WHEN s.qs_desired_state = N'READ_WRITE' AND s.qs_actual_state = N'READ_ONLY' THEN CONCAT(mon.fn_Pill(N'QS READ_ONLY', 'WARN'), N' ') END,
                                    CASE WHEN s.pct_growth_files > 0 THEN CONCAT(mon.fn_Pill(N'% GROWTH', 'NA'), N' ') END,
                                    CASE WHEN dr.n > 0 THEN CONCAT(mon.fn_Pill(CONCAT(dr.n, N' DRIFT'), 'WARN'), N' ') END,
                                    CASE WHEN s.collection_error IS NOT NULL THEN mon.fn_Small(N'no access') END),
                             CASE WHEN s.is_auto_close_on = 1 OR s.is_auto_shrink_on = 1 OR s.page_verify <> N'CHECKSUM' OR dr.n > 0
                                       OR (s.qs_desired_state = N'READ_WRITE' AND s.qs_actual_state = N'READ_ONLY') THEN 'WARN' END),
                   N'</tr>')
            FROM mon.vw_BackupHealth AS h
            LEFT JOIN mon.DatabaseStatus AS s ON s.database_name = h.database_name
            OUTER APPLY (SELECT COUNT(*) AS n FROM mon.Issue AS x
                         WHERE x.is_active = 1 AND x.category = 'CONFIG' AND x.issue_key LIKE N'DRIFT:' + h.database_name + N':%') AS dr
            ORDER BY CASE WHEN COALESCE(mon.fn_BackupLevel(h.full_status), mon.fn_BackupLevel(h.diff_status),
                                        mon.fn_BackupLevel(h.log_status)) = 'CRIT' OR (h.is_monitored = 1 AND h.state_desc <> N'ONLINE') THEN 0
                          WHEN h.log_used_pct >= @log_warn OR h.checkdb_status IN ('OVERDUE', 'NEVER') THEN 1
                          WHEN h.is_monitored = 0 THEN 3 ELSE 2 END,
                     h.database_name
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(N'Databases & backups - all user databases',
            N'Red = missing/overdue backup, broken log chain or database not online. Amber = needs attention. Sorted problems first. '
            + N'Age is measured to now; time shown is the backup finish (' + @tzl + N'). Source: msdb / rds task / rds log / dmv (sys.dm_db_log_stats).'
            + CASE WHEN @n > 250 THEN CONCAT(N' Showing 250 of ', @n, N' (OPS.mon.vw_BackupHealth).') ELSE N'' END,
            N'Database|State|Data / Log|Log used|Full|Diff (effective)|Log|CHECKDB|VLFs|Config',
            ISNULL(@rows, mon.fn_EmptyRow(10, N'No user databases found.')));

        /* ---------------- 3b. Backup files, storage & retention (fresh snapshot) ---------------- */
        IF @PreviewOnly = 0 EXEC mon.usp_SnapshotBackupInventory @Force = 1;      /* fresh numbers for the report */
        DECLARE @snap date = (SELECT MAX(snapshot_date) FROM mon.BackupInventoryDaily);
        DECLARE @ret_ok int, @ret_ok_bytes bigint;
        SELECT @n = SUM(CASE WHEN status IN ('NONE', 'SHORT', 'GAPS', 'POLICY') THEN 1 ELSE 0 END),
               @ret_ok = SUM(CASE WHEN status = 'OK' THEN 1 ELSE 0 END),
               @ret_ok_bytes = SUM(CASE WHEN status = 'OK' THEN total_bytes END)
        FROM mon.BackupInventoryDaily WHERE snapshot_date = @snap;

        /* Summary per backup type: files made / still on storage / declared policy / retention range. */
        SET @rows =
        (
            SELECT CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_Pill(x.backup_type, 'INFO'), NULL),
                   mon.fn_Td(CONVERT(nvarchar(10), x.dbs), NULL),
                   mon.fn_Td(CONCAT(N'<b>', FORMAT(x.files_24h, N'N0'), N'</b>'), CASE WHEN x.files_24h = 0 AND x.backup_type = 'LOG' THEN 'CRIT' END),
                   mon.fn_Td(FORMAT(x.files_total, N'N0'), NULL),
                   mon.fn_Td(CASE WHEN x.known_dbs = 0 THEN mon.fn_Small(N'unknown - declare policy')
                                  ELSE CONCAT(N'<b>', FORMAT(x.on_storage, N'N0'), N'</b>',
                                              mon.fn_Small(CONCAT(N'<br>', x.basis,
                                                   CASE WHEN x.known_dbs < x.dbs THEN CONCAT(N', ', x.dbs - x.known_dbs, N' DB unknown') END))) END,
                             CASE WHEN x.known_dbs < x.dbs THEN 'WARN' END),
                   mon.fn_Td(mon.fn_Nw(CASE WHEN x.min_pol IS NULL THEN N'not declared'
                                            WHEN x.min_pol = x.max_pol THEN CONCAT(x.min_pol, N' d')
                                            ELSE CONCAT(x.min_pol, N'-', x.max_pol, N' d') END),
                             CASE WHEN x.min_pol IS NULL THEN 'WARN' END),
                   mon.fn_Td(mon.fn_Nw(CONCAT(ISNULL(CONVERT(nvarchar(20), CONVERT(decimal(9,0), x.min_ret)), N'-'), N' - ',
                                              ISNULL(CONVERT(nvarchar(20), CONVERT(decimal(9,0), x.max_ret)), N'-'), N' d',
                                              mon.fn_Small(CONCAT(N' / target ', x.min_tgt, CASE WHEN x.max_tgt <> x.min_tgt THEN CONCAT(N'-', x.max_tgt) END, N' d')))),
                             CASE WHEN x.problems > 0 THEN 'WARN' END),
                   mon.fn_Td(mon.fn_Nw(CASE WHEN x.total_bytes IS NULL THEN N'-' ELSE CONCAT(FORMAT(x.total_bytes / 1073741824.0, N'N1'), N' GB') END), NULL),
                   mon.fn_Td(CASE WHEN x.problems = 0 THEN mon.fn_Pill(N'OK', 'OK')
                                  ELSE mon.fn_Pill(CONCAT(x.problems, N' ISSUE', CASE WHEN x.problems > 1 THEN N'S' END), 'CRIT') END, NULL),
                   N'</tr>')
            FROM
            (
                SELECT r.backup_type, COUNT(*) AS dbs, SUM(ISNULL(r.files_24h, 0)) AS files_24h, SUM(ISNULL(r.files_total, 0)) AS files_total,
                       SUM(ISNULL(r.files_on_storage, 0)) AS on_storage,
                       SUM(CASE WHEN r.files_on_storage IS NOT NULL THEN 1 ELSE 0 END) AS known_dbs,
                       CASE WHEN MAX(CASE WHEN r.storage_basis = 'RDS list' THEN 1 ELSE 0 END) = 1
                             AND MAX(CASE WHEN r.storage_basis = 'estimated' THEN 1 ELSE 0 END) = 1 THEN N'RDS list + estimated'
                            WHEN MAX(CASE WHEN r.storage_basis = 'RDS list' THEN 1 ELSE 0 END) = 1 THEN N'listed by RDS'
                            ELSE N'estimated from policy' END AS basis,
                       MIN(r.storage_days) AS min_pol, MAX(r.storage_days) AS max_pol,
                       MIN(r.retention_days) AS min_ret, MAX(r.retention_days) AS max_ret,
                       MIN(r.target_days) AS min_tgt, MAX(r.target_days) AS max_tgt,
                       SUM(r.total_bytes) AS total_bytes,
                       SUM(CASE WHEN r.status IN ('NONE', 'SHORT', 'GAPS', 'POLICY') THEN 1 ELSE 0 END) AS problems
                FROM mon.BackupInventoryDaily AS r
                WHERE r.snapshot_date = @snap AND r.status NOT IN ('OFF', 'N/A')
                GROUP BY r.backup_type
            ) AS x
            ORDER BY CASE x.backup_type WHEN 'FULL' THEN 1 WHEN 'DIFF' THEN 2 ELSE 3 END
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(N'Backup files & storage',
            CONCAT(N'Files made = backup files written (striped backups count every file). On storage: LOG = files RDS still lists ',
                   N'(exact, rds_fn_list_tlog_backup_metadata); FULL/DIFF on S3 or disk = estimated from the DECLARED lifecycle ',
                   N'(setting backup_storage_retention_days or mon.DatabaseCheck.storage_retention_days), because S3 cannot be listed from T-SQL. ',
                   N'Retention = how far back backups are recorded vs target. Snapshot ', ISNULL(CONVERT(nvarchar(10), @snap, 120), N'-'), N'.'),
            N'Type|Databases|Files 24h|Files made (recorded)|Files on storage|Storage policy|Retention (min-max)|Total size|Status',
            ISNULL(@rows, mon.fn_EmptyRow(9, N'No backup inventory yet (snapshot is created by the hourly job).')));

        /* Full grid per database and type (problems first) - the layout approved in mockup 2. */
        SELECT @n = COUNT(*) FROM mon.BackupInventoryDaily WHERE snapshot_date = @snap AND status NOT IN ('OFF', 'N/A');
        SET @rows =
        (
            SELECT TOP (@cap * 3) CONCAT(N'<tr>',
                   mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(r.database_name), N'</b>'), NULL),
                   mon.fn_Td(mon.fn_Pill(r.backup_type, CASE r.backup_type WHEN 'FULL' THEN 'INFO' ELSE 'NA' END), NULL),
                   mon.fn_Td(CONCAT(N'<b>', FORMAT(r.backup_count, N'N0'), N'</b>',
                                    CASE WHEN r.gaps > 0 THEN mon.fn_Small(CONCAT(N'<br>', r.gaps, N' gap(s)')) END),
                             CASE WHEN r.status = 'NONE' THEN 'CRIT' WHEN r.status = 'GAPS' THEN 'WARN' END),
                   mon.fn_Td(CONCAT(FORMAT(ISNULL(r.files_total, 0), N'N0'),
                                    mon.fn_Small(CONCAT(N'<br>', FORMAT(ISNULL(r.files_24h, 0), N'N0'), N' in 24h'))), NULL),
                   mon.fn_Td(CASE WHEN r.files_on_storage IS NULL THEN mon.fn_Small(N'not declared')
                                  ELSE CONCAT(FORMAT(r.files_on_storage, N'N0'),
                                              mon.fn_Small(CONCAT(N'<br>', CASE r.storage_basis WHEN 'RDS list' THEN N'listed by RDS' ELSE N'est.' END,
                                                   CASE WHEN r.storage_days IS NOT NULL THEN CONCAT(N' &middot; ', r.storage_days, N' d policy') END))) END,
                             CASE WHEN r.status = 'POLICY' THEN 'CRIT' END),
                   mon.fn_Td(mon.fn_Nw(CASE WHEN r.oldest_utc IS NULL THEN N'-' ELSE mon.fn_FmtLocal(r.oldest_utc, @tz) END), NULL),
                   mon.fn_Td(mon.fn_Nw(CASE WHEN r.newest_utc IS NULL THEN N'-' ELSE mon.fn_FmtLocal(r.newest_utc, @tz) END), NULL),
                   mon.fn_Td(mon.fn_Nw(CONCAT(N'<b>', ISNULL(CONVERT(nvarchar(20), r.retention_days), N'-'), N' d</b>',
                                              mon.fn_Small(CONCAT(N' / ', r.target_days, N' d')))),
                             CASE WHEN r.status IN ('SHORT', 'NONE') THEN 'CRIT' END),
                   mon.fn_Td(mon.fn_Nw(CASE WHEN r.avg_interval_min IS NULL THEN N'-' ELSE mon.fn_Duration(CONVERT(bigint, r.avg_interval_min) * 60) END), NULL),
                   mon.fn_Td(mon.fn_Nw(CASE WHEN r.avg_bytes IS NULL THEN N'-' WHEN r.avg_bytes < 1073741824
                                            THEN CONCAT(FORMAT(r.avg_bytes / 1048576.0, N'N0'), N' MB')
                                            ELSE CONCAT(FORMAT(r.avg_bytes / 1073741824.0, N'N1'), N' GB') END), NULL),
                   mon.fn_Td(mon.fn_Nw(CASE WHEN r.total_bytes IS NULL THEN N'-' WHEN r.total_bytes >= 1099511627776
                                            THEN CONCAT(FORMAT(r.total_bytes / 1099511627776.0, N'N1'), N' TB')
                                            ELSE CONCAT(FORMAT(r.total_bytes / 1073741824.0, N'N1'), N' GB') END), NULL),
                   mon.fn_Td(mon.fn_Pill(CASE r.status WHEN 'SHORT' THEN N'< TARGET' WHEN 'POLICY' THEN N'POLICY < TARGET'
                                                       WHEN 'GAPS' THEN CONCAT(r.gaps, N' GAPS') ELSE r.status END,
                                         CASE r.status WHEN 'OK' THEN 'OK' WHEN 'GAPS' THEN 'WARN' ELSE 'CRIT' END), NULL),
                   N'</tr>')
            FROM mon.BackupInventoryDaily AS r
            WHERE r.snapshot_date = @snap AND r.status NOT IN ('OFF', 'N/A')
              AND (r.status <> 'OK' OR @n <= 24)      /* large servers: exceptions only (Gmail clips mail > ~102 KB) */
            ORDER BY CASE r.status WHEN 'NONE' THEN 0 WHEN 'SHORT' THEN 1 WHEN 'POLICY' THEN 2 WHEN 'GAPS' THEN 3 ELSE 4 END,
                     r.database_name, CASE r.backup_type WHEN 'FULL' THEN 1 WHEN 'DIFF' THEN 2 ELSE 3 END
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(N'Backup retention & inventory - how many backups exist and how far back they go',
            CONCAT(N'Per database and backup type, problems first. Red = history shorter than target, no backups, or storage policy shorter than target; ',
                   N'amber = gaps longer than 1.25 x SLA inside the target window. Target: mon.DatabaseCheck.retention_days (default ',
                   ISNULL(mon.fn_Setting('backup_retention_target_days'), N'7'), N' d). Sources: msdb, RDS native task status, ',
                   N'rds_fn_list_tlog_backup_metadata, Ola CommandLog. Full grid: EXEC OPS.mon.usp_ShowBackupRetention;',
                   CASE WHEN @n > 24 THEN CONCAT(N' More than 24 rows: only exceptions shown; ', ISNULL(@ret_ok, 0), N' rows are OK.') END),
            N'Database|Type|Backups|Files|On storage|Oldest|Newest|Retention|Interval|Avg size|Total size|Status',
            ISNULL(@rows, mon.fn_EmptyRow(12, N'No backup inventory yet (snapshot is created by the hourly job).')));

        /* ---------------- 4. Blocking episodes ---------------- */
        SET @rows =
        (
            SELECT TOP (@cap) CONCAT(N'<tr>',
                   mon.fn_Td(CONCAT(mon.fn_FmtLocal(e.blocked_since_utc, @tz),
                                    CASE WHEN e.is_open = 1 THEN CONCAT(N'<br>', mon.fn_Pill(N'ONGOING', 'CRIT')) END), NULL),
                   mon.fn_Td(CONCAT(N'<b>', mon.fn_Duration(DATEDIFF(SECOND, e.blocked_since_utc, e.last_seen_utc)), N'</b>'),
                             CASE WHEN DATEDIFF(SECOND, e.blocked_since_utc, e.last_seen_utc) >= @blk_min * 60 THEN 'CRIT'
                                  WHEN DATEDIFF(SECOND, e.blocked_since_utc, e.last_seen_utc) >= 300 THEN 'WARN' END),
                   mon.fn_Td(CONCAT(N'spid ', e.head_session_id, N' &middot; ', mon.fn_HtmlEncode(ISNULL(e.head_login, N'?')), N'<br>',
                                    mon.fn_Small(mon.fn_HtmlEncode(CONCAT(ISNULL(e.head_host, N'?'), N' / ', LEFT(ISNULL(e.head_program, N'?'), 60))))), NULL),
                   mon.fn_Td(CASE WHEN e.head_status = N'sleeping' AND ISNULL(e.head_open_tran_count, 0) > 0
                                  THEN mon.fn_Pill(N'IDLE IN TRAN', 'WARN')
                                  ELSE mon.fn_HtmlEncode(ISNULL(e.head_status, N'?')) END, NULL),
                   mon.fn_Td(CONVERT(nvarchar(10), e.max_blocked_count), NULL),
                   mon.fn_Td(CONCAT(mon.fn_HtmlEncode(ISNULL(e.top_wait_type, N'?')), N'<br>',
                                    mon.fn_Small(mon.fn_OneLine(e.top_wait_resource, 80))), NULL),
                   mon.fn_Td(CONCAT(mon.fn_Small(CONCAT(N'<b>head:</b> ', mon.fn_OneLine(COALESCE(e.head_input_buffer, e.head_sql), 300))),
                                    N'<br>', mon.fn_Small(CONCAT(N'<b>blocked:</b> ', mon.fn_OneLine(e.blocked_sql_sample, 200)))), NULL),
                   N'</tr>')
            FROM mon.BlockingEpisode AS e
            WHERE e.last_seen_utc >= @window_start
              AND DATEDIFF(SECOND, e.blocked_since_utc, e.last_seen_utc) >= 60
            ORDER BY DATEDIFF(SECOND, e.blocked_since_utc, e.last_seen_utc) DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(CONCAT(N'Blocking episodes - last ', @lookback, N'h'),
            CONCAT(N'Episodes of 1 minute or longer (sampled every 30 s). Red = reached the ', @blk_min,
                   N'-minute alert threshold. Chain details: OPS.mon.BlockingSample.'),
            N'Started|Duration|Head blocker|Head state|Blocked|Wait|SQL',
            ISNULL(@rows, mon.fn_EmptyRow(7, N'No blocking of 1 minute or longer.')));

        /* ---------------- 5. SQL Agent ---------------- */
        SET @rows =
        (
            SELECT TOP (@cap) CONCAT(N'<tr>',
                   mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(f.job_name), N'</b>'), 'CRIT'),
                   mon.fn_Td(mon.fn_Pill(CASE f.run_status WHEN 3 THEN N'CANCELLED' ELSE N'FAILED' END, 'CRIT'), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(CONCAT(ISNULL(CONVERT(nvarchar(5), f.failed_step_id), N'?'), N'. ', ISNULL(f.failed_step_name, N'(job outcome)'))), NULL),
                   mon.fn_Td(mon.fn_Nw(mon.fn_FmtLocal(f.run_start_utc, @tz)), NULL),
                   mon.fn_Td(mon.fn_Duration(f.duration_s), NULL),
                   mon.fn_Td(mon.fn_Small(mon.fn_OneLine(f.message, 500)), NULL),
                   N'</tr>')
            FROM mon.AgentFailure AS f
            WHERE f.run_start_utc >= @window_start
            ORDER BY f.run_start_utc DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(CONCAT(N'SQL Agent failures - last ', @lookback, N'h'), N'All jobs, with the step that actually failed.',
            N'Job|Outcome|Failed step|Started|Duration|Message',
            ISNULL(@rows, mon.fn_EmptyRow(6, N'No failed or cancelled jobs.')));

        SET @rows =
        (
            SELECT TOP (@cap) CONCAT(N'<tr>',
                   mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(j.job_name), N'</b>'), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(j.job_type), NULL),
                   mon.fn_Td(mon.fn_Pill(REPLACE(j.health_status, '_', ' '),
                                         CASE WHEN j.health_status = 'OK' THEN 'OK'
                                              WHEN j.health_status IN ('DISABLED', 'NOT_FOUND', 'NOT_MONITORED') THEN 'WARN' ELSE 'CRIT' END),
                             CASE WHEN j.health_status IN ('FAILED', 'OVERDUE', 'NEVER_SUCCEEDED') THEN 'CRIT'
                                  WHEN j.health_status IN ('DISABLED', 'NOT_FOUND') THEN 'WARN' END),
                   mon.fn_Td(CONCAT(CONVERT(decimal(9,1), j.max_hours_since_success), N'h'), NULL),
                   mon.fn_Td(CONCAT(mon.fn_FmtLocal(j.last_run_utc, @tz), N'<br>',
                                    mon.fn_Small(CASE j.last_run_status WHEN 1 THEN N'succeeded' WHEN 0 THEN N'failed'
                                                      WHEN 3 THEN N'cancelled' WHEN 2 THEN N'retry' ELSE N'-' END)), NULL),
                   mon.fn_Td(mon.fn_FmtLocal(j.last_success_utc, @tz), NULL),
                   mon.fn_Td(CONCAT(mon.fn_Duration(j.last_duration_s),
                                    mon.fn_Small(CONCAT(N'<br>median ', mon.fn_Duration(CONVERT(bigint, j.median_s))))),
                             CASE WHEN j.last_duration_s >= @jd_min * 60 AND j.last_duration_s > j.median_s * @jd_factor THEN 'WARN' END),
                   N'</tr>')
            FROM mon.vw_JobHealth AS j
            WHERE j.is_monitored = 1
            ORDER BY CASE WHEN j.health_status = 'OK' THEN 1 ELSE 0 END, j.job_name
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(N'Maintenance jobs (Ola Hallengren / RDS native backup)',
            CONCAT(N'SLA = maximum hours since last success. Amber duration = last run took more than ', CONVERT(decimal(9,1), @jd_factor),
                   N'x its 30-day median. Add custom jobs to OPS.mon.JobPolicy.'),
            N'Job|Type|Health|SLA|Last run|Last success|Duration',
            ISNULL(@rows, mon.fn_EmptyRow(7, N'No maintenance jobs discovered.')));

        /* ---------------- 5b. Ola Hallengren CommandLog ---------------- */
        IF EXISTS (SELECT 1 FROM mon.OlaSource WHERE is_active = 1) OR EXISTS (SELECT 1 FROM mon.OlaCommand)
        BEGIN
            SET @rows =
            (
                SELECT CONCAT(N'<tr>',
                       mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(x.command_type), N'</b>'), NULL),
                       mon.fn_Td(FORMAT(x.cmds, N'N0'), NULL),
                       mon.fn_Td(CASE WHEN x.failed > 0 THEN CONCAT(N'<b>', x.failed, N'</b>') ELSE N'0' END, CASE WHEN x.failed > 0 THEN 'CRIT' END),
                       mon.fn_Td(CASE WHEN x.running > 0 THEN CONCAT(x.running, N' running') ELSE N'-' END, NULL),
                       mon.fn_Td(CONVERT(nvarchar(10), x.dbs), NULL),
                       mon.fn_Td(mon.fn_Nw(mon.fn_Duration(x.total_s)), NULL),
                       mon.fn_Td(CONCAT(mon.fn_Nw(mon.fn_Duration(x.max_s)),
                                        mon.fn_Small(CONCAT(N'<br>', mon.fn_OneLine(x.longest_obj, 60)))), NULL),
                       mon.fn_Td(CASE WHEN x.files > 0 THEN FORMAT(x.files, N'N0') ELSE N'-' END, NULL),
                       mon.fn_Td(mon.fn_Nw(mon.fn_FmtLocal(x.last_start, @tz)), NULL),
                       N'</tr>')
                FROM
                (
                    SELECT o.command_type, COUNT(*) AS cmds,
                           SUM(CASE WHEN ISNULL(o.error_number, 0) <> 0 THEN 1 ELSE 0 END) AS failed,
                           SUM(CASE WHEN o.end_utc IS NULL THEN 1 ELSE 0 END) AS running,
                           COUNT(DISTINCT o.database_name) AS dbs,
                           SUM(CONVERT(bigint, o.duration_s)) AS total_s, MAX(o.duration_s) AS max_s,
                           SUM(ISNULL(o.file_count, 0)) AS files, MAX(o.start_utc) AS last_start,
                           (SELECT TOP (1) CONCAT(o2.database_name, CASE WHEN o2.object_name IS NOT NULL THEN CONCAT(N'.', o2.object_name) END,
                                                  CASE WHEN o2.index_name IS NOT NULL THEN CONCAT(N' / ', o2.index_name) END)
                            FROM mon.OlaCommand AS o2
                            WHERE o2.command_type = o.command_type AND o2.start_utc >= @window_start
                            ORDER BY o2.duration_s DESC) AS longest_obj
                    FROM mon.OlaCommand AS o
                    WHERE o.start_utc >= @window_start
                    GROUP BY o.command_type
                ) AS x
                ORDER BY x.failed DESC, x.total_s DESC
                FOR XML PATH(''), TYPE
            ).value('(./text())[1]', 'nvarchar(max)');
            SET @body += mon.fn_Section(CONCAT(N'Ola Hallengren maintenance (CommandLog) - last ', @lookback, N'h'),
                CONCAT(N'Every command logged by DatabaseBackup / DatabaseIntegrityCheck / IndexOptimize in ',
                       ISNULL((SELECT TOP (1) CONCAT(database_name, N'.dbo.CommandLog') FROM mon.OlaSource WHERE is_active = 1 ORDER BY last_read_utc DESC), N'(not found)'),
                       N'. Details: EXEC OPS.mon.usp_ShowOlaLog;'),
                N'Command type|Commands|Failed|Unfinished|DBs|Total time|Longest|Backup files|Last start',
                ISNULL(@rows, mon.fn_EmptyRow(9, N'No Ola commands in the window.')));

            SET @rows =
            (
                SELECT TOP (@cap) CONCAT(N'<tr>',
                       mon.fn_Td(mon.fn_Nw(mon.fn_FmtLocal(o.start_utc, @tz)), 'CRIT'),
                       mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(ISNULL(o.database_name, N'?')), N'</b>',
                                        mon.fn_Small(CONCAT(N'<br>', mon.fn_HtmlEncode(CONCAT(o.object_name, CASE WHEN o.index_name IS NOT NULL THEN CONCAT(N' / ', o.index_name) END))))), NULL),
                       mon.fn_Td(mon.fn_HtmlEncode(o.command_type), NULL),
                       mon.fn_Td(CONVERT(nvarchar(10), o.error_number), NULL),
                       mon.fn_Td(mon.fn_Small(mon.fn_OneLine(o.error_message, 400)), NULL),
                       N'</tr>')
                FROM mon.OlaCommand AS o
                WHERE o.start_utc >= @window_start AND ISNULL(o.error_number, 0) <> 0
                ORDER BY o.start_utc DESC
                FOR XML PATH(''), TYPE
            ).value('(./text())[1]', 'nvarchar(max)');
            IF @rows IS NOT NULL
                SET @body += mon.fn_Section(N'Ola Hallengren - failed commands', NULL,
                                            N'Start|Database / object|Command type|Error|Message', @rows);
        END;

        /* ---------------- 6. Deadlocks ---------------- */
        SELECT @n = COUNT(*) FROM mon.Deadlock WHERE event_utc >= @window_start;
        SET @rows =
        (
            SELECT TOP (@cap) CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_Nw(mon.fn_FmtLocal(d.event_utc, @tz)), 'WARN'),
                   mon.fn_Td(mon.fn_HtmlEncode(ISNULL(d.database_name, N'?')), NULL),
                   mon.fn_Td(CONCAT(mon.fn_HtmlEncode(ISNULL(d.victim_login, N'?')), N'<br>',
                                    mon.fn_Small(mon.fn_HtmlEncode(CONCAT(ISNULL(d.victim_host, N'?'), N' / ', LEFT(ISNULL(d.victim_app, N'?'), 50))))), NULL),
                   mon.fn_Td(mon.fn_Small(mon.fn_OneLine(d.objects, 200)), NULL),
                   mon.fn_Td(CONCAT(mon.fn_Small(CONCAT(N'<b>victim:</b> ', mon.fn_OneLine(d.victim_sql, 250))), N'<br>',
                                    mon.fn_Small(CONCAT(N'<b>survivor:</b> ', mon.fn_OneLine(d.survivor_sql, 250)))), NULL),
                   N'</tr>')
            FROM mon.Deadlock AS d
            WHERE d.event_utc >= @window_start
            ORDER BY d.event_utc DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(CONCAT(N'Deadlocks - last ', @lookback, N'h'),
            CONCAT(N'From the system_health session. Full graphs (save as .xdl): SELECT deadlock_xml FROM OPS.mon.Deadlock.',
                   CASE WHEN @n > @cap THEN CONCAT(N' Showing ', @cap, N' of ', @n, N'.') END),
            N'Time|Database|Victim|Objects|Statements',
            ISNULL(@rows, mon.fn_EmptyRow(5, N'No deadlocks.')));

        /* ---------------- 7. Error log + failed logins ---------------- */
        SET @rows =
        (
            SELECT TOP (@cap) CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_Nw(mon.fn_FmtLocal(e.log_utc, @tz)), mon.fn_SevLevel(e.severity)),
                   mon.fn_Td(mon.fn_Pill(e.severity, mon.fn_SevLevel(e.severity)), NULL),
                   mon.fn_Td(ISNULL(CONVERT(nvarchar(10), e.error_number), N'-'), NULL),
                   mon.fn_Td(mon.fn_Small(mon.fn_OneLine(e.message, 500)), NULL),
                   N'</tr>')
            FROM mon.ErrorLogEvent AS e
            WHERE e.log_utc >= @window_start
            ORDER BY e.log_utc DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(CONCAT(N'SQL Server error log - last ', @lookback, N'h'),
            N'High-signal entries only: corruption (823/824/825), I/O stalls (833), log/file full (9002/1105), memory (701), '
            + N'schedulers (17883/17884), assertions/dumps, backup failures and severity 20+.',
            N'Time|Severity|Error|Message',
            ISNULL(@rows, mon.fn_EmptyRow(4, N'No high-signal error-log entries.')));

        SET @rows =
        (
            SELECT TOP (10) CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_HtmlEncode(x.login_name), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(x.client_address), NULL),
                   mon.fn_Td(mon.fn_Small(mon.fn_OneLine(x.reason, 160)), NULL),
                   mon.fn_Td(CONCAT(N'<b>', x.n, N'</b>'), CASE WHEN x.n >= 100 THEN 'WARN' END),
                   mon.fn_Td(mon.fn_FmtLocal(x.last_hour, @tz), NULL),
                   N'</tr>')
            FROM (SELECT l.login_name, l.client_address, MAX(l.reason) AS reason, SUM(l.failures) AS n, MAX(l.hour_utc) AS last_hour
                  FROM mon.LoginFailure AS l WHERE l.hour_utc >= @window_start
                  GROUP BY l.login_name, l.client_address) AS x
            ORDER BY x.n DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(CONCAT(N'Failed logins - last ', @lookback, N'h (top 10)'), NULL,
            N'Login|Client|Reason|Failures|Last hour',
            ISNULL(@rows, mon.fn_EmptyRow(5, N'No failed logins.')));

        /* ---------------- 8. Performance ---------------- */
        DECLARE @batch_rate bigint =
        (
            SELECT CASE WHEN MAX(p.batch_requests_total) >= MIN(p.batch_requests_total)
                             AND DATEDIFF(SECOND, MIN(p.sample_utc), MAX(p.sample_utc)) > 0
                        THEN (MAX(p.batch_requests_total) - MIN(p.batch_requests_total))
                             / DATEDIFF(SECOND, MIN(p.sample_utc), MAX(p.sample_utc)) END
            FROM mon.PerfSample AS p
            WHERE p.sample_utc >= @window_start
              AND p.sqlserver_start_utc = (SELECT TOP (1) sqlserver_start_utc FROM mon.PerfSample ORDER BY sample_utc DESC)
        );
        SET @body += CONCAT(N'<tr><td style="padding:22px 24px 0 24px"><div style="font-size:15px;font-weight:700;color:#0F172A">',
                            N'Performance - last ', @lookback, N'h</div></td></tr>');
        SET @body += mon.fn_KpiRow(CONCAT(CONVERT(nvarchar(max), N''),
            mon.fn_Kpi(ISNULL(CONVERT(nvarchar(20), @ple), N'-'), N'Page life exp. (s)', N'now', CASE WHEN @ple < 300 THEN 'WARN' END),
            mon.fn_Kpi(ISNULL(CONVERT(nvarchar(10), @grants_max), N'-'), N'Grants pending', N'max 24h', CASE WHEN @grants_max > 0 THEN 'WARN' END),
            mon.fn_Kpi(ISNULL(CONVERT(nvarchar(20), @tdb_max), N'-'), N'tempdb used GB', N'max 24h', NULL),
            mon.fn_Kpi(ISNULL(CONVERT(nvarchar(20), @vs_max), N'-'), N'Version store GB', N'max 24h', NULL),
            mon.fn_Kpi(ISNULL(CONVERT(nvarchar(20), @batch_rate), N'-'), N'Batch req/s', N'avg 24h', NULL)));

        /* Top waits over the window (cumulative snapshot delta, restart-safe). */
        DECLARE @w1 datetime2(0) = (SELECT MAX(snapshot_utc) FROM mon.WaitStatsSnapshot);
        DECLARE @w0 datetime2(0) = (SELECT MIN(snapshot_utc) FROM mon.WaitStatsSnapshot
                                    WHERE snapshot_utc >= DATEADD(MINUTE, -30, @window_start) AND snapshot_utc < @w1);
        IF EXISTS (SELECT 1 FROM mon.PerfSample WHERE sample_utc >= @w0 AND sqlserver_start_utc > @w0) SET @w0 = NULL;

        ;WITH W AS
        (
            SELECT b.wait_type,
                   CASE WHEN b.wait_ms >= ISNULL(a.wait_ms, 0) THEN b.wait_ms - ISNULL(a.wait_ms, 0) ELSE b.wait_ms END AS wait_ms,
                   CASE WHEN b.signal_ms >= ISNULL(a.signal_ms, 0) THEN b.signal_ms - ISNULL(a.signal_ms, 0) ELSE b.signal_ms END AS signal_ms,
                   CASE WHEN b.waiting_tasks >= ISNULL(a.waiting_tasks, 0) THEN b.waiting_tasks - ISNULL(a.waiting_tasks, 0) ELSE b.waiting_tasks END AS tasks
            FROM mon.WaitStatsSnapshot AS b
            LEFT JOIN mon.WaitStatsSnapshot AS a ON a.snapshot_utc = @w0 AND a.wait_type = b.wait_type
            WHERE b.snapshot_utc = @w1
        ), T AS
        (
            SELECT W.*, SUM(W.wait_ms) OVER () AS total_ms FROM W WHERE W.wait_ms > 0
        )
        SELECT @rows =
        (
            SELECT TOP (10) CONCAT(N'<tr>',
                   mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(T.wait_type), N'</b>'), NULL),
                   mon.fn_Td(mon.fn_Duration(T.wait_ms / 1000), NULL),
                   mon.fn_Td(CONCAT(CONVERT(decimal(5,1), T.wait_ms * 100.0 / NULLIF(T.total_ms, 0)), N'%'), NULL),
                   mon.fn_Td(CONVERT(nvarchar(20), CONVERT(decimal(19,1), T.wait_ms * 1.0 / NULLIF(T.tasks, 0))),
                             CASE WHEN T.wait_type LIKE N'PAGEIOLATCH%' AND T.wait_ms * 1.0 / NULLIF(T.tasks, 0) > 20 THEN 'WARN'
                                  WHEN T.wait_type = N'WRITELOG' AND T.wait_ms * 1.0 / NULLIF(T.tasks, 0) > 5 THEN 'WARN' END),
                   mon.fn_Td(CONCAT(CONVERT(decimal(5,1), T.signal_ms * 100.0 / NULLIF(T.wait_ms, 0)), N'%'),
                             CASE WHEN T.signal_ms * 100.0 / NULLIF(T.wait_ms, 0) > 25 AND T.wait_ms * 100.0 / NULLIF(T.total_ms, 0) > 5 THEN 'WARN' END),
                   mon.fn_Td(mon.fn_Small(mon.fn_HtmlEncode(mon.fn_WaitHint(T.wait_type))), NULL),
                   N'</tr>')
            FROM T
            ORDER BY T.wait_ms DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(N'Top waits',
            CONCAT(CASE WHEN @w0 IS NULL THEN N'Since SQL Server start (restart inside the window)'
                        ELSE CONCAT(N'From ', mon.fn_FmtLocal(@w0, @tz), N' to ', mon.fn_FmtLocal(@w1, @tz)) END,
                   N'. Benign waits filtered (OPS.mon.WaitTypeIgnore). Signal % &gt; 25 on a top wait suggests CPU pressure.'),
            N'Wait type|Wait time|% of total|Avg ms/wait|Signal %|What it usually means',
            ISNULL(@rows, mon.fn_EmptyRow(6, N'No wait statistics collected yet (hourly snapshots).')));

        /* I/O latency per file over the window. */
        DECLARE @f1 datetime2(0) = (SELECT MAX(snapshot_utc) FROM mon.FileStatsSnapshot);
        DECLARE @f0 datetime2(0) = (SELECT MIN(snapshot_utc) FROM mon.FileStatsSnapshot
                                    WHERE snapshot_utc >= DATEADD(MINUTE, -30, @window_start) AND snapshot_utc < @f1);
        IF EXISTS (SELECT 1 FROM mon.PerfSample WHERE sample_utc >= @f0 AND sqlserver_start_utc > @f0) SET @f0 = NULL;

        ;WITH F AS
        (
            SELECT b.database_name, b.logical_name, b.type_desc,
                   b.num_reads  - CASE WHEN b.num_reads  >= ISNULL(a.num_reads, 0)  THEN ISNULL(a.num_reads, 0)  ELSE 0 END AS rd,
                   b.num_writes - CASE WHEN b.num_writes >= ISNULL(a.num_writes, 0) THEN ISNULL(a.num_writes, 0) ELSE 0 END AS wr,
                   b.io_stall_read_ms  - CASE WHEN b.io_stall_read_ms  >= ISNULL(a.io_stall_read_ms, 0)  THEN ISNULL(a.io_stall_read_ms, 0)  ELSE 0 END AS rd_ms,
                   b.io_stall_write_ms - CASE WHEN b.io_stall_write_ms >= ISNULL(a.io_stall_write_ms, 0) THEN ISNULL(a.io_stall_write_ms, 0) ELSE 0 END AS wr_ms,
                   b.bytes_read    - CASE WHEN b.bytes_read    >= ISNULL(a.bytes_read, 0)    THEN ISNULL(a.bytes_read, 0)    ELSE 0 END AS rd_b,
                   b.bytes_written - CASE WHEN b.bytes_written >= ISNULL(a.bytes_written, 0) THEN ISNULL(a.bytes_written, 0) ELSE 0 END AS wr_b
            FROM mon.FileStatsSnapshot AS b
            LEFT JOIN mon.FileStatsSnapshot AS a ON a.snapshot_utc = @f0 AND a.database_id = b.database_id AND a.file_id = b.file_id
            WHERE b.snapshot_utc = @f1
        )
        SELECT @rows =
        (
            SELECT TOP (8) CONCAT(N'<tr>',
                   mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(ISNULL(F.database_name, N'?')), N'</b>'), NULL),
                   mon.fn_Td(CONCAT(mon.fn_HtmlEncode(ISNULL(F.logical_name, N'?')), mon.fn_Small(CONCAT(N'<br>', F.type_desc))), NULL),
                   mon.fn_Td(CONCAT(FORMAT(F.rd, N'N0'), mon.fn_Small(CONCAT(N'<br>', CONVERT(decimal(19,1), F.rd_b / 1073741824.0), N' GB'))), NULL),
                   mon.fn_Td(ISNULL(CONVERT(nvarchar(20), CONVERT(decimal(9,1), F.rd_ms * 1.0 / NULLIF(F.rd, 0))), N'-'),
                             CASE WHEN F.rd_ms * 1.0 / NULLIF(F.rd, 0) >= @io_ms THEN 'WARN' END),
                   mon.fn_Td(CONCAT(FORMAT(F.wr, N'N0'), mon.fn_Small(CONCAT(N'<br>', CONVERT(decimal(19,1), F.wr_b / 1073741824.0), N' GB'))), NULL),
                   mon.fn_Td(ISNULL(CONVERT(nvarchar(20), CONVERT(decimal(9,1), F.wr_ms * 1.0 / NULLIF(F.wr, 0))), N'-'),
                             CASE WHEN F.wr_ms * 1.0 / NULLIF(F.wr, 0) >= @io_ms THEN 'WARN' END),
                   N'</tr>')
            FROM F
            WHERE F.rd + F.wr > 0
            ORDER BY (F.rd_ms + F.wr_ms) DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(N'I/O by file (top 8 by total stall)',
            CONCAT(N'Average latency over the window. Amber &ge; ', @io_ms, N' ms. CloudWatch Read/WriteLatency and EBS burst balance are authoritative on RDS.'),
            N'Database|File|Reads|Avg read ms|Writes|Avg write ms',
            ISNULL(@rows, mon.fn_EmptyRow(6, N'No file statistics collected yet (hourly snapshots).')));

        /* ---------------- 9. Storage ---------------- */
        ;WITH S AS
        (
            SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.volume_mount_point ORDER BY s.sample_utc DESC) AS rn
            FROM mon.StorageSample AS s WHERE s.sample_utc >= DATEADD(HOUR, -2, @now)
        )
        SELECT @rows =
        (
            SELECT CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_HtmlEncode(S.volume_mount_point), NULL),
                   mon.fn_Td(CONVERT(nvarchar(20), CONVERT(decimal(19,1), S.total_bytes / 1073741824.0)), NULL),
                   mon.fn_Td(CONVERT(nvarchar(20), CONVERT(decimal(19,1), S.available_bytes / 1073741824.0)), NULL),
                   mon.fn_Td(CONCAT(CONVERT(decimal(9,1), S.available_bytes * 100.0 / NULLIF(S.total_bytes, 0)), N'%'),
                             CASE WHEN S.available_bytes * 100.0 / NULLIF(S.total_bytes, 0) <= @st_crit THEN 'CRIT'
                                  WHEN S.available_bytes * 100.0 / NULLIF(S.total_bytes, 0) < @st_warn THEN 'WARN' END),
                   N'</tr>')
            FROM S WHERE S.rn = 1
            ORDER BY S.volume_mount_point
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(N'Storage (SQL-visible volumes)', NULL, N'Volume|Total GB|Free GB|Free %',
            ISNULL(@rows, mon.fn_EmptyRow(4, N'No storage samples.')));

        /* ---------------- 9b. Monitoring coverage (switched-off checks) + DBA change log ---------------- */
        SET @rows =
        (
            SELECT CONCAT(N'<tr>',
                   mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(x.item), N'</b>'), NULL),
                   mon.fn_Td(x.pills, CASE WHEN x.item_off = 1 THEN 'WARN' END),
                   mon.fn_Td(mon.fn_Small(mon.fn_HtmlEncode(ISNULL(x.notes, N''))), NULL),
                   N'</tr>')
            FROM
            (
                SELECT c.database_name AS item, c.notes, CASE WHEN c.monitored = 0 THEN 1 ELSE 0 END AS item_off,
                       CASE WHEN c.monitored = 0 THEN mon.fn_Pill(N'NOT MONITORED', 'MUTE')
                            ELSE (SELECT CONCAT(mon.fn_Pill(k.display_name, 'NA'), N' ')
                                  FROM mon.vw_DatabaseCheckFlat AS f
                                  JOIN mon.CheckCatalog AS k ON k.check_code = f.check_code
                                  WHERE f.database_name = c.database_name AND f.is_enabled = 0
                                  ORDER BY k.sort_order
                                  FOR XML PATH(''), TYPE).value('(./text())[1]', 'nvarchar(max)') END AS pills,
                       0 AS grp
                FROM mon.DatabaseCheck AS c
                WHERE c.monitored = 0 OR EXISTS (SELECT 1 FROM mon.vw_DatabaseCheckFlat AS f
                                                 WHERE f.database_name = c.database_name AND f.is_enabled = 0)
                UNION ALL
                SELECT N'(server)', NULL, 0,
                       (SELECT CONCAT(mon.fn_Pill(s2.display_name, 'NA'), N' ')
                        FROM mon.ServerCheck AS s2 JOIN mon.CheckCatalog AS k2 ON k2.check_code = s2.check_code
                        WHERE s2.is_enabled = 0 ORDER BY k2.sort_order
                        FOR XML PATH(''), TYPE).value('(./text())[1]', 'nvarchar(max)'), 1
                WHERE EXISTS (SELECT 1 FROM mon.ServerCheck WHERE is_enabled = 0)
            ) AS x
            ORDER BY x.grp, x.item
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(N'Monitoring coverage - switched-off checks',
            CONCAT((SELECT COUNT(*) FROM mon.DatabaseCheck WHERE monitored = 1), N' databases monitored with ',
                   (SELECT COUNT(*) FROM mon.CheckCatalog WHERE scope = 'DATABASE' AND check_code <> 'MONITORED'),
                   N' database checks and ', (SELECT COUNT(*) FROM mon.ServerCheck WHERE is_enabled = 1), N' server checks enabled. ',
                   N'Only exceptions are listed. Full matrix: EXEC OPS.mon.usp_ShowChecks; edit: OPS.mon.DatabaseCheck (Edit Top 200 Rows) or EXEC OPS.mon.usp_SetCheck.'),
            N'Database|Checks switched OFF|Notes',
            ISNULL(@rows, mon.fn_EmptyRow(3, N'Every check is enabled for every database.')));

        SET @rows =
        (
            SELECT TOP (@cap) CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_Nw(mon.fn_FmtLocal(l.changed_utc, @tz)), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(CONCAT(l.changed_by, N' @ ', ISNULL(l.host_name, N'?'))), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(CONCAT(l.object_name, N' / ', l.item_name)), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(l.property_name), NULL),
                   mon.fn_Td(CONCAT(mon.fn_OneLine(ISNULL(l.old_value, N'NULL'), 200), N' &rarr; <b>',
                                    mon.fn_OneLine(ISNULL(l.new_value, N'NULL'), 200), N'</b>'),
                             CASE WHEN l.new_value = N'0' AND l.object_name IN ('DatabaseCheck', 'ServerCheck')
                                       AND l.property_name NOT IN (N'retention_days', N'notes') THEN 'WARN' END),
                   N'</tr>')
            FROM mon.CheckChangeLog AS l
            WHERE l.changed_utc > ISNULL(@since, DATEADD(HOUR, -24, @now))
            ORDER BY l.change_log_id DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        IF @rows IS NOT NULL
            SET @body += mon.fn_Section(N'Monitoring configuration changes since the last report',
                N'Audit of mon.DatabaseCheck, mon.ServerCheck, mon.Setting and mon.DatabasePolicy (OPS.mon.CheckChangeLog). Amber = a check was switched OFF.',
                N'When|Who|Object|Property|Old -> new', @rows);

        /* ---------------- 10. Monitor self-health ---------------- */
        SET @rows =
        (
            SELECT CONCAT(N'<tr>',
                   mon.fn_Td(mon.fn_HtmlEncode(c.component_name), NULL),
                   mon.fn_Td(mon.fn_FmtLocal(c.last_success_utc, @tz),
                             CASE WHEN c.consecutive_failures > 0 THEN 'WARN' END),
                   mon.fn_Td(ISNULL(CONVERT(nvarchar(20), c.last_duration_ms), N'-'), NULL),
                   mon.fn_Td(CONVERT(nvarchar(10), c.consecutive_failures), CASE WHEN c.consecutive_failures >= 3 THEN 'WARN' END),
                   mon.fn_Td(mon.fn_Small(mon.fn_OneLine(c.last_error_message, 300)), NULL),
                   N'</tr>')
            FROM mon.ComponentStatus AS c
            ORDER BY CASE WHEN c.consecutive_failures > 0 THEN 0 ELSE 1 END, c.component_name
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(N'Monitor self-health',
            CONCAT(N'Engine: ', ISNULL((SELECT TOP (1) CONCAT(N'run ', engine_run_id, N' started ', mon.fn_FmtLocal(started_utc, @tz),
                                                             N', last beat ', mon.fn_FmtLocal(last_heartbeat_utc, @tz),
                                                             N', ', full_cycles, N' cycles')
                                        FROM mon.EngineRun ORDER BY engine_run_id DESC), N'never ran'),
                   N'. Alerts sent in window: ', (SELECT COUNT(*) FROM mon.Notification WHERE notification_type = 'ALERT' AND send_ok = 1 AND created_utc >= @window_start),
                   N'. Quiet days skipped since last digest: ', ISNULL(@skipped, 0), N'.'),
            N'Component|Last success|ms|Failures|Last error',
            ISNULL(@rows, mon.fn_EmptyRow(5, N'No component status yet.')));

        /* ---------------- assemble & send ---------------- */
        DECLARE @subtitle nvarchar(1000) = CONCAT(
            DATENAME(WEEKDAY, @local_now), N' ', CONVERT(nvarchar(16), @local_now, 120), N' ', @tzl, N' &nbsp;|&nbsp; ',
            CASE WHEN @kind = 'HEARTBEAT'
                 THEN CONCAT(N'No changes since ', mon.fn_FmtLocal(@since, @tz), N' &middot; weekly proof-of-life')
                 ELSE CONCAT(@ch_total, N' change(s) since ', ISNULL(mon.fn_FmtLocal(@since, @tz), N'first run')) END,
            N' &nbsp;|&nbsp; ', @crit, N' critical &middot; ', @warn, N' warning');

        DECLARE @subject nvarchar(255) = LEFT(CONCAT(N'[', @server, N'] ', @overall, N' | ',
            CASE WHEN @kind = 'HEARTBEAT' THEN N'Weekly heartbeat (no changes) ' ELSE N'Daily digest ' END,
            CONVERT(nvarchar(10), @today, 120), N' | ', @crit, N' crit, ', @warn, N' warn',
            CASE WHEN @kind = 'DIGEST' THEN CONCAT(N', +', @ch_open, N' opened, -', @ch_res, N' resolved') END), 255);

        DECLARE @html nvarchar(max) = mon.fn_EmailShell(
            CASE @overall WHEN 'CRITICAL' THEN '#B91C1C' WHEN 'WARNING' THEN '#B45309' ELSE '#15803D' END,
            CONCAT(@server, N' - SQL Server health'),
            CASE WHEN @kind = 'HEARTBEAT' THEN CONCAT(N'Weekly heartbeat - ', @overall)
                 ELSE CONCAT(N'Daily digest - ', @overall) END,
            @subtitle,
            @body,
            CONCAT(N'<b>Change-only delivery:</b> this digest is sent only when an issue opened, resolved or changed severity since the previous one, ',
                   N'plus a weekly heartbeat (ISO weekday ', @hb_day, N') so silence never hides a dead monitor. ',
                   N'Immediate alerts are sent separately, also change-only.<br>',
                   N'<b>Default SLAs:</b> FULL ', mon.fn_Setting('full_max_age_minutes'), N'm, DIFF ', mon.fn_Setting('diff_max_age_minutes'),
                   N'm, LOG ', mon.fn_Setting('log_max_age_minutes'), N'm, CHECKDB ', mon.fn_Setting('checkdb_max_age_days'),
                   N'd (per-database overrides: OPS.mon.DatabasePolicy). Blocking alert ', @blk_min, N'm. All settings: OPS.mon.Setting.<br>',
                   N'<b>Commands:</b> <code>EXEC OPS.mon.usp_MuteIssue</code> &middot; <code>EXEC OPS.mon.usp_AcceptConfigBaseline</code> &middot; ',
                   N'<code>EXEC OPS.mon.usp_SendDailyDigest @Force = 1</code><br>',
                   N'CloudWatch remains authoritative for host CPU, FreeableMemory, FreeStorageSpace, IOPS/latency and Multi-AZ events. ',
                   N'History retention ', @retention, N' days. Generated ', CONVERT(nvarchar(19), @now, 120), N' UTC by OPS.mon on ',
                   mon.fn_HtmlEncode(@@SERVERNAME), N'.'));

        IF @PreviewOnly = 1
        BEGIN
            SELECT @subject AS subject, @html AS html_body, DATALENGTH(@html) / 2048 AS body_kb;
            RETURN;
        END;

        DECLARE @mailitem_id int,
                @importance varchar(6) = CASE WHEN @overall = 'CRITICAL' THEN 'High' ELSE 'Normal' END;
        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail
                 @profile_name = @profile, @recipients = @recipients,
                 @subject = @subject, @body = @html, @body_format = 'HTML',
                 @importance = @importance,
                 @mailitem_id = @mailitem_id OUTPUT;

            INSERT mon.Notification(notification_type, created_utc, report_date_local, subject, recipients, mailitem_id,
                                    send_ok, change_count, active_critical, active_warning, body_kb, last_change_id)
            VALUES (@kind, @now, CASE WHEN @Force = 1 THEN NULL ELSE @today END, @subject, @recipients, @mailitem_id,
                    1, @ch_total, @crit, @warn, DATALENGTH(@html) / 2048, @hwm);
            EXEC mon.usp_SetComponentStatus 'DIGEST_MAIL', 1, @started;
        END TRY
        BEGIN CATCH
            DECLARE @em nvarchar(2000) = ERROR_MESSAGE(), @en int = ERROR_NUMBER();
            INSERT mon.Notification(notification_type, created_utc, report_date_local, subject, recipients, send_ok, error_message, change_count)
            VALUES (@kind, @now, @today, @subject, @recipients, 0, @em, @ch_total);   /* not final -> retried next hour */
            EXEC mon.usp_SetComponentStatus 'DIGEST_MAIL', 0, @started, @en, @em;
        END CATCH;
    END TRY
    BEGIN CATCH
        DECLARE @em2 nvarchar(2000) = ERROR_MESSAGE(), @en2 int = ERROR_NUMBER();
        EXEC mon.usp_SetComponentStatus 'DIGEST_MAIL', 0, @started, @en2, @em2;
        IF @PreviewOnly = 1 OR @Force = 1 THROW;
    END CATCH;
END;
GO

/* Serialize alert sending (engine and watchdog run in different sessions). */
CREATE OR ALTER PROCEDURE mon.usp_SendAlerts
    @PreviewOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @lock int;
    EXEC @lock = sys.sp_getapplock @Resource = N'mon_SendAlerts', @LockMode = 'Exclusive',
                                   @LockOwner = 'Session', @LockTimeout = 60000;
    IF @lock < 0 RETURN;
    BEGIN TRY
        EXEC mon.usp_SendAlertsCore @PreviewOnly = @PreviewOnly;
    END TRY
    BEGIN CATCH
        /* core logs its own failures */
    END CATCH;
    EXEC sys.sp_releaseapplock @Resource = N'mon_SendAlerts', @LockOwner = 'Session';
END;
GO

/* =============================================================================
   SECTION 12  -  ENGINE LOOP, HOURLY RUNNER, PURGE, OPERATOR PROCEDURES
   ============================================================================= */

/*
   One Agent execution loops for engine_loop_minutes (default 55):
     every sample_interval_seconds  -> blocking sampler (+ fast BLOCKING evaluation/alert when needed)
     every collect_interval_minutes -> all collectors, full evaluation, change-only alert mail
   The job is scheduled every minute; SQL Agent does not start a job that is already
   running, so a crashed loop is restarted within ~1 minute and msdb job history
   receives ~24 rows per day instead of 1,440.
*/
CREATE OR ALTER PROCEDURE mon.usp_EngineLoop
    @MaxMinutes int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @loop_min int  = ISNULL(@MaxMinutes, ISNULL(mon.fn_SettingInt('engine_loop_minutes'), 55)),
            @sample_s int  = ISNULL(mon.fn_SettingInt('sample_interval_seconds'), 30),
            @collect_m int = ISNULL(mon.fn_SettingInt('collect_interval_minutes'), 5),
            @elog_m int    = ISNULL(mon.fn_SettingInt('errorlog_interval_minutes'), 15);
    IF @sample_s < 10 SET @sample_s = 10;
    IF @sample_s > 300 SET @sample_s = 300;

    DECLARE @run_id bigint, @end_utc datetime2(3) = DATEADD(MINUTE, @loop_min, SYSUTCDATETIME()),
            @next_full datetime2(3) = '19000101', @next_elog datetime2(3) = '19000101',
            @iter int = 0, @cycles int = 0, @reason nvarchar(400) = N'loop window elapsed',
            @open int, @iter_start datetime2(3), @cycle_start datetime2(3), @read_elog bit,
            @sleep_ms int, @delay char(8);

    INSERT mon.EngineRun(started_utc, last_heartbeat_utc) VALUES (SYSUTCDATETIME(), SYSUTCDATETIME());
    SET @run_id = SCOPE_IDENTITY();

    WHILE SYSUTCDATETIME() < @end_utc
    BEGIN
        IF ISNULL(mon.fn_SettingInt('engine_enabled'), 1) = 0
        BEGIN
            SET @reason = N'engine_enabled = 0';
            BREAK;
        END;

        SET @iter += 1;
        SET @iter_start = SYSUTCDATETIME();
        SET @open = NULL;

        /* ---- every sample: blocking ---- */
        BEGIN TRY
            EXEC mon.usp_CaptureBlocking @OpenEpisodes = @open OUTPUT;
        END TRY
        BEGIN CATCH
            SET @open = NULL;
        END CATCH;

        IF SYSUTCDATETIME() >= @next_full
        BEGIN
            /* ---- every collect interval: full cycle ---- */
            SET @cycle_start = SYSUTCDATETIME();
            BEGIN TRY
                EXEC mon.usp_SyncPolicies;
                EXEC mon.usp_CollectDatabaseState;
                EXEC mon.usp_CollectBackups;
                EXEC mon.usp_CollectAgent;
                EXEC mon.usp_CollectOlaCommandLog;
                SET @read_elog = CASE WHEN SYSUTCDATETIME() >= @next_elog THEN 1 ELSE 0 END;
                EXEC mon.usp_CollectEvents @ReadErrorLog = @read_elog;
                IF @read_elog = 1 SET @next_elog = DATEADD(MINUTE, @elog_m, SYSUTCDATETIME());
                EXEC mon.usp_CollectPerf;
                EXEC mon.usp_EvaluateIssues @Scope = 'ALL';
                EXEC mon.usp_SendAlerts;
                EXEC mon.usp_SetComponentStatus 'ENGINE_CYCLE', 1, @cycle_start;
                SET @cycles += 1;
            END TRY
            BEGIN CATCH
                DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
                EXEC mon.usp_SetComponentStatus 'ENGINE_CYCLE', 0, @cycle_start, @en, @em;
            END CATCH;
            SET @next_full = DATEADD(MINUTE, @collect_m, @cycle_start);
        END
        ELSE IF @open > 0 OR EXISTS (SELECT 1 FROM mon.Issue WHERE is_active = 1 AND category = 'BLOCKING')
        BEGIN
            /* ---- fast path: blocking may have crossed (or left) the threshold ---- */
            BEGIN TRY
                EXEC mon.usp_EvaluateIssues @Scope = 'BLOCKING';
                EXEC mon.usp_SendAlerts;
            END TRY
            BEGIN CATCH
                /* logged by the procedures */
            END CATCH;
        END;

        IF @@TRANCOUNT > 0 ROLLBACK;   /* defensive: nothing here opens transactions */

        UPDATE mon.EngineRun
           SET last_heartbeat_utc = SYSUTCDATETIME(), iterations = @iter, full_cycles = @cycles
         WHERE engine_run_id = @run_id;

        /* Sleep the remainder of the sample interval. */
        SET @sleep_ms = @sample_s * 1000 - DATEDIFF(MILLISECOND, @iter_start, SYSUTCDATETIME());
        IF @sleep_ms < 1000 SET @sleep_ms = 1000;
        IF DATEADD(MILLISECOND, @sleep_ms, SYSUTCDATETIME()) > @end_utc
            SET @sleep_ms = CASE WHEN DATEDIFF(MILLISECOND, SYSUTCDATETIME(), @end_utc) > 0
                                 THEN DATEDIFF(MILLISECOND, SYSUTCDATETIME(), @end_utc) ELSE 0 END;
        IF @sleep_ms > 0
        BEGIN
            SET @delay = CONVERT(char(8), DATEADD(SECOND, (@sleep_ms + 999) / 1000, CONVERT(time(0), '00:00:00')), 108);
            WAITFOR DELAY @delay;
        END;
    END;

    UPDATE mon.EngineRun
       SET ended_utc = SYSUTCDATETIME(), end_reason = @reason, iterations = @iter, full_cycles = @cycles
     WHERE engine_run_id = @run_id;
END;
GO

CREATE OR ALTER PROCEDURE mon.usp_Purge
AS
BEGIN
    SET NOCOUNT ON;
    SET DEADLOCK_PRIORITY LOW;
    SET LOCK_TIMEOUT 10000;

    DECLARE @days int = ISNULL(mon.fn_SettingInt('history_retention_days'), 90),
            @bdays int = ISNULL(mon.fn_SettingInt('blocking_sample_retention_days'), 30);
    DECLARE @cut datetime2(0) = DATEADD(DAY, -@days, SYSUTCDATETIME()),
            @bcut datetime2(0) = DATEADD(DAY, -@bdays, SYSUTCDATETIME()),
            @n int, @started datetime2(3) = SYSUTCDATETIME();

    BEGIN TRY
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.BlockingSample    WHERE sample_utc < @bcut;       SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.BlockingEpisode   WHERE is_open = 0 AND last_seen_utc < @cut; SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.PerfSample        WHERE sample_utc < @cut;        SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.CpuSample         WHERE sample_utc < @cut;        SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.StorageSample     WHERE sample_utc < @cut;        SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.WaitStatsSnapshot WHERE snapshot_utc < @cut;      SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.FileStatsSnapshot WHERE snapshot_utc < @cut;      SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.AgentJobRun       WHERE run_start_utc < @cut;     SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.AgentFailure      WHERE run_start_utc < @cut;     SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (1000) FROM mon.Deadlock          WHERE event_utc < @cut;         SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.ErrorLogEvent     WHERE log_utc < @cut;           SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.LoginFailure      WHERE hour_utc < @cut;          SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.RdsTask           WHERE last_collected_utc < @cut; SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.TlogBackup        WHERE backup_file_time_utc < @cut; SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.Notification      WHERE created_utc < @cut;       SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.EngineRun         WHERE started_utc < @cut;       SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.IssueMute         WHERE until_utc < @cut;         SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.OlaCommand        WHERE start_utc < @cut;         SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.BackupInventoryDaily WHERE snapshot_date < CONVERT(date, @cut); SET @n = @@ROWCOUNT; END;
        /* audit of monitoring changes is kept 4x longer than operational history */
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.CheckChangeLog    WHERE changed_utc < DATEADD(DAY, -4 * @days, SYSUTCDATETIME()); SET @n = @@ROWCOUNT; END;

        /* Closed issues and their change history. */
        SET @n = 1;
        WHILE @n > 0
        BEGIN
            DELETE TOP (5000) c
            FROM mon.IssueChange AS c
            JOIN mon.Issue AS i ON i.issue_id = c.issue_id
            WHERE i.is_active = 0 AND i.resolved_utc < @cut;
            SET @n = @@ROWCOUNT;
        END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.Issue WHERE is_active = 0 AND resolved_utc < @cut; SET @n = @@ROWCOUNT; END;

        EXEC mon.usp_SetComponentStatus 'PURGE', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'PURGE', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* Hourly: watchdog (dead-man switch for the engine), digest when due, purge. */
CREATE OR ALTER PROCEDURE mon.usp_RunHourly
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY EXEC mon.usp_SnapshotBackupInventory;            END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC mon.usp_EvaluateIssues @Scope = 'WATCHDOG'; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC mon.usp_SendAlerts;                         END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC mon.usp_SendDailyDigest;                    END TRY BEGIN CATCH END CATCH;
    IF DATEPART(HOUR, SYSUTCDATETIME()) % 6 = 0
    BEGIN
        BEGIN TRY EXEC mon.usp_Purge; END TRY BEGIN CATCH END CATCH;
    END;
END;
GO

/* Mute (or unmute) issues by LIKE pattern on issue_key. Muted issues stay visible in the digest. */
CREATE OR ALTER PROCEDURE mon.usp_MuteIssue
    @KeyPattern nvarchar(400),
    @Hours      int = 8,
    @Reason     nvarchar(400) = N'(no reason given)',
    @Unmute     bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @Unmute = 1
        UPDATE mon.IssueMute SET until_utc = SYSUTCDATETIME() WHERE key_pattern = @KeyPattern AND until_utc > SYSUTCDATETIME();
    ELSE
        INSERT mon.IssueMute(key_pattern, until_utc, reason) VALUES (@KeyPattern, DATEADD(HOUR, @Hours, SYSUTCDATETIME()), @Reason);

    UPDATE i SET is_muted = CASE WHEN EXISTS (SELECT 1 FROM mon.IssueMute AS m
                                             WHERE m.until_utc > SYSUTCDATETIME() AND i.issue_key LIKE m.key_pattern) THEN 1 ELSE 0 END
    FROM mon.Issue AS i
    WHERE i.is_active = 1;

    SELECT issue_key, severity, title, is_muted FROM mon.Issue WHERE is_active = 1 AND issue_key LIKE @KeyPattern;
END;
GO

/* Accept the current configuration of a database (or all, @DatabaseName = NULL) as the new baseline. */
CREATE OR ALTER PROCEDURE mon.usp_AcceptConfigBaseline
    @DatabaseName sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM mon.DatabaseConfigBaseline WHERE @DatabaseName IS NULL OR database_name = @DatabaseName;
    EXEC mon.usp_CollectDatabaseState;   /* re-seeds the baseline from current values */
    SELECT * FROM mon.DatabaseConfigBaseline
    WHERE @DatabaseName IS NULL OR database_name = @DatabaseName
    ORDER BY database_name, property_name;
END;
GO

/* =============================================================================
   SECTION 13  -  SQL AGENT JOBS  (msdb; RDS-safe: only documented Agent procs)
   ============================================================================= */
USE [msdb];
GO

DECLARE @owner sysname = SUSER_SNAME(),
        @job sysname = N'MON - Engine',
        @cmd nvarchar(max) = N'SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON;
SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
EXEC mon.usp_EngineLoop;',
        @desc nvarchar(512) = N'OPS.mon engine: blocking sampler every 30 s; collectors, issue evaluation and change-only alert mail every 5 min. Loops ~55 min per execution; scheduled every minute (Agent skips starts while running).';

IF NOT EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = @job)
BEGIN
    EXEC dbo.sp_add_job @job_name = @job, @enabled = 1, @description = @desc, @owner_login_name = @owner;
    EXEC dbo.sp_add_jobstep @job_name = @job, @step_name = N'Run engine loop', @subsystem = N'TSQL',
         @database_name = N'OPS', @command = @cmd, @retry_attempts = 0;
    EXEC dbo.sp_add_jobserver @job_name = @job;
END
ELSE
BEGIN
    EXEC dbo.sp_update_job @job_name = @job, @enabled = 1, @description = @desc;
    BEGIN TRY
        EXEC dbo.sp_update_jobstep @job_name = @job, @step_id = 1, @step_name = N'Run engine loop',
             @subsystem = N'TSQL', @database_name = N'OPS', @command = @cmd, @retry_attempts = 0;
    END TRY
    BEGIN CATCH
        EXEC dbo.sp_add_jobstep @job_name = @job, @step_name = N'Run engine loop', @subsystem = N'TSQL',
             @database_name = N'OPS', @command = @cmd, @retry_attempts = 0;
    END CATCH;
END;

BEGIN TRY
    EXEC dbo.sp_update_jobschedule @job_name = @job, @name = N'MON - Every minute', @enabled = 1,
         @freq_type = 4, @freq_interval = 1, @freq_subday_type = 4, @freq_subday_interval = 1,
         @active_start_time = 000000;
END TRY
BEGIN CATCH
    EXEC dbo.sp_add_jobschedule @job_name = @job, @name = N'MON - Every minute', @enabled = 1,
         @freq_type = 4, @freq_interval = 1, @freq_subday_type = 4, @freq_subday_interval = 1,
         @active_start_time = 000000;
END CATCH;
GO

DECLARE @owner sysname = SUSER_SNAME(),
        @job sysname = N'MON - Digest & Watchdog',
        @cmd nvarchar(max) = N'SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON;
SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
EXEC mon.usp_RunHourly;',
        @desc nvarchar(512) = N'OPS.mon hourly: engine watchdog (alerts if MON - Engine stops), change-only daily digest at 08:00 America/New_York with Monday heartbeat, history purge.';

IF NOT EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = @job)
BEGIN
    EXEC dbo.sp_add_job @job_name = @job, @enabled = 1, @description = @desc, @owner_login_name = @owner;
    EXEC dbo.sp_add_jobstep @job_name = @job, @step_name = N'Watchdog, digest, purge', @subsystem = N'TSQL',
         @database_name = N'OPS', @command = @cmd, @retry_attempts = 1, @retry_interval = 5;
    EXEC dbo.sp_add_jobserver @job_name = @job;
END
ELSE
BEGIN
    EXEC dbo.sp_update_job @job_name = @job, @enabled = 1, @description = @desc;
    BEGIN TRY
        EXEC dbo.sp_update_jobstep @job_name = @job, @step_id = 1, @step_name = N'Watchdog, digest, purge',
             @subsystem = N'TSQL', @database_name = N'OPS', @command = @cmd, @retry_attempts = 1, @retry_interval = 5;
    END TRY
    BEGIN CATCH
        EXEC dbo.sp_add_jobstep @job_name = @job, @step_name = N'Watchdog, digest, purge', @subsystem = N'TSQL',
             @database_name = N'OPS', @command = @cmd, @retry_attempts = 1, @retry_interval = 5;
    END CATCH;
END;

/* xx:02 every hour, so the 08:00 ET digest leaves at 08:02 after the 08:00 collection cycle. */
BEGIN TRY
    EXEC dbo.sp_update_jobschedule @job_name = @job, @name = N'MON - Hourly at :02', @enabled = 1,
         @freq_type = 4, @freq_interval = 1, @freq_subday_type = 8, @freq_subday_interval = 1,
         @active_start_time = 000200;
END TRY
BEGIN CATCH
    EXEC dbo.sp_add_jobschedule @job_name = @job, @name = N'MON - Hourly at :02', @enabled = 1,
         @freq_type = 4, @freq_interval = 1, @freq_subday_type = 8, @freq_subday_interval = 1,
         @active_start_time = 000200;
END CATCH;
GO

/* =============================================================================
   SECTION 14  -  INITIAL COLLECTION (no mail) + VALIDATION
   ============================================================================= */
USE [OPS];
GO

EXEC mon.usp_SyncPolicies;
EXEC mon.usp_CollectDatabaseState;
EXEC mon.usp_CollectBackups;
EXEC mon.usp_CollectAgent;
EXEC mon.usp_CollectOlaCommandLog;
EXEC mon.usp_CollectEvents @ReadErrorLog = 1;
EXEC mon.usp_CollectPerf;
EXEC mon.usp_CaptureBlocking;
EXEC mon.usp_SnapshotBackupInventory @Force = 1;
EXEC mon.usp_EvaluateIssues @Scope = 'ALL';
EXEC mon.usp_SetComponentStatus 'ENGINE_CYCLE', 1, NULL;

/*
   Pre-existing problems found at install time are NOT mailed as alerts
   (they would otherwise all arrive in one burst while OPS.monitor is also running).
   They appear in the first digest. Comment this UPDATE out to receive them as an alert.
*/
UPDATE mon.IssueChange SET alert_status = 'SKIPPED', alert_utc = SYSUTCDATETIME()
WHERE alert_status IS NULL
  AND NOT EXISTS (SELECT 1 FROM mon.Notification WHERE notification_type = 'ALERT');
GO

/* ---- Validation result sets: review before forcing a test mail ---- */
SELECT component_name, last_success_utc, last_duration_ms, consecutive_failures, last_error_message
FROM mon.ComponentStatus ORDER BY consecutive_failures DESC, component_name;

SELECT severity, category, database_name, title, issue_key, is_muted
FROM mon.vw_ActiveIssues ORDER BY mon.fn_SevRank(severity) DESC, category, title;

SELECT database_name, state_desc, recovery_model, full_status, diff_status, log_status, checkdb_status,
       full_finish_utc, effective_data_utc, log_finish_utc, log_source, log_used_pct, vlf_total
FROM mon.vw_BackupHealth ORDER BY database_name;

SELECT job_name, job_type, health_status, last_run_utc, last_success_utc, last_duration_s, median_s
FROM mon.vw_JobHealth ORDER BY job_name;

SELECT setting_name, setting_value, category, description FROM mon.Setting ORDER BY category, setting_name;
GO

/* Everything that is checked on this server (4 result sets) and the backup retention grid. */
EXEC mon.usp_ShowChecks;
EXEC mon.usp_ShowBackupRetention @Live = 0;
EXEC mon.usp_ShowOlaLog @Hours = 168;
GO

/*
================================================================================
 AFTER INSTALL - RUNBOOK
================================================================================
 1. Preview the digest HTML without sending (copy html_body into a .html file):
        EXEC OPS.mon.usp_SendDailyDigest @Force = 1, @PreviewOnly = 1;

 2. Send one test digest now:
        EXEC OPS.mon.usp_SendDailyDigest @Force = 1;

 3. Confirm RDS Database Mail delivery:
        SELECT TOP (20) * FROM msdb.dbo.rds_fn_sysmail_allitems() ORDER BY send_request_date DESC;
        SELECT TOP (50) * FROM msdb.dbo.rds_fn_sysmail_event_log() ORDER BY log_date DESC;

 4. Test blocking detection end-to-end (use a scratch database; set the alert to 2 minutes temporarily):
        UPDATE OPS.mon.Setting SET setting_value = N'2' WHERE setting_name = 'blocking_alert_minutes';
        -- Session A:  BEGIN TRAN; UPDATE dbo.T SET c = c WHERE id = 1;   (leave open)
        -- Session B:  SELECT * FROM dbo.T WHERE id = 1;                   (blocks)
        -- Within ~2.5 min: CRITICAL alert "Blocking 2m - session NN ... DIAGNOSIS: head blocker is IDLE ..."
        -- Session A:  ROLLBACK;  -> RESOLVED mail with final duration within ~30 s
        UPDATE OPS.mon.Setting SET setting_value = N'10' WHERE setting_name = 'blocking_alert_minutes';

 5. What is checked, per database (rev 5.1 check matrix; see MON_User_Guide for details)
        EXEC OPS.mon.usp_ShowChecks;                                             -- full matrix + audit
        EXEC OPS.mon.usp_SetCheck @Database = N'YourDb', @Check = 'DIFF', @Enabled = 0;      -- FULL + LOG only
        EXEC OPS.mon.usp_SetCheck @Database = N'YourDb', @Check = 'MONITORED', @Enabled = 0; -- ignore database
        EXEC OPS.mon.usp_SetCheck @Database = N'%', @Check = 'LONGQ', @Enabled = 0;         -- all databases
        EXEC OPS.mon.usp_SetCheck @Check = 'CPU', @Enabled = 0;                               -- server level
        EXEC OPS.mon.usp_SetCheck @Database = N'YourDb', @Check = 'RETENTION', @Enabled = 1, @RetentionDays = 14;
        -- or SSMS: Object Explorer > OPS > Tables > mon.DatabaseCheck > Edit Top 200 Rows
        -- SLA minutes stay in mon.DatabasePolicy:
        UPDATE OPS.mon.DatabasePolicy SET log_max_age_minutes = 15 WHERE database_name = N'YourDb';
        -- Weekly Ola job:
        UPDATE OPS.mon.JobPolicy SET max_hours_since_success = 192 WHERE job_name = N'IndexOptimize - USER_DATABASES';
        -- Custom job under SLA:
        INSERT OPS.mon.JobPolicy(job_id, job_name, job_type, max_hours_since_success, auto_discovered)
        SELECT job_id, name, 'CUSTOM', 24, 0 FROM msdb.dbo.sysjobs WHERE name = N'Your job';
        -- Alert on WARNING changes too (default: CRITICAL only; warnings go to the digest):
        UPDATE OPS.mon.Setting SET setting_value = N'WARNING' WHERE setting_name = 'alert_min_severity';
        -- Re-send still-open CRITICAL issues every 4 hours (default off = pure change-only):
        UPDATE OPS.mon.Setting SET setting_value = N'240' WHERE setting_name = 'reminder_minutes';

 6. Maintenance window: mute long queries / blocking during the nightly ETL for 3 hours:
        EXEC OPS.mon.usp_MuteIssue @KeyPattern = N'LONGQ:%',   @Hours = 3, @Reason = N'Nightly ETL';
        EXEC OPS.mon.usp_MuteIssue @KeyPattern = N'BLOCKING:%', @Hours = 3, @Reason = N'Nightly ETL';

 7. Stop / start the engine gracefully:
        UPDATE OPS.mon.Setting SET setting_value = N'0' WHERE setting_name = 'engine_enabled';   -- stops within 30 s
        UPDATE OPS.mon.Setting SET setting_value = N'1' WHERE setting_name = 'engine_enabled';   -- next minute

 8. When satisfied, retire the previous version (optional, manual):
        EXEC msdb.dbo.sp_update_job @job_name = N'OPS - Backup and Maintenance Monitor',   @enabled = 0;
        EXEC msdb.dbo.sp_update_job @job_name = N'OPS - Daily Backup and Maintenance Report', @enabled = 0;

 UNINSTALL (rollback of this script):
        EXEC msdb.dbo.sp_delete_job @job_name = N'MON - Engine';
        EXEC msdb.dbo.sp_delete_job @job_name = N'MON - Digest & Watchdog';
        -- then drop every object in schema [mon] (views, procedures, functions, tables) and:
        -- DROP SCHEMA mon;
================================================================================
*/
