
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
           CASE WHEN b.full_finish_utc IS NULL OR b.diff_finish_utc > b.full_finish_utc
                THEN CONCAT('DIFF/', b.diff_source) ELSE CONCAT('FULL/', b.full_source) END AS effective_data_source,
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
       i.alert_sent_utc, i.alert_severity,
       i.ack_utc, i.ack_by, i.ack_note,
       CASE WHEN i.is_muted = 1 THEN 'MUTED' WHEN i.ack_utc IS NOT NULL THEN 'ACKNOWLEDGED' ELSE 'NEW' END AS workflow_state
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

/* [rev 5.3] Close open issues whose check is switched off - immediately, silently (no RESOLVED mail).
   Called by the engine, the digest, the alert sender, usp_SetCheck and the PowerShell editor (APPLY). */
CREATE OR ALTER PROCEDURE mon.usp_CloseDisabledIssues
    @Closed        int = NULL OUTPUT,
    @LockTimeoutMs int = 30000
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(0) = SYSUTCDATETIME(), @lock int;
    DECLARE @chg TABLE(issue_id bigint, old_sev varchar(10));
    SET @Closed = 0;

    EXEC @lock = sys.sp_getapplock @Resource = N'mon_IssueMerge', @LockMode = 'Exclusive',
                                   @LockOwner = 'Session', @LockTimeout = @LockTimeoutMs;
    IF @lock < 0 RETURN;                                   /* engine busy: it will do the same at its merge */
    BEGIN TRY
        UPDATE t
           SET t.is_active = 0, t.resolved_utc = @now, t.close_type = 'DISABLED'
        OUTPUT inserted.issue_id, deleted.severity INTO @chg(issue_id, old_sev)
        FROM mon.Issue AS t
        WHERE t.is_active = 1 AND mon.fn_IsCheckEnabled(t.issue_key, t.database_name) = 0;

        INSERT mon.IssueChange(issue_id, change_type, old_severity, new_severity, change_utc, alert_status, alert_utc)
        SELECT c.issue_id, 'EXPIRED', c.old_sev, NULL, @now, 'SKIPPED', @now FROM @chg AS c;
        SET @Closed = @@ROWCOUNT;
    END TRY
    BEGIN CATCH
        EXEC sys.sp_releaseapplock @Resource = N'mon_IssueMerge', @LockOwner = 'Session';
        THROW;
    END CATCH;
    EXEC sys.sp_releaseapplock @Resource = N'mon_IssueMerge', @LockOwner = 'Session';
END;
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
        /* [rev 5.4] an install/upgrade that failed or never finished leaves the engine paused */
        IF @Scope = 'WATCHDOG' AND OBJECT_ID(N'mon.ReleaseHistory', N'U') IS NOT NULL
            INSERT #Issue(issue_key, category, severity, is_event, title, detail)
            SELECT TOP (1) N'MON_RELEASE', 'ENGINE', 'CRITICAL', 0,
                   CONCAT(N'Monitoring release ', r.version, N' is ', r.status, N' - engine may be paused'),
                   CONCAT(N'Started ', mon.fn_FmtLocal(r.started_utc, @tz), N' by ', r.installed_by,
                          N'; self-test errors: ', ISNULL(CONVERT(nvarchar(10), r.selftest_errors), N'n/a'),
                          N'. Run EXEC OPS.mon.usp_SelfTest; fix the errors and re-run the installer.')
            FROM mon.ReleaseHistory AS r
            WHERE r.release_id = (SELECT MAX(release_id) FROM mon.ReleaseHistory)
              AND (r.status = 'FAILED' OR (r.status = 'INSTALLING' AND r.started_utc < DATEADD(MINUTE, -30, @now)));
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
                ('DIFF', h.diff_status, h.diff_age_min, h.diff_max_age_minutes, h.effective_data_utc, h.effective_data_source,
                 CASE WHEN h.diff_status IN ('MISSING', 'OVERDUE') THEN 'CRITICAL' END),
                ('LOG',  h.log_status, h.log_age_min, h.log_max_age_minutes, h.log_finish_utc, h.log_source,
                 CASE WHEN h.log_status IN ('MISSING', 'OVERDUE', 'CHAIN_BROKEN') THEN 'CRITICAL' END)
            ) AS v(btype, st, age_min, sla_min, last_utc, src, sev)
            WHERE v.sev IS NOT NULL;

            INSERT #Issue(issue_key, category, severity, is_event, database_name, title, detail)
            SELECT CONCAT(N'CHECKDB:', h.database_name), 'INTEGRITY',   /* [5.6.4] database integrity, not a backup */
                   CASE WHEN h.checkdb_age_hours > h.checkdb_max_age_days * 24 * ISNULL(mon.fn_SettingInt('checkdb_crit_factor'), 4)
                        THEN 'CRITICAL' ELSE 'WARNING' END, 0, h.database_name,
                   CONCAT(N'No clean CHECKDB ', CASE WHEN h.checkdb_status = 'NEVER' THEN N'ever recorded'
                          ELSE CONCAT(N'for ', mon.fn_Duration(h.checkdb_age_hours * 3600)) END, N': ', h.database_name),
                   CONCAT(N'SLA ', h.checkdb_max_age_days, N' days; last known good ', ISNULL(CONVERT(nvarchar(16), mon.fn_UtcToLocal(h.last_checkdb_utc, @tz), 120), N'never'),
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
                INSERT #Scope VALUES ('BACKUP'), ('INTEGRITY');
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
                       SUM(CASE WHEN f.run_start_utc >= DATEADD(HOUR, -@lookback, @now) THEN 1 ELSE 0 END) OVER (PARTITION BY f.job_id) AS fails
                FROM mon.AgentFailure AS f
                /* not only the event window: a job whose LAST run failed stays open until it succeeds (max N days) */
                WHERE f.run_start_utc >= DATEADD(DAY, -ISNULL(mon.fn_SettingInt('job_failure_max_age_days'), 7), @now)
                  /* the engine itself: cancel by the installer / error 2801 after a redeploy are expected;
                     real engine outages are caught by the ENGINE_STALE watchdog */
                  AND NOT (f.job_name LIKE N'MON - Engine%' AND (f.run_status = 3 OR ISNULL(f.message, N'') LIKE N'%Error 2801%'))
            )
            INSERT #Issue(issue_key, category, severity, is_event, title, detail, event_utc)
            SELECT CONCAT(N'JOBFAIL:', F.job_id), 'AGENT', 'CRITICAL', 0,
                   LEFT(CONCAT(N'Job ', CASE WHEN F.run_status = 3 THEN N'cancelled' ELSE N'failed' END, N': ', F.job_name,
                          CASE WHEN F.fails > 1 THEN CONCAT(N' (', F.fails, N' failures in ', @lookback, N'h)') END), 400),
                   LEFT(CONCAT(N'Last failure ', mon.fn_FmtLocal(F.run_start_utc, @tz),
                               N' (', mon.fn_Duration(DATEDIFF(SECOND, F.run_start_utc, @now)), N' ago; no successful run since)',
                               N'; step ', ISNULL(CONVERT(nvarchar(10), F.failed_step_id), N'?'), N' "', ISNULL(F.failed_step_name, N'(job outcome)'),
                               N'": ', ISNULL(mon.fn_CleanAgentMessage(F.message), N'')), 4000),
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

            /* Running jobs vs 30-day median. [5.6.2] RDS: msdb.dbo.syssessions is not readable (Msg 229), so the
               running list comes from the Agent job-step sessions (VIEW SERVER STATE), plus sysjobactivity rows
               started in the last 2 days and not stopped (covers non-T-SQL steps). */
            CREATE TABLE #Running(job_id uniqueidentifier, start_utc datetime2(0));
            INSERT #Running
            SELECT j.job_id, MIN(j.start_utc)
            FROM (SELECT TRY_CONVERT(uniqueidentifier, TRY_CONVERT(binary(16),
                             SUBSTRING(s.program_name, CHARINDEX(N'(Job 0x', s.program_name) + 5, 34), 1)) AS job_id,
                         mon.fn_ServerToUtc(s.login_time) AS start_utc
                  FROM sys.dm_exec_sessions AS s
                  WHERE s.program_name LIKE N'SQLAgent - TSQL JobStep (Job 0x%') AS j
            WHERE j.job_id IS NOT NULL
            GROUP BY j.job_id;
            BEGIN TRY
                INSERT #Running
                EXEC sys.sp_executesql N'
                    SELECT ja.job_id, MIN(mon.fn_ServerToUtc(ja.start_execution_date))
                    FROM msdb.dbo.sysjobactivity AS ja
                    WHERE ja.start_execution_date >= DATEADD(DAY, -2, GETDATE())
                      AND ja.stop_execution_date IS NULL
                    GROUP BY ja.job_id;';
                /* keep one row per job (earliest start) */
                ;WITH d AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY start_utc) AS rn FROM #Running)
                DELETE FROM d WHERE rn > 1;
            END TRY
            BEGIN CATCH
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
                   CASE WHEN x.outcome = 'CORRUPTION' THEN 'CRITICAL'
                        WHEN x.outcome = 'SKIPPED' THEN 'WARNING'
                        WHEN o.command_type LIKE N'BACKUP%' OR o.command_type LIKE N'DBCC%' OR o.command_type LIKE N'RESTORE%'
                        THEN 'CRITICAL' ELSE 'WARNING' END, 1, o.database_name,
                   LEFT(CASE x.outcome
                        WHEN 'CORRUPTION' THEN CONCAT(N'CHECKDB found CORRUPTION in ', ISNULL(o.database_name, N'?'),
                                                      N' (error ', o.error_number, N') - the check ran and reported damage')
                        WHEN 'SKIPPED' THEN CONCAT(N'Ola ', o.command_type, N' skipped (', CASE o.error_number WHEN 1222 THEN N'lock timeout' ELSE N'deadlock victim' END,
                                                   N'): ', ISNULL(o.database_name, N'?'),
                                                   CASE WHEN o.object_name IS NOT NULL THEN CONCAT(N'.', o.object_name) END,
                                                   CASE WHEN o.index_name IS NOT NULL THEN CONCAT(N' (', o.index_name, N')') END)
                        ELSE CONCAT(N'Ola ', o.command_type, N' failed: ', ISNULL(o.database_name, N'?'),
                                    CASE WHEN o.object_name IS NOT NULL THEN CONCAT(N'.', o.object_name) END,
                                    CASE WHEN o.index_name IS NOT NULL THEN CONCAT(N' (', o.index_name, N')') END,
                                    N' - error ', o.error_number) END, 400),
                   LEFT(CONCAT(N'Started ', mon.fn_FmtLocal(o.start_utc, @tz), N', ran ', mon.fn_Duration(o.duration_s),
                               N' | Error ', o.error_number, N': ', ISNULL(o.error_message, N''),
                               N' | Command: ', ISNULL(o.command, N''), N' | Source: ', o.source_db, N'.dbo.CommandLog ID ', o.ola_id), 4000),
                   o.start_utc
            FROM mon.OlaCommand AS o
            CROSS APPLY (SELECT mon.fn_OlaOutcome(o.command_type, o.error_number) AS outcome) AS x
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
               t.category          = s.category,      /* [5.6.4] re-categorised checks move over (CHECKDB -> INTEGRITY) */
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
