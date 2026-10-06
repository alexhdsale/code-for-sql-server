
/* =============================================================================
   SECTION 3b  -  CHECK MATRIX (what is monitored) + BACKUP INVENTORY    [rev 5.1]
   mon.DatabaseCheck  : one row per database, one bit column per check.
                        Edit in SSMS: right-click table > Edit Top 200 Rows,
                        or EXEC mon.usp_SetCheck. Source of truth for on/off.
   mon.ServerCheck    : instance-level checks (one row per check).
   mon.CheckCatalog   : what every check does, which issue keys it owns.
   mon.CheckChangeLog : audit of every change (who / when / old -> new).
   mon.BackupInventoryDaily : daily retention/inventory snapshot per DB/type.
   mon.DatabasePolicy keeps the SLA minutes only; its require_* / is_monitored
   flags are migrated once into mon.DatabaseCheck and no longer read.
   ============================================================================= */

INSERT mon.Setting(setting_name, setting_value, value_type, category, description)
SELECT v.n, v.v, v.t, v.c, v.d
FROM (VALUES
    ('backup_retention_target_days', N'7', 'int', 'backup',
     N'Default number of days of backup history each database must have (per-DB override: mon.DatabaseCheck.retention_days).')
) AS v(n, v, t, c, d)
WHERE NOT EXISTS (SELECT 1 FROM mon.Setting AS s WHERE s.setting_name = v.n);
GO

IF OBJECT_ID(N'mon.CheckCatalog', N'U') IS NULL
BEGIN
    CREATE TABLE mon.CheckCatalog
    (
        check_code     varchar(20)    NOT NULL CONSTRAINT PK_mon_CheckCatalog PRIMARY KEY,
        scope          varchar(10)    NOT NULL,          /* DATABASE | SERVER */
        column_name    sysname        NULL,              /* column in mon.DatabaseCheck (DATABASE scope) */
        key_pattern    nvarchar(100)  NULL,              /* LIKE pattern on mon.Issue.issue_key it owns */
        display_name   nvarchar(60)   NOT NULL,
        description    nvarchar(1000) NOT NULL,
        threshold_info nvarchar(400)  NULL,              /* which mon.Setting rows tune it */
        sort_order     int            NOT NULL,
        CONSTRAINT CK_mon_CheckCatalog_Scope CHECK (scope IN ('DATABASE', 'SERVER'))
    );
END;
GO

;WITH Seed AS
(
    SELECT * FROM (VALUES
    /* code            scope       column                   key pattern          display                  sort description / thresholds */
     ('MONITORED',     'DATABASE', 'monitored',             NULL,                N'Monitored',             10, N'Master switch. OFF = the database is ignored by every check and its open issues are closed silently.', NULL)
    ,('FULL',          'DATABASE', 'full_backup',           N'BACKUP:FULL:%',    N'Full backup',           20, N'Last FULL backup age vs SLA (msdb, RDS native task).', N'DatabasePolicy.full_max_age_minutes')
    ,('DIFF',          'DATABASE', 'diff_backup',           N'BACKUP:DIFF:%',    N'Diff backup',           30, N'Last DIFF or FULL (effective data backup) age vs SLA.', N'DatabasePolicy.diff_max_age_minutes')
    ,('LOG',           'DATABASE', 'log_backup',            N'BACKUP:LOG:%',     N'Log backup',            40, N'Last LOG backup age vs SLA, broken log chain. Not applicable to SIMPLE recovery.', N'DatabasePolicy.log_max_age_minutes')
    ,('RETENTION',     'DATABASE', 'backup_retention',      N'RETENTION:%',      N'Backup retention',      50, N'Backup history depth (days) vs target, no backups of an enabled type, gaps in the chain.', N'DatabaseCheck.retention_days / setting backup_retention_target_days')
    ,('CHECKDB',       'DATABASE', 'checkdb',               N'CHECKDB:%',        N'CHECKDB',               60, N'Last known good DBCC CHECKDB age.', N'DatabasePolicy.checkdb_max_age_days')
    ,('LOGUSED',       'DATABASE', 'log_used',              N'LOGUSED:%',        N'Log used %',            70, N'Transaction log fullness with log_reuse_wait explanation.', N'log_used_warn_pct / log_used_crit_pct')
    ,('VLF',           'DATABASE', 'vlf_count',             N'VLF:%',            N'VLF count',             80, N'Too many virtual log files.', N'vlf_warn_count')
    ,('FILEMAX',       'DATABASE', 'file_near_max',         N'FILEMAX:%',        N'File near MAXSIZE',     90, N'Data/log file close to its MAXSIZE.', N'file_near_max_pct')
    ,('DRIFT',         'DATABASE', 'config_drift',          N'DRIFT:%',          N'Config drift',         100, N'Recovery model, compat level, owner, page verify, RCSI, read-only... changed vs accepted baseline.', N'EXEC mon.usp_AcceptConfigBaseline')
    ,('CONFIG',        'DATABASE', 'config_best_practice',  N'CONFIG:%',         N'Best-practice config', 110, N'AUTO_CLOSE / AUTO_SHRINK ON, PAGE_VERIFY not CHECKSUM.', NULL)
    ,('QSTORE',        'DATABASE', 'query_store',           N'QSTORE:%',         N'Query Store',          120, N'Query Store forced to READ_ONLY (e.g. size limit reached).', NULL)
    ,('BLOCKING',      'DATABASE', 'blocking',              N'BLOCKING:%',       N'Blocking',             130, N'Blocking episode longer than the alert threshold (sampled every 30 s).', N'blocking_alert_minutes')
    ,('LONGQ',         'DATABASE', 'long_queries',          N'LONGQ:%',          N'Long queries',         140, N'Requests running longer than the thresholds.', N'long_query_warn_minutes / long_query_crit_minutes')
    ,('OPENTRAN',      'DATABASE', 'open_trans',            N'OPENTRAN:%',       N'Open transactions',    150, N'Idle or long open transactions (locks, log truncation).', N'open_tran_warn_minutes / open_tran_crit_minutes')
    ,('DEADLOCK',      'DATABASE', 'deadlocks',             N'DEADLOCK:%',       N'Deadlocks',            160, N'Each deadlock from system_health.', N'deadlock_severity')
    ,('IOLAT',         'DATABASE', 'io_latency',            N'IOLAT:%',          N'I/O latency',          170, N'Average read/write latency per file over the last hour.', N'io_latency_warn_ms / io_latency_min_ios')
    ,('DB_STATE',      'SERVER',   NULL,                    N'DBSTATE:%',        N'Database state',       200, N'Database not ONLINE, SINGLE_USER, or dropped.', NULL)
    ,('AGENT_FAIL',    'SERVER',   NULL,                    N'JOBFAIL:%',        N'Agent job failures',   210, N'Any SQL Agent job failed or was cancelled.', N'event_lookback_hours')
    ,('JOB_SLA',       'SERVER',   NULL,                    N'JOBSLA:%',         N'Maintenance job SLA',  220, N'Ola Hallengren / RDS backup jobs: hours since last success, disabled, missing.', N'mon.JobPolicy.max_hours_since_success')
    ,('JOB_LONG',      'SERVER',   NULL,                    N'JOBLONG:%',        N'Job duration anomaly', 230, N'Running job far longer than its 30-day median.', N'job_duration_factor / job_duration_min_minutes')
    ,('RDS_TASKS',     'SERVER',   NULL,                    N'RDS%',             N'RDS native tasks',     240, N'RDS native backup task failed, cancelled or stuck.', N'rds_task_stuck_hours')
    ,('ERRORLOG',      'SERVER',   NULL,                    N'ERRLOG:%',         N'SQL error log',        250, N'High-signal error log entries (823/824/825, 9002, 17883, sev 20+...).', NULL)
    ,('LOGIN_FAIL',    'SERVER',   NULL,                    N'LOGINFAIL',        N'Failed logins',        260, N'Burst of failed logins.', N'failed_login_warn_per_hour')
    ,('DEADLOCK_STORM','SERVER',   NULL,                    N'DEADLOCK_STORM',   N'Deadlock storm',       270, N'Many deadlocks in one hour.', N'deadlock_storm_per_hour')
    ,('CPU',           'SERVER',   NULL,                    N'CPU',              N'CPU',                  280, N'SQL Server CPU 15-minute average.', N'cpu_warn_pct / cpu_crit_pct')
    ,('MEMGRANTS',     'SERVER',   NULL,                    N'MEMGRANTS',        N'Memory grants',        290, N'Memory grants pending in consecutive samples.', NULL)
    ,('TEMPDB',        'SERVER',   NULL,                    N'TEMPDB',           N'tempdb',               300, N'tempdb used % of allocated.', N'tempdb_used_warn_pct')
    ,('STORAGE',       'SERVER',   NULL,                    N'STORAGE:%',        N'Storage',              310, N'SQL-visible volume free space.', N'storage_free_warn_pct / storage_free_crit_pct')
    ,('RESTART',       'SERVER',   NULL,                    N'RESTART:%',        N'Restart / failover',   320, N'SQL Server restarted or failed over.', NULL)
    ,('MAIL',          'SERVER',   NULL,                    N'MAIL:%',           N'Database Mail',        330, N'Database Mail items failed / stuck unsent.', NULL)
    ) AS v(check_code, scope, column_name, key_pattern, display_name, sort_order, description, threshold_info)
)
MERGE mon.CheckCatalog AS t
USING Seed AS s ON t.check_code = s.check_code
WHEN MATCHED THEN UPDATE SET scope = s.scope, column_name = s.column_name, key_pattern = s.key_pattern,
     display_name = s.display_name, description = s.description, threshold_info = s.threshold_info, sort_order = s.sort_order
WHEN NOT MATCHED THEN INSERT (check_code, scope, column_name, key_pattern, display_name, description, threshold_info, sort_order)
     VALUES (s.check_code, s.scope, s.column_name, s.key_pattern, s.display_name, s.description, s.threshold_info, s.sort_order);
GO

SET XACT_ABORT ON;
DECLARE @first_install bit = CASE WHEN OBJECT_ID(N'mon.DatabaseCheck', N'U') IS NULL THEN 1 ELSE 0 END;

IF @first_install = 1
BEGIN
    BEGIN TRANSACTION;   /* create + migrate atomically: a failed migration leaves no empty table behind */
    CREATE TABLE mon.DatabaseCheck
    (
        database_name         sysname        NOT NULL CONSTRAINT PK_mon_DatabaseCheck PRIMARY KEY,
        monitored             bit            NOT NULL CONSTRAINT DF_mon_DC_mon   DEFAULT (1),
        full_backup           bit            NOT NULL CONSTRAINT DF_mon_DC_full  DEFAULT (1),
        diff_backup           bit            NOT NULL CONSTRAINT DF_mon_DC_diff  DEFAULT (1),
        log_backup            bit            NOT NULL CONSTRAINT DF_mon_DC_log   DEFAULT (1),
        backup_retention      bit            NOT NULL CONSTRAINT DF_mon_DC_ret   DEFAULT (1),
        retention_days        int            NULL,     /* NULL = setting backup_retention_target_days */
        checkdb               bit            NOT NULL CONSTRAINT DF_mon_DC_chk   DEFAULT (1),
        log_used              bit            NOT NULL CONSTRAINT DF_mon_DC_logu  DEFAULT (1),
        vlf_count             bit            NOT NULL CONSTRAINT DF_mon_DC_vlf   DEFAULT (1),
        file_near_max         bit            NOT NULL CONSTRAINT DF_mon_DC_fmax  DEFAULT (1),
        config_drift          bit            NOT NULL CONSTRAINT DF_mon_DC_drift DEFAULT (1),
        config_best_practice  bit            NOT NULL CONSTRAINT DF_mon_DC_cfg   DEFAULT (1),
        query_store           bit            NOT NULL CONSTRAINT DF_mon_DC_qs    DEFAULT (1),
        blocking              bit            NOT NULL CONSTRAINT DF_mon_DC_blk   DEFAULT (1),
        long_queries          bit            NOT NULL CONSTRAINT DF_mon_DC_lq    DEFAULT (1),
        open_trans            bit            NOT NULL CONSTRAINT DF_mon_DC_ot    DEFAULT (1),
        deadlocks             bit            NOT NULL CONSTRAINT DF_mon_DC_dl    DEFAULT (1),
        io_latency            bit            NOT NULL CONSTRAINT DF_mon_DC_io    DEFAULT (1),
        notes                 nvarchar(400)  NULL,
        modified_utc          datetime2(0)   NOT NULL CONSTRAINT DF_mon_DC_mod   DEFAULT SYSUTCDATETIME(),
        modified_by           sysname        NOT NULL CONSTRAINT DF_mon_DC_by    DEFAULT ORIGINAL_LOGIN(),
        CONSTRAINT CK_mon_DC_Retention CHECK (retention_days IS NULL OR retention_days BETWEEN 1 AND 3650)
    );

    /* One-time migration of the rev 5.0 flags from mon.DatabasePolicy. */
    INSERT mon.DatabaseCheck(database_name, monitored, full_backup, diff_backup, log_backup, checkdb, notes)
    SELECT p.database_name, p.is_monitored, p.require_full, p.require_diff,
           CASE WHEN EXISTS (SELECT 1 FROM sys.databases AS d
                             WHERE d.name = p.database_name AND d.recovery_model_desc <> N'FULL')
                THEN 1 ELSE p.require_log END,   /* SIMPLE today: keep ON so a later switch to FULL is watched */
           p.require_checkdb, LEFT(p.notes, 400)
    FROM mon.DatabasePolicy AS p;
    COMMIT;
END;
GO

IF COL_LENGTH(N'mon.DatabaseCheck', N'storage_retention_days') IS NULL
    ALTER TABLE mon.DatabaseCheck ADD storage_retention_days int NULL;   /* declared file lifecycle on storage (days) [5.2] */
GO

IF OBJECT_ID(N'mon.ServerCheck', N'U') IS NULL
BEGIN
    CREATE TABLE mon.ServerCheck
    (
        check_code    varchar(20)   NOT NULL CONSTRAINT PK_mon_ServerCheck PRIMARY KEY,
        display_name  nvarchar(60)  NOT NULL,
        is_enabled    bit           NOT NULL CONSTRAINT DF_mon_SC_en  DEFAULT (1),
        notes         nvarchar(400) NULL,
        modified_utc  datetime2(0)  NOT NULL CONSTRAINT DF_mon_SC_mod DEFAULT SYSUTCDATETIME(),
        modified_by   sysname       NOT NULL CONSTRAINT DF_mon_SC_by  DEFAULT ORIGINAL_LOGIN()
    );
END;
GO

INSERT mon.ServerCheck(check_code, display_name)
SELECT c.check_code, c.display_name
FROM mon.CheckCatalog AS c
WHERE c.scope = 'SERVER'
  AND NOT EXISTS (SELECT 1 FROM mon.ServerCheck AS s WHERE s.check_code = c.check_code);

UPDATE s SET s.display_name = c.display_name
FROM mon.ServerCheck AS s JOIN mon.CheckCatalog AS c ON c.check_code = s.check_code
WHERE s.display_name <> c.display_name;
GO

IF OBJECT_ID(N'mon.CheckChangeLog', N'U') IS NULL
BEGIN
    CREATE TABLE mon.CheckChangeLog
    (
        change_log_id  bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_mon_CheckChangeLog PRIMARY KEY,
        changed_utc    datetime2(0)   NOT NULL CONSTRAINT DF_mon_CCL_utc DEFAULT SYSUTCDATETIME(),
        changed_by     sysname        NOT NULL CONSTRAINT DF_mon_CCL_by  DEFAULT ORIGINAL_LOGIN(),
        host_name      nvarchar(128)  NULL     CONSTRAINT DF_mon_CCL_host DEFAULT HOST_NAME(),
        object_name    varchar(40)    NOT NULL,     /* DatabaseCheck | ServerCheck | Setting | DatabasePolicy */
        item_name      nvarchar(128)  NOT NULL,     /* database name, check code or setting name */
        property_name  nvarchar(128)  NOT NULL,
        old_value      nvarchar(4000) NULL,
        new_value      nvarchar(4000) NULL
    );
    CREATE INDEX IX_mon_CheckChangeLog_Time ON mon.CheckChangeLog(changed_utc DESC);
END;
GO

IF OBJECT_ID(N'mon.BackupInventoryDaily', N'U') IS NULL
BEGIN
    CREATE TABLE mon.BackupInventoryDaily
    (
        snapshot_date     date           NOT NULL,
        database_name     sysname        NOT NULL,
        backup_type       varchar(4)     NOT NULL,     /* FULL | DIFF | LOG */
        status            varchar(10)    NOT NULL,     /* OK | GAPS | SHORT | NONE | OFF | N/A */
        source_name       varchar(20)    NULL,
        backup_count      int            NOT NULL,
        oldest_utc        datetime2(0)   NULL,
        newest_utc        datetime2(0)   NULL,
        retention_days    decimal(9,1)   NULL,
        target_days       int            NULL,
        gaps              int            NULL,
        avg_interval_min  int            NULL,
        avg_bytes         bigint         NULL,
        total_bytes       bigint         NULL,
        captured_utc      datetime2(0)   NOT NULL CONSTRAINT DF_mon_BID_c DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_mon_BackupInventoryDaily PRIMARY KEY (snapshot_date, database_name, backup_type)
    );
END;
GO

/* ---------- Audit triggers: every checkbox / setting change is logged ---------- */

CREATE OR ALTER TRIGGER mon.trg_DatabaseCheck_Audit
ON mon.DatabaseCheck
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF TRIGGER_NESTLEVEL(@@PROCID) > 1 RETURN;

    INSERT mon.CheckChangeLog(object_name, item_name, property_name, old_value, new_value)
    SELECT 'DatabaseCheck', i.database_name, v.col, v.old_v, v.new_v
    FROM inserted AS i
    JOIN deleted AS d ON d.database_name = i.database_name
    CROSS APPLY (VALUES
        (N'monitored',            CONVERT(nvarchar(20), d.monitored),            CONVERT(nvarchar(20), i.monitored)),
        (N'full_backup',          CONVERT(nvarchar(20), d.full_backup),          CONVERT(nvarchar(20), i.full_backup)),
        (N'diff_backup',          CONVERT(nvarchar(20), d.diff_backup),          CONVERT(nvarchar(20), i.diff_backup)),
        (N'log_backup',           CONVERT(nvarchar(20), d.log_backup),           CONVERT(nvarchar(20), i.log_backup)),
        (N'backup_retention',     CONVERT(nvarchar(20), d.backup_retention),     CONVERT(nvarchar(20), i.backup_retention)),
        (N'retention_days',       CONVERT(nvarchar(20), d.retention_days),       CONVERT(nvarchar(20), i.retention_days)),
        (N'storage_retention_days', CONVERT(nvarchar(20), d.storage_retention_days), CONVERT(nvarchar(20), i.storage_retention_days)),
        (N'checkdb',              CONVERT(nvarchar(20), d.checkdb),              CONVERT(nvarchar(20), i.checkdb)),
        (N'log_used',             CONVERT(nvarchar(20), d.log_used),             CONVERT(nvarchar(20), i.log_used)),
        (N'vlf_count',            CONVERT(nvarchar(20), d.vlf_count),            CONVERT(nvarchar(20), i.vlf_count)),
        (N'file_near_max',        CONVERT(nvarchar(20), d.file_near_max),        CONVERT(nvarchar(20), i.file_near_max)),
        (N'config_drift',         CONVERT(nvarchar(20), d.config_drift),         CONVERT(nvarchar(20), i.config_drift)),
        (N'config_best_practice', CONVERT(nvarchar(20), d.config_best_practice), CONVERT(nvarchar(20), i.config_best_practice)),
        (N'query_store',          CONVERT(nvarchar(20), d.query_store),          CONVERT(nvarchar(20), i.query_store)),
        (N'blocking',             CONVERT(nvarchar(20), d.blocking),             CONVERT(nvarchar(20), i.blocking)),
        (N'long_queries',         CONVERT(nvarchar(20), d.long_queries),         CONVERT(nvarchar(20), i.long_queries)),
        (N'open_trans',           CONVERT(nvarchar(20), d.open_trans),           CONVERT(nvarchar(20), i.open_trans)),
        (N'deadlocks',            CONVERT(nvarchar(20), d.deadlocks),            CONVERT(nvarchar(20), i.deadlocks)),
        (N'io_latency',           CONVERT(nvarchar(20), d.io_latency),           CONVERT(nvarchar(20), i.io_latency)),
        (N'notes',                CONVERT(nvarchar(400), d.notes),               CONVERT(nvarchar(400), i.notes))
    ) AS v(col, old_v, new_v)
    WHERE ISNULL(v.old_v, N'~') <> ISNULL(v.new_v, N'~');

    UPDATE t SET modified_utc = SYSUTCDATETIME(), modified_by = ORIGINAL_LOGIN()
    FROM mon.DatabaseCheck AS t JOIN inserted AS i ON i.database_name = t.database_name;
END;
GO

CREATE OR ALTER TRIGGER mon.trg_ServerCheck_Audit
ON mon.ServerCheck
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF TRIGGER_NESTLEVEL(@@PROCID) > 1 RETURN;

    INSERT mon.CheckChangeLog(object_name, item_name, property_name, old_value, new_value)
    SELECT 'ServerCheck', i.check_code, v.col, v.old_v, v.new_v
    FROM inserted AS i
    JOIN deleted AS d ON d.check_code = i.check_code
    CROSS APPLY (VALUES
        (N'is_enabled', CONVERT(nvarchar(20), d.is_enabled), CONVERT(nvarchar(20), i.is_enabled)),
        (N'notes',      CONVERT(nvarchar(400), d.notes),     CONVERT(nvarchar(400), i.notes))
    ) AS v(col, old_v, new_v)
    WHERE ISNULL(v.old_v, N'~') <> ISNULL(v.new_v, N'~');

    UPDATE t SET modified_utc = SYSUTCDATETIME(), modified_by = ORIGINAL_LOGIN()
    FROM mon.ServerCheck AS t JOIN inserted AS i ON i.check_code = t.check_code;
END;
GO

CREATE OR ALTER TRIGGER mon.trg_Setting_Audit
ON mon.Setting
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT mon.CheckChangeLog(object_name, item_name, property_name, old_value, new_value)
    SELECT 'Setting', i.setting_name, N'setting_value', d.setting_value, i.setting_value
    FROM inserted AS i
    JOIN deleted AS d ON d.setting_name = i.setting_name
    WHERE d.setting_value <> i.setting_value;
END;
GO

CREATE OR ALTER TRIGGER mon.trg_DatabasePolicy_Audit
ON mon.DatabasePolicy
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT mon.CheckChangeLog(object_name, item_name, property_name, old_value, new_value)
    SELECT 'DatabasePolicy', i.database_name, v.col, v.old_v, v.new_v
    FROM inserted AS i
    JOIN deleted AS d ON d.database_name = i.database_name
    CROSS APPLY (VALUES
        (N'full_max_age_minutes', CONVERT(nvarchar(20), d.full_max_age_minutes), CONVERT(nvarchar(20), i.full_max_age_minutes)),
        (N'diff_max_age_minutes', CONVERT(nvarchar(20), d.diff_max_age_minutes), CONVERT(nvarchar(20), i.diff_max_age_minutes)),
        (N'log_max_age_minutes',  CONVERT(nvarchar(20), d.log_max_age_minutes),  CONVERT(nvarchar(20), i.log_max_age_minutes)),
        (N'checkdb_max_age_days', CONVERT(nvarchar(20), d.checkdb_max_age_days), CONVERT(nvarchar(20), i.checkdb_max_age_days))
    ) AS v(col, old_v, new_v)
    WHERE ISNULL(v.old_v, N'~') <> ISNULL(v.new_v, N'~');
END;
GO

/* Flat (unpivoted) view of the matrix: one row per database and check. */
CREATE OR ALTER VIEW mon.vw_DatabaseCheckFlat
AS
SELECT c.database_name, c.monitored, v.check_code, v.is_enabled
FROM mon.DatabaseCheck AS c
CROSS APPLY (VALUES
    ('FULL', c.full_backup), ('DIFF', c.diff_backup), ('LOG', c.log_backup), ('RETENTION', c.backup_retention),
    ('CHECKDB', c.checkdb), ('LOGUSED', c.log_used), ('VLF', c.vlf_count), ('FILEMAX', c.file_near_max),
    ('DRIFT', c.config_drift), ('CONFIG', c.config_best_practice), ('QSTORE', c.query_store),
    ('BLOCKING', c.blocking), ('LONGQ', c.long_queries), ('OPENTRAN', c.open_trans),
    ('DEADLOCK', c.deadlocks), ('IOLAT', c.io_latency)
) AS v(check_code, is_enabled);
GO

/* Is the check that owns this issue key enabled for this database / instance? */
CREATE OR ALTER FUNCTION mon.fn_IsCheckEnabled(@issue_key nvarchar(400), @database_name sysname)
RETURNS bit
AS
BEGIN
    DECLARE @code varchar(20), @scope varchar(10);

    SELECT TOP (1) @code = c.check_code, @scope = c.scope
    FROM mon.CheckCatalog AS c
    WHERE c.key_pattern IS NOT NULL AND @issue_key LIKE c.key_pattern
    ORDER BY LEN(c.key_pattern) DESC;

    IF @code IS NULL RETURN 1;                        /* self-health etc.: never switchable */

    /* An unmonitored database produces nothing at all - database AND server-level issues about it. */
    IF @database_name IS NOT NULL
       AND EXISTS (SELECT 1 FROM mon.DatabaseCheck AS d WHERE d.database_name = @database_name AND d.monitored = 0)
        RETURN 0;

    IF @scope = 'SERVER'
        RETURN ISNULL((SELECT s.is_enabled FROM mon.ServerCheck AS s WHERE s.check_code = @code), 1);

    RETURN ISNULL((SELECT f.is_enabled FROM mon.vw_DatabaseCheckFlat AS f
                   WHERE f.database_name = @database_name AND f.check_code = @code), 1);
END;
GO

/* =============================================================================
   SECTION 3c  -  OLA HALLENGREN COMMANDLOG + BACKUP FILE / STORAGE TRACKING  [rev 5.2]
   ============================================================================= */

INSERT mon.Setting(setting_name, setting_value, value_type, category, description)
SELECT v.n, v.v, v.t, v.c, v.d
FROM (VALUES
    ('ola_commandlog_database', N'', 'text', 'ola',
     N'Database that holds Ola Hallengren dbo.CommandLog. Empty = auto-discover (every online database + master, re-checked hourly).'),
    ('job_failure_max_age_days', N'7', 'int', 'jobs',
     N'A job whose LAST run failed stays an open issue (and is listed in the digest) until it succeeds or the failure is older than N days - also for unscheduled / manually started jobs.'),
    ('checkdb_crit_factor', N'4', 'int', 'backup',
     N'CHECKDB issue becomes CRITICAL when the last clean CHECKDB is older than checkdb_max_age_days x this factor (WARNING before that).'),
    ('ola_initial_load_days', N'35', 'int', 'ola',
     N'How many days of CommandLog history are imported on the first run.'),
    ('backup_storage_retention_days', N'', 'text', 'backup',
     N'DECLARED lifecycle of backup files on storage (S3 lifecycle rule / Ola @CleanupTime in days). Empty = not declared. Per-DB override: mon.DatabaseCheck.storage_retention_days. Used to estimate how many files are still on storage.')
) AS v(n, v, t, c, d)
WHERE NOT EXISTS (SELECT 1 FROM mon.Setting AS s WHERE s.setting_name = v.n);
GO

IF COL_LENGTH(N'mon.TlogBackup', N'last_seen_utc') IS NULL
    ALTER TABLE mon.TlogBackup ADD last_seen_utc datetime2(0) NULL;       /* last time RDS still listed the file */
GO
IF COL_LENGTH(N'mon.BackupInventoryDaily', N'files_total') IS NULL
    ALTER TABLE mon.BackupInventoryDaily ADD files_total int NULL, files_24h int NULL, files_on_storage int NULL,
                                             storage_days int NULL, storage_basis varchar(20) NULL;
GO
IF COL_LENGTH(N'mon.DatabaseStatus', N'checkdb_source') IS NULL
    ALTER TABLE mon.DatabaseStatus ADD checkdb_source varchar(20) NULL;   /* DBPROPERTY | DBINFO */
GO

MERGE mon.CheckCatalog AS t
USING (VALUES ('OLA_LOG', 'SERVER', CONVERT(sysname, NULL), N'OLAFAIL:%', N'Ola CommandLog errors', 245,
               N'Failed commands in Ola Hallengren dbo.CommandLog (backup, DBCC CHECKDB, index/statistics maintenance, cleanup).',
               N'ola_commandlog_database')) AS s(check_code, scope, column_name, key_pattern, display_name, sort_order, description, threshold_info)
ON t.check_code = s.check_code
WHEN MATCHED THEN UPDATE SET scope = s.scope, key_pattern = s.key_pattern, display_name = s.display_name,
     sort_order = s.sort_order, description = s.description, threshold_info = s.threshold_info
WHEN NOT MATCHED THEN INSERT (check_code, scope, column_name, key_pattern, display_name, description, threshold_info, sort_order)
     VALUES (s.check_code, s.scope, s.column_name, s.key_pattern, s.display_name, s.description, s.threshold_info, s.sort_order);

INSERT mon.ServerCheck(check_code, display_name)
SELECT c.check_code, c.display_name FROM mon.CheckCatalog AS c
WHERE c.scope = 'SERVER' AND NOT EXISTS (SELECT 1 FROM mon.ServerCheck AS s WHERE s.check_code = c.check_code);
GO

IF OBJECT_ID(N'mon.OlaSource', N'U') IS NULL
BEGIN
    CREATE TABLE mon.OlaSource
    (
        database_name   sysname       NOT NULL CONSTRAINT PK_mon_OlaSource PRIMARY KEY,
        last_id         bigint        NOT NULL CONSTRAINT DF_mon_OlaSrc_Id DEFAULT (0),
        discovered_utc  datetime2(0)  NOT NULL CONSTRAINT DF_mon_OlaSrc_D  DEFAULT SYSUTCDATETIME(),
        last_read_utc   datetime2(0)  NULL,
        is_active       bit           NOT NULL CONSTRAINT DF_mon_OlaSrc_A  DEFAULT (1)
    );
END;
GO

IF OBJECT_ID(N'mon.OlaCommand', N'U') IS NULL
BEGIN
    CREATE TABLE mon.OlaCommand
    (
        source_db        sysname        NOT NULL,
        ola_id           bigint         NOT NULL,
        database_name    sysname        NULL,
        command_type     nvarchar(60)   NOT NULL,
        object_name      nvarchar(300)  NULL,
        index_name       sysname        NULL,
        statistics_name  sysname        NULL,
        command          nvarchar(4000) NULL,
        backup_type      varchar(4)     NULL,      /* FULL | DIFF | LOG for BACKUP_* commands */
        backup_file      nvarchar(1000) NULL,      /* first target file / URL */
        file_count       int            NULL,      /* number of DISK= / URL= targets */
        start_utc        datetime2(0)   NOT NULL,
        end_utc          datetime2(0)   NULL,
        duration_s       int            NULL,
        error_number     int            NULL,
        error_message    nvarchar(2000) NULL,
        collected_utc    datetime2(0)   NOT NULL CONSTRAINT DF_mon_OlaCmd_C DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_mon_OlaCommand PRIMARY KEY (source_db, ola_id)
    );
    CREATE INDEX IX_mon_OlaCommand_Type ON mon.OlaCommand(command_type, start_utc DESC) INCLUDE (database_name, error_number, end_utc);
    CREATE INDEX IX_mon_OlaCommand_Db   ON mon.OlaCommand(database_name, command_type, end_utc DESC) INCLUDE (error_number);
END;
GO
