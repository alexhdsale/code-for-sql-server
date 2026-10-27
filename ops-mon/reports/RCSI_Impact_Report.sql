/* =============================================================================
   RCSI IMPACT REPORT v2  -  performance BEFORE vs AFTER READ COMMITTED SNAPSHOT
   Target : MS-APP-PROD (Amazon RDS for SQL Server 2017+)
   Reads  : Query Store of every selected database (runtime + wait stats), and
            OPS.mon 5.8 history when present (blocking, deadlocks, server waits,
            CPU, tempdb / version store, I/O latency).  Writes nothing except the
            mail item.

   WHAT IS NEW IN v2 (after the first PROD run of 2026-10-27)
     - Fair windows: AFTER = since the cutover; BEFORE = the SAME WEEKDAYS one week
       earlier (same length, same hours) so a Friday/Saturday batch is in both.
       The plain "7 days before the cutover" window is still shown as a reference.
     - "Same queries" comparison: every query that ran in both windows is compared
       at its own executions - a workload-mix-free answer to "did RCSI make the
       system faster or slower?", split into OLTP (short) and batch (long) queries.
     - Plain-language FINDINGS at the top, generated from the numbers (what RCSI
       removed, what it costs, what is unrelated workload, what to do next).
     - Blocking explained: wait types of the blocked sessions (shared-lock waits
       are what RCSI removes; X/U/schema waits are not) and the top head blockers.
     - Version store: who held the longest versioning transactions, which tables
       generate the versions, and a fragmentation / fill-factor check of those
       tables (the 14-byte version tag causes page splits on first modification).
     - Readable numbers: GB instead of MB, "x 12" instead of "+1,003,524 %".

   HOW TO RUN (SSMS, any database context):
     set the parameters below (or leave the NULL defaults), execute the whole file.
     Result sets: findings, scorecard, same-queries summary, per database, waits,
     blocking, version store, fragmentation, top regressed / improved, notes,
     mail status + html.
   ============================================================================= */
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* ------------------------------- PARAMETERS ------------------------------- */
DECLARE @CutoverLocal   datetime2(0)  = NULL;          /* e.g. '2026-10-23 20:53' (display time zone); NULL = OPS.mon.RcsiCutover */
DECLARE @Databases      nvarchar(max) = NULL;          /* 'Db1,Db2'; NULL = every database with RCSI ON */
DECLARE @AfterDays      int           = NULL;          /* "after" window length from the cutover; NULL = until now */
DECLARE @SkipHours      int           = 1;             /* hours right after the cutover excluded (plan cache warm-up) */
DECLARE @BeforeDays     int           = 7;             /* reference window "N days before the cutover" */
DECLARE @TimeZone       nvarchar(100) = N'Eastern Standard Time';
DECLARE @TzLabel        nvarchar(10)  = N'ET';
DECLARE @TopN           int           = 15;            /* queries listed per table */
DECLARE @MinExecs       int           = 20;            /* OLTP query lists: executions needed in both windows */
DECLARE @OltpMaxMs      int           = 100;           /* avg ms (before) below this = OLTP query; >= @BatchMinMs = batch */
DECLARE @BatchMinMs     int           = 1000;
DECLARE @CheckFragmentation bit       = 1;             /* index physical stats (LIMITED) of the tables that generate row versions */
DECLARE @FragTopTables  int           = 10;
DECLARE @ServerLabel    nvarchar(128) = NULL;          /* NULL = OPS.mon server_label or @@SERVERNAME */
DECLARE @Recipients     nvarchar(1000)= N'aleksey_kokit@miopartners.com';   /* who gets the HTML report (semicolon separated) */
DECLARE @SendMail       bit           = 1;             /* 1 = email the HTML through Database Mail; 0 = result sets only */
DECLARE @MailProfile    sysname       = NULL;          /* NULL = OPS.mon mail_profile (e.g. Notifications), else the default profile */
/* -------------------------------------------------------------------------- */

DECLARE @now datetime2(0) = SYSUTCDATETIME(), @sql nvarchar(max), @db sysname;
DECLARE @has_mon bit = CASE WHEN OBJECT_ID(N'OPS.mon.TempdbSample') IS NOT NULL THEN 1 ELSE 0 END;
DECLARE @notes TABLE (seq int IDENTITY, note nvarchar(1000));

IF @ServerLabel IS NULL AND OBJECT_ID(N'OPS.mon.Setting') IS NOT NULL
    SELECT @ServerLabel = setting_value FROM OPS.mon.Setting WHERE setting_name = 'server_label';
SET @ServerLabel = ISNULL(@ServerLabel, @@SERVERNAME);

/* ---- databases ---- */
CREATE TABLE #Db (database_name sysname PRIMARY KEY, database_id int, is_rcsi_on bit, si_state nvarchar(60),
                  qs_actual nvarchar(60), qs_capture nvarchar(60), qs_interval_min int, qs_oldest_utc datetime2(0),
                  qs_ok bit, note nvarchar(400));
IF @Databases IS NULL
    INSERT #Db(database_name, database_id, is_rcsi_on, si_state)
    SELECT name, database_id, is_read_committed_snapshot_on, snapshot_isolation_state_desc
    FROM sys.databases WHERE database_id > 4 AND is_read_committed_snapshot_on = 1 AND state_desc = N'ONLINE';
ELSE
    INSERT #Db(database_name, database_id, is_rcsi_on, si_state)
    SELECT d.name, d.database_id, d.is_read_committed_snapshot_on, d.snapshot_isolation_state_desc
    FROM sys.databases AS d
    JOIN (SELECT LTRIM(RTRIM(value)) AS n FROM STRING_SPLIT(@Databases, ',')) AS l ON l.n = d.name
    WHERE d.state_desc = N'ONLINE';
IF NOT EXISTS (SELECT 1 FROM #Db)
BEGIN
    RAISERROR(N'No database selected: no online database has RCSI ON, or @Databases names none that exist.', 16, 1);
    RETURN;
END;

/* ---- cutover ---- */
DECLARE @cut_utc datetime2(0) = NULL, @cut_src nvarchar(200);
IF @CutoverLocal IS NOT NULL
    SELECT @cut_utc = CONVERT(datetime2(0), (@CutoverLocal AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC'), @cut_src = N'parameter';
ELSE IF OBJECT_ID(N'OPS.mon.RcsiCutover') IS NOT NULL
BEGIN
    SELECT @cut_utc = MIN(c.enabled_utc)
    FROM OPS.mon.RcsiCutover AS c JOIN #Db AS d ON d.database_name = c.database_name
    WHERE c.enabled_utc IS NOT NULL;
    SET @cut_src = N'detected by OPS.mon';
END;
IF @cut_utc IS NULL
BEGIN
    RAISERROR(N'Cutover unknown: set @CutoverLocal (e.g. ''2026-10-23 20:53'') - OPS.mon.RcsiCutover has no date for the selected databases.', 16, 1);
    RETURN;
END;
DECLARE @cut_local datetime2(0) = CONVERT(datetime2(0), (@cut_utc AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone);

/* windows: A = after, B = same weekdays one week earlier (primary before), C = @BeforeDays right before the cutover (reference) */
DECLARE @a0 datetime2(0) = DATEADD(HOUR, @SkipHours, @cut_utc),
        @a1 datetime2(0) = CASE WHEN @AfterDays IS NULL THEN @now ELSE DATEADD(DAY, @AfterDays, @cut_utc) END;
IF @a1 > @now SET @a1 = @now;
IF @a1 <= @a0
BEGIN
    DECLARE @cut_txt varchar(19) = CONVERT(varchar(19), @cut_utc, 120);
    RAISERROR(N'The "after" window is empty: the cutover (%s UTC) is too recent.', 16, 1, @cut_txt);
    RETURN;
END;
DECLARE @weeks_back int = 1;
IF DATEDIFF(MINUTE, @a0, @a1) > 7 * 1440 SET @weeks_back = CEILING(DATEDIFF(MINUTE, @a0, @a1) / (7.0 * 1440));   /* long after-window: shift a whole number of weeks */
DECLARE @b0 datetime2(0) = DATEADD(DAY, -7 * @weeks_back, @a0),
        @b1 datetime2(0) = DATEADD(DAY, -7 * @weeks_back, @a1);
IF @b1 > @cut_utc SET @b1 = @cut_utc;
DECLARE @c0 datetime2(0) = DATEADD(DAY, -@BeforeDays, @cut_utc), @c1 datetime2(0) = @cut_utc;

CREATE TABLE #Win (win char(1) PRIMARY KEY, label nvarchar(60), t0 datetime2(0), t1 datetime2(0), hours decimal(9,2));
INSERT #Win VALUES
    ('A', N'After RCSI', @a0, @a1, DATEDIFF(MINUTE, @a0, @a1) / 60.0),
    ('B', CONCAT(N'Same weekdays, ', @weeks_back, N' week(s) earlier'), @b0, @b1, DATEDIFF(MINUTE, @b0, @b1) / 60.0),
    ('C', CONCAT(@BeforeDays, N' days before the cutover'), @c0, @c1, DATEDIFF(MINUTE, @c0, @c1) / 60.0);
DECLARE @ah decimal(9,2) = (SELECT hours FROM #Win WHERE win = 'A'), @bh decimal(9,2) = (SELECT hours FROM #Win WHERE win = 'B'), @ch decimal(9,2) = (SELECT hours FROM #Win WHERE win = 'C');

/* ============================ QUERY STORE ============================ */
CREATE TABLE #QsKpi (database_name sysname, win char(1), execs bigint, queries int, plans int,
                     dur_ms decimal(19,1), cpu_ms decimal(19,1), reads bigint, writes bigint, tempdb_pages bigint,
                     max_dur_ms decimal(19,1), aborted bigint, PRIMARY KEY (database_name, win));
CREATE TABLE #QsWait (database_name sysname, win char(1), wait_category nvarchar(60), wait_ms bigint,
                      PRIMARY KEY (database_name, win, wait_category));
CREATE TABLE #QsQuery (database_name sysname, win char(1), query_hash binary(8), query_id bigint, object_name nvarchar(300),
                       sql_text nvarchar(400), execs bigint, dur_ms decimal(19,1), cpu_ms decimal(19,1), reads bigint,
                       writes bigint, tempdb_pages bigint, max_dur_ms decimal(19,1), lock_wait_ms bigint, plans int, top_plan_id bigint,
                       PRIMARY KEY (database_name, win, query_hash));
CREATE TABLE #QsHour (database_name sysname, hour_utc datetime2(0), execs bigint, dur_ms decimal(19,1), cpu_ms decimal(19,1),
                      PRIMARY KEY (database_name, hour_utc));
DECLARE @span0 datetime2(0) = CASE WHEN @b0 < @c0 THEN @b0 ELSE @c0 END;

DECLARE dbc CURSOR LOCAL FAST_FORWARD FOR SELECT database_name FROM #Db ORDER BY database_name;
OPEN dbc; FETCH NEXT FROM dbc INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'USE ' + QUOTENAME(@db) + N';
            UPDATE d SET qs_actual = o.actual_state_desc, qs_capture = o.query_capture_mode_desc, qs_interval_min = o.interval_length_minutes,
                         qs_oldest_utc = (SELECT CONVERT(datetime2(0), MIN(start_time)) FROM sys.query_store_runtime_stats_interval),
                         qs_ok = CASE WHEN o.actual_state_desc IN (N''READ_WRITE'', N''READ_ONLY'') THEN 1 ELSE 0 END
            FROM #Db AS d CROSS JOIN sys.database_query_store_options AS o WHERE d.database_name = @db;';
        EXEC sys.sp_executesql @sql, N'@db sysname', @db = @db;

        IF (SELECT qs_ok FROM #Db WHERE database_name = @db) = 1
        BEGIN
            SET @sql = N'USE ' + QUOTENAME(@db) + N';
            INSERT #QsKpi(database_name, win, execs, queries, plans, dur_ms, cpu_ms, reads, writes, tempdb_pages, max_dur_ms, aborted)
            SELECT @db, w.win, SUM(rs.count_executions), COUNT(DISTINCT p.query_id), COUNT(DISTINCT rs.plan_id),
                   SUM(rs.count_executions * rs.avg_duration) / 1000.0, SUM(rs.count_executions * rs.avg_cpu_time) / 1000.0,
                   SUM(rs.count_executions * rs.avg_logical_io_reads), SUM(rs.count_executions * rs.avg_logical_io_writes),
                   SUM(rs.count_executions * rs.avg_tempdb_space_used), MAX(rs.max_duration) / 1000.0,
                   SUM(CASE WHEN rs.execution_type IN (3, 4) THEN rs.count_executions ELSE 0 END)
            FROM #Win AS w
            JOIN sys.query_store_runtime_stats_interval AS i ON i.start_time >= w.t0 AND i.end_time <= w.t1
            JOIN sys.query_store_runtime_stats AS rs ON rs.runtime_stats_interval_id = i.runtime_stats_interval_id
            JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
            GROUP BY w.win;

            INSERT #QsWait(database_name, win, wait_category, wait_ms)
            SELECT @db, w.win, ws.wait_category_desc, SUM(ws.total_query_wait_time_ms)
            FROM #Win AS w
            JOIN sys.query_store_runtime_stats_interval AS i ON i.start_time >= w.t0 AND i.end_time <= w.t1
            JOIN sys.query_store_wait_stats AS ws ON ws.runtime_stats_interval_id = i.runtime_stats_interval_id
            GROUP BY w.win, ws.wait_category_desc;

            ;WITH R AS
            (
                SELECT w.win, q.query_hash, q.query_id, q.object_id, p.plan_id,
                       rs.count_executions, rs.avg_duration, rs.avg_cpu_time, rs.avg_logical_io_reads, rs.avg_logical_io_writes,
                       rs.avg_tempdb_space_used, rs.max_duration
                FROM #Win AS w
                JOIN sys.query_store_runtime_stats_interval AS i ON i.start_time >= w.t0 AND i.end_time <= w.t1
                JOIN sys.query_store_runtime_stats AS rs ON rs.runtime_stats_interval_id = i.runtime_stats_interval_id
                JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
                JOIN sys.query_store_query AS q ON q.query_id = p.query_id
                WHERE rs.execution_type = 0 AND w.win IN (''A'', ''B'')
            ), L AS
            (
                SELECT w.win, q.query_hash, SUM(ws.total_query_wait_time_ms) AS lock_ms
                FROM #Win AS w
                JOIN sys.query_store_runtime_stats_interval AS i ON i.start_time >= w.t0 AND i.end_time <= w.t1
                JOIN sys.query_store_wait_stats AS ws ON ws.runtime_stats_interval_id = i.runtime_stats_interval_id
                JOIN sys.query_store_plan AS p ON p.plan_id = ws.plan_id
                JOIN sys.query_store_query AS q ON q.query_id = p.query_id
                WHERE ws.wait_category_desc = N''Lock'' AND w.win IN (''A'', ''B'')
                GROUP BY w.win, q.query_hash
            ), TP AS
            (
                SELECT win, query_hash, plan_id, ROW_NUMBER() OVER (PARTITION BY win, query_hash ORDER BY SUM(count_executions) DESC, plan_id) AS rn
                FROM R GROUP BY win, query_hash, plan_id
            ), G AS
            (
                SELECT R.win, R.query_hash, MIN(R.query_id) AS query_id, MIN(R.object_id) AS object_id,
                       SUM(R.count_executions) AS execs, COUNT(DISTINCT R.plan_id) AS plans,
                       SUM(R.count_executions * R.avg_duration) / 1000.0 AS dur_ms,
                       SUM(R.count_executions * R.avg_cpu_time) / 1000.0 AS cpu_ms,
                       SUM(R.count_executions * R.avg_logical_io_reads) AS reads,
                       SUM(R.count_executions * R.avg_logical_io_writes) AS writes,
                       SUM(R.count_executions * R.avg_tempdb_space_used) AS tempdb_pages,
                       MAX(R.max_duration) / 1000.0 AS max_dur_ms
                FROM R GROUP BY R.win, R.query_hash
            )
            INSERT #QsQuery(database_name, win, query_hash, query_id, object_name, sql_text, execs, dur_ms, cpu_ms, reads, writes, tempdb_pages, max_dur_ms, lock_wait_ms, plans, top_plan_id)
            SELECT @db, G.win, G.query_hash, G.query_id,
                   CASE WHEN G.object_id > 0 THEN OBJECT_SCHEMA_NAME(G.object_id) + N''.'' + OBJECT_NAME(G.object_id) END,
                   LEFT(t.query_sql_text, 400),
                   G.execs, G.dur_ms, G.cpu_ms, G.reads, G.writes, G.tempdb_pages, G.max_dur_ms, ISNULL(L.lock_ms, 0), G.plans, TP.plan_id
            FROM G
            LEFT JOIN L ON L.win = G.win AND L.query_hash = G.query_hash
            LEFT JOIN TP ON TP.win = G.win AND TP.query_hash = G.query_hash AND TP.rn = 1
            JOIN sys.query_store_query AS q ON q.query_id = G.query_id
            JOIN sys.query_store_query_text AS t ON t.query_text_id = q.query_text_id;

            INSERT #QsHour(database_name, hour_utc, execs, dur_ms, cpu_ms)
            SELECT @db, DATEADD(HOUR, DATEDIFF(HOUR, 0, CONVERT(datetime2(0), i.start_time)), 0),
                   SUM(rs.count_executions), SUM(rs.count_executions * rs.avg_duration) / 1000.0, SUM(rs.count_executions * rs.avg_cpu_time) / 1000.0
            FROM sys.query_store_runtime_stats_interval AS i
            JOIN sys.query_store_runtime_stats AS rs ON rs.runtime_stats_interval_id = i.runtime_stats_interval_id
            WHERE i.start_time >= @span0 AND i.end_time <= @a1
            GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, CONVERT(datetime2(0), i.start_time)), 0);';
            EXEC sys.sp_executesql @sql, N'@db sysname, @span0 datetime2(0), @a1 datetime2(0)', @db = @db, @span0 = @span0, @a1 = @a1;
        END
        ELSE
            UPDATE #Db SET note = N'Query Store not active (' + ISNULL(qs_actual, N'?') + N') - query sections skipped' WHERE database_name = @db;

        IF (SELECT qs_oldest_utc FROM #Db WHERE database_name = @db) > @span0
            UPDATE #Db SET note = CONCAT(ISNULL(note + N'; ', N''), N'Query Store history starts ', CONVERT(nvarchar(16), qs_oldest_utc, 120),
                                         N' UTC - the before windows are only partially covered') WHERE database_name = @db;
    END TRY
    BEGIN CATCH
        UPDATE #Db SET note = LEFT(CONCAT(N'Query Store read failed: ', ERROR_MESSAGE()), 400) WHERE database_name = @db;
    END CATCH;
    FETCH NEXT FROM dbc INTO @db;
END;
CLOSE dbc; DEALLOCATE dbc;

/* ============================ OPS.mon HISTORY ============================ */
CREATE TABLE #Mon (win char(1), metric nvarchar(60), value decimal(19,3), PRIMARY KEY (win, metric));
CREATE TABLE #BlkWait (win char(1), wait_type nvarchar(60), samples int, blocked_sessions int, PRIMARY KEY (win, wait_type));
CREATE TABLE #BlkHead (win char(1), rn int, head_program nvarchar(256), head_login nvarchar(128), head_database sysname, episodes int,
                       minutes decimal(19,1), max_victims int, head_sql nvarchar(400), top_wait_type nvarchar(60), PRIMARY KEY (win, rn));
CREATE TABLE #VsTran (rn int PRIMARY KEY, minutes decimal(9,1), session_id int, login_name sysname, database_name sysname, program_name nvarchar(128),
                      seen_from datetime2(0), seen_to datetime2(0), vs_mb_max decimal(19,2));
CREATE TABLE #VsGen (rn int PRIMARY KEY, database_name sysname, object_name nvarchar(300), index_name sysname, version_mb_max decimal(19,2),
                     version_mb_avg decimal(19,2), samples int);
IF @has_mon = 1
BEGIN
    BEGIN TRY
        /* blocking */
        SELECT w.win, e.episode_id, e.blocked_since_utc, DATEDIFF(SECOND, e.blocked_since_utc, ISNULL(e.ended_utc, e.last_seen_utc)) / 60.0 AS minutes,
               e.max_blocked_count, e.head_program, e.head_login, e.head_database, e.head_sql, e.head_input_buffer, e.top_wait_type
        INTO #BE
        FROM #Win AS w JOIN OPS.mon.BlockingEpisode AS e ON e.blocked_since_utc >= w.t0 AND e.blocked_since_utc < w.t1
        WHERE e.head_database IN (SELECT database_name FROM #Db) OR e.head_database IS NULL
           OR EXISTS (SELECT 1 FROM #Db AS d WHERE e.databases_affected LIKE N'%' + d.database_name + N'%');
        INSERT #Mon SELECT w.win, N'blocking_episodes', COUNT(b.episode_id) FROM #Win AS w LEFT JOIN #BE AS b ON b.win = w.win GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'blocking_minutes', ISNULL(SUM(b.minutes), 0) FROM #Win AS w LEFT JOIN #BE AS b ON b.win = w.win GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'blocking_longest_min', ISNULL(MAX(b.minutes), 0) FROM #Win AS w LEFT JOIN #BE AS b ON b.win = w.win GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'blocking_max_victims', ISNULL(MAX(b.max_blocked_count), 0) FROM #Win AS w LEFT JOIN #BE AS b ON b.win = w.win GROUP BY w.win;

        INSERT #BlkWait(win, wait_type, samples, blocked_sessions)
        SELECT b.win, ISNULL(s.wait_type, N'(unknown)'), COUNT(*), COUNT(DISTINCT s.session_id)
        FROM #BE AS b JOIN OPS.mon.BlockingSample AS s ON s.episode_id = b.episode_id
        WHERE s.blocking_session_id <> 0
        GROUP BY b.win, ISNULL(s.wait_type, N'(unknown)');

        INSERT #BlkHead(win, rn, head_program, head_login, head_database, episodes, minutes, max_victims, head_sql, top_wait_type)
        SELECT x.win, ROW_NUMBER() OVER (PARTITION BY x.win ORDER BY x.minutes DESC), x.head_program, x.head_login, x.head_database,
               x.episodes, x.minutes, x.max_victims, x.head_sql, x.top_wait_type
        FROM (SELECT b.win, b.head_program, b.head_login, b.head_database, COUNT(*) AS episodes, SUM(b.minutes) AS minutes,
                     MAX(b.max_blocked_count) AS max_victims, MAX(LEFT(COALESCE(b.head_input_buffer, b.head_sql), 400)) AS head_sql,
                     MAX(b.top_wait_type) AS top_wait_type
              FROM #BE AS b GROUP BY b.win, b.head_program, b.head_login, b.head_database) AS x;

        /* deadlocks, long queries, open transactions */
        INSERT #Mon SELECT w.win, N'deadlocks', COUNT(d.deadlock_hash)
        FROM #Win AS w LEFT JOIN OPS.mon.Deadlock AS d ON d.event_utc >= w.t0 AND d.event_utc < w.t1
             AND (d.database_name IN (SELECT database_name FROM #Db) OR d.database_name IS NULL)
        GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'longq_issues', COUNT(i.issue_id)
        FROM #Win AS w LEFT JOIN OPS.mon.Issue AS i ON i.first_seen_utc >= w.t0 AND i.first_seen_utc < w.t1 AND i.issue_key LIKE N'LONGQ:%'
        GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'opentran_issues', COUNT(i.issue_id)
        FROM #Win AS w LEFT JOIN OPS.mon.Issue AS i ON i.first_seen_utc >= w.t0 AND i.first_seen_utc < w.t1 AND i.issue_key LIKE N'OPENTRAN:%'
        GROUP BY w.win;

        /* server waits: hourly cumulative snapshots -> positive deltas */
        ;WITH S AS
        (
            SELECT w.win, s.wait_type, s.wait_ms - LAG(s.wait_ms) OVER (PARTITION BY w.win, s.wait_type ORDER BY s.snapshot_utc) AS d_ms
            FROM #Win AS w JOIN OPS.mon.WaitStatsSnapshot AS s ON s.snapshot_utc >= w.t0 AND s.snapshot_utc < w.t1
        )
        INSERT #Mon SELECT S.win, N'wait_' + x.grp, ISNULL(SUM(CASE WHEN S.d_ms > 0 THEN S.d_ms ELSE 0 END), 0) / 1000.0
        FROM S CROSS APPLY (SELECT CASE WHEN S.wait_type LIKE N'LCK[_]M[_]S%' AND S.wait_type NOT LIKE N'LCK[_]M[_]SCH%' THEN N'lock_s'
                                        WHEN S.wait_type LIKE N'LCK[_]M[_]%' THEN N'lock_other'
                                        WHEN S.wait_type LIKE N'PAGELATCH[_]%' THEN N'pagelatch'
                                        WHEN S.wait_type LIKE N'PAGEIOLATCH[_]%' THEN N'pageiolatch'
                                        WHEN S.wait_type = N'WRITELOG' THEN N'writelog'
                                        ELSE N'other' END AS grp) AS x
        GROUP BY S.win, x.grp;

        /* CPU, batch/s, PLE */
        INSERT #Mon SELECT w.win, N'cpu_avg', AVG(c.sql_cpu_pct * 1.0) FROM #Win AS w JOIN OPS.mon.CpuSample AS c ON c.sample_utc >= w.t0 AND c.sample_utc < w.t1 GROUP BY w.win;
        INSERT #Mon SELECT DISTINCT w.win, N'cpu_p95', PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY c.sql_cpu_pct) OVER (PARTITION BY w.win)
        FROM #Win AS w JOIN OPS.mon.CpuSample AS c ON c.sample_utc >= w.t0 AND c.sample_utc < w.t1;
        SELECT w.win, p.sample_utc, p.ple_sec,
               p.batch_requests_total - LAG(p.batch_requests_total) OVER (PARTITION BY w.win ORDER BY p.sample_utc) AS d_batch,
               DATEDIFF(SECOND, LAG(p.sample_utc) OVER (PARTITION BY w.win ORDER BY p.sample_utc), p.sample_utc) AS d_s
        INTO #P
        FROM #Win AS w JOIN OPS.mon.PerfSample AS p ON p.sample_utc >= w.t0 AND p.sample_utc < w.t1;
        INSERT #Mon SELECT P.win, N'batch_per_s', SUM(CASE WHEN P.d_batch > 0 THEN P.d_batch ELSE 0 END) * 1.0 / NULLIF(SUM(CASE WHEN P.d_batch > 0 THEN P.d_s ELSE 0 END), 0) FROM #P AS P GROUP BY P.win;
        INSERT #Mon SELECT P.win, N'ple_avg', AVG(P.ple_sec * 1.0) FROM #P AS P GROUP BY P.win;

        /* tempdb / version store */
        INSERT #Mon SELECT DISTINCT w.win, N'tempdb_used_p95', PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY t.used_mb) OVER (PARTITION BY w.win) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1;
        INSERT #Mon SELECT w.win, N'tempdb_used_max', MAX(t.used_mb) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1 GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'vs_avg', AVG(t.version_store_mb) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1 GROUP BY w.win;
        INSERT #Mon SELECT DISTINCT w.win, N'vs_p95', PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY t.version_store_mb) OVER (PARTITION BY w.win) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1;
        INSERT #Mon SELECT w.win, N'vs_max', MAX(t.version_store_mb) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1 GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'vs_tran_max_min', ISNULL(MAX(t.vs_longest_tran_s), 0) / 60.0 FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1 GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'tempdb_size_max', MAX(t.size_mb) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1 GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'tempdb_growths', COUNT(g.event_utc) FROM #Win AS w LEFT JOIN OPS.mon.TempdbGrowthEvent AS g ON g.event_utc >= w.t0 AND g.event_utc < w.t1 GROUP BY w.win;

        /* who held the version store (after window): distinct long versioning transactions */
        ;WITH T AS
        (
            SELECT t.sample_utc, t.vs_longest_tran_s, t.vs_longest_session_id, t.vs_longest_login, t.vs_longest_database, t.vs_longest_program, t.version_store_mb,
                   DATEADD(SECOND, -t.vs_longest_tran_s, t.sample_utc) AS tran_start_utc
            FROM OPS.mon.TempdbSample AS t
            WHERE t.sample_utc >= @a0 AND t.sample_utc < @a1 AND t.vs_longest_tran_s >= 600
        ), K AS
        (
            SELECT T.vs_longest_session_id, T.vs_longest_login, T.vs_longest_database, T.vs_longest_program,
                   DATEADD(MINUTE, 10 * (DATEDIFF(MINUTE, 0, T.tran_start_utc) / 10), 0) AS start_bucket,
                   MAX(T.vs_longest_tran_s) / 60.0 AS minutes, MIN(T.sample_utc) AS seen_from, MAX(T.sample_utc) AS seen_to, MAX(T.version_store_mb) AS vs_mb_max
            FROM T GROUP BY T.vs_longest_session_id, T.vs_longest_login, T.vs_longest_database, T.vs_longest_program,
                     DATEADD(MINUTE, 10 * (DATEDIFF(MINUTE, 0, T.tran_start_utc) / 10), 0)
        )
        INSERT #VsTran(rn, minutes, session_id, login_name, database_name, program_name, seen_from, seen_to, vs_mb_max)
        SELECT TOP (8) ROW_NUMBER() OVER (ORDER BY K.minutes DESC), K.minutes, K.vs_longest_session_id, K.vs_longest_login, K.vs_longest_database, K.vs_longest_program,
               K.seen_from, K.seen_to, K.vs_mb_max
        FROM K ORDER BY K.minutes DESC;

        INSERT #VsGen(rn, database_name, object_name, index_name, version_mb_max, version_mb_avg, samples)
        SELECT TOP (@FragTopTables) ROW_NUMBER() OVER (ORDER BY MAX(g.version_mb) DESC), g.database_name, g.object_name, g.index_name,
               MAX(g.version_mb), AVG(g.version_mb), COUNT(*)
        FROM OPS.mon.TempdbVersionGenerator AS g
        WHERE g.sample_utc >= @a0 AND g.sample_utc < @a1 AND g.object_name NOT LIKE N'(rowset%'
        GROUP BY g.database_name, g.object_name, g.index_name
        ORDER BY MAX(g.version_mb) DESC;

        /* I/O latency per window: selected databases' files + tempdb */
        ;WITH F AS
        (
            SELECT w.win, w.hours, CASE WHEN f.database_id = 2 THEN N'tempdb' ELSE N'data' END AS kind,
                   f.num_reads - LAG(f.num_reads) OVER (PARTITION BY w.win, f.database_id, f.file_id ORDER BY f.snapshot_utc) AS d_rd,
                   f.num_writes - LAG(f.num_writes) OVER (PARTITION BY w.win, f.database_id, f.file_id ORDER BY f.snapshot_utc) AS d_wr,
                   f.io_stall_read_ms - LAG(f.io_stall_read_ms) OVER (PARTITION BY w.win, f.database_id, f.file_id ORDER BY f.snapshot_utc) AS d_srd,
                   f.io_stall_write_ms - LAG(f.io_stall_write_ms) OVER (PARTITION BY w.win, f.database_id, f.file_id ORDER BY f.snapshot_utc) AS d_swr,
                   f.bytes_read - LAG(f.bytes_read) OVER (PARTITION BY w.win, f.database_id, f.file_id ORDER BY f.snapshot_utc) AS d_brd,
                   f.bytes_written - LAG(f.bytes_written) OVER (PARTITION BY w.win, f.database_id, f.file_id ORDER BY f.snapshot_utc) AS d_bwr
            FROM #Win AS w JOIN OPS.mon.FileStatsSnapshot AS f ON f.snapshot_utc >= w.t0 AND f.snapshot_utc < w.t1
            WHERE f.database_id = 2 OR f.database_id IN (SELECT database_id FROM #Db)
        ), G AS
        (
            SELECT F.win, F.kind,
                   SUM(CASE WHEN F.d_srd > 0 THEN F.d_srd ELSE 0 END) * 1.0 / NULLIF(SUM(CASE WHEN F.d_rd > 0 THEN F.d_rd ELSE 0 END), 0) AS read_ms,
                   SUM(CASE WHEN F.d_swr > 0 THEN F.d_swr ELSE 0 END) * 1.0 / NULLIF(SUM(CASE WHEN F.d_wr > 0 THEN F.d_wr ELSE 0 END), 0) AS write_ms,
                   SUM(CASE WHEN F.d_brd > 0 THEN F.d_brd ELSE 0 END) / 1048576.0 / NULLIF(MAX(F.hours), 0) AS read_mb_h,
                   SUM(CASE WHEN F.d_bwr > 0 THEN F.d_bwr ELSE 0 END) / 1048576.0 / NULLIF(MAX(F.hours), 0) AS write_mb_h
            FROM F GROUP BY F.win, F.kind
        )
        INSERT #Mon SELECT G.win, N'io_' + G.kind + N'_' + x.m, x.v
        FROM G CROSS APPLY (VALUES (N'read_ms', G.read_ms), (N'write_ms', G.write_ms), (N'read_mb_h', G.read_mb_h), (N'write_mb_h', G.write_mb_h)) AS x(m, v);
    END TRY
    BEGIN CATCH
        INSERT @notes VALUES (LEFT(CONCAT(N'OPS.mon history partially unavailable: ', ERROR_MESSAGE()), 1000));
    END CATCH;
END
ELSE
    INSERT @notes VALUES (N'OPS.mon is not installed on this instance: blocking, server waits, CPU, tempdb / version store and I/O sections are skipped (Query Store only).');

/* ============================ FRAGMENTATION OF THE VERSIONED TABLES ============================ */
CREATE TABLE #Frag (database_name sysname, object_name nvarchar(300), index_name sysname NULL, index_type nvarchar(60), fill_factor int,
                    page_count bigint, size_gb decimal(19,2), frag_pct decimal(9,1), version_mb_max decimal(19,2), note nvarchar(200));
IF @CheckFragmentation = 1 AND EXISTS (SELECT 1 FROM #VsGen)
BEGIN
    DECLARE @fdb sysname, @fobj nvarchar(300), @fvs decimal(19,2);
    DECLARE fc CURSOR LOCAL FAST_FORWARD FOR SELECT database_name, object_name, MAX(version_mb_max) FROM #VsGen GROUP BY database_name, object_name ORDER BY MAX(version_mb_max) DESC;
    OPEN fc; FETCH NEXT FROM fc INTO @fdb, @fobj, @fvs;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N'USE ' + QUOTENAME(@fdb) + N';
                INSERT #Frag(database_name, object_name, index_name, index_type, fill_factor, page_count, size_gb, frag_pct, version_mb_max, note)
                SELECT @fdb, @fobj, i.name, i.type_desc, i.fill_factor, ps.page_count, ps.page_count * 8 / 1048576.0,
                       CONVERT(decimal(9,1), ps.avg_fragmentation_in_percent), @fvs,
                       CASE WHEN i.fill_factor IN (0, 100) AND ps.avg_fragmentation_in_percent >= 30 AND ps.page_count >= 1000
                                 THEN N''fragmented, fill factor 100: page splits (RCSI version tag) - rebuild with FILLFACTOR 90''
                            WHEN ps.avg_fragmentation_in_percent >= 30 AND ps.page_count >= 1000 THEN N''fragmented - rebuild''
                            WHEN i.type = 0 THEN N''heap: version tag creates forwarded records - consider a clustered index''
                            ELSE N'''' END
                FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(@fobj), NULL, NULL, N''LIMITED'') AS ps
                JOIN sys.indexes AS i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
                WHERE ps.index_level = 0 AND ps.alloc_unit_type_desc = N''IN_ROW_DATA'';';
            EXEC sys.sp_executesql @sql, N'@fdb sysname, @fobj nvarchar(300), @fvs decimal(19,2)', @fdb = @fdb, @fobj = @fobj, @fvs = @fvs;
        END TRY
        BEGIN CATCH
            INSERT #Frag(database_name, object_name, note) VALUES (@fdb, @fobj, LEFT(CONCAT(N'physical stats failed: ', ERROR_MESSAGE()), 200));
        END CATCH;
        FETCH NEXT FROM fc INTO @fdb, @fobj, @fvs;
    END;
    CLOSE fc; DEALLOCATE fc;
END;

/* ============================ AGGREGATES PER WINDOW ============================ */
CREATE TABLE #Agg (win char(1) PRIMARY KEY, hours decimal(9,2), execs bigint, dur_ms decimal(19,1), cpu_ms decimal(19,1), reads bigint, writes bigint,
                   tempdb_pages bigint, max_dur_ms decimal(19,1), aborted bigint, lock_ms bigint, bufio_ms bigint, latch_ms bigint, log_ms bigint, par_ms bigint, all_ms bigint,
                   blocking_episodes decimal(19,3), blocking_minutes decimal(19,3), blocking_longest_min decimal(19,3), blocking_max_victims decimal(19,3), deadlocks decimal(19,3), longq_issues decimal(19,3), opentran_issues decimal(19,3), wait_lock_s decimal(19,3), wait_lock_other decimal(19,3), wait_pagelatch decimal(19,3), wait_pageiolatch decimal(19,3), wait_writelog decimal(19,3), cpu_avg decimal(19,3), cpu_p95 decimal(19,3), batch_per_s decimal(19,3), ple_avg decimal(19,3), tempdb_used_p95 decimal(19,3), tempdb_used_max decimal(19,3), vs_avg decimal(19,3), vs_p95 decimal(19,3), vs_max decimal(19,3), vs_tran_max_min decimal(19,3), tempdb_size_max decimal(19,3), tempdb_growths decimal(19,3), io_data_read_ms decimal(19,3), io_data_write_ms decimal(19,3), io_data_read_mb_h decimal(19,3), io_data_write_mb_h decimal(19,3), io_tempdb_read_ms decimal(19,3), io_tempdb_write_ms decimal(19,3), io_tempdb_read_mb_h decimal(19,3), io_tempdb_write_mb_h decimal(19,3));
INSERT #Agg(win, hours, execs, dur_ms, cpu_ms, reads, writes, tempdb_pages, max_dur_ms, aborted, lock_ms, bufio_ms, latch_ms, log_ms, par_ms, all_ms,
            blocking_episodes, blocking_minutes, blocking_longest_min, blocking_max_victims, deadlocks, longq_issues, opentran_issues, wait_lock_s, wait_lock_other, wait_pagelatch, wait_pageiolatch, wait_writelog, cpu_avg, cpu_p95, batch_per_s, ple_avg, tempdb_used_p95, tempdb_used_max, vs_avg, vs_p95, vs_max, vs_tran_max_min, tempdb_size_max, tempdb_growths, io_data_read_ms, io_data_write_ms, io_data_read_mb_h, io_data_write_mb_h, io_tempdb_read_ms, io_tempdb_write_ms, io_tempdb_read_mb_h, io_tempdb_write_mb_h)
SELECT w.win, w.hours, k.execs, k.dur_ms, k.cpu_ms, k.reads, k.writes, k.tempdb_pages, k.max_dur_ms, k.aborted, q.lock_ms, q.bufio_ms, q.latch_ms, q.log_ms, q.par_ms, q.all_ms,
       m.blocking_episodes, m.blocking_minutes, m.blocking_longest_min, m.blocking_max_victims, m.deadlocks, m.longq_issues, m.opentran_issues, m.wait_lock_s, m.wait_lock_other, m.wait_pagelatch, m.wait_pageiolatch, m.wait_writelog, m.cpu_avg, m.cpu_p95, m.batch_per_s, m.ple_avg, m.tempdb_used_p95, m.tempdb_used_max, m.vs_avg, m.vs_p95, m.vs_max, m.vs_tran_max_min, m.tempdb_size_max, m.tempdb_growths, m.io_data_read_ms, m.io_data_write_ms, m.io_data_read_mb_h, m.io_data_write_mb_h, m.io_tempdb_read_ms, m.io_tempdb_write_ms, m.io_tempdb_read_mb_h, m.io_tempdb_write_mb_h
FROM #Win AS w
LEFT JOIN (SELECT win, SUM(execs) AS execs, SUM(dur_ms) AS dur_ms, SUM(cpu_ms) AS cpu_ms, SUM(reads) AS reads, SUM(writes) AS writes,
                  SUM(tempdb_pages) AS tempdb_pages, MAX(max_dur_ms) AS max_dur_ms, SUM(aborted) AS aborted
           FROM #QsKpi GROUP BY win) AS k ON k.win = w.win
LEFT JOIN (SELECT win, SUM(CASE WHEN wait_category = N'Lock' THEN wait_ms ELSE 0 END) AS lock_ms,
                  SUM(CASE WHEN wait_category = N'Buffer IO' THEN wait_ms ELSE 0 END) AS bufio_ms,
                  SUM(CASE WHEN wait_category = N'Buffer Latch' THEN wait_ms ELSE 0 END) AS latch_ms,
                  SUM(CASE WHEN wait_category = N'Tran Log IO' THEN wait_ms ELSE 0 END) AS log_ms,
                  SUM(CASE WHEN wait_category = N'Parallelism' THEN wait_ms ELSE 0 END) AS par_ms,
                  SUM(wait_ms) AS all_ms
           FROM #QsWait GROUP BY win) AS q ON q.win = w.win
LEFT JOIN (SELECT win,
       MAX(CASE WHEN m.metric = N'blocking_episodes' THEN m.value END) AS blocking_episodes,
       MAX(CASE WHEN m.metric = N'blocking_minutes' THEN m.value END) AS blocking_minutes,
       MAX(CASE WHEN m.metric = N'blocking_longest_min' THEN m.value END) AS blocking_longest_min,
       MAX(CASE WHEN m.metric = N'blocking_max_victims' THEN m.value END) AS blocking_max_victims,
       MAX(CASE WHEN m.metric = N'deadlocks' THEN m.value END) AS deadlocks,
       MAX(CASE WHEN m.metric = N'longq_issues' THEN m.value END) AS longq_issues,
       MAX(CASE WHEN m.metric = N'opentran_issues' THEN m.value END) AS opentran_issues,
       MAX(CASE WHEN m.metric = N'wait_lock_s' THEN m.value END) AS wait_lock_s,
       MAX(CASE WHEN m.metric = N'wait_lock_other' THEN m.value END) AS wait_lock_other,
       MAX(CASE WHEN m.metric = N'wait_pagelatch' THEN m.value END) AS wait_pagelatch,
       MAX(CASE WHEN m.metric = N'wait_pageiolatch' THEN m.value END) AS wait_pageiolatch,
       MAX(CASE WHEN m.metric = N'wait_writelog' THEN m.value END) AS wait_writelog,
       MAX(CASE WHEN m.metric = N'cpu_avg' THEN m.value END) AS cpu_avg,
       MAX(CASE WHEN m.metric = N'cpu_p95' THEN m.value END) AS cpu_p95,
       MAX(CASE WHEN m.metric = N'batch_per_s' THEN m.value END) AS batch_per_s,
       MAX(CASE WHEN m.metric = N'ple_avg' THEN m.value END) AS ple_avg,
       MAX(CASE WHEN m.metric = N'tempdb_used_p95' THEN m.value END) AS tempdb_used_p95,
       MAX(CASE WHEN m.metric = N'tempdb_used_max' THEN m.value END) AS tempdb_used_max,
       MAX(CASE WHEN m.metric = N'vs_avg' THEN m.value END) AS vs_avg,
       MAX(CASE WHEN m.metric = N'vs_p95' THEN m.value END) AS vs_p95,
       MAX(CASE WHEN m.metric = N'vs_max' THEN m.value END) AS vs_max,
       MAX(CASE WHEN m.metric = N'vs_tran_max_min' THEN m.value END) AS vs_tran_max_min,
       MAX(CASE WHEN m.metric = N'tempdb_size_max' THEN m.value END) AS tempdb_size_max,
       MAX(CASE WHEN m.metric = N'tempdb_growths' THEN m.value END) AS tempdb_growths,
       MAX(CASE WHEN m.metric = N'io_data_read_ms' THEN m.value END) AS io_data_read_ms,
       MAX(CASE WHEN m.metric = N'io_data_write_ms' THEN m.value END) AS io_data_write_ms,
       MAX(CASE WHEN m.metric = N'io_data_read_mb_h' THEN m.value END) AS io_data_read_mb_h,
       MAX(CASE WHEN m.metric = N'io_data_write_mb_h' THEN m.value END) AS io_data_write_mb_h,
       MAX(CASE WHEN m.metric = N'io_tempdb_read_ms' THEN m.value END) AS io_tempdb_read_ms,
       MAX(CASE WHEN m.metric = N'io_tempdb_write_ms' THEN m.value END) AS io_tempdb_write_ms,
       MAX(CASE WHEN m.metric = N'io_tempdb_read_mb_h' THEN m.value END) AS io_tempdb_read_mb_h,
       MAX(CASE WHEN m.metric = N'io_tempdb_write_mb_h' THEN m.value END) AS io_tempdb_write_mb_h
           FROM #Mon AS m GROUP BY win) AS m ON m.win = w.win;

/* ============================ SAME QUERIES, BEFORE (B) vs AFTER (A) ============================ */
CREATE TABLE #QCmp (database_name sysname, query_hash binary(8), query_id bigint, object_name nvarchar(300), sql_text nvarchar(400), class varchar(5),
                    b_execs bigint, a_execs bigint, b_avg_ms decimal(19,1), a_avg_ms decimal(19,1), b_cpu_ms decimal(19,1), a_cpu_ms decimal(19,1),
                    b_reads decimal(19,1), a_reads decimal(19,1), b_writes decimal(19,1), a_writes decimal(19,1), b_lock_ms decimal(19,2), a_lock_ms decimal(19,2),
                    delta_pct decimal(9,1), impact_s_per_h decimal(19,1), b_time_ms decimal(19,1), a_time_at_b_ms decimal(19,1),
                    plan_changed bit, reads_ratio decimal(9,2), is_nolock bit, is_write bit, plans_b int, plans_a int);
INSERT #QCmp
SELECT b.database_name, b.query_hash, a.query_id, ISNULL(a.object_name, b.object_name), ISNULL(a.sql_text, b.sql_text),
       CASE WHEN b.dur_ms / NULLIF(b.execs, 0) < @OltpMaxMs THEN 'OLTP' WHEN b.dur_ms / NULLIF(b.execs, 0) >= @BatchMinMs THEN 'BATCH' ELSE 'MID' END,
       b.execs, a.execs, b.dur_ms / NULLIF(b.execs, 0), a.dur_ms / NULLIF(a.execs, 0), b.cpu_ms / NULLIF(b.execs, 0), a.cpu_ms / NULLIF(a.execs, 0),
       b.reads * 1.0 / NULLIF(b.execs, 0), a.reads * 1.0 / NULLIF(a.execs, 0), b.writes * 1.0 / NULLIF(b.execs, 0), a.writes * 1.0 / NULLIF(a.execs, 0),
       b.lock_wait_ms * 1.0 / NULLIF(b.execs, 0), a.lock_wait_ms * 1.0 / NULLIF(a.execs, 0),
       (a.dur_ms / NULLIF(a.execs, 0) - b.dur_ms / NULLIF(b.execs, 0)) * 100.0 / NULLIF(b.dur_ms / NULLIF(b.execs, 0), 0),
       (a.dur_ms / NULLIF(a.execs, 0) - b.dur_ms / NULLIF(b.execs, 0)) * (a.execs / NULLIF(@ah, 0)) / 1000.0,
       b.dur_ms, (a.dur_ms / NULLIF(a.execs, 0)) * b.execs,
       CASE WHEN a.top_plan_id <> b.top_plan_id THEN 1 ELSE 0 END,
       CONVERT(decimal(9,2), (a.reads * 1.0 / NULLIF(a.execs, 0)) / NULLIF(b.reads * 1.0 / NULLIF(b.execs, 0), 0)),
       CASE WHEN ISNULL(a.sql_text, b.sql_text) LIKE N'%NOLOCK%' OR ISNULL(a.sql_text, b.sql_text) LIKE N'%READUNCOMMITTED%' THEN 1 ELSE 0 END,
       CASE WHEN ISNULL(a.sql_text, b.sql_text) LIKE N'%)insert %' OR ISNULL(a.sql_text, b.sql_text) LIKE N'insert %' OR ISNULL(a.sql_text, b.sql_text) LIKE N'%)update %'
              OR ISNULL(a.sql_text, b.sql_text) LIKE N'update %' OR ISNULL(a.sql_text, b.sql_text) LIKE N'%)delete %' OR ISNULL(a.sql_text, b.sql_text) LIKE N'delete %'
              OR ISNULL(a.sql_text, b.sql_text) LIKE N'%)merge %' OR ISNULL(a.sql_text, b.sql_text) LIKE N'merge %' THEN 1 ELSE 0 END,
       b.plans, a.plans
FROM #QsQuery AS b
JOIN #QsQuery AS a ON a.database_name = b.database_name AND a.query_hash = b.query_hash AND a.win = 'A'
WHERE b.win = 'B' AND b.execs > 0 AND a.execs > 0;

CREATE TABLE #Idx (class varchar(5) PRIMARY KEY, queries int, b_time_h decimal(19,2), a_time_at_b_h decimal(19,2), index_pct decimal(9,1),
                   faster int, slower int, same int, coverage_pct decimal(9,1), nolock_pct decimal(9,1), write_pct decimal(9,1));
INSERT #Idx
SELECT x.class, COUNT(*), SUM(q.b_time_ms) / 3600000.0, SUM(q.a_time_at_b_ms) / 3600000.0,
       (SUM(q.a_time_at_b_ms) - SUM(q.b_time_ms)) * 100.0 / NULLIF(SUM(q.b_time_ms), 0),
       SUM(CASE WHEN q.delta_pct <= -10 THEN 1 ELSE 0 END), SUM(CASE WHEN q.delta_pct >= 10 THEN 1 ELSE 0 END), SUM(CASE WHEN ABS(q.delta_pct) < 10 THEN 1 ELSE 0 END),
       SUM(q.b_time_ms) * 100.0 / NULLIF((SELECT SUM(dur_ms) FROM #QsQuery WHERE win = 'B' AND (x.class = 'ALL' OR
                                             (x.class = 'OLTP' AND dur_ms / NULLIF(execs, 0) < @OltpMaxMs) OR
                                             (x.class = 'BATCH' AND dur_ms / NULLIF(execs, 0) >= @BatchMinMs) OR
                                             (x.class = 'MID' AND dur_ms / NULLIF(execs, 0) >= @OltpMaxMs AND dur_ms / NULLIF(execs, 0) < @BatchMinMs))), 0),
       SUM(CASE WHEN q.is_nolock = 1 THEN q.b_execs ELSE 0 END) * 100.0 / NULLIF(SUM(q.b_execs), 0),
       SUM(CASE WHEN q.is_write = 1 THEN q.b_time_ms ELSE 0 END) * 100.0 / NULLIF(SUM(q.b_time_ms), 0)
FROM #QCmp AS q
CROSS APPLY (VALUES ('ALL'), (q.class)) AS x(class)
GROUP BY x.class;

/* ============================ SCORECARD ============================ */
CREATE TABLE #Score (seq int PRIMARY KEY, grp nvarchar(60), metric nvarchar(80), unit varchar(8), direction smallint,
                     b decimal(19,3) NULL, a decimal(19,3) NULL, c decimal(19,3) NULL, pct decimal(19,1) NULL, verdict varchar(6) NULL, note nvarchar(300) NULL);
INSERT #Score(seq, grp, metric, unit, direction, b, a, c, pct, verdict, note)
SELECT x.seq, x.grp, x.metric, x.unit, x.direction, x.b, x.a, x.c,
       CASE WHEN x.unit = 'idx' THEN x.a
            WHEN x.b IS NULL OR x.a IS NULL THEN NULL WHEN x.b = 0 AND x.a = 0 THEN 0 WHEN x.b = 0 THEN NULL ELSE (x.a - x.b) * 100.0 / x.b END,
       CASE WHEN x.unit = 'idx' THEN CASE WHEN x.a IS NULL THEN 'n/a' WHEN x.a <= -10 THEN 'better' WHEN x.a >= 10 THEN 'worse' ELSE 'same' END
            WHEN x.b IS NULL OR x.a IS NULL THEN 'n/a'
            WHEN x.direction = 0 THEN 'info'
            WHEN x.b = 0 AND x.a = 0 THEN 'same'
            WHEN x.b = 0 THEN CASE WHEN x.direction = -1 THEN 'worse' ELSE 'better' END
            WHEN ABS((x.a - x.b) * 100.0 / x.b) < 10 THEN 'same'
            WHEN (x.a - x.b) * x.direction > 0 THEN 'better' ELSE 'worse' END,
       x.note
FROM (SELECT 1 AS one) AS o
LEFT JOIN #Agg AS B ON B.win = 'B'
LEFT JOIN #Agg AS A ON A.win = 'A'
LEFT JOIN #Agg AS C ON C.win = 'C'
LEFT JOIN #Idx AS IA ON IA.class = 'ALL'
LEFT JOIN #Idx AS IO ON IO.class = 'OLTP'
LEFT JOIN #Idx AS IB ON IB.class = 'BATCH'
CROSS APPLY (VALUES
    /* 1. did RCSI remove waiting? */
    (10, N'1. Did RCSI remove waiting?', N'Lock wait per execution (queries)',      'ms',   -1, B.lock_ms * 1.0 / NULLIF(B.execs, 0), A.lock_ms * 1.0 / NULLIF(A.execs, 0), C.lock_ms * 1.0 / NULLIF(C.execs, 0), N'Query Store wait category Lock - the wait RCSI removes for readers'),
    (11, N'1. Did RCSI remove waiting?', N'Lock wait, total',                       's/h',  -1, B.lock_ms / 1000.0 / NULLIF(@bh, 0), A.lock_ms / 1000.0 / NULLIF(@ah, 0), C.lock_ms / 1000.0 / NULLIF(@ch, 0), NULL),
    (12, N'1. Did RCSI remove waiting?', N'Lock share of all query waits',          '%',    -1, B.lock_ms * 100.0 / NULLIF(B.all_ms, 0), A.lock_ms * 100.0 / NULLIF(A.all_ms, 0), C.lock_ms * 100.0 / NULLIF(C.all_ms, 0), N'how much of the waiting was locks at all'),
    (13, N'1. Did RCSI remove waiting?', N'Shared-lock waits, whole instance',      's/h',  -1, B.wait_lock_s / NULLIF(@bh, 0), A.wait_lock_s / NULLIF(@ah, 0), C.wait_lock_s / NULLIF(@ch, 0), N'LCK_M_S / IS: readers waiting for writers - RCSI removes these'),
    (14, N'1. Did RCSI remove waiting?', N'Other lock waits, whole instance',       's/h',  -1, B.wait_lock_other / NULLIF(@bh, 0), A.wait_lock_other / NULLIF(@ah, 0), C.wait_lock_other / NULLIF(@ch, 0), N'LCK_M_X / U / IX / SCH: writers waiting for writers, schema locks - RCSI does not change these'),
    (15, N'1. Did RCSI remove waiting?', N'Blocking episodes',                      '/day', -1, B.blocking_episodes * 24 / NULLIF(@bh, 0), A.blocking_episodes * 24 / NULLIF(@ah, 0), C.blocking_episodes * 24 / NULLIF(@ch, 0), N'OPS.mon sampler, waits of 15 s or more'),
    (16, N'1. Did RCSI remove waiting?', N'Time spent blocked',                     'min/d', -1, B.blocking_minutes * 24 / NULLIF(@bh, 0), A.blocking_minutes * 24 / NULLIF(@ah, 0), C.blocking_minutes * 24 / NULLIF(@ch, 0), N'sum of episode durations per day'),
    (17, N'1. Did RCSI remove waiting?', N'Longest blocking episode',               'min',  -1, B.blocking_longest_min, A.blocking_longest_min, C.blocking_longest_min, NULL),
    (18, N'1. Did RCSI remove waiting?', N'Deadlocks',                              '/day', -1, B.deadlocks * 24 / NULLIF(@bh, 0), A.deadlocks * 24 / NULLIF(@ah, 0), C.deadlocks * 24 / NULLIF(@ch, 0), NULL),
    /* 2. same work, faster or slower? */
    (20, N'2. Same queries: faster or slower?', N'All matched queries',             'idx',  -1, 0, IA.index_pct, NULL, CONCAT(N'time the BEFORE workload would take at AFTER speeds; ', IA.queries, N' queries, ', FORMAT(IA.coverage_pct, 'N0'), N'% of the before time')),
    (21, N'2. Same queries: faster or slower?', N'OLTP queries (< 100 ms)',         'idx',  -1, 0, IO.index_pct, NULL, CONCAT(IO.queries, N' queries: ', IO.faster, N' faster, ', IO.slower, N' slower, ', IO.same, N' same; ', FORMAT(IO.nolock_pct, 'N0'), N'% of executions use NOLOCK')),
    (22, N'2. Same queries: faster or slower?', N'Batch queries (1 s and more)',    'idx',  -1, 0, IB.index_pct, NULL, CONCAT(IB.queries, N' queries: ', IB.faster, N' faster, ', IB.slower, N' slower, ', IB.same, N' same; ', FORMAT(IB.write_pct, 'N0'), N'% of their time is INSERT / UPDATE / DELETE / MERGE')),
    (23, N'2. Same queries: faster or slower?', N'Avg duration per execution (all)', 'ms',  -1, B.dur_ms / NULLIF(B.execs, 0), A.dur_ms / NULLIF(A.execs, 0), C.dur_ms / NULLIF(C.execs, 0), N'raw average - moves with the query mix'),
    (24, N'2. Same queries: faster or slower?', N'CPU per execution',               'ms',   -1, B.cpu_ms / NULLIF(B.execs, 0), A.cpu_ms / NULLIF(A.execs, 0), C.cpu_ms / NULLIF(C.execs, 0), NULL),
    (25, N'2. Same queries: faster or slower?', N'Logical reads per execution',     'pages', -1, B.reads * 1.0 / NULLIF(B.execs, 0), A.reads * 1.0 / NULLIF(A.execs, 0), C.reads * 1.0 / NULLIF(C.execs, 0), N'more pages per execution = page splits (version tag) or plan changes'),
    (26, N'2. Same queries: faster or slower?', N'Logical writes per execution',    'pages', -1, B.writes * 1.0 / NULLIF(B.execs, 0), A.writes * 1.0 / NULLIF(A.execs, 0), C.writes * 1.0 / NULLIF(C.execs, 0), N'the 14-byte version tag is written on every modified row'),
    /* 3. what does it cost? */
    (30, N'3. What does RCSI cost?', N'Version store, typical peak (p95)',          'MB',   -1, B.vs_p95, A.vs_p95, C.vs_p95, N'row versions kept in tempdb; 95% of the samples are below this'),
    (31, N'3. What does RCSI cost?', N'Version store, maximum',                     'MB',   -1, B.vs_max, A.vs_max, C.vs_max, NULL),
    (32, N'3. What does RCSI cost?', N'tempdb used, typical peak (p95)',            'MB',   -1, B.tempdb_used_p95, A.tempdb_used_p95, C.tempdb_used_p95, NULL),
    (33, N'3. What does RCSI cost?', N'tempdb used, maximum',                       'MB',   -1, B.tempdb_used_max, A.tempdb_used_max, C.tempdb_used_max, CONCAT(N'tempdb size ', FORMAT(A.tempdb_size_max / 1024.0, 'N0'), N' GB')),
    (34, N'3. What does RCSI cost?', N'Longest transaction holding versions',      'min',  -1, B.vs_tran_max_min, A.vs_tran_max_min, C.vs_tran_max_min, N'while it runs, no version created after it can be cleaned up'),
    (35, N'3. What does RCSI cost?', N'tempdb autogrowth events',                   '',     -1, B.tempdb_growths, A.tempdb_growths, C.tempdb_growths, NULL),
    (36, N'3. What does RCSI cost?', N'Disk-read waits (Buffer IO)',                's/h',  -1, B.bufio_ms / 1000.0 / NULLIF(@bh, 0), A.bufio_ms / 1000.0 / NULLIF(@ah, 0), C.bufio_ms / 1000.0 / NULLIF(@ch, 0), N'PAGEIOLATCH: queries waiting for pages from disk'),
    (37, N'3. What does RCSI cost?', N'Data file read latency',                     'ms',   -1, B.io_data_read_ms, A.io_data_read_ms, C.io_data_read_ms, N'selected databases; RDS: tempdb shares the volume and its IOPS'),
    (38, N'3. What does RCSI cost?', N'Data file write latency',                    'ms',   -1, B.io_data_write_ms, A.io_data_write_ms, C.io_data_write_ms, NULL),
    (39, N'3. What does RCSI cost?', N'tempdb written per hour',                    'MB',   -1, B.io_tempdb_write_mb_h, A.io_tempdb_write_mb_h, C.io_tempdb_write_mb_h, N'version store traffic shows up here'),
    (40, N'3. What does RCSI cost?', N'tempdb write latency',                       'ms',   -1, B.io_tempdb_write_ms, A.io_tempdb_write_ms, C.io_tempdb_write_ms, NULL),
    (41, N'3. What does RCSI cost?', N'Page life expectancy',                       's',    +1, B.ple_avg, A.ple_avg, C.ple_avg, N'how long a page stays in memory - lower = memory pressure'),
    (42, N'3. What does RCSI cost?', N'Log write waits (WRITELOG)',                 's/h',  -1, B.wait_writelog / NULLIF(@bh, 0), A.wait_writelog / NULLIF(@ah, 0), C.wait_writelog / NULLIF(@ch, 0), NULL),
    (43, N'3. What does RCSI cost?', N'tempdb page contention (PAGELATCH)',         's/h',  -1, B.wait_pagelatch / NULLIF(@bh, 0), A.wait_pagelatch / NULLIF(@ah, 0), C.wait_pagelatch / NULLIF(@ch, 0), NULL),
    (44, N'3. What does RCSI cost?', N'SQL CPU, average',                           '%',    -1, B.cpu_avg, A.cpu_avg, C.cpu_avg, NULL),
    (45, N'3. What does RCSI cost?', N'SQL CPU, busy hours (p95)',                  '%',    -1, B.cpu_p95, A.cpu_p95, C.cpu_p95, NULL),
    /* 4. is the workload comparable? */
    (50, N'4. Is the workload comparable?', N'Query executions',                    '/h',    0, B.execs / NULLIF(@bh, 0), A.execs / NULLIF(@ah, 0), C.execs / NULLIF(@ch, 0), N'if this moved a lot, totals moved with it - trust the per-execution rows'),
    (51, N'4. Is the workload comparable?', N'Batch requests',                      '/s',    0, B.batch_per_s, A.batch_per_s, C.batch_per_s, NULL),
    (52, N'4. Is the workload comparable?', N'Total query time',                    's/h',   0, B.dur_ms / 1000.0 / NULLIF(@bh, 0), A.dur_ms / 1000.0 / NULLIF(@ah, 0), C.dur_ms / 1000.0 / NULLIF(@ch, 0), N'sum of elapsed time of all executions'),
    (53, N'4. Is the workload comparable?', N'Parallelism waits',                   's/h',   0, B.par_ms / 1000.0 / NULLIF(@bh, 0), A.par_ms / 1000.0 / NULLIF(@ah, 0), C.par_ms / 1000.0 / NULLIF(@ch, 0), N'CXPACKET: big parallel batch queries running'),
    (54, N'4. Is the workload comparable?', N'Aborted / failed executions',         '/h',   -1, B.aborted / NULLIF(@bh, 0), A.aborted / NULLIF(@ah, 0), C.aborted / NULLIF(@ch, 0), N'timeouts, cancels, errors')
) AS x(seq, grp, metric, unit, direction, b, a, c, note)
WHERE NOT (x.b IS NULL AND x.a IS NULL) AND NOT (x.unit = 'idx' AND x.a IS NULL);

/* ============================ FINDINGS (plain language) ============================ */
CREATE TABLE #Find (seq int IDENTITY PRIMARY KEY, level varchar(5), title nvarchar(120), text nvarchar(2000));
DECLARE @f_b decimal(19,3), @f_a decimal(19,3), @f_pct decimal(19,1), @f_b2 decimal(19,3), @f_a2 decimal(19,3), @f_pct2 decimal(19,1), @txt nvarchar(2000), @n int;
DECLARE @idx_all decimal(9,1) = (SELECT index_pct FROM #Idx WHERE class = 'ALL'),
        @idx_oltp decimal(9,1) = (SELECT index_pct FROM #Idx WHERE class = 'OLTP'),
        @idx_batch decimal(9,1) = (SELECT index_pct FROM #Idx WHERE class = 'BATCH'),
        @nolock_pct decimal(9,1) = (SELECT nolock_pct FROM #Idx WHERE class = 'OLTP'),
        @vs_size_gb decimal(19,1) = (SELECT tempdb_size_max / 1024.0 FROM #Agg WHERE win = 'A');

/* 1. workload comparability */
SELECT @f_b = b, @f_a = a, @f_pct = pct FROM #Score WHERE seq = 50;
SELECT @f_b2 = b, @f_a2 = a, @f_pct2 = pct FROM #Score WHERE seq = 51;
IF ABS(ISNULL(@f_pct, 0)) > 30 OR ABS(ISNULL(@f_pct2, 0)) > 30
    INSERT #Find(level, title, text) VALUES ('warn', N'The two periods do not carry the same workload',
        CONCAT(N'Query executions: ', FORMAT(@f_b, 'N0'), N' per hour before vs ', FORMAT(@f_a, 'N0'), N' after (', CASE WHEN @f_pct > 0 THEN N'+' ELSE N'' END, FORMAT(@f_pct, 'N0'), N'%)',
               CASE WHEN @f_b2 IS NOT NULL THEN CONCAT(N'; batch requests ', FORMAT(@f_b2, 'N0'), N' vs ', FORMAT(@f_a2, 'N0'), N' per second') ELSE N'' END,
               N'. Every "per hour" total (CPU, waits, total query time, blocking minutes) moves with the workload, so read them as context, not as the RCSI effect. ',
               N'The fair comparisons are the per-execution rows, the same-weekday window (section 1) and the "same queries" index (section 2).'));
ELSE
    INSERT #Find(level, title, text) VALUES ('info', N'The two periods carry a comparable workload',
        CONCAT(N'Query executions per hour: ', FORMAT(@f_b, 'N0'), N' before vs ', FORMAT(@f_a, 'N0'), N' after (', CASE WHEN @f_pct > 0 THEN N'+' ELSE N'' END, FORMAT(ISNULL(@f_pct, 0), 'N0'), N'%). Totals can be compared directly.'));

/* 2. was there lock waiting to remove, and did it go? */
SELECT @f_b = b, @f_a = a, @f_pct = pct FROM #Score WHERE seq = 12;   /* lock share */
SELECT @f_b2 = b, @f_a2 = a, @f_pct2 = pct FROM #Score WHERE seq = 11; /* lock s/h */
IF @f_b IS NOT NULL
BEGIN
    IF @f_b < 2
        INSERT #Find(level, title, text) VALUES ('bad', N'There was almost no lock waiting for RCSI to remove',
            CONCAT(N'Before the switch, lock waits were ', FORMAT(@f_b, 'N1'), N'% of all query waits (', FORMAT(@f_b2, 'N1'), N' seconds per hour across the selected databases). ',
                   N'RCSI only helps readers that wait for writers; ',
                   CASE WHEN @nolock_pct >= 20 THEN CONCAT(FORMAT(@nolock_pct, 'N0'), N'% of the OLTP executions read with NOLOCK / READ UNCOMMITTED, which never waited for writers in the first place and gain nothing from RCSI. ') ELSE N'' END,
                   N'After the switch lock waits are ', FORMAT(@f_a2, 'N1'), N' s/h (', CASE WHEN @f_pct2 > 0 THEN N'+' ELSE N'' END, FORMAT(@f_pct2, 'N0'), N'%). The benefit side of RCSI is therefore small on this server.'));
    ELSE IF @f_pct2 <= -50
        INSERT #Find(level, title, text) VALUES ('good', N'RCSI removed most of the lock waiting',
            CONCAT(N'Lock waits fell from ', FORMAT(@f_b2, 'N1'), N' to ', FORMAT(@f_a2, 'N1'), N' seconds per hour (', FORMAT(@f_pct2, 'N0'), N'%); they were ', FORMAT(@f_b, 'N1'), N'% of all query waits before and are ', FORMAT(@f_a, 'N1'), N'% now.'));
    ELSE
        INSERT #Find(level, title, text) VALUES ('warn', N'Lock waiting did not fall as expected',
            CONCAT(N'Lock waits: ', FORMAT(@f_b2, 'N1'), N' s/h before, ', FORMAT(@f_a2, 'N1'), N' s/h after (', CASE WHEN @f_pct2 > 0 THEN N'+' ELSE N'' END, FORMAT(@f_pct2, 'N0'), N'%). ',
                   N'Check the wait types in section 3: RCSI changes only READ COMMITTED readers - writers vs writers (LCK_M_X / U), schema locks, and sessions running REPEATABLE READ / SERIALIZABLE (e.g. .NET TransactionScope default) still block.'));
END;

/* 3. same queries index */
IF @idx_all IS NOT NULL
BEGIN
    SET @txt = CONCAT(N'Taking every query that ran in both periods at its own BEFORE execution count, the same work takes ',
                      CASE WHEN @idx_all >= 0 THEN CONCAT(N'<b>', FORMAT(@idx_all, 'N0'), N'% longer</b>') ELSE CONCAT(N'<b>', FORMAT(-@idx_all, 'N0'), N'% less time</b>') END,
                      N' after RCSI',
                      CASE WHEN @idx_oltp IS NOT NULL THEN CONCAT(N'; OLTP queries (under ', @OltpMaxMs, N' ms): ', CASE WHEN @idx_oltp > 0 THEN N'+' ELSE N'' END, FORMAT(@idx_oltp, 'N0'), N'%') ELSE N'' END,
                      CASE WHEN @idx_batch IS NOT NULL THEN CONCAT(N'; batch queries (', @BatchMinMs / 1000, N' s and more): ', CASE WHEN @idx_batch > 0 THEN N'+' ELSE N'' END, FORMAT(@idx_batch, 'N0'), N'%') ELSE N'' END,
                      N'. This index is independent of how much work ran in each period.');
    INSERT #Find(level, title, text)
    VALUES (CASE WHEN @idx_all <= -10 THEN 'good' WHEN @idx_all >= 10 THEN 'bad' ELSE 'info' END,
            CASE WHEN @idx_all <= -10 THEN N'The same queries run faster' WHEN @idx_all >= 10 THEN N'The same queries run slower' ELSE N'The same queries run at about the same speed' END, @txt);
END;

/* 4. batch regressions: same plan, many more reads -> version tag page splits */
DECLARE @reg_n int, @reg_obj nvarchar(300), @reg_ratio decimal(9,1), @reg_plan int, @reg_ms_b decimal(19,1), @reg_ms_a decimal(19,1);
SELECT @reg_n = COUNT(*), @reg_ratio = AVG(reads_ratio), @reg_plan = SUM(CONVERT(int, plan_changed)),
       @reg_ms_b = SUM(b_avg_ms * b_execs) / NULLIF(SUM(b_execs), 0), @reg_ms_a = SUM(a_avg_ms * b_execs) / NULLIF(SUM(b_execs), 0)
FROM #QCmp WHERE class = 'BATCH' AND delta_pct >= 50 AND reads_ratio >= 2;
SELECT TOP (1) @reg_obj = object_name FROM #QCmp WHERE class = 'BATCH' AND delta_pct >= 50 AND reads_ratio >= 2 AND object_name IS NOT NULL
GROUP BY object_name ORDER BY SUM(impact_s_per_h) DESC;
IF @reg_n >= 2
    INSERT #Find(level, title, text) VALUES ('bad', CONCAT(@reg_n, N' batch statements read ', FORMAT(@reg_ratio, 'N1'), N' times more pages per execution'),
        CONCAT(CASE WHEN @reg_obj IS NOT NULL THEN CONCAT(N'Mostly in <b>', @reg_obj, N'</b>: ') ELSE N'' END,
               N'average ', FORMAT(@reg_ms_b / 1000.0, 'N0'), N' s before, ', FORMAT(@reg_ms_a / 1000.0, 'N0'), N' s after per execution. ',
               CASE WHEN @reg_plan * 2 <= @reg_n THEN CONCAT(N'The execution plan did not change for ', @reg_n - @reg_plan, N' of them, so the extra reads come from the data itself: ')
                    ELSE CONCAT(N'The plan changed for ', @reg_plan, N' of them (compare the plans in Query Store); for the rest the extra reads come from the data itself: ') END,
               N'after the switch every row that is modified for the first time grows by a 14-byte version tag; pages with no free space (fill factor 100) split, ',
               N'so the DELETE / INSERT / MERGE steps of the load now touch far more pages and the readers that follow traverse version chains in tempdb. ',
               N'Fix: rebuild the versioned tables (section "Tables that generate versions") with FILLFACTOR 90 once, then keep them in the weekly IndexOptimize; ',
               N'the effect fades as all rows carry the tag.'));
ELSE
BEGIN
    SET @n = (SELECT COUNT(*) FROM #QCmp WHERE class = 'BATCH' AND delta_pct >= 50);
    IF @n > 0
        INSERT #Find(level, title, text) VALUES ('warn', N'Some batch statements got slower',
            CONCAT(@n, N' batch statements run 50% or more slower per execution - see "Queries that got slower". Rising reads with the same plan point at page splits / version chains; a changed plan points at the optimizer.'));
END;

/* 5. blocking */
SELECT @f_b = b, @f_a = a, @f_pct = pct FROM #Score WHERE seq = 16;   /* blocked minutes/day */
DECLARE @blk_s_pct decimal(9,1) = (SELECT SUM(CASE WHEN wait_type LIKE N'LCK[_]M[_]S%' AND wait_type NOT LIKE N'LCK[_]M[_]SCH%' THEN samples ELSE 0 END) * 100.0 / NULLIF(SUM(samples), 0) FROM #BlkWait WHERE win = 'A'),
        @blk_top nvarchar(60) = (SELECT TOP (1) wait_type FROM #BlkWait WHERE win = 'A' ORDER BY samples DESC),
        @blk_head nvarchar(400) = (SELECT TOP (1) CONCAT(ISNULL(head_program, N'?'), N' / ', ISNULL(head_login, N'?'), CASE WHEN head_database IS NOT NULL THEN CONCAT(N' in ', head_database) END) FROM #BlkHead WHERE win = 'A' AND rn = 1);
IF @f_b IS NOT NULL
BEGIN
    IF @f_pct >= 25
        INSERT #Find(level, title, text) VALUES ('bad', N'Blocking got worse, and it is not the kind RCSI fixes',
            CONCAT(N'Sessions spent ', FORMAT(@f_a, 'N0'), N' minutes per day blocked (15 s or longer) vs ', FORMAT(@f_b, 'N0'), N' before (+', FORMAT(@f_pct, 'N0'), N'%). ',
                   CASE WHEN @blk_top IS NOT NULL THEN CONCAT(N'The blocked sessions mostly wait on <b>', @blk_top, N'</b>; only ', FORMAT(ISNULL(@blk_s_pct, 0), 'N0'), N'% of the blocked samples are shared-lock waits (the only kind RCSI removes) - the rest are writers waiting for writers or schema locks. ') ELSE N'' END,
                   CASE WHEN @blk_head IS NOT NULL THEN CONCAT(N'Biggest head blocker: ', @blk_head, N'. ') ELSE N'' END,
                   N'Longer-running load statements hold their X locks longer, which is the mechanism here (see finding on batch statements).'));
    ELSE IF @f_pct <= -25
        INSERT #Find(level, title, text) VALUES ('good', N'Less blocking',
            CONCAT(N'Sessions spent ', FORMAT(@f_a, 'N0'), N' minutes per day blocked vs ', FORMAT(@f_b, 'N0'), N' before (', FORMAT(@f_pct, 'N0'), N'%).',
                   CASE WHEN @blk_top IS NOT NULL THEN CONCAT(N' Remaining blocked waits are mostly ', @blk_top, N'.') ELSE N'' END));
    ELSE
        INSERT #Find(level, title, text) VALUES ('info', N'Blocking unchanged',
            CONCAT(N'About ', FORMAT(@f_a, 'N0'), N' minutes per day blocked before and after.',
                   CASE WHEN @blk_top IS NOT NULL THEN CONCAT(N' Blocked sessions mostly wait on ', @blk_top, N'; ', FORMAT(ISNULL(@blk_s_pct, 0), 'N0'), N'% are shared-lock waits.') ELSE N'' END));
END;

/* 6. version store */
SELECT @f_a = vs_max FROM #Agg WHERE win = 'A';
DECLARE @vs_pct int = CONVERT(int, @f_a * 100.0 / NULLIF(@vs_size_gb * 1024, 0)),
        @vs_who nvarchar(400) = (SELECT TOP (1) CONCAT(FORMAT(minutes, 'N0'), N' min by ', ISNULL(login_name, N'?'), N' / ', ISNULL(program_name, N'?'), N' in ', ISNULL(database_name, N'?')) FROM #VsTran WHERE rn = 1),
        @vs_gen nvarchar(400) = (SELECT STRING_AGG(CONVERT(nvarchar(max), object_name), N', ') WITHIN GROUP (ORDER BY rn) FROM (SELECT TOP (3) rn, object_name FROM #VsGen ORDER BY rn) AS g);
IF @f_a IS NOT NULL
    INSERT #Find(level, title, text)
    VALUES (CASE WHEN @vs_pct >= 50 THEN 'bad' WHEN @vs_pct >= 15 THEN 'warn' ELSE 'info' END,
            CONCAT(N'Version store peaked at ', FORMAT(@f_a / 1024.0, 'N1'), N' GB', CASE WHEN @vs_pct IS NOT NULL THEN CONCAT(N' = ', @vs_pct, N'% of tempdb') ELSE N'' END),
            CONCAT(N'This is the price of RCSI: every modified row keeps its previous version in tempdb until no transaction can still need it. ',
                   CASE WHEN @vs_who IS NOT NULL THEN CONCAT(N'The longest transaction holding versions ran ', @vs_who, N' - while it runs nothing newer can be cleaned up. ') ELSE N'' END,
                   CASE WHEN @vs_gen IS NOT NULL THEN CONCAT(N'The versions come mainly from ', @vs_gen, N'. ') ELSE N'' END,
                   CASE WHEN @vs_pct >= 50 THEN CONCAT(N'<b>Risk:</b> if tempdb fills, every versioned database stops with error 3966 / 3967. tempdb is ', FORMAT(@vs_size_gb, 'N0'), N' GB; OPS.mon check TEMPDB_VS alerts at 50% / 75%. Options: split the load into shorter transactions, give tempdb more space (RDS: a db.m5d / r5d class puts tempdb on local instance store), or run the heaviest load steps when fewer readers are active.')
                        ELSE N'Keep the TEMPDB_VS alert on; the size follows the length of the longest transaction, not the amount of data.' END));

/* 7. I/O */
SELECT @f_b = b, @f_a = a, @f_pct = pct FROM #Score WHERE seq = 36;   /* buffer IO s/h */
SELECT @f_b2 = b, @f_a2 = a, @f_pct2 = pct FROM #Score WHERE seq = 37; /* read latency */
DECLARE @ple_pct decimal(19,1) = (SELECT pct FROM #Score WHERE seq = 41), @tdb_wr_b decimal(19,1), @tdb_wr_a decimal(19,1);
SELECT @tdb_wr_b = b, @tdb_wr_a = a FROM #Score WHERE seq = 39;
IF @f_pct >= 50 OR @f_pct2 >= 25
    INSERT #Find(level, title, text) VALUES ('warn', N'More disk reads, slower disk',
        CONCAT(N'Queries waited ', FORMAT(@f_a, 'N0'), N' s/h for pages from disk vs ', FORMAT(@f_b, 'N0'), N' before',
               CASE WHEN @f_b > 0 THEN CONCAT(N' (x ', FORMAT(@f_a / NULLIF(@f_b, 0), 'N1'), N')') ELSE N'' END,
               CASE WHEN @f_b2 IS NOT NULL THEN CONCAT(N'; read latency ', FORMAT(@f_b2, 'N0'), N' -> ', FORMAT(@f_a2, 'N0'), N' ms') ELSE N'' END,
               CASE WHEN @ple_pct IS NOT NULL THEN CONCAT(N'; page life expectancy ', CASE WHEN @ple_pct > 0 THEN N'+' ELSE N'' END, FORMAT(@ple_pct, 'N0'), N'%') ELSE N'' END,
               N'. Two RCSI effects add up here: the version store is written and read in tempdb (', FORMAT(ISNULL(@tdb_wr_b, 0) / 1024.0, 'N1'), N' -> ', FORMAT(ISNULL(@tdb_wr_a, 0) / 1024.0, 'N1'),
               N' GB per hour written to tempdb), which on RDS shares the EBS volume and its IOPS with the data files, and split pages take more buffer pool. ',
               N'Part of it is also the heavier workload of the after period. Check CloudWatch ReadIOPS / WriteIOPS against the provisioned limit and DiskQueueDepth.'));

/* 8. fragmentation of versioned tables */
SELECT @n = COUNT(*) FROM #Frag WHERE note LIKE N'fragmented%';
DECLARE @ff100 bit = CASE WHEN EXISTS (SELECT 1 FROM #Frag WHERE note LIKE N'%fill factor 100%') THEN 1 ELSE 0 END,
        @frag_list nvarchar(1000) = (SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT(object_name, N' (', ISNULL(index_name, N'heap'), N', ', FORMAT(frag_pct, 'N0'), N'%)')), N', ') WITHIN GROUP (ORDER BY page_count DESC)
                                     FROM (SELECT TOP (4) object_name, index_name, frag_pct, page_count FROM #Frag WHERE note LIKE N'fragmented%' ORDER BY page_count DESC) AS f);
IF @n > 0
    INSERT #Find(level, title, text) VALUES ('bad', CONCAT(@n, N' indexes on the versioned tables are fragmented'),
        CONCAT(N'Of the tables that generate row versions, ', @n, N' indexes are 30% or more fragmented',
               CASE WHEN @ff100 = 1 THEN N' with fill factor 100 - exactly what the 14-byte version tag does to full pages' ELSE N'' END,
               N': ', @frag_list,
               N'. Rebuild them once with FILLFACTOR = 90 (ALTER INDEX ... REBUILD WITH (FILLFACTOR = 90, ONLINE = ON) or Ola IndexOptimize @FillFactor = 90) and keep the fill factor in the weekly maintenance.'));
ELSE IF @CheckFragmentation = 1 AND EXISTS (SELECT 1 FROM #Frag WHERE page_count IS NOT NULL)
    INSERT #Find(level, title, text) VALUES ('good', N'The versioned tables are not fragmented', N'None of the indexes on the tables that generate row versions is 30% or more fragmented.');

/* 9. logical writes */
SELECT @f_b = b, @f_a = a, @f_pct = pct FROM #Score WHERE seq = 26;
IF @f_pct >= 50
    INSERT #Find(level, title, text) VALUES ('info', N'More pages written per execution - expected',
        CONCAT(N'Logical writes per execution rose from ', FORMAT(@f_b, 'N1'), N' to ', FORMAT(@f_a, 'N1'), N' pages (+', FORMAT(@f_pct, 'N0'), N'%): the version tag is written on every modified row, split pages are written twice, and every modification also writes its old version to tempdb.'));

/* 10. deadlocks */
SELECT @f_b = b, @f_a = a, @f_pct = pct FROM #Score WHERE seq = 18;
IF @f_b > 0 AND @f_pct <= -50
    INSERT #Find(level, title, text) VALUES ('good', N'Fewer deadlocks', CONCAT(FORMAT(@f_b, 'N1'), N' per day before, ', FORMAT(@f_a, 'N1'), N' after.'));

/* ============================ RESULT SETS (SSMS) ============================ */
SELECT N'RCSI impact report v2' AS [Report], @ServerLabel AS [Server], @cut_local AS [Cutover (local)], @cut_src AS [Cutover source],
       (SELECT STRING_AGG(database_name, N', ') FROM #Db) AS [Databases], @has_mon AS [OPS.mon present];
SELECT w.win AS [Window], w.label AS [Label],
       CONVERT(datetime2(0), (w.t0 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS [From (local)],
       CONVERT(datetime2(0), (w.t1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS [To (local)], w.hours AS [Hours]
FROM #Win AS w ORDER BY w.win;

SELECT level AS [Level], title AS [Finding], REPLACE(REPLACE(text, N'<b>', N''), N'</b>', N'') AS [Detail] FROM #Find ORDER BY seq;

SELECT grp AS [Question], metric AS [Metric], unit AS [Unit], CONVERT(decimal(19,2), b) AS [Before (same weekdays)], CONVERT(decimal(19,2), a) AS [After],
       pct AS [Change %], verdict AS [Verdict], CONVERT(decimal(19,2), c) AS [7 days before cutover], note AS [Note]
FROM #Score ORDER BY seq;

SELECT class AS [Class], queries AS [Matched queries], b_time_h AS [Before time h], a_time_at_b_h AS [Same work at after speed h], index_pct AS [Index %],
       faster AS [Faster], slower AS [Slower], same AS [Same], coverage_pct AS [Coverage % of before time], nolock_pct AS [NOLOCK exec %], write_pct AS [Write time %]
FROM #Idx ORDER BY CASE class WHEN 'ALL' THEN 0 WHEN 'OLTP' THEN 1 WHEN 'MID' THEN 2 ELSE 3 END;

SELECT d.database_name AS [Database], d.is_rcsi_on AS [RCSI], d.si_state AS [Snapshot isolation], d.qs_actual AS [Query Store], d.qs_capture AS [Capture], d.qs_interval_min AS [Interval min],
       CONVERT(datetime2(0), (d.qs_oldest_utc AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS [QS history from (local)],
       b.execs / NULLIF(@bh, 0) AS [Execs/h before], a.execs / NULLIF(@ah, 0) AS [Execs/h after],
       CONVERT(decimal(19,2), b.dur_ms / NULLIF(b.execs, 0)) AS [Avg ms before], CONVERT(decimal(19,2), a.dur_ms / NULLIF(a.execs, 0)) AS [Avg ms after],
       CONVERT(decimal(19,2), b.cpu_ms / NULLIF(b.execs, 0)) AS [CPU ms before], CONVERT(decimal(19,2), a.cpu_ms / NULLIF(a.execs, 0)) AS [CPU ms after],
       CONVERT(decimal(19,1), b.reads * 1.0 / NULLIF(b.execs, 0)) AS [Reads before], CONVERT(decimal(19,1), a.reads * 1.0 / NULLIF(a.execs, 0)) AS [Reads after],
       CONVERT(decimal(19,2), wb.lock_ms * 1.0 / NULLIF(b.execs, 0)) AS [Lock ms/exec before], CONVERT(decimal(19,2), wa.lock_ms * 1.0 / NULLIF(a.execs, 0)) AS [Lock ms/exec after], d.note AS [Note]
FROM #Db AS d
LEFT JOIN #QsKpi AS b ON b.database_name = d.database_name AND b.win = 'B'
LEFT JOIN #QsKpi AS a ON a.database_name = d.database_name AND a.win = 'A'
LEFT JOIN (SELECT database_name, SUM(wait_ms) AS lock_ms FROM #QsWait WHERE win = 'B' AND wait_category = N'Lock' GROUP BY database_name) AS wb ON wb.database_name = d.database_name
LEFT JOIN (SELECT database_name, SUM(wait_ms) AS lock_ms FROM #QsWait WHERE win = 'A' AND wait_category = N'Lock' GROUP BY database_name) AS wa ON wa.database_name = d.database_name
ORDER BY d.database_name;

SELECT ISNULL(b.wait_category, a.wait_category) AS [Wait category],
       CONVERT(decimal(19,1), ISNULL(b.ms, 0) / 1000.0 / NULLIF(@bh, 0)) AS [Before s/h], CONVERT(decimal(19,1), ISNULL(a.ms, 0) / 1000.0 / NULLIF(@ah, 0)) AS [After s/h],
       CONVERT(decimal(9,1), ISNULL(b.ms, 0) * 100.0 / NULLIF((SELECT SUM(wait_ms) FROM #QsWait WHERE win = 'B'), 0)) AS [Share before %],
       CONVERT(decimal(9,1), ISNULL(a.ms, 0) * 100.0 / NULLIF((SELECT SUM(wait_ms) FROM #QsWait WHERE win = 'A'), 0)) AS [Share after %]
FROM (SELECT wait_category, SUM(wait_ms) AS ms FROM #QsWait WHERE win = 'B' GROUP BY wait_category) AS b
FULL JOIN (SELECT wait_category, SUM(wait_ms) AS ms FROM #QsWait WHERE win = 'A' GROUP BY wait_category) AS a ON a.wait_category = b.wait_category
ORDER BY ISNULL(b.ms, 0) + ISNULL(a.ms, 0) DESC;

SELECT win AS [Window], wait_type AS [Blocked sessions wait on], samples AS [Samples], blocked_sessions AS [Sessions] FROM #BlkWait ORDER BY win, samples DESC;
SELECT win AS [Window], rn AS [#], head_program AS [Head program], head_login AS [Head login], head_database AS [Head db], episodes AS [Episodes], minutes AS [Blocked min],
       max_victims AS [Max blocked], top_wait_type AS [Wait type], head_sql AS [Head statement] FROM #BlkHead WHERE rn <= @TopN ORDER BY win, rn;
SELECT rn AS [#], minutes AS [Minutes], session_id AS [Session], login_name AS [Login], database_name AS [Database], program_name AS [Program],
       CONVERT(datetime2(0), (seen_from AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS [Seen from (local)], CONVERT(datetime2(0), (seen_to AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS [Seen to (local)],
       vs_mb_max AS [Version store MB] FROM #VsTran ORDER BY rn;
SELECT rn AS [#], database_name AS [Database], object_name AS [Object], index_name AS [Index], version_mb_max AS [Versions max MB], version_mb_avg AS [Versions avg MB], samples AS [Samples] FROM #VsGen ORDER BY rn;
SELECT database_name AS [Database], object_name AS [Object], index_name AS [Index], index_type AS [Type], fill_factor AS [Fill factor], page_count AS [Pages], size_gb AS [GB], frag_pct AS [Fragmentation %], note AS [Note]
FROM #Frag ORDER BY version_mb_max DESC, page_count DESC;

SELECT TOP (@TopN) N'SLOWER' AS [Set], class AS [Class], database_name AS [Database], object_name AS [Object], query_id AS [query_id],
       b_execs AS [Execs before], a_execs AS [Execs after], b_avg_ms AS [Avg ms before], a_avg_ms AS [Avg ms after], delta_pct AS [Change %], impact_s_per_h AS [Impact s/h],
       reads_ratio AS [Reads ratio], plan_changed AS [Plan changed], b_lock_ms AS [Lock ms before], a_lock_ms AS [Lock ms after], b_cpu_ms AS [CPU before], a_cpu_ms AS [CPU after], is_nolock AS [NOLOCK], is_write AS [Write], sql_text AS [Statement]
FROM #QCmp WHERE delta_pct >= 10 AND (b_execs >= @MinExecs OR class <> 'OLTP') ORDER BY impact_s_per_h DESC;
SELECT TOP (@TopN) N'FASTER' AS [Set], class AS [Class], database_name AS [Database], object_name AS [Object], query_id AS [query_id],
       b_execs AS [Execs before], a_execs AS [Execs after], b_avg_ms AS [Avg ms before], a_avg_ms AS [Avg ms after], delta_pct AS [Change %], impact_s_per_h AS [Impact s/h],
       reads_ratio AS [Reads ratio], plan_changed AS [Plan changed], b_lock_ms AS [Lock ms before], a_lock_ms AS [Lock ms after], b_cpu_ms AS [CPU before], a_cpu_ms AS [CPU after], is_nolock AS [NOLOCK], is_write AS [Write], sql_text AS [Statement]
FROM #QCmp WHERE delta_pct <= -10 AND (b_execs >= @MinExecs OR class <> 'OLTP') ORDER BY impact_s_per_h ASC;

SELECT note AS [Note] FROM @notes UNION ALL SELECT CONCAT(database_name, N': ', note) FROM #Db WHERE note IS NOT NULL;

/* ============================ HTML ============================ */
DECLARE @css nvarchar(max) = N'<style>
body{margin:0;padding:0;background:#F3F4F6;font-family:Segoe UI,Arial,Helvetica,sans-serif;color:#1F2937}
.card{max-width:1100px;margin:16px auto;background:#FFFFFF;border:1px solid #E5E7EB}
.banner{padding:18px 24px;background:#1E3A5F;color:#FFFFFF}
.eyebrow{font-size:11px;letter-spacing:1.2px;text-transform:uppercase}
.title{font-size:22px;line-height:28px;font-weight:700;margin-top:2px}
.sub{font-size:12px;margin-top:4px;color:#DBEAFE}
.sec{padding:18px 24px 4px 24px}
.sec h2{font-size:15px;font-weight:700;color:#0F172A;margin:0}
.sec .d{font-size:11px;color:#6B7280;margin:2px 0 8px 0}
table.t{width:100%;border-collapse:collapse;border:1px solid #E5E7EB;font-size:12px}
table.t th{padding:7px 8px;font-size:11px;font-weight:700;color:#FFFFFF;background:#1E3A5F;text-align:left;text-transform:uppercase;letter-spacing:.4px;white-space:nowrap}
table.t td{padding:6px 8px;border-bottom:1px solid #E5E7EB;vertical-align:top;line-height:16px}
td.n{text-align:right;white-space:nowrap}
td.m{text-align:right;white-space:nowrap;color:#9CA3AF;font-size:11px}
td.g{background:#F9FAFB;font-weight:700;color:#374151;width:150px}
.pill{display:inline-block;padding:1px 7px;border-radius:9px;font-size:10px;font-weight:700;letter-spacing:.3px;white-space:nowrap}
.better{background:#16A34A;color:#FFFFFF}.worse{background:#DC2626;color:#FFFFFF}.same{background:#E5E7EB;color:#374151}.info{background:#2563EB;color:#FFFFFF}.na{background:#F3F4F6;color:#9CA3AF}
.good{background:#16A34A;color:#FFFFFF}.bad{background:#DC2626;color:#FFFFFF}.warn{background:#F59E0B;color:#111827}
.v{font-size:22px;line-height:26px;font-weight:700}
.l{font-size:10px;line-height:13px;text-transform:uppercase;letter-spacing:.5px;color:#374151;font-weight:600}
.s{font-size:10px;color:#6B7280}
table.b{border-collapse:collapse;width:100%}
table.t table.b td{padding:0;border:0;vertical-align:middle}
table.t table.b td.f{height:10px;line-height:10px;font-size:1px}
table.t table.b td.x{font-size:11px;color:#374151;padding-left:6px;white-space:nowrap}
table.fd{width:100%;border-collapse:collapse}
table.fd td{padding:8px 10px;border-bottom:1px solid #E5E7EB;vertical-align:top;font-size:12px;line-height:17px}
code{font-family:Consolas,Menlo,monospace;font-size:11px;color:#374151;white-space:pre-wrap;word-break:break-word}
.foot{padding:16px 24px 22px 24px;border-top:1px solid #E5E7EB;font-size:11px;line-height:16px;color:#6B7280}
.cut{padding:8px 24px 0 24px;font-size:12px;color:#374151;line-height:18px}
</style>';

DECLARE @h nvarchar(max) = N'', @rows nvarchar(max), @kpi nvarchar(max);
DECLARE @dbs nvarchar(max) = (SELECT STRING_AGG(database_name, N', ') WITHIN GROUP (ORDER BY database_name) FROM #Db);
DECLARE @n_good int = (SELECT COUNT(*) FROM #Find WHERE level = 'good'), @n_bad int = (SELECT COUNT(*) FROM #Find WHERE level = 'bad'), @n_warn int = (SELECT COUNT(*) FROM #Find WHERE level = 'warn');
DECLARE @wd_b nvarchar(60) = CONCAT(DATENAME(WEEKDAY, CONVERT(datetime2(0), (@b0 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone)), N' ', CONVERT(nvarchar(16), CONVERT(datetime2(0), (@b0 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120),
                              N' - ', DATENAME(WEEKDAY, CONVERT(datetime2(0), (@b1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone)), N' ', CONVERT(nvarchar(16), CONVERT(datetime2(0), (@b1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120)),
        @wd_a nvarchar(60) = CONCAT(DATENAME(WEEKDAY, CONVERT(datetime2(0), (@a0 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone)), N' ', CONVERT(nvarchar(16), CONVERT(datetime2(0), (@a0 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120),
                              N' - ', DATENAME(WEEKDAY, CONVERT(datetime2(0), (@a1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone)), N' ', CONVERT(nvarchar(16), CONVERT(datetime2(0), (@a1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120));

/* windows line */
SET @h = CONCAT(@h, N'<div class="cut"><b>RCSI switched on ', CONVERT(nvarchar(16), @cut_local, 120), N' ', @TzLabel, N'</b> (', @cut_src, N') on <b>', @dbs, N'</b>.<br>',
    N'<b>After</b> = ', @wd_a, N' (', FORMAT(@ah / 24.0, 'N1'), N' days; the first ', @SkipHours, N' h after the switch excluded). ',
    N'<b>Before</b> = the same weekdays and hours ', @weeks_back, N' week earlier: ', @wd_b, N' (', FORMAT(@bh / 24.0, 'N1'), N' days). ',
    N'The grey column is the plain ', @BeforeDays, N'-day period before the switch, for reference.</div>');

/* headline tiles */
SELECT @kpi = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<td align="center" valign="top" width="16%" bgcolor="', CASE s.verdict WHEN 'better' THEN N'#F0FDF4' WHEN 'worse' THEN N'#FEF2F2' ELSE N'#F9FAFB' END,
    N'" style="padding:10px 6px;border:1px solid #FFFFFF;background:', CASE s.verdict WHEN 'better' THEN N'#F0FDF4' WHEN 'worse' THEN N'#FEF2F2' ELSE N'#F9FAFB' END, N'">',
    N'<div class="v" style="color:', CASE s.verdict WHEN 'better' THEN N'#15803D' WHEN 'worse' THEN N'#B91C1C' ELSE N'#111827' END, N'">', x.fa, N'</div>',
    N'<div class="l">', s.metric, N'</div>',
    N'<div class="s">', CASE WHEN s.unit = 'idx' THEN N'same work, after vs before' ELSE CONCAT(N'before ', x.fb, CASE WHEN x.fd <> N'' THEN CONCAT(N' &middot; ', x.fd) ELSE N'' END) END, N'</div></td>')), N'')
    WITHIN GROUP (ORDER BY CASE s.seq WHEN 20 THEN 1 WHEN 10 THEN 2 WHEN 16 THEN 3 WHEN 31 THEN 4 WHEN 36 THEN 5 WHEN 37 THEN 6 END)
FROM #Score AS s
CROSS APPLY (SELECT CASE WHEN s.a IS NULL THEN N'-'
             WHEN s.unit = 'idx' THEN CONCAT(CASE WHEN s.a > 0 THEN N'+' ELSE N'' END, FORMAT(s.a, 'N0'), N'%')
             WHEN s.unit = 'MB' THEN CASE WHEN ABS(s.a) >= 1024 THEN CONCAT(FORMAT(s.a / 1024.0, 'N1'), N' GB') WHEN ABS(s.a) >= 10 THEN CONCAT(FORMAT(s.a, 'N0'), N' MB') ELSE CONCAT(FORMAT(s.a, 'N1'), N' MB') END
             WHEN s.unit = '%' THEN CONCAT(FORMAT(s.a, CASE WHEN ABS(s.a) >= 10 THEN 'N0' ELSE 'N1' END), N'%')
             WHEN s.unit = 'min' THEN CASE WHEN s.a >= 120 THEN CONCAT(FORMAT(s.a / 60.0, 'N1'), N' h') ELSE CONCAT(FORMAT(s.a, 'N0'), N' min') END
             WHEN s.unit = 's' THEN CASE WHEN s.a >= 3600 THEN CONCAT(FORMAT(s.a / 3600.0, 'N1'), N' h') ELSE CONCAT(FORMAT(s.a, 'N0'), N' s') END
             WHEN s.unit = 'ms' THEN CASE WHEN s.a >= 10000 THEN CONCAT(FORMAT(s.a / 1000.0, 'N1'), N' s') ELSE CONCAT(FORMAT(s.a, CASE WHEN ABS(s.a) >= 100 THEN 'N0' WHEN ABS(s.a) >= 10 THEN 'N1' ELSE 'N2' END), N' ms') END
             ELSE CONCAT(FORMAT(s.a, CASE WHEN ABS(s.a) >= 100 THEN 'N0' WHEN ABS(s.a) >= 10 THEN 'N1' ELSE 'N2' END), CASE WHEN s.unit = '' THEN N'' ELSE N' ' + s.unit END) END AS fa, CASE WHEN s.b IS NULL THEN N'-'
             WHEN s.unit = 'idx' THEN CONCAT(CASE WHEN s.b > 0 THEN N'+' ELSE N'' END, FORMAT(s.b, 'N0'), N'%')
             WHEN s.unit = 'MB' THEN CASE WHEN ABS(s.b) >= 1024 THEN CONCAT(FORMAT(s.b / 1024.0, 'N1'), N' GB') WHEN ABS(s.b) >= 10 THEN CONCAT(FORMAT(s.b, 'N0'), N' MB') ELSE CONCAT(FORMAT(s.b, 'N1'), N' MB') END
             WHEN s.unit = '%' THEN CONCAT(FORMAT(s.b, CASE WHEN ABS(s.b) >= 10 THEN 'N0' ELSE 'N1' END), N'%')
             WHEN s.unit = 'min' THEN CASE WHEN s.b >= 120 THEN CONCAT(FORMAT(s.b / 60.0, 'N1'), N' h') ELSE CONCAT(FORMAT(s.b, 'N0'), N' min') END
             WHEN s.unit = 's' THEN CASE WHEN s.b >= 3600 THEN CONCAT(FORMAT(s.b / 3600.0, 'N1'), N' h') ELSE CONCAT(FORMAT(s.b, 'N0'), N' s') END
             WHEN s.unit = 'ms' THEN CASE WHEN s.b >= 10000 THEN CONCAT(FORMAT(s.b / 1000.0, 'N1'), N' s') ELSE CONCAT(FORMAT(s.b, CASE WHEN ABS(s.b) >= 100 THEN 'N0' WHEN ABS(s.b) >= 10 THEN 'N1' ELSE 'N2' END), N' ms') END
             ELSE CONCAT(FORMAT(s.b, CASE WHEN ABS(s.b) >= 100 THEN 'N0' WHEN ABS(s.b) >= 10 THEN 'N1' ELSE 'N2' END), CASE WHEN s.unit = '' THEN N'' ELSE N' ' + s.unit END) END AS fb, CASE WHEN s.unit = 'idx' THEN N''
             WHEN s.b IS NULL OR s.a IS NULL THEN N'-'
             WHEN s.b = 0 AND s.a = 0 THEN N'0%'
             WHEN s.b = 0 THEN N'new'
             WHEN ABS(s.pct) <= 999 THEN CONCAT(CASE WHEN s.pct > 0 THEN N'+' ELSE N'' END, FORMAT(s.pct, 'N0'), N'%')
             ELSE CONCAT(N'x ', FORMAT(s.a / NULLIF(s.b, 0), 'N0')) END AS fd) AS x
WHERE s.seq IN (20, 10, 16, 31, 36, 37);
SET @h = CONCAT(@h, N'<div style="padding:4px 24px 0 24px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;table-layout:fixed"><tr>', @kpi, N'</tr></table></div>');

/* findings */
SELECT @rows = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td width="70" valign="top"><span class="pill ', f.level, N'">', CASE f.level WHEN 'good' THEN N'GOOD' WHEN 'bad' THEN N'PROBLEM' WHEN 'warn' THEN N'WATCH' ELSE N'NOTE' END, N'</span></td>',
    N'<td><b>', f.title, N'</b><br>', f.text, N'</td></tr>')), N'') WITHIN GROUP (ORDER BY f.seq)
FROM #Find AS f;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Bottom line</h2><div class="d">', @n_good, N' good, ', @n_bad, N' problem(s), ', @n_warn, N' to watch - generated from the numbers below.</div>',
    N'<table class="fd">', ISNULL(@rows, N'<tr><td>No findings - not enough data.</td></tr>'), N'</table></div>');

/* scorecard */
SELECT @rows = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr>', CASE WHEN s.seq = g.first_seq THEN CONCAT(N'<td class="g" rowspan="', g.n, N'">', s.grp, N'</td>') ELSE N'' END,
    N'<td>', s.metric, CASE WHEN s.note IS NOT NULL THEN CONCAT(N'<br><span style="color:#6B7280;font-size:11px">', s.note, N'</span>') ELSE N'' END, N'</td>',
    N'<td class="n">', CASE WHEN s.unit = 'idx' THEN N'' ELSE x.fb END, N'</td>',
    N'<td class="n"><b>', x.fa, N'</b></td>',
    N'<td class="n">', x.fd, N'</td>',
    N'<td><span class="pill ', REPLACE(s.verdict, '/', ''), N'">', UPPER(s.verdict), N'</span></td>',
    N'<td class="m">', CASE WHEN s.unit = 'idx' THEN N'' ELSE x.fc END, N'</td></tr>')), N'')
    WITHIN GROUP (ORDER BY s.seq)
FROM #Score AS s
JOIN (SELECT grp, MIN(seq) AS first_seq, COUNT(*) AS n FROM #Score GROUP BY grp) AS g ON g.grp = s.grp
CROSS APPLY (SELECT CASE WHEN s.a IS NULL THEN N'-'
             WHEN s.unit = 'idx' THEN CONCAT(CASE WHEN s.a > 0 THEN N'+' ELSE N'' END, FORMAT(s.a, 'N0'), N'%')
             WHEN s.unit = 'MB' THEN CASE WHEN ABS(s.a) >= 1024 THEN CONCAT(FORMAT(s.a / 1024.0, 'N1'), N' GB') WHEN ABS(s.a) >= 10 THEN CONCAT(FORMAT(s.a, 'N0'), N' MB') ELSE CONCAT(FORMAT(s.a, 'N1'), N' MB') END
             WHEN s.unit = '%' THEN CONCAT(FORMAT(s.a, CASE WHEN ABS(s.a) >= 10 THEN 'N0' ELSE 'N1' END), N'%')
             WHEN s.unit = 'min' THEN CASE WHEN s.a >= 120 THEN CONCAT(FORMAT(s.a / 60.0, 'N1'), N' h') ELSE CONCAT(FORMAT(s.a, 'N0'), N' min') END
             WHEN s.unit = 's' THEN CASE WHEN s.a >= 3600 THEN CONCAT(FORMAT(s.a / 3600.0, 'N1'), N' h') ELSE CONCAT(FORMAT(s.a, 'N0'), N' s') END
             WHEN s.unit = 'ms' THEN CASE WHEN s.a >= 10000 THEN CONCAT(FORMAT(s.a / 1000.0, 'N1'), N' s') ELSE CONCAT(FORMAT(s.a, CASE WHEN ABS(s.a) >= 100 THEN 'N0' WHEN ABS(s.a) >= 10 THEN 'N1' ELSE 'N2' END), N' ms') END
             ELSE CONCAT(FORMAT(s.a, CASE WHEN ABS(s.a) >= 100 THEN 'N0' WHEN ABS(s.a) >= 10 THEN 'N1' ELSE 'N2' END), CASE WHEN s.unit = '' THEN N'' ELSE N' ' + s.unit END) END AS fa, CASE WHEN s.b IS NULL THEN N'-'
             WHEN s.unit = 'idx' THEN CONCAT(CASE WHEN s.b > 0 THEN N'+' ELSE N'' END, FORMAT(s.b, 'N0'), N'%')
             WHEN s.unit = 'MB' THEN CASE WHEN ABS(s.b) >= 1024 THEN CONCAT(FORMAT(s.b / 1024.0, 'N1'), N' GB') WHEN ABS(s.b) >= 10 THEN CONCAT(FORMAT(s.b, 'N0'), N' MB') ELSE CONCAT(FORMAT(s.b, 'N1'), N' MB') END
             WHEN s.unit = '%' THEN CONCAT(FORMAT(s.b, CASE WHEN ABS(s.b) >= 10 THEN 'N0' ELSE 'N1' END), N'%')
             WHEN s.unit = 'min' THEN CASE WHEN s.b >= 120 THEN CONCAT(FORMAT(s.b / 60.0, 'N1'), N' h') ELSE CONCAT(FORMAT(s.b, 'N0'), N' min') END
             WHEN s.unit = 's' THEN CASE WHEN s.b >= 3600 THEN CONCAT(FORMAT(s.b / 3600.0, 'N1'), N' h') ELSE CONCAT(FORMAT(s.b, 'N0'), N' s') END
             WHEN s.unit = 'ms' THEN CASE WHEN s.b >= 10000 THEN CONCAT(FORMAT(s.b / 1000.0, 'N1'), N' s') ELSE CONCAT(FORMAT(s.b, CASE WHEN ABS(s.b) >= 100 THEN 'N0' WHEN ABS(s.b) >= 10 THEN 'N1' ELSE 'N2' END), N' ms') END
             ELSE CONCAT(FORMAT(s.b, CASE WHEN ABS(s.b) >= 100 THEN 'N0' WHEN ABS(s.b) >= 10 THEN 'N1' ELSE 'N2' END), CASE WHEN s.unit = '' THEN N'' ELSE N' ' + s.unit END) END AS fb, CASE WHEN s.c IS NULL THEN N'-'
             WHEN s.unit = 'idx' THEN CONCAT(CASE WHEN s.c > 0 THEN N'+' ELSE N'' END, FORMAT(s.c, 'N0'), N'%')
             WHEN s.unit = 'MB' THEN CASE WHEN ABS(s.c) >= 1024 THEN CONCAT(FORMAT(s.c / 1024.0, 'N1'), N' GB') WHEN ABS(s.c) >= 10 THEN CONCAT(FORMAT(s.c, 'N0'), N' MB') ELSE CONCAT(FORMAT(s.c, 'N1'), N' MB') END
             WHEN s.unit = '%' THEN CONCAT(FORMAT(s.c, CASE WHEN ABS(s.c) >= 10 THEN 'N0' ELSE 'N1' END), N'%')
             WHEN s.unit = 'min' THEN CASE WHEN s.c >= 120 THEN CONCAT(FORMAT(s.c / 60.0, 'N1'), N' h') ELSE CONCAT(FORMAT(s.c, 'N0'), N' min') END
             WHEN s.unit = 's' THEN CASE WHEN s.c >= 3600 THEN CONCAT(FORMAT(s.c / 3600.0, 'N1'), N' h') ELSE CONCAT(FORMAT(s.c, 'N0'), N' s') END
             WHEN s.unit = 'ms' THEN CASE WHEN s.c >= 10000 THEN CONCAT(FORMAT(s.c / 1000.0, 'N1'), N' s') ELSE CONCAT(FORMAT(s.c, CASE WHEN ABS(s.c) >= 100 THEN 'N0' WHEN ABS(s.c) >= 10 THEN 'N1' ELSE 'N2' END), N' ms') END
             ELSE CONCAT(FORMAT(s.c, CASE WHEN ABS(s.c) >= 100 THEN 'N0' WHEN ABS(s.c) >= 10 THEN 'N1' ELSE 'N2' END), CASE WHEN s.unit = '' THEN N'' ELSE N' ' + s.unit END) END AS fc, CASE WHEN s.unit = 'idx' THEN N''
             WHEN s.b IS NULL OR s.a IS NULL THEN N'-'
             WHEN s.b = 0 AND s.a = 0 THEN N'0%'
             WHEN s.b = 0 THEN N'new'
             WHEN ABS(s.pct) <= 999 THEN CONCAT(CASE WHEN s.pct > 0 THEN N'+' ELSE N'' END, FORMAT(s.pct, 'N0'), N'%')
             ELSE CONCAT(N'x ', FORMAT(s.a / NULLIF(s.b, 0), 'N0')) END AS fd) AS x;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Scorecard</h2><div class="d">Before = same weekdays a week earlier; After = since the switch. ',
    N'Rates are per hour / per day so periods of different length compare fairly; BETTER / WORSE needs a change of at least 10%. Grey column: the ', @BeforeDays, N' days right before the switch.</div>',
    N'<table class="t"><tr><th>Question</th><th>Metric</th><th>Before</th><th>After</th><th>Change</th><th>Verdict</th><th>', @BeforeDays, N'd before</th></tr>', @rows, N'</table></div>');

/* same queries detail */
SELECT @rows = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td>', CASE i.class WHEN 'ALL' THEN N'<b>All matched queries</b>' WHEN 'OLTP' THEN CONCAT(N'OLTP (under ', @OltpMaxMs, N' ms)') WHEN 'BATCH' THEN CONCAT(N'Batch (', @BatchMinMs / 1000, N' s and more)') ELSE N'In between' END, N'</td>',
    N'<td class="n">', FORMAT(i.queries, 'N0'), N'</td>',
    N'<td class="n">', FORMAT(i.b_time_h, 'N1'), N' h</td><td class="n">', FORMAT(i.a_time_at_b_h, 'N1'), N' h</td>',
    N'<td class="n"><span class="pill ', CASE WHEN i.index_pct <= -10 THEN N'better' WHEN i.index_pct >= 10 THEN N'worse' ELSE N'same' END, N'">', CASE WHEN i.index_pct > 0 THEN N'+' ELSE N'' END, FORMAT(i.index_pct, 'N0'), N'%</span></td>',
    N'<td class="n"><span style="color:#15803D">', i.faster, N' faster</span> &middot; <span style="color:#B91C1C">', i.slower, N' slower</span> &middot; ', i.same, N' same</td>',
    N'<td class="n">', FORMAT(i.coverage_pct, 'N0'), N'%</td><td class="n">', FORMAT(i.nolock_pct, 'N0'), N'%</td><td class="n">', FORMAT(i.write_pct, 'N0'), N'%</td></tr>')), N'')
    WITHIN GROUP (ORDER BY CASE i.class WHEN 'ALL' THEN 0 WHEN 'OLTP' THEN 1 WHEN 'MID' THEN 2 ELSE 3 END)
FROM #Idx AS i;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Same queries, before vs after</h2><div class="d">Every query (by query_hash) that ran in both periods, taken at its BEFORE execution count: "at after speed" = how long the before workload would take with the after per-execution times. ',
    N'Independent of how much work ran in each period. Coverage = share of the before query time these queries represent.</div>',
    N'<table class="t"><tr><th>Class</th><th>Queries</th><th>Before time</th><th>At after speed</th><th>Index</th><th>Per query</th><th>Coverage</th><th>NOLOCK execs</th><th>Write time</th></tr>',
    ISNULL(@rows, N'<tr><td colspan="9">No query ran in both periods.</td></tr>'), N'</table></div>');

/* blocking: wait types + heads */
DECLARE @bw nvarchar(max), @bhd nvarchar(max);
SELECT @bw = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td>', x.wait_type, N'</td><td>', CASE WHEN x.wait_type LIKE N'LCK[_]M[_]S%' AND x.wait_type NOT LIKE N'LCK[_]M[_]SCH%' THEN N'reader waiting for a writer - <b>RCSI removes this</b>'
                                                 WHEN x.wait_type LIKE N'LCK[_]M[_]SCH%' THEN N'schema lock (DDL, recompile, truncate) - not affected by RCSI'
                                                 WHEN x.wait_type LIKE N'LCK[_]M[_]%' THEN N'writer waiting for a writer - not affected by RCSI'
                                                 ELSE N'' END, N'</td>',
    N'<td class="n">', FORMAT(ISNULL(x.b, 0), 'N0'), N'</td><td class="n"><b>', FORMAT(ISNULL(x.a, 0), 'N0'), N'</b></td></tr>')), N'')
    WITHIN GROUP (ORDER BY ISNULL(x.a, 0) + ISNULL(x.b, 0) DESC)
FROM (SELECT ISNULL(b.wait_type, a.wait_type) AS wait_type, b.samples AS b, a.samples AS a
      FROM (SELECT wait_type, samples FROM #BlkWait WHERE win = 'B') AS b
      FULL JOIN (SELECT wait_type, samples FROM #BlkWait WHERE win = 'A') AS a ON a.wait_type = b.wait_type) AS x;
SELECT @bhd = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td>', CASE h.win WHEN 'A' THEN N'after' ELSE N'before' END, N'</td>',
    N'<td>', ISNULL(h.head_program, N'?'), N'<br><span style="color:#6B7280;font-size:11px">', ISNULL(h.head_login, N'?'), CASE WHEN h.head_database IS NOT NULL THEN CONCAT(N' &middot; ', h.head_database) ELSE N'' END, N'</span></td>',
    N'<td class="n">', h.episodes, N'</td><td class="n"><b>', FORMAT(h.minutes, 'N0'), N' min</b></td><td class="n">', h.max_victims, N'</td><td>', ISNULL(h.top_wait_type, N''), N'</td>',
    N'<td><code>', LEFT(REPLACE(REPLACE(REPLACE(ISNULL(h.head_sql, N''), N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), 160), N'</code></td></tr>')), N'')
    WITHIN GROUP (ORDER BY CASE h.win WHEN 'A' THEN 0 ELSE 1 END, h.rn)
FROM #BlkHead AS h WHERE h.rn <= 5;
IF @has_mon = 1
    SET @h = CONCAT(@h, N'<div class="sec"><h2>Blocking: what are the blocked sessions waiting for?</h2><div class="d">OPS.mon samples every 30 s; one sample = one blocked session seen once. RCSI changes only the first kind.</div>',
        N'<table class="t"><tr><th>Wait type</th><th>Meaning</th><th>Samples before</th><th>Samples after</th></tr>', ISNULL(@bw, N'<tr><td colspan="4">No blocking recorded in either period.</td></tr>'), N'</table>',
        N'<div class="d" style="margin-top:10px">Head blockers (the session everybody waits for), top 5 per period.</div>',
        N'<table class="t"><tr><th>Period</th><th>Program / login</th><th>Episodes</th><th>Blocked time</th><th>Max blocked</th><th>Wait type</th><th>Head statement</th></tr>', ISNULL(@bhd, N'<tr><td colspan="7">-</td></tr>'), N'</table></div>');

/* version store: who + which tables + fragmentation */
DECLARE @vt nvarchar(max), @vg nvarchar(max), @fr nvarchar(max);
SELECT @vt = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td class="n"><b>', FORMAT(t.minutes, 'N0'), N' min</b></td><td>', ISNULL(t.login_name, N'?'), N'</td><td>', ISNULL(t.program_name, N'?'), N'</td><td>', ISNULL(t.database_name, N'?'), N'</td>',
    N'<td class="n">', CONVERT(nvarchar(16), CONVERT(datetime2(0), (t.seen_from AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120), N' - ', CONVERT(nvarchar(5), CONVERT(datetime2(0), (t.seen_to AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 108), N'</td>',
    N'<td class="n">', FORMAT(t.vs_mb_max / 1024.0, 'N1'), N' GB</td></tr>')), N'') WITHIN GROUP (ORDER BY t.rn)
FROM #VsTran AS t;
SELECT @vg = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td>', g.database_name, N'</td><td><code>', g.object_name, N'</code>', CASE WHEN g.index_name IS NOT NULL THEN CONCAT(N' <span style="color:#6B7280;font-size:11px">', g.index_name, N'</span>') ELSE N'' END, N'</td>',
    N'<td class="n"><b>', CASE WHEN g.version_mb_max >= 1024 THEN CONCAT(FORMAT(g.version_mb_max / 1024.0, 'N1'), N' GB') ELSE CONCAT(FORMAT(g.version_mb_max, 'N0'), N' MB') END, N'</b></td>',
    N'<td class="n">', CASE WHEN g.version_mb_avg >= 1024 THEN CONCAT(FORMAT(g.version_mb_avg / 1024.0, 'N1'), N' GB') ELSE CONCAT(FORMAT(g.version_mb_avg, 'N0'), N' MB') END, N'</td></tr>')), N'') WITHIN GROUP (ORDER BY g.rn)
FROM #VsGen AS g;
SELECT @fr = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td><code>', f.object_name, N'</code></td><td>', ISNULL(f.index_name, N'(heap)'), N'<br><span style="color:#6B7280;font-size:11px">', f.index_type, N'</span></td>',
    N'<td class="n">', CASE WHEN f.fill_factor = 0 THEN N'100' ELSE CONVERT(nvarchar(10), f.fill_factor) END, N'</td>',
    N'<td class="n">', FORMAT(f.page_count, 'N0'), N'<br><span style="color:#6B7280;font-size:11px">', FORMAT(f.size_gb, 'N1'), N' GB</span></td>',
    N'<td class="n"', CASE WHEN f.frag_pct >= 30 THEN N' bgcolor="#FEE2E2" style="background:#FEE2E2;color:#7F1D1D"' ELSE N'' END, N'><b>', FORMAT(f.frag_pct, 'N0'), N'%</b></td>',
    N'<td>', ISNULL(f.note, N''), N'</td></tr>')), N'') WITHIN GROUP (ORDER BY f.version_mb_max DESC, f.page_count DESC)
FROM #Frag AS f WHERE f.page_count IS NOT NULL;
IF @has_mon = 1
    SET @h = CONCAT(@h, N'<div class="sec"><h2>Version store: who holds it and which tables fill it</h2><div class="d">Row versions live in tempdb until the oldest transaction that might still read them ends. Long transactions in the after period (10 min or more):</div>',
        N'<table class="t"><tr><th>Held for</th><th>Login</th><th>Program</th><th>Database</th><th>Seen (local)</th><th>Version store then</th></tr>', ISNULL(@vt, N'<tr><td colspan="6">No transaction held versions for 10 minutes or more.</td></tr>'), N'</table>',
        N'<div class="d" style="margin-top:10px">Tables that generate the versions (sys.dm_tran_top_version_generators): these are the UPDATE / DELETE targets of the load.</div>',
        N'<table class="t"><tr><th>Database</th><th>Table / index</th><th>Versions, max</th><th>Versions, avg</th></tr>', ISNULL(@vg, N'<tr><td colspan="4">-</td></tr>'), N'</table>',
        CASE WHEN @fr IS NOT NULL THEN CONCAT(N'<div class="d" style="margin-top:10px">Physical state of those tables now. After RCSI every row modified for the first time grows by 14 bytes; full pages (fill factor 100) split, which is what the DELETE / INSERT steps then pay for in extra reads.</div>',
            N'<table class="t"><tr><th>Table</th><th>Index</th><th>Fill factor</th><th>Pages</th><th>Fragmentation</th><th>Note</th></tr>', @fr, N'</table>') ELSE N'' END,
        N'</div>');

/* slower / faster queries */
DECLARE @q nvarchar(max);
SELECT @q = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td><span class="pill ', CASE q.class WHEN 'BATCH' THEN N'info' WHEN 'OLTP' THEN N'same' ELSE N'na' END, N'">', q.class, N'</span><br>', q.database_name,
    CASE WHEN q.object_name IS NOT NULL THEN CONCAT(N'<br><span style="color:#6B7280;font-size:11px">', q.object_name, N'</span>') ELSE N'' END, N'</td>',
    N'<td><code>', LEFT(REPLACE(REPLACE(REPLACE(q.sql_text, N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), 180), CASE WHEN LEN(q.sql_text) > 180 THEN N'&#8230;' ELSE N'' END, N'</code></td>',
    N'<td class="n">', FORMAT(q.b_execs / NULLIF(@bh, 0), CASE WHEN q.b_execs / NULLIF(@bh, 0) < 10 THEN 'N1' ELSE 'N0' END), N' &rarr; ', FORMAT(q.a_execs / NULLIF(@ah, 0), CASE WHEN q.a_execs / NULLIF(@ah, 0) < 10 THEN 'N1' ELSE 'N0' END), N'</td>',
    N'<td class="n">', CASE WHEN q.b_avg_ms >= 10000 THEN CONCAT(FORMAT(q.b_avg_ms / 1000.0, 'N0'), N' s') ELSE CONCAT(FORMAT(q.b_avg_ms, 'N1'), N' ms') END, N' &rarr; <b>',
                       CASE WHEN q.a_avg_ms >= 10000 THEN CONCAT(FORMAT(q.a_avg_ms / 1000.0, 'N0'), N' s') ELSE CONCAT(FORMAT(q.a_avg_ms, 'N1'), N' ms') END, N'</b></td>',
    N'<td class="n"><span class="pill ', CASE WHEN q.delta_pct > 0 THEN N'worse' ELSE N'better' END, N'">', CASE WHEN q.delta_pct > 0 THEN N'+' ELSE N'' END, FORMAT(q.delta_pct, 'N0'), N'%</span></td>',
    N'<td class="n">x ', FORMAT(q.reads_ratio, 'N1'), N'</td>',
    N'<td>', CASE WHEN q.plan_changed = 1 THEN N'<span class="pill warn">PLAN CHANGED</span>' ELSE N'same plan' END, CASE WHEN q.is_nolock = 1 THEN N'<br><span class="pill na">NOLOCK</span>' ELSE N'' END, N'</td>',
    N'<td class="n">', FORMAT(q.b_lock_ms, 'N1'), N' &rarr; ', FORMAT(q.a_lock_ms, 'N1'), N'</td>',
    N'<td class="n">', CASE WHEN q.impact_s_per_h > 0 THEN N'+' ELSE N'' END, FORMAT(q.impact_s_per_h, 'N1'), N' s/h</td></tr>')), N'')
    WITHIN GROUP (ORDER BY q.impact_s_per_h DESC)
FROM (SELECT TOP (@TopN) * FROM #QCmp WHERE delta_pct >= 10 AND (b_execs >= @MinExecs OR class <> 'OLTP') ORDER BY impact_s_per_h DESC) AS q;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Queries that got slower</h2><div class="d">Ordered by impact = extra ms per execution x executions per hour. "Reads" = pages read per execution after vs before; "same plan" with more reads = the data changed (page splits, version chains), "PLAN CHANGED" = the optimizer changed its mind (compare in Query Store).</div>',
    N'<table class="t"><tr><th>Class / database</th><th>Statement</th><th>Execs/h</th><th>Avg time</th><th>Change</th><th>Reads</th><th>Plan</th><th>Lock ms/exec</th><th>Impact</th></tr>',
    ISNULL(@q, N'<tr><td colspan="9" style="background:#F0FDF4;color:#166534">&#10003; No query got slower.</td></tr>'), N'</table></div>');

SELECT @q = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td><span class="pill ', CASE q.class WHEN 'BATCH' THEN N'info' WHEN 'OLTP' THEN N'same' ELSE N'na' END, N'">', q.class, N'</span><br>', q.database_name,
    CASE WHEN q.object_name IS NOT NULL THEN CONCAT(N'<br><span style="color:#6B7280;font-size:11px">', q.object_name, N'</span>') ELSE N'' END, N'</td>',
    N'<td><code>', LEFT(REPLACE(REPLACE(REPLACE(q.sql_text, N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), 180), CASE WHEN LEN(q.sql_text) > 180 THEN N'&#8230;' ELSE N'' END, N'</code></td>',
    N'<td class="n">', FORMAT(q.b_execs / NULLIF(@bh, 0), CASE WHEN q.b_execs / NULLIF(@bh, 0) < 10 THEN 'N1' ELSE 'N0' END), N' &rarr; ', FORMAT(q.a_execs / NULLIF(@ah, 0), CASE WHEN q.a_execs / NULLIF(@ah, 0) < 10 THEN 'N1' ELSE 'N0' END), N'</td>',
    N'<td class="n">', CASE WHEN q.b_avg_ms >= 10000 THEN CONCAT(FORMAT(q.b_avg_ms / 1000.0, 'N0'), N' s') ELSE CONCAT(FORMAT(q.b_avg_ms, 'N1'), N' ms') END, N' &rarr; <b>',
                       CASE WHEN q.a_avg_ms >= 10000 THEN CONCAT(FORMAT(q.a_avg_ms / 1000.0, 'N0'), N' s') ELSE CONCAT(FORMAT(q.a_avg_ms, 'N1'), N' ms') END, N'</b></td>',
    N'<td class="n"><span class="pill better">', FORMAT(q.delta_pct, 'N0'), N'%</span></td>',
    N'<td class="n">x ', FORMAT(q.reads_ratio, 'N1'), N'</td>',
    N'<td>', CASE WHEN q.plan_changed = 1 THEN N'<span class="pill warn">PLAN CHANGED</span>' ELSE N'same plan' END, CASE WHEN q.is_nolock = 1 THEN N'<br><span class="pill na">NOLOCK</span>' ELSE N'' END, N'</td>',
    N'<td class="n">', FORMAT(q.b_lock_ms, 'N1'), N' &rarr; ', FORMAT(q.a_lock_ms, 'N1'), N'</td>',
    N'<td class="n">', FORMAT(q.impact_s_per_h, 'N1'), N' s/h</td></tr>')), N'')
    WITHIN GROUP (ORDER BY q.impact_s_per_h ASC)
FROM (SELECT TOP (@TopN) * FROM #QCmp WHERE delta_pct <= -10 AND (b_execs >= @MinExecs OR class <> 'OLTP') ORDER BY impact_s_per_h ASC) AS q;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Queries that got faster</h2><div class="d">Ordered by time saved per hour. A query marked NOLOCK never waited for writers, so its gain is not an RCSI effect (caching, data, plan).</div>',
    N'<table class="t"><tr><th>Class / database</th><th>Statement</th><th>Execs/h</th><th>Avg time</th><th>Change</th><th>Reads</th><th>Plan</th><th>Lock ms/exec</th><th>Saved</th></tr>',
    ISNULL(@q, N'<tr><td colspan="9">No query got faster.</td></tr>'), N'</table></div>');

/* day by day with weekday */
;WITH D AS
(
    SELECT CONVERT(date, (h.hour_utc AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS d, SUM(h.execs) AS execs, SUM(h.dur_ms) AS dur_ms, SUM(h.cpu_ms) AS cpu_ms
    FROM #QsHour AS h GROUP BY CONVERT(date, (h.hour_utc AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone)
), X AS
(
    SELECT D.*, D.dur_ms / NULLIF(D.execs, 0) AS avg_ms, MAX(D.dur_ms / NULLIF(D.execs, 0)) OVER () AS max_avg, MAX(D.execs) OVER () AS max_execs,
           CASE WHEN D.d >= CONVERT(date, @cut_local) THEN 1 ELSE 0 END AS is_after,
           CASE WHEN D.d >= CONVERT(date, CONVERT(datetime2(0), (@b0 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone)) AND D.d <= CONVERT(date, CONVERT(datetime2(0), (@b1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone)) THEN 1 ELSE 0 END AS in_b
    FROM D
)
SELECT @rows = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td', CASE WHEN X.in_b = 1 OR X.is_after = 1 THEN N'' ELSE N' style="color:#9CA3AF"' END, N'>', LEFT(DATENAME(WEEKDAY, X.d), 3), N' ', CONVERT(nvarchar(10), X.d, 120),
    CASE WHEN X.d = CONVERT(date, @cut_local) THEN N' <span class="pill info">CUTOVER</span>' WHEN X.in_b = 1 THEN N' <span class="pill same">BEFORE</span>' ELSE N'' END, N'</td>',
    N'<td width="28%"><table role="presentation" class="b" cellpadding="0" cellspacing="0" border="0"><tr><td class="f" width="', pc.p1, N'%" bgcolor="', pc.c, N'" style="background:', pc.c, N'">&nbsp;</td><td class="x" width="', 100 - pc.p1, N'%">', FORMAT(X.avg_ms, 'N1'), N' ms</td></tr></table></td>',
    N'<td width="24%"><table role="presentation" class="b" cellpadding="0" cellspacing="0" border="0"><tr><td class="f" width="', pc.p2, N'%" bgcolor="', pc.c2, N'" style="background:', pc.c2, N'">&nbsp;</td><td class="x" width="', 100 - pc.p2, N'%">', FORMAT(X.execs, 'N0'), N'</td></tr></table></td>',
    N'<td class="n">', FORMAT(X.cpu_ms / NULLIF(X.execs, 0), 'N1'), N' ms</td>',
    N'<td class="n">', FORMAT(X.dur_ms / 1000.0 / 3600.0, 'N1'), N' h</td></tr>')), N'')
    WITHIN GROUP (ORDER BY X.d)
FROM X
CROSS APPLY (SELECT CASE WHEN X.avg_ms >= X.max_avg THEN 100 ELSE CONVERT(int, 100 * X.avg_ms / NULLIF(X.max_avg, 0)) + 1 END AS p1,
                    CASE WHEN X.execs >= X.max_execs THEN 100 ELSE CONVERT(int, 100 * X.execs / NULLIF(X.max_execs, 0)) + 1 END AS p2,
                    CASE WHEN X.is_after = 1 THEN N'#F59E0B' WHEN X.in_b = 1 THEN N'#2563EB' ELSE N'#CBD5E1' END AS c,
                    CASE WHEN X.is_after = 1 THEN N'#FCD34D' WHEN X.in_b = 1 THEN N'#93C5FD' ELSE N'#E2E8F0' END AS c2) AS pc;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Day by day</h2><div class="d">Average time per execution and executions per local day. Blue = the before period (same weekdays), amber = after the switch, grey = other days. Days with many more executions are batch days - compare like with like.</div>',
    N'<table class="t"><tr><th>Day</th><th>Avg time per execution</th><th>Executions</th><th>CPU / exec</th><th>Total query time</th></tr>',
    ISNULL(@rows, N'<tr><td colspan="5">No Query Store data.</td></tr>'), N'</table></div>');

/* glossary + method */
DECLARE @notes_html nvarchar(max) = (SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT(N'<li>', note, N'</li>')), N'') FROM @notes);
DECLARE @foot nvarchar(max) = CONCAT(
    CASE WHEN @notes_html IS NOT NULL THEN CONCAT(N'<ul style="margin:0 0 8px 16px;padding:0">', @notes_html, N'</ul>') ELSE N'' END,
    N'<b>Glossary.</b> <b>RCSI</b> (read committed snapshot): readers see the last committed version of a row instead of waiting for the writer; the price is that every modified row keeps its old version in tempdb (the <b>version store</b>) and grows by a 14-byte tag. ',
    N'<b>Lock wait</b>: time a query spent waiting for a lock; <b>LCK_M_S</b> = waiting for a shared (read) lock - the kind RCSI removes; <b>LCK_M_X / U</b> = writers waiting for writers - unchanged by RCSI. ',
    N'<b>Buffer IO (PAGEIOLATCH)</b>: waiting for a page to come from disk. <b>p95</b>: 95% of the 5-minute samples are at or below this value (the typical peak; the max is often one event). ',
    N'<b>Same-queries index</b>: the time the before workload would take at after per-execution speeds, minus 100% - a mix-free measure. <b>Impact</b>: (after - before ms) x executions per hour = seconds per hour gained or lost.<br>',
    N'<b>Method.</b> Query numbers: Query Store runtime statistics and wait statistics of ', @dbs, N' (regular executions; all plans of a query_hash merged). ',
    N'Instance numbers (blocking, deadlocks, server waits, CPU, tempdb, version store, I/O latency): OPS.mon 5.8 history. Windows: After = ', FORMAT(@ah / 24.0, 'N1'), N' days since the switch; Before = the same weekdays ', @weeks_back, N' week earlier; reference = ', @BeforeDays, N' days before the switch. ',
    N'Verdicts need a change of 10% or more. Expected RCSI signature: lock waits and reader blocking down, version store and tempdb up, a few percent more CPU / writes on modified rows, no change for queries that never waited. ',
    N'Generated ', CONVERT(nvarchar(16), CONVERT(datetime2(0), (@now AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120), N' ', @TzLabel, N' by RCSI_Impact_Report.sql v2', CASE WHEN @SendMail = 1 THEN CONCAT(N'; emailed to ', @Recipients) ELSE N'' END, N'.');

DECLARE @idx_txt nvarchar(60) = (SELECT CASE WHEN index_pct IS NULL THEN N'' WHEN index_pct >= 0 THEN CONCAT(N'same queries +', FORMAT(index_pct, 'N0'), N'%') ELSE CONCAT(N'same queries ', FORMAT(index_pct, 'N0'), N'%') END FROM #Idx WHERE class = 'ALL');
DECLARE @html nvarchar(max) = CONCAT(
    N'<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>RCSI impact - ', @ServerLabel, N'</title>', @css, N'</head><body>',
    N'<div class="card"><div class="banner"><div class="eyebrow">', @ServerLabel, N' &middot; READ COMMITTED SNAPSHOT</div>',
    N'<div class="title">RCSI on ', @ServerLabel, N': what changed, what it costs, what to do</div>',
    N'<div class="sub">', @n_good, N' good &middot; ', @n_bad, N' problem(s) &middot; ', @n_warn, N' to watch', CASE WHEN @idx_txt <> N'' THEN CONCAT(N' &middot; ', @idx_txt) ELSE N'' END, N' &middot; ', @dbs, N'</div></div>',
    @h, N'<div class="foot">', @foot, N'</div></div></body></html>');

/* ============================ EMAIL (Database Mail, same as OPS.mon) ============================ */
DECLARE @mail_status nvarchar(1000) = N'not sent (@SendMail = 0)', @mailitem_id int = NULL, @profile sysname = @MailProfile;
IF @SendMail = 1
BEGIN
    BEGIN TRY
        IF @profile IS NULL AND OBJECT_ID(N'OPS.mon.Setting') IS NOT NULL
            SELECT @profile = NULLIF(setting_value, N'') FROM OPS.mon.Setting WHERE setting_name = 'mail_profile';
        DECLARE @s_idx nvarchar(60) = (SELECT CASE WHEN index_pct IS NULL THEN N'' WHEN index_pct >= 0 THEN CONCAT(N' | same queries +', FORMAT(index_pct, 'N0'), N'%') ELSE CONCAT(N' | same queries ', FORMAT(index_pct, 'N0'), N'%') END FROM #Idx WHERE class = 'ALL'),
                @s_vs nvarchar(60) = (SELECT CONCAT(N' | version store max ', FORMAT(vs_max / 1024.0, 'N1'), N' GB') FROM #Agg WHERE win = 'A' AND vs_max IS NOT NULL);
        DECLARE @subject nvarchar(255) = LEFT(CONCAT(N'[', @ServerLabel, N'] RCSI impact v2 ', CONVERT(nvarchar(10), @cut_local, 120), N' -> ',
            CONVERT(nvarchar(10), CONVERT(datetime2(0), (@a1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120),
            N' | ', @n_good, N' good, ', @n_bad, N' problem(s), ', @n_warn, N' watch', ISNULL(@s_idx, N''), ISNULL(@s_vs, N'')), 255);
        IF @profile IS NOT NULL
            EXEC msdb.dbo.sp_send_dbmail @profile_name = @profile, @recipients = @Recipients, @subject = @subject,
                 @body = @html, @body_format = 'HTML', @importance = 'Normal', @mailitem_id = @mailitem_id OUTPUT;
        ELSE
            EXEC msdb.dbo.sp_send_dbmail @recipients = @Recipients, @subject = @subject,
                 @body = @html, @body_format = 'HTML', @importance = 'Normal', @mailitem_id = @mailitem_id OUTPUT;
        SET @mail_status = CONCAT(N'queued: mailitem_id ', @mailitem_id, N' via profile ', ISNULL(@profile, N'(default)'), N' to ', @Recipients);
    END TRY
    BEGIN CATCH
        SET @mail_status = LEFT(CONCAT(N'FAILED: ', ERROR_MESSAGE(), N' (profile ', ISNULL(@profile, N'?'), N')'), 1000);
    END CATCH;
    PRINT CONCAT(N'Email ', @mail_status);
END;

SELECT @mail_status AS [Email], @Recipients AS [Recipients], DATALENGTH(@html) / 2048 AS [HTML KB],
       CASE WHEN DATALENGTH(@html) / 2048 > 100 THEN N'over ~100 KB: Gmail clips the message (Outlook does not); lower @TopN' ELSE N'' END AS [Size note],
       @html AS html;
