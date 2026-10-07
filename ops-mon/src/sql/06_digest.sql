
/* =============================================================================
   SECTION 11  -  DAILY DIGEST / WEEKLY HEARTBEAT  (change-only)
   Due from report_hour_local (DST aware) once per local day. Sent only if at
   least one issue OPENED / ESCALATED / DEESCALATED / RESOLVED since the last
   digest; otherwise logged as DIGEST_SKIPPED. On heartbeat_weekday a digest is
   sent even without changes. @Force = 1 sends now; @PreviewOnly = 1 returns HTML.
   ============================================================================= */
CREATE OR ALTER PROCEDURE mon.usp_SendDailyDigest
    @Force       bit = 0,
    @PreviewOnly bit = 0,
    @Scheduled   bit = 0      /* [5.6] called by usp_RunScheduledEmails at a scheduled hour: skip the once-a-day gate, keep change-only */
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

    /* [rev 5.3] checks switched off since the last engine cycle must not appear in this digest */
    BEGIN TRY EXEC mon.usp_CloseDisabledIssues; END TRY BEGIN CATCH END CATCH;

    BEGIN TRY
        /* ---------------- due / change-only decision ---------------- */
        IF @Force = 0 AND @PreviewOnly = 0 AND @Scheduled = 0
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
                                       THEN CONCAT(mon.fn_Pill(CASE mon.fn_OlaOutcome(N'DBCC_CHECKDB', h.checkdb_last_error)
                                                                    WHEN 'CORRUPTION' THEN CONCAT(N'CORRUPTION FOUND ', h.checkdb_last_error)
                                                                    ELSE CONCAT(N'CHECKDB DID NOT COMPLETE ', h.checkdb_last_error) END, 'CRIT'), N'<br>') END,
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
                   mon.fn_Td(CONCAT(mon.fn_Pill(CASE f.run_status WHEN 3 THEN N'CANCELLED' ELSE N'FAILED' END, 'CRIT'),
                                    CASE WHEN f.run_start_utc < @window_start THEN CONCAT(N'<br>', mon.fn_Pill(N'STILL FAILED', 'WARN')) END), NULL),
                   mon.fn_Td(mon.fn_HtmlEncode(CONCAT(ISNULL(CONVERT(nvarchar(5), f.failed_step_id), N'?'), N'. ', ISNULL(f.failed_step_name, N'(job outcome)'))), NULL),
                   mon.fn_Td(mon.fn_Nw(mon.fn_FmtLocal(f.run_start_utc, @tz)), NULL),
                   mon.fn_Td(mon.fn_Duration(f.duration_s), NULL),
                   mon.fn_Td(mon.fn_Small(mon.fn_OneLine(mon.fn_CleanAgentMessage(f.message), 500)), NULL),
                   N'</tr>')
            FROM mon.AgentFailure AS f
            WHERE NOT (f.job_name LIKE N'MON - Engine%' AND (f.run_status = 3 OR ISNULL(f.message, N'') LIKE N'%Error 2801%'))
              AND (f.run_start_utc >= @window_start
               /* older failure of a job whose last run is still failed (e.g. unscheduled job, nobody re-ran it) */
               OR (f.run_start_utc >= DATEADD(DAY, -ISNULL(NULLIF(mon.fn_SettingInt('job_failure_max_age_days'), 0), 36500), @now)
                   AND f.instance_id = (SELECT MAX(r.instance_id) FROM mon.AgentJobRun AS r WHERE r.job_id = f.job_id)))
            ORDER BY f.run_start_utc DESC
            FOR XML PATH(''), TYPE
        ).value('(./text())[1]', 'nvarchar(max)');
        SET @body += mon.fn_Section(CONCAT(N'SQL Agent failures - last ', @lookback, N'h + jobs still failed'),
            CONCAT(N'All jobs, with the step that actually failed. STILL FAILED = older failure and the job has not succeeded since',
                   CASE WHEN ISNULL(mon.fn_SettingInt('job_failure_max_age_days'), 0) > 0
                        THEN CONCAT(N' (up to ', mon.fn_Setting('job_failure_max_age_days'), N' days)') END, N'.'),
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
                       mon.fn_Td(CASE WHEN x.corrupt + x.failed + x.skipped = 0 THEN N'0'
                                      ELSE CONCAT(CASE WHEN x.corrupt > 0 THEN CONCAT(mon.fn_Pill(CONCAT(x.corrupt, N' CORRUPTION'), 'CRIT'), N' ') END,
                                                  CASE WHEN x.failed > 0 THEN CONCAT(mon.fn_Pill(CONCAT(x.failed, N' FAILED'), 'CRIT'), N' ') END,
                                                  CASE WHEN x.skipped > 0 THEN mon.fn_Pill(CONCAT(x.skipped, N' SKIPPED'), 'WARN') END) END,
                                 CASE WHEN x.corrupt + x.failed > 0 THEN 'CRIT' WHEN x.skipped > 0 THEN 'WARN' END),
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
                           SUM(CASE WHEN mon.fn_OlaOutcome(o.command_type, o.error_number) = 'CORRUPTION' THEN 1 ELSE 0 END) AS corrupt,
                           SUM(CASE WHEN mon.fn_OlaOutcome(o.command_type, o.error_number) = 'FAILED' THEN 1 ELSE 0 END) AS failed,
                           SUM(CASE WHEN mon.fn_OlaOutcome(o.command_type, o.error_number) = 'SKIPPED' THEN 1 ELSE 0 END) AS skipped,
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
                ORDER BY x.corrupt DESC, x.failed DESC, x.skipped DESC, x.total_s DESC
                FOR XML PATH(''), TYPE
            ).value('(./text())[1]', 'nvarchar(max)');
            SET @body += mon.fn_Section(CONCAT(N'Ola Hallengren maintenance (CommandLog) - last ', @lookback, N'h'),
                CONCAT(N'Every command logged by DatabaseBackup / DatabaseIntegrityCheck / IndexOptimize in ',
                       ISNULL((SELECT TOP (1) CONCAT(database_name, N'.dbo.CommandLog') FROM mon.OlaSource WHERE is_active = 1 ORDER BY last_read_utc DESC), N'(not found)'),
                       N'. Details: EXEC OPS.mon.usp_ShowOlaLog;'),
                N'Command type|Commands|Problems|Unfinished|DBs|Total time|Longest|Backup files|Last start',
                ISNULL(@rows, mon.fn_EmptyRow(9, N'No Ola commands in the window.')));

            SET @rows =
            (
                SELECT TOP (@cap) CONCAT(N'<tr>',
                       mon.fn_Td(mon.fn_Nw(mon.fn_FmtLocal(o.start_utc, @tz)), 'CRIT'),
                       mon.fn_Td(CONCAT(N'<b>', mon.fn_HtmlEncode(ISNULL(o.database_name, N'?')), N'</b>',
                                        mon.fn_Small(CONCAT(N'<br>', mon.fn_HtmlEncode(CONCAT(o.object_name, CASE WHEN o.index_name IS NOT NULL THEN CONCAT(N' / ', o.index_name) END))))), NULL),
                       mon.fn_Td(CONCAT(mon.fn_HtmlEncode(o.command_type), N'<br>',
                                        mon.fn_Pill(CASE mon.fn_OlaOutcome(o.command_type, o.error_number)
                                                         WHEN 'CORRUPTION' THEN N'CORRUPTION FOUND' WHEN 'SKIPPED' THEN N'SKIPPED' ELSE N'FAILED' END,
                                                    CASE mon.fn_OlaOutcome(o.command_type, o.error_number) WHEN 'SKIPPED' THEN 'WARN' ELSE 'CRIT' END)), NULL),
                       mon.fn_Td(CONVERT(nvarchar(10), o.error_number), NULL),
                       mon.fn_Td(mon.fn_Small(mon.fn_OneLine(o.error_message, 400)), NULL),
                       N'</tr>')
                FROM mon.OlaCommand AS o
                WHERE o.start_utc >= @window_start AND ISNULL(o.error_number, 0) <> 0
                ORDER BY o.start_utc DESC
                FOR XML PATH(''), TYPE
            ).value('(./text())[1]', 'nvarchar(max)');
            IF @rows IS NOT NULL
                SET @body += mon.fn_Section(N'Ola Hallengren - commands with errors',
                    N'CORRUPTION FOUND = DBCC CHECKDB ran to the end and REPORTED damage (restore / repair needed, not an Ola problem). '
                    + N'SKIPPED = could not get a lock in time (1222) or deadlock victim (1205); the object is retried next run. FAILED = anything else.',
                    N'Start|Database / object|Command / outcome|Error|Message', @rows);
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
            CONCAT(N'<b>Delivery:</b> ',
                   CASE WHEN NULLIF(mon.fn_Setting('full_report_hours_local'), N'') IS NULL
                        THEN CONCAT(N'this digest is sent once a day only when an issue opened, resolved or changed severity, plus a weekly heartbeat (ISO weekday ', @hb_day, N'). ')
                        ELSE CONCAT(N'this full report is scheduled at ', mon.fn_Setting('full_report_hours_local'), N':00 on ISO weekdays ',
                                    mon.fn_Setting('full_report_weekdays'), N'; a short summary goes out at ', ISNULL(NULLIF(mon.fn_Setting('summary_email_hours_local'), N''), N'-'), N':00. ') END,
                   N'Issue alerts are sent immediately and only when something changes.<br>',
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
