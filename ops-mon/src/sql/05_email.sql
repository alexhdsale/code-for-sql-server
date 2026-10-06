
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

    /* [rev 5.3] never alert on a check that was just switched off */
    BEGIN TRY EXEC mon.usp_CloseDisabledIssues; END TRY BEGIN CATCH END CATCH;

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
              AND i.ack_utc IS NULL                     /* [5.6] acknowledged = someone is on it: no reminders */
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
