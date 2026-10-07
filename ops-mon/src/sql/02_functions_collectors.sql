
/* =============================================================================
   SECTION 4  -  HELPER FUNCTIONS  (formatting, time, HTML building blocks)
   All HTML is inline-styled and table-based for Outlook desktop (Word engine),
   Outlook web/mobile, Gmail and Apple Mail. The file is pure ASCII on purpose:
   special characters are emitted as HTML entities.
   ============================================================================= */

CREATE OR ALTER FUNCTION mon.fn_Setting(@name varchar(64))
RETURNS nvarchar(4000)
AS
BEGIN
    RETURN (SELECT s.setting_value FROM mon.Setting AS s WHERE s.setting_name = @name);
END;
GO

CREATE OR ALTER FUNCTION mon.fn_SettingInt(@name varchar(64))
RETURNS int
AS
BEGIN
    RETURN (SELECT TRY_CONVERT(int, s.setting_value) FROM mon.Setting AS s WHERE s.setting_name = @name);
END;
GO

CREATE OR ALTER FUNCTION mon.fn_ServerToUtc(@dt datetime2(3))
RETURNS datetime2(3)
AS
BEGIN
    /* Server-local (GETDATE-based) value -> UTC using the current server offset.
       RDS instances run in UTC unless a time zone was chosen at creation. */
    RETURN CASE WHEN @dt IS NULL THEN NULL
                ELSE DATEADD(MINUTE, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), @dt) END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_UtcToLocal(@utc datetime2(3), @tz nvarchar(100))
RETURNS datetime2(0)
AS
BEGIN
    RETURN CASE WHEN @utc IS NULL THEN NULL
                ELSE CONVERT(datetime2(0), (@utc AT TIME ZONE 'UTC') AT TIME ZONE @tz) END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_FmtLocal(@utc datetime2(3), @tz nvarchar(100))
RETURNS nvarchar(20)
AS
BEGIN
    /* 'MM-DD HH:MM' in the display time zone; 'YYYY-MM-DD' when older than 300 days (no ambiguous year). */
    RETURN CASE WHEN @utc IS NULL THEN N'never'
                WHEN @utc < DATEADD(DAY, -300, SYSUTCDATETIME())
                     THEN CONVERT(nvarchar(10), mon.fn_UtcToLocal(@utc, @tz), 120)
                ELSE SUBSTRING(CONVERT(nvarchar(16), mon.fn_UtcToLocal(@utc, @tz), 120), 6, 11) END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Duration(@seconds bigint)
RETURNS nvarchar(20)
AS
BEGIN
    IF @seconds IS NULL RETURN N'-';
    IF @seconds < 0 SET @seconds = 0;
    RETURN CASE
        WHEN @seconds < 60    THEN CONCAT(@seconds, N's')
        WHEN @seconds < 3600  THEN CONCAT(@seconds / 60, N'm')
        WHEN @seconds < 86400 THEN CONCAT(@seconds / 3600, N'h ', RIGHT(CONCAT(N'0', (@seconds % 3600) / 60), 2), N'm')
        ELSE CONCAT(@seconds / 86400, N'd ', RIGHT(CONCAT(N'0', (@seconds % 86400) / 3600), 2), N'h')
    END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_HtmlEncode(@value nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    IF @value IS NULL RETURN N'';
    SET @value = REPLACE(@value, N'&', N'&amp;');
    SET @value = REPLACE(@value, N'<', N'&lt;');
    SET @value = REPLACE(@value, N'>', N'&gt;');
    SET @value = REPLACE(@value, N'"', N'&quot;');
    SET @value = REPLACE(@value, N'''', N'&#39;');
    RETURN @value;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_OneLine(@value nvarchar(max), @max_len int)
RETURNS nvarchar(max)
AS
BEGIN
    /* Collapse whitespace of SQL text / messages and truncate, then HTML-encode. */
    IF @value IS NULL RETURN N'';
    SET @value = REPLACE(REPLACE(REPLACE(@value, NCHAR(13), N' '), NCHAR(10), N' '), NCHAR(9), N' ');
    WHILE CHARINDEX(N'  ', @value) > 0 SET @value = REPLACE(@value, N'  ', N' ');
    SET @value = LTRIM(RTRIM(@value));
    RETURN mon.fn_HtmlEncode(LEFT(@value, @max_len))
         + CASE WHEN LEN(@value) > @max_len THEN N'&#8230;' ELSE N'' END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_CleanAgentMessage(@m nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    /* Agent step output repeats harmless ANSI warnings (8153 'Null value is eliminated...') that hide
       the real error. Strip them so the message starts with what matters. */
    IF @m IS NULL RETURN NULL;
    SET @m = REPLACE(@m, N'Warning: Null value is eliminated by an aggregate or other SET operation. [SQLSTATE 01003] (Message 8153)', N'');
    SET @m = REPLACE(@m, N'Warning: Null value is eliminated by an aggregate or other SET operation.', N'');
    WHILE CHARINDEX(N'  ', @m) > 0 SET @m = REPLACE(@m, N'  ', N' ');
    RETURN LTRIM(RTRIM(@m));
END;
GO

CREATE OR ALTER FUNCTION mon.fn_SevLevel(@severity varchar(10))
RETURNS varchar(4)
AS
BEGIN
    RETURN CASE @severity WHEN 'CRITICAL' THEN 'CRIT' WHEN 'WARNING' THEN 'WARN' ELSE 'INFO' END;
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Pill(@text nvarchar(200), @level varchar(4))
RETURNS nvarchar(max)
AS
BEGIN
    /* Colored status badge. Levels: CRIT, WARN, OK, INFO, NA, MUTE */
    DECLARE @bg varchar(7), @fg varchar(7);
    SELECT @bg = CASE @level WHEN 'CRIT' THEN '#DC2626' WHEN 'WARN' THEN '#F59E0B' WHEN 'OK' THEN '#16A34A'
                              WHEN 'INFO' THEN '#2563EB' WHEN 'MUTE' THEN '#9CA3AF' ELSE '#E5E7EB' END,
           @fg = CASE @level WHEN 'WARN' THEN '#111827' WHEN 'NA' THEN '#374151' ELSE '#FFFFFF' END;
    RETURN CONCAT(N'<span style="display:inline-block;padding:1px 7px;border-radius:9px;font-size:10px;',
                  N'font-weight:700;letter-spacing:.3px;white-space:nowrap;background:', @bg, N';color:', @fg, N'">',
                  mon.fn_HtmlEncode(@text), N'</span>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Td(@html nvarchar(max), @level varchar(4))
RETURNS nvarchar(max)
AS
BEGIN
    /* Table cell. Base style comes from the td.c class in the email <style> block (keeps the
       digest under Gmail's ~102 KB clipping limit); anomalies add bgcolor (Outlook) + inline tint. */
    DECLARE @bg varchar(7) = CASE @level WHEN 'CRIT' THEN '#FEE2E2' WHEN 'WARN' THEN '#FEF3C7'
                                         WHEN 'OK' THEN '#F0FDF4' ELSE NULL END;
    IF @bg IS NULL
        RETURN CONCAT(CONVERT(nvarchar(max), N'<td class="c" valign="top">'), @html, N'</td>');
    RETURN CONCAT(CONVERT(nvarchar(max), N'<td class="c" valign="top" bgcolor="'), @bg, N'" style="background:', @bg,
                  N';color:', CASE @level WHEN 'CRIT' THEN '#7F1D1D' WHEN 'WARN' THEN '#78350F' ELSE '#14532D' END,
                  N'">', @html, N'</td>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Small(@html nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    RETURN CONCAT(CONVERT(nvarchar(max), N'<span style="font-size:11px;font-weight:400;color:#6B7280">'), @html, N'</span>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Nw(@html nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    /* no-wrap wrapper for short values (times, sizes) */
    RETURN CONCAT(CONVERT(nvarchar(max), N'<span style="white-space:nowrap">'), @html, N'</span>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_Section(@title nvarchar(200), @subtitle nvarchar(1000), @header_cells nvarchar(max), @rows nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    /* One titled table section of the email. @header_cells = pipe separated column names. */
    DECLARE @th nvarchar(max) = N'', @rest nvarchar(max) = @header_cells + N'|', @pos int, @col nvarchar(200);
    /* Ordered split without STRING_SPLIT (order not guaranteed, needs compat 130). */
    SET @pos = CHARINDEX(N'|', @rest);
    WHILE @pos > 0
    BEGIN
        SET @col = LTRIM(RTRIM(LEFT(@rest, @pos - 1)));
        SET @rest = SUBSTRING(@rest, @pos + 1, 4000);
        SET @th += N'<th class="h" align="left" bgcolor="#1E3A5F" style="color:#FFFFFF">' + mon.fn_HtmlEncode(@col) + N'</th>';
        SET @pos = CHARINDEX(N'|', @rest);
    END;

    RETURN CONCAT(
        N'<tr><td style="padding:18px 24px 4px 24px">',
        N'<div style="font-size:15px;font-weight:700;color:#0F172A;margin:0">', mon.fn_HtmlEncode(@title), N'</div>',
        CASE WHEN @subtitle IS NOT NULL AND @subtitle <> N''
             THEN CONCAT(N'<div style="font-size:11px;color:#6B7280;margin:2px 0 6px 0">', @subtitle, N'</div>')
             ELSE N'<div style="height:6px;line-height:6px;font-size:6px">&nbsp;</div>' END,
        N'<table role="presentation" width="100%" cellpadding="5" cellspacing="0" border="0" ',
        N'style="border-collapse:collapse;border:1px solid #E5E7EB;font-family:Segoe UI,Arial,Helvetica,sans-serif">',
        N'<tr>', @th, N'</tr>', @rows, N'</table></td></tr>');
END;
GO

CREATE OR ALTER FUNCTION mon.fn_EmptyRow(@colspan int, @text nvarchar(400))
RETURNS nvarchar(max)
AS
BEGIN
    RETURN CONCAT(CONVERT(nvarchar(max), N'<tr><td colspan="'), @colspan, N'" bgcolor="#F0FDF4" style="padding:8px;font-size:12px;color:#166534;background:#F0FDF4">',
                  N'&#10003; ', mon.fn_HtmlEncode(@text), N'</td></tr>');
END;
GO

/* =============================================================================
   SECTION 5  -  COMPONENT STATUS (self-monitoring of every collector)
   ============================================================================= */

CREATE OR ALTER PROCEDURE mon.usp_SetComponentStatus
    @Component    varchar(40),
    @Succeeded    bit,
    @StartedUtc   datetime2(3) = NULL,
    @ErrorNumber  int = NULL,
    @ErrorMessage nvarchar(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(3) = SYSUTCDATETIME();
    DECLARE @ms int = CASE WHEN @StartedUtc IS NULL THEN NULL ELSE DATEDIFF(MILLISECOND, @StartedUtc, @now) END;

    UPDATE mon.ComponentStatus
       SET last_attempt_utc     = @now,
           last_success_utc     = CASE WHEN @Succeeded = 1 THEN @now ELSE last_success_utc END,
           last_duration_ms     = @ms,
           consecutive_failures = CASE WHEN @Succeeded = 1 THEN 0 ELSE consecutive_failures + 1 END,
           last_error_number    = CASE WHEN @Succeeded = 1 THEN NULL ELSE @ErrorNumber END,
           last_error_message   = CASE WHEN @Succeeded = 1 THEN NULL ELSE LEFT(@ErrorMessage, 2000) END
     WHERE component_name = @Component;

    IF @@ROWCOUNT = 0
        INSERT mon.ComponentStatus(component_name, last_attempt_utc, last_success_utc, last_duration_ms,
                                   consecutive_failures, last_error_number, last_error_message)
        VALUES (@Component, @now, CASE WHEN @Succeeded = 1 THEN @now END, @ms,
                CASE WHEN @Succeeded = 1 THEN 0 ELSE 1 END,
                CASE WHEN @Succeeded = 0 THEN @ErrorNumber END,
                CASE WHEN @Succeeded = 0 THEN LEFT(@ErrorMessage, 2000) END);
END;
GO

/* =============================================================================
   SECTION 6  -  COLLECTORS
   Every collector is independent, runs with LOCK_TIMEOUT + DEADLOCK_PRIORITY LOW,
   records its own success/failure in mon.ComponentStatus and never throws to
   the engine. Version/RDS-specific objects are referenced through dynamic SQL
   so a missing object is a catchable runtime error, not a compile failure.
   ============================================================================= */

CREATE OR ALTER PROCEDURE mon.usp_SyncPolicies
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    BEGIN TRY
        /* New user databases get default policy; existing rows are never overwritten. */
        INSERT mon.DatabasePolicy
            (database_name, require_log, full_max_age_minutes, diff_max_age_minutes,
             log_max_age_minutes, checkdb_max_age_days)
        SELECT d.name,
               CASE WHEN d.recovery_model_desc = N'FULL' THEN 1 ELSE 0 END,
               ISNULL(mon.fn_SettingInt('full_max_age_minutes'), 1440),
               ISNULL(mon.fn_SettingInt('diff_max_age_minutes'), 360),
               ISNULL(mon.fn_SettingInt('log_max_age_minutes'), 30),
               ISNULL(mon.fn_SettingInt('checkdb_max_age_days'), 8)
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.name <> N'rdsadmin'
          AND d.source_database_id IS NULL
          AND NOT EXISTS (SELECT 1 FROM mon.DatabasePolicy AS p WHERE p.database_name = d.name);

        /* Check matrix row for every new database: all checks ON (edit mon.DatabaseCheck to opt out). */
        INSERT mon.DatabaseCheck(database_name)
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.name <> N'rdsadmin'
          AND d.source_database_id IS NULL
          AND NOT EXISTS (SELECT 1 FROM mon.DatabaseCheck AS c WHERE c.database_name = d.name);

        /* Standard Ola Hallengren + RDS native backup job discovery. Overrides preserved. */
        ;WITH J AS
        (
            SELECT j.job_id, j.name,
                   CASE
                       WHEN j.name LIKE N'DatabaseBackup%LOG%'        THEN 'BACKUP_LOG'
                       WHEN j.name LIKE N'DatabaseBackup%DIFF%'       THEN 'BACKUP_DIFF'
                       WHEN j.name LIKE N'DatabaseBackup%FULL%'       THEN 'BACKUP_FULL'
                       WHEN j.name LIKE N'DatabaseIntegrityCheck%'    THEN 'INTEGRITY_CHECK'
                       WHEN j.name LIKE N'IndexOptimize%'             THEN 'INDEX_OPTIMIZE'
                       WHEN j.name = N'DBMaintenance - Daily Backups' THEN 'RDS_NATIVE_BACKUP'
                       ELSE 'CLEANUP'
                   END AS job_type,
                   CONVERT(decimal(9,2),
                   CASE
                       WHEN j.name LIKE N'DatabaseBackup%LOG%'        THEN 0.5
                       WHEN j.name LIKE N'DatabaseBackup%DIFF%'       THEN 6
                       WHEN j.name LIKE N'DatabaseBackup%FULL%'       THEN 24
                       WHEN j.name = N'DBMaintenance - Daily Backups' THEN 24
                       ELSE 192
                   END) AS max_hours
            FROM msdb.dbo.sysjobs AS j
            WHERE j.name LIKE N'DatabaseBackup%'
               OR j.name LIKE N'DatabaseIntegrityCheck%'
               OR j.name LIKE N'IndexOptimize%'
               OR j.name = N'DBMaintenance - Daily Backups'
               OR j.name IN (N'CommandLog Cleanup', N'Output File Cleanup',
                             N'sp_delete_backuphistory', N'sp_purge_jobhistory')
        )
        INSERT mon.JobPolicy(job_id, job_name, job_type, max_hours_since_success)
        SELECT J.job_id, J.name, J.job_type, J.max_hours
        FROM J
        WHERE NOT EXISTS (SELECT 1 FROM mon.JobPolicy AS p WHERE p.job_id = J.job_id);

        UPDATE p
           SET p.job_name = j.name, p.last_seen_utc = SYSUTCDATETIME()
        FROM mon.JobPolicy AS p
        JOIN msdb.dbo.sysjobs AS j ON j.job_id = p.job_id;

        EXEC mon.usp_SetComponentStatus 'POLICY_SYNC', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'POLICY_SYNC', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------------
   Database state: inventory, sizes, log usage, VLFs, CHECKDB, Query Store,
   configuration baseline.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectDatabaseState
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME(),
            @now datetime2(0) = SYSUTCDATETIME(),
            @errors nvarchar(2000) = NULL;

    BEGIN TRY
        CREATE TABLE #Db
        (
            database_name sysname COLLATE DATABASE_DEFAULT PRIMARY KEY, database_id int, state_desc nvarchar(60),
            user_access_desc nvarchar(60), is_read_only bit, recovery_model nvarchar(60),
            compatibility_level tinyint, owner_name sysname NULL, page_verify nvarchar(60),
            is_auto_close_on bit, is_auto_shrink_on bit, is_rcsi_on bit, snapshot_isolation nvarchar(60),
            log_reuse_wait_desc nvarchar(60), create_date_utc datetime2(0),
            data_size_mb decimal(19,2), data_used_mb decimal(19,2) NULL, log_size_mb decimal(19,2),
            log_used_pct decimal(9,2) NULL, vlf_total int NULL, vlf_active int NULL,
            log_since_backup_mb decimal(19,2) NULL, dmv_log_backup_utc datetime2(0) NULL,
            last_checkdb_utc datetime2(0) NULL, qs_desired_state nvarchar(60) NULL,
            qs_actual_state nvarchar(60) NULL, qs_readonly_reason int NULL,
            pct_growth_files int NULL, max_file_pct_of_maxsize decimal(9,2) NULL,
            max_file_name sysname NULL, collection_error nvarchar(1000) NULL, checkdb_source varchar(20) NULL
        );
        CREATE TABLE #DbInfo(ParentObject nvarchar(255), [Object] nvarchar(255), Field nvarchar(255), [Value] nvarchar(255));

        INSERT #Db(database_name, database_id, state_desc, user_access_desc, is_read_only, recovery_model,
                   compatibility_level, owner_name, page_verify, is_auto_close_on, is_auto_shrink_on,
                   is_rcsi_on, snapshot_isolation, log_reuse_wait_desc, create_date_utc,
                   data_size_mb, log_size_mb, pct_growth_files, last_checkdb_utc)
        SELECT d.name, d.database_id, d.state_desc, d.user_access_desc, d.is_read_only, d.recovery_model_desc,
               d.compatibility_level, SUSER_SNAME(d.owner_sid), d.page_verify_option_desc,
               d.is_auto_close_on, d.is_auto_shrink_on, d.is_read_committed_snapshot_on,
               d.snapshot_isolation_state_desc, d.log_reuse_wait_desc,
               mon.fn_ServerToUtc(d.create_date),
               mf.data_mb, mf.log_mb, mf.pct_growth_files,
               CASE WHEN d.state_desc = N'ONLINE' THEN
                    mon.fn_ServerToUtc(NULLIF(TRY_CONVERT(datetime2(3),
                        DATABASEPROPERTYEX(d.name, 'LastGoodCheckDbTime')), '19000101'))
               END
        FROM sys.databases AS d
        OUTER APPLY
        (
            SELECT SUM(CASE WHEN f.type = 0 THEN CONVERT(bigint, f.size) END) * 8 / 1024.0 AS data_mb,
                   SUM(CASE WHEN f.type = 1 THEN CONVERT(bigint, f.size) END) * 8 / 1024.0 AS log_mb,
                   SUM(CASE WHEN f.is_percent_growth = 1 AND f.growth > 0 THEN 1 ELSE 0 END) AS pct_growth_files
            FROM sys.master_files AS f
            WHERE f.database_id = d.database_id
        ) AS mf
        WHERE d.database_id > 4
          AND d.name <> N'rdsadmin'
          AND d.source_database_id IS NULL;

        UPDATE #Db SET checkdb_source = 'DBPROPERTY' WHERE last_checkdb_utc IS NOT NULL;

        /* Files closest to MAXSIZE (max_size -1 = unlimited, 0 = no growth). */
        ;WITH F AS
        (
            SELECT DB_NAME(f.database_id) AS database_name, f.name,
                   CONVERT(decimal(9,2), f.size * 100.0 / NULLIF(f.max_size, 0)) AS pct,
                   ROW_NUMBER() OVER (PARTITION BY f.database_id ORDER BY f.size * 1.0 / NULLIF(f.max_size, 0) DESC) AS rn
            FROM sys.master_files AS f
            WHERE f.database_id > 4 AND f.max_size > 0 AND f.growth > 0
              AND f.max_size <> 268435456   /* 2 TB log default = effectively unlimited */
        )
        UPDATE d SET d.max_file_pct_of_maxsize = F.pct, d.max_file_name = F.name
        FROM #Db AS d JOIN F ON F.database_name = d.database_name AND F.rn = 1;

        /* Log utilization (cheap, instance wide). */
        BEGIN TRY
            CREATE TABLE #LogSpace(database_name sysname COLLATE DATABASE_DEFAULT, log_size_mb decimal(19,2), log_used_pct decimal(9,2), status_code int);
            INSERT #LogSpace EXEC (N'DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS;');
            UPDATE d SET d.log_used_pct = l.log_used_pct
            FROM #Db AS d JOIN #LogSpace AS l ON l.database_name = d.database_name;
        END TRY
        BEGIN CATCH
            SET @errors = CONCAT(@errors, N' LOGSPACE: ', ERROR_MESSAGE());
        END CATCH;

        /* VLFs + last log backup as seen by the engine itself (includes RDS automated log backups). */
        BEGIN TRY
            CREATE TABLE #LogStats(database_id int PRIMARY KEY, total_vlf int, active_vlf int,
                                   since_mb decimal(19,2), log_backup_time datetime2(3) NULL);
            INSERT #LogStats
            EXEC sys.sp_executesql N'
                SELECT d.database_id, ls.total_vlf_count, ls.active_vlf_count,
                       ls.log_since_last_log_backup_mb, NULLIF(ls.log_backup_time, ''19000101'')
                FROM sys.databases AS d
                CROSS APPLY sys.dm_db_log_stats(d.database_id) AS ls
                WHERE d.database_id > 4 AND d.state_desc = N''ONLINE'' AND d.is_in_standby = 0
                  AND d.source_database_id IS NULL;';
            UPDATE d SET d.vlf_total = s.total_vlf, d.vlf_active = s.active_vlf,
                         d.log_since_backup_mb = s.since_mb,
                         d.dmv_log_backup_utc = mon.fn_ServerToUtc(s.log_backup_time)
            FROM #Db AS d JOIN #LogStats AS s ON s.database_id = d.database_id;
        END TRY
        BEGIN CATCH
            SET @errors = CONCAT(@errors, N' dm_db_log_stats: ', ERROR_MESSAGE());
        END CATCH;

        /* Per-database context: data space used + Query Store state. */
        DECLARE @dbinfo_denied bit = 0;
        DECLARE @db sysname, @proc nvarchar(300), @du decimal(19,2), @qd nvarchar(60), @qa nvarchar(60), @qr int;
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT database_name FROM #Db WHERE state_desc = N'ONLINE' AND user_access_desc <> N'SINGLE_USER';
        OPEN c;
        FETCH NEXT FROM c INTO @db;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SELECT @du = NULL, @qd = NULL, @qa = NULL, @qr = NULL;
                SET @proc = QUOTENAME(@db) + N'.sys.sp_executesql';
                EXEC @proc N'
                    SELECT @du = SUM(CONVERT(bigint, FILEPROPERTY(name, ''SpaceUsed''))) * 8 / 1024.0
                    FROM sys.database_files WHERE type = 0;
                    SELECT @qd = desired_state_desc, @qa = actual_state_desc, @qr = readonly_reason
                    FROM sys.database_query_store_options;',
                    N'@du decimal(19,2) OUTPUT, @qd nvarchar(60) OUTPUT, @qa nvarchar(60) OUTPUT, @qr int OUTPUT',
                    @du = @du OUTPUT, @qd = @qd OUTPUT, @qa = @qa OUTPUT, @qr = @qr OUTPUT;
                UPDATE #Db SET data_used_mb = @du, qs_desired_state = @qd, qs_actual_state = @qa,
                               qs_readonly_reason = @qr
                WHERE database_name = @db;

                /* CHECKDB fallback when DATABASEPROPERTYEX('LastGoodCheckDbTime') is not available on this build:
                   read dbi_dbccLastKnownGood from the boot page (DBCC DBINFO). Ola CommandLog is a third source (view). */
                IF @dbinfo_denied = 0 AND EXISTS (SELECT 1 FROM #Db WHERE database_name = @db AND last_checkdb_utc IS NULL)
                BEGIN
                    BEGIN TRY
                        TRUNCATE TABLE #DbInfo;
                        INSERT #DbInfo EXEC @proc N'DBCC DBINFO WITH TABLERESULTS, NO_INFOMSGS;';
                        UPDATE #Db
                           SET last_checkdb_utc = mon.fn_ServerToUtc(NULLIF(TRY_CONVERT(datetime2(3),
                                   (SELECT TOP (1) i.[Value] FROM #DbInfo AS i WHERE i.Field = N'dbi_dbccLastKnownGood')), '19000101')),
                               checkdb_source = 'DBINFO'
                         WHERE database_name = @db;
                        UPDATE #Db SET checkdb_source = NULL WHERE database_name = @db AND last_checkdb_utc IS NULL;
                    END TRY
                    BEGIN CATCH
                        SET @dbinfo_denied = 1;   /* not permitted (RDS: not sysadmin) - stop trying this run; Ola CommandLog remains */
                    END CATCH;
                END;
            END TRY
            BEGIN CATCH
                UPDATE #Db SET collection_error = LEFT(ERROR_MESSAGE(), 1000) WHERE database_name = @db;
            END CATCH;
            FETCH NEXT FROM c INTO @db;
        END;
        CLOSE c;
        DEALLOCATE c;

        /* Upsert current state; databases no longer present are flagged, not deleted. */
        MERGE mon.DatabaseStatus AS t
        USING #Db AS s ON t.database_name = s.database_name
        WHEN MATCHED THEN UPDATE SET
            database_id = s.database_id, is_present = 1, collected_utc = @now, state_desc = s.state_desc,
            user_access_desc = s.user_access_desc, is_read_only = s.is_read_only, recovery_model = s.recovery_model,
            compatibility_level = s.compatibility_level, owner_name = s.owner_name, page_verify = s.page_verify,
            is_auto_close_on = s.is_auto_close_on, is_auto_shrink_on = s.is_auto_shrink_on, is_rcsi_on = s.is_rcsi_on,
            snapshot_isolation = s.snapshot_isolation, log_reuse_wait_desc = s.log_reuse_wait_desc,
            create_date_utc = s.create_date_utc, data_size_mb = s.data_size_mb, data_used_mb = s.data_used_mb,
            log_size_mb = s.log_size_mb, log_used_pct = s.log_used_pct, vlf_total = s.vlf_total,
            vlf_active = s.vlf_active, log_since_backup_mb = s.log_since_backup_mb,
            dmv_log_backup_utc = s.dmv_log_backup_utc, last_checkdb_utc = s.last_checkdb_utc,
            qs_desired_state = s.qs_desired_state, qs_actual_state = s.qs_actual_state,
            qs_readonly_reason = s.qs_readonly_reason, pct_growth_files = s.pct_growth_files,
            max_file_pct_of_maxsize = s.max_file_pct_of_maxsize, max_file_name = s.max_file_name,
            collection_error = s.collection_error, checkdb_source = s.checkdb_source
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (database_name, database_id, is_present, collected_utc, state_desc, user_access_desc, is_read_only,
             recovery_model, compatibility_level, owner_name, page_verify, is_auto_close_on, is_auto_shrink_on,
             is_rcsi_on, snapshot_isolation, log_reuse_wait_desc, create_date_utc, data_size_mb, data_used_mb,
             log_size_mb, log_used_pct, vlf_total, vlf_active, log_since_backup_mb, dmv_log_backup_utc,
             last_checkdb_utc, qs_desired_state, qs_actual_state, qs_readonly_reason, pct_growth_files,
             max_file_pct_of_maxsize, max_file_name, collection_error, checkdb_source)
        VALUES
            (s.database_name, s.database_id, 1, @now, s.state_desc, s.user_access_desc, s.is_read_only,
             s.recovery_model, s.compatibility_level, s.owner_name, s.page_verify, s.is_auto_close_on,
             s.is_auto_shrink_on, s.is_rcsi_on, s.snapshot_isolation, s.log_reuse_wait_desc, s.create_date_utc,
             s.data_size_mb, s.data_used_mb, s.log_size_mb, s.log_used_pct, s.vlf_total, s.vlf_active,
             s.log_since_backup_mb, s.dmv_log_backup_utc, s.last_checkdb_utc, s.qs_desired_state,
             s.qs_actual_state, s.qs_readonly_reason, s.pct_growth_files, s.max_file_pct_of_maxsize,
             s.max_file_name, s.collection_error, s.checkdb_source)
        WHEN NOT MATCHED BY SOURCE AND t.is_present = 1 THEN UPDATE SET
            is_present = 0, collected_utc = @now, state_desc = N'NOT_FOUND';

        /* Configuration baseline: first observation of every property is accepted automatically. */
        ;WITH P AS
        (
            SELECT s.database_name, v.property_name, v.property_value
            FROM mon.DatabaseStatus AS s
            CROSS APPLY (VALUES
                ('recovery_model',      CONVERT(nvarchar(256), s.recovery_model)),
                ('compatibility_level', CONVERT(nvarchar(256), s.compatibility_level)),
                ('owner_name',          CONVERT(nvarchar(256), s.owner_name)),
                ('page_verify',         CONVERT(nvarchar(256), s.page_verify)),
                ('auto_close',          CONVERT(nvarchar(256), s.is_auto_close_on)),
                ('auto_shrink',         CONVERT(nvarchar(256), s.is_auto_shrink_on)),
                ('read_only',           CONVERT(nvarchar(256), s.is_read_only)),
                ('rcsi',                CONVERT(nvarchar(256), s.is_rcsi_on)),
                ('snapshot_isolation',  CONVERT(nvarchar(256), s.snapshot_isolation)),
                ('user_access',         CONVERT(nvarchar(256), s.user_access_desc))
            ) AS v(property_name, property_value)
            WHERE s.is_present = 1 AND s.state_desc = N'ONLINE'
        )
        INSERT mon.DatabaseConfigBaseline(database_name, property_name, baseline_value)
        SELECT P.database_name, P.property_name, P.property_value
        FROM P
        WHERE NOT EXISTS (SELECT 1 FROM mon.DatabaseConfigBaseline AS b
                          WHERE b.database_name = P.database_name AND b.property_name = P.property_name);

        IF @errors IS NULL
            EXEC mon.usp_SetComponentStatus 'DATABASE_STATE', 1, @started;
        ELSE
            EXEC mon.usp_SetComponentStatus 'DATABASE_STATE', 0, @started, 50001, @errors;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'DATABASE_STATE', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------------
   Backups: msdb history, RDS native task status, RDS log-backup metadata and
   sys.dm_db_log_stats. Latest evidence per database/type -> mon.BackupStatus.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectBackups
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME(), @now datetime2(0) = SYSUTCDATETIME(),
            @note nvarchar(1000) = NULL, @task_error bit = 0;

    BEGIN TRY
        /* 1. RDS native backup/restore task status (asynchronous tasks). */
        CREATE TABLE #RdsTasks
        (
            task_id int, task_type nvarchar(128) COLLATE DATABASE_DEFAULT, database_name sysname COLLATE DATABASE_DEFAULT NULL,
            percent_complete_text nvarchar(100), duration_minutes_text nvarchar(100),
            lifecycle nvarchar(40), task_info nvarchar(max), last_updated datetime, created_at datetime,
            s3_object_arn nvarchar(max), overwrite_s3_backup_file nvarchar(100),
            kms_master_key_arn nvarchar(max), filepath nvarchar(max), overwrite_file nvarchar(100)
        );
        BEGIN TRY
            INSERT #RdsTasks EXEC msdb.dbo.rds_task_status;
        END TRY
        BEGIN CATCH
            SET @note = CONCAT(N'rds_task_status unavailable: ', LEFT(ERROR_MESSAGE(), 300));
            SET @task_error = 1;
        END CATCH;

        /* [5.7] Are rds_task_status times UTC or server-local? On an instance with a non-UTC time zone
           a UTC value of a fresh task is ahead of the server clock -> UTC (remembered in rds_task_times_utc).
           Wrong guess = backups shown in the future ("0s ago"). */
        DECLARE @rds_utc_setting nvarchar(10) = ISNULL(mon.fn_Setting('rds_task_times_utc'), N'AUTO'),
                @tz_off int = DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), @rds_utc bit = 0;
        IF @rds_utc_setting = N'1' OR @tz_off = 0
            SET @rds_utc = 1;
        ELSE IF @rds_utc_setting = N'AUTO'
             AND EXISTS (SELECT 1 FROM #RdsTasks
                         WHERE last_updated > DATEADD(MINUTE, 10, GETDATE()) OR created_at > DATEADD(MINUTE, 10, GETDATE()))
        BEGIN
            SET @rds_utc = 1;
            UPDATE mon.Setting SET setting_value = N'1', modified_utc = SYSUTCDATETIME()
            WHERE setting_name = 'rds_task_times_utc';
            /* rows stored earlier were shifted by the server offset: put them back */
            UPDATE mon.RdsTask SET last_updated_utc = DATEADD(MINUTE, @tz_off, last_updated_utc),
                                   created_utc      = DATEADD(MINUTE, @tz_off, created_utc);
        END;

        MERGE mon.RdsTask AS t
        USING (SELECT task_id, task_type, database_name,
                      TRY_CONVERT(decimal(9,2), REPLACE(percent_complete_text, N'%', N'')) AS pct,
                      TRY_CONVERT(int, duration_minutes_text) AS dur,
                      lifecycle, task_info,
                      CASE WHEN @rds_utc = 1 THEN CONVERT(datetime2(3), last_updated) ELSE mon.fn_ServerToUtc(last_updated) END AS last_updated_utc,
                      CASE WHEN @rds_utc = 1 THEN CONVERT(datetime2(3), created_at)   ELSE mon.fn_ServerToUtc(created_at)   END AS created_utc,
                      LEFT(s3_object_arn, 4000) AS arn
               FROM #RdsTasks) AS s
        ON t.task_id = s.task_id
        WHEN MATCHED THEN UPDATE SET
            task_type = s.task_type, database_name = s.database_name, percent_complete = s.pct,
            duration_minutes = s.dur, lifecycle = s.lifecycle, task_info = s.task_info,
            last_updated_utc = s.last_updated_utc, created_utc = s.created_utc,
            s3_object_arn = s.arn, last_collected_utc = @now
        WHEN NOT MATCHED THEN INSERT
            (task_id, task_type, database_name, percent_complete, duration_minutes, lifecycle, task_info,
             last_updated_utc, created_utc, s3_object_arn)
        VALUES (s.task_id, s.task_type, s.database_name, s.pct, s.dur, s.lifecycle, s.task_info,
                s.last_updated_utc, s.created_utc, s.arn);

        /* 2. RDS automated transaction-log backup metadata (requires T-log backup access feature). */
        CREATE TABLE #Tlog
        (
            db_name sysname COLLATE DATABASE_DEFAULT, db_id int, family_guid uniqueidentifier, rds_backup_seq_id int,
            backup_file_epoch bigint, backup_file_time_utc datetime, starting_lsn numeric(25,0),
            ending_lsn numeric(25,0), is_log_chain_broken bit, file_size_bytes bigint, error_message varchar(4000)
        );
        DECLARE @db sysname, @tlog_errors int = 0, @since datetime,
                @full_scan bit = CASE WHEN EXISTS (SELECT 1 FROM mon.ComponentStatus WHERE component_name = 'TLOG_FULL_SCAN'
                                                   AND last_success_utc > DATEADD(HOUR, -24, SYSUTCDATETIME())) THEN 0 ELSE 1 END;
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT p.database_name
            FROM mon.DatabaseCheck AS p
            JOIN sys.databases AS d ON d.name = p.database_name
            WHERE p.monitored = 1 AND (p.log_backup = 1 OR p.backup_retention = 1)
              AND d.state_desc = N'ONLINE' AND d.recovery_model_desc = N'FULL';
        OPEN c;
        FETCH NEXT FROM c INTO @db;
        WHILE @@FETCH_STATUS = 0 AND @tlog_errors < 2   /* feature disabled -> stop probing after 2 errors */
        BEGIN
            /* first time for this database: load the whole RDS retention window (for the retention grid) */
            /* Full RDS retention window on first contact and once a day (marks which files RDS still has);
               otherwise only the last 2 days. */
            SET @since = CASE WHEN @full_scan = 1 OR NOT EXISTS (SELECT 1 FROM mon.TlogBackup WHERE database_name = @db)
                              THEN '20000101' ELSE DATEADD(DAY, -2, SYSUTCDATETIME()) END;
            BEGIN TRY
                INSERT #Tlog
                EXEC sys.sp_executesql N'
                    SELECT db_name, db_id, family_guid, rds_backup_seq_id, backup_file_epoch,
                           backup_file_time_utc, starting_lsn, ending_lsn, is_log_chain_broken,
                           file_size_bytes, [Error]
                    FROM msdb.dbo.rds_fn_list_tlog_backup_metadata(@p_db)
                    WHERE backup_file_time_utc >= @p_since;',
                    N'@p_db sysname, @p_since datetime', @p_db = @db, @p_since = @since;
            END TRY
            BEGIN CATCH
                SET @tlog_errors += 1;
            END CATCH;
            FETCH NEXT FROM c INTO @db;
        END;
        CLOSE c;
        DEALLOCATE c;

        INSERT mon.TlogBackup(database_name, rds_backup_seq_id, backup_file_time_utc, starting_lsn,
                              ending_lsn, is_log_chain_broken, file_size_bytes, last_seen_utc)
        SELECT m.db_name, m.rds_backup_seq_id, m.backup_file_time_utc, m.starting_lsn, m.ending_lsn,
               m.is_log_chain_broken, m.file_size_bytes, @now
        FROM #Tlog AS m
        WHERE m.rds_backup_seq_id IS NOT NULL AND m.backup_file_time_utc IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM mon.TlogBackup AS t
                          WHERE t.database_name = m.db_name AND t.rds_backup_seq_id = m.rds_backup_seq_id);

        /* Files RDS still lists = still on storage. */
        UPDATE t SET t.last_seen_utc = @now
        FROM mon.TlogBackup AS t
        JOIN #Tlog AS m ON m.db_name = t.database_name AND m.rds_backup_seq_id = t.rds_backup_seq_id;

        IF @full_scan = 1   /* once a day, whatever the outcome (a failing DB must not force a full scan every cycle) */
            EXEC mon.usp_SetComponentStatus 'TLOG_FULL_SCAN', 1, NULL;

        /* 3. Candidate evidence from every source, normalized to UTC. */
        CREATE TABLE #Cand
        (
            database_name sysname COLLATE DATABASE_DEFAULT, backup_type char(1), finish_utc datetime2(0), duration_s int NULL,
            size_bytes bigint NULL, source_name varchar(20), location nvarchar(1000) NULL, chain_broken bit NULL
        );

        ;WITH B AS
        (
            SELECT b.database_name, b.type, b.backup_start_date, b.backup_finish_date,
                   COALESCE(b.compressed_backup_size, b.backup_size) AS size_bytes, b.media_set_id,
                   ROW_NUMBER() OVER (PARTITION BY b.database_name, b.type ORDER BY b.backup_finish_date DESC) AS rn
            FROM msdb.dbo.backupset AS b
            WHERE b.type IN ('D', 'I', 'L')
              AND b.backup_finish_date >= DATEADD(DAY, -400, GETDATE())   /* [5.5] sargable on msdb backupset date index; no full-history scan */
              AND EXISTS (SELECT 1 FROM mon.DatabasePolicy AS p WHERE p.database_name = b.database_name)
        )
        INSERT #Cand
        SELECT B.database_name, B.type, mon.fn_ServerToUtc(B.backup_finish_date),
               DATEDIFF(SECOND, B.backup_start_date, B.backup_finish_date), B.size_bytes, 'MSDB',
               LEFT(mf.physical_device_name, 1000), NULL
        FROM B
        OUTER APPLY (SELECT TOP (1) f.physical_device_name
                     FROM msdb.dbo.backupmediafamily AS f
                     WHERE f.media_set_id = B.media_set_id
                     ORDER BY f.family_sequence_number) AS mf
        WHERE B.rn = 1;

        INSERT #Cand
        SELECT r.database_name, CASE WHEN r.task_type = N'BACKUP_DB' THEN 'D' ELSE 'I' END,
               r.last_updated_utc, r.duration_minutes * 60, NULL, 'RDS_TASK', LEFT(r.s3_object_arn, 1000), NULL
        FROM mon.RdsTask AS r
        WHERE r.lifecycle = N'SUCCESS'
          AND r.task_type IN (N'BACKUP_DB', N'BACKUP_DB_DIFFERENTIAL')
          AND r.last_updated_utc IS NOT NULL
          AND r.database_name IS NOT NULL;

        INSERT #Cand
        /* [5.5] latest file per database: one index seek each (was ROW_NUMBER over the whole table) */
        SELECT p.database_name, 'L', t.backup_file_time_utc, NULL, t.file_size_bytes, 'RDS_TLOG', NULL, t.is_log_chain_broken
        FROM mon.DatabasePolicy AS p
        CROSS APPLY (SELECT TOP (1) x.backup_file_time_utc, x.file_size_bytes, x.is_log_chain_broken
                     FROM mon.TlogBackup AS x
                     WHERE x.database_name = p.database_name
                     ORDER BY x.backup_file_time_utc DESC) AS t;

        INSERT #Cand
        SELECT s.database_name, 'L', s.dmv_log_backup_utc, NULL, NULL, 'DMV_LOG_STATS', NULL, NULL
        FROM mon.DatabaseStatus AS s
        WHERE s.is_present = 1 AND s.dmv_log_backup_utc IS NOT NULL AND s.recovery_model = N'FULL';

        ;WITH L AS
        (
            SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.database_name, c.backup_type
                                           ORDER BY c.finish_utc DESC, c.source_name) AS rn
            FROM #Cand AS c
        )
        SELECT * INTO #Latest FROM L WHERE rn = 1;

        MERGE mon.BackupStatus AS t
        USING
        (
            SELECT p.database_name,
                   f.finish_utc AS full_finish_utc, f.duration_s AS full_duration_s, f.size_bytes AS full_size_bytes,
                   f.source_name AS full_source, f.location AS full_location,
                   i.finish_utc AS diff_finish_utc, i.duration_s AS diff_duration_s, i.size_bytes AS diff_size_bytes,
                   i.source_name AS diff_source,
                   l.finish_utc AS log_finish_utc, l.size_bytes AS log_size_bytes, l.source_name AS log_source,
                   (SELECT MAX(CONVERT(tinyint, t.is_log_chain_broken)) FROM mon.TlogBackup AS t
                    WHERE t.database_name = p.database_name
                      AND t.backup_file_time_utc >= DATEADD(HOUR, -24, @now)) AS chain_broken
            FROM mon.DatabasePolicy AS p
            LEFT JOIN #Latest AS f ON f.database_name = p.database_name AND f.backup_type = 'D'
            LEFT JOIN #Latest AS i ON i.database_name = p.database_name AND i.backup_type = 'I'
            LEFT JOIN #Latest AS l ON l.database_name = p.database_name AND l.backup_type = 'L'
        ) AS s
        ON t.database_name = s.database_name
        WHEN MATCHED THEN UPDATE SET
            collected_utc = @now, full_finish_utc = s.full_finish_utc, full_duration_s = s.full_duration_s,
            full_size_bytes = s.full_size_bytes, full_source = s.full_source, full_location = s.full_location,
            diff_finish_utc = s.diff_finish_utc, diff_duration_s = s.diff_duration_s,
            diff_size_bytes = s.diff_size_bytes, diff_source = s.diff_source,
            log_finish_utc = s.log_finish_utc, log_size_bytes = s.log_size_bytes, log_source = s.log_source,
            log_chain_broken = s.chain_broken, note = @note
        WHEN NOT MATCHED THEN INSERT
            (database_name, collected_utc, full_finish_utc, full_duration_s, full_size_bytes, full_source,
             full_location, diff_finish_utc, diff_duration_s, diff_size_bytes, diff_source, log_finish_utc,
             log_size_bytes, log_source, log_chain_broken, note)
        VALUES
            (s.database_name, @now, s.full_finish_utc, s.full_duration_s, s.full_size_bytes, s.full_source,
             s.full_location, s.diff_finish_utc, s.diff_duration_s, s.diff_size_bytes, s.diff_source,
             s.log_finish_utc, s.log_size_bytes, s.log_source, s.chain_broken, @note)
        WHEN NOT MATCHED BY SOURCE THEN DELETE;

        IF @task_error = 0
            EXEC mon.usp_SetComponentStatus 'BACKUPS', 1, @started;
        ELSE
            EXEC mon.usp_SetComponentStatus 'BACKUPS', 0, @started, 50003, @note;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'BACKUPS', 0, @started, @en, @em;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------------
   SQL Agent: every job outcome (for SLA + duration baselines, and to outlive
   the small msdb history limit) and every failed/cancelled job run with the
   step that actually failed.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectAgent
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    BEGIN TRY
        DECLARE @since_int int = CONVERT(int, CONVERT(char(8), DATEADD(DAY, -35, GETDATE()), 112));

        INSERT mon.AgentJobRun(job_id, instance_id, job_name, run_status, run_start_utc, duration_s, message)
        SELECT h.job_id, h.instance_id, j.name, h.run_status,
               mon.fn_ServerToUtc(DATETIMEFROMPARTS(h.run_date / 10000, (h.run_date / 100) % 100, h.run_date % 100,
                                                    h.run_time / 10000, (h.run_time / 100) % 100, h.run_time % 100, 0)),
               (h.run_duration / 10000) * 3600 + ((h.run_duration / 100) % 100) * 60 + h.run_duration % 100,
               LEFT(mon.fn_CleanAgentMessage(h.message), 4000)
        FROM msdb.dbo.sysjobhistory AS h
        JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
        WHERE h.step_id = 0
          AND h.run_date >= @since_int
          AND NOT EXISTS (SELECT 1 FROM mon.AgentJobRun AS x WHERE x.job_id = h.job_id AND x.instance_id = h.instance_id);

        INSERT mon.AgentFailure(job_id, instance_id, job_name, run_status, run_start_utc, duration_s,
                                failed_step_id, failed_step_name, message)
        SELECT r.job_id, r.instance_id, r.job_name, r.run_status, r.run_start_utc, r.duration_s,
               st.step_id, st.step_name, COALESCE(st.message, r.message)
        FROM mon.AgentJobRun AS r
        OUTER APPLY
        (
            /* The failing step of this execution: last failed step row before the outcome row. */
            SELECT TOP (1) s.step_id, s.step_name, LEFT(mon.fn_CleanAgentMessage(s.message), 4000) AS message
            FROM msdb.dbo.sysjobhistory AS s
            WHERE s.job_id = r.job_id AND s.step_id > 0 AND s.run_status = 0
              AND s.instance_id < r.instance_id
              AND s.instance_id > ISNULL((SELECT MAX(p.instance_id)
                                          FROM msdb.dbo.sysjobhistory AS p
                                          WHERE p.job_id = r.job_id AND p.step_id = 0
                                            AND p.instance_id < r.instance_id), 0)
            ORDER BY s.instance_id DESC
        ) AS st
        WHERE r.run_status IN (0, 3)
          AND r.run_start_utc >= DATEADD(DAY, -7, SYSUTCDATETIME())
          AND NOT EXISTS (SELECT 1 FROM mon.AgentFailure AS f WHERE f.job_id = r.job_id AND f.instance_id = r.instance_id);

        EXEC mon.usp_SetComponentStatus 'AGENT', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'AGENT', 0, @started, @en, @em;
    END CATCH;
END;
GO
