/* ============================================================
   STEP 0: Confirm the backup/restore option is enabled
   ============================================================ */
EXEC msdb.dbo.rds_task_status;           /* if the proc exists, the option is on */

/* Optional: is any backup/restore already running? Only one
   task per database at a time. */
EXEC msdb.dbo.rds_task_status @db_name = 'YourDB';


/* ============================================================
   STEP 1: Full backup to S3
   ============================================================ */
EXEC msdb.dbo.rds_backup_database
     @source_db_name      = N'YourDB',
     @s3_arn_to_backup_to = N'arn:aws:s3:::your-bucket/backups/YourDB_FULL_20260828.bak',
     @overwrite_s3_backup_file = 1,      /* 1 = overwrite if exists, 0 = fail */
     @type                = 'FULL';      /* 'FULL' or 'DIFFERENTIAL' */

/* Encrypted variant: add
     @kms_master_key_arn = N'arn:aws:kms:us-east-1:123456789012:key/xxxx'
   Multi-file (recommended > ~1 TB, and you MUST use it for files > 5 TB):
     @s3_arn_to_backup_to = N'arn:aws:s3:::your-bucket/backups/YourDB_FULL*.bak',
     @number_of_files = 4                                                    */

/* Returns a task_id — keep it. */


/* ============================================================
   STEP 2: Watch progress
   ============================================================ */
EXEC msdb.dbo.rds_task_status @db_name = 'YourDB';
/* Columns of interest: task_id, task_type, lifecycle
   (CREATED / IN_PROGRESS / SUCCESS / ERROR / CANCEL_REQUESTED / CANCELLED),
   % complete, duration(mins), task_info (error text lives here) */

/* Cancel a running one if needed */
/* EXEC msdb.dbo.rds_cancel_task @task_id = 123; */


/* ============================================================
   STEP 3: Backup history
   ============================================================ */

/* A) RDS native task history — S3 backups/restores only, last ~36 h */
EXEC msdb.dbo.rds_task_status;                          /* all dbs */
EXEC msdb.dbo.rds_task_status @db_name = 'YourDB';      /* one db  */

/* B) Standard msdb backup history — includes RDS automated snapshots
      (they show as VDI/snapshot backups) AND your S3 native backups.
      Retained longer than rds_task_status. */
SELECT TOP (100)
    bs.database_name,
    bs.backup_start_date,
    bs.backup_finish_date,
    DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date) AS duration_sec,
    CASE bs.type
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END                                   AS backup_type,
    CAST(bs.backup_size / 1048576.0 AS DECIMAL(18,2))            AS size_mb,
    CAST(bs.compressed_backup_size / 1048576.0 AS DECIMAL(18,2)) AS compressed_mb,
    bs.is_copy_only,
    bs.is_snapshot,
    bmf.physical_device_name,
    bmf.device_type,           /* 2 = disk, 7 = virtual device (snapshot / S3 stream) */
    bs.recovery_model,
    bs.first_lsn,
    bs.last_lsn,
    bs.checkpoint_lsn,
    bs.database_backup_lsn
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.database_name = N'YourDB'
ORDER BY bs.backup_start_date DESC;

/* C) Last full / diff / log per database at a glance */
SELECT
    d.name,
    d.recovery_model_desc,
    MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) AS last_full,
    MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END) AS last_diff,
    MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) AS last_log
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset bs ON bs.database_name = d.name
WHERE d.database_id > 4 AND d.name <> 'rdsadmin'
GROUP BY d.name, d.recovery_model_desc
ORDER BY d.name;
