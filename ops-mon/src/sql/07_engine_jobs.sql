
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
    /* [5.6] per-area retention; empty setting = history_retention_days */
    DECLARE @perf_days  int = ISNULL(TRY_CONVERT(int, NULLIF(mon.fn_Setting('retention_perf_days'), N'')), @days),
            @bk_days    int = ISNULL(TRY_CONVERT(int, NULLIF(mon.fn_Setting('retention_backup_days'), N'')), @days),
            @iss_days   int = ISNULL(TRY_CONVERT(int, NULLIF(mon.fn_Setting('retention_issue_days'), N'')), @days),
            @mail_days  int = ISNULL(TRY_CONVERT(int, NULLIF(mon.fn_Setting('retention_email_days'), N'')), @days),
            @audit_days int = ISNULL(TRY_CONVERT(int, NULLIF(mon.fn_Setting('retention_audit_days'), N'')), 4 * @days);
    DECLARE @cut datetime2(0) = DATEADD(DAY, -@days, SYSUTCDATETIME()),
            @bcut datetime2(0) = DATEADD(DAY, -@bdays, SYSUTCDATETIME()),
            @pcut datetime2(0) = DATEADD(DAY, -@perf_days, SYSUTCDATETIME()),
            @kcut datetime2(0) = DATEADD(DAY, -@bk_days, SYSUTCDATETIME()),
            @icut datetime2(0) = DATEADD(DAY, -@iss_days, SYSUTCDATETIME()),
            @mcut datetime2(0) = DATEADD(DAY, -@mail_days, SYSUTCDATETIME()),
            @n int, @started datetime2(3) = SYSUTCDATETIME();

    BEGIN TRY
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.BlockingSample    WHERE sample_utc < @bcut;       SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.BlockingEpisode   WHERE is_open = 0 AND last_seen_utc < @cut; SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.PerfSample        WHERE sample_utc < @pcut;        SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.CpuSample         WHERE sample_utc < @pcut;        SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.StorageSample     WHERE sample_utc < @pcut;        SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.WaitStatsSnapshot WHERE snapshot_utc < @pcut;      SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.FileStatsSnapshot WHERE snapshot_utc < @pcut;      SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.AgentJobRun       WHERE run_start_utc < @cut;     SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.AgentFailure      WHERE run_start_utc < @cut;     SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (1000) FROM mon.Deadlock          WHERE event_utc < @cut;         SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.ErrorLogEvent     WHERE log_utc < @cut;           SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.LoginFailure      WHERE hour_utc < @cut;          SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.RdsTask           WHERE last_collected_utc < @kcut; SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.TlogBackup        WHERE backup_file_time_utc < @kcut; SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.Notification      WHERE created_utc < @mcut;       SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.EngineRun         WHERE started_utc < @mcut;       SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.IssueMute         WHERE until_utc < @cut;         SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.OlaCommand        WHERE start_utc < @kcut;         SET @n = @@ROWCOUNT; END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.BackupInventoryDaily WHERE snapshot_date < CONVERT(date, @kcut); SET @n = @@ROWCOUNT; END;
        /* audit of monitoring changes is kept 4x longer than operational history */
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.CheckChangeLog    WHERE changed_utc < DATEADD(DAY, -@audit_days, SYSUTCDATETIME()); SET @n = @@ROWCOUNT; END;

        /* Closed issues and their change history. */
        SET @n = 1;
        WHILE @n > 0
        BEGIN
            DELETE TOP (5000) c
            FROM mon.IssueChange AS c
            JOIN mon.Issue AS i ON i.issue_id = c.issue_id
            WHERE i.is_active = 0 AND i.resolved_utc < @icut;
            SET @n = @@ROWCOUNT;
        END;
        SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (5000) FROM mon.Issue WHERE is_active = 0 AND resolved_utc < @icut; SET @n = @@ROWCOUNT; END;

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
    BEGIN TRY EXEC mon.usp_RunScheduledEmails;                 END TRY BEGIN CATCH END CATCH;   /* [5.6] summary + full report schedule */
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
        @desc nvarchar(512) = N'OPS.mon hourly: engine watchdog (alerts if MON - Engine stops), scheduled summary and full report emails (mon.Setting summary_* / full_report_*), history purge every 6 h.';

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

/* clean already-collected Agent messages of the 8153 warning noise */
UPDATE mon.AgentFailure SET message = mon.fn_CleanAgentMessage(message) WHERE message LIKE N'%Message 8153%';
UPDATE mon.AgentJobRun  SET message = mon.fn_CleanAgentMessage(message) WHERE message LIKE N'%Message 8153%';

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
