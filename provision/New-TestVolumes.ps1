<#
  New-TestVolumes.ps1
  Creates the NTFS test volumes as VHDX files from *inside* the guest OS.

  Deliberately hypervisor-agnostic: VHDX creation and attach are native to
  Windows 10/11 via Mount-DiskImage / diskpart and do NOT require the Hyper-V
  role. The same script therefore yields byte-identical volume geometry on
  VMware Workstation, Hyper-V, VirtualBox, Parallels or bare metal, which is
  what makes the published results reproducible by a third party.

  Uses New-VHD when the Hyper-V PowerShell module happens to be present (it is
  faster and exposes sector size), and falls back to diskpart otherwise.
#>
[CmdletBinding()]
param(
    [string]$VhdRoot = 'C:\NtfsTest\vhd',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
    throw 'Must run elevated: VHDX attach and volume formatting require administrator.'
}

# Volume matrix. V64 vs V256 isolates volume size; V64 vs V64K isolates
# allocation-unit size. Without the third volume those two factors are
# confounded and a "small volumes behave differently" result is uninterpretable.
$Volumes = @(
    [pscustomobject]@{ Name='V64';  Letter='V'; SizeGB=64;  ClusterBytes=4096;  Label='NTFSTEST64';  Note='under 128GB threshold' }
    [pscustomobject]@{ Name='V256'; Letter='W'; SizeGB=256; ClusterBytes=4096;  Label='NTFSTEST256'; Note='over 128GB threshold' }
    [pscustomobject]@{ Name='V64K'; Letter='X'; SizeGB=64;  ClusterBytes=65536; Label='NTFSTEST64K'; Note='cluster-size control' }
)

New-Item -ItemType Directory -Force -Path $VhdRoot | Out-Null
$hyperv = [bool](Get-Command New-VHD -ErrorAction SilentlyContinue)
Write-Host "VHDX creation path: $(if ($hyperv) {'New-VHD (Hyper-V module present)'} else {'diskpart (no Hyper-V required)'})"

function New-VhdxFile {
    param([string]$Path, [int]$SizeGB)
    if ($hyperv) {
        New-VHD -Path $Path -SizeBytes ($SizeGB * 1GB) -Dynamic | Out-Null
        return
    }
    $mb = $SizeGB * 1024
    $lines = @(
        ('create vdisk file="{0}" maximum={1} type=expandable' -f $Path, $mb)
    )
    $tmp = [IO.Path]::GetTempFileName()
    Set-Content -LiteralPath $tmp -Value $lines -Encoding ASCII
    $out = & diskpart.exe /s $tmp 2>&1 | Out-String
    Remove-Item -LiteralPath $tmp -Force
    if ($out -notmatch 'successfully') { throw "diskpart failed creating ${Path}:`n$out" }
}

$results = foreach ($v in $Volumes) {
    $path = Join-Path $VhdRoot "$($v.Name).vhdx"

    if (Test-Path -LiteralPath $path) {
        if (-not $Force) {
            throw "$path already exists. Re-run with -Force to recreate (this destroys prior test data)."
        }
        Write-Host "Recreating $path"
        try { Dismount-DiskImage -ImagePath $path -ErrorAction SilentlyContinue | Out-Null } catch { }
        Remove-Item -LiteralPath $path -Force
    }

    Write-Host "Creating $($v.Name): $($v.SizeGB)GB, $($v.ClusterBytes)B clusters -> $($v.Letter):"
    New-VhdxFile -Path $path -SizeGB $v.SizeGB

    $img  = Mount-DiskImage -ImagePath $path -StorageType VHDX -PassThru
    $disk = $img | Get-DiskImage | Get-Disk

    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false | Out-Null
    New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $v.Letter | Out-Null
    Format-Volume -DriveLetter $v.Letter -FileSystem NTFS -AllocationUnitSize $v.ClusterBytes `
                  -NewFileSystemLabel $v.Label -Confirm:$false -Force | Out-Null

    # Modern Windows DISABLES 8.3 name creation on non-system volumes at format
    # time, while the system volume keeps it ENABLED. Left alone, every test
    # volume would carry a single $FILE_NAME attribute and the short-name $FN
    # behaviour -- which exists on real system volumes -- would go untested.
    # Force it on so the test volumes match a realistic C:.
    # Must happen BEFORE any test file is created: short names are not applied
    # retroactively to existing files.
    & fsutil.exe 8dot3name set "$($v.Letter):" 0 | Out-Null
    $d83 = (& fsutil.exe 8dot3name query "$($v.Letter):") -join ' '
    if ($d83 -notmatch 'is ENABLED') { Write-Warning "8.3 name creation NOT enabled on $($v.Letter): -- `$FN short-name cases will be invalid." }

    $vol = Get-Volume -DriveLetter $v.Letter
    [pscustomobject]@{
        Name           = $v.Name
        VhdxPath       = $path
        DriveLetter    = "$($v.Letter):"
        RequestedGB    = $v.SizeGB
        ActualSizeGB   = [math]::Round($vol.Size / 1GB, 2)
        ClusterBytes   = $v.ClusterBytes
        Label          = $v.Label
        UnderThreshold = $vol.Size -lt 128GB
        DiskNumber     = $disk.Number
        ShortNames8dot3 = if ($d83 -match 'is ENABLED') { 'ENABLED' } else { 'DISABLED' }
        Note           = $v.Note
    }
}

$manifest = Join-Path $VhdRoot 'volumes.json'
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest -Encoding UTF8
Write-Host "`nManifest: $manifest"
$results | Format-Table Name, DriveLetter, RequestedGB, ActualSizeGB, ClusterBytes, UnderThreshold -AutoSize

Write-Host @"

NEXT: exclude these volumes from Defender before running any test, or results
      will be contaminated by real-time scanning:

  Add-MpPreference -ExclusionPath 'V:\','W:\','X:\'

VHDX attach is NOT persistent across a guest reboot. Reattach with:

  .\Mount-TestVolumes.ps1
"@
