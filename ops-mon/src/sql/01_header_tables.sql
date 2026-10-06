/*
================================================================================
    MON  -  SQL Server Operational Monitoring & Change-Only Email Delivery
    Target : MS-APP-STG  (Amazon RDS for SQL Server, 2016 SP2 or later)
    Home   : [OPS] database, schema [mon]  (nothing is created in any other schema)
    Author : DBA team / generated with Claude
    Rev    : 5.4   (successor of OPS.monitor Rev 4 - runs side-by-side with it)
             5.1 adds: check matrix with checkboxes (mon.DatabaseCheck / mon.ServerCheck),
                       audit of every change (mon.CheckChangeLog), backup retention &
                       inventory grid (mon.vw_BackupRetention, daily mon.BackupInventoryDaily),
                       usp_SetCheck / usp_ShowChecks / usp_ShowBackupRetention, and an
                       SSMS custom report (MON_Checks_and_Retention.rdl).
             5.3 : switching a check OFF closes its open issues immediately
                   (mon.usp_CloseDisabledIssues, called by APPLY / usp_SetCheck /
                   digest / alerts); DIFF issue shows which backup counted
                   (FULL/... or DIFF/...); CHECKDB older than 4x SLA = CRITICAL
                   (setting checkdb_crit_factor); dates older than 300 days show the year.
             5.4 : release guard (mon.ReleaseHistory, engine paused during install,
                   mon.usp_SelfTest gate), email statistics (mon.usp_ShowEmailStats),
                   separate uninstall script (MON_Uninstall.sql).
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
   RELEASE GUARD [rev 5.4]
   - every install/upgrade is recorded in mon.ReleaseHistory (version, who, when, result);
   - the engine is PAUSED (engine_enabled = 0) for the duration of the install, so a
     half-installed version never runs;
   - at the end mon.usp_SelfTest validates every object; only if it passes is the engine
     resumed and the release marked COMPLETED. Otherwise the engine stays paused, the
     release is marked FAILED and the hourly watchdog raises a CRITICAL issue.
   - nothing outside schema [mon] is created (the self-test verifies this too); the only
     objects outside OPS are the two SQL Agent jobs "MON - Engine" and "MON - Digest & Watchdog".
   ============================================================================= */
IF OBJECT_ID(N'mon.ReleaseHistory', N'U') IS NULL
BEGIN
    CREATE TABLE mon.ReleaseHistory
    (
        release_id          int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_mon_ReleaseHistory PRIMARY KEY,
        version             varchar(20)    NOT NULL,
        status              varchar(20)    NOT NULL,     /* INSTALLING / COMPLETED / FAILED */
        started_utc         datetime2(0)   NOT NULL,
        started_server_time datetime2(0)   NOT NULL,     /* SYSDATETIME(): comparable with sys.objects.create_date */
        finished_utc        datetime2(0)   NULL,
        prev_version        varchar(20)    NULL,
        prev_engine_enabled nvarchar(20)   NULL,
        installed_by        sysname        NOT NULL CONSTRAINT DF_mon_RH_by   DEFAULT (ORIGINAL_LOGIN()),
        host_name           nvarchar(128)  NULL     CONSTRAINT DF_mon_RH_host DEFAULT (HOST_NAME()),
        selftest_errors     int            NULL,
        selftest_warnings   int            NULL,
        notes               nvarchar(4000) NULL
    );
END;
GO

DECLARE @version varchar(20) = '5.4';
DECLARE @prev varchar(20) = (SELECT TOP (1) version FROM mon.ReleaseHistory WHERE status = 'COMPLETED' ORDER BY release_id DESC);
DECLARE @prev_engine nvarchar(20) = NULL;

/* Abandon an earlier install that never finished (e.g. the script was stopped half way). */
UPDATE mon.ReleaseHistory SET status = 'FAILED', finished_utc = SYSUTCDATETIME(),
       notes = CONCAT(notes, N' Superseded by a new install before it completed.')
WHERE status = 'INSTALLING';

IF OBJECT_ID(N'mon.Setting', N'U') IS NOT NULL
BEGIN
    SELECT @prev_engine = setting_value FROM mon.Setting WHERE setting_name = 'engine_enabled';
    /* If a previous failed install left the engine paused, restore the value it had before that install. */
    IF @prev_engine = N'0'
       AND EXISTS (SELECT 1 FROM mon.ReleaseHistory WHERE status = 'FAILED' AND prev_engine_enabled IS NOT NULL)
        SELECT TOP (1) @prev_engine = prev_engine_enabled FROM mon.ReleaseHistory
        WHERE prev_engine_enabled IS NOT NULL ORDER BY release_id DESC;
    UPDATE mon.Setting SET setting_value = N'0' WHERE setting_name = 'engine_enabled';
END;

INSERT mon.ReleaseHistory(version, status, started_utc, started_server_time, prev_version, prev_engine_enabled)
VALUES (@version, 'INSTALLING', SYSUTCDATETIME(), DATEADD(SECOND, -1, SYSDATETIME()), @prev, @prev_engine);

PRINT CONCAT(N'MON install ', @version, N' started (previous: ', ISNULL(@prev, N'none'), N'). Engine paused until the self-test passes.');
GO

/*
   Re-install / upgrade: stop the running engine loop first. Altering mon.usp_EngineLoop while
   it runs makes that execution fail with error 2801 ("definition ... has changed since it was
   compiled"). The job's every-minute schedule restarts it automatically with the new code.
*/
BEGIN TRY
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'MON - Engine')
    BEGIN
        EXEC msdb.dbo.sp_stop_job @job_name = N'MON - Engine';
        PRINT N'MON - Engine was running: stopped for the upgrade (restarts within 1 minute).';
        WAITFOR DELAY '00:00:05';
    END;
END TRY
BEGIN CATCH
    /* job not running (error 22022) - nothing to stop */
END CATCH;
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
