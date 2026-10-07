<#
.SYNOPSIS
    MON Check Editor - check matrix editor for OPS.mon (rev 5.7) monitoring on MS-APP-STG.

.DESCRIPTION
    Windows GUI (WinForms) for the DBA:
      * Databases     - one row per database, one real checkbox per check (mon.DatabaseCheck)
      * Server checks - instance-level checks on/off (mon.ServerCheck)
      * Settings      - thresholds / recipients / schedule (mon.Setting)
      * Backup retention, Ola CommandLog, Change log - read-only views
    Changes are highlighted in yellow and written only when you press APPLY:
    one transaction, optimistic concurrency (a row changed by someone else meanwhile
    is not overwritten), every change audited in mon.CheckChangeLog by the server triggers.

    Nothing is installed. Uses .NET System.Data.SqlClient that ships with Windows.

.PARAMETER Server
    RDS endpoint, e.g. ms-app-stg.xxxxxxxx.us-east-1.rds.amazonaws.com,1433
.PARAMETER Database
    Database that holds the mon schema (default OPS).

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\MON-CheckEditor.ps1
.EXAMPLE
    .\MON-CheckEditor.ps1 -Server ms-app-stg.abc.us-east-1.rds.amazonaws.com

.NOTES
    Windows PowerShell 5.1 or PowerShell 7 on Windows. Requires network access to the RDS endpoint.
    The login needs SELECT/UPDATE on schema mon (the RDS master login has it) and EXECUTE on
    mon.usp_ShowBackupRetention / mon.usp_ShowOlaLog.
    Last server / login / auth mode are remembered in %APPDATA%\MON\CheckEditor.json (never the password).
#>
[CmdletBinding()]
param(
    [string]$Server   = '',
    [string]$Database = 'OPS'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Write-Error 'MON Check Editor needs Windows (WinForms).'
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data
# [rev 5.7] High-DPI: declare per-monitor awareness BEFORE the first window, otherwise Windows scales the
# fonts but not the fixed-size controls (clipped buttons, tiny text boxes, tiny tab headers).
# SYSTEM DPI aware (not per-monitor): native controls (TextBox, TabControl) and GDI+ text then use the same DPI,
# so fonts and control sizes stay proportional; on a second monitor with another scale Windows stretches the window.
try {
    Add-Type -Namespace MonUi -Name Dpi -MemberDefinition '[DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);' -ErrorAction Stop
    [void][MonUi.Dpi]::SetProcessDpiAwareness(1)      # 1 = PROCESS_SYSTEM_DPI_AWARE
} catch { try { Add-Type -Namespace MonUi -Name Dpi2 -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'; [void][MonUi.Dpi2]::SetProcessDPIAware() } catch { } }
[System.Windows.Forms.Application]::EnableVisualStyles()
# (SetCompatibleTextRenderingDefault is NOT called: it throws when the script is re-run in the same console / ISE session.)

# --------------------------------------------------------------------------------------------
#  State
# --------------------------------------------------------------------------------------------
$script:ConnString = $null
$script:Tables     = @{}          # tab key -> DataTable
$script:Grids      = @{}          # tab key -> DataGridView
$script:Friendly   = @{}          # DatabaseCheck column -> display name
$script:Loading    = $false
$script:Splits     = @()
$script:Tooltips   = @{}
$script:ServerLabel = ''
$script:CfgPath    = Join-Path $env:APPDATA 'MON\CheckEditor.json'

# Editable columns per table (whitelist - column names are never taken from user input).
$script:DbBitColumns = @('monitored','full_backup','diff_backup','log_backup','backup_retention','checkdb',
                         'log_used','vlf_count','file_near_max','config_drift','config_best_practice',
                         'query_store','blocking','long_queries','open_trans','deadlocks','io_latency')
$script:Editable = @{
    'db'       = $script:DbBitColumns + @('retention_days','storage_retention_days','notes')
    'server'   = @('is_enabled','notes')
    'settings' = @('setting_value')
}
$script:KeyColumn = @{ 'db' = 'database_name'; 'server' = 'check_code'; 'settings' = 'setting_name' }
$script:TargetTable = @{ 'db' = 'mon.DatabaseCheck'; 'server' = 'mon.ServerCheck'; 'settings' = 'mon.Setting' }

# Colors
$ColHeader  = [System.Drawing.Color]::FromArgb(30, 58, 95)
$ColChanged = [System.Drawing.Color]::FromArgb(255, 243, 176)
$ColOff     = [System.Drawing.Color]::FromArgb(254, 243, 199)
$ColNA      = [System.Drawing.Color]::FromArgb(243, 244, 246)
$ColCrit    = [System.Drawing.Color]::FromArgb(254, 226, 226)
$ColOk      = [System.Drawing.Color]::FromArgb(220, 252, 231)
$ColWarn    = [System.Drawing.Color]::FromArgb(254, 243, 199)
# Feature state badges
$BadgeOn    = [System.Drawing.Color]::FromArgb(22, 163, 74)     # green  = enabled
$BadgeOff   = [System.Drawing.Color]::FromArgb(220, 38, 38)     # red    = disabled
$BadgeNA    = [System.Drawing.Color]::FromArgb(156, 163, 175)   # grey   = not defined / not applicable
$BadgeEdit  = [System.Drawing.Color]::FromArgb(245, 158, 11)    # orange frame = changed, not applied
$BadgeSel   = [System.Drawing.Color]::FromArgb(37, 99, 235)     # blue frame = selected
$ColPanel   = [System.Drawing.Color]::FromArgb(243, 244, 246)   # light grey tool bars
$ColBorder  = [System.Drawing.Color]::FromArgb(209, 213, 219)
$ColText    = [System.Drawing.Color]::FromArgb(31, 41, 55)
$ColMuted   = [System.Drawing.Color]::FromArgb(107, 114, 128)
$ColAccent  = [System.Drawing.Color]::FromArgb(37, 99, 235)

# Everything that has a fixed pixel size goes through S() so the layout is identical at 100 % / 125 % / 150 % / 200 %.
$script:Scale = 1.0
try { $gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:Scale = [double]$gfx.DpiX / 96.0; $gfx.Dispose() } catch { }
function S([double]$Px) { return [int][Math]::Round($Px * $script:Scale) }
# Fonts in PIXELS (scaled with S) - identical size in every control type, whatever Windows thinks the DPI is.
function New-UiFont([double]$Px, [bool]$Bold = $false) {
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    return New-Object System.Drawing.Font('Segoe UI', [single](S $Px), $style, [System.Drawing.GraphicsUnit]::Pixel)
}
$UiFont     = New-UiFont 13
$UiBold     = New-UiFont 13 $true
$UiSmall    = New-UiFont 12
$GridFont   = New-UiFont 12.5
$GridBold   = New-UiFont 12.5 $true
$script:LineH = [System.Windows.Forms.TextRenderer]::MeasureText('Xg', $GridBold).Height

# --------------------------------------------------------------------------------------------
#  Data access
# --------------------------------------------------------------------------------------------
function New-MonConnection {
    $c = New-Object System.Data.SqlClient.SqlConnection $script:ConnString
    $c.Open()
    return $c
}

function Get-MonTable([string]$Sql) {
    $c = New-MonConnection
    try {
        $cmd = $c.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = 120
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)
        return ,$dt
    } finally { $c.Dispose() }
}

function Get-MonDataSet([string]$Sql) {
    $c = New-MonConnection
    try {
        $cmd = $c.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = 300
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $ds = New-Object System.Data.DataSet
        [void]$da.Fill($ds)
        return ,$ds
    } finally { $c.Dispose() }
}

function Test-ValueChanged($Row, [string]$Col) {
    if ($Row.RowState -ne [System.Data.DataRowState]::Modified) { return $false }
    $o = $Row.Item($Col, [System.Data.DataRowVersion]::Original)
    $n = $Row.Item($Col, [System.Data.DataRowVersion]::Current)
    return -not ([object]::Equals($o, $n))
}

function Get-PendingChanges {
    # Returns a flat list: Key, Tab, Item, Column, Old, New
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($key in @('db','server','settings')) {
        $dt = $script:Tables[$key]
        if ($null -eq $dt) { continue }
        foreach ($row in $dt.Rows) {
            if ($row.RowState -ne [System.Data.DataRowState]::Modified) { continue }
            foreach ($col in $script:Editable[$key]) {
                if (-not $dt.Columns.Contains($col)) { continue }
                if (Test-ValueChanged $row $col) {
                    $list.Add([pscustomobject]@{
                        Tab    = $key
                        Item   = [string]$row.Item($script:KeyColumn[$key])
                        Column = $col
                        Old    = $row.Item($col, [System.Data.DataRowVersion]::Original)
                        New    = $row.Item($col, [System.Data.DataRowVersion]::Current)
                    })
                }
            }
        }
    }
    return ,$list
}

function Format-Value($v) {
    if ($v -is [System.DBNull] -or $null -eq $v) { return 'NULL' }
    if ($v -is [bool]) { if ($v) { return 'ON' } else { return 'OFF' } }
    return [string]$v
}

function Invoke-ApplyChanges {
    $changes = Get-PendingChanges
    if ($changes.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Nothing to apply.', 'MON') | Out-Null
        return
    }

    $preview = ($changes | Select-Object -First 40 | ForEach-Object {
        $label = if ($_.Tab -eq 'db' -and $script:Friendly.ContainsKey($_.Column)) { $script:Friendly[$_.Column] } else { $_.Column }
        '{0,-24} {1,-26} {2} -> {3}' -f $_.Item, $label, (Format-Value $_.Old), (Format-Value $_.New)
    }) -join [Environment]::NewLine
    if ($changes.Count -gt 40) { $preview += [Environment]::NewLine + ('... and {0} more' -f ($changes.Count - 40)) }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Apply {0} change(s) to {1}.{2}?`r`n`r`n{3}" -f $changes.Count, $script:ServerLabel, $Database, $preview),
        'MON - confirm', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $c = New-MonConnection
    $tx = $c.BeginTransaction()
    $conflicts = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($key in @('db','server','settings')) {
            $dt = $script:Tables[$key]
            if ($null -eq $dt) { continue }
            foreach ($row in $dt.Rows) {
                if ($row.RowState -ne [System.Data.DataRowState]::Modified) { continue }
                $cols = @($script:Editable[$key] | Where-Object { $dt.Columns.Contains($_) -and (Test-ValueChanged $row $_) })
                if ($cols.Count -eq 0) { continue }

                $cmd = $c.CreateCommand()
                $cmd.Transaction = $tx
                $sets = @()
                for ($i = 0; $i -lt $cols.Count; $i++) {
                    $sets += ('[{0}] = @p{1}' -f $cols[$i], $i)          # whitelisted names only
                    [void]$cmd.Parameters.AddWithValue("@p$i", $row.Item($cols[$i]))
                }
                $where = ('[{0}] = @k' -f $script:KeyColumn[$key])
                [void]$cmd.Parameters.AddWithValue('@k', $row.Item($script:KeyColumn[$key]))
                # Optimistic concurrency: the row must still look like it did when it was loaded.
                if ($dt.Columns.Contains('modified_utc')) {
                    $where += ' AND modified_utc = @m'
                    [void]$cmd.Parameters.AddWithValue('@m', $row.Item('modified_utc', [System.Data.DataRowVersion]::Original))
                } elseif ($key -eq 'settings') {
                    $where += ' AND setting_value = @o'
                    [void]$cmd.Parameters.AddWithValue('@o', $row.Item('setting_value', [System.Data.DataRowVersion]::Original))
                }
                $cmd.CommandText = ('UPDATE {0} SET {1} WHERE {2};' -f $script:TargetTable[$key], ($sets -join ', '), $where)
                $n = $cmd.ExecuteNonQuery()
                if ($n -eq 0) { $conflicts.Add(('{0}: {1}' -f $script:TargetTable[$key], $row.Item($script:KeyColumn[$key]))) }
            }
        }

        if ($conflicts.Count -gt 0) {
            $tx.Rollback()
            [System.Windows.Forms.MessageBox]::Show(
                ("Nothing was saved: these rows were changed by someone else since you loaded them:`r`n`r`n{0}`r`n`r`nPress Refresh and apply again." -f ($conflicts -join "`r`n")),
                'MON - conflict', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $tx.Commit()
        $closed = 0
        try {
            $cc = $c.CreateCommand()
            # short lock wait: if the engine is merging right now it closes them itself within seconds
            $cc.CommandText = 'DECLARE @n int; EXEC mon.usp_CloseDisabledIssues @Closed = @n OUTPUT, @LockTimeoutMs = 3000; SELECT ISNULL(@n, 0);'
            $cc.CommandTimeout = 30
            $closed = [int]$cc.ExecuteScalar()
        } catch { }
        Set-Status ('Applied {0} change(s) at {1}. {2} open issue(s) of disabled checks closed now; re-enabled checks are evaluated at the next 5-minute cycle.' -f $changes.Count, (Get-Date -Format 'HH:mm:ss'), $closed)
    } catch {
        try { $tx.Rollback() } catch { }
        [System.Windows.Forms.MessageBox]::Show(("Apply failed, nothing was saved:`r`n{0}" -f $_.Exception.Message), 'MON - error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    } finally {
        $c.Dispose()
    }
    # Saved: mark rows clean (otherwise the reload asks "discard unsaved changes?") and reload only the fast tabs.
    foreach ($key in @('db','server','settings')) { if ($script:Tables[$key]) { $script:Tables[$key].AcceptChanges() } }
    $msg = $script:StatusLabel.Text
    $script:Form.Cursor = 'WaitCursor'
    try { Invoke-LoadEditable; Invoke-LoadChangeLog } finally { $script:Form.Cursor = 'Default' }
    $script:LoadedTabs = @{}
    Set-Status $msg
}

# --------------------------------------------------------------------------------------------
#  Grid helpers
# --------------------------------------------------------------------------------------------
function New-Grid([bool]$ReadOnly) {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.ReadOnly = $ReadOnly
    $g.SelectionMode = 'CellSelect'
    $g.RowHeadersVisible = $false
    $g.AutoSizeColumnsMode = 'DisplayedCells'
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.BorderStyle = 'None'
    $g.CellBorderStyle = 'SingleHorizontal'
    $g.GridColor = [System.Drawing.Color]::FromArgb(229, 231, 235)
    $g.Font = $GridFont
    $g.DefaultCellStyle.ForeColor = $ColText
    $g.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding((S 6), 0, (S 6), 0)
    $g.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
    $g.DefaultCellStyle.SelectionForeColor = $ColText
    $g.RowTemplate.Height = $script:LineH + (S 10)
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = $ColHeader
    $g.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $g.ColumnHeadersDefaultCellStyle.SelectionBackColor = $ColHeader
    $g.ColumnHeadersDefaultCellStyle.Font = $GridBold
    $g.ColumnHeadersDefaultCellStyle.Alignment = 'MiddleLeft'
    $g.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding((S 6), (S 4), (S 6), (S 4))
    $g.ColumnHeadersDefaultCellStyle.WrapMode = 'True'
    $g.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $g.ColumnHeadersHeight = 2 * $script:LineH + (S 12)      # room for two header lines at every DPI
    $g.ColumnHeadersBorderStyle = 'None'
    $g.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)
    # Double buffering (smooth scrolling of wide grids)
    $prop = $g.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $prop.SetValue($g, $true, $null)
    return $g
}

function Set-ReadOnlyColumns([System.Windows.Forms.DataGridView]$Grid, [string]$Key) {
    foreach ($col in $Grid.Columns) {
        $editable = $script:Editable.ContainsKey($Key) -and ($script:Editable[$Key] -contains $col.DataPropertyName)
        $col.ReadOnly = -not $editable
        if (-not $editable) { $col.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81) }
        if ($col -is [System.Windows.Forms.DataGridViewCheckBoxColumn]) {
            $col.AutoSizeMode = 'None'
            $col.Width = S 84
            $col.ReadOnly = $true          # toggled by our click handler, painted as a colored badge
            $col.SortMode = 'Automatic'
            $col.HeaderCell.Style.Alignment = 'MiddleCenter'
        }
    }
}

# [rev 5.7] Badge columns: as wide as the longest word of their header (wrapped to two lines), never clipped.
function Set-BadgeColumnWidths([System.Windows.Forms.DataGridView]$Grid) {
    foreach ($col in $Grid.Columns) {
        if (-not ($col -is [System.Windows.Forms.DataGridViewCheckBoxColumn])) { continue }
        $w = S 84
        foreach ($word in ([string]$col.HeaderText -split '\s+')) {
            if (-not $word) { continue }
            $m = [System.Windows.Forms.TextRenderer]::MeasureText($word, $GridBold).Width + (S 18)
            if ($m -gt $w) { $w = $m }
        }
        $col.Width = $w
    }
}

function Get-FeatureState($Row, [string]$Col) {
    # Returns ON | OFF | NA   (NA = not defined / not applicable)
    $v = $Row.Item($Col)
    if ($v -is [System.DBNull] -or $null -eq $v) { return 'NA' }
    $t = $Row.Table
    if ($t.Columns.Contains('monitored') -and $Col -ne 'monitored' -and -not [bool]$Row.Item('monitored')) { return 'NA' }
    if ($Col -eq 'log_backup' -and $t.Columns.Contains('recovery_model') -and [string]$Row.Item('recovery_model') -ne 'FULL') { return 'NA' }
    if ($t.Columns.Contains('state') -and [string]$Row.Item('state') -eq 'DROPPED' -and $Col -ne 'monitored') { return 'NA' }
    if ([bool]$v) { return 'ON' } else { return 'OFF' }
}

function Test-BoolColumn([System.Windows.Forms.DataGridView]$Grid, [int]$ColIndex) {
    if ($ColIndex -lt 0) { return $false }
    return ($Grid.Columns[$ColIndex] -is [System.Windows.Forms.DataGridViewCheckBoxColumn])
}

function Update-PendingLabel {
    $n = (Get-PendingChanges).Count
    $script:BtnApply.Text = if ($n -gt 0) { "APPLY ($n)" } else { 'APPLY' }
    $script:BtnApply.Enabled = ($n -gt 0)
    $script:BtnDiscard.Enabled = ($n -gt 0)
}

function Set-Status([string]$Text) {
    $script:StatusLabel.Text = $Text
}

function Set-SelectedCells([bool]$Value) {
    $tabKey = $script:TabControl.SelectedTab.Tag
    if (-not $script:Editable.ContainsKey($tabKey)) { return }
    $g = $script:Grids[$tabKey]
    foreach ($cell in $g.SelectedCells) {
        $colName = $g.Columns[$cell.ColumnIndex].DataPropertyName
        if (($script:Editable[$tabKey] -contains $colName) -and (Test-BoolColumn $g $cell.ColumnIndex)) {
            $drv = $g.Rows[$cell.RowIndex].DataBoundItem
            if ((Get-FeatureState $drv.Row $colName) -eq 'NA' -and $colName -ne 'monitored') { continue }
            $drv.Row[$colName] = $Value
        }
    }
    $g.Invalidate()
    Update-PendingLabel
}

# --------------------------------------------------------------------------------------------
#  Loading
# --------------------------------------------------------------------------------------------
function Invoke-LoadEditable {
    $script:Loading = $true
    try {
        # Friendly names for the matrix headers
        $cat = Get-MonTable 'SELECT column_name, display_name, description FROM mon.CheckCatalog WHERE column_name IS NOT NULL ORDER BY sort_order;'
        $script:Friendly = @{}
        $script:Tooltips = @{}
        foreach ($r in $cat.Rows) { $script:Friendly[[string]$r.column_name] = [string]$r.display_name; $script:Tooltips[[string]$r.column_name] = [string]$r.description }

        $cols = ($script:DbBitColumns | ForEach-Object { "c.[$_]" }) -join ', '
        $script:Tables['db'] = Get-MonTable @"
DECLARE @tz nvarchar(100) = ISNULL(mon.fn_Setting('display_time_zone'), N'Eastern Standard Time');
SELECT c.database_name, ISNULL(s.recovery_model, N'?') AS recovery_model,
       CASE WHEN ISNULL(s.is_present, 1) = 0 THEN N'DROPPED' ELSE ISNULL(s.state_desc, N'?') END AS state,
       $cols,
       c.retention_days, c.storage_retention_days, c.notes,
       CONVERT(varchar(16), mon.fn_UtcToLocal(ck.last_utc, @tz), 120) AS last_checkdb,
       LOWER(ck.src) AS checkdb_source,
       c.modified_utc, c.modified_by
FROM mon.DatabaseCheck AS c
LEFT JOIN mon.DatabaseStatus AS s ON s.database_name = c.database_name
OUTER APPLY (SELECT MAX(o.end_utc) AS last_ok_utc FROM mon.OlaCommand AS o
             WHERE o.database_name = c.database_name AND o.command_type = N'DBCC_CHECKDB'
               AND ISNULL(o.error_number, 0) = 0 AND o.end_utc IS NOT NULL) AS oc
CROSS APPLY (SELECT CASE WHEN oc.last_ok_utc > ISNULL(s.last_checkdb_utc, '19000101') THEN oc.last_ok_utc ELSE s.last_checkdb_utc END AS last_utc,
                    CASE WHEN oc.last_ok_utc > ISNULL(s.last_checkdb_utc, '19000101') THEN 'OLA' ELSE s.checkdb_source END AS src) AS ck
ORDER BY c.database_name;
"@
        $script:Tables['server'] = Get-MonTable @'
SELECT s.check_code, s.display_name, s.is_enabled, k.description, k.threshold_info, s.notes, s.modified_utc, s.modified_by
FROM mon.ServerCheck AS s JOIN mon.CheckCatalog AS k ON k.check_code = s.check_code
ORDER BY k.sort_order;
'@
        $script:Tables['settings'] = Get-MonTable 'SELECT setting_name, setting_value, category, description, modified_utc AS last_modified_utc, modified_by FROM mon.Setting ORDER BY category, setting_name;'

        foreach ($key in @('db','server','settings')) {
            $dt = $script:Tables[$key]
            foreach ($c in $dt.Columns) { $c.ReadOnly = -not ($script:Editable[$key] -contains $c.ColumnName) }
            $dt.AcceptChanges()
            $g = $script:Grids[$key]
            $view = New-Object System.Data.DataView $dt
            $g.DataSource = $view
            Set-ReadOnlyColumns $g $key
        }

        # Friendly headers + tooltips on the matrix
        foreach ($col in $script:Grids['db'].Columns) {
            $p = $col.DataPropertyName
            if ($script:Friendly.ContainsKey($p)) { $col.HeaderText = $script:Friendly[$p]; $col.ToolTipText = $script:Tooltips[$p] }
        }
        $h = $script:Grids['db'].Columns
        $h['database_name'].HeaderText = 'Database'; $h['database_name'].Frozen = $true
        $h['recovery_model'].HeaderText = 'Recovery'; $h['state'].HeaderText = 'State'
        $h['retention_days'].HeaderText = 'Retention target (d)'
        $h['retention_days'].ToolTipText = 'Required backup history depth. Empty = default setting backup_retention_target_days.'
        $h['storage_retention_days'].HeaderText = 'Storage policy (d)'
        $h['storage_retention_days'].ToolTipText = 'Declared lifecycle of backup files on S3/disk. Empty = default setting backup_storage_retention_days.'
        $h['last_checkdb'].HeaderText = 'Last good CHECKDB'
        $h['last_checkdb'].ToolTipText = 'Newest of DATABASEPROPERTYEX LastGoodCheckDbTime / DBCC DBINFO / Ola CommandLog DBCC_CHECKDB.'
        $h['checkdb_source'].HeaderText = 'CHECKDB source'
        $h['database_name'].DefaultCellStyle.Font = $GridBold
        foreach ($key in @('db','server')) { Set-BadgeColumnWidths $script:Grids[$key] }
        Invoke-ApplyFilter
    } finally {
        $script:Loading = $false
    }
    Update-PendingLabel
}

# [rev 5.3] Heavy read-only tabs load on demand (first time the tab is opened, or F5 on that tab).
$script:LoadedTabs = @{}
$script:Timings = @()
function Measure-Load([string]$What, [scriptblock]$Block) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Block
    $sw.Stop()
    $script:Timings += ('{0} {1:N1}s' -f $What, $sw.Elapsed.TotalSeconds)
}

function Invoke-LoadRetention([bool]$Live) {
    $script:Form.Cursor = 'WaitCursor'
    Set-Status ('Loading backup retention ({0})...' -f $(if ($Live) { 'live from msdb - can take a while' } else { 'daily snapshot' }))
    $script:Form.Refresh()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ds = Get-MonDataSet ('EXEC mon.usp_ShowBackupRetention @Live = {0};' -f [int]$Live)
        $script:Grids['ret'].DataSource = $ds.Tables[0]
        $script:Grids['retsum'].DataSource = $ds.Tables[1]
        $script:LoadedTabs['ret'] = $true
        Set-Status ('Backup retention loaded ({0}) in {1:N1}s. Press F5 on this tab for live data from msdb.' -f $(if ($Live) { 'live' } else { 'snapshot' }), $sw.Elapsed.TotalSeconds)
    } catch { Set-Status ('Backup retention: ' + $_.Exception.Message) }
    finally { $script:Form.Cursor = 'Default' }
}

function Invoke-LoadOla {
    $script:Form.Cursor = 'WaitCursor'
    Set-Status 'Loading Ola CommandLog (30 days)...'
    $script:Form.Refresh()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ds2 = Get-MonDataSet 'EXEC mon.usp_ShowOlaLog @Hours = 720;'
        $script:Grids['ola'].DataSource = $ds2.Tables[0]
        $script:Grids['olafail'].DataSource = $ds2.Tables[1]
        $script:Grids['oladb'].DataSource = $ds2.Tables[2]
        $script:Grids['olasrc'].DataSource = $ds2.Tables[3]
        $types = @($ds2.Tables[0].Rows | ForEach-Object { [string]$_.Item(0) })
        $src = @($ds2.Tables[3].Rows | Where-Object { $_.Item(1) } | ForEach-Object { [string]$_.Item(0) }) -join ', '
        $missing = @('DBCC_CHECKDB','BACKUP_DATABASE','BACKUP_LOG') | Where-Object { $types -notcontains $_ }
        $script:OlaNote.Text = if (-not $src) { 'No dbo.CommandLog found. Set setting ola_commandlog_database or install Ola with @LogToTable = ''Y''.' }
            elseif ($missing) { ('CommandLog read from: {0}.  Not seen in 30 days: {1}  -> that job does not log here (check @LogToTable = ''Y'' / @DatabaseName of CommandLog in its job step) or did not run. RDS native backups (DBMaintenance - Daily Backups) never appear here.' -f $src, ($missing -join ', ')) }
            else { ('CommandLog read from: {0}' -f $src) }
        $script:LoadedTabs['ola'] = $true
        Set-Status ('Ola CommandLog loaded in {0:N1}s.' -f $sw.Elapsed.TotalSeconds)
    } catch { Set-Status ('Ola log: ' + $_.Exception.Message) }
    finally { $script:Form.Cursor = 'Default' }
}

function Invoke-LoadEmails {
    $script:Form.Cursor = 'WaitCursor'
    Set-Status 'Loading email statistics (30 days)...'
    $script:Form.Refresh()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ds = Get-MonDataSet 'EXEC mon.usp_ShowEmailStats @Days = 30;'
        $script:Grids['mailday'].DataSource  = $ds.Tables[0]
        $script:Grids['maillast'].DataSource = $ds.Tables[2]
        if ($ds.Tables.Count -gt 3) { $script:Grids['mailsrv'].DataSource = $ds.Tables[3] }
        if ($ds.Tables.Count -gt 4) { $script:Grids['mailsubj'].DataSource = $ds.Tables[4] }
        $sent = 0; foreach ($r in $ds.Tables[0].Rows) { $sent += [int]$r.Item(1) }
        $script:LoadedTabs['mail'] = $true
        Set-Status ('Email statistics loaded in {0:N1}s. MON sent {1} email(s) in 30 days ({2:N1}/day).' -f $sw.Elapsed.TotalSeconds, $sent, ($sent / 30.0))
    } catch { Set-Status ('Emails: ' + $_.Exception.Message) }
    finally { $script:Form.Cursor = 'Default' }
}

function Invoke-LoadChangeLog {
    try {
        $script:Grids['log'].DataSource = Get-MonTable 'SELECT TOP (1000) changed_utc, changed_by, host_name, object_name, item_name, property_name, old_value, new_value FROM mon.CheckChangeLog ORDER BY change_log_id DESC;'
    } catch { Set-Status ('Change log: ' + $_.Exception.Message) }
}

function Invoke-RefreshAll {
    if ((Get-PendingChanges).Count -gt 0) {
        $a = [System.Windows.Forms.MessageBox]::Show('Discard unsaved changes and reload?', 'MON', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $script:Form.Cursor = 'WaitCursor'
    $script:Timings = @()
    try {
        Measure-Load 'checks' { Invoke-LoadEditable }
        Measure-Load 'audit'  { Invoke-LoadChangeLog }
        $script:LoadedTabs = @{}                       # heavy tabs reload when opened
        $dbs = $script:Tables['db'].Rows.Count
        $off = @($script:Tables['db'].Rows | Where-Object { -not $_.monitored }).Count
        Set-Status ('Connected to {0}.{1}  |  {2} databases ({3} not monitored)  |  loaded {4} ({5})' -f $script:ServerLabel, $Database, $dbs, $off, (Get-Date -Format 'HH:mm:ss'), ($script:Timings -join ', '))
        $tab = $script:TabControl.SelectedTab.Tag
        if ($tab -eq 'ret') { Invoke-LoadRetention $true }
        elseif ($tab -eq 'ola') { Invoke-LoadOla }
        elseif ($tab -eq 'mail') { Invoke-LoadEmails }
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'MON - load failed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        $script:Form.Cursor = 'Default'
    }
}

function Invoke-ApplyFilter {
    $txt = $script:TxtFilter.Text.Replace("'", "''").Replace('[', '[[]').Replace('*', '[*]').Replace('%', '[%]')
    foreach ($key in @('db','server','settings')) {
        $g = $script:Grids[$key]
        if ($null -eq $g.DataSource) { continue }
        $col = @{ 'db' = 'database_name'; 'server' = 'display_name'; 'settings' = 'setting_name' }[$key]
        $g.DataSource.RowFilter = if ($txt) { "$col LIKE '*$txt*'" } else { '' }
    }
}

# --------------------------------------------------------------------------------------------
#  Settings persistence (no passwords)
# --------------------------------------------------------------------------------------------
function Read-Config {
    if (Test-Path $script:CfgPath) {
        try { return Get-Content $script:CfgPath -Raw | ConvertFrom-Json } catch { }
    }
    return $null
}
function Save-Config {
    $dir = Split-Path $script:CfgPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [pscustomobject]@{
        Server = $script:TxtServer.Text; Login = $script:TxtLogin.Text
        WindowsAuth = $script:ChkWin.Checked; TrustCert = $script:ChkTrust.Checked
    } | ConvertTo-Json | Set-Content -Path $script:CfgPath -Encoding UTF8
}

# --------------------------------------------------------------------------------------------
#  UI
# --------------------------------------------------------------------------------------------
$script:Form = New-Object System.Windows.Forms.Form
$Form.Text = 'MON Check Editor - OPS.mon'
$Form.AutoScaleMode = 'None'            # we scale explicitly with S()
$Form.Size = New-Object System.Drawing.Size((S 1500), (S 880))
$Form.MinimumSize = New-Object System.Drawing.Size((S 1100), (S 600))
$Form.StartPosition = 'CenterScreen'
$Form.Font = $UiFont
$Form.BackColor = [System.Drawing.Color]::White
$Form.KeyPreview = $true

function New-ToolBar([int]$Height) {
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.Dock = 'Top'; $p.Height = S $Height; $p.WrapContents = $false; $p.AutoSize = $false
    $p.Padding = New-Object System.Windows.Forms.Padding((S 10), (S 7), (S 10), 0)
    $p.BackColor = $ColPanel
    return $p
}
function New-FieldLabel([string]$Text, [System.Windows.Forms.Control]$Parent) {
    $l = New-Object System.Windows.Forms.Label; $l.Text = $Text; $l.AutoSize = $true; $l.ForeColor = $ColText
    $l.Margin = New-Object System.Windows.Forms.Padding((S 10), (S 6), (S 4), 0)
    $Parent.Controls.Add($l); return $l
}
function New-Field([int]$Width, [System.Windows.Forms.Control]$Parent) {
    $t = New-Object System.Windows.Forms.TextBox; $t.Width = S $Width; $t.Font = $UiFont
    $t.Margin = New-Object System.Windows.Forms.Padding(0, (S 2), 0, 0)
    $Parent.Controls.Add($t); return $t
}
function New-Check([string]$Text, [System.Windows.Forms.Control]$Parent) {
    $c = New-Object System.Windows.Forms.CheckBox; $c.Text = $Text; $c.AutoSize = $true; $c.ForeColor = $ColText
    $c.Margin = New-Object System.Windows.Forms.Padding((S 12), (S 4), 0, 0)
    $Parent.Controls.Add($c); return $c
}
function New-ToolButton([string]$Text, [System.Windows.Forms.Control]$Parent, [bool]$Primary = $false) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.AutoSize = $true; $b.AutoSizeMode = 'GrowAndShrink'
    $b.MinimumSize = New-Object System.Drawing.Size((S 96), (S 30))
    $b.Padding = New-Object System.Windows.Forms.Padding((S 10), 0, (S 10), 0)
    $b.Margin = New-Object System.Windows.Forms.Padding((S 4), 0, (S 4), 0)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 1; $b.UseVisualStyleBackColor = $false
    if ($Primary) {
        $b.BackColor = $ColAccent; $b.ForeColor = [System.Drawing.Color]::White; $b.Font = $UiBold
        $b.FlatAppearance.BorderColor = $ColAccent
        $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
    } else {
        $b.BackColor = [System.Drawing.Color]::White; $b.ForeColor = $ColText
        $b.FlatAppearance.BorderColor = $ColBorder
        $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(239, 246, 255)
    }
    $Parent.Controls.Add($b); return $b
}

# --- connection bar ---
$top = New-ToolBar 46
[void](New-FieldLabel 'Server' $top)
$script:TxtServer = New-Field 420 $top
$script:ChkWin = New-Check 'Windows auth' $top
[void](New-FieldLabel 'Login' $top)
$script:TxtLogin = New-Field 150 $top
[void](New-FieldLabel 'Password' $top)
$script:TxtPwd = New-Field 170 $top; $TxtPwd.UseSystemPasswordChar = $true
$script:ChkTrust = New-Check 'Trust server certificate' $top; $ChkTrust.Checked = $true
$BtnConnect = New-ToolButton 'Connect' $top $true
$BtnConnect.Margin = New-Object System.Windows.Forms.Padding((S 14), 0, 0, 0)
$ChkWin.Add_CheckedChanged({ $script:TxtLogin.Enabled = -not $script:ChkWin.Checked; $script:TxtPwd.Enabled = -not $script:ChkWin.Checked })

# --- action bar ---
$bar = New-ToolBar 46
[void](New-FieldLabel 'Filter' $bar)
$script:TxtFilter = New-Field 200 $bar
$TxtFilter.Margin = New-Object System.Windows.Forms.Padding(0, (S 2), (S 14), 0)
$BtnOn      = New-ToolButton 'Check selected' $bar
$BtnOff     = New-ToolButton 'Uncheck selected' $bar
$script:BtnDiscard = New-ToolButton 'Discard changes' $bar
$BtnRefresh = New-ToolButton 'Refresh  (F5)' $bar
$script:BtnApply = New-ToolButton 'APPLY' $bar $true
$BtnApply.MinimumSize = New-Object System.Drawing.Size((S 120), (S 30))
$BtnApply.Margin = New-Object System.Windows.Forms.Padding((S 14), 0, 0, 0)
$BtnApply.Enabled = $false; $BtnDiscard.Enabled = $false
$BtnApply.Add_EnabledChanged({ param($s, $e) if ($s.Enabled) { $s.BackColor = $ColAccent; $s.FlatAppearance.BorderColor = $ColAccent } else { $s.BackColor = [System.Drawing.Color]::FromArgb(191, 219, 254); $s.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(191, 219, 254) } })
$BtnApply.BackColor = [System.Drawing.Color]::FromArgb(191, 219, 254); $BtnApply.FlatAppearance.BorderColor = $BtnApply.BackColor
$barTip = New-Object System.Windows.Forms.ToolTip
$barTip.SetToolTip($BtnOn,  'Set every selected badge to ON (select cells with the mouse, Shift / Ctrl for ranges)')
$barTip.SetToolTip($BtnOff, 'Set every selected badge to OFF')
$barTip.SetToolTip($BtnApply, 'Write all changes in one transaction (Ctrl+S). Disabled checks close their open issues immediately.')

$sep = New-Object System.Windows.Forms.Panel; $sep.Dock = 'Top'; $sep.Height = 1; $sep.BackColor = $ColBorder

# --- tabs ---
$script:TabControl = New-Object System.Windows.Forms.TabControl
$TabControl.Dock = 'Fill'; $TabControl.Font = $UiFont
$TabControl.Padding = New-Object System.Drawing.Point((S 16), (S 6))
$TabControl.SizeMode = 'Normal'
$tabHost = New-Object System.Windows.Forms.Panel
$tabHost.Dock = 'Fill'; $tabHost.Padding = New-Object System.Windows.Forms.Padding((S 8), (S 8), (S 8), (S 4)); $tabHost.BackColor = [System.Drawing.Color]::White
$tabHost.Controls.Add($TabControl)
function Add-Tab([string]$Title, [string]$Key, [System.Windows.Forms.Control]$Content) {
    $t = New-Object System.Windows.Forms.TabPage
    $t.Text = $Title; $t.Tag = $Key; $t.Padding = New-Object System.Windows.Forms.Padding((S 6)); $t.BackColor = [System.Drawing.Color]::White
    $t.UseVisualStyleBackColor = $false
    $t.Controls.Add($Content)
    $script:TabControl.TabPages.Add($t)
}
function New-SectionLabel([string]$Text) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text; $lbl.Dock = 'Top'; $lbl.Height = S 28; $lbl.Font = $UiBold; $lbl.ForeColor = $ColText
    $lbl.TextAlign = 'MiddleLeft'; $lbl.Padding = New-Object System.Windows.Forms.Padding((S 2), 0, 0, (S 2))
    return $lbl
}
function New-SplitGrids([string]$TopKey, [string]$TopTitle, [string]$BottomKey, [string]$BottomTitle) {
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'; $split.SplitterWidth = S 8; $split.BackColor = [System.Drawing.Color]::White
    $script:Splits += $split
    foreach ($pair in @(@($split.Panel1, $TopKey, $TopTitle), @($split.Panel2, $BottomKey, $BottomTitle))) {
        $g = New-Grid $true
        $script:Grids[$pair[1]] = $g
        $pair[0].Controls.Add($g); $pair[0].Controls.Add((New-SectionLabel $pair[2]))
    }
    return $split
}

foreach ($k in @('db','server','settings','log')) { $script:Grids[$k] = New-Grid ($k -eq 'log') }
Add-Tab 'Databases' 'db' $Grids['db']
Add-Tab 'Server checks' 'server' $Grids['server']
Add-Tab 'Settings' 'settings' $Grids['settings']
Add-Tab 'Backup retention' 'ret' (New-SplitGrids 'retsum' 'Totals per backup type (files made / on storage / policy)' 'ret' 'Per database and type (opens from the daily snapshot; F5 on this tab = live from msdb)')
$olaPanel = New-Object System.Windows.Forms.Panel; $olaPanel.Dock = 'Fill'
$script:OlaNote = New-Object System.Windows.Forms.Label
$OlaNote.Dock = 'Top'; $OlaNote.Height = S 34; $OlaNote.ForeColor = [System.Drawing.Color]::FromArgb(180, 83, 9); $OlaNote.TextAlign = 'MiddleLeft'
$olaOuter = New-SplitGrids 'ola' 'Commands per type (30 days)' 'olafail' 'Commands with errors (CORRUPTION FOUND / FAILED / SKIPPED)'
$olaInner = New-SplitGrids 'oladb' 'Last successful CHECKDB / FULL / DIFF / LOG per database (all imported history)' 'olasrc' 'Where dbo.CommandLog was found'
$olaMain = New-Object System.Windows.Forms.SplitContainer; $olaMain.Dock = 'Fill'; $olaMain.Orientation = 'Vertical'; $olaMain.SplitterWidth = S 8
$olaMain.Panel1.Controls.Add($olaOuter); $olaMain.Panel2.Controls.Add($olaInner)
$olaPanel.Controls.Add($olaMain); $olaPanel.Controls.Add($OlaNote)
Add-Tab 'Ola CommandLog' 'ola' $olaPanel
$mailLeft  = New-SplitGrids 'mailday' 'MON emails per day (alerts / digests / heartbeats / skipped / failures)' 'maillast' 'Last 100 MON emails'
$mailRight = New-SplitGrids 'mailsrv' 'ALL Database Mail on this server per day: MON vs others (OPS.monitor rev 4, jobs, apps)' 'mailsubj' 'Who sends the most (by subject, all senders)'
$mailMain = New-Object System.Windows.Forms.SplitContainer; $mailMain.Dock = 'Fill'; $mailMain.Orientation = 'Vertical'; $mailMain.SplitterWidth = S 8
$mailMain.Panel1.Controls.Add($mailLeft); $mailMain.Panel2.Controls.Add($mailRight)
Add-Tab 'Emails' 'mail' $mailMain
Add-Tab 'Change log' 'log' $Grids['log']

# --- status bar ---
$status = New-Object System.Windows.Forms.StatusStrip
$status.SizingGrip = $false; $status.BackColor = $ColPanel; $status.Font = $UiSmall
$status.Padding = New-Object System.Windows.Forms.Padding((S 10), (S 3), (S 10), (S 3))
$script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$StatusLabel.Text = 'Not connected.'; $StatusLabel.ForeColor = $ColText; $StatusLabel.Spring = $true; $StatusLabel.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($StatusLabel)
# colour legend (right side of the status bar - never collides with the buttons)
function Add-LegendChip([string]$Text, [System.Drawing.Color]$Color, [string]$Caption) {
    $chip = New-Object System.Windows.Forms.ToolStripStatusLabel
    $chip.Text = $Text; $chip.BackColor = $Color; $chip.ForeColor = [System.Drawing.Color]::White; $chip.Font = $UiSmall
    $chip.Padding = New-Object System.Windows.Forms.Padding((S 6), 0, (S 6), 0)
    $chip.Margin = New-Object System.Windows.Forms.Padding((S 10), (S 2), (S 2), (S 2))
    $cap = New-Object System.Windows.Forms.ToolStripStatusLabel
    $cap.Text = $Caption; $cap.ForeColor = $ColMuted; $cap.Font = $UiSmall
    [void]$status.Items.Add($chip); [void]$status.Items.Add($cap)
}
Add-LegendChip 'ON'   $BadgeOn   'enabled'
Add-LegendChip 'OFF'  $BadgeOff  'disabled'
Add-LegendChip 'n/a'  $BadgeNA   'not defined / not applicable'
Add-LegendChip 'ON *' $BadgeEdit 'changed, not applied'
$dpiLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$dpiLabel.Text = ('scale {0:P0}' -f $script:Scale); $dpiLabel.ForeColor = $ColMuted; $dpiLabel.Font = $UiSmall
$dpiLabel.Margin = New-Object System.Windows.Forms.Padding((S 14), 0, 0, 0)
[void]$status.Items.Add($dpiLabel)

$Form.Controls.Add($tabHost)
$Form.Controls.Add($sep)
$Form.Controls.Add($bar)
$Form.Controls.Add($top)
$Form.Controls.Add($status)

# --------------------------------------------------------------------------------------------
#  Events
# --------------------------------------------------------------------------------------------
foreach ($key in @('db','server','settings')) {
    $g = $script:Grids[$key]
    # Feature state badges: GREEN = ON, RED = OFF, GREY = not defined / n/a, ORANGE frame = pending change
    $g.Add_CellPainting({
        param($s, $e)
        if ($e.RowIndex -lt 0 -or -not (Test-BoolColumn $s $e.ColumnIndex)) { return }
        $drv = $s.Rows[$e.RowIndex].DataBoundItem
        if ($null -eq $drv) { return }
        $row = $drv.Row
        $colName = $s.Columns[$e.ColumnIndex].DataPropertyName
        $state = Get-FeatureState $row $colName
        $changed = Test-ValueChanged $row $colName
        $selected = ($e.State -band [System.Windows.Forms.DataGridViewElementStates]::Selected) -ne 0

        $back = if (($e.RowIndex % 2) -eq 1) { $s.AlternatingRowsDefaultCellStyle.BackColor } else { [System.Drawing.Color]::White }
        $bb = New-Object System.Drawing.SolidBrush $back
        $e.Graphics.FillRectangle($bb, $e.CellBounds); $bb.Dispose()
        # badge: fixed size, centred in the cell (same size in every column at every DPI)
        $bw = [Math]::Min($e.CellBounds.Width - (S 12), (S 56)); $bh = [Math]::Min($e.CellBounds.Height - (S 8), (S 20))
        $r = New-Object System.Drawing.Rectangle(($e.CellBounds.X + [int](($e.CellBounds.Width - $bw) / 2)), ($e.CellBounds.Y + [int](($e.CellBounds.Height - $bh) / 2)), $bw, $bh)
        $color = switch ($state) { 'ON' { $BadgeOn } 'OFF' { $BadgeOff } default { $BadgeNA } }
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $rad = S 4; $d = $rad * 2
        $path.AddArc($r.X, $r.Y, $d, $d, 180, 90); $path.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
        $path.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90); $path.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90); $path.CloseFigure()
        $brush = New-Object System.Drawing.SolidBrush $color
        $e.Graphics.FillPath($brush, $path); $brush.Dispose()
        if ($changed) { $pen = New-Object System.Drawing.Pen($BadgeEdit, (S 2)); $e.Graphics.DrawPath($pen, $path); $pen.Dispose() }
        if ($selected) { $pen = New-Object System.Drawing.Pen($BadgeSel, (S 1.5)); $e.Graphics.DrawRectangle($pen, $e.CellBounds.X + 1, $e.CellBounds.Y + 1, $e.CellBounds.Width - 3, $e.CellBounds.Height - 3); $pen.Dispose() }
        $path.Dispose()
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::Default
        $text = switch ($state) { 'ON' { 'ON' } 'OFF' { 'OFF' } default { 'n/a' } }
        if ($changed) { $text += ' *' }
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $GridBold, $r, [System.Drawing.Color]::White,
            [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter, SingleLine')
        $gp = New-Object System.Drawing.Pen($s.GridColor)
        $e.Graphics.DrawLine($gp, $e.CellBounds.Left, $e.CellBounds.Bottom - 1, $e.CellBounds.Right, $e.CellBounds.Bottom - 1); $gp.Dispose()
        $e.Handled = $true
    })
    # Single click (no Ctrl/Shift) on a badge toggles it
    $g.Add_CellMouseClick({
        param($s, $e)
        if ($e.RowIndex -lt 0 -or $e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        if ([System.Windows.Forms.Control]::ModifierKeys -ne [System.Windows.Forms.Keys]::None) { return }
        if (-not (Test-BoolColumn $s $e.ColumnIndex)) { return }
        $tabKey = $script:TabControl.SelectedTab.Tag
        $colName = $s.Columns[$e.ColumnIndex].DataPropertyName
        if (-not ($script:Editable[$tabKey] -contains $colName)) { return }
        $row = $s.Rows[$e.RowIndex].DataBoundItem.Row
        if ((Get-FeatureState $row $colName) -eq 'NA' -and $colName -ne 'monitored') {
            Set-Status 'Not applicable here (database not monitored, SIMPLE recovery for LOG, or dropped database).'
            return
        }
        $cur = $row.Item($colName)
        $row[$colName] = -not ($cur -is [bool] -and $cur)
        $s.InvalidateRow($e.RowIndex)
        Update-PendingLabel
    })
    $g.Add_CellValueChanged({ if (-not $script:Loading) { Update-PendingLabel } })
    $g.Add_DataError({ param($s, $e) $e.ThrowException = $false; Set-Status ('Invalid value: ' + $e.Exception.Message) })
    # Colors: changed = yellow, not monitored / not applicable = grey, OFF checks = amber
    $g.Add_CellFormatting({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $drv = $s.Rows[$e.RowIndex].DataBoundItem
        if ($null -eq $drv) { return }
        $row = $drv.Row
        $colName = $s.Columns[$e.ColumnIndex].DataPropertyName
        if (-not $row.Table.Columns.Contains($colName)) { return }
        if (Test-BoolColumn $s $e.ColumnIndex) { return }
        if (Test-ValueChanged $row $colName) { $e.CellStyle.BackColor = $ColChanged; return }
        if ($row.Table.Columns.Contains('monitored') -and $colName -ne 'monitored' -and $colName -ne 'database_name' -and -not $row.monitored) {
            $e.CellStyle.BackColor = $ColNA; $e.CellStyle.ForeColor = [System.Drawing.Color]::Gray; return
        }
        if ($colName -eq 'log_backup' -and $row.Table.Columns.Contains('recovery_model') -and [string]$row.recovery_model -ne 'FULL') {
            $e.CellStyle.BackColor = $ColNA; return
        }
        $v = $row.Item($colName)
        if ($v -is [bool] -and -not $v) { $e.CellStyle.BackColor = $ColOff }
        if ($colName -eq 'state' -and [string]$v -ne 'ONLINE') { $e.CellStyle.BackColor = $ColCrit }
    })
}

# Status coloring on read-only grids
foreach ($key in @('ret','olafail')) {
    $script:Grids[$key].Add_CellFormatting({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $name = $s.Columns[$e.ColumnIndex].Name
        if ($name -eq 'Status') {
            switch ([string]$e.Value) {
                'OK'     { $e.CellStyle.BackColor = $ColOk }
                'GAPS'   { $e.CellStyle.BackColor = $ColWarn }
                'N/A'    { $e.CellStyle.BackColor = $ColNA }
                'OFF'    { $e.CellStyle.BackColor = $ColNA }
                default  { $e.CellStyle.BackColor = $ColCrit }
            }
        }
        if ($name -eq 'Error' -and $null -ne $e.Value -and -not ($e.Value -is [System.DBNull])) { $e.CellStyle.BackColor = $ColCrit }
        if ($name -eq 'Outcome') {
            switch ([string]$e.Value) { 'SKIPPED' { $e.CellStyle.BackColor = $ColWarn } 'OK' { $e.CellStyle.BackColor = $ColOk } default { $e.CellStyle.BackColor = $ColCrit } }
        }
    })
}

$BtnConnect.Add_Click({
    try {
        $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $b['Data Source'] = $script:TxtServer.Text.Trim()
        $b['Initial Catalog'] = $Database
        $b['Application Name'] = 'MON Check Editor'
        $b['Encrypt'] = $true
        $b['TrustServerCertificate'] = $script:ChkTrust.Checked
        $b['Connect Timeout'] = 15
        if ($script:ChkWin.Checked) { $b['Integrated Security'] = $true }
        else { $b['User ID'] = $script:TxtLogin.Text.Trim(); $b['Password'] = $script:TxtPwd.Text }
        $script:ConnString = $b.ConnectionString
        $script:ServerLabel = $script:TxtServer.Text.Trim()
        $t = Get-MonTable "SELECT CASE WHEN SCHEMA_ID(N'mon') IS NULL THEN 0 ELSE 1 END AS ok, @@SERVERNAME AS srv;"
        if (-not $t.Rows[0].ok) { throw "Schema [mon] not found in database $Database. Run install/MON_Install.sql first." }
        $script:Loading = $false
        Save-Config
        $script:Form.Text = ('MON Check Editor - {0} ({1}).{2}' -f $script:ServerLabel, $t.Rows[0].srv, $Database)
        Invoke-RefreshAll
    } catch {
        $script:ConnString = $null
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'MON - connection failed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})
$BtnApply.Add_Click({ Invoke-ApplyChanges })
$TabControl.Add_SelectedIndexChanged({
    if (-not $script:ConnString) { return }
    $tab = $script:TabControl.SelectedTab.Tag
    if ($tab -eq 'ret' -and -not $script:LoadedTabs['ret']) { Invoke-LoadRetention $false }
    elseif ($tab -eq 'ola' -and -not $script:LoadedTabs['ola']) { Invoke-LoadOla }
    elseif ($tab -eq 'mail' -and -not $script:LoadedTabs['mail']) { Invoke-LoadEmails }
})
$BtnRefresh.Add_Click({ if ($script:ConnString) { Invoke-RefreshAll } })
$BtnOn.Add_Click({ Set-SelectedCells $true })
foreach ($k in @('db','server')) { $script:Grids[$k].Add_CellValueChanged({ param($s, $e) if ($e.RowIndex -ge 0) { $s.InvalidateRow($e.RowIndex) } }) }
$BtnOff.Add_Click({ Set-SelectedCells $false })
$BtnDiscard.Add_Click({
    foreach ($key in @('db','server','settings')) { if ($script:Tables[$key]) { $script:Tables[$key].RejectChanges() } }
    foreach ($g in $script:Grids.Values) { $g.Invalidate() }
    Update-PendingLabel
    Set-Status 'Changes discarded.'
})
$TxtFilter.Add_TextChanged({ Invoke-ApplyFilter })
$Form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'F5' -and $script:ConnString) { Invoke-RefreshAll; $e.Handled = $true }
    if ($e.Control -and $e.KeyCode -eq 'S' -and $script:BtnApply.Enabled) { Invoke-ApplyChanges; $e.Handled = $true }
    if ($e.KeyCode -eq 'Space' -and $script:TabControl.SelectedTab.Tag -eq 'db' -and $script:Grids['db'].SelectedCells.Count -gt 1) {
        # Space on a multi-cell selection toggles all selected checkboxes to the opposite of the first one
        $first = $script:Grids['db'].SelectedCells[0]
        $v = $first.Value
        if ($v -is [bool]) { Set-SelectedCells (-not $v); $e.Handled = $true; $e.SuppressKeyPress = $true }
    }
})
$Form.Add_FormClosing({
    param($s, $e)
    if ($script:ConnString -and (Get-PendingChanges).Count -gt 0) {
        $a = [System.Windows.Forms.MessageBox]::Show('You have changes that are not applied. Close anyway?', 'MON', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true }
    }
})

# --------------------------------------------------------------------------------------------
#  Start
# --------------------------------------------------------------------------------------------
$cfg = Read-Config
if ($Server) { $TxtServer.Text = $Server } elseif ($cfg) { $TxtServer.Text = $cfg.Server }
if ($cfg) {
    $TxtLogin.Text = $cfg.Login
    $ChkWin.Checked = [bool]$cfg.WindowsAuth
    $ChkTrust.Checked = [bool]$cfg.TrustCert
}
$Form.Add_Shown({ foreach ($sp in $script:Splits) { try { $sp.SplitterDistance = [int]($sp.Height * 0.32) } catch { } } })
$Form.Add_Shown({ if ($script:TxtServer.Text) { $script:TxtPwd.Focus() } else { $script:TxtServer.Focus() } })
[void]$Form.ShowDialog()
$Form.Dispose()
