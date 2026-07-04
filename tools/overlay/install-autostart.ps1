# DEPRECATED: the overlay is no longer a login-autostart app. The WFQoL game
# mod launches it on game start (main.lua launchOverlay), and it self-exits
# when the game closes/crashes. This script now just REMOVES the old Startup
# shortcut if a previous install left one (it spawned the overlay on PC boot).
$startup = [Environment]::GetFolderPath("Startup")
$lnkPath = Join-Path $startup "WFQoL-Overlay.lnk"
if (Test-Path $lnkPath) {
    Remove-Item $lnkPath -Force
    Write-Output "removed old autostart shortcut: $lnkPath"
} else {
    Write-Output "no autostart shortcut present (nothing to remove)"
}
Write-Output "overlay now launches with the game and closes with it - no login autostart"
