<#
.SYNOPSIS
    MON Check Editor - checkbox editor for OPS.mon (rev 5.2) monitoring on MS-APP-STG.
 
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
[System.Windows.Forms.Application]::EnableVisualStyles()
 
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
$UiFont     = New-Object System.Drawing.Font('Segoe UI', 9)
$UiBold     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
 
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
        Set-Status ('Applied {0} change(s) at {1}. They take effect at the next 5-minute cycle.' -f $changes.Count, (Get-Date -Format 'HH:mm:ss'))
    } catch {
        try { $tx.Rollback() } catch { }
        [System.Windows.Forms.MessageBox]::Show(("Apply failed, nothing was saved:`r`n{0}" -f $_.Exception.Message), 'MON - error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    } finally {
        $c.Dispose()
    }
    Invoke-RefreshAll
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
    $g.RowHeadersWidth = 24
    $g.AutoSizeColumnsMode = 'DisplayedCells'
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.BorderStyle = 'None'
    $g.Font = $UiFont
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = $ColHeader
    $g.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $g.ColumnHeadersDefaultCellStyle.Font = $UiBold
    $g.ColumnHeadersHeightSizeMode = 'AutoSize'
    $g.ColumnHeadersDefaultCellStyle.WrapMode = 'True'
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
            $col.Width = 62
        }
    }
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
        if (($script:Editable[$tabKey] -contains $colName) -and
            ($g.Columns[$cell.ColumnIndex] -is [System.Windows.Forms.DataGridViewCheckBoxColumn])) {
            $drv = $g.Rows[$cell.RowIndex].DataBoundItem
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
SELECT c.database_name, ISNULL(s.recovery_model, N'?') AS recovery_model,
       CASE WHEN ISNULL(s.is_present, 1) = 0 THEN N'DROPPED' ELSE ISNULL(s.state_desc, N'?') END AS state,
       $cols,
       c.retention_days, c.storage_retention_days, c.notes, c.modified_utc, c.modified_by
FROM mon.DatabaseCheck AS c
LEFT JOIN mon.DatabaseStatus AS s ON s.database_name = c.database_name
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
        Invoke-ApplyFilter
    } finally {
        $script:Loading = $false
    }
    Update-PendingLabel
}
 
function Invoke-LoadReadOnly {
    try {
        $ds = Get-MonDataSet 'EXEC mon.usp_ShowBackupRetention @Live = 1;'
        $script:Grids['ret'].DataSource = $ds.Tables[0]
        $script:Grids['retsum'].DataSource = $ds.Tables[1]
    } catch { Set-Status ('Backup retention: ' + $_.Exception.Message) }
    try {
        $ds2 = Get-MonDataSet 'EXEC mon.usp_ShowOlaLog @Hours = 168;'
        $script:Grids['ola'].DataSource = $ds2.Tables[0]
        $script:Grids['olafail'].DataSource = $ds2.Tables[1]
    } catch { Set-Status ('Ola log: ' + $_.Exception.Message) }
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
    try {
        Invoke-LoadEditable
        Invoke-LoadReadOnly
        $dbs = $script:Tables['db'].Rows.Count
        $off = @($script:Tables['db'].Rows | Where-Object { -not $_.monitored }).Count
        Set-Status ('Connected to {0}.{1}  |  {2} databases ({3} not monitored)  |  loaded {4}' -f $script:ServerLabel, $Database, $dbs, $off, (Get-Date -Format 'HH:mm:ss'))
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
$Form.Size = New-Object System.Drawing.Size(1480, 860)
$Form.StartPosition = 'CenterScreen'
$Form.Font = $UiFont
$Form.KeyPreview = $true
 
# --- connection bar ---
$top = New-Object System.Windows.Forms.FlowLayoutPanel
$top.Dock = 'Top'; $top.Height = 38; $top.Padding = '6,6,6,0'; $top.WrapContents = $false
function Add-Label($Text) { $l = New-Object System.Windows.Forms.Label; $l.Text = $Text; $l.AutoSize = $true; $l.Margin = '6,6,2,0'; $top.Controls.Add($l) }
Add-Label 'Server:'
$script:TxtServer = New-Object System.Windows.Forms.TextBox; $TxtServer.Width = 380; $top.Controls.Add($TxtServer)
$script:ChkWin = New-Object System.Windows.Forms.CheckBox; $ChkWin.Text = 'Windows auth'; $ChkWin.AutoSize = $true; $ChkWin.Margin = '10,5,0,0'; $top.Controls.Add($ChkWin)
Add-Label 'Login:'
$script:TxtLogin = New-Object System.Windows.Forms.TextBox; $TxtLogin.Width = 140; $top.Controls.Add($TxtLogin)
Add-Label 'Password:'
$script:TxtPwd = New-Object System.Windows.Forms.TextBox; $TxtPwd.Width = 140; $TxtPwd.UseSystemPasswordChar = $true; $top.Controls.Add($TxtPwd)
$script:ChkTrust = New-Object System.Windows.Forms.CheckBox; $ChkTrust.Text = 'Trust server certificate'; $ChkTrust.AutoSize = $true; $ChkTrust.Margin = '10,5,0,0'; $ChkTrust.Checked = $true; $top.Controls.Add($ChkTrust)
$BtnConnect = New-Object System.Windows.Forms.Button; $BtnConnect.Text = 'Connect'; $BtnConnect.Width = 90; $BtnConnect.Margin = '10,2,0,0'; $top.Controls.Add($BtnConnect)
$ChkWin.Add_CheckedChanged({ $script:TxtLogin.Enabled = -not $script:ChkWin.Checked; $script:TxtPwd.Enabled = -not $script:ChkWin.Checked })
 
# --- action bar ---
$bar = New-Object System.Windows.Forms.FlowLayoutPanel
$bar.Dock = 'Top'; $bar.Height = 38; $bar.Padding = '6,4,6,0'; $bar.WrapContents = $false
$lf = New-Object System.Windows.Forms.Label; $lf.Text = 'Filter:'; $lf.AutoSize = $true; $lf.Margin = '6,7,2,0'; $bar.Controls.Add($lf)
$script:TxtFilter = New-Object System.Windows.Forms.TextBox; $TxtFilter.Width = 180; $TxtFilter.Margin = '0,4,12,0'; $bar.Controls.Add($TxtFilter)
function Add-Button($Text, $Width) { $b = New-Object System.Windows.Forms.Button; $b.Text = $Text; $b.Width = $Width; $b.Height = 28; $bar.Controls.Add($b); return $b }
$BtnOn      = Add-Button 'Check selected' 120
$BtnOff     = Add-Button 'Uncheck selected' 120
$script:BtnDiscard = Add-Button 'Discard changes' 120
$BtnRefresh = Add-Button 'Refresh (F5)' 110
$script:BtnApply = Add-Button 'APPLY' 130
$BtnApply.Font = $UiBold; $BtnApply.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235); $BtnApply.ForeColor = [System.Drawing.Color]::White
$BtnApply.FlatStyle = 'Flat'; $BtnApply.Enabled = $false; $BtnDiscard.Enabled = $false
$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Select cells (drag / Ctrl / Shift) then Check/Uncheck.  Yellow = changed, not yet applied.  Grey = not monitored / not applicable.'
$hint.AutoSize = $true; $hint.Margin = '14,8,0,0'; $hint.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128); $bar.Controls.Add($hint)
 
# --- tabs ---
$script:TabControl = New-Object System.Windows.Forms.TabControl
$TabControl.Dock = 'Fill'
function Add-Tab([string]$Title, [string]$Key, [System.Windows.Forms.Control]$Content) {
    $t = New-Object System.Windows.Forms.TabPage
    $t.Text = $Title; $t.Tag = $Key; $t.Padding = '4,4,4,4'
    $t.Controls.Add($Content)
    $script:TabControl.TabPages.Add($t)
}
function New-SplitGrids([string]$TopKey, [string]$TopTitle, [string]$BottomKey, [string]$BottomTitle) {
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'
    $script:Splits += $split
    foreach ($pair in @(@($split.Panel1, $TopKey, $TopTitle), @($split.Panel2, $BottomKey, $BottomTitle))) {
        $g = New-Grid $true
        $script:Grids[$pair[1]] = $g
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $pair[2]; $lbl.Dock = 'Top'; $lbl.Height = 22; $lbl.Font = $UiBold
        $pair[0].Controls.Add($g); $pair[0].Controls.Add($lbl)
    }
    return $split
}
 
foreach ($k in @('db','server','settings','log')) { $script:Grids[$k] = New-Grid ($k -eq 'log') }
Add-Tab 'Databases - what is checked' 'db' $Grids['db']
Add-Tab 'Server checks' 'server' $Grids['server']
Add-Tab 'Settings / thresholds' 'settings' $Grids['settings']
Add-Tab 'Backup retention' 'ret' (New-SplitGrids 'retsum' 'Totals per backup type (files made / on storage / policy)' 'ret' 'Per database and type (live)')
Add-Tab 'Ola CommandLog (7 days)' 'ola' (New-SplitGrids 'ola' 'Commands per type' 'olafail' 'Failed commands')
Add-Tab 'Change log (audit)' 'log' $Grids['log']
 
# --- status bar ---
$status = New-Object System.Windows.Forms.StatusStrip
$script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$StatusLabel.Text = 'Not connected.'
[void]$status.Items.Add($StatusLabel)
 
$Form.Controls.Add($TabControl)
$Form.Controls.Add($bar)
$Form.Controls.Add($top)
$Form.Controls.Add($status)
 
# --------------------------------------------------------------------------------------------
#  Events
# --------------------------------------------------------------------------------------------
foreach ($key in @('db','server','settings')) {
    $g = $script:Grids[$key]
    # Commit checkbox clicks immediately (default is on cell leave)
    $g.Add_CurrentCellDirtyStateChanged({
        param($s, $e)
        if ($s.IsCurrentCellDirty -and $s.CurrentCell -is [System.Windows.Forms.DataGridViewCheckBoxCell]) {
            [void]$s.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
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
        if (-not $t.Rows[0].ok) { throw "Schema [mon] not found in database $Database. Install stage_monitoring_mon_v5.2.sql first." }
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
$BtnRefresh.Add_Click({ if ($script:ConnString) { Invoke-RefreshAll } })
$BtnOn.Add_Click({ Set-SelectedCells $true })
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
$Form.Add_Shown({ foreach ($sp in $script:Splits) { try { $sp.SplitterDistance = [int]($sp.Height * 0.3) } catch { } } })
$Form.Add_Shown({ if ($script:TxtServer.Text) { $script:TxtPwd.Focus() } else { $script:TxtServer.Focus() } })
[void]$Form.ShowDialog()
$Form.Dispose()
