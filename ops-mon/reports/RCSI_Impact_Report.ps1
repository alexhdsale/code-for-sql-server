<#
.SYNOPSIS
  Runs RCSI_Impact_Report.sql against a SQL Server / RDS instance and writes the HTML report to a file.

.EXAMPLE
  .\RCSI_Impact_Report.ps1 -Server 'ms-app-prod.xxxx.us-east-1.rds.amazonaws.com' -User admin
      # cutover and databases taken from OPS.mon.RcsiCutover / sys.databases

  .\RCSI_Impact_Report.ps1 -Server ms-app-prod -User admin -Cutover '2026-10-24 22:00' -Databases 'BDBPayrollLive,SmartTuition' -BeforeDays 7 -AfterDays 3 -Out C:\Temp\RCSI_Impact.html

  .\RCSI_Impact_Report.ps1 -Server ms-app-prod -Integrated      # Windows auth

.NOTES
  No module needed (System.Data.SqlClient). The .sql file next to this script is used; its DECLARE lines
  for the parameters are replaced with the values given here, nothing else is changed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Server,
    [string] $User,
    [string] $Password,
    [switch] $Integrated,
    [string] $Cutover,                 # 'YYYY-MM-DD HH:mm' in the display time zone (ET); omit = OPS.mon.RcsiCutover
    [string] $Databases,               # 'Db1,Db2'; omit = every database with RCSI ON
    [int]    $BeforeDays = 7,
    [int]    $AfterDays,               # omit = until now
    [int]    $SkipHours = 1,
    [int]    $TopN = 20,
    [int]    $MinExecs = 20,
    [string] $Out,                     # default: .\RCSI_Impact_<server>_<yyyyMMdd_HHmm>.html
    [switch] $NoOpen,
    [int]    $TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
$sqlFile = Join-Path $PSScriptRoot 'RCSI_Impact_Report.sql'
if (-not (Test-Path $sqlFile)) { throw "RCSI_Impact_Report.sql not found next to this script ($PSScriptRoot)." }
$sql = Get-Content -Raw -Encoding UTF8 $sqlFile

function Set-Param([string]$text, [string]$name, [string]$value) {
    # replaces the whole DECLARE line of one parameter (first occurrence, parameters block)
    $pattern = "(?m)^DECLARE\s+$([regex]::Escape($name))\s+[^=]+=\s*[^;]*;"
    if ($text -notmatch $pattern) { throw "Parameter $name not found in the script." }
    $m = [regex]::Match($text, $pattern)
    $decl = $m.Value -replace '=\s*[^;]*;$', "= $value;"
    return $text.Substring(0, $m.Index) + $decl + $text.Substring($m.Index + $m.Length)
}

if ($Cutover)   { $sql = Set-Param $sql '@CutoverLocal' "'$Cutover'" }
if ($Databases) { $sql = Set-Param $sql '@Databases'    "N'$($Databases -replace "'", "''")'" }
$sql = Set-Param $sql '@BeforeDays' $BeforeDays
$sql = Set-Param $sql '@AfterDays'  $(if ($PSBoundParameters.ContainsKey('AfterDays')) { $AfterDays } else { 'NULL' })
$sql = Set-Param $sql '@SkipHours'  $SkipHours
$sql = Set-Param $sql '@TopN'       $TopN
$sql = Set-Param $sql '@MinExecs'   $MinExecs

if (-not $Out) {
    $label = ($Server -split '[.,\\]')[0]
    $Out = Join-Path (Get-Location) ("RCSI_Impact_{0}_{1}.html" -f $label, (Get-Date -Format 'yyyyMMdd_HHmm'))
}

$cs = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$cs['Data Source'] = $Server
$cs['Initial Catalog'] = 'master'
$cs['Application Name'] = 'RCSI_Impact_Report'
$cs['Connect Timeout'] = 30
$cs['TrustServerCertificate'] = $true
if ($Integrated -or -not $User) { $cs['Integrated Security'] = $true }
else {
    if (-not $Password) {
        $sec = Read-Host -Prompt "Password for $User" -AsSecureString
        $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }
    $cs['User ID'] = $User; $cs['Password'] = $Password
}

$conn = New-Object System.Data.SqlClient.SqlConnection $cs.ConnectionString
$conn.FireInfoMessageEventOnUserErrors = $false
$conn.add_InfoMessage({ param($s, $e) Write-Host $e.Message -ForegroundColor DarkGray })
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Host "Connecting to $Server ..." -ForegroundColor Cyan
$conn.Open()
try {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = $TimeoutSec
    $rd = $cmd.ExecuteReader()
    $html = $null; $scorecard = @(); $setNo = 0
    do {
        $setNo++
        $cols = @(); for ($i = 0; $i -lt $rd.FieldCount; $i++) { $cols += $rd.GetName($i) }
        while ($rd.Read()) {
            if ($cols -contains 'html') { $html = [string]$rd['html']; continue }
            if ($setNo -eq 2) {
                $scorecard += [pscustomobject]@{ Area = $rd['Area']; Metric = $rd['Metric']; Before = $rd['Before']; After = $rd['After']; 'Change %' = $rd['Change %']; Verdict = $rd['Verdict'] }
            }
            elseif ($setNo -eq 1) {
                $row = [ordered]@{}; for ($i = 0; $i -lt $rd.FieldCount; $i++) { $row[$cols[$i]] = $rd.GetValue($i) }
                ([pscustomobject]$row) | Format-List | Out-String | Write-Host
            }
        }
    } while ($rd.NextResult())
    $rd.Close()
}
finally { $conn.Close() }

if (-not $html) { throw "The script returned no html (check the messages above - cutover unknown? no database with RCSI ON?)." }
[IO.File]::WriteAllText($Out, $html, (New-Object Text.UTF8Encoding $true))
Write-Host ("Report written: {0}  ({1:N0} KB, {2:N0} s)" -f $Out, ([IO.FileInfo]$Out).Length / 1KB, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
if ($scorecard.Count) { $scorecard | Format-Table -AutoSize | Out-String -Width 200 | Write-Host }
if (-not $NoOpen) { Start-Process $Out }
