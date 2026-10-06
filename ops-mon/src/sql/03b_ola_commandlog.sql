
/* ---------------------------------------------------------------------------
   What an Ola CommandLog error actually means:
     CORRUPTION - DBCC CHECK* COMPLETED and REPORTED consistency/allocation errors
                  (the check worked - the database is damaged)
     SKIPPED    - command could not run: lock timeout (1222) / deadlock victim (1205)
     FAILED     - anything else (backup failed, CHECKDB could not run, ...)
     OK         - ErrorNumber 0
   --------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION mon.fn_OlaOutcome(@command_type nvarchar(60), @error_number int)
RETURNS varchar(12)
AS
BEGIN
    RETURN CASE
        WHEN ISNULL(@error_number, 0) = 0 THEN 'OK'
        WHEN @command_type LIKE N'DBCC[_]CHECK%'
             AND (@error_number BETWEEN 2500 AND 2599 OR @error_number BETWEEN 7900 AND 7999
                  OR @error_number BETWEEN 8900 AND 8999 OR @error_number IN (823, 824, 825, 5250))
            THEN 'CORRUPTION'
        WHEN @error_number IN (1222, 1205) THEN 'SKIPPED'
        ELSE 'FAILED' END;
END;
GO

/* ---------------------------------------------------------------------------
   OLA HALLENGREN COMMANDLOG COLLECTOR   [rev 5.2]
   Finds dbo.CommandLog (setting ola_commandlog_database, or auto-discovery in every
   online database + master), imports new rows incrementally and re-reads rows that
   were still running (EndTime NULL) so their outcome is captured.
   Parses BACKUP commands: backup type (FULL/DIFF/LOG), target file and number of files.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectOlaCommandLog
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;   /* never block Ola while it writes its log */

    DECLARE @started datetime2(3) = SYSUTCDATETIME(), @now datetime2(0) = SYSUTCDATETIME(),
            @cfg sysname = NULLIF(LTRIM(RTRIM(mon.fn_Setting('ola_commandlog_database'))), N''),
            @init_days int = ISNULL(mon.fn_SettingInt('ola_initial_load_days'), 35),
            @db sysname, @from_id bigint, @sql nvarchar(max), @errors nvarchar(2000) = NULL;

    BEGIN TRY
        /* ---- discovery (hourly, or immediately when configured explicitly) ---- */
        IF @cfg IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM mon.OlaSource WHERE database_name = @cfg)
                INSERT mon.OlaSource(database_name) VALUES (@cfg);
            UPDATE mon.OlaSource SET is_active = CASE WHEN database_name = @cfg THEN 1 ELSE 0 END;
        END
        ELSE
            UPDATE mon.OlaSource SET is_active = 0
            WHERE database_name NOT IN (SELECT name FROM sys.databases WHERE state_desc = N'ONLINE');

        IF @cfg IS NULL AND NOT EXISTS (SELECT 1 FROM mon.ComponentStatus WHERE component_name = 'OLA_DISCOVERY'
                            AND last_success_utc > DATEADD(HOUR, -1, SYSUTCDATETIME()))
        BEGIN
            DECLARE d CURSOR LOCAL FAST_FORWARD FOR
                SELECT name FROM sys.databases
                WHERE state_desc = N'ONLINE' AND (database_id > 4 OR name = N'master')
                  AND name NOT IN (N'rdsadmin', N'tempdb', N'model') AND source_database_id IS NULL;
            OPEN d;
            FETCH NEXT FROM d INTO @db;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF OBJECT_ID(QUOTENAME(@db) + N'.dbo.CommandLog', N'U') IS NOT NULL
                   AND COL_LENGTH(QUOTENAME(@db) + N'.dbo.CommandLog', N'CommandType') IS NOT NULL
                BEGIN
                    IF NOT EXISTS (SELECT 1 FROM mon.OlaSource WHERE database_name = @db)
                        INSERT mon.OlaSource(database_name) VALUES (@db);
                    ELSE
                        UPDATE mon.OlaSource SET is_active = 1 WHERE database_name = @db;
                END
                ELSE
                    UPDATE mon.OlaSource SET is_active = 0 WHERE database_name = @db;
                FETCH NEXT FROM d INTO @db;
            END;
            CLOSE d;
            DEALLOCATE d;
            EXEC mon.usp_SetComponentStatus 'OLA_DISCOVERY', 1, NULL;
        END;

        /* ---- incremental import ---- */
        CREATE TABLE #C
        (
            ola_id bigint PRIMARY KEY, database_name sysname COLLATE DATABASE_DEFAULT NULL,
            command_type nvarchar(60) COLLATE DATABASE_DEFAULT, object_name nvarchar(300) COLLATE DATABASE_DEFAULT NULL,
            index_name sysname COLLATE DATABASE_DEFAULT NULL, statistics_name sysname COLLATE DATABASE_DEFAULT NULL,
            command nvarchar(max) COLLATE DATABASE_DEFAULT NULL, start_time datetime2(3), end_time datetime2(3) NULL,
            error_number int NULL, error_message nvarchar(2000) COLLATE DATABASE_DEFAULT NULL
        );

        DECLARE s CURSOR LOCAL FAST_FORWARD FOR SELECT database_name FROM mon.OlaSource WHERE is_active = 1;
        OPEN s;
        FETCH NEXT FROM s INTO @db;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                TRUNCATE TABLE #C;
                /* restart point: oldest still-running command of the last 2 days, else the high-water mark */
                SET @from_id = ISNULL((SELECT MIN(ola_id) - 1 FROM mon.OlaCommand
                                       WHERE source_db = @db AND end_utc IS NULL
                                         AND start_utc > DATEADD(DAY, -2, @now)),
                                      (SELECT last_id FROM mon.OlaSource WHERE database_name = @db));

                SET @sql = N'
                    SELECT c.ID, c.DatabaseName, c.CommandType,
                           CASE WHEN c.ObjectName IS NOT NULL THEN CONCAT(c.SchemaName, N''.'', c.ObjectName) END,
                           c.IndexName, c.StatisticsName, c.Command, c.StartTime, c.EndTime, c.ErrorNumber,
                           LEFT(c.ErrorMessage, 2000)
                    FROM ' + QUOTENAME(@db) + N'.dbo.CommandLog AS c
                    WHERE c.ID > @from_id
                      AND c.StartTime >= DATEADD(DAY, -@init_days, GETDATE());';
                INSERT #C EXEC sys.sp_executesql @sql, N'@from_id bigint, @init_days int', @from_id = @from_id, @init_days = @init_days;

                ;WITH P AS
                (
                    SELECT c.*,
                           UPPER(REPLACE(REPLACE(REPLACE(c.command, NCHAR(13), N' '), NCHAR(10), N' '), NCHAR(9), N' ')) AS u
                    FROM #C AS c
                ), Q AS
                (
                    SELECT P.*,
                           CASE WHEN P.command_type LIKE N'BACKUP[_]LOG%' OR P.u LIKE N'%BACKUP LOG%' THEN 'LOG'
                                WHEN P.command_type LIKE N'BACKUP%' AND P.u LIKE N'%DIFFERENTIAL%' THEN 'DIFF'
                                WHEN P.command_type LIKE N'BACKUP%' THEN 'FULL' END AS btype,
                           CHARINDEX(N'DISK = N''', P.u) AS p_disk,
                           CHARINDEX(N'URL = N''', P.u) AS p_url,
                           (LEN(P.u) - LEN(REPLACE(P.u, N'DISK = N''', N''))) / 9
                         + (LEN(P.u) - LEN(REPLACE(P.u, N'URL = N''', N''))) / 8 AS n_files
                    FROM P
                )
                MERGE mon.OlaCommand AS t
                USING
                (
                    SELECT Q.ola_id, Q.database_name, Q.command_type, Q.object_name, Q.index_name, Q.statistics_name,
                           LEFT(Q.command, 4000) AS command,
                           CASE WHEN Q.command_type LIKE N'BACKUP%' THEN Q.btype END AS backup_type,
                           CASE WHEN Q.command_type LIKE N'BACKUP%' AND (Q.p_disk > 0 OR Q.p_url > 0) THEN
                                LEFT(SUBSTRING(Q.command,
                                               CASE WHEN Q.p_disk > 0 THEN Q.p_disk + 9 ELSE Q.p_url + 8 END,
                                               ISNULL(NULLIF(CHARINDEX(N'''', Q.command,
                                                   CASE WHEN Q.p_disk > 0 THEN Q.p_disk + 9 ELSE Q.p_url + 8 END), 0), LEN(Q.command) + 1)
                                               - CASE WHEN Q.p_disk > 0 THEN Q.p_disk + 9 ELSE Q.p_url + 8 END), 1000) END AS backup_file,
                           CASE WHEN Q.command_type LIKE N'BACKUP%' THEN NULLIF(Q.n_files, 0) END AS file_count,
                           CONVERT(datetime2(0), mon.fn_ServerToUtc(Q.start_time)) AS start_utc,
                           CONVERT(datetime2(0), mon.fn_ServerToUtc(Q.end_time)) AS end_utc,
                           DATEDIFF(SECOND, Q.start_time, Q.end_time) AS duration_s,
                           Q.error_number, Q.error_message
                    FROM Q
                ) AS x
                ON t.source_db = @db AND t.ola_id = x.ola_id
                WHEN MATCHED AND (t.end_utc IS NULL OR ISNULL(t.error_number, -1) <> ISNULL(x.error_number, -1)) THEN UPDATE SET
                    end_utc = x.end_utc, duration_s = x.duration_s, error_number = x.error_number,
                    error_message = x.error_message, collected_utc = @now
                WHEN NOT MATCHED THEN INSERT
                    (source_db, ola_id, database_name, command_type, object_name, index_name, statistics_name, command,
                     backup_type, backup_file, file_count, start_utc, end_utc, duration_s, error_number, error_message)
                VALUES
                    (@db, x.ola_id, x.database_name, x.command_type, x.object_name, x.index_name, x.statistics_name, x.command,
                     x.backup_type, x.backup_file, x.file_count, x.start_utc, x.end_utc, x.duration_s, x.error_number, x.error_message);

                UPDATE mon.OlaSource
                   SET last_id = CASE WHEN (SELECT MAX(ola_id) FROM #C) > last_id THEN (SELECT MAX(ola_id) FROM #C) ELSE last_id END,
                       last_read_utc = @now
                 WHERE database_name = @db;
            END TRY
            BEGIN CATCH
                SET @errors = LEFT(CONCAT(@errors, N' ', @db, N': ', ERROR_MESSAGE()), 2000);
            END CATCH;
            FETCH NEXT FROM s INTO @db;
        END;
        CLOSE s;
        DEALLOCATE s;

        IF @errors IS NULL
            EXEC mon.usp_SetComponentStatus 'OLA_COMMANDLOG', 1, @started;
        ELSE
            EXEC mon.usp_SetComponentStatus 'OLA_COMMANDLOG', 0, @started, 50004, @errors;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'OLA_COMMANDLOG', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* Ola maintenance overview for SSMS. */
CREATE OR ALTER PROCEDURE mon.usp_ShowOlaLog
    @Hours    int = 24,
    @Database sysname = N'%'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @since datetime2(0) = DATEADD(HOUR, -@Hours, SYSUTCDATETIME()),
            @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');

    /* 1. Summary per command type */
    SELECT o.command_type AS [Command type], COUNT(*) AS [Commands],
           SUM(CASE WHEN mon.fn_OlaOutcome(o.command_type, o.error_number) = 'CORRUPTION' THEN 1 ELSE 0 END) AS [Corruption found],
           SUM(CASE WHEN mon.fn_OlaOutcome(o.command_type, o.error_number) = 'FAILED' THEN 1 ELSE 0 END) AS [Failed],
           SUM(CASE WHEN mon.fn_OlaOutcome(o.command_type, o.error_number) = 'SKIPPED' THEN 1 ELSE 0 END) AS [Skipped (lock)],
           SUM(CASE WHEN o.end_utc IS NULL THEN 1 ELSE 0 END) AS [Running / unfinished],
           mon.fn_Duration(SUM(CONVERT(bigint, o.duration_s))) AS [Total time],
           mon.fn_Duration(MAX(o.duration_s)) AS [Longest],
           COUNT(DISTINCT o.database_name) AS [Databases],
           SUM(ISNULL(o.file_count, 0)) AS [Backup files],
           mon.fn_UtcToLocal(MAX(o.start_utc), @tz) AS [Last start (local)]
    FROM mon.OlaCommand AS o
    WHERE o.start_utc >= @since AND ISNULL(o.database_name, N'') LIKE @Database
    GROUP BY o.command_type
    ORDER BY [Corruption found] DESC, [Failed] DESC, o.command_type;

    /* 2. Failures */
    SELECT mon.fn_UtcToLocal(o.start_utc, @tz) AS [Start (local)], mon.fn_OlaOutcome(o.command_type, o.error_number) AS [Outcome],
           o.database_name AS [Database], o.command_type AS [Type],
           o.object_name AS [Object], o.index_name AS [Index], o.error_number AS [Error], o.error_message AS [Message],
           o.command AS [Command], o.source_db AS [CommandLog in]
    FROM mon.OlaCommand AS o
    WHERE o.start_utc >= @since AND ISNULL(o.error_number, 0) <> 0 AND ISNULL(o.database_name, N'') LIKE @Database
    ORDER BY o.start_utc DESC;

    /* 3. Last successful CHECKDB / FULL / DIFF / LOG per database according to Ola */
    SELECT o.database_name AS [Database],
           mon.fn_UtcToLocal(MAX(CASE WHEN o.command_type = N'DBCC_CHECKDB' THEN o.end_utc END), @tz) AS [Last CHECKDB ok],
           mon.fn_Duration(MAX(CASE WHEN o.command_type = N'DBCC_CHECKDB' THEN o.duration_s END)) AS [Longest CHECKDB],
           mon.fn_UtcToLocal(MAX(CASE WHEN o.backup_type = 'FULL' THEN o.end_utc END), @tz) AS [Last FULL ok],
           mon.fn_UtcToLocal(MAX(CASE WHEN o.backup_type = 'DIFF' THEN o.end_utc END), @tz) AS [Last DIFF ok],
           mon.fn_UtcToLocal(MAX(CASE WHEN o.backup_type = 'LOG'  THEN o.end_utc END), @tz) AS [Last LOG ok],
           SUM(CASE WHEN o.command_type IN (N'ALTER_INDEX') THEN 1 ELSE 0 END) AS [Index ops],
           SUM(CASE WHEN o.command_type IN (N'UPDATE_STATISTICS') THEN 1 ELSE 0 END) AS [Stats updates]
    FROM mon.OlaCommand AS o
    WHERE ISNULL(o.error_number, 0) = 0 AND o.end_utc IS NOT NULL AND o.database_name LIKE @Database
    GROUP BY o.database_name
    ORDER BY o.database_name;

    /* 4. Where the CommandLog was found */
    SELECT database_name AS [CommandLog database], is_active AS [Active], last_id AS [Last ID read],
           mon.fn_UtcToLocal(last_read_utc, @tz) AS [Last read (local)]
    FROM mon.OlaSource;
END;
GO
