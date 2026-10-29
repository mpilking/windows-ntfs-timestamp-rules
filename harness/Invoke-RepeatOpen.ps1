# Runs on the guest (Invoke-Command -FilePath). Repeat-open test for the
# Explorer object-ID finding:
#   A  no object ID   -> open, then open again
#   B  object ID created beforehand with fsutil -> open once
# Each open is performed by Invoke-ExplorerDriver.ps1 (real double-click) in
# the console user's session, one scheduled task per open, so the live $SI and
# object ID can be read between opens.
param([string]$Label = 'repeatopen01', [int]$GapSeconds = 20)

$ErrorActionPreference = 'Stop'
$repo   = 'C:\NtfsTest\repo'
$runDir = "C:\NtfsTest\run\$Label"
$auto   = Join-Path $runDir 'automation'
$raw    = Join-Path $runDir 'raw'
if (Test-Path $runDir) { throw "$runDir already exists" }
New-Item -ItemType Directory -Force $auto, $raw | Out-Null
Import-Module "$repo\harness\NtfsTimestamps.psm1" -Force

$consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $consoleUser) { throw 'nobody is logged on at the console' }
if (Get-Process LogonUI -ErrorAction SilentlyContinue) { throw 'console is locked' }
& icacls.exe $auto /grant "${consoleUser}:(OI)(CI)M" | Out-Null

$ambient = & "$repo\provision\Set-AmbientConfig.ps1" -Mode CleanRoom
$log = New-Object Collections.Generic.List[string]
function Note([string]$t) { $line = '{0}  {1}' -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff'), $t; $log.Add($line); Write-Host $line }

function Get-ObjectId([string]$Path) {
    $out = & fsutil.exe objectid query $Path 2>&1
    $m = ($out | Out-String) | Select-String -Pattern 'Object ID\s*:\s*([0-9a-f]{32})'
    if ($m) { $m.Matches[0].Groups[1].Value } else { $null }
}
function Get-State([string]$Path) {
    $si = Get-SiTimestamp -Path $Path
    $lnk = Join-Path $env:APPDATA ("Microsoft\Windows\Recent\{0}.lnk" -f (Split-Path -Leaf $Path))
    $lnkInfo = if (Test-Path -LiteralPath $lnk) { Get-Item -LiteralPath $lnk } else { $null }
    $oid = Get-ObjectId $Path
    $lnkHasOid = $null
    if ($lnkInfo -and $oid) {
        $hex = [BitConverter]::ToString([IO.File]::ReadAllBytes($lnk)).Replace('-', '')
        $lnkHasOid = $hex.Contains($oid.ToUpperInvariant())
    }
    [pscustomobject]@{
        ReadUtc       = (Get-Date).ToUniversalTime().ToString('o')
        Created       = $si.Creation.ToString('o')
        Modified      = $si.Modified.ToString('o')
        Access        = $si.Access.ToString('o')
        EntryModified = $si.MftEntryModified.ToString('o')
        ObjectId      = $oid
        RecentLnk     = if ($lnkInfo) { [pscustomobject]@{ Created = $lnkInfo.CreationTimeUtc.ToString('o'); Written = $lnkInfo.LastWriteTimeUtc.ToString('o'); HoldsObjectId = $lnkHasOid } } else { $null }
    }
}

function Invoke-Open([string]$CaseId, [string]$Path) {
    $manifest = Join-Path $auto "$CaseId-manifest.json"
    $result   = Join-Path $auto "$CaseId-result.json"
    $logFile  = Join-Path $auto "$CaseId-driver.log"
    [pscustomobject]@{
        RunLabel = $Label; ResultFile = $result; LogFile = $logFile; CaseGapSeconds = 0; RenameBase = 'unused'
        Cases = @([pscustomobject]@{ CaseId = $CaseId; Operation = 'file_access'; Mechanism = 'explorer_open'
                                     SourcePath = $Path; SourceName = (Split-Path -Leaf $Path); DestDir = $null })
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest -Encoding UTF8

    $taskPath = '\NtfsTimestamps\'; $taskName = "ExplorerDriver_${Label}_$CaseId"
    $psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') `
                -Argument ("--headless `"$psExe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$repo\harness\Invoke-ExplorerDriver.ps1`" -Manifest `"$manifest`"")
    $principal = New-ScheduledTaskPrincipal -UserId $consoleUser -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -Priority 4
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    try {
        Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $result)) {
            Start-Sleep -Seconds 1
            if ($clock.Elapsed.TotalMinutes -gt 5) { Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue; throw "$CaseId driver timed out" }
        }
    } finally { Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
    $r = @((Get-Content -Raw -LiteralPath $result | ConvertFrom-Json).Cases)[0]
    if ($r.Error) { throw "$CaseId failed in the driver: $($r.Error)" }
    $r
}

# ------------------------------------------------------------------ stage
$caseDir = "V:\repeatopen_$([guid]::NewGuid().ToString('N').Substring(0,12))"
New-Item -ItemType Directory $caseDir | Out-Null
$tag = [guid]::NewGuid().ToString('N').Substring(0,8)
$fileA = Join-Path $caseDir "repeatopen_A_$tag.txt"
$fileB = Join-Path $caseDir "repeatopen_B_$tag.txt"
Set-Content -LiteralPath $fileA -Value 'repeat-open test file A' -Encoding ASCII
Set-Content -LiteralPath $fileB -Value 'repeat-open test file B' -Encoding ASCII
Note "staged $fileA, $fileB"
Start-Sleep -Seconds $GapSeconds
$created = (& fsutil.exe objectid create $fileB 2>&1 | Out-String).Trim()
Note "fsutil objectid create B: $(Get-ObjectId $fileB)"
Start-Sleep -Seconds $GapSeconds

& "$repo\harness\Export-Mft.ps1" -Volume 'V:' -OutFile (Join-Path $raw 'before_V-mft.bin') | Out-Null
Note 'before snapshot taken'
Start-Sleep -Seconds 5

# ------------------------------------------------------------------ opens
$steps = New-Object Collections.Generic.List[object]
foreach ($op in @(
    @{ Id = 'A1_open_first';  Path = $fileA },
    @{ Id = 'A2_open_repeat'; Path = $fileA },
    @{ Id = 'B1_open_preexisting_oid'; Path = $fileB })) {
    $before = Get-State $op.Path
    Note ("{0} before: EM {1}  Access {2}  OID {3}" -f $op.Id, $before.EntryModified, $before.Access, $before.ObjectId)
    $r = Invoke-Open -CaseId $op.Id -Path $op.Path
    Start-Sleep -Seconds 2
    $after = Get-State $op.Path
    Note ("{0} window {1} -> {2}" -f $op.Id, $r.OpStartUtc, $r.OpEndUtc)
    Note ("{0} after:  EM {1}  Access {2}  OID {3}  lnk {4}" -f $op.Id, $after.EntryModified, $after.Access, $after.ObjectId, ($after.RecentLnk | ConvertTo-Json -Compress))
    $steps.Add([pscustomobject]@{ CaseId = $op.Id; File = $op.Path; OpStartUtc = $r.OpStartUtc; OpEndUtc = $r.OpEndUtc
                                  DriverLiveSI = $r.LiveSI; DriverSteps = $r.Steps; Before = $before; After = $after })
    Start-Sleep -Seconds $GapSeconds
}

& "$repo\harness\Export-Mft.ps1" -Volume 'V:' -OutFile (Join-Path $raw 'after_V-mft.bin') | Out-Null
Note 'after snapshot taken'

$summary = [pscustomobject]@{
    Label = $Label; ConsoleUser = $consoleUser; CaseDir = $caseDir; FileA = $fileA; FileB = $fileB
    Build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | ForEach-Object { "$($_.CurrentBuildNumber).$($_.UBR)" })
    ObjectIdCreateB = $created; Steps = $steps
    Raw = @(Get-ChildItem $raw -File | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Sha256 = (Get-FileHash $_.FullName).Hash } })
    Log = $log.ToArray()
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDir 'repeat-open.json') -Encoding UTF8
Note "done: $runDir"
