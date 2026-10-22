# sp_WhoIsActive Logging – single-file installer

One script, `Install_sp_WhoIsActiveLogging.sql`, that deploys Erik Darling's
[sp_WhoIsActive Logging](https://github.com/erikdarlingdata/DarlingData/tree/main/sp_WhoIsActive%20Logging)
toolkit into a utility database instead of `master`.

## Install
1. Install/update [sp_WhoIsActive](https://github.com/amachanic/sp_whoisactive) in `master` or in the utility DB
   (root script for SQL 2022+, `2019/` folder for 2016–2019).
2. Edit the single `USE [Utility];` line (and the optional `#wia_config` values).
3. Run the whole script as sysadmin.

## What gets created
| Where | Object |
|---|---|
| Utility DB | `dbo.sp_WhoIsActiveLogging_Main`, `dbo.sp_WhoIsActiveLogging_Retention`, `dbo.sp_WhoIsActiveLogging_CreateViews` |
| Utility DB (runtime) | `dbo.WhoIsActive_YYYYMMDD` daily tables, `dbo.WhoIsActive` view, `dbo.WhoIsActive_blocking` view |
| msdb | Job `Log sp_WhoIsActive To A Daily Table` (category *Data Collector*, every minute, step runs in the Utility DB) |

## Config (`#wia_config` in the script)
| Setting | Default | Notes |
|---|---|---|
| RetentionDays | 10 | daily tables older than this are dropped |
| DataCompression | NONE | NONE / ROW / PAGE for new daily tables |
| CreateClusteredIndex | 1 | CI on `collection_time` per daily table |
| JobName | Log sp_WhoIsActive To A Daily Table | same as original |
| JobOwner | NULL | NULL = login with SID 0x01 (sa, even if renamed) |
| JobEnabled | 1 | |
| ScheduleEveryMinutes | 1 | 1–59 |
| ReplaceExistingJob | 1 | drop/recreate job on re-run, history kept |
| RunFirstCollection | 1 | runs one collection at the end of install |

## Changes vs. the original
- Logs to the database the procs live in (original hard-codes `master`); job step database = that DB.
- `sp_WhoIsActive` resolved at runtime: utility DB first, then `master`.
- Table date suffix via `CONVERT(..., 112)` (DATEFORMAT/language-safe).
- `dbo.WhoIsActive` view rebuilt only when the table set changes (no Sch-M lock every minute);
  tables with a different column layout (after an sp_WhoIsActive upgrade) are excluded instead of breaking the view.
- Retention/views scoped to `dbo`; retention can't go below 1 day.
- Prerequisite checks with `SET NOEXEC ON` (system DB / failed USE, Azure SQL DB, < 2016 SP1, missing/old sp_WhoIsActive).
- Uninstall block included (commented out).

Credits: Erik Darling / Darling Data, LLC (MIT) and Adam Machanic (sp_WhoIsActive, GPLv3).
