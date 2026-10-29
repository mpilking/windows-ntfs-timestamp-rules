<#
  Invoke-ExplorerDriver.ps1
  Performs the Explorer cases with real mouse and keyboard input, inside the
  logged-on user's desktop session.

  Not run directly. Invoke-ExplorerTest.ps1 -Driver Automated stages the cases,
  takes the before snapshots, writes a manifest, and launches this script
  through a scheduled task with an interactive token (LogonType Interactive).
  That is the only way to reach the desktop from PowerShell Remoting or
  PowerShell Direct, both of which run without one. The task runs as the
  console user, elevated: Windows drops injected input while a
  higher-integrity window has focus, and an elevated console is often left
  open on a test VM. The operations are still performed by the user's own
  unelevated explorer.exe, and anything it launches -- Notepad, for case 02 --
  inherits that, as it would for an operator.

  DESIGN RULE: automation sets the stage; the operation itself is real input.
  COM (Shell.Application) opens and closes folder windows, and UI Automation
  locates items on screen -- the preparation an operator does before pressing
  Enter. Everything inside the measured window is a click, a drag or a
  keystroke delivered through SendInput, so Explorer runs the code path it
  runs for a person. Performing the operation through COM verbs (CopyHere,
  MoveHere, InvokeVerb) would be testing a different mechanism.

  FAIL CLOSED: every step verifies that it happened -- the window opened, the
  item was drawn on screen, the point about to be clicked belongs to the
  expected window and item, the window had focus before a keystroke, and the
  file ended up where the case says it should. A step that cannot be verified
  marks the case failed, and a failed case is excluded from classification
  rather than producing a result nobody can vouch for.

  Results are written to the file named in the manifest. Progress is appended
  to the manifest's log file, which the launcher relays.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Manifest
)

$ErrorActionPreference = 'Stop'
$m = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json

function Write-Log {
    param([string]$Text)
    $line = '{0}  {1}' -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff'), $Text
    for ($i = 0; $i -lt 5; $i++) {
        try { [IO.File]::AppendAllText($m.LogFile, $line + [Environment]::NewLine); return }
        catch { Start-Sleep -Milliseconds 50 }
    }
}
function Get-UtcIso { (Get-Date).ToUniversalTime().ToString('o') }

Write-Log "driver started: pid $PID, session $([Diagnostics.Process]::GetCurrentProcess().SessionId), user $env:USERDOMAIN\$env:USERNAME"

# ---------------------------------------------------------------- native
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class NtfsExplorerNative
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public INPUTUNION u; }

    const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    const uint MOUSEEVENTF_MOVE = 0x0001, MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
    const uint MOUSEEVENTF_VIRTUALDESK = 0x4000, MOUSEEVENTF_ABSOLUTE = 0x8000;
    const uint KEYEVENTF_EXTENDEDKEY = 0x0001, KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004;

    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hgt, bool repaint);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern uint GetDoubleClickTime();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, ref RECT r, uint winIni);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();

    public static string SetDpiAware()
    {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return "per-monitor-v2"; } catch { }
        try { if (SetProcessDPIAware()) return "system-aware"; } catch { }
        return "unchanged";
    }

    public static RECT WorkArea() { RECT r = new RECT(); SystemParametersInfo(0x0030, 0, ref r, 0); return r; }
    public static string Title(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetWindowText(h, sb, sb.Capacity); return sb.ToString(); }
    public static string ClassOf(IntPtr h) { StringBuilder sb = new StringBuilder(256); GetClassName(h, sb, sb.Capacity); return sb.ToString(); }
    public static uint ProcessOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }

    // GA_ROOT. A dialog is top-level, so its root is itself.
    public static IntPtr RootAt(int x, int y)
    {
        POINT p; p.X = x; p.Y = y;
        IntPtr w = WindowFromPoint(p);
        return w == IntPtr.Zero ? w : GetAncestor(w, 2);
    }
    public static IntPtr ForegroundRoot()
    {
        IntPtr f = GetForegroundWindow();
        return f == IntPtr.Zero ? f : GetAncestor(f, 2);
    }
    public static List<IntPtr> TopWindows()
    {
        List<IntPtr> list = new List<IntPtr>();
        EnumWindows(delegate (IntPtr h, IntPtr l) { if (IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }

    // Brings a window to the top of the z-order without activating it.
    // Toggling TOPMOST is not subject to the foreground lock that blocks
    // SetForegroundWindow from a background process; activation then comes
    // from a real click, as it would for a person.
    public static void Raise(IntPtr h)
    {
        const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_SHOWWINDOW = 0x0040;
        SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    }

    static void Send(params INPUT[] inputs)
    {
        uint n = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        if (n != inputs.Length)
            throw new InvalidOperationException("SendInput delivered " + n + " of " + inputs.Length +
                " events (Win32 " + Marshal.GetLastWin32Error() + "); is the desktop locked?");
    }
    static INPUT Mouse(int x, int y, uint extra)
    {
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
        INPUT i = new INPUT();
        i.type = INPUT_MOUSE;
        i.u.mi.dx = (int)Math.Round((x - vx) * 65535.0 / (vw - 1));
        i.u.mi.dy = (int)Math.Round((y - vy) * 65535.0 / (vh - 1));
        i.u.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | extra;
        return i;
    }
    public static void MoveTo(int x, int y)   { Send(Mouse(x, y, 0)); }
    public static void LeftDown(int x, int y) { Send(Mouse(x, y, MOUSEEVENTF_LEFTDOWN)); }
    public static void LeftUp(int x, int y)   { Send(Mouse(x, y, MOUSEEVENTF_LEFTUP)); }
    public static POINT Cursor() { POINT p; GetCursorPos(out p); return p; }

    static bool Extended(ushort vk) { return vk == 0x2D || vk == 0x2E || (vk >= 0x21 && vk <= 0x28); }
    static INPUT Key(ushort vk, bool up)
    {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = vk;
        uint f = up ? KEYEVENTF_KEYUP : 0;
        if (Extended(vk)) f |= KEYEVENTF_EXTENDEDKEY;
        i.u.ki.dwFlags = f;
        return i;
    }
    public static void KeyDown(ushort vk) { Send(Key(vk, false)); }
    public static void KeyUp(ushort vk)   { Send(Key(vk, true)); }
    public static void Tap(ushort vk)     { Send(Key(vk, false)); Thread.Sleep(40); Send(Key(vk, true)); }
    public static void Chord(ushort mod, ushort vk)
    {
        Send(Key(mod, false)); Thread.Sleep(40);
        Send(Key(vk, false));  Thread.Sleep(40);
        Send(Key(vk, true));   Thread.Sleep(40);
        Send(Key(mod, true));
    }
    public static void TypeText(string s)
    {
        foreach (char c in s)
        {
            INPUT d = new INPUT(); d.type = INPUT_KEYBOARD; d.u.ki.wScan = c; d.u.ki.dwFlags = KEYEVENTF_UNICODE;
            INPUT u = d; u.u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            Send(d); Send(u);
            Thread.Sleep(15);
        }
    }
    // Never leave a modifier held in the user's session after a failure.
    public static void ReleaseModifiers()
    {
        try { Send(Key(0x10, true), Key(0x11, true), Key(0x12, true)); } catch { }
    }
}
'@

$VK = @{ Shift=0x10; Ctrl=0x11; Enter=0x0D; Escape=0x1B; F2=0x71; Delete=0x2E; C=0x43; V=0x56; W=0x57; X=0x58 }

# DPI awareness first, before anything measures the screen: UI Automation then
# reports physical pixels, which is what SendInput and WindowFromPoint use.
$dpiMode = [NtfsExplorerNative]::SetDpiAware()

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

Import-Module (Join-Path $PSScriptRoot 'NtfsTimestamps.psm1') -Force
$Shell = New-Object -ComObject Shell.Application

# ---------------------------------------------------------------- helpers
$script:Steps = $null
$script:ButtonDown = $false
$script:ShiftDown  = $false

function Step {
    param([string]$Text)
    $script:Steps.Add(('{0} {1}' -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff'), $Text))
    Write-Log "    $Text"
}
function Fail {
    param([string]$Check, [string]$Detail)
    throw "self-check failed [$Check]: $Detail"
}
function Wait-Until {
    # Variable names are deliberately unusual: the condition script block
    # resolves variables through the caller's scope.
    param([scriptblock]$Condition, [double]$TimeoutSeconds = 10, [int]$PollMs = 100)
    $__wuClock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $__wuResult = & $Condition
        if ($__wuResult) { return $__wuResult }
        Start-Sleep -Milliseconds $PollMs
    } while ($__wuClock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return $null
}
function Get-NormPath { param([string]$p) "$p".TrimEnd('\').ToLowerInvariant() }

function Find-FolderWindow {
    param([string]$Path, [IntPtr[]]$Exclude = @())
    $want = Get-NormPath $Path
    foreach ($w in @($Shell.Windows())) {
        try {
            $p = $w.Document.Folder.Self.Path
            if ((Get-NormPath $p) -eq $want) {
                $h = [IntPtr][int64]$w.HWND
                if ($Exclude -notcontains $h) { return [pscustomobject]@{ Hwnd=$h; Com=$w; Path=$p } }
            }
        } catch { }
    }
    $null
}

function Open-FolderWindow {
    param([string]$Path, [IntPtr[]]$Exclude = @())
    $Shell.Open($Path)
    $win = Wait-Until { Find-FolderWindow -Path $Path -Exclude $Exclude } -TimeoutSeconds 15
    if (-not $win) { Fail 'open-window' "no Explorer window reported $Path within 15 s" }
    if (-not (Wait-Until { [NtfsExplorerNative]::IsWindow($win.Hwnd) } -TimeoutSeconds 5)) { Fail 'open-window' "window for $Path is not a live window" }
    Step ("opened {0} as window 0x{1:x}" -f $Path, $win.Hwnd.ToInt64())
    $win
}

function Close-FolderWindow {
    param($Window)
    if ($Window) { try { $Window.Com.Quit() } catch { } }
}

function Set-WindowLayout {
    # Source on the left, destination on the right, never overlapping, so a
    # drag has a clear path and every click point is unambiguous.
    param($Source, $Dest)
    $wa = [NtfsExplorerNative]::WorkArea()
    $areaW = $wa.Right - $wa.Left; $areaH = $wa.Bottom - $wa.Top
    foreach ($win in @($Source, $Dest)) {
        if ($win -and ([NtfsExplorerNative]::IsIconic($win.Hwnd) -or [NtfsExplorerNative]::IsZoomed($win.Hwnd))) {
            [void][NtfsExplorerNative]::ShowWindow($win.Hwnd, 9)   # SW_RESTORE
        }
    }
    $half = [int]($areaW / 2)
    if ($Dest) {
        [void][NtfsExplorerNative]::MoveWindow($Source.Hwnd, $wa.Left, $wa.Top, $half, $areaH, $true)
        [void][NtfsExplorerNative]::MoveWindow($Dest.Hwnd, $wa.Left + $half, $wa.Top, $areaW - $half, $areaH, $true)
        [NtfsExplorerNative]::Raise($Dest.Hwnd)
    } else {
        [void][NtfsExplorerNative]::MoveWindow($Source.Hwnd, $wa.Left, $wa.Top, [int]($areaW * 0.6), $areaH, $true)
    }
    [NtfsExplorerNative]::Raise($Source.Hwnd)
    Start-Sleep -Milliseconds 600
}

function Get-RectText { param($r) '{0:0},{1:0} {2:0}x{3:0}' -f $r.Left, $r.Top, $r.Width, $r.Height }

function Test-ElementAtPoint {
    # True when the deepest element under the point is $Element or one of its
    # descendants. Confirms a click will land on the item, not beside it.
    param($Element, [int]$X, [int]$Y)
    try {
        $hit = $AE::FromPoint((New-Object System.Windows.Point($X, $Y)))
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        for ($i = 0; $hit -and $i -lt 6; $i++) {
            if ([System.Windows.Automation.Automation]::Compare($hit, $Element)) { return $true }
            $hit = $walker.GetParent($hit)
        }
    } catch { }
    $false
}

function Find-ItemElement {
    param([IntPtr]$Hwnd, [string[]]$Names)
    $root = $AE::FromHandle($Hwnd)
    foreach ($n in $Names) {
        $cond = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::ListItem)),
            (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $n)))
        $el = $root.FindFirst($TS::Descendants, $cond)
        if ($el) { return $el }
    }
    $null
}

function Get-ItemTarget {
    <# Locates the file in the folder view and chooses a point on its icon or
       name text. In Details view a row is selected by a click anywhere on it,
       but a drag must start on the icon or name -- pressing on the blank part
       of the name column starts a selection rectangle instead. #>
    param($Window, [string]$FileName, [int]$ViewMode)
    $names = @($FileName, [IO.Path]::GetFileNameWithoutExtension($FileName)) | Select-Object -Unique
    $el = Wait-Until { Find-ItemElement -Hwnd $Window.Hwnd -Names $names } -TimeoutSeconds 10
    if (-not $el) { Fail 'find-item' "'$FileName' not found in the window for $($Window.Path)" }
    $r = $el.Current.BoundingRectangle
    if ($el.Current.IsOffscreen -or $r.IsEmpty -or $r.Width -lt 4 -or $r.Height -lt 4) {
        Fail 'item-drawn' "'$FileName' has no on-screen rectangle"
    }
    $x = [int]($r.Left + $r.Width / 2); $y = [int]($r.Top + $r.Height / 2)
    if ($ViewMode -in 3, 4) {                                  # List, Details
        $cell = $el.FindFirst($TS::Descendants,
                    (New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'System.ItemNameDisplay')))
        $cr = if ($cell) { $cell.Current.BoundingRectangle } else { $r }
        # Past the icon, on the first characters of the name. The case files
        # have long names, so the text extends well beyond this point.
        $x = [int]($cr.Left + [Math]::Min(60, $cr.Width / 3)); $y = [int]($cr.Top + $cr.Height / 2)
    }
    if (-not (Test-ElementAtPoint -Element $el -X $x -Y $y)) {
        Fail 'item-drawn' "point ($x,$y) is not on '$FileName' (item at $(Get-RectText $r))"
    }
    Step "item '$FileName' at $(Get-RectText $r), target ($x,$y)"
    [pscustomobject]@{ Element=$el; X=$x; Y=$y }
}

function Get-ViewTarget {
    <# An empty point in a folder view: where a paste click or a drop goes. #>
    param($Window, [double]$VerticalFraction = 0.6)
    $root = $AE::FromHandle($Window.Hwnd)
    $el = $null
    foreach ($cls in 'UIItemsView','SHELLDLL_DefView') {
        $el = Wait-Until { $root.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, $cls))) } -TimeoutSeconds 5
        if ($el) { break }
    }
    if (-not $el) { Fail 'find-view' "no folder view found in the window for $($Window.Path)" }
    $r = $el.Current.BoundingRectangle
    $x = [int]($r.Left + $r.Width / 2); $y = [int]($r.Top + $r.Height * $VerticalFraction)
    $onItem = $false
    try {
        $hit = $AE::FromPoint((New-Object System.Windows.Point($x, $y)))
        $onItem = ($hit -and $hit.Current.ControlType -eq $CT::ListItem)
    } catch { }
    if ($onItem) { Fail 'find-view' "($x,$y) in $($Window.Path) is on an item, not empty space" }
    [pscustomobject]@{ Element=$el; X=$x; Y=$y }
}

$script:SelectionError = $null
function Test-Selected {
    <# Looks the item up afresh on every call: Explorer can replace an item's
       automation element when its state changes, and a stale element then
       reads as "not selected". #>
    param($Window, [string]$FileName)
    try {
        $names = @($FileName, [IO.Path]::GetFileNameWithoutExtension($FileName)) | Select-Object -Unique
        $el = Find-ItemElement -Hwnd $Window.Hwnd -Names $names
        if (-not $el) { $script:SelectionError = 'item not found'; return $false }
        $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected
    } catch { $script:SelectionError = $_.Exception.Message; $false }
}

function Save-Screenshot {
    # Diagnostic only: an image of the desktop, saved beside the driver log.
    param([string]$Name)
    try {
        Add-Type -AssemblyName System.Drawing
        $vx = [NtfsExplorerNative]::GetSystemMetrics(76); $vy = [NtfsExplorerNative]::GetSystemMetrics(77)
        $vw = [NtfsExplorerNative]::GetSystemMetrics(78); $vh = [NtfsExplorerNative]::GetSystemMetrics(79)
        $bmp = New-Object System.Drawing.Bitmap($vw, $vh)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($vx, $vy, 0, 0, $bmp.Size)
        $path = Join-Path (Split-Path -Parent $m.ResultFile) $Name
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        Write-Log "    screenshot $Name"
    } catch { Write-Log "    screenshot failed: $($_.Exception.Message)" }
}

function Assert-PointOwner {
    param([int]$X, [int]$Y, [IntPtr]$Owner, [string]$What)
    $at = [NtfsExplorerNative]::RootAt($X, $Y)
    if ($at -ne $Owner) {
        Fail 'click-target' ("({0},{1}) for {2} belongs to '{3}' [{4}], not the expected window" -f $X, $Y, $What, [NtfsExplorerNative]::Title($at), [NtfsExplorerNative]::ClassOf($at))
    }
}

function Invoke-Click {
    param([int]$X, [int]$Y, [IntPtr]$Owner, [string]$What, [switch]$Double)
    Assert-PointOwner -X $X -Y $Y -Owner $Owner -What $What
    [NtfsExplorerNative]::MoveTo($X, $Y); Start-Sleep -Milliseconds 80
    $clicks = if ($Double) { 2 } else { 1 }
    for ($i = 0; $i -lt $clicks; $i++) {
        [NtfsExplorerNative]::LeftDown($X, $Y); Start-Sleep -Milliseconds 50
        [NtfsExplorerNative]::LeftUp($X, $Y)
        if ($i -lt $clicks - 1) { Start-Sleep -Milliseconds 90 }
    }
    $cur = [NtfsExplorerNative]::Cursor()
    Step ("{0} ({1},{2}) {3}; cursor now ({4},{5})" -f $(if ($Double) { 'double-click' } else { 'click' }), $X, $Y, $What, $cur.X, $cur.Y)
}

function Invoke-Drag {
    <# Press on the item, move past the drag threshold, glide to the target,
       hover so Explorer's drop target registers, release. Shift is pressed
       once the drag is under way and held through the drop -- the key state
       at the drop decides move versus copy. #>
    param($From, $To, [IntPtr]$FromOwner, [IntPtr]$ToOwner, [switch]$Shift)
    Assert-PointOwner -X $From.X -Y $From.Y -Owner $FromOwner -What 'drag start'
    Assert-PointOwner -X $To.X -Y $To.Y -Owner $ToOwner -What 'drop target'
    [NtfsExplorerNative]::MoveTo($From.X, $From.Y); Start-Sleep -Milliseconds 120
    [NtfsExplorerNative]::LeftDown($From.X, $From.Y); $script:ButtonDown = $true
    Start-Sleep -Milliseconds 150
    $dx = [Math]::Max(4, [NtfsExplorerNative]::GetSystemMetrics(68))   # SM_CXDRAG
    for ($i = 1; $i -le 4; $i++) { [NtfsExplorerNative]::MoveTo($From.X + $i * $dx, $From.Y + $i); Start-Sleep -Milliseconds 40 }
    if ($Shift) { [NtfsExplorerNative]::KeyDown($VK.Shift); $script:ShiftDown = $true; Start-Sleep -Milliseconds 100 }
    $sx = $From.X + 4 * $dx; $sy = $From.Y + 4
    $n = 30
    for ($i = 1; $i -le $n; $i++) {
        [NtfsExplorerNative]::MoveTo([int]($sx + ($To.X - $sx) * $i / $n), [int]($sy + ($To.Y - $sy) * $i / $n))
        Start-Sleep -Milliseconds 20
    }
    Start-Sleep -Milliseconds 300
    [NtfsExplorerNative]::MoveTo($To.X + 3, $To.Y + 2); Start-Sleep -Milliseconds 150
    [NtfsExplorerNative]::MoveTo($To.X, $To.Y);         Start-Sleep -Milliseconds 300
    [NtfsExplorerNative]::LeftUp($To.X, $To.Y); $script:ButtonDown = $false
    Start-Sleep -Milliseconds 150
    if ($Shift) { [NtfsExplorerNative]::KeyUp($VK.Shift); $script:ShiftDown = $false }
    Step ("drag{0} ({1},{2}) -> ({3},{4})" -f $(if ($Shift) { '+shift' } else { '' }), $From.X, $From.Y, $To.X, $To.Y)
}

function Get-FocusText {
    # Describes the focused automation element, for failure messages.
    try {
        $f = $AE::FocusedElement.Current
        "{0} class={1} pid={2} name='{3}'" -f $f.ControlType.ProgrammaticName, $f.ClassName, $f.ProcessId, $f.Name
    } catch { "unavailable: $($_.Exception.Message)" }
}

function Assert-Foreground {
    param([IntPtr]$Hwnd, [string]$What)
    $ok = Wait-Until { [NtfsExplorerNative]::ForegroundRoot() -eq $Hwnd } -TimeoutSeconds 3
    if (-not $ok) {
        $f = [NtfsExplorerNative]::ForegroundRoot()
        Fail 'focus' ("{0} does not have focus (foreground is '{1}' [{2}])" -f $What, [NtfsExplorerNative]::Title($f), [NtfsExplorerNative]::ClassOf($f))
    }
}

function Find-TitledWindow {
    param([string]$Contains)
    foreach ($h in [NtfsExplorerNative]::TopWindows()) {
        $t = [NtfsExplorerNative]::Title($h)
        if ($t -and $t.IndexOf($Contains, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $h }
    }
    $null
}

function Find-ShellDialog {
    # A classic dialog owned by the Explorer process: delete confirmations,
    # and anything unexpected such as a "file in use" prompt.
    param([uint32]$ShellPid)
    foreach ($h in [NtfsExplorerNative]::TopWindows()) {
        if ([NtfsExplorerNative]::ClassOf($h) -eq '#32770' -and [NtfsExplorerNative]::ProcessOf($h) -eq $ShellPid) { return $h }
    }
    $null
}

function Confirm-ShellDialog {
    <# Accept a confirmation, but only after checking it is the expected one
       and that its focused button is Yes. #>
    param([IntPtr]$Dialog, [string]$What)
    Assert-Foreground -Hwnd $Dialog -What "$What dialog"
    $focus = $null
    try { $focus = $AE::FocusedElement.Current.Name } catch { }
    if ($focus -ne 'Yes') { Fail 'dialog' "$What dialog '$([NtfsExplorerNative]::Title($Dialog))' focused on '$focus', not Yes" }
    Step "dialog '$([NtfsExplorerNative]::Title($Dialog))' -> Yes"
    [NtfsExplorerNative]::Tap($VK.Enter)
}

function Wait-Effect {
    <# Waits for the operation's visible result, failing early if Explorer
       raises a dialog the case did not expect. #>
    param([scriptblock]$Done, [uint32]$ShellPid, [string]$What, [double]$TimeoutSeconds = 15)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (& $Done) { Step "$What confirmed"; return }
        $dlg = Find-ShellDialog -ShellPid $ShellPid
        if ($dlg) { Fail 'unexpected-dialog' "'$([NtfsExplorerNative]::Title($dlg))' appeared while waiting for $What" }
        Start-Sleep -Milliseconds 100
    }
    Fail 'effect' "$What not observed within $TimeoutSeconds s"
}

function Find-RecycledPath {
    <# Explorer renames a recycled file to $R<random>.<ext> under
       $Recycle.Bin\<SID>, with a matching $I file that records the original
       path. Parsing $I identifies the record without guessing. Read after the
       measured window closes; reading $I touches only $I. #>
    param([string]$OriginalPath)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $bin = Join-Path ([IO.Path]::GetPathRoot($OriginalPath)) ('$Recycle.Bin\' + $sid)
    if (-not (Test-Path -LiteralPath $bin)) { return $null }
    foreach ($i in @(Get-ChildItem -LiteralPath $bin -Force -File | Where-Object { $_.Name -like '$I*' })) {
        $b = [IO.File]::ReadAllBytes($i.FullName)
        if ($b.Length -lt 28) { continue }
        # $I version 2 (Windows 10+): version, size, deletion FILETIME, then a
        # character count and the UTF-16 original path. Version 1 has a fixed
        # 260-character path at offset 24.
        $ver = [BitConverter]::ToInt64($b, 0)
        $orig = if ($ver -eq 2) {
                    $len = [BitConverter]::ToInt32($b, 24)
                    [Text.Encoding]::Unicode.GetString($b, 28, [Math]::Min($len * 2, $b.Length - 28))
                } else {
                    [Text.Encoding]::Unicode.GetString($b, 24, [Math]::Min(520, $b.Length - 24))
                }
        if ($orig.TrimEnd([char]0) -ieq $OriginalPath) {
            $r = Join-Path $bin ('$R' + $i.Name.Substring(2))
            if (Test-Path -LiteralPath $r) { return $r }
        }
    }
    $null
}

function Move-MouseAside {
    # Rest the cursor on empty space so it does not hover over the item and
    # raise an infotip between steps.
    param($Window)
    try {
        $p = Get-ViewTarget -Window $Window -VerticalFraction 0.85
        [NtfsExplorerNative]::MoveTo($p.X, $p.Y)
    } catch { }
}

function Undo-PendingInput {
    if ($script:ButtonDown) {
        try { [NtfsExplorerNative]::Tap($VK.Escape) } catch { }
        try { $c = [NtfsExplorerNative]::Cursor(); [NtfsExplorerNative]::LeftUp($c.X, $c.Y) } catch { }
        $script:ButtonDown = $false
    }
    [NtfsExplorerNative]::ReleaseModifiers()
    $script:ShiftDown = $false
}

# ---------------------------------------------------------------- context
$hideExt = $null
try { $hideExt = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -ErrorAction Stop).HideFileExt } catch { }
$wa = [NtfsExplorerNative]::WorkArea()
$context = [pscustomobject]@{
    User            = "$env:USERDOMAIN\$env:USERNAME"
    SessionId       = [Diagnostics.Process]::GetCurrentProcess().SessionId
    Elevated        = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
    DpiAwareness    = $dpiMode
    SystemDpi       = [NtfsExplorerNative]::GetDpiForSystem()
    VirtualScreen   = '{0},{1} {2}x{3}' -f [NtfsExplorerNative]::GetSystemMetrics(76), [NtfsExplorerNative]::GetSystemMetrics(77), [NtfsExplorerNative]::GetSystemMetrics(78), [NtfsExplorerNative]::GetSystemMetrics(79)
    WorkArea        = '{0},{1} {2}x{3}' -f $wa.Left, $wa.Top, ($wa.Right - $wa.Left), ($wa.Bottom - $wa.Top)
    ExtensionsShown = ($hideExt -eq 0)
    DoubleClickMs   = [NtfsExplorerNative]::GetDoubleClickTime()
    CaseGapSeconds  = $m.CaseGapSeconds
}
Write-Log ("context: {0}" -f ($context | ConvertTo-Json -Compress))

# Mechanisms whose keystroke acts on the current selection. The file is
# selected before the measured window opens, as the manual plan instructs.
$PreSelect = @('explorer_rename','explorer_copy','explorer_cutpaste','explorer_recycle','explorer_shiftdelete')

$results = New-Object Collections.Generic.List[object]
$startedUtc = Get-UtcIso
$caseIndex = 0

foreach ($c in @($m.Cases)) {
    $caseIndex++
    $script:Steps = New-Object Collections.Generic.List[string]
    Write-Log "CASE $($c.CaseId)"
    $res = [ordered]@{
        CaseId     = $c.CaseId
        OpStartUtc = $null
        OpEndUtc   = $null
        PathAfter  = $null
        NameAfter  = $null
        LiveSI     = $null
        Error      = $null
        ViewMode   = $null
        Steps      = $null
    }
    $src = $null; $dst = $null
    try {
        if (-not (Test-Path -LiteralPath $c.SourcePath)) { Fail 'precondition' "source file is missing: $($c.SourcePath)" }
        if ($c.Mechanism -eq 'explorer_rename' -and -not $context.ExtensionsShown) {
            Fail 'precondition' 'file name extensions are hidden; the plan requires View > Show > File name extensions'
        }
        $srcDir = Split-Path -Parent $c.SourcePath
        $src = Open-FolderWindow -Path $srcDir
        if ($c.DestDir) {
            $dst = Open-FolderWindow -Path $c.DestDir
            if ($dst.Hwnd -eq $src.Hwnd) { Fail 'open-window' 'source and destination opened as tabs of one window; the cases need two windows side by side' }
        }
        Set-WindowLayout -Source $src -Dest $dst
        try { $res.ViewMode = [int]$src.Com.Document.CurrentViewMode } catch { }
        $shellPid = [NtfsExplorerNative]::ProcessOf($src.Hwnd)

        $item = Get-ItemTarget -Window $src -FileName $c.SourceName -ViewMode $res.ViewMode
        $drop = if ($dst) { Get-ViewTarget -Window $dst } else { $null }

        if ($c.Mechanism -in $PreSelect) {
            Invoke-Click -X $item.X -Y $item.Y -Owner $src.Hwnd -What "select $($c.SourceName)"
            if (-not (Wait-Until { Test-Selected -Window $src -FileName $c.SourceName } -TimeoutSeconds 3)) { Fail 'preselect' "'$($c.SourceName)' did not become selected ($script:SelectionError)" }
            Assert-Foreground -Hwnd $src.Hwnd -What 'source window'
        }
        Move-MouseAside -Window $src
        Start-Sleep -Milliseconds 800

        $srcPath = $c.SourcePath
        $dstPath = if ($c.DestDir) { Join-Path $c.DestDir $c.SourceName } else { $null }
        $pathAfter = $srcPath

        # ------------------------------------------ measured window opens
        $res.OpStartUtc = Get-UtcIso
        Step 'START'
        switch ($c.Mechanism) {
            'explorer_browse' {
                Invoke-Click -X $item.X -Y $item.Y -Owner $src.Hwnd -What "select $($c.SourceName)"
                if (-not (Wait-Until { Test-Selected -Window $src -FileName $c.SourceName } -TimeoutSeconds 3)) { Fail 'effect' "'$($c.SourceName)' did not become selected ($script:SelectionError)" }
                Step 'selected'
            }
            'explorer_open' {
                if (Find-TitledWindow -Contains $c.SourceName) { Fail 'precondition' "a window titled with '$($c.SourceName)' already exists" }
                Invoke-Click -X $item.X -Y $item.Y -Owner $src.Hwnd -What "open $($c.SourceName)" -Double
                $ed = Wait-Until { Find-TitledWindow -Contains $c.SourceName } -TimeoutSeconds 20
                if (-not $ed) { Fail 'effect' "no window titled with '$($c.SourceName)' appeared" }
                Step ("opened in '{0}' [{1}]" -f [NtfsExplorerNative]::Title($ed), [NtfsExplorerNative]::ClassOf($ed))
                Assert-Foreground -Hwnd $ed -What 'editor window'
                Start-Sleep -Milliseconds 1500
                # Ctrl+W closes the tab. With a fresh Notepad that is the whole
                # window; if Notepad was already open it leaves the user's tabs.
                [NtfsExplorerNative]::Chord($VK.Ctrl, $VK.W)
                Wait-Effect -Done { -not (Find-TitledWindow -Contains $c.SourceName) } -ShellPid $shellPid -What 'editor closed'
            }
            'explorer_rename' {
                Assert-Foreground -Hwnd $src.Hwnd -What 'source window'
                [NtfsExplorerNative]::Tap($VK.F2)
                # Win11 25H2 exposes the in-place rename box as a Pane of class
                # UIRenameTextElement. An Edit control is accepted for other builds.
                $edit = Wait-Until { try { $f = $AE::FocusedElement; if (($f.Current.ClassName -eq 'UIRenameTextElement' -or $f.Current.ControlType -eq $CT::Edit) -and $f.Current.ProcessId -eq $shellPid) { $f } } catch { } } -TimeoutSeconds 3
                if (-not $edit) { Fail 'effect' "F2 did not open the rename box (focus: $(Get-FocusText))" }
                Step 'rename box open'
                # F2 selects the name without its extension, so typing replaces
                # only the base name -- what an operator does.
                [NtfsExplorerNative]::TypeText($m.RenameBase)
                [NtfsExplorerNative]::Tap($VK.Enter)
                $newPath = Join-Path $srcDir ($m.RenameBase + [IO.Path]::GetExtension($c.SourceName))
                Wait-Effect -Done { (Test-Path -LiteralPath $newPath) -and -not (Test-Path -LiteralPath $srcPath) } -ShellPid $shellPid -What "rename to $(Split-Path -Leaf $newPath)"
                $pathAfter = $newPath
            }
            { $_ -in 'explorer_copy','explorer_cutpaste' } {
                Assert-Foreground -Hwnd $src.Hwnd -What 'source window'
                $key = if ($c.Mechanism -eq 'explorer_copy') { $VK.C } else { $VK.X }
                [NtfsExplorerNative]::Chord($VK.Ctrl, $key)
                Step $(if ($c.Mechanism -eq 'explorer_copy') { 'Ctrl+C' } else { 'Ctrl+X' })
                Start-Sleep -Milliseconds 300
                Invoke-Click -X $drop.X -Y $drop.Y -Owner $dst.Hwnd -What 'destination folder'
                Assert-Foreground -Hwnd $dst.Hwnd -What 'destination window'
                [NtfsExplorerNative]::Chord($VK.Ctrl, $VK.V)
                Step 'Ctrl+V'
                if ($c.Mechanism -eq 'explorer_copy') {
                    Wait-Effect -Done { (Test-Path -LiteralPath $dstPath) -and (Test-Path -LiteralPath $srcPath) } -ShellPid $shellPid -What 'copy'
                } else {
                    Wait-Effect -Done { (Test-Path -LiteralPath $dstPath) -and -not (Test-Path -LiteralPath $srcPath) } -ShellPid $shellPid -What 'move'
                }
                $pathAfter = $dstPath
            }
            { $_ -in 'explorer_drag','explorer_dragshift','explorer_dragcrossvol' } {
                Invoke-Drag -From $item -To $drop -FromOwner $src.Hwnd -ToOwner $dst.Hwnd -Shift:($c.Mechanism -eq 'explorer_dragshift')
                # Same-volume drag moves; cross-volume drag copies; Shift forces
                # a move. Checking which happened is the automated equivalent of
                # the operator reading the drag tooltip.
                if ($c.Operation -eq 'file_copy') {
                    Wait-Effect -Done { (Test-Path -LiteralPath $dstPath) -and (Test-Path -LiteralPath $srcPath) } -ShellPid $shellPid -What 'drag copy'
                } else {
                    Wait-Effect -Done { (Test-Path -LiteralPath $dstPath) -and -not (Test-Path -LiteralPath $srcPath) } -ShellPid $shellPid -What 'drag move'
                }
                $pathAfter = $dstPath
            }
            'explorer_recycle' {
                Assert-Foreground -Hwnd $src.Hwnd -What 'source window'
                [NtfsExplorerNative]::Tap($VK.Delete)
                Step 'Delete'
                # Windows 11 does not confirm a recycle by default. If this
                # system is set to, accept the prompt as an operator would.
                $clock = [Diagnostics.Stopwatch]::StartNew()
                while ((Test-Path -LiteralPath $srcPath) -and $clock.Elapsed.TotalSeconds -lt 10) {
                    $dlg = Find-ShellDialog -ShellPid $shellPid
                    if ($dlg) { Confirm-ShellDialog -Dialog $dlg -What 'recycle' }
                    Start-Sleep -Milliseconds 100
                }
                if (Test-Path -LiteralPath $srcPath) { Fail 'effect' 'file still present 10 s after Delete' }
                Step 'recycled'
            }
            'explorer_shiftdelete' {
                Assert-Foreground -Hwnd $src.Hwnd -What 'source window'
                [NtfsExplorerNative]::Chord($VK.Shift, $VK.Delete)
                Step 'Shift+Delete'
                $dlg = Wait-Until { Find-ShellDialog -ShellPid $shellPid } -TimeoutSeconds 5
                if (-not $dlg) { Fail 'effect' 'no permanent-delete confirmation appeared' }
                Confirm-ShellDialog -Dialog $dlg -What 'permanent delete'
                Wait-Effect -Done { -not (Test-Path -LiteralPath $srcPath) } -ShellPid $shellPid -What 'permanent delete'
                $pathAfter = $null
            }
            default { Fail 'precondition' "no automation for mechanism '$($c.Mechanism)'" }
        }
        $res.OpEndUtc = Get-UtcIso
        Step 'END'
        # ------------------------------------------ measured window closed

        # Live $SI straight from the in-memory record -- as the manual runner
        # does -- so a deferred Access write cannot read as "no change".
        if ($c.Mechanism -eq 'explorer_recycle') {
            $rp = Find-RecycledPath -OriginalPath $srcPath
            if ($rp) { $pathAfter = $rp; Step "recycled as $rp" } else { Step 'recycled record not located by $I; resolved by entry number' }
        }
        $res.PathAfter = $pathAfter
        $res.NameAfter = if ($pathAfter) { Split-Path -Leaf $pathAfter } else { $null }
        if ($pathAfter -and (Test-Path -LiteralPath $pathAfter)) {
            try {
                $live = Get-SiTimestamp -Path $pathAfter
                $res.LiveSI = [pscustomobject]@{
                    Created       = $live.Creation.ToString('o')
                    Modified      = $live.Modified.ToString('o')
                    Access        = $live.Access.ToString('o')
                    EntryModified = $live.MftEntryModified.ToString('o')
                }
            } catch { Step "live read failed: $($_.Exception.Message)" }
        }
    } catch {
        $res.Error = "$($_.Exception.Message)"
        Write-Log "  FAILED: $($res.Error)"
        $fgw = [NtfsExplorerNative]::ForegroundRoot()
        Write-Log ("    foreground at failure: {0} [{1}]" -f [NtfsExplorerNative]::Title($fgw), [NtfsExplorerNative]::ClassOf($fgw))
        Save-Screenshot ("{0}-failure.png" -f $c.CaseId)
        Undo-PendingInput
        # Dismiss a rename box or dialog left open by a failed step, but only
        # when it belongs to one of this case's windows.
        $fg = [NtfsExplorerNative]::ForegroundRoot()
        if (($src -and $fg -eq $src.Hwnd) -or ($dst -and $fg -eq $dst.Hwnd) -or ([NtfsExplorerNative]::ClassOf($fg) -eq '#32770')) {
            try { [NtfsExplorerNative]::Tap($VK.Escape) } catch { }
        }
    } finally {
        Close-FolderWindow $dst
        Close-FolderWindow $src
        $res.Steps = $script:Steps.ToArray()
        $results.Add([pscustomobject]$res)
        # Partial results survive a driver crash, for diagnosis.
        [pscustomobject]@{ Context=$context; StartedUtc=$startedUtc; Cases=$results } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath ($m.ResultFile + '.partial') -Encoding UTF8
    }
    if ($caseIndex -lt @($m.Cases).Count -and $m.CaseGapSeconds -gt 0) { Start-Sleep -Seconds $m.CaseGapSeconds }
}

$final = [pscustomobject]@{ Context=$context; StartedUtc=$startedUtc; CompletedUtc=(Get-UtcIso); Cases=$results }
$tmp = $m.ResultFile + '.tmp'
$final | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $m.ResultFile -Force
Write-Log ("driver finished: {0} performed, {1} failed" -f @($results | Where-Object { -not $_.Error }).Count, @($results | Where-Object { $_.Error }).Count)
