<#
  NtfsTimestamps.psm1
  Live $STANDARD_INFORMATION read/write via Win32 + NT native APIs.

  Why not Get-Item?  .NET exposes only Creation/LastWrite/LastAccess.  The fourth
  $SI value (MFT Entry Modified / "ChangeTime") has no .NET surface, so we go to
  GetFileInformationByHandleEx(FileBasicInfo) for reads and NtSetInformationFile
  (FileBasicInformation) for writes.  SetFileTime() cannot write ChangeTime,
  which is why the timestomp precondition uses the ntdll path instead.

  OBSERVER EFFECT: handles are opened with FILE_READ_ATTRIBUTES only (never
  GENERIC_READ) so that measuring a file does not update its own access time.
#>

$script:Sig = @'
using System;
using System.Runtime.InteropServices;

public static class NtfsTs
{
    [StructLayout(LayoutKind.Sequential)]
    public struct FILE_BASIC_INFO
    {
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public long ChangeTime;
        public uint FileAttributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_STATUS_BLOCK
    {
        public IntPtr Status;
        public IntPtr Information;
    }

    public const uint FILE_READ_ATTRIBUTES      = 0x0080;
    public const uint FILE_WRITE_ATTRIBUTES     = 0x0100;
    public const uint FILE_SHARE_ALL            = 0x0007;
    public const uint OPEN_EXISTING             = 3;
    public const uint FILE_FLAG_BACKUP_SEMANTICS= 0x02000000;
    public const int  FileBasicInfo             = 0;
    public const int  FileBasicInformation      = 4;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileInformationByHandleEx(IntPtr hFile,
        int FileInformationClass, out FILE_BASIC_INFO lpFileInformation, uint dwBufferSize);

    [DllImport("ntdll.dll")]
    public static extern int NtSetInformationFile(IntPtr FileHandle,
        out IO_STATUS_BLOCK IoStatusBlock, ref FILE_BASIC_INFO FileInformation,
        uint Length, int FileInformationClass);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr hObject);
}
'@

if (-not ('NtfsTs' -as [type])) { Add-Type -TypeDefinition $script:Sig -Language CSharp }

function Get-LongPath {
    # Build the long-path (\\?\) prefix from char codes.  Literal backslash pairs
    # are fragile when this file is authored through cross-shell heredocs.
    param([string]$p)
    $bs = [string][char]92
    if ($p.StartsWith($bs + $bs)) { return ($bs + $bs + '?' + $bs + 'UNC' + $p.Substring(1)) }
    return ($bs + $bs + '?' + $bs + $p)
}

function Open-TsHandle {
    param([string]$Path, [switch]$ForWrite)
    $access = if ($ForWrite) { [NtfsTs]::FILE_READ_ATTRIBUTES -bor [NtfsTs]::FILE_WRITE_ATTRIBUTES }
              else           { [NtfsTs]::FILE_READ_ATTRIBUTES }
    $h = [NtfsTs]::CreateFileW($Path, $access, [NtfsTs]::FILE_SHARE_ALL, [IntPtr]::Zero,
                               [NtfsTs]::OPEN_EXISTING, [NtfsTs]::FILE_FLAG_BACKUP_SEMANTICS, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::new(-1)) {
        throw "CreateFileW failed on '$Path' (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    $h
}

function Get-SiTimestamp {
<#  .SYNOPSIS  Read all four $SI timestamps, including MFT Entry Modified.  #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][string]$Path)
    process {
        $full = (Resolve-Path -LiteralPath $Path).ProviderPath
        $h = Open-TsHandle -Path (Get-LongPath $full)
        try {
            $info = New-Object NtfsTs+FILE_BASIC_INFO
            $size = [Runtime.InteropServices.Marshal]::SizeOf([type]'NtfsTs+FILE_BASIC_INFO')
            if (-not [NtfsTs]::GetFileInformationByHandleEx($h, [NtfsTs]::FileBasicInfo, [ref]$info, $size)) {
                throw "GetFileInformationByHandleEx failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
            }
            [pscustomobject]@{
                Path             = $full
                Source           = 'Win32:GetFileInformationByHandleEx'
                Attribute        = 'SI'
                Creation         = [DateTime]::FromFileTimeUtc($info.CreationTime)
                Modified         = [DateTime]::FromFileTimeUtc($info.LastWriteTime)
                Access           = [DateTime]::FromFileTimeUtc($info.LastAccessTime)
                MftEntryModified = [DateTime]::FromFileTimeUtc($info.ChangeTime)
            }
        } finally { [void][NtfsTs]::CloseHandle($h) }
    }
}

function Set-SiTimestamp {
<#  .SYNOPSIS  Timestomp all four $SI values (precondition for $FN provenance tests).
    .DESCRIPTION  Uses NtSetInformationFile so ChangeTime can be written too;
                  SetFileTime() cannot do this.  Pass UTC DateTimes.  #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [datetime]$Creation, [datetime]$Modified, [datetime]$Access, [datetime]$MftEntryModified
    )
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    if (-not $PSCmdlet.ShouldProcess($full, 'Set $SI timestamps')) { return }
    $h = Open-TsHandle -Path (Get-LongPath $full) -ForWrite
    try {
        $info = New-Object NtfsTs+FILE_BASIC_INFO
        $size = [Runtime.InteropServices.Marshal]::SizeOf([type]'NtfsTs+FILE_BASIC_INFO')
        [void][NtfsTs]::GetFileInformationByHandleEx($h, [NtfsTs]::FileBasicInfo, [ref]$info, $size)
        if ($PSBoundParameters.ContainsKey('Creation'))         { $info.CreationTime   = $Creation.ToFileTimeUtc() }
        if ($PSBoundParameters.ContainsKey('Modified'))         { $info.LastWriteTime  = $Modified.ToFileTimeUtc() }
        if ($PSBoundParameters.ContainsKey('Access'))           { $info.LastAccessTime = $Access.ToFileTimeUtc() }
        if ($PSBoundParameters.ContainsKey('MftEntryModified')) { $info.ChangeTime     = $MftEntryModified.ToFileTimeUtc() }
        $iosb = New-Object NtfsTs+IO_STATUS_BLOCK
        $st = [NtfsTs]::NtSetInformationFile($h, [ref]$iosb, [ref]$info, $size, [NtfsTs]::FileBasicInformation)
        if ($st -ne 0) { throw ("NtSetInformationFile failed, NTSTATUS 0x{0:X8}" -f $st) }
    } finally { [void][NtfsTs]::CloseHandle($h) }
}

function Get-DotNetTimestamp {
<#  .SYNOPSIS  Independent cross-check of 3 of the 4 $SI values via .NET.  #>
    param([Parameter(Mandatory)][string]$Path)
    $i = Get-Item -LiteralPath $Path -Force
    [pscustomobject]@{
        Path             = $i.FullName
        Source           = '.NET:FileSystemInfo'
        Attribute        = 'SI'
        Creation         = $i.CreationTimeUtc
        Modified         = $i.LastWriteTimeUtc
        Access           = $i.LastAccessTimeUtc
        MftEntryModified = $null   # not exposed by .NET -- by design, not an error
    }
}

Export-ModuleMember -Function Get-SiTimestamp, Set-SiTimestamp, Get-DotNetTimestamp
