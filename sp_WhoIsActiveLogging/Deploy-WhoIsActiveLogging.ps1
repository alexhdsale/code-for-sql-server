<#
.SYNOPSIS
    Deploys (or removes) sp_WhoIsActive + sp_WhoIsActive Logging on one or many SQL Server instances.

.DESCRIPTION
    Wrapper around Install_sp_WhoIsActiveLogging.sql / Uninstall_sp_WhoIsActiveLogging.sql.
    For each instance it:
      1. checks the target database exists (optionally creates it with -CreateDatabase),
      2. writes a temporary copy of the SQL script with the USE line and the option values
         from the parameters below swapped in,
      3. runs it with sqlcmd in a single session (-b: stop on first error),
      4. writes a log per instance to .\logs and prints a summary.
    Exit code = number of instances that failed (0 = all good).

    Requires sqlcmd (ODBC sqlcmd 15+ or go-sqlcmd):  winget install sqlcmd
    Works in Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER SqlInstance
    One or more instances, e.g. SQL01, SQL02\INST1, "sql03.domain.com,1433". Accepts pipeline input.
    With powershell.exe -File, pass several as one string separated by ';':  -SqlInstance "SQL01;SQL02\INST1".

.PARAMETER InstanceListFile
    Text file with one instance per line (blank lines and lines starting with # are ignored).

.PARAMETER Action
    Install (default) or Uninstall.

.PARAMETER Database
    Utility database to deploy into / remove from. Default: Utility.

.PARAMETER CreateDatabase
    Install only: create the database (default settings, SIMPLE recovery) if it does not exist.

.PARAMETER SqlCredential
    SQL login. Omit for Windows authentication. The password is passed to sqlcmd via the
    SQLCMDPASSWORD environment variable, never on the command line.

.PARAMETER TrustServerCertificate
    Adds sqlcmd -C. Needed with ODBC sqlcmd 18+ / go-sqlcmd when the server uses a self-signed certificate.

.PARAMETER WhatIf
    Install: only shows what would be done. Uninstall: runs the uninstall script in its own
    WhatIf mode, which connects and lists every object/job it would remove without changing anything.

.EXAMPLE
    .\Deploy-WhoIsActiveLogging.ps1 -SqlInstance SQL01

.EXAMPLE
    .\Deploy-WhoIsActiveLogging.ps1 -InstanceListFile .\servers.txt -Database DBA -RetentionDays 14 -DataCompression PAGE -CreateDatabase

.EXAMPLE
    .\Deploy-WhoIsActiveLogging.ps1 -SqlInstance SQL01,SQL02 -Action Uninstall -WhatIf

.EXAMPLE
    .\Deploy-WhoIsActiveLogging.ps1 -SqlInstance SQL01 -Action Uninstall -KeepDailyTables
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param
(
    [Parameter(ValueFromPipeline = $true)]
    [string[]] $SqlInstance,

    [string] $InstanceListFile,

    [ValidateSet('Install', 'Uninstall')]
    [string] $Action = 'Install',

    [ValidateNotNullOrEmpty()]
    [string] $Database = 'Utility',

    [switch] $CreateDatabase,

    [System.Management.Automation.PSCredential] $SqlCredential,

    [switch] $TrustServerCertificate,

    # ---- Install options (map to #wia_config in the install script) ----
    [ValidateRange(1, 3650)]
    [int] $RetentionDays = 10,

    [ValidateSet('NONE', 'ROW', 'PAGE')]
    [string] $DataCompression = 'NONE',

    [ValidateRange(1, 59)]
    [int] $ScheduleEveryMinutes = 1,

    [string] $JobName = 'Log sp_WhoIsActive To A Daily Table',

    [string] $JobOwner,                 # empty = login with SID 0x01 (sa)

    [switch] $JobDisabled,

    [switch] $NoClusteredIndex,

    [switch] $SkipWhoIsActive,          # do not install/upgrade dbo.sp_WhoIsActive

    [switch] $KeepExistingJob,          # do not replace an existing job

    [switch] $NoFirstCollection,

    # ---- Uninstall options (map to #wia_uninstall in the uninstall script) ----
    [switch] $KeepDailyTables,

    [switch] $KeepWhoIsActive,

    [switch] $KeepJob,

    # ---- Misc ----
    [string] $LogPath = (Join-Path $PSScriptRoot 'logs'),

    [ValidateRange(0, 65535)]
    [int] $QueryTimeoutSeconds = 0      # 0 = no timeout
)

begin
{
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'

    $instances = New-Object System.Collections.Generic.List[string]

    function ConvertTo-SqlLiteral
    {
        param ($Value)
        if ($null -eq $Value -or ($Value -is [string] -and $Value -eq '')) { return 'NULL' }
        if ($Value -is [bool])   { if ($Value) { return '1' } else { return '0' } }
        if ($Value -is [int])    { return [string]$Value }
        return "N'" + ([string]$Value).Replace("'", "''") + "'"
    }

    # Replaces the value on a config line such as:   10,    /* RetentionDays        */
    function Set-ConfigValue
    {
        param ([string] $Text, [string] $Name, $Value)
        $pattern = '(?m)^(?<indent>[ \t]*)(?<value>[^/\r\n]+?)(?<comma>,?)(?<pad>[ \t]*/\*[ \t]*' +
                   [regex]::Escape($Name) + '[ \t]*\*/)'
        $found = [regex]::Matches($Text, $pattern)
        if ($found.Count -ne 1)
        {
            throw "Config line for '$Name' found $($found.Count) times in the SQL script (expected 1)."
        }
        $literal = ConvertTo-SqlLiteral $Value
        return [regex]::Replace($Text, $pattern, {
            param ($m)
            $m.Groups['indent'].Value + $literal + $m.Groups['comma'].Value + $m.Groups['pad'].Value
        })
    }

    function Set-TargetDatabase
    {
        param ([string] $Text, [string] $Name)
        $pattern = '(?m)^USE \[Utility\];'
        if ([regex]::Matches($Text, $pattern).Count -ne 1)
        {
            throw "Expected exactly one 'USE [Utility];' line in the SQL script."
        }
        $quoted = '[' + $Name.Replace(']', ']]') + ']'
        return [regex]::Replace($Text, $pattern, { param ($m) "USE $quoted;" })
    }

    function Invoke-Sqlcmd2
    {
        # Runs sqlcmd; returns @{ ExitCode; Output }
        param ([string] $Instance, [string[]] $Arguments)

        $common = @('-S', $Instance, '-d', 'master', '-b', '-I', '-r', '1', '-W')
        if ($QueryTimeoutSeconds -gt 0) { $common += @('-t', [string]$QueryTimeoutSeconds) }
        if ($TrustServerCertificate)    { $common += '-C' }

        $oldPwd = $env:SQLCMDPASSWORD
        # Windows PowerShell 5.1 turns native stderr (2>&1) into a terminating error under 'Stop'
        $ErrorActionPreference = 'Continue'
        try
        {
            if ($SqlCredential)
            {
                $common += @('-U', $SqlCredential.UserName)
                $env:SQLCMDPASSWORD = $SqlCredential.GetNetworkCredential().Password
            }
            else
            {
                $common += '-E'
            }

            $output = & $script:sqlcmd @common @Arguments 2>&1 | ForEach-Object { [string]$_ }
            return @{ ExitCode = $LASTEXITCODE; Output = @($output) }
        }
        finally
        {
            $env:SQLCMDPASSWORD = $oldPwd
        }
    }
}

process
{
    # ';' also separates instances (handy for powershell.exe -File / SQL Agent / Task Scheduler,
    # where an array cannot be passed). ',' is NOT a separator: it is part of "server,port".
    foreach ($i in @($SqlInstance))
    {
        if ($i)
        {
            foreach ($part in $i.Split(';')) { if ($part.Trim()) { $instances.Add($part.Trim()) } }
        }
    }
}

end
{
    if ($InstanceListFile)
    {
        Get-Content -LiteralPath $InstanceListFile |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            ForEach-Object { $instances.Add($_) }
    }

    $targets = @($instances | Select-Object -Unique)
    if ($targets.Count -eq 0)
    {
        throw 'No instances given. Use -SqlInstance and/or -InstanceListFile.'
    }

    $cmd = Get-Command sqlcmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd)
    {
        throw 'sqlcmd was not found in PATH. Install it with:  winget install sqlcmd   (or the SQL Server ODBC sqlcmd utilities).'
    }
    $script:sqlcmd = $cmd.Source

    # ---------- prepare the SQL script once ----------
    if ($Action -eq 'Install')
    {
        $source = Join-Path $PSScriptRoot 'Install_sp_WhoIsActiveLogging.sql'
    }
    else
    {
        $source = Join-Path $PSScriptRoot 'Uninstall_sp_WhoIsActiveLogging.sql'
    }
    if (-not (Test-Path -LiteralPath $source)) { throw "SQL script not found: $source" }

    $sql = [System.IO.File]::ReadAllText($source)
    $sql = Set-TargetDatabase -Text $sql -Name $Database

    $serverWhatIf = $false
    if ($Action -eq 'Install')
    {
        $sql = Set-ConfigValue $sql 'InstallWhoIsActive'   (-not $SkipWhoIsActive.IsPresent)
        $sql = Set-ConfigValue $sql 'RetentionDays'        $RetentionDays
        $sql = Set-ConfigValue $sql 'DataCompression'      $DataCompression
        $sql = Set-ConfigValue $sql 'CreateClusteredIndex' (-not $NoClusteredIndex.IsPresent)
        $sql = Set-ConfigValue $sql 'JobName'              $JobName
        $sql = Set-ConfigValue $sql 'JobOwner'             $JobOwner
        $sql = Set-ConfigValue $sql 'JobEnabled'           (-not $JobDisabled.IsPresent)
        $sql = Set-ConfigValue $sql 'ScheduleEveryMinutes' $ScheduleEveryMinutes
        $sql = Set-ConfigValue $sql 'ReplaceExistingJob'   (-not $KeepExistingJob.IsPresent)
        $sql = Set-ConfigValue $sql 'RunFirstCollection'   (-not $NoFirstCollection.IsPresent)
    }
    else
    {
        # Uninstall -WhatIf = let the script connect and list what it would remove
        $serverWhatIf = [bool]$WhatIfPreference
        $sql = Set-ConfigValue $sql 'WhatIf'            $serverWhatIf
        $sql = Set-ConfigValue $sql 'JobName'           $JobName
        $sql = Set-ConfigValue $sql 'RemoveJob'         (-not $KeepJob.IsPresent)
        $sql = Set-ConfigValue $sql 'KeepDailyTables'   $KeepDailyTables.IsPresent
        $sql = Set-ConfigValue $sql 'RemoveWhoIsActive' (-not $KeepWhoIsActive.IsPresent)
    }

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("wia_{0}_{1}.sql" -f $Action, [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($tempFile, $sql, (New-Object System.Text.UTF8Encoding($true)))

    if (-not (Test-Path -LiteralPath $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force -WhatIf:$false | Out-Null }

    $results = New-Object System.Collections.Generic.List[object]
    $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dbLit   = "N'" + $Database.Replace("'", "''") + "'"
    $dbQuote = '[' + $Database.Replace(']', ']]') + ']'

    try
    {
        foreach ($instance in $targets)
        {
            $logFile = Join-Path $LogPath ("{0}_{1}_{2}.log" -f $stamp, ($instance -replace '[\\/:*?"<>|,]', '_'), $Action)
            $status  = 'OK'
            $detail  = ''
            $sw      = [System.Diagnostics.Stopwatch]::StartNew()

            Write-Host ''
            Write-Host ("==== {0} on {1} (database {2}){3}" -f $Action, $instance, $dbQuote, $(if ($WhatIfPreference) { ' [WhatIf]' } else { '' })) -ForegroundColor Cyan

            try
            {
                # 1. connectivity + database check
                $check = Invoke-Sqlcmd2 -Instance $instance -Arguments @('-h', '-1', '-Q',
                    "SET NOCOUNT ON; SELECT CASE WHEN DB_ID($dbLit) IS NULL THEN 'MISSING' ELSE 'EXISTS' END + '|' + CONVERT(varchar(10), IS_SRVROLEMEMBER('sysadmin')) + '|' + CONVERT(varchar(128), SERVERPROPERTY('ProductVersion'));")
                if ($check.ExitCode -ne 0)
                {
                    throw ("Cannot connect: " + (($check.Output | Where-Object { $_ }) -join ' '))
                }
                $line  = ($check.Output | Where-Object { $_ -match '\|' } | Select-Object -Last 1)
                $parts = ([string]$line).Trim().Split('|')
                if ($parts.Count -lt 3)
                {
                    throw ("Unexpected response from server: " + (($check.Output | Where-Object { $_ }) -join ' '))
                }
                $dbState = $parts[0]
                Write-Host ("  SQL Server {0}, sysadmin = {1}, database {2}" -f $parts[2], $parts[1], $dbState.ToLower())

                if ($parts[1] -ne '1') { throw 'Login is not sysadmin (needed to create/remove the SQL Agent job).' }

                if ($dbState -eq 'MISSING')
                {
                    if ($Action -eq 'Uninstall')
                    {
                        $status = 'SKIPPED'
                        $detail = "database $dbQuote does not exist"
                        Write-Host "  $detail - nothing to uninstall." -ForegroundColor Yellow
                        continue
                    }
                    if (-not $CreateDatabase)
                    {
                        throw "Database $dbQuote does not exist. Create it first or use -CreateDatabase."
                    }
                    if ($PSCmdlet.ShouldProcess($instance, "CREATE DATABASE $dbQuote"))
                    {
                        # owner = login with SID 0x01 (sa, even if renamed), resolved server-side
                        $create = Invoke-Sqlcmd2 -Instance $instance -Arguments @('-Q',
                            ("CREATE DATABASE $dbQuote; ALTER DATABASE $dbQuote SET RECOVERY SIMPLE; " +
                             "DECLARE @o nvarchar(300) = QUOTENAME(SUSER_SNAME(0x01)); " +
                             "EXECUTE (N'ALTER AUTHORIZATION ON DATABASE::" + $dbQuote.Replace("'", "''") + " TO ' + @o + N';');"))
                        if ($create.ExitCode -ne 0)
                        {
                            throw ("CREATE DATABASE failed: " + ($create.Output -join ' '))
                        }
                        Write-Host "  Created database $dbQuote." -ForegroundColor Green
                    }
                }

                # 2. run the install / uninstall script
                if ($Action -eq 'Install' -and $WhatIfPreference)
                {
                    $null = $PSCmdlet.ShouldProcess($instance, "Run Install_sp_WhoIsActiveLogging.sql in $dbQuote (retention $RetentionDays d, compression $DataCompression, every $ScheduleEveryMinutes min)")
                    $status = 'WHATIF'
                    continue
                }

                if ($serverWhatIf -or $PSCmdlet.ShouldProcess($instance, "Run $([System.IO.Path]::GetFileName($source)) in $dbQuote"))
                {
                    $run = Invoke-Sqlcmd2 -Instance $instance -Arguments @('-i', $tempFile, '-f', '65001')
                    $run.Output | Set-Content -LiteralPath $logFile -Encoding UTF8 -WhatIf:$false
                    $run.Output | Where-Object { $_ -and $_ -notmatch '^-+$' } | ForEach-Object { Write-Host "  $_" }

                    if ($run.ExitCode -ne 0)
                    {
                        throw "sqlcmd exit code $($run.ExitCode) - see $logFile"
                    }
                    if ($serverWhatIf) { $status = 'WHATIF' }
                    $detail = $logFile
                }
            }
            catch
            {
                $status = 'FAILED'
                $detail = $_.Exception.Message
                Write-Host "  FAILED: $detail" -ForegroundColor Red
            }
            finally
            {
                $sw.Stop()
                $results.Add([pscustomobject]@{
                    Instance = $instance
                    Action   = $Action
                    Database = $Database
                    Status   = $status
                    Seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                    Detail   = $detail
                })
            }
        }
    }
    finally
    {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }

    Write-Host ''
    $results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host

    $failed = @($results | Where-Object { $_.Status -eq 'FAILED' }).Count
    if ($failed -gt 0)
    {
        Write-Host "$failed of $($results.Count) instance(s) failed." -ForegroundColor Red
    }
    exit $failed
}
