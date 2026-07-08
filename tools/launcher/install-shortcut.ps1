# Places (or refreshes) the "Wayfinder (WFQoL)" shortcut on the Desktop.
# Double-clicking it runs the watchdog (hidden), which launches the game via Steam and
# auto-relaunches on crash/freeze. Re-run this any time to recreate the shortcut.
$here    = $PSScriptRoot
$vbs     = Join-Path $here 'launch-wayfinder.vbs'
$gameExe = 'D:\SteamLibrary\steamapps\common\Wayfinder\Atlas\Binaries\Win64\Wayfinder.exe'
$lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Wayfinder (WFQoL).lnk'

$sh  = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut($lnkPath)
$lnk.TargetPath       = 'wscript.exe'
$lnk.Arguments        = '"' + $vbs + '"'
$lnk.WorkingDirectory = $here
if (Test-Path $gameExe) { $lnk.IconLocation = "$gameExe,0" }  # use the game's own icon
$lnk.Description       = 'Launch Wayfinder with WFQoL mods + crash/freeze auto-relaunch watchdog'
$lnk.Save()

Write-Output "shortcut created: $lnkPath"
Write-Output "  target : wscript.exe `"$vbs`""
Write-Output "  icon   : $(if (Test-Path $gameExe) {'Wayfinder.exe'} else {'(default - game exe not found)'})"
