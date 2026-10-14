<#
  Compare-Fingerprint.ps1
  Validates that the test environment did not drift mid-run.

  Capture a fingerprint immediately BEFORE the first operation and immediately
  AFTER the last one, then diff them.  If ntfs.sys, the UBR, or any ambient
  filesystem setting changed partway through, every result in that run is
  suspect and must be discarded rather than explained.  A silent patch during a
  long run is exactly the kind of thing that produces an unreproducible
  "behaviour change" finding.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Before,
    [Parameter(Mandatory)][string]$After,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

$b = Get-Content -Raw -LiteralPath $Before | ConvertFrom-Json
$a = Get-Content -Raw -LiteralPath $After  | ConvertFrom-Json

# Fields that MUST be identical across a valid run. CapturedUtc and the volume
# free-space figures are expected to move, so they are deliberately excluded.
$Critical = @(
    'OSCaption','OSProductType','DisplayVersion','BuildNumber','UBR','FullBuild',
    'EditionID','TimeZone','Elevated',
    'Fsutil_DisableLastAccess','Fsutil_Disable8dot3','Fsutil_MftZone',
    'Reg_NtfsDisableLastAccessUpdate','Reg_MaximumTunnelEntries',
    'Reg_MaximumTunnelEntryAgeInSeconds','TunnelingEffective'
)

$findings = New-Object Collections.Generic.List[object]

foreach ($f in $Critical) {
    $bv = $b.$f; $av = $a.$f
    if ("$bv" -ne "$av") {
        $findings.Add([pscustomobject]@{ Severity='CRITICAL'; Field=$f; Before="$bv"; After="$av" })
    }
}

# Both layers matter: the filesystem driver, and the callers that decide how it
# is invoked. An Explorer or shell update can change a measured result while
# ntfs.sys is untouched.
foreach ($bin in 'NtfsDriver','NtOsKernel','Explorer','Shell32','WindowsStorage','SearchIndexer') {
    $bh = $b.$bin.SHA256; $ah = $a.$bin.SHA256
    if ("$bh" -ne "$ah") {
        $findings.Add([pscustomobject]@{
            Severity = 'CRITICAL'
            Field    = "$bin.SHA256"
            Before   = "$($b.$bin.FileVersion) $bh"
            After    = "$($a.$bin.FileVersion) $ah"
        })
    }
}

$bu = @($b.InstalledUpdates); $au = @($a.InstalledUpdates)
$newUpdates = $au | Where-Object { $_ -and $_ -notin $bu }
if ($newUpdates) {
    $findings.Add([pscustomobject]@{
        Severity='CRITICAL'; Field='InstalledUpdates'; Before='(baseline)'; After=($newUpdates -join '; ')
    })
}

$ba = @($b.InterferingAgents); $aa = @($a.InterferingAgents)
$newAgents = $aa | Where-Object { $_ -and $_ -notin $ba }
if ($newAgents) {
    $findings.Add([pscustomobject]@{
        Severity='WARNING'; Field='InterferingAgents'; Before=($ba -join ', '); After=($newAgents -join ', ')
    })
}

$critical = @($findings | Where-Object Severity -eq 'CRITICAL')

$lines = New-Object Collections.Generic.List[string]
$lines.Add('# Fingerprint Comparison')
$lines.Add('')
$lines.Add("- Before: ``$Before`` ($($b.CapturedUtc))")
$lines.Add("- After:  ``$After`` ($($a.CapturedUtc))")
$lines.Add('')
if ($findings.Count -eq 0) {
    $lines.Add('**RESULT: STABLE.** No drift detected. Run is valid.')
} else {
    $verdict = if ($critical.Count -gt 0) { 'INVALID' } else { 'VALID WITH WARNINGS' }
    $lines.Add("**RESULT: $verdict** - $($critical.Count) critical, $($findings.Count - $critical.Count) warning.")
    $lines.Add('')
    $lines.Add('| Severity | Field | Before | After |')
    $lines.Add('|---|---|---|---|')
    foreach ($f in $findings) { $lines.Add("| $($f.Severity) | $($f.Field) | $($f.Before) | $($f.After) |") }
}
$report = $lines -join "`n"

if ($OutFile) { $report | Set-Content -LiteralPath $OutFile -Encoding UTF8 }
Write-Host $report

if ($critical.Count -gt 0) {
    Write-Error "Environment drifted mid-run ($($critical.Count) critical change(s)). Discard these results and re-run."
    exit 1
}
exit 0
