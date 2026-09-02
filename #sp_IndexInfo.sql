/* ============================================================================
   #sp_IndexInfo  --  temporary stored procedure (lives in tempdb for your session)

   Set-based replacement for sp_helpindex12 / sp_SQLskills_ExposeColsInIndexLevels.
   One result set, one row per index (heap included), works on ANY table in ANY
   database on the instance, including temp tables and permanent tables in tempdb.

   Requires: SQL Server 2017+ (STRING_AGG, CONCAT_WS, CREATE OR ALTER).
   Permissions: VIEW DATABASE STATE in the target db (for size / usage / stats).
   Read-only. Nothing to clean up - the proc disappears when your session ends.

   Usage:
       EXEC #sp_IndexInfo 'dbo.Orders';                              /* current db      */
       EXEC #sp_IndexInfo 'AdventureWorks.Sales.SalesOrderDetail';   /* any db          */
       EXEC #sp_IndexInfo '#MyTemp';                                 /* temp table      */
       EXEC #sp_IndexInfo 'tempdb.dbo.StagingTable';                 /* perm in tempdb  */

   Output columns:
       table_name, index_id, index_name, index_type
       key_columns, included_columns, filter_definition
       columns_in_tree, columns_in_leaf      (physical layout incl. clustering key / UNIQUIFIER / RID)
       rows, partitions, reserved_mb, used_mb, data_compression, storage (filegroup / partition scheme)
       fill_factor, is_padded, allow_row_locks, allow_page_locks, ignore_dup_key
       user_seeks, user_scans, user_lookups, user_updates, last_user_read, last_user_update
       stats_updated, stats_rows_sampled, stats_sample_pct, stats_modifications, stats_no_recompute
       create_ddl                            (copy-paste script to recreate the index)
   ============================================================================ */
CREATE OR ALTER PROCEDURE #sp_IndexInfo
    @Table nvarchar(776)      /* [db.][schema.]table  or  #temptable */
AS
SET NOCOUNT ON;

DECLARE @db  sysname,
        @obj nvarchar(776),
        @sql nvarchar(max);

/* ---- resolve database + object name --------------------------------------- */
IF LEFT(LTRIM(@Table), 1) = N'#' OR PARSENAME(@Table, 1) LIKE N'#%'   /* '#t' or 'tempdb..#t' */
    SELECT @db = N'tempdb', @obj = ISNULL(PARSENAME(@Table, 1), LTRIM(RTRIM(@Table)));
ELSE
    SELECT @db  = ISNULL(PARSENAME(@Table, 3), DB_NAME()),
           @obj = ISNULL(QUOTENAME(PARSENAME(@Table, 2)) + N'.', N'') + QUOTENAME(PARSENAME(@Table, 1));

IF DB_ID(@db) IS NULL
BEGIN
    RAISERROR(N'Database [%s] not found.', 16, 1, @db);
    RETURN 1;
END;

/* ---- build the query; USE only when needed (keeps Azure SQL DB happy) ------ */
SET @sql = CASE WHEN @db <> DB_NAME() THEN N'USE ' + QUOTENAME(@db) + N'; ' ELSE N'' END + N'
DECLARE @oid int = OBJECT_ID(@obj);
IF @oid IS NULL
BEGIN
    RAISERROR(N''Object %s not found in database [%s].'', 16, 1, @obj, @db);
    RETURN;
END;

WITH ic AS
(   /* every column of every index on the table, pre-quoted */
    SELECT ic.index_id, ic.column_id, ic.key_ordinal, ic.partition_ordinal,
           ic.is_included_column,
           col      = CAST(QUOTENAME(c.name) AS nvarchar(max)),
           col_desc = CAST(QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN N'' DESC'' ELSE N'''' END AS nvarchar(max))
    FROM sys.index_columns AS ic
    JOIN sys.columns       AS c  ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE ic.object_id = @oid
),
cl AS
(   /* clustering key of a ROWSTORE clustered index (empty for heaps / CCI) */
    SELECT ic.column_id, ic.key_ordinal, ic.col
    FROM ic
    JOIN sys.indexes AS i ON i.object_id = @oid AND i.index_id = ic.index_id AND i.type = 1
    WHERE ic.index_id = 1 AND ic.key_ordinal > 0
),
tbl AS
(
    SELECT has_cl    = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = @oid AND index_id = 1 AND type = 1) THEN 1 ELSE 0 END,
           cl_unique = ISNULL((SELECT is_unique FROM sys.indexes WHERE object_id = @oid AND index_id = 1 AND type = 1), 0)
),
ps AS
(   /* size / rows / compression rolled up over partitions */
    SELECT p.index_id,
           partitions  = COUNT(*),
           [rows]      = SUM(s.row_count),
           reserved_mb = CAST(SUM(s.reserved_page_count) / 128.0 AS decimal(18,2)),
           used_mb     = CAST(SUM(s.used_page_count)     / 128.0 AS decimal(18,2)),
           compression = CASE WHEN MIN(p.data_compression_desc) = MAX(p.data_compression_desc)
                              THEN MIN(p.data_compression_desc)
                              ELSE N''MIXED ('' + MIN(p.data_compression_desc) + N''..'' + MAX(p.data_compression_desc) + N'')'' END
    FROM sys.partitions              AS p
    JOIN sys.dm_db_partition_stats   AS s ON s.partition_id = p.partition_id
    WHERE p.object_id = @oid
    GROUP BY p.index_id
)
SELECT
    table_name       = CASE WHEN @obj LIKE N''#%'' THEN N''tempdb..'' + @obj ELSE o.tn3 END,
    i.index_id,
    index_name       = ISNULL(i.name, N''<HEAP>''),
    index_type       = i.type_desc
                     + CASE WHEN i.is_primary_key = 1       THEN N'', PRIMARY KEY''
                            WHEN i.is_unique_constraint = 1 THEN N'', UNIQUE CONSTRAINT''
                            WHEN i.is_unique = 1            THEN N'', UNIQUE'' ELSE N'''' END
                     + CASE WHEN i.has_filter = 1      THEN N'', FILTERED''     ELSE N'''' END
                     + CASE WHEN i.is_disabled = 1     THEN N'', DISABLED''     ELSE N'''' END
                     + CASE WHEN i.is_hypothetical = 1 THEN N'', HYPOTHETICAL'' ELSE N'''' END,
    key_columns      = CASE WHEN i.type IN (5,6) THEN N''n/a (columnstore)'' ELSE k.list END,
    included_columns = CASE WHEN i.type = 6 THEN allc.list ELSE inc.list END,
    filter_definition = i.filter_definition,

    /* ---- physical layout: what is in the B-tree vs. the leaf level ---------- */
    columns_in_tree  =
        CASE
          WHEN i.type = 1 THEN CONCAT_WS(N'', '', k.list, CASE WHEN i.is_unique = 0 THEN N''UNIQUIFIER'' END)
          WHEN i.type = 2 AND tbl.has_cl = 1 AND i.is_unique = 0
               THEN CONCAT_WS(N'', '', k.list, clx.list, CASE WHEN tbl.cl_unique = 0 THEN N''UNIQUIFIER'' END)
          WHEN i.type = 2 AND tbl.has_cl = 1 AND i.is_unique = 1
               THEN k.list
          WHEN i.type = 2 AND tbl.has_cl = 0 AND i.is_unique = 0
               THEN CONCAT_WS(N'', '', k.list, N''RID'')
          WHEN i.type = 2 AND tbl.has_cl = 0 AND i.is_unique = 1
               THEN k.list
          ELSE N''n/a''
        END,
    columns_in_leaf  =
        CASE
          WHEN i.type = 0 THEN N''All columns (heap = data row)''
          WHEN i.type = 1 THEN N''All columns (leaf = data row)'' + CASE WHEN i.is_unique = 0 THEN N'' + UNIQUIFIER'' ELSE N'''' END
          WHEN i.type = 5 THEN N''All columns (columnstore segments)''
          WHEN i.type = 6 THEN N''Columnstore segments: '' + allc.list
          WHEN i.type = 2 AND tbl.has_cl = 1 AND i.is_unique = 0
               THEN CONCAT_WS(N'', '', k.list, clx.list, CASE WHEN tbl.cl_unique = 0 THEN N''UNIQUIFIER'' END, incx.list)
          WHEN i.type = 2 AND tbl.has_cl = 1 AND i.is_unique = 1
               THEN CONCAT_WS(N'', '', k.list, inc.list, clx2.list, CASE WHEN tbl.cl_unique = 0 THEN N''UNIQUIFIER'' END)
          WHEN i.type = 2 AND tbl.has_cl = 0
               THEN CONCAT_WS(N'', '', k.list, N''RID'', inc.list)
          ELSE N''n/a''
        END,

    /* ---- size & storage ------------------------------------------------------ */
    ps.[rows], ps.partitions, ps.reserved_mb, ps.used_mb,
    data_compression = ps.compression,
    storage          = CASE WHEN ds.type = N''PS'' THEN N''PS: '' + ds.name + N'' ('' + pc.col + N'')''
                            WHEN ds.type = N''FX'' THEN N''MEMORY_OPTIMIZED: '' + ds.name
                            ELSE ds.name END,
    fill_factor      = CASE WHEN i.fill_factor = 0 THEN 100 ELSE i.fill_factor END,
    i.is_padded, i.allow_row_locks, i.allow_page_locks, i.ignore_dup_key,

    /* ---- usage since last restart / rebuild --------------------------------- */
    user_seeks   = ISNULL(us.user_seeks, 0),
    user_scans   = ISNULL(us.user_scans, 0),
    user_lookups = ISNULL(us.user_lookups, 0),
    user_updates = ISNULL(us.user_updates, 0),
    last_user_read   = (SELECT MAX(v) FROM (VALUES (us.last_user_seek), (us.last_user_scan), (us.last_user_lookup)) AS x(v)),
    last_user_update = us.last_user_update,

    /* ---- statistics ---------------------------------------------------------- */
    stats_updated       = sp.last_updated,
    stats_rows_sampled  = sp.rows_sampled,
    stats_sample_pct    = CAST(sp.rows_sampled * 100.0 / NULLIF(sp.[rows], 0) AS decimal(5,1)),
    stats_modifications = sp.modification_counter,
    stats_no_recompute  = st.no_recompute,

    /* ---- recreate script ----------------------------------------------------- */
    create_ddl =
        CASE
          WHEN i.type IN (1,2) AND (i.is_primary_key = 1 OR i.is_unique_constraint = 1)
               THEN N''ALTER TABLE '' + o.tn + N'' ADD CONSTRAINT '' + QUOTENAME(i.name)
                  + CASE WHEN i.is_primary_key = 1 THEN N'' PRIMARY KEY '' ELSE N'' UNIQUE '' END
                  + i.type_desc + N'' ('' + k.list + N'')'' + o.with_rs + o.on_ds + N'';''
          WHEN i.type IN (1,2)
               THEN N''CREATE '' + CASE WHEN i.is_unique = 1 THEN N''UNIQUE '' ELSE N'''' END + i.type_desc
                  + N'' INDEX '' + QUOTENAME(i.name) + N'' ON '' + o.tn + N'' ('' + k.list + N'')''
                  + ISNULL(N'' INCLUDE ('' + inc.list + N'')'', N'''')
                  + ISNULL(N'' WHERE '' + i.filter_definition, N'''')
                  + o.with_rs + o.on_ds + N'';''
          WHEN i.type = 5
               THEN N''CREATE CLUSTERED COLUMNSTORE INDEX '' + QUOTENAME(i.name) + N'' ON '' + o.tn + o.with_cs + o.on_ds + N'';''
          WHEN i.type = 6
               THEN N''CREATE NONCLUSTERED COLUMNSTORE INDEX '' + QUOTENAME(i.name) + N'' ON '' + o.tn + N'' ('' + allc.list + N'')''
                  + ISNULL(N'' WHERE '' + i.filter_definition, N'''') + o.with_cs + o.on_ds + N'';''
          ELSE NULL
        END
FROM sys.indexes AS i
CROSS JOIN tbl
/* key columns in key order */
OUTER APPLY (SELECT list = STRING_AGG(col_desc, N'', '') WITHIN GROUP (ORDER BY key_ordinal)
             FROM ic WHERE ic.index_id = i.index_id AND ic.key_ordinal > 0) AS k
/* included columns */
OUTER APPLY (SELECT list = STRING_AGG(col, N'', '') WITHIN GROUP (ORDER BY column_id)
             FROM ic WHERE ic.index_id = i.index_id AND ic.is_included_column = 1) AS inc
/* all columns (columnstore) */
OUTER APPLY (SELECT list = STRING_AGG(col, N'', '') WITHIN GROUP (ORDER BY column_id)
             FROM ic WHERE ic.index_id = i.index_id) AS allc
/* clustering-key columns that are not already index keys */
OUTER APPLY (SELECT list = STRING_AGG(cl.col, N'', '') WITHIN GROUP (ORDER BY cl.key_ordinal)
             FROM cl WHERE NOT EXISTS (SELECT 1 FROM ic WHERE ic.index_id = i.index_id AND ic.key_ordinal > 0 AND ic.column_id = cl.column_id)) AS clx
/* clustering-key columns that are neither keys nor includes */
OUTER APPLY (SELECT list = STRING_AGG(cl.col, N'', '') WITHIN GROUP (ORDER BY cl.key_ordinal)
             FROM cl WHERE NOT EXISTS (SELECT 1 FROM ic WHERE ic.index_id = i.index_id AND ic.column_id = cl.column_id)) AS clx2
/* included columns that are not part of the clustering key (already in the tree) */
OUTER APPLY (SELECT list = STRING_AGG(ic.col, N'', '') WITHIN GROUP (ORDER BY ic.column_id)
             FROM ic WHERE ic.index_id = i.index_id AND ic.is_included_column = 1
                      AND NOT EXISTS (SELECT 1 FROM cl WHERE cl.column_id = ic.column_id)) AS incx
/* partitioning column */
OUTER APPLY (SELECT TOP (1) col FROM ic WHERE ic.index_id = i.index_id AND ic.partition_ordinal > 0) AS pc
LEFT JOIN ps                            ON ps.index_id = i.index_id
LEFT JOIN sys.data_spaces AS ds         ON ds.data_space_id = i.data_space_id
LEFT JOIN sys.stats       AS st         ON st.object_id = i.object_id AND st.stats_id = i.index_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
       ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = i.index_id
OUTER APPLY sys.dm_db_stats_properties(i.object_id, i.index_id) AS sp
/* DDL fragments */
OUTER APPLY (SELECT
    tn3     = QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(OBJECT_SCHEMA_NAME(@oid)) + N''.'' + QUOTENAME(OBJECT_NAME(@oid)),
    tn      = CASE WHEN @obj LIKE N''#%'' THEN @obj ELSE QUOTENAME(OBJECT_SCHEMA_NAME(@oid)) + N''.'' + QUOTENAME(OBJECT_NAME(@oid)) END,
    with_rs = N'' WITH (FILLFACTOR = '' + CAST(CASE WHEN i.fill_factor = 0 THEN 100 ELSE i.fill_factor END AS nvarchar(3))
            + N'', PAD_INDEX = '' + CASE WHEN i.is_padded = 1 THEN N''ON'' ELSE N''OFF'' END
            + CASE WHEN ps.compression IN (N''ROW'', N''PAGE'') THEN N'', DATA_COMPRESSION = '' + ps.compression ELSE N'''' END
            + N'', ONLINE = ON, SORT_IN_TEMPDB = ON)'',
    with_cs = CASE WHEN ps.compression = N''COLUMNSTORE_ARCHIVE'' THEN N'' WITH (DATA_COMPRESSION = COLUMNSTORE_ARCHIVE)'' ELSE N'''' END,
    on_ds   = CASE WHEN ds.type = N''PS'' THEN N'' ON '' + QUOTENAME(ds.name) + N''('' + pc.col + N'')''
                   WHEN ds.type = N''FG'' THEN N'' ON '' + QUOTENAME(ds.name)
                   ELSE N'''' END) AS o
WHERE i.object_id = @oid
ORDER BY i.index_id;';

EXEC sys.sp_executesql @sql, N'@obj nvarchar(776), @db sysname', @obj, @db;
GO
