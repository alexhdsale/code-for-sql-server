/* =============================================================================
   SECTION 12c  -  "MON - TempDB RCSI" EMAIL   [rev 5.8]
   Separate daily email (tempdb_report_hours_local, default 08:00 local):
     - yesterday vs the previous day vs a 7-day baseline (avg / p95 / max per metric)
     - BEFORE vs AFTER the RCSI cutover (mon.RcsiCutover; rcsi_compare_days before, everything after)
     - version store per database, top row-version generators, top tempdb consumers,
       hourly profile, tempdb files + autogrowth, tempdb I/O
     EXEC OPS.mon.usp_SendTempdbReport @PreviewOnly = 1;                -- yesterday, html only
     EXEC OPS.mon.usp_SendTempdbReport @Date = '2026-10-20';            -- a specific local day
     EXEC OPS.mon.usp_SendTempdbReport @Force = 1;                      -- send now
   ============================================================================= */
USE [OPS];
GO

CREATE OR ALTER FUNCTION mon.fn_FmtMb(@mb decimal(19,2))
RETURNS nvarchar(30)
AS
BEGIN
    RETURN CASE WHEN @mb IS NULL THEN N'-'
                WHEN ABS(@mb) >= 1048576 THEN CONCAT(CONVERT(decimal(19,2), @mb / 1048576.0), N' TB')
                WHEN ABS(@mb) >= 1024 THEN CONCAT(CONVERT(decimal(19,2), @mb / 1024.0), N' GB')
                WHEN ABS(@mb) >= 10 THEN CONCAT(CONVERT(int, ROUND(@mb, 0)), N' MB')
                ELSE CONCAT(CONVERT(decimal(9,1), @mb), N' MB') END;
END;
GO

/* Relative change as a colored badge. @bad_up = 1: growth is bad (tempdb used, version store); 0 = neutral (blue). */
CREATE OR ALTER FUNCTION mon.fn_DeltaPill(@new decimal(19,2), @old decimal(19,2), @bad_up bit)
RETURNS nvarchar(max)
AS
BEGIN
    IF @new IS NULL OR @old IS NULL RETURN mon.fn_Pill(N'n/a', 'NA');
    IF @old = 0 AND @new = 0 RETURN mon.fn_Pill(N'0%', 'NA');
    IF @old = 0 RETURN mon.fn_Pill(N'new', CASE WHEN @bad_up = 1 THEN 'WARN' ELSE 'INFO' END);
    DECLARE @pct decimal(9,1) = (@new - @old) * 100.0 / @old;
    DECLARE @txt nvarchar(20) = CONCAT(CASE WHEN @pct > 0 THEN N'+' ELSE N'' END, CONVERT(int, ROUND(@pct, 0)), N'%');
    IF ABS(@pct) < 5 RETURN mon.fn_Pill(@txt, 'NA');
    IF @bad_up = 0 RETURN mon.fn_Pill(@txt, 'INFO');
    RETURN mon.fn_Pill(@txt, CASE WHEN @pct >= 50 THEN 'CRIT' WHEN @pct >= 20 THEN 'WARN' WHEN @pct <= -20 THEN 'OK' ELSE 'NA' END);
END;
GO

/* Horizontal bar (0-100 %) that renders in Outlook: a two-cell table. */
CREATE OR ALTER FUNCTION mon.fn_Bar(@pct int, @color varchar(7), @label nvarchar(40))
RETURNS nvarchar(max)
AS
BEGIN
    IF @pct IS NULL SET @pct = 0;
    IF @pct < 0 SET @pct = 0;
    IF @pct > 100 SET @pct = 100;
    DECLARE @w int = CASE WHEN @pct = 0 THEN 1 ELSE @pct END;
    RETURN CONCAT(CONVERT(nvarchar(max), N'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse"><tr>'),
                  N'<td width="', @w, N'%" bgcolor="', @color, N'" style="background:', @color, N';height:12px;line-height:12px;font-size:1px">&nbsp;</td>',
                  N'<td width="', 100 - @w, N'%" style="font-size:11px;padding-left:6px;white-space:nowrap;color:#374151">', mon.fn_HtmlEncode(@label), N'</td>',
                  N'</tr></table>');
END;
GO

CREATE OR ALTER PROCEDURE mon.usp_SendTempdbReport
    @Date        date = NULL,          /* local day to report; default yesterday */
    @PreviewOnly bit  = 0,
    @Force       bit  = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    DECLARE @now datetime2(0) = SYSUTCDATETIME(), @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @profile sysname = mon.fn_Setting('mail_profile'),
            @recipients nvarchar(4000) = COALESCE(NULLIF(mon.fn_Setting('tempdb_report_recipients'), N''), mon.fn_Setting('report_recipients')),
            @server nvarchar(128) = ISNULL(mon.fn_Setting('server_label'), @@SERVERNAME),
            @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time'),
            @tzl nvarchar(20) = ISNULL(mon.fn_Setting('display_time_zone_label'), N'ET'),
            @cmp_days int = ISNULL(mon.fn_SettingInt('rcsi_compare_days'), 7),
            @vs_warn int = ISNULL(mon.fn_SettingInt('tempdb_vs_warn_pct'), 50),
            @vs_crit int = ISNULL(mon.fn_SettingInt('tempdb_vs_crit_pct'), 75),
            @tr_warn int = ISNULL(mon.fn_SettingInt('vs_tran_warn_minutes'), 30),
            @tr_crit int = ISNULL(mon.fn_SettingInt('vs_tran_crit_minutes'), 120),
            @gr_warn int = ISNULL(mon.fn_SettingInt('tempdb_growth_warn_per_hour'), 10),
            @rows_cap int = ISNULL(mon.fn_SettingInt('email_max_rows_per_section'), 40);
    DECLARE @local_now datetime2(0) = mon.fn_UtcToLocal(@now, @tz);
    IF @Date IS NULL SET @Date = DATEADD(DAY, -1, CONVERT(date, @local_now));

    IF @Force = 0 AND @PreviewOnly = 0 AND ISNULL(mon.fn_SettingInt('tempdb_report_enabled'), 1) = 0 RETURN;

    /* local day -> UTC window */
    DECLARE @d0 datetime2(0) = CONVERT(datetime2(0), (CONVERT(datetime2(0), @Date) AT TIME ZONE @tz) AT TIME ZONE 'UTC'),
            @d1 datetime2(0) = CONVERT(datetime2(0), (CONVERT(datetime2(0), DATEADD(DAY, 1, @Date)) AT TIME ZONE @tz) AT TIME ZONE 'UTC');
    DECLARE @prev date = DATEADD(DAY, -1, @Date);

    /* make sure the day (and any missing earlier day) is aggregated */
    BEGIN TRY EXEC mon.usp_SnapshotTempdbDaily; END TRY BEGIN CATCH END CATCH;
    IF NOT EXISTS (SELECT 1 FROM mon.TempdbDaily WHERE report_date = @Date)
       AND EXISTS (SELECT 1 FROM mon.TempdbSample WHERE sample_utc >= @d0 AND sample_utc < @d1)
    BEGIN
        BEGIN TRY EXEC mon.usp_SnapshotTempdbDaily @Date = @Date; END TRY BEGIN CATCH END CATCH;
    END;

    DECLARE @n_samples int = (SELECT ISNULL(samples, 0) FROM mon.TempdbDaily WHERE report_date = @Date);
    IF ISNULL(@n_samples, 0) = 0
    BEGIN
        IF @PreviewOnly = 1
            SELECT CONCAT(N'[', @server, N'] MON - TempDB RCSI ', CONVERT(nvarchar(10), @Date, 120), N' | no samples') AS subject, N'' AS html_body, 0 AS body_kb;
        ELSE
            INSERT mon.Notification(notification_type, created_utc, report_date_local, change_count)
            VALUES ('TEMPDB_SKIPPED', @now, @Date, 0);
        RETURN;
    END;

    /* ---------------- 1. daily comparison: yesterday / previous day / 7-day baseline ---------------- */
    CREATE TABLE #M (sort int, metric nvarchar(60), unit char(3), bad_up bit,
                     y_avg decimal(19,2) NULL, y_p95 decimal(19,2) NULL, y_max decimal(19,2) NULL,
                     p_avg decimal(19,2) NULL, p_p95 decimal(19,2) NULL, p_max decimal(19,2) NULL,
                     b_max decimal(19,2) NULL, b_days int NULL);
    ;WITH Y AS (SELECT * FROM mon.TempdbDaily WHERE report_date = @Date),
          P AS (SELECT * FROM mon.TempdbDaily WHERE report_date = @prev),
          B AS (SELECT COUNT(*) AS n, AVG(used_max_mb) AS used_max, AVG(used_p95_mb) AS used_p95, AVG(vs_max_mb) AS vs_max,
                       AVG(user_obj_max_mb) AS uo_max, AVG(internal_obj_max_mb) AS io_max, AVG(size_max_mb) AS size_max,
                       AVG(CONVERT(decimal(19,2), vs_tran_max_s)) AS tran_max, AVG(CONVERT(decimal(19,2), vs_active_tran_max)) AS atr_max,
                       AVG(CONVERT(decimal(19,2), sessions_max)) AS sess_max, AVG(top_session_max_mb) AS top_max,
                       AVG(log_used_max_pct) AS log_max, AVG(CONVERT(decimal(19,2), io_write_mb)) AS wr_mb, AVG(CONVERT(decimal(19,2), io_read_mb)) AS rd_mb,
                       AVG(io_write_ms_avg) AS wr_ms, AVG(io_read_ms_avg) AS rd_ms, AVG(CONVERT(decimal(19,2), growth_events)) AS growth
                FROM mon.TempdbDaily WHERE report_date BETWEEN DATEADD(DAY, -8, @Date) AND DATEADD(DAY, -2, @Date))
    INSERT #M(sort, metric, unit, bad_up, y_avg, y_p95, y_max, p_avg, p_p95, p_max, b_max, b_days)
    SELECT v.sort, v.metric, v.unit, v.bad_up, v.y_avg, v.y_p95, v.y_max, v.p_avg, v.p_p95, v.p_max, v.b_max, B.n
    FROM Y LEFT JOIN P ON 1 = 1 CROSS JOIN B
    CROSS APPLY (VALUES
        (10, N'tempdb used',             'MB ', 1, Y.used_avg_mb, Y.used_p95_mb, Y.used_max_mb, P.used_avg_mb, P.used_p95_mb, P.used_max_mb, B.used_max),
        (20, N'Version store',           'MB ', 1, Y.vs_avg_mb, Y.vs_p95_mb, Y.vs_max_mb, P.vs_avg_mb, P.vs_p95_mb, P.vs_max_mb, B.vs_max),
        (30, N'User objects',            'MB ', 1, Y.user_obj_avg_mb, NULL, Y.user_obj_max_mb, P.user_obj_avg_mb, NULL, P.user_obj_max_mb, B.uo_max),
        (40, N'Internal objects',        'MB ', 1, Y.internal_obj_avg_mb, NULL, Y.internal_obj_max_mb, P.internal_obj_avg_mb, NULL, P.internal_obj_max_mb, B.io_max),
        (50, N'tempdb size (allocated)', 'MB ', 1, NULL, NULL, Y.size_max_mb, NULL, NULL, P.size_max_mb, B.size_max),
        (60, N'Longest versioning tran', 'SEC', 1, NULL, NULL, Y.vs_tran_max_s, NULL, NULL, P.vs_tran_max_s, B.tran_max),
        (70, N'Versioning transactions', 'NUM', 1, NULL, NULL, Y.vs_active_tran_max, NULL, NULL, P.vs_active_tran_max, B.atr_max),
        (80, N'Sessions using tempdb (>= 1 MB)', 'NUM', 0, NULL, NULL, Y.sessions_max, NULL, NULL, P.sessions_max, B.sess_max),
        (90, N'Largest single session', 'MB ', 1, NULL, NULL, Y.top_session_max_mb, NULL, NULL, P.top_session_max_mb, B.top_max),
        (100, N'tempdb log used %',      'PCT', 1, NULL, NULL, Y.log_used_max_pct, NULL, NULL, P.log_used_max_pct, B.log_max),
        (110, N'Written to tempdb (day total)', 'MB ', 0, NULL, NULL, Y.io_write_mb, NULL, NULL, P.io_write_mb, B.wr_mb),
        (120, N'Read from tempdb (day total)',  'MB ', 0, NULL, NULL, Y.io_read_mb, NULL, NULL, P.io_read_mb, B.rd_mb),
        (130, N'tempdb write latency (avg)',    'MS ', 1, NULL, NULL, Y.io_write_ms_avg, NULL, NULL, P.io_write_ms_avg, B.wr_ms),
        (140, N'tempdb read latency (avg)',     'MS ', 1, NULL, NULL, Y.io_read_ms_avg, NULL, NULL, P.io_read_ms_avg, B.rd_ms),
        (150, N'Autogrowth events',      'NUM', 1, NULL, NULL, Y.growth_events, NULL, NULL, P.growth_events, B.growth)
    ) AS v(sort, metric, unit, bad_up, y_avg, y_p95, y_max, p_avg, p_p95, p_max, b_max);

    DECLARE @b_days int = ISNULL((SELECT MAX(b_days) FROM #M), 0);

    DECLARE @cmp_rows nvarchar(max) = N'';
    SELECT @cmp_rows = @cmp_rows + CONCAT(N'<tr>',
        mon.fn_Td(mon.fn_HtmlEncode(m.metric), NULL),
        mon.fn_Td(mon.fn_Nw(x.y), CASE WHEN m.sort = 20 AND y_max_pct >= @vs_crit THEN 'CRIT' WHEN m.sort = 20 AND y_max_pct >= @vs_warn THEN 'WARN'
                                       WHEN m.sort = 60 AND m.y_max >= @tr_crit * 60 THEN 'CRIT' WHEN m.sort = 60 AND m.y_max >= @tr_warn * 60 THEN 'WARN'
                                       ELSE NULL END),
        mon.fn_Td(mon.fn_Nw(x.p), NULL),
        mon.fn_Td(mon.fn_DeltaPill(m.y_max, m.p_max, m.bad_up), NULL),
        mon.fn_Td(mon.fn_Nw(x.b), NULL),
        mon.fn_Td(mon.fn_DeltaPill(m.y_max, m.b_max, m.bad_up), NULL),
        N'</tr>')
    FROM #M AS m
    CROSS APPLY (SELECT CONVERT(decimal(9,1), m.y_max * 100.0 / NULLIF((SELECT size_max_mb FROM mon.TempdbDaily WHERE report_date = @Date), 0)) AS y_max_pct) AS pc
    CROSS APPLY (SELECT
        CASE m.unit WHEN 'MB ' THEN CONCAT(CASE WHEN m.y_avg IS NOT NULL THEN CONCAT(N'avg ', mon.fn_FmtMb(m.y_avg), N' &middot; ') ELSE N'' END,
                                           CASE WHEN m.y_p95 IS NOT NULL THEN CONCAT(N'p95 ', mon.fn_FmtMb(m.y_p95), N' &middot; ') ELSE N'' END,
                                           N'<b>max ', mon.fn_FmtMb(m.y_max), N'</b>')
                    WHEN 'SEC' THEN CONCAT(N'<b>', mon.fn_Duration(CONVERT(bigint, m.y_max)), N'</b>')
                    WHEN 'MS ' THEN CONCAT(N'<b>', ISNULL(CONVERT(nvarchar(20), CONVERT(decimal(9,1), m.y_max)), N'-'), N' ms</b>')
                    WHEN 'PCT' THEN CONCAT(N'<b>', ISNULL(CONVERT(nvarchar(20), CONVERT(decimal(9,1), m.y_max)), N'-'), N'%</b>')
                    ELSE CONCAT(N'<b>', ISNULL(CONVERT(nvarchar(20), CONVERT(int, m.y_max)), N'-'), N'</b>') END AS y,
        CASE WHEN m.p_max IS NULL THEN N'-'
             WHEN m.unit = 'MB ' THEN CONCAT(CASE WHEN m.p_avg IS NOT NULL THEN CONCAT(N'avg ', mon.fn_FmtMb(m.p_avg), N' &middot; ') ELSE N'' END,
                                            CASE WHEN m.p_p95 IS NOT NULL THEN CONCAT(N'p95 ', mon.fn_FmtMb(m.p_p95), N' &middot; ') ELSE N'' END,
                                            N'max ', mon.fn_FmtMb(m.p_max))
             WHEN m.unit = 'SEC' THEN mon.fn_Duration(CONVERT(bigint, m.p_max))
             WHEN m.unit = 'MS ' THEN CONCAT(CONVERT(decimal(9,1), m.p_max), N' ms')
             WHEN m.unit = 'PCT' THEN CONCAT(CONVERT(decimal(9,1), m.p_max), N'%')
             ELSE CONVERT(nvarchar(20), CONVERT(int, m.p_max)) END AS p,
        CASE WHEN m.b_max IS NULL THEN N'-'
             WHEN m.unit = 'MB ' THEN mon.fn_FmtMb(m.b_max)
             WHEN m.unit = 'SEC' THEN mon.fn_Duration(CONVERT(bigint, m.b_max))
             WHEN m.unit = 'MS ' THEN CONCAT(CONVERT(decimal(9,1), m.b_max), N' ms')
             WHEN m.unit = 'PCT' THEN CONCAT(CONVERT(decimal(9,1), m.b_max), N'%')
             ELSE CONVERT(nvarchar(20), CONVERT(decimal(9,1), m.b_max)) END AS b) AS x
    ORDER BY m.sort;

    /* ---------------- 2. BEFORE vs AFTER RCSI ---------------- */
    DECLARE @cut_first datetime2(0), @cut_last datetime2(0), @cut_dbs nvarchar(1000) = N'', @unknown_dbs nvarchar(1000) = N'', @cut_n int = 0, @on_n int = 0;
    SELECT @cut_first = MIN(enabled_utc), @cut_last = MAX(enabled_utc), @cut_n = COUNT(enabled_utc),
           @on_n = SUM(CASE WHEN is_on = 1 THEN 1 ELSE 0 END)
    FROM mon.RcsiCutover;
    SELECT @cut_dbs = @cut_dbs + CONCAT(CASE WHEN @cut_dbs <> N'' THEN N', ' ELSE N'' END, c.database_name, N' (', mon.fn_FmtLocal(c.enabled_utc, @tz),
                                        CASE WHEN c.is_on = 0 THEN N', OFF again' ELSE N'' END, N')')
    FROM mon.RcsiCutover AS c WHERE c.enabled_utc IS NOT NULL ORDER BY c.enabled_utc, c.database_name;
    SELECT @unknown_dbs = @unknown_dbs + CONCAT(CASE WHEN @unknown_dbs <> N'' THEN N', ' ELSE N'' END, c.database_name)
    FROM mon.RcsiCutover AS c WHERE c.enabled_utc IS NULL AND c.is_on = 1 ORDER BY c.database_name;

    DECLARE @first_sample datetime2(0) = (SELECT MIN(sample_utc) FROM mon.TempdbSample);
    DECLARE @ba_rows nvarchar(max) = N'', @ba_subtitle nvarchar(1000), @ba_subject nvarchar(200) = N'';

    CREATE TABLE #W (w char(1) PRIMARY KEY, days decimal(9,1), samples int,
                     used_avg decimal(19,2), used_p95 decimal(19,2), used_max decimal(19,2),
                     vs_avg decimal(19,2), vs_p95 decimal(19,2), vs_max decimal(19,2),
                     uo_max decimal(19,2), io_max decimal(19,2), tran_max int, atr_max int, sess_max int, top_max decimal(19,2),
                     wr_mb_day decimal(19,2), wr_ms decimal(9,2), growth_day decimal(9,2));
    IF @cut_first IS NOT NULL
    BEGIN
        DECLARE @b0 datetime2(0) = DATEADD(DAY, -@cmp_days, @cut_first),
                @b1 datetime2(0) = @cut_first,
                @a0 datetime2(0) = @cut_last,
                @a1 datetime2(0) = @d1;   /* up to the end of the reported day */
        IF @b0 < @first_sample SET @b0 = @first_sample;

        /* raw samples (30 days) when available, otherwise the daily table */
        ;WITH X AS (SELECT v.w, v.t0, v.t1 FROM (VALUES ('B', @b0, @b1), ('A', @a0, @a1)) AS v(w, t0, t1)),
        S AS
        (
            SELECT X.w, X.t0, X.t1, s.sample_utc, s.used_mb, s.version_store_mb, s.user_obj_mb, s.internal_obj_mb,
                   s.vs_longest_tran_s, s.vs_active_tran, s.sessions_using_tempdb, s.top_session_mb,
                   PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY s.used_mb)          OVER (PARTITION BY X.w) AS used_p95,
                   PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY s.version_store_mb) OVER (PARTITION BY X.w) AS vs_p95,
                   s.io_bytes_written  - LAG(s.io_bytes_written)  OVER (PARTITION BY X.w ORDER BY s.sample_utc) AS d_bwr,
                   s.io_writes         - LAG(s.io_writes)         OVER (PARTITION BY X.w ORDER BY s.sample_utc) AS d_wr,
                   s.io_stall_write_ms - LAG(s.io_stall_write_ms) OVER (PARTITION BY X.w ORDER BY s.sample_utc) AS d_swr
            FROM X
            JOIN mon.TempdbSample AS s ON s.sample_utc >= X.t0 AND s.sample_utc < X.t1
        )
        INSERT #W(w, days, samples, used_avg, used_p95, used_max, vs_avg, vs_p95, vs_max, uo_max, io_max, tran_max, atr_max, sess_max, top_max, wr_mb_day, wr_ms, growth_day)
        SELECT S.w, CONVERT(decimal(9,1), DATEDIFF(MINUTE, S.t0, S.t1) / 1440.0), COUNT(*),
               AVG(S.used_mb), MAX(S.used_p95), MAX(S.used_mb), AVG(S.version_store_mb), MAX(S.vs_p95), MAX(S.version_store_mb),
               MAX(S.user_obj_mb), MAX(S.internal_obj_mb), MAX(S.vs_longest_tran_s), MAX(S.vs_active_tran), MAX(S.sessions_using_tempdb), MAX(S.top_session_mb),
               CONVERT(decimal(19,2), SUM(CASE WHEN S.d_bwr > 0 THEN S.d_bwr ELSE 0 END) / 1048576.0 / NULLIF(DATEDIFF(MINUTE, S.t0, S.t1) / 1440.0, 0)),
               CONVERT(decimal(9,2), SUM(CASE WHEN S.d_swr > 0 THEN S.d_swr ELSE 0 END) * 1.0 / NULLIF(SUM(CASE WHEN S.d_wr > 0 THEN S.d_wr ELSE 0 END), 0)),
               CONVERT(decimal(9,2), (SELECT COUNT(*) FROM mon.TempdbGrowthEvent AS g WHERE g.event_utc >= S.t0 AND g.event_utc < S.t1) / NULLIF(DATEDIFF(MINUTE, S.t0, S.t1) / 1440.0, 0))
        FROM S
        GROUP BY S.w, S.t0, S.t1;

        /* before-window older than the raw retention: use the daily aggregates */
        IF NOT EXISTS (SELECT 1 FROM #W WHERE w = 'B')
            INSERT #W(w, days, samples, used_avg, used_p95, used_max, vs_avg, vs_p95, vs_max, uo_max, io_max, tran_max, atr_max, sess_max, top_max, wr_mb_day, wr_ms, growth_day)
            SELECT 'B', COUNT(*), SUM(samples), AVG(used_avg_mb), MAX(used_p95_mb), MAX(used_max_mb), AVG(vs_avg_mb), MAX(vs_p95_mb), MAX(vs_max_mb),
                   MAX(user_obj_max_mb), MAX(internal_obj_max_mb), MAX(vs_tran_max_s), MAX(vs_active_tran_max), MAX(sessions_max), MAX(top_session_max_mb),
                   AVG(CONVERT(decimal(19,2), io_write_mb)), AVG(io_write_ms_avg), AVG(CONVERT(decimal(9,2), growth_events))
            FROM mon.TempdbDaily
            WHERE report_date >= CONVERT(date, mon.fn_UtcToLocal(@b0, @tz)) AND report_date < CONVERT(date, mon.fn_UtcToLocal(@b1, @tz))
            HAVING COUNT(*) > 0;

        SELECT @ba_rows = @ba_rows + CONCAT(N'<tr>',
            mon.fn_Td(mon.fn_HtmlEncode(v.metric), NULL),
            mon.fn_Td(mon.fn_Nw(v.b_txt), NULL),
            mon.fn_Td(mon.fn_Nw(v.a_txt), NULL),
            mon.fn_Td(mon.fn_DeltaPill(v.a_val, v.b_val, v.bad_up), NULL),
            N'</tr>')
        FROM (SELECT * FROM #W WHERE w = 'B') AS B
        FULL JOIN (SELECT * FROM #W WHERE w = 'A') AS A ON 1 = 1
        CROSS APPLY (VALUES
            (10, N'tempdb used - avg', 1, B.used_avg, A.used_avg, mon.fn_FmtMb(B.used_avg), mon.fn_FmtMb(A.used_avg)),
            (11, N'tempdb used - p95', 1, B.used_p95, A.used_p95, mon.fn_FmtMb(B.used_p95), mon.fn_FmtMb(A.used_p95)),
            (12, N'tempdb used - max', 1, B.used_max, A.used_max, mon.fn_FmtMb(B.used_max), mon.fn_FmtMb(A.used_max)),
            (20, N'Version store - avg', 1, B.vs_avg, A.vs_avg, mon.fn_FmtMb(B.vs_avg), mon.fn_FmtMb(A.vs_avg)),
            (21, N'Version store - p95', 1, B.vs_p95, A.vs_p95, mon.fn_FmtMb(B.vs_p95), mon.fn_FmtMb(A.vs_p95)),
            (22, N'Version store - max', 1, B.vs_max, A.vs_max, mon.fn_FmtMb(B.vs_max), mon.fn_FmtMb(A.vs_max)),
            (30, N'User objects - max', 1, B.uo_max, A.uo_max, mon.fn_FmtMb(B.uo_max), mon.fn_FmtMb(A.uo_max)),
            (31, N'Internal objects - max', 1, B.io_max, A.io_max, mon.fn_FmtMb(B.io_max), mon.fn_FmtMb(A.io_max)),
            (40, N'Longest versioning tran', 1, CONVERT(decimal(19,2), B.tran_max), CONVERT(decimal(19,2), A.tran_max), mon.fn_Duration(B.tran_max), mon.fn_Duration(A.tran_max)),
            (41, N'Versioning transactions - max', 1, CONVERT(decimal(19,2), B.atr_max), CONVERT(decimal(19,2), A.atr_max), ISNULL(CONVERT(nvarchar(20), B.atr_max), N'-'), ISNULL(CONVERT(nvarchar(20), A.atr_max), N'-')),
            (50, N'Sessions using tempdb - max', 0, CONVERT(decimal(19,2), B.sess_max), CONVERT(decimal(19,2), A.sess_max), ISNULL(CONVERT(nvarchar(20), B.sess_max), N'-'), ISNULL(CONVERT(nvarchar(20), A.sess_max), N'-')),
            (51, N'Largest single session', 1, B.top_max, A.top_max, mon.fn_FmtMb(B.top_max), mon.fn_FmtMb(A.top_max)),
            (60, N'Written to tempdb per day', 0, B.wr_mb_day, A.wr_mb_day, mon.fn_FmtMb(B.wr_mb_day), mon.fn_FmtMb(A.wr_mb_day)),
            (61, N'tempdb write latency', 1, B.wr_ms, A.wr_ms, CONCAT(ISNULL(CONVERT(nvarchar(20), B.wr_ms), N'-'), N' ms'), CONCAT(ISNULL(CONVERT(nvarchar(20), A.wr_ms), N'-'), N' ms')),
            (70, N'Autogrowth events per day', 1, B.growth_day, A.growth_day, ISNULL(CONVERT(nvarchar(20), B.growth_day), N'-'), ISNULL(CONVERT(nvarchar(20), A.growth_day), N'-'))
        ) AS v(sort, metric, bad_up, b_val, a_val, b_txt, a_txt)
        ORDER BY v.sort;

        DECLARE @bd decimal(9,1) = (SELECT days FROM #W WHERE w = 'B'), @ad decimal(9,1) = (SELECT days FROM #W WHERE w = 'A'),
                @bn int = (SELECT samples FROM #W WHERE w = 'B'), @an int = (SELECT samples FROM #W WHERE w = 'A');
        SET @ba_subtitle = CONCAT(N'Cutover: ', mon.fn_HtmlEncode(@cut_dbs), N'. ',
            N'BEFORE = ', ISNULL(CONVERT(nvarchar(20), @bd), N'0'), N' day(s) / ', ISNULL(@bn, 0), N' samples before the first cutover (',
            mon.fn_FmtLocal(@b0, @tz), N' - ', mon.fn_FmtLocal(@b1, @tz), N' ', @tzl, N'); ',
            N'AFTER = ', ISNULL(CONVERT(nvarchar(20), @ad), N'0'), N' day(s) / ', ISNULL(@an, 0), N' samples since the last cutover (',
            mon.fn_FmtLocal(@a0, @tz), N' - ', mon.fn_FmtLocal(@a1, @tz), N' ', @tzl, N').',
            CASE WHEN @unknown_dbs <> N'' THEN CONCAT(N' Already ON before monitoring started (date unknown): ', mon.fn_HtmlEncode(@unknown_dbs), N'.') ELSE N'' END);
        IF @ba_rows = N'' SET @ba_rows = mon.fn_EmptyRow(4, N'No samples in the comparison windows yet.');
        SELECT @ba_subject = CONCAT(N' | after RCSI: used p95 ', mon.fn_FmtMb(A.used_p95), N' vs ', mon.fn_FmtMb(B.used_p95), N' before')
        FROM (SELECT * FROM #W WHERE w = 'A') AS A CROSS JOIN (SELECT * FROM #W WHERE w = 'B') AS B;
    END
    ELSE
    BEGIN
        SET @ba_subtitle = CONCAT(N'No RCSI cutover recorded yet - collecting the baseline since ', mon.fn_FmtLocal(@first_sample, @tz), N' ', @tzl,
            N' (', CONVERT(decimal(9,1), DATEDIFF(MINUTE, @first_sample, @now) / 1440.0), N' days). ',
            N'The cutover is detected automatically when a database switches to READ COMMITTED SNAPSHOT (or record it with usp_SetRcsiCutover, see footer).',
            CASE WHEN @unknown_dbs <> N'' THEN CONCAT(N' Databases already ON before monitoring started (no pre-RCSI baseline): ', mon.fn_HtmlEncode(@unknown_dbs), N'.') ELSE N'' END);
        SET @ba_rows = mon.fn_EmptyRow(4, N'Before/after comparison appears here once RCSI has been switched on.');
    END;

    /* ---------------- 3. version store by database (reported day) ---------------- */
    DECLARE @vsdb_rows nvarchar(max) = N'';
    SELECT TOP (@rows_cap) @vsdb_rows = @vsdb_rows + CONCAT(N'<tr>',
        mon.fn_Td(mon.fn_HtmlEncode(v.database_name), NULL),
        mon.fn_Td(CASE WHEN v.rcsi = 1 THEN mon.fn_Pill(N'RCSI', 'INFO') ELSE N'' END + CASE WHEN v.si = 1 THEN CONCAT(N' ', mon.fn_Pill(N'SI', 'INFO')) ELSE N'' END, NULL),
        mon.fn_Td(mon.fn_Nw(CONCAT(N'<b>', mon.fn_FmtMb(v.vs_max), N'</b>')), NULL),
        mon.fn_Td(mon.fn_Nw(mon.fn_FmtMb(v.vs_avg)), NULL),
        mon.fn_Td(mon.fn_DeltaPill(v.vs_max, p.vs_max, 1), NULL),
        mon.fn_Td(CONVERT(nvarchar(20), v.atr_max), NULL),
        mon.fn_Td(mon.fn_Nw(mon.fn_Duration(v.tran_max)), CASE WHEN v.tran_max >= @tr_crit * 60 THEN 'CRIT' WHEN v.tran_max >= @tr_warn * 60 THEN 'WARN' ELSE NULL END),
        mon.fn_Td(mon.fn_Small(CONCAT(v.n, N' of ', @n_samples)), NULL),
        N'</tr>')
    FROM (SELECT database_name, MAX(CONVERT(tinyint, is_rcsi_on)) AS rcsi, MAX(CONVERT(tinyint, is_si_on)) AS si,
                 MAX(reserved_mb) AS vs_max, AVG(reserved_mb) AS vs_avg, MAX(active_tran) AS atr_max, MAX(longest_tran_s) AS tran_max, COUNT(*) AS n
          FROM mon.TempdbVersionStoreDb WHERE sample_utc >= @d0 AND sample_utc < @d1 GROUP BY database_name) AS v
    LEFT JOIN (SELECT database_name, MAX(reserved_mb) AS vs_max
               FROM mon.TempdbVersionStoreDb WHERE sample_utc >= DATEADD(DAY, -1, @d0) AND sample_utc < @d0 GROUP BY database_name) AS p ON p.database_name = v.database_name
    ORDER BY v.vs_max DESC, v.database_name;
    IF @vsdb_rows = N'' SET @vsdb_rows = mon.fn_EmptyRow(8, N'No database held row versions on this day.');

    /* ---------------- 4. top row-version generators ---------------- */
    DECLARE @gen_rows nvarchar(max) = N'';
    SELECT TOP (@rows_cap) @gen_rows = @gen_rows + CONCAT(N'<tr>',
        mon.fn_Td(mon.fn_HtmlEncode(g.database_name), NULL),
        mon.fn_Td(CONCAT(N'<code>', mon.fn_HtmlEncode(g.object_name), N'</code>', CASE WHEN g.index_name IS NOT NULL THEN CONCAT(N' ', mon.fn_Small(mon.fn_HtmlEncode(g.index_name))) ELSE N'' END), NULL),
        mon.fn_Td(mon.fn_Nw(CONCAT(N'<b>', mon.fn_FmtMb(g.mx), N'</b>')), NULL),
        mon.fn_Td(mon.fn_Nw(mon.fn_FmtMb(g.av)), NULL),
        mon.fn_Td(mon.fn_Small(CONCAT(g.n, N' of ', @n_samples)), NULL),
        N'</tr>')
    FROM (SELECT database_name, object_name, index_name, MAX(version_mb) AS mx, AVG(version_mb) AS av, COUNT(*) AS n
          FROM mon.TempdbVersionGenerator WHERE sample_utc >= @d0 AND sample_utc < @d1
          GROUP BY database_name, object_name, index_name) AS g
    ORDER BY g.mx DESC, g.database_name, g.object_name;
    IF @gen_rows = N'' SET @gen_rows = mon.fn_EmptyRow(5, N'No row-version generators observed on this day.');

    /* ---------------- 5. top tempdb consumers ---------------- */
    DECLARE @top_rows nvarchar(max) = N'';
    SELECT TOP (@rows_cap) @top_rows = @top_rows + CONCAT(N'<tr>',
        mon.fn_Td(CONCAT(mon.fn_HtmlEncode(ISNULL(c.login_name, N'?')), N'<br>', mon.fn_Small(CONCAT(mon.fn_HtmlEncode(ISNULL(c.host_name, N'')), N' &middot; ', mon.fn_HtmlEncode(LEFT(ISNULL(c.program_name, N''), 60))))), NULL),
        mon.fn_Td(mon.fn_HtmlEncode(ISNULL(c.database_name, N'')), NULL),
        mon.fn_Td(mon.fn_Nw(CONCAT(N'<b>', mon.fn_FmtMb(c.mx), N'</b>')), CASE WHEN c.mx >= 10240 THEN 'WARN' ELSE NULL END),
        mon.fn_Td(mon.fn_Nw(CONCAT(mon.fn_FmtMb(c.uo), N' / ', mon.fn_FmtMb(c.io))), NULL),
        mon.fn_Td(mon.fn_Small(CONCAT(c.n, N' sample(s), ', c.sessions, N' session(s)')), NULL),
        mon.fn_Td(CASE WHEN c.sql_text IS NULL THEN mon.fn_Small(N'(no statement captured)') ELSE CONCAT(N'<code>', mon.fn_OneLine(c.sql_text, 220), N'</code>') END, NULL),
        N'</tr>')
    FROM (SELECT login_name, host_name, program_name, database_name, query_hash,
                 MAX(total_mb) AS mx, MAX(user_obj_mb) AS uo, MAX(internal_obj_mb) AS io, COUNT(*) AS n, COUNT(DISTINCT session_id) AS sessions,
                 MAX(sql_text) AS sql_text
          FROM mon.TempdbTopConsumer WHERE sample_utc >= @d0 AND sample_utc < @d1
          GROUP BY login_name, host_name, program_name, database_name, query_hash) AS c
    ORDER BY c.mx DESC;
    IF @top_rows = N'' SET @top_rows = mon.fn_EmptyRow(6, CONCAT(N'No session held more than ', ISNULL(mon.fn_SettingInt('tempdb_top_min_mb'), 50), N' MB of tempdb on this day.'));

    /* ---------------- 6. hourly profile ---------------- */
    DECLARE @hour_rows nvarchar(max) = N'', @size_max decimal(19,2) = (SELECT size_max_mb FROM mon.TempdbDaily WHERE report_date = @Date);
    SELECT @hour_rows = @hour_rows + CONCAT(N'<tr>',
        mon.fn_Td(mon.fn_Nw(CONCAT(RIGHT(CONCAT(N'0', h.hr), 2), N':00')), NULL),
        N'<td class="c" valign="top" width="34%">', mon.fn_Bar(CONVERT(int, h.used_max * 100.0 / NULLIF(@size_max, 0)), '#2563EB', mon.fn_FmtMb(h.used_max)), N'</td>',
        N'<td class="c" valign="top" width="34%">', mon.fn_Bar(CONVERT(int, h.vs_max * 100.0 / NULLIF(@size_max, 0)), '#F59E0B', mon.fn_FmtMb(h.vs_max)), N'</td>',
        mon.fn_Td(CONVERT(nvarchar(20), h.atr_max), NULL),
        mon.fn_Td(mon.fn_Nw(mon.fn_Duration(h.tran_max)), CASE WHEN h.tran_max >= @tr_warn * 60 THEN 'WARN' ELSE NULL END),
        mon.fn_Td(CONVERT(nvarchar(20), h.sess_max), NULL),
        N'</tr>')
    FROM (SELECT DATEPART(HOUR, (s.sample_utc AT TIME ZONE 'UTC') AT TIME ZONE @tz) AS hr,
                 MAX(s.used_mb) AS used_max, MAX(s.version_store_mb) AS vs_max, MAX(s.vs_active_tran) AS atr_max,
                 MAX(s.vs_longest_tran_s) AS tran_max, MAX(s.sessions_using_tempdb) AS sess_max
          FROM mon.TempdbSample AS s WHERE s.sample_utc >= @d0 AND s.sample_utc < @d1
          GROUP BY DATEPART(HOUR, (s.sample_utc AT TIME ZONE 'UTC') AT TIME ZONE @tz)) AS h
    ORDER BY h.hr;
    IF @hour_rows = N'' SET @hour_rows = mon.fn_EmptyRow(6, N'No samples on this day.');

    /* ---------------- 7. files + autogrowth ---------------- */
    DECLARE @file_rows nvarchar(max) = N'', @last_sample datetime2(0) = (SELECT MAX(sample_utc) FROM mon.TempdbFileSample WHERE sample_utc < @d1);
    SELECT @file_rows = @file_rows + CONCAT(N'<tr>',
        mon.fn_Td(mon.fn_HtmlEncode(f.logical_name), NULL),
        mon.fn_Td(mon.fn_HtmlEncode(f.type_desc), NULL),
        mon.fn_Td(mon.fn_Nw(mon.fn_FmtMb(f.size_mb)), NULL),
        mon.fn_Td(mon.fn_Nw(CASE WHEN f.used_mb IS NULL THEN N'-' ELSE CONCAT(mon.fn_FmtMb(f.used_mb), N' (', CONVERT(int, f.used_mb * 100.0 / NULLIF(f.size_mb, 0)), N'%)') END), NULL),
        mon.fn_Td(mon.fn_Nw(CASE WHEN f.max_size_mb = -1 THEN N'unlimited' ELSE mon.fn_FmtMb(f.max_size_mb) END), NULL),
        mon.fn_Td(mon.fn_HtmlEncode(f.growth_desc), NULL),
        mon.fn_Td(CASE WHEN g.n IS NULL THEN N'0' ELSE CONCAT(N'<b>', g.n, N'</b> (+', mon.fn_FmtMb(g.mb), N')') END, CASE WHEN g.n >= @gr_warn THEN 'WARN' ELSE NULL END),
        N'</tr>')
    FROM mon.TempdbFileSample AS f
    LEFT JOIN (SELECT file_name, COUNT(*) AS n, SUM(growth_mb) AS mb FROM mon.TempdbGrowthEvent WHERE event_utc >= @d0 AND event_utc < @d1 GROUP BY file_name) AS g
           ON g.file_name = f.logical_name
    WHERE f.sample_utc = @last_sample
    ORDER BY f.type_desc DESC, f.file_id;
    IF @file_rows = N'' SET @file_rows = mon.fn_EmptyRow(7, N'No file sample for this day.');

    /* ---------------- KPIs + subject ---------------- */
    DECLARE @y_used decimal(19,2), @y_vs decimal(19,2), @y_tran int, @y_growth int, @y_size decimal(19,2), @y_sess int, @p_used decimal(19,2), @p_vs decimal(19,2);
    SELECT @y_used = used_max_mb, @y_vs = vs_max_mb, @y_tran = vs_tran_max_s, @y_growth = growth_events, @y_size = size_max_mb, @y_sess = sessions_max
    FROM mon.TempdbDaily WHERE report_date = @Date;
    SELECT @p_used = used_max_mb, @p_vs = vs_max_mb FROM mon.TempdbDaily WHERE report_date = @prev;
    DECLARE @vs_pct int = CONVERT(int, @y_vs * 100.0 / NULLIF(@y_size, 0));
    DECLARE @level varchar(4) = CASE WHEN @vs_pct >= @vs_crit OR @y_tran >= @tr_crit * 60 THEN 'CRIT'
                                     WHEN @vs_pct >= @vs_warn OR @y_tran >= @tr_warn * 60 OR @y_growth >= @gr_warn THEN 'WARN' ELSE 'OK' END;
    DECLARE @color varchar(7) = CASE @level WHEN 'CRIT' THEN '#DC2626' WHEN 'WARN' THEN '#D97706' ELSE '#1E3A5F' END;

    DECLARE @nfiles int = (SELECT TOP (1) data_file_count FROM mon.TempdbSample WHERE sample_utc < @d1 ORDER BY sample_utc DESC),
            @ndb int = (SELECT COUNT(*) FROM sys.databases WHERE database_id > 4);
    DECLARE @kpis nvarchar(max) = mon.fn_KpiRow(CONCAT(
        mon.fn_Kpi(mon.fn_FmtMb(@y_used), N'tempdb used max', CONCAT(N'prev ', mon.fn_FmtMb(@p_used)), CASE WHEN @p_used > 0 AND @y_used >= @p_used * 1.5 THEN 'WARN' ELSE NULL END),
        mon.fn_Kpi(mon.fn_FmtMb(@y_vs), N'version store max', CONCAT(ISNULL(CONVERT(nvarchar(10), @vs_pct), N'-'), N'% of tempdb'), CASE WHEN @vs_pct >= @vs_crit THEN 'CRIT' WHEN @vs_pct >= @vs_warn THEN 'WARN' ELSE NULL END),
        mon.fn_Kpi(mon.fn_Duration(@y_tran), N'longest versioning tran', N'max of the day', CASE WHEN @y_tran >= @tr_crit * 60 THEN 'CRIT' WHEN @y_tran >= @tr_warn * 60 THEN 'WARN' ELSE NULL END),
        mon.fn_Kpi(ISNULL(CONVERT(nvarchar(10), @y_growth), N'0'), N'autogrowths', N'tempdb files', CASE WHEN @y_growth >= @gr_warn THEN 'WARN' WHEN @y_growth > 0 THEN 'INFO' ELSE NULL END),
        mon.fn_Kpi(mon.fn_FmtMb(@y_size), N'tempdb size', CONCAT(@nfiles, N' data files'), NULL),
        mon.fn_Kpi(CONCAT(@on_n, N'/', @ndb), N'RCSI databases', CASE WHEN @cut_n > 0 THEN CONCAT(N'cutover ', mon.fn_FmtLocal(@cut_last, @tz)) ELSE N'no cutover yet' END, CASE WHEN @on_n > 0 THEN 'INFO' ELSE NULL END)));

    DECLARE @subject nvarchar(255) = LEFT(CONCAT(N'[', @server, N'] MON - TempDB RCSI ', CONVERT(nvarchar(10), @Date, 120),
        N' | used max ', mon.fn_FmtMb(@y_used), CASE WHEN @p_used > 0 THEN CONCAT(N' (', CASE WHEN @y_used >= @p_used THEN N'+' ELSE N'' END, CONVERT(int, (@y_used - @p_used) * 100.0 / @p_used), N'%)') ELSE N'' END,
        N' | version store max ', mon.fn_FmtMb(@y_vs), @ba_subject), 255);

    DECLARE @body nvarchar(max) = CONCAT(
        @kpis,
        mon.fn_Section(CONCAT(N'Day ', CONVERT(nvarchar(10), @Date, 120), N' vs previous day vs 7-day baseline'),
                       CONCAT(@n_samples, N' samples every ', ISNULL(mon.fn_SettingInt('collect_interval_minutes'), 5), N' min. Baseline = average of the daily maxima of the ',
                              @b_days, N' day(s) before the previous day. Deltas compare the daily MAX.'),
                       N'Metric|Reported day|Previous day|vs previous|7-day baseline|vs baseline', @cmp_rows),
        mon.fn_Section(N'Before vs after RCSI', @ba_subtitle, N'Metric|Before|After|Change', @ba_rows),
        mon.fn_Section(N'Version store by database', N'Row versions held per database on the reported day (sys.dm_tran_version_store_space_usage); versioning transactions = sys.dm_tran_active_snapshot_database_transactions.',
                       N'Database|Mode|VS max|VS avg|vs previous day|Versioning trans (max)|Longest tran|Seen', @vsdb_rows),
        mon.fn_Section(N'Top row-version generators', N'Objects whose rows were versioned (sys.dm_tran_top_version_generators): these are the UPDATE / DELETE targets that fill the version store.',
                       N'Database|Object|Max|Avg|Seen', @gen_rows),
        mon.fn_Section(N'Top tempdb consumers', CONCAT(N'Sessions holding at least ', ISNULL(mon.fn_SettingInt('tempdb_top_min_mb'), 50), N' MB of tempdb (session + running tasks), grouped by login / host / program / database / query.'),
                       N'Login / host / program|Database|Max tempdb|User / internal|Seen|Statement', @top_rows),
        mon.fn_Section(N'Hourly profile', CONCAT(N'Maximum per hour (', @tzl, N'); bars relative to the allocated tempdb size ', mon.fn_FmtMb(@size_max), N'. Blue = used, amber = version store.'),
                       N'Hour|tempdb used|Version store|Versioning trans|Longest tran|Sessions', @hour_rows),
        mon.fn_Section(N'tempdb files', CONCAT(N'As of ', mon.fn_FmtLocal(@last_sample, @tz), N' ', @tzl, N'. Autogrowth events on the reported day from the default trace.'),
                       N'File|Type|Size|Used|Max size|Growth|Autogrowths', @file_rows));

    DECLARE @footer nvarchar(max) = CONCAT(
        N'<b>MON - TempDB RCSI</b> is sent daily at ', ISNULL(NULLIF(mon.fn_Setting('tempdb_report_hours_local'), N''), N'8'), N':00 ', @tzl,
        N' (settings tempdb_report_*). Raw 5-minute samples are kept ', ISNULL(mon.fn_SettingInt('retention_tempdb_days'), 30),
        N' days, daily aggregates ', ISNULL(mon.fn_SettingInt('retention_tempdb_daily_days'), 400), N' days.<br>',
        N'Record the real cutover: <code>EXEC OPS.mon.usp_SetRcsiCutover @Database = N''MyDb'', @EnabledLocal = ''YYYY-MM-DD HH:MM'';</code> &middot; ',
        N'SSMS: <code>EXEC OPS.mon.usp_ShowTempdb;</code> &middot; re-send: <code>EXEC OPS.mon.usp_SendTempdbReport @Date = ''', CONVERT(nvarchar(10), @Date, 120), N''', @Force = 1;</code><br>',
        N'Checks TEMPDB_VS (version store ', @vs_warn, N'% / ', @vs_crit, N'% of tempdb; versioning transaction ', @tr_warn, N' / ', @tr_crit, N' min), TEMPDB_GROWTH (',
        @gr_warn, N' autogrowths / h) and RCSI (switch detected) raise issues through the normal alert mail; switch them in mon.ServerCheck.');

    DECLARE @html nvarchar(max) = mon.fn_EmailShell(@color, CONCAT(@server, N' - MON - TempDB RCSI'),
        CONCAT(N'tempdb & version store - ', CONVERT(nvarchar(10), @Date, 120)),
        CONCAT(N'Generated ', CONVERT(nvarchar(16), @local_now, 120), N' ', @tzl, N' &middot; ',
               CASE @level WHEN 'CRIT' THEN N'thresholds exceeded' WHEN 'WARN' THEN N'warning thresholds reached' ELSE N'within thresholds' END,
               CASE WHEN @cut_n > 0 THEN CONCAT(N' &middot; RCSI on ', @on_n, N' database(s)') ELSE N' &middot; pre-RCSI baseline' END),
        @body, @footer);

    IF @PreviewOnly = 1
    BEGIN
        SELECT @subject AS subject, @html AS html_body, DATALENGTH(@html) / 2048 AS body_kb;
        RETURN;
    END;

    DECLARE @mailitem_id int;
    BEGIN TRY
        EXEC msdb.dbo.sp_send_dbmail
             @profile_name = @profile, @recipients = @recipients,
             @subject = @subject, @body = @html, @body_format = 'HTML',
             @importance = 'Normal', @mailitem_id = @mailitem_id OUTPUT;
        INSERT mon.Notification(notification_type, created_utc, report_date_local, subject, recipients, mailitem_id, send_ok, body_kb)
        VALUES ('TEMPDB_REPORT', @now, @Date, @subject, @recipients, @mailitem_id, 1, DATALENGTH(@html) / 2048);
        EXEC mon.usp_SetComponentStatus 'TEMPDB_MAIL', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @em nvarchar(2000) = ERROR_MESSAGE(), @en int = ERROR_NUMBER();
        INSERT mon.Notification(notification_type, created_utc, report_date_local, subject, recipients, send_ok, error_message)
        VALUES ('TEMPDB_REPORT', @now, @Date, @subject, @recipients, 0, @em);
        EXEC mon.usp_SetComponentStatus 'TEMPDB_MAIL', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* Scheduler: called by the hourly job (MON - Digest & Watchdog, :02). */
CREATE OR ALTER PROCEDURE mon.usp_RunTempdbReport
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY EXEC mon.usp_SnapshotTempdbDaily; END TRY BEGIN CATCH END CATCH;

    IF ISNULL(mon.fn_SettingInt('tempdb_report_enabled'), 1) = 0 RETURN;
    DECLARE @now datetime2(0) = SYSUTCDATETIME(),
            @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');
    DECLARE @local_now datetime2(0) = mon.fn_UtcToLocal(@now, @tz);
    DECLARE @hour int = DATEPART(HOUR, @local_now),
            @iso_wd int = (DATEPART(WEEKDAY, @local_now) + @@DATEFIRST - 2) % 7 + 1,
            @yday date = DATEADD(DAY, -1, CONVERT(date, @local_now));

    IF mon.fn_InIntList(ISNULL(NULLIF(LTRIM(mon.fn_Setting('tempdb_report_hours_local')), N''), N'8'), @hour) = 0 RETURN;
    IF mon.fn_InIntList(ISNULL(mon.fn_Setting('tempdb_report_weekdays'), N'1,2,3,4,5,6,7'), @iso_wd) = 0 RETURN;
    IF EXISTS (SELECT 1 FROM mon.Notification
               WHERE notification_type IN ('TEMPDB_REPORT', 'TEMPDB_SKIPPED') AND report_date_local = @yday
                 AND (send_ok = 1 OR notification_type = 'TEMPDB_SKIPPED')) RETURN;   /* once per day */

    EXEC mon.usp_SendTempdbReport @Date = @yday;
END;
GO
