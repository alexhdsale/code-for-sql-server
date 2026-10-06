# OPS.mon — SQL Server monitoring with change-only email

Self-contained monitoring for SQL Server / Amazon RDS for SQL Server. Everything lives in **one schema (`mon`) of the OPS database**; the only objects outside it are two SQL Agent jobs (`MON - Engine`, `MON - Digest & Watchdog`). Easy to upgrade, move or remove as one unit.

**Current version: 5.4** — see [CHANGELOG.md](CHANGELOG.md).

## Quick start
1. Open [`install/MON_Install.sql`](install/MON_Install.sql) in SSMS (RDS master login) and run the whole file. It is idempotent: re-running upgrades in place and keeps settings, check matrix and history.
2. The installer pauses the engine, installs, runs `mon.usp_SelfTest`, and resumes the engine only if the self-test passes.
3. Check: `EXEC OPS.mon.usp_SelfTest;` and `SELECT * FROM OPS.mon.ReleaseHistory ORDER BY release_id DESC;`
4. Test mail: `EXEC OPS.mon.usp_SendDailyDigest @Force = 1;`
5. Before the first install set your recipients in `src/sql/01_header_tables.sql` (`alert_recipients`, `report_recipients`, `mail_profile`) or afterwards in `mon.Setting`.

## Layout
| Path | What |
|---|---|
| `install/MON_Install.sql` | **Latest installer / upgrader** (built from `src/sql`) |
| `install/MON_Uninstall.sql` | Removes jobs + schema `mon` (WhatIf by default) |
| `src/sql/*.sql` | Source, one file per area; build with `python build/build_install.py` |
| `tools/MON-CheckEditor.ps1` | Windows GUI: check matrix (green/red/grey), retention, Ola log, email statistics |
| `reports/MON_Checks_and_Retention.rdl` | SSMS custom report |
| `docs/MON_User_Guide_EN.md` | User guide (English); `MON_User_Guide_RU.md` — Russian |
| `docs/images` | Sample alert / digest emails and screenshots |

## Useful commands
```sql
EXEC OPS.mon.usp_ShowChecks;            -- what is checked, per database
EXEC OPS.mon.usp_ShowEmailStats;        -- how many emails, per day / type / sender
EXEC OPS.mon.usp_ShowBackupRetention;   -- backup history, files, retention
EXEC OPS.mon.usp_ShowOlaLog;            -- Ola Hallengren CommandLog
SELECT * FROM OPS.mon.vw_ActiveIssues;  -- open issues now
```
