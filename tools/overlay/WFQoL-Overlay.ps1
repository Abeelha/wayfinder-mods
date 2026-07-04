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
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        Width="280" Height="368" MinWidth="180" MinHeight="150"
        ResizeMode="CanResizeWithGrip">
  <Border CornerRadius="14" Background="#DD0E1116" BorderBrush="#2FFFFFFF" BorderThickness="1" Padding="6">
    <Viewbox Stretch="Uniform">
      <StackPanel Width="260" Margin="8">
        <DockPanel x:Name="Header" Margin="0,0,0,8" Background="#01000000">
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
      </StackPanel>
    </Viewbox>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)

# lock chip: a tiny second window that is NEVER click-through, so lock/unlock is
# always one click away even while the card ignores the mouse
$chipXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="WFQoL Lock" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        Width="64" Height="24" ResizeMode="NoResize" Visibility="Hidden">
  <Border CornerRadius="12" Background="#DD1A2027" BorderBrush="#2FFFFFFF" BorderThickness="1" Cursor="Hand">
    <TextBlock Name="ChipText" Text="UNLOCK" FontFamily="Consolas" FontSize="10" FontWeight="Bold"
               Foreground="#F5C871" HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
</Window>
'@
$lockChip = [Windows.Markup.XamlReader]::Parse($chipXaml)
$lockChipText = $lockChip.FindName("ChipText")

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
    @{ Name = "RELOAD"; Key = "F9"; Prop = "reload" },
    @{ Name = "AIMBOT"; Key = "F10"; Prop = "aim" }
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

# ---- aim config: sliders write aim-config.json, the Lua mod hot-reloads it ----
$AimCfgFile = Join-Path (Split-Path $StateFile) "aim-config.json"
$script:aimCfgDirty = $false
$aimDefaults = @{ fov = 40.0; smooth = 1.0; aimbot = $true; bullets = $false }
try {
    if (Test-Path $AimCfgFile) {
        $c = Get-Content $AimCfgFile -Raw | ConvertFrom-Json
        if ($null -ne $c.fov) { $aimDefaults.fov = [double]$c.fov }
        if ($null -ne $c.smooth) { $aimDefaults.smooth = [double]$c.smooth }
        if ($null -ne $c.aimbot) { $aimDefaults.aimbot = [bool]$c.aimbot }
        if ($null -ne $c.bullets) { $aimDefaults.bullets = [bool]$c.bullets }
    }
} catch { OLog "aim cfg load error: $_" }

$cfgHeader = New-Object Windows.Controls.TextBlock
$cfgHeader.Text = "AIMBOT CONFIG"; $cfgHeader.FontFamily = "Consolas"; $cfgHeader.FontSize = 10
$cfgHeader.Foreground = "#6E6E78"; $cfgHeader.Margin = "2,8,0,2"
[void]$rows.Children.Add($cfgHeader)

function Add-CfgSlider($label, $min, $max, $value, $fmt) {
    $row = New-Object Windows.Controls.DockPanel
    $row.Margin = "2,2,2,2"
    $name = New-Object Windows.Controls.TextBlock
    $name.Text = $label; $name.FontFamily = "Consolas"; $name.FontSize = 11
    $name.Foreground = "#D8D8DE"; $name.Width = 60; $name.VerticalAlignment = "Center"
    [void]$row.Children.Add($name)
    $val = New-Object Windows.Controls.TextBlock
    $val.FontFamily = "Consolas"; $val.FontSize = 11; $val.Foreground = "#6FB7FF"
    $val.Width = 38; $val.TextAlignment = "Right"; $val.VerticalAlignment = "Center"
    $val.Text = ($value.ToString($fmt))
    [Windows.Controls.DockPanel]::SetDock($val, "Right")
    [void]$row.Children.Add($val)
    $slider = New-Object Windows.Controls.Slider
    $slider.Minimum = $min; $slider.Maximum = $max; $slider.Value = $value
    $slider.VerticalAlignment = "Center"; $slider.Margin = "4,0,4,0"
    $slider.IsMoveToPointEnabled = $true
    [void]$row.Children.Add($slider)
    [void]$rows.Children.Add($row)
    return @{ Slider = $slider; Val = $val; Fmt = $fmt }
}

function Add-CfgCheck($label, $checked) {
    $row = New-Object Windows.Controls.DockPanel
    $row.Margin = "2,2,2,2"
    $cb = New-Object Windows.Controls.CheckBox
    $cb.Content = $label
    $cb.FontFamily = "Consolas"; $cb.FontSize = 10
    $cb.Foreground = "#D8D8DE"; $cb.IsChecked = $checked
    $cb.VerticalAlignment = "Center"
    $cb.Add_Checked({ $script:aimCfgDirty = $true })
    $cb.Add_Unchecked({ $script:aimCfgDirty = $true })
    [void]$row.Children.Add($cb)
    [void]$rows.Children.Add($row)
    return $cb
}

$script:fovCtl = Add-CfgSlider "FOV" 2 90 $aimDefaults.fov "0"
$script:smoothCtl = Add-CfgSlider "SNAP" 0.02 1.0 $aimDefaults.smooth "0.00"
$script:fovCtl.Slider.Add_ValueChanged({
    $script:fovCtl.Val.Text = $script:fovCtl.Slider.Value.ToString("0")
    $script:aimCfgDirty = $true
})
$script:smoothCtl.Slider.Add_ValueChanged({
    $script:smoothCtl.Val.Text = $script:smoothCtl.Slider.Value.ToString("0.00")
    $script:aimCfgDirty = $true
})

$script:aimbotCheck = Add-CfgCheck "AIMBOT (snap camera to enemy)" $aimDefaults.aimbot
$script:bulletsCheck = Add-CfgCheck "MAGIC BULLETS (damage inject)" $aimDefaults.bullets

function Save-AimCfg {
    try {
        $obj = @{
            fov = [math]::Round($script:fovCtl.Slider.Value, 0)
            smooth = [math]::Round($script:smoothCtl.Slider.Value, 2)
            aimbot = [bool]$script:aimbotCheck.IsChecked
            bullets = [bool]$script:bulletsCheck.IsChecked
        }
        ($obj | ConvertTo-Json -Compress) | Set-Content -Path $AimCfgFile -Encoding ascii
        OLog "aim cfg saved: fov=$($obj.fov) snap=$($obj.smooth) aimbot=$($obj.aimbot) bullets=$($obj.bullets)"
    } catch { OLog "aim cfg save error: $_" }
}
if (-not (Test-Path $AimCfgFile)) { Save-AimCfg }

# ------------------------------------------------------------------ settings
$cfgPath = Join-Path $env:APPDATA "wfqol-overlay.json"
$script:locked = $true # click-through by default; Ctrl+Alt+O or tray menu unlocks
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($cfg.left -ne $null) { $window.Left = $cfg.left; $window.Top = $cfg.top }
        if ($cfg.width) { $window.Width = $cfg.width; $window.Height = [Math]::Max([double]$cfg.height, 368) }
        if ($cfg.locked -ne $null) { $script:locked = [bool]$cfg.locked }
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

function Move-Chip {
    $lockChip.Left = $window.Left + $window.ActualWidth + 6
    $lockChip.Top = $window.Top
}

function Apply-Lock {
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
    $style = [Win32.Native]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    if ($script:locked) {
        [void][Win32.Native]::SetWindowLong($hwnd, $GWL_EXSTYLE, $style -bor $WS_EX_TRANSPARENT)
        $window.ResizeMode = "NoResize"
        $lockBtn.Content = "LOCKED"
        $lockChipText.Text = "UNLOCK"
        $lockChipText.Foreground = "#F5C871"
    } else {
        [void][Win32.Native]::SetWindowLong($hwnd, $GWL_EXSTYLE, $style -band (-bnot $WS_EX_TRANSPARENT))
        $window.ResizeMode = "CanResizeWithGrip"
        $lockBtn.Content = "LOCK"
        $lockChipText.Text = "LOCK"
        $lockChipText.Foreground = "#71F58A"
    }
    Save-Config
}

$lockBtn.Add_Click({ $script:locked = $true; Apply-Lock })
$closeBtn.Add_Click({ $window.Close() })
$lockChip.Add_MouseLeftButtonDown({ $script:locked = -not $script:locked; Apply-Lock })

# drag by the header row only (when unlocked); resize via bottom-right grip
$header = $window.FindName("Header")
$header.Add_MouseLeftButtonDown({
    if (-not $script:locked) { try { $window.DragMove(); Save-Config; Move-Chip } catch {} }
})

$window.Add_SourceInitialized({
    try { Apply-Lock; OLog "lock initialized" } catch { OLog "SourceInitialized error: $_" }
})
$window.Add_Loaded({ try { $window.Activate(); Move-Chip } catch {} })

# ------------------------------------------------------------------ state poll
$script:pollCount = 0
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    if ($script:aimCfgDirty) { $script:aimCfgDirty = $false; Save-AimCfg }
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
                if ($null -ne $s.aim) { Set-Pill "aim" $s.aim }
                if ($script:modeChip) { $script:modeChip.Text = "$($s.sprintMode)" }
                $combatDot.Fill = if ($s.combat) { "#FF5A5A" } else { "#71F58A" }
                $parryText.Text = if ($s.lastParry) { "last parry: $($s.lastParry)" } else { "" }
            }
            $script:pollCount++
            if ($script:pollCount -eq 1) { OLog "first state read OK (age ${age}s, stale=$stale)" }
        } catch { $stale = $true; OLog "state read error: $_" }
    }
    # resident behavior: card only exists on screen while the game heartbeat is fresh
    if ($stale) {
        if ($window.IsVisible) { $window.Hide(); $lockChip.Hide(); OLog "game heartbeat stale - hiding" }
    } else {
        if (-not $window.IsVisible) { $window.Show(); $lockChip.Show(); OLog "game heartbeat fresh - showing" }
        Move-Chip # cheap follow: keeps the chip glued through drags and resizes
    }
})
$timer.Start()

# ------------------------------------------------------------------ tray icon
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Text = "WFQoL Overlay"
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add("Lock / Unlock").add_Click({ $script:locked = -not $script:locked; Apply-Lock })
[void]$menu.Items.Add("Reset position").add_Click({ $window.Left = 40; $window.Top = 200; Move-Chip; Save-Config })
[void]$menu.Items.Add("Exit overlay").add_Click({ $window.Close() })
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ $script:locked = -not $script:locked; Apply-Lock })

$window.Add_Closed({
    Save-Config
    $tray.Visible = $false
    $tray.Dispose()
    OLog "closed"
    [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

OLog "showing window (locked=$($script:locked)); entering message loop"
$window.Show()
OLog "Show() returned; starting dispatcher"
[Windows.Threading.Dispatcher]::Run()
OLog "dispatcher exited"

} catch {
    OLog "FATAL: $_"
    OLog $_.ScriptStackTrace
    exit 1
}
