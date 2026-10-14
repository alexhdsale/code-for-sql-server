/* JSON array - works on 2016+, keeps one stable query text */
SELECT  cpv.custom_property_definition_id, cpv.entity_id, cpv.property_value
FROM    custom_property_value AS cpv
JOIN    OPENJSON(@ids) WITH (id int '$') AS j
          ON j.id = cpv.custom_property_definition_id;
/* @ids = N'[12,45,78,...]' */


/* ============================================================
   Generate plan guides: OPTION (RECOMPILE) for every captured
   variant of the custom_property_value IN (@P1..@Pn) statement
   ============================================================ */
USE assetmanagement_v2;
GO
SET NOCOUNT ON;

DECLARE @query_id bigint, @txt nvarchar(max), @pos int,
        @params nvarchar(max), @stmt nvarchar(max), @name sysname;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
SELECT  q.query_id, qt.query_sql_text
FROM    sys.query_store_query q
JOIN    sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
WHERE   qt.query_sql_text LIKE N'(@P1 %'
  AND   qt.query_sql_text LIKE N'%FROM custom_property_value%custom_property_definition_id IN (@P1%'
  AND   q.object_id = 0;                       /* ad hoc / prepared only */

OPEN c; FETCH NEXT FROM c INTO @query_id, @txt;
WHILE @@FETCH_STATUS = 0
BEGIN
    /* QS stores prepared text as "(<params>)<statement>" */
    SET @pos    = CHARINDEX(N')SELECT', @txt);
    SET @params = SUBSTRING(@txt, 2, @pos - 2);
    SET @stmt   = SUBSTRING(@txt, @pos + 1, LEN(@txt));
    SET @name   = N'PG_cpv_in_recompile_' + CAST(@query_id AS nvarchar(20));

    IF NOT EXISTS (SELECT 1 FROM sys.plan_guides WHERE name = @name)
    BEGIN
        EXEC sys.sp_create_plan_guide
             @name   = @name,
             @stmt   = @stmt,
             @type   = N'SQL',
             @module_or_batch = NULL,
             @params = @params,
             @hints  = N'OPTION (RECOMPILE)';
        PRINT N'Created ' + @name;
    END
    FETCH NEXT FROM c INTO @query_id, @txt;
END
CLOSE c; DEALLOCATE c;

/* Verify */
SELECT name, is_disabled, LEFT(query_text, 80) AS stmt_start, parameters
FROM   sys.plan_guides
WHERE  name LIKE N'PG_cpv_in_recompile_%';

/* UNDO (drop all of them):
DECLARE @n sysname;
DECLARE d CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.plan_guides WHERE name LIKE N'PG_cpv_in_recompile_%';
OPEN d; FETCH NEXT FROM d INTO @n;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sys.sp_control_plan_guide @operation = N'DROP', @name = @n;
    FETCH NEXT FROM d INTO @n;
END
CLOSE d; DEALLOCATE d;
*/


EXEC sys.sp_query_store_set_hints @query_id = 5492, @query_hints = N'OPTION (RECOMPILE)';
/* UNDO: EXEC sys.sp_query_store_clear_hints @query_id = 5492; */


Nothing is broken: the plan is a dynamic seek, and it looks odd because of how the parameters are typed.

Why it has this shape

Parameters in an IN list: SQL Server can’t deduplicate @P1…@P45 at compile time, since two of them may hold the same value at runtime. So it builds the list at runtime: one Constant Scan per parameter → Concatenation → Sort → Merge Interval (collapses duplicates and overlaps) → Nested Loops → one Index Seek per distinct value. That gives 45 branches for 45 parameters.
Type mismatch: each parameter is declared with its own length (varchar(52), varchar(50), varchar(48)…), which doesn’t match the column’s declared type. That is why every branch has its own Compute Scalar: it computes the seek range through a conversion (GetRangeWithMismatchedTypes in the operator properties).

The seek itself is efficient (Index Seek at 100%, no lookup), so the shape is cosmetic.

The real problem this screenshot shows

The driver sizes each varchar to the length of the value. The parameter declaration is part of the cache key, so every different combination of string lengths counts as a different query. That means:

a fresh compile of a 45-branch plan on almost every call;
plan cache bloat from single-use plans;
hundreds of query IDs in Query Store for one logical statement, which is why you saw many near-identical bars.

You can confirm it with this:

sql
SELECT COUNT(*) AS cached_plans,
       SUM(CASE WHEN cp.usecounts = 1 THEN 1 ELSE 0 END) AS single_use,
       SUM(CAST(cp.size_in_bytes AS bigint))/1048576 AS mb
FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) st
WHERE st.text LIKE '%FROM custom_property_value%custom_property_definition_id IN (@P1%';

Fix

App side (the proper fix): bind the parameters with a fixed type matching the column, e.g. varchar(255) or whatever the column is. The aliasing style looks like SQLAlchemy; if it is SQLAlchemy with pyodbc, that means use_setinputsizes=True (default in 2.0) with a proper String(n) column type. Better still, pass the list as a TVP or JSON and join to it, which gives one plan regardless of list length.
Server side (mitigation only): enable optimize for ad hoc workloads to cut the cache memory used by single-use plans. It doesn’t remove the compiles.
Investigating why the index metadata doesn't match the query plan.

This explains the scan: in this database the table has only the clustered primary key on custom_property_value_id. With no index on custom_property_definition_id, every lookup reads the whole table, which is the Clustered Index Scan + Filter you saw in plan 255.

It conflicts with your previous screenshot, though, which showed an Index Seek on a nonclustered index. So one of these is true:

the seek plan came from a different database or server (you have AssetManagement, assetmanagement_v2 and AssetManagement-2021-09);
the index existed and was dropped;
sp_help was run in a different database than the plan.

This shows where the index exists:

sql
EXEC sp_MSforeachdb N'USE [?];
IF OBJECT_ID(''dbo.custom_property_value'') IS NOT NULL
SELECT DB_NAME() AS db, i.name, i.type_desc
FROM sys.indexes i WHERE i.object_id = OBJECT_ID(''dbo.custom_property_value'');';

Fix for the database that lacks it:

sql
CREATE NONCLUSTERED INDEX IX_custom_property_value_definition_entity
ON dbo.custom_property_value (custom_property_definition_id, entity_id)
INCLUDE (property_value)
WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);   -- ONLINE needs Enterprise edition
Size: property_value is varchar(max), so including it makes this index nearly a second copy of the table. Check the table size first (sp_spaceused 'dbo.custom_property_value'). If space is tight, drop the INCLUDE and accept key lookups, though for long IN lists the optimizer may then go back to scanning.
Uniqueness: if (custom_property_definition_id, entity_id) is unique by design, declare the index UNIQUE. It gives the optimizer better estimates.

Two other things sp_help shows:

Type mismatch confirmed: the column is varchar(255) and the parameters arrive as varchar(30…80). Same type family, different length, which is what produces the per-parameter Compute Scalars. The app should bind them all as varchar(255), which also stops the one-plan-per-length-combination problem.
Wide clustering key: the clustered PK is a varchar(255), and it is carried in every nonclustered index row. It isn’t worth changing now, but it makes the new index larger than you’d expect.


App side (the proper fix): bind the parameters with a fixed type matching the column, e.g. varchar(255) or whatever the column is. The aliasing style looks like SQLAlchemy; if it is SQLAlchemy with pyodbc, that means use_setinputsizes=True (default in 2.0) with a proper String(n) column type. Better still, pass the list as a TVP or JSON and join to it, which gives one plan regardless of list length.
Server side (mitigation only): enable optimize for ad hoc workloads to cut the cache memory used by single-use plans. It doesn’t remove the compiles.
