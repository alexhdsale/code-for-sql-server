
/* =============================================================================
   SECTION 8b  -  BACKUP RETENTION / INVENTORY + CHECK MATRIX TOOLS   [rev 5.1]
   ============================================================================= */

/*
   Live retention per database and backup type.
   Evidence: msdb.backupset, RDS native task history (mon.RdsTask, ~36 days kept by AWS)
   and RDS automated log backups (mon.TlogBackup from rds_fn_list_tlog_backup_metadata).
   Per database/type the source with the most rows is used (avoids double counting a
   native backup that appears in both msdb and the RDS task list).
   NOTE: S3 lifecycle rules are invisible to T-SQL; "oldest" = oldest backup still recorded.
*/
CREATE OR ALTER VIEW mon.vw_BackupRetention
AS
/* [rev 5.5] performance rewrite: every source is read ONCE.
   - was: OUTER APPLY per database x type re-evaluated the whole CTE chain (36 x msdb scan)
   - was: scalar UDF mon.fn_ServerToUtc per msdb row (not inlineable) -> offset computed once
   - was: the source-selection CTE re-read all sources -> chosen with window functions in one pass */
WITH Z AS
(
    SELECT DATEPART(TZOFFSET, SYSDATETIMEOFFSET()) AS tz_off_min,
           CONVERT(datetime2(0), SYSUTCDATETIME()) AS now_utc,
           ISNULL((SELECT TRY_CONVERT(int, setting_value) FROM mon.Setting WHERE setting_name = 'backup_retention_target_days'), 7) AS def_target,
           (SELECT TRY_CONVERT(int, NULLIF(setting_value, N'')) FROM mon.Setting WHERE setting_name = 'backup_storage_retention_days') AS def_storage
), Cfg AS
(
    SELECT c.database_name, c.monitored, c.full_backup, c.diff_backup, c.log_backup, c.backup_retention,
           ISNULL(c.retention_days, Z.def_target) AS target_days,
           /* declared lifecycle of files on storage (S3 rule / Ola @CleanupTime); NULL = not declared */
           COALESCE(c.storage_retention_days, Z.def_storage) AS storage_days,
           ISNULL(p.full_max_age_minutes, 1440) AS full_sla, ISNULL(p.log_max_age_minutes, 30) AS log_sla,
           s.recovery_model, ISNULL(s.is_present, 0) AS is_present, s.create_date_utc
    FROM mon.DatabaseCheck AS c
    CROSS JOIN Z
    LEFT JOIN mon.DatabasePolicy AS p ON p.database_name = c.database_name
    LEFT JOIN mon.DatabaseStatus AS s ON s.database_name = c.database_name
), Ev AS
(
    /* msdb history: one row per backup, files = media families (striped backups count every file) */
    SELECT b.database_name COLLATE DATABASE_DEFAULT AS database_name,
           CONVERT(varchar(4), CASE b.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' ELSE 'LOG' END) AS btype,
           CONVERT(varchar(20), 'MSDB') AS src,
           CONVERT(datetime2(0), DATEADD(MINUTE, -Z.tz_off_min, b.backup_finish_date)) AS t,
           CONVERT(bigint, COALESCE(b.compressed_backup_size, b.backup_size)) AS bytes,
           ISNULL(mf.n, 1) AS files, CONVERT(int, NULL) AS on_storage
    FROM msdb.dbo.backupset AS b
    CROSS JOIN Z
    LEFT JOIN (SELECT media_set_id, COUNT(*) AS n FROM msdb.dbo.backupmediafamily GROUP BY media_set_id) AS mf
           ON mf.media_set_id = b.media_set_id
    WHERE b.type IN ('D', 'I', 'L')
      AND b.backup_finish_date >= DATEADD(DAY, -400, GETDATE())
    UNION ALL
    /* RDS native backup to S3 (task history kept ~36 days by AWS) */
    SELECT r.database_name, CASE WHEN r.task_type = N'BACKUP_DB' THEN 'FULL' ELSE 'DIFF' END, 'RDS_TASK',
           r.last_updated_utc, CONVERT(bigint, NULL), 1, CONVERT(int, NULL)
    FROM mon.RdsTask AS r
    WHERE r.lifecycle = N'SUCCESS' AND r.task_type IN (N'BACKUP_DB', N'BACKUP_DB_DIFFERENTIAL')
      AND r.database_name IS NOT NULL AND r.last_updated_utc IS NOT NULL
    UNION ALL
    /* RDS automated log backups: on_storage = RDS still lists the file (daily full scan) */
    SELECT t.database_name, 'LOG', 'RDS_TLOG', t.backup_file_time_utc, t.file_size_bytes, 1,
           CASE WHEN t.last_seen_utc >= DATEADD(HOUR, -26, Z.now_utc) THEN 1 ELSE 0 END
    FROM mon.TlogBackup AS t
    CROSS JOIN Z
    WHERE t.backup_file_time_utc >= DATEADD(DAY, -35, Z.now_utc)
    UNION ALL
    /* Ola Hallengren DatabaseBackup (dbo.CommandLog) */
    SELECT o.database_name, o.backup_type, 'OLA', o.end_utc, CONVERT(bigint, NULL), ISNULL(o.file_count, 1), CONVERT(int, NULL)
    FROM mon.OlaCommand AS o
    WHERE o.backup_type IS NOT NULL AND ISNULL(o.error_number, 0) = 0 AND o.end_utc IS NOT NULL AND o.database_name IS NOT NULL
), Ranked AS
(
    /* per database/type keep only the source with the most rows (no double counting) - one pass */
    SELECT Ev.*, COUNT(*) OVER (PARTITION BY Ev.database_name, Ev.btype, Ev.src) AS n_src
    FROM Ev
), Picked AS
(
    SELECT R.*, DENSE_RANK() OVER (PARTITION BY R.database_name, R.btype ORDER BY R.n_src DESC, R.src) AS src_rank
    FROM Ranked AS R
), E0 AS
(
    SELECT P.database_name, P.btype, P.src, P.t, P.bytes, P.files, P.on_storage,
           LAG(P.t) OVER (PARTITION BY P.database_name, P.btype ORDER BY P.t) AS prev_t
    FROM Picked AS P
    WHERE P.src_rank = 1
), E AS
(
    /* per-row flags computed here, so the aggregates below reference inner columns only (Msg 8124) */
    SELECT E0.*,
           CASE WHEN k.storage_days IS NOT NULL AND E0.t >= DATEADD(DAY, -k.storage_days, Z.now_utc)
                THEN E0.files ELSE 0 END AS files_in_policy_row,
           CASE WHEN E0.btype <> 'DIFF' AND E0.prev_t IS NOT NULL
                 AND E0.t >= DATEADD(DAY, -k.target_days, Z.now_utc)
                 AND DATEDIFF(MINUTE, E0.prev_t, E0.t) > 1.25 * CASE E0.btype WHEN 'FULL' THEN k.full_sla ELSE k.log_sla END
                THEN 1 ELSE 0 END AS is_gap,
           CASE WHEN E0.t >= DATEADD(HOUR, -24, Z.now_utc) THEN E0.files ELSE 0 END AS files_24h_row
    FROM E0
    JOIN Cfg AS k ON k.database_name = E0.database_name
    CROSS JOIN Z
), A AS
(
    /* aggregated ONCE for all databases and types */
    SELECT E.database_name, E.btype,
           MAX(E.src) AS source_name, COUNT(*) AS backup_count, MIN(E.t) AS oldest_utc, MAX(E.t) AS newest_utc,
           AVG(CONVERT(bigint, DATEDIFF(MINUTE, E.prev_t, E.t))) AS avg_interval_min,
           AVG(E.bytes) AS avg_bytes, SUM(E.bytes) AS total_bytes,
           SUM(E.files) AS files_total,
           SUM(E.files_24h_row) AS files_24h,
           SUM(CASE WHEN E.on_storage = 1 THEN E.files ELSE 0 END) AS files_listed,
           SUM(E.files_in_policy_row) AS files_in_policy,
           SUM(E.is_gap) AS gaps_raw
    FROM E
    GROUP BY E.database_name, E.btype
)
SELECT c.database_name, bt.btype AS backup_type,
       a.source_name, ISNULL(a.backup_count, 0) AS backup_count, a.oldest_utc, a.newest_utc,
       CONVERT(decimal(9,1), DATEDIFF(MINUTE, a.oldest_utc, Z.now_utc) / 1440.0) AS retention_days,
       c.target_days,
       /* gaps inside the target window: interval longer than 1.25 x SLA (FULL and LOG only) */
       CASE WHEN bt.btype = 'DIFF' THEN NULL ELSE a.gaps_raw END AS gaps,
       a.avg_interval_min, a.avg_bytes, a.total_bytes,
       ISNULL(a.files_total, 0) AS files_total, ISNULL(a.files_24h, 0) AS files_24h,
       CASE WHEN a.source_name = 'RDS_TLOG' THEN NULL ELSE c.storage_days END AS storage_days,   /* RDS log files follow RDS retention */
       CASE WHEN a.source_name = 'RDS_TLOG' THEN a.files_listed
            WHEN c.storage_days IS NOT NULL THEN a.files_in_policy END AS files_on_storage,
       CASE WHEN a.source_name = 'RDS_TLOG' THEN 'RDS list'
            WHEN c.storage_days IS NOT NULL THEN 'estimated'
            ELSE 'not declared' END AS storage_basis,
       CASE
           WHEN c.monitored = 0 OR c.backup_retention = 0 OR c.is_present = 0 THEN 'OFF'
           WHEN bt.btype = 'FULL' AND c.full_backup = 0 THEN 'OFF'
           WHEN bt.btype = 'DIFF' AND c.diff_backup = 0 THEN 'OFF'
           WHEN bt.btype = 'LOG'  AND (c.log_backup = 0 OR ISNULL(c.recovery_model, N'') <> N'FULL') THEN 'N/A'
           /* no DIFF rows at all = the database uses FULL (+LOG) only; DIFF age is covered by the DIFF check */
           WHEN bt.btype = 'DIFF' AND ISNULL(a.backup_count, 0) = 0 THEN 'N/A'
           WHEN ISNULL(a.backup_count, 0) = 0 THEN 'NONE'
           WHEN a.oldest_utc > DATEADD(DAY, -c.target_days, Z.now_utc)
                AND ISNULL(c.create_date_utc, '19000101') < DATEADD(DAY, -c.target_days, Z.now_utc) THEN 'SHORT'
           /* declared storage lifecycle deletes files before the required retention */
           WHEN c.storage_days IS NOT NULL AND c.storage_days < c.target_days AND ISNULL(a.source_name, '') <> 'RDS_TLOG' THEN 'POLICY'
           WHEN bt.btype <> 'DIFF' AND a.gaps_raw > 0 THEN 'GAPS'
           ELSE 'OK'
       END AS status
FROM Cfg AS c
CROSS JOIN Z
CROSS JOIN (VALUES ('FULL'), ('DIFF'), ('LOG')) AS bt(btype)
LEFT JOIN A AS a ON a.database_name = c.database_name AND a.btype = bt.btype;
GO

/* Daily snapshot (called by the hourly job; idempotent per day). Also feeds RETENTION issues. */
CREATE OR ALTER PROCEDURE mon.usp_SnapshotBackupInventory
    @Force bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 10000;
    SET DEADLOCK_PRIORITY LOW;
    DECLARE @today date = CONVERT(date, SYSUTCDATETIME()), @started datetime2(3) = SYSUTCDATETIME();
    BEGIN TRY
        IF @Force = 0 AND EXISTS (SELECT 1 FROM mon.BackupInventoryDaily WHERE snapshot_date = @today) RETURN;
        DELETE FROM mon.BackupInventoryDaily WHERE snapshot_date = @today;
        INSERT mon.BackupInventoryDaily(snapshot_date, database_name, backup_type, status, source_name, backup_count,
                                        oldest_utc, newest_utc, retention_days, target_days, gaps, avg_interval_min,
                                        avg_bytes, total_bytes, files_total, files_24h, files_on_storage,
                                        storage_days, storage_basis)
        SELECT @today, r.database_name, r.backup_type, r.status, r.source_name, r.backup_count,
               r.oldest_utc, r.newest_utc, r.retention_days, r.target_days, r.gaps, r.avg_interval_min,
               r.avg_bytes, r.total_bytes, r.files_total, r.files_24h, r.files_on_storage,
               r.storage_days, r.storage_basis
        FROM mon.vw_BackupRetention AS r;
        EXEC mon.usp_SetComponentStatus 'BACKUP_INVENTORY', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'BACKUP_INVENTORY', 0, @started, @en, @em;
    END CATCH;
END;
GO

/*
   Everything that is checked on this server, in one call (SSMS grid friendly):
     1) database matrix with check marks   2) server-level checks
     3) catalog: what each check does + which setting tunes it   4) last 50 changes (audit)
*/
CREATE OR ALTER PROCEDURE mon.usp_ShowChecks
    @Database sysname = N'%'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @y nchar(1) = NCHAR(10004), @na nvarchar(3) = N'n/a', @def int = ISNULL(mon.fn_SettingInt('backup_retention_target_days'), 7);

    SELECT c.database_name AS [Database],
           ISNULL(s.recovery_model, N'?') AS [Recovery],
           CASE WHEN c.monitored = 1 THEN @y ELSE N'' END AS [Monitored],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.full_backup = 1 THEN @y ELSE N'' END AS [Full],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.diff_backup = 1 THEN @y ELSE N'' END AS [Diff],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN ISNULL(s.recovery_model, N'FULL') <> N'FULL' THEN @na
                WHEN c.log_backup = 1 THEN @y ELSE N'' END AS [Log],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.backup_retention = 1 THEN @y ELSE N'' END AS [Retention],
           CONCAT(ISNULL(c.retention_days, @def), N'd', CASE WHEN c.retention_days IS NULL THEN N' (default)' END) AS [Retention target],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.checkdb = 1 THEN @y ELSE N'' END AS [CHECKDB],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.log_used = 1 THEN @y ELSE N'' END AS [Log used],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.vlf_count = 1 THEN @y ELSE N'' END AS [VLF],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.file_near_max = 1 THEN @y ELSE N'' END AS [File max],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.config_drift = 1 THEN @y ELSE N'' END AS [Drift],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.config_best_practice = 1 THEN @y ELSE N'' END AS [Config],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.query_store = 1 THEN @y ELSE N'' END AS [Query Store],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.blocking = 1 THEN @y ELSE N'' END AS [Blocking],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.long_queries = 1 THEN @y ELSE N'' END AS [Long queries],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.open_trans = 1 THEN @y ELSE N'' END AS [Open trans],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.deadlocks = 1 THEN @y ELSE N'' END AS [Deadlocks],
           CASE WHEN c.monitored = 0 THEN N'-' WHEN c.io_latency = 1 THEN @y ELSE N'' END AS [I/O latency],
           CONCAT(p.full_max_age_minutes, N' / ', p.diff_max_age_minutes, N' / ', p.log_max_age_minutes, N' min') AS [SLA full/diff/log],
           c.notes AS [Notes],
           CASE WHEN ISNULL(s.is_present, 1) = 0 THEN N'DROPPED' ELSE N'' END AS [State],
           c.modified_utc AS [Modified UTC], c.modified_by AS [Modified by]
    FROM mon.DatabaseCheck AS c
    LEFT JOIN mon.DatabaseStatus AS s ON s.database_name = c.database_name
    LEFT JOIN mon.DatabasePolicy AS p ON p.database_name = c.database_name
    WHERE c.database_name LIKE @Database
    ORDER BY c.monitored DESC, c.database_name;

    SELECT s.check_code AS [Code], s.display_name AS [Server-level check],
           CASE WHEN s.is_enabled = 1 THEN @y ELSE N'' END AS [Enabled],
           k.description AS [What it checks], k.threshold_info AS [Tuned by], s.notes AS [Notes],
           s.modified_utc AS [Modified UTC], s.modified_by AS [Modified by]
    FROM mon.ServerCheck AS s
    JOIN mon.CheckCatalog AS k ON k.check_code = s.check_code
    ORDER BY k.sort_order;

    SELECT k.check_code AS [Code], k.scope AS [Scope], k.display_name AS [Check], k.column_name AS [DatabaseCheck column],
           k.description AS [What it checks], k.threshold_info AS [Tuned by], k.key_pattern AS [Issue key pattern]
    FROM mon.CheckCatalog AS k
    ORDER BY k.sort_order;

    SELECT TOP (50) l.changed_utc AS [Changed UTC], l.changed_by AS [By], l.host_name AS [Host], l.object_name AS [Object],
           l.item_name AS [Item], l.property_name AS [Property], l.old_value AS [Old], l.new_value AS [New]
    FROM mon.CheckChangeLog AS l
    ORDER BY l.change_log_id DESC;
END;
GO

/*
   Switch a check ON/OFF.
     @Database : exact name or LIKE pattern (N'%' = all databases). Ignored for server checks.
     @Check    : check code (FULL, LOG, LONGQ, CPU, ...), column name (long_queries), or 'ALL'
                 (= every database-level check except MONITORED).
   Examples:
     EXEC mon.usp_SetCheck @Database = N'DWH_Stage', @Check = 'LOG', @Enabled = 0;
     EXEC mon.usp_SetCheck @Database = N'%',         @Check = 'LONGQ', @Enabled = 0;
     EXEC mon.usp_SetCheck @Database = N'TestRestore', @Check = 'MONITORED', @Enabled = 0;
     EXEC mon.usp_SetCheck @Check = 'CPU', @Enabled = 0;                      -- server level
     EXEC mon.usp_SetCheck @Database = N'MioCore', @Check = 'RETENTION', @Enabled = 1, @RetentionDays = 14;
*/
CREATE OR ALTER PROCEDURE mon.usp_SetCheck
    @Database      sysname = N'%',
    @Check         varchar(40),
    @Enabled       bit,
    @RetentionDays int = NULL,
    @Notes         nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @code varchar(20), @scope varchar(10), @col sysname, @sql nvarchar(max), @n int;

    IF @Check = 'ALL'
        SET @code = 'ALL';
    ELSE
        SELECT @code = c.check_code, @scope = c.scope, @col = c.column_name
        FROM mon.CheckCatalog AS c
        WHERE c.check_code = @Check OR c.column_name = @Check;
    /* exact name first (names may contain LIKE wildcards such as _ ) */
    IF EXISTS (SELECT 1 FROM mon.DatabaseCheck WHERE database_name = @Database)
        SET @Database = REPLACE(REPLACE(REPLACE(@Database, N'[', N'[[]'), N'_', N'[_]'), N'%', N'[%]');

    IF @code IS NULL
    BEGIN
        RAISERROR(N'Unknown check "%s". Valid codes: SELECT check_code, scope, display_name FROM OPS.mon.CheckCatalog;', 16, 1, @Check);
        RETURN;
    END;

    IF @scope = 'SERVER'
    BEGIN
        UPDATE mon.ServerCheck SET is_enabled = @Enabled, notes = COALESCE(@Notes, notes) WHERE check_code = @code;
        EXEC mon.usp_CloseDisabledIssues;
        SELECT check_code, display_name, is_enabled, notes, modified_utc, modified_by FROM mon.ServerCheck WHERE check_code = @code;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM mon.DatabaseCheck WHERE database_name LIKE @Database)
    BEGIN
        RAISERROR(N'No database in OPS.mon.DatabaseCheck matches "%s".', 16, 1, @Database);
        RETURN;
    END;

    IF @code = 'ALL'
        SET @sql = N'UPDATE mon.DatabaseCheck SET '
                 + STUFF((SELECT N', ' + QUOTENAME(c.column_name) + N' = @e'
                          FROM mon.CheckCatalog AS c
                          WHERE c.scope = 'DATABASE' AND c.column_name IS NOT NULL AND c.check_code <> 'MONITORED'
                          ORDER BY c.sort_order
                          FOR XML PATH(''), TYPE).value('(./text())[1]', 'nvarchar(max)'), 1, 2, N'')
                 + N' WHERE database_name LIKE @db;';
    ELSE
        SET @sql = N'UPDATE mon.DatabaseCheck SET ' + QUOTENAME(@col) + N' = @e WHERE database_name LIKE @db;';

    SELECT @n = COUNT(*) FROM mon.DatabaseCheck WHERE database_name LIKE @Database;
    EXEC sys.sp_executesql @sql, N'@e bit, @db sysname', @e = @Enabled, @db = @Database;

    IF @RetentionDays IS NOT NULL
        UPDATE mon.DatabaseCheck SET retention_days = NULLIF(@RetentionDays, 0) WHERE database_name LIKE @Database;
    IF @Notes IS NOT NULL
        UPDATE mon.DatabaseCheck SET notes = @Notes WHERE database_name LIKE @Database;

    DECLARE @closed int;
    EXEC mon.usp_CloseDisabledIssues @Closed = @closed OUTPUT;
    PRINT CONCAT(N'Updated ', @n, N' database(s). ', ISNULL(@closed, 0), N' open issue(s) of disabled checks closed now (silently); re-enabled checks are evaluated at the next 5-minute cycle.');
    EXEC mon.usp_ShowChecks @Database = @Database;
END;
GO

/* Retention grid for SSMS (live) - @Live = 0 reads today's snapshot (fast). */
CREATE OR ALTER PROCEDURE mon.usp_ShowBackupRetention
    @Database sysname = N'%',
    @Live     bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');

    /* [rev 5.3] the view scans msdb.backupset: evaluate it ONCE (it was evaluated twice) and
       read the totals from the daily snapshot when @Live = 0, so the fast path never touches msdb. */
    CREATE TABLE #R (database_name sysname, backup_type nvarchar(20), status nvarchar(20), backup_count bigint,
                     files_total bigint, files_24h bigint, files_on_storage bigint, storage_basis nvarchar(100),
                     total_bytes decimal(38,0), oldest_utc datetime2(3), newest_utc datetime2(3),
                     retention_days int, target_days int, gaps int, avg_interval_min bigint, avg_bytes decimal(38,0),
                     storage_days int, source_name nvarchar(40));
    IF @Live = 1
        INSERT #R
        SELECT r.database_name, r.backup_type, r.status, r.backup_count, r.files_total, r.files_24h, r.files_on_storage,
               r.storage_basis, r.total_bytes, r.oldest_utc, r.newest_utc, r.retention_days, r.target_days, r.gaps,
               r.avg_interval_min, r.avg_bytes, r.storage_days, r.source_name
        FROM mon.vw_BackupRetention AS r
        WHERE r.database_name LIKE @Database;
    ELSE
        INSERT #R (database_name, backup_type, status, backup_count, files_total, files_24h, files_on_storage,
                   storage_basis, total_bytes, oldest_utc, newest_utc)
        SELECT r.database_name, r.backup_type, r.status, r.backup_count, r.files_total, r.files_24h, r.files_on_storage,
               r.storage_basis, r.total_bytes, r.oldest_utc, r.newest_utc
        FROM mon.BackupInventoryDaily AS r
        WHERE r.snapshot_date = (SELECT MAX(snapshot_date) FROM mon.BackupInventoryDaily)
          AND r.database_name LIKE @Database;

    IF @Live = 1
        SELECT r.database_name AS [Database], r.backup_type AS [Type], r.status AS [Status], r.backup_count AS [Count],
               mon.fn_UtcToLocal(r.oldest_utc, @tz) AS [Oldest (local)], mon.fn_UtcToLocal(r.newest_utc, @tz) AS [Newest (local)],
               r.retention_days AS [Retention days], r.target_days AS [Target days], r.gaps AS [Gaps],
               mon.fn_Duration(r.avg_interval_min * 60) AS [Avg interval],
               CONVERT(decimal(19,2), r.avg_bytes / 1073741824.0) AS [Avg GB], CONVERT(decimal(19,2), r.total_bytes / 1073741824.0) AS [Total GB],
               r.files_total AS [Files made], r.files_24h AS [Files 24h], r.files_on_storage AS [Files on storage],
               r.storage_basis AS [On-storage basis], r.storage_days AS [Storage policy days],
               r.source_name AS [Source]
        FROM #R AS r
        ORDER BY CASE r.status WHEN 'NONE' THEN 0 WHEN 'SHORT' THEN 1 WHEN 'POLICY' THEN 2 WHEN 'GAPS' THEN 3 WHEN 'OK' THEN 4 ELSE 5 END,
                 r.database_name, CASE r.backup_type WHEN 'FULL' THEN 1 WHEN 'DIFF' THEN 2 ELSE 3 END;
    ELSE
        SELECT r.snapshot_date AS [Snapshot], r.database_name AS [Database], r.backup_type AS [Type], r.status AS [Status],
               r.backup_count AS [Count], mon.fn_UtcToLocal(r.oldest_utc, @tz) AS [Oldest (local)],
               mon.fn_UtcToLocal(r.newest_utc, @tz) AS [Newest (local)], r.retention_days AS [Retention days],
               r.target_days AS [Target days], r.gaps AS [Gaps], CONVERT(decimal(19,2), r.total_bytes / 1073741824.0) AS [Total GB],
               r.files_total AS [Files made], r.files_24h AS [Files 24h], r.files_on_storage AS [Files on storage],
               r.storage_basis AS [On-storage basis], r.storage_days AS [Storage policy days],
               r.source_name AS [Source]
        FROM mon.BackupInventoryDaily AS r
        WHERE r.snapshot_date = (SELECT MAX(snapshot_date) FROM mon.BackupInventoryDaily)
          AND r.database_name LIKE @Database
        ORDER BY CASE r.status WHEN 'NONE' THEN 0 WHEN 'SHORT' THEN 1 WHEN 'GAPS' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
                 r.database_name, r.backup_type;

    /* Totals per backup type: files made / still on storage / policy. */
    SELECT r.backup_type AS [Type], COUNT(*) AS [Databases], SUM(r.backup_count) AS [Backups recorded],
           SUM(r.files_total) AS [Files made], SUM(r.files_24h) AS [Files last 24h],
           SUM(r.files_on_storage) AS [Files on storage (known)],
           SUM(CASE WHEN r.storage_basis = 'not declared' THEN 1 ELSE 0 END) AS [DBs without declared storage policy],
           CONVERT(decimal(19,1), SUM(r.total_bytes) / 1073741824.0) AS [Total GB],
           MIN(r.oldest_utc) AS [Oldest UTC], MAX(r.newest_utc) AS [Newest UTC]
    FROM #R AS r
    WHERE r.status NOT IN ('OFF', 'N/A')
    GROUP BY r.backup_type
    ORDER BY CASE r.backup_type WHEN 'FULL' THEN 1 WHEN 'DIFF' THEN 2 ELSE 3 END;

    /* Trend: count and total size per day for the last 30 snapshots. */
    SELECT r.snapshot_date AS [Snapshot], r.backup_type AS [Type], SUM(r.backup_count) AS [Backups],
           SUM(r.files_on_storage) AS [Files on storage],
           CONVERT(decimal(19,1), SUM(r.total_bytes) / 1073741824.0) AS [Total GB],
           SUM(CASE WHEN r.status IN ('NONE', 'SHORT', 'GAPS', 'POLICY') THEN 1 ELSE 0 END) AS [Databases with problems]
    FROM mon.BackupInventoryDaily AS r
    WHERE r.snapshot_date >= DATEADD(DAY, -30, CONVERT(date, SYSUTCDATETIME()))
      AND r.database_name LIKE @Database
    GROUP BY r.snapshot_date, r.backup_type
    ORDER BY r.snapshot_date DESC, r.backup_type;
END;
GO

/* ---------- Datasets for the SSMS custom report (MON_Checks_and_Retention.rdl) ---------- */

CREATE OR ALTER PROCEDURE mon.usp_ReportChecks
AS
BEGIN
    SET NOCOUNT ON;
    /* Long format: one row per database x check; the report pivots it into a matrix. */
    SELECT c.database_name, k.check_code, k.display_name, k.sort_order,
           CASE WHEN k.check_code = 'MONITORED' THEN CASE WHEN c.monitored = 1 THEN 'ON' ELSE 'OFF' END
                WHEN c.monitored = 0 THEN 'NA'
                WHEN k.check_code = 'LOG' AND ISNULL(s.recovery_model, N'FULL') <> N'FULL' THEN 'NA'
                WHEN f.is_enabled = 1 THEN 'ON' ELSE 'OFF' END AS state,
           ISNULL(s.recovery_model, N'?') AS recovery_model, c.notes
    FROM mon.DatabaseCheck AS c
    CROSS JOIN mon.CheckCatalog AS k
    LEFT JOIN mon.vw_DatabaseCheckFlat AS f ON f.database_name = c.database_name AND f.check_code = k.check_code
    LEFT JOIN mon.DatabaseStatus AS s ON s.database_name = c.database_name
    WHERE k.scope = 'DATABASE'
    UNION ALL
    SELECT N'(server)', s.check_code, s.display_name, k.sort_order,
           CASE WHEN s.is_enabled = 1 THEN 'ON' ELSE 'OFF' END, N'', s.notes
    FROM mon.ServerCheck AS s JOIN mon.CheckCatalog AS k ON k.check_code = s.check_code;
END;
GO

CREATE OR ALTER PROCEDURE mon.usp_ReportRetention
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');
    SELECT r.database_name, r.backup_type, r.status, r.backup_count,
           CONVERT(nvarchar(16), mon.fn_UtcToLocal(r.oldest_utc, @tz), 120) AS oldest_local,
           CONVERT(nvarchar(16), mon.fn_UtcToLocal(r.newest_utc, @tz), 120) AS newest_local,
           r.retention_days, r.target_days, ISNULL(r.gaps, 0) AS gaps,
           mon.fn_Duration(r.avg_interval_min * 60) AS avg_interval,
           CONVERT(decimal(19,2), r.avg_bytes / 1073741824.0) AS avg_gb,
           CONVERT(decimal(19,2), r.total_bytes / 1073741824.0) AS total_gb,
           r.source_name,
           CASE r.status WHEN 'NONE' THEN 0 WHEN 'SHORT' THEN 1 WHEN 'POLICY' THEN 2 WHEN 'GAPS' THEN 3 WHEN 'OK' THEN 4 ELSE 5 END AS sort_key,
           r.files_total, r.files_24h, r.files_on_storage, r.storage_basis, r.storage_days
    FROM mon.vw_BackupRetention AS r
    WHERE r.status <> 'OFF';
END;
GO
