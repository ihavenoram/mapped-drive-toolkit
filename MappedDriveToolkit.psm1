<#
=========================================================
Module:      MappedDriveToolkit
Description: Shared core for the Mapped Drive Toolkit. Single source of truth for
             the canonical drive-map JSON model, MAPDRIVES.CMD generation, Public
             Desktop / backup deployment, the optional logon scheduled task,
             current-mapping enumeration, and share-device identification.

             Consumed by:
               MapDrives-Gui.ps1               (the WinForms GUI: Drives & Apply +
                                                Doctor & Diagnostics tabs)
             The Atera scripts (Get-DriveMappings, Inject-MapDrives, Diagnose-MapError)
             are deliberately self-contained and do not import this module.

             Faithful to the proven field scripts it replaced:
               - cmdkey /add:<target> /user:<IP-or-SERVER>\user /pass:"..."
                 (IP/SERVER-qualified for Win11 24H2 SMB + workgroup local accounts)
               - idempotent remap: if exist X:\ net use X: /delete /y  then
                 net use X: "<unc>" /PERSISTENT:YES
               - quote UNC paths containing spaces
               - pause only when run manually (cmdcmdline /c test)
               - enumerate maps from HKEY_USERS\<SID>\Network\<letter>\RemotePath

Requires:    Windows PowerShell 5.1+
=========================================================
#>

#Requires -Version 5.1
# StrictMode 1.0 (uninitialized-variable protection) - NOT 2.0/Latest: on
# Windows PowerShell 5.1 those flag the intrinsic .Count/.Length members on
# scalars, so any single-element pipeline result (one mapped drive, one group)
# throws "The property 'Count' cannot be found on this object". PS7 special-
# cases intrinsic members, which hides the bug during PS7 testing.
Set-StrictMode -Version 1.0

# ---------------------------------------------------------------------------
# region  Constants
# ---------------------------------------------------------------------------

# CLSID for "This PC" desktop icon (used by the original field script).
$script:ThisPcClsid = '{20D04FE0-3AEA-1069-A2D8-08002B30309D}'

# Default deployment locations.
$script:DefaultPublicDesktopCmd = Join-Path $env:PUBLIC 'Desktop\MAPDRIVES.CMD'
$script:DefaultBackupDir        = 'C:\ProgramData\MappedDriveToolkit'
$script:DefaultBackupCmd        = Join-Path $script:DefaultBackupDir 'MAPDRIVES.CMD'

$script:LogonTaskName = 'Map Drives'

# Stamped into generated MAPDRIVES.CMD headers for field traceability.
$script:ToolkitVersion = '3.0'

function Get-ToolkitVersion {
    <# Version of THIS loaded module - lets a GUI show/verify which copy is running. #>
    [CmdletBinding()] param()
    $script:ToolkitVersion
}

# Known NAS / device OUI prefixes (first 3 MAC octets, upper-case, colon form).
# Extend freely - used by Resolve-ShareDevice for vendor hints.
$script:OuiVendors = @{
    '00:11:32' = 'Synology'
    '90:09:D0' = 'Synology'
    '00:08:9B' = 'QNAP'
    '24:5E:BE' = 'QNAP'
    '00:15:5D' = 'Microsoft Hyper-V'
    '00:50:56' = 'VMware'
    '00:1C:14' = 'VMware'
    'B8:27:EB' = 'Raspberry Pi'
    'DC:A6:32' = 'Raspberry Pi'
}

# endregion

# ---------------------------------------------------------------------------
# region  Helpers
# ---------------------------------------------------------------------------

function Get-UncHost {
    <#
    .SYNOPSIS
        Extract the host (server name or IP) from a UNC path like \\host\share\dir.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Unc)

    $u = $Unc.Trim()
    if ($u -match '^\\\\([^\\]+)\\') { return $Matches[1] }
    if ($u -match '^\\\\([^\\]+)$')  { return $Matches[1] }
    return $null
}

function ConvertTo-NormalizedLetter {
    <# Returns a single upper-case drive letter (no colon) or $null. #>
    param([string]$Letter)
    if ([string]::IsNullOrWhiteSpace($Letter)) { return $null }
    $c = $Letter.Trim().TrimEnd(':').ToUpper()
    if ($c.Length -eq 1 -and $c -match '^[A-Z]$') { return $c }
    return $null
}

function Get-PropOrDefault {
    <# Safe property access for PSCustomObjects parsed from JSON (StrictMode-safe). #>
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') { return $prop.Value }
    return $Default
}

# endregion

# ---------------------------------------------------------------------------
# region  JSON model
# ---------------------------------------------------------------------------

function New-DriveEntry {
    <# Normalize one raw drive object into the canonical shape. #>
    param($Raw)

    $letter = ConvertTo-NormalizedLetter (Get-PropOrDefault $Raw 'letter' (Get-PropOrDefault $Raw 'DriveLetter' ''))
    $unc    = (Get-PropOrDefault $Raw 'unc' (Get-PropOrDefault $Raw 'RemotePath' '')).ToString().Trim()
    if (-not $letter -or -not $unc) { return $null }

    $tokens = @()
    $rawTokens = Get-PropOrDefault $Raw 'tokens' $null
    if ($rawTokens) { $tokens = @($rawTokens) }
    # Also auto-detect %TOKEN% style placeholders in the UNC.
    foreach ($m in [regex]::Matches($unc, '%([A-Za-z0-9_]+)%')) {
        if ($tokens -notcontains $m.Groups[1].Value) { $tokens += $m.Groups[1].Value }
    }

    $persistent = Get-PropOrDefault $Raw 'persistent' $true
    if ($persistent -is [string]) { $persistent = $persistent -notmatch '^(?i:false|no|0)$' }

    [PSCustomObject]@{
        Letter         = $letter
        Unc            = $unc
        Label          = (Get-PropOrDefault $Raw 'label' "$letter`: drive")
        Group          = (Get-PropOrDefault $Raw 'group' 'standard').ToString().ToLower()
        Persistent     = [bool]$persistent
        Tokens         = $tokens
        ConnectionUser = (Get-PropOrDefault $Raw 'connectionUser' (Get-PropOrDefault $Raw 'ConnectionUser' $null))
        # Authenticating identity detected by Resolve-DriveCredentials / the collector.
        # Informational only - generation uses the profile-level credential block.
        CredUser       = (Get-PropOrDefault $Raw 'credUser'   (Get-PropOrDefault $Raw 'CredUser'   $null))
        CredSource     = (Get-PropOrDefault $Raw 'credSource' (Get-PropOrDefault $Raw 'CredSource' $null))
        CredTarget     = (Get-PropOrDefault $Raw 'credTarget' (Get-PropOrDefault $Raw 'CredTarget' $null))
        CredNote       = (Get-PropOrDefault $Raw 'credNote'   (Get-PropOrDefault $Raw 'CredNote'   $null))
    }
}

function ConvertFrom-DriveMapJson {
    <#
    .SYNOPSIS
        Parse drive-map JSON (string or object) into a normalized profile object.
    .DESCRIPTION
        Accepts either a single profile { site, credential, options, drives } or an
        ARRAY of profiles / drive-collections (e.g. multi-machine collector output).
        When given an array, drives are merged and de-duped by Letter+Unc, and the
        first non-empty site/credential/options win.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$Json)

    process {
        if ($Json -is [string]) {
            # Tolerate console noise around the JSON (the collector's "=====" marker
            # lines, Atera banners, etc.): extract from the first {/[ to the last }/].
            $text = $Json
            $iObj = $text.IndexOf('{'); $iArr = $text.IndexOf('[')
            $start = @($iObj, $iArr) | Where-Object { $_ -ge 0 } | Sort-Object | Select-Object -First 1
            if ($null -ne $start) {
                $endChar = if ($text[$start] -eq '{') { '}' } else { ']' }
                $end = $text.LastIndexOf($endChar)
                if ($end -gt $start) { $text = $text.Substring($start, $end - $start + 1) }
            }
            try { $obj = $text | ConvertFrom-Json -ErrorAction Stop }
            catch { throw "Invalid JSON: $($_.Exception.Message)" }
        } else {
            $obj = $Json
        }

        $items = if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) { @($obj) } else { @($obj) }

        $site       = $null
        $credential = $null
        $options    = $null
        $allDrives  = New-Object System.Collections.Generic.List[object]
        $seen       = @{}

        foreach ($item in $items) {
            if (-not $site)       { $site       = Get-PropOrDefault $item 'site' $null }
            if (-not $credential) { $credential = Get-PropOrDefault $item 'credential' $null }
            if (-not $options)    { $options    = Get-PropOrDefault $item 'options' $null }

            $rawDrives = Get-PropOrDefault $item 'drives' $null
            if (-not $rawDrives -and ($item -is [System.Collections.IEnumerable])) { $rawDrives = $item }
            foreach ($rd in @($rawDrives)) {
                $entry = New-DriveEntry $rd
                if (-not $entry) { continue }
                $key = "$($entry.Letter)|$($entry.Unc.ToLower())"
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    $allDrives.Add($entry)
                }
            }
        }

        [PSCustomObject]@{
            Site       = if ($site) { $site } else { 'Drive Mapping' }
            Credential = [PSCustomObject]@{
                Mode     = (Get-PropOrDefault $credential 'mode' 'none').ToString().ToLower()
                Target   = Get-PropOrDefault $credential 'target' $null
                User     = Get-PropOrDefault $credential 'user' $null
                Password = Get-PropOrDefault $credential 'password' $null
            }
            Options    = [PSCustomObject]@{
                ShowThisPcIcon  = [bool](Get-PropOrDefault $options 'showThisPcIcon' $false)
                LogonTask       = [bool](Get-PropOrDefault $options 'logonTask' $false)
                RestartExplorer = [bool](Get-PropOrDefault $options 'restartExplorer' $false)
            }
            Drives     = $allDrives.ToArray()
        }
    }
}

function ConvertTo-DriveMapJson {
    <# Serialize a normalized profile (or drive array) to compact canonical JSON. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$DriveProfile,
        [switch]$Compress
    )
    process {
        $drives = @($DriveProfile.Drives | ForEach-Object {
            $d = [ordered]@{ letter = $_.Letter; unc = $_.Unc; label = $_.Label; group = $_.Group }
            if (-not $_.Persistent) { $d.persistent = $false }
            if ($_.Tokens -and @($_.Tokens).Count) { $d.tokens = @($_.Tokens) }
            # Detected authenticating identity (only when known). PSObject lookup so
            # hand-built drive objects without these properties stay StrictMode-safe.
            foreach ($pair in @(@('credUser','CredUser'), @('credSource','CredSource'), @('credTarget','CredTarget'), @('credNote','CredNote'))) {
                $p = $_.PSObject.Properties[$pair[1]]
                if ($p -and $p.Value) { $d[$pair[0]] = "$($p.Value)" }
            }
            [PSCustomObject]$d
        })
        # NOTE: build nested objects separately - nested [ordered]@{} literals throw
        # "Argument types do not match" on some PowerShell builds. [pscustomobject]
        # preserves key order in PS5+ and composes cleanly.
        $credOut = [pscustomobject]@{
            mode     = $DriveProfile.Credential.Mode
            target   = $DriveProfile.Credential.Target
            user     = $DriveProfile.Credential.User
            password = $DriveProfile.Credential.Password
        }
        $optOut = [pscustomobject]@{
            showThisPcIcon  = $DriveProfile.Options.ShowThisPcIcon
            logonTask       = $DriveProfile.Options.LogonTask
            restartExplorer = $DriveProfile.Options.RestartExplorer
        }
        $out = [pscustomobject]@{
            site       = $DriveProfile.Site
            credential = $credOut
            options    = $optOut
            drives     = $drives
        }
        $out | ConvertTo-Json -Depth 6 -Compress:$Compress
    }
}

function Select-ProfileDrives {
    <# Filter a profile's drives by group and/or explicit letters. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DriveProfile,
        [string[]]$Groups,
        [string[]]$Letters
    )
    $drives = @($DriveProfile.Drives)
    if ($Groups)  { $g = $Groups  | ForEach-Object { $_.ToLower() }; $drives = $drives | Where-Object { $g -contains $_.Group } }
    if ($Letters) { $l = $Letters | ForEach-Object { ConvertTo-NormalizedLetter $_ }; $drives = $drives | Where-Object { $l -contains $_.Letter } }
    @($drives)
}

function Get-ProfileGroups {
    <# Distinct, ordered list of groups present in a profile. #>
    param([Parameter(Mandatory)]$DriveProfile)
    @($DriveProfile.Drives | ForEach-Object { $_.Group } | Select-Object -Unique)
}

# endregion

# ---------------------------------------------------------------------------
# region  MAPDRIVES.CMD generation
# ---------------------------------------------------------------------------

function Resolve-DriveTokens {
    <# Substitute %TOKEN% placeholders in a UNC using supplied values. #>
    param([string]$Unc, [hashtable]$TokenValues)
    if (-not $TokenValues) { return $Unc }
    $out = $Unc
    foreach ($k in $TokenValues.Keys) {
        $out = $out -replace [regex]::Escape("%$k%"), [string]$TokenValues[$k]
    }
    $out
}

function New-MapDrivesCmdContent {
    <#
    .SYNOPSIS
        Build the MAPDRIVES.CMD batch text from a normalized profile.
    .DESCRIPTION
        Reproduces the proven field batch structure, generalized: optional
        This-PC icon, credential handling (cmdkey | inline | none), per-drive
        idempotent remap with /PERSISTENT, pause-if-manual. Returns a CRLF string.
    .PARAMETER DriveProfile
        Normalized profile from ConvertFrom-DriveMapJson.
    .PARAMETER Groups / Letters
        Optional selection filters (which drives to include).
    .PARAMETER TokenValues
        Hashtable of %TOKEN% -> value substitutions (e.g. @{ USERFOLDER = 'Kathy' }
        or @{ USERFOLDER = '%USERNAME%' } to resolve at runtime per user).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DriveProfile,
        [string[]]$Groups,
        [string[]]$Letters,
        [hashtable]$TokenValues
    )

    $cred    = $DriveProfile.Credential
    $opt     = $DriveProfile.Options
    # @()-wrap: a single selected drive unrolls to a scalar on return, and scalar
    # .Count breaks under PS5.1 strict mode (the "one mapped drive" field bug).
    $drives  = @(Select-ProfileDrives -DriveProfile $DriveProfile -Groups $Groups -Letters $Letters)
    if ($drives.Count -eq 0) { throw 'No drives selected for MAPDRIVES.CMD.' }

    # No-credential profiles rely on matched accounts / domain SSO. Anything else
    # hits net use's interactive prompt - which fails with error 1223 under Atera
    # (non-interactive) and is unreliable even interactively in workgroups.
    if ($cred.Mode -eq 'none') {
        Write-Warning "credential.mode is 'none': shares that need a login will prompt (or fail with error 1223 under Atera). Set cmdkey/inline before deploying to workgroup NAS/server shares."
    }

    # A blank password is never valid here and is actively destructive: the
    # generated 'cmdkey /add ... /pass:""' would OVERWRITE the user's working saved
    # credential with an empty one. Collect fills Target/User from the vault but
    # can never read the password (Windows does not expose it), so this is the
    # backstop that forces it to be typed.
    $needsPassword = ($cred.Mode -eq 'cmdkey') -or ($cred.Mode -eq 'inline' -and $cred.User)
    if ($needsPassword -and [string]::IsNullOrEmpty([string]$cred.Password)) {
        throw "A password is required for credential mode '$($cred.Mode)' (user '$($cred.User)'). Windows never reveals saved passwords, so Collect cannot fill it in - type it before generating."
    }

    # Safety warning for batch-hostile characters in a baked-in password.
    if ($cred.Mode -ne 'none' -and $cred.Password) {
        if ($cred.Password -match '%') { Write-Warning "Password contains '%' which cmd may expand; verify the generated file." }
        if ($cred.Password -match '"') { Write-Warning "Password contains a double-quote which will break the quoted cmd line." }
    }

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('@echo off')
    $L.Add(":: Generated by Mapped Drive Toolkit v$script:ToolkitVersion on $(Get-Date -Format 'yyyy-MM-dd HH:mm') ($($DriveProfile.Site))")
    $L.Add('echo ---------------------------------------')
    $L.Add('echo  RECONNECTING NETWORK DRIVES')
    $L.Add("echo  $($DriveProfile.Site)")
    $L.Add('echo ---------------------------------------')
    $L.Add('')

    if ($opt.ShowThisPcIcon) {
        $L.Add(':: Show "This PC" icon on the desktop (HKCU, per-user)')
        $L.Add("reg add `"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel`" /v `"$script:ThisPcClsid`" /t REG_DWORD /d 0 /f >nul 2>&1")
        $L.Add("reg add `"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu`" /v `"$script:ThisPcClsid`" /t REG_DWORD /d 0 /f >nul 2>&1")
        $L.Add('')
    }

    if ($cred.Mode -eq 'cmdkey') {
        if (-not $cred.Target -or -not $cred.User) { throw "credential.mode 'cmdkey' requires 'target' and 'user'." }
        $L.Add(":: Ensure credential is present in the running user's vault")
        $L.Add("cmdkey /add:$($cred.Target) /user:$($cred.User) /pass:`"$($cred.Password)`" >nul 2>&1")
        $L.Add('')
        $L.Add(':: Give the credential a moment to register before mapping')
        $L.Add(':: (ping delay - timeout.exe fails when stdin is redirected, e.g. some RMM runners)')
        $L.Add('ping -n 4 127.0.0.1 >nul')
        $L.Add('')
    }

    foreach ($d in $drives) {
        $unc = Resolve-DriveTokens -Unc $d.Unc -TokenValues $TokenValues
        if ($unc -match '%([A-Za-z0-9_]+)%') {
            Write-Warning "Drive $($d.Letter): still has an unresolved token in '$unc'. cmd will expand it as an environment variable at runtime."
        }
        $persistFlag = if ($d.Persistent) { '/PERSISTENT:YES' } else { '/PERSISTENT:NO' }
        $L.Add(":: Map $($d.Letter): - $($d.Label)")
        $L.Add("echo Mapping $($d.Letter): ...")
        $L.Add(":: Unconditional delete - 'if exist' misses disconnected drives, leaving 'name already in use'")
        $L.Add("net use $($d.Letter): /delete /y >nul 2>&1")
        if ($cred.Mode -eq 'inline' -and $cred.User) {
            $L.Add("net use $($d.Letter): `"$unc`" /user:$($cred.User) `"$($cred.Password)`" $persistFlag")
        } else {
            $L.Add("net use $($d.Letter): `"$unc`" $persistFlag")
        }
        $L.Add('')
    }

    if ($opt.RestartExplorer) {
        $L.Add(':: Restart Explorer to refresh the drive list (useful right after a NAS migration)')
        $L.Add('taskkill /f /im explorer.exe >nul 2>&1')
        $L.Add('start explorer.exe')
        $L.Add('')
    }

    $L.Add('echo.')
    $L.Add('echo Done!')
    $L.Add('')
    $L.Add(':: Pause only when run with no arguments (double-click / manual). The logon task')
    $L.Add(':: and Atera invoke this file with an "auto" argument, so they never pause.')
    $L.Add('if "%~1"=="" pause')

    ($L -join "`r`n")
}

function Write-MapDrivesCmd {
    <#
    .SYNOPSIS
        Write MAPDRIVES.CMD to the Public Desktop and a local backup copy (ASCII).
    .OUTPUTS
        PSCustomObject with the paths written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Content,
        [string]$PublicDesktopPath = $script:DefaultPublicDesktopCmd,
        [string]$BackupPath        = $script:DefaultBackupCmd,
        [switch]$NoPublicDesktop,
        [switch]$NoBackup
    )

    $written = New-Object System.Collections.Generic.List[string]

    if (-not $NoPublicDesktop) {
        $dir = Split-Path -Parent $PublicDesktopPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ($PSCmdlet.ShouldProcess($PublicDesktopPath, 'Write MAPDRIVES.CMD')) {
            $Content | Set-Content -Path $PublicDesktopPath -Force -Encoding ASCII
            $written.Add($PublicDesktopPath)
        }
    }
    if (-not $NoBackup) {
        $dir = Split-Path -Parent $BackupPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ($PSCmdlet.ShouldProcess($BackupPath, 'Write MAPDRIVES.CMD backup')) {
            $Content | Set-Content -Path $BackupPath -Force -Encoding ASCII
            $written.Add($BackupPath)
        }
    }

    [PSCustomObject]@{ PublicDesktop = $PublicDesktopPath; Backup = $BackupPath; Written = $written.ToArray() }
}

# endregion

# ---------------------------------------------------------------------------
# region  Logon scheduled task (optional, OFF by default)
# ---------------------------------------------------------------------------

function Register-MapDrivesLogonTask {
    <#
    .SYNOPSIS
        Register the "Map Drives" at-logon scheduled task (runs the .cmd as the
        logged-on user). Mirrors the proven field deployment.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$CmdPath = $script:DefaultPublicDesktopCmd)

    if ($PSCmdlet.ShouldProcess($script:LogonTaskName, 'Register at-logon scheduled task')) {
        $action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"`"$CmdPath`" auto`""
        $trigger   = New-ScheduledTaskTrigger -AtLogon
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -Id 'Author'  # BUILTIN\Users
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Unregister-ScheduledTask -TaskName $script:LogonTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $script:LogonTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    }
}

# endregion

# ---------------------------------------------------------------------------
# region  Enumerate current mappings (HKEY_USERS\<SID>\Network)
# ---------------------------------------------------------------------------

function Get-CurrentDriveMappings {
    <#
    .SYNOPSIS
        Enumerate persistent network drive mappings across all loaded user hives.
    .DESCRIPTION
        Reads HKEY_USERS\<SID>\Network\<letter>\RemotePath (reuses the proven
        generator's approach). Returns normalized drive objects de-duped by
        Letter+Unc, each tagged with the account whose hive holds the mapping
        (ConnectionUser / OwnerSid - the OWNER, not the authenticating identity).

        RegUserName = the Network key's UserName value, set when the drive was
        mapped with /user:. It is often blank (pass-through or vault credential);
        Resolve-DriveCredentials turns these into the authenticating identity.
    #>
    [CmdletBinding()]
    param()

    $results = @{}
    Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | ForEach-Object {
        $sid = $_.Name.Replace('HKEY_USERS\', '')
        if ($sid.EndsWith('_Classes') -or $sid -match '^S-1-5-1[890]$') { return }

        $user = 'Unknown'
        try { $user = ([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount]).Value } catch {}

        $netPath = "Registry::$($_.Name)\Network"
        if (Test-Path $netPath) {
            Get-ChildItem $netPath -ErrorAction SilentlyContinue | ForEach-Object {
                $letter = ConvertTo-NormalizedLetter $_.PSChildName
                $props  = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                $remote = $props.RemotePath
                # UserName is REG_SZ when set by /user:, but appears as "" or a
                # DWORD 0 on mappings made without one - treat those as absent.
                $regUser = $null
                $rawUser = $props.UserName
                if ($rawUser -is [string] -and $rawUser.Trim()) { $regUser = $rawUser.Trim() }
                if ($letter -and $remote) {
                    $key = "$letter|$($remote.ToLower())"
                    if (-not $results.ContainsKey($key)) {
                        $results[$key] = [PSCustomObject]@{
                            Letter         = $letter
                            Unc            = $remote
                            Label          = "$letter`: drive"
                            Group          = 'standard'
                            Persistent     = $true
                            Tokens         = @()
                            ConnectionUser = $user
                            OwnerSid       = $sid
                            RegUserName    = $regUser
                            CredUser       = $null
                            CredSource     = $null
                            CredTarget     = $null
                            CredNote       = $null
                        }
                    }
                }
            }
        }
    }
    @($results.Values | Sort-Object Letter)
}

# endregion

# ---------------------------------------------------------------------------
# region  Share device identification (Synology / Server / Workstation)
# ---------------------------------------------------------------------------

function Resolve-ShareDevice {
    <#
    .SYNOPSIS
        Identify the device backing a share - read-only / non-destructive.
    .DESCRIPTION
        Resolves a host (or UNC) to IP + MAC, infers a vendor from the OUI, probes
        Synology DSM ports and SMB, and classifies the device as Synology NAS,
        Windows Server, Workstation share, or Unknown - with the supporting evidence.
        A TCP 445 connect is attempted first so the ARP cache is populated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostOrUnc,
        [int]$TimeoutMs = 800
    )

    $hostName = if ($HostOrUnc -like '\\*') { Get-UncHost $HostOrUnc } else { $HostOrUnc }
    $evidence = New-Object System.Collections.Generic.List[string]

    $ip = $null
    if ($hostName -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $ip = $hostName
    } else {
        try {
            $ip = ([System.Net.Dns]::GetHostAddresses($hostName) |
                   Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                   Select-Object -First 1).IPAddressToString
            if ($ip) { $evidence.Add("DNS: $hostName -> $ip") }
        } catch { $evidence.Add("DNS resolution failed for $hostName") }
    }

    function Test-Port { param([string]$Addr, [int]$Port, [int]$Ms)
        if (-not $Addr) { return $false }
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $iar = $c.BeginConnect($Addr, $Port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne($Ms, $false)
            if ($ok -and $c.Connected) { $c.EndConnect($iar); $c.Close(); return $true }
            $c.Close(); return $false
        } catch { return $false }
    }

    $ping = $false
    if ($ip) { $ping = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue }
    $smb445 = Test-Port -Addr $ip -Port 445 -Ms $TimeoutMs   # also populates ARP
    $dsm5000 = Test-Port -Addr $ip -Port 5000 -Ms $TimeoutMs
    $dsm5001 = Test-Port -Addr $ip -Port 5001 -Ms $TimeoutMs
    $ldap389 = Test-Port -Addr $ip -Port 389  -Ms $TimeoutMs
    $kdc88   = Test-Port -Addr $ip -Port 88   -Ms $TimeoutMs

    if ($smb445)  { $evidence.Add('SMB (445) reachable') } else { $evidence.Add('SMB (445) NOT reachable') }
    if ($dsm5000 -or $dsm5001) { $evidence.Add("Synology DSM ports open (5000=$dsm5000 5001=$dsm5001)") }
    if ($ldap389 -or $kdc88)   { $evidence.Add("Directory ports open (LDAP=$ldap389 KDC=$kdc88)") }

    # MAC via Get-NetNeighbor (fast) then arp fallback.
    $mac = $null
    if ($ip) {
        try {
            $n = Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue | Where-Object { $_.LinkLayerAddress } | Select-Object -First 1
            if ($n) { $mac = $n.LinkLayerAddress }
        } catch {}
        if (-not $mac) {
            $arp = (arp -a $ip 2>$null | Select-String -Pattern $([regex]::Escape($ip)))
            if ($arp -and $arp.ToString() -match '([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}') { $mac = $Matches[0] }
        }
    }

    $vendor = $null
    if ($mac) {
        $norm = ($mac -replace '[-.]', ':').ToUpper()
        $oui  = ($norm -split ':')[0..2] -join ':'
        $mac  = $norm
        if ($script:OuiVendors.ContainsKey($oui)) { $vendor = $script:OuiVendors[$oui]; $evidence.Add("MAC $mac (OUI $oui = $vendor)") }
        else { $evidence.Add("MAC $mac (OUI $oui = unknown vendor)") }
    } else {
        $evidence.Add('MAC not resolved (host may be off-subnet or unreachable)')
    }

    # Classify.
    $type = 'Unknown'
    if ($vendor -eq 'Synology' -or $vendor -eq 'QNAP' -or $dsm5000 -or $dsm5001) {
        $type = 'NAS'
        if ($vendor) { $type = "$vendor NAS" } else { $type = 'NAS (DSM ports)' }
    } elseif ($ldap389 -or $kdc88) {
        $type = 'Windows Server (domain controller / directory)'
    } elseif ($smb445) {
        # Differentiate server vs workstation via SMB server info when possible.
        $os = $null
        try {
            $vinfo = (net view "\\$hostName" /all 2>$null)
            if ($vinfo) { $evidence.Add('SMB share enumeration succeeded') }
        } catch {}
        try {
            $cim = Get-CimInstance Win32_OperatingSystem -ComputerName $hostName -OperationTimeoutSec 3 -ErrorAction SilentlyContinue
            if ($cim) { $os = $cim.Caption; $evidence.Add("OS: $os") }
        } catch {}
        if ($os -and $os -match 'Server') { $type = 'Windows Server' }
        elseif ($os)                      { $type = 'Workstation share' }
        else                              { $type = 'SMB host (Windows server/workstation - OS undetermined)' }
    }

    [PSCustomObject]@{
        Host         = $hostName
        IPAddress    = $ip
        Mac          = $mac
        Vendor       = $vendor
        DeviceType   = $type
        Pingable     = [bool]$ping
        Smb445Open   = [bool]$smb445
        DsmPortsOpen = [bool]($dsm5000 -or $dsm5001)
        Evidence     = $evidence.ToArray()
    }
}

# endregion

# ---------------------------------------------------------------------------
# region  Diagnostics (read-only) - used by the GUI's Doctor & Diagnostics tab
# ---------------------------------------------------------------------------

function Get-DriveMappingState {
    <#
    .SYNOPSIS
        Report the live state of every mapped drive in the current user session.
    .DESCRIPTION
        Merges Get-SmbMapping (status) with the HKCU\Network registry (the
        persistent/intended target). Returns one row per drive letter with its
        remote path and a normalized Status: OK | Disconnected | Unavailable |
        Unmapped (intended but absent). Read-only.
    #>
    [CmdletBinding()]
    param()

    $rows = @{}

    # Persistent/intended mappings from the current user's registry hive.
    $regBase = 'Registry::HKEY_CURRENT_USER\Network'
    if (Test-Path $regBase) {
        Get-ChildItem $regBase -ErrorAction SilentlyContinue | ForEach-Object {
            $letter = ConvertTo-NormalizedLetter $_.PSChildName
            $remote = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).RemotePath
            if ($letter -and $remote) {
                $rows[$letter] = [PSCustomObject]@{
                    Letter = $letter; Unc = $remote; Status = 'Unmapped'; Persistent = $true; Source = 'registry'
                }
            }
        }
    }

    # Live SMB mappings (status).
    try {
        Get-SmbMapping -ErrorAction SilentlyContinue | ForEach-Object {
            $letter = ConvertTo-NormalizedLetter $_.LocalPath
            if (-not $letter) { return }
            $status = switch ("$($_.Status)") {
                'OK'           { 'OK' }
                'Disconnected' { 'Disconnected' }
                'Unavailable'  { 'Unavailable' }
                default        { "$($_.Status)" }
            }
            if ($rows.ContainsKey($letter)) {
                $rows[$letter].Status = $status
                if (-not $rows[$letter].Unc) { $rows[$letter].Unc = $_.RemotePath }
            } else {
                $rows[$letter] = [PSCustomObject]@{
                    Letter = $letter; Unc = $_.RemotePath; Status = $status; Persistent = $false; Source = 'smb'
                }
            }
        }
    } catch {}

    @($rows.Values | Sort-Object Letter)
}

function Test-ShareConnectivity {
    <#
    .SYNOPSIS
        Non-destructive reachability + SMB checks for one share host.
    .DESCRIPTION
        DNS resolution, ping, TCP 445/139 reachability, and the negotiated SMB
        dialect (if a connection already exists). Nothing here changes state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostOrUnc,
        [int]$TimeoutMs = 800
    )

    $hostName = if ($HostOrUnc -like '\\*') { Get-UncHost $HostOrUnc } else { $HostOrUnc }

    $ip = $null; $dnsOk = $false
    if ($hostName -match '^\d{1,3}(\.\d{1,3}){3}$') { $ip = $hostName; $dnsOk = $true }
    else {
        try {
            $ip = ([System.Net.Dns]::GetHostAddresses($hostName) |
                   Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString
            $dnsOk = [bool]$ip
        } catch { $dnsOk = $false }
    }

    function Test-Tcp { param($Addr,$Port,$Ms)
        if (-not $Addr) { return $false }
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $iar = $c.BeginConnect($Addr,$Port,$null,$null)
            $ok = $iar.AsyncWaitHandle.WaitOne($Ms,$false)
            if ($ok -and $c.Connected) { $c.EndConnect($iar); $c.Close(); return $true }
            $c.Close(); return $false
        } catch { return $false }
    }

    $ping  = if ($ip) { Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue } else { $false }
    $smb445 = Test-Tcp $ip 445 $TimeoutMs
    $smb139 = Test-Tcp $ip 139 $TimeoutMs

    $dialect = $null
    try {
        $conn = Get-SmbConnection -ServerName $hostName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) { $dialect = "$($conn.Dialect)" }
    } catch {}

    [PSCustomObject]@{
        Host        = $hostName
        IPAddress   = $ip
        DnsResolved = [bool]$dnsOk
        Pingable    = [bool]$ping
        Smb445Open  = [bool]$smb445
        Smb139Only  = [bool]($smb139 -and -not $smb445)
        SmbDialect  = $dialect
    }
}

function Get-SmbClientHealth {
    <#
    .SYNOPSIS
        Snapshot of local SMB-client settings relevant to drive mapping. Read-only.
    .DESCRIPTION
        SMB1 client state, insecure-guest-logon policy, required signing, the
        active network profile (Public blocks file sharing by default), and the
        health of the LanmanWorkstation and Dnscache services.
    #>
    [CmdletBinding()]
    param()

    $smb1 = $null; $guest = $null; $signing = $null
    try {
        $cc = Get-SmbClientConfiguration -ErrorAction SilentlyContinue
        if ($cc) {
            $guest   = [bool]$cc.EnableInsecureGuestLogons
            $signing = [bool]$cc.RequireSecuritySignature
        }
    } catch {}
    try {
        $opt = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol-Client -ErrorAction SilentlyContinue
        if ($opt) { $smb1 = ("$($opt.State)" -eq 'Enabled') }
    } catch {}

    $netProfile = $null
    try { $netProfile = (Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1).NetworkCategory } catch {}

    function Get-SvcState { param($n)
        try { $s = Get-Service -Name $n -ErrorAction SilentlyContinue; if ($s) { "$($s.Status)" } else { 'Absent' } } catch { 'Unknown' }
    }

    [PSCustomObject]@{
        Smb1ClientEnabled    = $smb1
        InsecureGuestEnabled = $guest
        RequireSigning       = $signing
        NetworkProfile       = "$netProfile"
        WorkstationService   = (Get-SvcState 'LanmanWorkstation')
        DnsClientService     = (Get-SvcState 'Dnscache')
    }
}

# endregion

# ---------------------------------------------------------------------------
# region  Interactive-session injection (SYSTEM -> logged-on user)
# ---------------------------------------------------------------------------
# NOTE: the logic here is mirrored, inline, in the self-contained
# Inject-MapDrives.Atera.ps1 (which must have NO module dependency so it pastes
# straight into Atera). Keep the two in sync. The GUI uses THESE module copies.

function Get-InteractiveUser {
    <#
    .SYNOPSIS
        Return the console/interactive user (DOMAIN\user) or $null if nobody is
        logged on. Works from SYSTEM. Read-only.
    .DESCRIPTION
        Win32_ComputerSystem.UserName is the interactive console user; if blank
        (e.g. RDP-only or a service context), fall back to the owner of explorer.exe.
    #>
    [CmdletBinding()]
    param()
    $who = $null
    try { $who = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
    if (-not $who) {
        try {
            $exp = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
            if ($exp) {
                $o = Invoke-CimMethod -InputObject $exp -MethodName GetOwner -ErrorAction Stop
                if ($o.User) { $who = "$($o.Domain)\$($o.User)" }
            }
        } catch {}
    }
    $who
}

function Remove-MapDrivesInjectionTask {
    <# Delete the one-shot injection task (safe if absent). #>
    [CmdletBinding()]
    param([string]$TaskName = 'Map Drives (inject)')
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Start-MapDrivesInjectionTask {
    <#
    .SYNOPSIS
        Register + start (NON-BLOCKING) a one-shot task that runs MAPDRIVES.CMD in
        the interactive user's session. Returns immediately - the CALLER polls for
        completion (e.g. a GUI that re-reads the registry with DoEvents so it never
        freezes). Pair with Remove-MapDrivesInjectionTask.
    .OUTPUTS
        PSCustomObject { Started; User; Message }.
    #>
    [CmdletBinding()]
    param(
        [string]$CmdPath = $script:DefaultPublicDesktopCmd,
        [string]$User,
        [string]$TaskName = 'Map Drives (inject)'
    )
    if (-not $User) { $User = Get-InteractiveUser }
    if (-not $User)                            { return [PSCustomObject]@{ Started=$false; User=$null;  Message='No interactive user is logged on - cannot inject into a session that does not exist.' } }
    if (-not (Test-Path -LiteralPath $CmdPath)){ return [PSCustomObject]@{ Started=$false; User=$User; Message="MAPDRIVES.CMD not found: $CmdPath" } }
    try {
        $action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $CmdPath + '" auto')
        $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return [PSCustomObject]@{ Started=$true; User=$User; Message="Triggered MAPDRIVES.CMD in $User's session." }
    } catch {
        Remove-MapDrivesInjectionTask -TaskName $TaskName
        return [PSCustomObject]@{ Started=$false; User=$User; Message="Could not start in-session task: $($_.Exception.Message)" }
    }
}

function Invoke-MapDrivesInUserSession {
    <#
    .SYNOPSIS
        Run MAPDRIVES.CMD INSIDE the interactive user's session so the mapped
        drives appear in their Explorer immediately (fixes the cross-session /
        UAC linked-token invisibility when mapping from SYSTEM). BLOCKING helper
        for CLI use - GUIs should use Start-MapDrivesInjectionTask + their own
        (DoEvents) poll so the window stays responsive.
    .DESCRIPTION
        A net use drive letter is scoped to the logon session (LUID) that created
        it. Mapping from SYSTEM (or a different token) leaves the drive invisible
        to the user. This starts a one-shot task as the interactive user
        (RunLevel=Limited + LogonType=Interactive - the standard token Explorer
        uses), waits for it, then removes the task. NOTE: a hung net use (missing/
        wrong credentials) keeps LastTaskResult at 0x41301 until timeout, so a
        registry re-read is a more reliable success signal - see the GUI.
    .PARAMETER OnPoll
        Optional scriptblock invoked each poll iteration (a GUI passes
        { [System.Windows.Forms.Application]::DoEvents() } to stay responsive).
    .OUTPUTS
        PSCustomObject { User; Ran; LastResult; Success; Message }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$CmdPath = $script:DefaultPublicDesktopCmd,
        [string]$User,
        [int]$TimeoutSec = 45,
        [string]$TaskName = 'Map Drives (inject)',
        [scriptblock]$OnPoll
    )

    if (-not $User) { $User = Get-InteractiveUser }
    if (-not $User) {
        return [PSCustomObject]@{ User=$null; Ran=$false; LastResult=$null; Success=$false; Message='No interactive user is logged on - cannot inject into a session that does not exist.' }
    }
    if (-not (Test-Path -LiteralPath $CmdPath)) {
        return [PSCustomObject]@{ User=$User; Ran=$false; LastResult=$null; Success=$false; Message="MAPDRIVES.CMD not found: $CmdPath" }
    }
    if (-not $PSCmdlet.ShouldProcess($User, "Run '$CmdPath' in the interactive session")) {
        return [PSCustomObject]@{ User=$User; Ran=$false; LastResult=$null; Success=$false; Message='Skipped (WhatIf).' }
    }

    $start = Start-MapDrivesInjectionTask -CmdPath $CmdPath -User $User -TaskName $TaskName
    if (-not $start.Started) {
        return [PSCustomObject]@{ User=$User; Ran=$false; LastResult=$null; Success=$false; Message=$start.Message }
    }

    $result = $null; $msg = ''
    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $info = $null
        do {
            Start-Sleep -Milliseconds 500
            if ($OnPoll) { try { & $OnPoll } catch {} }
            $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        } while ($info -and $info.LastTaskResult -eq 0x41301 -and (Get-Date) -lt $deadline)
        if ($info) { $result = $info.LastTaskResult }
        $msg = if ($result -eq 0) { 'In-session run completed (exit 0).' }
               elseif ($result -eq 0x41301) { "Still running after $TimeoutSec s (a hung net use usually means missing/wrong credentials)." }
               elseif ($null -eq $result) { 'No task result returned.' }
               else { ("In-session run exit code: {0} (0x{0:X})." -f $result) }
    } finally {
        Remove-MapDrivesInjectionTask -TaskName $TaskName
    }

    [PSCustomObject]@{ User=$User; Ran=$true; LastResult=$result; Success=($result -eq 0); Message=$msg }
}

function Invoke-CommandInUserSession {
    <#
    .SYNOPSIS
        Run an arbitrary command line INSIDE the interactive user's session and
        return its combined output. The general form behind the Dir / net-use /
        reproduce features - a SYSTEM/Backstage process can't see the user's
        session-scoped drives or SMB connections, so it must run there.
    .DESCRIPTION
        Writes a temp .cmd under Public\Documents (writable by the standard-user
        task, readable by SYSTEM) that runs the command with all output redirected
        to a temp file, runs it as the interactive user (one-shot task), reads the
        file back, and cleans up. Multiple commands can be chained with '&'.
    .OUTPUTS
        PSCustomObject { Success; Output; Message; User }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [string]$User,
        [int]$TimeoutSec = 25,
        [scriptblock]$OnPoll
    )
    if (-not $User) { $User = Get-InteractiveUser }
    if (-not $User) { return [PSCustomObject]@{ Success=$false; Output=$null; Message='No interactive user is logged on.'; User=$null } }

    $pubDocs = Join-Path $env:PUBLIC 'Documents'
    if (-not (Test-Path $pubDocs)) { $pubDocs = $env:PUBLIC }
    $stamp   = [guid]::NewGuid().ToString('N').Substring(0,8)
    $outFile = Join-Path $pubDocs "mdt-cmd-$stamp.out"
    $batFile = Join-Path $pubDocs "mdt-cmd-$stamp.cmd"
    # Group with ( ) so a '&'-chained command line redirects as one block. Args the
    # runner appends ('auto') are ignored by the batch.
    Set-Content -LiteralPath $batFile -Value ("@echo off`r`n( $CommandLine ) > `"$outFile`" 2>&1`r`n") -Encoding ASCII

    $taskName = 'MDT cmd probe'
    $out = $null; $msg = ''
    try {
        $start = Start-MapDrivesInjectionTask -CmdPath $batFile -User $User -TaskName $taskName
        if (-not $start.Started) { return [PSCustomObject]@{ Success=$false; Output=$null; Message=$start.Message; User=$User } }
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $done = $false
        do {
            Start-Sleep -Milliseconds 300
            if ($OnPoll) { try { & $OnPoll } catch {} }
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            $done = ($info -and $info.LastTaskResult -ne 0x41301)
        } while (-not $done -and (Get-Date) -lt $deadline)
        Start-Sleep -Milliseconds 200   # let the redirect flush to disk
        if (Test-Path -LiteralPath $outFile) {
            $out = Get-Content -LiteralPath $outFile -Raw
            $msg = 'Captured from the user session.'
        } else {
            $msg = "No output within $TimeoutSec s - the command may have hung, or the session could not run it."
        }
    } catch {
        $msg = "Could not run in the user's session: $($_.Exception.Message)"
    } finally {
        Remove-MapDrivesInjectionTask -TaskName $taskName
        Remove-Item -LiteralPath $batFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    }
    [PSCustomObject]@{ Success=[bool]$out; Output=$out; Message=$msg; User=$User }
}

function Invoke-MapDrivesNow {
    <#
    .SYNOPSIS
        One-shot: run MAPDRIVES.CMD content in the interactive user's session WITHOUT
        leaving a MAPDRIVES.CMD behind, and return the session's output (net use
        errors + a trailing 'net use' listing).
    .DESCRIPTION
        The content (it holds the password) is written to the USER'S OWN Temp folder
        (private ACL) when resolvable, run via Invoke-CommandInUserSession (one-shot
        task, the user's standard token = what Explorer sees), then deleted.
    .OUTPUTS
        { Success; Output; Message; User }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Content, [string]$User, [int]$TimeoutSec = 60, [scriptblock]$OnPoll)
    if (-not $User) { $User = Get-InteractiveUser }
    if (-not $User) { return [PSCustomObject]@{ Success=$false; Output=$null; Message='No interactive user is logged on - nothing to map into.'; User=$null } }
    $dir = $null
    try {
        $sid  = ([Security.Principal.NTAccount]$User).Translate([Security.Principal.SecurityIdentifier]).Value
        $prof = (Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
        $t = Join-Path ([Environment]::ExpandEnvironmentVariables($prof)) 'AppData\Local\Temp'
        if (Test-Path -LiteralPath $t) { $dir = $t }
    } catch {}
    if (-not $dir) { $dir = Join-Path $env:PUBLIC 'Documents' }
    $file = Join-Path $dir ("mdt-apply-{0}.cmd" -f [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        Set-Content -LiteralPath $file -Value $Content -Encoding ASCII -ErrorAction Stop
        $r = Invoke-CommandInUserSession -CommandLine ('call "' + $file + '" auto & echo. & echo ===NET USE=== & net use') -User $User -TimeoutSec $TimeoutSec -OnPoll $OnPoll
        [PSCustomObject]@{ Success=$r.Success; Output=$r.Output; Message=$r.Message; User=$User }
    } catch {
        [PSCustomObject]@{ Success=$false; Output=$null; Message="Could not stage the temporary map script: $($_.Exception.Message)"; User=$User }
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DirInUserSession {
    <# Thin wrapper: `dir <path>` in the interactive user's session (see Invoke-CommandInUserSession). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,   # e.g. 'Z:\' or a UNC
        [string]$User,
        [int]$TimeoutSec = 20,
        [scriptblock]$OnPoll
    )
    Invoke-CommandInUserSession -CommandLine ('dir "' + $Path + '"') -User $User -TimeoutSec $TimeoutSec -OnPoll $OnPoll
}

# endregion

# ---------------------------------------------------------------------------
# region  DNS diagnostics (read-only)
# ---------------------------------------------------------------------------

function Resolve-AddrBounded {
    <# Forward-resolve a name to IPv4/IPv6, but never wait longer than -Ms. Uses the
       async .NET resolver (same path 'ping'/'net use' use, incl. suffix search) and
       abandons it on timeout - so a dead configured DNS server can't hang the caller. #>
    param([string]$Name, [int]$Ms = 2500)
    $v4 = @(); $v6 = @()
    try {
        $iar = [System.Net.Dns]::BeginGetHostAddresses($Name, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($Ms, $false)) {
            $addrs = [System.Net.Dns]::EndGetHostAddresses($iar)
            $v4 = @($addrs | Where-Object { $_.AddressFamily -eq 'InterNetwork' }   | ForEach-Object { $_.IPAddressToString })
            $v6 = @($addrs | Where-Object { $_.AddressFamily -eq 'InterNetworkV6' } | ForEach-Object { $_.IPAddressToString })
        }
    } catch {}
    [PSCustomObject]@{ V4 = @($v4); V6 = @($v6) }
}

function Resolve-PtrBounded {
    <# Reverse-resolve an IP to a name, bounded by -Ms (never hangs on dead DNS). #>
    param([string]$Ip, [int]$Ms = 2500)
    try {
        $iar = [System.Net.Dns]::BeginGetHostEntry($Ip, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($Ms, $false)) { return ([System.Net.Dns]::EndGetHostEntry($iar)).HostName }
    } catch {}
    $null
}

function Test-DnsHealth {
    <#
    .SYNOPSIS
        DNS-focused health check for a share host - read-only / non-destructive.
    .DESCRIPTION
        Surfaces the exact signals behind the field fixes:
          - forward A (IPv4)     = 'ping -4 hostname'
          - forward AAAA (IPv6)  = why bare 'ping hostname' can pick the wrong path
          - reverse PTR          = 'ping -a <ip>' (detects wrong/stale target)
          - configured DNS servers + TCP-53 reachability (unreachable DNS server)
        Uses Resolve-DnsName (-DnsOnly) with a [System.Net.Dns] fallback.
    .OUTPUTS
        PSCustomObject with Ipv4Addresses, Ipv6Addresses, ReversePtr, RoundTripOk,
        DnsServers, DnsServerReachable, AnyDnsServerReachable, and Findings[].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostOrUnc,
        [int]$TimeoutMs = 800
    )

    $hostName = if ($HostOrUnc -like '\\*') { Get-UncHost $HostOrUnc } else { $HostOrUnc }
    $findings = New-Object System.Collections.Generic.List[string]

    $isLiteralIp = [bool]($hostName -match '^\d{1,3}(\.\d{1,3}){3}$')
    $aRecords    = @()
    $aaaaRecords = @()
    $ptr         = $null
    $roundTripOk = $null

    if ($isLiteralIp) {
        $aRecords = @($hostName)
        $findings.Add("Host is a literal IP ($hostName) - no forward DNS needed.")
    } else {
        # Bounded resolution (same resolver path ping/net use use); never hangs on a
        # dead configured DNS server the way Resolve-DnsName can.
        $res = Resolve-AddrBounded $hostName
        $aRecords    = @($res.V4)
        $aaaaRecords = @($res.V6)

        if (@($aRecords).Count) { $findings.Add("[OK] Forward A (ping -4): $hostName -> $($aRecords -join ', ')") }
        else                    { $findings.Add("[FAIL] Forward A: '$hostName' has no IPv4 (A) record - 'ping $hostName' cannot resolve. Stale name after a server/NAS swap, or wrong suffix.") }

        if (@($aaaaRecords).Count -and @($aRecords).Count -eq 0) {
            $findings.Add("[WARN] Only IPv6 (AAAA) resolves - if the share is IPv4-only, use an IP-qualified target or 'ping -4'.")
        } elseif (@($aaaaRecords).Count) {
            $findings.Add("[INFO] AAAA present ($($aaaaRecords -join ', ')) - if mapping is flaky, forcing IPv4 ('ping -4') is the workaround.")
        }
    }

    $firstIp = if (@($aRecords).Count) { $aRecords[0] } else { $null }

    # A NAME that resolves to a DEAD IP is the classic stale record after a server
    # swap (e.g. fs01 -> old .62, but the live box is .109). Cross-check mDNS.
    if ($firstIp -and -not $isLiteralIp) {
        $alive = $false
        try { $alive = Test-Connection -ComputerName $firstIp -Count 1 -Quiet -ErrorAction SilentlyContinue } catch {}
        if (-not $alive) {
            $shortN = ($hostName -split '\.')[0]
            $m4 = @((Resolve-AddrBounded "$shortN.local").V4)
            $mdnsIp = if ($m4.Count) { $m4[0] } else { $null }
            $extra = if ($mdnsIp -and $mdnsIp -ne $firstIp) { " mDNS '$shortN.local' resolves to $mdnsIp - that is likely the LIVE server." } else { '' }
            $findings.Add("[FAIL] '$hostName' resolves to $firstIp which does NOT respond - likely a STALE/WRONG DNS record (server replaced?).$extra Fix it in DNS Manager on the server, flush caches, or map by the live IP.")
        }
    }

    if ($firstIp) {
        $ptr = Resolve-PtrBounded $firstIp
        if ($ptr) {
            $findings.Add("[OK] Reverse PTR (ping -a): $firstIp -> $ptr")
            $short = ($ptr -split '\.')[0]
            if (-not $isLiteralIp) {
                $roundTripOk = ($ptr -ieq $hostName) -or ($short -ieq $hostName) -or ($ptr -ilike "$hostName.*")
                if (-not $roundTripOk) {
                    $findings.Add("[WARN] Wrong/stale target? '$hostName' -> $firstIp, which reverse-maps to '$ptr' (a different host). Classic after a NAS/server swap - flush DNS and verify the record.")
                }
            } else {
                # Literal IP given: does the IP's own (PTR) name forward-resolve back to
                # it? If the name resolves to a DIFFERENT IP, DNS has a stale record -
                # clients using the NAME reach the wrong/old box even though the IP works.
                $fwd = $null
                $f4 = @((Resolve-AddrBounded $short).V4)
                if ($f4.Count) { $fwd = $f4[0] }
                if ($fwd -and $fwd -ne $hostName) {
                    $roundTripOk = $false
                    $findings.Add("[WARN] STALE DNS: $hostName reverse-maps to '$ptr', but that name forward-resolves to $fwd (a DIFFERENT IP). Clients using the NAME reach $fwd (wrong/old server), not $hostName. Fix the record in DNS Manager on the server, flush caches, or map by IP.")
                } elseif ($fwd -and $fwd -eq $hostName) {
                    $roundTripOk = $true
                    $findings.Add("[OK] Name '$short' forward-resolves back to $hostName (DNS is consistent).")
                }
            }
        } else {
            $findings.Add("[INFO] No reverse (PTR) record for $firstIp (often normal on NAS / workgroup).")
        }
    }

    $dnsServers = @()
    try {
        $dnsServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses } | Select-Object -Unique)
    } catch {}
    $reachList = New-Object System.Collections.Generic.List[object]
    $anyReach  = $false
    foreach ($s in $dnsServers) {
        $ok = $false
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $iar = $c.BeginConnect($s, 53, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $c.Connected) { $c.EndConnect($iar); $ok = $true }
            $c.Close()
        } catch { $ok = $false }
        if ($ok) { $anyReach = $true }
        $reachList.Add([PSCustomObject]@{ Server = $s; Reachable = [bool]$ok })
    }
    if (@($dnsServers).Count) {
        $up   = @($reachList | Where-Object { $_.Reachable }      | ForEach-Object { $_.Server })
        $down = @($reachList | Where-Object { -not $_.Reachable } | ForEach-Object { $_.Server })
        if ($anyReach) { $findings.Add("[OK] DNS servers up: $($up -join ', ')$(if(@($down).Count){"   DOWN: $($down -join ', ')"})") }
        else           { $findings.Add("[FAIL] No configured DNS server answers on TCP 53 ($($dnsServers -join ', ')) - resolution will fail. Check the NIC's DNS settings / server.") }
    } else {
        $findings.Add("[WARN] No IPv4 DNS servers configured on any active adapter.")
    }

    # DNS suffix search list: a retired-domain suffix (e.g. CONTOSO.local) left here
    # suffixes bare names and can resolve them to stale records under the old domain.
    $suffixes = @()
    try { $g = Get-DnsClientGlobalSetting -ErrorAction Stop; if ($g.SuffixSearchList) { $suffixes += @($g.SuffixSearchList) } } catch {}
    try { $suffixes += @(Get-DnsClient -ErrorAction SilentlyContinue | ForEach-Object { $_.ConnectionSpecificSuffix } | Where-Object { $_ }) } catch {}
    $suffixes = @($suffixes | Where-Object { $_ } | Select-Object -Unique)
    if (@($suffixes).Count) { $findings.Add("[INFO] DNS suffixes appended to bare names: $($suffixes -join ', ') - a retired-domain suffix here can resolve bare names to stale records.") }

    [PSCustomObject]@{
        Host                  = $hostName
        IsLiteralIP           = $isLiteralIp
        Ipv4Addresses         = @($aRecords)
        Ipv6Addresses         = @($aaaaRecords)
        FirstIPv4             = $firstIp
        ReversePtr            = $ptr
        RoundTripOk           = $roundTripOk
        DnsServers            = @($dnsServers)
        DnsServerReachable    = $reachList.ToArray()
        AnyDnsServerReachable = $anyReach
        Findings              = $findings.ToArray()
    }
}

function Test-DnsServer {
    <#
    .SYNOPSIS
        Test whether a DNS server IP actually ANSWERS queries (not just TCP-53 open).
    .DESCRIPTION
        Sends a real DNS query over UDP/53 (raw packet - locale-independent) and reads
        the response code: NOERROR+answers = resolving; NXDOMAIN/NOERROR = responding as
        a DNS server; SERVFAIL = up but can't resolve (no forwarder/internet); REFUSED =
        up but won't answer this client; no reply = NOT a working/responding DNS server.
        Also reports TCP-53 reachability as a secondary signal.
    .OUTPUTS
        PSCustomObject { Server; Tcp53Open; Responds; Resolved; RCode; Answers; LatencyMs; Status }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [string]$ProbeName = 'microsoft.com',
        [int]$TimeoutMs = 1500
    )

    # TCP 53 reachability (secondary signal - some devices serve DNS over TCP too).
    $tcp53 = $false
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($Server, 53, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(700, $false) -and $c.Connected) { $c.EndConnect($iar); $tcp53 = $true }
        $c.Close()
    } catch {}

    # Raw UDP DNS query.
    $udp = $null; $responds = $false; $rcode = $null; $answers = 0; $latency = $null
    try {
        $id = Get-Random -Minimum 1 -Maximum 65534
        $q  = New-Object System.Collections.Generic.List[byte]
        $q.Add([byte]($id -shr 8)); $q.Add([byte]($id -band 0xFF))
        $q.AddRange([byte[]](0x01,0x00))   # flags: standard query, recursion desired
        $q.AddRange([byte[]](0x00,0x01))   # QDCOUNT = 1
        $q.AddRange([byte[]](0x00,0x00))   # ANCOUNT
        $q.AddRange([byte[]](0x00,0x00))   # NSCOUNT
        $q.AddRange([byte[]](0x00,0x00))   # ARCOUNT
        foreach ($label in ($ProbeName -split '\.')) {
            $b = [System.Text.Encoding]::ASCII.GetBytes($label)
            $q.Add([byte]$b.Length); $q.AddRange($b)
        }
        $q.Add([byte]0)                    # end of QNAME
        $q.AddRange([byte[]](0x00,0x01))   # QTYPE  A
        $q.AddRange([byte[]](0x00,0x01))   # QCLASS IN
        $query = $q.ToArray()

        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [void]$udp.Send($query, $query.Length, $Server, 53)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$remote)   # throws SocketException on timeout
        $sw.Stop(); $latency = $sw.ElapsedMilliseconds
        if ($resp -and $resp.Length -ge 12) {
            # Cast to [int] before -shl: shifting a [byte] is done in 8 bits, so
            # [byte] -shl 8 would be 0 and the high byte would be lost.
            $respId  = ([int]$resp[0] -shl 8) -bor [int]$resp[1]
            $rcode   = $resp[3] -band 0x0F
            $answers = ([int]$resp[6] -shl 8) -bor [int]$resp[7]
            if ($respId -eq $id) { $responds = $true }
        }
    } catch {
        # SocketException (timeout) => no response.
    } finally {
        if ($udp) { try { $udp.Close() } catch {} }
    }

    $rcodeName = switch ($rcode) { 0{'NOERROR'} 1{'FORMERR'} 2{'SERVFAIL'} 3{'NXDOMAIN'} 5{'REFUSED'} default { if ($null -ne $rcode) { "RCODE $rcode" } else { $null } } }
    $resolved  = [bool]($responds -and $rcode -eq 0 -and $answers -gt 0)
    $status = if (-not $responds) {
        "[FAIL] NOT responding to DNS queries (no UDP/53 reply in ${TimeoutMs}ms)$(if($tcp53){' - though TCP 53 is open'})."
    } elseif ($resolved) {
        "[OK] Working - resolved $ProbeName ($answers answer(s), ${latency}ms)."
    } elseif ($rcode -eq 0) {
        "[OK] Responding (NOERROR, 0 answers, ${latency}ms) - is a DNS server."
    } elseif ($rcode -eq 3) {
        "[OK] Responding (NXDOMAIN, ${latency}ms) - is a DNS server."
    } elseif ($rcode -eq 2) {
        "[WARN] Responding but SERVFAIL - up as DNS but can't resolve (no forwarder/internet?)."
    } elseif ($rcode -eq 5) {
        "[WARN] Responding but REFUSED - up but won't answer this client."
    } else {
        "[WARN] Responding (rcode $rcode, ${latency}ms)."
    }

    [PSCustomObject]@{
        Server=$Server; Tcp53Open=[bool]$tcp53; Responds=[bool]$responds; Resolved=$resolved
        RCode=$rcodeName; Answers=$answers; LatencyMs=$latency; Status=$status
    }
}

function Get-DnsServerHealth {
    <#
    .SYNOPSIS
        Test every configured DNS server on the ACTIVE interface(s) - are they actually
        answering queries? Labels them Primary / Secondary in configured order.
    .OUTPUTS
        Array of PSCustomObject { Interface; Role; Server; Responds; Resolved; RCode; LatencyMs; Status }
    #>
    [CmdletBinding()]
    param([string]$ProbeName = 'microsoft.com', [int]$TimeoutMs = 1500)

    # Prefer interfaces that carry the default route (the live network); fall back to all.
    $activeIdx = @()
    try { $activeIdx = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ifIndex -Unique) } catch {}

    $entries = @()
    try {
        $all = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.ServerAddresses }
        $entries = if (@($activeIdx).Count) { @($all | Where-Object { $activeIdx -contains $_.InterfaceIndex }) } else { @() }
        if (@($entries).Count -eq 0) { $entries = @($all) }   # fallback: everything configured
    } catch {}

    $out  = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($e in $entries) {
        $order = 0
        foreach ($s in $e.ServerAddresses) {
            $order++
            if ($seen.ContainsKey($s)) { continue }
            $seen[$s] = $true
            $role = switch ($order) { 1 {'Primary'} 2 {'Secondary'} default { "DNS $order" } }
            $t = Test-DnsServer -Server $s -ProbeName $ProbeName -TimeoutMs $TimeoutMs
            $out.Add([PSCustomObject]@{
                Interface=$e.InterfaceAlias; Role=$role; Server=$s
                Responds=$t.Responds; Resolved=$t.Resolved; RCode=$t.RCode; LatencyMs=$t.LatencyMs; Status=$t.Status
            })
        }
    }
    $out.ToArray()
}

# endregion

# ---------------------------------------------------------------------------
# region  Credential / share test (read-only-ish: connects then disconnects)
# ---------------------------------------------------------------------------

function Test-ShareCredential {
    <#
    .SYNOPSIS
        Decompose "the drive won't map" into: can we READ the share right now, does
        the share exist, and (only when safe) do explicit credentials authenticate -
        with the exact Windows error and plain-English guidance.
    .DESCRIPTION
        NON-DESTRUCTIVE. It never deletes existing connections: all shares on a
        server share ONE authenticated SMB session, so tearing connections down to
        "test" would disconnect the user's working drives. The access test therefore
        runs first and reflects the EFFECTIVE identity (which is the real question).
        An explicit /user: test is only attempted when no connection to that host
        already exists - otherwise Windows either reuses the existing session or
        returns error 1219, making the result meaningless; in that case use
        "Purge host session" first.
    .OUTPUTS
        PSCustomObject with CredentialsValid, CredError, Shares, TargetShare,
        TargetShareExists, ShareAccess, PreExistingConnection, Summary, Raw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Unc,     # \\host\share[\...]
        [string]$User,
        [string]$Password
    )

    # Callers (the GUI) run with $ErrorActionPreference='Stop'; redirecting a native
    # exe's stderr under Stop throws NativeCommandError, which previously surfaced a
    # cleanup step's "network connection could not be found" as the auth verdict.
    $ErrorActionPreference = 'Continue'

    $hostName = Get-UncHost $Unc
    $share = $null
    if ($Unc -match '^\\\\[^\\]+\\([^\\]+)') { $share = $Matches[1] }
    $ipc = '\\' + $hostName + '\IPC$'
    $pw  = if ($Password) { $Password } else { '' }

    function _net { param([string[]]$A) $o = (& net.exe @A 2>&1 | Out-String); [PSCustomObject]@{ Code=$LASTEXITCODE; Out=$o } }
    function _errNo { param($txt) if ("$txt" -match 'System error (\d+)') { [int]$Matches[1] } else { $null } }
    function _friendly { param($code,$txt)
        switch ($code) {
            1326 { 'Bad username or password (or wrong authority - for a workgroup server use SERVER\user or IP\user).' }
            86   { 'The network password is not correct.' }
            1327 { 'Account restriction: blank password not allowed, logon hours, or the account is disabled/expired.' }
            1385 { 'The account lacks the "Access this computer from the network" right on the server.' }
            5    { 'Authenticated, but ACCESS DENIED - share/NTFS permissions do not allow this account.' }
            53   { 'Network path not found - host/share wrong, or SMB (445) blocked.' }
            64   { 'The network name is no longer available - host down/unreachable, or the SMB session dropped.' }
            1231 { 'Network location cannot be reached - host down, wrong IP, or off-subnet.' }
            67   { 'Network name not found - that SHARE name does not exist on the server.' }
            1219 { 'A conflicting connection to this server already exists with different credentials - clear it and retry.' }
            59   { 'Unexpected network error - the connection dropped during setup, before the login was checked (not a password problem). Usually SMB signing (Win11 24H2 requires it; old NAS may not sign), a SharePoint/WebDAV path, or a device/firmware/VPN issue. Run Diagnose-MapError.Atera.ps1.' }
            1272 { 'Blocked as an unauthenticated GUEST connection - Windows 11 refuses guest access. Give the share a real account and save it with cmdkey.' }
            1311 { 'No logon servers available - Windows tried a DOMAIN logon. Use a LOCAL account: IP\user (e.g. ' + $hostName + '\user).' }
            1355 { 'The specified domain does not exist / cannot be contacted - the old domain is gone. Use a LOCAL account: IP\user.' }
            default { if ($code) { "Windows system error $code." } else { ("$txt").Trim() } }
        }
    }

    $notes = New-Object System.Collections.Generic.List[string]

    # 0) Is a session to this host already established? (Never torn down - all shares
    #    on a server share one session, so deleting it would drop working drives.)
    $existing = @()
    $nu = _net @('use')
    foreach ($line in ($nu.Out -split "`r?`n")) {
        if ($line -match "(?i)\\\\$([regex]::Escape($hostName))\\") { $existing += $line.Trim() }
    }
    $preExisting = [bool]@($existing).Count
    if ($preExisting) { $notes.Add("Existing connection(s) to $hostName are in place - they were left untouched.") }

    # 1) ACCESS TEST FIRST - reflects the EFFECTIVE identity, which is what actually
    #    decides whether the user can read the share. Read-only.
    $shareAccess = 'NotTested'; $accErrText = ''
    if ($share) {
        try {
            Get-ChildItem -LiteralPath $Unc -ErrorAction Stop | Select-Object -First 1 | Out-Null
            $shareAccess = 'Accessible'
        } catch {
            $accErrText = "$($_.Exception.Message)"
            if     ($accErrText -match '(?i)denied')                          { $shareAccess = 'AccessDenied' }
            elseif ($accErrText -match '(?i)not found|cannot find|not exist') { $shareAccess = 'ShareNotFound' }
            elseif ($accErrText -match '(?i)network path|network name')       { $shareAccess = 'PathNotFound' }
            else                                                              { $shareAccess = 'Error' }
        }
    }

    # 2) Share enumeration (read-only).
    $shares = @(); $targetExists = $null
    $v = _net @('view', ('\\' + $hostName)); $viewRaw = $v.Out
    foreach ($line in ($v.Out -split "`r?`n")) {
        if ($line -match '^(.+?)\s{2,}Disk\b') { $shares += $Matches[1].Trim() }
    }
    if ($share -and @($shares).Count) { $targetExists = [bool](@($shares) -contains $share) }
    elseif ($share -and $shareAccess -eq 'Accessible') { $targetExists = $true }

    # 3) Explicit-credential test - ONLY when nothing is already connected to the host.
    #    With an existing session Windows reuses it (false PASS) or returns 1219
    #    (false FAIL), so the result would be meaningless either way.
    $credOk = $null; $credErr = $null; $credRaw = ''
    if ($User -and -not $preExisting) {
        $c = _net @('use', $ipc, "/user:$User", $pw)
        $credRaw = $c.Out
        $credOk = ($c.Code -eq 0)
        $credErr = _errNo $c.Out
        # Remove ONLY the IPC$ connection this test created.
        if ($credOk) { [void](_net @('use', $ipc, '/delete', '/y')) }
    } elseif ($User -and $preExisting) {
        $notes.Add("Skipped the explicit /user: test: a session to $hostName already exists, so Windows would reuse it (false pass) or return error 1219 (false fail). Use 'Purge host session' first if you need to prove a specific account.")
    }

    # ---- Verdict: lead with what the user can actually do right now ----------
    $summary =
        if ($shareAccess -eq 'Accessible') {
            "OK: '$share' on $hostName is readable right now" + $(if ($preExisting) { ' (using the existing session/identity).' } else { '.' })
        } elseif ($shareAccess -eq 'AccessDenied') {
            "ACCESS DENIED to '$share' - authentication worked but this identity lacks rights. All shares on $hostName use ONE session, so check which account is actually in play (Credential audit) and the server-side ACLs."
        } elseif ($shareAccess -eq 'ShareNotFound') {
            "Share '$share' not found on $hostName." + $(if (@($shares).Count) { " Shares present: $((@($shares)) -join ', ')." } else { '' })
        } elseif ($shareAccess -eq 'PathNotFound') {
            "Cannot reach $hostName (network path not found) - check name resolution / SMB 445."
        } elseif ($credOk -eq $false) {
            'AUTH FAILED: ' + (_friendly $credErr $credRaw)
        } elseif ($credOk -eq $true) {
            "Credentials for '$User' authenticate to $hostName."
        } else {
            "Could not read '$share': $($accErrText.Trim())"
        }

    [PSCustomObject]@{
        Host                  = $hostName
        Unc                   = $Unc
        User                  = $User
        CredentialsValid      = $credOk
        CredError             = $credErr
        Shares                = @($shares)
        TargetShare           = $share
        TargetShareExists     = $targetExists
        ShareAccess           = $shareAccess
        PreExistingConnection = $preExisting
        Notes                 = $notes.ToArray()
        Summary               = $summary
        Raw                   = (($existing -join "`r`n") + "`r`n" + $credRaw.Trim() + "`r`n" + $viewRaw.Trim()).Trim()
    }
}

function Clear-SavedCredential {
    <#
    .SYNOPSIS
        Delete stored Credential Manager entries (cmdkey) for a host / IP - clears
        stale domain-era credentials that make Windows reuse a dead authority.
    .OUTPUTS
        PSCustomObject { Removed[]; Message }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Target)

    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($t in ($Target | Where-Object { $_ } | Select-Object -Unique)) {
        $out = & cmdkey.exe /delete:$t 2>&1 | Out-String
        if ($out -match 'deleted successfully') { $removed.Add($t) }
    }
    [PSCustomObject]@{
        Removed = $removed.ToArray()
        Message = if ($removed.Count) { 'Removed saved credential(s) for: ' + ($removed -join ', ') } else { 'No matching saved credentials found.' }
    }
}

function Clear-NameCaches {
    <#
    .SYNOPSIS
        Purge the machine's name-resolution caches - DNS resolver, ARP, and NetBIOS -
        so a stale name->IP (the "ping resolves to the OLD server" case) is re-learned.
        Mirrors the field fix: ipconfig /flushdns, arp -d *, nbtstat -R, nbtstat -RR.
        Needs elevation / SYSTEM (arp -d and nbtstat require admin).
    .OUTPUTS
        String[] of [OK]/[WARN]/[FAIL] lines.
    #>
    [CmdletBinding()]
    param()
    $log = New-Object System.Collections.Generic.List[string]

    try { Clear-DnsClientCache -ErrorAction Stop; $log.Add('[OK] DNS resolver cache flushed.') }
    catch {
        $o = (& ipconfig /flushdns 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) { $log.Add('[OK] DNS resolver cache flushed (ipconfig /flushdns).') }
        else { $log.Add("[FAIL] flush DNS: $($o.Trim())") }
    }

    $steps = @(
        @{ Exe='arp';     Args=@('-d','*'); Ok='ARP cache cleared (arp -d *).' }
        @{ Exe='nbtstat'; Args=@('-R');     Ok='NetBIOS remote name cache purged (nbtstat -R).' }
        @{ Exe='nbtstat'; Args=@('-RR');    Ok='NetBIOS names refreshed (nbtstat -RR).' }
    )
    foreach ($s in $steps) {
        $o = (& $s.Exe @($s.Args) 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) { $log.Add("[OK] $($s.Ok)") }
        else { $log.Add("[WARN] $($s.Exe) $($s.Args -join ' ') failed (needs elevation/SYSTEM?): $($o.Trim())") }
    }
    $log.ToArray()
}

# endregion

# ---------------------------------------------------------------------------
# region  Drive Doctor - ghost / Red-X detection & repair (4-layer model)
# ---------------------------------------------------------------------------
# Windows network drives span 4 decoupled layers: (1) kernel DOS-device namespace,
# (2) SMB provider engine (Get-SmbMapping), (3) user registry (HKCU\Network),
# (4) Explorer shell cache (MountPoints2). A drive can be live at 1-3 while 4 is
# stale (cosmetic Red X), or exist at 1/3 without 2 (orphaned ghost -> Error 85).
# These probes/fixes MUST run in the user's session (SYSTEM sees the wrong hive/LUID),
# so they go through Invoke-ScriptInUserSession.

function ConvertFrom-NoisyJson {
    <# Parse JSON that may be surrounded by console noise (extract first {/[ to last }/]). #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json -ErrorAction Stop) } catch {}
    $i = $Text.IndexOfAny([char[]]@('{','['))
    if ($i -lt 0) { return $null }
    $end = [Math]::Max($Text.LastIndexOf('}'), $Text.LastIndexOf(']'))
    if ($end -le $i) { return $null }
    try { return ($Text.Substring($i, $end - $i + 1) | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Invoke-ScriptInUserSession {
    <#
    .SYNOPSIS
        Run a scriptblock IN the interactive user's session and return its parsed
        (JSON) output. In-process when we already ARE the user; via a one-shot task
        when SYSTEM. Single source for the Drive Doctor probe + fixes.
    .PARAMETER Vars
        Simple variables (string/bool/int) injected as assignments at the top of the
        script - so the same scriptblock works in-process and injected.
    .OUTPUTS
        PSCustomObject { Success; Data; Raw; Message; User }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [hashtable]$Vars,
        [string]$User,
        [int]$TimeoutSec = 45,
        [scriptblock]$OnPoll
    )
    $prefix = ''
    if ($Vars) {
        foreach ($k in $Vars.Keys) {
            $v = $Vars[$k]
            $lit = if ($v -is [bool]) { if ($v) { '$true' } else { '$false' } }
                   elseif ($v -is [int]) { "$v" }
                   else { "'" + (("$v") -replace "'", "''") + "'" }
            $prefix += "`$$k = $lit`r`n"
        }
    }
    $full = $prefix + $ScriptBlock.ToString()
    $isSystem = ((([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value) -eq 'S-1-5-18')

    if (-not $isSystem) {
        $raw = ''
        try { $raw = (& ([scriptblock]::Create($full)) 2>&1 | Out-String) } catch { $raw = "$($_.Exception.Message)" }
        $data = ConvertFrom-NoisyJson $raw
        return [PSCustomObject]@{ Success = [bool]$data; Data = $data; Raw = $raw.Trim(); Message = $(if ($data) { 'ok (in-process)' } else { 'no/invalid JSON' }); User = $env:USERNAME }
    }

    if (-not $User) { $User = Get-InteractiveUser }
    if (-not $User) { return [PSCustomObject]@{ Success = $false; Data = $null; Raw = $null; Message = 'No interactive user is logged on.'; User = $null } }

    $pubDocs = Join-Path $env:PUBLIC 'Documents'
    if (-not (Test-Path $pubDocs)) { $pubDocs = $env:PUBLIC }
    $ps1 = Join-Path $pubDocs ("mdt-doc-{0}.ps1" -f [guid]::NewGuid().ToString('N').Substring(0,8))
    $body = "`$ErrorActionPreference='SilentlyContinue'; `$ProgressPreference='SilentlyContinue'`r`n" + $full
    Set-Content -LiteralPath $ps1 -Value $body -Encoding UTF8
    try {
        $r   = Invoke-CommandInUserSession -CommandLine ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $ps1 + '"') -User $User -TimeoutSec $TimeoutSec -OnPoll $OnPoll
        $raw = "$($r.Output)"
        $data = ConvertFrom-NoisyJson $raw
        return [PSCustomObject]@{ Success = [bool]$data; Data = $data; Raw = $raw.Trim(); Message = $(if ($data) { 'ok (user session)' } else { $r.Message }); User = $User }
    } finally {
        Remove-Item -LiteralPath $ps1 -Force -ErrorAction SilentlyContinue
    }
}

function Get-DriveDoctorReport {
    <#
    .SYNOPSIS
        Per network-drive-letter 4-layer state + a best-effort BUCKET, from inside the
        user's session. Red X isn't directly queryable, so the raw layer data is
        returned alongside the classification.
    .OUTPUTS
        Invoke-ScriptInUserSession result; .Data = { User; Drives[]; EnableLinkedConnections }.
        Each drive: Letter, Unc, DriveType, IsReady, Accessible, Provider, SessionId,
        InSmb, SmbStatus, InRegistry, Bucket(1-5), BucketName, Action.
    #>
    [CmdletBinding()]
    param([string]$User, [scriptblock]$OnPoll)

    $probe = {
        $out = New-Object System.Collections.Generic.List[object]
        $smb = @{}
        try { Get-SmbMapping -ErrorAction Stop | ForEach-Object { $l = ("$($_.LocalPath)").TrimEnd(':').ToUpper(); if ($l) { $smb[$l] = $_ } } } catch {}
        $wmi = @{}
        try { Get-CimInstance Win32_MappedLogicalDisk -ErrorAction Stop | ForEach-Object { $l = ("$($_.DeviceID)").TrimEnd(':').ToUpper(); if ($l) { $wmi[$l] = $_ } } } catch {}
        $reg = @{}
        try { Get-ChildItem 'HKCU:\Network' -ErrorAction Stop | ForEach-Object { $l = $_.PSChildName.ToUpper(); $reg[$l] = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).RemotePath } } catch {}

        $letters = New-Object System.Collections.Generic.SortedSet[string]
        try { [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Network' } | ForEach-Object { [void]$letters.Add($_.Name.TrimEnd('\').TrimEnd(':').ToUpper()) } } catch {}
        foreach ($k in $smb.Keys) { [void]$letters.Add($k) }
        foreach ($k in $wmi.Keys) { [void]$letters.Add($k) }
        foreach ($k in $reg.Keys) { [void]$letters.Add($k) }

        foreach ($L in $letters) {
            $di = $null; try { $di = New-Object System.IO.DriveInfo($L) } catch {}
            $isReady = $false; try { $isReady = [bool]$di.IsReady } catch {}
            $dtype = ''; try { $dtype = "$($di.DriveType)" } catch {}
            $accessible = $false; try { $accessible = Test-Path "${L}:\" } catch {}
            $w = $wmi[$L]; $provider = if ($w) { "$($w.ProviderName)" } else { $null }
            $sessId = if ($w) { "$($w.SessionID)" } else { $null }
            $s = $smb[$L]; $smbStatus = if ($s) { "$($s.Status)" } else { $null }
            $regRemote = $reg[$L]
            $unc = if ($s -and $s.RemotePath) { "$($s.RemotePath)" } elseif ($regRemote) { "$regRemote" } else { $null }
            $inWmi = [bool]$w; $inSmb = [bool]$s

            $bucket = 0; $name = ''; $action = ''
            if ($inSmb -and $smbStatus -eq 'OK') { $bucket = 1; $name = 'Healthy'; $action = 'None' }
            elseif ($inSmb) { $bucket = 2; $name = "Cosmetic Red-X (SMB $smbStatus)"; $action = 'Fix Red X' }
            elseif ($inWmi -and [string]::IsNullOrEmpty($provider)) { $bucket = 3; $name = 'Orphaned Ghost (blank provider, Error 85)'; $action = $(if ($accessible) { 'Fix Red X (cosmetic) OR Release ghost + remap' } else { 'Release ghost + remap' }) }
            elseif ($dtype -eq 'Network') { $bucket = 3; $name = 'Orphaned Ghost'; $action = 'Release ghost + remap' }
            elseif (-not $isReady) { $bucket = 4; $name = 'Not ready (network/creds)'; $action = 'Check connectivity / credentials / host conns' }
            else { $bucket = 2; $name = 'Cosmetic / unmanaged'; $action = 'Fix Red X, or re-map' }

            $out.Add([pscustomobject]@{
                Letter = $L; Unc = $unc; DriveType = $dtype; IsReady = $isReady; Accessible = $accessible
                Provider = $provider; SessionId = $sessId; InSmb = $inSmb; SmbStatus = $smbStatus
                InRegistry = [bool]$regRemote; Bucket = $bucket; BucketName = $name; Action = $action
            })
        }
        $linked = $null
        try { $linked = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLinkedConnections -ErrorAction Stop).EnableLinkedConnections } catch {}
        [pscustomobject]@{ User = $env:USERNAME; Drives = $out.ToArray(); EnableLinkedConnections = $linked } | ConvertTo-Json -Depth 5
    }
    Invoke-ScriptInUserSession -ScriptBlock $probe -User $User -TimeoutSec 40 -OnPoll $OnPoll
}

function Repair-RedXCache {
    <#
    .SYNOPSIS
        Cosmetic Red-X fix: back up + delete ONLY the target letter's MountPoints2
        shell-cache key(s), refresh the shell (SHChangeNotify), touch the drive. Runs
        in the user's session; never deletes the whole MountPoints2 tree or the
        connection itself.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Letter, [string]$User, [scriptblock]$OnPoll)

    $fix = {
        $L = $Letter.TrimEnd(':').ToUpper()
        $log = New-Object System.Collections.Generic.List[string]
        $mp2 = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'
        $unc = $null
        try { $unc = (Get-ItemProperty "HKCU:\Network\$L" -ErrorAction SilentlyContinue).RemotePath } catch {}
        if (-not $unc) { try { $unc = (Get-SmbMapping -LocalPath "${L}:" -ErrorAction SilentlyContinue).RemotePath } catch {} }
        $target = $null
        if ($unc -and $unc -match '^\\\\([^\\]+)\\(.+)$') { $target = '##' + $Matches[1] + '#' + ($Matches[2] -replace '\\', '#') }

        $keys = @()
        try { $keys = @(Get-ChildItem $mp2 -ErrorAction SilentlyContinue | Where-Object { $target -and $_.PSChildName -ieq $target } | ForEach-Object { $_.PSChildName }) } catch {}

        $bak = Join-Path ([Environment]::GetFolderPath('Desktop')) ("MountPoints2-backup-{0}.reg" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        & reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2" "$bak" /y *>$null
        if (Test-Path $bak) { $log.Add("[OK] Backed up MountPoints2 -> $bak") } else { $log.Add('[WARN] Could not back up MountPoints2') }

        foreach ($k in $keys) {
            & reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\$k" /f *>$null
            if ($LASTEXITCODE -eq 0) { $log.Add("[OK] Removed shell-cache key $k") } else { $log.Add("[WARN] Could not remove $k") }
        }
        if (-not @($keys).Count) { $log.Add("[INFO] No exact MountPoints2 key for $L ($unc) - nothing purged (safe).") }

        try {
            if (-not ('MDT.Shell' -as [type])) {
                Add-Type -Namespace MDT -Name Shell -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, System.IntPtr a, System.IntPtr b);' -ErrorAction Stop
            }
            [MDT.Shell]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)  # SHCNE_ASSOCCHANGED
            $log.Add('[OK] Shell refresh sent (SHChangeNotify).')
        } catch { $log.Add("[WARN] SHChangeNotify failed: $($_.Exception.Message)") }

        try { Get-ChildItem "${L}:\" -ErrorAction SilentlyContinue | Select-Object -First 1 | Out-Null; $log.Add("[OK] Touched ${L}: to refresh Explorer state.") } catch {}
        [pscustomobject]@{ Letter = $L; Unc = $unc; RemovedKeys = @($keys); Backup = $bak; Log = $log.ToArray() } | ConvertTo-Json -Depth 5
    }
    Invoke-ScriptInUserSession -ScriptBlock $fix -Vars @{ Letter = $Letter } -User $User -TimeoutSec 40 -OnPoll $OnPoll
}

function Clear-GhostDrive {
    <#
    .SYNOPSIS
        Release an orphaned "ghost" drive letter (Error 85) so it can be remapped:
        back up HKCU\Network\<letter>, delete it, call DefineDosDevice(DDD_REMOVE_
        DEFINITION) to free the DOS-device symlink, optionally clean-remap. Runs in the
        user's session. -WhatIf backs up + reports but does NOT delete/release.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Letter,
        [string]$Remap,
        [switch]$WhatIf,
        [string]$User,
        [scriptblock]$OnPoll
    )
    $rel = {
        $L = $Letter.TrimEnd(':').ToUpper()
        $log = New-Object System.Collections.Generic.List[string]
        $bak = Join-Path ([Environment]::GetFolderPath('Desktop')) ("GhostRelease-$L-{0}.reg" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        & reg export "HKCU\Network\$L" "$bak" /y *>$null
        if (Test-Path $bak) { $log.Add("[OK] Backed up HKCU\Network\$L -> $bak") } else { $log.Add("[INFO] No HKCU\Network\$L to back up.") }

        if ($WhatIfMode) {
            $log.Add("[INFO] WhatIf: would delete HKCU\Network\$L and DefineDosDevice-remove ${L}:.")
            [pscustomobject]@{ Letter = $L; WhatIf = $true; Remapped = $false; Log = $log.ToArray() } | ConvertTo-Json -Depth 5
            return
        }

        & reg delete "HKCU\Network\$L" /f *>$null
        $log.Add("[OK] Removed HKCU\Network\$L (if present).")

        try {
            if (-not ('MDT.Kernel' -as [type])) {
                Add-Type -Namespace MDT -Name Kernel -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)] public static extern bool DefineDosDevice(int flags, string device, string path);' -ErrorAction Stop
            }
            $ok = [MDT.Kernel]::DefineDosDevice(0x00000002, "${L}:", $null)  # DDD_REMOVE_DEFINITION
            if ($ok) { $log.Add("[OK] Released DOS device ${L}: (DefineDosDevice).") } else { $log.Add("[WARN] DefineDosDevice returned false for ${L}:.") }
        } catch { $log.Add("[WARN] DefineDosDevice failed: $($_.Exception.Message)") }

        $stillNet = $false
        try { $stillNet = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name.TrimEnd('\').TrimEnd(':').ToUpper() -eq $L -and $_.DriveType -eq 'Network' }).Count -gt 0 } catch {}
        if ($stillNet) { $log.Add("[WARN] ${L}: still present as a network drive - a sign-out may be required.") } else { $log.Add("[OK] ${L}: is now free.") }

        $remapped = $false
        if ($RemapUnc) {
            & net use "${L}:" "$RemapUnc" /persistent:yes *>$null
            if ($LASTEXITCODE -eq 0) { $remapped = $true; $log.Add("[OK] Remapped ${L}: -> $RemapUnc") } else { $log.Add("[WARN] Remap ${L}: failed (net use exit $LASTEXITCODE).") }
        }
        [pscustomobject]@{ Letter = $L; WhatIf = $false; Remapped = $remapped; Log = $log.ToArray() } | ConvertTo-Json -Depth 5
    }
    Invoke-ScriptInUserSession -ScriptBlock $rel -Vars @{ Letter = $Letter; RemapUnc = "$Remap"; WhatIfMode = [bool]$WhatIf } -User $User -TimeoutSec 45 -OnPoll $OnPoll
}

function Get-DriveOriginGpo {
    <#
    .SYNOPSIS
        Detect whether Group Policy "Drive Maps" / logon scripts create the user's
        drives (so the lasting fix is in policy, not local surgery). Writes a full
        HTML report to the user's Desktop. Runs in the user's session.
    #>
    [CmdletBinding()]
    param([string]$User, [scriptblock]$OnPoll)
    $g = {
        $log = New-Object System.Collections.Generic.List[string]
        $txt = (& gpresult /scope user /r 2>&1 | Out-String)
        $isGpo = [bool]($txt -match '(?im)Drive\s*Maps')
        if ($isGpo) { $log.Add('[WARN] Group Policy "Drive Maps" is present - drives may be GPO-created; fix in the policy, not locally.') }
        if ($txt -match '(?im)Logon\s*Script') { $log.Add('[INFO] Logon scripts are configured - a script may create the drives.') }
        $html = Join-Path ([Environment]::GetFolderPath('Desktop')) 'UserPolicy.html'
        & gpresult /scope user /h "$html" /f *>$null
        if (Test-Path $html) { $log.Add("[OK] Full policy report written: $html") }
        if (-not $isGpo) { $log.Add('[INFO] No GPO "Drive Maps" found in the user-policy summary.') }
        [pscustomobject]@{ GpoDriveMaps = $isGpo; Report = $html; Log = $log.ToArray() } | ConvertTo-Json -Depth 5
    }
    Invoke-ScriptInUserSession -ScriptBlock $g -User $User -TimeoutSec 60 -OnPoll $OnPoll
}

# endregion

# ---------------------------------------------------------------------------
# region  Credential contamination / domain health audit (v2.2)
# ---------------------------------------------------------------------------
# Windows multiplexes EVERY connection to a server over ONE authenticated SMB
# session. A saved Credential Manager entry for that server therefore decides the
# identity for ALL its drives - so a cred stored under a different account (the
# field case: vault said CONTOSO.local\jsmith, user was bjones) makes
# some shares work and others "Access is Denied" purely on that account's ACLs.
# Corollary traps: a partial teardown leaves the old identity alive, and
# `net use /user:` fixes the session but does NOT survive a reboot without cmdkey.
# NOTE: these probes MUST run in the USER's session - SYSTEM has its own vault,
# its own Kerberos cache and its own connections.

function Get-CredentialAudit {
    <#
    .SYNOPSIS
        Audit Credential Manager (cmdkey) in the user's session and flag stored
        credentials whose USER differs from the logged-on user - the classic cause
        of selective "Access is Denied" across shares on one server.
    .OUTPUTS
        Invoke-ScriptInUserSession result; .Data = { User; Entries[]; Findings[] }.
    #>
    [CmdletBinding()]
    param([string]$User, [scriptblock]$OnPoll)

    $probe = {
        $raw = (& cmdkey /list 2>&1 | Out-String)
        $entries = New-Object System.Collections.Generic.List[object]
        $cur = $null
        foreach ($line in ($raw -split "`r?`n")) {
            $t = $line.Trim()
            if ($t -match '^Target:\s*(.+)$') {
                if ($cur) { $entries.Add([pscustomobject]$cur) }
                $cur = @{ Target = $Matches[1].Trim(); Type = ''; CredUser = '' }
            } elseif ($cur -and $t -match '^Type:\s*(.+)$') { $cur.Type = $Matches[1].Trim() }
            elseif ($cur -and $t -match '^User:\s*(.+)$')   { $cur.CredUser = $Matches[1].Trim() }
        }
        if ($cur) { $entries.Add([pscustomobject]$cur) }

        $me = $env:USERNAME
        $partOfDomain = $false; $machDomain = ''
        try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop; $partOfDomain = [bool]$cs.PartOfDomain; $machDomain = "$($cs.Domain)" } catch {}
        $domShort = ($machDomain -split '\.')[0]

        $rows = New-Object System.Collections.Generic.List[object]
        $findings = New-Object System.Collections.Generic.List[string]
        $hostSeen = @{}

        foreach ($e in $entries) {
            # Domain:target=<host> entries are the SMB-relevant ones (cmdkey /add:<host>).
            $isSmb = ($e.Target -match '^Domain:target=(.+)$')
            $tgtHost = if ($isSmb) { $Matches[1].Trim() } else { $null }
            if (-not $isSmb) { continue }
            # Service-prefixed Domain: targets are not SMB servers - e.g. TERMSRV/host
            # (saved RDP logins) - and '*Session' is a logon-session placeholder.
            if ($tgtHost -match '/' -or $tgtHost -match '^\*Session$') { continue }
            $leaf = if ($e.CredUser -match '\\') { ($e.CredUser -split '\\')[-1] } else { $e.CredUser }
            $prefix = if ($e.CredUser -match '\\') { ($e.CredUser -split '\\')[0] } else { '' }
            $mismatch = ($leaf -and ($leaf -ne $me))
            $bare = ($e.CredUser -and ($e.CredUser -notmatch '\\') -and ($e.CredUser -notmatch '@'))
            # A DOMAIN account that is not the logged-on user is the dangerous case
            # (field case: vault said CONTOSO.local\jsmith while logged on as bjones).
            # On a workgroup PC a different account (NAS 'admin') is the NORMAL shared-account
            # model this toolkit itself uses - do not cry wolf.
            $domainCred = ($prefix -and $domShort -and (($prefix -ieq $domShort) -or ($prefix -ieq $machDomain)))
            $sev = if (-not $mismatch) { 'OK' } elseif ($partOfDomain -and $domainCred) { 'FAIL' } elseif ($partOfDomain) { 'WARN' } else { 'INFO' }
            $rows.Add([pscustomobject]@{ TargetHost = $tgtHost; Target = $e.Target; Type = $e.Type; CredUser = $e.CredUser; LeafUser = $leaf; Mismatch = [bool]$mismatch; BareUser = [bool]$bare; Severity = $sev })

            $note = if ($bare) { "  (bare username - qualify as SERVER\user or IP\user for Win11 24H2 / workgroup servers)" } else { '' }
            switch ($sev) {
                'FAIL' { $findings.Add("[FAIL] '$tgtHost' is authenticated by a stored DOMAIN credential '$($e.CredUser)', not the logged-on user '$me'. Every share on that server uses that identity, so shares $leaf lacks rights to return 'Access is Denied' while others work. Verify $leaf's password is current, or remove the credential so $me authenticates directly.$note") }
                'WARN' { $findings.Add("[WARN] '$tgtHost' uses stored credential '$($e.CredUser)' rather than the logged-on user '$me'. All shares on that server inherit that identity.$note") }
                'INFO' { $findings.Add("[INFO] '$tgtHost' uses stored credential '$($e.CredUser)' (not the logged-on user) - normal for a NAS/shared-account setup. Note: ALL shares on that server use this identity.$note") }
            }
            $key = ($tgtHost -replace '^\\\\','').ToLower()
            if ($hostSeen.ContainsKey($key)) { $findings.Add("[WARN] Duplicate stored credentials for '$tgtHost' - conflicting entries under name and IP forms cause error 1219 / identity flip-flop.") }
            $hostSeen[$key] = $true
        }
        # NOTE: use .Count directly on generic Lists - @($list).Count throws
        # "Argument types do not match" on Windows PowerShell 5.1.
        if ($rows.Count -eq 0) { $findings.Add("[INFO] No SMB (Domain:target=) credentials stored for '$me'. Connections will use the logged-on identity.") }
        elseif (@($rows.ToArray() | Where-Object { $_.Mismatch }).Count -eq 0) { $findings.Add("[OK] All stored SMB credentials match the logged-on user '$me'.") }

        [pscustomobject]@{ User = $me; Entries = $rows.ToArray(); Findings = $findings.ToArray(); TotalVaultEntries = $entries.Count } | ConvertTo-Json -Depth 5
    }
    Invoke-ScriptInUserSession -ScriptBlock $probe -User $User -TimeoutSec 40 -OnPoll $OnPoll
}

function Set-DriveNoteProp {
    <# Set a property on a drive object, adding it when absent (hand-built drives). #>
    param($Drive, [string]$Name, $Value)
    if ($Drive.PSObject.Properties[$Name]) { $Drive.$Name = $Value }
    else { $Drive | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Resolve-DriveCredentials {
    <#
    .SYNOPSIS
        Work out WHICH ACCOUNT authenticates each mapped drive - not just who owns it.
    .DESCRIPTION
        Per drive, first hit wins:
          1. RegUserName - the Network\<letter>\UserName value 'net use /user:' records.
          2. A saved Credential Manager entry (Domain:target=) whose target EXACTLY
             matches the UNC host (case-insensitive) or a '*.suffix' wildcard. This is
             how Windows itself picks a vault credential.
          3. Otherwise the logged-on user's own identity (pass-through / Kerberos).

        A vault entry for the same server under a DIFFERENT name (IP vs name, short
        vs FQDN) is reported in CredNote but never claimed as the identity - Windows
        will not use it for that path (a classic cause of the credential prompt /
        error 1223).

        The vault is per-user, so it is read in the interactive user's session via
        Get-CredentialAudit (in-process as the user, one-shot task from SYSTEM). It
        is NOT read when running as a different account (e.g. an elevated tech
        login) - that would report the wrong person's credentials. The password is
        never available: Windows does not expose saved passwords.
    .PARAMETER Drives
        Objects from Get-CurrentDriveMappings / ConvertFrom-DriveMapJson.
    .PARAMETER VaultEntries
        Pre-supplied entries (TargetHost + CredUser). Skips the live vault read; for tests.
    .PARAMETER VaultUser
        Whose vault -VaultEntries came from (optional; enables the ownership check).
    .OUTPUTS
        { Drives; VaultRead; VaultUser; Message }. Each drive gains CredUser,
        CredSource, CredTarget, CredNote.
    #>
    [CmdletBinding()]
    param(
        # AllowEmpty/Null: a Mandatory param otherwise rejects an empty drive list.
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()]$Drives,
        $VaultEntries,
        [string]$VaultUser,
        [switch]$SkipVault,
        [scriptblock]$OnPoll,
        [int]$DnsMs = 1500
    )

    $list = @($Drives | Where-Object { $null -ne $_ })
    # Leaf account name, comparable across DOMAIN\user, PC\user and user@domain forms.
    $leafOf = { param($n) if (-not $n) { return '' }; $x = ("$n" -split '\\')[-1]; ($x -split '@')[0].ToLower() }
    $keyOf  = { param($h) ("$h".Trim() -replace '^\\\\', '').TrimEnd('\').ToLower() }
    $isIp   = { param($h) "$h" -match '^\d{1,3}(\.\d{1,3}){3}$' }

    # ---- 1. Obtain the vault (the interactive user's), or explain why not ----
    $vault = @(); $vaultRead = $false; $message = ''
    if ($null -ne $VaultEntries) {
        $vault = @($VaultEntries | Where-Object { $null -ne $_ })
        $vaultRead = $true; $message = "Using $($vault.Count) supplied vault entr$(if($vault.Count -eq 1){'y'}else{'ies'})."
    } elseif ($SkipVault) {
        $message = 'Saved credentials not read (-SkipVault).'
    } else {
        $isSystem = ((([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value) -eq 'S-1-5-18')
        $interactive = $null
        try { $interactive = Get-InteractiveUser } catch {}
        $current = ([Security.Principal.WindowsIdentity]::GetCurrent()).Name
        if (-not $isSystem -and $interactive -and ((& $leafOf $current) -ne (& $leafOf $interactive))) {
            $message = "Running as '$current' but the logged-on user is '$interactive' - their saved credentials can only be read as that user or as SYSTEM (Backstage)."
        } elseif ($isSystem -and -not $interactive) {
            $message = 'No user is logged on - saved credentials not read.'
        } else {
            $r = Get-CredentialAudit -OnPoll $OnPoll
            if ($r -and $r.Success -and $r.Data) {
                if ($r.Data.PSObject.Properties['Entries'] -and $null -ne $r.Data.Entries) {
                    $vault = @($r.Data.Entries | Where-Object { $null -ne $_ })
                }
                if (-not $VaultUser) { $VaultUser = "$($r.Data.User)" }
                $vaultRead = $true
                $message = "Read $($vault.Count) saved server credential(s) for '$VaultUser'."
            } else {
                $why = if ($r) { "$($r.Message)" } else { 'no result' }
                $message = "Could not read saved credentials: $why"
            }
        }
    }

    # Normalise vault rows; drop non-SMB Domain: targets (TERMSRV/host = RDP logins).
    $vrows = @()
    foreach ($e in $vault) {
        $t = Get-PropOrDefault $e 'TargetHost' $null
        if (-not $t) {
            $raw = "$(Get-PropOrDefault $e 'Target' '')"
            if ($raw -match '^Domain:target=(.+)$') { $t = $Matches[1].Trim() } else { $t = $raw }
        }
        $u = Get-PropOrDefault $e 'CredUser' (Get-PropOrDefault $e 'User' $null)
        if (-not $t -or -not $u) { continue }
        if ("$t" -match '/' -or "$t" -match '^\*Session$') { continue }
        $vrows += [pscustomobject]@{ Target = "$t".Trim(); Key = (& $keyOf $t); User = "$u" }
    }

    # Bounded, cached forward lookups - only used for near-miss NOTES (IP vs name).
    # $dnsBudget caps total lookups so a dead DNS server can't stall Collect.
    $dnsCache = @{}; $dnsBudget = 12
    $v4Of = {
        param($name)
        $k = "$name".ToLower()
        if (-not $dnsCache.ContainsKey($k)) { $dnsCache[$k] = @((Resolve-AddrBounded -Name $name -Ms $DnsMs).V4) }
        $dnsCache[$k]
    }

    # ---- 2. Classify each drive ----
    foreach ($d in $list) {
        $unc  = "$(Get-PropOrDefault $d 'Unc' '')"
        $hostName = Get-UncHost $unc
        $hk   = & $keyOf $hostName
        $regU = Get-PropOrDefault $d 'RegUserName' $null
        $owner = "$(Get-PropOrDefault $d 'ConnectionUser' '')"
        $ownedByOther = ($vaultRead -and $VaultUser -and $owner -and $owner -ne 'Unknown' -and ((& $leafOf $owner) -ne (& $leafOf $VaultUser)))

        # Exact / wildcard vault match (how Windows chooses), only for the vault owner's drives.
        $match = $null
        if ($vaultRead -and -not $ownedByOther -and $hk) {
            $match = @($vrows | Where-Object { $_.Key -eq $hk }) | Select-Object -First 1
            if (-not $match) {
                $match = @($vrows | Where-Object { $_.Key -like '`*.*' -and $hk.EndsWith($_.Key.Substring(1)) }) | Select-Object -First 1
            }
        }

        # Near-miss: same server saved under another name - Windows will NOT use it.
        $near = $null
        if ($vaultRead -and -not $ownedByOther -and $hk -and -not $match -and $vrows.Count) {
            foreach ($v in $vrows) {
                if ($v.Key -like '`*.*') { continue }
                $hIp = & $isIp $hk; $vIp = & $isIp $v.Key
                if (-not $hIp -and -not $vIp -and (($hk -split '\.')[0] -eq ($v.Key -split '\.')[0])) { $near = $v; break }
                if ($hIp -and -not $vIp -and $dnsBudget -gt 0) {
                    $dnsBudget--; if (@(& $v4Of $v.Target) -contains $hk) { $near = $v; break }
                } elseif (-not $hIp -and $vIp -and $dnsBudget -gt 0) {
                    $dnsBudget--; if (@(& $v4Of $hostName) -contains $v.Key) { $near = $v; break }
                }
            }
        }

        $credUser = $null; $source = $null; $target = $null; $note = $null
        if ($regU) {
            $credUser = $regU; $source = 'mapped with /user:'; $target = $hostName
            if ($match -and ((& $leafOf $match.User) -ne (& $leafOf $regU))) {
                $note = "Also a saved credential for '$($match.Target)' as '$($match.User)' - two identities for one server cause error 1219."
            }
        } elseif ($match) {
            $credUser = $match.User; $source = 'saved credential'; $target = $match.Target
        } elseif ($ownedByOther) {
            $source = "not read (mapping belongs to $owner)"
        } elseif ($vaultRead) {
            $credUser = if ($owner -and $owner -ne 'Unknown') { $owner } else { $VaultUser }
            $source = 'logged-on user (pass-through)'
        } else {
            $source = 'unknown (saved credentials not read)'
        }
        if ($near -and -not $note) {
            $note = "Saved credential exists for '$($near.Target)' ($($near.User)) but this drive maps '\\$hostName' - Windows matches the exact server name, so it is NOT used. Map via '$($near.Target)' or save the credential for '$hostName'."
        }

        Set-DriveNoteProp $d 'CredUser'   $credUser
        Set-DriveNoteProp $d 'CredSource' $source
        Set-DriveNoteProp $d 'CredTarget' $target
        Set-DriveNoteProp $d 'CredNote'   $note
    }

    [pscustomobject]@{ Drives = @($list); VaultRead = $vaultRead; VaultUser = $VaultUser; Message = $message }
}

function Get-InferredCredential {
    <#
    .SYNOPSIS
        Pick the profile-level credential from per-drive detection results.
    .DESCRIPTION
        Chooses the (server, user) pair backing the most drives, preferring saved
        Credential Manager entries over 'net use /user:' records (tie -> lowest drive
        letter). Returns Mode cmdkey with Target/User filled and Password BLANK -
        Windows never exposes saved passwords, and New-MapDrivesCmdContent refuses to
        generate until one is typed. Credential = $null when nothing was detected
        (genuine pass-through).
    .OUTPUTS
        { Credential; Source; Note }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()]$Drives)

    $list = @($Drives | Where-Object { $null -ne $_ })
    $tally = @{}
    foreach ($d in $list) {
        $src = "$(Get-PropOrDefault $d 'CredSource' '')"
        $u   = Get-PropOrDefault $d 'CredUser' $null
        $t   = Get-PropOrDefault $d 'CredTarget' $null
        if (-not $u -or -not $t) { continue }
        $rank = -1
        if ($src -eq 'saved credential') { $rank = 0 } elseif ($src -eq 'mapped with /user:') { $rank = 1 }
        if ($rank -lt 0) { continue }
        $k = ("$t|$u").ToLower()
        if (-not $tally.ContainsKey($k)) {
            # 'N' not 'Count': a note property named Count is ambiguous with the
            # intrinsic .Count PowerShell adds to every object.
            $tally[$k] = [pscustomobject]@{ Target = "$t"; User = "$u"; Source = $src; Rank = $rank; N = 0; FirstLetter = 'Z' }
        }
        $row = $tally[$k]
        $row.N++
        $L = "$(Get-PropOrDefault $d 'Letter' 'Z')"
        if ($L -lt $row.FirstLetter) { $row.FirstLetter = $L }
        if ($rank -lt $row.Rank) { $row.Rank = $rank; $row.Source = $src }
    }
    if ($tally.Count -eq 0) {
        return [pscustomobject]@{ Credential = $null; Source = $null; Note = $null }
    }
    $rows = @($tally.Values | Sort-Object Rank, @{ Expression = 'N'; Descending = $true }, FirstLetter)
    $pick = $rows[0]
    $note = $null
    if ($rows.Count -gt 1) {
        $desc = ($rows | ForEach-Object { "$($_.User) @ $($_.Target) ($($_.N) drive$(if($_.N -ne 1){'s'}))" }) -join '; '
        $note = "Drives use $($rows.Count) different server credentials: $desc. The profile carries one ($($pick.User) @ $($pick.Target)); drives on other servers rely on credentials already saved on the target PC."
    }
    [pscustomobject]@{
        Credential = [pscustomobject]@{ Mode = 'cmdkey'; Target = $pick.Target; User = $pick.User; Password = '' }
        Source     = $pick.Source
        Note       = $note
    }
}

function Get-KerberosAudit {
    <#
    .SYNOPSIS
        Kerberos ticket audit in the user's session. A live SMB connection to a
        server with NO cifs/<server> ticket means NTLM fallback - typically a
        stored credential overriding the logged-on identity. N/A on workgroup.
    #>
    [CmdletBinding()]
    param([string]$User, [scriptblock]$OnPoll)

    $probe = {
        $partOfDomain = $false
        try { $partOfDomain = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch {}
        $findings = New-Object System.Collections.Generic.List[string]
        if (-not $partOfDomain) {
            $findings.Add('[INFO] Workgroup machine - Kerberos is not used (NTLM only). Check is N/A.')
            [pscustomobject]@{ PartOfDomain = $false; Tickets = @(); Hosts = @(); Findings = $findings.ToArray() } | ConvertTo-Json -Depth 5
            return
        }
        $raw = (& klist 2>&1 | Out-String)
        $tickets = New-Object System.Collections.Generic.List[object]
        $client = ''
        foreach ($line in ($raw -split "`r?`n")) {
            $t = $line.Trim()
            if ($t -match '^Client:\s*(.+)$') { $client = $Matches[1].Trim() }
            elseif ($t -match '^Server:\s*(.+)$') { $tickets.Add([pscustomobject]@{ Client = $client; Server = $Matches[1].Trim() }) }
        }
        # Hosts we currently hold SMB connections to.
        $hosts = New-Object System.Collections.Generic.List[string]
        try { Get-SmbMapping -ErrorAction Stop | ForEach-Object { if ("$($_.RemotePath)" -match '^\\\\([^\\]+)\\') { [void]$hosts.Add($Matches[1]) } } } catch {}
        try { Get-ChildItem 'HKCU:\Network' -ErrorAction Stop | ForEach-Object { $rp = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).RemotePath; if ("$rp" -match '^\\\\([^\\]+)\\') { [void]$hosts.Add($Matches[1]) } } } catch {}
        $uniq = @($hosts | Sort-Object -Unique)
        foreach ($h in $uniq) {
            $short = ($h -split '\.')[0]
            $has = @($tickets | Where-Object { $_.Server -match "(?i)^cifs/$([regex]::Escape($short))(\.|@|$)" }).Count -gt 0
            if ($has) { $findings.Add("[OK] Kerberos ticket cifs/$short present - authenticating as the logged-on user.") }
            else { $findings.Add("[WARN] Connected to '$h' but NO cifs/$short Kerberos ticket - NTLM fallback. Usually a STORED credential (cmdkey) is overriding the logged-on identity, or the password is stale.") }
        }
        if (@($uniq).Count -eq 0) { $findings.Add('[INFO] No SMB connections found to correlate against the ticket cache.') }
        [pscustomobject]@{ PartOfDomain = $true; Tickets = $tickets.ToArray(); Hosts = $uniq; Findings = $findings.ToArray() } | ConvertTo-Json -Depth 5
    }
    Invoke-ScriptInUserSession -ScriptBlock $probe -User $User -TimeoutSec 40 -OnPoll $OnPoll
}

function Get-DomainHealth {
    <#
    .SYNOPSIS
        Domain/DC health as it affects drive mapping: logon server, whether the
        user's token actually carries domain groups (empty = cached logon / broken
        token), DC reachability (ICMP + LDAP/KDC/SMB), and the secure channel.
        READ-ONLY - never runs Test-ComputerSecureChannel -Repair. N/A on workgroup.
    #>
    [CmdletBinding()]
    param([string]$User, [int]$TimeoutMs = 800, [scriptblock]$OnPoll)

    $probe = {
        $findings = New-Object System.Collections.Generic.List[string]
        $partOfDomain = $false; $domain = ''
        try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop; $partOfDomain = [bool]$cs.PartOfDomain; $domain = "$($cs.Domain)" } catch {}
        if (-not $partOfDomain) {
            $findings.Add("[INFO] Workgroup machine (domain='$domain') - DC / secure-channel / domain-group checks are N/A.")
            [pscustomobject]@{ PartOfDomain=$false; Domain=$domain; LogonServer=$null; DomainGroups=@(); HasDomainGroups=$null; DcReachable=$null; SecureChannel=$null; Findings=$findings.ToArray() } | ConvertTo-Json -Depth 5
            return
        }
        $logon = "$env:LOGONSERVER" -replace '^\\\\',''
        if ($logon) { $findings.Add("[INFO] LOGONSERVER = $logon (domain $domain)") } else { $findings.Add('[WARN] LOGONSERVER is empty - the user may have logged on with cached credentials.') }

        # Token: domain groups present?
        $groups = @()
        try { $groups = @((& whoami /groups 2>&1 | Out-String) -split "`r?`n" | Where-Object { $_ -match '^\s*\S' }) } catch {}
        $domShort = ($domain -split '\.')[0]
        $hasDom = [bool](@($groups | Where-Object { $_ -match '(?i)\bDomain Users\b' -or ($domShort -and $_ -match "(?i)^\s*$([regex]::Escape($domShort))\\") }).Count)
        if ($hasDom) { $findings.Add('[OK] Token contains domain groups.') }
        else { $findings.Add("[FAIL] Token contains NO domain groups - the user logged on with cached credentials or the machine's secure channel is broken. Share ACLs granted to domain groups will deny access. Fix: full log OFF and on (not lock/unlock); if it persists, repair the secure channel.") }

        # DC reachability.
        $dcIp = $null; $ping = $false; $p389=$false; $p88=$false; $p445=$false
        function TcpTest { param($a,$p,$ms) if(-not $a){return $false}; try { $c=New-Object System.Net.Sockets.TcpClient; $i=$c.BeginConnect($a,$p,$null,$null); $ok=$i.AsyncWaitHandle.WaitOne($ms,$false) -and $c.Connected; if($ok){$c.EndConnect($i)}; $c.Close(); return $ok } catch { return $false } }
        if ($logon) {
            try { $dcIp = ([System.Net.Dns]::GetHostAddresses($logon) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString } catch {}
            if ($dcIp) {
                try { $ping = [bool](Test-Connection -ComputerName $dcIp -Count 1 -Quiet -ErrorAction SilentlyContinue) } catch {}
                $p389 = TcpTest $dcIp 389 $TimeoutMsVal; $p88 = TcpTest $dcIp 88 $TimeoutMsVal; $p445 = TcpTest $dcIp 445 $TimeoutMsVal
                $findings.Add("[INFO] DC $logon -> $dcIp   ping=$ping  LDAP389=$p389  KDC88=$p88  SMB445=$p445")
                if (-not ($p389 -or $p88)) { $findings.Add("[FAIL] Domain controller '$logon' is NOT answering on LDAP/KDC - logons fall back to cached credentials and group-based share access breaks.") }
                elseif (-not $ping) { $findings.Add("[INFO] DC does not answer ICMP (often firewalled) but LDAP/KDC respond - considered reachable.") }
                else { $findings.Add("[OK] Domain controller '$logon' is reachable.") }
            } else { $findings.Add("[FAIL] Could not resolve the logon server '$logon' - DNS problem or the DC is gone.") }
        }
        # Is the DC also our DNS server? (mismatch is a common cause of stale/failed lookups)
        $dnsServers = @()
        try { $dnsServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses } | Select-Object -Unique) } catch {}
        if ($dcIp -and @($dnsServers).Count -and ($dnsServers -notcontains $dcIp)) {
            $findings.Add("[WARN] DNS servers ($($dnsServers -join ', ')) do not include the DC ($dcIp). On a domain, clients should normally use the DC for DNS or AD records may not resolve.")
        }

        # Secure channel - only if the DC answered, so we cannot hang on a dead DC.
        $sc = $null
        if ($p389 -or $p88) {
            try { $sc = [bool](Test-ComputerSecureChannel -ErrorAction Stop) } catch { $sc = $null }
            if ($sc -eq $true) { $findings.Add('[OK] Machine secure channel to the domain is healthy.') }
            elseif ($sc -eq $false) { $findings.Add('[FAIL] Machine secure channel is BROKEN - repair it (Test-ComputerSecureChannel -Repair, needs domain admin) or rejoin. Token/group problems follow from this.') }
        } else { $findings.Add('[INFO] Skipped secure-channel test (DC not answering) to avoid a long block.') }

        [pscustomobject]@{ PartOfDomain=$true; Domain=$domain; LogonServer=$logon; DcIp=$dcIp; DcPing=$ping; DcLdap=$p389; DcKdc=$p88; DcSmb=$p445; HasDomainGroups=$hasDom; DnsServers=$dnsServers; SecureChannel=$sc; Findings=$findings.ToArray() } | ConvertTo-Json -Depth 5
    }
    Invoke-ScriptInUserSession -ScriptBlock $probe -Vars @{ TimeoutMsVal = [int]$TimeoutMs } -User $User -TimeoutSec 60 -OnPoll $OnPoll
}

function Test-ShareAccessMatrix {
    <#
    .SYNOPSIS
        Differential access test across every share on one host, from the user's
        session. A mix of OK and AccessDenied on the SAME host proves the SMB
        session's identity lacks rights to some shares (all shares share one
        session) - i.e. a credential/ACL problem, not name resolution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetHost,
        [string[]]$ExtraShares,
        [string]$User,
        [scriptblock]$OnPoll
    )
    $probe = {
        $h = $HostName
        $shares = New-Object System.Collections.Generic.List[string]
        foreach ($s in ($ExtraShareList -split ';')) { if ($s) { [void]$shares.Add($s) } }
        # Shares already mapped to this host.
        try { Get-SmbMapping -ErrorAction Stop | ForEach-Object { if ("$($_.RemotePath)" -match "(?i)^\\\\$([regex]::Escape($h))\\([^\\]+)") { [void]$shares.Add($Matches[1]) } } } catch {}
        try { Get-ChildItem 'HKCU:\Network' -ErrorAction Stop | ForEach-Object { $rp = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).RemotePath; if ("$rp" -match "(?i)^\\\\$([regex]::Escape($h))\\([^\\]+)") { [void]$shares.Add($Matches[1]) } } } catch {}
        # Anything the server will admit to.
        try { foreach ($line in ((& net view "\\$h" /all 2>&1) -split "`r?`n")) { if ($line -match '^(.+?)\s{2,}Disk') { [void]$shares.Add($Matches[1].Trim()) } } } catch {}

        $uniq = @($shares | Where-Object { $_ -and $_ -notmatch '\$$' } | Sort-Object -Unique)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($s in $uniq) {
            $unc = "\\$h\$s"; $state = 'Unknown'; $err = ''
            try {
                Get-ChildItem -LiteralPath $unc -ErrorAction Stop | Select-Object -First 1 | Out-Null
                $state = 'OK'
            } catch {
                $err = "$($_.Exception.Message)"
                if ($err -match '(?i)denied')            { $state = 'AccessDenied' }
                elseif ($err -match '(?i)not found|cannot find|does not exist') { $state = 'NotFound' }
                elseif ($err -match '(?i)network path')  { $state = 'PathNotFound' }
                else { $state = 'Error' }
            }
            $rows.Add([pscustomobject]@{ Share = $s; Unc = $unc; State = $state; Error = $err })
        }
        $ok = @($rows.ToArray() | Where-Object { $_.State -eq 'OK' }); $den = @($rows.ToArray() | Where-Object { $_.State -eq 'AccessDenied' })
        $findings = New-Object System.Collections.Generic.List[string]
        if ($rows.Count -eq 0) { $findings.Add("[INFO] No shares discovered on $h to test.") }
        elseif (@($den).Count -and @($ok).Count) {
            $findings.Add("[FAIL] SELECTIVE ACCESS on $h - OK: $((@($ok | ForEach-Object { $_.Share })) -join ', ')  |  DENIED: $((@($den | ForEach-Object { $_.Share })) -join ', ').")
            $findings.Add("[INFO] All shares on one server share ONE authenticated SMB session, so this is NOT name resolution and NOT the mapping - the identity in play lacks rights to the denied shares. Check the stored credential (cmdkey) and the server-side ACLs.")
        }
        elseif (@($den).Count) { $findings.Add("[FAIL] Access denied to ALL tested shares on $h - wrong/stale credentials, or the account has no rights.") }
        else { $findings.Add("[OK] All $(@($ok).Count) tested share(s) on $h are accessible.") }
        [pscustomobject]@{ TargetHost = $h; Shares = $rows.ToArray(); Findings = $findings.ToArray() } | ConvertTo-Json -Depth 5
    }
    Invoke-ScriptInUserSession -ScriptBlock $probe -Vars @{ HostName = $TargetHost; ExtraShareList = (@($ExtraShares) -join ';') } -User $User -TimeoutSec 60 -OnPoll $OnPoll
}

function Clear-HostSession {
    <#
    .SYNOPSIS
        Credential + session teardown for ONE host, in the user's session: delete
        stored credentials (name AND IP forms), drop every connection to that host,
        then verify nothing survived. A single surviving connection keeps the old
        identity alive, so the verify step matters.
    .PARAMETER Global
        Escalation: also `net use * /delete /y` (ALL servers) and `klist purge`.
    .PARAMETER DryRun
        Report what would be done + current connections; change nothing.
    .OUTPUTS
        .Data = { Log[]; Survivors[]; NetUse }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetHost,
        [string[]]$AlsoForms,
        [switch]$Global,
        [switch]$DryRun,
        [string]$User,
        [scriptblock]$OnPoll
    )
    $work = {
        $log = New-Object System.Collections.Generic.List[string]
        $forms = @(); foreach ($f in ($FormList -split ';')) { if ($f) { $forms += $f } }
        $forms = @($forms | Sort-Object -Unique)
        $log.Add("[INFO] Target host forms: $($forms -join ', ')")

        if ($DryRunMode) {
            foreach ($f in $forms) { $log.Add("[INFO] WhatIf: cmdkey /delete:$f  ;  net use \\$f\* /delete /y") }
            if ($GlobalMode) { $log.Add('[INFO] WhatIf: net use * /delete /y  ;  klist purge') }
            $cur = (& net use 2>&1 | Out-String)
            [pscustomobject]@{ Log = $log.ToArray(); Survivors = @(); NetUse = $cur; DryRun = $true } | ConvertTo-Json -Depth 5
            return
        }

        foreach ($f in $forms) {
            $o = (& cmdkey /delete:$f 2>&1 | Out-String)
            if ($o -match 'deleted successfully') { $log.Add("[OK] Removed stored credential for $f") } else { $log.Add("[INFO] No stored credential for $f") }
        }
        foreach ($f in $forms) {
            & net use "\\$f\*" /delete /y *>$null
            $log.Add("[OK] Dropped connections to \\$f (exit $LASTEXITCODE)")
        }
        if ($GlobalMode) {
            & net use * /delete /y *>$null
            $log.Add('[OK] Global: dropped ALL network connections (net use * /delete /y).')
            $kp = (& klist purge 2>&1 | Out-String)
            $log.Add("[OK] Kerberos ticket cache purged. $($kp.Trim())")
        }

        $cur = (& net use 2>&1 | Out-String)
        $surv = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($cur -split "`r?`n")) {
            foreach ($f in $forms) { if ($line -match "(?i)\\\\$([regex]::Escape($f))\\") { [void]$surv.Add($line.Trim()); break } }
        }
        if ($surv.Count) { $log.Add("[WARN] $($surv.Count) connection(s) to the host SURVIVED - the old identity is still alive. Escalate (global purge) or reboot before remapping.") }
        else { $log.Add('[OK] No connections to the host remain - a remap will authenticate cleanly.') }
        [pscustomobject]@{ Log = $log.ToArray(); Survivors = $surv.ToArray(); NetUse = $cur; DryRun = $false } | ConvertTo-Json -Depth 5
    }
    $forms = @($TargetHost) + @($AlsoForms)
    Invoke-ScriptInUserSession -ScriptBlock $work -Vars @{ FormList = (@($forms | Where-Object { $_ }) -join ';'); GlobalMode = [bool]$Global; DryRunMode = [bool]$DryRun } -User $User -TimeoutSec 60 -OnPoll $OnPoll
}

function Set-LinkedConnections {
    <#
    .SYNOPSIS
        Read or set HKLM EnableLinkedConnections, so drives mapped in a standard
        token are also visible to the elevated token (and vice-versa). Needs
        admin/SYSTEM. Takes effect after a reboot / LanmanWorkstation restart.
    #>
    [CmdletBinding()]
    param([switch]$Enable)
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $log = New-Object System.Collections.Generic.List[string]
    $before = $null
    try { $before = (Get-ItemProperty -Path $key -Name EnableLinkedConnections -ErrorAction Stop).EnableLinkedConnections } catch {}
    $log.Add("[INFO] EnableLinkedConnections currently: $(if ($null -eq $before) { '(not set)' } else { $before })")
    if (-not $Enable) { return [PSCustomObject]@{ Value = $before; Changed = $false; Log = $log.ToArray() } }
    if ($before -eq 1) { $log.Add('[OK] Already enabled - nothing to do.'); return [PSCustomObject]@{ Value = 1; Changed = $false; Log = $log.ToArray() } }
    try {
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name 'EnableLinkedConnections' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        $log.Add('[OK] EnableLinkedConnections = 1 set.')
        $log.Add('[INFO] Takes effect after a reboot (or a LanmanWorkstation restart).')
        return [PSCustomObject]@{ Value = 1; Changed = $true; Log = $log.ToArray() }
    } catch {
        $log.Add("[FAIL] Could not set (needs admin/SYSTEM): $($_.Exception.Message)")
        return [PSCustomObject]@{ Value = $before; Changed = $false; Log = $log.ToArray() }
    }
}

function Get-SmbClientEvents {
    <#
    .SYNOPSIS
        Recent SMB client session-setup / security-negotiation failures
        (Microsoft-Windows-SMBClient/Operational 30800/30803/31010) with NTLM
        SubStatus decoding - shows WHY the redirector rejected a connection.
    #>
    [CmdletBinding()]
    param([int]$MaxEvents = 8, [int]$Hours = 24)
    $log = New-Object System.Collections.Generic.List[string]
    $rows = New-Object System.Collections.Generic.List[object]
    $subStatus = @{
        '0xC000006A' = 'Incorrect password'
        '0xC0000064' = 'User does not exist'
        '0xC0000224' = 'User must change password at next logon'
        '0xC0000072' = 'Account is disabled'
        '0xC0000193' = 'Account has expired'
        '0xC0000234' = 'Account locked out'
        '0xC000006E' = 'Account restriction (e.g. forceguest / logon hours)'
        '0xC000015B' = 'Logon type not granted (network logon right)'
    }
    try {
        $since = (Get-Date).AddHours(-[Math]::Abs($Hours))
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-SMBClient/Operational'; Id=@(30800,30803,31010); StartTime=$since } -MaxEvents $MaxEvents -ErrorAction Stop)
        foreach ($e in $ev) {
            $msg = ("$($e.Message)" -replace '\s+', ' ').Trim()
            $code = $null
            if ($msg -match '(0xC0[0-9A-Fa-f]{6})') { $code = $Matches[1].ToUpper() }
            $meaning = if ($code -and $subStatus.ContainsKey($code)) { $subStatus[$code] } else { $null }
            $rows.Add([PSCustomObject]@{ Time=$e.TimeCreated; Id=$e.Id; Code=$code; Meaning=$meaning; Message=$msg })
            $log.Add("[WARN] $($e.TimeCreated) SMBClient $($e.Id)$(if($code){" $code"})$(if($meaning){" = $meaning"})")
        }
        if (@($ev).Count -eq 0) { $log.Add("[OK] No SMB client session/negotiation failures in the last $Hours h.") }
    } catch {
        # "No events were found..." is the healthy case, not a failure.
        if ("$($_.Exception.Message)" -match '(?i)no events were found') { $log.Add("[OK] No SMB client session/negotiation failures in the last $Hours h.") }
        else { $log.Add("[INFO] SMBClient/Operational log not readable ($($_.Exception.Message)) - needs elevation, or the log is disabled.") }
    }
    [PSCustomObject]@{ Events = $rows.ToArray(); Log = $log.ToArray() }
}

function New-UserFixerScript {
    <#
    .SYNOPSIS
        Generate the pre-filled USER companion .cmd: host-scoped teardown ->
        cmdkey /add with a PASSWORD PROMPT (never on the command line or in
        ScreenConnect scrollback) -> persistent remap of each drive -> verify.
        Run it IN the user's session (double-click, or hand it to the user).
    .DESCRIPTION
        Solves the two traps the GUI cannot: an injected task has no console to
        prompt for a password, and `net use /user:` alone does not survive a reboot.
    .PARAMETER Drives
        Objects/hashtables with Letter + Unc (Label optional).
    .OUTPUTS
        PSCustomObject { Path; LaunchLine; Content }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)]$Drives,
        [string]$CredUser,
        [string[]]$AlsoForms,
        [string]$Path
    )
    $forms = @(@($TargetHost) + @($AlsoForms) | Where-Object { $_ } | Sort-Object -Unique)
    $safeHost = ($TargetHost -replace '[\\/:*?"<>|]', '_')
    if (-not $Path) { $Path = Join-Path $script:DefaultBackupDir ("Fix-MyDrives-$safeHost.cmd") }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('@echo off')
    $L.Add('setlocal')
    $L.Add(":: Mapped Drive Toolkit v$script:ToolkitVersion - user companion fixer for $TargetHost")
    $L.Add(":: Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm'). RUN THIS AS THE AFFECTED USER (not as admin/SYSTEM):")
    $L.Add(':: mapped drives belong to the logon session that creates them.')
    $L.Add('echo ============================================================')
    $L.Add("echo  Repairing drives for $TargetHost")
    $L.Add('echo ============================================================')
    $L.Add('echo.')
    $L.Add('echo [1/4] Removing stored credentials and existing connections...')
    foreach ($f in $forms) { $L.Add("cmdkey /delete:$f >nul 2>&1") }
    foreach ($f in $forms) { $L.Add("net use `"\\$f\*`" /delete /y >nul 2>&1") }
    $L.Add('')
    $L.Add(':: A single surviving connection keeps the OLD identity alive for every share.')
    $L.Add('echo [2/4] Remaining connections (should list none for this server):')
    $L.Add('net use')
    $L.Add('echo.')
    $L.Add('echo [3/4] Saving the credential. You will be prompted for the password.')
    $L.Add(':: /pass with NO value prompts - the password never appears in the command line,')
    $L.Add(':: the script, or a remote-session scrollback.')
    if ($CredUser) { $L.Add("cmdkey /add:$TargetHost /user:$CredUser /pass") }
    else {
        $L.Add('set /p MDTUSER=Enter the username (e.g. DOMAIN\user or SERVER\user): ')
        $L.Add("cmdkey /add:$TargetHost /user:%MDTUSER% /pass")
    }
    $L.Add('')
    $L.Add('echo [4/4] Re-creating the drives (persistent)...')
    foreach ($d in @($Drives)) {
        $ltr = "$(Get-PropOrDefault $d 'Letter' (Get-PropOrDefault $d 'letter' ''))".TrimEnd(':').ToUpper()
        $unc = "$(Get-PropOrDefault $d 'Unc' (Get-PropOrDefault $d 'unc' ''))"
        if (-not $ltr -or -not $unc) { continue }
        $L.Add("net use ${ltr}: /delete /y >nul 2>&1")
        $L.Add("net use ${ltr}: `"$unc`" /persistent:yes")
    }
    $L.Add('')
    $L.Add('echo.')
    $L.Add('echo ---------------- VERIFY ----------------')
    $L.Add('net use')
    $L.Add('klist 2>nul | findstr /i "cifs"')
    $L.Add('echo.')
    $L.Add('echo IMPORTANT: reboot and re-check. "net use /user:" alone does NOT survive a')
    $L.Add('echo restart - only the saved credential above makes these drives stick.')
    $L.Add('echo.')
    $L.Add('pause')
    $content = ($L -join "`r`n")
    $content | Set-Content -LiteralPath $Path -Force -Encoding ASCII

    [PSCustomObject]@{
        Path       = $Path
        LaunchLine = ('cmd /c "' + $Path + '"')
        Content    = $content
    }
}

function Invoke-DriveAudit {
    <#
    .SYNOPSIS
        Comprehensive drive audit: Drive Doctor buckets + credential contamination
        + Kerberos + domain/DC health + DNS + per-share access matrix + linked
        connections + SMB client events, ranked into a report with a TOP FINDING.
    .OUTPUTS
        PSCustomObject { Report[]; Findings[]; TopFinding; ServerSideChecks[]; Hosts[] }
    #>
    [CmdletBinding()]
    param([string]$User, [scriptblock]$OnPoll)

    $rep = New-Object System.Collections.Generic.List[string]
    $fin = New-Object System.Collections.Generic.List[object]
    function Add-Fin { param([int]$Rank, [string]$Text) $fin.Add([PSCustomObject]@{ Rank=$Rank; Text=$Text }) }
    $poll = if ($OnPoll) { $OnPoll } else { {} }

    $rep.Add('================ MAPPED DRIVE FULL AUDIT ================')
    $rep.Add("Host: $env:COMPUTERNAME    Run: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')    Toolkit v$script:ToolkitVersion")
    if (-not $User) { $User = Get-InteractiveUser }
    $rep.Add("Interactive user: $(if ($User) { $User } else { '(none detected)' })")
    $rep.Add('')

    # --- 1. Drives + buckets ------------------------------------------------
    $rep.Add('--- Drives (4-layer state) ---')
    $hosts = New-Object System.Collections.Generic.List[string]
    $doc = Get-DriveDoctorReport -User $User -OnPoll $poll
    if ($doc.Success -and $doc.Data) {
        foreach ($d in @($doc.Data.Drives)) {
            $rep.Add(("  {0}: {1}  [bucket {2} - {3}]  ready={4} smb={5}" -f $d.Letter, $d.Unc, $d.Bucket, $d.BucketName, $d.IsReady, $d.InSmb))
            if ($d.Unc -and "$($d.Unc)" -match '^\\\\([^\\]+)\\') { [void]$hosts.Add($Matches[1]) }
            if ($d.Bucket -eq 3) { Add-Fin 20 "Drive $($d.Letter): is an orphaned GHOST (Error-85 class) - use Release ghost, then remap." }
            if ($d.Bucket -eq 2) { Add-Fin 40 "Drive $($d.Letter): looks cosmetic (Red-X / stale shell cache) - use Fix Red X." }
        }
        if (@($doc.Data.Drives).Count -eq 0) { $rep.Add('  (no network drives found in the user session)') }
        if ($doc.Data.EnableLinkedConnections -ne 1) {
            $rep.Add("  EnableLinkedConnections = $(if ($null -eq $doc.Data.EnableLinkedConnections) { '(not set)' } else { $doc.Data.EnableLinkedConnections })")
            Add-Fin 60 'EnableLinkedConnections is not 1 - drives mapped in the standard token are invisible to the elevated token (and vice-versa). "Fix linked" sets it (needs reboot).'
        }
    } else { $rep.Add("  [WARN] Drive probe failed: $($doc.Message)") }
    $rep.Add('')

    # --- 2. Credential audit (the big one) ---------------------------------
    $rep.Add('--- Credential Manager (identity actually used for SMB) ---')
    $cred = Get-CredentialAudit -User $User -OnPoll $poll
    if ($cred.Success -and $cred.Data) {
        foreach ($e in @($cred.Data.Entries)) {
            $mark = switch ("$($e.Severity)") { 'FAIL' { '   <-- WRONG IDENTITY' } 'WARN' { '   <-- not the logged-on user' } default { '' } }
            $rep.Add(("  {0,-24} -> {1}{2}" -f $e.TargetHost, $e.CredUser, $mark))
        }
        foreach ($f in @($cred.Data.Findings)) {
            $rep.Add("  $f")
            if ($f -match '^\[FAIL\]') { Add-Fin 10 ($f -replace '^\[FAIL\]\s*','') }
            elseif ($f -match '^\[WARN\]') { Add-Fin 50 ($f -replace '^\[WARN\]\s*','') }
        }
    } else { $rep.Add("  [WARN] Credential audit failed: $($cred.Message)") }
    $rep.Add('')

    # --- 3. Kerberos --------------------------------------------------------
    $rep.Add('--- Kerberos / NTLM fallback ---')
    $krb = Get-KerberosAudit -User $User -OnPoll $poll
    if ($krb.Success -and $krb.Data) {
        foreach ($f in @($krb.Data.Findings)) { $rep.Add("  $f"); if ($f -match '^\[WARN\]') { Add-Fin 25 ($f -replace '^\[WARN\]\s*','') } }
    } else { $rep.Add("  [WARN] Kerberos audit failed: $($krb.Message)") }
    $rep.Add('')

    # --- 4. Domain / DC -----------------------------------------------------
    $rep.Add('--- Domain / domain controller ---')
    $dom = Get-DomainHealth -User $User -OnPoll $poll
    if ($dom.Success -and $dom.Data) {
        foreach ($f in @($dom.Data.Findings)) {
            $rep.Add("  $f")
            if ($f -match '^\[FAIL\]') { Add-Fin 15 ($f -replace '^\[FAIL\]\s*','') }
            elseif ($f -match '^\[WARN\]') { Add-Fin 55 ($f -replace '^\[WARN\]\s*','') }
        }
    } else { $rep.Add("  [WARN] Domain audit failed: $($dom.Message)") }
    $rep.Add('')

    # --- 5. Per-host: DNS, connectivity, share matrix -----------------------
    $uniqueHosts = @($hosts | Sort-Object -Unique)
    foreach ($h in $uniqueHosts) {
        & $poll
        $rep.Add("--- Host: $h ---")
        try {
            $dns = Test-DnsHealth -HostOrUnc $h
            foreach ($f in @($dns.Findings)) {
                $rep.Add("  $f")
                if ($f -match '^\[FAIL\]') { Add-Fin 18 "DNS: $($f -replace '^\[FAIL\]\s*','')" }
                elseif ($f -match '^\[WARN\]') { Add-Fin 45 "DNS: $($f -replace '^\[WARN\]\s*','')" }
            }
        } catch { $rep.Add("  [WARN] DNS check error: $($_.Exception.Message)") }
        try {
            $conn = Test-ShareConnectivity -HostOrUnc $h
            $rep.Add("  Ping=$($conn.Pingable)  SMB445=$($conn.Smb445Open)  Dialect=$($conn.SmbDialect)")
            if (-not $conn.Smb445Open) { Add-Fin 12 "Host $h is not reachable on SMB 445 - nothing will map until that is fixed." }
        } catch {}
        & $poll
        try {
            $mtx = Test-ShareAccessMatrix -TargetHost $h -User $User -OnPoll $poll
            if ($mtx.Success -and $mtx.Data) {
                foreach ($r in @($mtx.Data.Shares)) { $rep.Add(("    {0,-20} {1}" -f $r.Share, $r.State)) }
                foreach ($f in @($mtx.Data.Findings)) {
                    $rep.Add("  $f")
                    if ($f -match 'SELECTIVE ACCESS') { Add-Fin 11 ($f -replace '^\[FAIL\]\s*','') }
                    elseif ($f -match '^\[FAIL\]') { Add-Fin 22 ($f -replace '^\[FAIL\]\s*','') }
                }
            }
        } catch { $rep.Add("  [WARN] Share matrix error: $($_.Exception.Message)") }
        $rep.Add('')
    }

    # --- 6. SMB client events ----------------------------------------------
    $rep.Add('--- SMB client events (session setup / negotiation) ---')
    $ev = Get-SmbClientEvents
    foreach ($l in @($ev.Log)) { $rep.Add("  $l"); if ($l -match '^\[WARN\]') { Add-Fin 35 ($l -replace '^\[WARN\]\s*','') } }
    $rep.Add('')

    # --- Ranked findings ----------------------------------------------------
    $ranked = @($fin | Sort-Object Rank)
    $top = if (@($ranked).Count) { $ranked[0].Text } else { $null }
    $rep.Add('================ FINDINGS (most likely first) ================')
    if (@($ranked).Count -eq 0) { $rep.Add('  [OK] No problems detected.') }
    else { $i = 0; foreach ($f in $ranked) { $i++; $rep.Add("  $i. $($f.Text)") } }
    $rep.Add('')
    if ($top) { $rep.Add("TOP FINDING: $top"); $rep.Add('') }

    # --- Server-side follow-ups (we cannot run these from the client) -------
    $srv = @(
        '# Run these ON THE FILE SERVER (elevated) if the client side looks clean:'
        'Get-SmbShare | Select-Object Name,Path'
        'Get-SmbShareAccess -Name <share1>,<share2> | Format-Table -AutoSize'
        '(Get-Acl "<local path of share>").Access | Format-Table IdentityReference,FileSystemRights,AccessControlType'
        '# Orphaned SIDs (unresolved S-1-5-21-... = AD objects deleted/recreated):'
        'Get-SmbShareAccess -Name <shares> | Where-Object { $_.AccountName -match "^S-1-5-21" }'
        '# Who is actually connecting, and as whom:'
        'Get-SmbSession | Select-Object ClientComputerName,ClientUserName,NumOpens | Format-Table -AutoSize'
        '# Failed network logons + NTLM SubStatus (0xC000006A=bad password, 0xC0000072=disabled,'
        '#  0xC0000224=must change password, 0xC0000193=expired, 0xC000006E=account restriction):'
        'Get-WinEvent -LogName Security -FilterXPath "*[System[EventID=4625]]" -MaxEvents 3 | Format-List TimeCreated,Message'
    )
    $rep.Add('================ SERVER-SIDE FOLLOW-UPS ================')
    foreach ($s in $srv) { $rep.Add("  $s") }

    [PSCustomObject]@{ Report = $rep.ToArray(); Findings = $ranked; TopFinding = $top; ServerSideChecks = $srv; Hosts = $uniqueHosts }
}

# endregion

Export-ModuleMember -Function `
    Get-UncHost, ConvertTo-NormalizedLetter, `
    ConvertFrom-DriveMapJson, ConvertTo-DriveMapJson, Select-ProfileDrives, Get-ProfileGroups, `
    Resolve-DriveTokens, New-MapDrivesCmdContent, Write-MapDrivesCmd, `
    Register-MapDrivesLogonTask, `
    Get-CurrentDriveMappings, Resolve-ShareDevice, `
    Get-DriveMappingState, Test-ShareConnectivity, Get-SmbClientHealth, `
    Get-InteractiveUser, Start-MapDrivesInjectionTask, Remove-MapDrivesInjectionTask, `
    Invoke-MapDrivesInUserSession, Invoke-CommandInUserSession, Invoke-DirInUserSession, `
    Test-DnsHealth, Test-DnsServer, Get-DnsServerHealth, `
    Test-ShareCredential, Clear-SavedCredential, Clear-NameCaches, Get-ToolkitVersion, `
    Invoke-ScriptInUserSession, Get-DriveDoctorReport, Repair-RedXCache, Clear-GhostDrive, Get-DriveOriginGpo, `
    Get-CredentialAudit, Get-KerberosAudit, Get-DomainHealth, Test-ShareAccessMatrix, `
    Clear-HostSession, Set-LinkedConnections, Get-SmbClientEvents, New-UserFixerScript, Invoke-DriveAudit, `
    Resolve-DriveCredentials, Get-InferredCredential, Invoke-MapDrivesNow
