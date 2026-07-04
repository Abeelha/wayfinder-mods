# WFQoL external overlay - reads the state file written by the WFQoL UE4SS mod.
# Drag to move. Resize with the bottom-right grip (content scales). Lock button
# makes it click-through; Ctrl+Alt+O unlocks. Position/size/lock persisted.
# Diagnostics: %APPDATA%\wfqol-overlay.log (use start-overlay-debug.bat for console)
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

# single instance: the game mod auto-launches us on every boot
$mutex = New-Object System.Threading.Mutex($false, "WFQoL-Overlay-SingleInstance")
if (-not $mutex.WaitOne(0)) {
    OLog "another instance already running - exiting"
    exit 0
}

OLog "overlay starting (PS $($PSVersionTable.PSVersion))"
OLog "state file: $StateFile (exists: $(Test-Path $StateFile))"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
'@

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WFQoL Overlay" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="True"
        Width="280" Height="230" MinWidth="180" MinHeight="150"
        ResizeMode="CanResizeWithGrip">
  <Border CornerRadius="14" Background="#DD0E1116" BorderBrush="#2FFFFFFF" BorderThickness="1" Padding="6">
    <Viewbox Stretch="Uniform">
      <StackPanel Width="260" Margin="8">
        <DockPanel Margin="0,0,0,8">
          <Ellipse x:Name="CombatDot" Width="10" Height="10" Fill="#71F58A" VerticalAlignment="Center"/>
          <TextBlock Text="  WFQoL" FontFamily="Consolas" FontSize="16" FontWeight="Bold" Foreground="#7CFFD4" VerticalAlignment="Center"/>
          <TextBlock x:Name="OfflineText" Text="  offline" FontFamily="Consolas" FontSize="11" Foreground="#8A8A93" VerticalAlignment="Center" Visibility="Collapsed"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" DockPanel.Dock="Right">
            <Button x:Name="LockBtn" Content="LOCK" FontFamily="Consolas" FontSize="10" Padding="6,2"
                    Background="#22FFFFFF" Foreground="#C8C8CF" BorderThickness="0" Cursor="Hand" Margin="0,0,6,0"/>
            <Button x:Name="CloseBtn" Content="X" FontFamily="Consolas" FontSize="10" Padding="6,2"
                    Background="#22FFFFFF" Foreground="#C8C8CF" BorderThickness="0" Cursor="Hand"/>
          </StackPanel>
        </DockPanel>
        <StackPanel x:Name="Rows"/>
        <TextBlock x:Name="ParryText" Text="" FontFamily="Consolas" FontSize="10" Foreground="#6E6E78" Margin="2,8,0,0" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="HintText" Text="Ctrl+Alt+O unlock" FontFamily="Consolas" FontSize="9" Foreground="#44FFFFFF" Margin="2,2,0,0"/>
      </StackPanel>
    </Viewbox>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$rows = $window.FindName("Rows")
$combatDot = $window.FindName("CombatDot")
$offlineText = $window.FindName("OfflineText")
$parryText = $window.FindName("ParryText")
$lockBtn = $window.FindName("LockBtn")
$closeBtn = $window.FindName("CloseBtn")

$features = @(
    @{ Name = "SPRINT"; Key = "F6"; Prop = "sprint" },
    @{ Name = "CHAIN";  Key = "F7"; Prop = "chain" },
    @{ Name = "PARRY";  Key = "F8"; Prop = "parry" },
    @{ Name = "RELOAD"; Key = "F9"; Prop = "reload" }
)
$pills = @{}
$modeChip = $null

foreach ($f in $features) {
    $row = New-Object Windows.Controls.DockPanel
    $row.Margin = "2,3,2,3"

    $name = New-Object Windows.Controls.TextBlock
    $name.Text = $f.Name; $name.FontFamily = "Consolas"; $name.FontSize = 13
    $name.Foreground = "#D8D8DE"; $name.Width = 88; $name.VerticalAlignment = "Center"
    [void]$row.Children.Add($name)

    $key = New-Object Windows.Controls.Border
    $key.Background = "#1C2733"; $key.CornerRadius = 4; $key.Padding = "5,1,5,1"; $key.VerticalAlignment = "Center"
    $keyText = New-Object Windows.Controls.TextBlock
    $keyText.Text = $f.Key; $keyText.FontFamily = "Consolas"; $keyText.FontSize = 10; $keyText.Foreground = "#6FB7FF"
    $key.Child = $keyText
    [void]$row.Children.Add($key)

    if ($f.Prop -eq "sprint") {
        $chip = New-Object Windows.Controls.Border
        $chip.Background = "#332A16"; $chip.CornerRadius = 4; $chip.Padding = "5,1,5,1"
        $chip.Margin = "6,0,0,0"; $chip.VerticalAlignment = "Center"
        $chipText = New-Object Windows.Controls.TextBlock
        $chipText.Text = ""; $chipText.FontFamily = "Consolas"; $chipText.FontSize = 10; $chipText.Foreground = "#F5C871"
        $chip.Child = $chipText
        $script:modeChip = $chipText
        [void]$row.Children.Add($chip)
    }

    $pill = New-Object Windows.Controls.Border
    $pill.CornerRadius = 8; $pill.Padding = "10,2,10,2"; $pill.HorizontalAlignment = "Right"
    $pillText = New-Object Windows.Controls.TextBlock
    $pillText.FontFamily = "Consolas"; $pillText.FontSize = 12; $pillText.FontWeight = "Bold"
    $pill.Child = $pillText
    [Windows.Controls.DockPanel]::SetDock($pill, "Right")
    [void]$row.Children.Add($pill)

    $pills[$f.Prop] = @{ Border = $pill; Text = $pillText }
    [void]$rows.Children.Add($row)
}

function Set-Pill($prop, $on) {
    $p = $pills[$prop]
    if ($on) {
        $p.Border.Background = "#16351F"; $p.Text.Foreground = "#71F58A"; $p.Text.Text = "ON"
    } else {
        $p.Border.Background = "#2A2A31"; $p.Text.Foreground = "#8A8A93"; $p.Text.Text = "OFF"
    }
}

# ------------------------------------------------------------------ settings
$cfgPath = Join-Path $env:APPDATA "wfqol-overlay.json"
$script:locked = $false
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($cfg.left -ne $null) { $window.Left = $cfg.left; $window.Top = $cfg.top }
        if ($cfg.width) { $window.Width = $cfg.width; $window.Height = $cfg.height }
        if ($cfg.locked) { $script:locked = $true }
    } catch { OLog "config load failed: $_" }
} else {
    $window.Left = 40; $window.Top = 200
}

# rescue off-screen positions (monitor changes etc)
$vsLeft = [Windows.SystemParameters]::VirtualScreenLeft
$vsTop = [Windows.SystemParameters]::VirtualScreenTop
$vsRight = $vsLeft + [Windows.SystemParameters]::VirtualScreenWidth
$vsBottom = $vsTop + [Windows.SystemParameters]::VirtualScreenHeight
if ($window.Left -lt ($vsLeft - 30) -or $window.Left -gt ($vsRight - 60) -or
    $window.Top -lt ($vsTop - 30) -or $window.Top -gt ($vsBottom - 60)) {
    OLog "position off-screen ($($window.Left),$($window.Top)) - reset to 40,200"
    $window.Left = 40; $window.Top = 200
}
OLog "window at $($window.Left),$($window.Top) size $($window.Width)x$($window.Height) locked=$($script:locked)"

function Save-Config {
    @{ left = $window.Left; top = $window.Top; width = $window.Width; height = $window.Height; locked = $script:locked } |
        ConvertTo-Json | Set-Content $cfgPath -Encoding utf8
}

# ------------------------------------------------------------------ lock / unlock
$WS_EX_TRANSPARENT = 0x20
$GWL_EXSTYLE = -20

function Apply-Lock {
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
    $style = [Win32.Native]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    if ($script:locked) {
        [void][Win32.Native]::SetWindowLong($hwnd, $GWL_EXSTYLE, $style -bor $WS_EX_TRANSPARENT)
        $window.ResizeMode = "NoResize"
        $lockBtn.Content = "LOCKED"
    } else {
        [void][Win32.Native]::SetWindowLong($hwnd, $GWL_EXSTYLE, $style -band (-bnot $WS_EX_TRANSPARENT))
        $window.ResizeMode = "CanResizeWithGrip"
        $lockBtn.Content = "LOCK"
    }
    Save-Config
}

$lockBtn.Add_Click({ $script:locked = $true; Apply-Lock })
$closeBtn.Add_Click({ $window.Close() })
$window.Add_MouseLeftButtonDown({ if (-not $script:locked) { try { $window.DragMove(); Save-Config } catch {} } })

$window.Add_SourceInitialized({
    try {
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
        [void][Win32.Native]::RegisterHotKey($hwnd, 9001, 0x3, 0x4F) # Ctrl+Alt+O
        $src = [Windows.Interop.HwndSource]::FromHwnd($hwnd)
        $src.AddHook({
            param($h, $msg, $w, $l, [ref]$handled)
            if ($msg -eq 0x0312 -and $w.ToInt32() -eq 9001) {
                $script:locked = -not $script:locked
                Apply-Lock
                $handled.Value = $true
            }
            return [IntPtr]::Zero
        })
        Apply-Lock
        OLog "hotkey + lock initialized"
    } catch { OLog "SourceInitialized error: $_" }
})
$window.Add_Loaded({ try { $window.Activate() } catch {} })

# ------------------------------------------------------------------ state poll
$script:pollCount = 0
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    $stale = $true
    if (Test-Path $StateFile) {
        try {
            $s = Get-Content $StateFile -Raw | ConvertFrom-Json
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$s.ts
            $stale = $age -gt 5
            if (-not $stale) {
                Set-Pill "sprint" $s.sprint
                Set-Pill "chain" $s.chain
                Set-Pill "parry" $s.parry
                Set-Pill "reload" $s.reload
                if ($script:modeChip) { $script:modeChip.Text = "$($s.sprintMode)" }
                $combatDot.Fill = if ($s.combat) { "#FF5A5A" } else { "#71F58A" }
                $parryText.Text = if ($s.lastParry) { "last parry: $($s.lastParry)" } else { "" }
            }
            $script:pollCount++
            if ($script:pollCount -eq 1) { OLog "first state read OK (age ${age}s, stale=$stale)" }
        } catch { $stale = $true; OLog "state read error: $_" }
    }
    $offlineText.Visibility = if ($stale) { "Visible" } else { "Collapsed" }
    $window.Opacity = if ($stale) { 0.55 } else { 1.0 }
})
$timer.Start()

$window.Add_Closed({ Save-Config; OLog "closed" })
OLog "showing window"
[void]$window.ShowDialog()

} catch {
    OLog "FATAL: $_"
    OLog $_.ScriptStackTrace
    exit 1
}
