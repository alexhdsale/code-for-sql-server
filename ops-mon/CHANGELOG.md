# OPS.mon — Changelog

Newest first. The installer `install/MON_Install.sql` is always the latest version; git tags `ops-mon-vX.Y` mark each release.

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
