<#
  Mount-TestVolumes.ps1
  Reattaches the VHDX test volumes after a guest reboot.

  VHDX attachment is NOT persistent across a reboot. Without this the drive
  letters are simply absent and a run fails at the first file operation, which
  looks like a harness fault rather than an unmounted disk.

  Reads volumes.json written by New-TestVolumes.ps1, so sizes, cluster sizes
  and drive letters come from the recorded manifest rather than being
  re-specified (and possibly re-specified wrongly) here.
#>
[CmdletBinding()]
param(
    [string]$VhdRoot = 'C:\NtfsTest\vhd',
    [switch]$Detach
)

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
    throw 'Must run elevated: VHDX attach requires administrator.'
}

$manifest = Join-Path $VhdRoot 'volumes.json'
if (-not (Test-Path -LiteralPath $manifest)) {
    throw "No manifest at $manifest. Run New-TestVolumes.ps1 first."
}
$volumes = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json

$results = foreach ($v in $volumes) {
    if (-not (Test-Path -LiteralPath $v.VhdxPath)) {
        [pscustomobject]@{ Name=$v.Name; Expected=$v.DriveLetter; Status='VHDX MISSING'; Path=$v.VhdxPath }
        continue
    }

    if ($Detach) {
        try { Dismount-DiskImage -ImagePath $v.VhdxPath | Out-Null
              [pscustomobject]@{ Name=$v.Name; Expected=$v.DriveLetter; Status='detached'; Path=$v.VhdxPath } }
        catch { [pscustomobject]@{ Name=$v.Name; Expected=$v.DriveLetter; Status="detach failed: $($_.Exception.Message)"; Path=$v.VhdxPath } }
        continue
    }

    $img = Get-DiskImage -ImagePath $v.VhdxPath
    if (-not $img.Attached) { $img = Mount-DiskImage -ImagePath $v.VhdxPath -StorageType VHDX -PassThru | Get-DiskImage }

    $letter = $v.DriveLetter.TrimEnd(':')
    $vol    = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue

    # Windows does not always restore the original drive letter on reattach.
    # Re-assert it from the manifest so paths baked into a run stay valid.
    if (-not $vol) {
        $part = Get-Disk -Number ($img | Get-Disk).Number | Get-Partition |
                Where-Object { $_.Type -ne 'Reserved' } | Select-Object -First 1
        if ($part) {
            Set-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter $letter
            $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        }
    }

    # 8.3 creation is a per-volume flag and must stay ENABLED for $FN
    # short-name cases to be valid. Re-check rather than assume it survived.
    $d83 = if ($vol) { ((& fsutil.exe 8dot3name query "${letter}:") -join ' ') } else { '' }

    [pscustomobject]@{
        Name     = $v.Name
        Expected = $v.DriveLetter
        Status   = if ($vol) { 'attached' } else { 'ATTACH FAILED' }
        SizeGB   = if ($vol) { [math]::Round($vol.Size/1GB,2) } else { $null }
        Label    = if ($vol) { $vol.FileSystemLabel } else { $null }
        ShortNames = if ($d83 -match 'is ENABLED') { 'ENABLED' } elseif ($d83) { 'DISABLED' } else { '' }
        Path     = $v.VhdxPath
    }
}

$results | Format-Table Name, Expected, Status, SizeGB, Label, ShortNames -AutoSize

$bad = @($results | Where-Object { $_.Status -notin 'attached','detached' })
$noShort = @($results | Where-Object { $_.ShortNames -eq 'DISABLED' })
if ($noShort) {
    Write-Warning ("8.3 short names DISABLED on: {0}. `$FN short-name cases will be invalid; re-run New-TestVolumes.ps1." -f (($noShort.Expected) -join ', '))
}
if ($bad) { Write-Error ("{0} volume(s) not in the expected state." -f $bad.Count) }
$results
