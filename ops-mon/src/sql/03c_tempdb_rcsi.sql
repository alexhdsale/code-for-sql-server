/* =============================================================================
   SECTION 7c  -  TEMPDB USAGE / VERSION STORE / RCSI BEFORE-AFTER TRACKING   [rev 5.8]

   Why: READ COMMITTED SNAPSHOT (RCSI) moves row versions into the tempdb version
   store. This module measures tempdb before and after the switch so the effect is
   a number, not an impression.

   Every collect_interval_minutes (5 min) mon.usp_CollectTempdb stores:
     mon.TempdbSample            one row per sample: tempdb size / used / free, user objects,
                                 internal objects, version store, mixed extents, data file
                                 count + skew, tempdb log, version-store transactions (count,
                                 longest, who), sessions using tempdb, top session, RCSI / SI
                                 database counts, cumulative tempdb I/O (deltas at report time).
     mon.TempdbFileSample        per tempdb file: size, used, max size, growth setting.
     mon.TempdbVersionStoreDb    version store reserved per database (sys.dm_tran_version_store_space_usage)
                                 + active snapshot transactions per database.
     mon.TempdbVersionGenerator  top objects generating row versions (sys.dm_tran_top_version_generators,
                                 resolved to schema.table / index).
     mon.TempdbTopConsumer       top sessions by tempdb allocation (session + running tasks) with
                                 login / host / program / database / statement text.
     mon.TempdbGrowthEvent       tempdb autogrowth events from the default trace (scanned every
                                 tempdb_growth_scan_minutes).
     mon.RcsiCutover             when RCSI was switched ON / OFF per database (auto-detected; or
                                 EXEC mon.usp_SetRcsiCutover for the real date).
     mon.TempdbDaily             one row per local day (min / avg / p95 / max of the samples), kept
                                 retention_tempdb_daily_days (default 400) - the before/after and
                                 7-day baseline source. Raw samples are kept retention_tempdb_days (30).

   Checks (mon.ServerCheck, switchable):
     TEMPDB_VS      version store >= tempdb_vs_warn_pct / tempdb_vs_crit_pct of tempdb size (TEMPDBVS:SIZE),
                    a transaction has held the version store longer than vs_tran_warn_minutes /
                    vs_tran_crit_minutes (TEMPDBVS:TRAN).
     TEMPDB_GROWTH  tempdb autogrew >= tempdb_growth_warn_per_hour times in the last hour.
     RCSI           RCSI switched ON / OFF for a database (event; the cutover is recorded).

   Email: "MON - TempDB RCSI", separate from the digest (06c_tempdb_report.sql).
   ============================================================================= */
USE [OPS];
GO

INSERT mon.Setting(setting_name, setting_value, value_type, category, description)
SELECT v.n, v.v, v.t, v.c, v.d
FROM (VALUES
    ('tempdb_collect_enabled',       N'1',    'bit',  'tempdb', N'Master switch for the tempdb / version store / RCSI collector (every collect_interval_minutes).'),
    ('tempdb_top_consumers',         N'10',   'int',  'tempdb', N'Sessions stored per sample, by tempdb allocation (user + internal objects, session + running tasks).'),
    ('tempdb_top_min_mb',            N'50',   'int',  'tempdb', N'A session is stored as a top consumer only when it holds at least this many MB of tempdb.'),
    ('tempdb_top_generators',        N'10',   'int',  'tempdb', N'Objects stored per sample from sys.dm_tran_top_version_generators (row-version producers).'),
    ('tempdb_capture_sql',           N'1',    'bit',  'tempdb', N'1 = store the running statement (max 2000 chars) of every top consumer; 0 = login / host / program / database only.'),
    ('tempdb_growth_scan_minutes',   N'15',   'int',  'tempdb', N'How often the default trace is scanned for tempdb autogrowth events.'),
    ('tempdb_vs_warn_pct',           N'50',   'int',  'tempdb', N'Version store >= this % of tempdb allocated size -> WARNING (check TEMPDB_VS).'),
    ('tempdb_vs_crit_pct',           N'75',   'int',  'tempdb', N'Version store >= this % of tempdb allocated size -> CRITICAL.'),
    ('vs_tran_warn_minutes',         N'30',   'int',  'tempdb', N'A transaction holding the version store (sys.dm_tran_active_snapshot_database_transactions) longer than this -> WARNING.'),
    ('vs_tran_crit_minutes',         N'120',  'int',  'tempdb', N'... longer than this -> CRITICAL (the version store cannot be cleaned up behind it).'),
    ('tempdb_growth_warn_per_hour',  N'10',   'int',  'tempdb', N'tempdb autogrowth events in the last hour that raise a WARNING (check TEMPDB_GROWTH).'),
    ('rcsi_compare_days',            N'7',    'int',  'tempdb', N'Days before the RCSI cutover used as the "before" window in the TempDB RCSI report (after = everything since the cutover).'),
    ('tempdb_report_enabled',        N'1',    'bit',  'email',  N'1 = send the daily "MON - TempDB RCSI" email (separate from the digest).'),
    ('tempdb_report_hours_local',    N'8',    'text', 'email',  N'Local hours (comma list, 0-23) when the TempDB RCSI email is sent.'),
    ('tempdb_report_weekdays',       N'1,2,3,4,5,6,7', 'text', 'email', N'ISO weekdays for the TempDB RCSI email (1 = Monday ... 7 = Sunday).'),
    ('tempdb_report_recipients',     N'',     'text', 'email',  N'Recipients of the TempDB RCSI email. Empty = report_recipients.'),
    ('retention_tempdb_days',        N'30',   'int',  'issues', N'Days kept for raw tempdb samples (TempdbSample, TempdbFileSample, TempdbVersionStoreDb, TempdbVersionGenerator, TempdbTopConsumer).'),
    ('retention_tempdb_daily_days',  N'400',  'int',  'issues', N'Days kept for the daily tempdb aggregates (TempdbDaily) and autogrowth events.')
) AS v(n, v, t, c, d)
WHERE NOT EXISTS (SELECT 1 FROM mon.Setting AS s WHERE s.setting_name = v.n);
GO

MERGE mon.CheckCatalog AS t
USING (VALUES
    ('TEMPDB_VS',     'SERVER', CONVERT(sysname, NULL), N'TEMPDBVS:%',   N'tempdb version store',  302,
     N'Version store size vs tempdb size, and transactions holding the version store too long (RCSI / snapshot isolation).',
     N'tempdb_vs_warn_pct / tempdb_vs_crit_pct / vs_tran_warn_minutes / vs_tran_crit_minutes'),
    ('TEMPDB_GROWTH', 'SERVER', CONVERT(sysname, NULL), N'TEMPDBGROWTH', N'tempdb autogrowth',     304,
     N'tempdb data / log file autogrowth events per hour (default trace).', N'tempdb_growth_warn_per_hour'),
    ('RCSI',          'SERVER', CONVERT(sysname, NULL), N'RCSI:%',       N'RCSI switched',         306,
     N'READ COMMITTED SNAPSHOT switched ON or OFF for a database (the cutover is recorded in mon.RcsiCutover for the before/after report).', NULL)
) AS s(check_code, scope, column_name, key_pattern, display_name, sort_order, description, threshold_info)
ON t.check_code = s.check_code
WHEN MATCHED THEN UPDATE SET scope = s.scope, key_pattern = s.key_pattern, display_name = s.display_name,
     sort_order = s.sort_order, description = s.description, threshold_info = s.threshold_info
WHEN NOT MATCHED THEN INSERT (check_code, scope, column_name, key_pattern, display_name, description, threshold_info, sort_order)
     VALUES (s.check_code, s.scope, s.column_name, s.key_pattern, s.display_name, s.description, s.threshold_info, s.sort_order);

INSERT mon.ServerCheck(check_code, display_name)
SELECT c.check_code, c.display_name FROM mon.CheckCatalog AS c
WHERE c.scope = 'SERVER' AND NOT EXISTS (SELECT 1 FROM mon.ServerCheck AS s WHERE s.check_code = c.check_code);
GO

IF OBJECT_ID(N'mon.TempdbSample', N'U') IS NULL
BEGIN
    CREATE TABLE mon.TempdbSample
    (
        sample_utc              datetime2(0)  NOT NULL CONSTRAINT PK_mon_TempdbSample PRIMARY KEY,
        size_mb                 decimal(19,2) NULL,     /* allocated size of the data files */
        used_mb                 decimal(19,2) NULL,
        free_mb                 decimal(19,2) NULL,
        user_obj_mb             decimal(19,2) NULL,     /* temp tables, table variables */
        internal_obj_mb         decimal(19,2) NULL,     /* sorts, hashes, spools, cursors */
        version_store_mb        decimal(19,2) NULL,     /* row versions (RCSI / SI / triggers / MARS / online index) */
        mixed_extent_mb         decimal(19,2) NULL,
        data_file_count         int           NULL,
        data_file_min_mb        decimal(19,2) NULL,
        data_file_max_mb        decimal(19,2) NULL,
        log_size_mb             decimal(19,2) NULL,
        log_used_pct            decimal(9,2)  NULL,
        vs_db_count             int           NULL,     /* databases with version store reserved */
        vs_active_tran          int           NULL,     /* active snapshot / versioning transactions */
        vs_longest_tran_s       int           NULL,
        vs_longest_session_id   int           NULL,
        vs_longest_login        sysname       NULL,
        vs_longest_database     sysname       NULL,
        vs_longest_program      nvarchar(128) NULL,
        sessions_using_tempdb   int           NULL,     /* sessions holding >= 1 MB */
        top_session_mb          decimal(19,2) NULL,
        top_session_id          int           NULL,
        rcsi_db_count           int           NULL,
        si_db_count             int           NULL,
        io_reads                bigint        NULL,     /* cumulative since SQL start: all tempdb files */
        io_writes               bigint        NULL,
        io_bytes_read           bigint        NULL,
        io_bytes_written        bigint        NULL,
        io_stall_read_ms        bigint        NULL,
        io_stall_write_ms       bigint        NULL,
        collection_error        nvarchar(1000) NULL
    );
END;
GO

IF OBJECT_ID(N'mon.TempdbFileSample', N'U') IS NULL
BEGIN
    CREATE TABLE mon.TempdbFileSample
    (
        sample_utc    datetime2(0)  NOT NULL,
        file_id       int           NOT NULL,
        logical_name  sysname       NULL,
        type_desc     nvarchar(60)  NULL,
        size_mb       decimal(19,2) NULL,
        used_mb       decimal(19,2) NULL,
        max_size_mb   decimal(19,2) NULL,     /* -1 = unlimited */
        growth_desc   nvarchar(40)  NULL,
        CONSTRAINT PK_mon_TempdbFileSample PRIMARY KEY (sample_utc, file_id)
    );
END;
GO

IF OBJECT_ID(N'mon.TempdbVersionStoreDb', N'U') IS NULL
BEGIN
    CREATE TABLE mon.TempdbVersionStoreDb
    (
        sample_utc       datetime2(0)  NOT NULL,
        database_name    sysname       NOT NULL,
        database_id      int           NULL,
        reserved_mb      decimal(19,2) NULL,
        active_tran      int           NULL,
        longest_tran_s   int           NULL,
        is_rcsi_on       bit           NULL,
        is_si_on         bit           NULL,
        CONSTRAINT PK_mon_TempdbVersionStoreDb PRIMARY KEY (sample_utc, database_name)
    );
END;
GO

IF OBJECT_ID(N'mon.TempdbVersionGenerator', N'U') IS NULL
BEGIN
    CREATE TABLE mon.TempdbVersionGenerator
    (
        sample_utc     datetime2(0)  NOT NULL,
        database_name  sysname       NOT NULL,
        rowset_id      bigint        NOT NULL,
        object_name    nvarchar(300) NULL,
        index_name     sysname       NULL,
        version_mb     decimal(19,2) NULL,
        CONSTRAINT PK_mon_TempdbVersionGenerator PRIMARY KEY (sample_utc, database_name, rowset_id)
    );
END;
GO

IF OBJECT_ID(N'mon.TempdbTopConsumer', N'U') IS NULL
BEGIN
    CREATE TABLE mon.TempdbTopConsumer
    (
        sample_utc        datetime2(0)  NOT NULL,
        session_id        int           NOT NULL,
        login_name        sysname       NULL,
        host_name         nvarchar(128) NULL,
        program_name      nvarchar(128) NULL,
        database_name     sysname       NULL,
        status            nvarchar(30)  NULL,
        user_obj_mb       decimal(19,2) NULL,
        internal_obj_mb   decimal(19,2) NULL,
        total_mb          decimal(19,2) NULL,
        request_elapsed_s int           NULL,
        wait_type         nvarchar(60)  NULL,
        query_hash        binary(8)     NULL,
        sql_text          nvarchar(2000) NULL,
        CONSTRAINT PK_mon_TempdbTopConsumer PRIMARY KEY (sample_utc, session_id)
    );
END;
GO

IF OBJECT_ID(N'mon.TempdbGrowthEvent', N'U') IS NULL
BEGIN
    CREATE TABLE mon.TempdbGrowthEvent
    (
        event_utc     datetime2(3)  NOT NULL,
        file_name     sysname       NOT NULL,
        event_type    varchar(10)   NOT NULL,     /* DATA | LOG */
        growth_mb     decimal(19,2) NULL,
        duration_ms   int           NULL,
        CONSTRAINT PK_mon_TempdbGrowthEvent PRIMARY KEY (event_utc, file_name)
    );
END;
GO

IF OBJECT_ID(N'mon.RcsiCutover', N'U') IS NULL
BEGIN
    CREATE TABLE mon.RcsiCutover
    (
        database_name  sysname       NOT NULL CONSTRAINT PK_mon_RcsiCutover PRIMARY KEY,
        is_on          bit           NOT NULL,
        enabled_utc    datetime2(0)  NULL,          /* NULL = already ON when monitoring started: set it with usp_SetRcsiCutover */
        disabled_utc   datetime2(0)  NULL,
        change_utc     datetime2(0)  NULL,          /* last ON/OFF switch seen by the collector (raises the RCSI event) */
        source         varchar(10)   NOT NULL,      /* AUTO | MANUAL | INSTALL */
        note           nvarchar(400) NULL,
        modified_utc   datetime2(0)  NOT NULL CONSTRAINT DF_mon_RC_mod DEFAULT SYSUTCDATETIME(),
        modified_by    sysname       NOT NULL CONSTRAINT DF_mon_RC_by  DEFAULT ORIGINAL_LOGIN()
    );
END;
GO

IF OBJECT_ID(N'mon.TempdbDaily', N'U') IS NULL
BEGIN
    CREATE TABLE mon.TempdbDaily
    (
        report_date            date          NOT NULL CONSTRAINT PK_mon_TempdbDaily PRIMARY KEY,   /* local date (display_time_zone) */
        samples                int           NOT NULL,
        size_max_mb            decimal(19,2) NULL,
        used_min_mb            decimal(19,2) NULL,
        used_avg_mb            decimal(19,2) NULL,
        used_p95_mb            decimal(19,2) NULL,
        used_max_mb            decimal(19,2) NULL,
        user_obj_avg_mb        decimal(19,2) NULL,
        user_obj_max_mb        decimal(19,2) NULL,
        internal_obj_avg_mb    decimal(19,2) NULL,
        internal_obj_max_mb    decimal(19,2) NULL,
        vs_avg_mb              decimal(19,2) NULL,
        vs_p95_mb              decimal(19,2) NULL,
        vs_max_mb              decimal(19,2) NULL,
        vs_tran_max_s          int           NULL,
        vs_active_tran_max     int           NULL,
        sessions_max           int           NULL,
        top_session_max_mb     decimal(19,2) NULL,
        log_used_max_pct       decimal(9,2)  NULL,
        io_read_mb             bigint        NULL,     /* sum of per-sample deltas (restart-safe) */
        io_write_mb            bigint        NULL,
        io_read_ms_avg         decimal(9,2)  NULL,     /* stall per I/O over the day */
        io_write_ms_avg        decimal(9,2)  NULL,
        growth_events          int           NULL,
        rcsi_db_count_max      int           NULL,
        computed_utc           datetime2(0)  NOT NULL CONSTRAINT DF_mon_TD_comp DEFAULT SYSUTCDATETIME()
    );
END;
GO

/*
   Record (or correct) the real RCSI cutover of a database - the before/after report uses it.
     EXEC OPS.mon.usp_SetRcsiCutover @Database = N'MyDb', @EnabledLocal = '2026-10-20 22:00', @Note = N'change CHG-1234';
     EXEC OPS.mon.usp_SetRcsiCutover @Database = N'MyDb', @EnabledLocal = NULL;   -- unknown again
   @EnabledLocal is in display_time_zone (Eastern by default).
*/
CREATE OR ALTER PROCEDURE mon.usp_SetRcsiCutover
    @Database     sysname,
    @EnabledLocal datetime2(0) = NULL,
    @Note         nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');
    DECLARE @utc datetime2(0) = CASE WHEN @EnabledLocal IS NULL THEN NULL
                                     ELSE CONVERT(datetime2(0), (@EnabledLocal AT TIME ZONE @tz) AT TIME ZONE 'UTC') END;
    DECLARE @on bit = ISNULL((SELECT is_read_committed_snapshot_on FROM sys.databases WHERE name = @Database), 0);

    IF EXISTS (SELECT 1 FROM mon.RcsiCutover WHERE database_name = @Database)
        UPDATE mon.RcsiCutover
           SET enabled_utc = @utc, source = 'MANUAL', note = ISNULL(@Note, note), is_on = @on,
               modified_utc = SYSUTCDATETIME(), modified_by = ORIGINAL_LOGIN()
         WHERE database_name = @Database;
    ELSE
        INSERT mon.RcsiCutover(database_name, is_on, enabled_utc, source, note)
        VALUES (@Database, @on, @utc, 'MANUAL', @Note);

    SELECT database_name, is_on, mon.fn_UtcToLocal(enabled_utc, @tz) AS enabled_local, mon.fn_UtcToLocal(disabled_utc, @tz) AS disabled_local,
           source, note, modified_by, mon.fn_UtcToLocal(modified_utc, @tz) AS modified_local
    FROM mon.RcsiCutover ORDER BY database_name;
END;
GO

/* ---------------------------------------------------------------------------
   COLLECTOR  (every collect_interval_minutes, after usp_CollectPerf)
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectTempdb
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    IF ISNULL(mon.fn_SettingInt('tempdb_collect_enabled'), 1) = 0 RETURN;

    DECLARE @started datetime2(3) = SYSUTCDATETIME(),
            @now datetime2(0) = SYSUTCDATETIME(),
            @errors nvarchar(2000) = NULL,
            @sql nvarchar(max),
            @topn int = ISNULL(mon.fn_SettingInt('tempdb_top_consumers'), 10),
            @minmb int = ISNULL(mon.fn_SettingInt('tempdb_top_min_mb'), 50),
            @topgen int = ISNULL(mon.fn_SettingInt('tempdb_top_generators'), 10),
            @capture_sql bit = ISNULL(mon.fn_SettingInt('tempdb_capture_sql'), 1),
            @scan_m int = ISNULL(mon.fn_SettingInt('tempdb_growth_scan_minutes'), 15),
            @first bit = CASE WHEN EXISTS (SELECT 1 FROM mon.TempdbSample) THEN 0 ELSE 1 END;

    IF EXISTS (SELECT 1 FROM mon.TempdbSample WHERE sample_utc = @now) RETURN;

    /* ---- 1. files + space split ---- */
    CREATE TABLE #F (file_id int PRIMARY KEY, logical_name sysname, type_desc nvarchar(60), size_mb decimal(19,2),
                     used_mb decimal(19,2), max_size_mb decimal(19,2), growth_desc nvarchar(40));
    DECLARE @size decimal(19,2), @used decimal(19,2), @free decimal(19,2), @uo decimal(19,2), @io decimal(19,2),
            @vs decimal(19,2), @mx decimal(19,2), @nfiles int, @fmin decimal(19,2), @fmax decimal(19,2),
            @log_mb decimal(19,2), @log_pct decimal(9,2);
    BEGIN TRY
        INSERT #F(file_id, logical_name, type_desc, size_mb, used_mb, max_size_mb, growth_desc)
        SELECT mf.file_id, mf.name, mf.type_desc, mf.size / 128.0,
               CASE WHEN mf.type = 0 THEN (u.total_page_count - u.unallocated_extent_page_count) / 128.0 END,
               CASE WHEN mf.max_size = -1 OR mf.max_size = 268435456 THEN -1 ELSE mf.max_size / 128.0 END,
               CASE WHEN mf.is_percent_growth = 1 THEN CONCAT(mf.growth, N'%') ELSE CONCAT(mf.growth / 128, N' MB') END
        FROM sys.master_files AS mf
        LEFT JOIN tempdb.sys.dm_db_file_space_usage AS u ON u.file_id = mf.file_id
        WHERE mf.database_id = 2;

        SELECT @size = SUM(u.total_page_count) / 128.0,
               @used = SUM(u.total_page_count - u.unallocated_extent_page_count) / 128.0,
               @free = SUM(u.unallocated_extent_page_count) / 128.0,
               @uo   = SUM(u.user_object_reserved_page_count) / 128.0,
               @io   = SUM(u.internal_object_reserved_page_count) / 128.0,
               @vs   = SUM(u.version_store_reserved_page_count) / 128.0,
               @mx   = SUM(u.mixed_extent_page_count) / 128.0
        FROM tempdb.sys.dm_db_file_space_usage AS u;

        SELECT @nfiles = COUNT(*), @fmin = MIN(size_mb), @fmax = MAX(size_mb)
        FROM #F WHERE type_desc = N'ROWS';
        SELECT @log_mb = SUM(size_mb) FROM #F WHERE type_desc = N'LOG';

        INSERT mon.TempdbFileSample(sample_utc, file_id, logical_name, type_desc, size_mb, used_mb, max_size_mb, growth_desc)
        SELECT @now, file_id, logical_name, type_desc, size_mb, used_mb, max_size_mb, growth_desc FROM #F;
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' Space: ', ERROR_MESSAGE());
    END CATCH;

    BEGIN TRY
        SELECT @log_pct = CONVERT(decimal(9,2), used_log_space_in_percent) FROM tempdb.sys.dm_db_log_space_usage;
    END TRY
    BEGIN CATCH
        SET @log_pct = NULL;   /* optional */
    END CATCH;

    /* ---- 2. version store per database + versioning transactions ---- */
    CREATE TABLE #VS (database_id int PRIMARY KEY, reserved_mb decimal(19,2));
    CREATE TABLE #AT (session_id int, database_id int NULL, elapsed_s int);
    DECLARE @vs_db int, @vs_tran int, @vs_long int, @vs_sid int, @vs_login sysname, @vs_db_name sysname, @vs_prog nvarchar(128),
            @rcsi int, @si int;
    BEGIN TRY
        IF OBJECT_ID(N'sys.dm_tran_version_store_space_usage') IS NOT NULL
            EXEC sys.sp_executesql N'INSERT #VS(database_id, reserved_mb)
                                     SELECT database_id, reserved_space_kb / 1024.0 FROM sys.dm_tran_version_store_space_usage;';

        INSERT #AT(session_id, database_id, elapsed_s)
        SELECT a.session_id, s.database_id, a.elapsed_time_seconds
        FROM sys.dm_tran_active_snapshot_database_transactions AS a
        LEFT JOIN sys.dm_exec_sessions AS s ON s.session_id = a.session_id;

        SELECT @vs_db = COUNT(*) FROM #VS WHERE reserved_mb > 0;
        SELECT @vs_tran = COUNT(*), @vs_long = MAX(elapsed_s) FROM #AT;

        SELECT TOP (1) @vs_sid = a.session_id, @vs_login = s.login_name, @vs_db_name = DB_NAME(a.database_id), @vs_prog = s.program_name
        FROM #AT AS a LEFT JOIN sys.dm_exec_sessions AS s ON s.session_id = a.session_id
        ORDER BY a.elapsed_s DESC;

        SELECT @rcsi = SUM(CASE WHEN is_read_committed_snapshot_on = 1 THEN 1 ELSE 0 END),
               @si   = SUM(CASE WHEN snapshot_isolation_state = 1 THEN 1 ELSE 0 END)
        FROM sys.databases WHERE database_id > 4;

        INSERT mon.TempdbVersionStoreDb(sample_utc, database_name, database_id, reserved_mb, active_tran, longest_tran_s, is_rcsi_on, is_si_on)
        SELECT @now, d.name, d.database_id, ISNULL(v.reserved_mb, 0), ISNULL(t.n, 0), t.longest,
               d.is_read_committed_snapshot_on, CASE WHEN d.snapshot_isolation_state = 1 THEN 1 ELSE 0 END
        FROM sys.databases AS d
        LEFT JOIN #VS AS v ON v.database_id = d.database_id
        LEFT JOIN (SELECT database_id, COUNT(*) AS n, MAX(elapsed_s) AS longest FROM #AT GROUP BY database_id) AS t ON t.database_id = d.database_id
        WHERE ISNULL(v.reserved_mb, 0) > 0 OR ISNULL(t.n, 0) > 0;
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' Version store: ', ERROR_MESSAGE());
    END CATCH;

    /* ---- 3. top version generators (objects producing row versions) ---- */
    BEGIN TRY
        CREATE TABLE #G (database_id int, rowset_id bigint, version_mb decimal(19,2), object_name nvarchar(300) NULL, index_name sysname NULL);
        INSERT #G(database_id, rowset_id, version_mb)
        SELECT TOP (@topgen) g.database_id, g.rowset_id, g.aggregated_record_length_in_bytes / 1048576.0
        FROM sys.dm_tran_top_version_generators AS g
        ORDER BY g.aggregated_record_length_in_bytes DESC;

        DECLARE @gdb int, @gname sysname;
        DECLARE gen CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT g.database_id, d.name
            FROM #G AS g JOIN sys.databases AS d ON d.database_id = g.database_id
            WHERE d.state_desc = N'ONLINE' AND d.user_access_desc = N'MULTI_USER';
        OPEN gen; FETCH NEXT FROM gen INTO @gdb, @gname;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @sql = N'UPDATE g SET object_name = QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name), index_name = i.name
                            FROM #G AS g
                            JOIN ' + QUOTENAME(@gname) + N'.sys.partitions AS p ON p.hobt_id = g.rowset_id
                            JOIN ' + QUOTENAME(@gname) + N'.sys.objects AS o ON o.object_id = p.object_id
                            JOIN ' + QUOTENAME(@gname) + N'.sys.schemas AS s ON s.schema_id = o.schema_id
                            LEFT JOIN ' + QUOTENAME(@gname) + N'.sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
                            WHERE g.database_id = @d;';
                EXEC sys.sp_executesql @sql, N'@d int', @d = @gdb;
            END TRY
            BEGIN CATCH
                /* database not readable: object stays unresolved (rowset id only) */
            END CATCH;
            FETCH NEXT FROM gen INTO @gdb, @gname;
        END;
        CLOSE gen; DEALLOCATE gen;

        INSERT mon.TempdbVersionGenerator(sample_utc, database_name, rowset_id, object_name, index_name, version_mb)
        SELECT @now, ISNULL(DB_NAME(g.database_id), CONCAT(N'db ', g.database_id)), g.rowset_id,
               ISNULL(g.object_name, CONCAT(N'(rowset ', g.rowset_id, N')')), g.index_name, g.version_mb
        FROM #G AS g
        WHERE g.version_mb > 0;
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' Generators: ', ERROR_MESSAGE());
    END CATCH;

    /* ---- 4. top tempdb consumers (session + running tasks) ---- */
    DECLARE @sess int, @top_mb decimal(19,2), @top_sid int;
    BEGIN TRY
        CREATE TABLE #S (session_id int PRIMARY KEY, user_mb decimal(19,2), int_mb decimal(19,2));
        INSERT #S(session_id, user_mb, int_mb)
        SELECT su.session_id,
               (su.user_objects_alloc_page_count - su.user_objects_dealloc_page_count + ISNULL(t.uo, 0)) / 128.0,
               (su.internal_objects_alloc_page_count - su.internal_objects_dealloc_page_count + ISNULL(t.io, 0)) / 128.0
        FROM sys.dm_db_session_space_usage AS su
        LEFT JOIN (SELECT session_id,
                          SUM(user_objects_alloc_page_count - user_objects_dealloc_page_count) AS uo,
                          SUM(internal_objects_alloc_page_count - internal_objects_dealloc_page_count) AS io
                   FROM sys.dm_db_task_space_usage GROUP BY session_id) AS t ON t.session_id = su.session_id;

        SELECT @sess = COUNT(*) FROM #S WHERE user_mb + int_mb >= 1;
        SELECT TOP (1) @top_mb = user_mb + int_mb, @top_sid = session_id FROM #S ORDER BY user_mb + int_mb DESC;

        INSERT mon.TempdbTopConsumer(sample_utc, session_id, login_name, host_name, program_name, database_name, status,
                                     user_obj_mb, internal_obj_mb, total_mb, request_elapsed_s, wait_type, query_hash, sql_text)
        SELECT TOP (@topn) @now, s.session_id, es.login_name, es.host_name, es.program_name, DB_NAME(es.database_id), es.status,
               s.user_mb, s.int_mb, s.user_mb + s.int_mb,
               CASE WHEN r.session_id IS NOT NULL THEN r.total_elapsed_time / 1000 END, r.wait_type, r.query_hash,
               CASE WHEN @capture_sql = 1
                    THEN LEFT(COALESCE(
                              SUBSTRING(st.text, r.statement_start_offset / 2 + 1,
                                        CASE WHEN r.statement_end_offset = -1 THEN 2000
                                             ELSE (r.statement_end_offset - r.statement_start_offset) / 2 + 1 END),
                              st.text, ib.event_info), 2000) END
        FROM #S AS s
        LEFT JOIN sys.dm_exec_sessions AS es ON es.session_id = s.session_id
        LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
        OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
        OUTER APPLY sys.dm_exec_input_buffer(s.session_id, NULL) AS ib
        WHERE s.user_mb + s.int_mb >= @minmb
        ORDER BY s.user_mb + s.int_mb DESC;
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' Consumers: ', ERROR_MESSAGE());
    END CATCH;

    /* ---- 5. cumulative tempdb I/O ---- */
    DECLARE @rd bigint, @wr bigint, @brd bigint, @bwr bigint, @srd bigint, @swr bigint;
    BEGIN TRY
        SELECT @rd = SUM(num_of_reads), @wr = SUM(num_of_writes), @brd = SUM(num_of_bytes_read), @bwr = SUM(num_of_bytes_written),
               @srd = SUM(io_stall_read_ms), @swr = SUM(io_stall_write_ms)
        FROM sys.dm_io_virtual_file_stats(2, NULL);
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' IO: ', ERROR_MESSAGE());
    END CATCH;

    /* ---- 6. the sample row ---- */
    INSERT mon.TempdbSample(sample_utc, size_mb, used_mb, free_mb, user_obj_mb, internal_obj_mb, version_store_mb, mixed_extent_mb,
                            data_file_count, data_file_min_mb, data_file_max_mb, log_size_mb, log_used_pct,
                            vs_db_count, vs_active_tran, vs_longest_tran_s, vs_longest_session_id, vs_longest_login, vs_longest_database, vs_longest_program,
                            sessions_using_tempdb, top_session_mb, top_session_id, rcsi_db_count, si_db_count,
                            io_reads, io_writes, io_bytes_read, io_bytes_written, io_stall_read_ms, io_stall_write_ms, collection_error)
    VALUES (@now, @size, @used, @free, @uo, @io, @vs, @mx, @nfiles, @fmin, @fmax, @log_mb, @log_pct,
            @vs_db, @vs_tran, @vs_long, @vs_sid, @vs_login, @vs_db_name, @vs_prog,
            @sess, @top_mb, @top_sid, @rcsi, @si,
            @rd, @wr, @brd, @bwr, @srd, @swr, LEFT(@errors, 1000));

    /* ---- 7. RCSI cutover detection (per user database) ---- */
    BEGIN TRY
        MERGE mon.RcsiCutover AS t
        USING (SELECT d.name, d.is_read_committed_snapshot_on AS is_on
               FROM sys.databases AS d WHERE d.database_id > 4 AND d.state_desc = N'ONLINE') AS s
        ON t.database_name = s.name
        WHEN NOT MATCHED BY TARGET AND s.is_on = 1 THEN
            INSERT (database_name, is_on, enabled_utc, change_utc, source, note)
            VALUES (s.name, 1,
                    CASE WHEN @first = 1 THEN NULL ELSE @now END,
                    CASE WHEN @first = 1 THEN NULL ELSE @now END,
                    CASE WHEN @first = 1 THEN 'INSTALL' ELSE 'AUTO' END,
                    CASE WHEN @first = 1 THEN N'RCSI was already ON when tempdb monitoring started; no pre-RCSI baseline. Set the real date: EXEC mon.usp_SetRcsiCutover.'
                         ELSE N'RCSI switched ON (detected by the collector).' END)
        WHEN MATCHED AND s.is_on = 1 AND t.is_on = 0 THEN
            UPDATE SET is_on = 1, enabled_utc = @now, disabled_utc = NULL, change_utc = @now,
                       source = CASE WHEN t.source = 'MANUAL' THEN 'MANUAL' ELSE 'AUTO' END,
                       note = N'RCSI switched ON (detected by the collector).', modified_utc = @now, modified_by = N'mon.usp_CollectTempdb'
        WHEN MATCHED AND s.is_on = 0 AND t.is_on = 1 THEN
            UPDATE SET is_on = 0, disabled_utc = @now, change_utc = @now,
                       note = N'RCSI switched OFF (detected by the collector).', modified_utc = @now, modified_by = N'mon.usp_CollectTempdb';
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' RCSI: ', ERROR_MESSAGE());
    END CATCH;

    /* ---- 8. autogrowth events from the default trace (every tempdb_growth_scan_minutes) ---- */
    DECLARE @wm datetime2(3) = (SELECT watermark_utc FROM mon.ComponentStatus WHERE component_name = 'TEMPDB_GROWTH');
    IF @wm IS NULL OR @wm < DATEADD(MINUTE, -@scan_m, @started)
    BEGIN
        BEGIN TRY
            DECLARE @path nvarchar(260) = (SELECT TOP (1) path FROM sys.traces WHERE is_default = 1 AND status = 1);
            IF @path IS NOT NULL
            BEGIN
                /* base file name: log_123.trc -> log.trc reads the whole rollover set */
                IF CHARINDEX(N'_', REVERSE(@path)) > 0
                    SET @path = LEFT(@path, LEN(@path) - CHARINDEX(N'_', REVERSE(@path))) + N'.trc';
                DECLARE @since datetime = (SELECT ISNULL(DATEADD(MINUTE, -1, MAX(event_utc)), DATEADD(DAY, -3, @now)) FROM mon.TempdbGrowthEvent);
                /* trace times are server-local: shift the lower bound into server time */
                SET @since = DATEADD(MINUTE, DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), @since);

                INSERT mon.TempdbGrowthEvent(event_utc, file_name, event_type, growth_mb, duration_ms)
                SELECT x.event_utc, x.file_name, x.event_type, x.growth_mb, x.duration_ms
                FROM (SELECT CONVERT(datetime2(3), mon.fn_ServerToUtc(t.StartTime)) AS event_utc,
                             ISNULL(t.FileName, N'?') AS file_name,
                             CASE t.EventClass WHEN 92 THEN 'DATA' ELSE 'LOG' END AS event_type,
                             CONVERT(decimal(19,2), t.IntegerData / 128.0) AS growth_mb,
                             CONVERT(int, t.Duration / 1000) AS duration_ms
                      FROM sys.fn_trace_gettable(@path, DEFAULT) AS t
                      WHERE t.EventClass IN (92, 93) AND t.DatabaseName = N'tempdb' AND t.StartTime > @since) AS x
                WHERE NOT EXISTS (SELECT 1 FROM mon.TempdbGrowthEvent AS e WHERE e.event_utc = x.event_utc AND e.file_name = x.file_name);
            END;
            EXEC mon.usp_SetComponentStatus 'TEMPDB_GROWTH', 1, @started;
        END TRY
        BEGIN CATCH
            DECLARE @gen int = ERROR_NUMBER(), @gem nvarchar(2000) = ERROR_MESSAGE();
            EXEC mon.usp_SetComponentStatus 'TEMPDB_GROWTH', 0, @started, @gen, @gem;
        END CATCH;
        UPDATE mon.ComponentStatus SET watermark_utc = @started WHERE component_name = 'TEMPDB_GROWTH';
    END;

    IF @errors IS NULL
        EXEC mon.usp_SetComponentStatus 'TEMPDB', 1, @started;
    ELSE
        EXEC mon.usp_SetComponentStatus 'TEMPDB', 0, @started, 50003, @errors;
END;
GO

/* ---------------------------------------------------------------------------
   DAILY AGGREGATES  (hourly job; fills every complete local day that has samples
   but no mon.TempdbDaily row yet; @Date re-computes one day)
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_SnapshotTempdbDaily
    @Date date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');
    DECLARE @today date = CONVERT(date, mon.fn_UtcToLocal(SYSUTCDATETIME(), @tz));

    IF @Date IS NOT NULL
        DELETE FROM mon.TempdbDaily WHERE report_date = @Date;
    ELSE
        /* a row computed while its day was still running (preview / manual run) is recomputed once the day is over */
        DELETE d FROM mon.TempdbDaily AS d
        WHERE d.report_date < @today
          AND d.computed_utc < CONVERT(datetime2(0), (CONVERT(datetime2(0), DATEADD(DAY, 1, d.report_date)) AT TIME ZONE @tz) AT TIME ZONE 'UTC');

    ;WITH L AS
    (
        SELECT s.*, CONVERT(date, (s.sample_utc AT TIME ZONE 'UTC') AT TIME ZONE @tz) AS d
        FROM mon.TempdbSample AS s
        WHERE s.sample_utc >= DATEADD(DAY, -45, SYSUTCDATETIME())
    ), D AS
    (
        SELECT L.d FROM L
        WHERE (@Date IS NULL AND L.d < @today) OR L.d = @Date
        GROUP BY L.d
        HAVING NOT EXISTS (SELECT 1 FROM mon.TempdbDaily AS t WHERE t.report_date = L.d)
    ), P AS
    (
        SELECT L.d,
               PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY L.used_mb)          OVER (PARTITION BY L.d) AS used_p95,
               PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY L.version_store_mb) OVER (PARTITION BY L.d) AS vs_p95,
               L.io_bytes_read  - LAG(L.io_bytes_read)  OVER (PARTITION BY L.d ORDER BY L.sample_utc) AS d_brd,
               L.io_bytes_written - LAG(L.io_bytes_written) OVER (PARTITION BY L.d ORDER BY L.sample_utc) AS d_bwr,
               L.io_reads  - LAG(L.io_reads)  OVER (PARTITION BY L.d ORDER BY L.sample_utc) AS d_rd,
               L.io_writes - LAG(L.io_writes) OVER (PARTITION BY L.d ORDER BY L.sample_utc) AS d_wr,
               L.io_stall_read_ms  - LAG(L.io_stall_read_ms)  OVER (PARTITION BY L.d ORDER BY L.sample_utc) AS d_srd,
               L.io_stall_write_ms - LAG(L.io_stall_write_ms) OVER (PARTITION BY L.d ORDER BY L.sample_utc) AS d_swr,
               L.sample_utc, L.size_mb, L.used_mb, L.user_obj_mb, L.internal_obj_mb, L.version_store_mb, L.vs_longest_tran_s,
               L.vs_active_tran, L.sessions_using_tempdb, L.top_session_mb, L.log_used_pct, L.rcsi_db_count
        FROM L
        WHERE L.d IN (SELECT d FROM D)
    )
    INSERT mon.TempdbDaily(report_date, samples, size_max_mb, used_min_mb, used_avg_mb, used_p95_mb, used_max_mb,
                           user_obj_avg_mb, user_obj_max_mb, internal_obj_avg_mb, internal_obj_max_mb,
                           vs_avg_mb, vs_p95_mb, vs_max_mb, vs_tran_max_s, vs_active_tran_max, sessions_max, top_session_max_mb,
                           log_used_max_pct, io_read_mb, io_write_mb, io_read_ms_avg, io_write_ms_avg, growth_events, rcsi_db_count_max)
    SELECT P.d, COUNT(*), MAX(P.size_mb), MIN(P.used_mb), AVG(P.used_mb), MAX(P.used_p95), MAX(P.used_mb),
           AVG(P.user_obj_mb), MAX(P.user_obj_mb), AVG(P.internal_obj_mb), MAX(P.internal_obj_mb),
           AVG(P.version_store_mb), MAX(P.vs_p95), MAX(P.version_store_mb), MAX(P.vs_longest_tran_s), MAX(P.vs_active_tran),
           MAX(P.sessions_using_tempdb), MAX(P.top_session_mb), MAX(P.log_used_pct),
           SUM(CASE WHEN P.d_brd > 0 THEN P.d_brd ELSE 0 END) / 1048576,
           SUM(CASE WHEN P.d_bwr > 0 THEN P.d_bwr ELSE 0 END) / 1048576,
           CONVERT(decimal(9,2), SUM(CASE WHEN P.d_srd > 0 THEN P.d_srd ELSE 0 END) * 1.0 / NULLIF(SUM(CASE WHEN P.d_rd > 0 THEN P.d_rd ELSE 0 END), 0)),
           CONVERT(decimal(9,2), SUM(CASE WHEN P.d_swr > 0 THEN P.d_swr ELSE 0 END) * 1.0 / NULLIF(SUM(CASE WHEN P.d_wr > 0 THEN P.d_wr ELSE 0 END), 0)),
           (SELECT COUNT(*) FROM mon.TempdbGrowthEvent AS g
             WHERE CONVERT(date, (g.event_utc AT TIME ZONE 'UTC') AT TIME ZONE @tz) = P.d),
           MAX(P.rcsi_db_count)
    FROM P
    GROUP BY P.d;
END;
GO

/*
   What does tempdb look like, and what happened before / after RCSI?  (SSMS, 6 result sets)
     EXEC OPS.mon.usp_ShowTempdb;              -- last 30 days
     EXEC OPS.mon.usp_ShowTempdb @Days = 7;
*/
CREATE OR ALTER PROCEDURE mon.usp_ShowTempdb
    @Days int = 30
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');
    DECLARE @since datetime2(0) = DATEADD(DAY, -@Days, SYSUTCDATETIME());

    /* 1) now */
    SELECT TOP (1) mon.fn_UtcToLocal(s.sample_utc, @tz) AS [Sample (local)],
           s.size_mb AS [tempdb MB], s.used_mb AS [Used MB], s.free_mb AS [Free MB],
           s.user_obj_mb AS [User objects MB], s.internal_obj_mb AS [Internal MB], s.version_store_mb AS [Version store MB],
           s.data_file_count AS [Data files], s.data_file_min_mb AS [Smallest file MB], s.data_file_max_mb AS [Largest file MB],
           s.log_size_mb AS [Log MB], s.log_used_pct AS [Log used %],
           s.vs_active_tran AS [Versioning trans], s.vs_longest_tran_s AS [Longest tran s], s.vs_longest_session_id AS [Longest session],
           s.vs_longest_login AS [Longest login], s.vs_longest_database AS [Longest db],
           s.sessions_using_tempdb AS [Sessions >= 1 MB], s.top_session_mb AS [Top session MB], s.top_session_id AS [Top session],
           s.rcsi_db_count AS [RCSI dbs], s.si_db_count AS [SI dbs], s.collection_error AS [Collection error]
    FROM mon.TempdbSample AS s ORDER BY s.sample_utc DESC;

    /* 2) RCSI cutovers */
    SELECT c.database_name AS [Database], c.is_on AS [RCSI on], mon.fn_UtcToLocal(c.enabled_utc, @tz) AS [Enabled (local)],
           mon.fn_UtcToLocal(c.disabled_utc, @tz) AS [Disabled (local)], c.source AS [Source], c.note AS [Note],
           c.modified_by AS [By], mon.fn_UtcToLocal(c.modified_utc, @tz) AS [Modified (local)]
    FROM mon.RcsiCutover AS c ORDER BY c.database_name;

    /* 3) daily */
    SELECT d.report_date AS [Day], d.samples AS [Samples], d.size_max_mb AS [tempdb MB], d.used_avg_mb AS [Used avg], d.used_p95_mb AS [Used p95],
           d.used_max_mb AS [Used max], d.user_obj_max_mb AS [User obj max], d.internal_obj_max_mb AS [Internal max],
           d.vs_avg_mb AS [VS avg], d.vs_p95_mb AS [VS p95], d.vs_max_mb AS [VS max], d.vs_tran_max_s AS [Longest tran s],
           d.vs_active_tran_max AS [Versioning trans max], d.sessions_max AS [Sessions max], d.top_session_max_mb AS [Top session max MB],
           d.log_used_max_pct AS [Log used max %], d.io_read_mb AS [Read MB], d.io_write_mb AS [Write MB],
           d.io_read_ms_avg AS [Read ms], d.io_write_ms_avg AS [Write ms], d.growth_events AS [Autogrowths], d.rcsi_db_count_max AS [RCSI dbs]
    FROM mon.TempdbDaily AS d WHERE d.report_date >= CONVERT(date, @since) ORDER BY d.report_date DESC;

    /* 4) version store by database (last 24 h) */
    SELECT v.database_name AS [Database], MAX(CONVERT(tinyint, v.is_rcsi_on)) AS [RCSI], MAX(CONVERT(tinyint, v.is_si_on)) AS [SI],
           MAX(v.reserved_mb) AS [VS max MB], AVG(v.reserved_mb) AS [VS avg MB], MAX(v.active_tran) AS [Versioning trans max],
           MAX(v.longest_tran_s) AS [Longest tran s], COUNT(*) AS [Samples]
    FROM mon.TempdbVersionStoreDb AS v WHERE v.sample_utc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
    GROUP BY v.database_name ORDER BY [VS max MB] DESC;

    /* 5) top version generators (last 24 h) */
    SELECT TOP (30) g.database_name AS [Database], g.object_name AS [Object], g.index_name AS [Index],
           MAX(g.version_mb) AS [Max MB], AVG(g.version_mb) AS [Avg MB], COUNT(*) AS [Samples],
           mon.fn_UtcToLocal(MAX(g.sample_utc), @tz) AS [Last seen (local)]
    FROM mon.TempdbVersionGenerator AS g WHERE g.sample_utc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
    GROUP BY g.database_name, g.object_name, g.index_name ORDER BY [Max MB] DESC;

    /* 6) top consumers (last 24 h) */
    SELECT TOP (50) mon.fn_UtcToLocal(c.sample_utc, @tz) AS [Sample (local)], c.session_id AS [Session], c.login_name AS [Login],
           c.host_name AS [Host], c.program_name AS [Program], c.database_name AS [Database], c.status AS [Status],
           c.total_mb AS [tempdb MB], c.user_obj_mb AS [User obj MB], c.internal_obj_mb AS [Internal MB],
           c.request_elapsed_s AS [Running s], c.wait_type AS [Wait], c.sql_text AS [Statement]
    FROM mon.TempdbTopConsumer AS c WHERE c.sample_utc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
    ORDER BY c.total_mb DESC;
END;
GO
