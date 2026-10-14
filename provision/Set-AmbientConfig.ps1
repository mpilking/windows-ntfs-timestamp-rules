<#
  Set-AmbientConfig.ps1
  Puts the guest into a declared, recorded ambient state before a run.

  CleanRoom mode deliberately uses Defender *exclusions* rather than disabling
  real-time protection: the service keeps running, so the machine stays in a
  normal Windows state, while the test volumes are removed from the
  experimental path. "We disabled security" is both less realistic and harder
  to defend in published methodology than "we scoped the scanner away from the
  test volumes."

  RealisticBaseline mode removes those exclusions so the noise floor of a stock
  install can be measured against the clean-room results.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('CleanRoom','RealisticBaseline')]
    [string]$Mode = 'CleanRoom',

    [string[]]$TestVolumes = @('V:\','W:\','X:\'),

    # The two modes are NOT inverses of each other. CleanRoom adds exclusions
    # AND stops OneDrive/WSearch; RealisticBaseline removes exclusions AND
    # restarts WSearch. Using RealisticBaseline merely to drop one exclusion
    # therefore also restarts the indexer, silently contaminating the next
    # clean-room run. -ExclusionsOnly confines the call to exclusion handling
    # and leaves every service as it found it.
    [switch]$ExclusionsOnly,

    [ValidateSet('Enabled','Disabled','LeaveAsIs')]
    [string]$LastAccess = 'LeaveAsIs',

    [ValidateSet('Default','Disabled','LeaveAsIs')]
    [string]$Tunneling = 'LeaveAsIs'
)

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
    throw 'Must run elevated.'
}

$fsKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$actions = New-Object Collections.Generic.List[object]
function Note { param($Item,$Action,$Detail) $actions.Add([pscustomobject]@{Item=$Item;Action=$Action;Detail=$Detail}) }

# ---------------------------------------------------------------- Defender
try {
    $existing = @((Get-MpPreference).ExclusionPath)
    if ($Mode -eq 'CleanRoom') {
        foreach ($v in $TestVolumes) {
            if ($existing -notcontains $v) {
                if ($PSCmdlet.ShouldProcess($v,'Add Defender exclusion')) { Add-MpPreference -ExclusionPath $v }
                Note 'Defender' 'ExclusionAdded' $v
            } else { Note 'Defender' 'ExclusionAlreadyPresent' $v }
        }
    } else {
        foreach ($v in $TestVolumes) {
            if ($existing -contains $v) {
                if ($PSCmdlet.ShouldProcess($v,'Remove Defender exclusion')) { Remove-MpPreference -ExclusionPath $v }
                Note 'Defender' 'ExclusionRemoved' $v
            }
        }
    }
    $rt = (Get-MpComputerStatus).RealTimeProtectionEnabled
    Note 'Defender' 'RealTimeProtection' "$rt (intentionally left ON)"
} catch {
    Note 'Defender' 'ERROR' $_.Exception.Message
}

# ------------------------------------------------------------------ OneDrive
# A lab VM has no legitimate need for a sync client, and a sync engine can
# rewrite timestamps after the fact. Stopped, not uninstalled, so the change is
# reversible and visible in the fingerprint.
$od = Get-Process OneDrive -ErrorAction SilentlyContinue
if ($ExclusionsOnly) {
    Note 'OneDrive' 'Skipped' '-ExclusionsOnly'
    Note 'WSearch'  'Skipped' '-ExclusionsOnly'
} elseif ($od -and $Mode -eq 'CleanRoom') {
    if ($PSCmdlet.ShouldProcess('OneDrive','Stop process')) { $od | Stop-Process -Force }
    Note 'OneDrive' 'Stopped' "$($od.Count) process(es)"
} else {
    Note 'OneDrive' 'NoAction' "running=$([bool]$od) mode=$Mode"
}

# ------------------------------------------------------------- Search indexer
# Freshly created VHDX volumes are not normally in the default crawl scope, so
# this is belt-and-suspenders rather than the primary control.
$ws = Get-Service WSearch -ErrorAction SilentlyContinue
if ($ws -and -not $ExclusionsOnly) {
    if ($Mode -eq 'CleanRoom' -and $ws.Status -eq 'Running') {
        if ($PSCmdlet.ShouldProcess('WSearch','Stop service')) { Stop-Service WSearch -Force }
        Note 'WSearch' 'Stopped' 'was Running'
    } elseif ($Mode -eq 'RealisticBaseline' -and $ws.Status -ne 'Running') {
        # A deliberately DISABLED service cannot be started, and that is a valid
        # experimental condition (isolating the indexer as a cause). Failing the
        # whole run over it would make the control impossible to express.
        if ($PSCmdlet.ShouldProcess('WSearch','Start service')) {
            try   { Start-Service WSearch -ErrorAction Stop; Note 'WSearch' 'Started' 'realistic baseline default state' }
            catch { Note 'WSearch' 'StartFailed' "left as-is: $($_.Exception.Message -replace '\s+',' ')" }
        }
    } else {
        Note 'WSearch' 'NoAction' $ws.Status
    }
}

# ------------------------------------------------------- Last access updating
# 0 = enabled (user managed), 1 = disabled (user managed),
# 2 = system managed enabled, 3 = system managed disabled.
if ($LastAccess -ne 'LeaveAsIs') {
    $val = if ($LastAccess -eq 'Enabled') { 0 } else { 1 }
    if ($PSCmdlet.ShouldProcess("disablelastaccess=$val","fsutil behavior set")) {
        & fsutil.exe behavior set disablelastaccess $val | Out-Null
    }
    Note 'LastAccess' 'Set' "$LastAccess (disablelastaccess=$val) - REBOOT REQUIRED"
}

# ------------------------------------------------------------- File tunneling
# Absent values mean the default (~15s, enabled). Setting the age to 0 disables
# tunneling; removing the values restores the default.
if ($Tunneling -ne 'LeaveAsIs') {
    if ($Tunneling -eq 'Disabled') {
        if ($PSCmdlet.ShouldProcess('MaximumTunnelEntryAgeInSeconds=0','Set registry')) {
            New-ItemProperty -Path $fsKey -Name 'MaximumTunnelEntryAgeInSeconds' -Value 0 -PropertyType DWord -Force | Out-Null
        }
        Note 'Tunneling' 'Disabled' 'MaximumTunnelEntryAgeInSeconds=0 - REBOOT REQUIRED'
    } else {
        if ($PSCmdlet.ShouldProcess('MaximumTunnelEntryAgeInSeconds','Remove registry value')) {
            Remove-ItemProperty -Path $fsKey -Name 'MaximumTunnelEntryAgeInSeconds' -ErrorAction SilentlyContinue
        }
        Note 'Tunneling' 'Default' 'registry value removed (~15s) - REBOOT REQUIRED'
    }
}

Write-Host "Mode: $Mode"
$actions | Format-Table Item, Action, Detail -AutoSize

if ($actions | Where-Object Detail -match 'REBOOT REQUIRED') {
    Write-Warning 'Filesystem behaviour changes require a reboot before they take effect. Reboot, then re-run Get-EnvironmentFingerprint.ps1 to confirm.'
}
$actions
