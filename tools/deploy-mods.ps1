# Deploy mods from my-mods/ to the live Wayfinder Mods folder.
# Usage: .\tools\deploy-mods.ps1            -> deploy all mods in my-mods/
#        .\tools\deploy-mods.ps1 AutoChain  -> deploy one mod
param([string]$Mod = "")

$repo = Split-Path -Parent $PSScriptRoot
$gameMods = "D:\SteamLibrary\steamapps\common\Wayfinder\Atlas\Binaries\Win64\Mods"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $repo "backups\$stamp"

if (-not (Test-Path $gameMods)) { Write-Error "Game Mods folder not found: $gameMods"; exit 1 }

$sources = if ($Mod) { @(Join-Path $repo "my-mods\$Mod\$Mod") } else {
    Get-ChildItem (Join-Path $repo "my-mods") -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName $_.Name }
}

foreach ($src in $sources) {
    if (-not (Test-Path $src)) { Write-Warning "skip, not found: $src"; continue }
    $name = Split-Path $src -Leaf
    $dst = Join-Path $gameMods $name

    if (Test-Path $dst) {
        New-Item -ItemType Directory -Force $backupRoot | Out-Null
        Copy-Item $dst (Join-Path $backupRoot $name) -Recurse
    }
    Copy-Item $src $gameMods -Recurse -Force
    Write-Output "deployed $name"

    $modsTxt = Join-Path $gameMods "mods.txt"
    if ((Get-Content $modsTxt -Raw) -notmatch "(?m)^\s*$name\s*:") {
        Write-Warning "$name missing from mods.txt (enabled.txt in mod folder still autostarts it)"
    }
}
