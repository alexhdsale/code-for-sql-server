
/* =============================================================================
   SECTION 12b  -  EMAIL SCHEDULE (SUMMARY / FULL REPORT) + ISSUE WORKFLOW   [rev 5.6]

   Three kinds of email:
     1. ISSUE ALERT   (mon.usp_SendAlerts, every engine cycle)   - change-only: sent ONLY when an issue
                      opens / escalates / resolves at or above alert_min_severity. Nothing changed = no email.
     2. SUMMARY       (mon.usp_SendSummary, scheduled)           - short: health KPIs + open issues list.
                      Hours: summary_email_hours_local, days: summary_email_weekdays.
     3. FULL REPORT   (mon.usp_SendDailyDigest, scheduled)       - everything that is monitored.
                      Hours: full_report_hours_local, days: full_report_weekdays,
                      full_report_change_only = 1 sends it only when something changed.
                      Empty full_report_hours_local = legacy mode (one change-only digest per day at report_hour_local).

   Issue workflow: OPEN -> ACKNOWLEDGED (usp_AckIssue: someone is on it, no more reminders)
                        -> RESOLVED automatically when the condition clears (or usp_ResolveIssue, manual;
                           re-opens at the next cycle if the condition still exists).
   ============================================================================= */

INSERT mon.Setting(setting_name, setting_value, value_type, category, description)
SELECT v.n, v.v, v.t, v.c, v.d
FROM (VALUES
    ('summary_email_hours_local', N'8', 'text', 'email',
     N'Local hours (comma list, 0-23) when the SHORT summary email is sent. Empty = no summary emails.'),
    ('summary_email_weekdays', N'1,2,3,4,5,6,7', 'text', 'email',
     N'ISO weekdays for the summary (1 = Monday ... 7 = Sunday).'),
    ('summary_recipients', N'', 'text', 'email',
     N'Recipients of the summary email. Empty = report_recipients.'),
    ('summary_max_issues', N'20', 'int', 'email',
     N'Maximum open issues listed in the summary email (most severe / oldest first).'),
    ('summary_skip_when_full', N'1', 'bit', 'email',
     N'1 = do not send the summary in an hour when the full report is sent anyway.'),
    ('full_report_hours_local', N'8', 'text', 'email',
     N'Local hours (comma list, 0-23) when the FULL report (every monitored item) is sent. Empty = legacy: one change-only digest per day at report_hour_local.'),
    ('full_report_weekdays', N'1,4', 'text', 'email',
     N'ISO weekdays for the full report (1 = Monday ... 7 = Sunday). Default Monday and Thursday.'),
    ('full_report_change_only', N'0', 'bit', 'email',
     N'1 = the scheduled full report is skipped when nothing changed since the previous one; 0 = always sent.'),
    ('retention_perf_days', N'', 'text', 'issues',
     N'Days kept for performance samples (PerfSample, CpuSample, StorageSample, WaitStatsSnapshot, FileStatsSnapshot). Empty = history_retention_days.'),
    ('retention_backup_days', N'', 'text', 'issues',
     N'Days kept for backup evidence (TlogBackup, RdsTask, OlaCommand, BackupInventoryDaily). Empty = history_retention_days.'),
    ('retention_issue_days', N'', 'text', 'issues',
     N'Days kept for RESOLVED issues and their change history (open issues are never purged). Empty = history_retention_days.'),
    ('retention_email_days', N'', 'text', 'issues',
     N'Days kept for the email log (Notification) and engine runs. Empty = history_retention_days.'),
    ('retention_audit_days', N'', 'text', 'issues',
     N'Days kept for the monitoring-change audit (CheckChangeLog). Empty = 4 x history_retention_days.')
) AS v(n, v, t, c, d)
WHERE NOT EXISTS (SELECT 1 FROM mon.Setting AS s WHERE s.setting_name = v.n);
GO

/* Is @value in a comma separated list of integers? ('8, 17' contains 8; '08' = 8; empty list = false) */
CREATE OR ALTER FUNCTION mon.fn_InIntList(@list nvarchar(400), @value int)
RETURNS bit
AS
BEGIN
    DECLARE @s nvarchar(402) = REPLACE(REPLACE(ISNULL(@list, N''), N' ', N''), N';', N',') + N',',
            @p int, @tok nvarchar(20);
    WHILE LEN(@s) > 0
    BEGIN
        SET @p = CHARINDEX(N',', @s);
        SET @tok = LEFT(@s, @p - 1);
        SET @s = SUBSTRING(@s, @p + 1, 400);
        IF @tok <> N'' AND TRY_CONVERT(int, @tok) = @value RETURN 1;
    END;
    RETURN 0;
END;
GO

/* -----------------------------------------------------------------------------
   Issue workflow
   ----------------------------------------------------------------------------- */

/* "I am on it": marks open issues as acknowledged (shown in summary / full report, no reminders). */
CREATE OR ALTER PROCEDURE mon.usp_AckIssue
    @KeyPattern nvarchar(400),            /* issue_key or LIKE pattern, e.g. N'BACKUP:LOG:ops' or N'CHECKDB:%' */
    @Note       nvarchar(1000) = NULL,
    @Unack      bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE mon.Issue
       SET ack_utc  = CASE WHEN @Unack = 1 THEN NULL ELSE SYSUTCDATETIME() END,
           ack_by   = CASE WHEN @Unack = 1 THEN NULL ELSE ORIGINAL_LOGIN() END,
           ack_note = CASE WHEN @Unack = 1 THEN NULL ELSE @Note END
     WHERE is_active = 1 AND issue_key LIKE @KeyPattern;
    PRINT CONCAT(@@ROWCOUNT, N' open issue(s) ', CASE WHEN @Unack = 1 THEN N'un-acknowledged.' ELSE N'acknowledged.' END);
    SELECT issue_id, severity, title, issue_key, workflow_state, ack_by, ack_utc, ack_note
    FROM mon.vw_ActiveIssues WHERE issue_key LIKE @KeyPattern;
END;
GO

/*
   Close open issues by hand after you fixed the cause (e.g. you took the FULL backup that restarts a
   broken log chain and do not want to wait for the next cycle). The engine re-checks every 5 minutes:
   if the condition still exists the issue RE-OPENS (and alerts again). To silence a condition you accept,
   use mon.usp_MuteIssue or switch the check off; to say "I am working on it", use mon.usp_AckIssue.
*/
CREATE OR ALTER PROCEDURE mon.usp_ResolveIssue
    @KeyPattern nvarchar(400),
    @Note       nvarchar(1000)
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(@Note), N'') IS NULL
    BEGIN
        RAISERROR(N'@Note is required: say what was done to resolve the issue.', 16, 1);
        RETURN;
    END;
    DECLARE @now datetime2(0) = SYSUTCDATETIME(), @lock int;
    DECLARE @c TABLE(issue_id bigint, old_sev varchar(10));

    EXEC @lock = sys.sp_getapplock @Resource = N'mon_IssueMerge', @LockMode = 'Exclusive',
                                   @LockOwner = 'Session', @LockTimeout = 30000;
    IF @lock < 0 BEGIN RAISERROR(N'Engine is busy, try again in a few seconds.', 16, 1); RETURN; END;
    BEGIN TRY
        UPDATE mon.Issue
           SET is_active = 0, resolved_utc = @now, close_type = 'MANUAL',
               resolved_by = ORIGINAL_LOGIN(), resolve_note = @Note
        OUTPUT inserted.issue_id, deleted.severity INTO @c(issue_id, old_sev)
        WHERE is_active = 1 AND issue_key LIKE @KeyPattern;

        INSERT mon.IssueChange(issue_id, change_type, old_severity, new_severity, change_utc, alert_status, alert_utc)
        SELECT issue_id, 'RESOLVED', old_sev, NULL, @now, 'SKIPPED', @now FROM @c;
    END TRY
    BEGIN CATCH
        EXEC sys.sp_releaseapplock @Resource = N'mon_IssueMerge', @LockOwner = 'Session';
        THROW;
    END CATCH;
    EXEC sys.sp_releaseapplock @Resource = N'mon_IssueMerge', @LockOwner = 'Session';

    PRINT CONCAT((SELECT COUNT(*) FROM @c), N' issue(s) resolved manually. If the condition still exists they re-open within 5 minutes.');
    SELECT i.issue_id, i.severity, i.title, i.issue_key, i.resolved_by, i.resolved_utc, i.resolve_note
    FROM mon.Issue AS i JOIN @c AS c ON c.issue_id = i.issue_id;
END;
GO

/* KPI tile for the summary email */
CREATE OR ALTER FUNCTION mon.fn_SummaryTile(@label nvarchar(100), @value nvarchar(50), @level varchar(4))
RETURNS nvarchar(max)
AS
BEGIN
    DECLARE @fg varchar(7) = CASE @level WHEN 'CRIT' THEN '#DC2626' WHEN 'WARN' THEN '#D97706' ELSE '#16A34A' END;
    RETURN CONCAT(N'<td width="25%" style="padding:8px;border:1px solid #E5E7EB;text-align:center">',
                  N'<div style="font-size:22px;font-weight:700;color:', @fg, N'">', mon.fn_HtmlEncode(@value), N'</div>',
                  N'<div style="font-size:11px;color:#6B7280">', mon.fn_HtmlEncode(@label), N'</div></td>');
END;
GO

/* -----------------------------------------------------------------------------
   SUMMARY email: short, phone friendly. Health KPIs + every open issue that needs action.
     EXEC OPS.mon.usp_SendSummary @PreviewOnly = 1;   -- returns subject + html, sends nothing
     EXEC OPS.mon.usp_SendSummary;                    -- send now
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_SendSummary
    @PreviewOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    BEGIN TRY EXEC mon.usp_CloseDisabledIssues; END TRY BEGIN CATCH END CATCH;

    DECLARE @now datetime2(0) = SYSUTCDATETIME(), @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @profile sysname = mon.fn_Setting('mail_profile'),
            @recipients nvarchar(4000) = COALESCE(NULLIF(mon.fn_Setting('summary_recipients'), N''), mon.fn_Setting('report_recipients')),
            @server nvarchar(128) = ISNULL(mon.fn_Setting('server_label'), @@SERVERNAME),
            @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time'),
            @tzl nvarchar(20) = ISNULL(mon.fn_Setting('display_time_zone_label'), N'ET'),
            @max int = ISNULL(mon.fn_SettingInt('summary_max_issues'), 20);
    DECLARE @local_now datetime2(0) = mon.fn_UtcToLocal(@now, @tz);

    DECLARE @db_total int, @db_online int, @bk_total int, @bk_ok int,
            @crit int, @warn int, @muted int, @acked int, @new_crit int,
            @opened24 int, @resolved24 int, @mails24 int, @last_cycle datetime2(3), @overall varchar(10);

    SELECT @db_total = COUNT(*), @db_online = SUM(CASE WHEN state_desc = N'ONLINE' THEN 1 ELSE 0 END)
    FROM mon.DatabaseStatus WHERE is_present = 1;

    SELECT @bk_total = COUNT(*),
           @bk_ok = SUM(CASE WHEN full_status IN ('OK', 'NOT_REQUIRED', 'PENDING')
                              AND diff_status IN ('OK', 'NOT_REQUIRED', 'PENDING')
                              AND log_status  IN ('OK', 'NOT_REQUIRED', 'PENDING') THEN 1 ELSE 0 END)
    FROM mon.vw_BackupHealth WHERE is_monitored = 1 AND is_present = 1;

    SELECT @crit     = SUM(CASE WHEN severity = 'CRITICAL' AND is_muted = 0 THEN 1 ELSE 0 END),
           @warn     = SUM(CASE WHEN severity = 'WARNING'  AND is_muted = 0 THEN 1 ELSE 0 END),
           @muted    = SUM(CASE WHEN is_muted = 1 THEN 1 ELSE 0 END),
           @acked    = SUM(CASE WHEN is_muted = 0 AND ack_utc IS NOT NULL THEN 1 ELSE 0 END),
           @new_crit = SUM(CASE WHEN severity = 'CRITICAL' AND is_muted = 0 AND ack_utc IS NULL THEN 1 ELSE 0 END)
    FROM mon.Issue WHERE is_active = 1;

    SELECT @opened24   = SUM(CASE WHEN change_type = 'OPENED' THEN 1 ELSE 0 END),
           @resolved24 = SUM(CASE WHEN change_type = 'RESOLVED' THEN 1 ELSE 0 END)
    FROM mon.IssueChange WHERE change_utc >= DATEADD(HOUR, -24, @now);

    SELECT @mails24 = COUNT(*) FROM mon.Notification WHERE created_utc >= DATEADD(HOUR, -24, @now) AND send_ok = 1;
    SELECT @last_cycle = last_success_utc FROM mon.ComponentStatus WHERE component_name = 'ENGINE_CYCLE';

    SELECT @crit = ISNULL(@crit, 0), @warn = ISNULL(@warn, 0), @muted = ISNULL(@muted, 0), @acked = ISNULL(@acked, 0),
           @new_crit = ISNULL(@new_crit, 0), @opened24 = ISNULL(@opened24, 0), @resolved24 = ISNULL(@resolved24, 0),
           @bk_ok = ISNULL(@bk_ok, 0), @db_online = ISNULL(@db_online, 0);
    SET @overall = CASE WHEN @crit > 0 THEN 'CRITICAL' WHEN @warn > 0 THEN 'WARNING' ELSE 'OK' END;

    DECLARE @color varchar(7) = CASE @overall WHEN 'CRITICAL' THEN '#DC2626' WHEN 'WARNING' THEN '#D97706' ELSE '#16A34A' END;
    DECLARE @subject nvarchar(255) = CONCAT(N'[', @server, N'] Summary ', CONVERT(nvarchar(10), @local_now, 120), N' | ',
            CASE WHEN @overall = 'OK' THEN N'all clear'
                 ELSE CONCAT(@crit, N' critical, ', @warn, N' warning', CASE WHEN @new_crit > 0 THEN CONCAT(N' (', @new_crit, N' critical not acknowledged)') END) END);

    DECLARE @kpi nvarchar(max) = CONCAT(
        N'<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="border-collapse:collapse;margin:10px 0">',
        N'<tr>',
        mon.fn_SummaryTile(N'Critical', CONVERT(nvarchar(20), @crit), CASE WHEN @crit > 0 THEN 'CRIT' ELSE 'OK' END),
        mon.fn_SummaryTile(N'Warning', CONVERT(nvarchar(20), @warn), CASE WHEN @warn > 0 THEN 'WARN' ELSE 'OK' END),
        mon.fn_SummaryTile(N'Databases online', CONCAT(@db_online, N'/', @db_total), CASE WHEN @db_online < @db_total THEN 'CRIT' ELSE 'OK' END),
        mon.fn_SummaryTile(N'Backups OK', CONCAT(@bk_ok, N'/', @bk_total), CASE WHEN @bk_ok < @bk_total THEN 'WARN' ELSE 'OK' END),
        N'</tr></table>',
        N'<div style="font-size:12px;color:#374151;margin:4px 0 12px">',
        N'Last 24 h: <b>', @opened24, N'</b> opened &middot; <b>', @resolved24, N'</b> resolved &middot; ',
        @acked, N' acknowledged &middot; ', @muted, N' muted &middot; ', ISNULL(@mails24, 0), N' emails sent &middot; engine last cycle ',
        CASE WHEN @last_cycle IS NULL THEN N'<b style="color:#DC2626">never</b>'
             WHEN @last_cycle < DATEADD(MINUTE, -15, @now) THEN CONCAT(N'<b style="color:#DC2626">', mon.fn_Duration(DATEDIFF(SECOND, @last_cycle, @now)), N' ago</b>')
             ELSE CONCAT(mon.fn_Duration(DATEDIFF(SECOND, @last_cycle, @now)), N' ago') END,
        N'</div>');

    DECLARE @rows nvarchar(max) = N'';
    SELECT @rows = @rows + CONCAT(
        N'<tr style="border-bottom:1px solid #E5E7EB">',
        N'<td style="padding:6px 6px;vertical-align:top;white-space:nowrap">', mon.fn_Pill(i.severity, mon.fn_SevLevel(i.severity)), N'</td>',
        N'<td style="padding:6px 6px;vertical-align:top;font-size:12px"><b>', mon.fn_HtmlEncode(i.title), N'</b>',
        CASE WHEN i.detail IS NOT NULL THEN CONCAT(N'<br><span style="color:#6B7280">', mon.fn_OneLine(i.detail, 220), N'</span>') END,
        N'<br><span style="color:#9CA3AF;font-size:11px">key: ', mon.fn_HtmlEncode(i.issue_key), N'</span></td>',
        N'<td style="padding:6px 6px;vertical-align:top;font-size:12px;white-space:nowrap">', mon.fn_Duration(DATEDIFF(SECOND, i.first_seen_utc, @now)), N'</td>',
        N'<td style="padding:6px 6px;vertical-align:top;font-size:11px">',
        CASE WHEN i.is_muted = 1 THEN mon.fn_Pill(N'MUTED', 'MUTE')
             WHEN i.ack_utc IS NOT NULL THEN CONCAT(mon.fn_Pill(N'ACK', 'INFO'), N'<br>', mon.fn_HtmlEncode(i.ack_by),
                                                    CASE WHEN i.ack_note IS NOT NULL THEN CONCAT(N': ', mon.fn_OneLine(i.ack_note, 80)) END)
             ELSE mon.fn_Pill(N'NEEDS ACTION', CASE WHEN i.severity = 'CRITICAL' THEN 'CRIT' ELSE 'WARN' END) END,
        N'</td></tr>')
    FROM (SELECT TOP (@max) * FROM mon.Issue
          WHERE is_active = 1
          ORDER BY is_muted, CASE severity WHEN 'CRITICAL' THEN 0 ELSE 1 END, CASE WHEN ack_utc IS NULL THEN 0 ELSE 1 END, first_seen_utc) AS i
    ORDER BY i.is_muted, CASE i.severity WHEN 'CRITICAL' THEN 0 ELSE 1 END, CASE WHEN i.ack_utc IS NULL THEN 0 ELSE 1 END, i.first_seen_utc;

    DECLARE @n_open int = (SELECT COUNT(*) FROM mon.Issue WHERE is_active = 1);
    DECLARE @issues nvarchar(max) = CASE
        WHEN @n_open = 0 THEN N'<div style="padding:14px;background:#F0FDF4;border:1px solid #BBF7D0;border-radius:6px;font-size:13px;color:#166534"><b>All clear.</b> Nothing needs attention.</div>'
        ELSE CONCAT(N'<div style="font-size:13px;font-weight:700;margin:6px 0">Open issues (', @n_open,
                    CASE WHEN @n_open > @max THEN CONCAT(N', first ', @max) END, N')</div>',
                    N'<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="border-collapse:collapse">',
                    N'<tr style="background:#F3F4F6;font-size:11px;color:#374151"><td style="padding:5px 6px">Severity</td><td style="padding:5px 6px">Issue</td><td style="padding:5px 6px">Open for</td><td style="padding:5px 6px">State</td></tr>',
                    @rows, N'</table>') END;

    DECLARE @html nvarchar(max) = CONCAT(
        N'<!DOCTYPE html><html><body style="margin:0;padding:0;background:#F9FAFB;font-family:Segoe UI,Arial,sans-serif">',
        N'<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="max-width:760px;margin:0 auto;background:#FFFFFF">',
        N'<tr><td style="background:', @color, N';color:#FFFFFF;padding:14px 16px">',
        N'<div style="font-size:18px;font-weight:700">', mon.fn_HtmlEncode(@server), N' &middot; ',
        CASE @overall WHEN 'OK' THEN N'All clear' ELSE @overall END, N'</div>',
        N'<div style="font-size:12px;opacity:.9">Summary &middot; ', CONVERT(nvarchar(16), @local_now, 120), N' ', @tzl, N'</div></td></tr>',
        N'<tr><td style="padding:10px 16px">', @kpi, @issues,
        N'<div style="margin-top:14px;font-size:11px;color:#6B7280;line-height:1.5">',
        N'<b>Work an issue:</b> <code>EXEC OPS.mon.usp_AckIssue @KeyPattern = N''&lt;key&gt;'', @Note = N''on it'';</code> &middot; ',
        N'after the fix it resolves automatically within 5 minutes (or <code>EXEC OPS.mon.usp_ResolveIssue @KeyPattern = N''&lt;key&gt;'', @Note = N''what was done'';</code>) &middot; ',
        N'known condition: <code>EXEC OPS.mon.usp_MuteIssue</code>.<br>',
        N'Issue alerts are sent only when something changes. Full report: hours ', ISNULL(NULLIF(mon.fn_Setting('full_report_hours_local'), N''), N'(daily digest)'),
        N', weekdays ', ISNULL(mon.fn_Setting('full_report_weekdays'), N'-'), N'. Run now: <code>EXEC OPS.mon.usp_SendDailyDigest @Force = 1;</code>',
        N'</div></td></tr></table></body></html>');

    IF @PreviewOnly = 1
    BEGIN
        SELECT @subject AS subject, @html AS html_body, DATALENGTH(@html) / 2048 AS body_kb;
        RETURN;
    END;

    DECLARE @mailitem_id int, @importance varchar(6) = CASE WHEN @new_crit > 0 THEN 'High' ELSE 'Normal' END;
    BEGIN TRY
        EXEC msdb.dbo.sp_send_dbmail
             @profile_name = @profile, @recipients = @recipients,
             @subject = @subject, @body = @html, @body_format = 'HTML',
             @importance = @importance, @mailitem_id = @mailitem_id OUTPUT;
        INSERT mon.Notification(notification_type, created_utc, report_date_local, subject, recipients, mailitem_id,
                                send_ok, active_critical, active_warning, body_kb)
        VALUES ('SUMMARY', @now, CONVERT(date, @local_now), @subject, @recipients, @mailitem_id, 1, @crit, @warn, DATALENGTH(@html) / 2048);
        EXEC mon.usp_SetComponentStatus 'SUMMARY_MAIL', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @em nvarchar(2000) = ERROR_MESSAGE(), @en int = ERROR_NUMBER();
        INSERT mon.Notification(notification_type, created_utc, report_date_local, subject, recipients, send_ok, error_message)
        VALUES ('SUMMARY', @now, CONVERT(date, @local_now), @subject, @recipients, 0, @em);
        EXEC mon.usp_SetComponentStatus 'SUMMARY_MAIL', 0, @started, @en, @em;
    END CATCH;
END;
GO


/* -----------------------------------------------------------------------------
   Scheduler (called by the hourly job "MON - Digest & Watchdog" at :02).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_RunScheduledEmails
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(0) = SYSUTCDATETIME(),
            @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');
    DECLARE @local_now datetime2(0) = mon.fn_UtcToLocal(@now, @tz);
    DECLARE @hour int = DATEPART(HOUR, @local_now),
            @iso_wd int = (DATEPART(WEEKDAY, @local_now) + @@DATEFIRST - 2) % 7 + 1;   /* 1 = Monday */
    DECLARE @full_hours nvarchar(400) = mon.fn_Setting('full_report_hours_local'),
            @full_due bit = 0, @full_sent bit = 0;

    /* FULL REPORT */
    IF NULLIF(LTRIM(@full_hours), N'') IS NULL
    BEGIN
        EXEC mon.usp_SendDailyDigest;                 /* legacy: once a day at report_hour_local, change-only */
    END
    ELSE IF mon.fn_InIntList(@full_hours, @hour) = 1
        AND mon.fn_InIntList(ISNULL(mon.fn_Setting('full_report_weekdays'), N'1,2,3,4,5,6,7'), @iso_wd) = 1
        AND NOT EXISTS (SELECT 1 FROM mon.Notification
                        WHERE notification_type IN ('DIGEST', 'HEARTBEAT', 'DIGEST_SKIPPED')
                          AND created_utc >= DATEADD(MINUTE, -50, @now))
    BEGIN
        SET @full_due = 1;
        IF ISNULL(mon.fn_SettingInt('full_report_change_only'), 0) = 1
            EXEC mon.usp_SendDailyDigest @Scheduled = 1;    /* skipped (DIGEST_SKIPPED) when nothing changed */
        ELSE
            EXEC mon.usp_SendDailyDigest @Force = 1;
        IF EXISTS (SELECT 1 FROM mon.Notification WHERE notification_type IN ('DIGEST', 'HEARTBEAT')
                   AND send_ok = 1 AND created_utc >= DATEADD(MINUTE, -50, @now))
            SET @full_sent = 1;
    END;

    /* SUMMARY */
    IF mon.fn_InIntList(mon.fn_Setting('summary_email_hours_local'), @hour) = 1
       AND mon.fn_InIntList(ISNULL(mon.fn_Setting('summary_email_weekdays'), N'1,2,3,4,5,6,7'), @iso_wd) = 1
       AND NOT (@full_sent = 1 AND ISNULL(mon.fn_SettingInt('summary_skip_when_full'), 1) = 1)
       AND NOT EXISTS (SELECT 1 FROM mon.Notification
                       WHERE notification_type = 'SUMMARY' AND send_ok = 1 AND created_utc >= DATEADD(MINUTE, -50, @now))
        EXEC mon.usp_SendSummary;
END;
GO

/*
   How much data does the monitor keep, and for how long?
     EXEC OPS.mon.usp_ShowDataRetention;
*/
CREATE OR ALTER PROCEDURE mon.usp_ShowDataRetention
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @days int = ISNULL(mon.fn_SettingInt('history_retention_days'), 90);
    SELECT t.name AS [Table],
           r.area AS [Area],
           CASE WHEN r.setting_name IS NULL THEN N'kept (configuration / current state)'
                ELSE CONCAT(COALESCE(TRY_CONVERT(int, NULLIF(s.setting_value, N'')),
                                     CASE r.setting_name WHEN 'retention_audit_days' THEN 4 * @days
                                                         WHEN 'blocking_sample_retention_days' THEN 30 ELSE @days END), N' days (', r.setting_name,
                            CASE WHEN NULLIF(s.setting_value, N'') IS NULL AND r.setting_name NOT IN ('history_retention_days', 'blocking_sample_retention_days')
                                 THEN N' = default' ELSE N'' END, N')') END AS [Retention],
           SUM(CASE WHEN p.index_id IN (0, 1) THEN p.row_count ELSE 0 END) AS [Rows],
           CONVERT(decimal(19,1), SUM(p.reserved_page_count) * 8 / 1024.0) AS [Reserved MB]
    FROM sys.tables AS t
    JOIN sys.dm_db_partition_stats AS p ON p.object_id = t.object_id
    LEFT JOIN (VALUES
        (N'PerfSample', 'retention_perf_days', N'performance'), (N'CpuSample', 'retention_perf_days', N'performance'),
        (N'StorageSample', 'retention_perf_days', N'performance'), (N'WaitStatsSnapshot', 'retention_perf_days', N'performance'),
        (N'FileStatsSnapshot', 'retention_perf_days', N'performance'),
        (N'TlogBackup', 'retention_backup_days', N'backups'), (N'RdsTask', 'retention_backup_days', N'backups'),
        (N'OlaCommand', 'retention_backup_days', N'backups'), (N'BackupInventoryDaily', 'retention_backup_days', N'backups'),
        (N'Issue', 'retention_issue_days', N'issues (resolved only)'), (N'IssueChange', 'retention_issue_days', N'issues (resolved only)'),
        (N'Notification', 'retention_email_days', N'email log'), (N'EngineRun', 'retention_email_days', N'engine runs'),
        (N'CheckChangeLog', 'retention_audit_days', N'audit'),
        (N'BlockingSample', 'blocking_sample_retention_days', N'blocking'), (N'BlockingEpisode', 'history_retention_days', N'blocking'),
        (N'AgentJobRun', 'history_retention_days', N'agent'), (N'AgentFailure', 'history_retention_days', N'agent'),
        (N'Deadlock', 'history_retention_days', N'events'), (N'ErrorLogEvent', 'history_retention_days', N'events'),
        (N'LoginFailure', 'history_retention_days', N'events'), (N'IssueMute', 'history_retention_days', N'mutes (expired)')
    ) AS r(table_name, setting_name, area) ON r.table_name = t.name
    LEFT JOIN mon.Setting AS s ON s.setting_name = r.setting_name
    WHERE SCHEMA_NAME(t.schema_id) = N'mon'
    GROUP BY t.name, r.area, r.setting_name, s.setting_value
    ORDER BY [Reserved MB] DESC, t.name;
END;
GO
