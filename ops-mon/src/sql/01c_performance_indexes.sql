
/* =============================================================================
   SECTION 3d  -  PERFORMANCE INDEXES   [rev 5.5]
   Idempotent: each index is created only if missing (or rebuilt with DROP_EXISTING
   when its definition changed). All indexes live on mon.* tables only.
   ============================================================================= */

/* Retention view + backup collector: per-database latest log backup and the 35-day window,
   covering so no key lookups on ~50k rows. Replaces IX_mon_TlogBackup_Time (same keys, now with INCLUDE). */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mon.TlogBackup') AND name = N'IX_mon_TlogBackup_Time')
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns AS ic JOIN sys.indexes AS i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   WHERE i.object_id = OBJECT_ID(N'mon.TlogBackup') AND i.name = N'IX_mon_TlogBackup_Time' AND ic.is_included_column = 1)
    CREATE INDEX IX_mon_TlogBackup_Time ON mon.TlogBackup(database_name, backup_file_time_utc DESC)
        INCLUDE (file_size_bytes, is_log_chain_broken, last_seen_utc) WITH (DROP_EXISTING = ON);
GO
/* Purge (DELETE ... WHERE backup_file_time_utc < @cut) and the cross-database 35-day filter */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mon.TlogBackup') AND name = N'IX_mon_TlogBackup_FileTime')
    CREATE INDEX IX_mon_TlogBackup_FileTime ON mon.TlogBackup(backup_file_time_utc)
        INCLUDE (database_name, file_size_bytes, last_seen_utc);
GO
/* Retention view: successful RDS native backups */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mon.RdsTask') AND name = N'IX_mon_RdsTask_Lifecycle')
    CREATE INDEX IX_mon_RdsTask_Lifecycle ON mon.RdsTask(lifecycle, task_type)
        INCLUDE (database_name, last_updated_utc, created_utc);
GO
/* Retention view: Ola backups only (filtered) */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mon.OlaCommand') AND name = N'IX_mon_OlaCommand_Backup')
    CREATE INDEX IX_mon_OlaCommand_Backup ON mon.OlaCommand(database_name, backup_type, end_utc)
        INCLUDE (error_number, file_count) WHERE backup_type IS NOT NULL;
GO
/* Purge by time */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mon.OlaCommand') AND name = N'IX_mon_OlaCommand_Start')
    CREATE INDEX IX_mon_OlaCommand_Start ON mon.OlaCommand(start_utc);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mon.AgentJobRun') AND name = N'IX_mon_AgentJobRun_Time')
    CREATE INDEX IX_mon_AgentJobRun_Time ON mon.AgentJobRun(run_start_utc);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mon.EngineRun') AND name = N'IX_mon_EngineRun_Started')
    CREATE INDEX IX_mon_EngineRun_Started ON mon.EngineRun(started_utc);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mon.RdsTask') AND name = N'IX_mon_RdsTask_Collected')
    CREATE INDEX IX_mon_RdsTask_Collected ON mon.RdsTask(last_collected_utc);
GO
/* Issue history joins (digest "what changed", purge DELETE ... JOIN Issue) */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mon.IssueChange') AND name = N'IX_mon_IssueChange_Issue')
    CREATE INDEX IX_mon_IssueChange_Issue ON mon.IssueChange(issue_id, change_id);
GO
/* Email statistics: MON vs other senders (EXISTS by mailitem_id) */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mon.Notification') AND name = N'IX_mon_Notification_Mailitem')
    CREATE INDEX IX_mon_Notification_Mailitem ON mon.Notification(mailitem_id) WHERE mailitem_id IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mon.Notification') AND name = N'IX_mon_Notification_Created')
    CREATE INDEX IX_mon_Notification_Created ON mon.Notification(created_utc) INCLUDE (notification_type, send_ok, body_kb);
GO
