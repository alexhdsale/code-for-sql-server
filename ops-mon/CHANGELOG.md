# OPS.mon — Changelog

Newest first. The installer `install/MON_Install.sql` is always the latest version; git tags `ops-mon-vX.Y` mark each release.

## 5.8.1 — 2026-10-14
- Fix: 5.8.0 install failed its self-test — `mon.usp_CollectTempdb` was not created (Msg 10714: the RCSI-cutover `MERGE` had two `WHEN MATCHED … UPDATE` clauses; SQL Server allows one). ON and OFF switches are now one `WHEN MATCHED AND s.is_on <> t.is_on` with `CASE`. Re-run the installer; the engine resumes after the self-test passes.

## 5.8.0 — 2026-10-14
- **tempdb / version store / RCSI before-after tracking** (new source file `03c_tempdb_rcsi.sql`). Every 5 minutes `mon.usp_CollectTempdb` stores: tempdb size / used / free split into user objects, internal objects, version store and mixed extents; per-file size, used, max size, growth setting; **version store per database** (`sys.dm_tran_version_store_space_usage`) with active versioning transactions and the longest one (who / which database / program); **top row-version generators** resolved to `schema.table` / index (`sys.dm_tran_top_version_generators`); **top tempdb consumers** (session + running tasks, login / host / program / database, statement text); cumulative tempdb I/O; tempdb **autogrowth events** from the default trace; RCSI / SI database counts. Tables `mon.TempdbSample`, `mon.TempdbFileSample`, `mon.TempdbVersionStoreDb`, `mon.TempdbVersionGenerator`, `mon.TempdbTopConsumer`, `mon.TempdbGrowthEvent`.
- **RCSI cutover** is detected automatically per database and recorded in `mon.RcsiCutover` (raises a WARNING event `RCSI:<db>:<time>` once, check `RCSI`). Databases already ON when monitoring starts get no date — set it with `EXEC OPS.mon.usp_SetRcsiCutover @Database = N'MyDb', @EnabledLocal = '2026-10-20 22:00';`.
- **Daily aggregates** `mon.TempdbDaily` (min / avg / p95 / max per local day, I/O deltas, autogrowths) kept `retention_tempdb_daily_days` (400); raw samples kept `retention_tempdb_days` (30). `mon.usp_ShowTempdb` for SSMS (now, cutovers, daily, by database, generators, consumers).
- **Separate daily email "MON - TempDB RCSI"** (`mon.usp_SendTempdbReport`, scheduled by `mon.usp_RunTempdbReport` in the hourly job at `tempdb_report_hours_local` = 08:00, recipients `tempdb_report_recipients` or `report_recipients`): KPI tiles; **reported day vs previous day vs 7-day baseline** (avg / p95 / max with colored deltas); **BEFORE vs AFTER RCSI** (`rcsi_compare_days` before the first cutover vs everything since the last one); version store by database; top row-version generators; top tempdb consumers with statements; hourly profile bars; tempdb files + autogrowths. Preview: `EXEC OPS.mon.usp_SendTempdbReport @PreviewOnly = 1;`. Disable: `tempdb_report_enabled = 0`.
- New server checks: **TEMPDB_VS** (version store ≥ `tempdb_vs_warn_pct` 50 % / `tempdb_vs_crit_pct` 75 % of tempdb; a transaction holding the version store longer than `vs_tran_warn_minutes` 30 / `vs_tran_crit_minutes` 120), **TEMPDB_GROWTH** (≥ `tempdb_growth_warn_per_hour` 10 autogrowths in an hour), **RCSI**. Issue category `TEMPDB`.
- Installer: the release gate now **prints every self-test ERROR / WARN row in the Messages tab** next to the failure message (`usp_SelfTest @Print = 1`); the failure message names the usual cause on a new instance (Database Mail profile). A forced `mail_profile` that does not exist on the instance **falls back to the only Database Mail profile defined there** (printed); otherwise a warning with the fix is printed before the self-test.

## 5.7.3 — 2026-10-13
- **DIFF backup and CHECKDB checks start OFF.** New databases get `diff_backup = 0` and `checkdb = 0` in `mon.DatabaseCheck` (settings `new_db_diff_backup` / `new_db_checkdb`, default 0; set to 1 for the old behaviour).
- One-time on upgrade: existing databases whose DIFF / CHECKDB checkbox was never changed by hand (no `mon.CheckChangeLog` row) are switched OFF too; open DIFF / CHECKDB issues close silently at the next cycle. Checkboxes switched on deliberately are kept.
- Enable per database: `EXEC OPS.mon.usp_SetCheck @Database = N'MyDb', @Check = 'DIFF', @Enabled = 1;` (same with `'CHECKDB'`), or in the Check Editor.

## 5.7.2 — 2026-10-07
- Failed SQL Agent jobs are **re-mailed daily** (`jobfail_reminder_minutes`, default 1440) until the job succeeds, is disabled or deleted, or the issue is acknowledged / muted. Reminder-only mails carry the subject prefix **STILL OPEN**. Independent of the generic `reminder_minutes`.

## 5.7.1 — 2026-10-06
- `alert_style` = **BRIEF** (default): the alert mail contains only what changed — the failure or the resolution, one line per issue with a short detail. No "still active" context table, no counts, no issue keys. `FULL` restores the 5.6 layout.
- Check Editor: system-DPI mode with pixel-scaled fonts (proportional on mixed-DPI monitors), legend in the status bar, header/row heights from the font; removed `SetCompatibleTextRenderingDefault` (failed on re-run in the same console).

## 5.7.0 — 2026-10-06
- **Email policy AUTO** (`daily_email_mode`, applied on upgrade): failures and anomalies (WARNING + CRITICAL) are emailed when they happen, once per change, no reminders; **one daily email at 08:00** — the short summary when everything is good, the full report when something is open, **no email when nothing changed** (weekly proof-of-life on `heartbeat_weekday`). `SCHEDULE` keeps the 5.6 behaviour.
- Fix: a failed Agent job (e.g. unscheduled `_test_job`) was auto-resolved after 7 days although its last run still failed. `job_failure_max_age_days` now defaults to 0 = open until the job succeeds, is disabled or deleted.
- Check Editor: high-DPI aware (no more clipped buttons / tiny text boxes at 125-200 % scaling), every size scales with the monitor; tool bars, legend chips, rounded badges, two-line headers that never clip, tab and section typography.
- Fix: RDS native backup task times (`rds_task_status`) are UTC; on an instance with a non-UTC time zone they were shifted into the future ("0s ago" for every FULL backup). Auto-detected (`rds_task_times_utc`), stored rows corrected; a time still ahead of the clock shows **TIME AHEAD** instead of "0s ago".

## 5.6.4 — 2026-10-06
- CHECKDB issues are reported under category **INTEGRITY** instead of BACKUP (open issues move over at the next 5-minute cycle).

## 5.6.3 — 2026-10-06
- `usp_ShowChecks` is created before `usp_SetCheck` — no more "depends on the missing object" message during install.
- Release gate finds this install's `ReleaseHistory` row through `SESSION_CONTEXT` (the previous run was reported as "previous: none"); the start message shows the last version even if it was not recorded as COMPLETED.

## 5.6.2 — 2026-10-06
- Fix: `msdb.dbo.syssessions` is no longer used (not readable by the RDS master user — Msg 229): the installer's engine-running check and the JOBLONG running-job list now use sysjobactivity (last 2 days) and Agent job-step sessions.

## 5.6.1 — 2026-10-06
- Fix: `usp_ResolveIssue` failed to compile (Msg 1046 — subquery inside PRINT), which made the 5.6 self-test fail and left the engine paused.
- Fix: installer no longer prints Msg 22022 when `MON - Engine` is not running (stops the job only if it is active).

## 5.6 — 2026-10-06
- **Three kinds of email:** issue alerts (immediate, change-only — nothing changed = no email), a scheduled **short summary** (`mon.usp_SendSummary`: KPI tiles + every open issue with NEEDS ACTION / ACK / MUTED) and a scheduled **full report** (everything monitored). Scheduler `mon.usp_RunScheduledEmails` in the hourly job; settings `summary_email_hours_local`, `summary_email_weekdays`, `summary_recipients`, `summary_max_issues`, `summary_skip_when_full`, `full_report_hours_local`, `full_report_weekdays`, `full_report_change_only`. Defaults: summary daily 08:00, full report Monday + Thursday 08:00. Empty `full_report_hours_local` = old behaviour.
- **Issue workflow:** `mon.usp_AckIssue` (owner + note, no reminders while acknowledged), `mon.usp_ResolveIssue` (manual close with a note, re-opens if the condition persists); `vw_ActiveIssues.workflow_state`.
- **Retention per area:** `retention_perf_days`, `retention_backup_days`, `retention_issue_days`, `retention_email_days`, `retention_audit_days`; `mon.usp_ShowDataRetention` shows rows / MB / retention per table.
- New `docs/MON_Operations_Guide.md`: deployment, Agent jobs, retention, email schedule, issue resolution.

## 5.5 — 2026-10-06
- **Performance:** `mon.vw_BackupRetention` rewritten to read every source once and aggregate once (was re-evaluated per database × backup type through OUTER APPLY — `usp_ShowBackupRetention` took ~36 s). Server-time → UTC offset computed once instead of a per-row scalar UDF on msdb history; settings read inline.
- Backup collector: msdb history scan bounded to 400 days (sargable); latest RDS log backup per database via index seek instead of ROW_NUMBER over the whole table.
- New `src/sql/01c_performance_indexes.sql`: covering index on `mon.TlogBackup`, purge/time indexes on `TlogBackup`, `OlaCommand`, `AgentJobRun`, `EngineRun`, `RdsTask`; `IssueChange(issue_id)`, `Notification(mailitem_id)` / `(created_utc)`. All idempotent, all in schema `mon`.

## 5.4 — 2026-10-06
- **Release guard:** every install is recorded in `mon.ReleaseHistory`; the engine is paused (`engine_enabled = 0`) during the install; `mon.usp_SelfTest @Deep = 1` runs at the end (required objects, views bind, modules compile, no broken references, nothing created outside schema `mon`, jobs, settings, mail profile, check catalog). The engine resumes only with 0 errors; otherwise the release is `FAILED` and the watchdog raises CRITICAL `MON_RELEASE`.
- **Email statistics:** `mon.usp_ShowEmailStats @Days` — MON emails per day / type, last 100, all Database Mail on the server split MON vs others; Check Editor tab *Emails (30 days)*.
- **`MON_Uninstall.sql`:** removes both jobs and the whole `mon` schema (WhatIf by default).

## 5.3 — 2026-09-30 … 2026-10-06
- Switching a check off closes its open issues immediately (`mon.usp_CloseDisabledIssues`, called by APPLY, `usp_SetCheck`, digest, alerts).
- DIFF alerts show which backup counted (`via FULL/...` / `via DIFF/...`).
- CHECKDB becomes CRITICAL after SLA × `checkdb_crit_factor` (4); dates older than 300 days show the year.
- Check Editor: green ON / red OFF / grey n/a badges, click-to-toggle, Last good CHECKDB column, 30-day Ola tab; faster Refresh/APPLY (lazy tabs, snapshot retention, 3 s lock wait).
- `usp_ShowBackupRetention` evaluates the msdb-based view once instead of twice.

## 5.2 — 2026-09-29
- Backup files made / last 24 h / on storage; declared storage retention, POLICY status.
- Last good CHECKDB from DATABASEPROPERTYEX → DBCC DBINFO → Ola CommandLog.
- Ola Hallengren CommandLog collector with outcomes CORRUPTION FOUND / SKIPPED / FAILED.
- Failed jobs stay open while the last run failed (up to 7 days, STILL FAILED).
- PowerShell Check Editor.

## 5.1
- Check matrix (`mon.DatabaseCheck` / `mon.ServerCheck`) with audit; backup retention grid; SSMS custom report.

## 5.0
- New `mon` schema; issue lifecycle; change-only alerts + daily digest + Monday heartbeat; 30-s blocking sampler with 10-minute alert; long queries, open transactions, job duration anomalies, config drift, perf snapshot.
