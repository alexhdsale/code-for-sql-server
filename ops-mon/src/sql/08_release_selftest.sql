
/* =============================================================================
   SECTION 15  -  EMAIL STATISTICS + SELF-TEST + RELEASE GATE   [rev 5.4]
   ============================================================================= */
USE [OPS];
GO

/*
   How often does the monitor (and everything else on this server) send email?
     EXEC OPS.mon.usp_ShowEmailStats;              -- last 30 days
     EXEC OPS.mon.usp_ShowEmailStats @Days = 7;
   Result sets:
     1) MON emails per day: alerts / digests / heartbeats / skipped digests / failures / size
     2) MON emails per type over the period (count, per-day average, first / last)
     3) last 100 MON emails (subject, recipients, result)
     4) ALL Database Mail on this server per day, split MON vs other senders (legacy OPS.monitor, jobs, apps)
     5) ALL Database Mail on this server by subject (top 50) - who sends the most
*/
CREATE OR ALTER PROCEDURE mon.usp_ShowEmailStats
    @Days int = 30
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');
    DECLARE @since datetime2(0) = DATEADD(DAY, -@Days, SYSUTCDATETIME());
    DECLARE @n_days decimal(9,2) = CASE WHEN @Days < 1 THEN 1 ELSE @Days END;

    /* 1) per day */
    SELECT CONVERT(date, mon.fn_UtcToLocal(n.created_utc, @tz)) AS [Day (local)],
           SUM(CASE WHEN n.send_ok = 1 THEN 1 ELSE 0 END)                                              AS [Emails sent],
           SUM(CASE WHEN n.notification_type = 'ALERT' AND n.send_ok = 1 THEN 1 ELSE 0 END)            AS [Alerts],
           SUM(CASE WHEN n.notification_type = 'DIGEST' AND n.send_ok = 1 THEN 1 ELSE 0 END)           AS [Digests],
           SUM(CASE WHEN n.notification_type = 'HEARTBEAT' AND n.send_ok = 1 THEN 1 ELSE 0 END)        AS [Heartbeats],
           SUM(CASE WHEN n.notification_type NOT IN ('ALERT', 'DIGEST', 'HEARTBEAT', 'DIGEST_SKIPPED')
                     AND n.send_ok = 1 THEN 1 ELSE 0 END)                                              AS [Other],
           SUM(CASE WHEN n.notification_type = 'DIGEST_SKIPPED' THEN 1 ELSE 0 END)                     AS [Digest skipped (no change)],
           SUM(CASE WHEN n.send_ok = 0 THEN 1 ELSE 0 END)                                              AS [Send failures],
           MAX(n.body_kb)                                                                              AS [Largest KB]
    FROM mon.Notification AS n
    WHERE n.created_utc >= @since
    GROUP BY CONVERT(date, mon.fn_UtcToLocal(n.created_utc, @tz))
    ORDER BY [Day (local)] DESC;

    /* 2) per type */
    SELECT n.notification_type AS [Type],
           SUM(CASE WHEN n.send_ok = 1 THEN 1 ELSE 0 END) AS [Sent],
           SUM(CASE WHEN n.send_ok = 0 THEN 1 ELSE 0 END) AS [Failed],
           COUNT(*) AS [Logged],
           CONVERT(decimal(9,2), COUNT(*) / @n_days) AS [Per day (avg)],
           mon.fn_UtcToLocal(MIN(n.created_utc), @tz) AS [First (local)],
           mon.fn_UtcToLocal(MAX(n.created_utc), @tz) AS [Last (local)]
    FROM mon.Notification AS n
    WHERE n.created_utc >= @since
    GROUP BY n.notification_type
    ORDER BY [Logged] DESC;

    /* 3) last 100 */
    SELECT TOP (100)
           mon.fn_UtcToLocal(n.created_utc, @tz) AS [Time (local)], n.notification_type AS [Type],
           CASE WHEN n.notification_type = 'DIGEST_SKIPPED' THEN 'not sent (no change)'
                WHEN n.send_ok = 1 THEN 'sent' WHEN n.send_ok = 0 THEN 'FAILED' ELSE '?' END AS [Result],
           n.subject AS [Subject], n.recipients AS [Recipients], n.change_count AS [Changes],
           n.active_critical AS [Open CRITICAL], n.active_warning AS [Open WARNING], n.body_kb AS [KB],
           n.mailitem_id AS [Mailitem id], n.error_message AS [Error]
    FROM mon.Notification AS n
    WHERE n.created_utc >= @since
    ORDER BY n.notification_id DESC;

    /* 4) + 5) every Database Mail item on the server (RDS function or msdb view) */
    CREATE TABLE #M (mailitem_id int, subject nvarchar(510), recipients nvarchar(max), sent_status nvarchar(20),
                     send_request_date datetime, sent_date datetime NULL);
    BEGIN TRY
        IF OBJECT_ID(N'msdb.dbo.rds_fn_sysmail_allitems') IS NOT NULL
            EXEC sys.sp_executesql N'INSERT #M SELECT mailitem_id, subject, recipients, CONVERT(nvarchar(20), sent_status), send_request_date, sent_date
                                      FROM msdb.dbo.rds_fn_sysmail_allitems() WHERE send_request_date >= DATEADD(DAY, -@d, GETDATE());',
                                   N'@d int', @d = @Days;
        ELSE
            EXEC sys.sp_executesql N'INSERT #M SELECT mailitem_id, subject, recipients, CONVERT(nvarchar(20), sent_status), send_request_date, sent_date
                                      FROM msdb.dbo.sysmail_allitems WHERE send_request_date >= DATEADD(DAY, -@d, GETDATE());',
                                   N'@d int', @d = @Days;
    END TRY
    BEGIN CATCH
        PRINT CONCAT(N'Database Mail history not readable: ', ERROR_MESSAGE());
    END CATCH;

    SELECT CONVERT(date, m.send_request_date) AS [Day (server time)],
           COUNT(*) AS [All mail items],
           SUM(CASE WHEN x.is_mon = 1 THEN 1 ELSE 0 END) AS [From MON],
           SUM(CASE WHEN x.is_mon = 0 THEN 1 ELSE 0 END) AS [From others (OPS.monitor rev 4, jobs, apps)],
           SUM(CASE WHEN m.sent_status = N'sent' THEN 1 ELSE 0 END) AS [Sent],
           SUM(CASE WHEN m.sent_status = N'failed' THEN 1 ELSE 0 END) AS [Failed],
           SUM(CASE WHEN m.sent_status IN (N'unsent', N'retrying') THEN 1 ELSE 0 END) AS [Unsent / retrying]
    FROM #M AS m
    CROSS APPLY (SELECT CASE WHEN EXISTS (SELECT 1 FROM mon.Notification AS n WHERE n.mailitem_id = m.mailitem_id)
                             THEN 1 ELSE 0 END AS is_mon) AS x
    GROUP BY CONVERT(date, m.send_request_date)
    ORDER BY [Day (server time)] DESC;

    SELECT TOP (50)
           CASE WHEN x.is_mon = 1 THEN 'MON' ELSE 'other' END AS [Sender],
           LEFT(m.subject, CASE WHEN CHARINDEX(N'|', m.subject) > 0 THEN CHARINDEX(N'|', m.subject) - 1 ELSE 80 END) AS [Subject (family)],
           COUNT(*) AS [Emails],
           CONVERT(decimal(9,2), COUNT(*) / @n_days) AS [Per day (avg)],
           SUM(CASE WHEN m.sent_status = N'failed' THEN 1 ELSE 0 END) AS [Failed],
           MAX(m.send_request_date) AS [Last (server time)],
           MAX(LEFT(m.recipients, 200)) AS [Recipients (sample)]
    FROM #M AS m
    CROSS APPLY (SELECT CASE WHEN EXISTS (SELECT 1 FROM mon.Notification AS n WHERE n.mailitem_id = m.mailitem_id)
                             THEN 1 ELSE 0 END AS is_mon) AS x
    GROUP BY CASE WHEN x.is_mon = 1 THEN 'MON' ELSE 'other' END,
             LEFT(m.subject, CASE WHEN CHARINDEX(N'|', m.subject) > 0 THEN CHARINDEX(N'|', m.subject) - 1 ELSE 80 END)
    ORDER BY [Emails] DESC;
END;
GO

/*
   Self-test: is the installed monitor complete and consistent?
     EXEC OPS.mon.usp_SelfTest;               -- safe any time (does not touch running code)
     EXEC OPS.mon.usp_SelfTest @Deep = 1;     -- also re-validates every procedure/function (installer uses this;
                                              -- run it only while the engine is paused, it recompiles modules)
   One row per check: OK / WARN / ERROR. Errors block the release gate.
*/
CREATE OR ALTER PROCEDURE mon.usp_SelfTest
    @Deep       bit = 0,
    @Since      datetime2(0) = NULL,      /* server time: objects created since then must all be in [mon] */
    @Quiet      bit = 0,
    @Errors     int = NULL OUTPUT,
    @Warnings   int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #T (seq int IDENTITY(1,1), check_name nvarchar(100), object_name nvarchar(300) NULL,
                     result varchar(5), detail nvarchar(2000) NULL);
    DECLARE @name nvarchar(300), @type char(2), @sql nvarchar(max);

    /* 1. Required core objects */
    INSERT #T(check_name, object_name, result, detail)
    SELECT N'Required object', r.n,
           CASE WHEN OBJECT_ID(r.n) IS NULL THEN 'ERROR' ELSE 'OK' END,
           CASE WHEN OBJECT_ID(r.n) IS NULL THEN N'missing - re-run the installer' END
    FROM (VALUES (N'mon.Setting'), (N'mon.DatabasePolicy'), (N'mon.DatabaseCheck'), (N'mon.ServerCheck'), (N'mon.CheckCatalog'),
                 (N'mon.CheckChangeLog'), (N'mon.Issue'), (N'mon.IssueChange'), (N'mon.IssueMute'), (N'mon.Notification'),
                 (N'mon.ComponentStatus'), (N'mon.EngineRun'), (N'mon.DatabaseStatus'), (N'mon.BackupStatus'),
                 (N'mon.BackupInventoryDaily'), (N'mon.OlaCommand'), (N'mon.OlaSource'), (N'mon.ReleaseHistory'),
                 (N'mon.vw_BackupHealth'), (N'mon.vw_BackupRetention'), (N'mon.vw_ActiveIssues'),
                 (N'mon.fn_IsCheckEnabled'), (N'mon.fn_Setting'), (N'mon.fn_SettingInt'),
                 (N'mon.usp_EngineLoop'), (N'mon.usp_RunHourly'), (N'mon.usp_EvaluateIssues'), (N'mon.usp_SendAlerts'),
                 (N'mon.usp_SendAlertsCore'), (N'mon.usp_SendDailyDigest'), (N'mon.usp_CloseDisabledIssues'),
                 (N'mon.usp_SetCheck'), (N'mon.usp_ShowChecks'), (N'mon.usp_ShowBackupRetention'),
                 (N'mon.usp_ShowOlaLog'), (N'mon.usp_ShowEmailStats'),
                 (N'mon.usp_SendSummary'), (N'mon.usp_RunScheduledEmails'), (N'mon.usp_AckIssue'), (N'mon.usp_ResolveIssue'), (N'mon.usp_ShowDataRetention')) AS r(n);

    /* 2. Every view in [mon] binds (cheap, no side effects) */
    DECLARE v CURSOR LOCAL FAST_FORWARD FOR
        SELECT QUOTENAME(s.name) + N'.' + QUOTENAME(o.name)
        FROM sys.objects AS o JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE s.name = N'mon' AND o.type = 'V' ORDER BY o.name;
    OPEN v; FETCH NEXT FROM v INTO @name;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N'SELECT TOP (0) * INTO #x FROM ' + @name + N';';
            EXEC sys.sp_executesql @sql;
            INSERT #T(check_name, object_name, result) VALUES (N'View binds', @name, 'OK');
        END TRY
        BEGIN CATCH
            INSERT #T(check_name, object_name, result, detail) VALUES (N'View binds', @name, 'ERROR', ERROR_MESSAGE());
        END CATCH;
        FETCH NEXT FROM v INTO @name;
    END;
    CLOSE v; DEALLOCATE v;

    /* 3. References to [mon] objects that do not exist */
    INSERT #T(check_name, object_name, result, detail)
    SELECT DISTINCT N'Broken reference', QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name), 'ERROR',
           CONCAT(N'references missing object mon.', d.referenced_entity_name)
    FROM sys.sql_expression_dependencies AS d
    JOIN sys.objects AS o ON o.object_id = d.referencing_id
    WHERE SCHEMA_NAME(o.schema_id) = N'mon'
      AND d.referenced_schema_name = N'mon'
      AND d.referenced_database_name IS NULL
      AND d.referenced_id IS NULL
      AND d.referenced_entity_name NOT LIKE N'#%';

    /* 4. Deep: re-validate procedures / functions / triggers (column-level binding). Only while the engine is paused. */
    IF @Deep = 1
    BEGIN
        DECLARE m CURSOR LOCAL FAST_FORWARD FOR
            SELECT QUOTENAME(s.name) + N'.' + QUOTENAME(o.name), o.type
            FROM sys.objects AS o JOIN sys.schemas AS s ON s.schema_id = o.schema_id
            WHERE s.name = N'mon' AND o.type IN ('P', 'FN', 'IF', 'TF', 'TR')
              AND o.object_id <> @@PROCID
            ORDER BY CASE WHEN o.type IN ('FN', 'IF', 'TF') THEN 1 ELSE 2 END, o.name;
        OPEN m; FETCH NEXT FROM m INTO @name, @type;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                EXEC sys.sp_refreshsqlmodule @name = @name;
            END TRY
            BEGIN CATCH
                INSERT #T(check_name, object_name, result, detail) VALUES (N'Module compiles', @name, 'ERROR', ERROR_MESSAGE());
            END CATCH;
            FETCH NEXT FROM m INTO @name, @type;
        END;
        CLOSE m; DEALLOCATE m;
        IF NOT EXISTS (SELECT 1 FROM #T WHERE check_name = N'Module compiles')
            INSERT #T(check_name, object_name, result, detail)
            SELECT N'Module compiles', N'(all procedures / functions / triggers)', 'OK',
                   CONCAT(COUNT(*), N' modules validated')
            FROM sys.objects WHERE SCHEMA_NAME(schema_id) = N'mon' AND type IN ('P', 'FN', 'IF', 'TF', 'TR');
    END;

    /* 5. Nothing created outside [mon] by this release (OPS database) */
    IF @Since IS NOT NULL
        INSERT #T(check_name, object_name, result, detail)
        SELECT N'Created outside [mon]', QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name), 'ERROR',
               CONCAT(o.type_desc, N' created ', CONVERT(varchar(19), o.create_date, 120))
        FROM sys.objects AS o
        WHERE o.create_date >= @Since AND o.is_ms_shipped = 0
          AND SCHEMA_NAME(o.schema_id) <> N'mon'
          AND o.parent_object_id = 0;
    IF NOT EXISTS (SELECT 1 FROM #T WHERE check_name = N'Created outside [mon]')
        INSERT #T(check_name, object_name, result, detail)
        VALUES (N'Created outside [mon]', N'OPS database', 'OK',
                CASE WHEN @Since IS NULL THEN N'not checked (no @Since)' ELSE N'no object outside schema mon' END);

    /* 6. SQL Agent jobs */
    BEGIN TRY
        INSERT #T(check_name, object_name, result, detail)
        SELECT N'Agent job', j.n,
               CASE WHEN sj.job_id IS NULL THEN 'ERROR' WHEN sj.enabled = 0 THEN 'WARN'
                    WHEN NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobschedules AS js
                                     JOIN msdb.dbo.sysschedules AS sc ON sc.schedule_id = js.schedule_id
                                     WHERE js.job_id = sj.job_id AND sc.enabled = 1) THEN 'ERROR'
                    ELSE 'OK' END,
               CASE WHEN sj.job_id IS NULL THEN N'job missing'
                    WHEN sj.enabled = 0 THEN N'job disabled'
                    WHEN NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobschedules AS js
                                     JOIN msdb.dbo.sysschedules AS sc ON sc.schedule_id = js.schedule_id
                                     WHERE js.job_id = sj.job_id AND sc.enabled = 1) THEN N'no enabled schedule' END
        FROM (VALUES (N'MON - Engine'), (N'MON - Digest & Watchdog')) AS j(n)
        LEFT JOIN msdb.dbo.sysjobs AS sj ON sj.name = j.n;
    END TRY
    BEGIN CATCH
        INSERT #T(check_name, object_name, result, detail) VALUES (N'Agent job', N'msdb', 'WARN', ERROR_MESSAGE());
    END CATCH;

    /* 7. Required settings */
    INSERT #T(check_name, object_name, result, detail)
    SELECT N'Setting', r.n,
           CASE WHEN NULLIF(LTRIM(s.setting_value), N'') IS NULL THEN 'ERROR' ELSE 'OK' END,
           CASE WHEN s.setting_name IS NULL THEN N'missing' WHEN NULLIF(LTRIM(s.setting_value), N'') IS NULL THEN N'empty' END
    FROM (VALUES (N'mail_profile'), (N'alert_recipients'), (N'report_recipients'), (N'display_time_zone'), (N'engine_enabled')) AS r(n)
    LEFT JOIN mon.Setting AS s ON s.setting_name = r.n;

    /* 8. Database Mail profile exists */
    BEGIN TRY
        DECLARE @profile sysname = mon.fn_Setting('mail_profile');
        IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @profile)
            INSERT #T(check_name, object_name, result) VALUES (N'Database Mail profile', @profile, 'OK');
        ELSE
            INSERT #T(check_name, object_name, result, detail) VALUES (N'Database Mail profile', @profile, 'ERROR', N'profile not found in msdb.dbo.sysmail_profile');
    END TRY
    BEGIN CATCH
        INSERT #T(check_name, object_name, result, detail) VALUES (N'Database Mail profile', @profile, 'WARN', ERROR_MESSAGE());
    END CATCH;

    /* 9. Every catalog check has a matrix column / server row */
    INSERT #T(check_name, object_name, result, detail)
    SELECT N'Check catalog', c.check_code, 'ERROR',
           CASE WHEN c.scope = 'DATABASE' THEN CONCAT(N'column mon.DatabaseCheck.', c.column_name, N' missing')
                ELSE N'row missing in mon.ServerCheck' END
    FROM mon.CheckCatalog AS c
    WHERE (c.scope = 'DATABASE' AND c.column_name IS NOT NULL AND COL_LENGTH(N'mon.DatabaseCheck', c.column_name) IS NULL)
       OR (c.scope = 'SERVER' AND NOT EXISTS (SELECT 1 FROM mon.ServerCheck AS s WHERE s.check_code = c.check_code));
    IF NOT EXISTS (SELECT 1 FROM #T WHERE check_name = N'Check catalog')
        INSERT #T(check_name, object_name, result) VALUES (N'Check catalog', N'(all checks)', 'OK');

    /* 10. Collector health (informational) */
    INSERT #T(check_name, object_name, result, detail)
    SELECT N'Collector', c.component_name, 'WARN', LEFT(CONCAT(c.consecutive_failures, N' consecutive failures: ', c.last_error_message), 2000)
    FROM mon.ComponentStatus AS c
    WHERE c.consecutive_failures > 0;

    SELECT @Errors = SUM(CASE WHEN result = 'ERROR' THEN 1 ELSE 0 END),
           @Warnings = SUM(CASE WHEN result = 'WARN' THEN 1 ELSE 0 END)
    FROM #T;
    SELECT @Errors = ISNULL(@Errors, 0), @Warnings = ISNULL(@Warnings, 0);

    IF @Quiet = 0
        SELECT result AS [Result], check_name AS [Check], object_name AS [Object], detail AS [Detail]
        FROM #T
        ORDER BY CASE result WHEN 'ERROR' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, seq;
    ELSE
        SELECT result AS [Result], check_name AS [Check], object_name AS [Object], detail AS [Detail]
        FROM #T WHERE result <> 'OK'
        ORDER BY CASE result WHEN 'ERROR' THEN 0 ELSE 1 END, seq;
END;
GO

/* =============================================================================
   RELEASE GATE: self-test, then resume the engine only if everything is valid.
   ============================================================================= */
DECLARE @rid int, @since datetime2(0), @prev_engine nvarchar(20), @version varchar(20), @e int, @w int;
SELECT TOP (1) @rid = release_id, @since = started_server_time, @prev_engine = prev_engine_enabled, @version = version
FROM mon.ReleaseHistory WHERE status = 'INSTALLING' ORDER BY release_id DESC;

EXEC mon.usp_SelfTest @Deep = 1, @Since = @since, @Quiet = 1, @Errors = @e OUTPUT, @Warnings = @w OUTPUT;

IF @e = 0
BEGIN
    UPDATE mon.Setting SET setting_value = ISNULL(@prev_engine, N'1') WHERE setting_name = 'engine_enabled';
    UPDATE mon.ReleaseHistory SET status = 'COMPLETED', finished_utc = SYSUTCDATETIME(), selftest_errors = @e, selftest_warnings = @w
    WHERE release_id = @rid;
    PRINT CONCAT(N'MON ', @version, N' installed: self-test passed (', @w, N' warning(s)). Engine resumed (engine_enabled = ',
                 ISNULL(@prev_engine, N'1'), N'); next run within 1 minute.');
END
ELSE
BEGIN
    UPDATE mon.ReleaseHistory SET status = 'FAILED', finished_utc = SYSUTCDATETIME(), selftest_errors = @e, selftest_warnings = @w,
           notes = N'Self-test failed: engine left paused. Fix the errors listed by EXEC OPS.mon.usp_SelfTest @Deep = 1; and re-run the installer.'
    WHERE release_id = @rid;
    RAISERROR(N'MON %s install FAILED the self-test (%d error(s)). The engine stays PAUSED (engine_enabled = 0) so the previous alerts are not replaced by a broken version. See the result set above, fix, and re-run the installer.', 16, 1, @version, @e);
END;
GO

SELECT TOP (10) release_id, version, status, started_utc, finished_utc, prev_version, installed_by, host_name,
       selftest_errors, selftest_warnings, notes
FROM mon.ReleaseHistory ORDER BY release_id DESC;
GO
