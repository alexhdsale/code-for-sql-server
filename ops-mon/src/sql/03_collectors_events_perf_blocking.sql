
/* ---------------------------------------------------------------------------
   Events: deadlocks (system_health ring buffer), high-signal error-log entries,
   failed logins (aggregated per hour/login/client/reason).
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectEvents
    @ReadErrorLog bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();

    /* ---- Deadlocks ---- */
    BEGIN TRY
        DECLARE @rb xml;
        SELECT @rb = TRY_CAST(t.target_data AS xml)
        FROM sys.dm_xe_session_targets AS t
        JOIN sys.dm_xe_sessions AS s ON s.address = t.event_session_address
        WHERE s.name = N'system_health' AND t.target_name = N'ring_buffer';

        ;WITH D AS
        (
            SELECT TRY_CONVERT(datetime2(3), n.value('@timestamp', 'nvarchar(50)')) AS event_utc,
                   n.query('(data/value/deadlock)[1]') AS dx
            FROM @rb.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS x(n)
        ), S AS
        (
            SELECT D.event_utc, D.dx,
                   HASHBYTES('SHA2_256', CONVERT(varbinary(max), CONVERT(nvarchar(max), D.dx))) AS h,
                   D.dx.value('(/deadlock/victim-list/victimProcess/@id)[1]', 'nvarchar(100)') AS victim_id,
                   D.dx.value('count(/deadlock/process-list/process)', 'int') AS pc
            FROM D
            WHERE D.event_utc IS NOT NULL AND D.dx.exist('/deadlock') = 1
        )
        INSERT mon.Deadlock(deadlock_hash, event_utc, database_name, process_count, victim_login, victim_host,
                            victim_app, victim_sql, survivor_sql, objects, deadlock_xml)
        SELECT S.h, S.event_utc,
               COALESCE(NULLIF(v.p.value('@currentdbname', 'nvarchar(128)'), N''),
                        DB_NAME(v.p.value('@currentdb', 'int'))),
               S.pc,
               v.p.value('@loginname', 'nvarchar(128)'),
               v.p.value('@hostname', 'nvarchar(128)'),
               v.p.value('@clientapp', 'nvarchar(256)'),
               LEFT(LTRIM(v.p.value('(inputbuf)[1]', 'nvarchar(max)')), 2000),
               LEFT(LTRIM(S.dx.value('(/deadlock/process-list/process[@id != sql:column("S.victim_id")]/inputbuf)[1]', 'nvarchar(max)')), 2000),
               LEFT(o.objects, 1000),
               S.dx
        FROM S
        OUTER APPLY S.dx.nodes('(/deadlock/process-list/process[@id = sql:column("S.victim_id")])[1]') AS v(p)
        OUTER APPLY
        (
            SELECT STUFF((
                SELECT DISTINCT N', ' + r.value('@objectname', 'nvarchar(256)')
                FROM S.dx.nodes('/deadlock/resource-list/*') AS rr(r)
                WHERE r.value('@objectname', 'nvarchar(256)') IS NOT NULL
                FOR XML PATH(''), TYPE).value('(./text())[1]', 'nvarchar(max)'), 1, 2, N'') AS objects
        ) AS o
        WHERE NOT EXISTS (SELECT 1 FROM mon.Deadlock AS x WHERE x.deadlock_hash = S.h);

        EXEC mon.usp_SetComponentStatus 'DEADLOCKS', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en1 int = ERROR_NUMBER(), @em1 nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'DEADLOCKS', 0, @started, @en1, @em1;
    END CATCH;

    /* ---- Error log + failed logins ---- */
    IF @ReadErrorLog = 1
    BEGIN
        SET @started = SYSUTCDATETIME();
        BEGIN TRY
            DECLARE @wm datetime2(3) =
                ISNULL((SELECT watermark_utc FROM mon.ComponentStatus WHERE component_name = 'ERRORLOG'),
                       DATEADD(DAY, -1, SYSUTCDATETIME()));
            DECLARE @is_rds bit = 1;

            CREATE TABLE #EL
            (
                row_id int IDENTITY(1,1) PRIMARY KEY, log_idx tinyint NULL,
                LogDate datetime, ProcessInfo nvarchar(100) COLLATE DATABASE_DEFAULT, [Text] nvarchar(max) COLLATE DATABASE_DEFAULT
            );

            BEGIN TRY
                INSERT #EL(LogDate, ProcessInfo, [Text]) EXEC rdsadmin.dbo.rds_read_error_log @index = 0, @type = 1;
            END TRY
            BEGIN CATCH
                SET @is_rds = 0;   /* not RDS: fall back to the standard reader */
                INSERT #EL(LogDate, ProcessInfo, [Text]) EXEC sys.xp_readerrorlog 0, 1;
            END CATCH;
            UPDATE #EL SET log_idx = 0 WHERE log_idx IS NULL;

            /* Previous log only when the current one starts after our watermark (restart / recycle). */
            IF mon.fn_ServerToUtc((SELECT MIN(LogDate) FROM #EL)) > @wm
            BEGIN
                BEGIN TRY
                    IF @is_rds = 1
                        INSERT #EL(LogDate, ProcessInfo, [Text]) EXEC rdsadmin.dbo.rds_read_error_log @index = 1, @type = 1;
                    ELSE
                        INSERT #EL(LogDate, ProcessInfo, [Text]) EXEC sys.xp_readerrorlog 1, 1;
                    UPDATE #EL SET log_idx = 1 WHERE log_idx IS NULL;
                END TRY
                BEGIN CATCH
                    /* previous log may not exist on a new instance */
                END CATCH;
            END;

            ;WITH R AS
            (
                SELECT e.row_id, mon.fn_ServerToUtc(e.LogDate) AS log_utc, e.ProcessInfo, e.[Text],
                       LEAD(e.[Text]) OVER (PARTITION BY e.log_idx ORDER BY e.row_id) AS next_text,
                       LAG(e.[Text])  OVER (PARTITION BY e.log_idx ORDER BY e.row_id) AS prev_text
                FROM #EL AS e
            ), C AS
            (
                SELECT R.*,
                       CASE WHEN R.[Text] LIKE N'Error: %, Severity: %'
                            THEN TRY_CONVERT(int, SUBSTRING(R.[Text], 8, CHARINDEX(N',', R.[Text]) - 8)) END AS err_no,
                       CASE WHEN R.[Text] LIKE N'Error: %, Severity: %'
                            THEN TRY_CONVERT(int, REPLACE(SUBSTRING(R.[Text], CHARINDEX(N'Severity: ', R.[Text]) + 10, 2), N',', N'')) END AS sev
                FROM R
                WHERE R.log_utc > DATEADD(MINUTE, -10, @wm)
            ), K AS
            (
                SELECT C.*,
                       CASE
                           WHEN C.err_no IN (17806, 17830, 17832, 17835, 17836, 18456) THEN NULL   /* scanners / logins */
                           WHEN C.err_no IN (605, 701, 802, 823, 824, 825, 829, 832, 845, 1105, 3041, 3313, 3314,
                                             3414, 3624, 9001, 9002, 17883, 17884, 17888, 18204, 18210) THEN 'CRITICAL'
                           WHEN C.err_no IN (833, 1204, 5144, 5145, 17890) THEN 'WARNING'
                           WHEN C.sev >= 20 THEN 'CRITICAL'
                           WHEN C.err_no IS NULL AND ISNULL(C.prev_text, N'') NOT LIKE N'Error: %, Severity: %'
                                AND (C.[Text] LIKE N'%SQL Server Assertion%' OR C.[Text] LIKE N'%Stack Signature%'
                                     OR C.[Text] LIKE N'%non-yielding%' OR C.[Text] LIKE N'%deadlocked schedulers%'
                                     OR C.[Text] LIKE N'%stack dump%') THEN 'CRITICAL'
                           WHEN C.err_no IS NULL AND ISNULL(C.prev_text, N'') NOT LIKE N'Error: %, Severity: %'
                                AND (C.[Text] LIKE N'%I/O requests taking longer than 15 seconds%'
                                     OR C.[Text] LIKE N'FlushCache: cleaned up%'
                                     OR C.[Text] LIKE N'%significant part of sql server process memory has been paged out%') THEN 'WARNING'
                       END AS sev_level
                FROM C
            ), H AS
            (
                SELECT K.log_utc, K.ProcessInfo, K.err_no, K.sev_level,
                       LEFT(CASE WHEN K.err_no IS NOT NULL
                                 THEN CONCAT(K.next_text, N'  [', K.[Text], N']')
                                 ELSE K.[Text] END, 4000) AS message
                FROM K
                WHERE K.sev_level IS NOT NULL
            )
            INSERT mon.ErrorLogEvent(event_hash, log_utc, process_info, error_number, severity, message)
            SELECT DISTINCT
                   HASHBYTES('SHA2_256', CONVERT(varbinary(max), CONCAT(CONVERT(nvarchar(23), H.log_utc, 121), N'|',
                             H.ProcessInfo, N'|', H.message))),
                   H.log_utc, H.ProcessInfo, H.err_no, H.sev_level, H.message
            FROM H
            WHERE NOT EXISTS (SELECT 1 FROM mon.ErrorLogEvent AS x
                              WHERE x.event_hash = HASHBYTES('SHA2_256', CONVERT(varbinary(max),
                                    CONCAT(CONVERT(nvarchar(23), H.log_utc, 121), N'|', H.ProcessInfo, N'|', H.message))));

            /* Failed logins newer than the watermark, aggregated per hour. */
            ;WITH L AS
            (
                SELECT mon.fn_ServerToUtc(e.LogDate) AS log_utc, e.[Text] AS t
                FROM #EL AS e
                WHERE e.[Text] LIKE N'Login failed for user %'
                  AND mon.fn_ServerToUtc(e.LogDate) > @wm
            ), P AS
            (
                SELECT L.log_utc, L.t,
                       CHARINDEX(N'''', L.t) AS q1,
                       CHARINDEX(N'''', L.t, CHARINDEX(N'''', L.t) + 1) AS q2,
                       CHARINDEX(N'Reason: ', L.t) AS r1,
                       CHARINDEX(N'[CLIENT: ', L.t) AS c1
                FROM L
            ), V AS
            (
                SELECT CONVERT(datetime2(0), DATEADD(HOUR, DATEDIFF(HOUR, CONVERT(datetime2(0), '19000101'), P.log_utc),
                               CONVERT(datetime2(0), '19000101'))) AS hour_utc,
                       LEFT(CASE WHEN P.q1 > 0 AND P.q2 > P.q1 THEN SUBSTRING(P.t, P.q1 + 1, P.q2 - P.q1 - 1) ELSE N'?' END, 128) AS login_name,
                       LEFT(CASE WHEN P.c1 > 0 THEN REPLACE(SUBSTRING(P.t, P.c1 + 9, 64), N']', N'') ELSE N'?' END, 64) AS client_address,
                       LEFT(CASE WHEN P.r1 > 0
                                 THEN LTRIM(RTRIM(SUBSTRING(P.t, P.r1 + 8,
                                          CASE WHEN P.c1 > P.r1 THEN P.c1 - P.r1 - 8 ELSE 400 END)))
                                 ELSE N'(no reason)' END, 200) AS reason
                FROM P
            )
            MERGE mon.LoginFailure AS t
            USING (SELECT hour_utc, login_name, LTRIM(RTRIM(client_address)) AS client_address, reason, COUNT(*) AS n
                   FROM V GROUP BY hour_utc, login_name, LTRIM(RTRIM(client_address)), reason) AS s
            ON t.hour_utc = s.hour_utc AND t.login_name = s.login_name
               AND t.client_address = s.client_address AND t.reason = s.reason
            WHEN MATCHED THEN UPDATE SET failures = t.failures + s.n
            WHEN NOT MATCHED THEN INSERT (hour_utc, login_name, client_address, reason, failures)
                                  VALUES (s.hour_utc, s.login_name, s.client_address, s.reason, s.n);

            DECLARE @new_wm datetime2(3) = mon.fn_ServerToUtc((SELECT MAX(LogDate) FROM #EL));
            EXEC mon.usp_SetComponentStatus 'ERRORLOG', 1, @started;
            UPDATE mon.ComponentStatus
               SET watermark_utc = CASE WHEN @new_wm > ISNULL(watermark_utc, '19000101') THEN @new_wm ELSE watermark_utc END
             WHERE component_name = 'ERRORLOG';
        END TRY
        BEGIN CATCH
            DECLARE @en2 int = ERROR_NUMBER(), @em2 nvarchar(2000) = ERROR_MESSAGE();
            EXEC mon.usp_SetComponentStatus 'ERRORLOG', 0, @started, @en2, @em2;
        END CATCH;
    END;
END;
GO

/* ---------------------------------------------------------------------------
   Performance & capacity: CPU (ring buffer), counters, tempdb, storage, and
   hourly cumulative snapshots of wait stats and file I/O stats.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CollectPerf
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @started datetime2(3) = SYSUTCDATETIME(),
            @now datetime2(0) = SYSUTCDATETIME(),
            @errors nvarchar(2000) = NULL;

    /* CPU history: one record per minute kept by SQLOS for ~4 hours. */
    BEGIN TRY
        DECLARE @ms_ticks bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);
        DECLARE @last_cpu datetime2(0) = ISNULL((SELECT MAX(sample_utc) FROM mon.CpuSample), '19000101');

        ;WITH RB AS
        (
            SELECT r.[timestamp] AS ts, CONVERT(xml, r.record) AS rec
            FROM sys.dm_os_ring_buffers AS r
            WHERE r.ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
              AND r.record LIKE N'%<SystemHealth>%'
              AND @ms_ticks - r.[timestamp] < 2000000000
        ), V AS
        (
            SELECT CONVERT(datetime2(0), DATEADD(MILLISECOND, -CONVERT(int, @ms_ticks - RB.ts), SYSUTCDATETIME())) AS sample_utc,
                   RB.rec.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS sql_cpu,
                   RB.rec.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS idle
            FROM RB
        )
        INSERT mon.CpuSample(sample_utc, sql_cpu_pct, other_cpu_pct)
        SELECT V.sample_utc, V.sql_cpu,
               CASE WHEN 100 - ISNULL(V.idle, 100) - V.sql_cpu < 0 THEN 0 ELSE 100 - ISNULL(V.idle, 100) - V.sql_cpu END
        FROM V
        WHERE V.sample_utc > DATEADD(SECOND, 30, @last_cpu)
          AND V.sql_cpu BETWEEN 0 AND 100;
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' CPU: ', ERROR_MESSAGE());
    END CATCH;

    /* Counters + tempdb. */
    BEGIN TRY
        INSERT mon.PerfSample(sample_utc, ple_sec, memory_grants_pending, batch_requests_total, user_connections,
                              target_mem_mb, total_mem_mb, tempdb_size_mb, tempdb_used_mb, tempdb_version_store_mb,
                              tempdb_user_obj_mb, tempdb_internal_obj_mb, sqlserver_start_utc)
        SELECT @now, pc.ple, pc.grants, pc.batch, pc.conns, pc.target_kb / 1024, pc.total_kb / 1024,
               tf.size_mb, tf.used_mb, tf.vs_mb, tf.uo_mb, tf.io_mb,
               (SELECT mon.fn_ServerToUtc(sqlserver_start_time) FROM sys.dm_os_sys_info)
        FROM
        (
            SELECT MAX(CASE WHEN RTRIM(counter_name) = N'Page life expectancy' AND object_name LIKE N'%Buffer Manager%' THEN cntr_value END) AS ple,
                   MAX(CASE WHEN RTRIM(counter_name) = N'Memory Grants Pending' THEN cntr_value END) AS grants,
                   MAX(CASE WHEN RTRIM(counter_name) = N'Batch Requests/sec' THEN cntr_value END) AS batch,
                   MAX(CASE WHEN RTRIM(counter_name) = N'User Connections' THEN cntr_value END) AS conns,
                   MAX(CASE WHEN RTRIM(counter_name) = N'Target Server Memory (KB)' THEN cntr_value END) AS target_kb,
                   MAX(CASE WHEN RTRIM(counter_name) = N'Total Server Memory (KB)' THEN cntr_value END) AS total_kb
            FROM sys.dm_os_performance_counters
            WHERE counter_name IN (N'Page life expectancy', N'Memory Grants Pending', N'Batch Requests/sec',
                                   N'User Connections', N'Target Server Memory (KB)', N'Total Server Memory (KB)')
        ) AS pc
        CROSS JOIN
        (
            SELECT SUM(total_page_count) / 128.0 AS size_mb,
                   SUM(total_page_count - unallocated_extent_page_count) / 128.0 AS used_mb,
                   SUM(version_store_reserved_page_count) / 128.0 AS vs_mb,
                   SUM(user_object_reserved_page_count) / 128.0 AS uo_mb,
                   SUM(internal_object_reserved_page_count) / 128.0 AS io_mb
            FROM tempdb.sys.dm_db_file_space_usage
        ) AS tf
        WHERE NOT EXISTS (SELECT 1 FROM mon.PerfSample WHERE sample_utc = @now);
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' Counters: ', ERROR_MESSAGE());
    END CATCH;

    /* SQL-visible storage (CloudWatch FreeStorageSpace stays authoritative on RDS). */
    BEGIN TRY
        INSERT mon.StorageSample(sample_utc, volume_mount_point, total_bytes, available_bytes)
        SELECT @now, COALESCE(NULLIF(v.volume_mount_point, N''), N'(RDS volume)'),
               MAX(v.total_bytes), MIN(v.available_bytes)
        FROM sys.master_files AS f
        CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.file_id) AS v
        GROUP BY COALESCE(NULLIF(v.volume_mount_point, N''), N'(RDS volume)')
        HAVING NOT EXISTS (SELECT 1 FROM mon.StorageSample AS x WHERE x.sample_utc = @now);
    END TRY
    BEGIN CATCH
        SET @errors = CONCAT(@errors, N' Storage: ', ERROR_MESSAGE());
    END CATCH;

    /* Hourly cumulative snapshots; deltas are computed at report / evaluation time. */
    IF NOT EXISTS (SELECT 1 FROM mon.WaitStatsSnapshot WHERE snapshot_utc > DATEADD(MINUTE, -55, @now))
    BEGIN
        BEGIN TRY
            INSERT mon.WaitStatsSnapshot(snapshot_utc, wait_type, waiting_tasks, wait_ms, signal_ms)
            SELECT @now, w.wait_type, w.waiting_tasks_count, w.wait_time_ms, w.signal_wait_time_ms
            FROM sys.dm_os_wait_stats AS w
            WHERE w.waiting_tasks_count > 0
              AND w.wait_type NOT LIKE N'SLEEP[_]%'
              AND w.wait_type NOT LIKE N'PREEMPTIVE[_]HADR%'
              AND NOT EXISTS (SELECT 1 FROM mon.WaitTypeIgnore AS i WHERE i.wait_type = w.wait_type);

            INSERT mon.FileStatsSnapshot(snapshot_utc, database_id, file_id, database_name, logical_name, type_desc,
                                         num_reads, io_stall_read_ms, num_writes, io_stall_write_ms, bytes_read, bytes_written)
            SELECT @now, vfs.database_id, vfs.file_id, DB_NAME(vfs.database_id), mf.name, mf.type_desc,
                   vfs.num_of_reads, vfs.io_stall_read_ms, vfs.num_of_writes, vfs.io_stall_write_ms,
                   vfs.num_of_bytes_read, vfs.num_of_bytes_written
            FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
            LEFT JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id;
        END TRY
        BEGIN CATCH
            SET @errors = CONCAT(@errors, N' Hourly snapshots: ', ERROR_MESSAGE());
        END CATCH;
    END;

    IF @errors IS NULL
        EXEC mon.usp_SetComponentStatus 'PERF', 1, @started;
    ELSE
        EXEC mon.usp_SetComponentStatus 'PERF', 0, @started, 50002, @errors;
END;
GO

/* ---------------------------------------------------------------------------
   BLOCKING SAMPLER  (called every sample_interval_seconds by the engine)
   Builds blocking trees from one consistent DMV snapshot, keeps one episode
   per head-blocker connection (session_id + login_time), and stores the
   chain details of every sample for forensics.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mon.usp_CaptureBlocking
    @OpenEpisodes int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET LOCK_TIMEOUT 2000;
    SET DEADLOCK_PRIORITY LOW;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE @started datetime2(3) = SYSUTCDATETIME(),
            @now datetime2(0) = SYSUTCDATETIME(),
            @min_ms bigint = ISNULL(mon.fn_SettingInt('blocking_capture_min_seconds'), 15) * 1000,
            @max_rows int = ISNULL(mon.fn_SettingInt('blocking_max_sample_rows'), 200);

    BEGIN TRY
        /* Fast path: nothing blocked -> just close open episodes. */
        /* dm_os_waiting_tasks (not dm_exec_requests) so blocked PARALLEL queries are seen too:
           their request row shows CXPACKET/CXCONSUMER while a worker task waits on the lock. */
        IF NOT EXISTS (SELECT 1 FROM sys.dm_os_waiting_tasks
                       WHERE blocking_session_id > 0 AND blocking_session_id <> session_id)
        BEGIN
            UPDATE mon.BlockingEpisode SET is_open = 0, ended_utc = last_seen_utc WHERE is_open = 1;
            SET @OpenEpisodes = 0;
            EXEC mon.usp_SetComponentStatus 'BLOCKING', 1, @started;
            RETURN;
        END;

        /* One consistent snapshot of all requests, one row per session (MARS can return several). */
        ;WITH R AS
        (
            SELECT r.session_id, r.blocking_session_id, r.wait_type, CONVERT(bigint, r.wait_time) AS wait_ms,
                   r.wait_resource, r.database_id, r.command, r.status, r.start_time,
                   r.sql_handle, r.statement_start_offset, r.statement_end_offset,
                   ROW_NUMBER() OVER (PARTITION BY r.session_id
                                      ORDER BY CASE WHEN r.blocking_session_id > 0 THEN 0 ELSE 1 END, r.wait_time DESC) AS rn
            FROM sys.dm_exec_requests AS r
            WHERE r.session_id <> @@SPID
        )
        SELECT session_id, blocking_session_id, wait_type, wait_ms, wait_resource, database_id, command, status,
               start_time, sql_handle, statement_start_offset, statement_end_offset
        INTO #Req
        FROM R WHERE rn = 1;

        /* Blocked edges from waiting tasks: one blocker per session (longest wait), self-waits excluded. */
        ;WITH W AS
        (
            SELECT wt.session_id, wt.blocking_session_id, CONVERT(bigint, wt.wait_duration_ms) AS wait_ms,
                   ROW_NUMBER() OVER (PARTITION BY wt.session_id ORDER BY wt.wait_duration_ms DESC) AS rn
            FROM sys.dm_os_waiting_tasks AS wt
            WHERE wt.session_id > 0
              AND wt.blocking_session_id > 0
              AND wt.blocking_session_id <> wt.session_id
              AND wt.session_id <> @@SPID
        )
        SELECT session_id, blocking_session_id, wait_ms
        INTO #Edge
        FROM W WHERE rn = 1;

        ;WITH Heads AS
        (
            SELECT DISTINCT e.blocking_session_id AS head
            FROM #Edge AS e
            WHERE NOT EXISTS (SELECT 1 FROM #Edge AS x WHERE x.session_id = e.blocking_session_id)
        ), Tree AS
        (
            SELECT h.head, e.session_id, e.blocking_session_id, e.wait_ms, CONVERT(int, 1) AS lvl
            FROM Heads AS h JOIN #Edge AS e ON e.blocking_session_id = h.head
            UNION ALL
            SELECT t.head, e.session_id, e.blocking_session_id, e.wait_ms, t.lvl + 1
            FROM Tree AS t JOIN #Edge AS e ON e.blocking_session_id = t.session_id
            WHERE t.lvl < 50
        )
        SELECT head, session_id, blocking_session_id, wait_ms, lvl
        INTO #Tree
        FROM Tree
        OPTION (MAXRECURSION 60);

        /* Qualifying heads: something in the tree has waited at least the capture threshold. */
        SELECT t.head,
               COUNT(*) AS blocked_count,
               MAX(t.wait_ms) AS max_wait_ms,
               /* start = longest DIRECT wait on this head (a new head must not inherit an older chain's age) */
               DATEADD(SECOND, -CONVERT(int, ISNULL(MAX(CASE WHEN t.lvl = 1 THEN t.wait_ms END), MAX(t.wait_ms)) / 1000), @now) AS blocked_since_utc
        INTO #Head
        FROM #Tree AS t
        GROUP BY t.head
        HAVING MAX(t.wait_ms) >= @min_ms;

        /* Head details (session may be sleeping with an open transaction: no request row). */
        SELECT h.head, h.blocked_count, h.max_wait_ms, h.blocked_since_utc,
               s.login_time, s.status AS head_status, s.login_name, s.host_name, s.program_name,
               DB_NAME(s.database_id) AS head_database, s.open_transaction_count,
               hr.command AS head_command, hr.wait_type AS head_wait_type,
               LEFT(COALESCE(
                    CASE WHEN hr.sql_handle IS NOT NULL THEN
                        SUBSTRING(ht.text, hr.statement_start_offset / 2 + 1,
                                  (CASE hr.statement_end_offset WHEN -1 THEN DATALENGTH(ht.text)
                                        ELSE hr.statement_end_offset END - hr.statement_start_offset) / 2 + 1) END,
                    ct.text), 4000) AS head_sql,
               LEFT(ib.event_info, 4000) AS head_input_buffer,
               tr.tran_begin_utc,
               w.top_wait_type, w.top_wait_resource, w.blocked_sql, w.dbs
        INTO #HeadInfo
        FROM #Head AS h
        JOIN sys.dm_exec_sessions AS s ON s.session_id = h.head
        LEFT JOIN #Req AS hr ON hr.session_id = h.head
        OUTER APPLY sys.dm_exec_sql_text(hr.sql_handle) AS ht
        LEFT JOIN sys.dm_exec_connections AS c ON c.session_id = h.head AND c.parent_connection_id IS NULL
        OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS ct
        OUTER APPLY sys.dm_exec_input_buffer(h.head, NULL) AS ib
        OUTER APPLY
        (
            SELECT mon.fn_ServerToUtc(MIN(at.transaction_begin_time)) AS tran_begin_utc
            FROM sys.dm_tran_session_transactions AS st
            JOIN sys.dm_tran_active_transactions AS at ON at.transaction_id = st.transaction_id
            WHERE st.session_id = h.head
        ) AS tr
        OUTER APPLY
        (
            SELECT TOP (1) q.wait_type AS top_wait_type, q.wait_resource AS top_wait_resource,
                   LEFT(SUBSTRING(qt.text, q.statement_start_offset / 2 + 1,
                                  (CASE q.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text)
                                        ELSE q.statement_end_offset END - q.statement_start_offset) / 2 + 1), 2000) AS blocked_sql,
                   STUFF((SELECT DISTINCT N', ' + DB_NAME(q2.database_id)
                          FROM #Tree AS t2 JOIN #Req AS q2 ON q2.session_id = t2.session_id
                          WHERE t2.head = h.head
                          FOR XML PATH(''), TYPE).value('(./text())[1]', 'nvarchar(1000)'), 1, 2, N'') AS dbs
            FROM #Tree AS t
            JOIN #Req AS q ON q.session_id = t.session_id
            OUTER APPLY sys.dm_exec_sql_text(q.sql_handle) AS qt
            WHERE t.head = h.head
            ORDER BY t.wait_ms DESC
        ) AS w;

        /* Episode upsert: same head connection = same episode. */
        UPDATE e
           SET e.last_seen_utc        = @now,
               e.sample_count         = e.sample_count + 1,
               e.blocked_since_utc    = CASE WHEN i.blocked_since_utc < e.blocked_since_utc THEN i.blocked_since_utc ELSE e.blocked_since_utc END,
               e.max_blocked_count    = CASE WHEN i.blocked_count > e.max_blocked_count THEN i.blocked_count ELSE e.max_blocked_count END,
               e.max_wait_ms          = CASE WHEN i.max_wait_ms > e.max_wait_ms THEN i.max_wait_ms ELSE e.max_wait_ms END,
               e.head_status          = i.head_status,
               e.head_database        = i.head_database,
               e.head_open_tran_count = i.open_transaction_count,
               e.head_tran_begin_utc  = COALESCE(i.tran_begin_utc, e.head_tran_begin_utc),
               e.head_command         = i.head_command,
               e.head_wait_type       = i.head_wait_type,
               e.head_sql             = COALESCE(i.head_sql, e.head_sql),
               e.head_input_buffer    = COALESCE(i.head_input_buffer, e.head_input_buffer),
               e.top_wait_type        = COALESCE(i.top_wait_type, e.top_wait_type),
               e.top_wait_resource    = COALESCE(i.top_wait_resource, e.top_wait_resource),
               e.blocked_sql_sample   = COALESCE(e.blocked_sql_sample, i.blocked_sql),
               e.databases_affected   = COALESCE(i.dbs, e.databases_affected)
        FROM mon.BlockingEpisode AS e
        JOIN #HeadInfo AS i ON i.head = e.head_session_id AND i.login_time = e.head_login_time
        WHERE e.is_open = 1;

        INSERT mon.BlockingEpisode
            (head_session_id, head_login_time, blocked_since_utc, first_sample_utc, last_seen_utc, is_open,
             sample_count, max_blocked_count, max_wait_ms, head_status, head_login, head_host, head_program,
             head_database, head_open_tran_count, head_tran_begin_utc, head_command, head_wait_type, head_sql,
             head_input_buffer, top_wait_type, top_wait_resource, blocked_sql_sample, databases_affected)
        SELECT i.head, i.login_time, i.blocked_since_utc, @now, @now, 1,
               1, i.blocked_count, i.max_wait_ms, i.head_status, i.login_name, i.host_name, i.program_name,
               i.head_database, i.open_transaction_count, i.tran_begin_utc, i.head_command, i.head_wait_type, i.head_sql,
               i.head_input_buffer, i.top_wait_type, i.top_wait_resource, i.blocked_sql, i.dbs
        FROM #HeadInfo AS i
        WHERE i.login_time IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM mon.BlockingEpisode AS e
                          WHERE e.is_open = 1 AND e.head_session_id = i.head AND e.head_login_time = i.login_time);

        /* Close episodes whose head is no longer blocking anybody long enough. */
        UPDATE e SET e.is_open = 0, e.ended_utc = e.last_seen_utc
        FROM mon.BlockingEpisode AS e
        WHERE e.is_open = 1
          AND NOT EXISTS (SELECT 1 FROM #HeadInfo AS i
                          WHERE i.head = e.head_session_id AND i.login_time = e.head_login_time);

        /* Chain details for forensics. */
        INSERT mon.BlockingSample(sample_utc, episode_id, session_id, blocking_session_id, chain_level, wait_type,
                                  wait_ms, wait_resource, database_name, login_name, host_name, program_name, statement_text)
        SELECT TOP (@max_rows) @now, e.episode_id, t.session_id, t.blocking_session_id, t.lvl, q.wait_type, t.wait_ms,
               q.wait_resource, DB_NAME(q.database_id), s.login_name, s.host_name, s.program_name,
               LEFT(SUBSTRING(qt.text, q.statement_start_offset / 2 + 1,
                              (CASE q.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text)
                                    ELSE q.statement_end_offset END - q.statement_start_offset) / 2 + 1), 2000)
        FROM #Tree AS t
        JOIN #HeadInfo AS i ON i.head = t.head
        JOIN mon.BlockingEpisode AS e ON e.is_open = 1 AND e.head_session_id = i.head AND e.head_login_time = i.login_time
        JOIN #Req AS q ON q.session_id = t.session_id
        LEFT JOIN sys.dm_exec_sessions AS s ON s.session_id = t.session_id
        OUTER APPLY sys.dm_exec_sql_text(q.sql_handle) AS qt
        WHERE NOT EXISTS (SELECT 1 FROM mon.BlockingSample AS b WHERE b.sample_utc = @now AND b.session_id = t.session_id)
        ORDER BY t.wait_ms DESC;

        SET @OpenEpisodes = (SELECT COUNT(*) FROM mon.BlockingEpisode WHERE is_open = 1);
        EXEC mon.usp_SetComponentStatus 'BLOCKING', 1, @started;
    END TRY
    BEGIN CATCH
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(2000) = ERROR_MESSAGE();
        EXEC mon.usp_SetComponentStatus 'BLOCKING', 0, @started, @en, @em;
        SET @OpenEpisodes = NULL;
    END CATCH;
END;
GO
