<#
  Compare-Runs.ps1
  Lines up the classified results of two or more runs, cell by cell.

  Used to confirm that repeated passes of the same cases agree: two manual
  Explorer passes, or an automated pass against the manual ones. A cell is one
  attribute x operation x mechanism x variant x timestamp, exactly as in
  summary.csv, so any runs that performed the same cases are comparable.

  A disagreement is listed, never resolved. Two things are reported alongside
  because they are the first to check when cells disagree:

  - Window width. An operator's measured window is tens of seconds; a script's
    is a second or two. A write that lands a few seconds after an operation
    falls inside one and outside the other, and reads as OP_TIME in one run
    and UNCLASSIFIED in the other.
  - Access vs Entry Modified. A cell can agree on OP_TIME while one run shows
    Access written BY the operation (EXACT) and the other shows it written
    shortly after by something else (TRAILS).

  Run Compare-Results.ps1 on each run first; this reads its output.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateCount(2, 16)][string[]]$RunDir,
    [ValidateSet('normal','timestomped','all')][string]$Variant = 'normal',
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

function ConvertTo-UtcTime {
    # run.json holds ISO 8601 strings, or -- for older runs written through
    # PowerShell 5.1 -- "/Date(ms)/" values, which may arrive already parsed.
    param($v)
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) { return $v.ToUniversalTime() }
    if ("$v" -match '^/Date\((-?\d+)\)/$') { return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Matches[1]).UtcDateTime }
    [datetime]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

$runs = New-Object Collections.Generic.List[object]
$seen = @{}
foreach ($d in $RunDir) {
    $dir = (Resolve-Path -LiteralPath $d).ProviderPath
    $sum = Join-Path $dir 'summary.csv'
    if (-not (Test-Path -LiteralPath $sum)) { throw "No summary.csv in $dir -- run Compare-Results.ps1 on that run first." }
    $rows = @(Import-Csv -LiteralPath $sum)
    if ($Variant -ne 'all') { $rows = @($rows | Where-Object Variant -eq $Variant) }

    $label = Split-Path -Leaf $dir
    if ($seen.ContainsKey($label)) { $label = "$label#$($runs.Count + 1)" }
    $seen[$label] = $true

    $meta = $null
    $json = Join-Path $dir 'run.json'
    if (Test-Path -LiteralPath $json) { $meta = Get-Content -Raw -LiteralPath $json | ConvertFrom-Json }
    $driver = if ($meta -and $meta.PSObject.Properties.Name -contains 'Driver' -and $meta.Driver) { $meta.Driver }
              elseif ($meta -and $meta.PSObject.Properties.Name -contains 'Interactive' -and $meta.Interactive) { 'operator' }
              else { 'script' }

    $ave = [ordered]@{}
    $aveCsv = Join-Path $dir 'access-vs-entrymodified.csv'
    if (Test-Path -LiteralPath $aveCsv) {
        foreach ($g in (Import-Csv -LiteralPath $aveCsv | Where-Object { $Variant -eq 'all' -or $_.Variant -eq $Variant } |
                        Group-Object Operation, Mechanism, Variant)) {
            $ave[$g.Name] = (@($g.Group | Select-Object -ExpandProperty Classification -Unique | Sort-Object) -join '/')
        }
    }

    $windows = [ordered]@{}
    if ($meta) {
        foreach ($c in @($meta.Cases)) {
            if (-not $c.Result -or $c.Result.Error) { continue }
            $s = ConvertTo-UtcTime $c.Result.OpStartUtc; $e = ConvertTo-UtcTime $c.Result.OpEndUtc
            if ($s -and $e) { $windows["$($c.Operation), $($c.Mechanism)"] = [math]::Round(($e - $s).TotalSeconds, 1) }
        }
    }

    $runs.Add([pscustomobject]@{
        Label = $label; Dir = $dir; Driver = $driver; Rows = $rows; AccessVsEm = $ave; Windows = $windows
        Index = @{}
    })
    foreach ($r in $rows) { $runs[$runs.Count - 1].Index["$($r.Attribute)|$($r.Operation)|$($r.Mechanism)|$($r.Variant)|$($r.Timestamp)"] = $r }
}

# Cell order follows the first run, then any cells only later runs have.
$keys = New-Object Collections.Generic.List[string]
$keySeen = @{}
foreach ($run in $runs) {
    foreach ($r in $run.Rows) {
        $k = "$($r.Attribute)|$($r.Operation)|$($r.Mechanism)|$($r.Variant)|$($r.Timestamp)"
        if (-not $keySeen.ContainsKey($k)) { $keySeen[$k] = $true; $keys.Add($k) }
    }
}

$cells = New-Object Collections.Generic.List[object]
foreach ($k in $keys) {
    $p = $k.Split('|')
    $row = [ordered]@{ Attribute=$p[0]; Operation=$p[1]; Mechanism=$p[2]; Variant=$p[3]; Timestamp=$p[4] }
    $values = @(); $missing = $false; $toolSplit = $false
    foreach ($run in $runs) {
        $hit = $run.Index[$k]
        if ($hit) {
            $row[$run.Label] = $hit.Observed
            $values += $hit.Observed
            if ($hit.ToolsAgree -eq 'False') { $toolSplit = $true }
        } else {
            $row[$run.Label] = ''
            $missing = $true
        }
    }
    $row['Comparison'] = if ($missing) { 'MISSING' }
                         elseif (@($values | Select-Object -Unique).Count -eq 1) { 'AGREE' }
                         else { 'DIFFERS' }
    $row['ToolSplit'] = $toolSplit
    $cells.Add([pscustomobject]$row)
}

$opKeys = @($runs | ForEach-Object { $_.AccessVsEm.Keys } | Select-Object -Unique)
$aveRows = foreach ($k in $opKeys) {
    $p = $k.Split(',') | ForEach-Object { $_.Trim() }
    $row = [ordered]@{ Operation=$p[0]; Mechanism=$p[1]; Variant=$p[2] }
    $vals = @()
    foreach ($run in $runs) { $v = $run.AccessVsEm[$k]; $row[$run.Label] = $v; $vals += "$v" }
    $row['Comparison'] = if (@($vals | Select-Object -Unique).Count -eq 1) { 'AGREE' } else { 'DIFFERS' }
    [pscustomobject]$row
}

$winKeys = @($runs | ForEach-Object { $_.Windows.Keys } | Select-Object -Unique)
$winRows = foreach ($k in $winKeys) {
    $row = [ordered]@{ Case=$k }
    foreach ($run in $runs) { $row["$($run.Label) (s)"] = $run.Windows[$k] }
    [pscustomobject]$row
}

if (-not $OutFile) { $OutFile = Join-Path $runs[$runs.Count - 1].Dir 'run-comparison.csv' }
$cells | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
$aveFile = [IO.Path]::ChangeExtension($OutFile, $null).TrimEnd('.') + '-access-vs-entrymodified.csv'
@($aveRows) | Export-Csv -LiteralPath $aveFile -NoTypeInformation -Encoding UTF8

$agree   = @($cells | Where-Object Comparison -eq 'AGREE').Count
$differs = @($cells | Where-Object Comparison -eq 'DIFFERS')
$missing = @($cells | Where-Object Comparison -eq 'MISSING')
$aveDiff = @($aveRows | Where-Object Comparison -eq 'DIFFERS')

Write-Host "`n=== RUN COMPARISON ($Variant) ===" -ForegroundColor Cyan
foreach ($run in $runs) { Write-Host ("  {0,-22} {1,-9} {2} cells" -f $run.Label, $run.Driver, @($run.Rows).Count) }
Write-Host ("  cells agree          : {0} of {1}" -f $agree, $cells.Count)
Write-Host ("  cells DIFFER         : {0}" -f $differs.Count) -ForegroundColor $(if ($differs) { 'Yellow' } else { 'Gray' })
Write-Host ("  cells missing a run  : {0}" -f $missing.Count) -ForegroundColor $(if ($missing) { 'Yellow' } else { 'Gray' })
Write-Host ("  Access-vs-EntryMod   : {0} of {1} operations agree" -f (@($aveRows).Count - $aveDiff.Count), @($aveRows).Count) -ForegroundColor $(if ($aveDiff) { 'Yellow' } else { 'Gray' })
Write-Host "`n  $OutFile`n  $aveFile"

$labels = @($runs | ForEach-Object Label)
if ($differs) {
    Write-Host "`n--- DIFFERING CELLS ---" -ForegroundColor Yellow
    $differs | Format-Table (@('Attribute','Operation','Mechanism','Timestamp') + $labels) -AutoSize | Out-Host
}
if ($missing) {
    Write-Host "`n--- CELLS MISSING FROM A RUN (case failed or not performed) ---" -ForegroundColor Yellow
    $missing | Format-Table (@('Attribute','Operation','Mechanism','Timestamp') + $labels) -AutoSize | Out-Host
}
if ($aveDiff) {
    Write-Host "`n--- ACCESS vs ENTRY MODIFIED DIFFERS ---" -ForegroundColor Yellow
    $aveDiff | Format-Table (@('Operation','Mechanism') + $labels) -AutoSize | Out-Host
}
if ($winRows) {
    Write-Host "`n--- MEASURED WINDOW WIDTH ---" -ForegroundColor DarkGray
    $winRows | Format-Table -AutoSize | Out-Host
}

[pscustomobject]@{
    Runs = $labels; Cells = $cells.Count; Agree = $agree; Differs = $differs.Count; Missing = $missing.Count
    AccessVsEmDiffers = $aveDiff.Count; OutFile = $OutFile; Detail = $cells
}
