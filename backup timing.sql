/* ============================================================
   SETUP — same header on every instance
   ============================================================ */
DECLARE @Since datetime2(0) = DATEADD(DAY, -7, SYSDATETIME());   /* migration window */
DECLARE @DBs TABLE (DatabaseName sysname PRIMARY KEY);
INSERT @DBs VALUES (N'BDBAudit'), (N'BDBPayrollLive');


/* ============================================================
   A. BACKUPS from CommandLog  (run on the PRIMARY / backup source)
   ============================================================ */

/* A1. Detail, one row per backup command */
SELECT cl.DatabaseName,
       backup_kind = CASE WHEN cl.CommandType = 'BACKUP_LOG' THEN 'LOG'
                          WHEN cl.Command LIKE '%DIFFERENTIAL%' THEN 'DIFF'
                          WHEN cl.CommandType = 'BACKUP_DATABASE' THEN 'FULL'
                          ELSE cl.CommandType END,
       cl.StartTime, cl.EndTime,
       seconds = DATEDIFF(SECOND, cl.StartTime, cl.EndTime),
       cl.ErrorNumber,
       file_count = (LEN(cl.Command) - LEN(REPLACE(cl.Command, 'DISK = ', ''))) / 7,
       cl.Command
FROM   dbo.CommandLog cl
JOIN   @DBs d ON d.DatabaseName = cl.DatabaseName
WHERE  cl.CommandType IN ('BACKUP_DATABASE','BACKUP_LOG')
  AND  cl.StartTime >= @Since
ORDER BY cl.DatabaseName, cl.StartTime;

/* A2. Sums per DB per kind + per-DB total + grand total (ROLLUP) */
SELECT DatabaseName  = ISNULL(cl.DatabaseName, '** ALL DBs **'),
       backup_kind   = ISNULL(k.backup_kind, '** TOTAL **'),
       commands      = COUNT(*),
       total_seconds = SUM(DATEDIFF(SECOND, cl.StartTime, cl.EndTime)),
       total_hhmmss  = CONVERT(varchar(12), DATEADD(SECOND, SUM(DATEDIFF(SECOND, cl.StartTime, cl.EndTime)), 0), 108),
       avg_seconds   = AVG(DATEDIFF(SECOND, cl.StartTime, cl.EndTime)),
       max_seconds   = MAX(DATEDIFF(SECOND, cl.StartTime, cl.EndTime)),
       first_start   = MIN(cl.StartTime),
       last_end      = MAX(cl.EndTime),
       wallclock_sec = DATEDIFF(SECOND, MIN(cl.StartTime), MAX(cl.EndTime)),   /* includes idle gaps */
       errors        = SUM(CASE WHEN cl.ErrorNumber <> 0 THEN 1 ELSE 0 END)
FROM   dbo.CommandLog cl
JOIN   @DBs d ON d.DatabaseName = cl.DatabaseName
CROSS APPLY (SELECT CASE WHEN cl.CommandType = 'BACKUP_LOG' THEN 'LOG'
                         WHEN cl.Command LIKE '%DIFFERENTIAL%' THEN 'DIFF'
                         ELSE 'FULL' END) k(backup_kind)
WHERE  cl.CommandType IN ('BACKUP_DATABASE','BACKUP_LOG')
  AND  cl.StartTime >= @Since
GROUP BY ROLLUP (cl.DatabaseName, k.backup_kind)
ORDER BY GROUPING(cl.DatabaseName), cl.DatabaseName, GROUPING(k.backup_kind),
         CASE k.backup_kind WHEN 'FULL' THEN 1 WHEN 'DIFF' THEN 2 ELSE 3 END;

/* ============================================================
   C. SYSTEM-TABLE CROSS-CHECK
   msdb.dbo.backupset has true start/finish per backup (run on PRIMARY).
   msdb.dbo.restorehistory has only the finish time (run on SECONDARY),
   so restore seconds there = gap to the previous restore of the same DB —
   an upper bound; the errorlog "successfully processed ... in N seconds"
   line is the exact figure and is included as a third column set.
   ============================================================ */

/* C1. PRIMARY: backupset vs CommandLog, side by side */
;WITH bs AS (
    SELECT bs.database_name AS DatabaseName,
           kind = CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' END,
           n = COUNT(*),
           sec = SUM(DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date)),
           mb  = SUM(bs.backup_size) / 1048576.0,
           cmb = SUM(bs.compressed_backup_size) / 1048576.0
    FROM   msdb.dbo.backupset bs
    JOIN   @DBs d ON d.DatabaseName = bs.database_name
    WHERE  bs.backup_start_date >= @Since AND bs.is_copy_only = 0
    GROUP BY bs.database_name, bs.type
), cl AS (
    SELECT cl.DatabaseName,
           kind = CASE WHEN cl.CommandType = 'BACKUP_LOG' THEN 'LOG'
                       WHEN cl.Command LIKE '%DIFFERENTIAL%' THEN 'DIFF' ELSE 'FULL' END,
           n = COUNT(*),
           sec = SUM(DATEDIFF(SECOND, cl.StartTime, cl.EndTime))
    FROM   dbo.CommandLog cl
    JOIN   @DBs d ON d.DatabaseName = cl.DatabaseName
    WHERE  cl.CommandType IN ('BACKUP_DATABASE','BACKUP_LOG') AND cl.StartTime >= @Since
    GROUP BY cl.DatabaseName,
             CASE WHEN cl.CommandType = 'BACKUP_LOG' THEN 'LOG'
                  WHEN cl.Command LIKE '%DIFFERENTIAL%' THEN 'DIFF' ELSE 'FULL' END
)
SELECT DatabaseName = COALESCE(bs.DatabaseName, cl.DatabaseName),
       kind         = COALESCE(bs.kind, cl.kind),
       msdb_count = bs.n,  msdb_seconds = bs.sec,
       cl_count   = cl.n,  cl_seconds   = cl.sec,
       delta_sec  = cl.sec - bs.sec,          /* CommandLog includes CHECKSUM/verify/xp_delete overhead → normally a few sec higher */
       backup_mb  = CAST(bs.mb  AS decimal(12,1)),
       compr_mb   = CAST(bs.cmb AS decimal(12,1)),
       mb_per_sec = CAST(bs.mb / NULLIF(bs.sec,0) AS decimal(12,1))
FROM   bs FULL OUTER JOIN cl ON cl.DatabaseName = bs.DatabaseName AND cl.kind = bs.kind
ORDER BY 1, CASE COALESCE(bs.kind, cl.kind) WHEN 'FULL' THEN 1 WHEN 'DIFF' THEN 2 ELSE 3 END;


/* ============================================================
   B. RESTORES from CommandLog  (run on the SECONDARY)
   Only populated if RESTORE ran via dbo.CommandExecute. CommandType is
   whatever you passed; the LIKE below catches the usual naming.
   ============================================================ */

/* B1. Detail */
SELECT cl.DatabaseName,
       restore_kind = CASE WHEN cl.Command LIKE 'RESTORE LOG%'      THEN 'LOG'
                           WHEN cl.Command LIKE 'RESTORE DATABASE%' AND cl.Command LIKE '%_bridge%' THEN 'LOG'
                           WHEN cl.Command LIKE 'RESTORE DATABASE%' AND cl.Command LIKE '%DIFF%' THEN 'DIFF'
                           WHEN cl.Command LIKE 'RESTORE DATABASE%' THEN 'FULL'
                           ELSE cl.CommandType END,
       cl.StartTime, cl.EndTime,
       seconds = DATEDIFF(SECOND, cl.StartTime, cl.EndTime),
       cl.ErrorNumber, cl.ErrorMessage, cl.Command
FROM   dbo.CommandLog cl
JOIN   @DBs d ON d.DatabaseName = cl.DatabaseName
WHERE  (cl.CommandType LIKE 'RESTORE%' OR cl.Command LIKE 'RESTORE %')
  AND  cl.CommandType <> 'RESTORE_VERIFYONLY'
  AND  cl.StartTime >= @Since
ORDER BY cl.DatabaseName, cl.StartTime;

/* B2. Sums per DB per kind + totals */
SELECT DatabaseName  = ISNULL(cl.DatabaseName, '** ALL DBs **'),
       restore_kind  = ISNULL(k.restore_kind, '** TOTAL **'),
       commands      = COUNT(*),
       total_seconds = SUM(DATEDIFF(SECOND, cl.StartTime, cl.EndTime)),
       total_hhmmss  = CONVERT(varchar(12), DATEADD(SECOND, SUM(DATEDIFF(SECOND, cl.StartTime, cl.EndTime)), 0), 108),
       first_start   = MIN(cl.StartTime),
       last_end      = MAX(cl.EndTime),
       wallclock_sec = DATEDIFF(SECOND, MIN(cl.StartTime), MAX(cl.EndTime)),
       errors        = SUM(CASE WHEN cl.ErrorNumber <> 0 THEN 1 ELSE 0 END)
FROM   dbo.CommandLog cl
JOIN   @DBs d ON d.DatabaseName = cl.DatabaseName
CROSS APPLY (SELECT CASE WHEN cl.Command LIKE 'RESTORE LOG%' THEN 'LOG'
                         WHEN cl.Command LIKE '%DIFF%'       THEN 'DIFF'
                         ELSE 'FULL' END) k(restore_kind)
WHERE  (cl.CommandType LIKE 'RESTORE%' OR cl.Command LIKE 'RESTORE %')
  AND  cl.CommandType <> 'RESTORE_VERIFYONLY'
  AND  cl.StartTime >= @Since
GROUP BY ROLLUP (cl.DatabaseName, k.restore_kind)
ORDER BY GROUPING(cl.DatabaseName), cl.DatabaseName, GROUPING(k.restore_kind),
         CASE k.restore_kind WHEN 'FULL' THEN 1 WHEN 'DIFF' THEN 2 ELSE 3 END;


/* C2. SECONDARY: restorehistory (+ errorlog exact seconds) vs CommandLog */
DECLARE @log TABLE (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));
DECLARE @i int = 0;
WHILE @i <= 6
BEGIN INSERT @log EXEC xp_readerrorlog @i, 1, N'successfully processed', N'RESTORE'; SET @i += 1; END;

;WITH rh AS (
    SELECT rh.destination_database_name AS DatabaseName,
           kind = CASE rh.restore_type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' END,
           rh.restore_date,
           gap_sec = DATEDIFF(SECOND,
                     LAG(rh.restore_date) OVER (PARTITION BY rh.destination_database_name ORDER BY rh.restore_date),
                     rh.restore_date)
    FROM   msdb.dbo.restorehistory rh
    JOIN   @DBs d ON d.DatabaseName = rh.destination_database_name
    WHERE  rh.restore_date >= @Since
), rh_agg AS (
    SELECT DatabaseName, kind, n = COUNT(*), gap_sec = SUM(gap_sec),
           first_done = MIN(restore_date), last_done = MAX(restore_date)
    FROM rh GROUP BY DatabaseName, kind
), el AS (
    SELECT DatabaseName = d.DatabaseName,
           kind = CASE WHEN l.[Text] LIKE 'RESTORE LOG%' THEN 'LOG' ELSE 'FULL/DIFF' END,
           sec  = TRY_CAST(SUBSTRING(l.[Text], CHARINDEX(' in ', l.[Text]) + 4,
                   CHARINDEX(' seconds', l.[Text]) - CHARINDEX(' in ', l.[Text]) - 4) AS decimal(12,3))
    FROM   @log l
    JOIN   @DBs d ON l.[Text] LIKE '%' + d.DatabaseName + '%'
    WHERE  l.LogDate >= @Since
), el_agg AS (
    SELECT DatabaseName, kind, n = COUNT(*), sec = SUM(sec) FROM el GROUP BY DatabaseName, kind
), cl AS (
    SELECT cl.DatabaseName,
           kind = CASE WHEN cl.Command LIKE 'RESTORE LOG%' THEN 'LOG'
                       WHEN cl.Command LIKE '%DIFF%' THEN 'DIFF' ELSE 'FULL' END,
           n = COUNT(*), sec = SUM(DATEDIFF(SECOND, cl.StartTime, cl.EndTime))
    FROM   dbo.CommandLog cl
    JOIN   @DBs d ON d.DatabaseName = cl.DatabaseName
    WHERE  (cl.CommandType LIKE 'RESTORE%' OR cl.Command LIKE 'RESTORE %')
      AND  cl.CommandType <> 'RESTORE_VERIFYONLY' AND cl.StartTime >= @Since
    GROUP BY cl.DatabaseName,
             CASE WHEN cl.Command LIKE 'RESTORE LOG%' THEN 'LOG'
                  WHEN cl.Command LIKE '%DIFF%' THEN 'DIFF' ELSE 'FULL' END
)
SELECT DatabaseName = COALESCE(rh.DatabaseName, cl.DatabaseName),
       kind         = COALESCE(rh.kind, cl.kind),
       msdb_count       = rh.n,
       msdb_gap_seconds = rh.gap_sec,           /* upper bound (includes idle between files) */
       errorlog_seconds = el.sec,               /* exact; FULL+DIFF are merged in the errorlog text */
       cl_count         = cl.n,
       cl_seconds       = cl.sec,
       rh.first_done, rh.last_done,
       wallclock_sec    = DATEDIFF(SECOND, rh.first_done, rh.last_done)
FROM   rh_agg rh
FULL OUTER JOIN cl ON cl.DatabaseName = rh.DatabaseName AND cl.kind = rh.kind
LEFT  JOIN el_agg el ON el.DatabaseName = COALESCE(rh.DatabaseName, cl.DatabaseName)
                    AND el.kind = CASE COALESCE(rh.kind, cl.kind) WHEN 'LOG' THEN 'LOG' ELSE 'FULL/DIFF' END
ORDER BY 1, CASE COALESCE(rh.kind, cl.kind) WHEN 'FULL' THEN 1 WHEN 'DIFF' THEN 2 ELSE 3 END;

/* C3. Grand total restore wall-clock per DB and for both, from msdb (independent of CommandLog) */
SELECT DatabaseName = ISNULL(destination_database_name, '** BOTH **'),
       files = COUNT(*),
       first_restore_done = MIN(restore_date),
       last_restore_done  = MAX(restore_date),
       total_minutes      = DATEDIFF(MINUTE, MIN(restore_date), MAX(restore_date))
FROM   msdb.dbo.restorehistory rh
JOIN   @DBs d ON d.DatabaseName = rh.destination_database_name
WHERE  rh.restore_date >= @Since
GROUP BY ROLLUP (destination_database_name)
ORDER BY GROUPING(destination_database_name), 1;
