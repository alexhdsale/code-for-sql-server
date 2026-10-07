# OPS.mon — Changelog

Newest first. The installer `install/MON_Install.sql` is always the latest version; git tags `ops-mon-vX.Y` mark each release.

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
