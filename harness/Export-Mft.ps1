<#
  Export-Mft.ps1
  Extracts a volume's $MFT to a file for offline parsing.

  WHY NOT `icat ... > out.bin`:
  PowerShell's redirection operator treats a native command's stdout as TEXT.
  Redirecting binary through it inserts a BOM and re-encodes the stream, which
  silently corrupts the $MFT -- the damaged file still looks plausible (it has
  a size, it parses partially) but its first four bytes read "??F " instead of
  "FILE" and every offset after that is wrong. Observed on this harness: a
  262,144-byte $MFT came back as 524,336 bytes of mangled UTF-16.

  This copies the raw stdout stream straight to a FileStream instead, so no
  encoding layer ever touches the bytes.

  WHY AN EXTRACTED COPY IS NEEDED AT ALL:
  MFTECmd can read a live locked $MFT through its own raw NTFS access, but
  mft_dump and Mft2Csv cannot -- they need a real file. The extracted copy is
  also the artefact worth archiving: it lets a third party re-derive our
  conclusions with a parser that does not exist yet.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Volume,          # e.g. 'V:'
    [Parameter(Mandatory)][string]$OutFile,
    [string]$IcatPath = 'C:\NtfsTest\repo\tools\SleuthKit\sleuthkit-4.15.0-win32\bin\icat.exe',
    [switch]$SkipFlush
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $IcatPath)) { throw "icat.exe not found at $IcatPath" }

$drive = $Volume.TrimEnd('\').TrimEnd(':') + ':'

# Push cached metadata to disk before reading the on-disk structure. NTFS
# updates MFT records lazily, so a raw read taken immediately after an
# operation can return the pre-operation record.
if (-not $SkipFlush) { & fsutil.exe volume flush $drive | Out-Null }

$parent = Split-Path -Parent $OutFile
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName               = $IcatPath
$psi.Arguments              = "-f ntfs \\.\$drive 0"   # inode 0 is $MFT
$psi.UseShellExecute        = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow         = $true

$proc = [Diagnostics.Process]::Start($psi)
$fs   = [IO.File]::Create($OutFile)
try   { $proc.StandardOutput.BaseStream.CopyTo($fs) }
finally { $fs.Close() }
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()

if ($proc.ExitCode -ne 0) { throw "icat failed on $drive (exit $($proc.ExitCode)): $stderr" }

$bytes = [IO.File]::ReadAllBytes($OutFile)
if ($bytes.Length -eq 0) { throw "Extraction produced an empty file for $drive." }

# Integrity gates. Each has caught a real failure during harness development.
$sig = [Text.Encoding]::ASCII.GetString($bytes, 0, 4)
if ($sig -ne 'FILE') {
    throw "Extracted `$MFT for $drive has signature '$sig', expected 'FILE'. The stream was corrupted (classic symptom of text-mode redirection)."
}
if ($bytes.Length % 1024 -ne 0) {
    throw "Extracted `$MFT for $drive is $($bytes.Length) bytes, not a multiple of the 1024-byte record size. Stream is corrupt or truncated."
}

[pscustomobject]@{
    Volume       = $drive
    OutFile      = (Resolve-Path -LiteralPath $OutFile).ProviderPath
    SizeBytes    = $bytes.Length
    RecordSlots  = $bytes.Length / 1024
    SHA256       = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
    ExtractedUtc = (Get-Date).ToUniversalTime().ToString('o')
}
