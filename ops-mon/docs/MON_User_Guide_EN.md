# OPS.mon — SQL Server Monitoring & Change-Only Alerting (rev 5.6)

**Server:** MS-APP-STG (Amazon RDS for SQL Server) · **Database:** OPS · **Schema:** mon
**Owner:** DBA team · **Runs alongside:** legacy OPS.monitor rev 4 (untouched)

| File | Purpose |
|---|---|
| `stage_monitoring_mon_v5.4.sql` | Installer / upgrader (idempotent, run the whole file) |
| `MON-CheckEditor.ps1` | Windows GUI to view and switch checks per database / server |
| `MON_Checks_and_Retention.rdl` | SSMS custom report (read-only check matrix + backup retention) |
| `MON_Uninstall.sql` | Complete removal (jobs + schema `mon`), WhatIf by default |

---

## 1. Overview

OPS.mon is a self-contained monitoring framework that lives entirely in the `mon` schema of the OPS database. It collects backup, CHECKDB, blocking, job, performance and configuration data, turns findings into **issues** with a lifecycle, and sends email **only when something changes**.

### 1.1 Architecture

```
MON - Engine  (SQL Agent, starts every minute, one run loops for 55 minutes)
  every 30 s : usp_CaptureBlocking -> BlockingEpisode / BlockingSample
               blocking >= 10 min  -> usp_EvaluateIssues 'BLOCKING' -> usp_SendAlerts
  every 5 min: SyncPolicies -> DatabaseState -> Backups -> Agent -> Events -> Perf -> Ola CommandLog
               -> usp_EvaluateIssues 'ALL' -> usp_SendAlerts (only on change)

MON - Digest & Watchdog  (SQL Agent, hourly at :02)
  retention snapshot -> engine watchdog -> daily digest (08:02 ET) -> history purge (every 6 h)
```

### 1.2 Issue lifecycle

Every check produces **issues** identified by a key (for example `BACKUP:DIFF:MIO_PARTY`).

- State issues: `OPENED -> ESCALATED / DEESCALATED -> RESOLVED` (with a grace period against flapping).
- Event issues (deadlock, job failure, error-log entry): `OPENED -> EXPIRED` silently.
- Issues of a check that is switched off are closed silently (`close_type = DISABLED`).

### 1.3 Email policy

| Email | Sent when | Not sent when |
|---|---|---|
| **Alert** (immediate) | New or escalated CRITICAL; RESOLVED for an issue that was alerted | Nothing opened, escalated or resolved |
| **Daily digest** (08:02 ET) | At least one issue changed since the last digest, **or** someone changed checks/settings | No changes → logged as `DIGEST_SKIPPED` |
| **Heartbeat** (Monday) | Always, even with no changes — proves the monitor is alive | — |

If `sp_send_dbmail` fails, changes stay pending and are re-sent on the next cycle (outbox semantics).

---

## 2. Installation and upgrade

1. Open `stage_monitoring_mon_v5.4.sql` in SSMS as the RDS master login and execute the **whole file** (F5).
   - The script is idempotent: settings, check matrix, mutes, baselines and history are preserved.
   - The same file upgrades any 5.x install. It stops `MON - Engine` first to avoid error 2801 while procedures are replaced; the job restarts on its next minute schedule.
2. Review the result sets printed at the end:
   - `ComponentStatus`: every component should have `consecutive_failures = 0`.
   - `vw_ActiveIssues`: findings at install time (not emailed; they appear in the first digest).
   - `usp_ShowChecks`: the check matrix.
   - `usp_ShowBackupRetention`: the retention grid.
3. Sanity checks on the server:
   ```sql
   SELECT TOP 5 task_type, lifecycle FROM OPS.mon.RdsTask;     -- DIFF = BACKUP_DB_DIFFERENTIAL
   SELECT SYSDATETIMEOFFSET();                                  -- +00:00 (RDS runs in UTC)
   SELECT TOP 1 * FROM msdb.dbo.sysjobactivity;                 -- access works
   ```
4. Preview, then send a test digest:
   ```sql
   EXEC OPS.mon.usp_SendDailyDigest @Force = 1, @PreviewOnly = 1;   -- html_body -> save as .html
   EXEC OPS.mon.usp_SendDailyDigest @Force = 1;
   SELECT TOP 10 * FROM msdb.dbo.rds_fn_sysmail_allitems() ORDER BY send_request_date DESC;
   ```
5. Legacy `OPS - ...` jobs (rev 4) keep running until you disable them (see section 11).

### 2.1 Release safety (rev 5.4)

- **Everything lives in schema `mon`** of the OPS database. The only objects outside OPS are the two SQL Agent jobs `MON - Engine` and `MON - Digest & Watchdog`. Nothing is created in `dbo` or any other schema, so the solution can be adjusted, moved or removed as one unit.
- **Upgrades never drop data**: tables are created only if missing, new columns are added with `IF COL_LENGTH(...) IS NULL`, procedures/views use `CREATE OR ALTER`, settings are inserted only if missing (your values are kept).
- **Release guard** — every run of the installer:
  1. records itself in `mon.ReleaseHistory` (version, who, host, start/finish, result);
  2. **pauses the engine** (`engine_enabled = 0`) and stops the running loop, so a half-installed version never runs;
  3. at the end runs **`mon.usp_SelfTest @Deep = 1`**: required objects, every view binds, every procedure/function/trigger compiles, no broken references, **no object created outside `mon`**, jobs exist/enabled/scheduled, required settings, Database Mail profile, check catalog consistency;
  4. **only if there are no errors** restores `engine_enabled` and marks the release `COMPLETED`. Otherwise the release is `FAILED`, the engine stays paused (the previous alerts keep their state) and the hourly watchdog raises CRITICAL `MON_RELEASE` + `ENGINE_STALE`.
- Check any time:
  ```sql
  EXEC OPS.mon.usp_SelfTest;                                        -- safe while running
  SELECT * FROM OPS.mon.ReleaseHistory ORDER BY release_id DESC;    -- install history
  ```

### 2.2 Uninstall / migrate

- **Uninstall:** open `MON_Uninstall.sql`, run once as is (WhatIf lists every job/object it would drop), then set `@WhatIf = 0` and `@Confirm = 'REMOVE MON'`.
- **Migrate to another server:** run the installer there, then copy the configuration tables: `mon.Setting`, `mon.DatabaseCheck`, `mon.ServerCheck`, `mon.DatabasePolicy`, `mon.IssueMute`, `mon.DatabaseConfigBaseline`, `mon.JobPolicy`. Everything else is collected data and rebuilds itself.

---

## 3. What is checked — the check matrix

Every database has a row in `mon.DatabaseCheck` with one on/off flag per check. Server-wide checks live in `mon.ServerCheck`. Every change is audited in `mon.CheckChangeLog` (who, when, host, old → new).

### 3.1 See everything with one command

```sql
EXEC OPS.mon.usp_ShowChecks;                       -- all databases
EXEC OPS.mon.usp_ShowChecks @Database = N'MIO%';
```

Returns four result sets:

1. **Matrix** — one row per database, one column per check. `✔` = on, blank = off, `-` = database not monitored, `n/a` = not applicable (LOG on SIMPLE recovery).
2. **Server checks** — on/off, description, tuning setting.
3. **Catalog** — every check, its column, its issue-key pattern.
4. **Audit** — last 50 changes.

### 3.2 Option 1 (recommended): MON Check Editor (PowerShell GUI)

Windows only, nothing to install (uses the built-in .NET SqlClient).

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\MON-CheckEditor.ps1 -Server <rds-endpoint>
```

1. Enter login and password (or Windows auth) and click **Connect**. Server, login and auth mode are remembered in `%APPDATA%\MON\CheckEditor.json`; the password is never saved.
2. Tabs:
   - **Databases** — check matrix, retention target, storage retention, notes, **Last good CHECKDB** and its **source**.
   - **Server checks**
   - **Settings / thresholds**
   - **Backup retention** — summary and grid (read-only).
   - **Ola CommandLog (30 days)** — read-only, four grids (see 3.3).
   - **Change log** — audit trail.
3. Cell colours:

| Cell | Meaning |
|---|---|
| 🟢 **ON** (green) | Check is enabled |
| 🔴 **OFF** (red) | Check is disabled |
| ⚪ **n/a** (grey) | Not applicable / not defined: database not monitored, LOG check on non-FULL recovery, database dropped, or no value. Not clickable. |
| Orange frame + `*` | Changed, not applied yet |
| Blue frame | Selected |

4. **Left-click** a cell to toggle ON/OFF. For bulk changes, select cells (Ctrl/Shift) and use **Check selected** / **Uncheck selected** or the Space key. n/a cells are skipped.
5. The **APPLY (N)** button shows the number of pending changes. **APPLY** (or Ctrl+S) shows an "old → new" list and writes everything in **one transaction**. If someone else changed the same row meanwhile, nothing is saved and you are asked to Refresh.
6. After APPLY, open issues of checks you switched **off are closed immediately**; the status bar shows how many. Checks switched **on** are evaluated at the next 5-minute cycle.
7. **Discard changes** reverts edits, **F5** reloads, the filter box filters by database name.
8. Performance: Refresh / APPLY reload only the check tabs and the audit (about a second). **Backup retention** and **Ola CommandLog** load when you open the tab; Backup retention opens from the daily snapshot, and **F5 on that tab** reads live from msdb (slower on large backup history). Load times are shown in the status bar.

### 3.3 Ola CommandLog tab

Four grids:

1. Summary per command type: count, **Corruption found**, **Failed**, **Skipped**, durations.
2. Failures with a coloured **Outcome** column.
3. Last successful CHECKDB / FULL / DIFF / LOG per database.
4. CommandLog sources the monitor reads (`mon.OlaSource`).

A note at the top lists expected command types that were not seen (for example `DBCC_CHECKDB`). The usual reason is that the Ola job runs with the default **`@LogToTable = 'N'`**. See section 8.3.

### 3.4 Option 2: one T-SQL command (good for bulk changes)

```sql
-- one check, one database
EXEC OPS.mon.usp_SetCheck @Database = N'DWH_Stage',   @Check = 'LOG',   @Enabled = 0;
-- one check, all databases
EXEC OPS.mon.usp_SetCheck @Database = N'%',           @Check = 'LONGQ', @Enabled = 0;
-- all checks of a database (except Monitored)
EXEC OPS.mon.usp_SetCheck @Database = N'Archive2019', @Check = 'ALL',   @Enabled = 0;
-- exclude a database completely
EXEC OPS.mon.usp_SetCheck @Database = N'TestRestore', @Check = 'MONITORED', @Enabled = 0, @Notes = N'scratch restore';
-- server-level check
EXEC OPS.mon.usp_SetCheck @Check = 'CPU', @Enabled = 0;
-- retention target in days (0 = back to default)
EXEC OPS.mon.usp_SetCheck @Database = N'MIO_CONFIG', @Check = 'RETENTION', @Enabled = 1, @RetentionDays = 14;
```

`@Check` accepts the code (`LOG`) or the column name (`log_backup`). Full list: `SELECT * FROM OPS.mon.CheckCatalog;`
The procedure prints how many open issues it closed and shows the updated matrix.

### 3.5 Option 3: SSMS Edit Top 200 Rows

Object Explorer → **OPS → Tables → mon.DatabaseCheck** → right-click → **Edit Top 200 Rows**. Bit columns show as True/False. The row is saved when you leave it. The same works for `mon.ServerCheck` (`is_enabled`) and `mon.DatabasePolicy` (SLA minutes).
Changes made this way are applied at the next 5-minute cycle.

### 3.6 Option 4: SSMS custom report (read-only)

Server → **Reports → Custom Reports…** → `MON_Checks_and_Retention.rdl` → **Run**. Shows a coloured matrix, server checks and the retention grid. Refresh: right-click the report → Refresh.

### 3.7 Check reference

| Code | Column | What it checks | Tuned by (default) |
|---|---|---|---|
| MONITORED | monitored | Master switch for the database | — |
| FULL | full_backup | Age of last FULL backup | DatabasePolicy.full_max_age_minutes (1440) |
| DIFF | diff_backup | Age of last DIFF **or** FULL (newest data backup) | DatabasePolicy.diff_max_age_minutes (360) |
| LOG | log_backup | Age of last LOG backup, broken log chain | DatabasePolicy.log_max_age_minutes (30) |
| RETENTION | backup_retention (+ retention_days) | Backup history depth, no backups, gaps, storage policy | backup_retention_target_days (7) |
| CHECKDB | checkdb | Last clean DBCC CHECKDB | checkdb_max_age_days (8), checkdb_crit_factor (4) |
| LOGUSED | log_used | Log fullness + log_reuse_wait reason | log_used_warn/crit_pct (80/90) |
| VLF | vlf_count | VLF count | vlf_warn_count (1000) |
| FILEMAX | file_near_max | File close to MAXSIZE | file_near_max_pct (90) |
| DRIFT | config_drift | Recovery / compat / owner / RCSI… changed vs baseline | usp_AcceptConfigBaseline |
| CONFIG | config_best_practice | AUTO_CLOSE, AUTO_SHRINK, PAGE_VERIFY | — |
| QSTORE | query_store | Query Store forced READ_ONLY | — |
| BLOCKING | blocking | Blocking episode ≥ N minutes | blocking_alert_minutes (10) |
| LONGQ | long_queries | Long-running requests | long_query_warn/crit_minutes (30/120) |
| OPENTRAN | open_trans | Idle / long open transactions | open_tran_warn/crit_minutes (15/60) |
| DEADLOCK | deadlocks | Each deadlock | deadlock_severity (WARNING) |
| IOLAT | io_latency | Read/write latency per file | io_latency_warn_ms (50) |
| *Server:* DB_STATE, AGENT_FAIL, JOB_SLA, JOB_LONG, RDS_TASKS, ERRORLOG, LOGIN_FAIL, DEADLOCK_STORM, CPU, MEMGRANTS, TEMPDB, STORAGE, RESTART, MAIL, OLA_LOG | mon.ServerCheck.is_enabled | see `usp_ShowChecks` set 2 | see "Tuned by" |

> **Tip — daily DIFF schedule.** The DIFF default SLA is 6 hours. If data backups run once a day, raise the SLA to 26 hours instead of switching the check off:
> ```sql
> UPDATE OPS.mon.DatabasePolicy SET diff_max_age_minutes = 1560;
> UPDATE OPS.mon.Setting SET setting_value = N'1560' WHERE setting_name = N'diff_max_age_minutes';
> ```

### 3.8 What happens when a check is switched off or on

- **Off:** open issues of that check close **immediately and silently** (no RESOLVED email) when changed via the Check Editor or `usp_SetCheck`; with direct table edits, at the next cycle at the latest. The digest and alert sender also close them before sending, so a disabled check never appears in an email. The digest lists the change under *Monitoring configuration changes* and the database under *Monitoring coverage*.
- **On:** if the problem exists, the issue re-opens at the next 5-minute cycle and an alert is sent. Event checks (DEADLOCK, ERRORLOG, MAIL) re-open events from the last `event_lookback_hours` (24 h) — expected.
- **New database:** added automatically with all checks ON.
- **Dropped database:** stays in the matrix with a "no longer exists" issue. Switch it off with `@Check = 'MONITORED', @Enabled = 0`.
- Thresholds are **not** in the matrix: they live in `mon.Setting` (global) and `mon.DatabasePolicy` (per-database SLA).

---

## 4. Backups, retention and storage

```sql
EXEC OPS.mon.usp_ShowBackupRetention;                         -- live, all databases + 30-day trend
EXEC OPS.mon.usp_ShowBackupRetention @Database = N'MIO_CONFIG';
EXEC OPS.mon.usp_ShowBackupRetention @Live = 0;               -- fast, from today's snapshot
SELECT * FROM OPS.mon.vw_BackupRetention;                     -- raw data
SELECT * FROM OPS.mon.BackupInventoryDaily ORDER BY snapshot_date DESC;
```

| Column | Meaning |
|---|---|
| Count / Files | Backups and backup files recorded (a 4-way striped backup = 4 files) |
| Files 24h | Files created in the last 24 hours |
| On storage | Files still on storage (exact for RDS LOG, estimated for FULL/DIFF) |
| Oldest / Newest | Oldest and newest recorded backup (local time) |
| Retention days | How far back history goes |
| Target days | `DatabaseCheck.retention_days`, else setting `backup_retention_target_days` (7) |
| Gaps | Intervals inside the target window longer than SLA × 1.25 (FULL, LOG) |
| Source | MSDB / RDS_TASK / RDS_TLOG / OLA — the richest source per database and type, no double counting |

**Statuses:** OK · **SHORT** (history shorter than target; databases younger than target excluded) · **NONE** (no backups of this type) · **GAPS** · **POLICY** (declared storage retention shorter than required retention — files will be deleted too early) · N/A · OFF.
SHORT, NONE, GAPS and POLICY raise a WARNING issue `RETENTION:<type>:<db>`.

### 4.1 Files on storage

- **LOG (RDS automated):** exact. Once a day the monitor re-reads `rds_fn_list_tlog_backup_metadata`; a file RDS still lists counts as on storage.
- **FULL / DIFF (RDS native to S3, Ola to disk/URL):** T-SQL cannot see S3, so the count is **estimated** from the storage retention **you declare**:
  ```sql
  -- all databases (days: S3 lifecycle rule or Ola @CleanupTime)
  UPDATE OPS.mon.Setting SET setting_value = N'35' WHERE setting_name = 'backup_storage_retention_days';
  -- one database
  UPDATE OPS.mon.DatabaseCheck SET storage_retention_days = 14 WHERE database_name = N'MIO_CONFIG';
  ```
  Until declared, the column shows `not declared`.

### 4.2 Limitations

- T-SQL cannot read S3 lifecycle rules: "Oldest" is the oldest **recorded** backup, not proof the file still exists.
- RDS automated log backups are visible for up to 35 days.
- msdb history is trimmed by `sp_delete_backuphistory`; MSDB-based retention can't exceed that window. Align it with the retention target.

### 4.3 Backup alert details

- DIFF alerts show which backup counted: `via FULL/...` or `via DIFF/...`. If you only see `FULL/...`, there are no DIFF backups and the DIFF SLA is effectively checking the FULL schedule.
- `LOG ... CHAIN_BROKEN`: the log chain is broken. Take a FULL (or DIFF) backup to restart it.

---

## 5. DBCC CHECKDB

The last clean CHECKDB is taken from the newest of three sources:

1. `DATABASEPROPERTYEX(db, 'LastGoodCheckDbTime')` — SQL Server's own record (2016 SP2, 2019+).
2. `DBCC DBINFO` → `dbi_dbccLastKnownGood` — fallback; usually not permitted on RDS, errors are handled.
3. **Ola CommandLog** — last `DBCC_CHECKDB` with `ErrorNumber = 0`.

- Older than `checkdb_max_age_days` (8) → **WARNING**; older than 8 × `checkdb_crit_factor` (4) = 32 days → **CRITICAL**.
- Dates older than 300 days are shown with the year (e.g. `2023-09-10`) so a multi-year gap is obvious.
- If the last Ola CHECKDB found corruption, the cell is red with **CORRUPTION FOUND** and a CRITICAL alert is sent.

---

## 6. Ola Hallengren CommandLog

- `dbo.CommandLog` is discovered automatically (every online database + master, hourly) or set explicitly:
  ```sql
  UPDATE OPS.mon.Setting SET setting_value = N'ops' WHERE setting_name = 'ola_commandlog_database';
  ```
- Imported incrementally every 5 minutes with READ UNCOMMITTED; unfinished commands are re-read until they get an EndTime. First load: 35 days (`ola_initial_load_days`).
- An error in CommandLog **does not always mean Ola failed**. Outcomes:
  - **CORRUPTION FOUND** — CHECKDB **completed and found corruption** (errors 25xx, 79xx, 89xx, 823–825). The check worked; the database is damaged. CRITICAL — restore or repair. Not counted as last known good.
  - **SKIPPED** — 1222 (lock timeout) or 1205 (deadlock victim). WARNING; the object is retried next run.
  - **FAILED** — anything else. CRITICAL for BACKUP / DBCC / RESTORE, WARNING otherwise.
- Each creates an `OLAFAIL:...` issue (switch: **OLA_LOG** in `mon.ServerCheck`). A failed Ola job typically produces two alerts: `OLAFAIL` (what failed) and `JOBFAIL` (the Agent job).

```sql
EXEC OPS.mon.usp_ShowOlaLog;                                    -- last 24 h
EXEC OPS.mon.usp_ShowOlaLog @Hours = 720, @Database = N'MIO_REF';
SELECT TOP 100 * FROM OPS.mon.OlaCommand ORDER BY start_utc DESC;
```

> **Important:** Ola's default is `@LogToTable = 'N'`. Every `DatabaseBackup`, `DatabaseIntegrityCheck` and `IndexOptimize` job step must include **`@LogToTable = 'Y'`**, otherwise the run is invisible here. Find steps that don't log:
> ```sql
> SELECT j.name AS job_name, s.step_id, s.step_name
> FROM msdb.dbo.sysjobsteps s
> JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id
> WHERE (s.command LIKE '%DatabaseIntegrityCheck%' OR s.command LIKE '%DatabaseBackup%' OR s.command LIKE '%IndexOptimize%')
>   AND s.command NOT LIKE '%@LogToTable%=%''Y''%';
> ```

---

## 7. Blocking longer than 10 minutes

- Sampled every 30 s from `sys.dm_os_waiting_tasks` (parallel blocked queries are caught too).
- An episode = one head-blocker connection (session_id + login_time).
- At 10 minutes a **CRITICAL alert** is sent with: blocker login / host / program, session status, open-transaction age, head and blocked SQL, wait resource. A sleeping session with an open transaction is flagged **DIAGNOSIS: IDLE inside an open transaction**.
- When it clears, a **RESOLVED** email with the final duration follows within ~30 s.
- Nothing is ever killed automatically.

```sql
SELECT * FROM OPS.mon.vw_BlockingNow;                                            -- live chains
SELECT TOP 20 * FROM OPS.mon.BlockingEpisode ORDER BY last_seen_utc DESC;        -- history
SELECT * FROM OPS.mon.BlockingSample WHERE episode_id = 123 ORDER BY sample_utc;  -- chain detail
```

**Test on a test database:**

1. `UPDATE OPS.mon.Setting SET setting_value = N'2' WHERE setting_name = 'blocking_alert_minutes';`
2. Session A: `BEGIN TRAN; UPDATE t SET c = c WHERE id = 1;` (leave open).
3. Session B: `SELECT * FROM t WHERE id = 1;` (blocks).
4. A CRITICAL alert arrives after ~2.5 minutes.
5. Session A: `ROLLBACK;` → RESOLVED email.
6. Restore: `UPDATE OPS.mon.Setting SET setting_value = N'10' WHERE setting_name = 'blocking_alert_minutes';`

---

## 8. Daily DBA operations

### 8.1 Common commands

| Task | Command |
|---|---|
| What is open now | `SELECT * FROM OPS.mon.vw_ActiveIssues ORDER BY severity, category;` |
| Changes this week | `SELECT * FROM OPS.mon.vw_RecentChanges ORDER BY change_utc DESC;` |
| Mute a known issue | `EXEC OPS.mon.usp_MuteIssue @KeyPattern = N'LONGQ:%', @Hours = 3, @Reason = N'ETL';` |
| Unmute | `EXEC OPS.mon.usp_MuteIssue @KeyPattern = N'LONGQ:%', @Unmute = 1;` |
| Accept a DB config change | `EXEC OPS.mon.usp_AcceptConfigBaseline @DatabaseName = N'MIO_CONFIG';` |
| Close issues of disabled checks now | `EXEC OPS.mon.usp_CloseDisabledIssues;` |
| Monitor self-health | `SELECT * FROM OPS.mon.ComponentStatus; SELECT TOP 5 * FROM OPS.mon.EngineRun ORDER BY 1 DESC;` |
| Email log | `SELECT TOP 50 * FROM OPS.mon.Notification ORDER BY notification_id DESC;` |
| Who changed monitoring | `SELECT TOP 100 * FROM OPS.mon.CheckChangeLog ORDER BY change_log_id DESC;` |
| Preview alert email | `EXEC OPS.mon.usp_SendAlertsCore @PreviewOnly = 1;` |

**Mute vs. switching a check off:** a mute is temporary, matches an issue-key pattern, and the issue stays visible in the digest as MUTED. Switching a check off is permanent until switched back on.

### 8.2 Key settings (`mon.Setting`)

```sql
SELECT * FROM OPS.mon.Setting ORDER BY category, setting_name;                  -- with descriptions
UPDATE OPS.mon.Setting SET setting_value = N'...' WHERE setting_name = '...';   -- audited
```

| Setting | Default | Why change it |
|---|---|---|
| alert_recipients / report_recipients | DBA mailbox | Other recipients |
| alert_min_severity | CRITICAL | `WARNING` to get warnings immediately too |
| reminder_minutes | 0 | e.g. 240: remind about unresolved CRITICALs |
| report_hour_local / heartbeat_weekday | 8 / 1 (Mon) | Digest time; heartbeat day (0 = off) |
| blocking_alert_minutes | 10 | Blocking threshold |
| backup_retention_target_days | 7 | Required backup history depth |
| backup_storage_retention_days | (empty) | Declared S3 lifecycle / Ola cleanup days |
| diff_max_age_minutes | 360 | Default DIFF SLA for new databases (use 1560 for daily backups) |
| checkdb_crit_factor | 4 | CHECKDB becomes CRITICAL after SLA × factor |
| job_failure_max_age_days | 7 | A job whose last run failed stays open up to N days |
| ola_commandlog_database | (auto) | Database holding Ola `dbo.CommandLog` |
| engine_enabled | 1 | 0 = graceful engine stop within 30 s |

### 8.3 Troubleshooting

| Symptom | What to check |
|---|---|
| No email at all | `mon.Notification` → `send_ok`, `error_message`; `rds_fn_sysmail_event_log()`; mail profile |
| "Monitoring engine is not running" alert | `MON - Engine` job history, `mon.EngineRun.end_reason`, `engine_enabled` |
| "Monitoring collector failing" issue | `mon.ComponentStatus.last_error_message` for that component |
| No digest today | Expected if nothing changed: `SELECT * FROM mon.Notification WHERE notification_type = 'DIGEST_SKIPPED'` |
| Disabled check still in an email | Upgrade to 5.3 (closes on APPLY / before send) or run `EXEC OPS.mon.usp_CloseDisabledIssues;` |
| DIFF OVERDUE every evening | SLA 6 h vs daily backups — set `diff_max_age_minutes = 1560` (see 3.7) |
| CHECKDB / backups missing in Ola tab | Ola step without `@LogToTable = 'Y'`, or logging to another database (section 6) |
| Error 2801 in MON - Engine | Procedures replaced while the loop ran; harmless, excluded from alerts. The installer stops the engine first. |
| Job failure not in digest | Failures stay listed while the last run failed (up to `job_failure_max_age_days`), shown as **STILL FAILED** |

### 8.4 How often are emails sent?

```sql
EXEC OPS.mon.usp_ShowEmailStats;            -- last 30 days
EXEC OPS.mon.usp_ShowEmailStats @Days = 7;
```

1. MON emails **per day**: alerts, digests, heartbeats, skipped digests (no change), failures, largest size.
2. Per type over the period: sent, failed, average per day, first/last.
3. Last 100 MON emails: time, type, result, subject, recipients.
4. **All Database Mail on the server per day**, split *MON* vs *others* (legacy OPS.monitor rev 4, Agent job notifications, applications).
5. Top 50 subjects across all senders — who sends the most.

The same data is in the Check Editor tab **Emails (30 days)**. Raw log: `SELECT * FROM OPS.mon.Notification ORDER BY notification_id DESC;`

---

## 9. Reading the emails

- **Alert:** header colour red = CRITICAL, amber = WARNING, green = resolutions only. Sections: New / escalated → Resolved → Still active. Each issue shows its `key:` — use it with `usp_MuteIssue`.
- **Digest** sections, in order: KPI tiles · What changed · Open issues · Databases & backups · Backup files & storage · Backup retention & inventory · Blocking · SQL Agent · Ola Hallengren maintenance · Deadlocks · Error log / Failed logins · Performance · Storage · Monitoring coverage · Configuration changes · Self-health.
- Red cell = action required; amber = review; grey pill = information.
- Sized to stay below Gmail's ~100 KB clipping limit: large sections show exceptions and the first 40 rows only.

---

## 10. Outside SQL Server (recommendations)

- **CloudWatch** remains the source of truth for host CPU, FreeableMemory, FreeStorageSpace, IOPS/EBS latency and Multi-AZ events — create alarms there.
- **S3 lifecycle / AWS Backup** retention is verified on the AWS side.
- **External dead-man switch:** if the whole instance is down, SQL cannot send email. A missing Monday heartbeat is a signal; a CloudWatch alarm on instance status / `DatabaseConnections` is the reliable one.

---

## 11. Migration from rev 4 and uninstall

Once the new emails are confirmed:

```sql
EXEC msdb.dbo.sp_update_job @job_name = N'OPS - Backup and Maintenance Monitor',    @enabled = 0;
EXEC msdb.dbo.sp_update_job @job_name = N'OPS - Daily Backup and Maintenance Report', @enabled = 0;
```

Uninstall rev 5.x:

1. Delete the jobs:
   ```sql
   EXEC msdb.dbo.sp_delete_job @job_name = N'MON - Engine';
   EXEC msdb.dbo.sp_delete_job @job_name = N'MON - Digest & Watchdog';
   ```
2. Drop `mon` objects in OPS: triggers → procedures → views → functions → tables.
3. `DROP SCHEMA mon;`

---

## 12. Release notes

| Rev | Changes |
|---|---|
| 5.0 | New `mon` schema; issue lifecycle; change-only alerts and digest; Monday heartbeat; 30-s blocking sampler with 10-minute alert; long queries, open transactions, job duration anomalies, config drift, performance snapshot |
| 5.1 | Check matrix (`DatabaseCheck` / `ServerCheck`) with audit; backup retention & inventory grid; `usp_SetCheck` / `usp_ShowChecks` / `usp_ShowBackupRetention`; SSMS custom report |
| 5.2 | Backup files made vs on storage, storage-retention policy; CHECKDB from three sources; Ola CommandLog collector with correct outcome interpretation (corruption found ≠ Ola failure); job failures stay open while the last run failed; PowerShell Check Editor |
| 5.6 | Issue alerts (change-only) + scheduled short summary + scheduled full report; issue workflow `usp_AckIssue` / `usp_ResolveIssue`; per-area data retention and `usp_ShowDataRetention`. Details: `MON_Operations_Guide.md` |
| 5.5 | Performance: `vw_BackupRetention` single-pass rewrite (retention report ~36 s → seconds), no per-row UDF on msdb history, bounded msdb scans, new covering/purge indexes (`01c_performance_indexes.sql`) |
| 5.4 | Release guard: `mon.ReleaseHistory`, engine paused during install, `mon.usp_SelfTest` gate (engine resumes only when it passes), watchdog `MON_RELEASE`; email statistics `mon.usp_ShowEmailStats` + Emails tab; `MON_Uninstall.sql` |
| 5.3 | Switching a check off closes its issues immediately (APPLY, `usp_SetCheck`, digest, alerts — `usp_CloseDisabledIssues`); DIFF alerts show FULL/DIFF source; CHECKDB CRITICAL after SLA × `checkdb_crit_factor`; dates older than 300 days show the year; Check Editor with green/red/grey states, click-to-toggle, Last good CHECKDB column and a 30-day Ola tab |
