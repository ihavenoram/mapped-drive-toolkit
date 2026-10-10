<#
=========================================================
Script Name: Diagnose-MapError.Atera
Description: Pinpoints WHY a network drive won't map when net use fails with a
             CONNECTION-level error - System error 59 "An unexpected network error
             occurred", 53, 64, 1231, 1272 - the failures a password, the fixer or
             the injector cannot fix (they happen before the login is checked).

             For each target share it checks, then ranks the likely cause:
               - path type: SharePoint/WebDAV (@SSL\DavWWWRoot), \\tsclient (RDP)
               - name resolution, ping, TCP 445 / 139 (SMB1-only devices)
               - the live SMB connection to that server (dialect, signed?)
               - AS THE LOGGED-ON USER (one-shot task when run as SYSTEM):
                   net view \\server  -> the share names the device offers NOW
                   dir \\server\share -> the user's real result for each share
                 This is what separates "the server is broken" from "that one
                 share is broken" (e.g. a Synology usbshare whose USB disk is gone).
               - an anonymous test connection made by SYSTEM
               - this PC's SMB client rules (Win11 24H2: signing required, guest
                 blocked, NTLM blocking), SMB1 client state
               - recent SMBClient WARNING/ERROR events for that server, with
                 NTSTATUS codes decoded (information events are ignored)

             Read-only, apart from short-lived test connections and a one-shot
             scheduled task, all removed again. Never prints passwords (cmdkey
             lines are not read).
Category:    ScriptLibrary
Run Time:    5 minutes
Arguments:   (none)                       every drive in MAPDRIVES.CMD + the users' mappings
             -Unc "\\server\share"        just this share (comma-separate several)
             -EventHours 48               look further back in the SMB event logs
Run As:      System (Atera)  - or paste into ScreenConnect Backstage PowerShell.
             With a user logged on, the user-session tests run automatically.
=========================================================
#>
#Requires -Version 5.1
param(
    [string]$Unc,              # string, not string[]: Atera -File collapses arrays
    [int]$EventHours = 24
)

$ErrorActionPreference = 'Continue'
function Out-Line([string]$Tag, [string]$Msg) { Write-Output ("[{0}] {1}" -f $Tag, $Msg) }
$me       = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem = ($me.User.Value -eq 'S-1-5-18')
$build    = try { [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber } catch { 0 }

# --------------------------- helpers --------------------------------------
function Get-NetCode([string]$Text, [int]$Exit) {
    if ($Text -match 'System error (\d+)') { return [long]$Matches[1] }
    if ($Exit -eq 0) { return 0 }
    -1
}
function Invoke-NetNoPrompt([string]$NetArgs) {
    # cmd + <nul + explicit credentials: net use must never stop at an
    # "Enter the user name" prompt - under Atera that is cancelled (error 1223,
    # masking the real code) and in an interactive console it would hang.
    $o = (& cmd.exe /c ("net $NetArgs <nul 2>&1") | Out-String)
    [pscustomobject]@{ Text = $o; Exit = $LASTEXITCODE }
}
function Get-CodeMeaning([long]$Code) {
    switch ($Code) {
        0    { 'OK' }
        5    { 'access denied' }
        53   { 'network path not found' }
        59   { 'unexpected network error - connection dropped during setup' }
        64   { 'network name no longer available - connection dropped' }
        67   { 'share name not found on that server' }
        86   { 'password refused' }
        1219 { 'conflicting connection with other credentials' }
        1223 { 'cancelled at a credential prompt' }
        1231 { 'network location cannot be reached' }
        1272 { 'blocked as an unauthenticated GUEST connection' }
        1326 { 'username/password refused' }
        default { if ($Code -lt 0) { 'unknown result' } else { "system error $Code" } }
    }
}
function Get-DirCode([string]$Text) {
    # 'dir' prints messages, not codes - map the common ones back to codes.
    if ($Text -match 'Directory of') { return 0 }
    if ($Text -match 'System error (\d+)') { return [long]$Matches[1] }
    $map = [ordered]@{
        'unexpected network error' = 59; 'network name cannot be found' = 67; 'network path was not found' = 53
        'no longer available' = 64; 'Access is denied' = 5; 'user name or password is incorrect' = 1326
        'network password is not correct' = 86; 'guest access' = 1272; 'cannot be reached' = 1231
    }
    foreach ($k in $map.Keys) { if ($Text -match [regex]::Escape($k)) { return $map[$k] } }
    -1
}
function Resolve-V4([string]$Name, [int]$Ms = 3000) {
    if ($Name -match '^\d{1,3}(\.\d{1,3}){3}$') { return @($Name) }
    try {
        $iar = [Net.Dns]::BeginGetHostAddresses($Name, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($Ms, $false)) {
            return @([Net.Dns]::EndGetHostAddresses($iar) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
        }
    } catch {}
    @()
}
function Test-Tcp([string]$Ip, [int]$Port, [int]$Ms = 3000) {
    # 3 s: a REFUSED connect takes ~2 s to surface on Windows.
    $c = New-Object Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($Ip, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($Ms, $false)) { return 'no answer (filtered)' }
        $c.EndConnect($iar); 'open'
    } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        if ($e -is [Net.Sockets.SocketException]) { "closed ($($e.SocketErrorCode))" } else { 'error' }
    } finally { $c.Close() }
}
function Get-InteractiveUserName {
    $u = $null
    try { $u = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
    if (-not $u) {
        try {
            $p = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
            if ($p) { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop; if ($o.User) { $u = "$($o.Domain)\$($o.User)" } }
        } catch {}
    }
    $u
}
$interactive = if ($isSystem) { Get-InteractiveUserName } else { $me.Name }

function Invoke-AsUser([string]$CmdLine, [int]$TimeoutSec = 60) {
    # Runs a cmd line as the logged-on user: in-process when we ARE that user,
    # otherwise via a one-shot task (their standard token - same as Explorer).
    if (-not $isSystem) {
        $o = (& cmd.exe /c ("(" + $CmdLine + ") <nul 2>&1") | Out-String)
        return [pscustomobject]@{ Ok = $true; Out = $o; Msg = "ran as $($me.Name)" }
    }
    if (-not $interactive) { return [pscustomobject]@{ Ok = $false; Out = ''; Msg = 'no user is logged on' } }
    $dir = Join-Path $env:PUBLIC 'Documents'; if (-not (Test-Path $dir)) { $dir = $env:PUBLIC }
    $id  = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $bat = Join-Path $dir "mdt-diag-$id.cmd"; $out = Join-Path $dir "mdt-diag-$id.out"
    $tn  = "MDT diag probe $id"
    try {
        Set-Content -LiteralPath $bat -Value ("@echo off`r`n(" + $CmdLine + ") <nul > `"$out`" 2>&1`r`n") -Encoding ASCII
        $act = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $bat + '"')
        $pri = New-ScheduledTaskPrincipal -UserId $interactive -LogonType Interactive -RunLevel Limited
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $tn -Action $act -Principal $pri -Settings $set -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $tn -ErrorAction Stop
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        do {
            Start-Sleep -Milliseconds 400
            $i = Get-ScheduledTaskInfo -TaskName $tn -ErrorAction SilentlyContinue
            # 0x41301 = running, 0x41303 = not started yet.
        } while ((-not $i -or $i.LastTaskResult -eq 0x41301 -or $i.LastTaskResult -eq 0x41303) -and (Get-Date) -lt $deadline)
        Start-Sleep -Milliseconds 300
        if (Test-Path -LiteralPath $out) { return [pscustomobject]@{ Ok = $true; Out = (Get-Content -LiteralPath $out -Raw); Msg = "ran as $interactive" } }
        [pscustomobject]@{ Ok = $false; Out = ''; Msg = "no output within $TimeoutSec s" }
    } catch {
        [pscustomobject]@{ Ok = $false; Out = ''; Msg = "$($_.Exception.Message)" }
    } finally {
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $bat, $out -Force -ErrorAction SilentlyContinue
    }
}

Write-Output '===MAP ERROR DIAGNOSIS==='
Out-Line INFO ("Host: {0}   Context: {1}   Logged-on user: {2}   Windows build: {3}{4}" -f $env:COMPUTERNAME, $me.Name, $(if ($interactive) { $interactive } else { '(none)' }), $build, $(if ($build -ge 26100) { ' (24H2+: SMB signing required + guest blocked by default)' } else { '' }))

# --------------------------- 1. What should be mapped ---------------------
$order = New-Object System.Collections.ArrayList
$targets = @{}
function Add-Target([string]$Path, [string]$Letter, [string]$Source) {
    $p = "$Path".Trim().TrimEnd('\')
    if (-not $p) { return }
    $k = $p.ToLower()
    if (-not $targets.ContainsKey($k)) {
        $targets[$k] = [pscustomobject]@{ Unc = $p; Letters = ''; Sources = '' }
        [void]$order.Add($k)
    }
    $t = $targets[$k]
    if ($Letter -and ($t.Letters -notmatch "(^|,)$Letter(,|$)")) { $t.Letters = (@($t.Letters, $Letter) | Where-Object { $_ }) -join ',' }
    if ($Source -and ($t.Sources -notmatch [regex]::Escape($Source))) { $t.Sources = (@($t.Sources, $Source) | Where-Object { $_ }) -join '; ' }
}
if ($Unc) {
    foreach ($u in ($Unc -split '[,;]')) { Add-Target $u '' 'argument' }
} else {
    foreach ($f in @((Join-Path $env:PUBLIC 'Desktop\MAPDRIVES.CMD'), 'C:\ProgramData\MappedDriveToolkit\MAPDRIVES.CMD', 'C:\temp\MAPDRIVES.CMD')) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        # Only the net use lines - the cmdkey line (password) is never read out.
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $f -Raw), '(?im)^\s*net use ([A-Z]):\s+"([^"]+)"')) {
            Add-Target $m.Groups[2].Value $m.Groups[1].Value $f
        }
    }
    Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | ForEach-Object {
        $sid = $_.Name.Replace('HKEY_USERS\', '')
        if ($sid.EndsWith('_Classes') -or $sid -match '^S-1-5-1[890]$') { return }
        $who = $sid; try { $who = ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value } catch {}
        $net = "Registry::$($_.Name)\Network"
        if (Test-Path $net) {
            Get-ChildItem $net -ErrorAction SilentlyContinue | ForEach-Object {
                $rp = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).RemotePath
                if ($rp) { Add-Target $rp $_.PSChildName.ToUpper() "mapping of $who" }
            }
        }
    }
}
if ($order.Count -eq 0) {
    Out-Line FAIL 'Nothing to test: no MAPDRIVES.CMD found and no user mappings. Re-run with -Unc "\\server\share".'
    exit 1
}
# Share roots per SMB server, so each server's user-session test runs once.
$rootsBySrv = @{}
foreach ($k in $order) {
    if ($targets[$k].Unc -match '^\\\\([^\\@]+)\\([^\\]+)') {
        $s = $Matches[1].ToLower(); $r = "\\$($Matches[1])\$($Matches[2])"
        if (-not $rootsBySrv.ContainsKey($s)) { $rootsBySrv[$s] = New-Object System.Collections.ArrayList }
        if (-not ($rootsBySrv[$s] -contains $r)) { [void]$rootsBySrv[$s].Add($r) }
    }
}

# --------------------------- 2. This PC's SMB client rules ----------------
Write-Output ''
Write-Output '===SMB CLIENT (this PC)==='
$requireSigning = $null
try {
    $cfg = Get-SmbClientConfiguration -ErrorAction Stop
    $requireSigning = [bool]$cfg.RequireSecuritySignature
    foreach ($p in $cfg.PSObject.Properties) {
        if ($p.Name -match '^(RequireSecuritySignature|EnableSecuritySignature|EnableInsecureGuestLogons|RequireEncryption)$' -or $p.Name -match 'Dialect|NTLM') {
            Out-Line INFO ("{0} = {1}" -f $p.Name, $p.Value)
        }
    }
} catch { Out-Line WARN "Get-SmbClientConfiguration failed: $($_.Exception.Message)" }
$smb1 = 'not installed'
try {
    $st = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10' -Name Start -ErrorAction Stop).Start
    $smb1 = if ($st -eq 4) { 'installed but disabled' } else { 'ENABLED' }
} catch {}
Out-Line INFO "SMB1 client: $smb1"
try { $gp = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' -Name AllowInsecureGuestAuth -ErrorAction Stop).AllowInsecureGuestAuth; Out-Line INFO "Policy AllowInsecureGuestAuth = $gp" } catch {}
$webClient = try { "$((Get-Service WebClient -ErrorAction Stop).Status)" } catch { 'not installed' }
Out-Line INFO "WebClient (WebDAV) service: $webClient"

# --------------------------- 3. Recent SMB client events ------------------
$since = (Get-Date).AddHours(-[Math]::Abs($EventHours))
$events = @()
$eventLogsRead = 0
foreach ($log in 'Microsoft-Windows-SMBClient/Security', 'Microsoft-Windows-SMBClient/Connectivity', 'Microsoft-Windows-SMBClient/Operational') {
    try {
        $events += @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since } -MaxEvents 300 -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Time = $_.TimeCreated; Log = ($log -split '/')[-1]; Id = $_.Id; Level = [int]$_.Level; Msg = ("$($_.Message)" -replace '\s+', ' ').Trim() }
        })
        $eventLogsRead++
    } catch {
        if ("$($_.Exception.Message)" -match '(?i)no events were found') { $eventLogsRead++ }
    }
}
$ntStatus = @{
    '0XC000A000' = 'INVALID SIGNATURE - SMB signing mismatch'
    '0XC0000388' = 'DOWNGRADE DETECTED - negotiation validation failed (signing/dialect)'
    '0XC00000BB' = 'NOT SUPPORTED - the device rejected a required feature (dialect, signing, NTLM)'
    '0XC00000E9' = 'UNEXPECTED NETWORK ERROR (this is error 59)'
    '0XC000020C' = 'CONNECTION DISCONNECTED'
    '0XC000013C' = 'REMOTE DISCONNECT - the server dropped the connection'
    '0XC000023A' = 'CONNECTION ABORTED'
    '0XC0000236' = 'CONNECTION REFUSED'
    '0XC00000B5' = 'I/O TIMEOUT'
    '0XC0000466' = 'SERVER UNAVAILABLE'
    '0XC00000CC' = 'BAD NETWORK NAME - that share does not exist'
    '0XC000006D' = 'LOGON FAILURE'
    '0XC000006A' = 'WRONG PASSWORD'
    '0XC0000064' = 'NO SUCH USER'
    '0XC000006E' = 'ACCOUNT RESTRICTION'
    '0XC0000072' = 'ACCOUNT DISABLED'
    '0XC0000022' = 'ACCESS DENIED'
    '0XC000005E' = 'NO LOGON SERVERS'
}

# --------------------------- 4. Per share ---------------------------------
$summary = New-Object System.Collections.ArrayList
$hostDone = @{}
foreach ($k in $order) {
    $t = $targets[$k]
    $path = $t.Unc
    Write-Output ''
    Write-Output ("===TARGET {0}{1}===" -f $path, $(if ($t.Letters) { "  (drive $($t.Letters))" } else { '' }))
    Out-Line INFO "Found in: $($t.Sources)"

    # Path type first - some can never be mapped by net use + saved credentials.
    if ($path -match '^https?:' -or $path -match '@SSL' -or $path -match 'DavWWWRoot' -or $path -match '^\\\\[^\\]+@\d+') {
        Out-Line FAIL 'SharePoint / WebDAV path, not an SMB share. net use relies on the user''s browser sign-in and the WebClient service here, not on saved credentials - error 59 is the classic symptom. Use OneDrive sync ("Add shortcut to My files") instead, or remove it from the profile.'
        [void]$summary.Add("$path : SharePoint/WebDAV path - cannot be recreated by MAPDRIVES.CMD (use OneDrive sync)")
        continue
    }
    if ($path -notmatch '^\\\\([^\\]+)\\([^\\]+)') { Out-Line WARN "Not a \\server\share path - skipped."; continue }
    $srv = $Matches[1]; $share = $Matches[2]
    $root = "\\$srv\$share"
    if ($srv -ieq 'tsclient') {
        Out-Line FAIL '\\tsclient is an RDP-redirected local drive. It exists only inside an RDP session - remove it from the profile.'
        [void]$summary.Add("$path : RDP-redirected drive (\\tsclient) - remove it from the profile")
        continue
    }

    # ---- Server-level checks (once per server) ----
    if (-not $hostDone.ContainsKey($srv.ToLower())) {
        $h = [pscustomobject]@{ Ips = @(); Ping = $false; P445 = ''; P139 = ''; ViewCode = $null; Dialect = $null; Signed = $null
                                EvFlags = @(); UserRan = $false; UserMsg = ''; UserShares = @(); UserViewCode = $null; UserDir = @{} }
        $h.Ips = @(Resolve-V4 $srv)
        if ($h.Ips.Count -eq 0) {
            Out-Line FAIL "'$srv' does not resolve to an IPv4 address (DNS/NetBIOS)."
        } else {
            $ip = $h.Ips[0]
            Out-Line OK ("'{0}' -> {1}" -f $srv, ($h.Ips -join ', '))
            $h.Ping = [bool](Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue)
            $h.P445 = Test-Tcp $ip 445
            $h.P139 = Test-Tcp $ip 139
            Out-Line INFO ("Ping: {0}   TCP 445 (SMB2/3): {1}   TCP 139 (NetBIOS/SMB1): {2}" -f $(if ($h.Ping) { 'reply' } else { 'no reply' }), $h.P445, $h.P139)
        }
        if ($h.P445 -eq 'open') {
            $nv = Invoke-NetNoPrompt ('view "\\' + $srv + '"')
            $h.ViewCode = Get-NetCode $nv.Text $nv.Exit
            Out-Line INFO ("Anonymous test as {0} (net view \\{1}): {2} - {3}" -f $(if ($isSystem) { 'SYSTEM' } else { 'this account' }), $srv, $(if ($h.ViewCode -ge 0) { "code $($h.ViewCode)" } else { 'no code' }), (Get-CodeMeaning $h.ViewCode))
            try {
                $sc = Get-SmbConnection -ServerName $srv -ErrorAction Stop | Select-Object -First 1
                if ($sc) {
                    $h.Dialect = "$($sc.Dialect)"
                    if ($sc.PSObject.Properties['Signed']) { $h.Signed = [bool]$sc.Signed }
                    Out-Line OK ("Live SMB connection to {0}: dialect {1}{2}" -f $srv, $h.Dialect, $(if ($null -ne $h.Signed) { "   signed: $($h.Signed)" } else { '' }))
                }
            } catch {}

            # ---- AS THE LOGGED-ON USER: share list + each share's real result ----
            $roots = @($rootsBySrv[$srv.ToLower()])
            $parts = @('net view "\\' + $srv + '"')
            foreach ($r in $roots) { $parts += ('echo ===DIR ' + $r + '==='); $parts += ('dir "' + $r + '"') }
            $ur = Invoke-AsUser ($parts -join ' & ') (30 + 15 * $roots.Count)
            $h.UserRan = $ur.Ok; $h.UserMsg = $ur.Msg
            if ($ur.Ok) {
                $chunks = [regex]::Split("$($ur.Out)", '===DIR ')
                $viewTxt = $chunks[0]
                $h.UserViewCode = Get-NetCode $viewTxt 0
                $h.UserShares = @(($viewTxt -split "`r?`n") | ForEach-Object { if ($_ -match '^(.+?)\s{2,}(Disk|Print|IPC|Device)\b') { $Matches[1].Trim() } })
                if ($h.UserShares.Count) { Out-Line OK ("As {0}: {1} offers {2}" -f $interactive, $srv, (($h.UserShares | ForEach-Object { "'$_'" }) -join ', ')) }
                elseif ($viewTxt -match 'System error (\d+)') { Out-Line WARN ("As {0}: net view \\{1} -> system error {2} ({3})" -f $interactive, $srv, $Matches[1], (Get-CodeMeaning ([long]$Matches[1]))) }
                for ($ci = 1; $ci -lt $chunks.Count; $ci++) {
                    $c = $chunks[$ci]
                    $nl = $c.IndexOf('===')
                    if ($nl -lt 0) { continue }
                    $rName = $c.Substring(0, $nl).Trim()
                    $body = $c.Substring($nl + 3)
                    $code = Get-DirCode $body
                    $first = @(($body -split "`r?`n") | Where-Object { "$_".Trim() } | Select-Object -First 1)
                    $h.UserDir[$rName.ToLower()] = [pscustomobject]@{ Code = $code; Text = "$($first -join '')".Trim() }
                    $tag = if ($code -eq 0) { 'OK' } else { 'FAIL' }
                    Out-Line $tag ("As {0}: dir {1} -> {2}" -f $interactive, $rName, $(if ($code -eq 0) { 'opens fine' } else { "$(Get-CodeMeaning $code) ('$("$($first -join '')".Trim())')" }))
                }
            } else {
                Out-Line INFO "User-session test not run: $($ur.Msg)"
            }
        }

        # Only WARNING/ERROR events are evidence - 'connection established ...
        # Signing used: true' information events are routine and prove nothing bad.
        $needles = @($srv) + @($h.Ips)
        $mention = @($events | Where-Object { $m = $_.Msg; @($needles | Where-Object { $m -match [regex]::Escape($_) }).Count -gt 0 })
        $bad = @($mention | Where-Object { $_.Level -ge 1 -and $_.Level -le 3 } | Sort-Object Time -Descending)
        $info = $mention.Count - $bad.Count
        if ($bad.Count) {
            Out-Line INFO ("{0} SMB client warning/error event(s) mention {1} in the last {2} h (newest first){3}:" -f $bad.Count, $srv, $EventHours, $(if ($info) { " - $info routine information event(s) ignored" } else { '' }))
            foreach ($e in @($bad | Select-Object -First 8)) {
                $codes = @([regex]::Matches($e.Msg, '0[xX][cC]0[0-9a-fA-F]{6}') | ForEach-Object { $_.Value.ToUpper() } | Select-Object -Unique)
                $dec = @($codes | ForEach-Object { if ($ntStatus.ContainsKey($_)) { "$_ = $($ntStatus[$_])" } else { $_ } }) -join '; '
                $txt = if ($e.Msg.Length -gt 220) { $e.Msg.Substring(0, 220) + '...' } else { $e.Msg }
                Out-Line WARN ("{0:yyyy-MM-dd HH:mm} {1} {2}: {3}{4}" -f $e.Time, $e.Log, $e.Id, $txt, $(if ($dec) { "  [$dec]" } else { '' }))
                if ($codes -contains '0XC000A000' -or $codes -contains '0XC0000388') { $h.EvFlags += 'signing' }
                if ($codes -contains '0XC00000BB') { $h.EvFlags += 'notsupported' }
                if ($e.Msg -match '(?i)(signature|signing).{0,60}(invalid|fail|mismatch|required)|(invalid|fail|mismatch).{0,60}(signature|signing)') { $h.EvFlags += 'signing' }
                if ($e.Msg -match '(?i)guest') { $h.EvFlags += 'guest' }
                if ($e.Msg -match '(?i)NTLM') { $h.EvFlags += 'ntlm' }
            }
        } elseif ($eventLogsRead -eq 0) {
            Out-Line INFO 'SMB client event logs could not be read (run as SYSTEM/admin).'
        } else {
            Out-Line OK ("No SMB client warnings/errors mention {0} in the last {1} h{2}." -f $srv, $EventHours, $(if ($info) { " ($info routine information event(s) ignored)" } else { '' }))
        }
        # A live, SIGNED connection proves signing works - never blame it then.
        if ($h.Signed -eq $true) { $h.EvFlags = @($h.EvFlags | Where-Object { $_ -ne 'signing' }) }
        $h.EvFlags = @($h.EvFlags | Select-Object -Unique)
        $hostDone[$srv.ToLower()] = $h
    }
    $h = $hostDone[$srv.ToLower()]

    # ---- Anonymous connect to the share ROOT (session-level result only) ----
    $shareCode = $null
    if ($h.P445 -eq 'open') {
        $su = Invoke-NetNoPrompt ('use "' + $root + '" "" /user:""')
        $shareCode = Get-NetCode $su.Text $su.Exit
        if ($shareCode -eq 0) { [void](Invoke-NetNoPrompt ('use "' + $root + '" /delete /y')) }
        Out-Line INFO ("Anonymous test ({0}): {1} - {2}" -f $root, $(if ($shareCode -ge 0) { "code $shareCode" } else { 'no code' }), (Get-CodeMeaning $shareCode))
    }

    # ---- Ranked conclusion for this target ----
    $ud = $h.UserDir[$root.ToLower()]
    $userCode = if ($ud) { $ud.Code } else { $null }
    $otherOk = @($h.UserDir.Keys | Where-Object { $_ -ne $root.ToLower() -and $h.UserDir[$_].Code -eq 0 }).Count -gt 0
    $serverFine = ($otherOk -or $h.Signed -eq $true -or $h.UserViewCode -eq 0 -or $h.UserShares.Count -gt 0)
    $listed = @($h.UserShares | Where-Object { $_ -ieq $share }).Count -gt 0
    $usbHint = if ($share -match '^usbshare') { " On a Synology, '$share' is the automatic share for a USB disk plugged into the NAS: check DSM > Control Panel > External Devices (is the disk connected and mounted?) and Shared Folder (its current name - DSM names USB shares by port/partition: usbshare1, usbshare1-1, usbshare2...)." } else { '' }
    $why = $null
    if ($h.Ips.Count -eq 0) {
        $why = "'$srv' does not resolve - wrong/old server name, or DNS/NetBIOS can't find it. Try the IP, or fix DNS."
    } elseif ($h.P445 -ne 'open') {
        if ($h.P139 -like 'open*') { $why = "Only NetBIOS/SMB1 (139) answers on $srv - an SMB1-only device. Windows 11 doesn't speak SMB1 (client: $smb1). Enable SMB2/3 on the device, or replace it." }
        elseif ($h.Ping) { $why = "$srv is up but SMB (445) is $($h.P445) - firewall on the device, or file sharing turned off." }
        else { $why = "$srv is unreachable (no ping, no SMB) - powered off, wrong IP, or a different network/VPN down." }
    } elseif ($userCode -eq 0) {
        $why = "Works now: '$root' opens fine as $interactive. If the drive letter still fails, re-run Apply now / the injector (it may have been temporary)."
    } elseif ($h.UserShares.Count -gt 0 -and -not $listed -and $share -notmatch '\$$') {
        # (hidden shares - name ending in $ - never appear in net view)
        # Near-miss names: case, spaces/underscores and LEADING zeros of a number
        # (usbshare01 vs usbshare1). Hyphens are kept - usbshare1-1 is a different
        # partition, not usbshare11 - and mid-number zeros are kept (share100 != share10).
        $norm = { param($n) (("$n".ToLower() -replace '[\s_]', '') -replace '(?<!\d)0+(?=\d)', '') }
        $wanted = & $norm $share
        $near = @($h.UserShares | Where-Object { (& $norm $_) -eq $wanted })
        $didYouMean = if ($near.Count) { " DID YOU MEAN '$($near[0])'? Re-map to \\$srv\$($near[0])." } else { '' }
        $why = "'$share' is NOT offered by $srv right now - it offers: $(($h.UserShares | ForEach-Object { "'$_'" }) -join ', ').$didYouMean The share was renamed or removed, or the storage behind it is offline.$usbHint"
    } elseif (($userCode -eq 59 -or $userCode -eq 64) -and $serverFine) {
        $why = "$srv itself is fine$(if ($h.Dialect) { " (SMB $($h.Dialect)$(if ($h.Signed) { ', signed' }))" })$(if ($otherOk) { ' and its other shares open' }), but '$share' fails with error $userCode for $interactive - the folder BEHIND that share is unavailable on the device (disk offline/asleep/unmountable, or a volume error).$usbHint"
    } elseif ($userCode -eq 5) {
        $why = "Access denied for $interactive on '$share' - the login to $srv works; the share/folder permissions on the device don't allow the account being used."
    } elseif ($userCode -in 1326, 86) {
        $why = "$srv refuses the credentials $interactive's session uses for '$share' - check the saved credential (cmdkey /list) and the account on the device."
    } elseif ($userCode -eq 67 -or $shareCode -eq 67) {
        $why = "The share '$share' does not exist on $srv (renamed or removed).$usbHint"
    } elseif ($h.EvFlags -contains 'guest' -or $shareCode -eq 1272 -or $userCode -eq 1272) {
        $why = "Guest access is being blocked. The share only allows guest/anonymous access, which Windows 11 refuses. Give it a real account on the device and save that credential (cmdkey)."
    } elseif ($h.EvFlags -contains 'signing') {
        $why = "SMB SIGNING mismatch: the SMB client logged signature failures for $srv and this PC requires signed SMB$(if ($build -ge 26100) { ' (Windows 11 24H2 default)' }). FIX ON THE DEVICE: enable SMB signing / SMB3 (Synology: Control Panel > File Services > SMB > Advanced). To CONFIRM only: Set-SmbClientConfiguration -RequireSecuritySignature `$false -Force, retry, then set it back to `$true."
    } elseif ($h.EvFlags -contains 'ntlm') {
        $why = "NTLM is being blocked or rejected for $srv. Connecting by IP forces NTLM - map by server NAME so Kerberos is used, or allow NTLM for that server."
    } elseif (($userCode -eq 59 -or $h.ViewCode -eq 59 -or $shareCode -eq 59) -and -not $serverFine) {
        $why = "SMB setup with $srv fails with error 59 before any login - a protocol/transport problem with that DEVICE (dialect, signing, encryption, firmware, or VPN/MTU if remote). Check the warning events above and the device's SMB settings."
    } elseif ($serverFine -and -not $h.UserRan) {
        $why = "$srv negotiates fine$(if ($h.Dialect) { " (SMB $($h.Dialect))" }), so the problem is specific to '$share' or the user's session. Re-run as SYSTEM while the user is logged on (or as the user) so the share can be tested in their session.$usbHint"
    } else {
        $why = "No single cause identified - see the checks above."
    }
    Out-Line RESULT $why
    [void]$summary.Add("$path : $why")
}

Write-Output ''
Write-Output '===SUMMARY==='
foreach ($s in $summary) { Write-Output "  - $s" }
exit 0
