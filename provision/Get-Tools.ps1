<#
  Get-Tools.ps1
  Downloads the third-party parsers and records their SHA256 in
  tools/tool-hashes.json.

  Binaries are deliberately NOT vendored into the repository: each has its own
  license and release cadence, and "which build produced this result" has to
  stay auditable. The pinned hash file is committed; the binaries are not.

  On a normal run the downloaded file is checked against the pinned hash and
  the script FAILS on mismatch rather than silently proceeding -- a parser
  changing underneath a published result set is exactly the kind of drift this
  study exists to detect. Use -Update to deliberately re-pin.

  The test VM has no internet by design (host-only networking). Run this on the
  host, then stage with Copy-Item -ToSession.
#>
[CmdletBinding()]
param(
    [string]$ToolDir,                        # default: ..\tools
    [string]$HashFile,                       # default: ..\tools\tool-hashes.json
    [switch]$Update
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Windows PowerShell 5.1 leaves $PSScriptRoot empty in the param defaults of a
# [CmdletBinding()] script run with -File; it is set by the time the body runs.
if (-not $ToolDir)  { $ToolDir  = Join-Path $PSScriptRoot '..\tools' }
if (-not $HashFile) { $HashFile = Join-Path $PSScriptRoot '..\tools\tool-hashes.json' }

$Tools = @(
    [pscustomobject]@{
        Name='MFTECmd'; Version='net9'
        Url='https://download.ericzimmermanstools.com/net9/MFTECmd.zip'
        File='MFTECmd.zip'; Extract=$true
        Note='Eric Zimmerman. Framework-dependent .NET 9 build; guest needs the .NET 9 Desktop Runtime.'
    }
    [pscustomobject]@{
        Name='SleuthKit'; Version='4.15.0'
        Url='https://github.com/sleuthkit/sleuthkit/releases/download/sleuthkit-4.15.0/sleuthkit-4.15.0-win32.zip'
        File='sleuthkit-4.15.0-win32.zip'; Extract=$true
        Note='Volume/disk-level parsing (istat, fls, mmls). Cannot parse a standalone $MFT file. A detached .asc signature is published alongside.'
    }
    [pscustomobject]@{
        Name='Mft2Csv'; Version='v2.0.0.51'
        Url='https://github.com/jschicht/Mft2Csv/releases/download/v2.0.0.51/Mft2Csv_v2.0.0.51.zip'
        File='Mft2Csv_v2.0.0.51.zip'; Extract=$true
        Note='Joakim Schicht. GUI-driven: no documented CLI, so it is NOT part of the automated pipeline. Used as a MANUAL SPOT-CHECK on a sample of records per run, recorded in the run notes.'
    }
    [pscustomobject]@{
        Name='Velociraptor'; Version='v0.77.2'
        Url='https://github.com/Velocidex/velociraptor/releases/download/v0.77.2/velociraptor-v0.77.2-windows-amd64.exe'
        File='velociraptor.exe'; Extract=$false
        Note='Go. Automated second opinion covering all 8 timestamps via VQL parse_mft(). Single static binary, no runtime dependency. A detached .sig is published alongside.'
    }
    [pscustomobject]@{
        Name='DotNetRuntime9'; Version='9.0-latest'
        Url='https://aka.ms/dotnet/9.0/dotnet-runtime-win-x64.exe'
        File='dotnet-runtime-9-win-x64.exe'; Extract=$false
        Note='MFTECmd is a framework-dependent net9.0 build requiring Microsoft.NETCore.App 9.0. The guest has no internet, so the runtime is staged from the host. Silent install: /install /quiet /norestart'
    }
    [pscustomobject]@{
        Name='VCRedist2015_2022'; Version='17-latest'
        Url='https://aka.ms/vs/17/release/vc_redist.x64.exe'
        File='vc_redist.x64.exe'; Extract=$false
        Note='mft_dump is a Rust x86_64-pc-windows-msvc build and needs vcruntime140.dll, which is absent on a clean Windows install. Without it the process exits 0xC0000135 (STATUS_DLL_NOT_FOUND) with no message. Silent install: /install /quiet /norestart'
    }
    [pscustomobject]@{
        Name='mft_dump'; Version='v0.7.0'
        Url='https://github.com/omerbenamram/mft/releases/download/v0.7.0/mft_dump-v0.7.0-x86_64-pc-windows-msvc.exe'
        File='mft_dump.exe'; Extract=$false
        Note='Rust. Single static binary, no runtime dependency; used for automated re-verification of archived $MFT files.'
    }
)

New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null

$pinned = @{}
if (Test-Path -LiteralPath $HashFile) {
    (Get-Content -Raw -LiteralPath $HashFile | ConvertFrom-Json).tools |
        ForEach-Object { $pinned[$_.name] = $_ }
}

$records = foreach ($t in $Tools) {
    $dest = Join-Path $ToolDir $t.File
    Write-Host "[$($t.Name)] $($t.Url)"
    Invoke-WebRequest -Uri $t.Url -OutFile $dest -UseBasicParsing -TimeoutSec 300

    $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
    $size = (Get-Item -LiteralPath $dest).Length

    if ($pinned.ContainsKey($t.Name) -and -not $Update) {
        if ($pinned[$t.Name].sha256 -ne $hash) {
            throw @"
HASH MISMATCH for $($t.Name).
  pinned   : $($pinned[$t.Name].sha256)
  retrieved: $hash
The upstream artifact changed. Do not proceed: results produced with a
different parser build are not comparable. Investigate, then re-pin with
-Update if the change is legitimate.
"@
        }
        Write-Host "  hash matches pin" -ForegroundColor Green
    }

    if ($t.Extract) {
        $out = Join-Path $ToolDir $t.Name
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
        Expand-Archive -LiteralPath $dest -DestinationPath $out -Force
    }

    Write-Host ("  {0:N2} MB  {1}" -f ($size/1MB), $hash.Substring(0,16) + '...')

    [pscustomobject]@{
        name       = $t.Name
        version    = $t.Version
        url        = $t.Url
        file       = $t.File
        sha256     = $hash
        size_bytes = $size
        retrieved  = (Get-Date).ToUniversalTime().ToString('o')
        note       = $t.Note
    }
}

[pscustomobject]@{
    description = 'Pinned third-party parser builds. A hash change invalidates comparison with previously published results.'
    tools       = @($records)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $HashFile -Encoding UTF8

Write-Host "`nPins written: $HashFile"
$records | Format-Table name, version, @{n='MB';e={[math]::Round($_.size_bytes/1MB,2)}}, @{n='sha256';e={$_.sha256.Substring(0,24)+'...'}} -AutoSize
