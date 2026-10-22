# sp_WhoIsActive + sp_WhoIsActive Logging – single-file installer

One script, **`Install_sp_WhoIsActiveLogging.sql`**, deploys everything into a utility database:

- Adam Machanic's [sp_WhoIsActive](https://github.com/amachanic/sp_whoisactive) (embedded, version-aware)
- Erik Darling's [sp_WhoIsActive Logging](https://github.com/erikdarlingdata/DarlingData/tree/main/sp_WhoIsActive%20Logging) procs
- The SQL Agent job in `msdb`

## Install
1. Edit the single `USE [Utility];` line (the database must already exist).
2. Optionally change the `#wia_config` values.
3. Run the whole script as sysadmin (F5). It's re-runnable.

## What gets created
| Where | Object |
|---|---|
| Utility DB | `dbo.sp_WhoIsActive` — 2022+ build on SQL 2022+, 2012-2019 build on SQL 2016-2019 (picked automatically) |
| Utility DB | `dbo.sp_WhoIsActiveLogging_Main`, `dbo.sp_WhoIsActiveLogging_Retention`, `dbo.sp_WhoIsActiveLogging_CreateViews` |
| Utility DB (runtime) | `dbo.WhoIsActive_YYYYMMDD` daily tables, `dbo.WhoIsActive` view, `dbo.WhoIsActive_blocking` view |
| msdb | Job `Log sp_WhoIsActive To A Daily Table` (category *Data Collector*, every minute, step runs in the Utility DB) |

An existing `master.dbo.sp_WhoIsActive` is left untouched; the job uses the Utility DB copy.

## Config (`#wia_config` in the script)
| Setting | Default | Notes |
|---|---|---|
| InstallWhoIsActive | 1 | install/upgrade `dbo.sp_WhoIsActive` in the Utility DB; 0 = use an existing copy (Utility DB, then master) |
| RetentionDays | 10 | daily tables older than this are dropped |
| DataCompression | NONE | NONE / ROW / PAGE for new daily tables |
| CreateClusteredIndex | 1 | CI on `collection_time` per daily table |
| JobName | Log sp_WhoIsActive To A Daily Table | same as original |
| JobOwner | NULL | NULL = login with SID 0x01 (sa, even if renamed) |
| JobEnabled | 1 | |
| ScheduleEveryMinutes | 1 | 1–59 |
| ReplaceExistingJob | 1 | drop/recreate job on re-run, history kept |
| RunFirstCollection | 1 | runs one collection at the end of install |

## Updating sp_WhoIsActive
The installer is generated. Don't edit it by hand:
```
cd build
python build_installer.py                 # pulls latest amachanic/sp_whoisactive
python build_installer.py --wia-path X:\src\sp_whoisactive   # or use a local clone
```
Edit `build/Install_template.sql` for changes to the logging part, then rebuild.

## Changes vs. the original toolkit
- Logs to the database the procs live in (original hard-codes `master`); job step database = that DB.
- `sp_WhoIsActive` resolved at runtime: Utility DB first, then `master`.
- Table date suffix via `CONVERT(..., 112)` (DATEFORMAT/language-safe).
- `dbo.WhoIsActive` view rebuilt only when the table set changes (no Sch-M lock every minute);
  tables with a different column layout (after an sp_WhoIsActive upgrade) are excluded instead of breaking the view.
- Retention/views scoped to `dbo`; retention can't go below 1 day.
- Prerequisite checks with `SET NOEXEC ON` (system DB / failed USE, Azure SQL DB, < 2016 SP1).
- Uninstall block included (commented out).

## Licenses
- sp_WhoIsActive © 2007-2026 Adam Machanic — GPLv3 (embedded unmodified; the installer file as a whole is therefore distributed under GPLv3).
- sp_WhoIsActive Logging © 2026 Darling Data, LLC — MIT.
