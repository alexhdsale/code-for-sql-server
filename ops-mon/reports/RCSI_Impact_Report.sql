/* =============================================================================
   RCSI IMPACT REPORT  -  performance BEFORE vs AFTER READ COMMITTED SNAPSHOT
   Target : MS-APP-PROD (Amazon RDS for SQL Server 2017+; tested layout: 2022)
   Reads  : Query Store of every selected database (runtime stats + wait stats),
            OPS.mon 5.8 history when present (blocking, deadlocks, waits, CPU,
            tempdb / version store, I/O latency). Nothing is written anywhere.
   Output : result sets for SSMS (scorecard, per database, waits, top queries,
            lock-wait queries, notes) + ONE HTML document (last result set, column
            html) that is also EMAILED through Database Mail to @Recipients.

   HOW TO RUN (SSMS, any database context, login that can read the app databases'
   Query Store and OPS.mon):
     1. Set the parameters below (@CutoverLocal, @Databases) - or leave NULL:
        the cutover is taken from OPS.mon.RcsiCutover, the databases = every
        database with is_read_committed_snapshot_on = 1.
     2. Execute the whole file.  Results: scorecard, per-database workload,
        wait categories, top regressed / improved queries, lock-wait queries,
        notes, html + mail status.  @SendMail = 0 for the result sets only.
   ============================================================================= */
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* ------------------------------- PARAMETERS ------------------------------- */
DECLARE @CutoverLocal   datetime2(0)  = NULL;          /* e.g. '2026-10-24 22:00'  (display time zone); NULL = from OPS.mon.RcsiCutover */
DECLARE @Databases      nvarchar(max) = NULL;          /* 'Db1,Db2'; NULL = every database with RCSI ON */
DECLARE @BeforeDays     int           = 7;             /* "before" window length, ending at the cutover */
DECLARE @AfterDays      int           = NULL;          /* "after" window length, starting at the cutover; NULL = until now */
DECLARE @SkipHours      int           = 1;             /* hours after the cutover excluded (plan cache warm-up, the change itself) */
DECLARE @TimeZone       nvarchar(100) = N'Eastern Standard Time';
DECLARE @TzLabel        nvarchar(10)  = N'ET';
DECLARE @TopN           int           = 20;            /* queries listed per table */
DECLARE @MinExecs       int           = 20;            /* a query needs this many executions in BOTH windows to be compared */
DECLARE @MinAvgMs       int           = 5;             /* ... and an average duration of at least this many ms in one window */
DECLARE @ServerLabel    nvarchar(128) = NULL;          /* NULL = OPS.mon server_label or @@SERVERNAME */
DECLARE @Recipients     nvarchar(1000)= N'aleksey_kokit@miopartners.com';   /* who gets the HTML report (semicolon separated) */
DECLARE @SendMail       bit           = 1;             /* 1 = email the HTML through Database Mail; 0 = result sets only */
DECLARE @MailProfile    sysname       = NULL;          /* NULL = OPS.mon mail_profile (e.g. Notifications), else the default Database Mail profile */
/* -------------------------------------------------------------------------- */

DECLARE @now datetime2(0) = SYSUTCDATETIME(), @sql nvarchar(max), @db sysname, @msg nvarchar(4000);
DECLARE @has_mon bit = CASE WHEN OBJECT_ID(N'OPS.mon.TempdbSample') IS NOT NULL THEN 1 ELSE 0 END;
DECLARE @notes TABLE (seq int IDENTITY, note nvarchar(1000));

IF @ServerLabel IS NULL AND OBJECT_ID(N'OPS.mon.Setting') IS NOT NULL
    SELECT @ServerLabel = setting_value FROM OPS.mon.Setting WHERE setting_name = 'server_label';
SET @ServerLabel = ISNULL(@ServerLabel, @@SERVERNAME);

/* ---- databases ---- */
CREATE TABLE #Db (database_name sysname PRIMARY KEY, database_id int, is_rcsi_on bit, si_state nvarchar(60),
                  qs_desired nvarchar(60), qs_actual nvarchar(60), qs_capture nvarchar(60), qs_interval_min int,
                  qs_oldest_utc datetime2(0), qs_ok bit, note nvarchar(400));
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
    SELECT @cut_utc = CONVERT(datetime2(0), (@CutoverLocal AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC'), @cut_src = N'parameter @CutoverLocal';
ELSE IF OBJECT_ID(N'OPS.mon.RcsiCutover') IS NOT NULL
BEGIN
    SELECT @cut_utc = MIN(c.enabled_utc)
    FROM OPS.mon.RcsiCutover AS c JOIN #Db AS d ON d.database_name = c.database_name
    WHERE c.enabled_utc IS NOT NULL;
    SET @cut_src = N'OPS.mon.RcsiCutover (earliest enabled_utc of the selected databases)';
END;
IF @cut_utc IS NULL
BEGIN
    RAISERROR(N'Cutover unknown: set @CutoverLocal (e.g. ''2026-10-24 22:00'') - OPS.mon.RcsiCutover has no date for the selected databases.', 16, 1);
    RETURN;
END;
DECLARE @cut_local datetime2(0) = CONVERT(datetime2(0), (@cut_utc AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone);

DECLARE @b0 datetime2(0) = DATEADD(DAY, -@BeforeDays, @cut_utc),
        @b1 datetime2(0) = @cut_utc,
        @a0 datetime2(0) = DATEADD(HOUR, @SkipHours, @cut_utc),
        @a1 datetime2(0) = CASE WHEN @AfterDays IS NULL THEN @now ELSE DATEADD(DAY, @AfterDays, @cut_utc) END;
IF @a1 > @now SET @a1 = @now;
IF @a1 <= @a0
BEGIN
    DECLARE @cut_txt varchar(19) = CONVERT(varchar(19), @cut_utc, 120);
    RAISERROR(N'The "after" window is empty: the cutover (%s UTC) is too recent.', 16, 1, @cut_txt);
    RETURN;
END;
DECLARE @bh decimal(9,2) = DATEDIFF(MINUTE, @b0, @b1) / 60.0, @ah decimal(9,2) = DATEDIFF(MINUTE, @a0, @a1) / 60.0;

CREATE TABLE #Win (win char(1) PRIMARY KEY, t0 datetime2(0), t1 datetime2(0), hours decimal(9,2));
INSERT #Win VALUES ('B', @b0, @b1, @bh), ('A', @a0, @a1, @ah);

/* ============================ QUERY STORE ============================ */
CREATE TABLE #QsKpi (database_name sysname, win char(1), execs bigint, queries int, plans int,
                     dur_ms decimal(19,1), cpu_ms decimal(19,1), reads bigint, writes bigint, tempdb_pages bigint,
                     max_dur_ms decimal(19,1), max_cpu_ms decimal(19,1), dop_weighted decimal(9,2), grant_pages bigint,
                     aborted bigint, exceptions bigint, PRIMARY KEY (database_name, win));
CREATE TABLE #QsWait (database_name sysname, win char(1), wait_category nvarchar(60), wait_ms bigint,
                      PRIMARY KEY (database_name, win, wait_category));
CREATE TABLE #QsQuery (database_name sysname, win char(1), query_hash binary(8), query_id bigint, object_name nvarchar(300),
                       sql_text nvarchar(400), execs bigint, dur_ms decimal(19,1), cpu_ms decimal(19,1), reads bigint,
                       writes bigint, tempdb_pages bigint, max_dur_ms decimal(19,1), lock_wait_ms bigint, plans int,
                       PRIMARY KEY (database_name, win, query_hash));
CREATE TABLE #QsHour (database_name sysname, hour_utc datetime2(0), execs bigint, dur_ms decimal(19,1), cpu_ms decimal(19,1),
                      PRIMARY KEY (database_name, hour_utc));

DECLARE dbc CURSOR LOCAL FAST_FORWARD FOR SELECT database_name FROM #Db ORDER BY database_name;
OPEN dbc; FETCH NEXT FROM dbc INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'USE ' + QUOTENAME(@db) + N';
            UPDATE d SET qs_desired = o.desired_state_desc, qs_actual = o.actual_state_desc, qs_capture = o.query_capture_mode_desc,
                         qs_interval_min = o.interval_length_minutes,
                         qs_oldest_utc = (SELECT CONVERT(datetime2(0), MIN(start_time)) FROM sys.query_store_runtime_stats_interval),
                         qs_ok = CASE WHEN o.actual_state_desc IN (N''READ_WRITE'', N''READ_ONLY'') THEN 1 ELSE 0 END
            FROM #Db AS d CROSS JOIN sys.database_query_store_options AS o WHERE d.database_name = @db;';
        EXEC sys.sp_executesql @sql, N'@db sysname', @db = @db;

        IF (SELECT qs_ok FROM #Db WHERE database_name = @db) = 1
        BEGIN
            /* KPIs per window */
            SET @sql = N'USE ' + QUOTENAME(@db) + N';
            INSERT #QsKpi(database_name, win, execs, queries, plans, dur_ms, cpu_ms, reads, writes, tempdb_pages, max_dur_ms, max_cpu_ms, dop_weighted, grant_pages, aborted, exceptions)
            SELECT @db, w.win, SUM(rs.count_executions), COUNT(DISTINCT p.query_id), COUNT(DISTINCT rs.plan_id),
                   SUM(rs.count_executions * rs.avg_duration) / 1000.0, SUM(rs.count_executions * rs.avg_cpu_time) / 1000.0,
                   SUM(rs.count_executions * rs.avg_logical_io_reads), SUM(rs.count_executions * rs.avg_logical_io_writes),
                   SUM(rs.count_executions * rs.avg_tempdb_space_used),
                   MAX(rs.max_duration) / 1000.0, MAX(rs.max_cpu_time) / 1000.0,
                   SUM(rs.count_executions * rs.avg_dop) * 1.0 / NULLIF(SUM(rs.count_executions), 0),
                   SUM(rs.count_executions * rs.avg_query_max_used_memory),
                   SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END),
                   SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END)
            FROM #Win AS w
            JOIN sys.query_store_runtime_stats_interval AS i ON i.start_time >= w.t0 AND i.end_time <= w.t1
            JOIN sys.query_store_runtime_stats AS rs ON rs.runtime_stats_interval_id = i.runtime_stats_interval_id
            JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
            GROUP BY w.win;

            /* wait categories per window */
            INSERT #QsWait(database_name, win, wait_category, wait_ms)
            SELECT @db, w.win, ws.wait_category_desc, SUM(ws.total_query_wait_time_ms)
            FROM #Win AS w
            JOIN sys.query_store_runtime_stats_interval AS i ON i.start_time >= w.t0 AND i.end_time <= w.t1
            JOIN sys.query_store_wait_stats AS ws ON ws.runtime_stats_interval_id = i.runtime_stats_interval_id
            GROUP BY w.win, ws.wait_category_desc;

            /* per query (query_hash merges plans and recompiled query_ids) */
            ;WITH R AS
            (
                SELECT w.win, q.query_hash, q.query_id, q.object_id, p.plan_id, rs.runtime_stats_interval_id,
                       rs.count_executions, rs.avg_duration, rs.avg_cpu_time, rs.avg_logical_io_reads, rs.avg_logical_io_writes,
                       rs.avg_tempdb_space_used, rs.max_duration
                FROM #Win AS w
                JOIN sys.query_store_runtime_stats_interval AS i ON i.start_time >= w.t0 AND i.end_time <= w.t1
                JOIN sys.query_store_runtime_stats AS rs ON rs.runtime_stats_interval_id = i.runtime_stats_interval_id
                JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
                JOIN sys.query_store_query AS q ON q.query_id = p.query_id
                WHERE rs.execution_type = 0
            ), L AS
            (
                SELECT w.win, q.query_hash, SUM(ws.total_query_wait_time_ms) AS lock_ms
                FROM #Win AS w
                JOIN sys.query_store_runtime_stats_interval AS i ON i.start_time >= w.t0 AND i.end_time <= w.t1
                JOIN sys.query_store_wait_stats AS ws ON ws.runtime_stats_interval_id = i.runtime_stats_interval_id
                JOIN sys.query_store_plan AS p ON p.plan_id = ws.plan_id
                JOIN sys.query_store_query AS q ON q.query_id = p.query_id
                WHERE ws.wait_category_desc = N''Lock''
                GROUP BY w.win, q.query_hash
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
            INSERT #QsQuery(database_name, win, query_hash, query_id, object_name, sql_text, execs, dur_ms, cpu_ms, reads, writes, tempdb_pages, max_dur_ms, lock_wait_ms, plans)
            SELECT @db, G.win, G.query_hash, G.query_id,
                   CASE WHEN G.object_id > 0 THEN OBJECT_SCHEMA_NAME(G.object_id) + N''.'' + OBJECT_NAME(G.object_id) END,
                   LEFT(t.query_sql_text, 400),
                   G.execs, G.dur_ms, G.cpu_ms, G.reads, G.writes, G.tempdb_pages, G.max_dur_ms, ISNULL(L.lock_ms, 0), G.plans
            FROM G
            LEFT JOIN L ON L.win = G.win AND L.query_hash = G.query_hash
            JOIN sys.query_store_query AS q ON q.query_id = G.query_id
            JOIN sys.query_store_query_text AS t ON t.query_text_id = q.query_text_id;

            /* hourly profile (both windows) */
            INSERT #QsHour(database_name, hour_utc, execs, dur_ms, cpu_ms)
            SELECT @db, DATEADD(HOUR, DATEDIFF(HOUR, 0, CONVERT(datetime2(0), i.start_time)), 0),
                   SUM(rs.count_executions), SUM(rs.count_executions * rs.avg_duration) / 1000.0, SUM(rs.count_executions * rs.avg_cpu_time) / 1000.0
            FROM sys.query_store_runtime_stats_interval AS i
            JOIN sys.query_store_runtime_stats AS rs ON rs.runtime_stats_interval_id = i.runtime_stats_interval_id
            WHERE i.start_time >= @b0 AND i.end_time <= @a1
            GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, CONVERT(datetime2(0), i.start_time)), 0);';
            EXEC sys.sp_executesql @sql, N'@db sysname, @b0 datetime2(0), @a1 datetime2(0)', @db = @db, @b0 = @b0, @a1 = @a1;
        END
        ELSE
            UPDATE #Db SET note = N'Query Store not active (' + ISNULL(qs_actual, N'?') + N') - workload sections skipped' WHERE database_name = @db;

        IF (SELECT qs_oldest_utc FROM #Db WHERE database_name = @db) > @b0
            UPDATE #Db SET note = CONCAT(ISNULL(note + N'; ', N''), N'Query Store history starts ', CONVERT(nvarchar(16), qs_oldest_utc, 120),
                                         N' UTC - the BEFORE window is only partially covered') WHERE database_name = @db;
    END TRY
    BEGIN CATCH
        UPDATE #Db SET note = LEFT(CONCAT(N'Query Store read failed: ', ERROR_MESSAGE()), 400) WHERE database_name = @db;
    END CATCH;
    FETCH NEXT FROM dbc INTO @db;
END;
CLOSE dbc; DEALLOCATE dbc;

/* ============================ OPS.mon HISTORY ============================ */
CREATE TABLE #Mon (win char(1), metric nvarchar(60), value decimal(19,3), PRIMARY KEY (win, metric));
IF @has_mon = 1
BEGIN
    BEGIN TRY
        /* blocking */
        INSERT #Mon SELECT w.win, N'blocking_episodes', COUNT(e.episode_id)
        FROM #Win AS w LEFT JOIN OPS.mon.BlockingEpisode AS e ON e.blocked_since_utc >= w.t0 AND e.blocked_since_utc < w.t1
             AND (e.head_database IN (SELECT database_name FROM #Db) OR e.head_database IS NULL)
        GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'blocking_minutes', ISNULL(SUM(DATEDIFF(SECOND, e.blocked_since_utc, ISNULL(e.ended_utc, e.last_seen_utc))), 0) / 60.0
        FROM #Win AS w LEFT JOIN OPS.mon.BlockingEpisode AS e ON e.blocked_since_utc >= w.t0 AND e.blocked_since_utc < w.t1
             AND (e.head_database IN (SELECT database_name FROM #Db) OR e.head_database IS NULL)
        GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'blocking_longest_min', ISNULL(MAX(DATEDIFF(SECOND, e.blocked_since_utc, ISNULL(e.ended_utc, e.last_seen_utc))), 0) / 60.0
        FROM #Win AS w LEFT JOIN OPS.mon.BlockingEpisode AS e ON e.blocked_since_utc >= w.t0 AND e.blocked_since_utc < w.t1
             AND (e.head_database IN (SELECT database_name FROM #Db) OR e.head_database IS NULL)
        GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'blocking_max_victims', ISNULL(MAX(e.max_blocked_count), 0)
        FROM #Win AS w LEFT JOIN OPS.mon.BlockingEpisode AS e ON e.blocked_since_utc >= w.t0 AND e.blocked_since_utc < w.t1
        GROUP BY w.win;
        /* deadlocks */
        INSERT #Mon SELECT w.win, N'deadlocks', COUNT(d.deadlock_hash)
        FROM #Win AS w LEFT JOIN OPS.mon.Deadlock AS d ON d.event_utc >= w.t0 AND d.event_utc < w.t1
             AND (d.database_name IN (SELECT database_name FROM #Db) OR d.database_name IS NULL)
        GROUP BY w.win;
        /* long queries / open transactions issues opened */
        INSERT #Mon SELECT w.win, N'longq_issues', COUNT(i.issue_id)
        FROM #Win AS w LEFT JOIN OPS.mon.Issue AS i ON i.first_seen_utc >= w.t0 AND i.first_seen_utc < w.t1 AND i.issue_key LIKE N'LONGQ:%'
        GROUP BY w.win;
        INSERT #Mon SELECT w.win, N'opentran_issues', COUNT(i.issue_id)
        FROM #Win AS w LEFT JOIN OPS.mon.Issue AS i ON i.first_seen_utc >= w.t0 AND i.first_seen_utc < w.t1 AND i.issue_key LIKE N'OPENTRAN:%'
        GROUP BY w.win;
        /* server waits (hourly cumulative snapshots -> positive deltas) */
        ;WITH S AS
        (
            SELECT w.win, s.wait_type, s.wait_ms - LAG(s.wait_ms) OVER (PARTITION BY w.win, s.wait_type ORDER BY s.snapshot_utc) AS d_ms
            FROM #Win AS w JOIN OPS.mon.WaitStatsSnapshot AS s ON s.snapshot_utc >= w.t0 AND s.snapshot_utc < w.t1
        )
        INSERT #Mon SELECT S.win, N'wait_' + x.grp, ISNULL(SUM(CASE WHEN S.d_ms > 0 THEN S.d_ms ELSE 0 END), 0) / 1000.0
        FROM S CROSS APPLY (SELECT CASE WHEN S.wait_type LIKE N'LCK[_]M[_]%' THEN N'lock'
                                        WHEN S.wait_type LIKE N'PAGELATCH[_]%' THEN N'pagelatch'
                                        WHEN S.wait_type LIKE N'PAGEIOLATCH[_]%' THEN N'pageiolatch'
                                        WHEN S.wait_type = N'WRITELOG' THEN N'writelog'
                                        WHEN S.wait_type IN (N'CXPACKET', N'CXCONSUMER') THEN N'parallel'
                                        WHEN S.wait_type = N'SOS_SCHEDULER_YIELD' THEN N'cpu'
                                        WHEN S.wait_type = N'RESOURCE_SEMAPHORE' THEN N'memgrant'
                                        ELSE N'other' END AS grp) AS x
        GROUP BY S.win, x.grp;
        /* CPU */
        INSERT #Mon SELECT w.win, N'cpu_avg', AVG(c.sql_cpu_pct * 1.0) FROM #Win AS w JOIN OPS.mon.CpuSample AS c ON c.sample_utc >= w.t0 AND c.sample_utc < w.t1 GROUP BY w.win;
        INSERT #Mon SELECT DISTINCT w.win, N'cpu_p95', PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY c.sql_cpu_pct) OVER (PARTITION BY w.win)
        FROM #Win AS w JOIN OPS.mon.CpuSample AS c ON c.sample_utc >= w.t0 AND c.sample_utc < w.t1;
        /* batch requests per second, PLE, grants pending */
        SELECT w.win, p.sample_utc, p.ple_sec, p.memory_grants_pending,
               p.batch_requests_total - LAG(p.batch_requests_total) OVER (PARTITION BY w.win ORDER BY p.sample_utc) AS d_batch,
               DATEDIFF(SECOND, LAG(p.sample_utc) OVER (PARTITION BY w.win ORDER BY p.sample_utc), p.sample_utc) AS d_s
        INTO #P
        FROM #Win AS w JOIN OPS.mon.PerfSample AS p ON p.sample_utc >= w.t0 AND p.sample_utc < w.t1;
        INSERT #Mon SELECT P.win, N'batch_per_s', SUM(CASE WHEN P.d_batch > 0 THEN P.d_batch ELSE 0 END) * 1.0 / NULLIF(SUM(CASE WHEN P.d_batch > 0 THEN P.d_s ELSE 0 END), 0) FROM #P AS P GROUP BY P.win;
        INSERT #Mon SELECT P.win, N'ple_avg', AVG(P.ple_sec * 1.0) FROM #P AS P GROUP BY P.win;
        INSERT #Mon SELECT P.win, N'grants_pending_max', MAX(P.memory_grants_pending) FROM #P AS P GROUP BY P.win;
        /* tempdb */
        IF OBJECT_ID(N'OPS.mon.TempdbSample') IS NOT NULL
        BEGIN
            INSERT #Mon SELECT w.win, N'tempdb_used_avg', AVG(t.used_mb) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1 GROUP BY w.win;
            INSERT #Mon SELECT DISTINCT w.win, N'tempdb_used_p95', PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY t.used_mb) OVER (PARTITION BY w.win) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1;
            INSERT #Mon SELECT w.win, N'tempdb_used_max', MAX(t.used_mb) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1 GROUP BY w.win;
            INSERT #Mon SELECT w.win, N'vs_avg', AVG(t.version_store_mb) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1 GROUP BY w.win;
            INSERT #Mon SELECT DISTINCT w.win, N'vs_p95', PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY t.version_store_mb) OVER (PARTITION BY w.win) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1;
            INSERT #Mon SELECT w.win, N'vs_max', MAX(t.version_store_mb) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1 GROUP BY w.win;
            INSERT #Mon SELECT w.win, N'vs_tran_max_min', ISNULL(MAX(t.vs_longest_tran_s), 0) / 60.0 FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1 GROUP BY w.win;
            INSERT #Mon SELECT w.win, N'tempdb_size_max', MAX(t.size_mb) FROM #Win AS w JOIN OPS.mon.TempdbSample AS t ON t.sample_utc >= w.t0 AND t.sample_utc < w.t1 GROUP BY w.win;
            INSERT #Mon SELECT w.win, N'tempdb_growths', COUNT(g.event_utc) FROM #Win AS w LEFT JOIN OPS.mon.TempdbGrowthEvent AS g ON g.event_utc >= w.t0 AND g.event_utc < w.t1 GROUP BY w.win;
        END;
        /* I/O latency per window: selected databases' data files + tempdb */
        ;WITH F AS
        (
            SELECT w.win, CASE WHEN f.database_id = 2 THEN N'tempdb' ELSE N'data' END AS kind,
                   f.num_reads - LAG(f.num_reads) OVER (PARTITION BY w.win, f.database_id, f.file_id ORDER BY f.snapshot_utc) AS d_rd,
                   f.num_writes - LAG(f.num_writes) OVER (PARTITION BY w.win, f.database_id, f.file_id ORDER BY f.snapshot_utc) AS d_wr,
                   f.io_stall_read_ms - LAG(f.io_stall_read_ms) OVER (PARTITION BY w.win, f.database_id, f.file_id ORDER BY f.snapshot_utc) AS d_srd,
                   f.io_stall_write_ms - LAG(f.io_stall_write_ms) OVER (PARTITION BY w.win, f.database_id, f.file_id ORDER BY f.snapshot_utc) AS d_swr
            FROM #Win AS w JOIN OPS.mon.FileStatsSnapshot AS f ON f.snapshot_utc >= w.t0 AND f.snapshot_utc < w.t1
            WHERE f.database_id = 2 OR f.database_id IN (SELECT database_id FROM #Db)
        ), G AS
        (
            SELECT F.win, F.kind,
                   SUM(CASE WHEN F.d_srd > 0 THEN F.d_srd ELSE 0 END) * 1.0 / NULLIF(SUM(CASE WHEN F.d_rd > 0 THEN F.d_rd ELSE 0 END), 0) AS read_ms,
                   SUM(CASE WHEN F.d_swr > 0 THEN F.d_swr ELSE 0 END) * 1.0 / NULLIF(SUM(CASE WHEN F.d_wr > 0 THEN F.d_wr ELSE 0 END), 0) AS write_ms
            FROM F GROUP BY F.win, F.kind
        )
        INSERT #Mon SELECT G.win, N'io_' + G.kind + N'_' + x.m, x.v
        FROM G CROSS APPLY (VALUES (N'read_ms', G.read_ms), (N'write_ms', G.write_ms)) AS x(m, v);
    END TRY
    BEGIN CATCH
        INSERT @notes VALUES (LEFT(CONCAT(N'OPS.mon history partially unavailable: ', ERROR_MESSAGE()), 1000));
    END CATCH;
END
ELSE
    INSERT @notes VALUES (N'OPS.mon is not installed on this instance: blocking, deadlocks, server waits, CPU, tempdb and I/O sections are skipped (Query Store only).');

/* ============================ SCORECARD ============================ */
/* one row per metric; direction: -1 = lower is better, +1 = higher is better, 0 = informational */
CREATE TABLE #Score (seq int, grp nvarchar(30), metric nvarchar(80), unit nvarchar(12), direction smallint,
                     before_v decimal(19,3) NULL, after_v decimal(19,3) NULL, pct decimal(9,1) NULL, verdict nvarchar(10) NULL, note nvarchar(200) NULL);

CREATE TABLE #Agg (win char(1) PRIMARY KEY, hours decimal(9,2), execs bigint, dur_ms decimal(19,1), cpu_ms decimal(19,1), reads bigint, writes bigint,
                   tempdb_pages bigint, max_dur_ms decimal(19,1), aborted bigint, lock_ms bigint, bufio_ms bigint, latch_ms bigint, log_ms bigint, all_ms bigint,
                   blocking_episodes decimal(19,3), blocking_minutes decimal(19,3), blocking_longest_min decimal(19,3), blocking_max_victims decimal(19,3), deadlocks decimal(19,3), longq_issues decimal(19,3), opentran_issues decimal(19,3), wait_lock decimal(19,3), wait_pagelatch decimal(19,3), wait_writelog decimal(19,3), cpu_avg decimal(19,3), cpu_p95 decimal(19,3), batch_per_s decimal(19,3), ple_avg decimal(19,3), grants_pending_max decimal(19,3), tempdb_used_avg decimal(19,3), tempdb_used_p95 decimal(19,3), tempdb_used_max decimal(19,3), vs_avg decimal(19,3), vs_p95 decimal(19,3), vs_max decimal(19,3), vs_tran_max_min decimal(19,3), tempdb_size_max decimal(19,3), tempdb_growths decimal(19,3), io_data_read_ms decimal(19,3), io_data_write_ms decimal(19,3), io_tempdb_read_ms decimal(19,3), io_tempdb_write_ms decimal(19,3));
INSERT #Agg(win, hours, execs, dur_ms, cpu_ms, reads, writes, tempdb_pages, max_dur_ms, aborted, lock_ms, bufio_ms, latch_ms, log_ms, all_ms,
            blocking_episodes, blocking_minutes, blocking_longest_min, blocking_max_victims, deadlocks, longq_issues, opentran_issues, wait_lock, wait_pagelatch, wait_writelog, cpu_avg, cpu_p95, batch_per_s, ple_avg, grants_pending_max, tempdb_used_avg, tempdb_used_p95, tempdb_used_max, vs_avg, vs_p95, vs_max, vs_tran_max_min, tempdb_size_max, tempdb_growths, io_data_read_ms, io_data_write_ms, io_tempdb_read_ms, io_tempdb_write_ms)
SELECT w.win, w.hours, k.execs, k.dur_ms, k.cpu_ms, k.reads, k.writes, k.tempdb_pages, k.max_dur_ms, k.aborted, q.lock_ms, q.bufio_ms, q.latch_ms, q.log_ms, q.all_ms,
       m.blocking_episodes, m.blocking_minutes, m.blocking_longest_min, m.blocking_max_victims, m.deadlocks, m.longq_issues, m.opentran_issues, m.wait_lock, m.wait_pagelatch, m.wait_writelog, m.cpu_avg, m.cpu_p95, m.batch_per_s, m.ple_avg, m.grants_pending_max, m.tempdb_used_avg, m.tempdb_used_p95, m.tempdb_used_max, m.vs_avg, m.vs_p95, m.vs_max, m.vs_tran_max_min, m.tempdb_size_max, m.tempdb_growths, m.io_data_read_ms, m.io_data_write_ms, m.io_tempdb_read_ms, m.io_tempdb_write_ms
FROM #Win AS w
LEFT JOIN (SELECT win, SUM(execs) AS execs, SUM(dur_ms) AS dur_ms, SUM(cpu_ms) AS cpu_ms, SUM(reads) AS reads, SUM(writes) AS writes,
                  SUM(tempdb_pages) AS tempdb_pages, MAX(max_dur_ms) AS max_dur_ms, SUM(aborted + exceptions) AS aborted
           FROM #QsKpi GROUP BY win) AS k ON k.win = w.win
LEFT JOIN (SELECT win, SUM(CASE WHEN wait_category = N'Lock' THEN wait_ms ELSE 0 END) AS lock_ms,
                  SUM(CASE WHEN wait_category = N'Buffer IO' THEN wait_ms ELSE 0 END) AS bufio_ms,
                  SUM(CASE WHEN wait_category = N'Buffer Latch' THEN wait_ms ELSE 0 END) AS latch_ms,
                  SUM(CASE WHEN wait_category = N'Tran Log IO' THEN wait_ms ELSE 0 END) AS log_ms,
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
       MAX(CASE WHEN m.metric = N'wait_lock' THEN m.value END) AS wait_lock,
       MAX(CASE WHEN m.metric = N'wait_pagelatch' THEN m.value END) AS wait_pagelatch,
       MAX(CASE WHEN m.metric = N'wait_writelog' THEN m.value END) AS wait_writelog,
       MAX(CASE WHEN m.metric = N'cpu_avg' THEN m.value END) AS cpu_avg,
       MAX(CASE WHEN m.metric = N'cpu_p95' THEN m.value END) AS cpu_p95,
       MAX(CASE WHEN m.metric = N'batch_per_s' THEN m.value END) AS batch_per_s,
       MAX(CASE WHEN m.metric = N'ple_avg' THEN m.value END) AS ple_avg,
       MAX(CASE WHEN m.metric = N'grants_pending_max' THEN m.value END) AS grants_pending_max,
       MAX(CASE WHEN m.metric = N'tempdb_used_avg' THEN m.value END) AS tempdb_used_avg,
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
       MAX(CASE WHEN m.metric = N'io_tempdb_read_ms' THEN m.value END) AS io_tempdb_read_ms,
       MAX(CASE WHEN m.metric = N'io_tempdb_write_ms' THEN m.value END) AS io_tempdb_write_ms
           FROM #Mon AS m GROUP BY win) AS m ON m.win = w.win;

;WITH V AS
(
    SELECT x.seq, x.grp, x.metric, x.unit, x.direction, x.b, x.a, x.note
    FROM (SELECT 1 AS one) AS o
    LEFT JOIN #Agg AS B ON B.win = 'B'
    LEFT JOIN #Agg AS A ON A.win = 'A'
    CROSS APPLY (VALUES
        /* --- Query Store: the application's own queries --- */
        (10, N'Workload', N'Executions per hour',                N'/h',    0,  B.execs / NULLIF(@bh, 0), A.execs / NULLIF(@ah, 0), N'Query Store, selected databases'),
        (11, N'Workload', N'Avg duration per execution',         N'ms',   -1,  B.dur_ms / NULLIF(B.execs, 0), A.dur_ms / NULLIF(A.execs, 0), N'elapsed, all queries weighted by executions'),
        (12, N'Workload', N'Avg CPU per execution',              N'ms',   -1,  B.cpu_ms / NULLIF(B.execs, 0), A.cpu_ms / NULLIF(A.execs, 0), NULL),
        (13, N'Workload', N'Avg logical reads per execution',    N'pages', -1, B.reads * 1.0 / NULLIF(B.execs, 0), A.reads * 1.0 / NULLIF(A.execs, 0), N'RCSI adds the 14-byte version pointer to modified rows'),
        (14, N'Workload', N'Avg logical writes per execution',   N'pages', -1, B.writes * 1.0 / NULLIF(B.execs, 0), A.writes * 1.0 / NULLIF(A.execs, 0), NULL),
        (15, N'Workload', N'Avg tempdb per execution',           N'pages', -1, B.tempdb_pages * 1.0 / NULLIF(B.execs, 0), A.tempdb_pages * 1.0 / NULLIF(A.execs, 0), N'query-level tempdb (sorts, spools), not the version store'),
        (16, N'Workload', N'Total query time per hour',          N's/h',  -1,  B.dur_ms / 1000.0 / NULLIF(@bh, 0), A.dur_ms / 1000.0 / NULLIF(@ah, 0), N'sum of elapsed time - the overall load'),
        (17, N'Workload', N'Slowest single execution',           N'ms',   -1,  B.max_dur_ms, A.max_dur_ms, NULL),
        (18, N'Workload', N'Aborted / exception executions per hour', N'/h', -1, B.aborted / NULLIF(@bh, 0), A.aborted / NULLIF(@ah, 0), N'timeouts, cancels, errors (incl. 3960 update conflicts under SI)'),
        /* --- Query Store waits --- */
        (20, N'Waits',    N'Lock wait per execution',            N'ms',   -1,  B.lock_ms * 1.0 / NULLIF(B.execs, 0), A.lock_ms * 1.0 / NULLIF(A.execs, 0), N'the wait RCSI is meant to remove (readers vs writers)'),
        (21, N'Waits',    N'Lock wait per hour',                 N's/h',  -1,  B.lock_ms / 1000.0 / NULLIF(@bh, 0), A.lock_ms / 1000.0 / NULLIF(@ah, 0), NULL),
        (22, N'Waits',    N'Lock share of all query waits',      N'%',    -1,  B.lock_ms * 100.0 / NULLIF(B.all_ms, 0), A.lock_ms * 100.0 / NULLIF(A.all_ms, 0), NULL),
        (23, N'Waits',    N'Buffer IO wait per hour',            N's/h',  -1,  B.bufio_ms / 1000.0 / NULLIF(@bh, 0), A.bufio_ms / 1000.0 / NULLIF(@ah, 0), N'PAGEIOLATCH - reading pages from disk'),
        (24, N'Waits',    N'Buffer latch wait per hour',         N's/h',  -1,  B.latch_ms / 1000.0 / NULLIF(@bh, 0), A.latch_ms / 1000.0 / NULLIF(@ah, 0), N'PAGELATCH - tempdb / hot page contention'),
        (25, N'Waits',    N'Tran log IO wait per hour',          N's/h',  -1,  B.log_ms / 1000.0 / NULLIF(@bh, 0), A.log_ms / 1000.0 / NULLIF(@ah, 0), N'WRITELOG'),
        (26, N'Waits',    N'All query waits per hour',           N's/h',  -1,  B.all_ms / 1000.0 / NULLIF(@bh, 0), A.all_ms / 1000.0 / NULLIF(@ah, 0), NULL),
        /* --- OPS.mon: concurrency --- */
        (30, N'Concurrency', N'Blocking episodes per day',       N'/day', -1,  B.blocking_episodes * 24 / NULLIF(@bh, 0), A.blocking_episodes * 24 / NULLIF(@ah, 0), N'OPS.mon 30-second sampler, waits >= 15 s'),
        (31, N'Concurrency', N'Blocked time per day',            N'min/day', -1, B.blocking_minutes * 24 / NULLIF(@bh, 0), A.blocking_minutes * 24 / NULLIF(@ah, 0), N'sum of episode durations'),
        (32, N'Concurrency', N'Longest blocking episode',        N'min',  -1,  B.blocking_longest_min, A.blocking_longest_min, NULL),
        (33, N'Concurrency', N'Most sessions blocked at once',   N'',     -1,  B.blocking_max_victims, A.blocking_max_victims, NULL),
        (34, N'Concurrency', N'Deadlocks per day',               N'/day', -1,  B.deadlocks * 24 / NULLIF(@bh, 0), A.deadlocks * 24 / NULLIF(@ah, 0), N'system_health'),
        (35, N'Concurrency', N'Long-query issues per day',       N'/day', -1,  B.longq_issues * 24 / NULLIF(@bh, 0), A.longq_issues * 24 / NULLIF(@ah, 0), N'requests > long_query_warn_minutes'),
        (36, N'Concurrency', N'Open-transaction issues per day', N'/day', -1,  B.opentran_issues * 24 / NULLIF(@bh, 0), A.opentran_issues * 24 / NULLIF(@ah, 0), N'under RCSI these also pin the version store'),
        (37, N'Concurrency', N'Server LCK_M_* wait per hour',    N's/h',  -1,  B.wait_lock / NULLIF(@bh, 0), A.wait_lock / NULLIF(@ah, 0), N'sys.dm_os_wait_stats, whole instance'),
        (38, N'Concurrency', N'Server PAGELATCH wait per hour',  N's/h',  -1,  B.wait_pagelatch / NULLIF(@bh, 0), A.wait_pagelatch / NULLIF(@ah, 0), N'tempdb allocation contention'),
        (39, N'Concurrency', N'Server WRITELOG wait per hour',   N's/h',  -1,  B.wait_writelog / NULLIF(@bh, 0), A.wait_writelog / NULLIF(@ah, 0), NULL),
        /* --- OPS.mon: resources --- */
        (40, N'Resources', N'SQL CPU average',                   N'%',    -1,  B.cpu_avg, A.cpu_avg, NULL),
        (41, N'Resources', N'SQL CPU p95',                       N'%',    -1,  B.cpu_p95, A.cpu_p95, NULL),
        (42, N'Resources', N'Batch requests per second',         N'/s',    0,  B.batch_per_s, A.batch_per_s, N'load level - compare like with like'),
        (43, N'Resources', N'Page life expectancy (avg)',        N's',    +1,  B.ple_avg, A.ple_avg, NULL),
        (44, N'Resources', N'Memory grants pending (max)',       N'',     -1,  B.grants_pending_max, A.grants_pending_max, NULL),
        (45, N'Resources', N'Data file read latency',            N'ms',   -1,  B.io_data_read_ms, A.io_data_read_ms, N'selected databases'),
        (46, N'Resources', N'Data file write latency',           N'ms',   -1,  B.io_data_write_ms, A.io_data_write_ms, NULL),
        /* --- OPS.mon: tempdb --- */
        (50, N'tempdb',   N'tempdb used p95',                    N'MB',   -1,  B.tempdb_used_p95, A.tempdb_used_p95, NULL),
        (51, N'tempdb',   N'tempdb used max',                    N'MB',   -1,  B.tempdb_used_max, A.tempdb_used_max, NULL),
        (52, N'tempdb',   N'Version store avg',                  N'MB',   -1,  B.vs_avg, A.vs_avg, N'expected to grow: this is the price of RCSI'),
        (53, N'tempdb',   N'Version store p95',                  N'MB',   -1,  B.vs_p95, A.vs_p95, NULL),
        (54, N'tempdb',   N'Version store max',                  N'MB',   -1,  B.vs_max, A.vs_max, NULL),
        (55, N'tempdb',   N'Longest versioning transaction',     N'min',  -1,  B.vs_tran_max_min, A.vs_tran_max_min, N'keeps every newer version alive'),
        (56, N'tempdb',   N'tempdb allocated size (max)',        N'MB',   -1,  B.tempdb_size_max, A.tempdb_size_max, NULL),
        (57, N'tempdb',   N'tempdb autogrowth events',           N'',     -1,  B.tempdb_growths, A.tempdb_growths, NULL),
        (58, N'tempdb',   N'tempdb write latency',               N'ms',   -1,  B.io_tempdb_write_ms, A.io_tempdb_write_ms, NULL),
        (59, N'tempdb',   N'tempdb read latency',                N'ms',   -1,  B.io_tempdb_read_ms, A.io_tempdb_read_ms, NULL)
    ) AS x(seq, grp, metric, unit, direction, b, a, note)
)
INSERT #Score(seq, grp, metric, unit, direction, before_v, after_v, pct, verdict, note)
SELECT V.seq, V.grp, V.metric, V.unit, V.direction, V.b, V.a,
       CASE WHEN V.b IS NULL OR V.a IS NULL THEN NULL WHEN V.b = 0 AND V.a = 0 THEN 0 WHEN V.b = 0 THEN NULL ELSE (V.a - V.b) * 100.0 / V.b END,
       CASE WHEN V.b IS NULL OR V.a IS NULL THEN N'n/a'
            WHEN V.direction = 0 THEN N'info'
            WHEN V.b = 0 AND V.a = 0 THEN N'same'
            WHEN V.b = 0 THEN CASE WHEN V.direction = -1 THEN N'worse' ELSE N'better' END
            WHEN ABS((V.a - V.b) * 100.0 / V.b) < 10 THEN N'same'
            WHEN (V.a - V.b) * V.direction > 0 THEN N'better' ELSE N'worse' END,
       V.note
FROM V
WHERE NOT (V.b IS NULL AND V.a IS NULL);

/* per-query comparison */
CREATE TABLE #QCmp (database_name sysname, query_hash binary(8), query_id bigint, object_name nvarchar(300), sql_text nvarchar(400),
                    b_execs bigint, a_execs bigint, b_avg_ms decimal(19,1), a_avg_ms decimal(19,1), b_cpu_ms decimal(19,1), a_cpu_ms decimal(19,1),
                    b_reads decimal(19,1), a_reads decimal(19,1), b_lock_ms decimal(19,2), a_lock_ms decimal(19,2),
                    delta_ms decimal(19,1), delta_pct decimal(9,1), impact_s_per_h decimal(19,1), plans_b int, plans_a int);
INSERT #QCmp
SELECT b.database_name, b.query_hash, a.query_id, ISNULL(a.object_name, b.object_name), ISNULL(a.sql_text, b.sql_text),
       b.execs, a.execs, b.dur_ms / NULLIF(b.execs, 0), a.dur_ms / NULLIF(a.execs, 0), b.cpu_ms / NULLIF(b.execs, 0), a.cpu_ms / NULLIF(a.execs, 0),
       b.reads * 1.0 / NULLIF(b.execs, 0), a.reads * 1.0 / NULLIF(a.execs, 0), b.lock_wait_ms * 1.0 / NULLIF(b.execs, 0), a.lock_wait_ms * 1.0 / NULLIF(a.execs, 0),
       a.dur_ms / NULLIF(a.execs, 0) - b.dur_ms / NULLIF(b.execs, 0),
       (a.dur_ms / NULLIF(a.execs, 0) - b.dur_ms / NULLIF(b.execs, 0)) * 100.0 / NULLIF(b.dur_ms / NULLIF(b.execs, 0), 0),
       (a.dur_ms / NULLIF(a.execs, 0) - b.dur_ms / NULLIF(b.execs, 0)) * (a.execs / NULLIF(@ah, 0)) / 1000.0,   /* seconds of elapsed time per hour gained / lost */
       b.plans, a.plans
FROM #QsQuery AS b
JOIN #QsQuery AS a ON a.database_name = b.database_name AND a.query_hash = b.query_hash AND a.win = 'A'
WHERE b.win = 'B' AND b.execs >= @MinExecs AND a.execs >= @MinExecs
  AND (b.dur_ms / NULLIF(b.execs, 0) >= @MinAvgMs OR a.dur_ms / NULLIF(a.execs, 0) >= @MinAvgMs);

/* ============================ RESULT SETS (SSMS) ============================ */
SELECT N'RCSI impact report' AS [Report], @ServerLabel AS [Server], @cut_local AS [Cutover (local)], @cut_src AS [Cutover source],
       CONVERT(datetime2(0), (@b0 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS [Before from], CONVERT(datetime2(0), (@b1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS [Before to], @bh AS [Before hours],
       CONVERT(datetime2(0), (@a0 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS [After from],  CONVERT(datetime2(0), (@a1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS [After to],  @ah AS [After hours],
       (SELECT STRING_AGG(database_name, N', ') FROM #Db) AS [Databases], @has_mon AS [OPS.mon present];

SELECT grp AS [Area], metric AS [Metric], unit AS [Unit], CONVERT(decimal(19,2), before_v) AS [Before], CONVERT(decimal(19,2), after_v) AS [After],
       pct AS [Change %], verdict AS [Verdict], note AS [Note]
FROM #Score ORDER BY seq;

SELECT d.database_name AS [Database], d.is_rcsi_on AS [RCSI], d.si_state AS [Snapshot isolation], d.qs_actual AS [Query Store], d.qs_capture AS [Capture],
       d.qs_interval_min AS [Interval min], CONVERT(datetime2(0), (d.qs_oldest_utc AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS [QS history from (local)],
       b.execs / NULLIF(@bh, 0) AS [Execs/h before], a.execs / NULLIF(@ah, 0) AS [Execs/h after],
       CONVERT(decimal(19,2), b.dur_ms / NULLIF(b.execs, 0)) AS [Avg ms before], CONVERT(decimal(19,2), a.dur_ms / NULLIF(a.execs, 0)) AS [Avg ms after],
       CONVERT(decimal(19,2), b.cpu_ms / NULLIF(b.execs, 0)) AS [CPU ms before], CONVERT(decimal(19,2), a.cpu_ms / NULLIF(a.execs, 0)) AS [CPU ms after],
       CONVERT(decimal(19,1), b.reads * 1.0 / NULLIF(b.execs, 0)) AS [Reads before], CONVERT(decimal(19,1), a.reads * 1.0 / NULLIF(a.execs, 0)) AS [Reads after],
       CONVERT(decimal(19,2), wb.lock_ms * 1.0 / NULLIF(b.execs, 0)) AS [Lock ms/exec before], CONVERT(decimal(19,2), wa.lock_ms * 1.0 / NULLIF(a.execs, 0)) AS [Lock ms/exec after],
       b.queries AS [Queries before], a.queries AS [Queries after], d.note AS [Note]
FROM #Db AS d
LEFT JOIN #QsKpi AS b ON b.database_name = d.database_name AND b.win = 'B'
LEFT JOIN #QsKpi AS a ON a.database_name = d.database_name AND a.win = 'A'
LEFT JOIN (SELECT database_name, SUM(wait_ms) AS lock_ms FROM #QsWait WHERE win = 'B' AND wait_category = N'Lock' GROUP BY database_name) AS wb ON wb.database_name = d.database_name
LEFT JOIN (SELECT database_name, SUM(wait_ms) AS lock_ms FROM #QsWait WHERE win = 'A' AND wait_category = N'Lock' GROUP BY database_name) AS wa ON wa.database_name = d.database_name
ORDER BY d.database_name;

SELECT ISNULL(b.wait_category, a.wait_category) AS [Wait category],
       CONVERT(decimal(19,1), ISNULL(b.ms, 0) / 1000.0 / NULLIF(@bh, 0)) AS [Before s/h], CONVERT(decimal(19,1), ISNULL(a.ms, 0) / 1000.0 / NULLIF(@ah, 0)) AS [After s/h],
       CONVERT(decimal(9,1), (ISNULL(a.ms, 0) / NULLIF(@ah, 0) - ISNULL(b.ms, 0) / NULLIF(@bh, 0)) * 100.0 / NULLIF(ISNULL(b.ms, 0) / NULLIF(@bh, 0), 0)) AS [Change %],
       CONVERT(decimal(9,1), ISNULL(b.ms, 0) * 100.0 / NULLIF((SELECT SUM(wait_ms) FROM #QsWait WHERE win = 'B'), 0)) AS [Share before %],
       CONVERT(decimal(9,1), ISNULL(a.ms, 0) * 100.0 / NULLIF((SELECT SUM(wait_ms) FROM #QsWait WHERE win = 'A'), 0)) AS [Share after %]
FROM (SELECT wait_category, SUM(wait_ms) AS ms FROM #QsWait WHERE win = 'B' GROUP BY wait_category) AS b
FULL JOIN (SELECT wait_category, SUM(wait_ms) AS ms FROM #QsWait WHERE win = 'A' GROUP BY wait_category) AS a ON a.wait_category = b.wait_category
ORDER BY ISNULL(b.ms, 0) + ISNULL(a.ms, 0) DESC;

SELECT TOP (@TopN) N'REGRESSED' AS [Set], database_name AS [Database], object_name AS [Object], query_id AS [query_id], query_hash AS [query_hash],
       b_execs AS [Execs before], a_execs AS [Execs after], b_avg_ms AS [Avg ms before], a_avg_ms AS [Avg ms after], delta_pct AS [Change %],
       impact_s_per_h AS [Impact s/h], b_cpu_ms AS [CPU before], a_cpu_ms AS [CPU after], b_reads AS [Reads before], a_reads AS [Reads after],
       b_lock_ms AS [Lock ms before], a_lock_ms AS [Lock ms after], plans_b AS [Plans before], plans_a AS [Plans after], sql_text AS [Statement]
FROM #QCmp WHERE delta_ms > 0 ORDER BY impact_s_per_h DESC;

SELECT TOP (@TopN) N'IMPROVED' AS [Set], database_name AS [Database], object_name AS [Object], query_id AS [query_id], query_hash AS [query_hash],
       b_execs AS [Execs before], a_execs AS [Execs after], b_avg_ms AS [Avg ms before], a_avg_ms AS [Avg ms after], delta_pct AS [Change %],
       impact_s_per_h AS [Impact s/h], b_cpu_ms AS [CPU before], a_cpu_ms AS [CPU after], b_reads AS [Reads before], a_reads AS [Reads after],
       b_lock_ms AS [Lock ms before], a_lock_ms AS [Lock ms after], plans_b AS [Plans before], plans_a AS [Plans after], sql_text AS [Statement]
FROM #QCmp WHERE delta_ms < 0 ORDER BY impact_s_per_h ASC;

SELECT TOP (@TopN) N'LOCK WAITS BEFORE' AS [Set], database_name AS [Database], object_name AS [Object], query_id AS [query_id],
       b_execs AS [Execs before], a_execs AS [Execs after], b_lock_ms AS [Lock ms/exec before], a_lock_ms AS [Lock ms/exec after],
       b_avg_ms AS [Avg ms before], a_avg_ms AS [Avg ms after], delta_pct AS [Change %], sql_text AS [Statement]
FROM #QCmp WHERE b_lock_ms > 0 ORDER BY b_lock_ms * b_execs DESC;

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
td.n{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
td.g{background:#F9FAFB;font-weight:700;color:#374151}
.pill{display:inline-block;padding:1px 7px;border-radius:9px;font-size:10px;font-weight:700;letter-spacing:.3px;white-space:nowrap}
.better{background:#16A34A;color:#FFFFFF}.worse{background:#DC2626;color:#FFFFFF}.same{background:#E5E7EB;color:#374151}.info{background:#2563EB;color:#FFFFFF}.na{background:#F3F4F6;color:#9CA3AF}
.v{font-size:22px;line-height:26px;font-weight:700}
.l{font-size:10px;line-height:13px;text-transform:uppercase;letter-spacing:.5px;color:#374151;font-weight:600}
.s{font-size:10px;color:#6B7280}
table.b{border-collapse:collapse;width:100%}
table.t table.b td{padding:0;border:0;vertical-align:middle}
table.t table.b td.f{height:10px;line-height:10px;font-size:1px}
table.t table.b td.x{font-size:11px;color:#374151;padding-left:6px;white-space:nowrap}
code{font-family:Consolas,Menlo,monospace;font-size:11px;color:#374151;white-space:pre-wrap;word-break:break-word}
.foot{padding:16px 24px 22px 24px;border-top:1px solid #E5E7EB;font-size:11px;line-height:16px;color:#6B7280}
.cut{padding:8px 24px 0 24px;font-size:12px;color:#374151}
</style>';

DECLARE @h nvarchar(max) = N'', @kpi nvarchar(max) = N'', @rows nvarchar(max);
DECLARE @dbs nvarchar(max) = (SELECT STRING_AGG(database_name, N', ') WITHIN GROUP (ORDER BY database_name) FROM #Db);
DECLARE @n_better int = (SELECT COUNT(*) FROM #Score WHERE verdict = N'better'), @n_worse int = (SELECT COUNT(*) FROM #Score WHERE verdict = N'worse'),
        @n_same int = (SELECT COUNT(*) FROM #Score WHERE verdict = N'same');

/* --- KPI tiles: six headline metrics --- */
SELECT @kpi = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<td align="center" valign="top" width="16%" bgcolor="', CASE s.verdict WHEN N'better' THEN N'#F0FDF4' WHEN N'worse' THEN N'#FEF2F2' ELSE N'#F9FAFB' END,
    N'" style="padding:10px 6px;border:1px solid #FFFFFF;background:', CASE s.verdict WHEN N'better' THEN N'#F0FDF4' WHEN N'worse' THEN N'#FEF2F2' ELSE N'#F9FAFB' END, N'">',
    N'<div class="v" style="color:', CASE s.verdict WHEN N'better' THEN N'#15803D' WHEN N'worse' THEN N'#B91C1C' ELSE N'#111827' END, N'">', CASE WHEN s.after_v IS NULL THEN N'-' ELSE FORMAT(s.after_v, CASE WHEN ABS(s.after_v) >= 100 THEN 'N0' ELSE 'N1' END) END, N' ', s.unit, N'</div>',
    N'<div class="l">', s.metric, N'</div>',
    N'<div class="s">before ', CASE WHEN s.before_v IS NULL THEN N'-' ELSE FORMAT(s.before_v, CASE WHEN ABS(s.before_v) >= 100 THEN 'N0' ELSE 'N1' END) END,
    CASE WHEN s.pct IS NOT NULL THEN CONCAT(N' &middot; ', CASE WHEN s.pct > 0 THEN N'+' ELSE N'' END, FORMAT(s.pct, 'N0'), N'%') ELSE N'' END, N'</div></td>')), N'')
    WITHIN GROUP (ORDER BY s.seq)
FROM #Score AS s WHERE s.seq IN (11, 20, 30, 34, 53, 40);

/* --- scorecard --- */
SELECT @rows = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr>', CASE WHEN s.seq = g.first_seq THEN CONCAT(N'<td class="g" rowspan="', g.n, N'">', s.grp, N'</td>') ELSE N'' END,
    N'<td>', s.metric, CASE WHEN s.note IS NOT NULL THEN CONCAT(N'<br><span style="color:#6B7280;font-size:11px">', s.note, N'</span>') ELSE N'' END, N'</td>',
    N'<td class="n">', CASE WHEN s.before_v IS NULL THEN N'-' ELSE FORMAT(s.before_v, CASE WHEN ABS(s.before_v) >= 100 THEN 'N0' WHEN ABS(s.before_v) >= 10 THEN 'N1' ELSE 'N2' END) END, N' ', s.unit, N'</td>',
    N'<td class="n"><b>', CASE WHEN s.after_v IS NULL THEN N'-' ELSE FORMAT(s.after_v, CASE WHEN ABS(s.after_v) >= 100 THEN 'N0' WHEN ABS(s.after_v) >= 10 THEN 'N1' ELSE 'N2' END) END, N' ', s.unit, N'</b></td>',
    N'<td class="n">', CASE WHEN s.pct IS NULL THEN N'-' ELSE CONCAT(CASE WHEN s.pct > 0 THEN N'+' ELSE N'' END, FORMAT(s.pct, 'N0'), N'%') END, N'</td>',
    N'<td><span class="pill ', REPLACE(s.verdict, N'/', N''), N'">', UPPER(s.verdict), N'</span></td></tr>')), N'')
    WITHIN GROUP (ORDER BY s.seq)
FROM #Score AS s
JOIN (SELECT grp, MIN(seq) AS first_seq, COUNT(*) AS n FROM #Score GROUP BY grp) AS g ON g.grp = s.grp;

SET @h = CONCAT(@h,
    N'<div class="cut">Cutover <b>', CONVERT(nvarchar(16), @cut_local, 120), N' ', @TzLabel, N'</b> (', @cut_src, N') &middot; ',
    N'BEFORE = ', FORMAT(@bh / 24.0, 'N1'), N' days (', CONVERT(nvarchar(16), CONVERT(datetime2(0), (@b0 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120), N' - ',
    CONVERT(nvarchar(16), CONVERT(datetime2(0), (@b1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120), N') &middot; ',
    N'AFTER = ', FORMAT(@ah / 24.0, 'N1'), N' days (', CONVERT(nvarchar(16), CONVERT(datetime2(0), (@a0 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120), N' - ',
    CONVERT(nvarchar(16), CONVERT(datetime2(0), (@a1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120), N', first ', @SkipHours, N' h after the switch excluded) &middot; ',
    N'Databases: <b>', @dbs, N'</b></div>',
    N'<div style="padding:14px 24px 0 24px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;table-layout:fixed"><tr>', @kpi, N'</tr></table></div>',
    N'<div class="sec"><h2>Scorecard</h2><div class="d">', @n_better, N' better &middot; ', @n_worse, N' worse &middot; ', @n_same, N' unchanged (&lt; 10 %). ',
    N'Rates are per hour / per day so windows of different length compare fairly. Query Store = the selected databases'' own queries; OPS.mon = instance-wide history.</div>',
    N'<table class="t"><tr><th>Area</th><th>Metric</th><th>Before</th><th>After</th><th>Change</th><th>Verdict</th></tr>', @rows, N'</table></div>');

/* --- wait categories --- */
DECLARE @wmax decimal(19,3) = (SELECT MAX(v) FROM (SELECT SUM(wait_ms) / 1000.0 / NULLIF(@bh, 0) AS v FROM #QsWait WHERE win = 'B' GROUP BY wait_category
                                                   UNION ALL SELECT SUM(wait_ms) / 1000.0 / NULLIF(@ah, 0) FROM #QsWait WHERE win = 'A' GROUP BY wait_category) AS x);
SELECT @rows = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td>', x.wait_category, N'</td>',
    N'<td width="28%">', mon_bar.b, N'</td>',
    N'<td width="28%">', mon_bar.a, N'</td>',
    N'<td class="n">', CASE WHEN x.b = 0 THEN N'-' ELSE CONCAT(CASE WHEN x.a > x.b THEN N'+' ELSE N'' END, FORMAT((x.a - x.b) * 100.0 / x.b, 'N0'), N'%') END, N'</td>',
    N'<td><span class="pill ', CASE WHEN x.b = 0 AND x.a = 0 THEN N'same' WHEN x.b = 0 THEN N'worse' WHEN ABS(x.a - x.b) * 100.0 / x.b < 10 THEN N'same' WHEN x.a < x.b THEN N'better' ELSE N'worse' END, N'">',
    CASE WHEN x.b = 0 AND x.a = 0 THEN N'SAME' WHEN x.b = 0 THEN N'NEW' WHEN ABS(x.a - x.b) * 100.0 / x.b < 10 THEN N'SAME' WHEN x.a < x.b THEN N'BETTER' ELSE N'WORSE' END, N'</span></td></tr>')), N'')
    WITHIN GROUP (ORDER BY x.b + x.a DESC)
FROM (SELECT ISNULL(b.wait_category, a.wait_category) AS wait_category, ISNULL(b.v, 0) AS b, ISNULL(a.v, 0) AS a
      FROM (SELECT wait_category, SUM(wait_ms) / 1000.0 / NULLIF(@bh, 0) AS v FROM #QsWait WHERE win = 'B' GROUP BY wait_category) AS b
      FULL JOIN (SELECT wait_category, SUM(wait_ms) / 1000.0 / NULLIF(@ah, 0) AS v FROM #QsWait WHERE win = 'A' GROUP BY wait_category) AS a ON a.wait_category = b.wait_category) AS x
CROSS APPLY (SELECT CASE WHEN x.b <= 0 THEN 1 WHEN x.b >= @wmax THEN 100 ELSE CONVERT(int, 100 * x.b / NULLIF(@wmax, 0)) + 1 END AS pb,
                    CASE WHEN x.a <= 0 THEN 1 WHEN x.a >= @wmax THEN 100 ELSE CONVERT(int, 100 * x.a / NULLIF(@wmax, 0)) + 1 END AS pa) AS pc
CROSS APPLY (SELECT CONCAT(N'<table role="presentation" class="b" cellpadding="0" cellspacing="0" border="0"><tr><td class="f" width="', pc.pb, N'%" bgcolor="#2563EB" style="background:#2563EB">&nbsp;</td><td class="x" width="', 100 - pc.pb, N'%">', FORMAT(x.b, 'N1'), N' s/h</td></tr></table>') AS b,
                    CONCAT(N'<table role="presentation" class="b" cellpadding="0" cellspacing="0" border="0"><tr><td class="f" width="', pc.pa, N'%" bgcolor="#F59E0B" style="background:#F59E0B">&nbsp;</td><td class="x" width="', 100 - pc.pa, N'%">', FORMAT(x.a, 'N1'), N' s/h</td></tr></table>') AS a) AS mon_bar;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Query waits by category</h2><div class="d">sys.query_store_wait_stats of the selected databases, seconds of wait per hour of window. Blue = before, amber = after. ',
    N'<b>Lock</b> is what RCSI removes (readers no longer wait for writers); watch <b>Buffer Latch</b> (tempdb) and <b>Tran Log IO</b> for the cost side.</div>',
    N'<table class="t"><tr><th>Category</th><th>Before</th><th>After</th><th>Change</th><th></th></tr>',
    ISNULL(@rows, N'<tr><td colspan="5">No Query Store wait statistics in the windows.</td></tr>'), N'</table></div>');

/* --- daily profile: avg duration and executions per local day --- */
;WITH D AS
(
    SELECT CONVERT(date, (h.hour_utc AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) AS d, SUM(h.execs) AS execs, SUM(h.dur_ms) AS dur_ms, SUM(h.cpu_ms) AS cpu_ms
    FROM #QsHour AS h GROUP BY CONVERT(date, (h.hour_utc AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone)
), X AS
(
    SELECT D.*, D.dur_ms / NULLIF(D.execs, 0) AS avg_ms, MAX(D.dur_ms / NULLIF(D.execs, 0)) OVER () AS max_avg, MAX(D.execs) OVER () AS max_execs,
           CASE WHEN D.d >= CONVERT(date, @cut_local) THEN 1 ELSE 0 END AS is_after
    FROM D
)
SELECT @rows = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td>', CONVERT(nvarchar(10), X.d, 120), CASE WHEN X.d = CONVERT(date, @cut_local) THEN N' <span class="pill info">CUTOVER</span>' ELSE N'' END, N'</td>',
    N'<td width="30%"><table role="presentation" class="b" cellpadding="0" cellspacing="0" border="0"><tr><td class="f" width="', pc.p1, N'%" bgcolor="', pc.c, N'" style="background:', pc.c, N'">&nbsp;</td><td class="x" width="', 100 - pc.p1, N'%">', FORMAT(X.avg_ms, 'N1'), N' ms</td></tr></table></td>',
    N'<td width="24%"><table role="presentation" class="b" cellpadding="0" cellspacing="0" border="0"><tr><td class="f" width="', pc.p2, N'%" bgcolor="', pc.c2, N'" style="background:', pc.c2, N'">&nbsp;</td><td class="x" width="', 100 - pc.p2, N'%">', FORMAT(X.execs, 'N0'), N'</td></tr></table></td>',
    N'<td class="n">', FORMAT(X.cpu_ms / NULLIF(X.execs, 0), 'N1'), N' ms</td>',
    N'<td class="n">', FORMAT(X.dur_ms / 1000.0 / 3600.0, 'N2'), N' h</td></tr>')), N'')
    WITHIN GROUP (ORDER BY X.d)
FROM X
CROSS APPLY (SELECT CASE WHEN X.avg_ms >= X.max_avg THEN 100 ELSE CONVERT(int, 100 * X.avg_ms / NULLIF(X.max_avg, 0)) + 1 END AS p1,
                    CASE WHEN X.execs >= X.max_execs THEN 100 ELSE CONVERT(int, 100 * X.execs / NULLIF(X.max_execs, 0)) + 1 END AS p2,
                    CASE WHEN X.is_after = 1 THEN N'#F59E0B' ELSE N'#2563EB' END AS c,
                    CASE WHEN X.is_after = 1 THEN N'#FCD34D' ELSE N'#93C5FD' END AS c2) AS pc;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Day by day</h2><div class="d">Average elapsed time per execution, executions, CPU per execution and total query time per local day (Query Store, both windows). Blue = before the cutover, amber = after.</div>',
    N'<table class="t"><tr><th>Day</th><th>Avg duration</th><th>Executions</th><th>CPU / exec</th><th>Total query time</th></tr>',
    ISNULL(@rows, N'<tr><td colspan="5">No Query Store data.</td></tr>'), N'</table></div>');

/* --- top regressed / improved --- */
DECLARE @qrows nvarchar(max);
SELECT @qrows = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td>', q.database_name, CASE WHEN q.object_name IS NOT NULL THEN CONCAT(N'<br><span style="color:#6B7280;font-size:11px">', q.object_name, N'</span>') ELSE N'' END, N'</td>',
    N'<td><code>', LEFT(REPLACE(REPLACE(REPLACE(q.sql_text, N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), 220), CASE WHEN LEN(q.sql_text) > 220 THEN N'&#8230;' ELSE N'' END, N'</code>',
    N'<br><span style="color:#9CA3AF;font-size:11px">query_id ', q.query_id, N' &middot; plans ', q.plans_b, N' &rarr; ', q.plans_a, N'</span></td>',
    N'<td class="n">', FORMAT(q.b_execs / NULLIF(@bh, 0), 'N0'), N' &rarr; ', FORMAT(q.a_execs / NULLIF(@ah, 0), 'N0'), N'</td>',
    N'<td class="n">', FORMAT(q.b_avg_ms, 'N1'), N' &rarr; <b>', FORMAT(q.a_avg_ms, 'N1'), N'</b></td>',
    N'<td class="n"><span class="pill ', CASE WHEN q.delta_pct > 0 THEN N'worse' ELSE N'better' END, N'">', CASE WHEN q.delta_pct > 0 THEN N'+' ELSE N'' END, FORMAT(q.delta_pct, 'N0'), N'%</span></td>',
    N'<td class="n">', FORMAT(q.b_lock_ms, 'N1'), N' &rarr; ', FORMAT(q.a_lock_ms, 'N1'), N'</td>',
    N'<td class="n">', FORMAT(q.b_cpu_ms, 'N1'), N' &rarr; ', FORMAT(q.a_cpu_ms, 'N1'), N'</td>',
    N'<td class="n">', FORMAT(q.b_reads, 'N0'), N' &rarr; ', FORMAT(q.a_reads, 'N0'), N'</td>',
    N'<td class="n">', CASE WHEN q.impact_s_per_h > 0 THEN N'+' ELSE N'' END, FORMAT(q.impact_s_per_h, 'N1'), N' s/h</td></tr>')), N'')
    WITHIN GROUP (ORDER BY q.impact_s_per_h DESC)
FROM (SELECT TOP (@TopN) * FROM #QCmp WHERE delta_ms > 0 ORDER BY impact_s_per_h DESC) AS q;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Top regressed queries</h2><div class="d">Queries with at least ', @MinExecs, N' executions in both windows, ordered by impact = (after - before avg ms) &times; executions per hour. ',
    N'Rising <b>reads</b> with flat lock wait usually means a plan change, not RCSI; rising <b>CPU</b> on UPDATE / DELETE statements is the row-versioning cost.</div>',
    N'<table class="t"><tr><th>Database / object</th><th>Statement</th><th>Execs/h</th><th>Avg ms</th><th>Change</th><th>Lock ms/exec</th><th>CPU ms</th><th>Reads</th><th>Impact</th></tr>',
    ISNULL(@qrows, N'<tr><td colspan="9" style="background:#F0FDF4;color:#166534">&#10003; No query got slower (with the minimum-executions filter).</td></tr>'), N'</table></div>');

SELECT @qrows = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td>', q.database_name, CASE WHEN q.object_name IS NOT NULL THEN CONCAT(N'<br><span style="color:#6B7280;font-size:11px">', q.object_name, N'</span>') ELSE N'' END, N'</td>',
    N'<td><code>', LEFT(REPLACE(REPLACE(REPLACE(q.sql_text, N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), 220), CASE WHEN LEN(q.sql_text) > 220 THEN N'&#8230;' ELSE N'' END, N'</code>',
    N'<br><span style="color:#9CA3AF;font-size:11px">query_id ', q.query_id, N' &middot; plans ', q.plans_b, N' &rarr; ', q.plans_a, N'</span></td>',
    N'<td class="n">', FORMAT(q.b_execs / NULLIF(@bh, 0), 'N0'), N' &rarr; ', FORMAT(q.a_execs / NULLIF(@ah, 0), 'N0'), N'</td>',
    N'<td class="n">', FORMAT(q.b_avg_ms, 'N1'), N' &rarr; <b>', FORMAT(q.a_avg_ms, 'N1'), N'</b></td>',
    N'<td class="n"><span class="pill better">', FORMAT(q.delta_pct, 'N0'), N'%</span></td>',
    N'<td class="n">', FORMAT(q.b_lock_ms, 'N1'), N' &rarr; ', FORMAT(q.a_lock_ms, 'N1'), N'</td>',
    N'<td class="n">', FORMAT(q.b_cpu_ms, 'N1'), N' &rarr; ', FORMAT(q.a_cpu_ms, 'N1'), N'</td>',
    N'<td class="n">', FORMAT(q.b_reads, 'N0'), N' &rarr; ', FORMAT(q.a_reads, 'N0'), N'</td>',
    N'<td class="n">', FORMAT(q.impact_s_per_h, 'N1'), N' s/h</td></tr>')), N'')
    WITHIN GROUP (ORDER BY q.impact_s_per_h ASC)
FROM (SELECT TOP (@TopN) * FROM #QCmp WHERE delta_ms < 0 ORDER BY impact_s_per_h ASC) AS q;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Top improved queries</h2><div class="d">Same filter, ordered by time saved per hour. A drop in <b>lock ms/exec</b> alongside the drop in duration is the RCSI effect; a drop with unchanged lock wait is something else (plan, data, load).</div>',
    N'<table class="t"><tr><th>Database / object</th><th>Statement</th><th>Execs/h</th><th>Avg ms</th><th>Change</th><th>Lock ms/exec</th><th>CPU ms</th><th>Reads</th><th>Saved</th></tr>',
    ISNULL(@qrows, N'<tr><td colspan="9">No query got faster (with the minimum-executions filter).</td></tr>'), N'</table></div>');

/* --- queries that waited on locks before: did the wait go away? --- */
SELECT @qrows = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td>', q.database_name, CASE WHEN q.object_name IS NOT NULL THEN CONCAT(N'<br><span style="color:#6B7280;font-size:11px">', q.object_name, N'</span>') ELSE N'' END, N'</td>',
    N'<td><code>', LEFT(REPLACE(REPLACE(REPLACE(q.sql_text, N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), 200), CASE WHEN LEN(q.sql_text) > 200 THEN N'&#8230;' ELSE N'' END, N'</code></td>',
    N'<td class="n">', FORMAT(q.b_lock_ms, 'N1'), N' &rarr; <b>', FORMAT(q.a_lock_ms, 'N1'), N'</b></td>',
    N'<td class="n">', FORMAT(q.b_lock_ms * q.b_execs / 1000.0 / NULLIF(@bh, 0), 'N1'), N' &rarr; ', FORMAT(q.a_lock_ms * q.a_execs / 1000.0 / NULLIF(@ah, 0), 'N1'), N' s/h</td>',
    N'<td class="n">', FORMAT(q.b_avg_ms, 'N1'), N' &rarr; ', FORMAT(q.a_avg_ms, 'N1'), N'</td>',
    N'<td><span class="pill ', CASE WHEN q.a_lock_ms <= q.b_lock_ms * 0.5 THEN N'better' WHEN q.a_lock_ms > q.b_lock_ms * 1.1 THEN N'worse' ELSE N'same' END, N'">',
    CASE WHEN q.b_lock_ms = 0 THEN N'-' ELSE CONCAT(FORMAT((q.a_lock_ms - q.b_lock_ms) * 100.0 / q.b_lock_ms, 'N0'), N'%') END, N'</span></td></tr>')), N'')
    WITHIN GROUP (ORDER BY q.b_lock_ms * q.b_execs DESC)
FROM (SELECT TOP (@TopN) * FROM #QCmp WHERE b_lock_ms > 0 ORDER BY b_lock_ms * b_execs DESC) AS q;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Queries that waited on locks before the cutover</h2><div class="d">The direct test of RCSI: lock wait per execution before &rarr; after for the queries that used to wait the most. SELECTs should drop to ~0; writers (UPDATE / DELETE) still wait for each other.</div>',
    N'<table class="t"><tr><th>Database / object</th><th>Statement</th><th>Lock ms/exec</th><th>Lock wait total</th><th>Avg ms</th><th>Lock wait change</th></tr>',
    ISNULL(@qrows, N'<tr><td colspan="6">No query had lock waits in the BEFORE window.</td></tr>'), N'</table></div>');

/* --- per database --- */
SELECT @rows = STRING_AGG(CONVERT(nvarchar(max), CONCAT(
    N'<tr><td><b>', d.database_name, N'</b><br><span style="color:#6B7280;font-size:11px">RCSI ', CASE WHEN d.is_rcsi_on = 1 THEN N'ON' ELSE N'OFF' END, N' &middot; SI ', ISNULL(d.si_state, N'?'),
    N' &middot; QS ', ISNULL(d.qs_actual, N'?'), N' / ', ISNULL(d.qs_capture, N'?'), N' / ', ISNULL(CONVERT(nvarchar(10), d.qs_interval_min), N'?'), N' min</span></td>',
    N'<td class="n">', FORMAT(b.execs / NULLIF(@bh, 0), 'N0'), N' &rarr; ', FORMAT(a.execs / NULLIF(@ah, 0), 'N0'), N'</td>',
    N'<td class="n">', FORMAT(b.dur_ms / NULLIF(b.execs, 0), 'N1'), N' &rarr; <b>', FORMAT(a.dur_ms / NULLIF(a.execs, 0), 'N1'), N'</b></td>',
    N'<td class="n">', FORMAT(b.cpu_ms / NULLIF(b.execs, 0), 'N1'), N' &rarr; ', FORMAT(a.cpu_ms / NULLIF(a.execs, 0), 'N1'), N'</td>',
    N'<td class="n">', FORMAT(b.reads * 1.0 / NULLIF(b.execs, 0), 'N0'), N' &rarr; ', FORMAT(a.reads * 1.0 / NULLIF(a.execs, 0), 'N0'), N'</td>',
    N'<td class="n">', FORMAT(ISNULL(wb.lock_ms, 0) * 1.0 / NULLIF(b.execs, 0), 'N2'), N' &rarr; <b>', FORMAT(ISNULL(wa.lock_ms, 0) * 1.0 / NULLIF(a.execs, 0), 'N2'), N'</b></td>',
    N'<td class="n">', FORMAT(b.tempdb_pages / 128.0 / NULLIF(b.execs, 0), 'N2'), N' &rarr; ', FORMAT(a.tempdb_pages / 128.0 / NULLIF(a.execs, 0), 'N2'), N'</td>',
    N'<td>', ISNULL(d.note, N''), N'</td></tr>')), N'')
    WITHIN GROUP (ORDER BY d.database_name)
FROM #Db AS d
LEFT JOIN #QsKpi AS b ON b.database_name = d.database_name AND b.win = 'B'
LEFT JOIN #QsKpi AS a ON a.database_name = d.database_name AND a.win = 'A'
LEFT JOIN (SELECT database_name, SUM(wait_ms) AS lock_ms FROM #QsWait WHERE win = 'B' AND wait_category = N'Lock' GROUP BY database_name) AS wb ON wb.database_name = d.database_name
LEFT JOIN (SELECT database_name, SUM(wait_ms) AS lock_ms FROM #QsWait WHERE win = 'A' AND wait_category = N'Lock' GROUP BY database_name) AS wa ON wa.database_name = d.database_name;
SET @h = CONCAT(@h, N'<div class="sec"><h2>Per database</h2><div class="d">before &rarr; after, per execution unless stated.</div>',
    N'<table class="t"><tr><th>Database</th><th>Execs/h</th><th>Avg ms</th><th>CPU ms</th><th>Reads</th><th>Lock ms</th><th>tempdb MB</th><th>Note</th></tr>', @rows, N'</table></div>');

/* --- notes --- */
DECLARE @notes_html nvarchar(max) = (SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT(N'<li>', note, N'</li>')), N'') FROM @notes);
DECLARE @foot nvarchar(max) = CONCAT(
    CASE WHEN @notes_html IS NOT NULL THEN CONCAT(N'<ul style="margin:0 0 8px 16px;padding:0">', @notes_html, N'</ul>') ELSE N'' END,
    N'<b>Method.</b> BEFORE = ', @BeforeDays, N' days up to the cutover; AFTER = everything from ', @SkipHours, N' h after the cutover to ', CASE WHEN @AfterDays IS NULL THEN N'now' ELSE CONCAT(@AfterDays, N' days') END,
    N'. Query metrics come from Query Store runtime statistics (regular executions, all plans of a query_hash merged) and sys.query_store_wait_stats; ',
    N'instance metrics (blocking, deadlocks, server waits, CPU, tempdb, version store, I/O latency) from OPS.mon 5.8 history. ',
    N'Verdict thresholds: &plusmn;10 % = unchanged. Compare like with like: if executions per hour changed a lot, the workload itself changed (release, month-end, batch) and per-execution numbers matter more than totals. ',
    N'<b>Expected RCSI signature:</b> lock waits and blocking down, version store and tempdb up, +~2-5 % CPU / writes on modified rows (14-byte version pointer), no change for queries that never waited. ',
    N'Generated ', CONVERT(nvarchar(16), CONVERT(datetime2(0), (@now AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120), N' ', @TzLabel, N' by RCSI_Impact_Report.sql', CASE WHEN @SendMail = 1 THEN CONCAT(N'; emailed to ', @Recipients) ELSE N'' END, N'.');

DECLARE @html nvarchar(max) = CONCAT(
    N'<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>RCSI impact - ', @ServerLabel, N'</title>', @css, N'</head><body>',
    N'<div class="card"><div class="banner"><div class="eyebrow">', @ServerLabel, N' &middot; READ COMMITTED SNAPSHOT</div>',
    N'<div class="title">RCSI impact: before vs after</div>',
    N'<div class="sub">', @n_better, N' metrics better &middot; ', @n_worse, N' worse &middot; ', @n_same, N' unchanged &middot; ', @dbs, N'</div></div>',
    @h, N'<div class="foot">', @foot, N'</div></div></body></html>');

/* ============================ EMAIL (Database Mail) ============================ */
DECLARE @mail_status nvarchar(1000) = N'not sent (@SendMail = 0)', @mailitem_id int = NULL, @profile sysname = @MailProfile;
IF @SendMail = 1
BEGIN
    BEGIN TRY
        /* same as OPS.mon: the profile name comes from mon.Setting (or @MailProfile) and goes straight to
           sp_send_dbmail - no read of msdb.dbo.sysmail_profile (not readable by every login on RDS) */
        IF @profile IS NULL AND OBJECT_ID(N'OPS.mon.Setting') IS NOT NULL
            SELECT @profile = NULLIF(setting_value, N'') FROM OPS.mon.Setting WHERE setting_name = 'mail_profile';

        DECLARE @s_avg nvarchar(100) = N'', @s_lock nvarchar(100) = N'';
        SELECT @s_avg = CONCAT(N' | avg ', FORMAT(before_v, 'N1'), N' -> ', FORMAT(after_v, 'N1'), N' ms') FROM #Score WHERE seq = 11 AND before_v IS NOT NULL AND after_v IS NOT NULL;
        SELECT @s_lock = CONCAT(N' | lock ', FORMAT(before_v, 'N1'), N' -> ', FORMAT(after_v, 'N1'), N' ms/exec') FROM #Score WHERE seq = 20 AND before_v IS NOT NULL AND after_v IS NOT NULL;
        DECLARE @subject nvarchar(255) = LEFT(CONCAT(N'[', @ServerLabel, N'] RCSI impact ', CONVERT(nvarchar(10), @cut_local, 120), N' -> ',
            CONVERT(nvarchar(10), CONVERT(datetime2(0), (@a1 AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone), 120),
            N' | ', @n_better, N' better, ', @n_worse, N' worse, ', @n_same, N' same', @s_avg, @s_lock), 255);
        IF @profile IS NOT NULL
            EXEC msdb.dbo.sp_send_dbmail @profile_name = @profile, @recipients = @Recipients, @subject = @subject,
                 @body = @html, @body_format = 'HTML', @importance = 'Normal', @mailitem_id = @mailitem_id OUTPUT;
        ELSE   /* default Database Mail profile of the login / instance */
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
