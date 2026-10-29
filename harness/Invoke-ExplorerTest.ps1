<#
  Invoke-ExplorerTest.ps1
  Runner for the Explorer-driven cases, performed by an operator or by the
  automated driver.

  It is the same five-phase structure as Invoke-TimestampTest.ps1 -- fresh file
  per case, before snapshot, operations, after snapshot. Only phase 3 differs
  between the two drivers, so both perform the same cases on identically
  staged files and produce the same run.json, which Compare-Results.ps1 and
  New-ResultsReport.ps1 consume unchanged.

  -Driver Operator (default): RUN FROM THE GUEST CONSOLE. Each operation is
  bracketed by a prompt; the operator presses Enter immediately before and
  after acting.

  -Driver Automated: run over PowerShell Remoting, elevated, while the harness
  user is logged on at the console with the desktop unlocked. Phase 3 is
  handed to Invoke-ExplorerDriver.ps1, launched in the console session through
  a scheduled task with an interactive token, which performs each operation
  with real mouse and keyboard input. Do not use the console while it runs.
  The automated pass is an ADDITIONAL test, compared cell by cell with the
  manual passes (Compare-Runs.ps1); it does not replace them.

  RUN THIS ON A NON-INDEXED VOLUME. Windows Search updates $SI Access on files
  in indexed locations roughly a second after any change, which would be
  indistinguishable from an Explorer-caused update. V:, W: and X: are not in
  the default crawl scope; C:\Users\ is.
#>
[CmdletBinding()]
param(
    [string]$PrimaryVolume   = 'V:',
    [string]$SecondaryVolume = 'W:',
    [string]$WorkDir         = 'C:\NtfsTest\run',
    [string]$ToolRoot        = 'C:\NtfsTest\repo\tools',
    [string]$HarnessRoot     = 'C:\NtfsTest\repo\harness',
    # Pause before the after snapshots so a late read-only case has time for
    # its deferred Access write to land. The per-case live reads are the real
    # defence; this widens the margin.
    [int]$PostRunSettleSeconds = 180,

    [ValidateSet('Operator','Automated')]
    [string]$Driver          = 'Operator',
    # Automated only: pause between cases. An operator's cases were 30 s to
    # several minutes apart; this keeps one case's background Explorer work
    # from running into the next case's window.
    [int]$CaseGapSeconds     = 20,
    # Automated only: abandon the driver after this long. 0 = derive from the
    # number of cases.
    [int]$DriverTimeoutMinutes = 0,

    [string]$RunLabel,
    [string[]]$OnlyCases
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $HarnessRoot 'NtfsTimestamps.psm1') -Force
Import-Module (Join-Path $HarnessRoot 'Operations.psm1') -Force
Import-Module (Join-Path $HarnessRoot 'Capture.psm1')    -Force

if (-not $RunLabel) {
    $prefix = if ($Driver -eq 'Automated') { 'explorerauto_' } else { 'explorer_' }
    $RunLabel = $prefix + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
}

$consoleUser = $null
if ($Driver -eq 'Operator') {
    if (-not [Environment]::UserInteractive) {
        throw 'Not an interactive session. Run this from the guest console, not over PowerShell Remoting -- or use -Driver Automated.'
    }
} else {
    # The driver needs a desktop to act on: a user logged on at the console,
    # with the session unlocked. Checked before anything is staged.
    $consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $consoleUser) { throw 'No user is logged on at the console. Log on as the harness user (or configure auto-logon) and re-run.' }
    if (Get-Process -Name LogonUI -ErrorAction SilentlyContinue) { throw "The console session ($consoleUser) is locked. Unlock it and disable the lock-screen timeout for the run." }
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
        throw 'Not elevated. The $MFT snapshots need raw volume access.'
    }
    $driverScript = Join-Path $HarnessRoot 'Invoke-ExplorerDriver.ps1'
    if (-not (Test-Path -LiteralPath $driverScript)) { throw "Driver not found: $driverScript" }
}

$runDir = Join-Path $WorkDir $RunLabel
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

# Operation ids match the automated matrix so results compare against the same
# baselines; mechanisms are explorer_* so they never blend into the CLI rules.
$Cases = @(
    @{ Id='01'; Op='file_access';      Mech='explorer_browse';          NeedsDest=$false
       What='SELECT the file once in Explorer (single click). Do not open it.'
       Why='Control: does merely browsing/selecting update Access?' }

    @{ Id='02'; Op='file_access';      Mech='explorer_open';            NeedsDest=$false
       What='DOUBLE-CLICK the file to open it in Notepad, then close Notepad.'
       Why='The commonest real-world "user accessed a file".' }

    @{ Id='03'; Op='file_rename';      Mech='explorer_rename';          NeedsDest=$false
       What='Press F2 and rename the file to  renamed_explorer_<caseid>.txt'
       Why='CLI rename does not update Access on 25H2. Does Explorer differ?' }

    @{ Id='04'; Op='file_copy';        Mech='explorer_copy';            NeedsDest=$true;  DestVolume='primary'
       What='Ctrl+C on the file, then Ctrl+V in the DESTINATION folder.'
       Why='Baseline Explorer copy, same volume.' }

    @{ Id='05'; Op='file_move_local';  Mech='explorer_cutpaste';        NeedsDest=$true;  DestVolume='primary'
       What='Ctrl+X on the file, then Ctrl+V in the DESTINATION folder.'
       Why='Explorer move within one volume.' }

    @{ Id='06'; Op='file_move_local';  Mech='explorer_drag';            NeedsDest=$true;  DestVolume='primary'
       What='DRAG the file to the DESTINATION folder. Same volume, so this moves.'
       Why='Does drag differ from cut/paste?' }

    @{ Id='07'; Op='file_move_volume'; Mech='explorer_cutpaste';        NeedsDest=$true;  DestVolume='secondary'
       What='Ctrl+X on the file, then Ctrl+V in the DESTINATION folder on the OTHER volume.'
       Why='THE CRITICAL CASE. The 22H2 charts show $SI Creation INHERITED here but set to move time via CLI -- the only cell where mechanism changes the answer.' }

    @{ Id='08'; Op='file_move_volume'; Mech='explorer_dragshift';       NeedsDest=$true;  DestVolume='secondary'
       What='Hold SHIFT and DRAG the file to the DESTINATION folder on the OTHER volume (Shift forces a move).'
       Why='Cross-volume drag defaults to COPY; Shift forces a move. Does it match cut/paste?' }

    @{ Id='09'; Op='file_copy';        Mech='explorer_dragcrossvol';    NeedsDest=$true;  DestVolume='secondary'
       What='DRAG the file to the DESTINATION folder on the OTHER volume, WITHOUT Shift. This copies.'
       Why='Cross-volume drag is a copy. Does it match a same-volume copy?' }

    @{ Id='10'; Op='file_delete';      Mech='explorer_recycle';         NeedsDest=$false
       What='Press DELETE (not Shift+Delete). The file goes to the Recycle Bin.'
       Why='Recycle is a move into $Recycle.Bin plus a rename to $R... -- NOT the same as shift+delete.' }

    @{ Id='11'; Op='file_delete';      Mech='explorer_shiftdelete';     NeedsDest=$false
       What='Press SHIFT+DELETE and confirm. Permanent delete.'
       Why='Should match the CLI delete rules.' }
)

if ($OnlyCases) { $Cases = @($Cases | Where-Object { $_.Id -in $OnlyCases }) }

# ----------------------------------------------------------- PHASE 1: SETUP
Write-Host "`n=== PHASE 1: staging $($Cases.Count) cases ===" -ForegroundColor Cyan
$staged = New-Object Collections.Generic.List[object]
foreach ($c in $Cases) {
    $dir = New-CaseDirectory -Root ($PrimaryVolume + '\')
    $cr  = Invoke-OpCreate -Directory $dir -Mechanism powershell
    $dest = $null
    if ($c.NeedsDest) {
        $root = if ($c.DestVolume -eq 'secondary') { $SecondaryVolume + '\' } else { $PrimaryVolume + '\' }
        $dest = New-CaseDirectory -Root $root
    }
    $staged.Add([pscustomobject]@{
        CaseId     = "$($c.Id)_$($c.Op)_$($c.Mech)"
        Operation  = $c.Op
        Mechanism  = $c.Mech
        Variant    = 'normal'
        SourcePath = $cr.PathAfter
        SourceName = Split-Path -Leaf $cr.PathAfter
        DestDir    = $dest
        What       = $c.What
        Why        = $c.Why
        Result     = $null
    })
}
Write-Host "  staged. Letting creation timestamps settle..."
Start-Sleep -Seconds 20

# ---------------------------------------------------------- PHASE 2: BEFORE
Write-Host "`n=== PHASE 2: before snapshots ===" -ForegroundColor Cyan
$volumes = @($PrimaryVolume, $SecondaryVolume) | Select-Object -Unique
$before = @{}
foreach ($v in $volumes) {
    $before[$v] = Get-MftSnapshot -Volume $v -WorkDir $runDir -ToolRoot $ToolRoot -HarnessRoot $HarnessRoot -Label 'before'
    Write-Host "  $v  $($before[$v].ToolCounts)"
}

# Entry numbers let a case be found again even when Explorer changes its name
# unpredictably -- the Recycle Bin renames to $R<random>.<ext>, which no
# name-based lookup can anticipate.
foreach ($c in $staged) {
    $rec = @($before[$PrimaryVolume].Records |
             Where-Object { $_.Tool -eq 'MFTECmd' -and $_.FileName -eq $c.SourceName })[0]
    $c | Add-Member -NotePropertyName SourceEntryNumber -NotePropertyValue $(if ($rec) { $rec.EntryNumber } else { $null }) -Force
}

# ---------------------------------------------------------- PHASE 3: ACTIONS
$automation = $null
if ($Driver -eq 'Operator') {
Write-Host "`n=== PHASE 3: perform each operation in Explorer ===" -ForegroundColor Cyan
Write-Host "Press Enter immediately BEFORE acting, and again immediately AFTER." -ForegroundColor Yellow
Write-Host "Type s then Enter to skip a case.`n" -ForegroundColor Yellow

foreach ($c in $staged) {
    Write-Host ("-" * 78)
    Write-Host "CASE $($c.CaseId)" -ForegroundColor Green
    Write-Host "  why    : $($c.Why)"
    Write-Host "  file   : $($c.SourcePath)"
    if ($c.DestDir) { Write-Host "  dest   : $($c.DestDir)" }
    Write-Host "  ACTION : $($c.What)" -ForegroundColor Cyan

    $go = Read-Host "`n  Enter to START (or 's' to skip)"
    if ($go -eq 's') {
        $c.Result = [pscustomobject]@{ OpStartUtc=$null; OpEndUtc=$null; PathAfter=$null; NameAfter=$null; Error='skipped by operator' }
        Write-Host "  skipped" -ForegroundColor DarkGray
        continue
    }
    $start = (Get-Date).ToUniversalTime()
    Read-Host "  ...perform the action now, then press Enter" | Out-Null
    $end = (Get-Date).ToUniversalTime()

    # Resolve where the file ended up. Explorer may have renamed or moved it,
    # so ask rather than guess; blank means "unchanged / not applicable".
    $newPath = Read-Host "  Full path of the file now (Enter if unchanged, 'gone' if deleted)"
    # Explorer's "Copy as path" wraps the path in double quotes. Taken
    # literally, the trailing quote becomes part of the filename and every
    # lookup for that case fails.
    $newPath = "$newPath".Trim().Trim('"').Trim("'")
    $pathAfter = if ([string]::IsNullOrWhiteSpace($newPath)) {
                     if ($c.DestDir) { Join-Path $c.DestDir $c.SourceName } else { $c.SourcePath }
                 } elseif ($newPath -eq 'gone') { $null } else { $newPath }

    # Live $SI straight from the in-memory record. NTFS defers writing an
    # Access update to the $MFT and a flush cannot force it out, so an
    # $MFT-only capture can read as "did not change" when a write is merely
    # pending. This read cannot be stale. It matters most for cases 01 and 02,
    # whose whole finding is about Access.
    $live = $null
    if ($pathAfter -and (Test-Path -LiteralPath $pathAfter)) {
        try { $live = Get-SiTimestamp -Path $pathAfter } catch { }
    }

    $c.Result = [pscustomobject]@{
        OpStartUtc = $start
        OpEndUtc   = $end
        PathAfter  = $pathAfter
        NameAfter  = if ($pathAfter) { Split-Path -Leaf $pathAfter } else { $null }
        LiveSI     = if ($live) {
                         [pscustomobject]@{
                             Created       = $live.Creation.ToString('o')
                             Modified      = $live.Modified.ToString('o')
                             Access        = $live.Access.ToString('o')
                             EntryModified = $live.MftEntryModified.ToString('o')
                         }
                     } else { $null }
        Error      = $null
    }
    Write-Host ("  recorded: {0:HH:mm:ss.fff} -> {1:HH:mm:ss.fff} UTC" -f $start, $end) -ForegroundColor DarkGray
}
} else {
    Write-Host "`n=== PHASE 3: automated driver in $consoleUser's desktop session ===" -ForegroundColor Cyan
    Write-Host "Do not use the console until the driver finishes." -ForegroundColor Yellow

    # Exchange directory, written by the driver as the console user, so
    # that user is granted write access to it explicitly.
    $autoDir = Join-Path $runDir 'automation'
    New-Item -ItemType Directory -Force -Path $autoDir | Out-Null
    & icacls.exe $autoDir /grant "${consoleUser}:(OI)(CI)M" | Out-Null
    $manifestPath = Join-Path $autoDir 'manifest.json'
    $resultPath   = Join-Path $autoDir 'driver-result.json'
    $logPath      = Join-Path $autoDir 'driver.log'
    Remove-Item -LiteralPath $resultPath, $logPath -Force -ErrorAction SilentlyContinue

    [pscustomobject]@{
        RunLabel       = $RunLabel
        ResultFile     = $resultPath
        LogFile        = $logPath
        CaseGapSeconds = $CaseGapSeconds
        # Same naming as the operator instruction for case 03.
        RenameBase     = "renamed_explorer_$RunLabel"
        Cases          = @($staged | ForEach-Object {
                             [pscustomobject]@{ CaseId=$_.CaseId; Operation=$_.Operation; Mechanism=$_.Mechanism
                                                SourcePath=$_.SourcePath; SourceName=$_.SourceName; DestDir=$_.DestDir } })
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $timeoutMin = $DriverTimeoutMinutes
    if ($timeoutMin -le 0) {
        $perCase = [double]($CaseGapSeconds + 90)
        $timeoutMin = [int][Math]::Ceiling($staged.Count * $perCase / 60.0) + 5
    }

    # LogonType Interactive runs the task in the user's existing desktop
    # session with their own token; no password is stored.
    # RunLevel Highest is required, not a convenience: Windows silently drops
    # injected input and refuses SetCursorPos while a higher-integrity window
    # has focus (UIPI), and an elevated console is routinely left open on a
    # test VM. The driver's elevation does not reach the operations -- they
    # are performed by the user's existing, unelevated explorer.exe, and any
    # application it launches inherits that.
    # conhost --headless hosts the console without ever showing a window, so
    # nothing steals focus or covers the Explorer windows.
    $taskPath = '\NtfsTimestamps\'
    $taskName = "ExplorerDriver_$RunLabel"
    $psExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action   = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') `
                    -Argument ("--headless `"$psExe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$driverScript`" -Manifest `"$manifestPath`"")
    $principal = New-ScheduledTaskPrincipal -UserId $consoleUser -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes $timeoutMin) -Priority 4
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

    $shown = 0
    $relay = {
        $lines = @()
        try { $lines = @(Get-Content -LiteralPath $logPath -ErrorAction Stop) } catch { }
        for ($i = $shown; $i -lt $lines.Count; $i++) { Write-Host "  [driver] $($lines[$i])" -ForegroundColor DarkGray }
        if ($lines.Count -gt $shown) { $shown = $lines.Count }
    }
    try {
        Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $resultPath)) {
            Start-Sleep -Seconds 2
            . $relay
            $state = (Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName).State
            if ($clock.Elapsed.TotalSeconds -gt 60 -and -not (Test-Path -LiteralPath $logPath)) {
                throw "The driver produced no log within 60 s (task state: $state). Check that $consoleUser is logged on at the console and can run $driverScript."
            }
            if ($clock.Elapsed.TotalSeconds -gt 10 -and $state -ne 'Running' -and -not (Test-Path -LiteralPath $resultPath)) {
                Start-Sleep -Seconds 2
                if (-not (Test-Path -LiteralPath $resultPath)) {
                    $last = (Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $taskName).LastTaskResult
                    throw ("The driver exited without writing results (task result 0x{0:x}). Partial results, if any: {1}.partial" -f $last, $resultPath)
                }
            }
            if ($clock.Elapsed.TotalMinutes -gt $timeoutMin) {
                Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
                throw "The driver did not finish within $timeoutMin minutes and was stopped."
            }
        }
        . $relay
    } finally {
        Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    $drv = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
    $byId = @{}
    foreach ($r in @($drv.Cases)) { $byId["$($r.CaseId)"] = $r }
    foreach ($c in $staged) {
        $r = $byId["$($c.CaseId)"]
        if (-not $r) {
            $c.Result = [pscustomobject]@{ OpStartUtc=$null; OpEndUtc=$null; PathAfter=$null; NameAfter=$null; Error='not performed by the driver' }
            continue
        }
        $c.Result = [pscustomobject]@{
            OpStartUtc = $r.OpStartUtc
            OpEndUtc   = $r.OpEndUtc
            PathAfter  = $r.PathAfter
            NameAfter  = $r.NameAfter
            LiveSI     = $r.LiveSI
            Error      = $r.Error
            Automation = [pscustomobject]@{ ViewMode=$r.ViewMode; Steps=@($r.Steps) }
        }
        if ($r.Error) {
            Write-Host ("  {0}  FAILED  {1}" -f $c.CaseId, $r.Error) -ForegroundColor Yellow
        } else {
            $w = ((Get-Date $r.OpEndUtc) - (Get-Date $r.OpStartUtc)).TotalSeconds
            Write-Host ("  {0}  ok  window {1:N2} s" -f $c.CaseId, $w) -ForegroundColor DarkGray
        }
    }
    $automation = [pscustomobject]@{
        Driver      = 'Invoke-ExplorerDriver.ps1'
        TaskUser    = $consoleUser
        Context     = $drv.Context
        StartedUtc  = $drv.StartedUtc
        CompletedUtc= $drv.CompletedUtc
    }
}

# ----------------------------------------------------------- PHASE 4: AFTER
if ($PostRunSettleSeconds -gt 0) {
    Write-Host "`nSettling $PostRunSettleSeconds s before the after snapshots..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PostRunSettleSeconds
}

Write-Host "`n=== PHASE 4: after snapshots ===" -ForegroundColor Cyan
$after = @{}
foreach ($v in $volumes) {
    $after[$v] = Get-MftSnapshot -Volume $v -WorkDir $runDir -ToolRoot $ToolRoot -HarnessRoot $HarnessRoot -Label 'after'
    Write-Host "  $v  $($after[$v].ToolCounts)"
}

# ------------------------------------------------------------------- EMIT
# Keep records matching a case by name OR by the entry number captured before
# the manual phase -- the Recycle Bin case has no predictable name afterwards.
$caseNames   = @{}
$caseEntries = @{}
foreach ($c in $staged) {
    if ($c.SourceName)              { $caseNames["$($c.SourceName)"] = $true }
    if ($c.Result.NameAfter)        { $caseNames["$($c.Result.NameAfter)"] = $true }
    if ($null -ne $c.SourceEntryNumber) { $caseEntries["$($c.SourceEntryNumber)"] = $true }
}
function Select-CaseRecords {
    param($Records)
    @($Records | Where-Object { $caseNames.ContainsKey("$($_.FileName)") -or $caseEntries.ContainsKey("$($_.EntryNumber)") })
}

$out = [pscustomobject]@{
    RunLabel        = $RunLabel
    Driver          = $Driver.ToLowerInvariant()
    Harness         = Get-HarnessProvenance -RepoRoot (Split-Path -Parent $HarnessRoot)
    Automation      = $automation
    Interactive     = $true
    CompletedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    PrimaryVolume   = $PrimaryVolume
    SecondaryVolume = $SecondaryVolume
    SettleSeconds   = 20
    LateCaptureMinutes = 0
    Cases           = $staged
    Snapshots       = @{
        Before = @($volumes | ForEach-Object { @{ Volume=$_; Sha256=$before[$_].MftSha256; Records=(Select-CaseRecords $before[$_].Records) } })
        After  = @($volumes | ForEach-Object { @{ Volume=$_; Sha256=$after[$_].MftSha256;  Records=(Select-CaseRecords $after[$_].Records)  } })
        Late   = @()
    }
}
$jsonPath = Join-Path $runDir 'run.json'
$out | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$done    = @($staged | Where-Object { -not $_.Result.Error })
$skipped = @($staged | Where-Object { $_.Result.Error })
$notDone = if ($Driver -eq 'Automated') { 'failed self-check' } else { 'skipped' }
Write-Host "`nComplete: $($done.Count) performed, $($skipped.Count) $notDone"
Write-Host "  $jsonPath"
Write-Host "`nNext:" -ForegroundColor Cyan
Write-Host "  .\harness\Compare-Results.ps1 -RunJson '$jsonPath'"

[pscustomobject]@{ RunLabel=$RunLabel; RunDir=$runDir; JsonPath=$jsonPath; Performed=$done.Count; Skipped=$skipped.Count }
