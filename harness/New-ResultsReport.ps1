<#
  New-ResultsReport.ps1
  Renders the published Markdown report from a classified summary.

  STRUCTURE IS DELIBERATE AND THE SEPARATION IS NOT NEGOTIABLE:

    Section 1  NORMAL BEHAVIOUR -- the primary rule tables, built ONLY from the
               'normal' variant. This is what an analyst sees on an ordinary
               system and it is the direct successor to the published charts.

    Section 2  TIMESTOMPED BEHAVIOUR -- a separate finding set showing how
               prior timestomping changes what a later operation produces.
               Reported as a DELTA against section 1, never merged into it.

    Section 3  MECHANISM NOTES -- cells that cannot be determined from normal
               observation alone, because $SI and $FN start equal. The
               timestomped variant reveals the underlying mechanism. These are
               explicitly labelled as mechanism, NOT as normal observables: an
               analyst looking at an ordinary file will see the section 1 value.

    Section 4  DIFFERENCES FROM THE BASELINE CHARTS.

  Collapsing sections 1 and 3 would misrepresent a laboratory inference as a
  field observation. That is the specific error this layout exists to prevent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SummaryCsv,
    [string]$OutFile,
    [string]$Title = 'NTFS Timestamp Rules',
    [string]$FingerprintJson
)

$ErrorActionPreference = 'Stop'
$summary = Import-Csv -LiteralPath $SummaryCsv
if (-not $OutFile) { $OutFile = Join-Path (Split-Path -Parent $SummaryCsv) 'results.md' }

# Display order matches the published charts.
$TsOrder = @('Modified','Access','MftEntryModified','Creation')
$TsLabel = @{ 'Modified'='Modified'; 'Access'='Access'; 'MftEntryModified'='Metadata'; 'Creation'='Creation' }
$OpOrder = @('file_create','file_access','file_modify','file_rename','file_copy',
             'file_move_local','file_move_volume','file_delete')
$OpLabel = @{
    'file_create'='Creation'; 'file_access'='Access'; 'file_modify'='Modification'
    'file_rename'='Rename'; 'file_copy'='Copy'; 'file_move_local'='Local Move'
    'file_move_volume'='Volume Move'; 'file_delete'='Deletion'
}
$Short = @{
    'OP_TIME'='op time'; 'NO_CHANGE'='no change'; 'INHERITED'='inherited'
    'PREV_SI_MODIFIED'='prev $SI mod'; 'PREV_SI_ACCESS'='prev $SI acc'
    'PREV_SI_ENTRYMOD'='prev $SI meta'; 'PREV_SI_CREATION'='prev $SI create'
    'AMBIGUOUS'='indeterminate'; 'UNCLASSIFIED'='**unclassified**'; 'NO_DATA'='-'
}
function Fmt($v) { if ($Short.ContainsKey("$v")) { $Short["$v"] } else { "$v" } }

function New-RuleTable {
    param($Rows, [string]$Attribute)
    $set = @($Rows | Where-Object Attribute -eq $Attribute)
    if (-not $set) { return @('_No data._','') }
    $ops = @($OpOrder | Where-Object { $o = $_; $set | Where-Object Operation -eq $o })
    $out = New-Object Collections.Generic.List[string]
    $out.Add('| | ' + (($ops | ForEach-Object { $OpLabel[$_] }) -join ' | ') + ' |')
    $out.Add('|---|' + (($ops | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($ts in $TsOrder) {
        $cells = foreach ($op in $ops) {
            $c = @($set | Where-Object { $_.Operation -eq $op -and $_.Timestamp -eq $ts })
            if (-not $c) { '-' }
            else {
                $vals = @($c | Select-Object -ExpandProperty Observed -Unique)
                if ($vals.Count -eq 1) { Fmt $vals[0] }
                else { '**varies by mechanism**' }   # see per-mechanism table
            }
        }
        $out.Add("| **$($TsLabel[$ts])** | " + ($cells -join ' | ') + ' |')
    }
    $out.Add('')
    $out
}

function New-MechanismBreakout {
    param($Rows, [string]$Attribute)
    $set = @($Rows | Where-Object Attribute -eq $Attribute)
    $varying = foreach ($g in ($set | Group-Object Operation, Timestamp)) {
        $vals = @($g.Group | Select-Object -ExpandProperty Observed -Unique)
        if ($vals.Count -gt 1) { $g.Group }
    }
    $varying = @($varying)
    if (-not $varying) { return @() }
    $out = New-Object Collections.Generic.List[string]
    $out.Add("**Where mechanism matters (`$$Attribute`):**")
    $out.Add('')
    $out.Add('| Operation | Timestamp | Mechanism | Result |')
    $out.Add('|---|---|---|---|')
    foreach ($r in ($varying | Sort-Object Operation, Timestamp, Mechanism)) {
        $out.Add("| $($OpLabel[$r.Operation]) | $($TsLabel[$r.Timestamp]) | ``$($r.Mechanism)`` | $(Fmt $r.Observed) |")
    }
    $out.Add('')
    $out
}

# CORE = the canonical mechanism only: one fresh file, one operation, the
# ordinary way. Other mechanisms are variations, reported separately so the
# core table stays the plain statement of the rule.
$normalAll = @($summary | Where-Object Variant -eq 'normal')
$normal    = @($normalAll | Where-Object { "$($_.IsCore)" -eq 'True' })
if (-not $normal) { $normal = $normalAll }   # tolerate summaries without IsCore
$stomp  = @($summary | Where-Object Variant -eq 'timestomped')

$md = New-Object Collections.Generic.List[string]
$md.Add("# $Title")
$md.Add('')
if ($FingerprintJson -and (Test-Path -LiteralPath $FingerprintJson)) {
    $fp = Get-Content -Raw -LiteralPath $FingerprintJson | ConvertFrom-Json
    $md.Add("**Build:** $($fp.OSCaption) $($fp.DisplayVersion), build $($fp.FullBuild)  ")
    $md.Add("**ntfs.sys SHA256:** ``$($fp.NtfsDriver.SHA256)``  ")
    $md.Add("**Last access:** $($fp.Fsutil_DisableLastAccess)  ")
    $md.Add("**Tunneling:** $($fp.TunnelingEffective)")
    $md.Add('')
}
$md.Add('Results apply to the `ntfs.sys` build above. See `docs/exceptions.md` for')
$md.Add('conditions under which these rules do not hold.')
$md.Add('')
$md.Add('---')
$md.Add('')

# ------------------------------------------------------------- SECTION 1
$md.Add('## 1. Normal behaviour')
$md.Add('')
$md.Add('**This is the primary result.** Files created and operated on conventionally,')
$md.Add('with no prior timestamp manipulation. These tables describe what an analyst')
$md.Add('sees on an ordinary system.')
$md.Add('')
foreach ($attr in 'SI','FN') {
    $attrName = if ($attr -eq 'SI') { 'STANDARD_INFORMATION' } else { 'FILE_NAME' }
    $md.Add('### `$' + $attrName + '`')
    $md.Add('')
    New-RuleTable -Rows $normal -Attribute $attr | ForEach-Object { $md.Add($_) }
}

# Mechanism variations: non-canonical mechanisms whose result differs from the
# core value. An empty list is itself a finding -- it says the rule holds
# regardless of how the operation was performed.
$coreIdx = @{}
foreach ($r in $normal) { $coreIdx["$($r.Attribute)|$($r.Operation)|$($r.Timestamp)"] = $r.Observed }
$variations = foreach ($r in @($normalAll | Where-Object { "$($_.IsCore)" -ne 'True' })) {
    $k = "$($r.Attribute)|$($r.Operation)|$($r.Timestamp)"
    if ($coreIdx.ContainsKey($k) -and $coreIdx[$k] -ne $r.Observed) {
        [pscustomobject]@{ Attribute=$r.Attribute; Operation=$r.Operation; Mechanism=$r.Mechanism
                           Timestamp=$r.Timestamp; Core=$coreIdx[$k]; Variant=$r.Observed }
    }
}
$variations = @($variations)

$md.Add('### Mechanism variations')
$md.Add('')
if ($variations) {
    $md.Add('Every other mechanism tested produced the core result **except** these.')
    $md.Add('They are tool behaviour, not NTFS rules, and belong on the exceptions list:')
    $md.Add('')
    $md.Add('| Attr | Operation | Timestamp | Core result | Mechanism | Its result |')
    $md.Add('|---|---|---|---|---|---|')
    foreach ($v in ($variations | Sort-Object Attribute, Operation, Timestamp, Mechanism)) {
        $md.Add("| ``$($v.Attribute)`` | $($OpLabel[$v.Operation]) | $($TsLabel[$v.Timestamp]) | $(Fmt $v.Core) | ``$($v.Mechanism)`` | $(Fmt $v.Variant) |")
    }
} else {
    $md.Add('**None.** Every mechanism tested produced the same result as the canonical one,')
    $md.Add('for every operation and every timestamp.')
}
$md.Add('')

$indet = @($normal | Where-Object Determinacy -eq 'INDETERMINATE_FROM_NORMAL')
if ($indet) {
    $md.Add('> **On "indeterminate" cells.** `$SI` and `$FN` hold identical values on a')
    $md.Add('> normally created file, so "unchanged" and "repopulated from `$SI`" produce')
    $md.Add('> the same observation. The *observed value* is correct and unambiguous; only')
    $md.Add('> the mechanism behind it cannot be read off a normal file. See section 3.')
    $md.Add('')
}

# ------------------------------------------------------------- SECTION 2
$md.Add('---')
$md.Add('')
$md.Add('## 2. Behaviour after timestomping')
$md.Add('')
$md.Add('A separate condition, not a correction to section 1. Here `$SI` was set to')
$md.Add('distinct historical values **before** the operation, then the same operation')
$md.Add('was performed. This shows how prior tampering changes what a later operation')
$md.Add('leaves behind.')
$md.Add('')
if ($stomp) {
    $deltas = foreach ($s in $stomp) {
        $n = @($normal | Where-Object {
            $_.Attribute -eq $s.Attribute -and $_.Operation -eq $s.Operation -and
            $_.Mechanism -eq $s.Mechanism -and $_.Timestamp -eq $s.Timestamp })[0]
        if ($n -and $n.Observed -ne $s.Observed) {
            [pscustomobject]@{ Attribute=$s.Attribute; Operation=$s.Operation
                               Mechanism=$s.Mechanism; Timestamp=$s.Timestamp
                               Normal=$n.Observed; Timestomped=$s.Observed }
        }
    }
    $deltas = @($deltas)
    if ($deltas) {
        $md.Add('| Attr | Operation | Mechanism | Timestamp | Normal | After timestomping |')
        $md.Add('|---|---|---|---|---|---|')
        foreach ($d in ($deltas | Sort-Object Attribute, Operation, Timestamp)) {
            $md.Add("| ``$($d.Attribute)`` | $($OpLabel[$d.Operation]) | ``$($d.Mechanism)`` | $($TsLabel[$d.Timestamp]) | $(Fmt $d.Normal) | $(Fmt $d.Timestomped) |")
        }
        $md.Add('')
        $md.Add('Differences here are mostly **resolution, not divergence**: a cell that reads')
        $md.Add('_indeterminate_ under normal conditions becomes decidable once `$SI` and `$FN`')
        $md.Add('have been forced apart. Where a value genuinely differs, it is called out below.')
    } else {
        $md.Add('_No cell differed between the normal and timestomped conditions._')
    }
    $md.Add('')
    $md.Add('### Full timestomped tables')
    $md.Add('')
    foreach ($attr in 'SI','FN') {
        $md.Add("#### ``$attr`` after timestomping")
        $md.Add('')
        New-RuleTable -Rows $stomp -Attribute $attr | ForEach-Object { $md.Add($_) }
    }
} else {
    $md.Add('_Timestomped variant not present in this run._')
    $md.Add('')
}

# ------------------------------------------------------------- SECTION 3
$md.Add('---')
$md.Add('')
$md.Add('## 3. Mechanism notes')
$md.Add('')
$md.Add('**These are laboratory inferences, not field observations.** Each describes how')
$md.Add('NTFS populates a value internally, established only by forcing `$SI` and `$FN`')
$md.Add('apart. On an ordinary file the analyst sees the section 1 value. Do not read')
$md.Add('this section as a correction to section 1.')
$md.Add('')
if ($indet) {
    $md.Add('| Attr | Operation | Timestamp | Observed normally | Underlying mechanism |')
    $md.Add('|---|---|---|---|---|')
    foreach ($r in ($indet | Sort-Object Attribute, Operation, Timestamp | Select-Object Attribute,Operation,Timestamp,Observed,MechanismFromTimestomp -Unique)) {
        $md.Add("| ``$($r.Attribute)`` | $($OpLabel[$r.Operation]) | $($TsLabel[$r.Timestamp]) | $(Fmt $r.Observed) | $(Fmt $r.MechanismFromTimestomp) |")
    }
    $md.Add('')
} else {
    $md.Add('_Every cell was determinate from normal observation; no inference required._')
    $md.Add('')
}

# ------------------------------------------------------------- SECTION 4
$md.Add('---')
$md.Add('')
$md.Add('## 4. Differences from the baseline charts')
$md.Add('')
$diffs = @($normal | Where-Object Result -eq 'DIFFERS')
if ($diffs) {
    $md.Add('Compared against the published Windows 11 22H2 charts, using the **normal**')
    $md.Add('condition only.')
    $md.Add('')
    $md.Add('| Attr | Operation | Mechanism | Timestamp | 22H2 chart | Observed |')
    $md.Add('|---|---|---|---|---|---|')
    foreach ($d in ($diffs | Sort-Object Attribute, Operation, Timestamp)) {
        $md.Add("| ``$($d.Attribute)`` | $($OpLabel[$d.Operation]) | ``$($d.Mechanism)`` | $($TsLabel[$d.Timestamp]) | $(Fmt $d.Expected22H2) | $(Fmt $d.Observed) |")
    }
} else {
    $md.Add('_No differences from the baseline charts in the normal condition._')
}
$md.Add('')

$md -join "`n" | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Host "Report written: $OutFile"
Write-Host ("  normal cells: {0}   timestomped cells: {1}   indeterminate: {2}   differs: {3}" -f
            $normal.Count, $stomp.Count, $indet.Count, $diffs.Count)
Get-Item -LiteralPath $OutFile
