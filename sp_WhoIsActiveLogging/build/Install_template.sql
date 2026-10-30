/*
================================================================================
 sp_WhoIsActive + sp_WhoIsActive Logging - single-file installer
 (utility-database edition)
================================================================================

 GENERATED FILE - do not edit by hand. Edit build/Install_template.sql and run
 build/build_installer.py (it splices in the current sp_WhoIsActive sources).
   Built: {{BUILD_DATE}}

 Embedded: Adam Machanic's sp_WhoIsActive
   https://github.com/amachanic/sp_whoisactive  (C) 2007-2026 Adam Machanic
   License: GPLv3 - https://github.com/amachanic/sp_whoisactive/blob/master/LICENSE
   - SQL Server 2022+     : {{WIA_2022_VERSION}}  (root sp_WhoIsActive.sql)
   - SQL Server 2016-2019 : {{WIA_2019_VERSION}}  (2019/sp_WhoIsActive.sql)
   Source commit: {{WIA_COMMIT}}
   The installer picks the right build from SERVERPROPERTY('ProductMajorVersion').

 Based on Erik Darling's "sp_WhoIsActive Logging" toolkit:
   https://github.com/erikdarlingdata/DarlingData/tree/main/sp_WhoIsActive%20Logging
   Copyright 2026 Darling Data, LLC - https://www.erikdarling.com/ - MIT License
   (source files 01..04, commit ea1a93a, 2026-09-29)

 WHAT THIS SCRIPT DOES (all in ONE run, idempotent / re-runnable)
   1. Switches to the target database ONCE (the USE line below).
   2. Validates prerequisites (not a system DB, SQL 2016 SP1+, not Azure SQL DB).
   3. Creates/updates in the target database:
        dbo.sp_WhoIsActive                      (version-appropriate build)
        dbo.sp_WhoIsActiveLogging_CreateViews
        dbo.sp_WhoIsActiveLogging_Retention
        dbo.sp_WhoIsActiveLogging_Main
      Runtime objects (created by the job):
        dbo.WhoIsActive_YYYYMMDD   - one table per day
        dbo.WhoIsActive            - UNION ALL view across daily tables
        dbo.WhoIsActive_blocking   - recursive blocking-chain view
   4. Creates the SQL Agent job in msdb (same definition as Erik's script),
      with the job step pointed at the target database.
   5. Optionally runs one collection so tables + views exist immediately.

 DIFFERENCES FROM THE ORIGINAL (all deliberate, all small)
   - sp_WhoIsActive itself is installed into the target database.
   - Destination database = the database the procs live in (original: master).
   - sp_WhoIsActive is located at runtime: target DB first, then master.
   - Daily table name uses CONVERT(..., 112) - immune to DATEFORMAT/language.
   - Optional clustered index on collection_time + optional data compression
     on each new daily table (original: heap, no compression).
   - View dbo.WhoIsActive is only rebuilt when the set of tables changes
     (original: CREATE OR ALTER VIEW every minute -> Sch-M lock every minute).
   - Tables whose column layout differs from the newest table (e.g. after an
     sp_WhoIsActive upgrade) are left out of the view instead of breaking it.
     They are still queryable directly and age out via retention.
   - Retention/view logic scoped to the dbo schema of the target DB only.
   - Job owner = the instance's SID 0x01 login (renamed 'sa' safe).
   - Re-running the installer replaces the job (history is kept).

 HOW TO USE
   1. Change the database name in the USE statement below (default: Utility).
   2. Optionally adjust the values in the CONFIGURATION section.
   3. Run the whole script (F5). Needs sysadmin (SQL Agent job creation).

================================================================================
*/
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
SET IMPLICIT_TRANSACTIONS OFF;
SET STATISTICS TIME, IO OFF;
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

/* ===================== TARGET DATABASE - CHANGE HERE ONLY ===================== */
USE [Utility];
GO
/* ============================================================================== */


/*------------------------------------------------------------------------------
 CONFIGURATION (session temp table - survives the GO batches below)
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'tempdb..#wia_config') IS NOT NULL
    DROP TABLE #wia_config;

CREATE TABLE #wia_config
(
    InstallWhoIsActive   bit           NOT NULL,  /* 1 = install/upgrade dbo.sp_WhoIsActive in this DB */
    RetentionDays        int           NOT NULL,
    DataCompression      nvarchar(4)   NOT NULL,  /* NONE | ROW | PAGE */
    CreateClusteredIndex bit           NOT NULL,  /* CI on collection_time per daily table */
    JobName              sysname       NOT NULL,
    JobOwner             sysname       NULL,      /* NULL = login with SID 0x01 (sa) */
    JobEnabled           bit           NOT NULL,
    ScheduleEveryMinutes int           NOT NULL,  /* 1 = every minute, like the original */
    ReplaceExistingJob   bit           NOT NULL,  /* 1 = drop & recreate job (history kept) */
    RunFirstCollection   bit           NOT NULL   /* 1 = run one collection at end of install */
);

INSERT #wia_config
(
    InstallWhoIsActive,
    RetentionDays, DataCompression, CreateClusteredIndex,
    JobName, JobOwner, JobEnabled, ScheduleEveryMinutes,
    ReplaceExistingJob, RunFirstCollection
)
VALUES
(
    1,                                        /* InstallWhoIsActive   */
    10,                                       /* RetentionDays        */
    N'NONE',                                  /* DataCompression      */
    1,                                        /* CreateClusteredIndex */
    N'Log sp_WhoIsActive To A Daily Table',   /* JobName              */
    NULL,                                     /* JobOwner             */
    1,                                        /* JobEnabled           */
    1,                                        /* ScheduleEveryMinutes */
    1,                                        /* ReplaceExistingJob   */
    1                                         /* RunFirstCollection   */
);
GO


/*------------------------------------------------------------------------------
 PREREQUISITE CHECKS - any failure stops the rest of the script (SET NOEXEC ON)
------------------------------------------------------------------------------*/
DECLARE
    @db              sysname = DB_NAME(),
    @major           int     = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')),
    @engine_edition  int     = CONVERT(int, SERVERPROPERTY('EngineEdition')),
    @install_wia     bit,
    @wia_object_id   int,
    @wia_location    nvarchar(300),
    @compression     nvarchar(4),
    @minutes         int,
    @retention       int,
    @msg             nvarchar(2048);

SELECT
    @install_wia = c.InstallWhoIsActive,
    @compression = UPPER(c.DataCompression),
    @minutes     = c.ScheduleEveryMinutes,
    @retention   = c.RetentionDays
FROM #wia_config AS c;

IF @db IN (N'master', N'model', N'msdb', N'tempdb')
BEGIN
    SET @msg = N'Current database is ' + @db + N'. Either the USE statement failed (database does not exist?) '
             + N'or it points to a system database. Create the utility database first / fix the USE line. Install aborted.';
    RAISERROR(@msg, 16, 1) WITH NOWAIT;
    SET NOEXEC ON;
END;
ELSE IF @engine_edition = 5
BEGIN
    RAISERROR(N'Azure SQL Database has no SQL Agent / msdb jobs. Use Elastic Jobs instead. Install aborted.', 16, 1) WITH NOWAIT;
    SET NOEXEC ON;
END;
ELSE IF @major < 13
     OR (@major = 13 AND CONVERT(nvarchar(128), SERVERPROPERTY('ProductLevel')) = N'RTM')
BEGIN
    RAISERROR(N'SQL Server 2016 SP1 or later is required (CREATE OR ALTER). Install aborted.', 16, 1) WITH NOWAIT;
    SET NOEXEC ON;
END;
ELSE IF @compression NOT IN (N'NONE', N'ROW', N'PAGE')
     OR @minutes NOT BETWEEN 1 AND 59
     OR @retention < 1
BEGIN
    RAISERROR(N'Invalid #wia_config values (DataCompression NONE|ROW|PAGE, ScheduleEveryMinutes 1-59, RetentionDays >= 1). Install aborted.', 16, 1) WITH NOWAIT;
    SET NOEXEC ON;
END;
ELSE IF @install_wia = 1
BEGIN
    SET @msg = N'Prerequisites OK. Target database: ' + QUOTENAME(@db)
             + N'. sp_WhoIsActive will be installed/upgraded in ' + QUOTENAME(@db) + N'.';
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    IF OBJECT_ID(N'master.dbo.sp_WhoIsActive', N'P') IS NOT NULL
    BEGIN
        RAISERROR(N'Note: master.dbo.sp_WhoIsActive also exists. The logging job uses the copy in the target database; the master copy is left untouched.', 0, 1) WITH NOWAIT;
    END;
END;
ELSE
BEGIN
    /* InstallWhoIsActive = 0: an existing sp_WhoIsActive must be present (target DB first, then master) */
    SET @wia_object_id = OBJECT_ID(QUOTENAME(@db) + N'.dbo.sp_WhoIsActive', N'P');
    SET @wia_location  = QUOTENAME(@db) + N'.dbo.sp_WhoIsActive';

    IF @wia_object_id IS NULL
    BEGIN
        SET @wia_object_id = OBJECT_ID(N'master.dbo.sp_WhoIsActive', N'P');
        SET @wia_location  = N'[master].[dbo].[sp_WhoIsActive]';
    END;

    IF @wia_object_id IS NULL
    BEGIN
        SET @msg = N'InstallWhoIsActive = 0 but sp_WhoIsActive was not found in ' + QUOTENAME(@db)
                 + N' or [master]. Set InstallWhoIsActive = 1. Install aborted.';
        RAISERROR(@msg, 16, 1) WITH NOWAIT;
        SET NOEXEC ON;
    END;
    ELSE IF
    (
        (@wia_location LIKE N'[[]master]%'
         AND NOT EXISTS (SELECT 1/0 FROM master.sys.parameters AS p
                         WHERE p.object_id = @wia_object_id AND p.name = N'@get_memory_info'))
        OR
        (@wia_location NOT LIKE N'[[]master]%'
         AND NOT EXISTS (SELECT 1/0 FROM sys.parameters AS p
                         WHERE p.object_id = @wia_object_id AND p.name = N'@get_memory_info'))
    )
    BEGIN
        SET @msg = N'sp_WhoIsActive at ' + @wia_location + N' is too old (no @get_memory_info parameter). '
                 + N'Set InstallWhoIsActive = 1 to install the embedded version. Install aborted.';
        RAISERROR(@msg, 16, 1) WITH NOWAIT;
        SET NOEXEC ON;
    END;
    ELSE
    BEGIN
        SET @msg = N'Prerequisites OK. Target database: ' + QUOTENAME(@db)
                 + N'. Using existing sp_WhoIsActive: ' + @wia_location + N'.';
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
    END;
END;
GO


/*------------------------------------------------------------------------------
 0. dbo.sp_WhoIsActive   (Adam Machanic, GPLv3 - embedded, version-aware)
    SQL Server 2022+ gets {{WIA_2022_VERSION}}, 2016-2019 gets {{WIA_2019_VERSION}}.
    The procedure text is passed to EXECUTE() verbatim (quotes doubled), so the
    stored definition - including the --~ help markers - is identical to the
    original script.
------------------------------------------------------------------------------*/
DECLARE
    @install_wia bit,
    @major       int = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')),
    @msg         nvarchar(2048);

SELECT
    @install_wia = c.InstallWhoIsActive
FROM #wia_config AS c;

IF @install_wia = 1
BEGIN
    IF OBJECT_ID(N'dbo.sp_WhoIsActive', N'P') IS NULL
    BEGIN
        EXECUTE (N'CREATE PROCEDURE dbo.sp_WhoIsActive AS SELECT ''stub version, to be replaced'';');
    END;

    IF @major >= 16
    BEGIN
        EXECUTE (N'{{WIA_2022_BODY}}');
        SET @msg = N'dbo.sp_WhoIsActive {{WIA_2022_VERSION}} (SQL Server 2022+ build) installed in ' + QUOTENAME(DB_NAME()) + N'.';
    END;
    ELSE
    BEGIN
        EXECUTE (N'{{WIA_2019_BODY}}');
        SET @msg = N'dbo.sp_WhoIsActive {{WIA_2019_VERSION}} (SQL Server 2012-2019 build) installed in ' + QUOTENAME(DB_NAME()) + N'.';
    END;

    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END;
GO


/*------------------------------------------------------------------------------
 1. dbo.sp_WhoIsActiveLogging_CreateViews   (Erik's file 01, hardened)
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.sp_WhoIsActiveLogging_CreateViews', N'P') IS NULL
BEGIN
    EXECUTE (N'CREATE PROCEDURE dbo.sp_WhoIsActiveLogging_CreateViews AS RETURN 138;');
END;
GO

ALTER PROCEDURE
    dbo.sp_WhoIsActiveLogging_CreateViews
AS
BEGIN
    SET STATISTICS XML OFF;
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE
        @newest_signature nvarchar(MAX),
        @vsql             nvarchar(MAX),
        @current          nvarchar(MAX);

    /* Daily logging tables in dbo of this database, with a column signature */
    CREATE TABLE #tables
    (
        table_name  sysname       NOT NULL PRIMARY KEY,
        create_date datetime      NOT NULL,
        signature   nvarchar(MAX) NULL
    );

    INSERT #tables
    (
        table_name,
        create_date,
        signature
    )
    SELECT
        t.name,
        t.create_date,
        (
            SELECT
                [text()] =
                    QUOTENAME(c.name) +
                    N':' +
                    TYPE_NAME(c.user_type_id) +
                    N';'
            FROM sys.columns AS c
            WHERE c.object_id = t.object_id
            ORDER BY
                c.column_id
            FOR XML
                PATH(N''),
                TYPE
        ).value
         (
             './text()[1]',
             'nvarchar(max)'
         )
    FROM sys.tables AS t
    WHERE t.schema_id = SCHEMA_ID(N'dbo')
    AND   t.name LIKE N'WhoIsActive[_][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%';

    IF NOT EXISTS (SELECT 1/0 FROM #tables)
    BEGIN
        RETURN;
    END;

    /* Newest table defines the view's shape */
    SELECT TOP (1)
        @newest_signature = t.signature
    FROM #tables AS t
    ORDER BY
        t.create_date DESC,
        t.table_name DESC;

    SELECT
        @vsql =
            N'CREATE OR ALTER VIEW' + NCHAR(10) +
            N'    dbo.WhoIsActive' + NCHAR(10) +
            N'AS' + NCHAR(10) +
            STUFF
            (
                (
                    SELECT TOP (9223372036854775807)
                        [text()] =
                            N'UNION ALL' + NCHAR(10) +
                            N'SELECT * FROM [dbo].' +
                            QUOTENAME(t.table_name) +
                            NCHAR(10)
                    FROM #tables AS t
                    WHERE t.signature = @newest_signature
                    ORDER BY
                        t.create_date DESC,
                        t.table_name DESC
                    FOR XML
                        PATH(N''),
                        TYPE
                ).value
                 (
                     './text()[1]',
                     'nvarchar(max)'
                 ),
                1,
                10,
                N''
            ) +
            N';';

    /* Only rebuild when the table set actually changed (avoids a Sch-M lock every minute) */
    SELECT
        @current = OBJECT_DEFINITION(OBJECT_ID(N'dbo.WhoIsActive', N'V'));

    IF @current IS NULL
    OR @current <> @vsql COLLATE Latin1_General_BIN2
    BEGIN
        EXECUTE sys.sp_executesql
            @vsql;
    END;

    IF NOT EXISTS
    (
        SELECT
            1/0
        FROM sys.views AS v
        WHERE v.name = N'WhoIsActive_blocking'
        AND   v.schema_id = SCHEMA_ID(N'dbo')
    )
    BEGIN
        DECLARE
            @sql nvarchar(MAX) = N'
        CREATE OR ALTER VIEW
            dbo.WhoIsActive_blocking
        AS
        WITH b AS
        (
            SELECT
                l =
                    CONVERT
                    (
                        varchar(1000),
                        REPLICATE
                        (
                            '' '',
                            4 -
                            LEN
                            (
                                CONVERT
                                (
                                    varchar(1000),
                                    wia.session_id
                                )
                            )
                        ) +
                          CONVERT
                          (
                              varchar(1000),
                              wia.session_id
                          )
                    ),
                wia.collection_time,
                wia.[dd hh:mm:ss.mss],
                wia.sql_text,
                wia.sql_command,
                wia.login_name,
                wia.wait_info,
                wia.session_id,
                wia.blocking_session_id,
                wia.blocked_session_count,
                wia.implicit_tran,
                wia.status,
                wia.open_tran_count,
                wia.query_plan,
                wia.additional_info
            FROM dbo.WhoIsActive AS wia
            WHERE (wia.blocking_session_id IS NULL
                    OR  wia.blocking_session_id = wia.session_id)
            AND   EXISTS
                  (
                      SELECT
                          1/0
                      FROM dbo.WhoIsActive AS wia2
                      WHERE wia2.blocking_session_id = wia.session_id
                      AND   wia2.collection_time = wia.collection_time
                      AND   wia2.blocking_session_id <> wia2.session_id
                  )

            UNION ALL

            SELECT
                l =
                    CONVERT
                    (
                        varchar(1000),
                        REPLICATE
                        (
                            '' '',
                            4 -
                            LEN
                            (
                                CONVERT
                                (
                                    varchar(1000),
                                    wia.session_id
                                )
                            )
                        ) +
                          CONVERT
                          (
                              varchar(1000),
                              wia.session_id
                          )
                    ),
                wia.collection_time,
                wia.[dd hh:mm:ss.mss],
                wia.sql_text,
                wia.sql_command,
                wia.login_name,
                wia.wait_info,
                wia.session_id,
                wia.blocking_session_id,
                wia.blocked_session_count,
                wia.implicit_tran,
                wia.status,
                wia.open_tran_count,
                wia.query_plan,
                wia.additional_info
            FROM dbo.WhoIsActive AS wia
            JOIN b AS b
              ON  wia.blocking_session_id = b.session_id
              AND b.collection_time = wia.collection_time
            WHERE wia.blocking_session_id IS NOT NULL
            AND   wia.blocking_session_id <> wia.session_id
        )
        SELECT TOP (9223372036854775807)
            b.[dd hh:mm:ss.mss],
            blocking =
                ''|--->'' +
                REPLICATE
                (
                    '' |---> '',
                    LEN(b.l) / 4 - 1
                ) +
                CASE
                    WHEN b.blocking_session_id IS NULL
                    THEN '' Lead SPID: ''
                    ELSE ''|---> Blocked SPID: ''
                END +
                CONVERT
                (
                    varchar(10),
                    b.session_id
                ) +
                '' '' +
                CONVERT
                (
                    varchar(30),
                    b.collection_time
                ),
            b.wait_info,
            b.sql_text,
            b.sql_command,
            b.query_plan,
            b.additional_info,
            b.session_id,
            b.blocking_session_id,
            b.blocked_session_count,
            b.implicit_tran,
            b.status,
            b.open_tran_count,
            b.login_name,
            b.collection_time
        FROM b AS b
        ORDER BY
            b.collection_time,
            b.blocked_session_count DESC;';

        EXECUTE sys.sp_executesql
            @sql;
    END;
END;
GO


/*------------------------------------------------------------------------------
 2. dbo.sp_WhoIsActiveLogging_Retention   (Erik's file 03, scoped to dbo)
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.sp_WhoIsActiveLogging_Retention', N'P') IS NULL
BEGIN
    EXECUTE (N'CREATE PROCEDURE dbo.sp_WhoIsActiveLogging_Retention AS RETURN 138;');
END;
GO

ALTER PROCEDURE
    dbo.sp_WhoIsActiveLogging_Retention
(
    @RetentionPeriod integer = 10
)
AS
BEGIN
    SET STATISTICS XML OFF;
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    /* Never let a bad parameter wipe today's table */
    IF @RetentionPeriod IS NULL OR @RetentionPeriod < 1
    BEGIN
        SET @RetentionPeriod = 1;
    END;

    DECLARE
        @dsql nvarchar(MAX) = N'';

    SELECT
        @dsql =
        (
            SELECT TOP (9223372036854775807)
                [text()] =
                    N'DROP TABLE ' +
                    QUOTENAME(SCHEMA_NAME(t.schema_id)) +
                    N'.' +
                    QUOTENAME(t.name) +
                    N';'
            FROM sys.tables AS t
            WHERE t.schema_id = SCHEMA_ID(N'dbo')
            AND   t.name LIKE N'WhoIsActive[_][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%'
            AND   t.create_date < DATEADD(DAY, (@RetentionPeriod * -1), SYSDATETIME())
            ORDER BY
                t.create_date DESC
            FOR XML
                PATH(N''),
                TYPE
        ).value
         (
             './text()[1]',
             'nvarchar(max)'
         );

    IF @dsql IS NOT NULL
    BEGIN
        EXECUTE sys.sp_executesql
            @dsql;
    END;
END;
GO


/*------------------------------------------------------------------------------
 3. dbo.sp_WhoIsActiveLogging_Main   (Erik's file 02, logs to THIS database)
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.sp_WhoIsActiveLogging_Main', N'P') IS NULL
BEGIN
    EXECUTE (N'CREATE PROCEDURE dbo.sp_WhoIsActiveLogging_Main AS RETURN 138;');
END;
GO

ALTER PROCEDURE
    dbo.sp_WhoIsActiveLogging_Main
(
    @RetentionPeriod      int         = 10,
    @DataCompression      nvarchar(4) = N'NONE', /* NONE | ROW | PAGE - applied to new daily tables */
    @CreateClusteredIndex bit         = 1        /* clustered index on collection_time */
)
AS
BEGIN
    /*
    SQL Agent has some weird settings.
    This sets them to the correct ones.
    */
    SET
        NOCOUNT,
        XACT_ABORT,
        ANSI_NULLS,
        ANSI_PADDING,
        ANSI_WARNINGS,
        ARITHABORT,
        CONCAT_NULL_YIELDS_NULL,
        QUOTED_IDENTIFIER
    ON;

    SET NUMERIC_ROUNDABORT OFF;

    DECLARE
        @table_name sysname =
            N'WhoIsActive_' +
            CONVERT(nchar(8), GETDATE(), 112),  /* YYYYMMDD, independent of DATEFORMAT/language */
        @destination_database sysname =
            DB_NAME(),                          /* the database this procedure lives in */
        @destination_table nvarchar(400),
        @local_table nvarchar(400),
        @whoisactive nvarchar(400),
        @schema nvarchar(MAX) = N'',
        @ddl nvarchar(MAX);

    SELECT
        @local_table =
            N'[dbo].' + QUOTENAME(@table_name),
        @destination_table =
            QUOTENAME(@destination_database) +
            N'.[dbo].' +
            QUOTENAME(@table_name),
        @DataCompression =
            UPPER(ISNULL(@DataCompression, N'NONE'));

    IF @DataCompression NOT IN (N'NONE', N'ROW', N'PAGE')
    BEGIN
        SET @DataCompression = N'NONE';
    END;

    /*
    Find sp_WhoIsActive: this database first, then master.
    */
    IF OBJECT_ID(QUOTENAME(@destination_database) + N'.dbo.sp_WhoIsActive', N'P') IS NOT NULL
    BEGIN
        SET @whoisactive = QUOTENAME(@destination_database) + N'.dbo.sp_WhoIsActive';
    END;
    ELSE IF OBJECT_ID(N'master.dbo.sp_WhoIsActive', N'P') IS NOT NULL
    BEGIN
        SET @whoisactive = N'master.dbo.sp_WhoIsActive';
    END;
    ELSE
    BEGIN
        RAISERROR(N'sp_WhoIsActive not found in this database or master. Get it at https://github.com/amachanic/sp_whoisactive', 16, 1);
        RETURN;
    END;

    /*
    Create the table for logging.
    */
    IF OBJECT_ID(@destination_table, N'U') IS NULL
    BEGIN
        EXECUTE @whoisactive
            @get_transaction_info = 1,
            @get_outer_command = 1,
            @get_plans = 1,
            @get_task_info = 2,
            @get_additional_info = 1,
            @find_block_leaders = 1,
            @get_memory_info = 1,
            @return_schema = 1,
            @schema = @schema OUTPUT;

        SELECT
            @schema =
                REPLACE
                (
                    @schema,
                    N'<table_name>',
                    @destination_table
                );

        EXECUTE sys.sp_executesql
            @schema;

        /* Optional: clustered index and/or compression on the (still empty) daily table */
        IF @CreateClusteredIndex = 1
        BEGIN
            SET @ddl =
                N'CREATE CLUSTERED INDEX ' +
                QUOTENAME(N'cx_' + @table_name) +
                N' ON ' + @local_table + N' (collection_time)' +
                N' WITH (DATA_COMPRESSION = ' + @DataCompression + N');';

            EXECUTE sys.sp_executesql
                @ddl;
        END;
        ELSE IF @DataCompression <> N'NONE'
        BEGIN
            SET @ddl =
                N'ALTER TABLE ' + @local_table +
                N' REBUILD WITH (DATA_COMPRESSION = ' + @DataCompression + N');';

            EXECUTE sys.sp_executesql
                @ddl;
        END;
    END;

    /*
    This logs to the table.
    */
    EXECUTE @whoisactive
        @get_transaction_info = 1,
        @get_outer_command = 1,
        @get_plans = 1,
        @get_task_info = 2,
        @get_additional_info = 1,
        @find_block_leaders = 1,
        @get_memory_info = 1,
        @destination_table = @destination_table;

    /*Execute this to prune tables*/
    EXECUTE dbo.sp_WhoIsActiveLogging_Retention
        @RetentionPeriod = @RetentionPeriod;

    /*Execute this to create views*/
    EXECUTE dbo.sp_WhoIsActiveLogging_CreateViews;
END;
GO


/*------------------------------------------------------------------------------
 4. SQL Agent job in msdb   (Erik's file 04 - same job/step/schedule/category)
    No USE msdb: everything is called with msdb.dbo.* three-part names, so the
    script keeps a single USE at the top. Job step runs in the target database.
------------------------------------------------------------------------------*/
DECLARE
    @ReturnCode           int = 0,
    @jobId                binary(16),
    @target_db            sysname = DB_NAME(),
    @active_start_date    int = CONVERT(int, CONVERT(varchar(8), GETDATE(), 112)),
    @schedule_uid         nvarchar(36) = CONVERT(nvarchar(36), NEWID()),
    @job_name             sysname,
    @job_owner            sysname,
    @job_enabled          tinyint,
    @every_minutes        int,
    @replace_job          bit,
    @retention            int,
    @compression          nvarchar(4),
    @create_ci            bit,
    @command              nvarchar(MAX),
    @schedule_name        sysname,
    @msg                  nvarchar(2048);

SELECT
    @job_name      = c.JobName,
    @job_owner     = ISNULL(c.JobOwner, SUSER_SNAME(0x01)),
    @job_enabled   = c.JobEnabled,
    @every_minutes = c.ScheduleEveryMinutes,
    @replace_job   = c.ReplaceExistingJob,
    @retention     = c.RetentionDays,
    @compression   = UPPER(c.DataCompression),
    @create_ci     = c.CreateClusteredIndex
FROM #wia_config AS c;

SELECT
    @command =
        N'EXECUTE dbo.sp_WhoIsActiveLogging_Main' + NCHAR(13) + NCHAR(10) +
        N'    @RetentionPeriod = ' + CONVERT(nvarchar(10), @retention) + N',' + NCHAR(13) + NCHAR(10) +
        N'    @DataCompression = N''' + @compression + N''',' + NCHAR(13) + NCHAR(10) +
        N'    @CreateClusteredIndex = ' + CONVERT(nchar(1), @create_ci) + N';',
    @schedule_name =
        CASE
            WHEN @every_minutes = 1
            THEN N'Log sp_WhoIsActive To A Daily Table Every Minute'
            ELSE N'Log sp_WhoIsActive To A Daily Table Every ' + CONVERT(nvarchar(10), @every_minutes) + N' Minutes'
        END;

/* Existing job? Replace (history kept) or leave it alone */
IF EXISTS (SELECT 1/0 FROM msdb.dbo.sysjobs AS j WHERE j.name = @job_name)
BEGIN
    IF @replace_job = 1
    BEGIN
        EXECUTE msdb.dbo.sp_delete_job
            @job_name = @job_name,
            @delete_history = 0,
            @delete_unused_schedule = 1;

        SET @msg = N'Existing job [' + @job_name + N'] removed (history kept) and will be recreated.';
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
    END;
    ELSE
    BEGIN
        SET @msg = N'Job [' + @job_name + N'] already exists and ReplaceExistingJob = 0. Job left unchanged.';
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
        GOTO EndSave;
    END;
END;

BEGIN TRANSACTION;

IF NOT EXISTS
(
    SELECT
        1/0
    FROM msdb.dbo.syscategories
    WHERE name = N'Data Collector'
    AND   category_class = 1
)
BEGIN
    EXECUTE @ReturnCode = msdb.dbo.sp_add_category
        @class = N'JOB',
        @type = N'LOCAL',
        @name = N'Data Collector';

    IF (@@ERROR <> 0 OR @ReturnCode <> 0)
        GOTO QuitWithRollback;
END;

EXECUTE @ReturnCode = msdb.dbo.sp_add_job
    @job_name = @job_name,
    @enabled = @job_enabled,
    @notify_level_eventlog = 0,
    @notify_level_email = 0,
    @notify_level_netsend = 0,
    @notify_level_page = 0,
    @delete_level = 0,
    @description = N'Copyright 2022 Darling Data, LLC
https://www.erikdarling.com/

This will log sp_WhoIsActive to a table.
It will create a new table every day,
so you don''t have a gigantic table to sift through
forever and ever or until your drive fills up.

If you need to get or update sp_WhoIsActive:
https://github.com/amachanic/sp_whoisactive
(C) 2007-2024, Adam Machanic

If you get an error message that @get_memory_info
isn''t a valid parameter, that''s a pretty good
sign you need to update.',
    @category_name = N'Data Collector',
    @owner_login_name = @job_owner,
    @job_id = @jobId OUTPUT;

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback;

EXECUTE @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId,
    @step_name = N'Log sp_WhoIsActive To A Daily Table',
    @step_id = 1,
    @cmdexec_success_code = 0,
    @on_success_action = 1,
    @on_success_step_id = 0,
    @on_fail_action = 2,
    @on_fail_step_id = 0,
    @retry_attempts = 0,
    @retry_interval = 0,
    @os_run_priority = 0,
    @subsystem = N'TSQL',
    @command = @command,
    @database_name = @target_db,     /* original: master */
    @flags = 0;

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback;

EXECUTE @ReturnCode = msdb.dbo.sp_update_job
    @job_id = @jobId,
    @start_step_id = 1;

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback;

EXECUTE @ReturnCode = msdb.dbo.sp_add_jobschedule
    @job_id = @jobId,
    @name = @schedule_name,
    @enabled = 1,
    @freq_type = 4,
    @freq_interval = 1,
    @freq_subday_type = 4,
    @freq_subday_interval = @every_minutes,
    @freq_relative_interval = 0,
    @freq_recurrence_factor = 0,
    @active_start_date = @active_start_date,
    @active_end_date = 99991231,
    @active_start_time = 0,
    @active_end_time = 235959,
    @schedule_uid = @schedule_uid;

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback;

EXECUTE @ReturnCode = msdb.dbo.sp_add_jobserver
    @job_id = @jobId,
    @server_name = N'(local)';

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback;

COMMIT TRANSACTION;

SET @msg = N'Job [' + @job_name + N'] created in msdb. Step database: ' + QUOTENAME(@target_db)
         + N', owner: ' + @job_owner + N', every ' + CONVERT(nvarchar(10), @every_minutes) + N' minute(s).';
RAISERROR(@msg, 0, 1) WITH NOWAIT;

GOTO EndSave;

QuitWithRollback:
    IF (@@TRANCOUNT > 0)
        ROLLBACK TRANSACTION;
    RAISERROR(N'SQL Agent job creation failed and was rolled back.', 16, 1) WITH NOWAIT;

EndSave:
GO


/*------------------------------------------------------------------------------
 5. Optional first collection + install summary
------------------------------------------------------------------------------*/
DECLARE
    @run bit,
    @retention int,
    @compression nvarchar(4),
    @create_ci bit;

SELECT
    @run         = c.RunFirstCollection,
    @retention   = c.RetentionDays,
    @compression = UPPER(c.DataCompression),
    @create_ci   = c.CreateClusteredIndex
FROM #wia_config AS c;

IF @run = 1
BEGIN
    EXECUTE dbo.sp_WhoIsActiveLogging_Main
        @RetentionPeriod = @retention,
        @DataCompression = @compression,
        @CreateClusteredIndex = @create_ci;
END;

SELECT
    database_name = DB_NAME(),
    object_name   = SCHEMA_NAME(o.schema_id) + N'.' + o.name,
    o.type_desc,
    o.create_date,
    o.modify_date
FROM sys.objects AS o
WHERE o.schema_id = SCHEMA_ID(N'dbo')
AND
(
      o.name = N'sp_WhoIsActive'
   OR o.name LIKE N'sp[_]WhoIsActiveLogging[_]%'
   OR o.name IN (N'WhoIsActive', N'WhoIsActive_blocking')
   OR o.name LIKE N'WhoIsActive[_][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%'
)
ORDER BY
    o.type_desc,
    o.name;

SELECT
    j.name,
    j.enabled,
    owner         = SUSER_SNAME(j.owner_sid),
    s.step_name,
    s.database_name,
    s.command,
    schedule_name = sc.name,
    sc.freq_subday_interval
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS s
  ON s.job_id = j.job_id
LEFT JOIN msdb.dbo.sysjobschedules AS js
  ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules AS sc
  ON sc.schedule_id = js.schedule_id
WHERE j.name = (SELECT c.JobName FROM #wia_config AS c);

DROP TABLE #wia_config;
GO

SET NOEXEC OFF;  /* always reset, also after an aborted install */
GO


/*------------------------------------------------------------------------------
 USAGE
--------------------------------------------------------------------------------
 -- everything logged (all retained days)
 SELECT TOP (100) * FROM dbo.WhoIsActive ORDER BY collection_time DESC;

 -- blocking chains
 SELECT * FROM dbo.WhoIsActive_blocking
 WHERE collection_time >= DATEADD(HOUR, -1, GETDATE());

 -- manual run / custom retention
 EXECUTE dbo.sp_WhoIsActiveLogging_Main @RetentionPeriod = 30;
 EXECUTE dbo.sp_WhoIsActiveLogging_Retention @RetentionPeriod = 15;
 EXECUTE dbo.sp_WhoIsActiveLogging_CreateViews;

--------------------------------------------------------------------------------
 UNINSTALL
--------------------------------------------------------------------------------
 Use Uninstall_sp_WhoIsActiveLogging.sql (same folder): removes the job, views,
 procedures, daily tables and dbo.sp_WhoIsActive, with a WhatIf dry-run mode.
 Or: .\Deploy-WhoIsActiveLogging.ps1 -SqlInstance <server> -Action Uninstall
------------------------------------------------------------------------------*/
