<#
  Operations.psm1
  Activity generators: the operation x mechanism matrix.

  The mechanism is a FIRST-CLASS VARIABLE, not an implementation detail. The
  22H2 baseline shows a volume move via CLI setting $SI Creation to the time of
  the move, while the same logical operation via Explorer cut/paste inherits it
  from the original. Folding mechanisms together would have hidden that.

  Every generator returns a uniform result object carrying the tolerance window
  (OpStartUtc/OpEndUtc). Comparison is against that window, never against an
  exact value, because access times in Windows 11 have been observed to differ
  from the moment of activity by a few seconds.

  NAMING: every case gets a GUID-suffixed name in its own GUID-named directory.
  This is not cosmetic. NTFS file tunneling caches a deleted or renamed file's
  creation time for ~15s keyed on NAME + DIRECTORY, so reusing a name across
  cases would silently transplant one case's creation timestamp into the next
  and the result would look entirely plausible.
#>

Set-StrictMode -Version Latest

$script:ExplorerMechanisms = @('explorer_copy','explorer_cutpaste','explorer_recycle')

function New-OpResult {
    param($Operation, $Mechanism, $Start, $End, $PathBefore, $PathAfter, $Extra)
    [pscustomobject]@{
        Operation   = $Operation
        Mechanism   = $Mechanism
        OpStartUtc  = $Start
        OpEndUtc    = $End
        PathBefore  = $PathBefore
        PathAfter   = $PathAfter
        Extra       = $Extra
    }
}

function Invoke-Timed {
    <# Brackets an action so the comparison window spans the whole operation. #>
    param([scriptblock]$Action)
    $start = (Get-Date).ToUniversalTime()
    & $Action
    $end = (Get-Date).ToUniversalTime()
    @{ Start = $start; End = $end }
}

function New-CaseDirectory {
    <# Fresh, uniquely named directory per case. See NAMING note above. #>
    param([Parameter(Mandatory)][string]$Root)
    $d = Join-Path $Root ('case_' + [guid]::NewGuid().ToString('N').Substring(0,12))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $d
}

function New-CaseFileName {
    param([string]$Prefix = 'tf')
    # Long enough to force an 8.3 short name, so both $FN attributes exist.
    "$Prefix`_LongEnoughToForceShortName_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
}

# ---------------------------------------------------------------- CREATE
function Invoke-OpCreate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [ValidateSet('dotnet','powershell','cmd_echo','fsutil')][string]$Mechanism = 'powershell',
        [string]$Content = 'baseline content for timestamp testing'
    )
    $path = Join-Path $Directory (New-CaseFileName 'create')
    $t = Invoke-Timed {
        switch ($Mechanism) {
            'powershell' { Set-Content -LiteralPath $path -Value $Content -NoNewline }
            'dotnet'     { [IO.File]::WriteAllText($path, $Content) }
            'cmd_echo'   { & cmd.exe '/c' "echo $Content> `"$path`"" | Out-Null }
            'fsutil'     { & fsutil.exe file createnew $path 256 | Out-Null }
        }
    }
    New-OpResult 'file_create' $Mechanism $t.Start $t.End $null $path $null
}

# ---------------------------------------------------------------- ACCESS
function Invoke-OpAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('powershell','dotnet','cmd_type')][string]$Mechanism = 'powershell'
    )
    $t = Invoke-Timed {
        switch ($Mechanism) {
            'powershell' { Get-Content -LiteralPath $Path -Raw | Out-Null }
            'dotnet'     { [void][IO.File]::ReadAllText($Path) }
            'cmd_type'   { & cmd.exe '/c' "type `"$Path`"" | Out-Null }
        }
    }
    New-OpResult 'file_access' $Mechanism $t.Start $t.End $Path $Path $null
}

# ---------------------------------------------------------------- MODIFY
function Invoke-OpModify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('powershell_append','dotnet_append','dotnet_overwrite')][string]$Mechanism = 'powershell_append'
    )
    $t = Invoke-Timed {
        switch ($Mechanism) {
            'powershell_append' { Add-Content -LiteralPath $Path -Value 'appended' -NoNewline }
            'dotnet_append'     { [IO.File]::AppendAllText($Path, 'appended') }
            'dotnet_overwrite'  { [IO.File]::WriteAllText($Path, 'overwritten content') }
        }
    }
    New-OpResult 'file_modify' $Mechanism $t.Start $t.End $Path $Path $null
}

# ---------------------------------------------------------------- RENAME
function Invoke-OpRename {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('powershell','dotnet','cmd_ren')][string]$Mechanism = 'powershell'
    )
    $dir     = Split-Path -Parent $Path
    $newName = New-CaseFileName 'renamed'
    $newPath = Join-Path $dir $newName
    $t = Invoke-Timed {
        switch ($Mechanism) {
            'powershell' { Rename-Item -LiteralPath $Path -NewName $newName }
            'dotnet'     { [IO.File]::Move($Path, $newPath) }
            'cmd_ren'    { & cmd.exe '/c' "ren `"$Path`" `"$newName`"" | Out-Null }
        }
    }
    New-OpResult 'file_rename' $Mechanism $t.Start $t.End $Path $newPath $null
}

# ---------------------------------------------------------------- COPY
function Invoke-OpCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DestDirectory,
        [ValidateSet('powershell','dotnet','cmd_copy','xcopy','robocopy','robocopy_dat')][string]$Mechanism = 'powershell'
    )
    $leaf = Split-Path -Leaf $Path
    $dest = Join-Path $DestDirectory $leaf
    $srcDir = Split-Path -Parent $Path
    $t = Invoke-Timed {
        switch ($Mechanism) {
            'powershell'   { Copy-Item -LiteralPath $Path -Destination $dest }
            'dotnet'       { [IO.File]::Copy($Path, $dest, $true) }
            'cmd_copy'     { & cmd.exe '/c' "copy /Y `"$Path`" `"$dest`"" | Out-Null }
            'xcopy'        { & cmd.exe '/c' "xcopy /Y /Q `"$Path`" `"$DestDirectory\`"" | Out-Null }
            'robocopy'     { & robocopy.exe $srcDir $DestDirectory $leaf /NJH /NJS /NP /NFL /NDL | Out-Null }
            'robocopy_dat' { & robocopy.exe $srcDir $DestDirectory $leaf /COPY:DAT /NJH /NJS /NP /NFL /NDL | Out-Null }
        }
    }
    New-OpResult 'file_copy' $Mechanism $t.Start $t.End $Path $dest $null
}

# ------------------------------------------------------------ MOVE (local)
function Invoke-OpMoveLocal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DestDirectory,
        [ValidateSet('powershell','dotnet','cmd_move')][string]$Mechanism = 'powershell'
    )
    $leaf = Split-Path -Leaf $Path
    $dest = Join-Path $DestDirectory $leaf
    $t = Invoke-Timed {
        switch ($Mechanism) {
            'powershell' { Move-Item -LiteralPath $Path -Destination $dest }
            'dotnet'     { [IO.File]::Move($Path, $dest) }
            'cmd_move'   { & cmd.exe '/c' "move /Y `"$Path`" `"$dest`"" | Out-Null }
        }
    }
    New-OpResult 'file_move_local' $Mechanism $t.Start $t.End $Path $dest $null
}

# ----------------------------------------------------------- MOVE (volume)
function Invoke-OpMoveVolume {
    <#
      A cross-volume move is physically copy + delete. The source and
      destination MUST be on different volumes or this silently degrades into
      a local move and the result is mislabelled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DestDirectory,
        [ValidateSet('powershell','dotnet','cmd_move','robocopy_move')][string]$Mechanism = 'cmd_move'
    )
    $srcRoot = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path).ProviderPath)
    $dstRoot = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $DestDirectory).ProviderPath)
    if ($srcRoot -eq $dstRoot) {
        throw "Invoke-OpMoveVolume requires different volumes; both resolve to $srcRoot."
    }
    $leaf   = Split-Path -Leaf $Path
    $dest   = Join-Path $DestDirectory $leaf
    $srcDir = Split-Path -Parent $Path
    $t = Invoke-Timed {
        switch ($Mechanism) {
            'powershell'    { Move-Item -LiteralPath $Path -Destination $dest }
            'dotnet'        { [IO.File]::Move($Path, $dest) }
            'cmd_move'      { & cmd.exe '/c' "move /Y `"$Path`" `"$dest`"" | Out-Null }
            'robocopy_move' { & robocopy.exe $srcDir $DestDirectory $leaf /MOV /NJH /NJS /NP /NFL /NDL | Out-Null }
        }
    }
    New-OpResult 'file_move_volume' $Mechanism $t.Start $t.End $Path $dest @{ SrcVolume=$srcRoot; DstVolume=$dstRoot }
}

# ------------------------------------------------- ALTERNATE DATA STREAM
function Invoke-OpWriteAds {
    <#
      Writes a NAMED data stream on an existing file.

      An ADS is a second $DATA attribute on the SAME MFT record, so this is an
      in-place operation -- the record is modified but no new record appears,
      and the file's visible content and size are unchanged. A directory
      listing shows neither the stream nor its size.

      That asymmetry is the point: if the record's timestamps move while the
      file appears untouched, an analyst sees a modification with no apparent
      cause.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('powershell_stream','cmd_redirect')][string]$Mechanism = 'powershell_stream',
        [string]$StreamName = 'ads_probe'
    )
    $t = Invoke-Timed {
        switch ($Mechanism) {
            'powershell_stream' { Set-Content -LiteralPath $Path -Stream $StreamName -Value 'hidden stream content' -NoNewline }
            'cmd_redirect'      { & cmd.exe '/c' "echo hidden stream content> `"${Path}:${StreamName}`"" | Out-Null }
        }
    }
    New-OpResult 'file_ads_write' $Mechanism $t.Start $t.End $Path $Path @{ StreamName = $StreamName }
}

# ---------------------------------------------------------------- DELETE
function Invoke-OpDelete {
    <#
      Deletion cases must be sequenced LAST within a volume. The record is read
      after the file is gone, and NTFS recycles deleted records -- creating any
      new file first can overwrite the very evidence being captured.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('powershell','dotnet','cmd_del')][string]$Mechanism = 'powershell'
    )
    $t = Invoke-Timed {
        switch ($Mechanism) {
            'powershell' { Remove-Item -LiteralPath $Path -Force }
            'dotnet'     { [IO.File]::Delete($Path) }
            'cmd_del'    { & cmd.exe '/c' "del /F /Q `"$Path`"" | Out-Null }
        }
    }
    New-OpResult 'file_delete' $Mechanism $t.Start $t.End $Path $null $null
}

function Get-ExplorerMechanismList {
    <#
      Explorer-driven mechanisms require an INTERACTIVE desktop session.
      PowerShell Remoting sessions are non-interactive, so IFileOperation /
      shell automation does not work over a remote session. These cases run
      from the guest console (or a scheduled task set to "run only when user is
      logged on") and are invoked as a separate group by the runner.
    #>
    $script:ExplorerMechanisms
}

Export-ModuleMember -Function Invoke-Op*, New-CaseDirectory, New-CaseFileName, Get-ExplorerMechanismList
