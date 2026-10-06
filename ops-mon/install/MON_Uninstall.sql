/*
================================================================================
    MON  -  UNINSTALL   (removes the OPS.mon monitoring solution completely)
    Removes: SQL Agent jobs "MON - Engine" and "MON - Digest & Watchdog",
             every object in schema [mon] of database OPS, and the schema itself.
    Does NOT touch: OPS.monitor (rev 4), any other schema, Database Mail, Ola, msdb history.

    SAFETY: nothing happens unless you set @Confirm below to 'REMOVE MON'.
            Run once with @WhatIf = 1 to see the list of objects that would be dropped.
    TIP:    to keep the history, first back up OPS or export the mon.* tables you care about
            (Setting, DatabaseCheck, ServerCheck, DatabasePolicy, IssueMute, DatabaseConfigBaseline,
             JobPolicy are the configuration; everything else is collected data).
================================================================================
*/
USE [OPS];
GO
SET NOCOUNT ON;

DECLARE @Confirm varchar(20) = '';          /* <<< type REMOVE MON here to really uninstall */
DECLARE @WhatIf  bit         = 1;           /* 1 = only list what would be dropped */

IF @Confirm <> 'REMOVE MON' AND @WhatIf = 0
BEGIN
    RAISERROR(N'Set @Confirm = ''REMOVE MON'' to uninstall. Nothing was changed.', 16, 1);
    RETURN;
END;

DECLARE @drop TABLE (seq int IDENTITY(1,1), stmt nvarchar(max), what nvarchar(300));

/* 1. jobs */
INSERT @drop(stmt, what)
SELECT N'EXEC msdb.dbo.sp_delete_job @job_name = N''' + REPLACE(name, N'''', N'''''') + N''', @delete_unused_schedule = 1;',
       N'SQL Agent job ' + name
FROM msdb.dbo.sysjobs WHERE name IN (N'MON - Engine', N'MON - Digest & Watchdog');

/* 2. foreign keys inside mon (none by design, kept for safety) */
INSERT @drop(stmt, what)
SELECT N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) + N' DROP CONSTRAINT ' + QUOTENAME(f.name) + N';',
       N'FK ' + f.name
FROM sys.foreign_keys AS f JOIN sys.tables AS t ON t.object_id = f.parent_object_id
WHERE SCHEMA_NAME(t.schema_id) = N'mon';

/* 3. modules and tables, in dependency-safe order: triggers -> procedures -> views -> functions -> tables */
INSERT @drop(stmt, what)
SELECT N'DROP ' + CASE o.type WHEN 'TR' THEN N'TRIGGER ' WHEN 'P' THEN N'PROCEDURE ' WHEN 'V' THEN N'VIEW '
                              WHEN 'U' THEN N'TABLE ' ELSE N'FUNCTION ' END
       + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N';',
       o.type_desc + N' mon.' + o.name
FROM sys.objects AS o
WHERE SCHEMA_NAME(o.schema_id) = N'mon' AND o.type IN ('TR', 'P', 'V', 'FN', 'IF', 'TF', 'U')
ORDER BY CASE o.type WHEN 'TR' THEN 1 WHEN 'P' THEN 2 WHEN 'V' THEN 3 WHEN 'U' THEN 5 ELSE 4 END, o.name;

/* 4. types / sequences / synonyms (none by design) and the schema */
INSERT @drop(stmt, what)
SELECT N'DROP SEQUENCE mon.' + QUOTENAME(name) + N';', N'sequence ' + name FROM sys.sequences WHERE SCHEMA_NAME(schema_id) = N'mon';
INSERT @drop(stmt, what)
SELECT N'DROP SYNONYM mon.' + QUOTENAME(name) + N';', N'synonym ' + name FROM sys.synonyms WHERE SCHEMA_NAME(schema_id) = N'mon';
IF SCHEMA_ID(N'mon') IS NOT NULL
    INSERT @drop(stmt, what) VALUES (N'DROP SCHEMA mon;', N'schema mon');

IF @WhatIf = 1 OR @Confirm <> 'REMOVE MON'
BEGIN
    SELECT seq, what AS [Would drop], stmt AS [Statement] FROM @drop ORDER BY seq;
    PRINT N'WhatIf mode: nothing was changed. Set @WhatIf = 0 and @Confirm = ''REMOVE MON'' to uninstall.';
    RETURN;
END;

DECLARE @i int = 1, @n int = (SELECT MAX(seq) FROM @drop), @s nvarchar(max), @w nvarchar(300);
WHILE @i <= @n
BEGIN
    SELECT @s = stmt, @w = what FROM @drop WHERE seq = @i;
    BEGIN TRY
        EXEC sys.sp_executesql @s;
        PRINT N'Dropped ' + @w;
    END TRY
    BEGIN CATCH
        PRINT N'FAILED to drop ' + @w + N': ' + ERROR_MESSAGE();
    END CATCH;
    SET @i += 1;
END;

IF SCHEMA_ID(N'mon') IS NULL
    PRINT N'MON uninstalled: jobs removed, schema [mon] and all its objects dropped.';
ELSE
    PRINT N'Schema [mon] still exists - see FAILED lines above.';
GO
