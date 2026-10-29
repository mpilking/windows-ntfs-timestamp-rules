<#
  Get-EnvironmentFingerprint.ps1
  Captures every ambient setting known to influence NTFS timestamp behaviour, so
  a future run on a future Windows build can be compared like-for-like.  Emits
  JSON (machine diff) and Markdown (human record).
#>
[CmdletBinding()]
param(
    [string]$OutDir,                         # default: ..\results
    [string[]]$TestVolume = @('C:')
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 leaves $PSScriptRoot empty in the param defaults of a
# [CmdletBinding()] script run with -File; it is set by the time the body runs.
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '..\results' }
$fsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'

function Get-FsutilBehavior {
    param([string]$Name)
    try { (& fsutil.exe behavior query $Name 2>&1 | Out-String).Trim() } catch { "ERROR: $_" }
}

function Get-VolumeFacts {
    param([string]$Drive)
    $letter = $Drive.TrimEnd(':') + ':'
    $vol = Get-Volume -DriveLetter $letter[0] -ErrorAction SilentlyContinue
    $ntfs = (& fsutil.exe fsinfo ntfsinfo $letter 2>&1 | Out-String)
    $bpc  = if ($ntfs -match 'Bytes Per Cluster\s*:\s*(\d+)') { [int]$Matches[1] } else { $null }
    $mftS = if ($ntfs -match 'Mft Valid Data Length\s*:\s*(\S+)') { $Matches[1] } else { $null }
    $ver  = if ($ntfs -match 'NTFS Version\s*:\s*(\S+)')          { $Matches[1] } else { $null }
    [pscustomobject]@{
        Drive              = $letter
        FileSystem         = $vol.FileSystem
        Label              = $vol.FileSystemLabel
        SizeBytes          = $vol.Size
        SizeGB             = if ($vol) { [math]::Round($vol.Size/1GB,2) } else { $null }
        FreeGB             = if ($vol) { [math]::Round($vol.SizeRemaining/1GB,2) } else { $null }
        BytesPerCluster    = $bpc
        NtfsOnDiskVersion  = $ver
        UnderThreshold128G = if ($vol) { $vol.Size -lt 128GB } else { $null }
        MftValidDataLength = $mftS
    }
}

function Get-BinaryFacts {
    # The OS build alone is not precise enough. A cumulative update can ship new
    # binaries while CurrentBuildNumber stays the same (only the UBR moves), so
    # each component's own hash identifies the code that produced a result.
    #
    # NOT just the filesystem driver. Timestamp outcomes depend on the CALLER as
    # much as on NTFS: measured on this build, a cross-volume move via Explorer
    # inherits $SI Creation while the same move via CLI sets it to the move
    # time -- identical ntfs.sys, different result. Opening a file from Explorer
    # updates MFT Entry Modified where a programmatic read does not. The search
    # indexer rewrites Access on files it crawls. Each of those lives outside
    # ntfs.sys and can change independently of it.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $f = Get-Item -LiteralPath $Path
    [pscustomobject]@{
        Path           = $f.FullName
        FileVersion    = $f.VersionInfo.FileVersion
        ProductVersion = $f.VersionInfo.ProductVersion
        SizeBytes      = $f.Length
        LastWriteUtc   = $f.LastWriteTimeUtc.ToString('o')
        SHA256         = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    }
}

$cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$fsp = Get-ItemProperty $fsKey -ErrorAction SilentlyContinue

$interference = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'OneDrive|Dropbox|GoogleDrive|Box|MsMpEng|MpDefenderCoreService|SearchIndexer|CrowdStrike|SentinelOne|carbonblack' } |
    Select-Object -ExpandProperty Name -Unique | Sort-Object

$tools = @{}
foreach ($t in 'MFTECmd.exe','istat.exe','fls.exe','fsutil.exe','robocopy.exe','xcopy.exe') {
    $cmd = Get-Command $t -ErrorAction SilentlyContinue
    $tools[$t] = if ($cmd) {
        [pscustomobject]@{
            Path    = $cmd.Source
            Version = (Get-Item $cmd.Source).VersionInfo.FileVersion
            SHA256  = (Get-FileHash $cmd.Source -Algorithm SHA256).Hash
        }
    } else { $null }
}

$fp = [ordered]@{
    CapturedUtc            = (Get-Date).ToUniversalTime().ToString('o')
    Hostname               = $env:COMPUTERNAME
    OSCaption              = (Get-CimInstance Win32_OperatingSystem).Caption
    OSProductType          = switch ((Get-CimInstance Win32_OperatingSystem).ProductType) { 1 {'Workstation'} 2 {'DomainController'} 3 {'Server'} }
    DisplayVersion         = $cv.DisplayVersion
    BuildNumber            = $cv.CurrentBuildNumber
    UBR                    = $cv.UBR
    FullBuild              = "$($cv.CurrentBuildNumber).$($cv.UBR)"
    EditionID              = $cv.EditionID
    # Filesystem layer
    NtfsDriver             = Get-BinaryFacts "$env:SystemRoot\System32\drivers\ntfs.sys"
    NtOsKernel             = Get-BinaryFacts "$env:SystemRoot\System32\ntoskrnl.exe"
    # Caller layer -- these decide HOW the filesystem is invoked, and measurably
    # change timestamp outcomes without ntfs.sys changing at all.
    Explorer               = Get-BinaryFacts "$env:SystemRoot\explorer.exe"
    Shell32                = Get-BinaryFacts "$env:SystemRoot\System32\shell32.dll"
    WindowsStorage         = Get-BinaryFacts "$env:SystemRoot\System32\windows.storage.dll"
    SearchIndexer          = Get-BinaryFacts "$env:SystemRoot\System32\SearchIndexer.exe"
    InstalledUpdates       = @(Get-HotFix -ErrorAction SilentlyContinue |
                                Sort-Object InstalledOn -Descending |
                                Select-Object -First 10 |
                                ForEach-Object { "$($_.HotFixID) $(if($_.InstalledOn){$_.InstalledOn.ToString('yyyy-MM-dd')})" })
    TimeZone               = (Get-TimeZone).Id
    IsVirtualMachine       = ((Get-CimInstance Win32_ComputerSystem).Model -match 'Virtual|VMware|KVM|Xen')
    Hypervisor             = (Get-CimInstance Win32_ComputerSystem).Manufacturer
    Elevated               = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
    Fsutil_DisableLastAccess = Get-FsutilBehavior 'disablelastaccess'
    Fsutil_Disable8dot3      = Get-FsutilBehavior 'disable8dot3'
    Fsutil_MftZone           = Get-FsutilBehavior 'mftzone'
    Reg_NtfsDisableLastAccessUpdate  = $fsp.NtfsDisableLastAccessUpdate
    Reg_MaximumTunnelEntries         = $fsp.MaximumTunnelEntries
    Reg_MaximumTunnelEntryAgeInSeconds = $fsp.MaximumTunnelEntryAgeInSeconds
    TunnelingEffective     = if ($null -eq $fsp.MaximumTunnelEntryAgeInSeconds) { 'DEFAULT (~15s, ENABLED)' } else { "$($fsp.MaximumTunnelEntryAgeInSeconds)s" }
    InterferingAgents      = $interference
    Volumes                = @($TestVolume | ForEach-Object { Get-VolumeFacts $_ })
    Tools                  = $tools
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$jsonPath = Join-Path $OutDir "fingerprint-$stamp.json"
$fp | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$md = New-Object Text.StringBuilder
[void]$md.AppendLine("# Environment Fingerprint")
[void]$md.AppendLine()
[void]$md.AppendLine("| Property | Value |")
[void]$md.AppendLine("|---|---|")
foreach ($k in $fp.Keys) {
    if ($k -in 'Volumes','Tools') { continue }
    $v = $fp[$k]
    if ($v -is [array]) { $v = ($v -join ', ') }
    [void]$md.AppendLine("| $k | $($v -replace '\r?\n',' / ') |")
}
[void]$md.AppendLine()
[void]$md.AppendLine("## Volumes under test")
[void]$md.AppendLine()
[void]$md.AppendLine("| Drive | FS | SizeGB | BytesPerCluster | <128GB |")
[void]$md.AppendLine("|---|---|---|---|---|")
foreach ($v in $fp.Volumes) {
    [void]$md.AppendLine("| $($v.Drive) | $($v.FileSystem) | $($v.SizeGB) | $($v.BytesPerCluster) | $($v.UnderThreshold128G) |")
}
$mdPath = Join-Path $OutDir "fingerprint-$stamp.md"
$md.ToString() | Set-Content -LiteralPath $mdPath -Encoding UTF8

if ($fp.InterferingAgents) {
    Write-Warning "Sync/AV/indexer agents running: $($fp.InterferingAgents -join ', '). These touch test files and can corrupt results. Exclude the test volume or use a clean VM."
}
if (-not $fp.Elevated) { Write-Warning "Not elevated. Raw volume reads and VHDX operations will fail." }

Write-Host "Fingerprint written:`n  $jsonPath`n  $mdPath"
[pscustomobject]$fp
