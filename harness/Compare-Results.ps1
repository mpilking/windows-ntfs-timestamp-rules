<#
  Compare-Results.ps1
  Classifies every observed timestamp and diffs the result against the baseline
  rule tables.

  CLASSIFICATION VOCABULARY (matches the baseline CSVs):
    OP_TIME     value falls inside the operation's tolerance window
    NO_CHANGE   value is identical to the same field before the operation
    INHERITED   value equals the SOURCE file's pre-operation value for the same
                field (a new file carrying the original's timestamp)
    PREV_SI_*   value equals the source's pre-operation $SI value for a named
                field (how $FN is populated on rename / local move)

  WHY A TOLERANCE WINDOW AND NOT EQUALITY:
  Access times in Windows 11 have been observed to differ from the moment of
  activity by up to a few seconds. Testing OP_TIME by equality would produce
  false negatives on exactly the row most prone to skew. The window spans the
  bracketed operation plus -Tolerance on each side.

  AMBIGUITY IS REPORTED, NOT RESOLVED:
  A value can satisfy more than one label -- on a pristine file, NO_CHANGE and
  PREV_SI_CREATION are indistinguishable because $SI and $FN start equal. The
  classifier returns every label that fits and marks the cell AMBIGUOUS when
  more than one survives. The stomped variant is what collapses the ambiguity,
  so a cell ambiguous in 'pristine' but decided in 'stomped' is the expected
  pattern, not a defect.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunJson,
    [string]$BaselineDir = (Join-Path $PSScriptRoot '..\expected'),
    [string]$OutDir      = (Split-Path -Parent $RunJson),
    [int]$ToleranceSeconds = 5
)

$ErrorActionPreference = 'Stop'

$run = Get-Content -Raw -LiteralPath $RunJson | ConvertFrom-Json
$tol = [TimeSpan]::FromSeconds($ToleranceSeconds)

# The run's spacing must exceed the tolerance window on BOTH sides, or a file's
# creation time falls inside the operation's window and NO_CHANGE becomes
# indistinguishable from OP_TIME -- every cell then reports AMBIGUOUS for a
# reason that has nothing to do with NTFS.
if ($run.SettleSeconds -le (2 * $ToleranceSeconds)) {
    Write-Warning ("Run spacing ({0}s) is not greater than twice the tolerance ({1}s). " -f $run.SettleSeconds, $ToleranceSeconds +
                   "Creation and operation times are not separable and AMBIGUOUS verdicts are expected. " +
                   "Re-run with -SettleSeconds greater than $((2 * $ToleranceSeconds)).")
}

$Fields = @(
    @{ Attr='SI'; Name='Modified';         Prop='SI_Modified' }
    @{ Attr='SI'; Name='Access';           Prop='SI_Access' }
    @{ Attr='SI'; Name='MftEntryModified'; Prop='SI_EntryModified' }
    @{ Attr='SI'; Name='Creation';         Prop='SI_Created' }
    @{ Attr='FN'; Name='Modified';         Prop='FN_Modified' }
    @{ Attr='FN'; Name='Access';           Prop='FN_Access' }
    @{ Attr='FN'; Name='MftEntryModified'; Prop='FN_EntryModified' }
    @{ Attr='FN'; Name='Creation';         Prop='FN_Created' }
)

# $SI source fields that $FN may be populated from, for PREV_SI_* detection.
$SiSourceMap = [ordered]@{
    'SI_Modified'       = 'PREV_SI_MODIFIED'
    'SI_Access'         = 'PREV_SI_ACCESS'
    'SI_EntryModified'  = 'PREV_SI_ENTRYMOD'
    'SI_Created'        = 'PREV_SI_CREATION'
}

function Get-Dt {
    <#
      Must preserve 100 ns precision. A DateTime is used directly -- coercing
      one to a string first ("$v") silently drops the fractional second, which
      would make the sub-second analysis report every value as round.
    #>
    param($v)
    if ($null -eq $v) { return $null }
    if ($v -is [datetime]) { return [datetime]::SpecifyKind($v, [DateTimeKind]::Utc) }
    $s = "$v"
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Test-Near { param($A,$B) ($null -ne $A) -and ($null -ne $B) -and ([math]::Abs(($A - $B).TotalSeconds) -le 1) }

function Find-Record {
    <# Match on file name plus the case's unique GUID directory token. A copy
       shares its leaf name with its source, so name alone is not unique. #>
    param($Records, [string]$Tool, [string]$Name, [string]$DirToken, $EntryNumber, [string]$Operation)
    $c = @($Records | Where-Object { $_.Tool -eq $Tool -and $_.FileName -eq $Name })

    # Fallback for operations that rename the file to something unpredictable.
    # A Recycle Bin delete moves the file into $Recycle.Bin AND renames it to
    # $R<random>.<ext>, so no name is knowable in advance. The MFT entry number
    # survives both, and is safe because delete cases run last -- nothing is
    # created afterwards that could recycle the record.
    #
    # NEVER for a new-record operation. A copy or cross-volume move leaves the
    # SOURCE record intact under its original entry number, so this fallback
    # would silently match the source instead of the result -- and comparing a
    # record against itself reads as "unchanged", which the classifier reports
    # as INHERITED. That is a wrong answer delivered confidently, which is far
    # worse than an unresolved one.
    $entryFallbackOk = $Operation -and ($Operation -notin $NewRecordOps)
    if ($c.Count -eq 0 -and $entryFallbackOk -and $null -ne $EntryNumber -and "$EntryNumber" -ne '') {
        $c = @($Records | Where-Object { $_.Tool -eq $Tool -and "$($_.EntryNumber)" -eq "$EntryNumber" })
    }

    if ($c.Count -le 1 -or -not $DirToken) { return $c | Select-Object -First 1 }
    $narrowed = @($c | Where-Object { "$($_.ParentPath)" -like "*$DirToken*" })
    if ($narrowed.Count -ge 1) { return $narrowed[0] }
    return $c[0]
}

# Operations that produce a NEW MFT record. INHERITED is only meaningful for
# these: for an in-place operation the "source" and the result are the same
# record, so INHERITED would always coincide with NO_CHANGE and manufacture a
# false ambiguity on every single cell.
# file_create has no 'before' record at all -- its subject does not exist when
# the before snapshot is taken. An absent source record is EXPECTED there, not
# a lookup failure, and OP_TIME is the only label that can apply.
$NewRecordOps = @('file_create','file_copy','file_move_volume')

# Operations that actually rewrite the $FILE_NAME attribute. PREV_SI_* is only
# a meaningful hypothesis for these. On an operation that does not touch $FN
# (access, modify, delete) the unchanged $FN value trivially equals the
# unchanged $SI value, so testing PREV_SI_* there labels every cell AMBIGUOUS
# when the correct answer is simply NO_CHANGE.
$FnRewriteOps = @('file_rename','file_move_local','file_move_volume','file_copy')

function Get-Classification {
    param($AfterVal, $BeforeVal, $SourceRec, $WinStart, $WinEnd, [string]$Prop,
          [bool]$IsFnField, [string]$Operation)
    if ($null -eq $AfterVal) { return @{ Labels=@(); Note='no value from tool' } }
    $labels = New-Object Collections.Generic.List[string]

    # NO_CHANGE is only meaningful for an operation acting on an EXISTING
    # record. For copy and cross-volume move the result is a brand-new record
    # that had no prior value, so "unchanged" is not a coherent claim -- and
    # testing it compares the new file against the source, which is exactly
    # what INHERITED already tests. Emitting both made every such cell
    # spuriously AMBIGUOUS.
    if ($Operation -notin $NewRecordOps -and (Test-Near $AfterVal $BeforeVal)) { $labels.Add('NO_CHANGE') }

    if ($WinStart -and $WinEnd -and $AfterVal -ge ($WinStart - $tol) -and $AfterVal -le ($WinEnd + $tol)) {
        $labels.Add('OP_TIME')
    }

    if ($SourceRec) {
        if ($Operation -in $NewRecordOps -and (Test-Near $AfterVal $SourceRec.$Prop)) {
            $labels.Add('INHERITED')
        }
        # PREV_SI_*: how $FN is populated from the pre-operation $SI values.
        # Only meaningful for $FN fields, and only where $FN is rewritten.
        if ($IsFnField -and $Operation -in $FnRewriteOps) {
            foreach ($k in $SiSourceMap.Keys) {
                if (Test-Near $AfterVal $SourceRec.$k) { $labels.Add($SiSourceMap[$k]) }
            }
        }
    }
    # @() is load-bearing: a single-element result would otherwise collapse to a
    # bare string, and indexing [0] into it returns its first CHARACTER.
    @{ Labels = @($labels | Select-Object -Unique); Note = $null }
}

# --------------------------------------------------------------- classify
$beforeAll = @(); $run.Snapshots.Before | ForEach-Object { $beforeAll += @($_.Records | Where-Object { $_ -and $_.Tool }) }
$afterAll  = @(); $run.Snapshots.After  | ForEach-Object { $afterAll  += @($_.Records | Where-Object { $_ -and $_.Tool }) }
$tools = @($afterAll | Select-Object -ExpandProperty Tool -Unique)

$rows = New-Object Collections.Generic.List[object]

foreach ($case in $run.Cases) {
    if ($case.Result.Error) { continue }
    $nameAfter = if ($case.Result.NameAfter) { $case.Result.NameAfter } else { $case.SourceName }
    $dirToken  = if ($case.Result.PathAfter) { Split-Path -Leaf (Split-Path -Parent $case.Result.PathAfter) } else { $null }
    $ws = Get-Dt $case.Result.OpStartUtc
    $we = Get-Dt $case.Result.OpEndUtc

    foreach ($tool in $tools) {
        $src = Find-Record -Records $beforeAll -Tool $tool -Name $case.SourceName -DirToken $null
        $aft = Find-Record -Records $afterAll  -Tool $tool -Name $nameAfter -DirToken $dirToken -EntryNumber $case.SourceEntryNumber -Operation $case.Operation

        # Convert the whole source record once per tool. Building it per field
        # risked a duplicate key whenever the field under test was itself one
        # of the four $SI properties.
        $srcDt = $null
        if ($src) {
            $srcDt = [pscustomobject]@{
                SI_Modified      = Get-Dt $src.SI_Modified
                SI_Access        = Get-Dt $src.SI_Access
                SI_EntryModified = Get-Dt $src.SI_EntryModified
                SI_Created       = Get-Dt $src.SI_Created
                FN_Modified      = Get-Dt $src.FN_Modified
                FN_Access        = Get-Dt $src.FN_Access
                FN_EntryModified = Get-Dt $src.FN_EntryModified
                FN_Created       = Get-Dt $src.FN_Created
            }
        }

        foreach ($f in $Fields) {
            $afterVal  = if ($aft) { Get-Dt $aft.($f.Prop) } else { $null }
            $beforeVal = if ($src) { Get-Dt $src.($f.Prop) } else { $null }

            $cls = Get-Classification -AfterVal $afterVal -BeforeVal $beforeVal -SourceRec $srcDt `
                       -WinStart $ws -WinEnd $we -Prop $f.Prop -IsFnField ($f.Attr -eq 'FN') `
                       -Operation $case.Operation

            $rows.Add([pscustomobject]@{
                CaseId      = $case.CaseId
                Operation   = $case.Operation
                Mechanism   = $case.Mechanism
                Variant     = $case.Variant
                Tool        = $tool
                Attribute   = $f.Attr
                Timestamp   = $f.Name
                Observed    = if ($afterVal) { $afterVal.ToString('o') } else { $null }
                Labels      = ($cls.Labels -join '|')
                LabelCount  = @($cls.Labels).Count
                Verdict     = if (@($cls.Labels).Count -eq 1) { @($cls.Labels)[0] }
                              elseif (@($cls.Labels).Count -eq 0) { if ($afterVal) { 'UNCLASSIFIED' } else { 'NO_DATA' } }
                              else { 'AMBIGUOUS' }
                Note        = $cls.Note
            })
        }
    }
}

# ------------------------------------------------- tool agreement + baseline
# The baseline distinguishes mechanism CLASSES, not individual mechanisms:
# Volume Move has separate 'cli' and 'explorer_cutpaste' rows that disagree on
# $SI Creation. Keying without the class silently kept whichever row loaded
# last and compared CLI results against the Explorer expectation.
function Get-MechanismClass {
    param([string]$Mechanism)
    if ($Mechanism -like 'explorer*') { return 'explorer_cutpaste' }
    return 'cli'
}

$baselines = @{}
foreach ($bf in Get-ChildItem -LiteralPath $BaselineDir -Filter '*.csv') {
    foreach ($b in (Import-Csv -LiteralPath $bf.FullName)) {
        $baselines["$($b.attribute)|$($b.operation_id)|$($b.mechanism)|$($b.timestamp)"] = $b
    }
}

function Find-Baseline {
    param([string]$Attribute,[string]$OperationId,[string]$Mechanism,[string]$Timestamp)
    # Prefer a row matching this mechanism class, then fall back to 'any'.
    $cls = Get-MechanismClass $Mechanism
    foreach ($m in @($cls,'any')) {
        $k = "$Attribute|$OperationId|$m|$Timestamp"
        if ($baselines.ContainsKey($k)) { return $baselines[$k] }
    }
    return $null
}

$summary = New-Object Collections.Generic.List[object]
foreach ($g in ($rows | Group-Object Operation, Mechanism, Variant, Attribute, Timestamp)) {
    $set = @($g.Group)
    $decided = @($set | Where-Object { $_.Verdict -notin 'NO_DATA' })
    $verdicts = @($decided | Select-Object -ExpandProperty Verdict -Unique)
    $toolsAgree = ($verdicts.Count -le 1)

    $first = $set[0]
    $exp   = Find-Baseline -Attribute $first.Attribute -OperationId $first.Operation `
                           -Mechanism $first.Mechanism -Timestamp $first.Timestamp

    $observed = if ($verdicts.Count -eq 1) { @($verdicts)[0] } else { ($verdicts -join '/') }
    $match = if (-not $exp) { 'NO_BASELINE' }
             elseif ($exp.expected -eq 'UNRESOLVED') { 'RESOLVES_OPEN_QUESTION' }
             elseif ($observed -eq $exp.expected) { 'MATCH' }
             else { 'DIFFERS' }

    $summary.Add([pscustomobject]@{
        Attribute   = $first.Attribute
        Operation   = $first.Operation
        Mechanism   = $first.Mechanism
        Variant     = $first.Variant
        Timestamp   = $first.Timestamp
        Observed    = $observed
        Expected22H2= if ($exp) { $exp.expected } else { '' }
        Result      = $match
        ToolsAgree  = $toolsAgree
        ToolCount   = $decided.Count
        AllLabels   = (($set | Select-Object -ExpandProperty Labels -Unique) -join ' ; ')
    })
}

# --------------------------------------------- determinacy + mechanism link
# The 'normal' variant is the primary result. Where a normal cell is AMBIGUOUS
# the ambiguity is a limit of what is OBSERVABLE on an ordinary file, not a
# defect -- $SI and $FN start equal, so "unchanged" and "copied from $SI" look
# identical. The matching timestomped cell can reveal the mechanism, but that
# mechanism belongs in a separate table and must never be silently promoted
# into the normal rule.
# The CORE result is one fresh file, one operation, performed the ordinary way.
# Every operation designates a canonical mechanism; the others are reported as
# variations rather than averaged into the core table. The choice of canonical
# mechanism does not change any core value -- all mechanisms agree per operation
# except robocopy, which is reported as an exception.
$CoreMechanism = @{
    'file_create'      = 'powershell'
    'file_access'      = 'powershell'
    'file_modify'      = 'powershell_append'
    'file_ads_write'   = 'powershell_stream'
    'file_rename'      = 'powershell'
    'file_copy'        = 'powershell'
    'file_move_local'  = 'powershell'
    'file_move_volume' = 'cmd_move'       # "move via CLI", matching the published charts
    'file_delete'      = 'powershell'
}

$stompIndex = @{}
foreach ($r in ($summary | Where-Object Variant -eq 'timestomped')) {
    $stompIndex["$($r.Attribute)|$($r.Operation)|$($r.Mechanism)|$($r.Timestamp)"] = $r
}
foreach ($r in $summary) {
    $det  = 'DETERMINATE'
    $mech = ''
    if ($r.Variant -eq 'normal' -and $r.Observed -eq 'AMBIGUOUS') {
        $det = 'INDETERMINATE_FROM_NORMAL'
        $k = "$($r.Attribute)|$($r.Operation)|$($r.Mechanism)|$($r.Timestamp)"
        if ($stompIndex.ContainsKey($k)) { $mech = $stompIndex[$k].Observed }

        # An indeterminate normal cell whose mechanism agrees with the baseline
        # is NOT a divergence -- the baseline is right and our normal variant
        # simply cannot see it. Reporting it as DIFFERS would pad section 4
        # with non-findings and bury the one real change.
        if ($mech -and $r.Expected22H2 -and $mech -eq $r.Expected22H2) {
            $r.Result = 'CONSISTENT_MECHANISM'
        }
    }
    $r | Add-Member -NotePropertyName Determinacy           -NotePropertyValue $det  -Force
    $r | Add-Member -NotePropertyName MechanismFromTimestomp -NotePropertyValue $mech -Force
    $r | Add-Member -NotePropertyName IsCore -NotePropertyValue `
         ($CoreMechanism.ContainsKey($r.Operation) -and $CoreMechanism[$r.Operation] -eq $r.Mechanism) -Force
}

# ------------------------------------------------ sub-second precision check
# NTFS stores timestamps at 100 ns granularity, so a genuine value essentially
# never has a zero fractional part. Software that READS a file and then
# RESTORES the access time through SetFileTime -- behaviour reported in some
# AV products -- preserves the whole second but loses the fraction, leaving
# .0000000 behind.
#
# The verdict classifier CANNOT see this: Test-Near uses a one-second tolerance,
# so .3394512 -> .0000000 still reads as NO_CHANGE. This pass compares exact
# tick values instead, and is the only part of the harness that can detect a
# lossy restore.
function Get-FractionTicks { param([datetime]$Dt) $Dt.Ticks % 10000000 }

$precision = New-Object Collections.Generic.List[object]
foreach ($case in $run.Cases) {
    if ($case.Result.Error) { continue }
    $nameAfter = if ($case.Result.NameAfter) { $case.Result.NameAfter } else { $case.SourceName }
    $dirToken  = if ($case.Result.PathAfter) { Split-Path -Leaf (Split-Path -Parent $case.Result.PathAfter) } else { $null }
    foreach ($tool in $tools) {
        $src = Find-Record -Records $beforeAll -Tool $tool -Name $case.SourceName -DirToken $null
        $aft = Find-Record -Records $afterAll  -Tool $tool -Name $nameAfter -DirToken $dirToken -EntryNumber $case.SourceEntryNumber -Operation $case.Operation
        foreach ($f in $Fields) {
            $a = if ($aft) { Get-Dt $aft.($f.Prop) } else { $null }
            $b = if ($src) { Get-Dt $src.($f.Prop) } else { $null }
            if ($null -eq $a) { continue }
            $aFrac = Get-FractionTicks $a
            $bFrac = if ($b) { Get-FractionTicks $b } else { $null }

            # Strongest signal: same whole second, fraction present before and
            # zeroed after. That is a read-then-restore, not an NTFS update.
            $lossy = ($null -ne $b) -and ($aFrac -eq 0) -and ($bFrac -ne 0) -and
                     ([math]::Floor($a.Ticks / 10000000) -eq [math]::Floor($b.Ticks / 10000000))

            $precision.Add([pscustomobject]@{
                CaseId      = $case.CaseId
                Operation   = $case.Operation
                Mechanism   = $case.Mechanism
                Variant     = $case.Variant
                Tool        = $tool
                Attribute   = $f.Attr
                Timestamp   = $f.Name
                AfterValue  = $a.ToString('o')
                AfterFracTicks  = $aFrac
                BeforeFracTicks = $bFrac
                ZeroFraction    = ($aFrac -eq 0)
                LossyRestore    = $lossy
            })
        }
    }
}
$lossyRows = @($precision | Where-Object LossyRestore)
# Zero fractions in the timestomped variant are expected -- the stomp writes
# whole-second values by construction -- so rate is reported for 'normal' only.
$normalPrec = @($precision | Where-Object Variant -eq 'normal')
$zeroRate = if ($normalPrec.Count) {
    [math]::Round(100 * @($normalPrec | Where-Object ZeroFraction).Count / $normalPrec.Count, 1)
} else { 0 }

# ------------------------------------------ live vs $MFT (pending-write check)
# Each case records the live $SI read immediately after its operation. NTFS can
# hold an Access update in the file control block for up to an hour before
# writing it to the $MFT, and a flush cannot force it out, so an $MFT-only
# capture may show a stale value that reads as "no change".
#
# Where the live value and the $MFT disagree, the live value is authoritative --
# it is the in-memory record and cannot be stale. A disagreement is reported
# rather than silently classified, because the failure mode is a false
# NO_CHANGE, which looks like a finding.
$pendingWrites = New-Object Collections.Generic.List[object]
$liveFields = @(
    @{ Live='Created';       Prop='SI_Created';       Name='Creation' }
    @{ Live='Modified';      Prop='SI_Modified';      Name='Modified' }
    @{ Live='Access';        Prop='SI_Access';        Name='Access' }
    @{ Live='EntryModified'; Prop='SI_EntryModified'; Name='MftEntryModified' }
)
foreach ($case in $run.Cases) {
    if ($case.Result.Error -or -not $case.Result.LiveSI) { continue }
    $nameAfter = if ($case.Result.NameAfter) { $case.Result.NameAfter } else { $case.SourceName }
    $dirToken  = if ($case.Result.PathAfter) { Split-Path -Leaf (Split-Path -Parent $case.Result.PathAfter) } else { $null }
    foreach ($tool in $tools) {
        $aft = Find-Record -Records $afterAll -Tool $tool -Name $nameAfter -DirToken $dirToken `
                           -EntryNumber $case.SourceEntryNumber -Operation $case.Operation
        if (-not $aft) { continue }
        foreach ($f in $liveFields) {
            $liveVal = Get-Dt $case.Result.LiveSI.($f.Live)
            $mftVal  = Get-Dt $aft.($f.Prop)
            if ($null -eq $liveVal -or $null -eq $mftVal) { continue }
            if (-not (Test-Near $liveVal $mftVal)) {
                $pendingWrites.Add([pscustomobject]@{
                    CaseId=$case.CaseId; Operation=$case.Operation; Mechanism=$case.Mechanism
                    Variant=$case.Variant; Tool=$tool; Timestamp=$f.Name
                    LiveValue=$liveVal.ToString('o'); MftValue=$mftVal.ToString('o')
                    DeltaSeconds=[math]::Round(($liveVal - $mftVal).TotalSeconds,3)
                })
            }
        }
    }
}

# ------------------------------------- Access vs Entry Modified correlation
# A timestamp written BY an operation is part of the same MFT record update,
# so it matches $SI Entry Modified EXACTLY. Anything that writes Access
# afterwards -- a search crawler, a scanner -- leaves a small positive gap.
#
# This distinction is invisible to the verdict classifier, whose OP_TIME label
# uses a multi-second tolerance window and therefore cannot separate "the
# operation set this" from "something set it a second later". Measured on
# Win11 25H2, the Windows Search crawler left Access +0.007 s to +1.03 s after
# Entry Modified, including on plain file creation where all four $SI values
# are otherwise identical to the tick.
$accessDelta = New-Object Collections.Generic.List[object]
foreach ($g in ($precision | Where-Object { $_.Attribute -eq 'SI' } |
                Group-Object CaseId, Tool)) {
    $em = @($g.Group | Where-Object Timestamp -eq 'MftEntryModified')[0]
    $ac = @($g.Group | Where-Object Timestamp -eq 'Access')[0]
    if (-not $em -or -not $ac -or -not $em.AfterValue -or -not $ac.AfterValue) { continue }
    $d = (Get-Dt $ac.AfterValue) - (Get-Dt $em.AfterValue)
    $sec = $d.TotalSeconds
    $cls = if ($sec -eq 0)                      { 'EXACT'    }   # written by the operation
           elseif ($sec -gt 0 -and $sec -le 30) { 'TRAILS'   }   # third party wrote it after
           elseif ($sec -gt 30)                 { 'LATE'     }
           else                                 { 'PRECEDES' }   # untouched by the operation
    $accessDelta.Add([pscustomobject]@{
        CaseId=$em.CaseId; Operation=$em.Operation; Mechanism=$em.Mechanism
        Variant=$em.Variant; Tool=$em.Tool
        EntryModified=$em.AfterValue; Access=$ac.AfterValue
        DeltaSeconds=[math]::Round($sec,7); Classification=$cls
    })
}
$trailing = @($accessDelta | Where-Object { $_.Classification -eq 'TRAILS' -and $_.Variant -eq 'normal' })

# ------------------------------------------------- deferred-update detection
# If a late snapshot exists, any value that MOVED between 'after' and 'late'
# was a deferred write, not a stable rule. Such a cell must not be published
# from the 'after' snapshot alone.
$deferred = New-Object Collections.Generic.List[object]
if ($run.Snapshots.PSObject.Properties.Name -contains 'Late' -and @($run.Snapshots.Late).Count -gt 0) {
    $lateAll = @(); $run.Snapshots.Late | ForEach-Object { $lateAll += @($_.Records | Where-Object { $_ -and $_.Tool }) }
    foreach ($case in $run.Cases) {
        if ($case.Result.Error) { continue }
        $nameAfter = if ($case.Result.NameAfter) { $case.Result.NameAfter } else { $case.SourceName }
        $dirToken  = if ($case.Result.PathAfter) { Split-Path -Leaf (Split-Path -Parent $case.Result.PathAfter) } else { $null }
        foreach ($tool in $tools) {
            $a = Find-Record -Records $afterAll -Tool $tool -Name $nameAfter -DirToken $dirToken
            $l = Find-Record -Records $lateAll  -Tool $tool -Name $nameAfter -DirToken $dirToken
            if (-not $a -or -not $l) { continue }
            foreach ($f in $Fields) {
                $av = Get-Dt $a.($f.Prop); $lv = Get-Dt $l.($f.Prop)
                if ($av -and $lv -and -not (Test-Near $av $lv)) {
                    $deferred.Add([pscustomobject]@{
                        CaseId=$case.CaseId; Operation=$case.Operation; Mechanism=$case.Mechanism
                        Variant=$case.Variant; Tool=$tool; Attribute=$f.Attr; Timestamp=$f.Name
                        After=$av.ToString('o'); Late=$lv.ToString('o')
                    })
                }
            }
        }
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$detailCsv  = Join-Path $OutDir 'classified-detail.csv'
$summaryCsv = Join-Path $OutDir 'summary.csv'
$rows      | Export-Csv -LiteralPath $detailCsv -NoTypeInformation -Encoding UTF8
$precision   | Export-Csv -LiteralPath (Join-Path $OutDir 'precision-analysis.csv') -NoTypeInformation -Encoding UTF8
$accessDelta   | Export-Csv -LiteralPath (Join-Path $OutDir 'access-vs-entrymodified.csv') -NoTypeInformation -Encoding UTF8
if ($pendingWrites.Count) { $pendingWrites | Export-Csv -LiteralPath (Join-Path $OutDir 'pending-writes.csv') -NoTypeInformation -Encoding UTF8 }
$summary | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding UTF8

# Split by variant. The normal table is the primary deliverable; the
# timestomped table is a separate finding set, never merged into it.
$normalCsv = Join-Path $OutDir 'summary-normal.csv'
$stompCsv  = Join-Path $OutDir 'summary-timestomped.csv'
@($summary | Where-Object Variant -eq 'normal')      | Export-Csv -LiteralPath $normalCsv -NoTypeInformation -Encoding UTF8
@($summary | Where-Object Variant -eq 'timestomped') | Export-Csv -LiteralPath $stompCsv  -NoTypeInformation -Encoding UTF8

$differs   = @($summary | Where-Object Result -eq 'DIFFERS')
$resolves  = @($summary | Where-Object Result -eq 'RESOLVES_OPEN_QUESTION')
$disagree  = @($summary | Where-Object { -not $_.ToolsAgree })
$ambiguous = @($summary | Where-Object Observed -eq 'AMBIGUOUS')

Write-Host "`n=== COMPARISON ===" -ForegroundColor Cyan
Write-Host ("  cells evaluated      : {0}" -f $summary.Count)
Write-Host ("  match 22H2 baseline  : {0}" -f @($summary | Where-Object Result -eq 'MATCH').Count)
Write-Host ("  DIFFER from baseline : {0}" -f $differs.Count)   -ForegroundColor $(if($differs){'Yellow'}else{'Gray'})
Write-Host ("  resolve open question: {0}" -f $resolves.Count)  -ForegroundColor $(if($resolves){'Green'}else{'Gray'})
Write-Host ("  TOOL DISAGREEMENT    : {0}" -f $disagree.Count)  -ForegroundColor $(if($disagree){'Red'}else{'Gray'})
Write-Host ("  ambiguous            : {0}" -f $ambiguous.Count)
Write-Host ("  zero sub-second frac : {0}%  (normal variant; genuine NTFS values are almost never round)" -f $zeroRate)
Write-Host ("  LIVE vs MFT mismatch : {0}  (deferred write not yet on disk -- live value is authoritative)" -f $pendingWrites.Count) -ForegroundColor $(if($pendingWrites.Count){'Yellow'}else{'Gray'})
Write-Host ("  Access TRAILS EntryMod: {0}  (Access written AFTER the operation -- crawler/scanner, not the operation)" -f $trailing.Count) -ForegroundColor $(if($trailing){'Yellow'}else{'Gray'})
Write-Host ("  LOSSY RESTORES       : {0}  (same second, fraction zeroed -- read-then-SetFileTime)" -f $lossyRows.Count) -ForegroundColor $(if($lossyRows){'Red'}else{'Gray'})
if (@($run.Snapshots.Late).Count -gt 0) {
    Write-Host ("  DEFERRED updates     : {0}  (late capture +{1} min)" -f $deferred.Count, $run.LateCaptureMinutes) -ForegroundColor $(if($deferred){'Yellow'}else{'Gray'})
} else {
    Write-Host "  deferred-update check: not run (no late capture)" -ForegroundColor DarkGray
}
Write-Host "`n  $detailCsv`n  $summaryCsv"

if ($differs)  { Write-Host "`n--- DIFFERS ---" -ForegroundColor Yellow
                 $differs  | Format-Table Attribute,Operation,Mechanism,Variant,Timestamp,Observed,Expected22H2 -AutoSize }
if ($resolves) { Write-Host "`n--- RESOLVES OPEN QUESTION ---" -ForegroundColor Green
                 $resolves | Format-Table Attribute,Operation,Mechanism,Variant,Timestamp,Observed,AllLabels -AutoSize }
if ($deferred.Count -gt 0) { Write-Host "`n--- DEFERRED UPDATES (value moved after the 'after' snapshot) ---" -ForegroundColor Yellow
                 $deferred | Format-Table CaseId,Attribute,Timestamp,After,Late -AutoSize
                 $deferred | Export-Csv -LiteralPath (Join-Path $OutDir 'deferred-updates.csv') -NoTypeInformation -Encoding UTF8 }
if ($disagree) { Write-Host "`n--- TOOL DISAGREEMENT (investigate before publishing) ---" -ForegroundColor Red
                 $disagree | Format-Table Attribute,Operation,Mechanism,Variant,Timestamp,Observed,ToolCount -AutoSize }

[pscustomobject]@{
    Summary=$summary; Detail=$rows; DetailCsv=$detailCsv; SummaryCsv=$summaryCsv
    Differs=$differs.Count; Resolves=$resolves.Count; Disagreements=$disagree.Count; Deferred=$deferred.Count
    ZeroFractionPct=$zeroRate; LossyRestores=$lossyRows.Count; Precision=$precision
    AccessDelta=$accessDelta; AccessTrailing=$trailing.Count
    PendingWrites=$pendingWrites; PendingWriteCount=$pendingWrites.Count
}
