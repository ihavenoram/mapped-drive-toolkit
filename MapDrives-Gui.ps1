<#
=========================================================
Script Name: MapDrives-Gui
Description: The Mapped Drive Toolkit GUI (WinForms). One window, two tabs:

               Drives & Apply       WHAT to map: paste/load/collect a drive profile
                                    (Collect detects the authenticating account),
                                    edit the drive grid, set credentials, then
                                    Apply now (maps in the user's session), Create on
                                    Desktop, Save .json, Export Atera (the injector),
                                    Export User Fixer, Test creds.

               Doctor & Diagnostics WHY it's broken: the user's current mappings,
                                    Drive Doctor (Red X, ghosts, GPO origin), "Why
                                    won't it map?" (Diagnose-MapError), DNS /
                                    connectivity / device diagnosis, FULL AUDIT,
                                    credential audit and the safe fixes.

             Runs as SYSTEM in ScreenConnect Backstage or as the user. Anything that
             touches mapped drives runs INSIDE the interactive user's session (a net
             use drive letter belongs to the logon session that made it).

             v3.0 merged the old Repair-DriveMappings-Gui.ps1 into this file.
Requires:    Windows PowerShell 5.1 (WinForms). MappedDriveToolkit.psm1 beside it.
             Launch: Launch-MapDrives-Gui.cmd, or in Backstage:
             powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "<path>\MapDrives-Gui.ps1"
=========================================================
#>
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ModulePath = Join-Path $PSScriptRoot 'MappedDriveToolkit.psm1'
Import-Module $script:ModulePath -Force

# --------------------------- module freshness guard ------------------
# A stale MappedDriveToolkit.psm1 (old staged copy) would fail later with a cryptic
# "term not recognized". Catch it up front with a clear fix.
$requiredFns = @(
    'Get-ToolkitVersion','Get-InteractiveUser','ConvertFrom-DriveMapJson','ConvertTo-DriveMapJson',
    'ConvertTo-NormalizedLetter','Get-UncHost','New-MapDrivesCmdContent','Write-MapDrivesCmd','Register-MapDrivesLogonTask',
    'Get-CurrentDriveMappings','Get-DriveMappingState','Resolve-DriveCredentials','Get-InferredCredential','Invoke-MapDrivesNow',
    'Invoke-CommandInUserSession','Invoke-DirInUserSession','Invoke-ScriptInUserSession','Test-DnsHealth','Test-DnsServer',
    'Get-DnsServerHealth','Test-ShareConnectivity','Resolve-ShareDevice','Get-SmbClientHealth','Test-ShareCredential',
    'Clear-SavedCredential','Clear-NameCaches','Get-DriveDoctorReport','Repair-RedXCache','Clear-GhostDrive',
    'Get-DriveOriginGpo','Get-CredentialAudit','Get-KerberosAudit','Get-DomainHealth','Test-ShareAccessMatrix',
    'Clear-HostSession','Set-LinkedConnections','Get-SmbClientEvents','New-UserFixerScript','Invoke-DriveAudit'
)
$missingFns = @($requiredFns | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if($missingFns.Count){
    [System.Windows.Forms.MessageBox]::Show(
        ("This copy of MappedDriveToolkit.psm1 is OUT OF DATE - it is missing:`n  {0}`n`nLoaded from:`n  {1}`n`nFIX: copy the whole toolkit folder again (its files belong together), then relaunch." -f ($missingFns -join ', '),$script:ModulePath),
        'Mapped Drive Toolkit - module out of date','OK','Error') | Out-Null
    return
}
$script:ToolkitVer = try { Get-ToolkitVersion } catch { '?' }

# --------------------------- context detection -----------------------
$script:CurrentName     = ([Security.Principal.WindowsIdentity]::GetCurrent()).Name
$script:IsSystem        = (([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value -eq 'S-1-5-18')
$script:IsAdmin         = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:InteractiveUser = $null
try { $script:InteractiveUser = Get-InteractiveUser } catch {}
$script:Site       = "$env:COMPUTERNAME"
$script:TokenBoxes = @{}      # token name -> TextBox
$script:LastDoctor = @()      # last Get-DriveDoctorReport rows
$script:Anchors    = New-Object System.Collections.ArrayList   # applied on Shown (see below)

# --------------------------- control helpers -------------------------
function Set-Anchor($Control,[string]$Anchor){
    # Anchors are applied late: TabPages start at a default size and grow when laid
    # out, so an anchor set now would make Right/Bottom-anchored controls inflate
    # (memory: winforms-anchor-and-case-traps). Form-level ones apply on Shown, each
    # tab page's the first time that page is shown (Apply-Anchors).
    [void]$script:Anchors.Add(@($Control,$Anchor))
}
function Get-AnchorRoot($Control){
    $p=$Control.Parent
    while($p -and -not ($p -is [System.Windows.Forms.TabPage]) -and -not ($p -is [System.Windows.Forms.Form])){ $p=$p.Parent }
    $p
}
function Apply-Anchors($Root){
    foreach($a in @($script:Anchors)){
        if([object]::ReferenceEquals((Get-AnchorRoot $a[0]),$Root)){
            $a[0].Anchor=[System.Windows.Forms.AnchorStyles]$a[1]
        }
    }
}
function New-Label($Parent,[string]$Text,[int]$X,[int]$Y,[bool]$Bold=$false){
    $l=New-Object System.Windows.Forms.Label
    $l.Text=$Text; $l.Location=New-Object System.Drawing.Point($X,$Y)
    # AutoSize: the box shrinks to the text, so a label can never paint over the
    # control beside it, and text is never clipped at higher DPI.
    $l.AutoSize=$true
    if($Bold){ $l.Font=New-Object System.Drawing.Font($l.Font,[System.Drawing.FontStyle]::Bold) }
    $Parent.Controls.Add($l); $l
}
function New-Button($Parent,[string]$Text,[int]$X,[int]$Y,[int]$W=120){
    $b=New-Object System.Windows.Forms.Button
    $b.Text=$Text; $b.Location=New-Object System.Drawing.Point($X,$Y)
    $b.Size=New-Object System.Drawing.Size($W,28)
    $Parent.Controls.Add($b); $b
}

# --------------------------- form + banner ---------------------------
$form               = New-Object System.Windows.Forms.Form
$form.Text          = "Mapped Drive Toolkit v$($script:ToolkitVer)"
$form.Size          = New-Object System.Drawing.Size(1010, 720)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(900, 600)

# Form layout is DOCKED (banner top, status bottom, tabs fill), so nothing at form
# level can overlap; only controls inside the tab pages use anchors.
$lblBanner = New-Object System.Windows.Forms.Label
$lblBanner.Dock = 'Top'; $lblBanner.Height = 34; $lblBanner.AutoSize = $false
$lblBanner.Padding = New-Object System.Windows.Forms.Padding(10,0,0,0); $lblBanner.TextAlign = 'MiddleLeft'
$lblBanner.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$ctxTag = if($script:IsSystem){'SYSTEM'}elseif($script:IsAdmin){'elevated user'}else{'standard user'}
$iu = if($script:InteractiveUser){$script:InteractiveUser}else{'(none logged on)'}
$lblBanner.Text = "Context: $($script:CurrentName)  [$ctxTag]      Interactive user: $iu      Host: $env:COMPUTERNAME      Toolkit v$($script:ToolkitVer)"
if($script:IsSystem -and -not $script:InteractiveUser){ $lblBanner.ForeColor=[System.Drawing.Color]::Firebrick; $lblBanner.Text += '   - no user session to map into!' }
elseif($script:IsSystem){ $lblBanner.ForeColor=[System.Drawing.Color]::DarkGreen }
$form.Controls.Add($lblBanner)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabDrives = New-Object System.Windows.Forms.TabPage; $tabDrives.Text = 'Drives && Apply'
$tabDoctor = New-Object System.Windows.Forms.TabPage; $tabDoctor.Text = 'Doctor && Diagnostics'
$tabLog    = New-Object System.Windows.Forms.TabPage; $tabLog.Text    = 'Session log'
$tabs.TabPages.AddRange(@($tabDrives,$tabDoctor,$tabLog))
$form.Controls.Add($tabs)

# =====================================================================
# TAB 1 - DRIVES & APPLY
# =====================================================================
$P = $tabDrives
New-Label $P 'Drive profile JSON (Collect from PC, Load, or paste a saved profile):' 8 8 $true | Out-Null
$txtJson = New-Object System.Windows.Forms.TextBox
$txtJson.Multiline=$true; $txtJson.ScrollBars='Both'; $txtJson.WordWrap=$false
$txtJson.Font=New-Object System.Drawing.Font('Consolas',9)
$txtJson.Location=New-Object System.Drawing.Point(8,30); $txtJson.Size=New-Object System.Drawing.Size(630,86)
$P.Controls.Add($txtJson)

$btnParse   = New-Button $P 'Parse JSON'      652 30 100
$btnLoad    = New-Button $P 'Load .json...'   756 30 100
$btnCollect = New-Button $P 'Collect from PC' 860 30 108
$btnCollect.Font=New-Object System.Drawing.Font($btnCollect.Font,[System.Drawing.FontStyle]::Bold)

# ---- drive grid (replaces the old checkbox panel AND the old Quick Add) ----
New-Label $P 'Drives:' 8 128 $true | Out-Null
$btnStd    = New-Button $P 'Standard set' 70  122 96
$btnAll    = New-Button $P 'Select all'   170 122 82
$btnClr    = New-Button $P 'Clear'        256 122 64
$btnAddRow = New-Button $P '+ Row'        420 122 70
$btnDelRow = New-Button $P 'Remove Row'   494 122 96

$dgvDrives = New-Object System.Windows.Forms.DataGridView
$dgvDrives.Location = New-Object System.Drawing.Point(8,154)
$dgvDrives.Size = New-Object System.Drawing.Size(630,282)
$dgvDrives.AllowUserToAddRows=$false; $dgvDrives.AllowUserToDeleteRows=$false
$dgvDrives.RowHeadersVisible=$false; $dgvDrives.SelectionMode='FullRowSelect'; $dgvDrives.MultiSelect=$true
$dgvDrives.AutoSizeColumnsMode='None'; $dgvDrives.ShowCellToolTips=$true
$colUse = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $colUse.Name='gUse'; $colUse.HeaderText='Use'; $colUse.Width=38
[void]$dgvDrives.Columns.Add($colUse)
[void]$dgvDrives.Columns.Add('gLetter','Drv');   $dgvDrives.Columns['gLetter'].Width=40
[void]$dgvDrives.Columns.Add('gUnc','UNC path (\\server\share\folder)'); $dgvDrives.Columns['gUnc'].Width=228
[void]$dgvDrives.Columns.Add('gLabel','Label');  $dgvDrives.Columns['gLabel'].Width=104
[void]$dgvDrives.Columns.Add('gGroup','Group');  $dgvDrives.Columns['gGroup'].Width=66
[void]$dgvDrives.Columns.Add('gAuth','Authenticates as'); $dgvDrives.Columns['gAuth'].Width=132
$dgvDrives.Columns['gAuth'].ReadOnly=$true
$dgvDrives.Columns['gAuth'].DefaultCellStyle.ForeColor=[System.Drawing.Color]::DimGray
$P.Controls.Add($dgvDrives)

# ---- credentials (shared - the Doctor tab reads Target/User too) ----
$grpCred=New-Object System.Windows.Forms.GroupBox
$grpCred.Text='Credentials'; $grpCred.Location=New-Object System.Drawing.Point(652,66); $grpCred.Size=New-Object System.Drawing.Size(316,158)
$P.Controls.Add($grpCred)
$lblMode=New-Object System.Windows.Forms.Label; $lblMode.Text='Mode'; $lblMode.Location=New-Object System.Drawing.Point(10,25); $lblMode.Size=New-Object System.Drawing.Size(60,18)
$cmbMode=New-Object System.Windows.Forms.ComboBox; $cmbMode.DropDownStyle='DropDownList'; [void]$cmbMode.Items.AddRange(@('cmdkey','inline','none'))
$cmbMode.Location=New-Object System.Drawing.Point(76,22); $cmbMode.Size=New-Object System.Drawing.Size(226,22); $cmbMode.SelectedItem='cmdkey'
$lblTarget=New-Object System.Windows.Forms.Label; $lblTarget.Text='Target'; $lblTarget.Location=New-Object System.Drawing.Point(10,53); $lblTarget.Size=New-Object System.Drawing.Size(60,18)
$txtTarget=New-Object System.Windows.Forms.TextBox; $txtTarget.Location=New-Object System.Drawing.Point(76,50); $txtTarget.Size=New-Object System.Drawing.Size(226,22)
$lblUser=New-Object System.Windows.Forms.Label; $lblUser.Text='User'; $lblUser.Location=New-Object System.Drawing.Point(10,81); $lblUser.Size=New-Object System.Drawing.Size(60,18)
$txtUser=New-Object System.Windows.Forms.TextBox; $txtUser.Location=New-Object System.Drawing.Point(76,78); $txtUser.Size=New-Object System.Drawing.Size(226,22)
$lblPass=New-Object System.Windows.Forms.Label; $lblPass.Text='Password'; $lblPass.Location=New-Object System.Drawing.Point(10,109); $lblPass.Size=New-Object System.Drawing.Size(62,18)
$txtPass=New-Object System.Windows.Forms.TextBox; $txtPass.Location=New-Object System.Drawing.Point(76,106); $txtPass.Size=New-Object System.Drawing.Size(226,22); $txtPass.UseSystemPasswordChar=$true
$chkShowPass=New-Object System.Windows.Forms.CheckBox; $chkShowPass.Text='Show'; $chkShowPass.Location=New-Object System.Drawing.Point(76,132); $chkShowPass.Size=New-Object System.Drawing.Size(70,20)
$chkShowPass.Add_CheckedChanged({ $txtPass.UseSystemPasswordChar=(-not $chkShowPass.Checked) })
$grpCred.Controls.AddRange(@($lblMode,$cmbMode,$lblTarget,$txtTarget,$lblUser,$txtUser,$lblPass,$txtPass,$chkShowPass))
$tipCred=New-Object System.Windows.Forms.ToolTip; $tipCred.AutoPopDelay=20000
$tipCred.SetToolTip($cmbMode,"cmdkey = save the credential (NAS / shared account)`r`ninline = credentials on each net use line (server local account)`r`nnone   = no credentials (matched account / domain SSO)")
$tipCred.SetToolTip($txtUser,'Qualify it: SERVER\user or IP\user (Windows 11 24H2 / workgroup servers reject a bare name).')

# ---- options ----
$grpOpt=New-Object System.Windows.Forms.GroupBox
$grpOpt.Text='Options'; $grpOpt.Location=New-Object System.Drawing.Point(652,230); $grpOpt.Size=New-Object System.Drawing.Size(316,92)
$P.Controls.Add($grpOpt)
$chkTask=New-Object System.Windows.Forms.CheckBox; $chkTask.Text='Deploy at-logon task (default off)'; $chkTask.Location=New-Object System.Drawing.Point(10,18); $chkTask.Size=New-Object System.Drawing.Size(296,20)
$chkIcon=New-Object System.Windows.Forms.CheckBox; $chkIcon.Text='Show "This PC" icon (default off)'; $chkIcon.Location=New-Object System.Drawing.Point(10,40); $chkIcon.Size=New-Object System.Drawing.Size(296,20)
$chkExpl=New-Object System.Windows.Forms.CheckBox; $chkExpl.Text='Restart Explorer after mapping'; $chkExpl.Location=New-Object System.Drawing.Point(10,62); $chkExpl.Size=New-Object System.Drawing.Size(296,20)
$grpOpt.Controls.AddRange(@($chkTask,$chkIcon,$chkExpl))

# ---- token values ----
$grpTok=New-Object System.Windows.Forms.GroupBox
$grpTok.Text='Token values (e.g. USERFOLDER)'; $grpTok.Location=New-Object System.Drawing.Point(652,328); $grpTok.Size=New-Object System.Drawing.Size(316,108)
$P.Controls.Add($grpTok)
# GroupBox has no AutoScroll - scroll via an inner Panel.
$pnlTok=New-Object System.Windows.Forms.Panel
$pnlTok.Location=New-Object System.Drawing.Point(6,16); $pnlTok.Size=New-Object System.Drawing.Size(304,86); $pnlTok.AutoScroll=$true
$grpTok.Controls.Add($pnlTok)

# ---- actions ----
$y1=446
$btnPreview  = New-Button $P 'Preview'           8   $y1 90
$btnCreate   = New-Button $P 'Create on Desktop' 102 $y1 132
$btnSaveJson = New-Button $P 'Save .json...'     238 $y1 100
$btnTestCred = New-Button $P 'Test creds'        342 $y1 96
$btnApplyNow = New-Button $P 'Apply now'         442 $y1 110
$btnApplyNow.Font=New-Object System.Drawing.Font($btnApplyNow.Font,[System.Drawing.FontStyle]::Bold)
$chkSaveCmd=New-Object System.Windows.Forms.CheckBox
$chkSaveCmd.Text='Also save MAPDRIVES.CMD (Public Desktop)'; $chkSaveCmd.Checked=$false
$chkSaveCmd.Location=New-Object System.Drawing.Point(560,($y1+5)); $chkSaveCmd.AutoSize=$true
$P.Controls.Add($chkSaveCmd)
$y2=$y1+34
$btnAtera     = New-Button $P 'Export Atera...'       8   $y2 130
$btnUserFixer = New-Button $P 'Export User Fixer...'  142 $y2 150
$lblExportHint = New-Label $P 'Export Atera = the injector (Run As: System): maps in the user''s session; the save / logon-task options apply.' 300 ($y2+6)
$lblExportHint.ForeColor=[System.Drawing.Color]::DimGray

$yGui=$y2+40
New-Label $P 'Launch GUI (Backstage):' 8 ($yGui+4) | Out-Null
$txtGui=New-Object System.Windows.Forms.TextBox
$txtGui.ReadOnly=$true; $txtGui.Font=New-Object System.Drawing.Font('Consolas',9)
$txtGui.Text='powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "C:\temp\mapdrives\MapDrives-Gui.ps1"'
$txtGui.Location=New-Object System.Drawing.Point(160,$yGui); $txtGui.Size=New-Object System.Drawing.Size(712,22)
$P.Controls.Add($txtGui)
$btnGuiCopy = New-Button $P 'Copy' 878 ($yGui-2) 90

# =====================================================================
# TAB 2 - DOCTOR & DIAGNOSTICS
# =====================================================================
$Q = $tabDoctor
New-Label $Q 'Current mappings (user''s):' 8 10 $true | Out-Null
$btnAnalyze = New-Button $Q 'Analyze'       316 6 96
$btnDir     = New-Button $Q 'Dir (as user)' 416 6 100
$btnRefresh = New-Button $Q 'Refresh'       520 6 92

$dgvCurrent = New-Object System.Windows.Forms.DataGridView
$dgvCurrent.Location = New-Object System.Drawing.Point(8,38)
$dgvCurrent.Size = New-Object System.Drawing.Size(604,196)
$dgvCurrent.AllowUserToAddRows=$false; $dgvCurrent.AllowUserToDeleteRows=$false; $dgvCurrent.ReadOnly=$true
$dgvCurrent.RowHeadersVisible=$false; $dgvCurrent.SelectionMode='FullRowSelect'; $dgvCurrent.MultiSelect=$false
$dgvCurrent.AutoSizeColumnsMode='None'
[void]$dgvCurrent.Columns.Add('cLetter','Drv'); [void]$dgvCurrent.Columns.Add('cUnc','UNC path')
[void]$dgvCurrent.Columns.Add('cStatus','Status'); [void]$dgvCurrent.Columns.Add('cUser','User')
$dgvCurrent.Columns['cLetter'].Width=40; $dgvCurrent.Columns['cUnc'].Width=320
$dgvCurrent.Columns['cStatus'].Width=100; $dgvCurrent.Columns['cUser'].Width=124
$Q.Controls.Add($dgvCurrent)

# Per-drive actions (act on the selected current-mapping row).
$btnFixRedX  = New-Button $Q 'Fix Red X'          8   242 96
$btnRelGhost = New-Button $Q 'Release ghost'      108 242 108
$btnRemapSel = New-Button $Q 'Remap selected'     220 242 116
$btnGpo      = New-Button $Q 'Check GPO origin'   340 242 128
$btnWhyMap   = New-Button $Q "Why won't it map?"  472 242 140
$btnWhyMap.Font=New-Object System.Drawing.Font($btnWhyMap.Font,[System.Drawing.FontStyle]::Bold)

New-Label $Q 'Results:' 8 282 $true | Out-Null
$rtbDiag = New-Object System.Windows.Forms.RichTextBox
$rtbDiag.Location = New-Object System.Drawing.Point(8,302)
$rtbDiag.Size = New-Object System.Drawing.Size(604,262)
$rtbDiag.ReadOnly=$true; $rtbDiag.Font=New-Object System.Drawing.Font('Consolas',8.5)
$Q.Controls.Add($rtbDiag)

# Diagnose (read-only) first, then safe fixes, then the disruptive ones.
New-Label $Q 'Diagnose (read-only):' 626 10 $true | Out-Null
$bx1=626; $bx2=800; $bw=168
$btnDiag      = New-Button $Q 'Diagnose hosts'      $bx1 32  $bw
$btnFullAudit = New-Button $Q 'FULL AUDIT'          $bx2 32  $bw
$btnCredAudit = New-Button $Q 'Credential audit'    $bx1 64  $bw
$btnTestDns   = New-Button $Q 'Test DNS servers'    $bx2 64  $bw
$btnViewConn  = New-Button $Q 'View connections'    $bx1 96  $bw
$btnSaveRep   = New-Button $Q 'Save report...'      $bx2 96  $bw
$btnFullAudit.Font = New-Object System.Drawing.Font($btnFullAudit.Font,[System.Drawing.FontStyle]::Bold)
New-Label $Q 'Safe fixes:' 626 138 $true | Out-Null
$btnFlush     = New-Button $Q 'Flush DNS'           $bx1 160 $bw
$btnClearNames= New-Button $Q 'Clear name caches'   $bx2 160 $bw
$btnPrivate   = New-Button $Q 'Set network Private' $bx1 192 $bw
$btnWks       = New-Button $Q 'Start Workstation'   $bx2 192 $bw
$btnGuest     = New-Button $Q 'Enable guest logons' $bx1 224 $bw
$btnFixLinked = New-Button $Q 'Fix linked conns'    $bx2 224 $bw
New-Label $Q 'Disruptive (asks first):' 626 266 $true | Out-Null
$btnClearCred = New-Button $Q 'Clear saved creds'   $bx1 288 $bw
$btnClearConn = New-Button $Q 'Clear host conns'    $bx2 288 $bw
$btnPurgeHost = New-Button $Q 'Purge host session'  $bx1 320 $bw
$lblDocHint = New-Label $Q ("Host for the connection/credential actions: the selected`r`ncurrent-mapping row, else the Credentials Target, else`r`nthe first drive on the Drives tab.") 626 362
$lblDocHint.ForeColor=[System.Drawing.Color]::DimGray

# =====================================================================
# TAB 3 - SESSION LOG (its own tab; the title counts entries not yet seen)
# =====================================================================
$pnlLogBar = New-Object System.Windows.Forms.Panel; $pnlLogBar.Dock='Top'; $pnlLogBar.Height=40
$tabLog.Controls.Add($pnlLogBar)
New-Label $pnlLogBar 'This session, newest at the bottom. Failures also pop up; the status bar shows the latest.' 8 13 | Out-Null
$btnCopyLog  = New-Button $pnlLogBar 'Copy log'    0 6 90
$btnSaveLog  = New-Button $pnlLogBar 'Save log...' 0 6 96
$btnClearLog = New-Button $pnlLogBar 'Clear'       0 6 70
function Update-LogBar {
    # Right-align the buttons (the bar is docked, so its width is real once laid out).
    $x=$pnlLogBar.ClientSize.Width - 8
    foreach($b in @($btnClearLog,$btnSaveLog,$btnCopyLog)){ $x -= $b.Width; $b.Left=$x; $x -= 6 }
}
$pnlLogBar.Add_Resize({ Update-LogBar })
$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Dock='Fill'; $rtbLog.ReadOnly=$true; $rtbLog.Font=New-Object System.Drawing.Font('Consolas',9)
$tabLog.Controls.Add($rtbLog)
$rtbLog.BringToFront()     # Fill must be in front of the Top-docked bar
$script:LogUnseen = 0

$status=New-Object System.Windows.Forms.StatusStrip
$lblStatus=New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Text='Collect from PC, Load or paste a profile on the Drives tab - or open Doctor & Diagnostics.'
[void]$status.Items.Add($lblStatus)
$form.Controls.Add($status)
function Set-Status([string]$m){ $lblStatus.Text=$m }

# Resize behaviour for the main panes (applied on Shown).
Set-Anchor $txtJson 'Top,Left,Right'
foreach($c in @($btnParse,$btnLoad,$btnCollect,$grpCred,$grpOpt,$grpTok)){ Set-Anchor $c 'Top,Right' }
Set-Anchor $dgvDrives 'Top,Bottom,Left,Right'
foreach($c in @($btnPreview,$btnCreate,$btnSaveJson,$btnTestCred,$btnApplyNow,$chkSaveCmd,$btnAtera,$btnUserFixer,$lblExportHint)){ Set-Anchor $c 'Bottom,Left' }
Set-Anchor $txtGui 'Bottom,Left,Right'; Set-Anchor $btnGuiCopy 'Bottom,Right'
Set-Anchor $dgvCurrent 'Top,Left,Right'
Set-Anchor $rtbDiag 'Top,Bottom,Left,Right'
foreach($c in @($btnDiag,$btnFullAudit,$btnCredAudit,$btnTestDns,$btnViewConn,$btnSaveRep,$btnFlush,$btnClearNames,$btnPrivate,$btnWks,$btnGuest,$btnFixLinked,$btnClearCred,$btnClearConn,$btnPurgeHost,$lblDocHint)){ Set-Anchor $c 'Top,Right' }

# --------------------------- output helpers --------------------------
function Add-RichLine($rtb,[string]$text){
    $color=$rtb.ForeColor
    if($text -match '\[FAIL\]'){ $color=[System.Drawing.Color]::Firebrick }
    elseif($text -match '\[WARN\]'){ $color=[System.Drawing.Color]::DarkOrange }
    elseif($text -match '\[OK\]'){ $color=[System.Drawing.Color]::ForestGreen }
    elseif($text -match '\[INFO\]'){ $color=[System.Drawing.Color]::DimGray }
    $rtb.SelectionStart=$rtb.TextLength; $rtb.SelectionLength=0
    $rtb.SelectionColor=$color
    $rtb.AppendText($text + "`r`n")
    $rtb.SelectionColor=$rtb.ForeColor
    $rtb.ScrollToCaret()
}
function Log([string]$text){
    Add-RichLine $rtbLog ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'),$text)
    # Count entries the tech hasn't seen yet on the tab title.
    if(-not [object]::ReferenceEquals($tabs.SelectedTab,$tabLog)){
        $script:LogUnseen++
        $tabLog.Text = "Session log ($($script:LogUnseen))"
    }
}
function Diag([string]$text){ Add-RichLine $rtbDiag $text }
function Show-Error([string]$title,[string]$msg){
    Log "[FAIL] $msg"
    [System.Windows.Forms.MessageBox]::Show($msg,$title,'OK','Error') | Out-Null
}
function Show-OutputDialog([string]$title,[string]$text){
    $f=New-Object System.Windows.Forms.Form; $f.Text=$title; $f.Size=New-Object System.Drawing.Size(760,540); $f.StartPosition='CenterParent'
    $t=New-Object System.Windows.Forms.TextBox; $t.Multiline=$true; $t.ScrollBars='Both'; $t.WordWrap=$false; $t.ReadOnly=$true
    $t.Font=New-Object System.Drawing.Font('Consolas',9); $t.Dock='Fill'; $t.Text=[string]$text
    $f.Controls.Add($t); [void]$f.ShowDialog(); $f.Dispose()
}
function Show-CmdPreview([string]$text){
    # Preview + Copy + Save as... (replaces the old 'Copy CMD text' / 'Save .cmd...'
    # buttons). Handlers in a function-built form need .GetNewClosure(), or their
    # captured controls are $null on click (memory: winforms-builder-needs-getnewclosure).
    $f=New-Object System.Windows.Forms.Form; $f.Text='MAPDRIVES.CMD preview'; $f.Size=New-Object System.Drawing.Size(760,560); $f.StartPosition='CenterParent'
    $t=New-Object System.Windows.Forms.TextBox; $t.Multiline=$true; $t.ScrollBars='Both'; $t.WordWrap=$false; $t.ReadOnly=$true
    $t.Font=New-Object System.Drawing.Font('Consolas',9); $t.Dock='Fill'; $t.Text=$text
    $bar=New-Object System.Windows.Forms.Panel; $bar.Dock='Bottom'; $bar.Height=40
    $bCopy=New-Object System.Windows.Forms.Button; $bCopy.Text='Copy'; $bCopy.Location=New-Object System.Drawing.Point(8,6); $bCopy.Size=New-Object System.Drawing.Size(90,28)
    $bSave=New-Object System.Windows.Forms.Button; $bSave.Text='Save as...'; $bSave.Location=New-Object System.Drawing.Point(104,6); $bSave.Size=New-Object System.Drawing.Size(100,28)
    $bClose=New-Object System.Windows.Forms.Button; $bClose.Text='Close'; $bClose.Location=New-Object System.Drawing.Point(210,6); $bClose.Size=New-Object System.Drawing.Size(90,28)
    $bCopy.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($t.Text); $f.Text='MAPDRIVES.CMD preview - copied to clipboard' }.GetNewClosure())
    $bSave.Add_Click({
        $dlg=New-Object System.Windows.Forms.SaveFileDialog; $dlg.Filter='CMD (*.cmd)|*.cmd|All files (*.*)|*.*'; $dlg.FileName='MAPDRIVES.CMD'
        if($dlg.ShowDialog() -eq 'OK'){ $t.Text | Set-Content -LiteralPath $dlg.FileName -Force -Encoding ASCII; $f.Text="MAPDRIVES.CMD preview - saved $($dlg.FileName)" }
    }.GetNewClosure())
    $bClose.Add_Click({ $f.Close() }.GetNewClosure())
    $bar.Controls.AddRange(@($bCopy,$bSave,$bClose))
    $f.Controls.Add($t); $f.Controls.Add($bar); $t.BringToFront()
    [void]$f.ShowDialog(); $f.Dispose()
}
function Confirm-Fix([string]$prompt){
    ([System.Windows.Forms.MessageBox]::Show($prompt,'Confirm','YesNo','Question') -eq 'Yes')
}
function Get-DProp($o,[string]$n){
    # StrictMode-safe property read; '' when absent/empty.
    if($null -eq $o){ return '' }
    $p=$o.PSObject.Properties[$n]
    if($p -and $null -ne $p.Value){ "$($p.Value)" } else { '' }
}
function Run-InUserOrHere([string]$cmdline,[int]$timeout=25){
    # net use / dir are session-scoped: from SYSTEM they MUST run in the user's
    # session to show what the user sees.
    if($script:IsSystem){
        $u=$script:InteractiveUser
        if(-not $u){ return '(no interactive user session to run in)' }
        $r=Invoke-CommandInUserSession -CommandLine $cmdline -User $u -TimeoutSec $timeout -OnPoll { [System.Windows.Forms.Application]::DoEvents() }
        if($r.Success){ return $r.Output } else { return "(could not capture: $($r.Message))" }
    } else {
        return (& cmd /c "$cmdline" 2>&1 | Out-String)
    }
}
function Invoke-ChildScript([string]$Path,[string]$ArgString,[int]$TimeoutSec=240){
    # Run another toolkit script in a child powershell.exe with no window and capture
    # its output, pumping the UI while it runs.
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "' + $Path + '" ' + $ArgString
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $p=[System.Diagnostics.Process]::Start($psi)
    $o=$p.StandardOutput.ReadToEndAsync(); $e=$p.StandardError.ReadToEndAsync()
    $deadline=(Get-Date).AddSeconds($TimeoutSec)
    while(-not $p.HasExited -and (Get-Date) -lt $deadline){ [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 150 }
    if(-not $p.HasExited){ try{ $p.Kill() }catch{}; return ("(timed out after {0} s)`r`n{1}" -f $TimeoutSec,$o.Result) }
    $o.Result + $(if($e.Result){ "`r`n" + $e.Result } else { '' })
}

# =====================================================================
# DRIVES TAB - logic
# =====================================================================
function Get-AuthText($d){
    $cu=Get-DProp $d 'CredUser'; $cs=Get-DProp $d 'CredSource'
    $t = if($cu){ "$cu ($cs)" } elseif($cs){ $cs } else { '' }
    if(Get-DProp $d 'CredNote'){ $t = "(!) $t" }
    $t
}
function Set-RowFromDrive($row,$d){
    $row.Cells['gUse'].Value    = ((Get-DProp $d 'Group') -in @('','standard'))
    $row.Cells['gLetter'].Value = Get-DProp $d 'Letter'
    $row.Cells['gUnc'].Value    = Get-DProp $d 'Unc'
    $row.Cells['gLabel'].Value  = Get-DProp $d 'Label'
    $row.Cells['gGroup'].Value  = $(if(Get-DProp $d 'Group'){ Get-DProp $d 'Group' } else { 'standard' })
    $row.Cells['gAuth'].Value   = Get-AuthText $d
    $tip=@()
    if(Get-DProp $d 'CredUser'){ $tip += "Authenticates as: $(Get-DProp $d 'CredUser')" }
    if(Get-DProp $d 'CredSource'){ $tip += "Source: $(Get-DProp $d 'CredSource')" }
    if(Get-DProp $d 'CredTarget'){ $tip += "Credential target: $(Get-DProp $d 'CredTarget')" }
    if(Get-DProp $d 'CredNote'){ $tip += ''; $tip += (Get-DProp $d 'CredNote') }
    $row.Cells['gAuth'].ToolTipText = ($tip -join "`r`n")
    $row.Tag = $d
}
function Set-GridFromDrives($drives){
    $dgvDrives.Rows.Clear()
    foreach($d in @($drives)){
        $i=$dgvDrives.Rows.Add()
        Set-RowFromDrive $dgvDrives.Rows[$i] $d
    }
}
function Get-GridDrives([switch]$IncludedOnly){
    # Grid -> normalized drive objects. Detection fields (CredUser etc.) come from the
    # row Tag and are cleared when the UNC is edited (see CellEndEdit).
    $dgvDrives.EndEdit() | Out-Null
    $out=@(); $seen=@{}
    foreach($row in $dgvDrives.Rows){
        $use=[bool]$row.Cells['gUse'].Value
        $L=ConvertTo-NormalizedLetter "$($row.Cells['gLetter'].Value)"
        $u="$($row.Cells['gUnc'].Value)".Trim()
        if(-not $L -and -not $u){ continue }                  # blank row
        if($IncludedOnly -and -not $use){ continue }
        if(-not $L){ throw "A drive row has no valid letter (UNC $u)." }
        if($u -notmatch '^\\\\[^\\]+\\[^\\]+'){ throw "Drive ${L}: needs a UNC like \\server\share (got '$u')." }
        if($seen.ContainsKey($L)){ throw "Drive letter ${L}: is listed more than once." }
        $seen[$L]=$true
        $lab="$($row.Cells['gLabel'].Value)".Trim(); if(-not $lab){ $lab="${L}: drive" }
        $grp="$($row.Cells['gGroup'].Value)".Trim().ToLower(); if(-not $grp){ $grp='standard' }
        $tokens=@(); foreach($m in [regex]::Matches($u,'%([A-Za-z0-9_]+)%')){ $tokens += $m.Groups[1].Value }
        $t=$row.Tag
        $out += [PSCustomObject]@{
            Letter=$L; Unc=$u; Label=$lab; Group=$grp
            Persistent=$(if($t -and $t.PSObject.Properties['Persistent']){ [bool]$t.Persistent } else { $true })
            Tokens=$tokens
            ConnectionUser=(Get-DProp $t 'ConnectionUser')
            CredUser=(Get-DProp $t 'CredUser'); CredSource=(Get-DProp $t 'CredSource'); CredTarget=(Get-DProp $t 'CredTarget'); CredNote=(Get-DProp $t 'CredNote')
        }
    }
    @($out)
}
function Get-UiProfile([switch]$IncludedOnly){
    $drives=@(Get-GridDrives -IncludedOnly:$IncludedOnly)
    [PSCustomObject]@{
        Site       = $script:Site
        Credential = [PSCustomObject]@{ Mode=[string]$cmbMode.SelectedItem; Target=$txtTarget.Text.Trim(); User=$txtUser.Text.Trim(); Password=$txtPass.Text }
        Options    = [PSCustomObject]@{ ShowThisPcIcon=$chkIcon.Checked; LogonTask=$chkTask.Checked; RestartExplorer=$chkExpl.Checked }
        Drives     = $drives
    }
}
function Rebuild-TokenBoxes {
    # Keep any value already typed for a token that still exists.
    $prev=@{}; foreach($k in $script:TokenBoxes.Keys){ $prev[$k]=$script:TokenBoxes[$k].Text }
    $pnlTok.Controls.Clear(); $script:TokenBoxes=@{}
    $tokens=@()
    foreach($row in $dgvDrives.Rows){ foreach($m in [regex]::Matches("$($row.Cells['gUnc'].Value)",'%([A-Za-z0-9_]+)%')){ if($tokens -notcontains $m.Groups[1].Value){ $tokens += $m.Groups[1].Value } } }
    $ty=4
    foreach($t in $tokens){
        $l=New-Object System.Windows.Forms.Label; $l.Text=$t; $l.Location=New-Object System.Drawing.Point(2,($ty+3)); $l.Size=New-Object System.Drawing.Size(110,18)
        $tb=New-Object System.Windows.Forms.TextBox; $tb.Location=New-Object System.Drawing.Point(116,$ty); $tb.Size=New-Object System.Drawing.Size(166,22)
        $tb.Text = if($prev.ContainsKey($t)){ $prev[$t] } else { '%USERNAME%' }
        $pnlTok.Controls.AddRange(@($l,$tb)); $script:TokenBoxes[$t]=$tb; $ty+=28
    }
    if($tokens.Count -eq 0){
        $l=New-Object System.Windows.Forms.Label; $l.Text='(none - add %TOKEN% to a UNC to use one)'; $l.Location=New-Object System.Drawing.Point(2,4); $l.AutoSize=$true
        $pnlTok.Controls.Add($l)
    }
}
function Get-TokenValues {
    $h=@{}; foreach($k in $script:TokenBoxes.Keys){ if($script:TokenBoxes[$k].Text){ $h[$k]=$script:TokenBoxes[$k].Text } }; $h
}
function Update-TargetPrefill {
    # Pre-fill the cmdkey Target from the first drive's UNC host when empty.
    if(-not [string]::IsNullOrWhiteSpace($txtTarget.Text)){ return }
    foreach($row in $dgvDrives.Rows){
        $h=Get-UncHost "$($row.Cells['gUnc'].Value)"
        if($h){ $txtTarget.Text=$h; return }
    }
}
function Test-NeedsPassword {
    $m=[string]$cmbMode.SelectedItem
    ($m -eq 'cmdkey') -or ($m -eq 'inline' -and $txtUser.Text.Trim())
}
function Update-PassHint {
    # Yellow = a password is required but missing (generation will refuse).
    if((Test-NeedsPassword) -and -not $txtPass.Text){ $txtPass.BackColor=[System.Drawing.Color]::LightYellow }
    else { $txtPass.BackColor=[System.Drawing.SystemColors]::Window }
}
function Confirm-NoCredMode {
    # Warn before generating with mode=none (error 1223 under Atera - a field bug).
    if([string]$cmbMode.SelectedItem -ne 'none'){ return $true }
    ([System.Windows.Forms.MessageBox]::Show(
        "Credential mode is 'none' - shares that need a login will prompt interactively (or fail with error 1223 under Atera).`n`nContinue anyway?",
        'No credentials configured','YesNo','Warning') -eq 'Yes')
}
function Load-ProfileIntoUi([string]$jsonText){
    $prof = ConvertFrom-DriveMapJson $jsonText
    $script:Site = $prof.Site
    $c=$prof.Credential; $o=$prof.Options
    # No credential in the profile, but the drives carry detected identities (Collect
    # or the Atera collector) -> adopt the dominant saved credential. Password stays
    # blank: Windows never reveals it, and generation refuses until it is typed.
    $inferred=$null
    if($c.Mode -eq 'none'){
        $inf=Get-InferredCredential -Drives $prof.Drives
        if($inf -and $inf.Credential){ $inferred=$inf; $c.Mode=$inf.Credential.Mode; $c.Target=$inf.Credential.Target; $c.User=$inf.Credential.User; $c.Password='' }
    }
    $cmbMode.SelectedItem = $(if($cmbMode.Items.Contains($c.Mode)){$c.Mode}else{'none'})
    $txtTarget.Text=[string]$c.Target; $txtUser.Text=[string]$c.User; $txtPass.Text=[string]$c.Password
    $chkTask.Checked=[bool]$o.LogonTask; $chkIcon.Checked=[bool]$o.ShowThisPcIcon; $chkExpl.Checked=[bool]$o.RestartExplorer
    Set-GridFromDrives $prof.Drives
    Rebuild-TokenBoxes; Update-TargetPrefill; Update-PassHint

    $credNote=''
    if($inferred){ $credNote="   Detected credential: $($c.User) @ $($c.Target) ($($inferred.Source)) - TYPE THE PASSWORD (Windows never reveals saved passwords)." }
    elseif([string]$cmbMode.SelectedItem -eq 'none'){ $credNote='   NOTE: no credentials set - configure before deploying.' }
    elseif((Test-NeedsPassword) -and -not $txtPass.Text){ $credNote="   Enter the password for $($txtUser.Text) before generating." }
    $flagged=@($prof.Drives | Where-Object { Get-DProp $_ 'CredNote' }).Count
    if($flagged){ $credNote += "   $flagged drive(s) marked (!) - hover for details." }
    Set-Status ("Loaded: {0} - {1} drive(s).{2}" -f $prof.Site,@($prof.Drives).Count,$credNote)
    Log ("[INFO] Loaded profile '{0}' - {1} drive(s){2}." -f $prof.Site,@($prof.Drives).Count,$(if($inferred){"; detected credential $($c.User) @ $($c.Target)"}else{''}))
    if((Test-NeedsPassword) -and -not $txtPass.Text){ [void]$txtPass.Focus() }
}
function Build-Content {
    $prof=Get-UiProfile -IncludedOnly
    if(@($prof.Drives).Count -eq 0){ throw 'Tick at least one drive (Use) on the Drives tab.' }
    New-MapDrivesCmdContent -DriveProfile $prof -TokenValues (Get-TokenValues)    # refuses a blank password
}
function Get-SelectedGridUnc {
    $row=$dgvDrives.CurrentRow
    if($row){ $u="$($row.Cells['gUnc'].Value)".Trim(); if($u){ return $u } }
    foreach($r in $dgvDrives.Rows){ if([bool]$r.Cells['gUse'].Value){ $u="$($r.Cells['gUnc'].Value)".Trim(); if($u){ return $u } } }
    $null
}

# ---- Drives tab events ----
$btnParse.Add_Click({ try{ Load-ProfileIntoUi $txtJson.Text }catch{ Show-Error 'Parse error' $_.Exception.Message } })
$btnLoad.Add_Click({
    $dlg=New-Object System.Windows.Forms.OpenFileDialog; $dlg.Filter='JSON (*.json)|*.json|All files (*.*)|*.*'
    $profDir=Join-Path $PSScriptRoot 'profiles'; if(Test-Path $profDir){ $dlg.InitialDirectory=$profDir }
    if($dlg.ShowDialog() -eq 'OK'){ $txtJson.Text=Get-Content -LiteralPath $dlg.FileName -Raw; try{ Load-ProfileIntoUi $txtJson.Text }catch{ Show-Error 'Parse error' $_.Exception.Message } }
})
$btnCollect.Add_Click({
    $btnCollect.Enabled=$false
    try{
        $drives=@(Get-CurrentDriveMappings)   # @() - one mapping unrolls to a scalar
        if($drives.Count -eq 0){ Set-Status 'No mappings found on this PC.'; Log '[INFO] Collect: no persistent mappings found on this PC.'; return }
        # Which account AUTHENTICATES each drive: the user's saved credentials (read
        # in their session - injected when we run as SYSTEM) + any /user: recorded
        # with the mapping. Passwords are never readable.
        $who=$script:InteractiveUser
        Set-Status ("Reading saved credentials{0}..." -f $(if($who){" for $who"}else{''}))
        $form.Cursor=[System.Windows.Forms.Cursors]::WaitCursor; [System.Windows.Forms.Application]::DoEvents()
        $res=Resolve-DriveCredentials -Drives $drives -OnPoll { [System.Windows.Forms.Application]::DoEvents() }
        $drives=@($res.Drives)
        $inf=Get-InferredCredential -Drives $drives
        $cred=if($inf.Credential){ $inf.Credential } else { [PSCustomObject]@{Mode='none';Target=$null;User=$null;Password=$null} }
        $prof=[PSCustomObject]@{ Site="$env:COMPUTERNAME mappings"; Credential=$cred; Options=[PSCustomObject]@{ShowThisPcIcon=$false;LogonTask=$false;RestartExplorer=$false}; Drives=$drives }
        $txtJson.Text=ConvertTo-DriveMapJson $prof
        Load-ProfileIntoUi $txtJson.Text
        Log "[INFO] Collect: $($res.Message)"
        $warn=@()
        if(-not $res.VaultRead){ $warn += "Saved credentials were NOT read: $($res.Message)"; $warn += '' }
        if($inf.Note){ $warn += $inf.Note; $warn += '' }
        foreach($d in $drives){ $n=Get-DProp $d 'CredNote'; if($n){ $warn += "$($d.Letter): $n"; $warn += '' } }
        if($warn.Count){
            foreach($w in $warn){ if($w){ Log "[WARN] $w" } }
            $sum=@('CREDENTIAL DETECTION','')
            foreach($d in $drives){ $u=Get-DProp $d 'CredUser'; $s=Get-DProp $d 'CredSource'; $sum += ("  {0}:  {1,-40}  {2}" -f $d.Letter,$d.Unc,$(if($u){"as $u  ($s)"}else{$s})) }
            $sum += ''; $sum += 'REVIEW'; $sum += ''
            Show-OutputDialog 'Collect - credential detection' (($sum + $warn) -join "`r`n")
        }
    }catch{ Show-Error 'Collect error' $_.Exception.Message }
    finally{ $form.Cursor=[System.Windows.Forms.Cursors]::Default; $btnCollect.Enabled=$true }
})
# Commit checkbox clicks immediately (otherwise the value updates only on leaving the cell).
$dgvDrives.Add_CurrentCellDirtyStateChanged({ if($dgvDrives.IsCurrentCellDirty){ [void]$dgvDrives.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) } })
$dgvDrives.Add_CellEndEdit({
    param($s,$e)
    $row=$dgvDrives.Rows[$e.RowIndex]
    $col=$dgvDrives.Columns[$e.ColumnIndex].Name
    if($col -eq 'gLetter'){ $n=ConvertTo-NormalizedLetter "$($row.Cells['gLetter'].Value)"; if($n){ $row.Cells['gLetter'].Value=$n } }
    if($col -eq 'gUnc'){
        # The detected identity belonged to the old path - clear it.
        $t=$row.Tag
        if($t -and (Get-DProp $t 'Unc') -ne "$($row.Cells['gUnc'].Value)"){
            foreach($p in 'CredUser','CredSource','CredTarget','CredNote'){ if($t.PSObject.Properties[$p]){ $t.$p=$null } }
            $row.Cells['gAuth'].Value=''; $row.Cells['gAuth'].ToolTipText=''
        }
        Rebuild-TokenBoxes; Update-TargetPrefill
    }
})
$btnStd.Add_Click({ foreach($r in $dgvDrives.Rows){ $r.Cells['gUse'].Value=("$($r.Cells['gGroup'].Value)" -in @('','standard')) } })
$btnAll.Add_Click({ foreach($r in $dgvDrives.Rows){ $r.Cells['gUse'].Value=$true } })
$btnClr.Add_Click({ foreach($r in $dgvDrives.Rows){ $r.Cells['gUse'].Value=$false } })
$btnAddRow.Add_Click({
    $i=$dgvDrives.Rows.Add()
    $r=$dgvDrives.Rows[$i]; $r.Cells['gUse'].Value=$true; $r.Cells['gGroup'].Value='standard'
    $dgvDrives.CurrentCell=$r.Cells['gLetter']; [void]$dgvDrives.BeginEdit($true)
})
$btnDelRow.Add_Click({
    $rows=@($dgvDrives.SelectedRows)
    foreach($r in $rows){ $dgvDrives.Rows.Remove($r) }
    Rebuild-TokenBoxes
})
$cmbMode.Add_SelectedIndexChanged({ if([string]$cmbMode.SelectedItem -ne 'none'){ Update-TargetPrefill }; Update-PassHint })
$txtPass.Add_TextChanged({ Update-PassHint })
$txtUser.Add_TextChanged({ Update-PassHint })
$btnGuiCopy.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($txtGui.Text); Set-Status 'Copied the Backstage launch one-liner.' })

$btnPreview.Add_Click({ try{ Show-CmdPreview (Build-Content) }catch{ Show-Error 'Preview' $_.Exception.Message } })
$btnCreate.Add_Click({
    try{
        if(-not (Confirm-NoCredMode)){ return }
        $content=Build-Content
        $res=Write-MapDrivesCmd -Content $content
        foreach($w in $res.Written){ Log "[OK] Wrote $w" }
        $extra=''
        if($chkTask.Checked){ Register-MapDrivesLogonTask -CmdPath $res.PublicDesktop; $extra=' + logon task'; Log "[OK] Registered the at-logon 'Map Drives' task." }
        Set-Status ("Created: {0}{1}" -f ($res.Written -join '; '),$extra)
    }catch{ Show-Error 'Create on Desktop' $_.Exception.Message }
})
$btnSaveJson.Add_Click({
    try{
        $prof=Get-UiProfile
        $json=ConvertTo-DriveMapJson $prof
        $dlg=New-Object System.Windows.Forms.SaveFileDialog; $dlg.Filter='JSON (*.json)|*.json|All files (*.*)|*.*'
        $dlg.FileName=("{0}.json" -f ($script:Site -replace '[\\/:*?"<>|]','_'))
        $profDir=Join-Path $PSScriptRoot 'profiles'; if(Test-Path $profDir){ $dlg.InitialDirectory=$profDir }
        if($dlg.ShowDialog() -eq 'OK'){
            $json | Set-Content -Path $dlg.FileName -Force -Encoding UTF8
            Log "[OK] Saved profile $($dlg.FileName)$(if($txtPass.Text){' (contains the password in plain text)'})"; Set-Status "Saved profile $($dlg.FileName)"
        }
    }catch{ Show-Error 'Save .json' $_.Exception.Message }
})
$btnApplyNow.Add_Click({
    $btnApplyNow.Enabled=$false
    try{
        if(-not (Confirm-NoCredMode)){ return }
        $content=Build-Content                      # refuses a blank password
        $letters=@((Get-UiProfile -IncludedOnly).Drives | ForEach-Object { $_.Letter })
        $who=$script:InteractiveUser
        if(-not $who){ throw 'No user is logged on - there is no session to map the drives into.' }
        $saved='MAPDRIVES.CMD: not saved (one-shot).'
        if($chkSaveCmd.Checked){ $w=Write-MapDrivesCmd -Content $content; $saved="MAPDRIVES.CMD saved: $($w.Written -join '; ')" }
        Set-Status "Mapping $($letters -join ', ') in $who's session..."
        $form.Cursor=[System.Windows.Forms.Cursors]::WaitCursor; [System.Windows.Forms.Application]::DoEvents()
        $timeout=[Math]::Min(180, 30 + 20*$letters.Count)
        $run=Invoke-MapDrivesNow -Content $content -User $who -TimeoutSec $timeout -OnPoll { [System.Windows.Forms.Application]::DoEvents() }
        $out="$($run.Output)"
        # The trailing 'net use' ran in the user's own session - authoritative.
        $listing=if($out -match '===NET USE==='){ ($out -split '===NET USE===')[-1] } else { '' }
        $lines=@("APPLY NOW - mapped in $who's session ($($run.Message))", $saved, '')
        $ok=0
        foreach($L in $letters){
            if($listing -match "(?m)^\s*(OK|Unavailable|Disconnected|Reconnecting)?\s*${L}:\s"){
                $st=if($Matches[1]){$Matches[1]}else{'mapped'}
                if($st -eq 'OK' -or $st -eq 'mapped'){ $ok++ }
                $lines += "  ${L}:  $st"; Log "[OK] Apply now: ${L}: $st"
            } else { $lines += "  ${L}:  FAILED (see output below)"; Log "[FAIL] Apply now: ${L}: did not map - see the result window" }
        }
        $lines += ''; $lines += '--- output from the user''s session ---'
        $lines += @(("$out" -split "`r?`n") | Where-Object { "$_".Trim() })
        Show-OutputDialog 'Apply now - result' ($lines -join "`r`n")
        Set-Status ("Apply now: {0} of {1} drive(s) mapped in {2}'s session." -f $ok,$letters.Count,$who)
    }catch{ Show-Error 'Apply now' $_.Exception.Message }
    finally{ $btnApplyNow.Enabled=$true; $form.Cursor=[System.Windows.Forms.Cursors]::Default }
})
$btnAtera.Add_Click({
    try{
        if(-not (Confirm-NoCredMode)){ return }
        # THE Atera export: the injector (Run As: SYSTEM) with this MAPDRIVES.CMD baked
        # in as -ContentB64, and the GUI's options baked in as switch defaults.
        $content=Build-Content
        $b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
        $src=Join-Path $PSScriptRoot 'Inject-MapDrives.Atera.ps1'
        if(-not (Test-Path -LiteralPath $src)){ throw 'Inject-MapDrives.Atera.ps1 not found next to this GUI.' }
        $code=Get-Content -LiteralPath $src -Raw
        $patched=$code -replace '(?m)^(\s*\[string\]\$ContentB64),', ('$1 = ''' + $b64 + ''',')
        if($patched -eq $code){ throw 'Could not find the $ContentB64 parameter to bake the CMD into.' }
        $noSave = (-not $chkSaveCmd.Checked) -and (-not $chkTask.Checked)
        if($noSave){ $patched=$patched -replace '(?m)^(\s*\[switch\]\$NoSave),', '$1 = $true,' }
        if($chkTask.Checked){ $patched=$patched -replace '(?m)^(\s*\[switch\]\$LogonTask),', '$1 = $true,' }
        $does = @('maps the drives in the logged-on user''s session (output printed)')
        $does += $(if($noSave){ 'leaves NO MAPDRIVES.CMD behind' } else { 'saves MAPDRIVES.CMD to the Public Desktop + backup' })
        if($chkTask.Checked){ $does += 'registers the at-logon Map Drives task' }
        $hdr="# MAPDRIVES.CMD for '$($script:Site)' baked in by MapDrives-Gui v$($script:ToolkitVer) on $(Get-Date -Format 'yyyy-MM-dd').`r`n# Paste into Atera - Run As: SYSTEM. It $($does -join '; ').`r`n# Optional args: -EnableLinkedConnections (one-time UAC linked-token fix), -NoRun (deploy only).`r`n"
        $patched=$hdr+$patched
        Show-OutputDialog 'Atera script (paste into Atera, Run As: SYSTEM)' $patched
        [System.Windows.Forms.Clipboard]::SetText($patched)
        Log "[OK] Export Atera: injector generated and copied ($($does -join '; '))."
        Set-Status 'Atera script generated and copied to the clipboard - Run As: SYSTEM.'
    }catch{ Show-Error 'Export Atera' $_.Exception.Message }
})
$btnUserFixer.Add_Click({
    try{
        # A companion script the USER runs (double-click): prompts for the password,
        # saves it with cmdkey and remaps persistently. Nothing is stored here.
        $drives=@((Get-GridDrives -IncludedOnly) | ForEach-Object { [PSCustomObject]@{ Letter=$_.Letter; Unc=$_.Unc } })
        if(-not $drives.Count){
            foreach($row in $dgvCurrent.Rows){
                $l=ConvertTo-NormalizedLetter "$($row.Cells['cLetter'].Value)"; $u="$($row.Cells['cUnc'].Value)".Trim()
                if($l -and $u){ $drives += [PSCustomObject]@{ Letter=$l; Unc=$u } }
            }
        }
        if(-not $drives.Count){ Set-Status 'No drives to include - tick drives on the Drives tab (or Refresh the Doctor tab).'; return }
        $h = Get-UncHost $drives[0].Unc
        if(-not $h){ Set-Status 'Could not determine the server from the first UNC.'; return }
        $forms = Get-BothHostForms $h
        $r = New-UserFixerScript -TargetHost $h -Drives $drives -CredUser $txtUser.Text.Trim() -AlsoForms @($forms | Where-Object { $_ -ne $h })
        [System.Windows.Forms.Clipboard]::SetText($r.LaunchLine)
        Log "[OK] User fixer written: $($r.Path)"
        Log "[INFO] Run it AS THE USER (launch line copied to clipboard). It prompts for the password - nothing is stored in this window or the script."
        Show-OutputDialog ("User companion fixer - $($r.Path)") ($r.LaunchLine + "`r`n`r`n" + ('-'*70) + "`r`n" + $r.Content)
        Set-Status 'User fixer generated; launch line copied to clipboard.'
    }catch{ Show-Error 'Export User Fixer' $_.Exception.Message }
})
$btnTestCred.Add_Click({
    $btnTestCred.Enabled=$false
    try {
        $unc=Get-SelectedGridUnc
        if(-not $unc){ Set-Status 'Select (or tick) a drive row with a UNC to test.'; return }
        $mode=[string]$cmbMode.SelectedItem
        $user = if($mode -eq 'none'){ '' } else { $txtUser.Text }
        $pass = if($mode -eq 'none'){ '' } else { $txtPass.Text }
        Log ("[INFO] Testing credentials against {0} (user: {1})..." -f $unc,$(if($user){$user}else{'(none)'}))
        Set-Status "Testing $unc ..."; [System.Windows.Forms.Application]::DoEvents()
        $r = Test-ShareCredential -Unc $unc -User $user -Password $pass
        switch("$($r.ShareAccess)"){
            'Accessible'    { Log "[OK] $($r.Summary)" }
            'AccessDenied'  { Log "[FAIL] $($r.Summary)" }
            'ShareNotFound' { Log "[FAIL] $($r.Summary)" }
            'PathNotFound'  { Log "[FAIL] $($r.Summary)" }
            default         { if($r.CredentialsValid -eq $false){ Log "[FAIL] $($r.Summary)" } else { Log "[INFO] $($r.Summary)" } }
        }
        foreach($n in @($r.Notes)){ Log "  [INFO] $n" }
        $d=@()
        $d+="Target : $unc"; $d+="Host   : $($r.Host)"
        $d+=("User   : {0}" -f $(if($r.User){$r.User}else{'(none / current identity)'}))
        $d+=""
        $d+="Share access          : $($r.ShareAccess)"
        $d+="Share '$($r.TargetShare)' exists : $($r.TargetShareExists)"
        $d+=("Explicit cred test    : {0}{1}" -f $(if($null -eq $r.CredentialsValid){'not run'}else{$r.CredentialsValid}),$(if($r.CredError){" (Windows error $($r.CredError))"}else{''}))
        $d+="Pre-existing session  : $($r.PreExistingConnection)"
        if(@($r.Shares).Count){ $d+="Shares on server      : $(@($r.Shares) -join ', ')" }
        if(@($r.Notes).Count){ $d+=""; foreach($n in @($r.Notes)){ $d+="NOTE: $n" } }
        $d+=""; $d+="==> $($r.Summary)"; $d+=""; $d+="--- raw output ---"; $d+=$r.Raw
        Show-OutputDialog "Test creds - $unc" ($d -join "`r`n")
        Set-Status $r.Summary
    } catch { Show-Error 'Test creds' $_.Exception.Message }
    finally { $btnTestCred.Enabled=$true }
})

# =====================================================================
# DOCTOR TAB - logic (ported from the v2 repair console)
# =====================================================================
function Get-BothHostForms([string]$hostOrIp){
    # Both the IP and name forms of a host, so connections cached under either can be
    # cleared (the post-domain case: stale conns under \\NAME and \\IP).
    $forms=@("$hostOrIp".Trim())
    try {
        $d=Test-DnsHealth -HostOrUnc $hostOrIp
        if($d.IsLiteralIP){ if($d.ReversePtr){ $forms += (("$($d.ReversePtr)") -split '\.')[0] } }
        else { if($d.FirstIPv4){ $forms += $d.FirstIPv4 } }
    } catch {}
    @($forms | Where-Object { $_ } | Select-Object -Unique)
}
function Get-SelectedCurrentUnc {
    $sel=@($dgvCurrent.SelectedRows)
    if($sel.Count){ $u="$($sel[0].Cells['cUnc'].Value)".Trim(); if($u){ return $u } }
    $null
}
function Get-TargetHostForConn {
    # Selected current-mapping row -> Credentials Target -> first drive on the Drives tab.
    $u=Get-SelectedCurrentUnc; if($u){ $h=Get-UncHost $u; if($h){ return $h } }
    if($txtTarget.Text.Trim()){ return $txtTarget.Text.Trim() }
    foreach($r in $dgvDrives.Rows){ $h=Get-UncHost "$($r.Cells['gUnc'].Value)"; if($h){ return $h } }
    $null
}
function Get-DiagnosisHosts {
    $hosts=@()
    foreach($row in $dgvCurrent.Rows){ $h=Get-UncHost "$($row.Cells['cUnc'].Value)"; if($h){ $hosts += $h } }
    foreach($row in $dgvDrives.Rows){ $h=Get-UncHost "$($row.Cells['gUnc'].Value)"; if($h){ $hosts += $h } }
    @($hosts | Sort-Object -Unique)
}
function Refresh-Current {
    $dgvCurrent.Rows.Clear()
    $rows=@()
    try {
        if($script:IsSystem){ $rows=@(Get-CurrentDriveMappings) }   # user's persistent maps (HKU)
        else               { $rows=@(Get-DriveMappingState) }       # live status in our own session
    } catch { Log "[FAIL] Could not read mappings: $($_.Exception.Message)"; return }
    foreach($r in $rows){
        $st = if($r.PSObject.Properties['Status']){ "$($r.Status)" } else { 'persistent' }
        $user = if($r.PSObject.Properties['ConnectionUser']){ "$($r.ConnectionUser)" } else { '' }
        [void]$dgvCurrent.Rows.Add($r.Letter,$r.Unc,$st,$user)
    }
    $count=@($rows).Count
    $src = if($script:IsSystem){'HKEY_USERS registry (persistent)'}else{'live Get-SmbMapping'}
    Set-Status ("Current mappings: {0} row(s) from {1}." -f $count,$src)
    Log ("[INFO] Listed {0} current mapping(s) from {1}." -f $count,$src)
    if($count -eq 0 -and $script:IsSystem){ Log '[INFO] 0 persistent mappings in the registry. Session-only drives are not visible from SYSTEM - or the drives really are missing.' }
}
function Invoke-Diagnose {
    $rtbDiag.Clear()
    $hosts=@(Get-DiagnosisHosts)
    try {
        $sc=Get-SmbClientHealth
        Diag "[INFO] Network profile: $($sc.NetworkProfile)   Workstation svc: $($sc.WorkstationService)   DNS svc: $($sc.DnsClientService)"
        Diag "[INFO] SMB1: $($sc.Smb1ClientEnabled)   Insecure guest: $($sc.InsecureGuestEnabled)   Require signing: $($sc.RequireSigning)"
        if("$($sc.NetworkProfile)" -eq 'Public'){ Diag '[WARN] Network profile is Public - Windows blocks file sharing/discovery. Use "Set network Private".' }
        if("$($sc.WorkstationService)" -ne 'Running'){ Diag '[FAIL] LanmanWorkstation not running - SMB client cannot map drives. Use "Start Workstation".' }
    } catch {}
    if($hosts.Count -eq 0){ Diag '[INFO] No share hosts in the current mappings or on the Drives tab.'; Set-Status 'Nothing to diagnose.'; return }
    foreach($h in $hosts){
        Set-Status "Diagnosing $h ..."; [System.Windows.Forms.Application]::DoEvents()
        Diag ''; Diag "===== $h ====="
        try { $dns=Test-DnsHealth -HostOrUnc $h; foreach($f in $dns.Findings){ Diag "  $f" } } catch { Diag "  [FAIL] DNS check error: $($_.Exception.Message)" }
        try {
            $conn=Test-ShareConnectivity -HostOrUnc $h
            if($conn.Pingable){ Diag '  [OK] Ping reply' } else { Diag '  [WARN] No ping reply (may be firewalled)' }
            if($conn.Smb445Open){ Diag "  [OK] SMB 445 open$(if($conn.SmbDialect){" (dialect $($conn.SmbDialect))"})" }
            elseif($conn.Smb139Only){ Diag '  [WARN] Only legacy SMB 139 open (445 blocked) - SMB1-era device or firewall' }
            else { Diag '  [FAIL] SMB 445/139 NOT reachable' }
        } catch { Diag "  [FAIL] Connectivity check error: $($_.Exception.Message)" }
        try { $dev=Resolve-ShareDevice -HostOrUnc $h; Diag "  [INFO] Device: $($dev.DeviceType)$(if($dev.Vendor){" [$($dev.Vendor)]"})  IP=$($dev.IPAddress)  MAC=$($dev.Mac)" } catch {}
    }
    Set-Status ("Diagnosed {0} host(s)." -f $hosts.Count)
    Log ("[INFO] Diagnosed: {0}" -f ($hosts -join ', '))
}
function Get-SelectedDoctorLetter {
    $sel=@($dgvCurrent.SelectedRows)
    $row = if($sel.Count){ $sel[0] } else { $dgvCurrent.CurrentRow }
    if($row){ return "$($row.Cells['cLetter'].Value)".Trim().TrimEnd(':').ToUpper() }
    $null
}
function BucketShort([int]$b){ switch($b){ 1{'Healthy'} 2{'Red-X'} 3{'Ghost'} 4{'Not ready'} 5{'Scope'} default{'?'} } }

# ---- Doctor tab events ----
$btnRefresh.Add_Click({ Refresh-Current })
$btnDiag.Add_Click({ $btnDiag.Enabled=$false; try { Invoke-Diagnose } finally { $btnDiag.Enabled=$true } })
$btnWhyMap.Add_Click({
    $btnWhyMap.Enabled=$false
    try{
        # Diagnose-MapError: connection-level failures (59/53/64/1272...), including a
        # share list + dir AS THE USER, so it can tell "server broken" from "that share".
        $unc=Get-SelectedCurrentUnc
        if(-not $unc){ $unc=Get-SelectedGridUnc }
        if(-not $unc){ Set-Status 'Select a current mapping (or a drive on the Drives tab) first.'; return }
        $diagScript=Join-Path $PSScriptRoot 'Diagnose-MapError.Atera.ps1'
        if(-not (Test-Path -LiteralPath $diagScript)){ throw 'Diagnose-MapError.Atera.ps1 not found next to this GUI.' }
        $rtbDiag.Clear()
        Diag "[INFO] Why won't $unc map? (Diagnose-MapError - takes up to a minute)"
        Log "[INFO] Diagnosing $unc ..."
        Set-Status "Diagnosing $unc ..."
        $form.Cursor=[System.Windows.Forms.Cursors]::WaitCursor; [System.Windows.Forms.Application]::DoEvents()
        $out=Invoke-ChildScript $diagScript ('-Unc "' + $unc.TrimEnd('\') + '"')
        foreach($line in @("$out" -split "`r?`n")){ if("$line".Trim()){ Diag $line } }
        $res=@(("$out" -split "`r?`n") | Where-Object { $_ -match '^\[RESULT\]' }) | Select-Object -First 1
        if($res){ Log ("[WARN] " + ($res -replace '^\[RESULT\]\s*','')); Set-Status ($res -replace '^\[RESULT\]\s*','') }
        else { Set-Status 'Diagnosis complete - see Results.' }
    }catch{ Show-Error "Why won't it map?" $_.Exception.Message }
    finally{ $btnWhyMap.Enabled=$true; $form.Cursor=[System.Windows.Forms.Cursors]::Default }
})
$btnFlush.Add_Click({
    if(-not (Confirm-Fix 'Flush the DNS resolver cache? (safe)')){ return }
    try { Clear-DnsClientCache -ErrorAction SilentlyContinue; & ipconfig /flushdns | Out-Null; Log '[OK] DNS cache flushed.' }
    catch { Log "[FAIL] Flush DNS: $($_.Exception.Message)" }
})
$btnPrivate.Add_Click({
    if(-not (Confirm-Fix 'Set the active network connection profile to Private? (enables file sharing)')){ return }
    try { Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Stop; Log '[OK] Network profile set to Private.' }
    catch { Log "[FAIL] Set Private (needs elevation/SYSTEM): $($_.Exception.Message)" }
})
$btnWks.Add_Click({
    if(-not (Confirm-Fix 'Start/restart the LanmanWorkstation (Workstation) service?')){ return }
    try { Start-Service LanmanWorkstation -ErrorAction Stop; Log '[OK] Workstation service started.' }
    catch { Log "[FAIL] Start Workstation (needs elevation/SYSTEM): $($_.Exception.Message)" }
})
$btnGuest.Add_Click({
    if(-not (Confirm-Fix 'Enable insecure guest logons for the SMB client? (needed for guest-only NAS shares; slightly less secure)')){ return }
    try { Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -Force -ErrorAction Stop; Log '[OK] Insecure guest logons enabled.' }
    catch { Log "[FAIL] Enable guest (needs elevation/SYSTEM): $($_.Exception.Message)" }
})
$btnClearCred.Add_Click({
    try {
        $targets=@()
        if($txtTarget.Text.Trim()){ $targets += $txtTarget.Text.Trim() }
        foreach($row in $dgvDrives.Rows){ $h=Get-UncHost "$($row.Cells['gUnc'].Value)"; if($h){ $targets += $h } }
        foreach($row in $dgvCurrent.Rows){ $h=Get-UncHost "$($row.Cells['cUnc'].Value)"; if($h){ $targets += $h } }
        $targets=@($targets | Where-Object { $_ } | Select-Object -Unique)
        if(-not $targets.Count){ Set-Status 'No target host (fill Credentials Target, or add a drive).'; return }
        if([System.Windows.Forms.MessageBox]::Show(("Delete saved Windows credentials for:`n  {0}`n`nClears stale logons cached for these hosts." -f ($targets -join ', ')),'Clear saved credentials','YesNo','Question') -ne 'Yes'){ return }
        $r=Clear-SavedCredential -Target $targets
        Log "[OK] $($r.Message)"; Set-Status $r.Message
    } catch { Log "[FAIL] $($_.Exception.Message)" }
})
$btnClearNames.Add_Click({
    if(-not (Confirm-Fix "Purge DNS + ARP + NetBIOS name caches?`n(ipconfig /flushdns, arp -d *, nbtstat -R, nbtstat -RR)`n`nRe-learns a name that resolves to an old/stale IP.")){ return }
    $btnClearNames.Enabled=$false
    try {
        Log '[INFO] Clearing name-resolution caches...'
        Set-Status 'Clearing name caches...'; [System.Windows.Forms.Application]::DoEvents()
        foreach($line in @(Clear-NameCaches)){ Log $line }
        Set-Status 'Name caches cleared.'
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnClearNames.Enabled=$true }
})
$btnTestDns.Add_Click({
    $btnTestDns.Enabled=$false
    try {
        $rtbDiag.Clear()
        Diag '[INFO] Testing configured DNS servers with real queries (not just a port check)...'
        Set-Status 'Testing DNS servers...'; [System.Windows.Forms.Application]::DoEvents()
        $servers=@(Get-DnsServerHealth)
        if($servers.Count -eq 0){ Diag '[WARN] No configured DNS servers found on active interface(s).'; Set-Status 'No DNS servers configured.'; return }
        foreach($s in $servers){
            Diag ''; Diag ("{0} - {1}   [{2}]" -f $s.Role,$s.Server,$s.Interface); Diag ("  {0}" -f $s.Status)
            Log ("[INFO] DNS {0} {1}: {2}" -f $s.Role,$s.Server,($s.Status -replace '^\[\w+\]\s*',''))
        }
        $bad=@($servers | Where-Object { -not $_.Responds })
        Diag ''
        if($bad.Count){ Diag ("[WARN] {0} of {1} DNS server(s) not responding: {2}" -f $bad.Count,$servers.Count,(@($bad | ForEach-Object { $_.Server }) -join ', ')) }
        else { Diag '[OK] All configured DNS servers are responding.' }
        Set-Status 'DNS server test complete.'
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnTestDns.Enabled=$true }
})
$btnViewConn.Add_Click({
    $btnViewConn.Enabled=$false
    try {
        $ctx = if($script:IsSystem){ "$($script:InteractiveUser)'s session" } else { "this session ($env:USERNAME)" }
        Log "[INFO] Listing active connections (net use) in $ctx..."
        Set-Status "Reading connections in $ctx..."; [System.Windows.Forms.Application]::DoEvents()
        $out = Run-InUserOrHere 'net use' 20
        Show-OutputDialog "Active connections (net use) - $ctx" $out
        Log '[OK] Listed active connections.'; Set-Status 'Listed active connections.'
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnViewConn.Enabled=$true }
})
$btnClearConn.Add_Click({
    $btnClearConn.Enabled=$false
    try {
        $h = Get-TargetHostForConn
        if(-not $h){ Set-Status 'No target host (select a mapping, fill Credentials Target, or add a drive).'; return }
        $forms = Get-BothHostForms $h
        $ctx = if($script:IsSystem){ "$($script:InteractiveUser)'s session" } else { "this session ($env:USERNAME)" }
        if([System.Windows.Forms.MessageBox]::Show(
            ("Delete ALL SMB connections to these host forms in {0}:`n  {1}`n`nThis disconnects any drive/UNC to that server (including working ones) so a stale/conflicting session can't block the remap." -f $ctx,($forms -join ', ')),
            'Clear host connections','YesNo','Warning') -ne 'Yes'){ return }
        $clear = (@($forms | ForEach-Object { 'net use \\' + $_ + '\* /delete /y' }) -join ' & ') + ' & net use'
        Log "[INFO] Clearing connections to $($forms -join ', ') in $ctx..."
        Set-Status "Clearing connections in $ctx..."; [System.Windows.Forms.Application]::DoEvents()
        $out = Run-InUserOrHere $clear 25
        Show-OutputDialog "Cleared connections to $h - remaining (net use)" $out
        Log "[OK] Cleared connections to $($forms -join ', '). Re-test the map now."
        Set-Status 'Cleared host connections.'
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnClearConn.Enabled=$true }
})
$btnDir.Add_Click({
    $btnDir.Enabled=$false
    try {
        # Selected current mapping -> dir its letter; else dir the selected Drives-tab
        # UNC in the user's session (reproduces the exact error the user gets).
        $path=$null
        $selC=@($dgvCurrent.SelectedRows)
        if($selC.Count){ $l="$($selC[0].Cells['cLetter'].Value)".Trim(); if($l){ $path="${l}:\" } }
        if(-not $path){ $path=Get-SelectedGridUnc }
        if(-not $path){ Set-Status 'Select a current mapping, or a drive on the Drives tab.'; return }
        Log "[INFO] dir $path (as user)..."
        Set-Status "Listing $path as the user..."
        if($script:IsSystem){
            $target=$script:InteractiveUser
            if(-not $target){ Log '[WARN] No interactive user to run dir as.'; Set-Status 'No user session.'; return }
            $r = Invoke-DirInUserSession -Path $path -User $target -OnPoll { [System.Windows.Forms.Application]::DoEvents() }
            if($r.Success){ Show-OutputDialog ("dir $path   (as $target)") $r.Output; Log "[OK] dir $path captured from $target's session."; Set-Status "Listed $path (as $target)." }
            else { Log "[WARN] $($r.Message)"; Set-Status $r.Message; Show-OutputDialog ("dir $path   (as $target)") ("(no listing)`r`n`r`n" + $r.Message) }
        } else {
            $out = (& cmd /c ("dir `"$path`"") 2>&1 | Out-String)
            Show-OutputDialog ("dir $path   (as $env:USERNAME)") $out
            Log "[OK] dir $path listed in this session."; Set-Status "Listed $path."
        }
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnDir.Enabled=$true }
})
$btnAnalyze.Add_Click({
    $btnAnalyze.Enabled=$false
    try {
        $rtbDiag.Clear()
        Diag '[INFO] Analyzing drives in the user session (4-layer: DOS / SMB / registry / shell)...'
        Set-Status 'Analyzing drives...'; [System.Windows.Forms.Application]::DoEvents()
        $r = Get-DriveDoctorReport -OnPoll { [System.Windows.Forms.Application]::DoEvents() }
        if(-not $r.Success -or -not $r.Data){ Diag "[WARN] Could not analyze: $($r.Message)"; Set-Status 'Analyze failed.'; return }
        $drives=@($r.Data.Drives)
        $script:LastDoctor=$drives
        $dgvCurrent.Rows.Clear()
        foreach($d in $drives){ [void]$dgvCurrent.Rows.Add($d.Letter,$d.Unc,(BucketShort $d.Bucket),"$($r.Data.User)") }
        if($null -ne $r.Data.EnableLinkedConnections){ Diag "[INFO] EnableLinkedConnections = $($r.Data.EnableLinkedConnections) (1 = mapped drives shared across UAC linked tokens)." }
        if($drives.Count -eq 0){ Diag '[INFO] No network drive letters found in the user session.' }
        foreach($d in $drives){
            Diag ''
            $mark = switch($d.Bucket){ 1{'[OK]'} 2{'[WARN]'} 3{'[WARN]'} 4{'[FAIL]'} default{'[INFO]'} }
            Diag ("$mark $($d.Letter): BUCKET $($d.Bucket) - $($d.BucketName)")
            Diag ("     UNC=$($d.Unc)  Type=$($d.DriveType)  IsReady=$($d.IsReady)  Accessible=$($d.Accessible)")
            Diag ("     Layer2 SMB: $(if($d.InSmb){"yes ($($d.SmbStatus))"}else{'NO (not managed by SMB)'})   Layer3 Reg: $($d.InRegistry)   Provider: $(if($d.Provider){$d.Provider}else{'(blank)'})")
            Diag ("     -> $($d.Action)")
        }
        $ghosts=@($drives | Where-Object { $_.Bucket -eq 3 }); $redx=@($drives | Where-Object { $_.Bucket -eq 2 })
        Set-Status ("Analyzed {0} drive(s): {1} ghost, {2} red-X." -f $drives.Count,$ghosts.Count,$redx.Count)
        Log ("[INFO] Drive Doctor: {0} drive(s) - {1} ghost, {2} red-X." -f $drives.Count,$ghosts.Count,$redx.Count)
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnAnalyze.Enabled=$true }
})
$btnFixRedX.Add_Click({
    $L = Get-SelectedDoctorLetter
    if(-not $L){ Set-Status 'Select a drive row first (run Analyze).'; return }
    if(-not (Confirm-Fix "Fix the Red-X shell cache for ${L}: ?`n(Backs up MountPoints2, removes only that drive's cache key, refreshes Explorer. Does NOT unmap the drive.)")){ return }
    $btnFixRedX.Enabled=$false
    try {
        Log "[INFO] Fixing Red-X cache for ${L}: (as user)..."; Set-Status "Fixing Red-X for ${L}:..."; [System.Windows.Forms.Application]::DoEvents()
        $r = Repair-RedXCache -Letter $L -OnPoll { [System.Windows.Forms.Application]::DoEvents() }
        if($r.Data){ foreach($line in @($r.Data.Log)){ Log "  $line" } } else { Log "[WARN] $($r.Message)" }
        Log "[INFO] If the Red X persists, sign the user out/in (the drive object is bound to their logon session)."
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnFixRedX.Enabled=$true }
})
$btnRelGhost.Add_Click({
    $L = Get-SelectedDoctorLetter
    if(-not $L){ Set-Status 'Select a drive row first (run Analyze).'; return }
    $unc = ($script:LastDoctor | Where-Object { $_.Letter -eq $L } | Select-Object -First 1).Unc
    if(-not $unc){ $unc=Get-SelectedCurrentUnc }
    if([System.Windows.Forms.MessageBox]::Show(
        "RELEASE ghost drive ${L}: ? (Error-85 fix)`n`nBacks up HKCU\Network\${L} to the Desktop, deletes it, and frees the DOS-device letter (DefineDosDevice). Only do this for an orphaned/ghost drive.`n`nProceed?",
        'Release ghost drive','YesNo','Warning') -ne 'Yes'){ return }
    $remap = $false
    if($unc){ $remap = ([System.Windows.Forms.MessageBox]::Show("After releasing, remap ${L}: -> $unc ?",'Remap after release','YesNo','Question') -eq 'Yes') }
    $btnRelGhost.Enabled=$false
    try {
        Log "[INFO] Releasing ghost ${L}: (as user)$(if($remap){" then remap -> $unc"})..."; Set-Status "Releasing ghost ${L}:..."; [System.Windows.Forms.Application]::DoEvents()
        # NOT $args - that is PowerShell's automatic variable inside a scriptblock.
        $ghostArgs = @{ Letter=$L; OnPoll={ [System.Windows.Forms.Application]::DoEvents() } }
        if($remap -and $unc){ $ghostArgs.Remap=$unc }
        $r = Clear-GhostDrive @ghostArgs
        if($r.Data){ foreach($line in @($r.Data.Log)){ Log "  $line" } } else { Log "[WARN] $($r.Message)" }
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnRelGhost.Enabled=$true }
})
$btnRemapSel.Add_Click({
    $L = Get-SelectedDoctorLetter
    if(-not $L){ Set-Status 'Select a drive row first.'; return }
    $unc=Get-SelectedCurrentUnc
    if(-not $unc){ $unc = ($script:LastDoctor | Where-Object { $_.Letter -eq $L } | Select-Object -First 1).Unc }
    if(-not $unc){ Set-Status "No UNC known for ${L}: (run Analyze, or use the Drives tab)."; return }
    if(-not (Confirm-Fix "Remap ${L}: -> $unc in the user session? (net use /persistent:yes)")){ return }
    $btnRemapSel.Enabled=$false
    try {
        Log "[INFO] Remapping ${L}: -> $unc (as user)..."; Set-Status "Remapping ${L}:..."; [System.Windows.Forms.Application]::DoEvents()
        $out = Run-InUserOrHere ('net use ' + $L + ': "' + $unc + '" /persistent:yes 2>&1 & net use') 30
        foreach($line in @($out -split "`r?`n" | Where-Object { $_.Trim() })){ Log "  $line" }
        if($out -match 'error 85|already in use'){ Log "[WARN] Error 85 = the letter is a ghost. Use 'Release ghost' first, then remap." }
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnRemapSel.Enabled=$true }
})
$btnGpo.Add_Click({
    $btnGpo.Enabled=$false
    try {
        Log '[INFO] Checking GPO / logon-script origin (gpresult, as user)...'; Set-Status 'Checking GPO origin...'; [System.Windows.Forms.Application]::DoEvents()
        $r = Get-DriveOriginGpo -OnPoll { [System.Windows.Forms.Application]::DoEvents() }
        if($r.Data){ foreach($line in @($r.Data.Log)){ Log "  $line" }
            if($r.Data.GpoDriveMaps){ Log '[WARN] Drives may be GPO-created - the lasting fix is in Group Policy, not local surgery.' } }
        else { Log "[WARN] $($r.Message)" }
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnGpo.Enabled=$true }
})
$btnCredAudit.Add_Click({
    $btnCredAudit.Enabled=$false
    try {
        $rtbDiag.Clear()
        Diag '[INFO] Auditing Credential Manager in the user session...'
        Set-Status 'Auditing stored credentials...'; [System.Windows.Forms.Application]::DoEvents()
        $r = Get-CredentialAudit -OnPoll { [System.Windows.Forms.Application]::DoEvents() }
        if(-not $r.Success -or -not $r.Data){ Diag "[WARN] Credential audit failed: $($r.Message)"; return }
        Diag ("[INFO] Vault entries: $($r.Data.TotalVaultEntries); SMB-relevant: $(@($r.Data.Entries).Count); logged-on user: $($r.Data.User)")
        Diag ''
        foreach($e in @($r.Data.Entries)){ Diag ("  {0,-24} -> {1}   [{2}]" -f $e.TargetHost,$e.CredUser,$e.Severity) }
        Diag ''
        foreach($f in @($r.Data.Findings)){ Diag "  $f"; if($f -match '^\[FAIL\]'){ Log $f } }
        Set-Status 'Credential audit complete.'
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnCredAudit.Enabled=$true }
})
$btnFullAudit.Add_Click({
    $btnFullAudit.Enabled=$false
    try {
        $rtbDiag.Clear()
        Diag '[INFO] Running FULL AUDIT (drives, credentials, Kerberos, domain/DC, DNS, shares, SMB events)...'
        Set-Status 'Running full audit - this takes a few seconds...'; [System.Windows.Forms.Application]::DoEvents()
        $a = Invoke-DriveAudit -OnPoll { [System.Windows.Forms.Application]::DoEvents() }
        $rtbDiag.Clear()
        foreach($line in @($a.Report)){ Diag $line }
        if($a.TopFinding){ Log "[WARN] TOP FINDING: $($a.TopFinding)" } else { Log '[OK] Full audit: no problems detected.' }
        Log ("[INFO] Full audit complete - {0} finding(s). Use 'Save report...' for the ticket." -f @($a.Findings).Count)
        Set-Status $(if($a.TopFinding){ "Top finding: $($a.TopFinding)" } else { 'Full audit: no problems detected.' })
    } catch { Show-Error 'FULL AUDIT' $_.Exception.Message }
    finally { $btnFullAudit.Enabled=$true }
})
$btnSaveRep.Add_Click({
    try {
        if(-not $rtbDiag.Text -and -not $rtbLog.Text){ Set-Status 'Nothing to save yet - run FULL AUDIT or Analyze.'; return }
        $dlg=New-Object System.Windows.Forms.SaveFileDialog; $dlg.Filter='Text (*.txt)|*.txt|All files (*.*)|*.*'
        $dlg.FileName=("DriveAudit-{0}-{1}.txt" -f $env:COMPUTERNAME,(Get-Date -Format 'yyyyMMdd-HHmm'))
        if($dlg.ShowDialog() -eq 'OK'){
            ($rtbDiag.Text + "`r`n`r`n===== SESSION LOG =====`r`n" + $rtbLog.Text) | Set-Content -LiteralPath $dlg.FileName -Force -Encoding UTF8
            Log "[OK] Report saved: $($dlg.FileName)"; Set-Status "Saved $($dlg.FileName)"
        }
    } catch { Log "[FAIL] $($_.Exception.Message)" }
})
$btnFixLinked.Add_Click({
    if(-not (Confirm-Fix "Set EnableLinkedConnections = 1?`n`nMakes drives mapped in the standard token visible to the elevated token (and vice-versa). Takes effect after a reboot / LanmanWorkstation restart.")){ return }
    try {
        $r = Set-LinkedConnections -Enable
        foreach($l in @($r.Log)){ Log "  $l" }
        Set-Status $(if($r.Changed){'EnableLinkedConnections set (reboot to apply).'}else{'EnableLinkedConnections unchanged.'})
    } catch { Log "[FAIL] $($_.Exception.Message)" }
})
$btnPurgeHost.Add_Click({
    $h = Get-TargetHostForConn
    if(-not $h){ Set-Status 'No target host (select a mapping, fill Credentials Target, or add a drive).'; return }
    $forms = Get-BothHostForms $h
    if([System.Windows.Forms.MessageBox]::Show(
        ("PURGE the SMB session + stored credentials for:`n  {0}`n`nDeletes saved credentials AND drops every connection to that server, so the next map authenticates cleanly. Other servers' drives are left alone.`n`nProceed?" -f ($forms -join ', ')),
        'Purge host session','YesNo','Warning') -ne 'Yes'){ return }
    $btnPurgeHost.Enabled=$false
    try {
        Log "[INFO] Purging session + credentials for $($forms -join ', ')..."
        Set-Status 'Purging host session...'; [System.Windows.Forms.Application]::DoEvents()
        $r = Clear-HostSession -TargetHost $forms[0] -AlsoForms @($forms | Select-Object -Skip 1) -OnPoll { [System.Windows.Forms.Application]::DoEvents() }
        if($r.Data){
            foreach($l in @($r.Data.Log)){ Log "  $l" }
            if(@($r.Data.Survivors).Count){
                foreach($s in @($r.Data.Survivors)){ Log "    survivor: $s" }
                if([System.Windows.Forms.MessageBox]::Show(
                    "Connections to that server SURVIVED, so the old identity is still active.`n`nESCALATE to a global purge? This drops ALL network connections (every server) and purges the Kerberos ticket cache.",
                    'Escalate to global purge','YesNo','Warning') -eq 'Yes'){
                    $r2 = Clear-HostSession -TargetHost $forms[0] -AlsoForms @($forms | Select-Object -Skip 1) -Global -OnPoll { [System.Windows.Forms.Application]::DoEvents() }
                    if($r2.Data){ foreach($l in @($r2.Data.Log)){ Log "  $l" } }
                    if($r2.Data -and @($r2.Data.Survivors).Count){ Log '[WARN] Still not clean - a REBOOT is the only guaranteed way to drop a wedged SMB session.' }
                }
            }
        } else { Log "[WARN] $($r.Message)" }
        Log '[INFO] Now re-map (Drives tab: Apply now). Pair the credential with cmdkey so it survives a reboot.'
        Refresh-Current
    } catch { Log "[FAIL] $($_.Exception.Message)" }
    finally { $btnPurgeHost.Enabled=$true }
})
$btnCopyLog.Add_Click({ if($rtbLog.Text){ [System.Windows.Forms.Clipboard]::SetText($rtbLog.Text); Set-Status 'Session log copied.' } })
$btnSaveLog.Add_Click({
    try {
        if(-not $rtbLog.Text){ Set-Status 'The session log is empty.'; return }
        $dlg=New-Object System.Windows.Forms.SaveFileDialog; $dlg.Filter='Text (*.txt)|*.txt|All files (*.*)|*.*'
        $dlg.FileName=("MapDrives-log-{0}-{1}.txt" -f $env:COMPUTERNAME,(Get-Date -Format 'yyyyMMdd-HHmm'))
        if($dlg.ShowDialog() -eq 'OK'){ $rtbLog.Text | Set-Content -LiteralPath $dlg.FileName -Force -Encoding UTF8; Set-Status "Saved $($dlg.FileName)" }
    } catch { Show-Error 'Save log' $_.Exception.Message }
})
$btnClearLog.Add_Click({ $rtbLog.Clear(); Set-Status 'Session log cleared.' })

# =====================================================================
# LAYOUT + START
# =====================================================================
# Bring inputs in front of any label that might grow over them (larger system
# font / DPI), on every container.
function Set-InputsToFront($container){
    foreach($c in @($container.Controls)){
        if($c -is [System.Windows.Forms.Button] -or $c -is [System.Windows.Forms.TextBox] -or $c -is [System.Windows.Forms.CheckBox] -or
           $c -is [System.Windows.Forms.DataGridView] -or $c -is [System.Windows.Forms.RichTextBox] -or $c -is [System.Windows.Forms.GroupBox] -or
           $c -is [System.Windows.Forms.ComboBox]){ $c.BringToFront() }
        if($c.Controls.Count){ Set-InputsToFront $c }
    }
}
Set-InputsToFront $form
# Docking order: the Fill control must be at the FRONT of the z-order so the banner
# (Top) and status strip (Bottom) take their space first.
$tabs.BringToFront()
# Never taller/wider than the screen (Backstage sessions are often small); each tab
# page scrolls if the window is smaller than its content.
try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if($form.Height -gt $wa.Height){ $form.Height = [Math]::Max(600,$wa.Height - 20) }
    if($form.Width  -gt $wa.Width ){ $form.Width  = [Math]::Max(760,$wa.Width  - 20) }
    if($form.MinimumSize.Height -gt $form.Height -or $form.MinimumSize.Width -gt $form.Width){
        $form.MinimumSize = New-Object System.Drawing.Size([Math]::Min(940,$form.Width),[Math]::Min(600,$form.Height))
    }
} catch {}
$tabDrives.AutoScroll=$true; $tabDoctor.AutoScroll=$true
$script:AnchoredRoots=@{}
function Invoke-AnchorsOnce($Root){
    $k=[string]$Root.GetHashCode()
    if(-not $script:AnchoredRoots.ContainsKey($k)){ $script:AnchoredRoots[$k]=$true; Apply-Anchors $Root }
}
$form.Add_Shown({ Invoke-AnchorsOnce $tabs.SelectedTab; Update-LogBar })
$tabs.Add_SelectedIndexChanged({
    Invoke-AnchorsOnce $tabs.SelectedTab
    if([object]::ReferenceEquals($tabs.SelectedTab,$tabLog)){ $script:LogUnseen=0; $tabLog.Text='Session log'; Update-LogBar }
})

Log ("Started - context $($script:CurrentName) [$ctxTag]; interactive user: $iu; toolkit v$($script:ToolkitVer).")
if($script:IsSystem -and -not $script:InteractiveUser){ Log '[WARN] Running as SYSTEM but no user is logged on - Apply now / Doctor actions have no session to target.' }
Rebuild-TokenBoxes
Refresh-Current

[void]$form.ShowDialog()
