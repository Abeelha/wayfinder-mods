# Registers the WFQoL overlay to start silently at Windows login (resident tray
# app; the card only appears while the game is running) and starts it now.
$startup = [Environment]::GetFolderPath("Startup")
$vbs = Join-Path $PSScriptRoot "launch-overlay.vbs"
$lnkPath = Join-Path $startup "WFQoL-Overlay.lnk"

$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = "wscript.exe"
$lnk.Arguments = """$vbs"""
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.Description = "WFQoL game overlay (auto-shows while Wayfinder runs)"
$lnk.Save()
Write-Output "autostart shortcut created: $lnkPath"

# start it now (single-instance mutex makes this safe)
Start-Process wscript.exe -ArgumentList """$vbs"""
Write-Output "overlay started (tray icon; card appears when the game is running)"
