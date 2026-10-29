<#
  Invoke-TimestampTest.ps1
  Executes the operation x mechanism x variant matrix and records before/after
  MFT state for every case.

  FOUR PHASES, in this order for reasons that are not stylistic:

    1 SETUP    Create one uniquely named file per case in its own uniquely
               named directory. Apply the timestomp precondition to the
               'stomped' variant.
    2 BEFORE   One $MFT snapshot per volume. Two extractions per volume for the
               whole run instead of two per case -- the per-case cost would be
               prohibitive and buys nothing, since nothing mutates between
               setup and execute.
    3 EXECUTE  Perform each case's operation, spaced so tolerance windows cannot
               overlap. DELETE CASES RUN LAST: deleted MFT records are recycled
               by the next file created, so a copy executed afterwards could
               overwrite the very record a delete case needs read.
    4 AFTER    One $MFT snapshot per volume.

  TWO VARIANTS, TWO DIFFERENT QUESTIONS -- do not conflate them:

    'normal'       A file created and operated on conventionally. This is the
                   PRIMARY result set and the one the published rule tables are
                   built from. It answers: what does an analyst actually see on
                   an ordinary system?

    'timestomped'  $SI is forced to distinct historical values before the
                   operation. This is a SEPARATE finding set answering a
                   different question: how does prior timestomping change what
                   a subsequent operation produces?

  The timestomped variant also happens to expose mechanism that the normal
  variant cannot. On a normally created file $SI and $FN hold identical values,
  so "$FN was copied from $SI" and "$FN did not change" produce identical
  observations. That is a limit of what is OBSERVABLE normally, not a defect in
  the normal result -- and a mechanism revealed only under timestomping must be
  reported as mechanism, never folded into the normal rule table.
#>
[CmdletBinding()]
param(
    [string]$PrimaryVolume   = 'V:',
    [string]$SecondaryVolume = 'W:',
    [string]$WorkDir         = 'C:\NtfsTest\run',
    [string]$ToolRoot        = 'C:\NtfsTest\repo\tools',
    [string]$HarnessRoot     = 'C:\NtfsTest\repo\harness',
    [int]$SettleSeconds      = 10,
    [ValidateSet('normal','timestomped','both')][string]$Variant = 'both',
    [string[]]$OnlyOperations,   # e.g. 'file_rename','file_copy' -- for pilot runs
    [string[]]$OnlyMechanisms,

    # Optional PHASE 5. NTFS defers a last-access update when the existing
    # value is less than ~1 hour old, so a value that looks unchanged may
    # simply not have been written yet. Re-snapshotting after a delay longer
    # than that window distinguishes "never updated" from "not yet updated".
    # Use 65+ to clear the hour. The stomped variant largely obviates this --
    # stomping to a historical value puts it outside the deferral window and
    # forces an update if one is going to happen -- so this is confirmation,
    # not the primary control.
    [int]$LateCaptureMinutes = 0,

    # Where case directories are created. Defaults to the volume root, which is
    # what the VHDX test volumes use. Point it at a subdirectory when testing a
    # volume that cannot be excluded from scanning wholesale -- a system volume,
    # for example, where excluding the entire drive is both heavy-handed and
    # indistinguishable from malware behaviour to AV heuristics. Path depth does
    # not affect timestamp rules, so results remain comparable.
    [string]$CaseRoot,
    [string]$SecondaryCaseRoot,

    # Pause between the last operation and the after snapshots, so a late
    # read-only case has time for its deferred Access write to land.
    [int]$PostRunSettleSeconds = 180,

    [string]$RunLabel        = ('run_' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $HarnessRoot 'NtfsTimestamps.psm1') -Force
Import-Module (Join-Path $HarnessRoot 'Operations.psm1')     -Force
Import-Module (Join-Path $HarnessRoot 'Capture.psm1')        -Force

$runDir = Join-Path $WorkDir $RunLabel
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$primaryRoot   = if ($CaseRoot)          { $CaseRoot }          else { $PrimaryVolume + '\' }
$secondaryRoot = if ($SecondaryCaseRoot) { $SecondaryCaseRoot } else { $SecondaryVolume + '\' }
foreach ($r in @($primaryRoot, $secondaryRoot)) {
    # A drive root ("V:\") already exists and cannot be created -- New-Item
    # rejects it with "The path is not of a legal form."
    if ($r -match '^[A-Za-z]:\\?$') { continue }
    if (-not (Test-Path -LiteralPath $r)) { New-Item -ItemType Directory -Force -Path $r | Out-Null }
}
Write-Host "Case roots: primary=$primaryRoot  secondary=$secondaryRoot"

# Deliberately distinct values so every field is individually attributable.
# If $FN Modified came from $SI Modified we see 02-02, not 01-01.
$Stomp = @{
    Creation         = [datetime]::SpecifyKind('2019-01-01T01:01:01',[DateTimeKind]::Utc)
    Modified         = [datetime]::SpecifyKind('2019-02-02T02:02:02',[DateTimeKind]::Utc)
    Access           = [datetime]::SpecifyKind('2019-03-03T03:03:03',[DateTimeKind]::Utc)
    MftEntryModified = [datetime]::SpecifyKind('2019-04-04T04:04:04',[DateTimeKind]::Utc)
}

$Matrix = @(
    @{ Op='file_create';      Mechs=@('powershell','dotnet','cmd_echo','fsutil') }
    @{ Op='file_access';      Mechs=@('powershell','dotnet','cmd_type') }
    @{ Op='file_modify';      Mechs=@('powershell_append','dotnet_append','dotnet_overwrite') }
    @{ Op='file_ads_write';   Mechs=@('powershell_stream','cmd_redirect') }
    @{ Op='file_rename';      Mechs=@('powershell','dotnet','cmd_ren') }
    @{ Op='file_copy';        Mechs=@('powershell','dotnet','cmd_copy','xcopy','robocopy','robocopy_dat') }
    @{ Op='file_move_local';  Mechs=@('powershell','dotnet','cmd_move') }
    @{ Op='file_move_volume'; Mechs=@('powershell','dotnet','cmd_move','robocopy_move') }
    @{ Op='file_delete';      Mechs=@('powershell','dotnet','cmd_del') }
)

$variants = switch ($Variant) { 'both' { @('normal','timestomped') } default { @($Variant) } }

if ($OnlyOperations) { $Matrix = @($Matrix | Where-Object { $_.Op -in $OnlyOperations }) }
if ($OnlyMechanisms) {
    $Matrix = @($Matrix | ForEach-Object {
        $m = @($_.Mechs | Where-Object { $_ -in $OnlyMechanisms })
        if ($m) { @{ Op = $_.Op; Mechs = $m } }
    })
}
if (-not $Matrix) { throw 'Filters eliminated every case. Check -OnlyOperations / -OnlyMechanisms.' }

# ----------------------------------------------------------- PHASE 1: SETUP
Write-Host "`n=== PHASE 1: setup ===" -ForegroundColor Cyan
$cases = New-Object Collections.Generic.List[object]
$caseNum = 0

foreach ($entry in $Matrix) {
    foreach ($mech in $entry.Mechs) {
        foreach ($var in $variants) {
            $caseNum++
            $id  = '{0:D3}_{1}_{2}_{3}' -f $caseNum, $entry.Op, $mech, $var
            $dir = New-CaseDirectory -Root $primaryRoot

            # file_create is the one operation whose subject must NOT exist when
            # the 'before' snapshot is taken -- creation IS the operation under
            # test. Only its containing directory is made here, so the directory's
            # own creation stays outside the measured window. Every other case
            # gets its subject file now, in its own fresh directory, so that the
            # operation under test is the ONLY thing acting on that file.
            $isCreateCase = ($entry.Op -eq 'file_create')
            $cr = if ($isCreateCase) { $null } else { Invoke-OpCreate -Directory $dir -Mechanism powershell }

            if ($cr -and $var -eq 'timestomped') {
                Set-SiTimestamp -Path $cr.PathAfter -Creation $Stomp.Creation -Modified $Stomp.Modified `
                                -Access $Stomp.Access -MftEntryModified $Stomp.MftEntryModified
            }

            # Destination directory, pre-created so its own creation does not
            # land inside the measured window of the operation under test.
            $destDir = switch ($entry.Op) {
                'file_copy'        { New-CaseDirectory -Root $primaryRoot }
                'file_move_local'  { New-CaseDirectory -Root $primaryRoot }
                'file_move_volume' { New-CaseDirectory -Root $secondaryRoot }
                default            { $null }
            }

            $cases.Add([pscustomobject]@{
                CaseId      = $id
                Operation   = $entry.Op
                Mechanism   = $mech
                Variant     = $var
                CaseDir     = $dir
                SourcePath  = if ($cr) { $cr.PathAfter } else { $null }
                SourceName  = if ($cr) { Split-Path -Leaf $cr.PathAfter } else { $null }
                DestDir     = $destDir
                CreatedUtc  = $cr.OpEndUtc
                Result      = $null
            })
        }
    }
}
Write-Host "  $($cases.Count) cases staged across $(($cases.Operation | Select-Object -Unique).Count) operations"

# Let creation timestamps settle clearly before the operations under test, so
# an operation-time value is unambiguously distinguishable from creation time.
Start-Sleep -Seconds $SettleSeconds

# ---------------------------------------------------------- PHASE 2: BEFORE
Write-Host "`n=== PHASE 2: before snapshots ===" -ForegroundColor Cyan
$volumes = @($PrimaryVolume, $SecondaryVolume) | Select-Object -Unique
$before = @{}
foreach ($v in $volumes) {
    $before[$v] = Get-MftSnapshot -Volume $v -WorkDir $runDir -ToolRoot $ToolRoot -HarnessRoot $HarnessRoot -Label 'before'
    Write-Host "  $v  $($before[$v].ToolCounts)"
}

# --------------------------------------------------------- PHASE 3: EXECUTE
Write-Host "`n=== PHASE 3: execute ===" -ForegroundColor Cyan
# Deletes last. See header.
$ordered = @($cases | Where-Object Operation -ne 'file_delete') +
           @($cases | Where-Object Operation -eq 'file_delete')

foreach ($c in $ordered) {
    try {
        $r = switch ($c.Operation) {
            'file_create'      { Invoke-OpCreate     -Directory $c.CaseDir -Mechanism $c.Mechanism }
            'file_access'      { Invoke-OpAccess     -Path $c.SourcePath -Mechanism $c.Mechanism }
            'file_modify'      { Invoke-OpModify     -Path $c.SourcePath -Mechanism $c.Mechanism }
            'file_ads_write'   { Invoke-OpWriteAds   -Path $c.SourcePath -Mechanism $c.Mechanism }
            'file_rename'      { Invoke-OpRename     -Path $c.SourcePath -Mechanism $c.Mechanism }
            'file_copy'        { Invoke-OpCopy       -Path $c.SourcePath -DestDirectory $c.DestDir -Mechanism $c.Mechanism }
            'file_move_local'  { Invoke-OpMoveLocal  -Path $c.SourcePath -DestDirectory $c.DestDir -Mechanism $c.Mechanism }
            'file_move_volume' { Invoke-OpMoveVolume -Path $c.SourcePath -DestDirectory $c.DestDir -Mechanism $c.Mechanism }
            'file_delete'      { Invoke-OpDelete     -Path $c.SourcePath -Mechanism $c.Mechanism }
        }
        # Live $SI, read immediately and straight from the in-memory record.
        #
        # NTFS updates Access in memory on every access but defers writing it to
        # the $MFT by up to an hour, and `fsutil volume flush` cannot force it
        # out (there is no dirty page -- the value is still in the file control
        # block). An $MFT-only capture can therefore show a stale Access value
        # and be read as "did not change". This live read cannot be stale, so it
        # is the authoritative record of what the operation actually did.
        #
        # Handles open with FILE_READ_ATTRIBUTES only, so the read itself does
        # not update the Access time it is measuring.
        $live = $null
        if ($r.PathAfter -and (Test-Path -LiteralPath $r.PathAfter)) {
            try { $live = Get-SiTimestamp -Path $r.PathAfter } catch { }
        }

        $c.Result = [pscustomobject]@{
            OpStartUtc = $r.OpStartUtc; OpEndUtc = $r.OpEndUtc
            PathAfter  = $r.PathAfter
            NameAfter  = if ($r.PathAfter) { Split-Path -Leaf $r.PathAfter } else { $null }
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
        Write-Host ("  {0,-46} ok" -f $c.CaseId)
    } catch {
        $c.Result = [pscustomobject]@{ OpStartUtc=$null; OpEndUtc=$null; PathAfter=$null; NameAfter=$null; LiveSI=$null; Error=$_.Exception.Message }
        Write-Warning ("  {0,-46} FAILED: {1}" -f $c.CaseId, $_.Exception.Message)
    }
    Start-Sleep -Seconds $SettleSeconds
}

# ----------------------------------------------------------- PHASE 4: AFTER
# Settle before capturing. A read-only operation performed moments before the
# snapshot may still have its Access update sitting in the file control block,
# where it would read as "no change". The per-case live reads above are the
# real defence; this just widens the margin at negligible cost.
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

# ------------------------------------------------- PHASE 5: LATE (optional)
$late = @{}
if ($LateCaptureMinutes -gt 0) {
    Write-Host "`n=== PHASE 5: late capture (+$LateCaptureMinutes min) ===" -ForegroundColor Cyan
    Write-Host "  sleeping; a value differing from the 'after' snapshot indicates a DEFERRED update, not a stable rule"
    Start-Sleep -Seconds ($LateCaptureMinutes * 60)
    foreach ($v in $volumes) {
        $late[$v] = Get-MftSnapshot -Volume $v -WorkDir $runDir -ToolRoot $ToolRoot -HarnessRoot $HarnessRoot -Label 'late'
        Write-Host "  $v  $($late[$v].ToolCounts)"
    }
}

# ------------------------------------------------------------------- EMIT
# Trim the EMBEDDED records to the files actually under test. The complete
# $MFT stays archived on disk as the evidence; only the JSON is scoped.
# A system volume's $MFT holds hundreds of thousands of records (C: measured at
# 276 MB), and embedding them all would produce a multi-gigabyte run.json with
# no analytical gain -- every classification is keyed on a case file's name.
$caseNames = @{}
foreach ($c in $cases) {
    if ($c.SourceName)                              { $caseNames["$($c.SourceName)"] = $true }
    if ($c.Result -and $c.Result.NameAfter)         { $caseNames["$($c.Result.NameAfter)"] = $true }
}
function Select-CaseRecords {
    param($Records)
    @($Records | Where-Object { $caseNames.ContainsKey("$($_.FileName)") })
}
$trimStat = { param($Set,$Label)
    $tot = 0; $kept = 0
    foreach ($v in $volumes) { $tot += @($Set[$v].Records).Count; $kept += @(Select-CaseRecords $Set[$v].Records).Count }
    Write-Host ("  {0,-7} embedded {1} of {2} records" -f $Label, $kept, $tot)
}
Write-Host "`n=== scoping embedded records ==="
& $trimStat $before 'before'
& $trimStat $after  'after'

$out = [pscustomobject]@{
    RunLabel        = $RunLabel
    Driver          = 'script'
    Harness         = Get-HarnessProvenance -RepoRoot (Split-Path -Parent $HarnessRoot)
    StartedUtc      = $cases[0].CreatedUtc
    CompletedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    PrimaryVolume   = $PrimaryVolume
    SecondaryVolume = $SecondaryVolume
    SettleSeconds   = $SettleSeconds
    LateCaptureMinutes = $LateCaptureMinutes
    StompValues     = ($Stomp.GetEnumerator() | ForEach-Object { @{ $_.Key = $_.Value.ToString('o') } })
    Cases           = $cases
    Snapshots       = @{
        Before = @($volumes | ForEach-Object { @{ Volume=$_; Sha256=$before[$_].MftSha256; Records=(Select-CaseRecords $before[$_].Records) } })
        After  = @($volumes | ForEach-Object { @{ Volume=$_; Sha256=$after[$_].MftSha256;  Records=(Select-CaseRecords $after[$_].Records)  } })
        Late   = if ($LateCaptureMinutes -gt 0) {
                     @($volumes | ForEach-Object { @{ Volume=$_; Sha256=$late[$_].MftSha256; Records=(Select-CaseRecords $late[$_].Records) } })
                 } else { @() }
    }
}

$jsonPath = Join-Path $runDir 'run.json'
$out | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$failed = @($cases | Where-Object { $_.Result.Error })
Write-Host "`nRun complete: $($cases.Count) cases, $($failed.Count) failed"
Write-Host "  $jsonPath"
if ($failed) { $failed | ForEach-Object { Write-Warning "$($_.CaseId): $($_.Result.Error)" } }

[pscustomobject]@{ RunLabel=$RunLabel; RunDir=$runDir; JsonPath=$jsonPath; CaseCount=$cases.Count; FailedCount=$failed.Count }
