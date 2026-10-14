<#
  Invoke-ExplorerTest.ps1
  Interactive runner for the Explorer-driven cases.

  MUST BE RUN FROM THE GUEST CONSOLE. Explorer operations need an interactive
  desktop session; PowerShell Remoting and PowerShell Direct are both
  non-interactive, so shell automation does not work over them. This is the one
  part of the study a human performs by hand.

  It is the same five-phase structure as Invoke-TimestampTest.ps1 -- fresh file
  per case, before snapshot, operations, after snapshot -- with one difference:
  each operation is bracketed by a prompt instead of a script call. Press Enter
  immediately before and after each action and the measured window is as tight
  as the automated runs.

  Output is written in the same run.json format, so Compare-Results.ps1 and
  New-ResultsReport.ps1 consume it unchanged.

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

    [string]$RunLabel        = ('explorer_' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')),
    [string[]]$OnlyCases
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $HarnessRoot 'NtfsTimestamps.psm1') -Force
Import-Module (Join-Path $HarnessRoot 'Operations.psm1') -Force
Import-Module (Join-Path $HarnessRoot 'Capture.psm1')    -Force

if (-not [Environment]::UserInteractive) {
    throw 'Not an interactive session. Run this from the guest console, not over PowerShell Remoting.'
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

# --------------------------------------------------- PHASE 3: MANUAL ACTIONS
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
Write-Host "`nComplete: $($done.Count) performed, $($skipped.Count) skipped"
Write-Host "  $jsonPath"
Write-Host "`nNext:" -ForegroundColor Cyan
Write-Host "  .\harness\Compare-Results.ps1 -RunJson '$jsonPath'"

[pscustomobject]@{ RunLabel=$RunLabel; RunDir=$runDir; JsonPath=$jsonPath; Performed=$done.Count; Skipped=$skipped.Count }
