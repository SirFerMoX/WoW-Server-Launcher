#Requires -Version 5.1
<#
.NOTES
    SPP-LegionV2 Launcher - WPF GUI
    Located at Tools\Launcher\Scripts\ within the repack root.
    Use Launcher.bat in the root folder to start it.
#>

param([switch]$NoAdmin)

# Admin elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $NoAdmin -and -not $isAdmin) {
    $ps = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    Start-Process $ps -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Error diagnostics — shows a visible message box on crash
trap {
    try { [System.Windows.Forms.MessageBox]::Show("Launcher crash:`n`n$_`n`n$($_.ScriptStackTrace)", "Launcher Error") } catch {}
    throw
}

# Win32 API — console hide + console embedding
Add-Type -Name WinAPI -Namespace SPP -MemberDefinition @"
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool   ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]   public static extern IntPtr SetParent(IntPtr hWnd, IntPtr hWndNewParent);
    [DllImport("user32.dll")]   public static extern IntPtr GetParent(IntPtr hWnd);
    [DllImport("user32.dll")]   public static extern bool   MoveWindow(IntPtr hWnd, int x, int y, int w, int h, bool r);
    [DllImport("user32.dll")]   public static extern int    GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]   public static extern int    SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")]   public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("shell32.dll")] public static extern int    SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
"@
$_con = [SPP.WinAPI]::GetConsoleWindow()
if ($_con -ne [IntPtr]::Zero) { [SPP.WinAPI]::ShowWindow($_con, 0) | Out-Null }
# Unique App ID — prevents Windows from grouping this window with other PowerShell processes
# and allows the taskbar button to use our custom icon instead of powershell.exe's icon
[SPP.WinAPI]::SetCurrentProcessExplicitAppUserModelID("SPP.LegionLauncher") | Out-Null

# Restore console registry defaults (undo any side effects from previous launcher runs)
try {
    Remove-ItemProperty 'HKCU:\Console' 'ScreenColors'  -ErrorAction SilentlyContinue
    Remove-ItemProperty 'HKCU:\Console' 'ColorTable09'  -ErrorAction SilentlyContinue
    Remove-ItemProperty 'HKCU:\Console' 'ColorTable00'  -ErrorAction SilentlyContinue
} catch {}

# Win32 API — WriteConsoleInput for sending commands to embedded consoles
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace SPP {
    public static class ConsoleWriter {
        [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
        public struct KEY_EVENT {
            [FieldOffset(0)]  public int   bKeyDown;
            [FieldOffset(4)]  public short wRepeatCount;
            [FieldOffset(6)]  public short wVirtualKeyCode;
            [FieldOffset(8)]  public short wVirtualScanCode;
            [FieldOffset(10)] public char  UnicodeChar;
            [FieldOffset(12)] public int   dwControlKeyState;
        }
        [StructLayout(LayoutKind.Explicit)]
        public struct INPUT_RECORD {
            [FieldOffset(0)] public short    EventType;
            [FieldOffset(4)] public KEY_EVENT KeyEvent;
        }
        [DllImport("kernel32.dll")] static extern bool   AttachConsole(uint pid);
        [DllImport("kernel32.dll")] static extern bool   FreeConsole();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
        [DllImport("kernel32.dll")] static extern bool   WriteConsoleInput(IntPtr h, INPUT_RECORD[] b, uint len, out uint written);
        [DllImport("kernel32.dll")] static extern bool   CloseHandle(IntPtr h);

        public static bool Send(uint pid, string text) {
            FreeConsole();
            if (!AttachConsole(pid)) return false;
            IntPtr h = CreateFile(@"CONIN`$", 0xC0000000u, 3u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
            if (h == IntPtr.Zero || h.ToInt64() == -1L) { FreeConsole(); return false; }
            try {
                string line = text + "\r";
                INPUT_RECORD[] rec = new INPUT_RECORD[line.Length * 2];
                int i = 0;
                foreach (char c in line) {
                    rec[i].EventType = 1; rec[i].KeyEvent.bKeyDown = 1;
                    rec[i].KeyEvent.wRepeatCount = 1; rec[i].KeyEvent.UnicodeChar = c;
                    rec[i].KeyEvent.wVirtualKeyCode = (c == '\r') ? (short)0x0D : (short)0;
                    i++;
                    rec[i].EventType = 1; rec[i].KeyEvent.bKeyDown = 0;
                    rec[i].KeyEvent.wRepeatCount = 1; rec[i].KeyEvent.UnicodeChar = c;
                    rec[i].KeyEvent.wVirtualKeyCode = (c == '\r') ? (short)0x0D : (short)0;
                    i++;
                }
                uint written;
                return WriteConsoleInput(h, rec, (uint)rec.Length, out written);
            } finally { CloseHandle(h); FreeConsole(); }
        }
    }
}
"@

# Win32 API — per-process console color via palette remapping (SetConsoleScreenBufferInfoEx)
# Uses IntPtr/manual memory to avoid .NET 4.x ByValArray marshaling issues.
# Remaps ColorTable[9] so text written with attribute 9 (hardcoded blue in server binaries)
# visually appears in the user-chosen color regardless of SetConsoleTextAttribute calls.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace SPP {
    public struct CsCoord     { public short X, Y; }
    public struct CsSmallRect { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct CsConInfo {
        public CsCoord     dwSize;
        public CsCoord     dwCursorPosition;
        public ushort      wAttributes;
        public CsSmallRect srWindow;
        public CsCoord     dwMaximumWindowSize;
    }
    public static class ConsoleColors {
        // Standard Windows console COLORREF palette (0x00BBGGRR: blue=high, red=low)
        static readonly uint[] Palette = {
            0x000000, 0x800000, 0x008000, 0x808000,
            0x000080, 0x800080, 0x008080, 0xC0C0C0,
            0x808080, 0xFF0000, 0x00FF00, 0xFFFF00,
            0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF
        };
        [DllImport("kernel32.dll")] static extern bool   FreeConsole();
        [DllImport("kernel32.dll")] static extern bool   AttachConsole(uint pid);
        [DllImport("kernel32.dll")] static extern bool   CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern bool   GetConsoleScreenBufferInfo(IntPtr h, out CsConInfo i);
        [DllImport("kernel32.dll")] static extern bool   FillConsoleOutputAttribute(IntPtr h, ushort a, uint len, CsCoord coord, out uint written);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
        // IntPtr overloads avoid ByValArray struct marshaling
        [DllImport("kernel32.dll", EntryPoint = "GetConsoleScreenBufferInfoEx")]
        static extern bool GetCsbEx(IntPtr h, IntPtr buf);
        [DllImport("kernel32.dll", EntryPoint = "SetConsoleScreenBufferInfoEx")]
        static extern bool SetCsbEx(IntPtr h, IntPtr buf);
        // CONSOLE_SCREEN_BUFFER_INFOEX layout (96 bytes, no padding):
        //   0  cbSize          ULONG   4
        //   4  dwSize          COORD   4
        //   8  dwCursorPos     COORD   4
        //  12  wAttributes     WORD    2
        //  14  srWindow        SRECT   8
        //  22  dwMaxWinSize    COORD   4
        //  26  wPopupAttrib    WORD    2
        //  28  bFullscreen     BOOL    4
        //  32  ColorTable[16]  DWORD  64   <- each entry is a COLORREF
        // cc = two hex digits XY: X = bg index, Y = fg index  (same as CMD /T:XY)
        public static bool Apply(uint pid, string cc) {
            if (cc == null || cc.Length != 2) return false;
            int fg, bg;
            try { fg = Convert.ToInt32(cc[1].ToString(), 16); bg = Convert.ToInt32(cc[0].ToString(), 16); }
            catch { return false; }
            if (fg > 15 || bg > 15) return false;
            ushort attr = (ushort)((bg << 4) | fg);
            FreeConsole();
            if (!AttachConsole(pid)) return false;
            try {
                // Open CONOUT$ with GENERIC_READ|GENERIC_WRITE — required for
                // SetConsoleScreenBufferInfoEx; GetStdHandle alone may lack write access.
                IntPtr hOut = CreateFile("CONOUT$", 0xC0000000u, 3u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
                if (hOut == IntPtr.Zero || hOut.ToInt64() == -1L) return false;
                try {
                    // Remap ColorTable[9] (attribute used by server binaries for all output)
                    // so it visually renders as the user-chosen color regardless of how many
                    // times the server calls SetConsoleTextAttribute(handle, 9).
                    const int kSize = 96;
                    IntPtr buf = Marshal.AllocHGlobal(kSize);
                    try {
                        for (int i = 0; i < kSize; i++) Marshal.WriteByte(buf, i, 0);
                        Marshal.WriteInt32(buf, 0, kSize);
                        if (GetCsbEx(hOut, buf)) {
                            Marshal.WriteInt32(buf, 32 + 9 * 4, (int)Palette[fg]); // remap attr 9
                            Marshal.WriteInt16(buf, 12, (short)attr);               // default attr
                            Marshal.WriteInt32(buf, 0, kSize);
                            SetCsbEx(hOut, buf);
                        }
                    } finally { Marshal.FreeHGlobal(buf); }
                    // Retroactively recolor existing buffer content
                    CsConInfo info;
                    if (GetConsoleScreenBufferInfo(hOut, out info)) {
                        uint filled;
                        FillConsoleOutputAttribute(hOut, attr,
                            (uint)info.dwSize.X * (uint)info.dwSize.Y,
                            new CsCoord(), out filled);
                    }
                } finally { CloseHandle(hOut); }
                return true;
            } finally { FreeConsole(); }
        }
    }
}
"@

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# Script is at Tools\Launcher\Scripts\ — go 3 levels up to reach the repack root
$mainfolder  = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$iconsDir    = "$mainfolder\Tools\Launcher\Icons"
$connectDir  = "$mainfolder\Tools\Launcher\Connections"
$customDir   = "$mainfolder\Tools\Launcher\Custom"
$scriptsDir  = "$mainfolder\Tools\Launcher\Scripts"

# ── Server management functions ───────────────────────────────────────────────

function Test-Proc([string]$n) { [bool](Get-Process -Name $n -ErrorAction SilentlyContinue) }

function Read-Directories {
    $defaults = @{
        MySQL    = "$mainfolder\Database\MySQL_Server.bat"
        Auth     = "$mainfolder\Servers\authserver.exe"
        World    = "$mainfolder\Servers\worldserver.exe"
        Website  = "$mainfolder\Website\Apache\Apache_Server.bat"
        HeidiSQL = "$mainfolder\Tools\HeidiSQL\heidisql.exe"
        Notepad  = "$mainfolder\Tools\Notepad\notepad++.exe"
        ConfigFolder = "$mainfolder\Servers\configs"
        LogsFolder   = "$mainfolder\Logs"
        AuthConf     = "$mainfolder\Servers\configs\authserver.conf"
        WorldConf    = "$mainfolder\Servers\configs\worldserver.conf"
    }
    $f = "$scriptsDir\Directories.txt"
    if (Test-Path $f) {
        Get-Content $f | ForEach-Object {
            if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
            if ($_ -match '^\s*(\w+)\s*=\s*(.+)$') {
                $key = $Matches[1]; $val = $Matches[2].Trim()
                if (-not [System.IO.Path]::IsPathRooted($val)) { $val = "$mainfolder\$val" }
                $defaults[$key] = $val
            }
        }
    }
    return $defaults
}
$Script:srvDirs = Read-Directories

function Read-MySQLConfig {
    $cfg = @{ Host = "127.0.0.1"; Port = "3310"; User = "spp_user"; Password = "123456"; Description = "SPP-LegionV2" }
    $f = "$scriptsDir\MySQL.txt"
    if (Test-Path $f) {
        Get-Content $f | ForEach-Object {
            if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
            if ($_ -match '^\s*(\w+)\s*=\s*(.+)') { $cfg[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    return $cfg
}
$Script:mysqlCfg = Read-MySQLConfig

function Read-Updates {
    $url = "https://github.com/SirFerMoX/WoW-Tools/releases/tag/Launcher"
    $f = "$scriptsDir\Updates.txt"
    if (Test-Path $f) {
        Get-Content $f | ForEach-Object {
            if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
            if ($_ -match '^\s*UpdatesURL\s*=\s*(.+)') { $url = $Matches[1].Trim() }
        }
    }
    return $url
}
$Script:updatesURL = Read-Updates

function Read-Theme {
    $d = @{
        BgWindow      = '#0C1610'
        BgSidebar     = '#120808'
        BgCard        = '#1E1212'
        BgHover       = '#2A1515'
        BgSelected    = '#1E3025'
        BgConsole     = '#000000'
        BorderAccent  = '#6B2A2A'
        TextPrimary   = '#FFF2F2'
        TextSecondary = '#C47070'
        TextMuted     = '#9E5555'
        AccentGreen   = '#E53935'
        AccentGreenAlt= '#C41E3A'
        AccentBlue    = '#C41E3A'
        StatusStopped = '#EF4444'
        OverlayDim    = '#99000000'
        OverlayBg     = '#CC152218'
        ConsoleColor  = '09'
    }
    $f = "$scriptsDir\Theme.txt"
    if (Test-Path $f) {
        Get-Content $f | ForEach-Object {
            if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
            if ($_ -match '^\s*(\w+)\s*=\s*(.+)') { $d[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    return $d
}
$Script:theme = Read-Theme

function Apply-Theme([string]$s) {
    $t = $Script:theme
    # 8-char ARGB values first (before their 6-char substrings match)
    $s = $s -replace [regex]::Escape('#99000000'), $t.OverlayDim
    $s = $s -replace [regex]::Escape('#CC152218'), $t.OverlayBg
    # 6-char colors
    $s = $s -replace [regex]::Escape('#120808'), $t.BgSidebar
    $s = $s -replace [regex]::Escape('#0C1610'), $t.BgWindow
    $s = $s -replace [regex]::Escape('#1E1212'), $t.BgCard
    $s = $s -replace [regex]::Escape('#2A1515'), $t.BgHover
    $s = $s -replace [regex]::Escape('#1E3025'), $t.BgSelected
    $s = $s -replace [regex]::Escape('#000000'), $t.BgConsole
    $s = $s -replace [regex]::Escape('#6B2A2A'), $t.BorderAccent
    $s = $s -replace [regex]::Escape('#FFF2F2'), $t.TextPrimary
    $s = $s -replace [regex]::Escape('#C47070'), $t.TextSecondary
    $s = $s -replace [regex]::Escape('#9E5555'), $t.TextMuted
    $s = $s -replace [regex]::Escape('#FF5252'), $t.AccentBlue
    $s = $s -replace [regex]::Escape('#00E676'), $t.AccentGreen
    $s = $s -replace [regex]::Escape('#C41E3A'), $t.AccentGreenAlt
    $s = $s -replace [regex]::Escape('#EF4444'), $t.StatusStopped
    return $s
}

function Start-DBServer {
    if (Test-Proc "mysqld") { return }
    $bat = $Script:srvDirs.MySQL
    if (Test-Path $bat) { Start-Process cmd "/c `"$bat`"" -WorkingDirectory (Split-Path $bat) -WindowStyle Hidden }
}
function Stop-DBServer  { Stop-Process -Name "mysqld"      -Force -ErrorAction SilentlyContinue }

function Start-AuthServer {
    if (Test-Proc "authserver") { return }
    $exe = $Script:srvDirs.Auth
    if (Test-Path $exe) {
        Start-Process $exe -WorkingDirectory (Split-Path $exe) -WindowStyle Minimized
        Start-EmbedTimer
    }
}
function Stop-AuthServer  { Stop-Process -Name "authserver"  -Force -ErrorAction SilentlyContinue }

function Start-WorldServer {
    if (Test-Proc "worldserver") { return }
    $exe = $Script:srvDirs.World
    if (Test-Path $exe) {
        Start-Process $exe -WorkingDirectory (Split-Path $exe) -WindowStyle Minimized
        Start-EmbedTimer
    }
}
function Send-WorldCommand([string]$cmd) {
    $proc = Get-Process -Name "worldserver" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return }
    [SPP.ConsoleWriter]::Send([uint32]$proc.Id, $cmd) | Out-Null
}

$Script:shutdownTimer    = $null
$Script:shutdownPhase    = 0
$Script:shutdownTicks    = 0
$Script:shutdownCallback = $null

function Stop-WorldServer([scriptblock]$OnComplete = $null) {
    if (-not (Test-Proc "worldserver")) {
        if ($OnComplete) { & $OnComplete }
        return
    }
    Send-WorldCommand "saveall"
    $Script:shutdownPhase    = 1
    $Script:shutdownTicks    = 0
    $Script:shutdownCallback = $OnComplete
    if ($Script:shutdownTimer) { $Script:shutdownTimer.Stop() }
    $Script:shutdownTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:shutdownTimer.Interval = [TimeSpan]::FromSeconds(1)
    $Script:shutdownTimer.Add_Tick({
        $Script:shutdownTicks++
        if ($Script:shutdownPhase -eq 1 -and $Script:shutdownTicks -ge 3) {
            Send-WorldCommand "server shutdown 1"
            $Script:shutdownPhase = 2
            $Script:shutdownTicks = 0
        } elseif ($Script:shutdownPhase -eq 2) {
            if (-not (Test-Proc "worldserver") -or $Script:shutdownTicks -ge 30) {
                $Script:shutdownTimer.Stop()
                Stop-Process -Name "worldserver" -Force -ErrorAction SilentlyContinue
                if ($Script:shutdownCallback) { & $Script:shutdownCallback }
                Refresh-Status
            }
        }
    })
    $Script:shutdownTimer.Start()
}

function Start-WebServer {
    if (Test-Proc "httpd") { return }
    $bat = $Script:srvDirs.Website
    if (Test-Path $bat) { Start-Process cmd "/c `"$bat`"" -WorkingDirectory (Split-Path $bat) -WindowStyle Hidden }
}
function Stop-WebServer { Stop-Process -Name "httpd" -Force -ErrorAction SilentlyContinue }

$Script:overlayWin = $null

function Show-Overlay([string]$msg) {
    if ($Script:overlayWin) { $Script:overlayWin.Close(); $Script:overlayWin = $null }
    $oxaml = [xml](Apply-Theme @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize">
  <Border Background="#0C1610" CornerRadius="12" Padding="36,22"
          BorderThickness="1" BorderBrush="#6B2A2A">
    <TextBlock Name="OverlayMsg" Foreground="#FFF2F2" FontSize="15" FontWeight="SemiBold"
               HorizontalAlignment="Center"/>
  </Border>
</Window>
'@)
    $Script:overlayWin = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $oxaml))
    $Script:overlayWin.Owner = $win
    $Script:overlayWin.FindName("OverlayMsg").Text = $msg
    $Script:overlayWin.Show()
}

function Hide-Overlay {
    if ($Script:overlayWin) { $Script:overlayWin.Close(); $Script:overlayWin = $null }
}

$Script:asyncSteps = @()
$Script:asyncIdx   = 0
$Script:asyncTimer = $null

function Invoke-Async([object[]]$Steps) {
    $Script:asyncSteps = $Steps
    $Script:asyncIdx   = 0
    if ($Script:asyncTimer) { $Script:asyncTimer.Stop() }
    $Script:asyncTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:asyncTimer.Interval = [TimeSpan]::FromMilliseconds(50)
    $Script:asyncTimer.Add_Tick({
        while ($Script:asyncIdx -lt $Script:asyncSteps.Count) {
            $step = $Script:asyncSteps[$Script:asyncIdx]
            $Script:asyncIdx++
            if ($step -is [int] -or $step -is [double]) {
                $Script:asyncTimer.Interval = [TimeSpan]::FromSeconds($step)
                return
            } else {
                & $step
                $Script:asyncTimer.Interval = [TimeSpan]::FromMilliseconds(50)
            }
        }
        $Script:asyncTimer.Stop()
    })
    $Script:asyncTimer.Start()
}


function Get-RealmName {
    if (-not (Test-Proc "mysqld")) { return "" }
    $mysqlExe = "$mainfolder\Database\bin\mysql.exe"
    $conf     = "$connectDir\connection_auth.cnf"
    if (-not (Test-Path $mysqlExe) -or -not (Test-Path $conf)) { return "" }
    try {
        $result = & "$mysqlExe" "--defaults-extra-file=$conf" --silent --skip-column-names -e "SELECT name FROM realmlist WHERE id=1;" 2>$null
        return ($result | Select-Object -First 1).Trim()
    } catch { return "" }
}

function Set-RealmName([string]$newName) {
    $mysqlExe = "$mainfolder\Database\bin\mysql.exe"
    $conf     = "$connectDir\connection_auth.cnf"
    if ((Test-Path $mysqlExe) -and (Test-Path $conf)) {
        & "$mysqlExe" "--defaults-extra-file=$conf" --silent -e "UPDATE realmlist SET name='$newName' WHERE id=1;" 2>$null
    }
}

function Get-SaveSlots {
    1..9 | ForEach-Object {
        $d  = "$mainfolder\Saves\$_"
        $nf = "$d\name.txt"
        $af = "$d\auth.sql"
        $name = if (Test-Path $nf) { (Get-Content $nf -Raw).Trim() } else { "" }
        $has  = Test-Path $af
        [PSCustomObject]@{
            Slot    = $_
            Name    = if ($name) { $name } else { "-" }
            Status  = if ($has)  { "Saved" } else { "Empty" }
            HasData = $has
        }
    }
}

function Invoke-ExportSave([int]$slot, [string]$slotName) {
    $d    = "$mainfolder\Saves\$slot"
    $dump = "$mainfolder\Database\bin\mysqldump.exe"
    $conf = "$connectDir\connection.cnf"
    if (-not (Test-Path $dump)) { return $false }
    New-Item $d -ItemType Directory -Force | Out-Null
    $slotName | Out-File "$d\name.txt" -Encoding utf8 -NoNewline
    cmd /c "`"$dump`" --defaults-extra-file=`"$conf`" --default-character-set=utf8mb4 --routines --events --databases acore_auth --add-drop-database > `"$d\auth.sql`"" 2>&1 | Out-Null
    cmd /c "`"$dump`" --defaults-extra-file=`"$conf`" --default-character-set=utf8mb4 --routines --events --databases acore_characters --add-drop-database > `"$d\characters.sql`"" 2>&1 | Out-Null
    return $true
}

function Invoke-ImportSave([int]$slot) {
    $d  = "$mainfolder\Saves\$slot"
    $my = "$mainfolder\Database\bin\mysql.exe"
    $ca = "$connectDir\connection_auth.cnf"
    $cc = "$connectDir\connection_characters.cnf"
    if (-not (Test-Path "$d\auth.sql")) { return $false }
    cmd /c "`"$my`" --defaults-extra-file=`"$ca`" --default-character-set=utf8mb4 < `"$d\auth.sql`"" 2>&1 | Out-Null
    cmd /c "`"$my`" --defaults-extra-file=`"$cc`" --default-character-set=utf8mb4 < `"$d\characters.sql`"" 2>&1 | Out-Null
    return $true
}

# ── XAML ──────────────────────────────────────────────────────────────────────
# NOTE: use Name= (not x:Name=) so FindName() and SelectNodes(@Name) both work

[xml]$xaml = (Apply-Theme @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="SPP-LegionV2 Launcher"
    Height="680" Width="940"
    MinHeight="580" MinWidth="820"
    WindowStartupLocation="CenterScreen"
    Background="#0C1610"
    FontFamily="Segoe UI">

  <Window.Resources>

    <Style x:Key="NavBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#C47070"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="18,11"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Name="bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A1515"/>
                <Setter Property="Foreground" Value="#FFF2F2"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavBtnActive" TargetType="Button" BasedOn="{StaticResource NavBtn}">
      <Setter Property="Background" Value="#2A1515"/>
      <Setter Property="Foreground" Value="#FF5252"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style x:Key="BtnGreen" TargetType="Button">
      <Setter Property="Background" Value="#00E676"/>
      <Setter Property="Foreground" Value="#0C1610"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Name="bd" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#C41E3A"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#1E3025"/>
                <Setter Property="Foreground" Value="#9E5555"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnRed" TargetType="Button" BasedOn="{StaticResource BtnGreen}">
      <Setter Property="Background" Value="#EF4444"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>

    <Style x:Key="BtnGray" TargetType="Button" BasedOn="{StaticResource BtnGreen}">
      <Setter Property="Background" Value="#6B2A2A"/>
      <Setter Property="Foreground" Value="#FFF2F2"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#1E1212"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>

    <Style x:Key="TBox" TargetType="TextBox">
      <Setter Property="Background" Value="#1E3025"/>
      <Setter Property="Foreground" Value="#FFF2F2"/>
      <Setter Property="CaretBrush" Value="#FFF2F2"/>
      <Setter Property="BorderBrush" Value="#6B2A2A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style x:Key="LvItem" TargetType="ListViewItem">
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#FFF2F2"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="BorderBrush" Value="#2A1515"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListViewItem">
            <Border Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <GridViewRowPresenter Columns="{Binding Path=View.Columns,
                  RelativeSource={RelativeSource AncestorType=ListView}}"
                  Content="{TemplateBinding Content}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#1E3025"/>
          <Setter Property="Foreground" Value="#FF5252"/>
        </Trigger>
        <MultiTrigger>
          <MultiTrigger.Conditions>
            <Condition Property="IsMouseOver" Value="True"/>
            <Condition Property="IsSelected" Value="False"/>
          </MultiTrigger.Conditions>
          <Setter Property="Background" Value="#1E1212"/>
        </MultiTrigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="GvHeader" TargetType="GridViewColumnHeader">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#C47070"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GridViewColumnHeader">
            <Border Background="Transparent" Padding="{TemplateBinding Padding}">
              <TextBlock Text="{TemplateBinding Content}"
                         Foreground="{TemplateBinding Foreground}"
                         FontSize="{TemplateBinding FontSize}"
                         FontWeight="{TemplateBinding FontWeight}"
                         VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <!-- Dummy filler column that GridView adds at the end -->
        <Trigger Property="Role" Value="Padding">
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="GridViewColumnHeader">
                <Border Background="Transparent"/>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="190"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- SIDEBAR -->
    <Border Grid.Column="0" Background="#120808">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Padding="18,22,18,18" BorderBrush="#2A1515" BorderThickness="0,0,0,1">
          <StackPanel>
            <TextBlock Name="TxtAppName" FontSize="19" FontWeight="Bold" Foreground="#FF5252"/>
            <TextBlock Text="Server Launcher" FontSize="11" Foreground="#6B2A2A" Margin="0,3,0,0"/>
          </StackPanel>
        </Border>

        <StackPanel Grid.Row="1" Margin="0,10,0,0">
          <Button Name="NavMain"     Content="  Dashboard"       Style="{StaticResource NavBtnActive}"/>
          <Button Name="NavServers"  Content="  Server Manager"  Style="{StaticResource NavBtn}"/>
          <Button Name="NavSaves"    Content="  Saves Manager"   Style="{StaticResource NavBtn}"/>
          <Button Name="NavAccounts" Content="  Account Manager" Style="{StaticResource NavBtn}"/>
          <Button Name="NavSettings" Content="  Settings"        Style="{StaticResource NavBtn}"/>
          <Button Name="NavService"  Content="  Maintenance"     Style="{StaticResource NavBtn}"/>
        </StackPanel>

        <TextBlock Name="TxtAppVersion" Grid.Row="2"
                   Foreground="#1E3025" FontSize="10"
                   HorizontalAlignment="Center" Margin="0,0,0,14"/>
      </Grid>
    </Border>

    <!-- CONTENT -->
    <Grid Grid.Column="1">

      <!-- DASHBOARD -->
      <Grid Name="PageMain" Visibility="Visible">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Compact top bar: title, status pills, actions -->
        <StackPanel Grid.Row="0" Margin="24,22,24,10">

          <!-- Title + subtitle -->
          <TextBlock Text="Dashboard" FontSize="20" FontWeight="Bold" Foreground="#FFF2F2"/>
          <TextBlock Name="DashSubtitle" Text="Checking servers..."
                     FontSize="12" Foreground="#9E5555" Margin="0,3,0,10"/>

          <!-- Status pills (horizontal) -->
          <WrapPanel Margin="0,0,0,10">
            <Border Background="#1E1212" CornerRadius="6" Padding="10,6" Margin="0,0,6,0">
              <StackPanel Orientation="Horizontal">
                <Ellipse Name="DotDB" Width="8" Height="8" Fill="#EF4444" VerticalAlignment="Center" Margin="0,0,7,0"/>
                <TextBlock Text="Database" Foreground="#C47070" FontSize="11" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <TextBlock Name="LblDB" Text="Stopped" Foreground="#EF4444" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <Border Background="#1E1212" CornerRadius="6" Padding="10,6" Margin="0,0,6,0">
              <StackPanel Orientation="Horizontal">
                <Ellipse Name="DotAuth" Width="8" Height="8" Fill="#EF4444" VerticalAlignment="Center" Margin="0,0,7,0"/>
                <TextBlock Text="Auth" Foreground="#C47070" FontSize="11" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <TextBlock Name="LblAuth" Text="Stopped" Foreground="#EF4444" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <Border Background="#1E1212" CornerRadius="6" Padding="10,6" Margin="0,0,6,0">
              <StackPanel Orientation="Horizontal">
                <Ellipse Name="DotWorld" Width="8" Height="8" Fill="#EF4444" VerticalAlignment="Center" Margin="0,0,7,0"/>
                <TextBlock Text="World" Foreground="#C47070" FontSize="11" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <TextBlock Name="LblWorld" Text="Stopped" Foreground="#EF4444" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <Border Background="#1E1212" CornerRadius="6" Padding="10,6" Margin="0,0,14,0">
              <StackPanel Orientation="Horizontal">
                <Ellipse Name="DotWeb" Width="8" Height="8" Fill="#EF4444" VerticalAlignment="Center" Margin="0,0,7,0"/>
                <TextBlock Text="Website" Foreground="#C47070" FontSize="11" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <TextBlock Name="LblWeb" Text="Stopped" Foreground="#EF4444" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
          </WrapPanel>

          <!-- Actions bar -->
          <WrapPanel>
            <Button Name="BtnLaunchAll"   Content="Launch Servers" Style="{StaticResource BtnGreen}" Margin="0,0,6,4" MinWidth="140"/>
            <Button Name="BtnShutdownAll" Content="Shut Down All"  Style="{StaticResource BtnRed}"   Margin="0,0,6,4" MinWidth="120"/>
            <Button Name="BtnOpenWebsite" Content="Open Website"   Style="{StaticResource BtnGray}"  Margin="0,0,12,4" MinWidth="110"/>
            <CheckBox Name="ChkWebsite" VerticalAlignment="Center" Foreground="#C47070"
                      FontSize="11" Content="Include Website on launch" Margin="0,0,12,4"/>
          </WrapPanel>
        </StackPanel>

        <!-- Console panels: Bnet (top) | World (bottom) -->
        <Grid Grid.Row="1" Margin="24,0,24,20">
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="8"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <Grid Grid.Row="0">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#1E1212" CornerRadius="8,8,0,0" Padding="12,7">
              <TextBlock Text="Auth Server" Foreground="#FFF2F2" FontSize="11" FontWeight="SemiBold"/>
            </Border>
            <Border Name="ConsoleAuth" Grid.Row="1" Background="#000000" CornerRadius="0,0,6,6"/>
          </Grid>

          <Grid Grid.Row="2">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#1E1212" CornerRadius="8,8,0,0" Padding="12,7">
              <TextBlock Text="World Server" Foreground="#FFF2F2" FontSize="11" FontWeight="SemiBold"/>
            </Border>
            <Border Name="ConsoleWorld" Grid.Row="1" Background="#000000" CornerRadius="0,0,6,6"/>
          </Grid>
        </Grid>
      </Grid>

      <!-- SERVER MANAGER -->
      <ScrollViewer Name="PageServers" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,22,24,24">

          <TextBlock Text="Server Manager" FontSize="20" FontWeight="Bold" Foreground="#FFF2F2"/>
          <TextBlock Text="Start, stop or restart each server individually" FontSize="12"
                     Foreground="#9E5555" Margin="0,3,0,18"/>

          <Border Style="{StaticResource Card}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse Name="SrvDotDB" Width="9" Height="9" Fill="#EF4444" Margin="0,0,10,0"/>
                <StackPanel>
                  <TextBlock Text="Database" Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold"/>
                  <TextBlock Name="SrvLblDB" Text="mysqld.exe - Stopped" Foreground="#9E5555" FontSize="11"/>
                </StackPanel>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button Name="SrvStartDB"   Content="Start"   Style="{StaticResource BtnGreen}" Margin="0,0,6,0" MinWidth="72"/>
                <Button Name="SrvStopDB"    Content="Stop"    Style="{StaticResource BtnRed}"   Margin="0,0,6,0" MinWidth="72"/>
                <Button Name="SrvRestartDB" Content="Restart" Style="{StaticResource BtnGray}"  MinWidth="72"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Style="{StaticResource Card}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse Name="SrvDotAuth" Width="9" Height="9" Fill="#EF4444" Margin="0,0,10,0"/>
                <StackPanel>
                  <TextBlock Text="Auth Server" Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold"/>
                  <TextBlock Name="SrvLblAuth" Text="authserver.exe - Stopped" Foreground="#9E5555" FontSize="11"/>
                </StackPanel>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button Name="SrvStartAuth"   Content="Start"   Style="{StaticResource BtnGreen}" Margin="0,0,6,0" MinWidth="72"/>
                <Button Name="SrvStopAuth"    Content="Stop"    Style="{StaticResource BtnRed}"   Margin="0,0,6,0" MinWidth="72"/>
                <Button Name="SrvRestartAuth" Content="Restart" Style="{StaticResource BtnGray}"  MinWidth="72"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Style="{StaticResource Card}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse Name="SrvDotWorld" Width="9" Height="9" Fill="#EF4444" Margin="0,0,10,0"/>
                <StackPanel>
                  <TextBlock Text="World Server" Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold"/>
                  <TextBlock Name="SrvLblWorld" Text="worldserver.exe - Stopped" Foreground="#9E5555" FontSize="11"/>
                </StackPanel>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button Name="SrvStartWorld"   Content="Start"   Style="{StaticResource BtnGreen}" Margin="0,0,6,0" MinWidth="72"/>
                <Button Name="SrvStopWorld"    Content="Stop"    Style="{StaticResource BtnRed}"   Margin="0,0,6,0" MinWidth="72"/>
                <Button Name="SrvRestartWorld" Content="Restart" Style="{StaticResource BtnGray}"  MinWidth="72"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Style="{StaticResource Card}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse Name="SrvDotWeb" Width="9" Height="9" Fill="#EF4444" Margin="0,0,10,0"/>
                <StackPanel>
                  <TextBlock Text="Website Server" Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold"/>
                  <TextBlock Name="SrvLblWeb" Text="httpd.exe - Stopped" Foreground="#9E5555" FontSize="11"/>
                </StackPanel>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button Name="SrvStartWeb"   Content="Start"   Style="{StaticResource BtnGreen}" Margin="0,0,6,0" MinWidth="72"/>
                <Button Name="SrvStopWeb"    Content="Stop"    Style="{StaticResource BtnRed}"   Margin="0,0,6,0" MinWidth="72"/>
                <Button Name="SrvRestartWeb" Content="Restart" Style="{StaticResource BtnGray}"  MinWidth="72"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="All Servers" Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,4"/>
              <TextBlock Text="* Website Server (Apache) is not included in bulk operations"
                         Foreground="#9E5555" FontSize="11" Margin="0,0,0,12"/>
              <StackPanel Orientation="Horizontal">
                <Button Name="BulkStart"   Content="Start All"   Style="{StaticResource BtnGreen}" Margin="0,0,8,0" MinWidth="130"/>
                <Button Name="BulkStop"    Content="Stop All"    Style="{StaticResource BtnRed}"   Margin="0,0,8,0" MinWidth="130"/>
                <Button Name="BulkRestart" Content="Restart All" Style="{StaticResource BtnGray}"  MinWidth="130"/>
              </StackPanel>
            </StackPanel>
          </Border>

        </StackPanel>
      </ScrollViewer>

      <!-- SETTINGS -->
      <ScrollViewer Name="PageSettings" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,22,24,24">

          <TextBlock Text="Settings" FontSize="20" FontWeight="Bold" Foreground="#FFF2F2"/>
          <TextBlock Text="Server configuration and tools" FontSize="12"
                     Foreground="#9E5555" Margin="0,3,0,18"/>

          <Border Style="{StaticResource Card}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0">
                <TextBlock Text="MySQL Connection" Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,12"/>
                <TextBlock Text="Host" Foreground="#9E5555" FontSize="11"/>
                <TextBlock Name="TxtMySQLHost" Foreground="#FFF2F2" FontSize="13" Margin="0,2,0,8"/>
                <TextBlock Text="Port" Foreground="#9E5555" FontSize="11"/>
                <TextBlock Name="TxtMySQLPort" Foreground="#FFF2F2" FontSize="13" Margin="0,2,0,0"/>
              </StackPanel>
              <StackPanel Grid.Column="1" Margin="16,0,0,0">
                <TextBlock Text=" " FontSize="13" FontWeight="SemiBold" Margin="0,0,0,12"/>
                <TextBlock Text="User" Foreground="#9E5555" FontSize="11"/>
                <TextBlock Name="TxtMySQLUser" Foreground="#FFF2F2" FontSize="13" Margin="0,2,0,8"/>
                <TextBlock Text="Password" Foreground="#9E5555" FontSize="11"/>
                <TextBlock Name="TxtMySQLPass" Foreground="#FFF2F2" FontSize="13" Margin="0,2,0,0"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Realm Name" Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,12"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox  Name="RealmInput"    Grid.Column="0" Style="{StaticResource TBox}" Margin="0,0,8,0"/>
                <Button   Name="BtnApplyRealm" Content="Apply" Grid.Column="1" Style="{StaticResource BtnGreen}" MinWidth="80"/>
              </Grid>
              <TextBlock Name="RealmMsg" Text="" Foreground="#FF5252" FontSize="11" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Configuration Files" Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,12"/>
              <WrapPanel>
                <Button Name="BtnAuthConf"    Content="Auth Config"       Style="{StaticResource BtnGray}" Margin="0,0,8,6"/>
                <Button Name="BtnWorldConf"   Content="World Config"      Style="{StaticResource BtnGray}" Margin="0,0,8,6"/>
                <Button Name="BtnOpenConfDir" Content="Folder" Style="{StaticResource BtnGray}" Margin="0,0,0,6"/>
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Tools" Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,12"/>
              <WrapPanel>
<Button Name="BtnHeidSQL"    Content="Database Tool" Style="{StaticResource BtnGray}" Margin="0,0,8,6"/>
                <Button Name="BtnServerLogs" Content="Server Logs"        Style="{StaticResource BtnGray}" Margin="0,0,0,6"/>
              </WrapPanel>
            </StackPanel>
          </Border>

        </StackPanel>
      </ScrollViewer>

      <!-- SAVES MANAGER -->
      <Grid Name="PageSaves" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="24,22,24,12">
          <TextBlock Text="Saves Manager" FontSize="20" FontWeight="Bold" Foreground="#FFF2F2"/>
          <TextBlock Text="Backup and restore your auth and characters databases" FontSize="12"
                     Foreground="#9E5555" Margin="0,3,0,0"/>
        </StackPanel>

        <Border Grid.Row="1" Background="#0C1610" CornerRadius="8" Margin="24,0,24,0"
                BorderThickness="1" BorderBrush="#1E3025" ClipToBounds="True">
          <ListView Name="SavesList" Background="Transparent" BorderThickness="0" Padding="0"
                    ItemContainerStyle="{StaticResource LvItem}" SelectionMode="Single">
            <ListView.Template>
              <ControlTemplate TargetType="ListView">
                <DockPanel LastChildFill="True">
                  <!-- Header wrapper: CornerRadius matches outer Border inner edge (8-1=7) -->
                  <Border DockPanel.Dock="Top" Background="#1E1212"
                          CornerRadius="7,7,0,0"
                          BorderThickness="0,0,0,1" BorderBrush="#6B2A2A">
                    <GridViewHeaderRowPresenter Margin="0"
                      Columns="{Binding Path=View.Columns, RelativeSource={RelativeSource TemplatedParent}}"
                      ColumnHeaderContainerStyle="{Binding Path=View.ColumnHeaderContainerStyle, RelativeSource={RelativeSource TemplatedParent}}"
                      AllowsColumnReorder="False"/>
                  </Border>
                  <ScrollViewer Focusable="False" Padding="0"
                                HorizontalScrollBarVisibility="Disabled"
                                VerticalScrollBarVisibility="Auto">
                    <ItemsPresenter/>
                  </ScrollViewer>
                </DockPanel>
              </ControlTemplate>
            </ListView.Template>
            <ListView.View>
              <GridView ColumnHeaderContainerStyle="{StaticResource GvHeader}">
                <GridViewColumn Width="60">
                  <GridViewColumn.HeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource GvHeader}">
                      <Setter Property="Padding" Value="0,9"/>
                      <Setter Property="Template">
                        <Setter.Value>
                          <ControlTemplate TargetType="GridViewColumnHeader">
                            <Border Background="Transparent" Padding="{TemplateBinding Padding}">
                              <TextBlock Text="{TemplateBinding Content}"
                                         Foreground="{TemplateBinding Foreground}"
                                         FontSize="{TemplateBinding FontSize}"
                                         FontWeight="{TemplateBinding FontWeight}"
                                         HorizontalAlignment="Center"
                                         VerticalAlignment="Center"/>
                            </Border>
                          </ControlTemplate>
                        </Setter.Value>
                      </Setter>
                    </Style>
                  </GridViewColumn.HeaderContainerStyle>
                  <GridViewColumn.Header>Slot</GridViewColumn.Header>
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <TextBlock Text="{Binding Slot}" HorizontalAlignment="Center"
                                 VerticalAlignment="Center" Margin="-24,0,0,0"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Width="330">
                  <GridViewColumn.HeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource GvHeader}">
                      <Setter Property="Padding" Value="34,9"/>
                    </Style>
                  </GridViewColumn.HeaderContainerStyle>
                  <GridViewColumn.Header>Name</GridViewColumn.Header>
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <TextBlock Text="{Binding Name}" VerticalAlignment="Center" Margin="16,0,0,0"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Width="100">
                  <GridViewColumn.HeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource GvHeader}">
                      <Setter Property="Padding" Value="12,9"/>
                    </Style>
                  </GridViewColumn.HeaderContainerStyle>
                  <GridViewColumn.Header>Status</GridViewColumn.Header>
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <TextBlock Text="{Binding Status}" VerticalAlignment="Center" Margin="-6,0,0,0"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
              </GridView>
            </ListView.View>
          </ListView>
        </Border>

        <Border Grid.Row="2" Background="#1E1212" CornerRadius="8" Margin="24,10,24,24" Padding="16,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Name="SaveMsg" Grid.Column="0" Text="Select a slot and choose an action."
                       Foreground="#9E5555" FontSize="11" VerticalAlignment="Center"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
              <Button Name="BtnSave"       Content="Save"   Style="{StaticResource BtnGreen}" Margin="0,0,6,0" MinWidth="90"/>
              <Button Name="BtnLoad"       Content="Load"   Style="{StaticResource BtnGray}"  Margin="0,0,6,0" MinWidth="90"/>
              <Button Name="BtnDelete"     Content="Delete" Style="{StaticResource BtnRed}"   Margin="0,0,6,0" MinWidth="90"/>
              <Button Name="BtnSaveFolder" Content="Folder" Style="{StaticResource BtnGray}"  MinWidth="90"/>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>

      <!-- ACCOUNT MANAGER -->
      <Grid Name="PageAccounts" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="24,22,24,12">
          <TextBlock Text="Account Manager" FontSize="20" FontWeight="Bold" Foreground="#FFF2F2"/>
          <TextBlock Text="Create, modify and delete game accounts directly in the Auth database" FontSize="12"
                     Foreground="#9E5555" Margin="0,3,0,0"/>
        </StackPanel>

        <Border Grid.Row="1" Background="#0C1610" CornerRadius="8" Margin="24,0,24,0"
                BorderThickness="1" BorderBrush="#1E3025" ClipToBounds="True">
          <ListView Name="AccountsList" Background="Transparent" BorderThickness="0" Padding="0"
                    ItemContainerStyle="{StaticResource LvItem}" SelectionMode="Single">
            <ListView.Template>
              <ControlTemplate TargetType="ListView">
                <DockPanel LastChildFill="True">
                  <Border DockPanel.Dock="Top" Background="#1E1212"
                          CornerRadius="7,7,0,0"
                          BorderThickness="0,0,0,1" BorderBrush="#6B2A2A">
                    <GridViewHeaderRowPresenter Margin="0"
                      Columns="{Binding Path=View.Columns, RelativeSource={RelativeSource TemplatedParent}}"
                      ColumnHeaderContainerStyle="{Binding Path=View.ColumnHeaderContainerStyle, RelativeSource={RelativeSource TemplatedParent}}"
                      AllowsColumnReorder="False"/>
                  </Border>
                  <ScrollViewer Focusable="False" Padding="0"
                                HorizontalScrollBarVisibility="Disabled"
                                VerticalScrollBarVisibility="Auto">
                    <ItemsPresenter/>
                  </ScrollViewer>
                </DockPanel>
              </ControlTemplate>
            </ListView.Template>
            <ListView.View>
              <GridView ColumnHeaderContainerStyle="{StaticResource GvHeader}">
                <GridViewColumn Width="60">
                  <GridViewColumn.HeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource GvHeader}">
                      <Setter Property="Padding" Value="18,9"/>
                    </Style>
                  </GridViewColumn.HeaderContainerStyle>
                  <GridViewColumn.Header>ID</GridViewColumn.Header>
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <TextBlock Text="{Binding Id}" VerticalAlignment="Center"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Width="190">
                  <GridViewColumn.HeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource GvHeader}">
                      <Setter Property="Padding" Value="18,9"/>
                    </Style>
                  </GridViewColumn.HeaderContainerStyle>
                  <GridViewColumn.Header>Username</GridViewColumn.Header>
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <TextBlock Text="{Binding Username}" VerticalAlignment="Center"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Width="280">
                  <GridViewColumn.HeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource GvHeader}">
                      <Setter Property="Padding" Value="18,9"/>
                    </Style>
                  </GridViewColumn.HeaderContainerStyle>
                  <GridViewColumn.Header>Email</GridViewColumn.Header>
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <TextBlock Text="{Binding Email}" VerticalAlignment="Center"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Width="140">
                  <GridViewColumn.HeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource GvHeader}">
                      <Setter Property="Padding" Value="18,9"/>
                    </Style>
                  </GridViewColumn.HeaderContainerStyle>
                  <GridViewColumn.Header>Level</GridViewColumn.Header>
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <TextBlock Text="{Binding LevelName}" VerticalAlignment="Center"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
              </GridView>
            </ListView.View>
          </ListView>
        </Border>

        <Border Grid.Row="2" Background="#1E1212" CornerRadius="8" Margin="24,10,24,24" Padding="16,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Name="AccMsg" Grid.Column="0" Text="Select an account to manage it."
                       Foreground="#9E5555" FontSize="11" VerticalAlignment="Center"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
              <Button Name="BtnAccCreate"   Content="Create Account"  Style="{StaticResource BtnGreen}" Margin="0,0,6,0" MinWidth="120"/>
              <Button Name="BtnAccEdit"     Content="Edit Account"    Style="{StaticResource BtnGray}"  Margin="0,0,6,0" MinWidth="110"/>
              <Button Name="BtnAccPassword" Content="Change Password" Style="{StaticResource BtnGray}"  Margin="0,0,6,0" MinWidth="140"/>
              <Button Name="BtnAccDelete"   Content="Delete"          Style="{StaticResource BtnRed}"   MinWidth="90"/>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>

      <!-- MAINTENANCE -->
      <ScrollViewer Name="PageService" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,22,24,24">

          <TextBlock Text="Maintenance" FontSize="20" FontWeight="Bold" Foreground="#FFF2F2"/>
          <TextBlock Text="Maintenance and installers" FontSize="12"
                     Foreground="#9E5555" Margin="0,3,0,18"/>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Install Visual C++ Redistributable (x86 + x64)"
                         Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold"/>
              <TextBlock Text="Required to run the servers. Install if you see DLL errors."
                         Foreground="#9E5555" FontSize="11" Margin="0,4,0,12"/>
              <Button Name="BtnVCRedist" Content="Install VC++ Redist"
                      Style="{StaticResource BtnGreen}" HorizontalAlignment="Left" MinWidth="200"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Create Desktop Shortcut"
                         Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold"/>
              <TextBlock Text="Adds a shortcut to this launcher on your Desktop."
                         Foreground="#9E5555" FontSize="11" Margin="0,4,0,12"/>
              <Button Name="BtnShortcut" Content="Create Shortcut"
                      Style="{StaticResource BtnGreen}" HorizontalAlignment="Left" MinWidth="200"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Check Launcher Updates"
                         Foreground="#FFF2F2" FontSize="13" FontWeight="SemiBold"/>
              <TextBlock Text="Opens the GitHub releases page to check for new launcher versions."
                         Foreground="#9E5555" FontSize="11" Margin="0,4,0,12"/>
              <Button Name="BtnCheckUpdates" Content="Check for Updates"
                      Style="{StaticResource BtnGreen}" HorizontalAlignment="Left" MinWidth="200"/>
            </StackPanel>
          </Border>

        </StackPanel>
      </ScrollViewer>

    </Grid>

  </Grid>
</Window>
'@)

# ── Load window ───────────────────────────────────────────────────────────────

$reader = New-Object System.Xml.XmlNodeReader $xaml
try   { $win = [Windows.Markup.XamlReader]::Load($reader) }
catch { [System.Windows.Forms.MessageBox]::Show("XAML Error:`n`n$_", "Launcher Error"); exit 1 }

# Bind elements — Name= (not x:Name=) lets @Name work in XPath
$xaml.SelectNodes("//*[@Name]") | ForEach-Object {
    Set-Variable -Name $_.Name -Value $win.FindName($_.Name) -Scope Script
}

# Window icon
$iconPath = "$iconsDir\Launcher.ico"
if (Test-Path $iconPath) {
    try { $win.Icon = [Windows.Media.Imaging.BitmapImage]::new([uri]$iconPath) } catch {}
}

# ── Reusable colors ───────────────────────────────────────────────────────────

$GREEN = [Windows.Media.SolidColorBrush]([Windows.Media.Color]::FromRgb(0, 230, 118))
$RED   = [Windows.Media.SolidColorBrush]([Windows.Media.Color]::FromRgb(239, 68,  68))
$_bh   = $Script:theme.AccentBlue.TrimStart('#')
$BLUE  = [Windows.Media.SolidColorBrush]([Windows.Media.Color]::FromRgb(
    [Convert]::ToByte($_bh.Substring(0,2),16),
    [Convert]::ToByte($_bh.Substring(2,2),16),
    [Convert]::ToByte($_bh.Substring(4,2),16)))

$Script:wpfHwnd   = [IntPtr]::Zero   # set on Loaded
$Script:hwndAuth  = [IntPtr]::Zero   # HWND of embedded bnetserver console
$Script:hwndWorld = [IntPtr]::Zero   # HWND of embedded worldserver console

# ── Console embedding (Win32 SetParent) ───────────────────────────────────────

function Invoke-EmbedConsole($placeholder, $hwnd) {
    if ($hwnd -eq [IntPtr]::Zero -or $Script:wpfHwnd -eq [IntPtr]::Zero) { return }
    $src = [Windows.PresentationSource]::FromVisual($win)
    if (-not $src) { return }
    $sx = $src.CompositionTarget.TransformToDevice.M11
    $sy = $src.CompositionTarget.TransformToDevice.M22
    try   { $pt = $placeholder.TransformToAncestor($win).Transform([Windows.Point]::new(0,0)) }
    catch { return }
    $x = [int]($pt.X * $sx); $y = [int]($pt.Y * $sy)
    $w = [int]($placeholder.ActualWidth * $sx); $h = [int]($placeholder.ActualHeight * $sy)
    if ($w -le 0 -or $h -le 0) { return }
    # Reparent to WPF window
    [SPP.WinAPI]::SetParent($hwnd, $Script:wpfHwnd) | Out-Null
    # Strip title bar, resize borders and system menu
    $s = [SPP.WinAPI]::GetWindowLong($hwnd, -16)
    $s = $s -band (-bnot 0x00C00000) -band (-bnot 0x00040000) -band (-bnot 0x00080000)
    [SPP.WinAPI]::SetWindowLong($hwnd, -16, $s) | Out-Null
    [SPP.WinAPI]::MoveWindow($hwnd, $x, $y, $w, $h, $true) | Out-Null
    # Only show the console if the Dashboard page is currently active
    $sw = if ($PageMain.Visibility -eq "Visible") { 1 } else { 0 }
    [SPP.WinAPI]::ShowWindow($hwnd, $sw) | Out-Null
}

function Sync-Consoles {
    # Detects newly started servers and embeds them. Updates cached HWNDs.
    if ($Script:wpfHwnd -eq [IntPtr]::Zero) { return }
    foreach ($item in @(
        @{ ProcName = "authserver";  Placeholder = $ConsoleAuth  },
        @{ ProcName = "worldserver"; Placeholder = $ConsoleWorld }
    )) {
        $isBnet = $item.ProcName -eq "authserver"
        $proc = Get-Process -Name $item.ProcName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $proc) {
            if ($isBnet) { $Script:hwndAuth = [IntPtr]::Zero } else { $Script:hwndWorld = [IntPtr]::Zero }
            continue
        }
        $hwnd = $proc.MainWindowHandle
        if ($hwnd -eq [IntPtr]::Zero) { continue }
        if ([SPP.WinAPI]::GetParent($hwnd) -ne $Script:wpfHwnd) {
            Invoke-EmbedConsole $item.Placeholder $hwnd
            [SPP.ConsoleColors]::Apply([uint32]$proc.Id, $Script:theme.ConsoleColor) | Out-Null
        }
        if ($isBnet) { $Script:hwndAuth = $hwnd } else { $Script:hwndWorld = $hwnd }
    }
}

function Reposition-Console($placeholder, $hwnd) {
    # Lightweight: only MoveWindow — no process lookup. Called on every layout pass.
    if ($hwnd -eq [IntPtr]::Zero -or $Script:wpfHwnd -eq [IntPtr]::Zero) { return }
    $src = [Windows.PresentationSource]::FromVisual($win)
    if (-not $src) { return }
    $sx = $src.CompositionTarget.TransformToDevice.M11
    $sy = $src.CompositionTarget.TransformToDevice.M22
    try {
        $pt = $placeholder.TransformToAncestor($win).Transform([Windows.Point]::new(0,0))
        $x = [int]($pt.X * $sx); $y = [int]($pt.Y * $sy)
        $w = [int]($placeholder.ActualWidth * $sx)
        $h = [int]($placeholder.ActualHeight * $sy)
        if ($w -gt 0 -and $h -gt 0) { [SPP.WinAPI]::MoveWindow($hwnd, $x, $y, $w, $h, $true) | Out-Null }
    } catch {}
}

# ── Status update ─────────────────────────────────────────────────────────────

function Set-DotStatus($dot, $lbl, [bool]$running) {
    if ($null -eq $dot -or $null -eq $lbl) { return }
    if ($running) { $dot.Fill = $GREEN; $lbl.Foreground = $GREEN; $lbl.Text = "Running" }
    else          { $dot.Fill = $RED;   $lbl.Foreground = $RED;   $lbl.Text = "Stopped" }
}

$Script:lastDbRunning = $false

function Refresh-Status {
    $db    = Test-Proc "mysqld"
    $bnet  = Test-Proc "authserver"
    $world = Test-Proc "worldserver"
    $web   = Test-Proc "httpd"

    Set-DotStatus $DotDB    $LblDB    $db
    Set-DotStatus $DotAuth  $LblAuth  $bnet
    Set-DotStatus $DotWorld $LblWorld $world
    Set-DotStatus $DotWeb   $LblWeb   $web

    Set-DotStatus $SrvDotDB    $SrvLblDB    $db
    Set-DotStatus $SrvDotAuth  $SrvLblAuth  $bnet
    Set-DotStatus $SrvDotWorld $SrvLblWorld $world
    Set-DotStatus $SrvDotWeb   $SrvLblWeb   $web

    $SrvLblDB.Text    = "mysqld.exe - "     + $SrvLblDB.Text
    $SrvLblAuth.Text  = "authserver.exe - " + $SrvLblAuth.Text
    $SrvLblWorld.Text = "worldserver.exe - "+ $SrvLblWorld.Text
    $SrvLblWeb.Text   = "httpd.exe - "  + $SrvLblWeb.Text

    # Query realm name only on MySQL start transition — never on every tick
    if ($db -and -not $Script:lastDbRunning) {
        $n = Get-RealmName
        $DashSubtitle.Text = if ($n) { $n } else { "" }
    } elseif (-not $db) {
        $DashSubtitle.Text = ""
    }
    $Script:lastDbRunning = $db

    if ($PageMain.Visibility -eq "Visible") { Sync-Consoles }
}

# ── Navigation ────────────────────────────────────────────────────────────────

$allPages   = @($PageMain, $PageServers, $PageSaves, $PageAccounts, $PageSettings, $PageService)
$allNavBtns = @($NavMain,  $NavServers,  $NavSaves,  $NavAccounts,  $NavSettings,  $NavService)

function Switch-Page([int]$idx) {
    for ($i = 0; $i -lt $allPages.Count; $i++) {
        $allPages[$i].Visibility = if ($i -eq $idx) { "Visible" } else { "Collapsed" }
        $allNavBtns[$i].Style    = $win.Resources[$(if ($i -eq $idx) { "NavBtnActive" } else { "NavBtn" })]
    }
    # Show embedded consoles only when Dashboard is active
    $sw = if ($idx -eq 0) { 5 } else { 0 }   # SW_SHOW=5, SW_HIDE=0
    foreach ($hwnd in @($Script:hwndAuth, $Script:hwndWorld)) {
        if ($hwnd -ne [IntPtr]::Zero) { [SPP.WinAPI]::ShowWindow($hwnd, $sw) | Out-Null }
    }
    if ($idx -eq 0) { Sync-Consoles; $n = Get-RealmName; if ($n) { $DashSubtitle.Text = $n } }
    if ($idx -eq 2) { Refresh-Saves }
    if ($idx -eq 3) { Refresh-Accounts }
    if ($idx -eq 4) { $n = Get-RealmName; $RealmInput.Text = $n; $DashSubtitle.Text = $n }
}

$NavMain.Add_Click(          { Switch-Page 0 })
$NavServers.Add_Click(       { Switch-Page 1 })
$NavSaves.Add_Click(         { Switch-Page 2 })
$NavAccounts.Add_Click(      { Switch-Page 3 })
$NavSettings.Add_Click(      { Switch-Page 4 })
$NavService.Add_Click(       { Switch-Page 5 })

# ── Dashboard actions ─────────────────────────────────────────────────────────

$BtnLaunchAll.Add_Click({
    Show-Overlay "Starting servers..."
    $withWeb = $ChkWebsite.IsChecked
    $steps = if ($withWeb) {
        @({ Start-DBServer }, 2, { Start-AuthServer }, 1, { Start-WorldServer }, 1,
          { Start-WebServer }, 3, { Start-Process "http://127.0.0.1" }, 1,
          { Start-EmbedTimer; Refresh-Status; Hide-Overlay })
    } else {
        @({ Start-DBServer }, 2, { Start-AuthServer }, 1, { Start-WorldServer }, 1,
          { Start-EmbedTimer; Refresh-Status; Hide-Overlay })
    }
    Invoke-Async $steps
})

$BtnShutdownAll.Add_Click({
    if (-not (Show-Confirm "Shut down all servers?")) { return }
    Show-Overlay "Shutting down all servers..."
    Stop-WorldServer { Stop-AuthServer; Stop-WebServer; Stop-DBServer; Refresh-Status; Hide-Overlay }
})

$BtnOpenWebsite.Add_Click({ Start-Process "http://127.0.0.1" })

# ── Server Manager ────────────────────────────────────────────────────────────

$SrvStartDB.Add_Click({
    Show-Overlay "Starting Database..."
    Invoke-Async @({ Start-DBServer }, 1, { Refresh-Status; Hide-Overlay })
})
$SrvStopDB.Add_Click({
    Show-Overlay "Stopping Database..."
    Invoke-Async @({ Stop-DBServer }, 1, { Refresh-Status; Hide-Overlay })
})
$SrvRestartDB.Add_Click({
    Show-Overlay "Restarting Database..."
    Invoke-Async @({ Stop-DBServer }, 2, { Start-DBServer }, 1, { Refresh-Status; Hide-Overlay })
})

$SrvStartAuth.Add_Click({
    Show-Overlay "Starting Auth server..."
    Invoke-Async @({ Start-AuthServer }, 1, { Refresh-Status; Hide-Overlay })
})
$SrvStopAuth.Add_Click({
    Show-Overlay "Stopping Auth server..."
    Invoke-Async @({ Stop-AuthServer }, 1, { Refresh-Status; Hide-Overlay })
})
$SrvRestartAuth.Add_Click({
    Show-Overlay "Restarting Auth server..."
    Invoke-Async @({ Stop-AuthServer }, 1, { Start-AuthServer }, 1, { Refresh-Status; Hide-Overlay })
})

$SrvStartWorld.Add_Click({
    Show-Overlay "Starting World server..."
    Invoke-Async @({ Start-DBServer }, 2, { Start-AuthServer }, 1, { Start-WorldServer }, 1, { Refresh-Status; Hide-Overlay })
})
$SrvStopWorld.Add_Click({
    Show-Overlay "Stopping World server..."
    Stop-WorldServer { Refresh-Status; Hide-Overlay }
})
$SrvRestartWorld.Add_Click({
    Show-Overlay "Restarting World server..."
    Stop-WorldServer {
        Invoke-Async @({ Start-DBServer }, 2, { Start-AuthServer }, 1, { Start-WorldServer }, 1, { Refresh-Status; Hide-Overlay })
    }
})

$SrvStartWeb.Add_Click({
    Show-Overlay "Starting Website..."
    Invoke-Async @({ Start-DBServer }, 2, { Start-WebServer }, 3, { Start-Process "http://127.0.0.1"; Refresh-Status; Hide-Overlay })
})
$SrvStopWeb.Add_Click({
    Show-Overlay "Stopping Website..."
    Invoke-Async @({ Stop-WebServer }, 1, { Refresh-Status; Hide-Overlay })
})
$SrvRestartWeb.Add_Click({
    Show-Overlay "Restarting Website..."
    Invoke-Async @({ Stop-WebServer }, 1, { Start-DBServer }, 2, { Start-WebServer }, 3, { Refresh-Status; Hide-Overlay })
})

$BulkStart.Add_Click({
    Show-Overlay "Starting all servers..."
    Invoke-Async @({ Start-DBServer }, 2, { Start-AuthServer }, 1, { Start-WorldServer }, 1, { Start-EmbedTimer; Refresh-Status; Hide-Overlay })
})
$BulkStop.Add_Click({
    Show-Overlay "Stopping all servers..."
    Stop-WorldServer { Stop-AuthServer; Stop-WebServer; Stop-DBServer; Refresh-Status; Hide-Overlay }
})
$BulkRestart.Add_Click({
    Show-Overlay "Restarting all servers..."
    Stop-WorldServer {
        Stop-AuthServer; Stop-WebServer; Stop-DBServer
        Invoke-Async @({ Start-DBServer }, 2, { Start-AuthServer }, 1, { Start-WorldServer }, 1, { Refresh-Status; Hide-Overlay })
    }
})

# ── Settings ──────────────────────────────────────────────────────────────────

function Open-Config([string]$path) {
    if (-not (Test-Path $path)) { Show-Alert "File not found:`n$path"; return }
    $npp = $Script:srvDirs.Notepad
    if (Test-Path $npp) { Start-Process $npp "`"$path`"" } else { Start-Process notepad.exe "`"$path`"" }
}

$BtnAuthConf.Add_Click({    Open-Config $Script:srvDirs.AuthConf  })
$BtnWorldConf.Add_Click({   Open-Config $Script:srvDirs.WorldConf })
$BtnOpenConfDir.Add_Click({
    $d = $Script:srvDirs.ConfigFolder
    if (Test-Path $d) { Start-Process explorer $d }
    else { Show-Alert "Folder not found:`n$d" }
})

$BtnHeidSQL.Add_Click({
    $exe = $Script:srvDirs.HeidiSQL
    if (Test-Path $exe) {
        $c = $Script:mysqlCfg
        Start-Process $exe "--description=$($c.Description) --host=$($c.Host) --port=$($c.Port) --user=$($c.User) --password=$($c.Password)"
    } else { Show-Alert "Not found:`n$exe" }
})

$BtnServerLogs.Add_Click({
    $d = $Script:srvDirs.LogsFolder
    if (Test-Path $d) { Start-Process explorer $d }
    else { Show-Alert "Folder not found:`n$d" }
})

# ── Account Manager ────────────────────────────────────────────────────────────

function Invoke-AuthQuery([string]$sql) {
    if (-not (Test-Proc "mysqld")) { return $null }
    $mysqlExe = "$mainfolder\Database\bin\mysql.exe"
    $conf     = "$connectDir\connection_auth.cnf"
    if (-not (Test-Path $mysqlExe) -or -not (Test-Path $conf)) { return $null }
    try { return (& "$mysqlExe" "--defaults-extra-file=$conf" --silent --skip-column-names -e $sql 2>$null) }
    catch { return $null }
}

function Get-LevelName([int]$n) {
    switch ($n) {
        0 { "Player" }; 1 { "Moderator" }; 2 { "Game Master" }; 3 { "Administrator" }
        default { "Level $n" }
    }
}

function New-AccountSRP6([string]$username, [string]$password) {
    # AzerothCore uses WoW SRP6: verifier = g^x mod N
    # where x = SHA1(salt || SHA1(UPPER(username) + ":" + UPPER(password)))
    # N and g are the standard WoW SRP6 constants
    $N_hex = '894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7'
    $N_be  = [byte[]]@(for ($i = 0; $i -lt $N_hex.Length; $i += 2) { [Convert]::ToByte($N_hex.Substring($i,2),16) })
    [Array]::Reverse($N_be)  # to little-endian for BigInteger
    $N = [System.Numerics.BigInteger]::new([byte[]]($N_be + [byte]0x00))
    $g = [System.Numerics.BigInteger]::new(7)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    # 1. Random 32-byte salt
    $salt = [byte[]]::new(32)
    $rng.GetBytes($salt)

    # 2. H(I) = SHA1(UPPER(username) + ":" + UPPER(password))
    $h_I = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($username.ToUpper() + ':' + $password.ToUpper()))

    # 3. x = SHA1(salt || H(I))
    $x_bytes = $sha1.ComputeHash([byte[]]($salt + $h_I))
    $x = [System.Numerics.BigInteger]::new([byte[]]($x_bytes + [byte]0x00))

    # 4. v = g^x mod N  (stored as 32-byte little-endian)
    $v_raw    = [System.Numerics.BigInteger]::ModPow($g, $x, $N).ToByteArray()
    $verifier = [byte[]]::new(32)
    [Array]::Copy($v_raw, $verifier, [Math]::Min($v_raw.Length, 32))

    return @{
        SaltHex     = ($salt     | ForEach-Object { $_.ToString('X2') }) -join ''
        VerifierHex = ($verifier | ForEach-Object { $_.ToString('X2') }) -join ''
    }
}

function Get-Accounts {
    $rows = Invoke-AuthQuery "SELECT a.id, a.username, a.email, COALESCE(MAX(aa.gmlevel),0) FROM acore_auth.account a LEFT JOIN acore_auth.account_access aa ON a.id=aa.id GROUP BY a.id,a.username,a.email ORDER BY a.username;"
    if (-not $rows) { return @() }
    $rows | ForEach-Object {
        $c = $_ -split "`t"
        if ($c.Count -ge 4) {
            [PSCustomObject]@{ Id=[int]$c[0]; Username=$c[1]; Email=$c[2]; GmLevel=[int]$c[3]; LevelName=(Get-LevelName ([int]$c[3])) }
        }
    }
}

function Refresh-Accounts {
    $AccountsList.Items.Clear()
    $AccMsg.Text = "Select an account to manage it."
    if (-not (Test-Proc "mysqld")) { $AccMsg.Text = "Database is not running. Start MySQL to manage accounts."; return }
    Get-Accounts | ForEach-Object { $AccountsList.Items.Add($_) }
    if ($AccountsList.Items.Count -eq 0) { $AccMsg.Text = "No accounts found." }
}

function Show-CreateAccount {
    $d = New-Dialog @'
    <StackPanel>
      <TextBlock Text="Create Account" Foreground="#FFF2F2" FontSize="15" FontWeight="Bold" Margin="0,0,0,18"/>
      <TextBlock Text="Username" Foreground="#C47070" FontSize="11" Margin="0,0,0,4"/>
      <Border Background="#1E1212" CornerRadius="6" BorderThickness="1" BorderBrush="#6B2A2A" Padding="10,7" Margin="0,0,0,10">
        <TextBox Name="TxtUser" Background="Transparent" Foreground="#FFF2F2" BorderThickness="0" FontSize="12" CaretBrush="#FF5252"/>
      </Border>
      <TextBlock Text="Email" Foreground="#C47070" FontSize="11" Margin="0,0,0,4"/>
      <Border Background="#1E1212" CornerRadius="6" BorderThickness="1" BorderBrush="#6B2A2A" Padding="10,7" Margin="0,0,0,10">
        <TextBox Name="TxtEmail" Background="Transparent" Foreground="#FFF2F2" BorderThickness="0" FontSize="12" CaretBrush="#FF5252"/>
      </Border>
      <TextBlock Text="Password" Foreground="#C47070" FontSize="11" Margin="0,0,0,4"/>
      <Border Background="#1E1212" CornerRadius="6" BorderThickness="1" BorderBrush="#6B2A2A" Padding="10,7" Margin="0,0,0,10">
        <TextBox Name="TxtPass" Background="Transparent" Foreground="#FFF2F2" BorderThickness="0" FontSize="12" CaretBrush="#FF5252"/>
      </Border>
      <TextBlock Text="Account Level" Foreground="#C47070" FontSize="11" Margin="0,0,0,4"/>
      <ComboBox Name="CmbLevel" Margin="0,0,0,14">
        <ComboBoxItem Content="Player"        Tag="0" IsSelected="True"/>
        <ComboBoxItem Content="Moderator"     Tag="1"/>
        <ComboBoxItem Content="Game Master"   Tag="2"/>
        <ComboBoxItem Content="Administrator" Tag="3"/>
      </ComboBox>
      <TextBlock Name="ErrMsg" Foreground="#EF4444" FontSize="11" Margin="0,0,0,10" Visibility="Collapsed" TextWrapping="Wrap"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,4,0,0">
        <Button Name="BtnCancel" Content="Cancel" Style="{StaticResource DBtn}" Background="#6B2A2A" Foreground="#FFF2F2" Margin="0,0,10,0"/>
        <Button Name="BtnCreate" Content="Create" Style="{StaticResource DBtn}" Background="#C41E3A" Foreground="#120808"/>
      </StackPanel>
    </StackPanel>
'@
    $errMsg   = $d.FindName("ErrMsg")
    $txtUser  = $d.FindName("TxtUser")
    $txtEmail = $d.FindName("TxtEmail")
    $txtPass  = $d.FindName("TxtPass")
    $cmbLevel = $d.FindName("CmbLevel")

    $d.FindName("BtnCancel").Add_Click({ $d.DialogResult = $false })
    $d.FindName("BtnCreate").Add_Click({
        $u   = $txtUser.Text.Trim().ToUpper()
        $e   = $txtEmail.Text.Trim()
        $p   = $txtPass.Text
        $lvl = [int]($cmbLevel.SelectedItem.Tag)

        if ($u -notmatch '^[A-Za-z0-9_]{3,16}$')        { $errMsg.Text = "Username: 3-16 chars, letters/numbers/underscore."; $errMsg.Visibility = "Visible"; return }
        if ($e -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$')  { $errMsg.Text = "Enter a valid email address.";                     $errMsg.Visibility = "Visible"; return }
        if ($p.Length -lt 6)                              { $errMsg.Text = "Password must be at least 6 characters.";          $errMsg.Visibility = "Visible"; return }

        $uEsc = $u.Replace("'","''")
        $eEsc = $e.ToUpper().Replace("'","''")

        $existsUser = Invoke-AuthQuery "SELECT COUNT(*) FROM acore_auth.account WHERE username='$uEsc';"
        if ($existsUser -and [int]($existsUser.Trim()) -gt 0) { $errMsg.Text = "Username already exists."; $errMsg.Visibility = "Visible"; return }

        $existsEmail = Invoke-AuthQuery "SELECT COUNT(*) FROM acore_auth.account WHERE email='$eEsc';"
        if ($existsEmail -and [int]($existsEmail.Trim()) -gt 0) { $errMsg.Text = "An account with this email already exists."; $errMsg.Visibility = "Visible"; return }

        # Create account with SRP6 salt+verifier
        $srp = New-AccountSRP6 $u $p
        Invoke-AuthQuery "INSERT INTO acore_auth.account (username,salt,verifier,email,reg_mail,joindate,last_ip,expansion) VALUES ('$uEsc',UNHEX('$($srp.SaltHex)'),UNHEX('$($srp.VerifierHex)'),'$eEsc','$eEsc',NOW(),'127.0.0.1',2);" | Out-Null

        # Register account in realmcharacters for every realm
        Invoke-AuthQuery "INSERT INTO acore_auth.realmcharacters (acctid, realmid, numchars) SELECT a.id, r.id, 0 FROM acore_auth.account a JOIN acore_auth.realmlist r WHERE a.username='$uEsc';" | Out-Null

        # Set GM level if needed
        if ($lvl -gt 0) {
            Invoke-AuthQuery "INSERT INTO acore_auth.account_access (id,gmlevel,RealmID) SELECT id,$lvl,-1 FROM acore_auth.account WHERE username='$uEsc';" | Out-Null
        }
        $d.DialogResult = $true
    })
    return ($d.ShowDialog() -eq $true)
}

function Show-ChangePassword([PSCustomObject]$acc) {
    $d = New-Dialog (@"
    <StackPanel>
      <TextBlock Text="Change Password" Foreground="#FFF2F2" FontSize="15" FontWeight="Bold" Margin="0,0,0,4"/>
      <TextBlock Text="Account: $($acc.Username)" Foreground="#C47070" FontSize="11" Margin="0,0,0,18"/>
      <TextBlock Text="New Password" Foreground="#C47070" FontSize="11" Margin="0,0,0,4"/>
      <Border Background="#1E1212" CornerRadius="6" BorderThickness="1" BorderBrush="#6B2A2A" Padding="10,7" Margin="0,0,0,10">
        <PasswordBox Name="TxtPass" Background="Transparent" Foreground="#FFF2F2" BorderThickness="0" FontSize="12"/>
      </Border>
      <TextBlock Text="Confirm Password" Foreground="#C47070" FontSize="11" Margin="0,0,0,4"/>
      <Border Background="#1E1212" CornerRadius="6" BorderThickness="1" BorderBrush="#6B2A2A" Padding="10,7" Margin="0,0,0,14">
        <PasswordBox Name="TxtPass2" Background="Transparent" Foreground="#FFF2F2" BorderThickness="0" FontSize="12"/>
      </Border>
      <TextBlock Name="ErrMsg" Foreground="#EF4444" FontSize="11" Margin="0,0,0,10" Visibility="Collapsed"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,4,0,0">
        <Button Name="BtnCancel" Content="Cancel" Style="{StaticResource DBtn}" Background="#6B2A2A" Foreground="#FFF2F2" Margin="0,0,10,0"/>
        <Button Name="BtnSave"   Content="Save"   Style="{StaticResource DBtn}" Background="#C41E3A" Foreground="#120808"/>
      </StackPanel>
    </StackPanel>
"@)
    $errMsg   = $d.FindName("ErrMsg")
    $txtPass  = $d.FindName("TxtPass")
    $txtPass2 = $d.FindName("TxtPass2")

    $d.FindName("BtnCancel").Add_Click({ $d.DialogResult = $false })
    $d.FindName("BtnSave").Add_Click({
        $p  = $txtPass.Password
        $p2 = $txtPass2.Password
        if ($p.Length -lt 6) { $errMsg.Text = "Password must be at least 6 characters."; $errMsg.Visibility = "Visible"; return }
        if ($p -ne $p2)      { $errMsg.Text = "Passwords do not match.";                 $errMsg.Visibility = "Visible"; return }
        $srp = New-AccountSRP6 $acc.Username $p
        Invoke-AuthQuery "UPDATE acore_auth.account SET salt=UNHEX('$($srp.SaltHex)'),verifier=UNHEX('$($srp.VerifierHex)'),session_key=NULL WHERE id=$($acc.Id);" | Out-Null
        $d.DialogResult = $true
    })
    return ($d.ShowDialog() -eq $true)
}

function Show-EditAccount([PSCustomObject]$acc) {
    $d = New-Dialog @'
    <StackPanel>
      <TextBlock Text="Edit Account" Foreground="#FFF2F2" FontSize="15" FontWeight="Bold" Margin="0,0,0,18"/>
      <TextBlock Text="Username" Foreground="#C47070" FontSize="11" Margin="0,0,0,4"/>
      <Border Background="#1E1212" CornerRadius="6" BorderThickness="1" BorderBrush="#6B2A2A" Padding="10,7" Margin="0,0,0,10">
        <TextBox Name="TxtUser" Background="Transparent" Foreground="#FFF2F2" BorderThickness="0" FontSize="12" CaretBrush="#FF5252"/>
      </Border>
      <TextBlock Text="Email" Foreground="#C47070" FontSize="11" Margin="0,0,0,4"/>
      <Border Background="#1E1212" CornerRadius="6" BorderThickness="1" BorderBrush="#6B2A2A" Padding="10,7" Margin="0,0,0,10">
        <TextBox Name="TxtEmail" Background="Transparent" Foreground="#FFF2F2" BorderThickness="0" FontSize="12" CaretBrush="#FF5252"/>
      </Border>
      <TextBlock Text="Account Level" Foreground="#C47070" FontSize="11" Margin="0,0,0,4"/>
      <ComboBox Name="CmbLevel" Margin="0,0,0,14">
        <ComboBoxItem Content="Player"        Tag="0"/>
        <ComboBoxItem Content="Moderator"     Tag="1"/>
        <ComboBoxItem Content="Game Master"   Tag="2"/>
        <ComboBoxItem Content="Administrator" Tag="3"/>
      </ComboBox>
      <TextBlock Name="ErrMsg" Foreground="#EF4444" FontSize="11" Margin="0,0,0,10" Visibility="Collapsed" TextWrapping="Wrap"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,4,0,0">
        <Button Name="BtnCancel" Content="Cancel" Style="{StaticResource DBtn}" Background="#6B2A2A" Foreground="#FFF2F2" Margin="0,0,10,0"/>
        <Button Name="BtnSave"   Content="Save"   Style="{StaticResource DBtn}" Background="#C41E3A" Foreground="#120808"/>
      </StackPanel>
    </StackPanel>
'@
    $txtUser  = $d.FindName("TxtUser")
    $txtEmail = $d.FindName("TxtEmail")
    $cmb      = $d.FindName("CmbLevel")
    $errMsg   = $d.FindName("ErrMsg")

    $txtUser.Text  = $acc.Username
    $txtEmail.Text = $acc.Email
    for ($i = 0; $i -lt $cmb.Items.Count; $i++) {
        if ([int]$cmb.Items[$i].Tag -eq $acc.GmLevel) { $cmb.SelectedIndex = $i; break }
    }

    $d.FindName("BtnCancel").Add_Click({ $d.DialogResult = $false })
    $d.FindName("BtnSave").Add_Click({
        $newUser  = $txtUser.Text.Trim().ToUpper()
        $newEmail = $txtEmail.Text.Trim().ToUpper()
        $newLvl   = [int]($cmb.SelectedItem.Tag)

        if ($newUser -notmatch '^[A-Za-z0-9_]{3,16}$')        { $errMsg.Text = "Username: 3-16 chars, letters/numbers/underscore."; $errMsg.Visibility = "Visible"; return }
        if ($newEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $errMsg.Text = "Enter a valid email address.";                     $errMsg.Visibility = "Visible"; return }

        if ($newUser -ne $acc.Username) {
            $uEsc   = $newUser.Replace("'","''")
            $exists = Invoke-AuthQuery "SELECT COUNT(*) FROM acore_auth.account WHERE username='$uEsc' AND id<>$($acc.Id);"
            if ($exists -and [int]($exists.Trim()) -gt 0) { $errMsg.Text = "Username already exists."; $errMsg.Visibility = "Visible"; return }
        }

        $uEsc = $newUser.Replace("'","''")
        $eEsc = $newEmail.Replace("'","''")
        Invoke-AuthQuery "UPDATE acore_auth.account SET username='$uEsc', email='$eEsc', reg_mail='$eEsc' WHERE id=$($acc.Id);" | Out-Null
        Invoke-AuthQuery "DELETE FROM acore_auth.account_access WHERE id=$($acc.Id);" | Out-Null
        if ($newLvl -gt 0) {
            Invoke-AuthQuery "INSERT INTO acore_auth.account_access (id,gmlevel,RealmID) VALUES ($($acc.Id),$newLvl,-1);" | Out-Null
        }
        $d.DialogResult = $true
    })
    return ($d.ShowDialog() -eq $true)
}

$BtnAccCreate.Add_Click({
    if (-not (Test-Proc "mysqld")) { Show-Alert "Start the database first."; return }
    if (Show-CreateAccount) { Refresh-Accounts; $AccMsg.Text = "Account created successfully." }
})

$BtnAccPassword.Add_Click({
    $acc = $AccountsList.SelectedItem
    if (-not $acc) { Show-Alert "Select an account first."; return }
    if (Show-ChangePassword $acc) { $AccMsg.Text = "Password updated for '$($acc.Username)'." }
})

$BtnAccEdit.Add_Click({
    $acc = $AccountsList.SelectedItem
    if (-not $acc) { Show-Alert "Select an account first."; return }
    if (Show-EditAccount $acc) { Refresh-Accounts; $AccMsg.Text = "Account '$($acc.Username)' updated." }
})

$BtnAccDelete.Add_Click({
    $acc = $AccountsList.SelectedItem
    if (-not $acc) { Show-Alert "Select an account first."; return }
    if (-not (Show-Confirm "Delete account '$($acc.Username)'?`nAll characters and their data will also be permanently deleted.")) { return }

    # Get character GUIDs for this account
    $charRows  = Invoke-AuthQuery "SELECT guid FROM acore_characters.characters WHERE account=$($acc.Id);"
    $charGuids = @($charRows | Where-Object { $_ -match '^\d+$' } | ForEach-Object { $_.Trim() })

    if ($charGuids.Count -gt 0) {
        $cg = $charGuids -join ','

        # Item sub-tables (must be deleted before item_instance)
        Invoke-AuthQuery "
            DELETE FROM acore_characters.item_loot_storage     WHERE containerGUID IN (SELECT guid FROM acore_characters.item_instance WHERE owner_guid IN ($cg));
            DELETE FROM acore_characters.item_refund_instance  WHERE item_guid IN (SELECT guid FROM acore_characters.item_instance WHERE owner_guid IN ($cg));
            DELETE FROM acore_characters.item_soulbound_trade_data WHERE itemGuid IN (SELECT guid FROM acore_characters.item_instance WHERE owner_guid IN ($cg));
            DELETE FROM acore_characters.mail_items            WHERE item_guid IN (SELECT guid FROM acore_characters.item_instance WHERE owner_guid IN ($cg));
        " | Out-Null

        # Item instances and mail
        Invoke-AuthQuery "
            DELETE FROM acore_characters.item_instance WHERE owner_guid IN ($cg);
            DELETE FROM acore_characters.mail WHERE receiver IN ($cg);
            DELETE FROM acore_characters.mail_server_character WHERE guid IN ($cg);
        " | Out-Null

        # Pet sub-tables (must be deleted before character_pet)
        Invoke-AuthQuery "
            DELETE FROM acore_characters.pet_aura           WHERE guid IN (SELECT id FROM acore_characters.character_pet WHERE owner IN ($cg));
            DELETE FROM acore_characters.pet_spell          WHERE guid IN (SELECT id FROM acore_characters.character_pet WHERE owner IN ($cg));
            DELETE FROM acore_characters.pet_spell_cooldown WHERE guid IN (SELECT id FROM acore_characters.character_pet WHERE owner IN ($cg));
            DELETE FROM acore_characters.character_pet_declinedname WHERE owner IN ($cg);
            DELETE FROM acore_characters.character_pet WHERE owner IN ($cg);
        " | Out-Null

        # GM tickets and surveys
        Invoke-AuthQuery "
            DELETE FROM acore_characters.gm_subsurvey WHERE surveyId IN (SELECT id FROM acore_characters.gm_survey WHERE guid IN ($cg));
            DELETE FROM acore_characters.gm_survey  WHERE guid IN ($cg);
            DELETE FROM acore_characters.gm_ticket  WHERE playerGuid IN ($cg);
        " | Out-Null

        # Social, groups, guilds, arena, PvP, quests, logs, calendar, corpse
        Invoke-AuthQuery "
            DELETE FROM acore_characters.guild_member_withdraw WHERE guid IN ($cg);
            DELETE FROM acore_characters.guild_member WHERE guid IN ($cg);
            DELETE FROM acore_characters.arena_team_member WHERE guid IN ($cg);
            DELETE FROM acore_characters.group_member WHERE guid IN ($cg);
            DELETE FROM acore_characters.petition_sign WHERE playerguid IN ($cg) OR ownerguid IN ($cg);
            DELETE FROM acore_characters.petition WHERE ownerguid IN ($cg);
            DELETE FROM acore_characters.auctionhouse WHERE itemowner IN ($cg);
            DELETE FROM acore_characters.pvpstats_players WHERE character_guid IN ($cg);
            DELETE FROM acore_characters.quest_tracker WHERE character_guid IN ($cg);
            DELETE FROM acore_characters.log_arena_memberstats WHERE guid IN ($cg);
            DELETE FROM acore_characters.log_money WHERE sender_guid IN ($cg);
            DELETE FROM acore_characters.calendar_invites WHERE invitee IN ($cg) OR sender IN ($cg);
            DELETE FROM acore_characters.calendar_events WHERE creator IN ($cg);
            DELETE FROM acore_characters.corpse WHERE guid IN ($cg);
            DELETE FROM acore_characters.lfg_data WHERE guid IN ($cg);
            DELETE FROM acore_characters.battleground_deserters WHERE guid IN ($cg);
            DELETE FROM acore_characters.lag_reports WHERE guid IN ($cg);
            DELETE FROM acore_characters.recovery_item WHERE Guid IN ($cg);
        " | Out-Null

        # All character_* guid-based tables
        Invoke-AuthQuery "
            DELETE FROM acore_characters.character_account_data WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_achievement WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_achievement_offline_updates WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_achievement_progress WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_action WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_arena_stats WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_aura WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_banned WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_battleground_random WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_brew_of_the_month WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_declinedname WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_entry_point WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_equipmentsets WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_gifts WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_glyphs WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_homebind WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_instance WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_inventory WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_queststatus WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_queststatus_daily WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_queststatus_monthly WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_queststatus_rewarded WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_queststatus_seasonal WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_queststatus_weekly WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_reputation WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_settings WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_skills WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_social WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_spell WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_spell_cooldown WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_stats WHERE guid IN ($cg);
            DELETE FROM acore_characters.character_talent WHERE guid IN ($cg);
        " | Out-Null

        # Main characters table
        Invoke-AuthQuery "DELETE FROM acore_characters.characters WHERE account=$($acc.Id);" | Out-Null
    }

    # Account-level data in characters DB
    Invoke-AuthQuery "
        DELETE FROM acore_characters.account_data WHERE accountId=$($acc.Id);
        DELETE FROM acore_characters.account_instance_times WHERE accountId=$($acc.Id);
        DELETE FROM acore_characters.account_tutorial WHERE accountId=$($acc.Id);
    " | Out-Null

    # Auth account-level data
    Invoke-AuthQuery "
        DELETE FROM acore_auth.account_access WHERE id=$($acc.Id);
        DELETE FROM acore_auth.account_banned WHERE id=$($acc.Id);
        DELETE FROM acore_auth.account_muted WHERE guid=$($acc.Id);
        DELETE FROM acore_auth.realmcharacters WHERE acctid=$($acc.Id);
        DELETE FROM acore_auth.logs_ip_actions WHERE account_id=$($acc.Id);
        DELETE FROM acore_auth.account WHERE id=$($acc.Id);
    " | Out-Null

    Refresh-Accounts
    $AccMsg.Text = "Account '$($acc.Username)' and all associated data deleted."
})

$BtnApplyRealm.Add_Click({
    $name = $RealmInput.Text.Trim()
    if (-not $name) { $RealmMsg.Foreground = $RED; $RealmMsg.Text = "Please enter a realm name."; return }
    Set-RealmName $name
    $RealmMsg.Foreground = $BLUE
    $RealmMsg.Text = "Realm updated: $name"
    $DashSubtitle.Text = $name
})

# ── Saves Manager ─────────────────────────────────────────────────────────────

function Refresh-Saves {
    $SavesList.Items.Clear()
    Get-SaveSlots | ForEach-Object { $SavesList.Items.Add($_) }
}

$Script:dlgBtnXaml = @'
    <Style x:Key="DBtn" TargetType="Button">
      <Setter Property="Height" Value="32"/>
      <Setter Property="MinWidth" Value="90"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="14,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#FFF2F2"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border Name="Bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2A1515"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#6B2A2A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#FFF2F2"/>
      <Setter Property="Background" Value="#1E1212"/>
      <Setter Property="BorderBrush" Value="#6B2A2A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border Name="Border"
                      Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"
                      CornerRadius="6"/>
              <DockPanel Margin="10,0,0,0" IsHitTestVisible="False">
                <Path DockPanel.Dock="Right" Width="28" VerticalAlignment="Center"
                      HorizontalAlignment="Center"
                      Data="M 0,0 L 8,0 L 4,5 Z" Fill="#C47070" Stretch="None"/>
                <ContentPresenter Content="{TemplateBinding SelectionBoxItem}"
                                  ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                  VerticalAlignment="Center"/>
              </DockPanel>
              <ToggleButton Background="Transparent" BorderThickness="0" Focusable="False"
                            ClickMode="Press" Cursor="Hand"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Fade"
                     MinWidth="{TemplateBinding ActualWidth}">
                <Border Background="#1E1212" BorderBrush="#6B2A2A" BorderThickness="1"
                        CornerRadius="6" Margin="0,2,0,0">
                  <ScrollViewer MaxHeight="200" VerticalScrollBarVisibility="Auto"
                                HorizontalScrollBarVisibility="Disabled">
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Border" Property="BorderBrush" Value="#9E5555"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@

function New-Dialog([string]$innerXaml) {
    $xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
        Background="Transparent" Width="380" SizeToContent="Height"
        WindowStartupLocation="CenterOwner">
  <Window.Resources>
'@ + $Script:dlgBtnXaml + @'
  </Window.Resources>
  <Border Background="#0C1610" BorderThickness="1" BorderBrush="#6B2A2A" CornerRadius="10" Padding="24,22">
'@ + $innerXaml + @'
  </Border>
</Window>
'@
    $xaml = [xml](Apply-Theme $xamlStr)
    $d = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $d.Owner = $win
    return $d
}

function Show-Confirm([string]$msg) {
    $d = New-Dialog @'
    <StackPanel>
      <TextBlock Name="Msg" Foreground="#FFF2F2" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,22"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button Name="BtnNo"  Content="No"  Style="{StaticResource DBtn}" Background="#6B2A2A" Foreground="#FFF2F2" Margin="0,0,10,0"/>
        <Button Name="BtnYes" Content="Yes" Style="{StaticResource DBtn}" Background="#C41E3A" Foreground="#120808"/>
      </StackPanel>
    </StackPanel>
'@
    $d.FindName("Msg").Text = $msg
    $d.FindName("BtnNo").Add_Click({  $d.DialogResult = $false })
    $d.FindName("BtnYes").Add_Click({ $d.DialogResult = $true  })
    return ($d.ShowDialog() -eq $true)
}

function Show-Alert([string]$msg) {
    $d = New-Dialog @'
    <StackPanel>
      <TextBlock Name="Msg" Foreground="#FFF2F2" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,22"/>
      <Button Name="BtnOk" Content="OK" Style="{StaticResource DBtn}" Background="#C41E3A" Foreground="#120808" HorizontalAlignment="Right"/>
    </StackPanel>
'@
    $d.FindName("Msg").Text = $msg
    $d.FindName("BtnOk").Add_Click({ $d.DialogResult = $true })
    $d.ShowDialog() | Out-Null
}

function Show-InputWpf([string]$prompt, [string]$default) {
    $d = New-Dialog @'
    <StackPanel>
      <TextBlock Name="Prompt" Foreground="#FFF2F2" FontSize="13" Margin="0,0,0,10"/>
      <Border Background="#1E1212" CornerRadius="6" BorderThickness="1" BorderBrush="#6B2A2A" Padding="10,7" Margin="0,0,0,20">
        <TextBox Name="TxtInput" Background="Transparent" Foreground="#FFF2F2" BorderThickness="0"
                 FontSize="13" CaretBrush="#FF5252" SelectionBrush="#C41E3A"/>
      </Border>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button Name="BtnCancel" Content="Cancel" Style="{StaticResource DBtn}" Background="#6B2A2A" Foreground="#FFF2F2" Margin="0,0,10,0"/>
        <Button Name="BtnOk"     Content="OK"     Style="{StaticResource DBtn}" Background="#C41E3A" Foreground="#120808"/>
      </StackPanel>
    </StackPanel>
'@
    $d.FindName("Prompt").Text   = $prompt
    $txt = $d.FindName("TxtInput")
    $txt.Text = $default
    $txt.SelectAll()
    $d.FindName("BtnCancel").Add_Click({ $d.DialogResult = $false })
    $d.FindName("BtnOk").Add_Click({     if ($txt.Text.Trim()) { $d.DialogResult = $true } })
    $txt.Add_KeyDown({ param($s,$e); if ($e.Key -eq "Return" -and $txt.Text.Trim()) { $d.DialogResult = $true } })
    if ($d.ShowDialog() -eq $true) { return $txt.Text.Trim() }
    return $null
}

$BtnSave.Add_Click({
    $sel = $SavesList.SelectedItem
    if (-not $sel) { $SaveMsg.Text = "Select a slot first."; return }
    if ($sel.HasData) {
        if (-not (Show-Confirm "Overwrite save in slot $($sel.Slot)?")) { return }
    }
    $def   = if ($sel.HasData -and $sel.Name -ne "-") { $sel.Name } else { "Save$($sel.Slot)" }
    $sname = Show-InputWpf "Name for this save:" $def
    if (-not $sname) { return }
    $sname = $sname -replace '\s+','_'
    $SaveMsg.Text = "Saving slot $($sel.Slot)..."
    $win.IsEnabled = $false
    $win.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $ok2 = Invoke-ExportSave $sel.Slot $sname
    $win.IsEnabled = $true
    $SaveMsg.Text = if ($ok2) { "Slot $($sel.Slot) saved as '$sname'." } else { "Error: mysqldump.exe not found." }
    Refresh-Saves
})

$BtnLoad.Add_Click({
    $sel = $SavesList.SelectedItem
    if (-not $sel)         { $SaveMsg.Text = "Select a slot first."; return }
    if (-not $sel.HasData) { $SaveMsg.Text = "Slot $($sel.Slot) is empty."; return }
    if (-not (Show-Confirm "Load save '$($sel.Name)' (slot $($sel.Slot))?`n`nThis will OVERWRITE your current databases.`nStop all servers first.")) { return }
    $SaveMsg.Text = "Loading slot $($sel.Slot)..."
    $win.IsEnabled = $false
    $win.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $ok2 = Invoke-ImportSave $sel.Slot
    $win.IsEnabled = $true
    $SaveMsg.Text = if ($ok2) { "Slot $($sel.Slot) '$($sel.Name)' loaded." } else { "Load error." }
})

$BtnDelete.Add_Click({
    $sel = $SavesList.SelectedItem
    if (-not $sel)         { $SaveMsg.Text = "Select a slot first."; return }
    if (-not $sel.HasData) { $SaveMsg.Text = "Slot $($sel.Slot) is already empty."; return }
    if (-not (Show-Confirm "Delete save '$($sel.Name)' (slot $($sel.Slot))?")) { return }
    $d = "$mainfolder\Saves\$($sel.Slot)"
    Remove-Item "$d\auth.sql","$d\characters.sql","$d\name.txt" -Force -ErrorAction SilentlyContinue
    $SaveMsg.Text = "Slot $($sel.Slot) deleted."
    Refresh-Saves
})

$BtnSaveFolder.Add_Click({
    $d = "$mainfolder\Saves"; New-Item $d -ItemType Directory -Force | Out-Null; Start-Process explorer $d
})

# ── Maintenance ───────────────────────────────────────────────────────────────

$BtnVCRedist.Add_Click({
    $bat = "$mainfolder\Tools\Redist\Install_VC_AiO.bat"
    if (Test-Path $bat) { Start-Process cmd "/c `"$bat`"" -WindowStyle Hidden -Wait }
    else { Show-Alert "Not found:`n$bat" }
})

$BtnShortcut.Add_Click({
    $bat = "$mainfolder\Launcher.bat"
    $desktop = [Environment]::GetFolderPath("Desktop")
    $scNameFile = "$scriptsDir\AppName.txt"
    $scName = if (Test-Path $scNameFile) { (Get-Content $scNameFile -Raw).Trim() } else { "SPP Launcher" }
    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut("$desktop\$scName.lnk")
    $sc.TargetPath       = $bat
    $sc.WorkingDirectory = $mainfolder
    $ico = "$iconsDir\Launcher.ico"; if (Test-Path $ico) { $sc.IconLocation = $ico }
    $sc.Save()
    Show-Alert "Desktop shortcut created."
})

$BtnCheckUpdates.Add_Click({
    Start-Process $Script:updatesURL
})

# ── Status timer ──────────────────────────────────────────────────────────────

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(4)
$timer.Add_Tick({ Refresh-Status })
$timer.Start()

# ── Startup ───────────────────────────────────────────────────────────────────

$win.Add_Loaded({
    try {
        $Script:wpfHwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        if (Test-Path $iconPath) {
            try {
                $Script:icoSmall = [System.Drawing.Icon]::new($iconPath, 16, 16)
                $Script:icoBig   = [System.Drawing.Icon]::new($iconPath, 32, 32)
                [SPP.WinAPI]::SendMessage($Script:wpfHwnd, [uint32]0x0080, [IntPtr]0, $Script:icoSmall.Handle) | Out-Null
                [SPP.WinAPI]::SendMessage($Script:wpfHwnd, [uint32]0x0080, [IntPtr]1, $Script:icoBig.Handle)   | Out-Null
            } catch {}
        }
        $namePath    = "$scriptsDir\Name.txt"
        $verPath     = "$scriptsDir\Version.txt"
        $appNamePath = "$scriptsDir\AppName.txt"
        $TxtAppName.Text    = if (Test-Path $namePath)    { (Get-Content $namePath    -Raw).Trim() } else { "SPP Legion" }
        $TxtAppVersion.Text = if (Test-Path $verPath)     { (Get-Content $verPath     -Raw).Trim() } else { "v2.0" }
        $win.Title          = if (Test-Path $appNamePath) { (Get-Content $appNamePath -Raw).Trim() } else { "SPP Launcher" }
        $TxtMySQLHost.Text = $Script:mysqlCfg.Host
        $TxtMySQLPort.Text = $Script:mysqlCfg.Port
        $TxtMySQLUser.Text = $Script:mysqlCfg.User
        $TxtMySQLPass.Text = $Script:mysqlCfg.Password
        Refresh-Status
        $n = Get-RealmName
        $RealmInput.Text   = $n
        $DashSubtitle.Text = $n
        Refresh-Saves
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Loaded event error:`n`n$_`n`n$($_.ScriptStackTrace)", "Launcher Error")
        $win.Close()
    }
})

# ── Console repositioning via LayoutUpdated ───────────────────────────────────
$win.Add_LayoutUpdated({
    try {
        if ($PageMain.Visibility -ne "Visible") { return }
        Reposition-Console $ConsoleAuth  $Script:hwndAuth
        Reposition-Console $ConsoleWorld $Script:hwndWorld
    } catch {}
})

# ── Embed timer (fast poll after server start) ────────────────────────────────
# Polls every 300 ms until all running consoles are embedded, then stops itself.
$Script:embedTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:embedTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$Script:embedTimer.Add_Tick({
    Sync-Consoles
    # Stop polling only when every running server has a window and is embedded
    $allDone = $true
    foreach ($pName in @("authserver","worldserver")) {
        $p = Get-Process -Name $pName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p) {
            if ($p.MainWindowHandle -eq [IntPtr]::Zero) {
                $allDone = $false   # process running but window not ready yet — keep polling
            } elseif ([SPP.WinAPI]::GetParent($p.MainWindowHandle) -ne $Script:wpfHwnd) {
                $allDone = $false   # window exists but not embedded yet
            }
        }
    }
    if ($allDone) { $Script:embedTimer.Stop() }
})

function Start-EmbedTimer { $Script:embedTimer.Stop(); $Script:embedTimer.Start() }

# ── Console color maintenance timer ──────────────────────────────────────────
# Reapplies the console color every second so it survives server initialization
# resetting the attribute (worldserver takes several minutes to load).
$Script:colorTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:colorTimer.Interval = [TimeSpan]::FromSeconds(1)
$Script:colorTimer.Add_Tick({
    $cc = $Script:theme.ConsoleColor
    foreach ($pName in @("authserver","worldserver")) {
        $p = Get-Process -Name $pName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
            [SPP.ConsoleColors]::Apply([uint32]$p.Id, $cc) | Out-Null
        }
    }
})
$Script:colorTimer.Start()

$Script:isClosing = $false

$win.Add_Closing({
    param($s, $e)
    if ($Script:isClosing) { return }  # graceful shutdown finished — allow close

    $anyRunning = (Test-Proc "mysqld") -or (Test-Proc "authserver") -or (Test-Proc "worldserver") -or (Test-Proc "httpd")
    if ($anyRunning) {
        if (-not (Show-Confirm "There are servers still running.`nClose the launcher and shut them all down?")) {
            $e.Cancel = $true
            return
        }
        $e.Cancel = $true
        $Script:isClosing = $true
        Show-Overlay "Shutting down all servers..."
        Stop-WorldServer {
            Stop-AuthServer; Stop-WebServer; Stop-DBServer
            Hide-Overlay
            $timer.Stop(); $Script:embedTimer.Stop()
            if ($Script:shutdownTimer) { $Script:shutdownTimer.Stop() }
            foreach ($hwnd in @($Script:hwndAuth, $Script:hwndWorld)) {
                if ($hwnd -ne [IntPtr]::Zero) {
                    [SPP.WinAPI]::SetParent($hwnd, [IntPtr]::Zero) | Out-Null
                    [SPP.WinAPI]::ShowWindow($hwnd, 0) | Out-Null
                }
            }
            $win.Dispatcher.BeginInvoke([Action]{ $win.Close() }, [System.Windows.Threading.DispatcherPriority]::Background)
        }
        return
    }
    $timer.Stop(); $Script:embedTimer.Stop()
    if ($Script:shutdownTimer) { $Script:shutdownTimer.Stop() }
    foreach ($hwnd in @($Script:hwndAuth, $Script:hwndWorld)) {
        if ($hwnd -ne [IntPtr]::Zero) {
            [SPP.WinAPI]::SetParent($hwnd, [IntPtr]::Zero) | Out-Null
            [SPP.WinAPI]::ShowWindow($hwnd, 0) | Out-Null
        }
    }
})

$win.ShowDialog() | Out-Null
