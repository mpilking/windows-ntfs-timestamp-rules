<#
  Invoke-FullRun.ps1
  One-command reproducible pass: provision -> fingerprint -> execute ->
  fingerprint -> validate -> classify -> report.

  The two fingerprints bracket the run. If ntfs.sys, the UBR, or any ambient
  filesystem setting moved partway through, the run is marked INVALID rather
  than published -- a cumulative update landing mid-run would otherwise surface
  later as an unreproducible "behaviour change".
#>
[CmdletBinding()]
param(
    [string]$Repo              = 'C:\NtfsTest\repo',
    [string]$RunRoot           = 'C:\NtfsTest\run',
    [string]$ResultsRoot       = 'C:\NtfsTest\results',
    [string]$VhdRoot           = 'C:\NtfsTest\vhd',
    [string]$PrimaryVolume     = 'V:',
    [string]$SecondaryVolume   = 'W:',
    [int]$SettleSeconds        = 20,
    [int]$LateCaptureMinutes   = 0,
    [string]$CaseRoot,
    [string]$SecondaryCaseRoot,

    # CleanRoom isolates the test volumes from Defender and the indexer.
    # RealisticBaseline leaves a stock Windows install alone -- no exclusions,
    # indexer running -- so the delta against a CleanRoom run is the measured
    # noise floor an analyst actually faces. Exclusions are not realistic in
    # practice, so both conditions are published.
    [ValidateSet('CleanRoom','RealisticBaseline')]
    [string]$AmbientMode = 'CleanRoom',

    # Confine ambient setup to Defender exclusions and leave every service as
    # found. Required when a service state IS the experimental variable -- e.g.
    # isolating the search indexer by disabling it -- since the ambient modes
    # would otherwise overwrite the very condition under test.
    [switch]$AmbientExclusionsOnly,

    [switch]$SkipVolumeRebuild,
    [string]$RunLabel          = ('full_' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
)

$ErrorActionPreference = 'Stop'
Set-Location $Repo
$log = { param($m) Write-Host ("[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss'), $m) }

& $log "=== FULL RUN: $RunLabel ==="

# 1. Pristine volumes. A freshly formatted volume gives clean MFT record
#    numbering and no residue from prior runs.
if (-not $SkipVolumeRebuild) {
    & $log 'provisioning volumes'
    .\provision\New-TestVolumes.ps1 -VhdRoot $VhdRoot -Force *>$null
    $amb = @{}
    if ($AmbientExclusionsOnly) { $amb['ExclusionsOnly'] = $true }
    .\provision\Set-AmbientConfig.ps1 -Mode $AmbientMode -TestVolumes 'V:\','W:\','X:\' @amb *>$null
}
& $log "ambient mode: $AmbientMode"

# 2. Fingerprint BEFORE
& $log 'fingerprint (before)'
.\harness\Get-EnvironmentFingerprint.ps1 -TestVolume 'C:',$PrimaryVolume,$SecondaryVolume -OutDir $ResultsRoot *>$null
$fpBefore = (Get-ChildItem "$ResultsRoot\fingerprint-*.json" | Sort-Object LastWriteTime | Select-Object -Last 1).FullName

# 3. Execute
& $log "executing matrix (settle=${SettleSeconds}s, late=${LateCaptureMinutes}min)"
$extra = @{}
if ($CaseRoot)          { $extra['CaseRoot']          = $CaseRoot }
if ($SecondaryCaseRoot) { $extra['SecondaryCaseRoot'] = $SecondaryCaseRoot }
$run = .\harness\Invoke-TimestampTest.ps1 -PrimaryVolume $PrimaryVolume -SecondaryVolume $SecondaryVolume `
          -WorkDir $RunRoot -SettleSeconds $SettleSeconds -LateCaptureMinutes $LateCaptureMinutes `
          -RunLabel $RunLabel @extra
& $log "executed: $($run.CaseCount) cases, $($run.FailedCount) failed"

# 4. Fingerprint AFTER
& $log 'fingerprint (after)'
.\harness\Get-EnvironmentFingerprint.ps1 -TestVolume 'C:',$PrimaryVolume,$SecondaryVolume -OutDir $ResultsRoot *>$null
$fpAfter = (Get-ChildItem "$ResultsRoot\fingerprint-*.json" | Sort-Object LastWriteTime | Select-Object -Last 1).FullName

# 5. Drift gate
& $log 'validating environment stability'
$driftFile = Join-Path $run.RunDir 'fingerprint-comparison.md'
$driftOk = $true
try   { .\harness\Compare-Fingerprint.ps1 -Before $fpBefore -After $fpAfter -OutFile $driftFile *>$null }
catch { $driftOk = $false }
& $log ("environment: {0}" -f $(if ($driftOk) { 'STABLE' } else { 'DRIFTED -- RESULTS INVALID' }))

# 6. Classify
& $log 'classifying'
$cmp = .\harness\Compare-Results.ps1 -RunJson $run.JsonPath 6>$null

# 7. Report
& $log 'rendering report'
.\harness\New-ResultsReport.ps1 -SummaryCsv (Join-Path $run.RunDir 'summary.csv') `
    -FingerprintJson $fpAfter -Title "NTFS Timestamp Rules - $RunLabel" *>$null

& $log '=== DONE ==='
[pscustomobject]@{
    RunLabel      = $RunLabel
    RunDir        = $run.RunDir
    Cases         = $run.CaseCount
    Failed        = $run.FailedCount
    EnvironmentOk = $driftOk
    Differs       = $cmp.Differs
    Disagreements = $cmp.Disagreements
    Deferred      = $cmp.Deferred
    Report        = (Join-Path $run.RunDir 'results.md')
}
