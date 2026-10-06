# OPS.mon rev 5.2: руководство по использованию

Сервер: **MS-APP-STG** (Amazon RDS for SQL Server) · база **OPS** · схема **mon**
Файлы: `stage_monitoring_mon_v5.2.sql` (установщик), `MON_Checks_and_Retention.rdl` (отчёт SSMS), папка `preview/` (как выглядят письма и SSMS)

---

## 1. Как это устроено

```
 ┌───────────── MON - Engine (Agent, старт каждую минуту, один запуск крутится 55 мин) ─────────────┐
 │  каждые 30 с : usp_CaptureBlocking ──► BlockingEpisode / BlockingSample                            │
 │                если есть блокировка ≥ 10 мин ──► usp_EvaluateIssues 'BLOCKING' ──► usp_SendAlerts │
 │  каждые 5 мин: SyncPolicies → DatabaseState → Backups → Agent → Events → Perf                      │
 │                ──► usp_EvaluateIssues 'ALL' ──► usp_SendAlerts (только при изменениях)              │
 └───────────────────────────────────────────────────────────────────────────────────────────────────┘
 ┌──────── MON - Digest & Watchdog (каждый час в :02) ────────┐
 │  снимок retention → watchdog движка → digest (08:02 ET)    │
 │  → очистка истории (раз в 6 часов)                          │
 └─────────────────────────────────────────────────────────────┘
```

Каждая проверка создаёт **issue**. У issue есть жизненный цикл: `OPENED → ESCALATED / DEESCALATED → RESOLVED` (для состояний) или `EXPIRED` (для событий: deadlock, ошибка в errorlog). Письма отправляются **только при изменении** этого цикла:

| Письмо | Когда уходит | Когда НЕ уходит |
|---|---|---|
| **Alert** (сразу) | новый или эскалированный CRITICAL; RESOLVED по issue, о котором уже был alert | если ничего нового не открылось, не эскалировалось и не закрылось |
| **Digest** (08:02 ET) | если с прошлого digest было хоть одно изменение issue **или** кто-то поменял галочки/настройки | нет изменений → в журнал пишется `DIGEST_SKIPPED` |
| **Heartbeat** (понедельник) | всегда, даже без изменений: доказывает, что мониторинг жив | — |

---

## 2. Установка и обновление

1. Откройте `stage_monitoring_mon_v5.2.sql` в SSMS под master-логином RDS и выполните **весь файл** (F5). Скрипт идемпотентный: повторный запуск сохраняет все настройки, галочки, mute-правила, baseline и историю. Обновление с 5.0 делается тем же файлом.
   - При первом запуске 5.1 флаги из `mon.DatabasePolicy` (is_monitored, require_*) один раз переносятся в новую матрицу `mon.DatabaseCheck`.
2. В конце скрипт выводит проверочные наборы результатов. Посмотрите на них:
   - `ComponentStatus`: у всех компонентов `consecutive_failures = 0`;
   - `vw_ActiveIssues`: что найдено при установке (письмом **не** отправляется, попадёт в первый digest);
   - `usp_ShowChecks`: матрица проверок;
   - `usp_ShowBackupRetention`: сетка retention.
3. Сразу после установки проверьте три вещи на самом сервере:
   ```sql
   SELECT TOP 5 task_type, lifecycle FROM OPS.mon.RdsTask;                 -- DIFF должен быть BACKUP_DB_DIFFERENTIAL
   SELECT SYSDATETIMEOFFSET();                                              -- offset +00:00 (RDS в UTC)
   SELECT TOP 1 * FROM msdb.dbo.sysjobactivity;                             -- доступ есть
   ```
4. Посмотрите письмо без отправки, затем отправьте тестовое:
   ```sql
   EXEC OPS.mon.usp_SendDailyDigest @Force = 1, @PreviewOnly = 1;   -- html_body → сохранить как .html
   EXEC OPS.mon.usp_SendDailyDigest @Force = 1;
   SELECT TOP 10 * FROM msdb.dbo.rds_fn_sysmail_allitems() ORDER BY send_request_date DESC;
   ```
5. Старые джобы `OPS - ...` (rev 4) продолжают работать, пока вы их не выключите. Пока они включены, письма будут приходить от обеих систем (см. раздел 10).

---

## 3. Что проверяется: матрица с галочками (главное в 5.1)

### 3.1 Посмотреть всё одной командой
```sql
EXEC OPS.mon.usp_ShowChecks;                 -- все базы
EXEC OPS.mon.usp_ShowChecks @Database = N'Mio%';
```
Команда возвращает 4 набора результатов:

1. **Матрица**: строка на базу, колонка на проверку. `✔` = включено, пусто = выключено, `-` = база не мониторится, `n/a` = неприменимо (LOG при SIMPLE recovery). В этой же строке видны цель retention и SLA full/diff/log в минутах.
2. **Серверные проверки**: включено или нет, что проверяет, какой настройкой регулируется.
3. **Каталог**: полный список проверок, описание, колонка в таблице, шаблон ключа issue.
4. **Аудит**: последние 50 изменений (кто, когда, с какого хоста, старое → новое значение).

### 3.2 Поставить или снять галочку, вариант A: SSMS Edit Top 200 Rows
Object Explorer → **OPS → Tables → mon.DatabaseCheck** → правый клик → **Edit Top 200 Rows**.

- Колонка `bit` показывается как `True/False`: выберите значение в выпадающем списке или введите 1/0.
- Изменение сохраняется, когда вы уходите со строки (или по Ctrl+S). Каждое изменение автоматически пишется в `mon.CheckChangeLog` триггером.
- Так же редактируются **mon.ServerCheck** (колонка `is_enabled`) и **mon.DatabasePolicy** (SLA в минутах).
- Если строка не сохраняется («row was not committed»), значит, введено неверное значение. Нажмите Esc, чтобы откатить строку.

### 3.2a Вариант 1: MON Check Editor (PowerShell, настоящие чекбоксы + APPLY)
Файл `MON-CheckEditor.ps1` работает только на Windows и ничего не устанавливает: использует встроенный .NET SqlClient.
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\MON-CheckEditor.ps1 -Server ms-app-stg.xxxx.us-east-1.rds.amazonaws.com
```
1. Введите login и пароль (или включите Windows auth) и нажмите **Connect**. Сервер, login и режим запоминаются в `%APPDATA%\MON\CheckEditor.json`, пароль не сохраняется.
2. Вкладки:
   - **Databases**: матрица чекбоксов, цель retention, политика хранения, notes;
   - **Server checks**;
   - **Settings / thresholds**;
   - **Backup retention**: итоги и сетка, только просмотр;
   - **Ola CommandLog**: 7 дней, только просмотр;
   - **Change log**: аудит.
3. Кликайте по чекбоксам. Для массовых изменений выделите ячейки мышью (Ctrl/Shift) и нажмите **Check selected** / **Uncheck selected** или пробел.
4. Изменённые ячейки подсвечиваются **жёлтым**, счётчик показывается на кнопке **APPLY (N)**.
5. **APPLY** или Ctrl+S: окно показывает список «было → стало», после подтверждения всё записывается **одной транзакцией**. Если строку тем временем изменил кто-то другой, не сохраняется ничего, и программа просит нажать Refresh.
6. **Discard changes** отменяет правки, **F5** перезагружает данные, фильтр работает по имени базы.

Все изменения попадают в `mon.CheckChangeLog` от имени вашего login и с именем хоста. Вступают в силу в ближайшем 5-минутном цикле.

### 3.3 Вариант B: одной командой (удобно для массовых изменений)
```sql
-- одна проверка у одной базы
EXEC OPS.mon.usp_SetCheck @Database = N'DWH_Stage',  @Check = 'LOG',  @Enabled = 0;
-- одна проверка у всех баз
EXEC OPS.mon.usp_SetCheck @Database = N'%',          @Check = 'LONGQ', @Enabled = 0;
-- все проверки базы (кроме Monitored)
EXEC OPS.mon.usp_SetCheck @Database = N'Archive2019', @Check = 'ALL',  @Enabled = 0;
-- полностью исключить базу
EXEC OPS.mon.usp_SetCheck @Database = N'TestRestore', @Check = 'MONITORED', @Enabled = 0, @Notes = N'scratch restore';
-- серверная проверка
EXEC OPS.mon.usp_SetCheck @Check = 'CPU', @Enabled = 0;
-- цель retention для базы (дней); 0 = вернуть значение по умолчанию
EXEC OPS.mon.usp_SetCheck @Database = N'MioCore', @Check = 'RETENTION', @Enabled = 1, @RetentionDays = 14;
```
После выполнения `usp_SetCheck` сам показывает обновлённую матрицу. В `@Check` можно передать код (`LOG`) или имя колонки (`log_backup`). Список кодов: `SELECT * FROM OPS.mon.CheckCatalog`.

### 3.4 Вариант C: отчёт в SSMS (только просмотр, но наглядно)
1. Сохраните `MON_Checks_and_Retention.rdl` в любую папку.
2. Object Explorer → **правый клик на сервере** → **Reports → Custom Reports…** → выберите файл. На предупреждение о запуске запросов ответьте **Run**.
3. В отчёте: цветная матрица (синяя галочка = ON, жёлтое = OFF, серое = n/a), таблица серверных проверок и сетка retention с подсветкой.
4. Отчёт запоминается в Custom Reports, дальше он открывается в один клик. Обновить данные: правый клик на отчёте → Refresh.

Если вместо галочки виден квадратик, в Windows нет шрифта с этим символом. Замените в RDL FontFamily ячейки на `Segoe UI Symbol`.

### 3.5 Все проверки

| Код | Колонка в DatabaseCheck | Что проверяет | Чем регулируется |
|---|---|---|---|
| MONITORED | monitored | главный выключатель базы | — |
| FULL | full_backup | возраст последнего FULL | DatabasePolicy.full_max_age_minutes (1440) |
| DIFF | diff_backup | возраст DIFF или FULL (последний data-бэкап) | diff_max_age_minutes (360) |
| LOG | log_backup | возраст LOG, разрыв цепочки | log_max_age_minutes (30) |
| RETENTION | backup_retention (+ retention_days) | глубина истории бэкапов, отсутствие бэкапов, пропуски | backup_retention_target_days (7) |
| CHECKDB | checkdb | последний успешный CHECKDB | checkdb_max_age_days (8) |
| LOGUSED | log_used | заполненность журнала + причина (log_reuse_wait) | log_used_warn/crit_pct (80/90) |
| VLF | vlf_count | число VLF | vlf_warn_count (1000) |
| FILEMAX | file_near_max | файл у предела MAXSIZE | file_near_max_pct (90) |
| DRIFT | config_drift | изменение recovery/compat/owner/RCSI… относительно baseline | usp_AcceptConfigBaseline |
| CONFIG | config_best_practice | AUTO_CLOSE, AUTO_SHRINK, PAGE_VERIFY | — |
| QSTORE | query_store | Query Store ушёл в READ_ONLY | — |
| BLOCKING | blocking | блокировка ≥ N минут | blocking_alert_minutes (10) |
| LONGQ | long_queries | долгие запросы | long_query_warn/crit_minutes (30/120) |
| OPENTRAN | open_trans | открытые или «забытые» транзакции | open_tran_warn/crit_minutes (15/60) |
| DEADLOCK | deadlocks | каждый deadlock | deadlock_severity (WARNING) |
| IOLAT | io_latency | задержка I/O по файлам | io_latency_warn_ms (50) |
| *серверные:* DB_STATE, AGENT_FAIL, JOB_SLA, JOB_LONG, RDS_TASKS, ERRORLOG, LOGIN_FAIL, DEADLOCK_STORM, CPU, MEMGRANTS, TEMPDB, STORAGE, RESTART, MAIL | mon.ServerCheck.is_enabled | см. `usp_ShowChecks`, набор 2 | см. колонку «Tuned by» |

### 3.6 Что происходит, когда галочку снимают или ставят
- **Сняли:** со следующего 5-минутного цикла проверка перестаёт создавать issues для этой базы. Уже открытые issues этой проверки **закрываются молча**, письма RESOLVED не будет. В digest изменение видно в разделе «Monitoring configuration changes», а база попадает в раздел «Monitoring coverage».
- **Поставили:** если проблема существует, issue откроется заново и придёт alert.
  - Для событийных проверок (DEADLOCK, ERRORLOG, MAIL) при повторном включении откроются события за последние `event_lookback_hours` (24 ч). Это ожидаемо.
- **Новая база** появляется в матрице автоматически, со всеми галочками ON.
- **Удалённая база** остаётся в матрице, и приходит issue «no longer exists». Выключите её через `@Check='MONITORED', @Enabled=0`.
- Пороги (минуты, проценты) задаются **не** в матрице, а в `mon.Setting` (глобально) и `mon.DatabasePolicy` (SLA по базе).

---

## 4. История и retention бэкапов

```sql
EXEC OPS.mon.usp_ShowBackupRetention;                       -- live по всем базам + тренд за 30 дней
EXEC OPS.mon.usp_ShowBackupRetention @Database = N'MioCore';
EXEC OPS.mon.usp_ShowBackupRetention @Live = 0;             -- быстрый вариант из сегодняшнего снимка
SELECT * FROM OPS.mon.vw_BackupRetention;                   -- сырые данные
SELECT * FROM OPS.mon.BackupInventoryDaily ORDER BY snapshot_date DESC;  -- ежедневная история
```

| Колонка | Смысл |
|---|---|
| Count | сколько бэкапов этого типа записано |
| Oldest / Newest | самый старый и самый новый (по вашему времени) |
| Retention days | насколько далеко назад есть история |
| Target days | цель (`DatabaseCheck.retention_days`, иначе настройка `backup_retention_target_days` = 7) |
| Gaps | сколько интервалов в окне цели длиннее SLA × 1.25 (для FULL и LOG) |
| Interval / Avg / Total | средний интервал, средний и общий размер |
| Source | MSDB / RDS_TASK / RDS_TLOG. Для каждой базы и типа берётся источник с наибольшим числом записей, без двойного счёта |

**Статусы:**

- **OK** — всё в порядке.
- **SHORT** — история короче цели. Базы моложе цели не считаются.
- **NONE** — бэкапов этого типа нет.
- **GAPS** — есть пропуски.
- **N/A** — неприменимо: LOG при SIMPLE или DIFF, который не используется.
- **OFF** — проверка выключена.

SHORT, NONE и GAPS создают WARNING-issue `RETENTION:<тип>:<база>` и попадают в digest. В digest показываются только исключения и сводная строка «N комбинаций OK».

**Ограничения:**

- T-SQL не видит lifecycle-правила S3. «Oldest» означает самый старый бэкап, **записанный** в истории, а не гарантию, что файл ещё лежит в S3.
- Автоматические логовые бэкапы RDS учитываются максимум за 35 дней.
- История msdb обрезается джобой `sp_delete_backuphistory` (Ola). Если она чистит всё старше N дней, retention по MSDB не будет больше N. Согласуйте это с целью retention.

---

## 5. Блокировки > 10 минут

- Сэмплирование каждые 30 с по `sys.dm_os_waiting_tasks`, поэтому видны и заблокированные параллельные запросы.
- Эпизод = одно соединение головного блокировщика (session_id + login_time). Время начала считается по самому долгому прямому ожиданию.
- В 10 минут приходит **CRITICAL alert**. В нём: кто блокирует (login, host, program), статус сессии, возраст открытой транзакции, SQL головного блокировщика и заблокированный SQL, ресурс ожидания. Сессия в состоянии sleeping с открытой транзакцией подсвечивается как **DIAGNOSIS: IDLE inside an open transaction**.
- Когда блокировка уходит, в течение примерно 30 с приходит **RESOLVED** с итоговой длительностью.
- Ничего не убивается автоматически.
```sql
SELECT * FROM OPS.mon.vw_BlockingNow;                                           -- живые цепочки
SELECT TOP 20 * FROM OPS.mon.BlockingEpisode ORDER BY last_seen_utc DESC;       -- история
SELECT * FROM OPS.mon.BlockingSample WHERE episode_id = 123 ORDER BY sample_utc; -- детали цепочки
```
Тест на тестовой базе:

1. Временно снизьте порог до 2 минут:
   ```sql
   UPDATE OPS.mon.Setting SET setting_value = N'2' WHERE setting_name = 'blocking_alert_minutes';
   ```
2. В сессии A выполните `BEGIN TRAN; UPDATE t SET c = c WHERE id = 1;` и не завершайте транзакцию.
3. В сессии B выполните `SELECT * FROM t WHERE id = 1;` — запрос заблокируется.
4. Примерно через 2,5 минуты должен прийти CRITICAL alert.
5. В сессии A выполните `ROLLBACK`. Должно прийти письмо RESOLVED.
6. Верните порог на 10:
   ```sql
   UPDATE OPS.mon.Setting SET setting_value = N'10' WHERE setting_name = 'blocking_alert_minutes';
   ```

---

## 6. Ежедневная работа DBA

| Задача | Команда |
|---|---|
| Что открыто сейчас | `SELECT * FROM OPS.mon.vw_ActiveIssues ORDER BY severity, category;` |
| Что менялось за неделю | `SELECT * FROM OPS.mon.vw_RecentChanges ORDER BY change_utc DESC;` |
| Заглушить известную проблему | `EXEC OPS.mon.usp_MuteIssue @KeyPattern = N'LONGQ:%', @Hours = 3, @Reason = N'ETL';` |
| Снять заглушку | `EXEC OPS.mon.usp_MuteIssue @KeyPattern = N'LONGQ:%', @Unmute = 1;` |
| Принять изменение конфигурации БД | `EXEC OPS.mon.usp_AcceptConfigBaseline @DatabaseName = N'MioCore';` |
| Здоровье самого мониторинга | `SELECT * FROM OPS.mon.ComponentStatus; SELECT TOP 5 * FROM OPS.mon.EngineRun ORDER BY 1 DESC;` |
| Журнал писем | `SELECT TOP 50 * FROM OPS.mon.Notification ORDER BY notification_id DESC;` |
| Кто что поменял в мониторинге | `SELECT TOP 100 * FROM OPS.mon.CheckChangeLog ORDER BY change_log_id DESC;` |
| Предпросмотр alert-письма | `EXEC OPS.mon.usp_SendAlertsCore @PreviewOnly = 1;` |

Mute отличается от снятой галочки. Mute действует временно и по шаблону ключа issue, а issue остаётся видимым в digest с пометкой MUTED. Галочка выключает проверку постоянно.

---

## 7. Главные настройки (`mon.Setting`)

```sql
SELECT * FROM OPS.mon.Setting ORDER BY category, setting_name;   -- описание каждой
UPDATE OPS.mon.Setting SET setting_value = N'...' WHERE setting_name = '...';  -- изменение попадёт в аудит
```
| Настройка | По умолчанию | Зачем менять |
|---|---|---|
| alert_recipients / report_recipients | aleksey_kokit@… | другие получатели |
| alert_min_severity | CRITICAL | `WARNING` — получать сразу и предупреждения |
| reminder_minutes | 0 | например 240: напоминать о незакрытых CRITICAL (отходит от принципа «только изменения») |
| report_hour_local / heartbeat_weekday | 8 / 1 (пн) | время digest, день heartbeat (0 = выкл) |
| blocking_alert_minutes | 10 | порог блокировок |
| backup_retention_target_days | 7 | цель глубины истории бэкапов |
| engine_enabled | 1 | 0 = мягкая остановка движка в течение 30 с |

---

## 8. Как читать письма

- **Alert**:
  - цвет шапки: красный = CRITICAL, жёлтый = WARNING, зелёный = только закрытия;
  - разделы: New / escalated → Resolved → Still active (для контекста);
  - под каждым issue мелким шрифтом виден его `key:`, его и подставляйте в `usp_MuteIssue`.
- **Digest**, по порядку:
  - KPI-плитки;
  - What changed;
  - Open issues;
  - Databases & backups (все базы, проблемные ячейки подсвечены);
  - **Backup retention & inventory**;
  - Blocking;
  - SQL Agent;
  - Deadlocks;
  - Error log / Failed logins;
  - Performance;
  - Storage;
  - **Monitoring coverage**;
  - **Configuration changes**;
  - Self-health.
- Красная ячейка требует действия. Жёлтая означает «посмотреть». Серые плашки означают информацию.
- Размер письма рассчитан так, чтобы Gmail его не обрезал (меньше примерно 100 KB). Поэтому в больших разделах показываются только исключения и первые 40 строк.

---

## 9. Диагностика, если что-то не так

| Симптом | Что проверить |
|---|---|
| Нет писем вообще | `SELECT * FROM mon.Notification ORDER BY 1 DESC` → `send_ok`, `error_message`; `rds_fn_sysmail_event_log()`; профиль `Notifications` |
| Пришёл alert «Monitoring engine is not running» | история джобы `MON - Engine`, `mon.EngineRun.end_reason`, `engine_enabled` |
| Issue «Monitoring collector failing» | `mon.ComponentStatus.last_error_message` у названного компонента |
| Digest не пришёл | так и задумано, если ничего не изменилось: `SELECT * FROM mon.Notification WHERE notification_type='DIGEST_SKIPPED'` |
| Ложный RETENTION DIFF | база без DIFF-бэкапов даёт N/A; если бэкапы всё же есть, но редкие, выключите `DIFF` или `RETENTION` для этой базы |
| Галочка не действует | изменение применяется в следующем 5-минутном цикле; проверьте `mon.CheckChangeLog` |

---

## 10. Переход со старой версии (rev 4) и удаление

Когда убедитесь, что новые письма приходят:
```sql
EXEC msdb.dbo.sp_update_job @job_name = N'OPS - Backup and Maintenance Monitor',   @enabled = 0;
EXEC msdb.dbo.sp_update_job @job_name = N'OPS - Daily Backup and Maintenance Report', @enabled = 0;
```
Удаление rev 5.x:

1. Удалите джобы:
   ```sql
   EXEC msdb.dbo.sp_delete_job @job_name = N'MON - Engine';
   EXEC msdb.dbo.sp_delete_job @job_name = N'MON - Digest & Watchdog';
   ```
2. Удалите объекты схемы `mon` в OPS в таком порядке: триггеры → процедуры → представления → функции → таблицы.
3. Выполните `DROP SCHEMA mon`.

---

## 11. Что осталось вне SQL (рекомендации)

- **CloudWatch** остаётся источником истины для CPU хоста, FreeableMemory, FreeStorageSpace, IOPS и задержек EBS, а также Multi-AZ событий. Заведите на них alarm'ы.
- **S3 lifecycle и хранение native-бэкапов** проверяются на стороне AWS: правило lifecycle на бакете и AWS Backup, если используется.
- **Внешний dead-man switch.** Если выключится весь инстанс, мониторинг изнутри SQL не сможет прислать письмо. Отсутствие понедельничного heartbeat будет сигналом, а надёжнее всего — CloudWatch alarm на `DatabaseConnections` / статус инстанса.

---

## 12. Новое в 5.2: файлы бэкапов, хранилище, CHECKDB, Ola CommandLog

### 12.1 Сколько файлов бэкапов сделано и сколько лежит в хранилище
- В digest есть два раздела:
  - **Backup files & storage**: сводка по FULL, DIFF и LOG — сделано файлов за 24 часа, всего записано, сколько на хранилище, политика хранения, глубина retention, размер;
  - **Backup retention & inventory**: сетка по каждой базе, как на одобренном макете, плюс колонки Files и On storage.
- **LOG (RDS automated)** — точное число. Раз в сутки монитор перечитывает `rds_fn_list_tlog_backup_metadata`, и файл, который RDS всё ещё перечисляет, считается «на хранилище» (basis = `listed by RDS`).
- **FULL и DIFF (RDS native в S3, Ola на диск или URL)** — T-SQL не видит S3, поэтому число **оценочное** по **объявленной** вами политике хранения:
  ```sql
  -- для всех баз (дней, например правило lifecycle S3 или @CleanupTime у Ola)
  UPDATE OPS.mon.Setting SET setting_value = N'35' WHERE setting_name = 'backup_storage_retention_days';
  -- для одной базы
  UPDATE OPS.mon.DatabaseCheck SET storage_retention_days = 14 WHERE database_name = N'MioCore';
  ```
  Пока политика не объявлена, в колонке написано `not declared`.
- Статус **POLICY** означает, что объявленная политика хранения короче требуемой retention. Файлы будут удалены раньше, чем нужно. Появится WARNING-issue.
- Файлы считаются по `backupmediafamily`, поэтому striped-бэкап из четырёх файлов даёт 4 файла. Для Ola файлы считаются по количеству `DISK =` / `URL =` в команде.
```sql
EXEC OPS.mon.usp_ShowBackupRetention;   -- 1) сетка по базам, 2) итоги по типам (files made / on storage / policy), 3) тренд
```

### 12.2 Последний DBCC CHECKDB (теперь из трёх источников)
1. `DATABASEPROPERTYEX(db, 'LastGoodCheckDbTime')`. Работает на 2016 SP2 и 2019+, на 2017 возвращает NULL.
2. `DBCC DBINFO` → `dbi_dbccLastKnownGood`. Используется, если источник 1 пуст. На RDS обычно запрещён, ошибка перехватывается.
3. **Ola CommandLog**: последний `DBCC_CHECKDB` с `ErrorNumber = 0`.

Берётся самое свежее значение. В digest в ячейке CHECKDB видны возраст, дата, источник (`dbproperty` / `dbinfo` / `ola`) и длительность. Если последний запуск CHECKDB в Ola упал (например, ошибка 8939), ячейка красная с плашкой **LAST RUN FAILED**, и приходит CRITICAL alert.

### 12.3 Ola Hallengren CommandLog
- Таблица `dbo.CommandLog` находится автоматически: монитор ищет её во всех online-базах и в master раз в час. Можно указать базу явно:
  ```sql
  UPDATE OPS.mon.Setting SET setting_value = N'DBA' WHERE setting_name = 'ola_commandlog_database';
  ```
- Строки импортируются каждые 5 минут, инкрементально, с чтением READ UNCOMMITTED, чтобы не мешать Ola. Незавершённые команды перечитываются, пока не получат EndTime. При первом запуске загружается 35 дней (`ola_initial_load_days`).
- Ошибка в CommandLog **не всегда значит, что Ola упала**. Монитор различает три исхода:
  - **CORRUPTION FOUND** — CHECKDB **выполнился до конца и нашёл повреждения** (ошибки 25xx, 79xx, 89xx, 823–825). Проверка сработала, повреждена сама база: CRITICAL, нужен restore или repair. Такой запуск не считается «last known good».
  - **SKIPPED** — 1222 (lock timeout) или 1205 (deadlock victim). Команда не смогла получить блокировку, например REBUILD индекса. Это WARNING, в следующий запуск объект обработается снова.
  - **FAILED** — всё остальное: упал бэкап, CHECKDB не смог запуститься и т.п. Для BACKUP, DBCC и RESTORE это CRITICAL, для остального — WARNING.
- Каждая такая команда создаёт issue `OLAFAIL:...`. Проверку можно выключить галочкой **OLA_LOG** в `mon.ServerCheck`.
- В digest есть раздел **Ola Hallengren maintenance** по типам команд (сколько, упало, суммарное и самое долгое время, количество файлов) и таблица упавших команд.
```sql
EXEC OPS.mon.usp_ShowOlaLog;                   -- последние 24 ч
EXEC OPS.mon.usp_ShowOlaLog @Hours = 168, @Database = N'MioCore';
SELECT TOP 100 * FROM OPS.mon.OlaCommand ORDER BY start_utc DESC;
```
- Одна ошибка Ola обычно даёт два alert'а: `OLAFAIL` (что именно упало, объект и ошибка) и `JOBFAIL` (упала джоба Agent).
