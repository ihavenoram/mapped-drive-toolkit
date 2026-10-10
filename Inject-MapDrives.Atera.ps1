<#
=========================================================
Script Name: Inject-MapDrives.Atera
Description: THE Atera way to map drives so they appear IMMEDIATELY in the
             logged-on user's Explorer. Run As: SYSTEM. MapDrives-Gui's
             "Export Atera..." bakes the drive list in for you.

             WHY THIS EXISTS
             A net use drive letter is scoped to the LOGON SESSION (LUID) that
             created it, not to the user account. Atera "Run As: Current logged-on
             user" runs in a DIFFERENT session/token than the interactive desktop,
             so a drive it maps works in that Atera process (dir S:\ ok) but never
             shows up in the user's Explorer. The same split happens with UAC's
             linked tokens (elevated vs standard) - KB937624.

             THE FIX
             This script (as SYSTEM) runs MAPDRIVES.CMD INSIDE the interactive
             user's session via a one-shot scheduled task whose principal is that
             user at RunLevel=Limited (the exact standard token Explorer uses). The
             drives appear instantly, and the session's output (including any net
             use errors) is printed here.

.PARAMETER ContentB64
    Base64 (UTF8) of the MAPDRIVES.CMD to run. If omitted, an existing
    C:\Users\Public\Desktop\MAPDRIVES.CMD is used as-is.

.PARAMETER NoSave
    Map only - do NOT leave MAPDRIVES.CMD on the Public Desktop or the backup copy.
    The CMD (it holds the password) runs from a private temp copy in the user's own
    Temp folder, deleted afterwards. Ignored with -LogonTask (the task needs the file).

.PARAMETER LogonTask
    Also register the at-logon "Map Drives" task (runs the Public Desktop CMD as each
    user at logon). Saves the CMD.

.PARAMETER EnableLinkedConnections
    Also set HKLM ...\Policies\System\EnableLinkedConnections = 1 so mapped drives
    are shared across a user's UAC linked tokens. One-time per machine; takes effect
    after a reboot (or LanmanWorkstation restart).

.PARAMETER NoRun
    Deploy only (save the CMD / task / reg key) - do NOT map now.

.PARAMETER TimeoutSec
    How long to wait for the in-session run (default 90).
Category:    ScriptLibrary
Run Time:    10 minutes
Arguments:   -ContentB64 "..."   [optional] -NoSave  -LogonTask  -EnableLinkedConnections  -NoRun
Run As:      System

             SYNC NOTE: the "find interactive user" + "one-shot task in the user's
             session" + "private temp copy" logic is intentionally duplicated, inline,
             from MappedDriveToolkit.psm1 (Get-InteractiveUser /
             Invoke-CommandInUserSession / Invoke-MapDrivesNow). This script stays
             SELF-CONTAINED (no module import) so it pastes straight into Atera.
=========================================================
#>
#Requires -Version 5.1
param(
    [string]$ContentB64,
    [switch]$NoSave,
    [switch]$LogonTask,
    [switch]$EnableLinkedConnections,
    [switch]$NoRun,
    [int]$TimeoutSec = 90
)

$ErrorActionPreference = 'Continue'
function Write-OkLine   ([string]$m){ Write-Output "[OK]   $m" }
function Write-FailLine ([string]$m){ Write-Output "[FAIL] $m" }
function Write-InfoLine ([string]$m){ Write-Output "[INFO] $m" }

$desktop   = Join-Path $env:PUBLIC 'Desktop\MAPDRIVES.CMD'
$backupDir = 'C:\ProgramData\MappedDriveToolkit'

Write-InfoLine "Host: $env:COMPUTERNAME  Context: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
if ($LogonTask -and $NoSave) { Write-InfoLine '-LogonTask needs MAPDRIVES.CMD on the Public Desktop - saving it (-NoSave ignored).'; $NoSave = $false }

# --------------------------- 1. The CMD content ----------------------------
$content = $null
if ($ContentB64) {
    try { $content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ContentB64)) }
    catch { Write-FailLine "Could not decode -ContentB64: $($_.Exception.Message)"; exit 1 }
}
if (-not $content -and -not (Test-Path -LiteralPath $desktop)) {
    Write-FailLine 'No -ContentB64 supplied and no MAPDRIVES.CMD on the Public Desktop - nothing to run.'
    exit 1
}

# --------------------------- 2. Save (unless -NoSave) ----------------------
if ($content -and -not $NoSave) {
    try {
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        $content | Set-Content -Path $desktop -Force -Encoding ASCII -ErrorAction Stop
        $content | Set-Content -Path (Join-Path $backupDir 'MAPDRIVES.CMD') -Force -Encoding ASCII -ErrorAction Stop
        Write-OkLine "MAPDRIVES.CMD written to $desktop (+ backup)."
    } catch { Write-FailLine "Could not write MAPDRIVES.CMD: $($_.Exception.Message)"; exit 1 }
} elseif ($NoSave) {
    Write-InfoLine 'NoSave: no MAPDRIVES.CMD will be left on this PC.'
}

# --------------------------- 3. Logon task (optional) ----------------------
if ($LogonTask) {
    try {
        $act = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c ""' + $desktop + '" auto"')
        $trg = New-ScheduledTaskTrigger -AtLogon
        $pri = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -Id 'Author'   # BUILTIN\Users
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Unregister-ScheduledTask -TaskName 'Map Drives' -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName 'Map Drives' -Action $act -Trigger $trg -Principal $pri -Settings $set -Force -ErrorAction Stop | Out-Null
        Write-OkLine "Scheduled task 'Map Drives' (at logon) registered."
    } catch { Write-FailLine "Could not register the logon task: $($_.Exception.Message)" }
}

# --------------------------- 4. EnableLinkedConnections --------------------
if ($EnableLinkedConnections) {
    try {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name 'EnableLinkedConnections' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        Write-OkLine 'EnableLinkedConnections=1 set (takes effect after reboot / LanmanWorkstation restart).'
    } catch { Write-FailLine "Could not set EnableLinkedConnections: $($_.Exception.Message)" }
}

if ($NoRun) { Write-InfoLine 'NoRun specified - not mapping now.'; exit 0 }

# --------------------------- 5. Find the interactive user ------------------
$who = $null
try { $who = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
if (-not $who) {
    try {
        $exp = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
        if ($exp) { $o = Invoke-CimMethod -InputObject $exp -MethodName GetOwner -ErrorAction Stop; if ($o.User) { $who = "$($o.Domain)\$($o.User)" } }
    } catch {}
}
if (-not $who) {
    Write-FailLine 'No interactive user is logged on - there is no session to map into.'
    if (-not $NoSave) { Write-InfoLine 'MAPDRIVES.CMD is on the Public Desktop; it maps when the user runs it (or at logon with -LogonTask).' }
    exit 1
}
Write-InfoLine "Interactive user: $who"

# The user's own Temp (private ACL) for the output file and the -NoSave copy;
# Public\Documents as a fallback.
$work = $null
try {
    $sid  = ([Security.Principal.NTAccount]$who).Translate([Security.Principal.SecurityIdentifier]).Value
    $prof = (Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
    $t = Join-Path ([Environment]::ExpandEnvironmentVariables($prof)) 'AppData\Local\Temp'
    if (Test-Path -LiteralPath $t) { $work = $t }
} catch {}
if (-not $work) { $work = Join-Path $env:PUBLIC 'Documents' }
$id      = [guid]::NewGuid().ToString('N').Substring(0, 8)
$outFile = Join-Path $work "mdt-inject-$id.out"
$runPath = $desktop
if ($NoSave -and $content) {
    $runPath = Join-Path $work "mdt-inject-$id.cmd"
    try { $content | Set-Content -LiteralPath $runPath -Force -Encoding ASCII -ErrorAction Stop }
    catch { Write-FailLine "Could not stage the temporary map script: $($_.Exception.Message)"; exit 1 }
}

# --------------------------- 6. One-shot task in the user's session --------
# RunLevel=Limited + LogonType=Interactive => the user's STANDARD interactive token,
# the same one Explorer uses, so the drives are visible at once.
$taskName = "Map Drives (inject) $id"
$failed = 0
try {
    $act = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c ""' + $runPath + '" auto > "' + $outFile + '" 2>&1"')
    $pri = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $act -Principal $pri -Settings $set -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Write-OkLine "Running MAPDRIVES.CMD in $who's session..."

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Milliseconds 500
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        # 0x41301 = running, 0x41303 = not started yet
    } while ((-not $info -or $info.LastTaskResult -eq 0x41301 -or $info.LastTaskResult -eq 0x41303) -and (Get-Date) -lt $deadline)
    Start-Sleep -Milliseconds 300

    if ($info -and $info.LastTaskResult -eq 0x41301) { Write-FailLine "Still running after $TimeoutSec s - a net use is probably stuck (credentials or an unreachable server)." }
    Write-Output '===USER SESSION OUTPUT==='
    if (Test-Path -LiteralPath $outFile) {
        $lines = @(Get-Content -LiteralPath $outFile | Where-Object { "$_".Trim() })
        foreach ($l in $lines) { Write-Output "    $l" }
        $failed = @($lines | Where-Object { $_ -match 'System error \d+' }).Count
    } else {
        Write-Output '    (no output captured)'
        $failed = 1
    }
    Write-Output '===END==='
} catch {
    Write-FailLine "Could not run in the user's session: $($_.Exception.Message)"
    $failed = 1
} finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    if ($runPath -ne $desktop) { Remove-Item -LiteralPath $runPath -Force -ErrorAction SilentlyContinue }
}

if ($failed -eq 0) { Write-OkLine "Done - the drives should now be visible in $who's Explorer."; exit 0 }
else { Write-FailLine "$failed problem(s) - see the user-session output above. For connection errors (e.g. 'System error 59') run Diagnose-MapError.Atera.ps1."; exit 1 }
