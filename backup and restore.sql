EXECUTE dbo.DatabaseBackup
    @Databases = 'BDBAudit', @Directory = 'b:\mssql\backup\',
    @BackupType = 'FULL', @CopyOnly = 'Y',
    @Compress = 'Y', @CheckSum = 'Y', 
    @NumberOfFiles = 4,
    @MaxTransferSize = 4194304, @BufferCount = 100,
    @LogToTable = 'Y', @Execute = 'Y',
    @CompressionAlgorithm = 'zstd',
    @CompressionLevel = 'high' --51 min, 44gb(4 files)
  
exec [dbo].[sp_DatabaseRestore]
    @Database = 'BDBPayrollLive', 
    @RestoreDatabaseName = 'BDBPayrollLive', 
    @BackupPathLog = 'b:\mssql\backup\ag1\BDBPayrollLive\LOG\', 
    @BackupPathDiff = 'b:\mssql\backup\ag1\BDBPayrollLive\diff\', 
    @BackupPathFull = 'b:\mssql\backup\ag1\BDBPayrollLive\full\', 
    @MoveFiles = 1,
    @MoveDataDrive = 'd:\mssql\data\',
    @MoveLogDrive = 'l:\mssql\log\',
    @ContinueLogs = 0,
    @Execute  = 'Y',
       @RestoreDiff = 1,
       @ExistingDBAction = 1,          /* SINGLE_USER WITH ROLLBACK IMMEDIATE before the RESTORE */
     @BufferCount = 64, @MaxTransferSize = 4194304


    
    exec [dbo].[sp_DatabaseRestore]
    @Database            = 'BDBPayrollLive',
    @RestoreDatabaseName = 'BDBPayrollLive',
    @BackupPathLog       = 'b:\mssql\backup\ag1\BDBPayrollLive\LOG\',
    @ContinueLogs        = 1,
    @RunRecovery         = 0,     -- stay in RESTORING so you can run this again
    @Execute             = 'Y';
-----------------------------------------------------

exec [dbo].[sp_DatabaseRestore]
    @Database = 'BDBAudit', 
    @RestoreDatabaseName = 'BDBAudit', 
    @BackupPathLog = 'b:\mssql\backup\ag2\BDBAudit\LOG\', 
    @BackupPathDiff = 'b:\mssql\backup\ag2\BDBAudit\diff\', 
    @BackupPathFull = 'b:\mssql\backup\ag2\BDBAudit\full\', 
    @MoveFiles = 1,
    @MoveDataDrive = 'd:\mssql\data\',
    @MoveLogDrive = 'l:\mssql\log\',
    @ContinueLogs = 0,
    @Execute  = 'Y',
      @RestoreDiff = 1,
      @ExistingDBAction = 1,          /* SINGLE_USER WITH ROLLBACK IMMEDIATE before the RESTORE */
      @BufferCount = 64, @MaxTransferSize = 4194304


    
    exec [dbo].[sp_DatabaseRestore]
    @Database            = 'BDBAudit',
    @RestoreDatabaseName = 'BDBAudit',
    @BackupPathLog       = 'b:\mssql\backup\ag2\BDBAudit\LOG\',
    @ContinueLogs        = 1,
    @RunRecovery         = 0,     -- stay in RESTORING so you can run this again
    @Execute             = 'Y';


----------------------------------------------------
  
EXEC dbo.sp_DatabaseRestore
     @Database                = N'BDBPayrollLive',
     @RestoreDatabaseName     = N'BDBPayrollLive_check',
    @BackupPathLog = 'b:\mssql\backup\ag1\BDBPayrollLive\LOG\', 
    @BackupPathDiff = 'b:\mssql\backup\ag1\BDBPayrollLive\diff\', 
    @BackupPathFull = 'b:\mssql\backup\ag1\BDBPayrollLive\full\', 
    @MoveFiles = 1,
    @MoveDataDrive = 'f:\mssql\data\',
    @MoveLogDrive = 'l:\mssql\log\',

     @RestoreDiff             = 1,
     @ContinueLogs            = 0,
     @RunRecovery             = 1,
     @ForceSimpleRecovery     = 1,      /* replaces my manual ALTER DATABASE */
     @ExistingDBAction        = 3,
     @FixOrphanUsers          = 1,      /* only worth it if someone will log in to the copy */
     @DatabaseOwner           = N'sa',
     @BufferCount             = 100,
     @MaxTransferSize         = 4194304,
     @SimpleFolderEnumeration = 1,
     @RunCheckDB              = 0,      /* deliberately: see below */
     @TestRestore             = 0,
     @Execute                 = 'Y';

/* CHECKDB with the two knobs sp_DatabaseRestore's @RunCheckDB doesn't pass through */
EXEC dbo.DatabaseIntegrityCheck
     @Databases   = N'BDBPayrollLive_check',
     @CheckCommands = 'CHECKDB',
     @DataPurity  = 'Y',
     @MaxDOP      = 8,
     @LogToTable  = 'Y';
