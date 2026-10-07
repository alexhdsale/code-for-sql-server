# OPS.mon — Operations Guide (rev 5.7)

How to **deploy** the monitor, how its **SQL Agent jobs** work, how long **data** is kept, how the **three kinds of email** are scheduled, and how **issues get resolved**.

| | |
|---|---|
| Server | Amazon RDS for SQL Server (tested on MS-APP-STG, SQL Server 2022) |
| Home | Database `OPS`, schema **`mon`** — nothing is created in any other schema |
| Outside OPS | Two SQL Agent jobs: `MON - Engine`, `MON - Digest & Watchdog` |
| Installer | `install/MON_Install.sql` (always the latest; idempotent) |
| Removal | `install/MON_Uninstall.sql` |

---

## 1. Deployment

### 1.1 Prerequisites

| Requirement | How to check |
|---|---|
| RDS master login (or a login with the same rights) | `SELECT SUSER_SNAME(), IS_SRVROLEMEMBER('processadmin');` |
| SQL Server Agent running | RDS: always on. `SELECT * FROM msdb.dbo.sysjobs;` works |
| Database Mail profile (RDS: enabled through the DB parameter group `database mail xps = 1`) | `EXEC msdb.dbo.sysmail_help_profile_sp;` |
| Database `OPS` (created by the installer if missing) | `SELECT DB_ID('OPS');` |
| Ola Hallengren jobs log to a table (optional) | job steps contain `@LogToTable = 'Y'` |

### 1.2 First installation

1. **Set recipients and the mail profile before the first run** — open `src/sql/01_header_tables.sql` (or the same section near the top of `MON_Install.sql`) and edit the seed values:
   `mail_profile`, `alert_recipients`, `report_recipients`, `server_label`, `display_time_zone`.
   (You can also change them after installation in `OPS.mon.Setting`.)
2. Open **`install/MON_Install.sql`** in SSMS, connect as the RDS master login, **Execute (F5) the whole file**.
3. Read the **Messages** tab. The last lines must say:
   `MON 5.6 installed: self-test passed (n warning(s)). Engine resumed ...`
   If it says **FAILED**, the engine stays paused — see §1.5.
4. Check the release record and the self-test:
   ```sql
   SELECT TOP 5 * FROM OPS.mon.ReleaseHistory ORDER BY release_id DESC;
   EXEC OPS.mon.usp_SelfTest;
   ```
5. Send test emails (all three kinds):
   ```sql
   EXEC OPS.mon.usp_SendSummary;                       -- short summary
   EXEC OPS.mon.usp_SendDailyDigest @Force = 1;        -- full report
   EXEC OPS.mon.usp_SendAlertsCore @PreviewOnly = 1;   -- what an issue alert would contain now
   SELECT TOP 10 * FROM msdb.dbo.rds_fn_sysmail_allitems() ORDER BY send_request_date DESC;
   ```
6. Review what is checked and switch off what you do not need (PowerShell Check Editor or `EXEC OPS.mon.usp_ShowChecks;`).

### 1.3 Upgrade

Run the **new `MON_Install.sql` over the old one**. Nothing is dropped: tables are created only if missing, new columns are added with `COL_LENGTH` guards, code uses `CREATE OR ALTER`, settings are inserted only if missing (your values stay).
The installer pauses the engine, installs, runs the self-test and resumes the engine only if the self-test passes. Every run is recorded in `mon.ReleaseHistory`.

### 1.4 What gets deployed

| Object type | Where | Examples |
|---|---|---|
| Tables | `OPS.mon` | `Setting`, `DatabaseCheck`, `ServerCheck`, `Issue`, `IssueChange`, `Notification`, `TlogBackup`, `RdsTask`, `OlaCommand`, samples… |
| Views | `OPS.mon` | `vw_ActiveIssues`, `vw_BackupHealth`, `vw_BackupRetention`, `vw_RecentChanges` |
| Procedures / functions | `OPS.mon` | `usp_EngineLoop`, `usp_RunHourly`, `usp_SendSummary`, `usp_SendDailyDigest`, `usp_SendAlerts`, `usp_SelfTest`… |
| Agent jobs | `msdb` | `MON - Engine`, `MON - Digest & Watchdog` |

### 1.5 If the self-test fails

```sql
EXEC OPS.mon.usp_SelfTest @Deep = 1;            -- lists every ERROR / WARN with the object and the reason
```
Fix the cause (usually a missing permission or Database Mail profile) and **run the installer again**. Until then the engine stays paused (`engine_enabled = 0`) and the hourly watchdog raises the CRITICAL issue `MON_RELEASE`.

### 1.6 Uninstall / move to another server

- **Uninstall:** run `install/MON_Uninstall.sql` as is (WhatIf — lists what would be dropped), then set `@WhatIf = 0`, `@Confirm = 'REMOVE MON'`.
- **Move:** install on the new server, then copy the configuration tables `mon.Setting`, `mon.DatabaseCheck`, `mon.ServerCheck`, `mon.DatabasePolicy`, `mon.IssueMute`, `mon.DatabaseConfigBaseline`, `mon.JobPolicy`. Everything else is collected data.

---

## 2. SQL Agent jobs

The installer creates both jobs (owner = the login that ran the installer, normally the RDS master login). Re-running the installer updates them in place.

| Job | Schedule | Runs | What it does |
|---|---|---|---|
| **MON - Engine** | every minute (Agent skips a start while the previous run is still active) | `EXEC mon.usp_EngineLoop;` in `OPS` | One execution loops ~55 minutes: **every 30 s** blocking sampler; **every 5 min** collectors (databases, backups, CHECKDB, Agent, error log, performance, Ola CommandLog) → issue evaluation → **issue alert email** (only when something changed) |
| **MON - Digest & Watchdog** | hourly at **:02** | `EXEC mon.usp_RunHourly;` in `OPS` | Daily retention snapshot → engine watchdog (alerts if the engine stopped) → pending alerts → **scheduled summary / full report** → purge (every 6 h) |

### 2.1 Check the jobs

```sql
SELECT j.name, j.enabled, a.start_execution_date, a.stop_execution_date
FROM msdb.dbo.sysjobs AS j
OUTER APPLY (SELECT TOP 1 * FROM msdb.dbo.sysjobactivity AS x WHERE x.job_id = j.job_id ORDER BY x.session_id DESC) AS a
WHERE j.name LIKE N'MON - %';

SELECT TOP 10 * FROM OPS.mon.EngineRun ORDER BY engine_run_id DESC;    -- loop runs, cycles, end reason
SELECT * FROM OPS.mon.ComponentStatus ORDER BY consecutive_failures DESC; -- every collector's health
```

### 2.2 Stop / start

| Action | Command |
|---|---|
| Graceful stop (loop exits within 30 s, job keeps its schedule) | `UPDATE OPS.mon.Setting SET setting_value = N'0' WHERE setting_name = 'engine_enabled';` |
| Start again (next minute) | `UPDATE OPS.mon.Setting SET setting_value = N'1' WHERE setting_name = 'engine_enabled';` |
| Hard stop now | `EXEC msdb.dbo.sp_stop_job @job_name = N'MON - Engine';` |
| Disable completely | `EXEC msdb.dbo.sp_update_job @job_name = N'MON - Engine', @enabled = 0;` (re-running the installer enables it again) |

### 2.3 Tuning intervals (settings, no job change needed)

| Setting | Default | Meaning |
|---|---|---|
| `sample_interval_seconds` | 30 | blocking sampler interval (10–300) |
| `collect_interval_minutes` | 5 | full collection + evaluation cycle |
| `engine_loop_minutes` | 55 | length of one engine job execution |
| `errorlog_interval_minutes` | 15 | how often the SQL error log is read |

Do **not** change the job schedules themselves: the every-minute schedule is the restart mechanism of the loop, and the :02 hourly schedule drives the email schedule.

---

## 3. Data retention (`mon.*` tables)

Purge runs inside the hourly job **every 6 hours** (deletes in batches of 5,000 rows, low deadlock priority). Open issues, configuration tables and current-state tables are never purged.

| Area | Tables | Setting | Default |
|---|---|---|---|
| Everything not listed below | Agent history, deadlocks, error log events, failed logins, blocking episodes, expired mutes | `history_retention_days` | 90 |
| Blocking chain detail (bulky) | `BlockingSample` | `blocking_sample_retention_days` | 30 |
| Performance samples | `PerfSample`, `CpuSample`, `StorageSample`, `WaitStatsSnapshot`, `FileStatsSnapshot` | `retention_perf_days` | = history |
| Backup evidence | `TlogBackup`, `RdsTask`, `OlaCommand`, `BackupInventoryDaily` | `retention_backup_days` | = history |
| Resolved issues + their history | `Issue` (inactive), `IssueChange` | `retention_issue_days` | = history |
| Email log, engine runs | `Notification`, `EngineRun` | `retention_email_days` | = history |
| Monitoring-change audit | `CheckChangeLog` | `retention_audit_days` | 4 × history |

An empty setting means "use `history_retention_days`".

```sql
EXEC OPS.mon.usp_ShowDataRetention;      -- every mon table: rows, MB, retention applied
UPDATE OPS.mon.Setting SET setting_value = N'30'  WHERE setting_name = 'retention_perf_days';
UPDATE OPS.mon.Setting SET setting_value = N'180' WHERE setting_name = 'retention_issue_days';
EXEC OPS.mon.usp_Purge;                  -- purge now instead of waiting up to 6 h
```

Note: the backup retention report can only look back as far as `retention_backup_days` for RDS log backups and RDS task history (AWS itself keeps ~35 days of both).

---

## 4. Emails

### 4.1 Three kinds

| Email | When | Content | Sent if nothing changed? |
|---|---|---|---|
| **Issue alert** | immediately (every 5-min cycle; blocking within 30 s) | what **opened / escalated / resolved**, plus still-active critical issues for context | **No** — change-only |
| **Summary** (short) | scheduled hours (`summary_email_hours_local`) | 4 KPI tiles, last-24 h counts, **every open issue** with age and state (NEEDS ACTION / ACK / MUTED) | Yes — that is its purpose (shows "All clear") |
| **Full report** | scheduled hours and weekdays (`full_report_hours_local`, `full_report_weekdays`) | **everything monitored**: all databases and backups, retention, CHECKDB, Agent jobs, Ola, blocking, deadlocks, error log, performance, storage, coverage, configuration changes, self-health | Yes, unless `full_report_change_only = 1` |

Email policy since 5.7 (`daily_email_mode = AUTO`, applied automatically on upgrade):

- **Failures and anomalies:** a **brief** mail (`alert_style = BRIEF`: just the failure, nothing else) emailed **when they happen** — WARNING and CRITICAL (`alert_min_severity = WARNING`), once per change (opened / escalated / resolved). No reminders for an unchanged issue (`reminder_minutes = 0`).
- **One daily email at 08:00** (`full_report_hours_local`, every day):
  - everything good (no open, unmuted issue) → the **short summary** ("All clear");
  - something open → the **full report**;
  - **nothing changed** since the previous daily email → **no email** (logged as DIGEST_SKIPPED), except a weekly proof-of-life on `heartbeat_weekday` (Monday; `0` = never).
- `daily_email_mode = SCHEDULE` restores the separate summary / full-report schedules described by the settings below.

### 4.2 Settings

| Setting | Default | Meaning |
|---|---|---|
| `alert_recipients` | — | issue alerts |
| `report_recipients` | — | full report (and summary when `summary_recipients` is empty) |
| `summary_recipients` | (empty) | summary only |
| `daily_email_mode` | `AUTO` | AUTO = one daily email: short when all good, full when something is open, none when nothing changed. SCHEDULE = separate summary / full schedules |
| `alert_min_severity` | `WARNING` (5.7) | `CRITICAL` = alert only on critical; warnings then wait for the daily email |
| `alert_style` | `BRIEF` | BRIEF = the alert mail shows only the failure / resolution itself (one line per issue, short detail). FULL = adds the "still active" context table, active counts and issue keys |
| `alert_on_resolve` | 1 | send a RESOLVED email for issues that were alerted |
| `jobfail_reminder_minutes` | 1440 | a failed Agent job is re-mailed every N minutes (subject STILL OPEN) until it succeeds, is disabled/deleted, or is acknowledged / muted; 0 = mail once |
| `reminder_minutes` | 0 | re-send still-open, **not acknowledged** CRITICAL issues every N minutes (0 = off) |
| `summary_email_hours_local` | `8` | comma list of hours 0–23; empty = no summary |
| `summary_email_weekdays` | `1,2,3,4,5,6,7` | ISO weekdays (1 = Monday) |
| `summary_max_issues` | 20 | issues listed in the summary |
| `summary_skip_when_full` | 1 | no summary in an hour when the full report is sent |
| `full_report_hours_local` | `8` | comma list of hours; **empty = legacy** (one change-only digest per day at `report_hour_local`) |
| `full_report_weekdays` | `1,2,3,4,5,6,7` | ISO weekdays |
| `heartbeat_weekday` | 1 | AUTO: weekday on which the daily email is sent even if nothing changed (0 = never) |
| `job_failure_max_age_days` | 0 | 0 = a failed Agent job stays open until it succeeds (or is disabled / deleted); N = also close after N days |
| `full_report_change_only` | 0 | 1 = skip the scheduled full report when nothing changed |
| `display_time_zone` | Eastern Standard Time | Windows time-zone name for all local hours |

### 4.3 Recipes

```sql
-- Issue email also for warnings
UPDATE OPS.mon.Setting SET setting_value = N'WARNING' WHERE setting_name = 'alert_min_severity';

-- Summary twice a day on working days
UPDATE OPS.mon.Setting SET setting_value = N'8,17'      WHERE setting_name = 'summary_email_hours_local';
UPDATE OPS.mon.Setting SET setting_value = N'1,2,3,4,5' WHERE setting_name = 'summary_email_weekdays';

-- Full report every working day at 07:00 and 15:00
UPDATE OPS.mon.Setting SET setting_value = N'7,15'      WHERE setting_name = 'full_report_hours_local';
UPDATE OPS.mon.Setting SET setting_value = N'1,2,3,4,5' WHERE setting_name = 'full_report_weekdays';

-- Full report only when something changed
UPDATE OPS.mon.Setting SET setting_value = N'1' WHERE setting_name = 'full_report_change_only';

-- Remind every 4 hours about critical issues nobody acknowledged
UPDATE OPS.mon.Setting SET setting_value = N'240' WHERE setting_name = 'reminder_minutes';

-- Back to the old behaviour (one change-only digest per day)
UPDATE OPS.mon.Setting SET setting_value = N'' WHERE setting_name = 'full_report_hours_local';
```

Changes apply at the next hourly run (:02).

### 4.4 Preview, send now, statistics

```sql
EXEC OPS.mon.usp_SendSummary @PreviewOnly = 1;            -- subject + HTML, nothing sent
EXEC OPS.mon.usp_SendDailyDigest @Force = 1, @PreviewOnly = 1;
EXEC OPS.mon.usp_SendSummary;                             -- send now
EXEC OPS.mon.usp_SendDailyDigest @Force = 1;              -- send full report now
EXEC OPS.mon.usp_ShowEmailStats;                          -- how many emails per day / type, failures, all Database Mail
```

If Database Mail fails, the issue changes stay pending and go out with the next alert; summary/full report failures are logged in `mon.Notification` (`send_ok = 0`) and in `mon.ComponentStatus` (`SUMMARY_MAIL`, `DIGEST_MAIL`).

---

## 5. Issues and how they get resolved

### 5.1 Lifecycle

```
condition detected ──► OPEN ──(escalates / de-escalates)──► OPEN
                         │
                         ├─ usp_AckIssue ──► ACKNOWLEDGED  (someone is on it: shown as ACK, no reminders)
                         │
                         ├─ condition gone (next 5-min check, after a short grace period) ──► RESOLVED  (+ RESOLVED email if it was alerted)
                         ├─ usp_ResolveIssue (manual, with a note) ─────────────────────────► RESOLVED  (re-opens if still true)
                         ├─ check switched off ─────────────────────────────────────────────► closed silently
                         └─ event issues (deadlock, error-log entry) ───────────────────────► EXPIRED after the lookback window
usp_MuteIssue: stays open but MUTED (no alerts) until the mute expires — for known / accepted conditions
```

An issue is **really resolved only when its cause is fixed**: the engine re-checks every 5 minutes and closes it by itself. Manual resolve is only a shortcut after a fix; if the condition still exists the issue re-opens and alerts again.

### 5.2 Daily routine

1. Read the **summary** (or the full report). Everything in **NEEDS ACTION** has no owner yet.
2. Take ownership: `EXEC OPS.mon.usp_AckIssue @KeyPattern = N'<key from the email>', @Note = N'Alexey - checking';`
3. Fix the cause (see §5.4).
4. Wait for the next cycle (≤ 5 min) — the issue resolves automatically and you get the RESOLVED email — or resolve it by hand:
   `EXEC OPS.mon.usp_ResolveIssue @KeyPattern = N'<key>', @Note = N'FULL backup taken, chain restarted';`
5. Known / accepted condition → mute it with a reason and an end time, or switch the check off for that database.

### 5.3 Commands

| Task | Command |
|---|---|
| All open issues with state | `SELECT severity, workflow_state, title, issue_key, open_minutes, ack_by FROM OPS.mon.vw_ActiveIssues ORDER BY severity, open_minutes DESC;` |
| Acknowledge | `EXEC OPS.mon.usp_AckIssue @KeyPattern = N'BACKUP:LOG:ops', @Note = N'on it';` |
| Remove acknowledgement | `EXEC OPS.mon.usp_AckIssue @KeyPattern = N'BACKUP:LOG:ops', @Unack = 1;` |
| Resolve manually | `EXEC OPS.mon.usp_ResolveIssue @KeyPattern = N'BACKUP:LOG:ops', @Note = N'what was done';` |
| Mute for a maintenance window | `EXEC OPS.mon.usp_MuteIssue @KeyPattern = N'LONGQ:%', @Hours = 3, @Reason = N'ETL';` |
| Switch a check off for a database | `EXEC OPS.mon.usp_SetCheck @Database = N'MIO_REF', @Check = 'DIFF', @Enabled = 0;` |
| History of an issue | `SELECT * FROM OPS.mon.vw_RecentChanges WHERE issue_key = N'<key>' ORDER BY change_utc;` |
| Who resolved what | `SELECT issue_key, resolved_utc, close_type, resolved_by, resolve_note FROM OPS.mon.Issue WHERE close_type = 'MANUAL' ORDER BY resolved_utc DESC;` |

`@KeyPattern` accepts LIKE patterns (`N'CHECKDB:%'`, `N'%MIO_PARTY%'`).

### 5.4 Typical issues and the fix

| Issue key | Meaning | Fix |
|---|---|---|
| `BACKUP:FULL:<db>` / `BACKUP:DIFF:<db>` OVERDUE | last FULL / data backup older than the SLA | check the backup job; if the schedule is intentionally daily, set `DatabasePolicy.diff_max_age_minutes = 1560` |
| `BACKUP:LOG:<db>` CHAIN_BROKEN | log chain broken (recovery model switch, log backup outside RDS…) | take a FULL (or DIFF) backup of the database |
| `CHECKDB:<db>` | no clean CHECKDB within `checkdb_max_age_days` (CRITICAL after × `checkdb_crit_factor`) | run `DatabaseIntegrityCheck` (with `@LogToTable = 'Y'`) |
| `OLAFAIL:...` CORRUPTION FOUND | CHECKDB completed and found corruption | restore / repair — treat as incident |
| `JOBFAIL:<job>` | last run of an Agent job failed | fix and re-run the job; the issue closes when the job succeeds |
| `BLOCKING:<id>` | blocking ≥ 10 min | the email names the head blocker; resolve with the owner (the monitor never kills sessions) |
| `LOGUSED:<db>` | log file filling up | see `log_reuse_wait` in the detail (LOG_BACKUP, ACTIVE_TRANSACTION…) |
| `ENGINE_STALE` / `MON_RELEASE` | the monitor itself is not running / a failed install | §2.1, §1.5 |
| `COMPONENT:<name>` | a collector fails repeatedly | `SELECT * FROM OPS.mon.ComponentStatus WHERE component_name = '<name>';` |

---

## 6. Quick reference

```sql
EXEC OPS.mon.usp_SelfTest;               -- is the monitor healthy and complete?
EXEC OPS.mon.usp_ShowChecks;             -- what is checked
SELECT * FROM OPS.mon.vw_ActiveIssues;   -- what is open now
EXEC OPS.mon.usp_SendSummary;            -- short status email now
EXEC OPS.mon.usp_ShowEmailStats;         -- emails per day / type
EXEC OPS.mon.usp_ShowDataRetention;      -- data volume and retention
EXEC OPS.mon.usp_ShowBackupRetention;    -- backup history, files, retention
SELECT * FROM OPS.mon.Setting ORDER BY category, setting_name;   -- every setting with a description
```
