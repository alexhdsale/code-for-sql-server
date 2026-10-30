/*
================================================================================
 sp_WhoIsActive + sp_WhoIsActive Logging - single-file UNINSTALLER
 (companion to Install_sp_WhoIsActiveLogging.sql)
================================================================================

 WHAT THIS SCRIPT REMOVES (each part can be switched off in #wia_uninstall)
   msdb:
     - SQL Agent job(s): the job named in JobName, plus any job whose step runs
       dbo.sp_WhoIsActiveLogging_Main in the target database (catches renamed
       jobs). A running job is stopped first. Job history is removed with it.
   Target database (dbo schema only):
     - views       dbo.WhoIsActive_blocking, dbo.WhoIsActive
     - procedures  dbo.sp_WhoIsActiveLogging_Main
                   dbo.sp_WhoIsActiveLogging_Retention
                   dbo.sp_WhoIsActiveLogging_CreateViews
     - tables      dbo.WhoIsActive_YYYYMMDD   (ALL LOGGED DATA)
     - procedure   dbo.sp_WhoIsActive         (see safety check below)

 NOT REMOVED
   - The target database itself.
   - master.dbo.sp_WhoIsActive or a copy in any other database.
   - The 'Data Collector' job category (built-in name, other jobs may use it).

 SAFETY
   - Refuses to run in master / model / msdb / tempdb (also catches a failed USE).
   - dbo.sp_WhoIsActive is kept if anything else still uses it: another module
     in this database, or another SQL Agent job step that mentions it.
   - WhatIf = 1 lists every action without changing anything.
   - Each action runs on its own with TRY/CATCH and a 30 s lock timeout; one
     failure does not stop the others. A result grid shows what happened.
   - Re-runnable: objects that are already gone are skipped.

 HOW TO USE
   1. Set the database in the USE statement below - the SAME one you installed into.
   2. Optionally adjust #wia_uninstall (e.g. KeepDailyTables = 1 to keep the data,
      WhatIf = 1 for a dry run).
   3. Run the whole script (F5) as sysadmin.

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
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

/* ===================== TARGET DATABASE - CHANGE HERE ONLY ===================== */
USE [Utility];
GO
/* ============================================================================== */


/*------------------------------------------------------------------------------
 OPTIONS
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'tempdb..#wia_uninstall') IS NOT NULL
    DROP TABLE #wia_uninstall;

CREATE TABLE #wia_uninstall
(
    WhatIf            bit     NOT NULL,  /* 1 = dry run: list actions only */
    JobName           sysname NOT NULL,  /* job name used at install time */
    RemoveJob         bit     NOT NULL,
    KeepDailyTables   bit     NOT NULL,  /* 1 = keep dbo.WhoIsActive_YYYYMMDD data tables */
    RemoveWhoIsActive bit     NOT NULL   /* 1 = drop dbo.sp_WhoIsActive in this DB (if unused elsewhere) */
);

INSERT #wia_uninstall
(
    WhatIf, JobName, RemoveJob, KeepDailyTables, RemoveWhoIsActive
)
VALUES
(
    0,                                        /* WhatIf            */
    N'Log sp_WhoIsActive To A Daily Table',   /* JobName           */
    1,                                        /* RemoveJob         */
    0,                                        /* KeepDailyTables   */
    1                                         /* RemoveWhoIsActive */
);
GO


/*------------------------------------------------------------------------------
 UNINSTALL
------------------------------------------------------------------------------*/
DECLARE
    @db                  sysname = DB_NAME(),
    @what_if             bit,
    @job_name            sysname,
    @remove_job          bit,
    @keep_tables         bit,
    @remove_wia          bit,
    @msg                 nvarchar(2048),
    @seq                 int,
    @action              nvarchar(400),
    @sql                 nvarchar(MAX),
    @job_id              uniqueidentifier,
    @waited              int,
    @wia_users           nvarchar(MAX);

SELECT
    @what_if     = u.WhatIf,
    @job_name    = u.JobName,
    @remove_job  = u.RemoveJob,
    @keep_tables = u.KeepDailyTables,
    @remove_wia  = u.RemoveWhoIsActive
FROM #wia_uninstall AS u;

IF @db IN (N'master', N'model', N'msdb', N'tempdb')
BEGIN
    SET @msg = N'Current database is ' + @db + N'. Either the USE statement failed (database does not exist?) '
             + N'or it points to a system database. Nothing was removed.';
    RAISERROR(@msg, 16, 1) WITH NOWAIT;
    RETURN;
END;

SET @msg = N'Uninstalling sp_WhoIsActive Logging from ' + QUOTENAME(@db)
         + CASE WHEN @what_if = 1 THEN N'  ** WHATIF - nothing will be changed **' ELSE N'' END;
RAISERROR(@msg, 0, 1) WITH NOWAIT;

CREATE TABLE #actions
(
    seq        int IDENTITY(1, 1) PRIMARY KEY,
    action     nvarchar(400) NOT NULL,
    job_id     uniqueidentifier NULL,     /* set for job actions */
    sql_text   nvarchar(MAX) NULL,        /* set for DROP actions */
    result     nvarchar(2048) NULL
);

/* ---------- 1. SQL Agent jobs (first, so nothing recreates tables mid-uninstall) ---------- */
IF @remove_job = 1
BEGIN
    INSERT #actions (action, job_id)
    SELECT
        N'Delete SQL Agent job ' + QUOTENAME(j.name),
        j.job_id
    FROM msdb.dbo.sysjobs AS j
    WHERE j.name = @job_name
    OR EXISTS
       (
           SELECT 1/0
           FROM msdb.dbo.sysjobsteps AS s
           WHERE s.job_id = j.job_id
           AND   s.database_name = @db
           AND   s.command LIKE N'%sp[_]WhoIsActiveLogging[_]Main%'
       );
END;

/* ---------- 2. Views ---------- */
INSERT #actions (action, sql_text)
SELECT
    N'Drop view dbo.' + v.name,
    N'DROP VIEW dbo.' + QUOTENAME(v.name) + N';'
FROM (VALUES (1, N'WhoIsActive_blocking'), (2, N'WhoIsActive')) AS x (ord, name)
JOIN sys.views AS v
  ON  v.name = x.name
  AND v.schema_id = SCHEMA_ID(N'dbo')
ORDER BY
    x.ord;

/* ---------- 3. Logging procedures ---------- */
INSERT #actions (action, sql_text)
SELECT
    N'Drop procedure dbo.' + p.name,
    N'DROP PROCEDURE dbo.' + QUOTENAME(p.name) + N';'
FROM (VALUES (1, N'sp_WhoIsActiveLogging_Main'),
             (2, N'sp_WhoIsActiveLogging_Retention'),
             (3, N'sp_WhoIsActiveLogging_CreateViews')) AS x (ord, name)
JOIN sys.procedures AS p
  ON  p.name = x.name
  AND p.schema_id = SCHEMA_ID(N'dbo')
ORDER BY
    x.ord;

/* ---------- 4. Daily data tables ---------- */
IF @keep_tables = 0
BEGIN
    INSERT #actions (action, sql_text)
    SELECT
        N'Drop table dbo.' + t.name
          + N' (' + CONVERT(nvarchar(20), ISNULL(r.row_count, 0)) + N' rows)',
        N'DROP TABLE dbo.' + QUOTENAME(t.name) + N';'
    FROM sys.tables AS t
    OUTER APPLY
    (
        SELECT row_count = SUM(ps.row_count)
        FROM sys.dm_db_partition_stats AS ps
        WHERE ps.object_id = t.object_id
        AND   ps.index_id IN (0, 1)
    ) AS r
    WHERE t.schema_id = SCHEMA_ID(N'dbo')
    AND   t.name LIKE N'WhoIsActive[_][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%'
    ORDER BY
        t.name;
END;

/* ---------- 5. dbo.sp_WhoIsActive (only if nothing else uses it) ---------- */
IF @remove_wia = 1
AND OBJECT_ID(N'dbo.sp_WhoIsActive', N'P') IS NOT NULL
BEGIN
    /* other modules in this DB that reference it (our own logging procs excluded) */
    SELECT
        @wia_users =
            STUFF
            (
                (
                    SELECT
                        N', ' + OBJECT_SCHEMA_NAME(d.referencing_id) + N'.' + OBJECT_NAME(d.referencing_id)
                    FROM sys.sql_expression_dependencies AS d
                    WHERE d.referenced_entity_name = N'sp_WhoIsActive'
                    AND   OBJECT_NAME(d.referencing_id) NOT IN
                          (N'sp_WhoIsActiveLogging_Main',
                           N'sp_WhoIsActiveLogging_Retention',
                           N'sp_WhoIsActiveLogging_CreateViews',
                           N'sp_WhoIsActive')
                    GROUP BY
                        d.referencing_id
                    FOR XML PATH(N''), TYPE
                ).value('./text()[1]', 'nvarchar(max)'),
                1, 2, N''
            );

    /* other SQL Agent job steps that call sp_WhoIsActive in this DB (jobs being removed excluded) */
    SELECT
        @wia_users =
            CONCAT
            (
                @wia_users + N'; ',
                STUFF
                (
                    (
                        SELECT
                            N', job ' + QUOTENAME(j.name)
                        FROM msdb.dbo.sysjobs AS j
                        WHERE NOT EXISTS (SELECT 1/0 FROM #actions AS a WHERE a.job_id = j.job_id)
                        AND EXISTS
                            (
                                SELECT 1/0
                                FROM msdb.dbo.sysjobsteps AS s
                                WHERE s.job_id = j.job_id
                                AND   s.command LIKE N'%sp[_]WhoIsActive%'
                                AND   (s.database_name = @db OR s.command LIKE N'%' + @db + N'%')
                            )
                        FOR XML PATH(N''), TYPE
                    ).value('./text()[1]', 'nvarchar(max)'),
                    1, 2, N''
                )
            );

    IF NULLIF(@wia_users, N'') IS NULL
    BEGIN
        INSERT #actions (action, sql_text)
        VALUES
        (
            N'Drop procedure dbo.sp_WhoIsActive',
            N'DROP PROCEDURE dbo.sp_WhoIsActive;'
        );
    END;
    ELSE
    BEGIN
        INSERT #actions (action, result)
        VALUES
        (
            N'KEEP procedure dbo.sp_WhoIsActive',
            N'Skipped - still used by: ' + @wia_users
        );
    END;
END;

IF OBJECT_ID(N'master.dbo.sp_WhoIsActive', N'P') IS NOT NULL
BEGIN
    INSERT #actions (action, result)
    VALUES (N'master.dbo.sp_WhoIsActive', N'Left untouched (not part of this install)');
END;

/* ---------- Execute ---------- */
SET LOCK_TIMEOUT 30000;

DECLARE actions CURSOR LOCAL FAST_FORWARD FOR
    SELECT a.seq, a.action, a.job_id, a.sql_text
    FROM #actions AS a
    WHERE a.result IS NULL
    ORDER BY a.seq;

OPEN actions;
FETCH NEXT FROM actions INTO @seq, @action, @job_id, @sql;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @what_if = 1
    BEGIN
        UPDATE #actions SET result = N'WhatIf - would run' WHERE seq = @seq;
    END;
    ELSE
    BEGIN
        BEGIN TRY
            IF @job_id IS NOT NULL
            BEGIN
                /* stop the job if it is running right now */
                IF EXISTS
                (
                    SELECT 1/0
                    FROM msdb.dbo.sysjobactivity AS ja
                    WHERE ja.job_id = @job_id
                    AND   ja.session_id = (SELECT MAX(s.session_id) FROM msdb.dbo.syssessions AS s)
                    AND   ja.start_execution_date IS NOT NULL
                    AND   ja.stop_execution_date IS NULL
                )
                BEGIN
                    EXECUTE msdb.dbo.sp_stop_job @job_id = @job_id;

                    SET @waited = 0;
                    WHILE @waited < 30
                    AND EXISTS
                    (
                        SELECT 1/0
                        FROM msdb.dbo.sysjobactivity AS ja
                        WHERE ja.job_id = @job_id
                        AND   ja.session_id = (SELECT MAX(s.session_id) FROM msdb.dbo.syssessions AS s)
                        AND   ja.start_execution_date IS NOT NULL
                        AND   ja.stop_execution_date IS NULL
                    )
                    BEGIN
                        WAITFOR DELAY '00:00:01';
                        SET @waited += 1;
                    END;
                END;

                EXECUTE msdb.dbo.sp_delete_job
                    @job_id = @job_id,
                    @delete_history = 1,
                    @delete_unused_schedule = 1;
            END;
            ELSE
            BEGIN
                EXECUTE sys.sp_executesql @sql;
            END;

            UPDATE #actions SET result = N'Done' WHERE seq = @seq;
        END TRY
        BEGIN CATCH
            UPDATE #actions
            SET result = N'FAILED - Msg ' + CONVERT(nvarchar(10), ERROR_NUMBER()) + N': ' + ERROR_MESSAGE()
            WHERE seq = @seq;
        END CATCH;
    END;

    SET @msg = @action + N' -> ' + (SELECT a.result FROM #actions AS a WHERE a.seq = @seq);
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    FETCH NEXT FROM actions INTO @seq, @action, @job_id, @sql;
END;

CLOSE actions;
DEALLOCATE actions;

SET LOCK_TIMEOUT -1;

/* ---------- Summary ---------- */
IF NOT EXISTS (SELECT 1/0 FROM #actions)
BEGIN
    RAISERROR(N'Nothing to remove - sp_WhoIsActive Logging is not installed here.', 0, 1) WITH NOWAIT;
END;

SELECT
    database_name = @db,
    a.seq,
    a.action,
    a.result
FROM #actions AS a
ORDER BY
    a.seq;

IF EXISTS (SELECT 1/0 FROM #actions AS a WHERE a.result LIKE N'FAILED%')
BEGIN
    RAISERROR(N'Uninstall finished with errors - see the result grid. Fix and re-run; finished steps are skipped.', 16, 1) WITH NOWAIT;
END;
ELSE IF @what_if = 0
BEGIN
    RAISERROR(N'Uninstall complete.', 0, 1) WITH NOWAIT;
END;

/* What is left behind (should be empty, apart from kept data tables / a kept sp_WhoIsActive) */
SELECT
    remaining_object = SCHEMA_NAME(o.schema_id) + N'.' + o.name,
    o.type_desc
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

DROP TABLE #actions;
DROP TABLE #wia_uninstall;
GO
