/* ---- Job: DatabaseBackup - USER_DATABASES - FULL   (Sunday 01:00) ---------- */
EXECUTE dbo.DatabaseBackup
    @Databases        = 'USER_DATABASES',
    @Directory        = 'E:\mssql\backup',
    @BackupType       = 'FULL',
    @Compress         = 'Y',            /* inherits instance ZSTD default */
    @CheckSum         = 'Y',
    @Verify           = 'N',            /* verified by the weekly restore+CHECKDB instead */
    @NumberOfFiles    = 4,
    @MaxTransferSize  = 4194304,
    @BufferCount      = 100,
    @BlockSize        = 65536,
    @CleanupTime      = 336,            /* 14 days; align with your retention */
    @CleanupMode      = 'AFTER_BACKUP',
    @AvailabilityGroupBackupPreference = 'Y',   /* honours AG backup-preference; job exists on all replicas */
    @LogToTable       = 'Y',
    @Execute          = 'Y';

/* ---- Job: DatabaseBackup - USER_DATABASES - DIFF   (every 6 h, skip Sunday 01:00 slot) --- */
EXECUTE dbo.DatabaseBackup
    @Databases        = 'USER_DATABASES',
    @Directory        = 'E:\mssql\backup',
    @BackupType       = 'DIFF',
    @Compress         = 'Y',
    @CheckSum         = 'Y',
    @Verify           = 'N',
    @NumberOfFiles    = 2,
    @MaxTransferSize  = 4194304,
    @BufferCount      = 50,
    @ModificationLevel = 50,            /* if >50% extents changed, take a FULL instead — a diff that big restores slower than a full */
    @ChangeBackupType = 'Y',            /* also takes FULL automatically if no base exists (new DB) */
    @CleanupTime      = 336,
    @AvailabilityGroupBackupPreference = 'Y',
    @LogToTable       = 'Y',
    @Execute          = 'Y';

/* ---- Job: DatabaseBackup - USER_DATABASES - LOG    (every 15 min) ---------- */
EXECUTE dbo.DatabaseBackup
    @Databases        = 'USER_DATABASES',
    @Directory        = 'E:\mssql\backup',
    @BackupType       = 'LOG',
    @Compress         = 'Y',
    @CheckSum         = 'Y',
    @Verify           = 'N',
    @NumberOfFiles    = 1,
    @MaxTransferSize  = 1048576,
    @BufferCount      = 20,
    @LogSizeSinceLastLogBackup = 1024,  /* skip if <1 GB of new log AND less than @TimeSinceLastLogBackup */
    @TimeSinceLastLogBackup    = 3600,  /* ... but never go more than 1 h without one */
    @ChangeBackupType = 'Y',            /* FULL if no chain exists yet */
    @CleanupTime      = 336,
    @AvailabilityGroupBackupPreference = 'Y',
    @LogToTable       = 'Y',
    @Execute          = 'Y';

/* ---- Ad hoc COPY_ONLY (manual / refresh jobs) --------------------------------- */
EXECUTE dbo.DatabaseBackup
    @Databases = 'BDBPayrollLive', @Directory = 'E:\mssql\backup\adhoc',
    @BackupType = 'FULL', @CopyOnly = 'Y',
    @Compress = 'Y', @CheckSum = 'Y', @NumberOfFiles = 4,
    @MaxTransferSize = 4194304, @BufferCount = 100,
    @LogToTable = 'Y', @Execute = 'Y';


-------------

/* Every full since Sunday; anything with is_copy_only = 0 that isn't yours is a broken chain */
SELECT backup_start_date, is_copy_only, user_name, checkpoint_lsn, differential_base_lsn,
       bmf.physical_device_name
FROM   msdb.dbo.backupset bs
JOIN   msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE  bs.database_name = N'BDBPayrollLive' AND bs.type = 'D'
  AND  bs.backup_start_date >= DATEADD(DAY, -8, SYSDATETIME())
ORDER BY backup_start_date;

/* Which full the current diffs actually depend on */
SELECT DISTINCT differential_base_lsn, differential_base_guid
FROM   msdb.dbo.backupset
WHERE  database_name = N'BDBPayrollLive' AND type = 'I'
  AND  backup_start_date >= DATEADD(DAY, -8, SYSDATETIME());

---------------------------------

EXEC dbo.sp_DatabaseRestore
     @Database                = N'BDBPayrollLive',
     @RestoreDatabaseName     = N'BDBPayrollLive_check',
     @BackupPathFull          = N'E:\mssql\backup\AG1\BDBPayrollLive\FULL\',
     @BackupPathDiff          = N'E:\mssql\backup\AG1\BDBPayrollLive\DIFF\',
     @BackupPathLog           = N'E:\mssql\backup\AG1\BDBPayrollLive\LOG\',
     @MoveFiles               = 1,
     @MoveDataDrive           = N'M:\mssql\data\',
     @MoveLogDrive            = N'S:\mssql\log\',
     @RestoreDiff             = 1,
     @ContinueLogs            = 0,
     @RunRecovery             = 1,
     @ForceSimpleRecovery     = 1,      /* replaces my manual ALTER DATABASE */
     @ExistingDBAction        = 3,
     @FixOrphanUsers          = 1,      /* only worth it if someone will log in to the copy */
     @DatabaseOwner           = N'sa',
     @BufferCount             = 100,
     @MaxTransferSize         = 4194304,
     @SimpleFolderEnumeration = 1,
     @RunCheckDB              = 0,      /* deliberately: see below */
     @TestRestore             = 0,
     @Execute                 = 'Y';

/* CHECKDB with the two knobs sp_DatabaseRestore's @RunCheckDB doesn't pass through */
EXEC dbo.DatabaseIntegrityCheck
     @Databases   = N'BDBPayrollLive_check',
     @CheckCommands = 'CHECKDB',
     @DataPurity  = 'Y',
     @MaxDOP      = 8,
     @LogToTable  = 'Y';

-----------------------------------------
/* ============================================================
   VERIFY — what actually happened, from system tables + CommandLog
   ============================================================ */

/* Restore chain applied, in order, with throughput (msdb) */
SELECT rh.restore_type, rh.restore_date,
       DATEDIFF(SECOND, LAG(rh.restore_date) OVER (ORDER BY rh.restore_date), rh.restore_date) AS sec_since_prev,
       bs.backup_start_date, bs.first_lsn, bs.last_lsn,
       CAST(bs.backup_size/1048576.0 AS decimal(12,1)) AS mb,
       bmf.physical_device_name
FROM   msdb.dbo.restorehistory rh
JOIN   msdb.dbo.backupset bs          ON bs.backup_set_id = rh.backup_set_id
JOIN   msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE  rh.destination_database_name = N'BDBPayrollLive_check'
  AND  rh.restore_date >= DATEADD(HOUR, -12, SYSDATETIME())
ORDER BY rh.restore_date;

/* Exact restore seconds per file from the errorlog */
DECLARE @log TABLE (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));
INSERT @log EXEC xp_readerrorlog 0, 1, N'successfully processed', N'RESTORE';
SELECT LogDate, [Text] FROM @log WHERE [Text] LIKE '%BDBPayrollLive_check%' ORDER BY LogDate;

/* CHECKDB duration + result from CommandLog */
SELECT DatabaseName, CommandType, StartTime, EndTime,
       DATEDIFF(SECOND, StartTime, EndTime) AS seconds, ErrorNumber, ErrorMessage, Command
FROM   dbo.CommandLog
WHERE  DatabaseName = N'BDBPayrollLive_check' AND CommandType = 'DBCC_CHECKDB'
ORDER BY ID DESC;

/* Last known-good CHECKDB stamped in the boot page */
DBCC DBINFO (N'BDBPayrollLive_check') WITH TABLERESULTS;   /* look for dbi_dbccLastKnownGood */

/* Throughput per backup, from msdb — compare before/after the change */
SELECT database_name, type, backup_start_date,
       DATEDIFF(SECOND, backup_start_date, backup_finish_date) AS sec,
       CAST(backup_size/1048576.0 AS decimal(12,0))            AS mb,
       CAST(compressed_backup_size/1048576.0 AS decimal(12,0)) AS compressed_mb,
       CAST(backup_size / NULLIF(DATEDIFF(SECOND, backup_start_date, backup_finish_date),0) / 1048576.0 AS decimal(12,1)) AS mb_per_sec,
       CAST(1.0 * backup_size / NULLIF(compressed_backup_size,0) AS decimal(6,2)) AS ratio,
       compression_algorithm,                 /* 2022+ column */
       (SELECT COUNT(*) FROM msdb.dbo.backupmediafamily f WHERE f.media_set_id = bs.media_set_id) AS files,
       is_copy_only, has_backup_checksums
FROM   msdb.dbo.backupset bs
WHERE  database_name = N'BDBPayrollLive' AND backup_start_date >= DATEADD(DAY, -14, SYSDATETIME())
ORDER BY backup_start_date DESC;

/* What's the backup waiting on right now? (run during a full)
   BACKUPIO = source disk read; BACKUPBUFFER = raise BUFFERCOUNT;
   BACKUPTHREAD / ASYNC_IO_COMPLETION = destination writes */
SELECT r.session_id, r.command, r.percent_complete, r.wait_type, r.wait_time,
       DATEADD(SECOND, r.estimated_completion_time/1000, SYSDATETIME()) AS eta
FROM   sys.dm_exec_requests r
WHERE  r.command LIKE 'BACKUP%' OR r.command LIKE 'RESTORE%';


/* Same DB, three levels, to NUL so disk write speed doesn't muddy the result.
   Reads the full DB three times — run on BDBPayrollLive_check, not on the primary. */
DECLARE @lvl TABLE (lvl nvarchar(10));
INSERT @lvl VALUES (N'LOW'), (N'MEDIUM'), (N'HIGH');

DECLARE @l nvarchar(10), @sql nvarchar(max), @t0 datetime2(0);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT lvl FROM @lvl;
OPEN c; FETCH c INTO @l;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @t0 = SYSDATETIME();
    SET @sql = N'BACKUP DATABASE [BDBPayrollLive_check] TO DISK = N''NUL'', DISK = N''NUL'', DISK = N''NUL'', DISK = N''NUL''
                 WITH COPY_ONLY, COMPRESSION (ALGORITHM = ZSTD, LEVEL = ' + @l + N'), CHECKSUM,
                      MAXTRANSFERSIZE = 4194304, BUFFERCOUNT = 100;';
    EXEC sys.sp_executesql @sql;
    PRINT CONCAT(@l, ': ', DATEDIFF(SECOND, @t0, SYSDATETIME()), ' s');
    FETCH c INTO @l;
END
CLOSE c; DEALLOCATE c;

/* Sizes + CPU-ish proxy per level */
SELECT TOP (3) backup_start_date, compression_algorithm,
       DATEDIFF(SECOND, backup_start_date, backup_finish_date) AS sec,
       CAST(backup_size/1073741824.0 AS decimal(10,1))            AS gb,
       CAST(compressed_backup_size/1073741824.0 AS decimal(10,1)) AS compressed_gb,
       CAST(1.0*backup_size/NULLIF(compressed_backup_size,0) AS decimal(6,2)) AS ratio
FROM   msdb.dbo.backupset
WHERE  database_name = N'BDBPayrollLive_check' AND is_copy_only = 1
ORDER BY backup_start_date DESC;


/* Look at the current step text first */
SELECT j.name, s.step_id, s.command
FROM   msdb.dbo.sysjobs j
JOIN   msdb.dbo.sysjobsteps s ON s.job_id = j.job_id
WHERE  j.name LIKE 'DatabaseBackup%';

/* Inject the two parameters right after @Compress = 'Y' in every DatabaseBackup step.
   Adjust the search string to match your steps' exact spacing/quoting. */
DECLARE @job sysname, @step int, @cmd nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT j.name, s.step_id, s.command
    FROM   msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id
    WHERE  j.name LIKE 'DatabaseBackup%' AND s.command LIKE '%@Compress = ''Y''%'
      AND  s.command NOT LIKE '%@CompressionAlgorithm%';
OPEN c; FETCH c INTO @job, @step, @cmd;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @cmd = REPLACE(@cmd, N'@Compress = ''Y''',
               N'@Compress = ''Y'', @CompressionAlgorithm = ''ZSTD'', @CompressionLevel = ''LOW''');
    EXEC msdb.dbo.sp_update_jobstep @job_name = @job, @step_id = @step, @command = @cmd;
    PRINT CONCAT('updated: ', @job, ' step ', @step);
    FETCH c INTO @job, @step, @cmd;
END
CLOSE c; DEALLOCATE c;
/* UNDO: re-run with the REPLACE arguments swapped */


SELECT r.session_id, r.command, r.percent_complete, r.wait_type,
       DATEADD(SECOND, r.estimated_completion_time/1000, SYSDATETIME()) AS eta,
       explicit_algorithm = CASE WHEN t.text LIKE '%ALGORITHM%' THEN
                                 SUBSTRING(t.text, CHARINDEX('ALGORITHM', t.text), 40)
                                 ELSE 'instance default: ' +
                                      (SELECT CAST(value_in_use AS varchar(20)) FROM sys.configurations
                                       WHERE name = 'backup compression algorithm') END,
       explicit_level     = CASE WHEN t.text LIKE '%LEVEL%' THEN
                                 SUBSTRING(t.text, CHARINDEX('LEVEL', t.text), 15) ELSE 'default (LOW)' END,
       t.text
FROM   sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE  r.command LIKE 'BACKUP%';


SELECT bs.database_name, bs.type, bs.backup_start_date,
       bs.compression_algorithm,                                  /* NULL = not compressed; MS_XPRESS / ZSTD / QAT_DEFLATE */
       CAST(1.0*bs.backup_size/NULLIF(bs.compressed_backup_size,0) AS decimal(6,2)) AS ratio,
       DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date) AS sec,
       CAST(bs.backup_size/1048576.0 / NULLIF(DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date),0) AS decimal(10,1)) AS mb_per_sec,
       bs.has_backup_checksums, bs.is_copy_only, bs.user_name,
       files = (SELECT COUNT(*) FROM msdb.dbo.backupmediafamily f WHERE f.media_set_id = bs.media_set_id)
FROM   msdb.dbo.backupset bs
WHERE  bs.database_name = N'BDBPayrollLive'
  AND  bs.backup_start_date >= DATEADD(DAY, -30, SYSDATETIME())
ORDER BY bs.backup_start_date DESC;



