<#
  Update-RunSnapshots.ps1
  Re-parses a completed run's archived $MFT files and rewrites run.json.

  The operations are NOT re-executed. This is the point of archiving the
  extracted $MFT: a parser fix, a new parser version, or a tool nobody has
  written yet can be applied to evidence already collected, and the original
  run stands. It is also how a third party verifies our conclusions without
  trusting our parsers.

  The original run.json is preserved as run.json.bak-<timestamp> before the
  rewrite, so a re-parse is never destructive.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunJson,
    [string]$ToolRoot    = 'C:\NtfsTest\repo\tools',
    [string]$HarnessRoot = 'C:\NtfsTest\repo\harness'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $HarnessRoot 'Capture.psm1') -Force

$runDir = Split-Path -Parent $RunJson
$run    = Get-Content -Raw -LiteralPath $RunJson | ConvertFrom-Json

# Re-parsing must apply the same scoping the original run did, or a re-parse of
# a system-volume run would re-inflate run.json with every record on the volume.
$caseNames = @{}
foreach ($c in $run.Cases) {
    if ($c.SourceName)                      { $caseNames["$($c.SourceName)"] = $true }
    if ($c.Result -and $c.Result.NameAfter) { $caseNames["$($c.Result.NameAfter)"] = $true }
}
function Select-CaseRecords {
    param($Records)
    @($Records | Where-Object { $caseNames.ContainsKey("$($_.FileName)") })
}

$bak = "$RunJson.bak-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))"
Copy-Item -LiteralPath $RunJson -Destination $bak -Force
Write-Host "Original preserved: $bak"

function Reparse {
    param([string]$Label, $SnapshotSet)
    $out = foreach ($snap in $SnapshotSet) {
        # @($null) has ONE element -- a null. An absent 'Late' set therefore
        # iterates once on nothing unless this guard is here.
        if ($null -eq $snap -or -not $snap.Volume) { continue }
        $drive = $snap.Volume.TrimEnd(':')
        $dir   = Join-Path $runDir ("{0}_{1}" -f $Label, $drive)
        $mft   = Join-Path $dir 'mft.bin'
        if (-not (Test-Path -LiteralPath $mft)) {
            Write-Warning "Missing archived `$MFT: $mft -- leaving $Label/$($snap.Volume) unchanged"
            $snap
            continue
        }

        # Verify the archive still matches what the run recorded.
        $sha = (Get-FileHash -LiteralPath $mft -Algorithm SHA256).Hash
        if ($snap.Sha256 -and $sha -ne $snap.Sha256) {
            throw "Archived `$MFT for $Label/$($snap.Volume) does not match the hash recorded at run time. Evidence has changed; refusing to re-parse."
        }

        $records = @()
        $records += Invoke-MFTECmd      -MftFile $mft -WorkDir $dir -ToolRoot $ToolRoot
        $records += Invoke-Velociraptor -MftFile $mft -WorkDir $dir -ToolRoot $ToolRoot
        $records += Invoke-MftDump      -MftFile $mft -WorkDir $dir -ToolRoot $ToolRoot

        $scoped = Select-CaseRecords $records
        Write-Host ("  {0,-7} {1}  parsed {2}  embedded {3}" -f $Label, $snap.Volume,
                    (($records | Group-Object Tool | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '),
                    @($scoped).Count)
        [pscustomobject]@{ Volume = $snap.Volume; Sha256 = $sha; Records = $scoped }
    }
    @($out)
}

Write-Host 'Re-parsing archived $MFT files...'
$newBefore = Reparse 'before' $run.Snapshots.Before
$newAfter  = Reparse 'after'  $run.Snapshots.After
$newLate   = if (@($run.Snapshots.Late).Count -gt 0) { Reparse 'late' $run.Snapshots.Late } else { @() }

$run.Snapshots.Before = $newBefore
$run.Snapshots.After  = $newAfter
if (@($newLate).Count -gt 0) { $run.Snapshots.Late = $newLate }

$run | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $RunJson -Encoding UTF8
Write-Host "Rewritten: $RunJson"
[pscustomobject]@{ RunJson = $RunJson; Backup = $bak }
