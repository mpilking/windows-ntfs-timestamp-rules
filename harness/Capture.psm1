<#
  Capture.psm1
  Extracts a volume's $MFT and parses it with every automated parser, returning
  one normalised record set per tool.

  Each parser names its columns differently and mft_dump omits MFT Entry
  Modified entirely. Normalising here means the diff engine compares
  like-for-like and a missing value stays $null rather than being quietly
  coerced to something comparable.
#>

Set-StrictMode -Version Latest

function ConvertTo-Utc {
    <# Parsers emit several formats. A value that cannot be parsed returns $null
       rather than a wrong DateTime -- silent misparsing would corrupt verdicts. #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    [datetime]$dt = [datetime]::MinValue
    if ([datetime]::TryParse($v, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt)) {
        return [datetime]::SpecifyKind($dt, [DateTimeKind]::Utc)
    }
    return $null
}

function ConvertTo-IsoString {
    <#
      Timestamps are stored as round-trip ISO 8601 strings ('o', 7 fractional
      digits), NEVER as DateTime objects.

      PowerShell 5.1's ConvertTo-Json serialises a DateTime as
      "/Date(<milliseconds>)/", which truncates NTFS's 100 ns granularity to
      milliseconds. Interpolating a DateTime into a string ("$d") is worse --
      the default format carries no fractional part at all. Either path
      destroys exactly the detail the sub-second analysis depends on, and does
      so silently: the values still look like valid timestamps.
    #>
    param($Dt)
    if ($null -eq $Dt) { return $null }
    ([datetime]$Dt).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function New-TsRecord {
    param($Tool,$Entry,$Name,$Parent,$SiC,$SiM,$SiA,$SiE,$FnC,$FnM,$FnA,$FnE,$Extra)
    $SiC = ConvertTo-IsoString $SiC; $SiM = ConvertTo-IsoString $SiM
    $SiA = ConvertTo-IsoString $SiA; $SiE = ConvertTo-IsoString $SiE
    $FnC = ConvertTo-IsoString $FnC; $FnM = ConvertTo-IsoString $FnM
    $FnA = ConvertTo-IsoString $FnA; $FnE = ConvertTo-IsoString $FnE
    [pscustomobject]@{
        Tool               = $Tool
        EntryNumber        = [int]$Entry
        FileName           = $Name
        ParentPath         = $Parent
        SI_Created         = $SiC
        SI_Modified        = $SiM
        SI_Access          = $SiA
        SI_EntryModified   = $SiE
        FN_Created         = $FnC
        FN_Modified        = $FnM
        FN_Access          = $FnA
        FN_EntryModified   = $FnE
        Extra              = $Extra
    }
}

function Invoke-MFTECmd {
    param([string]$MftFile,[string]$WorkDir,[string]$ToolRoot)
    $out = Join-Path $WorkDir 'mftecmd.csv'
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    & "$ToolRoot\MFTECmd\MFTECmd.exe" -f $MftFile --csv $WorkDir --csvf 'mftecmd.csv' *> $null
    if (-not (Test-Path -LiteralPath $out)) { Write-Warning 'MFTECmd produced no output'; return @() }
    foreach ($r in (Import-Csv -LiteralPath $out)) {
        $si = @{
            C = ConvertTo-Utc $r.Created0x10;    M = ConvertTo-Utc $r.LastModified0x10
            A = ConvertTo-Utc $r.LastAccess0x10; E = ConvertTo-Utc $r.LastRecordChange0x10
        }
        $fnRaw = @{
            C = ConvertTo-Utc $r.Created0x30;    M = ConvertTo-Utc $r.LastModified0x30
            A = ConvertTo-Utc $r.LastAccess0x30; E = ConvertTo-Utc $r.LastRecordChange0x30
        }

        # MFTECmd OMITS a 0x30 column when that $FN value is IDENTICAL to its
        # 0x10 counterpart -- a noise-reduction convention, not missing data.
        # Velociraptor and mft_dump emit 0x30 unconditionally. Taken literally,
        # MFTECmd's blanks make it look as though the parsers disagree on every
        # untampered file, when in fact they agree exactly. Backfill from 0x10
        # and record that the value was inferred rather than read.
        $inferred = @()
        foreach ($k in 'C','M','A','E') {
            if ($null -eq $fnRaw[$k] -and $null -ne $si[$k]) { $fnRaw[$k] = $si[$k]; $inferred += $k }
        }

        New-TsRecord 'MFTECmd' $r.EntryNumber $r.FileName $r.ParentPath `
            $si.C $si.M $si.A $si.E `
            $fnRaw.C $fnRaw.M $fnRaw.A $fnRaw.E `
            @{ InUse = $r.InUse; IsDirectory = $r.IsDirectory
               Fn0x30InferredFrom0x10 = ($inferred -join ',') }
    }
}

function Invoke-Velociraptor {
    param([string]$MftFile,[string]$WorkDir,[string]$ToolRoot)
    $f = $MftFile.Replace('\','/')
    $q = "SELECT EntryNumber, FullPath, FileName, Created0x10, LastModified0x10, LastAccess0x10, " +
         "LastRecordChange0x10, Created0x30, LastModified0x30, LastAccess0x30, LastRecordChange0x30 " +
         "FROM parse_mft(filename='$f', accessor='file')"
    # jsonl, not json: Velociraptor streams results in batches and `--format
    # json` emits one JSON array PER BATCH, so the concatenated output is not a
    # single valid document. jsonl gives one object per line, which parses
    # deterministically regardless of how the result set is chunked.
    $lines = & "$ToolRoot\velociraptor.exe" --nobanner query $q --format jsonl 2>$null
    if (-not $lines) { Write-Warning 'Velociraptor produced no output'; return @() }
    $parsed = foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $line | ConvertFrom-Json } catch { Write-Warning "Velociraptor: unparsable line skipped"; continue }
    }
    foreach ($r in $parsed) {
        $leaf = if ($r.PSObject.Properties.Name -contains 'FileName' -and $r.FileName) { $r.FileName }
                else { Split-Path -Leaf $r.FullPath }
        New-TsRecord 'Velociraptor' $r.EntryNumber $leaf $r.FullPath `
            (ConvertTo-Utc $r.Created0x10) (ConvertTo-Utc $r.LastModified0x10) `
            (ConvertTo-Utc $r.LastAccess0x10) (ConvertTo-Utc $r.LastRecordChange0x10) `
            (ConvertTo-Utc $r.Created0x30) (ConvertTo-Utc $r.LastModified0x30) `
            (ConvertTo-Utc $r.LastAccess0x30) (ConvertTo-Utc $r.LastRecordChange0x30) $null
    }
}

function Invoke-MftDump {
    param([string]$MftFile,[string]$WorkDir,[string]$ToolRoot)
    $out = Join-Path $WorkDir 'mftdump.csv'
    & "$ToolRoot\mft_dump.exe" -o csv -f $out --no-confirm-overwrite $MftFile *> $null
    if (-not (Test-Path -LiteralPath $out)) { Write-Warning 'mft_dump produced no output'; return @() }
    foreach ($r in (Import-Csv -LiteralPath $out)) {
        # Orphaned and some system records carry an empty FullPath; Split-Path
        # throws on an empty string rather than returning nothing.
        $leaf = if ([string]::IsNullOrWhiteSpace($r.FullPath)) { '' } else { Split-Path -Leaf $r.FullPath }
        # NOTE: mft_dump exposes no MFT Entry Modified for either attribute.
        # Those stay $null; the diff engine skips rather than guesses.
        New-TsRecord 'mft_dump' $r.EntryId $leaf $r.FullPath `
            (ConvertTo-Utc $r.StandardInfoCreated) (ConvertTo-Utc $r.StandardInfoLastModified) `
            (ConvertTo-Utc $r.StandardInfoLastAccess) $null `
            (ConvertTo-Utc $r.FileNameCreated) (ConvertTo-Utc $r.FileNameLastModified) `
            (ConvertTo-Utc $r.FileNameLastAccess) $null `
            @{ HardLinkCount = $r.HardLinkCount; IsDeleted = $r.IsDeleted }
    }
}

function Get-MftSnapshot {
<#
  .SYNOPSIS  Extract a volume's $MFT and parse it with every automated parser.
  .OUTPUTS   Snapshot object: metadata plus Records (all tools, flat).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Volume,
        [Parameter(Mandatory)][string]$WorkDir,
        [string]$ToolRoot    = 'C:\NtfsTest\repo\tools',
        [string]$HarnessRoot = 'C:\NtfsTest\repo\harness',
        [string]$Label       = 'snapshot'
    )
    $drive = $Volume.TrimEnd('\').TrimEnd(':') + ':'
    $dir   = Join-Path $WorkDir ("{0}_{1}" -f $Label, $drive.TrimEnd(':'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $mft = Join-Path $dir 'mft.bin'
    $ex  = & (Join-Path $HarnessRoot 'Export-Mft.ps1') -Volume $drive -OutFile $mft `
                -IcatPath "$ToolRoot\SleuthKit\sleuthkit-4.15.0-win32\bin\icat.exe"

    $records = @()
    $records += Invoke-MFTECmd      -MftFile $mft -WorkDir $dir -ToolRoot $ToolRoot
    $records += Invoke-Velociraptor -MftFile $mft -WorkDir $dir -ToolRoot $ToolRoot
    $records += Invoke-MftDump      -MftFile $mft -WorkDir $dir -ToolRoot $ToolRoot

    [pscustomobject]@{
        Label        = $Label
        Volume       = $drive
        CapturedUtc  = (Get-Date).ToUniversalTime()
        MftFile      = $mft
        MftSha256    = $ex.SHA256
        MftSizeBytes = $ex.SizeBytes
        Records      = $records
        ToolCounts   = ($records | Group-Object Tool | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
    }
}

function Select-SnapshotRecord {
<#  .SYNOPSIS  Find one file's record from each tool within a snapshot.
    Matches on file name, which is unique per case by construction (GUID
    suffixes), avoiding reliance on entry numbers that can be reused. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$FileName
    )
    $Snapshot.Records | Where-Object { $_.FileName -eq $FileName }
}

# The individual parser wrappers are exported so archived $MFT files can be
# re-parsed later (Update-RunSnapshots.ps1) without re-running a whole capture.
Export-ModuleMember -Function Get-MftSnapshot, Select-SnapshotRecord, ConvertTo-Utc,
                              Invoke-MFTECmd, Invoke-Velociraptor, Invoke-MftDump
