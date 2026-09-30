/*
    MS-APP-STG / Amazon RDS for SQL Server
    OPS Backup and Ola Hallengren Maintenance Monitor
    Revision 4 - complete live database inventory in every report

    What this installer creates
      - OPS database (only when missing)
      - monitor schema and configuration tables
      - collection of RDS native FULL/DIFF tasks, msdb backup history,
        RDS automated transaction-log metadata, and SQL Agent outcomes
      - auto-discovery of standard Ola Hallengren maintenance jobs
      - all SQL Agent failures/cancellations from the last 12 hours
      - deadlocks from the system_health ring buffer, with XML retained in OPS
      - high-signal RDS SQL error-log entries and SQL-visible capacity anomalies
      - 90-day monitoring history
      - de-duplicated immediate failure/overdue email alerts
      - daily highlighted HTML health report at 08:00 America/New_York (DST aware)
      - SQL Agent jobs running every 5 minutes and hourly

    Deployment values selected by the DBA team
      Server label : MS-APP-STG
      OPS database : OPS
      Mail profile : Notifications
      Recipients   : aleksey_kokit@miopartners.com
      Thresholds  : FULL 24h, DIFF/effective data backup 6h, LOG 30m

    RDS notes
      - RDS SQL Agent operator notifications are not used. Email is sent by
        msdb.dbo.sp_send_dbmail.
      - RDS native FULL/DIFF tasks are asynchronous; final status is collected
        from msdb.dbo.rds_task_status.
      - RDS automated transaction-log backups are not assumed to exist in
        msdb.dbo.backupset. When available, the monitor reads
        msdb.dbo.rds_fn_list_tlog_backup_metadata.
      - SQL cannot verify an S3 lifecycle/retention rule. The report therefore
        shows backup age, task duration, S3 object ARN, and msdb expiration date
        when present. OPS monitoring history is retained for 90 days.
      - The installer does not SELECT from protected msdb job-step or schedule
        catalogs. Existing job steps and schedules are updated through the
        supported SQL Agent stored procedures.

    Run this entire file as the RDS master login in SSMS. The installer is
    idempotent: it preserves policy overrides and updates only its own jobs.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE [OPS];
GO

IF SCHEMA_ID(N'monitor') IS NULL
    EXEC(N'CREATE SCHEMA monitor AUTHORIZATION dbo;');
GO

/* ---------- Configuration and history tables ---------- */

IF OBJECT_ID(N'monitor.Settings', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.Settings
    (
        settings_id                 tinyint       NOT NULL CONSTRAINT PK_Settings PRIMARY KEY,
        server_label                sysname       NOT NULL,
        mail_profile                sysname       NOT NULL,
        recipients                  nvarchar(4000) NOT NULL,
        report_hour_eastern         tinyint       NOT NULL,
        history_retention_days      smallint      NOT NULL,
        repeat_critical_minutes     int           NOT NULL,
        send_immediate_alerts       bit           NOT NULL,
        send_daily_report           bit           NOT NULL,
        modified_utc                datetime2(0)   NOT NULL CONSTRAINT DF_Settings_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT CK_Settings_Singleton CHECK (settings_id = 1),
        CONSTRAINT CK_Settings_Hour CHECK (report_hour_eastern BETWEEN 0 AND 23),
        CONSTRAINT CK_Settings_Retention CHECK (history_retention_days BETWEEN 7 AND 3650)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM monitor.Settings WHERE settings_id = 1)
BEGIN
    INSERT monitor.Settings
    (
        settings_id, server_label, mail_profile, recipients,
        report_hour_eastern, history_retention_days,
        repeat_critical_minutes, send_immediate_alerts, send_daily_report
    )
    VALUES
    (1, N'MS-APP-STG', N'Notifications', N'aleksey_kokit@miopartners.com',
     8, 90, 1440, 1, 1);
END;
ELSE
BEGIN
    UPDATE monitor.Settings
       SET server_label = N'MS-APP-STG',
           mail_profile = N'Notifications',
           recipients = N'aleksey_kokit@miopartners.com',
           report_hour_eastern = 8,
           modified_utc = SYSUTCDATETIME()
     WHERE settings_id = 1;
END;
GO

IF OBJECT_ID(N'monitor.DatabaseBackupPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.DatabaseBackupPolicy
    (
        database_name               sysname      NOT NULL CONSTRAINT PK_DatabaseBackupPolicy PRIMARY KEY,
        is_enabled                  bit          NOT NULL CONSTRAINT DF_DBPolicy_Enabled DEFAULT (1),
        require_full                bit          NOT NULL CONSTRAINT DF_DBPolicy_Full DEFAULT (1),
        require_diff                bit          NOT NULL CONSTRAINT DF_DBPolicy_Diff DEFAULT (1),
        require_log                 bit          NOT NULL CONSTRAINT DF_DBPolicy_Log DEFAULT (1),
        full_max_age_minutes        int          NOT NULL CONSTRAINT DF_DBPolicy_FullAge DEFAULT (1440),
        diff_max_age_minutes        int          NOT NULL CONSTRAINT DF_DBPolicy_DiffAge DEFAULT (360),
        log_max_age_minutes         int          NOT NULL CONSTRAINT DF_DBPolicy_LogAge DEFAULT (30),
        notes                       nvarchar(1000) NULL,
        added_utc                   datetime2(0)  NOT NULL CONSTRAINT DF_DBPolicy_Added DEFAULT SYSUTCDATETIME(),
        modified_utc                datetime2(0)  NOT NULL CONSTRAINT DF_DBPolicy_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT CK_DBPolicy_Ages CHECK
        (
            full_max_age_minutes > 0 AND diff_max_age_minutes > 0 AND log_max_age_minutes > 0
        )
    );
END;
GO

IF OBJECT_ID(N'monitor.RdsTaskHistory', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.RdsTaskHistory
    (
        task_id                     int            NOT NULL CONSTRAINT PK_RdsTaskHistory PRIMARY KEY,
        task_type                   nvarchar(128)  NULL,
        database_name               sysname        NULL,
        percent_complete            decimal(9,2)   NULL,
        duration_minutes            int            NULL,
        lifecycle                   nvarchar(40)   NULL,
        task_info                   nvarchar(max)  NULL,
        last_updated_server_time    datetime2(0)   NULL,
        created_at_server_time      datetime2(0)   NULL,
        s3_object_arn               nvarchar(4000) NULL,
        first_collected_utc          datetime2(0)   NOT NULL CONSTRAINT DF_RdsTask_First DEFAULT SYSUTCDATETIME(),
        last_collected_utc           datetime2(0)   NOT NULL CONSTRAINT DF_RdsTask_Last DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_RdsTask_DbTypeTime
        ON monitor.RdsTaskHistory(database_name, task_type, created_at_server_time DESC);
END;
GO

IF OBJECT_ID(N'monitor.TlogBackupHistory', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.TlogBackupHistory
    (
        database_name               sysname         NOT NULL,
        rds_backup_seq_id           int             NOT NULL,
        backup_file_time_utc        datetime2(0)    NOT NULL,
        starting_lsn                numeric(25,0)   NULL,
        ending_lsn                  numeric(25,0)   NULL,
        is_log_chain_broken         bit             NULL,
        file_size_bytes             bigint          NULL,
        error_message               nvarchar(4000)  NULL,
        collected_utc               datetime2(0)    NOT NULL CONSTRAINT DF_Tlog_Collected DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_TlogBackupHistory PRIMARY KEY(database_name, rds_backup_seq_id)
    );
    CREATE INDEX IX_TlogBackup_Time
        ON monitor.TlogBackupHistory(database_name, backup_file_time_utc DESC);
END;
GO

IF OBJECT_ID(N'monitor.BackupSample', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.BackupSample
    (
        sample_id                   bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_BackupSample PRIMARY KEY,
        captured_utc                datetime2(0)   NOT NULL,
        captured_server_time        datetime2(0)   NOT NULL,
        database_name               sysname        NOT NULL,
        database_state              nvarchar(60)   NOT NULL,
        recovery_model              nvarchar(60)   NOT NULL,
        full_finish_time            datetime2(0)   NULL,
        full_duration_seconds       int            NULL,
        full_size_bytes             bigint         NULL,
        full_source                 nvarchar(40)   NULL,
        full_location               nvarchar(4000) NULL,
        full_expiration_time        datetime2(0)   NULL,
        diff_finish_time            datetime2(0)   NULL,
        diff_duration_seconds       int            NULL,
        diff_size_bytes             bigint         NULL,
        diff_source                 nvarchar(40)   NULL,
        diff_location               nvarchar(4000) NULL,
        diff_expiration_time        datetime2(0)   NULL,
        log_finish_time             datetime2(0)   NULL,
        log_duration_seconds        int            NULL,
        log_size_bytes              bigint         NULL,
        log_source                  nvarchar(40)   NULL,
        log_chain_broken            bit            NULL,
        log_visibility              nvarchar(40)   NOT NULL,
        collection_note             nvarchar(2000) NULL
    );
    CREATE INDEX IX_BackupSample_DbTime
        ON monitor.BackupSample(database_name, captured_utc DESC);
END;
GO

IF OBJECT_ID(N'monitor.MaintenanceJobPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.MaintenanceJobPolicy
    (
        job_id                      uniqueidentifier NOT NULL CONSTRAINT PK_MaintenanceJobPolicy PRIMARY KEY,
        job_name                    sysname          NOT NULL,
        maintenance_type            nvarchar(40)     NOT NULL,
        is_monitored                bit              NOT NULL CONSTRAINT DF_JobPolicy_Monitored DEFAULT (1),
        max_hours_since_success     decimal(9,2)     NOT NULL,
        auto_discovered             bit              NOT NULL CONSTRAINT DF_JobPolicy_Auto DEFAULT (1),
        last_seen_utc               datetime2(0)     NOT NULL CONSTRAINT DF_JobPolicy_Seen DEFAULT SYSUTCDATETIME(),
        notes                       nvarchar(1000)   NULL,
        CONSTRAINT UQ_MaintenanceJobPolicy_Name UNIQUE(job_name),
        CONSTRAINT CK_JobPolicy_Age CHECK (max_hours_since_success > 0)
    );
END;
GO

IF OBJECT_ID(N'monitor.AgentJobRun', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.AgentJobRun
    (
        job_id                      uniqueidentifier NOT NULL,
        instance_id                int              NOT NULL,
        job_name                    sysname          NOT NULL,
        run_status                  int              NOT NULL,
        run_start_server_time       datetime2(0)     NOT NULL,
        run_duration_seconds        int              NOT NULL,
        message                     nvarchar(4000)   NULL,
        imported_utc                datetime2(0)     NOT NULL CONSTRAINT DF_AgentJobRun_Imported DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_AgentJobRun PRIMARY KEY(job_id, instance_id)
    );
    CREATE INDEX IX_AgentJobRun_NameTime
        ON monitor.AgentJobRun(job_name, run_start_server_time DESC);
END;
GO

IF OBJECT_ID(N'monitor.CollectorRun', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.CollectorRun
    (
        collector_run_id            bigint          IDENTITY(1,1) NOT NULL CONSTRAINT PK_CollectorRun PRIMARY KEY,
        started_utc                 datetime2(0)    NOT NULL,
        finished_utc                datetime2(0)    NULL,
        succeeded                   bit             NULL,
        backup_rows                 int             NULL,
        job_rows                    int             NULL,
        error_number                int             NULL,
        error_message               nvarchar(2048)  NULL
    );
END;
GO

IF OBJECT_ID(N'monitor.AlertState', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.AlertState
    (
        alert_key                   nvarchar(450)  NOT NULL CONSTRAINT PK_AlertState PRIMARY KEY,
        alert_kind                  nvarchar(20)   NOT NULL,
        category                    nvarchar(40)   NOT NULL,
        severity                    nvarchar(20)   NOT NULL,
        summary                     nvarchar(1000) NOT NULL,
        detail                      nvarchar(4000) NULL,
        is_active                   bit            NOT NULL,
        first_seen_utc              datetime2(0)   NOT NULL,
        last_seen_utc               datetime2(0)   NOT NULL,
        last_sent_utc               datetime2(0)   NULL,
        resolved_utc                datetime2(0)   NULL
    );
END;
GO

IF OBJECT_ID(N'monitor.NotificationLog', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.NotificationLog
    (
        notification_id             bigint          IDENTITY(1,1) NOT NULL CONSTRAINT PK_NotificationLog PRIMARY KEY,
        notification_type           nvarchar(20)    NOT NULL,
        queued_utc                  datetime2(0)    NOT NULL,
        report_date_eastern         date            NULL,
        subject                     nvarchar(255)   NOT NULL,
        recipients                  nvarchar(4000)  NOT NULL,
        mailitem_id                 int             NULL,
        exception_count             int             NULL
    );
    CREATE UNIQUE INDEX UX_NotificationLog_Daily
        ON monitor.NotificationLog(report_date_eastern, notification_type)
        WHERE report_date_eastern IS NOT NULL AND notification_type = N'DAILY';
END;
GO

IF OBJECT_ID(N'monitor.AgentFailureEvent', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.AgentFailureEvent
    (
        job_id                      uniqueidentifier NOT NULL,
        instance_id                int              NOT NULL,
        job_name                    sysname          NOT NULL,
        run_status                  int              NOT NULL,
        run_start_server_time       datetime2(0)     NOT NULL,
        run_duration_seconds        int              NOT NULL,
        failure_step_name           sysname          NULL,
        message                     nvarchar(4000)   NULL,
        collected_utc               datetime2(0)     NOT NULL CONSTRAINT DF_AgentFailure_Collected DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_AgentFailureEvent PRIMARY KEY(job_id, instance_id)
    );
    CREATE INDEX IX_AgentFailure_Time
        ON monitor.AgentFailureEvent(run_start_server_time DESC, job_name);
END;
GO

IF OBJECT_ID(N'monitor.DeadlockEvent', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.DeadlockEvent
    (
        deadlock_hash               binary(32)     NOT NULL CONSTRAINT PK_DeadlockEvent PRIMARY KEY,
        event_utc                   datetime2(3)   NOT NULL,
        database_name               sysname        NULL,
        victim_process_id           nvarchar(100)  NULL,
        process_count               int            NULL,
        deadlock_xml                xml            NOT NULL,
        collected_utc               datetime2(0)   NOT NULL CONSTRAINT DF_Deadlock_Collected DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_DeadlockEvent_Time
        ON monitor.DeadlockEvent(event_utc DESC, database_name);
END;
GO

IF OBJECT_ID(N'monitor.ServerErrorLogEvent', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.ServerErrorLogEvent
    (
        event_hash                  binary(32)     NOT NULL CONSTRAINT PK_ServerErrorLogEvent PRIMARY KEY,
        log_date_server_time        datetime2(0)   NOT NULL,
        process_info                nvarchar(100)  NULL,
        message                     nvarchar(4000) NOT NULL,
        collected_utc               datetime2(0)   NOT NULL CONSTRAINT DF_ServerError_Collected DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_ServerError_Time
        ON monitor.ServerErrorLogEvent(log_date_server_time DESC);
END;
GO

IF OBJECT_ID(N'monitor.DatabaseLogSample', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.DatabaseLogSample
    (
        captured_utc                datetime2(3)  NOT NULL,
        database_name               sysname       NOT NULL,
        log_size_mb                 decimal(19,2) NULL,
        log_used_percent            decimal(9,2)  NULL,
        status_code                 int           NULL,
        CONSTRAINT PK_DatabaseLogSample PRIMARY KEY(captured_utc, database_name)
    );
    CREATE INDEX IX_DatabaseLogSample_DbTime
        ON monitor.DatabaseLogSample(database_name, captured_utc DESC);
END;
GO

IF OBJECT_ID(N'monitor.StorageSample', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.StorageSample
    (
        captured_utc                datetime2(3)  NOT NULL,
        volume_mount_point          nvarchar(512) NOT NULL,
        total_bytes                 bigint        NULL,
        available_bytes             bigint        NULL,
        CONSTRAINT PK_StorageSample PRIMARY KEY(captured_utc, volume_mount_point)
    );
    CREATE INDEX IX_StorageSample_Time
        ON monitor.StorageSample(captured_utc DESC);
END;
GO

IF OBJECT_ID(N'monitor.ComponentStatus', N'U') IS NULL
BEGIN
    CREATE TABLE monitor.ComponentStatus
    (
        component_name              sysname        NOT NULL CONSTRAINT PK_ComponentStatus PRIMARY KEY,
        last_attempt_utc            datetime2(0)   NOT NULL,
        last_success_utc            datetime2(0)   NULL,
        last_error_number           int            NULL,
        last_error_message          nvarchar(2000) NULL
    );
END;
GO

/* ---------- Helper functions ---------- */

CREATE OR ALTER FUNCTION monitor.fn_HtmlEncode(@value nvarchar(max))
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

/* ---------- Collection ---------- */

CREATE OR ALTER PROCEDURE monitor.usp_SyncDatabaseBackupPolicy
AS
BEGIN
    SET NOCOUNT ON;

    /*
       Seed every SQL-visible user database. Existing rows are never overwritten,
       so DBA changes to requirements, thresholds, and enabled state are retained.
    */
    INSERT monitor.DatabaseBackupPolicy(database_name, require_log)
    SELECT d.name,
           CASE WHEN d.recovery_model_desc = N'FULL' THEN 1 ELSE 0 END
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.name <> N'rdsadmin'
      AND NOT EXISTS
          (SELECT 1
           FROM monitor.DatabaseBackupPolicy AS p
           WHERE p.database_name = d.name);
END;
GO

CREATE OR ALTER PROCEDURE monitor.usp_CollectBackupAndMaintenance
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET DEADLOCK_PRIORITY LOW;
    SET LOCK_TIMEOUT 3000;

    DECLARE @run_id bigint,
            @backup_rows int = 0,
            @job_rows int = 0,
            @tlog_note nvarchar(2000) = NULL;

    INSERT monitor.CollectorRun(started_utc) VALUES(SYSUTCDATETIME());
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
        /* Add newly created/restored databases without overwriting DBA policy changes. */
        EXEC monitor.usp_SyncDatabaseBackupPolicy;

        /* Standard Ola Hallengren job names. Policy overrides are preserved. */
        ;WITH OlaJobs AS
        (
            SELECT j.job_id, j.name,
                   CASE
                       WHEN j.name LIKE N'DatabaseBackup%LOG%'  THEN N'BACKUP_LOG'
                       WHEN j.name LIKE N'DatabaseBackup%DIFF%' THEN N'BACKUP_DIFF'
                       WHEN j.name LIKE N'DatabaseBackup%FULL%' THEN N'BACKUP_FULL'
                       WHEN j.name LIKE N'DatabaseIntegrityCheck%' THEN N'INTEGRITY_CHECK'
                       WHEN j.name LIKE N'IndexOptimize%' THEN N'INDEX_OPTIMIZE'
                       WHEN j.name = N'DBMaintenance - Daily Backups'
                         THEN N'RDS_NATIVE_BACKUP'
                       ELSE N'CLEANUP'
                   END AS maintenance_type,
                   CONVERT(decimal(9,2),
                       CASE
                           WHEN j.name LIKE N'DatabaseBackup%LOG%'  THEN 0.50
                           WHEN j.name LIKE N'DatabaseBackup%DIFF%' THEN 6.00
                           WHEN j.name LIKE N'DatabaseBackup%FULL%' THEN 24.00
                           WHEN j.name LIKE N'DatabaseIntegrityCheck%' THEN 192.00
                           WHEN j.name LIKE N'IndexOptimize%' THEN 192.00
                           WHEN j.name = N'DBMaintenance - Daily Backups'
                             THEN 24.00
                           ELSE 192.00
                       END) AS max_hours
            FROM msdb.dbo.sysjobs AS j
            WHERE j.name LIKE N'DatabaseBackup%'
               OR j.name LIKE N'DatabaseIntegrityCheck%'
               OR j.name LIKE N'IndexOptimize%'
               OR j.name = N'DBMaintenance - Daily Backups'
               OR j.name IN
                  (N'CommandLog Cleanup', N'Output File Cleanup',
                   N'sp_delete_backuphistory', N'sp_purge_jobhistory')
        )
        INSERT monitor.MaintenanceJobPolicy
            (job_id, job_name, maintenance_type, max_hours_since_success)
        SELECT o.job_id, o.name, o.maintenance_type, o.max_hours
        FROM OlaJobs AS o
        WHERE NOT EXISTS
              (SELECT 1 FROM monitor.MaintenanceJobPolicy AS p
               WHERE p.job_id = o.job_id OR p.job_name = o.name);

        UPDATE p
           SET p.job_name = j.name,
               p.last_seen_utc = SYSUTCDATETIME()
        FROM monitor.MaintenanceJobPolicy AS p
        JOIN msdb.dbo.sysjobs AS j ON j.job_id = p.job_id;

        /* Import job-level outcomes (step_id 0); use server-local time consistently. */
        INSERT monitor.AgentJobRun
        (
            job_id, instance_id, job_name, run_status,
            run_start_server_time, run_duration_seconds, message
        )
        SELECT j.job_id,
               h.instance_id,
               j.name,
               h.run_status,
               DATETIMEFROMPARTS
               (
                   h.run_date / 10000,
                   (h.run_date / 100) % 100,
                   h.run_date % 100,
                   h.run_time / 10000,
                   (h.run_time / 100) % 100,
                   h.run_time % 100,
                   0
               ),
               (h.run_duration / 10000) * 3600
                 + ((h.run_duration / 100) % 100) * 60
                 + h.run_duration % 100,
               LEFT(h.message, 4000)
        FROM msdb.dbo.sysjobhistory AS h
        JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
        JOIN monitor.MaintenanceJobPolicy AS p ON p.job_id = j.job_id
        WHERE h.step_id = 0
          AND h.run_date > 0
          AND NOT EXISTS
              (SELECT 1 FROM monitor.AgentJobRun AS x
               WHERE x.job_id = h.job_id AND x.instance_id = h.instance_id);
        SET @job_rows = @@ROWCOUNT;

        /* Collect all visible RDS backup/restore task statuses. */
        CREATE TABLE #RdsTasks
        (
            task_id                     int,
            task_type                   nvarchar(128),
            database_name               sysname,
            percent_complete_text       nvarchar(100),
            duration_minutes_text       nvarchar(100),
            lifecycle                   nvarchar(40),
            task_info                   nvarchar(max),
            last_updated                datetime,
            created_at                  datetime,
            s3_object_arn               nvarchar(max),
            overwrite_s3_backup_file    nvarchar(100),
            kms_master_key_arn          nvarchar(max),
            filepath                    nvarchar(max),
            overwrite_file              nvarchar(100)
        );

        BEGIN TRY
            INSERT #RdsTasks
            EXEC msdb.dbo.rds_task_status;
        END TRY
        BEGIN CATCH
            SET @tlog_note = CONCAT(N'rds_task_status unavailable: ', ERROR_MESSAGE());
        END CATCH;

        UPDATE t
           SET task_type = r.task_type,
               database_name = r.database_name,
               percent_complete = TRY_CONVERT(decimal(9,2), REPLACE(r.percent_complete_text, N'%', N'')),
               duration_minutes = TRY_CONVERT(int, r.duration_minutes_text),
               lifecycle = r.lifecycle,
               task_info = r.task_info,
               last_updated_server_time = r.last_updated,
               created_at_server_time = r.created_at,
               s3_object_arn = r.s3_object_arn,
               last_collected_utc = SYSUTCDATETIME()
        FROM monitor.RdsTaskHistory AS t
        JOIN #RdsTasks AS r ON r.task_id = t.task_id;

        INSERT monitor.RdsTaskHistory
        (
            task_id, task_type, database_name, percent_complete,
            duration_minutes, lifecycle, task_info,
            last_updated_server_time, created_at_server_time, s3_object_arn
        )
        SELECT r.task_id, r.task_type, r.database_name,
               TRY_CONVERT(decimal(9,2), REPLACE(r.percent_complete_text, N'%', N'')),
               TRY_CONVERT(int, r.duration_minutes_text), r.lifecycle, r.task_info,
               r.last_updated, r.created_at, r.s3_object_arn
        FROM #RdsTasks AS r
        WHERE NOT EXISTS
              (SELECT 1 FROM monitor.RdsTaskHistory AS t WHERE t.task_id = r.task_id);

        /* Collect RDS automated transaction-log metadata, database by database. */
        CREATE TABLE #TlogMetadata
        (
            db_name                     sysname,
            db_id                       int,
            family_guid                 uniqueidentifier,
            rds_backup_seq_id           int,
            backup_file_epoch           bigint,
            backup_file_time_utc        datetime,
            starting_lsn                numeric(25,0),
            ending_lsn                  numeric(25,0),
            is_log_chain_broken         bit,
            file_size_bytes             bigint,
            error_message               varchar(4000)
        );

        CREATE TABLE #TlogProbe
        (
            database_name               sysname PRIMARY KEY,
            is_visible                  bit NOT NULL,
            error_message               nvarchar(2000) NULL
        );

        DECLARE @db sysname, @sql nvarchar(max);
        DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT p.database_name
            FROM monitor.DatabaseBackupPolicy AS p
            JOIN sys.databases AS d ON d.name = p.database_name
            WHERE p.is_enabled = 1 AND p.require_log = 1
              AND d.state_desc = N'ONLINE' AND d.recovery_model_desc = N'FULL';

        OPEN db_cursor;
        FETCH NEXT FROM db_cursor INTO @db;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @sql = N'
                    SELECT db_name, db_id, family_guid, rds_backup_seq_id,
                           backup_file_epoch, backup_file_time_utc,
                           starting_lsn, ending_lsn, is_log_chain_broken,
                           file_size_bytes, [Error]
                    FROM msdb.dbo.rds_fn_list_tlog_backup_metadata(@p_db);';
                INSERT #TlogMetadata
                EXEC sys.sp_executesql @sql, N'@p_db sysname', @p_db = @db;

                INSERT #TlogProbe(database_name, is_visible, error_message)
                SELECT @db,
                       CASE WHEN EXISTS
                            (SELECT 1 FROM #TlogMetadata
                             WHERE db_name = @db AND error_message IS NOT NULL)
                            THEN 0 ELSE 1 END,
                       (SELECT TOP (1) LEFT(error_message, 2000)
                        FROM #TlogMetadata
                        WHERE db_name = @db AND error_message IS NOT NULL);
            END TRY
            BEGIN CATCH
                INSERT #TlogProbe(database_name, is_visible, error_message)
                VALUES(@db, 0, LEFT(ERROR_MESSAGE(), 2000));
            END CATCH;

            FETCH NEXT FROM db_cursor INTO @db;
        END;
        CLOSE db_cursor;
        DEALLOCATE db_cursor;

        INSERT monitor.TlogBackupHistory
        (
            database_name, rds_backup_seq_id, backup_file_time_utc,
            starting_lsn, ending_lsn, is_log_chain_broken,
            file_size_bytes, error_message
        )
        SELECT m.db_name, m.rds_backup_seq_id, m.backup_file_time_utc,
               m.starting_lsn, m.ending_lsn, m.is_log_chain_broken,
               m.file_size_bytes, m.error_message
        FROM #TlogMetadata AS m
        WHERE m.rds_backup_seq_id IS NOT NULL
          AND m.backup_file_time_utc IS NOT NULL
          AND NOT EXISTS
              (SELECT 1 FROM monitor.TlogBackupHistory AS t
               WHERE t.database_name = m.db_name
                 AND t.rds_backup_seq_id = m.rds_backup_seq_id);

        /* Normalize all usable backup evidence into one candidate set. */
        CREATE TABLE #BackupCandidate
        (
            database_name               sysname,
            backup_type                 char(1),
            finish_time                 datetime2(0),
            duration_seconds            int,
            size_bytes                  bigint,
            source_name                 nvarchar(40),
            location                    nvarchar(4000),
            expiration_time             datetime2(0),
            chain_broken                bit
        );

        INSERT #BackupCandidate
        SELECT b.database_name,
               b.type,
               b.backup_finish_date,
               DATEDIFF(SECOND, b.backup_start_date, b.backup_finish_date),
               COALESCE(b.compressed_backup_size, b.backup_size),
               N'MSDB_BACKUPSET',
               LEFT(m.physical_device_name, 4000),
               b.expiration_date,
               NULL
        FROM msdb.dbo.backupset AS b
        OUTER APPLY
        (
            SELECT TOP (1) mf.physical_device_name
            FROM msdb.dbo.backupmediafamily AS mf
            WHERE mf.media_set_id = b.media_set_id
            ORDER BY mf.family_sequence_number
        ) AS m
        JOIN monitor.DatabaseBackupPolicy AS p ON p.database_name = b.database_name
        LEFT JOIN #TlogProbe AS tp ON tp.database_name = b.database_name
        WHERE b.type IN ('D', 'I', 'L')
          /* Do not compare server-local msdb log times with UTC RDS metadata. */
          AND (b.type <> 'L' OR ISNULL(tp.is_visible, 0) = 0);

        INSERT #BackupCandidate
        SELECT r.database_name,
               CASE WHEN r.task_type = N'BACKUP_DB' THEN 'D' ELSE 'I' END,
               r.last_updated_server_time,
               r.duration_minutes * 60,
               NULL,
               N'RDS_TASK_STATUS',
               r.s3_object_arn,
               NULL,
               NULL
        FROM monitor.RdsTaskHistory AS r
        JOIN monitor.DatabaseBackupPolicy AS p ON p.database_name = r.database_name
        WHERE r.lifecycle = N'SUCCESS'
          AND r.task_type IN (N'BACKUP_DB', N'BACKUP_DB_DIFFERENTIAL')
          AND r.last_updated_server_time IS NOT NULL;

        INSERT #BackupCandidate
        SELECT t.database_name, 'L', t.backup_file_time_utc, NULL,
               t.file_size_bytes, N'RDS_TLOG_METADATA', NULL, NULL,
               t.is_log_chain_broken
        FROM monitor.TlogBackupHistory AS t
        JOIN monitor.DatabaseBackupPolicy AS p ON p.database_name = t.database_name;

        ;WITH Ranked AS
        (
            SELECT c.*,
                   ROW_NUMBER() OVER
                   (PARTITION BY c.database_name, c.backup_type
                    ORDER BY c.finish_time DESC, c.source_name) AS rn
            FROM #BackupCandidate AS c
        )
        SELECT * INTO #LatestBackup FROM Ranked WHERE rn = 1;

        INSERT monitor.BackupSample
        (
            captured_utc, captured_server_time, database_name,
            database_state, recovery_model,
            full_finish_time, full_duration_seconds, full_size_bytes,
            full_source, full_location, full_expiration_time,
            diff_finish_time, diff_duration_seconds, diff_size_bytes,
            diff_source, diff_location, diff_expiration_time,
            log_finish_time, log_duration_seconds, log_size_bytes,
            log_source, log_chain_broken, log_visibility, collection_note
        )
        SELECT SYSUTCDATETIME(), GETDATE(), p.database_name,
               COALESCE(d.state_desc, N'NOT_FOUND'),
               COALESCE(d.recovery_model_desc, N'UNKNOWN'),
               f.finish_time, f.duration_seconds, f.size_bytes,
               f.source_name, f.location, f.expiration_time,
               i.finish_time, i.duration_seconds, i.size_bytes,
               i.source_name, i.location, i.expiration_time,
               l.finish_time, l.duration_seconds, l.size_bytes,
               l.source_name, l.chain_broken,
               CASE
                   WHEN p.require_log = 0 OR d.recovery_model_desc <> N'FULL' THEN N'NOT_REQUIRED'
                   WHEN tp.is_visible = 1 THEN N'RDS_TLOG_VISIBLE'
                   WHEN l.finish_time IS NOT NULL THEN N'MSDB_VISIBLE'
                   ELSE N'UNVERIFIED'
               END,
               LEFT(CONCAT(@tlog_note,
                    CASE WHEN tp.error_message IS NOT NULL
                         THEN CONCAT(N' T-log metadata: ', tp.error_message) END), 2000)
        FROM monitor.DatabaseBackupPolicy AS p
        LEFT JOIN sys.databases AS d ON d.name = p.database_name
        LEFT JOIN #LatestBackup AS f
               ON f.database_name = p.database_name AND f.backup_type = 'D'
        LEFT JOIN #LatestBackup AS i
               ON i.database_name = p.database_name AND i.backup_type = 'I'
        LEFT JOIN #LatestBackup AS l
               ON l.database_name = p.database_name AND l.backup_type = 'L'
        LEFT JOIN #TlogProbe AS tp ON tp.database_name = p.database_name
        WHERE p.is_enabled = 1;
        SET @backup_rows = @@ROWCOUNT;

        UPDATE monitor.CollectorRun
           SET finished_utc = SYSUTCDATETIME(), succeeded = 1,
               backup_rows = @backup_rows, job_rows = @job_rows
         WHERE collector_run_id = @run_id;
    END TRY
    BEGIN CATCH
        UPDATE monitor.CollectorRun
           SET finished_utc = SYSUTCDATETIME(), succeeded = 0,
               backup_rows = @backup_rows, job_rows = @job_rows,
               error_number = ERROR_NUMBER(),
               error_message = LEFT(ERROR_MESSAGE(), 2048)
         WHERE collector_run_id = @run_id;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE monitor.usp_SetComponentStatus
    @ComponentName sysname,
    @Succeeded bit,
    @ErrorNumber int = NULL,
    @ErrorMessage nvarchar(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE monitor.ComponentStatus
       SET last_attempt_utc = SYSUTCDATETIME(),
           last_success_utc = CASE WHEN @Succeeded = 1 THEN SYSUTCDATETIME() ELSE last_success_utc END,
           last_error_number = CASE WHEN @Succeeded = 1 THEN NULL ELSE @ErrorNumber END,
           last_error_message = CASE WHEN @Succeeded = 1 THEN NULL ELSE LEFT(@ErrorMessage, 2000) END
     WHERE component_name = @ComponentName;

    IF @@ROWCOUNT = 0
        INSERT monitor.ComponentStatus
        (
            component_name, last_attempt_utc, last_success_utc,
            last_error_number, last_error_message
        )
        VALUES
        (
            @ComponentName, SYSUTCDATETIME(),
            CASE WHEN @Succeeded = 1 THEN SYSUTCDATETIME() END,
            CASE WHEN @Succeeded = 0 THEN @ErrorNumber END,
            CASE WHEN @Succeeded = 0 THEN LEFT(@ErrorMessage, 2000) END
        );
END;
GO

CREATE OR ALTER PROCEDURE monitor.usp_CollectOperationalHealth
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET DEADLOCK_PRIORITY LOW;
    SET LOCK_TIMEOUT 3000;

    DECLARE @captured_utc datetime2(3) = SYSUTCDATETIME();

    /* Persist failures/cancellations for every SQL Agent job, not only maintenance jobs. */
    BEGIN TRY
        INSERT monitor.AgentFailureEvent
        (
            job_id, instance_id, job_name, run_status,
            run_start_server_time, run_duration_seconds,
            failure_step_name, message
        )
        SELECT j.job_id,
               h.instance_id,
               j.name,
               h.run_status,
               DATETIMEFROMPARTS
               (
                   h.run_date / 10000,
                   (h.run_date / 100) % 100,
                   h.run_date % 100,
                   h.run_time / 10000,
                   (h.run_time / 100) % 100,
                   h.run_time % 100,
                   0
               ),
               (h.run_duration / 10000) * 3600
                 + ((h.run_duration / 100) % 100) * 60
                 + h.run_duration % 100,
               NULLIF(h.step_name, N'(Job outcome)'),
               LEFT(h.message, 4000)
        FROM msdb.dbo.sysjobhistory AS h
        JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
        WHERE
          (
              (h.step_id > 0 AND h.run_status IN (0, 2, 3))
              OR (h.step_id = 0 AND h.run_status = 3)
          )
          AND h.run_date > 0
          AND NOT EXISTS
              (SELECT 1 FROM monitor.AgentFailureEvent AS x
               WHERE x.job_id = h.job_id AND x.instance_id = h.instance_id);

        EXEC monitor.usp_SetComponentStatus N'ALL_AGENT_FAILURES', 1;
    END TRY
    BEGIN CATCH
        DECLARE @agent_error_number int = ERROR_NUMBER(),
                @agent_error_message nvarchar(4000) = ERROR_MESSAGE();
        EXEC monitor.usp_SetComponentStatus
             N'ALL_AGENT_FAILURES', 0, @agent_error_number, @agent_error_message;
    END CATCH;

    /* Import recent xml_deadlock_report events from the built-in system_health ring buffer. */
    BEGIN TRY
        DECLARE @ring_buffer xml;
        SELECT @ring_buffer = TRY_CAST(t.target_data AS xml)
        FROM sys.dm_xe_session_targets AS t
        JOIN sys.dm_xe_sessions AS s
          ON s.address = t.event_session_address
        WHERE s.name = N'system_health'
          AND t.target_name = N'ring_buffer';

        ;WITH Deadlocks AS
        (
            SELECT n.query('.') AS event_xml
            FROM @ring_buffer.nodes
                 ('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS x(n)
        ), Shaped AS
        (
            SELECT TRY_CONVERT(datetime2(3),
                       event_xml.value('(event/@timestamp)[1]', 'nvarchar(50)')) AS event_utc,
                   event_xml.value
                       ('(event/data/value/deadlock/process-list/process[1]/@currentdbname)[1]', 'nvarchar(128)') AS database_name,
                   event_xml.value
                       ('(event/data/value/deadlock/victim-list/victimProcess[1]/@id)[1]', 'nvarchar(100)') AS victim_process_id,
                   event_xml.value
                       ('count(event/data/value/deadlock/process-list/process)', 'int') AS process_count,
                   event_xml.query('(event/data/value/deadlock)[1]') AS deadlock_xml
            FROM Deadlocks
        ), Hashed AS
        (
            SELECT HASHBYTES('SHA2_256',
                       CONVERT(varbinary(max), CONVERT(nvarchar(max), deadlock_xml))) AS deadlock_hash,
                   event_utc, database_name, victim_process_id,
                   process_count, deadlock_xml
            FROM Shaped
            WHERE event_utc IS NOT NULL
              AND deadlock_xml.exist('/deadlock[1]') = 1
        )
        INSERT monitor.DeadlockEvent
        (
            deadlock_hash, event_utc, database_name,
            victim_process_id, process_count, deadlock_xml
        )
        SELECT h.deadlock_hash, h.event_utc, NULLIF(h.database_name, N''),
               h.victim_process_id, h.process_count, h.deadlock_xml
        FROM Hashed AS h
        WHERE NOT EXISTS
              (SELECT 1 FROM monitor.DeadlockEvent AS d
               WHERE d.deadlock_hash = h.deadlock_hash);

        EXEC monitor.usp_SetComponentStatus N'DEADLOCK_RING_BUFFER', 1;
    END TRY
    BEGIN CATCH
        DECLARE @deadlock_error_number int = ERROR_NUMBER(),
                @deadlock_error_message nvarchar(4000) = ERROR_MESSAGE();
        EXEC monitor.usp_SetComponentStatus
             N'DEADLOCK_RING_BUFFER', 0, @deadlock_error_number, @deadlock_error_message;
    END CATCH;

    /* Collect high-signal entries from the current and previous RDS SQL error logs. */
    IF NOT EXISTS
       (SELECT 1 FROM monitor.ComponentStatus
        WHERE component_name = N'RDS_ERROR_LOG'
          AND last_attempt_utc >= DATEADD(MINUTE, -15, SYSUTCDATETIME()))
    BEGIN
    BEGIN TRY
        CREATE TABLE #ErrorLog
        (
            LogDate datetime,
            ProcessInfo nvarchar(100),
            [Text] nvarchar(max)
        );

        INSERT #ErrorLog EXEC rdsadmin.dbo.rds_read_error_log @index = 0, @type = 1;
        BEGIN TRY
            INSERT #ErrorLog EXEC rdsadmin.dbo.rds_read_error_log @index = 1, @type = 1;
        END TRY
        BEGIN CATCH
            /* Previous log can be absent on a recently created/restarted instance. */
        END CATCH;

        ;WITH HighSignal AS
        (
            SELECT LogDate, ProcessInfo, LEFT([Text], 4000) AS message
            FROM #ErrorLog
            WHERE LogDate >= DATEADD(DAY, -2, GETDATE())
              AND
              (
                   [Text] LIKE N'%Severity: 2[0-5]%'
                OR [Text] LIKE N'%Error: 823,%'
                OR [Text] LIKE N'%Error: 824,%'
                OR [Text] LIKE N'%Error: 825,%'
                OR [Text] LIKE N'%Error: 832,%'
                OR [Text] LIKE N'%Error: 833,%'
                OR [Text] LIKE N'%Error: 9002,%'
                OR [Text] LIKE N'%Error: 1105,%'
                OR [Text] LIKE N'%SQL Server Assertion%'
                OR [Text] LIKE N'%stack dump%'
                OR [Text] LIKE N'%corruption%'
                OR [Text] LIKE N'%I/O requests taking longer%'
                OR [Text] LIKE N'%failed to allocate%page%'
              )
        ), Hashed AS
        (
            SELECT HASHBYTES('SHA2_256', CONVERT(varbinary(max),
                       CONCAT(CONVERT(nvarchar(23), LogDate, 121), N'|',
                              ProcessInfo, N'|', message))) AS event_hash,
                   LogDate, ProcessInfo, message
            FROM HighSignal
        )
        INSERT monitor.ServerErrorLogEvent
            (event_hash, log_date_server_time, process_info, message)
        SELECT h.event_hash, h.LogDate, h.ProcessInfo, h.message
        FROM Hashed AS h
        WHERE NOT EXISTS
              (SELECT 1 FROM monitor.ServerErrorLogEvent AS e
               WHERE e.event_hash = h.event_hash);

        EXEC monitor.usp_SetComponentStatus N'RDS_ERROR_LOG', 1;
    END TRY
    BEGIN CATCH
        DECLARE @errorlog_error_number int = ERROR_NUMBER(),
                @errorlog_error_message nvarchar(4000) = ERROR_MESSAGE();
        EXEC monitor.usp_SetComponentStatus
             N'RDS_ERROR_LOG', 0, @errorlog_error_number, @errorlog_error_message;
    END CATCH;
    END;

    /* Database log utilization. */
    BEGIN TRY
        CREATE TABLE #LogSpace
        (
            database_name sysname,
            log_size_mb decimal(19,2),
            log_used_percent decimal(9,2),
            status_code int
        );
        INSERT #LogSpace EXEC(N'DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS;');

        INSERT monitor.DatabaseLogSample
            (captured_utc, database_name, log_size_mb, log_used_percent, status_code)
        SELECT @captured_utc, database_name, log_size_mb, log_used_percent, status_code
        FROM #LogSpace;

        EXEC monitor.usp_SetComponentStatus N'DATABASE_LOG_SPACE', 1;
    END TRY
    BEGIN CATCH
        DECLARE @logspace_error_number int = ERROR_NUMBER(),
                @logspace_error_message nvarchar(4000) = ERROR_MESSAGE();
        EXEC monitor.usp_SetComponentStatus
             N'DATABASE_LOG_SPACE', 0, @logspace_error_number, @logspace_error_message;
    END CATCH;

    /* SQL-visible volume capacity. CloudWatch FreeStorageSpace remains authoritative for RDS. */
    BEGIN TRY
        INSERT monitor.StorageSample
            (captured_utc, volume_mount_point, total_bytes, available_bytes)
        SELECT @captured_utc,
               COALESCE(NULLIF(v.volume_mount_point, N''), N'(RDS volume)'),
               MAX(v.total_bytes), MIN(v.available_bytes)
        FROM sys.master_files AS f
        CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.file_id) AS v
        WHERE f.database_id > 4
        GROUP BY COALESCE(NULLIF(v.volume_mount_point, N''), N'(RDS volume)');

        EXEC monitor.usp_SetComponentStatus N'SQL_VOLUME_SPACE', 1;
    END TRY
    BEGIN CATCH
        DECLARE @storage_error_number int = ERROR_NUMBER(),
                @storage_error_message nvarchar(4000) = ERROR_MESSAGE();
        EXEC monitor.usp_SetComponentStatus
             N'SQL_VOLUME_SPACE', 0, @storage_error_number, @storage_error_message;
    END CATCH;
END;
GO

/* ---------- Current-health views ---------- */

CREATE OR ALTER VIEW monitor.vw_BackupHealth
AS
WITH DatabaseInventory AS
(
    /* Live inventory is authoritative; retained policy rows expose dropped/invisible DBs. */
    SELECT d.name AS database_name,
           d.state_desc AS current_database_state,
           d.recovery_model_desc AS current_recovery_model
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.name <> N'rdsadmin'

    UNION ALL

    SELECT p.database_name, NULL, NULL
    FROM monitor.DatabaseBackupPolicy AS p
    WHERE NOT EXISTS
          (SELECT 1 FROM sys.databases AS d WHERE d.name = p.database_name)
), H AS
(
    SELECT i.database_name,
           COALESCE(l.captured_utc, CONVERT(datetime2(0), SYSUTCDATETIME())) AS captured_utc,
           COALESCE(l.captured_server_time, CONVERT(datetime2(0), GETDATE())) AS captured_server_time,
           COALESCE(i.current_database_state, l.database_state, N'NOT_FOUND') AS database_state,
           COALESCE(i.current_recovery_model, l.recovery_model, N'UNKNOWN') AS recovery_model,
           l.full_finish_time, l.full_duration_seconds, l.full_size_bytes,
           l.full_source, l.full_location, l.full_expiration_time,
           l.diff_finish_time, l.diff_duration_seconds, l.diff_size_bytes,
           l.diff_source, l.diff_location, l.diff_expiration_time,
           l.log_finish_time, l.log_duration_seconds, l.log_size_bytes,
           l.log_source, l.log_chain_broken,
           COALESCE(l.log_visibility, N'UNVERIFIED') AS log_visibility,
           l.collection_note,
           COALESCE(p.is_enabled, CONVERT(bit, 1)) AS monitoring_enabled,
           COALESCE(p.require_full, CONVERT(bit, 1)) AS require_full,
           COALESCE(p.require_diff, CONVERT(bit, 1)) AS require_diff,
           COALESCE(p.require_log,
                    CASE WHEN i.current_recovery_model = N'FULL' THEN CONVERT(bit, 1)
                         ELSE CONVERT(bit, 0) END) AS require_log,
           COALESCE(p.full_max_age_minutes, 1440) AS full_max_age_minutes,
           COALESCE(p.diff_max_age_minutes, 360) AS diff_max_age_minutes,
           COALESCE(p.log_max_age_minutes, 30) AS log_max_age_minutes,
           CASE
               WHEN l.diff_finish_time IS NULL THEN l.full_finish_time
               WHEN l.full_finish_time IS NULL THEN l.diff_finish_time
               WHEN l.diff_finish_time > l.full_finish_time THEN l.diff_finish_time
               ELSE l.full_finish_time
           END AS effective_data_finish_time
    FROM DatabaseInventory AS i
    LEFT JOIN monitor.DatabaseBackupPolicy AS p
      ON p.database_name = i.database_name
    OUTER APPLY
    (
        SELECT TOP (1) s.*
        FROM monitor.BackupSample AS s
        WHERE s.database_name = i.database_name
        ORDER BY s.captured_utc DESC, s.sample_id DESC
    ) AS l
)
SELECT h.*,
       CASE
           WHEN h.monitoring_enabled = 0 THEN N'NOT_MONITORED'
           WHEN h.database_state <> N'ONLINE' THEN N'NOT_ONLINE'
           WHEN h.require_full = 0 THEN N'NOT_REQUIRED'
           WHEN h.full_finish_time IS NULL THEN N'MISSING'
           WHEN DATEDIFF(MINUTE, h.full_finish_time, h.captured_server_time) > h.full_max_age_minutes THEN N'OVERDUE'
           ELSE N'OK'
       END AS full_status,
       CASE
           WHEN h.monitoring_enabled = 0 THEN N'NOT_MONITORED'
           WHEN h.database_state <> N'ONLINE' THEN N'NOT_ONLINE'
           WHEN h.require_diff = 0 THEN N'NOT_REQUIRED'
           WHEN h.effective_data_finish_time IS NULL THEN N'MISSING'
           WHEN DATEDIFF(MINUTE, h.effective_data_finish_time, h.captured_server_time) > h.diff_max_age_minutes THEN N'OVERDUE'
           ELSE N'OK'
       END AS diff_status,
       CASE
           WHEN h.monitoring_enabled = 0 THEN N'NOT_MONITORED'
           WHEN h.database_state <> N'ONLINE' THEN N'NOT_ONLINE'
           WHEN h.require_log = 0 OR h.recovery_model <> N'FULL' THEN N'NOT_REQUIRED'
           WHEN h.log_visibility = N'UNVERIFIED' THEN N'UNVERIFIED'
           WHEN h.log_finish_time IS NULL THEN N'MISSING'
           WHEN h.log_chain_broken = 1 THEN N'CHAIN_BROKEN'
           WHEN DATEDIFF(MINUTE, h.log_finish_time, h.captured_utc) > h.log_max_age_minutes THEN N'OVERDUE'
           ELSE N'OK'
       END AS log_status
FROM H AS h;
GO

CREATE OR ALTER VIEW monitor.vw_MaintenanceJobHealth
AS
SELECT p.job_id, p.job_name, p.maintenance_type,
       p.max_hours_since_success, p.is_monitored,
       j.enabled AS agent_job_enabled,
       lr.run_status AS last_run_status,
       lr.run_start_server_time AS last_run_server_time,
       lr.run_duration_seconds AS last_run_duration_seconds,
       lr.message AS last_run_message,
       ls.last_success_server_time,
       CASE
           WHEN j.job_id IS NULL THEN N'NOT_FOUND'
           WHEN p.is_monitored = 0 THEN N'NOT_MONITORED'
           WHEN j.enabled = 0 THEN N'DISABLED'
           WHEN lr.run_status IN (0, 2, 3) THEN N'FAILED'
           WHEN ls.last_success_server_time IS NULL THEN N'NEVER_SUCCEEDED'
           WHEN DATEDIFF(MINUTE, ls.last_success_server_time, GETDATE())
                  > p.max_hours_since_success * 60.0 THEN N'OVERDUE'
           ELSE N'OK'
       END AS health_status
FROM monitor.MaintenanceJobPolicy AS p
LEFT JOIN msdb.dbo.sysjobs AS j ON j.job_id = p.job_id
OUTER APPLY
(
    SELECT TOP (1) r.run_status, r.run_start_server_time,
           r.run_duration_seconds, r.message
    FROM monitor.AgentJobRun AS r
    WHERE r.job_id = p.job_id
    ORDER BY r.run_start_server_time DESC, r.instance_id DESC
) AS lr
OUTER APPLY
(
    SELECT MAX(r.run_start_server_time) AS last_success_server_time
    FROM monitor.AgentJobRun AS r
    WHERE r.job_id = p.job_id AND r.run_status = 1
) AS ls;
GO

/* ---------- Email rendering and alerting ---------- */

CREATE OR ALTER PROCEDURE monitor.usp_SendImmediateAlerts
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @enabled bit, @profile sysname, @recipients nvarchar(4000),
            @server sysname, @repeat_minutes int;
    SELECT @enabled = send_immediate_alerts, @profile = mail_profile,
           @recipients = recipients, @server = server_label,
           @repeat_minutes = repeat_critical_minutes
    FROM monitor.Settings WHERE settings_id = 1;
    IF ISNULL(@enabled, 0) = 0 RETURN;

    CREATE TABLE #CurrentException
    (
        alert_key nvarchar(450) PRIMARY KEY,
        alert_kind nvarchar(20),
        category nvarchar(40),
        severity nvarchar(20),
        summary nvarchar(1000),
        detail nvarchar(4000)
    );

    INSERT #CurrentException
    SELECT CONCAT(N'BACKUP:', database_name), N'STATE', N'BACKUP', N'CRITICAL',
           CONCAT(database_name, N' backup is not compliant'),
           CONCAT(N'FULL=', full_status, N'; DIFF/effective=', diff_status,
                  N'; LOG=', log_status, N'; recovery=', recovery_model)
    FROM monitor.vw_BackupHealth
    WHERE full_status IN (N'MISSING', N'OVERDUE', N'NOT_ONLINE')
       OR diff_status IN (N'MISSING', N'OVERDUE', N'NOT_ONLINE')
       OR log_status IN (N'MISSING', N'OVERDUE', N'CHAIN_BROKEN', N'NOT_ONLINE');

    INSERT #CurrentException
    SELECT CONCAT(N'JOB:', CONVERT(nvarchar(36), job_id)), N'STATE',
           N'MAINTENANCE', N'CRITICAL',
           CONCAT(job_name, N' is ', health_status),
           CONCAT(N'Type=', maintenance_type,
                  N'; last run=', COALESCE(CONVERT(nvarchar(19), last_run_server_time, 120), N'never'),
                  N'; last success=', COALESCE(CONVERT(nvarchar(19), last_success_server_time, 120), N'never'),
                  N'; SLA hours=', CONVERT(nvarchar(30), max_hours_since_success),
                  N'; message=', COALESCE(last_run_message, N''))
    FROM monitor.vw_MaintenanceJobHealth
    WHERE is_monitored = 1
      /* Failed runs are sent by the all-Agent failure event below. */
      AND health_status IN (N'OVERDUE', N'NEVER_SUCCEEDED');

    INSERT #CurrentException
    SELECT CONCAT(N'AGENT_FAILURE:', CONVERT(nvarchar(36), job_id), N':', instance_id),
           N'EVENT', N'SQL_AGENT', N'CRITICAL',
           CONCAT(job_name, N' ',
                  CASE run_status WHEN 3 THEN N'was cancelled'
                                      WHEN 2 THEN N'entered retry'
                                      ELSE N'had a failed step' END),
           CONCAT(N'Run=', CONVERT(nvarchar(19), run_start_server_time, 120),
                  N'; step=', COALESCE(failure_step_name, N'(job outcome)'),
                  N'; duration=', run_duration_seconds, N's; message=', COALESCE(message, N''))
    FROM monitor.AgentFailureEvent
    WHERE run_start_server_time >= DATEADD(HOUR, -12, GETDATE());

    INSERT #CurrentException
    SELECT CONCAT(N'DEADLOCK:', CONVERT(varchar(64), deadlock_hash, 2)),
           N'EVENT', N'DEADLOCK', N'CRITICAL',
           CONCAT(N'Deadlock detected',
                  CASE WHEN database_name IS NOT NULL THEN CONCAT(N' in ', database_name) ELSE N'' END),
           CONCAT(N'UTC=', CONVERT(nvarchar(23), event_utc, 121),
                  N'; victim=', COALESCE(victim_process_id, N'unknown'),
                  N'; processes=', COALESCE(CONVERT(nvarchar(20), process_count), N'unknown'))
    FROM monitor.DeadlockEvent
    WHERE event_utc >= DATEADD(HOUR, -12, SYSUTCDATETIME());

    INSERT #CurrentException
    SELECT CONCAT(N'SERVER_ERROR:', CONVERT(varchar(64), event_hash, 2)),
           N'EVENT', N'SERVER_ERROR', N'CRITICAL',
           CONCAT(N'High-signal SQL Server error: ', LEFT(message, 300)),
           CONCAT(N'Time=', CONVERT(nvarchar(19), log_date_server_time, 120),
                  N'; process=', COALESCE(process_info, N''), N'; ', message)
    FROM monitor.ServerErrorLogEvent
    WHERE log_date_server_time >= DATEADD(HOUR, -12, GETDATE());

    INSERT #CurrentException
    SELECT CONCAT(N'RDS_TASK:', task_id), N'EVENT', N'RDS_BACKUP_TASK', N'CRITICAL',
           CONCAT(database_name, N' ', task_type, N' task ', task_id, N' failed'),
           CONCAT(N'Created=', COALESCE(CONVERT(nvarchar(19), created_at_server_time, 120), N''),
                  N'; S3=', COALESCE(s3_object_arn, N''),
                  N'; error=', COALESCE(task_info, N''))
    FROM monitor.RdsTaskHistory
    WHERE task_type IN (N'BACKUP_DB', N'BACKUP_DB_DIFFERENTIAL')
      AND lifecycle IN (N'ERROR', N'CANCELLED')
      /* Avoid flooding the first deployment with AWS's 36-day task history. */
      AND created_at_server_time >= DATEADD(HOUR, -12, GETDATE());

    UPDATE s
       SET is_active = 0, resolved_utc = SYSUTCDATETIME()
    FROM monitor.AlertState AS s
    WHERE s.alert_kind = N'STATE' AND s.is_active = 1
      AND NOT EXISTS (SELECT 1 FROM #CurrentException AS c WHERE c.alert_key = s.alert_key);

    UPDATE s
       SET category = c.category, severity = c.severity,
           summary = c.summary, detail = c.detail,
           is_active = 1, last_seen_utc = SYSUTCDATETIME(), resolved_utc = NULL
    FROM monitor.AlertState AS s
    JOIN #CurrentException AS c ON c.alert_key = s.alert_key;

    INSERT monitor.AlertState
    (
        alert_key, alert_kind, category, severity, summary, detail,
        is_active, first_seen_utc, last_seen_utc
    )
    SELECT c.alert_key, c.alert_kind, c.category, c.severity,
           c.summary, c.detail, 1, SYSUTCDATETIME(), SYSUTCDATETIME()
    FROM #CurrentException AS c
    WHERE NOT EXISTS (SELECT 1 FROM monitor.AlertState AS s WHERE s.alert_key = c.alert_key);

    CREATE TABLE #Due
    (
        alert_key nvarchar(450) PRIMARY KEY,
        category nvarchar(40), severity nvarchar(20),
        summary nvarchar(1000), detail nvarchar(4000)
    );
    INSERT #Due
    SELECT s.alert_key, s.category, s.severity, s.summary, s.detail
    FROM monitor.AlertState AS s
    WHERE s.is_active = 1
      AND (s.last_sent_utc IS NULL
           OR (s.alert_kind = N'STATE'
               AND s.last_sent_utc < DATEADD(MINUTE, -@repeat_minutes, SYSUTCDATETIME())));

    DECLARE @count int = (SELECT COUNT(*) FROM #Due);
    IF @count = 0 RETURN;

    DECLARE @rows nvarchar(max) = N'', @body nvarchar(max),
            @subject nvarchar(255), @mailitem_id int;
    SELECT @rows = @rows
         + N'<tr><td>' + monitor.fn_HtmlEncode(category) + N'</td>'
         + N'<td><b>' + monitor.fn_HtmlEncode(severity) + N'</b></td>'
         + N'<td>' + monitor.fn_HtmlEncode(summary) + N'</td>'
         + N'<td>' + monitor.fn_HtmlEncode(detail) + N'</td></tr>'
    FROM #Due ORDER BY category, summary;

    SET @subject = LEFT(CONCAT(N'[CRITICAL] ', @server,
                        N' SQL Server operational alert (', @count, N')'), 255);
    SET @body = N'<html><head><style>'
        + N'body{font-family:Segoe UI,Arial;color:#1f2937}h2{color:#991b1b}'
        + N'table{border-collapse:collapse;width:100%}th{background:#7f1d1d;color:white}'
        + N'th,td{border:1px solid #d1d5db;padding:7px;text-align:left;vertical-align:top}'
        + N'tr:nth-child(even){background:#f9fafb}.small{color:#6b7280;font-size:12px}'
        + N'</style></head><body><h2>' + monitor.fn_HtmlEncode(@server)
        + N' SQL Server Operational Alert</h2><p>' + CONVERT(nvarchar(20), @count)
        + N' new or still-active critical condition(s) require review.</p>'
        + N'<table><tr><th>Category</th><th>Severity</th><th>Condition</th><th>Details</th></tr>'
        + @rows + N'</table><p class="small">Generated '
        + CONVERT(nvarchar(19), SYSUTCDATETIME(), 120) + N' UTC by OPS.monitor.</p></body></html>';

    EXEC msdb.dbo.sp_send_dbmail
         @profile_name = @profile,
         @recipients = @recipients,
         @subject = @subject,
         @body = @body,
         @body_format = 'HTML',
         @importance = 'High',
         @mailitem_id = @mailitem_id OUTPUT;

    UPDATE s SET last_sent_utc = SYSUTCDATETIME()
    FROM monitor.AlertState AS s JOIN #Due AS d ON d.alert_key = s.alert_key;

    INSERT monitor.NotificationLog
        (notification_type, queued_utc, subject, recipients, mailitem_id, exception_count)
    VALUES(N'IMMEDIATE', SYSUTCDATETIME(), @subject, @recipients, @mailitem_id, @count);
END;
GO

CREATE OR ALTER PROCEDURE monitor.usp_SendDailyReport
    @Force bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @enabled bit, @profile sysname, @recipients nvarchar(4000),
            @server sysname, @report_hour tinyint, @retention smallint;
    SELECT @enabled = send_daily_report, @profile = mail_profile,
           @recipients = recipients, @server = server_label,
           @report_hour = report_hour_eastern,
           @retention = history_retention_days
    FROM monitor.Settings WHERE settings_id = 1;
    IF ISNULL(@enabled, 0) = 0 AND @Force = 0 RETURN;

    /* Ensure a newly created/restored database appears even before the next collector run. */
    EXEC monitor.usp_SyncDatabaseBackupPolicy;

    DECLARE @eastern_now datetimeoffset =
        (SYSUTCDATETIME() AT TIME ZONE 'UTC') AT TIME ZONE 'Eastern Standard Time';
    DECLARE @report_date date = CONVERT(date, @eastern_now);

    IF @Force = 0 AND DATEPART(HOUR, @eastern_now) <> @report_hour RETURN;
    IF @Force = 0 AND EXISTS
       (SELECT 1 FROM monitor.NotificationLog
        WHERE notification_type = N'DAILY' AND report_date_eastern = @report_date) RETURN;

    DECLARE @backup_bad int =
    (
        SELECT COUNT(*) FROM monitor.vw_BackupHealth
        WHERE full_status NOT IN (N'OK', N'NOT_REQUIRED')
           OR diff_status NOT IN (N'OK', N'NOT_REQUIRED')
           OR log_status NOT IN (N'OK', N'NOT_REQUIRED')
    );
    DECLARE @job_bad int =
    (
        SELECT COUNT(*) FROM monitor.vw_MaintenanceJobHealth
        WHERE is_monitored = 1 AND health_status <> N'OK'
    );
    DECLARE @rds_fail int =
    (
        SELECT COUNT(*) FROM monitor.RdsTaskHistory
        WHERE task_type IN (N'BACKUP_DB', N'BACKUP_DB_DIFFERENTIAL')
          AND lifecycle IN (N'ERROR', N'CANCELLED')
          AND created_at_server_time >= DATEADD(HOUR, -12, GETDATE())
    );
    DECLARE @agent_fail int =
    (
        SELECT COUNT(*) FROM monitor.AgentFailureEvent
        WHERE run_start_server_time >= DATEADD(HOUR, -12, GETDATE())
    );
    DECLARE @deadlock_count int =
    (
        SELECT COUNT(*) FROM monitor.DeadlockEvent
        WHERE event_utc >= DATEADD(HOUR, -12, SYSUTCDATETIME())
    );
    DECLARE @server_error_count int =
    (
        SELECT COUNT(*) FROM monitor.ServerErrorLogEvent
        WHERE log_date_server_time >= DATEADD(HOUR, -12, GETDATE())
    );
    DECLARE @last_collection_utc datetime2(0) =
    (
        SELECT MAX(finished_utc) FROM monitor.CollectorRun WHERE succeeded = 1
    );
    DECLARE @collector_bad int =
        CASE WHEN @last_collection_utc IS NULL
                   OR @last_collection_utc < DATEADD(MINUTE, -15, SYSUTCDATETIME())
             THEN 1 ELSE 0 END;

    CREATE TABLE #Anomaly
    (
        severity nvarchar(20) NOT NULL,
        anomaly nvarchar(300) NOT NULL,
        details nvarchar(4000) NULL
    );

    INSERT #Anomaly
    SELECT N'CRITICAL', CONCAT(N'Database ', name, N' is ', state_desc),
           CONCAT(N'user_access=', user_access_desc,
                  N'; recovery=', recovery_model_desc,
                  N'; log_reuse_wait=', log_reuse_wait_desc)
    FROM sys.databases
    WHERE database_id > 4 AND name <> N'rdsadmin'
      AND source_database_id IS NULL AND state_desc <> N'ONLINE';

    ;WITH Latest AS
    (
        SELECT s.*,
               ROW_NUMBER() OVER(PARTITION BY database_name ORDER BY captured_utc DESC) AS rn
        FROM monitor.DatabaseLogSample AS s
    )
    INSERT #Anomaly
    SELECT CASE WHEN log_used_percent >= 90 THEN N'CRITICAL' ELSE N'WARNING' END,
           CONCAT(N'High transaction-log utilization: ', database_name),
           CONCAT(CONVERT(nvarchar(30), log_used_percent), N'% used of ',
                  CONVERT(nvarchar(30), log_size_mb), N' MB')
    FROM Latest
    WHERE rn = 1 AND log_used_percent >= 80;

    ;WITH Latest AS
    (
        SELECT s.*,
               ROW_NUMBER() OVER(PARTITION BY volume_mount_point ORDER BY captured_utc DESC) AS rn
        FROM monitor.StorageSample AS s
    )
    INSERT #Anomaly
    SELECT CASE WHEN available_bytes * 100.0 / NULLIF(total_bytes, 0) <= 10
                     OR available_bytes < 10737418240 THEN N'CRITICAL' ELSE N'WARNING' END,
           CONCAT(N'Low SQL-visible storage: ', volume_mount_point),
           CONCAT(CONVERT(decimal(19,2), available_bytes / 1073741824.0), N' GB free of ',
                  CONVERT(decimal(19,2), total_bytes / 1073741824.0), N' GB (',
                  CONVERT(decimal(9,2), available_bytes * 100.0 / NULLIF(total_bytes, 0)), N'%)')
    FROM Latest
    WHERE rn = 1
      AND (available_bytes * 100.0 / NULLIF(total_bytes, 0) < 15
           OR available_bytes < 21474836480);

    INSERT #Anomaly
    SELECT N'WARNING', CONCAT(N'Monitoring component unavailable: ', component_name),
           CONCAT(N'Error ', COALESCE(CONVERT(nvarchar(20), last_error_number), N''),
                  N': ', COALESCE(last_error_message, N''),
                  N'; last successful UTC=',
                  COALESCE(CONVERT(nvarchar(19), last_success_utc, 120), N'never'))
    FROM monitor.ComponentStatus
    WHERE last_error_message IS NOT NULL
      AND (last_success_utc IS NULL OR last_attempt_utc > last_success_utc);

    INSERT #Anomaly
    SELECT N'WARNING', N'OPS collector execution failed',
           CONCAT(N'UTC=', CONVERT(nvarchar(19), started_utc, 120),
                  N'; error ', COALESCE(CONVERT(nvarchar(20), error_number), N''),
                  N': ', COALESCE(error_message, N''))
    FROM monitor.CollectorRun
    WHERE succeeded = 0 AND started_utc >= DATEADD(HOUR, -12, SYSUTCDATETIME());

    IF @collector_bad = 1
        INSERT #Anomaly VALUES
        (N'CRITICAL', N'Backup/maintenance collector is stale',
         CONCAT(N'Last successful UTC=', COALESCE(CONVERT(nvarchar(19), @last_collection_utc, 120), N'never')));

    INSERT #Anomaly
    SELECT N'WARNING', CONCAT(N'RDS task appears stuck: ', database_name, N' ', task_type),
           CONCAT(N'Task ', task_id, N'; lifecycle=', lifecycle,
                  N'; created=', CONVERT(nvarchar(19), created_at_server_time, 120),
                  N'; percent=', COALESCE(CONVERT(nvarchar(30), percent_complete), N'unknown'))
    FROM monitor.RdsTaskHistory
    WHERE lifecycle IN (N'CREATED', N'IN_PROGRESS')
      AND created_at_server_time < DATEADD(HOUR, -4, GETDATE());

    BEGIN TRY
        INSERT #Anomaly
        SELECT N'WARNING', N'SQL Server restarted or failed over within 12 hours',
               CONCAT(N'SQL Server start time=', CONVERT(nvarchar(19), sqlserver_start_time, 120))
        FROM sys.dm_os_sys_info
        WHERE sqlserver_start_time >= DATEADD(HOUR, -12, GETDATE());
    END TRY
    BEGIN CATCH
        /* RDS can restrict server-state DMVs; ComponentStatus covers core collectors. */
    END CATCH;

    BEGIN TRY
        INSERT #Anomaly
        SELECT CASE WHEN r.wait_time >= 300000 THEN N'CRITICAL' ELSE N'WARNING' END,
               CONCAT(N'Blocking over 60 seconds: session ', r.session_id),
               CONCAT(N'blocked by ', r.blocking_session_id,
                      N'; database=', COALESCE(DB_NAME(r.database_id), N''),
                      N'; wait=', COALESCE(r.wait_type, N''),
                      N'; wait_ms=', r.wait_time)
        FROM sys.dm_exec_requests AS r
        WHERE r.blocking_session_id > 0 AND r.wait_time >= 60000;
    END TRY
    BEGIN CATCH
        /* Optional live blocking signal; do not fail the email on an RDS permission denial. */
    END CATCH;

    BEGIN TRY
        INSERT #Anomaly
        SELECT CASE WHEN sent_status = N'failed' THEN N'CRITICAL' ELSE N'WARNING' END,
               CONCAT(N'Database Mail item ', mailitem_id, N' is ', sent_status),
               CONCAT(N'Requested=', CONVERT(nvarchar(19), send_request_date, 120),
                      N'; recipients=', COALESCE(recipients, N''),
                      N'; subject=', COALESCE(subject, N''))
        FROM msdb.dbo.rds_fn_sysmail_allitems()
        WHERE
             (sent_status = N'failed' AND send_request_date >= DATEADD(HOUR, -12, GETDATE()))
          OR (sent_status = N'unsent' AND send_request_date < DATEADD(MINUTE, -15, GETDATE())
                                      AND send_request_date >= DATEADD(HOUR, -12, GETDATE()));
    END TRY
    BEGIN CATCH
        INSERT #Anomaly VALUES
        (N'WARNING', N'Database Mail delivery status could not be checked', LEFT(ERROR_MESSAGE(), 4000));
    END CATCH;

    DECLARE @anomaly_count int = (SELECT COUNT(*) FROM #Anomaly);

    DECLARE @backup_rows nvarchar(max) = N'', @job_rows nvarchar(max) = N'',
            @failure_rows nvarchar(max) = N'', @agent_rows nvarchar(max) = N'',
            @deadlock_rows nvarchar(max) = N'', @server_error_rows nvarchar(max) = N'',
            @anomaly_rows nvarchar(max) = N'';

    SELECT @backup_rows = @backup_rows
         + N'<tr class="'
         + CASE
               WHEN full_status IN (N'MISSING', N'OVERDUE', N'NOT_ONLINE')
                 OR diff_status IN (N'MISSING', N'OVERDUE', N'NOT_ONLINE')
                 OR log_status IN (N'MISSING', N'OVERDUE', N'CHAIN_BROKEN', N'NOT_ONLINE')
                   THEN N'critical'
               WHEN log_status IN (N'UNVERIFIED', N'NOT_MONITORED')
                 OR full_status = N'NOT_MONITORED'
                 OR diff_status = N'NOT_MONITORED' THEN N'warning'
               ELSE N'okrow'
           END
         + N'"><td><b>' + monitor.fn_HtmlEncode(database_name) + N'</b></td>'
         + N'<td>' + monitor.fn_HtmlEncode(recovery_model) + N'</td>'
         + N'<td>' + monitor.fn_HtmlEncode(full_status) + N'<br><span class="small">'
             + monitor.fn_HtmlEncode(COALESCE(CONVERT(nvarchar(19), full_finish_time, 120), N'never'))
             + N' | ' + monitor.fn_HtmlEncode(COALESCE(full_source, N''))
             + N' | ' + COALESCE(CONVERT(nvarchar(20), full_duration_seconds), N'-') + N's</span></td>'
         + N'<td>' + monitor.fn_HtmlEncode(diff_status) + N'<br><span class="small">'
             + monitor.fn_HtmlEncode(COALESCE(CONVERT(nvarchar(19), diff_finish_time, 120), N'never'))
             + N' | ' + monitor.fn_HtmlEncode(COALESCE(diff_source, N''))
             + N' | ' + COALESCE(CONVERT(nvarchar(20), diff_duration_seconds), N'-') + N's</span></td>'
         + N'<td>' + monitor.fn_HtmlEncode(log_status) + N'<br><span class="small">'
             + monitor.fn_HtmlEncode(COALESCE(CONVERT(nvarchar(19), log_finish_time, 120), N'never'))
             + N' | ' + monitor.fn_HtmlEncode(log_visibility)
             + CASE WHEN log_chain_broken = 1 THEN N' | CHAIN BROKEN' ELSE N'' END
             + N'</span></td>'
         + N'<td class="small">' + monitor.fn_HtmlEncode(COALESCE(full_location, diff_location, N'')) + N'</td></tr>'
    FROM monitor.vw_BackupHealth
    ORDER BY
        CASE WHEN full_status <> N'OK' OR diff_status <> N'OK'
                    OR log_status NOT IN (N'OK', N'NOT_REQUIRED') THEN 0 ELSE 1 END,
        database_name;

    SELECT @job_rows = @job_rows
         + N'<tr class="' + CASE WHEN health_status = N'OK' THEN N'okrow'
                                  WHEN health_status IN (N'DISABLED', N'NOT_MONITORED') THEN N'warning'
                                  ELSE N'critical' END
         + N'"><td><b>' + monitor.fn_HtmlEncode(job_name) + N'</b></td>'
         + N'<td>' + monitor.fn_HtmlEncode(maintenance_type) + N'</td>'
         + N'<td>' + monitor.fn_HtmlEncode(health_status) + N'</td>'
         + N'<td>' + CONVERT(nvarchar(30), max_hours_since_success) + N'h</td>'
         + N'<td>' + monitor.fn_HtmlEncode(COALESCE(CONVERT(nvarchar(19), last_run_server_time, 120), N'never'))
             + N'<br><span class="small">duration '
             + COALESCE(CONVERT(nvarchar(20), last_run_duration_seconds), N'-') + N's</span></td>'
         + N'<td>' + monitor.fn_HtmlEncode(COALESCE(CONVERT(nvarchar(19), last_success_server_time, 120), N'never')) + N'</td>'
         + N'<td class="small">' + monitor.fn_HtmlEncode(COALESCE(last_run_message, N'')) + N'</td></tr>'
    FROM monitor.vw_MaintenanceJobHealth
    WHERE is_monitored = 1
    ORDER BY CASE WHEN health_status = N'OK' THEN 1 ELSE 0 END, job_name;

    SELECT @failure_rows = @failure_rows
         + N'<tr><td>' + CONVERT(nvarchar(20), task_id) + N'</td><td>'
         + monitor.fn_HtmlEncode(COALESCE(database_name, N'')) + N'</td><td>'
         + monitor.fn_HtmlEncode(COALESCE(task_type, N'')) + N'</td><td>'
         + monitor.fn_HtmlEncode(COALESCE(CONVERT(nvarchar(19), created_at_server_time, 120), N'')) + N'</td><td>'
         + monitor.fn_HtmlEncode(COALESCE(task_info, N'')) + N'</td></tr>'
    FROM monitor.RdsTaskHistory
    WHERE task_type IN (N'BACKUP_DB', N'BACKUP_DB_DIFFERENTIAL')
      AND lifecycle IN (N'ERROR', N'CANCELLED')
      AND created_at_server_time >= DATEADD(HOUR, -12, GETDATE())
    ORDER BY created_at_server_time DESC;

    SELECT @agent_rows = @agent_rows
         + N'<tr class="critical"><td><b>' + monitor.fn_HtmlEncode(job_name) + N'</b></td><td>'
         + CASE run_status WHEN 3 THEN N'CANCELLED' WHEN 2 THEN N'RETRY' ELSE N'FAILED' END + N'</td><td>'
         + monitor.fn_HtmlEncode(COALESCE(failure_step_name, N'(job outcome)')) + N'</td><td>'
         + monitor.fn_HtmlEncode(CONVERT(nvarchar(19), run_start_server_time, 120)) + N'</td><td>'
         + CONVERT(nvarchar(20), run_duration_seconds) + N's</td><td class="small">'
         + monitor.fn_HtmlEncode(COALESCE(message, N'')) + N'</td></tr>'
    FROM monitor.AgentFailureEvent
    WHERE run_start_server_time >= DATEADD(HOUR, -12, GETDATE())
    ORDER BY run_start_server_time DESC, job_name;

    SELECT @deadlock_rows = @deadlock_rows
         + N'<tr class="critical"><td>' + monitor.fn_HtmlEncode(CONVERT(nvarchar(23), event_utc, 121)) + N' UTC</td><td>'
         + monitor.fn_HtmlEncode(COALESCE(database_name, N'(not identified)')) + N'</td><td>'
         + monitor.fn_HtmlEncode(COALESCE(victim_process_id, N'unknown')) + N'</td><td>'
         + COALESCE(CONVERT(nvarchar(20), process_count), N'unknown') + N'</td><td class="small">'
         + monitor.fn_HtmlEncode(CONVERT(varchar(64), deadlock_hash, 2)) + N'</td></tr>'
    FROM monitor.DeadlockEvent
    WHERE event_utc >= DATEADD(HOUR, -12, SYSUTCDATETIME())
    ORDER BY event_utc DESC;

    SELECT @server_error_rows = @server_error_rows
         + N'<tr class="critical"><td>'
         + monitor.fn_HtmlEncode(CONVERT(nvarchar(19), log_date_server_time, 120)) + N'</td><td>'
         + monitor.fn_HtmlEncode(COALESCE(process_info, N'')) + N'</td><td class="small">'
         + monitor.fn_HtmlEncode(message) + N'</td></tr>'
    FROM monitor.ServerErrorLogEvent
    WHERE log_date_server_time >= DATEADD(HOUR, -12, GETDATE())
    ORDER BY log_date_server_time DESC;

    SELECT @anomaly_rows = @anomaly_rows
         + N'<tr class="' + CASE WHEN severity = N'CRITICAL' THEN N'critical' ELSE N'warning' END
         + N'"><td><b>' + monitor.fn_HtmlEncode(severity) + N'</b></td><td>'
         + monitor.fn_HtmlEncode(anomaly) + N'</td><td class="small">'
         + monitor.fn_HtmlEncode(COALESCE(details, N'')) + N'</td></tr>'
    FROM #Anomaly
    ORDER BY CASE WHEN severity = N'CRITICAL' THEN 0 ELSE 1 END, anomaly;

    IF @backup_rows = N'' SET @backup_rows = N'<tr><td colspan="6">No monitored databases found.</td></tr>';
    IF @job_rows = N'' SET @job_rows = N'<tr><td colspan="7">No standard Ola Hallengren jobs were discovered. Add custom jobs to monitor.MaintenanceJobPolicy if needed.</td></tr>';
    IF @failure_rows = N'' SET @failure_rows = N'<tr class="okrow"><td colspan="5">No failed or cancelled RDS native backup tasks in the last 12 hours.</td></tr>';
    IF @agent_rows = N'' SET @agent_rows = N'<tr class="okrow"><td colspan="6">No failed, retried, or cancelled SQL Agent job steps in the last 12 hours.</td></tr>';
    IF @deadlock_rows = N'' SET @deadlock_rows = N'<tr class="okrow"><td colspan="5">No deadlocks captured in the last 12 hours.</td></tr>';
    IF @server_error_rows = N'' SET @server_error_rows = N'<tr class="okrow"><td colspan="3">No high-signal SQL Server error-log entries in the last 12 hours.</td></tr>';
    IF @anomaly_rows = N'' SET @anomaly_rows = N'<tr class="okrow"><td colspan="3">No current server anomalies detected by the SQL-visible checks.</td></tr>';

    DECLARE @overall nvarchar(20) =
        CASE WHEN @backup_bad + @job_bad + @rds_fail + @collector_bad
                       + @agent_fail + @deadlock_count + @server_error_count + @anomaly_count > 0
             THEN N'ATTENTION' ELSE N'HEALTHY' END;
    DECLARE @subject nvarchar(255) = LEFT(CONCAT(N'[', @overall, N'] ', @server,
        N' Daily SQL Server Health Report - ', CONVERT(nvarchar(10), @report_date, 120)), 255);
    DECLARE @body nvarchar(max), @mailitem_id int;

    SET @body = N'<html><head><style>'
        + N'body{font-family:Segoe UI,Arial;color:#1f2937}h1{margin-bottom:2px}h2{color:#1e3a5f;margin-top:24px}'
        + N'.cards{display:flex;gap:12px}.card{display:inline-block;border:1px solid #cbd5e1;border-radius:6px;padding:10px 18px;margin-right:10px}'
        + N'.ok{color:#166534}.bad{color:#991b1b}table{border-collapse:collapse;width:100%;font-size:13px}'
        + N'th{background:#1e3a5f;color:#fff}th,td{border:1px solid #cbd5e1;padding:6px;text-align:left;vertical-align:top}'
        + N'tr:nth-child(even){background:#f8fafc}.small{font-size:11px;color:#64748b}'
        + N'tr.critical td{background:#fee2e2;color:#7f1d1d}tr.warning td{background:#fef3c7;color:#78350f}'
        + N'tr.okrow td{background:#ecfdf5;color:#14532d}'
        + N'</style></head><body><h1>' + monitor.fn_HtmlEncode(@server)
        + N' SQL Server Operational Health</h1><div class="small">Report time: '
        + monitor.fn_HtmlEncode(CONVERT(nvarchar(30), @eastern_now, 120)) + N' Eastern | Collection times shown in SQL Server time unless marked UTC</div>'
        + N'<p><span class="card"><b>Overall</b><br><span class="'
        + CASE WHEN @overall = N'HEALTHY' THEN N'ok' ELSE N'bad' END + N'">' + @overall + N'</span></span>'
        + N'<span class="card"><b>Backup exceptions</b><br>' + CONVERT(nvarchar(20), @backup_bad) + N'</span>'
        + N'<span class="card"><b>Agent failures (12h)</b><br>' + CONVERT(nvarchar(20), @agent_fail) + N'</span>'
        + N'<span class="card"><b>Maintenance exceptions</b><br>' + CONVERT(nvarchar(20), @job_bad) + N'</span>'
        + N'<span class="card"><b>Deadlocks (12h)</b><br>' + CONVERT(nvarchar(20), @deadlock_count) + N'</span>'
        + N'<span class="card"><b>Server errors (12h)</b><br>' + CONVERT(nvarchar(20), @server_error_count) + N'</span>'
        + N'<span class="card"><b>Server anomalies</b><br>' + CONVERT(nvarchar(20), @anomaly_count) + N'</span>'
        + N'<span class="card"><b>RDS task failures (12h)</b><br>' + CONVERT(nvarchar(20), @rds_fail) + N'</span>'
        + N'<span class="card"><b>Collector freshness</b><br>'
        + CASE WHEN @collector_bad = 0 THEN N'<span class="ok">OK</span>' ELSE N'<span class="bad">STALE</span>' END
        + N'<br><span class="small">' + COALESCE(CONVERT(nvarchar(19), @last_collection_utc, 120), N'never') + N' UTC</span></span></p>'
        + N'<h2>Backup Health — All User Databases</h2><p class="small">Red = missing, overdue, broken chain, or database not online. Amber = monitoring disabled or log backup status cannot be verified. Green = compliant. Default SLA: FULL 24h; DIFF/effective data backup 6h; LOG 30m.</p>'
        + N'<table><tr><th>Database</th><th>Recovery</th><th>FULL</th><th>DIFF / Effective</th><th>LOG</th><th>S3 / Device</th></tr>'
        + @backup_rows + N'</table>'
        + N'<h2>All SQL Agent Failures / Retries / Cancellations — Last 12 Hours</h2><table><tr><th>Job</th><th>Outcome</th><th>Step</th><th>Run time</th><th>Duration</th><th>Message</th></tr>'
        + @agent_rows + N'</table>'
        + N'<h2>Current Server Anomalies</h2><table><tr><th>Severity</th><th>Anomaly</th><th>Details</th></tr>'
        + @anomaly_rows + N'</table>'
        + N'<h2>Deadlocks — Last 12 Hours</h2><p class="small">The complete deadlock XML is retained in OPS.monitor.DeadlockEvent for investigation.</p><table><tr><th>UTC time</th><th>Database</th><th>Victim process</th><th>Processes</th><th>Event hash</th></tr>'
        + @deadlock_rows + N'</table>'
        + N'<h2>High-Signal SQL Server Error Log — Last 12 Hours</h2><table><tr><th>Server time</th><th>Process</th><th>Message</th></tr>'
        + @server_error_rows + N'</table>'
        + N'<h2>Ola Hallengren Maintenance Job Health</h2><table><tr><th>Job</th><th>Type</th><th>Health</th><th>Max age</th><th>Last run</th><th>Last success</th><th>Last message</th></tr>'
        + @job_rows + N'</table>'
        + N'<h2>Failed / Cancelled RDS Native Backup Tasks — Last 12 Hours</h2><table><tr><th>Task</th><th>Database</th><th>Type</th><th>Created</th><th>Error</th></tr>'
        + @failure_rows + N'</table>'
        + N'<h2>Interpretation Notes</h2><ul>'
        + N'<li><b>UNVERIFIED</b> transaction-log status means SQL cannot read RDS log-backup metadata; it does not mean the log backup failed.</li>'
        + N'<li>S3 lifecycle retention is not exposed through these T-SQL interfaces. Verify the bucket lifecycle policy separately.</li>'
        + N'<li>CloudWatch remains authoritative for RDS CPU, FreeableMemory, FreeStorageSpace, failover events, and host-level health.</li>'
        + N'<li>OPS monitoring history retention: ' + CONVERT(nvarchar(10), @retention) + N' days. RDS task history itself is retained by AWS for 36 days.</li>'
        + N'</ul><p class="small">Generated by OPS.monitor on ' + monitor.fn_HtmlEncode(@server) + N'.</p></body></html>';

    EXEC msdb.dbo.sp_send_dbmail
         @profile_name = @profile,
         @recipients = @recipients,
         @subject = @subject,
         @body = @body,
         @body_format = 'HTML',
         @mailitem_id = @mailitem_id OUTPUT;

    INSERT monitor.NotificationLog
        (notification_type, queued_utc, report_date_eastern, subject,
         recipients, mailitem_id, exception_count)
    VALUES(N'DAILY', SYSUTCDATETIME(),
           CASE WHEN @Force = 1 THEN NULL ELSE @report_date END, @subject,
           @recipients, @mailitem_id,
           @backup_bad + @job_bad + @rds_fail + @collector_bad
             + @agent_fail + @deadlock_count + @server_error_count + @anomaly_count);
END;
GO

CREATE OR ALTER PROCEDURE monitor.usp_PurgeHistory
AS
BEGIN
    SET NOCOUNT ON;
    SET DEADLOCK_PRIORITY LOW;
    DECLARE @days int =
        (SELECT history_retention_days FROM monitor.Settings WHERE settings_id = 1);
    IF @days IS NULL SET @days = 90;

    DELETE TOP (10000) FROM monitor.BackupSample
     WHERE captured_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
    DELETE TOP (10000) FROM monitor.AgentJobRun
     WHERE imported_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
    DELETE TOP (10000) FROM monitor.AgentFailureEvent
     WHERE collected_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
    DELETE TOP (10000) FROM monitor.DeadlockEvent
     WHERE event_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
    DELETE TOP (10000) FROM monitor.ServerErrorLogEvent
     WHERE collected_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
    DELETE TOP (10000) FROM monitor.DatabaseLogSample
     WHERE captured_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
    DELETE TOP (10000) FROM monitor.StorageSample
     WHERE captured_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
    DELETE TOP (10000) FROM monitor.RdsTaskHistory
     WHERE last_collected_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
    DELETE TOP (10000) FROM monitor.TlogBackupHistory
     WHERE collected_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
    DELETE TOP (10000) FROM monitor.CollectorRun
     WHERE started_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
    DELETE TOP (10000) FROM monitor.NotificationLog
     WHERE queued_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
    DELETE TOP (10000) FROM monitor.AlertState
     WHERE is_active = 0 AND resolved_utc < DATEADD(DAY, -@days, SYSUTCDATETIME());
END;
GO

/* ---------- SQL Agent jobs ---------- */

USE [msdb];
GO

DECLARE @owner sysname = SUSER_SNAME();

IF NOT EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'OPS - Backup and Maintenance Monitor')
BEGIN
    EXEC dbo.sp_add_job
         @job_name = N'OPS - Backup and Maintenance Monitor',
         @enabled = 1,
         @description = N'Collects backup, Agent failure, deadlock, RDS error, capacity, and Ola health; sends de-duplicated alerts.',
         @owner_login_name = @owner;
    EXEC dbo.sp_add_jobstep
         @job_name = N'OPS - Backup and Maintenance Monitor',
         @step_name = N'Collect and alert',
         @subsystem = N'TSQL',
         @database_name = N'OPS',
         @command = N'EXEC monitor.usp_CollectBackupAndMaintenance; EXEC monitor.usp_CollectOperationalHealth; EXEC monitor.usp_SendImmediateAlerts;',
         @retry_attempts = 2,
         @retry_interval = 1;
    EXEC dbo.sp_add_jobserver @job_name = N'OPS - Backup and Maintenance Monitor';
END
ELSE
BEGIN
    EXEC dbo.sp_update_job
         @job_name = N'OPS - Backup and Maintenance Monitor',
         @enabled = 1,
         @description = N'Collects backup, Agent failure, deadlock, RDS error, capacity, and Ola health; sends de-duplicated alerts.';
    BEGIN TRY
        EXEC dbo.sp_update_jobstep
             @job_name = N'OPS - Backup and Maintenance Monitor',
             @step_id = 1, @step_name = N'Collect and alert',
             @subsystem = N'TSQL', @database_name = N'OPS',
             @command = N'EXEC monitor.usp_CollectBackupAndMaintenance; EXEC monitor.usp_CollectOperationalHealth; EXEC monitor.usp_SendImmediateAlerts;',
             @retry_attempts = 2, @retry_interval = 1;
    END TRY
    BEGIN CATCH
        EXEC dbo.sp_add_jobstep
             @job_name = N'OPS - Backup and Maintenance Monitor',
             @step_name = N'Collect and alert',
             @subsystem = N'TSQL', @database_name = N'OPS',
             @command = N'EXEC monitor.usp_CollectBackupAndMaintenance; EXEC monitor.usp_CollectOperationalHealth; EXEC monitor.usp_SendImmediateAlerts;',
             @retry_attempts = 2, @retry_interval = 1;
    END CATCH;
END;

/*
   RDS master users can't SELECT msdb.dbo.sysschedules/sysjobschedules.
   Use Agent procedures, which perform the protected catalog work internally.
*/
BEGIN TRY
    EXEC dbo.sp_update_jobschedule
         @job_name = N'OPS - Backup and Maintenance Monitor',
         @name = N'OPS - Every 5 minutes',
         @enabled = 1,
         @freq_type = 4, @freq_interval = 1,
         @freq_subday_type = 4, @freq_subday_interval = 5,
         @active_start_time = 000000;
END TRY
BEGIN CATCH
    /* The first installation has no job-specific schedule to update. */
    EXEC dbo.sp_add_jobschedule
         @job_name = N'OPS - Backup and Maintenance Monitor',
         @name = N'OPS - Every 5 minutes',
         @enabled = 1,
         @freq_type = 4, @freq_interval = 1,
         @freq_subday_type = 4, @freq_subday_interval = 5,
         @active_start_time = 000000;
END CATCH;
GO

DECLARE @owner sysname = SUSER_SNAME();

IF NOT EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'OPS - Daily Backup and Maintenance Report')
BEGIN
    EXEC dbo.sp_add_job
         @job_name = N'OPS - Daily Backup and Maintenance Report',
         @enabled = 1,
         @description = N'Sends the DST-aware 08:00 Eastern SQL Server health report and purges monitoring history.',
         @owner_login_name = @owner;
    EXEC dbo.sp_add_jobstep
         @job_name = N'OPS - Daily Backup and Maintenance Report',
         @step_name = N'Send report when due',
         @subsystem = N'TSQL',
         @database_name = N'OPS',
         @command = N'EXEC monitor.usp_SendDailyReport @Force = 0; EXEC monitor.usp_PurgeHistory;',
         @retry_attempts = 1,
         @retry_interval = 5;
    EXEC dbo.sp_add_jobserver @job_name = N'OPS - Daily Backup and Maintenance Report';
END
ELSE
BEGIN
    EXEC dbo.sp_update_job
         @job_name = N'OPS - Daily Backup and Maintenance Report',
         @enabled = 1,
         @description = N'Sends the DST-aware 08:00 Eastern SQL Server health report and purges monitoring history.';
    BEGIN TRY
        EXEC dbo.sp_update_jobstep
             @job_name = N'OPS - Daily Backup and Maintenance Report',
             @step_id = 1, @step_name = N'Send report when due',
             @subsystem = N'TSQL', @database_name = N'OPS',
             @command = N'EXEC monitor.usp_SendDailyReport @Force = 0; EXEC monitor.usp_PurgeHistory;',
             @retry_attempts = 1, @retry_interval = 5;
    END TRY
    BEGIN CATCH
        EXEC dbo.sp_add_jobstep
             @job_name = N'OPS - Daily Backup and Maintenance Report',
             @step_name = N'Send report when due',
             @subsystem = N'TSQL', @database_name = N'OPS',
             @command = N'EXEC monitor.usp_SendDailyReport @Force = 0; EXEC monitor.usp_PurgeHistory;',
             @retry_attempts = 1, @retry_interval = 5;
    END CATCH;
END;

/* Hourly schedule + Eastern-time guard avoids DST drift. */
BEGIN TRY
    EXEC dbo.sp_update_jobschedule
         @job_name = N'OPS - Daily Backup and Maintenance Report',
         @name = N'OPS - Hourly report check',
         @enabled = 1,
         @freq_type = 4, @freq_interval = 1,
         @freq_subday_type = 8, @freq_subday_interval = 1,
         @active_start_time = 000000;
END TRY
BEGIN CATCH
    EXEC dbo.sp_add_jobschedule
         @job_name = N'OPS - Daily Backup and Maintenance Report',
         @name = N'OPS - Hourly report check',
         @enabled = 1,
         @freq_type = 4, @freq_interval = 1,
         @freq_subday_type = 8, @freq_subday_interval = 1,
         @active_start_time = 000000;
END CATCH;
GO

USE [OPS];
GO

/* Initial collection. No email is sent by this installer. */
EXEC monitor.usp_CollectBackupAndMaintenance;
EXEC monitor.usp_CollectOperationalHealth;
GO

/* Validation result sets. Review these before forcing a test email. */
SELECT * FROM monitor.vw_BackupHealth ORDER BY database_name;
SELECT * FROM monitor.vw_MaintenanceJobHealth ORDER BY job_name;
SELECT TOP (20) * FROM monitor.CollectorRun ORDER BY collector_run_id DESC;
SELECT * FROM monitor.ComponentStatus ORDER BY component_name;
SELECT TOP (100) * FROM monitor.AgentFailureEvent
 WHERE run_start_server_time >= DATEADD(HOUR, -12, GETDATE())
 ORDER BY run_start_server_time DESC;
SELECT TOP (100) event_utc, database_name, victim_process_id, process_count, deadlock_hash
 FROM monitor.DeadlockEvent
 WHERE event_utc >= DATEADD(HOUR, -12, SYSUTCDATETIME())
 ORDER BY event_utc DESC;
GO

/*
    After reviewing the result sets, send one test report manually:

        USE OPS;
        EXEC monitor.usp_SendDailyReport @Force = 1;

    Verify RDS Database Mail delivery:

        SELECT TOP (20) *
        FROM msdb.dbo.rds_fn_sysmail_allitems()
        ORDER BY send_request_date DESC;

        SELECT TOP (100) *
        FROM msdb.dbo.rds_fn_sysmail_event_log()
        ORDER BY log_date DESC;

    Common policy overrides:

        -- A database does not use differential backups:
        UPDATE OPS.monitor.DatabaseBackupPolicy
        SET require_diff = 0, notes = N'FULL + LOG strategy'
        WHERE database_name = N'YourDatabase';

        -- A weekly Ola job may go 8 days between successes:
        UPDATE OPS.monitor.MaintenanceJobPolicy
        SET max_hours_since_success = 192
        WHERE job_name = N'IndexOptimize - USER_DATABASES';

        -- Add a custom maintenance job not matching standard Ola names:
        INSERT OPS.monitor.MaintenanceJobPolicy
            (job_id, job_name, maintenance_type, max_hours_since_success, auto_discovered)
        SELECT job_id, name, N'CUSTOM', 24, 0
        FROM msdb.dbo.sysjobs
        WHERE name = N'Your custom maintenance job';
*/
