# WFQoL external overlay - reads overlay-state.json written by the WFQoL mod.
# Flat dark, sharp corners. Click a row to toggle that mod (writes overlay-cmd
# for the mod to apply). Drag the header to move. Resize via the bottom-right
# grip. The little square in the header locks/unlocks move+resize (color coded).
# Launched by the mod on game start; self-exits ~20s after the game closes.
# Diagnostics: %APPDATA%\wfqol-overlay.log
param(
    [string]$StateFile = "D:\SteamLibrary\steamapps\common\Wayfinder\Atlas\Binaries\Win64\Mods\WFQoL\overlay-state.json"
)

$logPath = Join-Path $env:APPDATA "wfqol-overlay.log"
function OLog($msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $msg
    try { Add-Content -Path $logPath -Value $line -Encoding utf8 } catch {}
    Write-Host $line
}
try { Set-Content -Path $logPath -Value "" -Encoding utf8 } catch {}

try {

$mutex = New-Object System.Threading.Mutex($false, "WFQoL-Overlay-SingleInstance")
if (-not $mutex.WaitOne(0)) { OLog "another instance already running - exiting"; exit 0 }

OLog "overlay starting (PS $($PSVersionTable.PSVersion))"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# WS_EX_NOACTIVATE: overlay never steals foreground focus from the game (no more
# mouse-unfocus / window-switch beep). clicks on the rows still register - the
# window just doesn't become the active window. applied at SourceInitialized.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class WinNoActivate {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    public static void Apply(IntPtr h) {
        int ex = GetWindowLong(h, -20);        // GWL_EXSTYLE
        SetWindowLong(h, -20, ex | 0x08000000); // WS_EX_NOACTIVATE
    }
}
"@

$CmdFile = Join-Path (Split-Path $StateFile) "overlay-cmd.json"

# FONT: Cascadia Mono ships on Win11; falls back to Consolas. Swap the family
# string here for a pixel TTF later if wanted.
$FONT = "Cascadia Mono, Consolas, Lucida Console"

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WFQoL" WindowStyle="None" Background="#0F1116" Topmost="True"
        ShowActivated="False" ShowInTaskbar="False" Width="230" Height="360"
        MinWidth="150" MinHeight="120" ResizeMode="CanResize"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Border BorderBrush="#2C313C" BorderThickness="1">
    <Grid>
      <DockPanel LastChildFill="True">
        <Grid x:Name="Header" DockPanel.Dock="Top" Background="#171A21" Height="26">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="7,0,0,0">
            <Rectangle x:Name="CombatDot" Width="8" Height="8" Fill="#5CE08A" VerticalAlignment="Center"/>
            <TextBlock Text=" WFQoL" FontFamily="$FONT" FontSize="13" FontWeight="Bold" Foreground="#E4E9F2" VerticalAlignment="Center"/>
            <TextBlock x:Name="OfflineText" Text=" [offline]" FontFamily="$FONT" FontSize="10" Foreground="#8089A0" VerticalAlignment="Center" Visibility="Collapsed"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,7,0">
            <Border x:Name="LockSquare" Width="14" Height="14" Background="#5CE08A" Margin="0,0,10,0" Cursor="Hand" ToolTip="lock / unlock move + resize"/>
            <TextBlock x:Name="CloseBtn" Text="x" FontFamily="$FONT" FontSize="14" FontWeight="Bold" Foreground="#96A0B4" Cursor="Hand"/>
          </StackPanel>
        </Grid>
        <Border x:Name="TelegraphBar" DockPanel.Dock="Top" Background="#1B1E26" Height="20" Visibility="Collapsed">
          <TextBlock x:Name="TelegraphText" Text="" FontFamily="$FONT" FontSize="11" FontWeight="Bold" Foreground="#FFC24B" VerticalAlignment="Center" Margin="8,0,0,0"/>
        </Border>
        <Grid DockPanel.Dock="Bottom" Background="#171A21" Height="19">
          <TextBlock x:Name="FooterText" Text="" FontFamily="$FONT" FontSize="10" Foreground="#6E778C" VerticalAlignment="Center" Margin="7,0,0,0" TextTrimming="CharacterEllipsis"/>
        </Grid>
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="Rows" Margin="0,3,0,3"/>
        </ScrollViewer>
      </DockPanel>
      <Grid HorizontalAlignment="Right" VerticalAlignment="Bottom" Width="15" Height="15">
        <Polygon Points="15,0 15,15 0,15" Fill="#3B4252"/>
        <Polygon Points="15,5 15,15 5,15" Fill="#586074"/>
        <Thumb x:Name="ResizeGrip" Opacity="0" Background="Transparent" Cursor="SizeNWSE"/>
      </Grid>
    </Grid>
  </Border>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$rows = $window.FindName("Rows")
$combatDot = $window.FindName("CombatDot")
$offlineText = $window.FindName("OfflineText")
$footerText = $window.FindName("FooterText")
$lockSquare = $window.FindName("LockSquare")
$closeBtn = $window.FindName("CloseBtn")
$header = $window.FindName("Header")
$resizeGrip = $window.FindName("ResizeGrip")
$telegraphBar = $window.FindName("TelegraphBar")
$telegraphText = $window.FindName("TelegraphText")

# ---- command channel: row click -> overlay-cmd.json -> mod toggles the mod ----
$script:cmdSeq = 0
function Send-Toggle($feature) {
    $script:cmdSeq = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    try { "{`"seq`":$($script:cmdSeq),`"feature`":`"$feature`"}" | Set-Content -Path $CmdFile -Encoding ascii } catch { OLog "cmd write err: $_" }
}

# ---- rows: one clickable button per mod ----
$features = @(
    @{ Name = "SPRINT"; Key = "F6";  Prop = "sprint" },
    @{ Name = "CHAIN";  Key = "F7";  Prop = "chain" },
    @{ Name = "PARRY";  Key = "F8";  Prop = "parry" },
    @{ Name = "RELOAD"; Key = "F9";  Prop = "reload" },
    @{ Name = "HOMING"; Key = "clk"; Prop = "homing" }
)
$script:rowMap = @{}
foreach ($f in $features) {
    $rb = New-Object Windows.Controls.Border
    $rb.Background = "#00000000"; $rb.Height = 27; $rb.Tag = $f.Prop; $rb.Cursor = "Hand"
    $dp = New-Object Windows.Controls.DockPanel
    $dp.Margin = "8,0,8,0"; $dp.LastChildFill = $false

    $name = New-Object Windows.Controls.TextBlock
    $name.Text = $f.Name; $name.FontFamily = $FONT; $name.FontSize = 13
    $name.Foreground = "#C9D1E0"; $name.VerticalAlignment = "Center"
    [Windows.Controls.DockPanel]::SetDock($name, "Left")
    [void]$dp.Children.Add($name)

    $state = New-Object Windows.Controls.TextBlock
    $state.FontFamily = $FONT; $state.FontSize = 12; $state.FontWeight = "Bold"
    $state.VerticalAlignment = "Center"; $state.Text = "--"
    [Windows.Controls.DockPanel]::SetDock($state, "Right")
    [void]$dp.Children.Add($state)

    $key = New-Object Windows.Controls.TextBlock
    $key.Text = $f.Key; $key.FontFamily = $FONT; $key.FontSize = 9
    $key.Foreground = "#5A6478"; $key.VerticalAlignment = "Center"; $key.Margin = "0,0,10,0"
    [Windows.Controls.DockPanel]::SetDock($key, "Right")
    [void]$dp.Children.Add($key)

    $rb.Child = $dp
    $rb.Add_MouseEnter({ $this.Background = "#20242E" })
    $rb.Add_MouseLeave({ $this.Background = "#00000000" })
    $rb.Add_MouseLeftButtonUp({ Send-Toggle $this.Tag })
    [void]$rows.Children.Add($rb)
    $script:rowMap[$f.Prop] = $state
}

function Set-Row($prop, $on) {
    $t = $script:rowMap[$prop]
    if ($null -eq $t) { return }
    if ($on) { $t.Foreground = "#5CE08A"; $t.Text = "ON" }
    else { $t.Foreground = "#6B7286"; $t.Text = "OFF" }
}

# ------------------------------------------------------------------ settings
$cfgPath = Join-Path $env:APPDATA "wfqol-overlay.json"
$script:locked = $false
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($null -ne $cfg.left) { $window.Left = $cfg.left; $window.Top = $cfg.top }
        if ($cfg.width) { $window.Width = [Math]::Max([double]$cfg.width, 150); $window.Height = [Math]::Max([double]$cfg.height, 120) }
        if ($null -ne $cfg.locked) { $script:locked = [bool]$cfg.locked }
    } catch { OLog "config load failed: $_" }
} else {
    $window.Left = 40; $window.Top = 200
}

# rescue off-screen (virtual AND primary bounds - a 2nd monitor hides it)
$pw = [Windows.SystemParameters]::PrimaryScreenWidth
$ph = [Windows.SystemParameters]::PrimaryScreenHeight
$vsR = [Windows.SystemParameters]::VirtualScreenLeft + [Windows.SystemParameters]::VirtualScreenWidth
$vsB = [Windows.SystemParameters]::VirtualScreenTop + [Windows.SystemParameters]::VirtualScreenHeight
if ($window.Left -lt -30 -or $window.Left -gt ($pw - 60) -or $window.Top -lt -30 -or $window.Top -gt ($ph - 60) -or
    $window.Left -gt ($vsR - 60) -or $window.Top -gt ($vsB - 60)) {
    OLog "off-screen ($($window.Left),$($window.Top)) - reset onto primary"
    $window.Left = [Math]::Max(20, $pw - $window.Width - 40); $window.Top = 200
}
OLog "window at $($window.Left),$($window.Top) size $($window.Width)x$($window.Height) locked=$($script:locked)"

function Save-Config {
    @{ left = $window.Left; top = $window.Top; width = $window.Width; height = $window.Height; locked = $script:locked } |
        ConvertTo-Json | Set-Content $cfgPath -Encoding utf8
}

# ------------------------------------------------------------------ lock square
function Apply-Lock {
    if ($script:locked) { $lockSquare.Background = "#E0655C"; $resizeGrip.Visibility = "Collapsed" }
    else { $lockSquare.Background = "#5CE08A"; $resizeGrip.Visibility = "Visible" }
    Save-Config
}
$lockSquare.Add_MouseLeftButtonDown({ $script:locked = -not $script:locked; Apply-Lock })
$closeBtn.Add_MouseLeftButtonDown({ $window.Close() })

# drag by header (unless locked)
$header.Add_MouseLeftButtonDown({
    if (-not $script:locked) { try { $window.DragMove(); Save-Config } catch {} }
})
# resize via the bottom-right grip
$resizeGrip.Add_DragDelta({
    if ($script:locked) { return }
    $w = $window.Width + $_.HorizontalChange
    $h = $window.Height + $_.VerticalChange
    if ($w -ge $window.MinWidth) { $window.Width = $w }
    if ($h -ge $window.MinHeight) { $window.Height = $h }
})
$resizeGrip.Add_DragCompleted({ Save-Config })

$window.Add_SourceInitialized({
    try { Apply-Lock } catch { OLog "init lock err: $_" }
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        [WinNoActivate]::Apply($h)
    } catch { OLog "no-activate err: $_" }
})

# ------------------------------------------------------------------ state poll
$script:staleSince = $null
$EXIT_AFTER_STALE = 20
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    $stale = $true
    if (Test-Path $StateFile) {
        try {
            $s = Get-Content $StateFile -Raw | ConvertFrom-Json
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$s.ts
            $stale = $age -gt 5
            if (-not $stale) {
                Set-Row "sprint" $s.sprint
                Set-Row "chain" $s.chain
                Set-Row "parry" $s.parry
                Set-Row "reload" $s.reload
                Set-Row "homing" $s.homing
                $combatDot.Fill = if ($s.combat) { "#FF5A5A" } else { "#5CE08A" }
                # incoming parryable-attack telegraph (amber); shows ~2s
                if ($s.incoming -and (([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$s.incomingTs) -lt 2)) {
                    $telegraphText.Foreground = "#FFC24B"; $telegraphText.Text = "PARRY  $($s.incoming)"
                    $telegraphBar.Visibility = "Visible"
                } else {
                    $telegraphBar.Visibility = "Collapsed"
                }
                $mode = "$($s.sprintMode)"
                $footerText.Text = "parries:$($s.statParry) seen:$($s.statSeen) | $mode"
            }
        } catch { $stale = $true }
    }
    if ($stale) {
        if ($null -eq $script:staleSince) { $script:staleSince = [DateTime]::UtcNow }
        $offlineText.Visibility = "Visible"; $combatDot.Fill = "#4A4F5E"
        if (([DateTime]::UtcNow - $script:staleSince).TotalSeconds -ge $EXIT_AFTER_STALE) {
            OLog "game gone ${EXIT_AFTER_STALE}s - exiting"; $window.Close(); return
        }
    } else {
        $script:staleSince = $null; $offlineText.Visibility = "Collapsed"
        # INS toggle: state.overlay=false hides the window (app stays alive polling,
        # so pressing INS again re-shows it). null/true = shown (backward compatible).
        if ($s.overlay -eq $false) {
            if ($window.IsVisible) { $window.Hide() }
        } elseif (-not $window.IsVisible) {
            $window.Show()
        }
    }
    # always-autosave: persist any position/size change (drag, resize, OS snap)
    $geo = "$($window.Left),$($window.Top),$($window.Width),$($window.Height)"
    if ($geo -ne $script:lastGeo) { $script:lastGeo = $geo; Save-Config }
})
$timer.Start()

# ------------------------------------------------------------------ tray icon
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Text = "WFQoL Overlay"; $tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add("Lock / Unlock").add_Click({ $script:locked = -not $script:locked; Apply-Lock })
[void]$menu.Items.Add("Reset position").add_Click({ $window.Left = 40; $window.Top = 200; Save-Config })
[void]$menu.Items.Add("Exit overlay").add_Click({ $window.Close() })
$tray.ContextMenuStrip = $menu

$window.Add_Closed({
    Save-Config; $tray.Visible = $false; $tray.Dispose(); OLog "closed"
    [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

OLog "showing window (locked=$($script:locked))"
$window.Show()
[Windows.Threading.Dispatcher]::Run()

} catch {
    OLog "FATAL: $_"; OLog $_.ScriptStackTrace; exit 1
}
