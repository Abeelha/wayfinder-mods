# WFQoL Watchdog Launcher
# ------------------------------------------------------------------------------------------------
# Launches Wayfinder via Steam (keeps Steam overlay + SteamID + achievements), then babysits it.
# You cannot stop a shaky UE4 game from crashing (recent crashes are the BASE GAME - 0 mod frames).
# So this makes crashes NOT MATTER: detect crash OR freeze -> relaunch -> always-online game drops
# you back at the hub in ~30-60s. Crash goes from "session over" to a brief blip.
#
# Detection (three independent signals, no false-fires on normal loads):
#   1. CRASH  = game process gone AND a NEW crash artifact appeared since launch
#               (UE4CC crash dir in Saved/Crashes, or a UE4SS crash_*.dmp) -> relaunch.
#   2. FREEZE (whole process) = heartbeat.txt file mtime stale > FreezeSecs while proc alive.
#   3. HANG (game thread only) = heartbeat `behind` value climbs past BehindLimit (async thread
#               keeps writing but the game thread stopped answering). -> kill + relaunch.
#   Clean exit (proc gone, NO new crash artifact) = you quit on purpose -> watchdog stops.
#
# The heartbeat is written every ~1s by the WFQoL mod (Mods/WFQoL/heartbeat.txt).
# To stop babysitting: just quit the game normally. To force-stop: close this PowerShell window.
# ------------------------------------------------------------------------------------------------

# ---- config (edit paths here if the install ever moves) ----
$AppId        = 1171690
$GameProcName = 'Wayfinder'                 # process name, no .exe
$Win64        = 'D:\SteamLibrary\steamapps\common\Wayfinder\Atlas\Binaries\Win64'
$Heartbeat    = Join-Path $Win64 'Mods\WFQoL\heartbeat.txt'
$CrashesDir   = Join-Path $env:LOCALAPPDATA 'Wayfinder\Saved\Crashes'
$LogFile      = Join-Path $PSScriptRoot 'watchdog.log'

$FreezeSecs      = 25     # heartbeat file untouched this long (proc alive) = whole-process freeze
$BehindLimit     = 18     # heartbeat `behind=N` (~N seconds game thread unresponsive) = hang
$BootTimeoutSecs = 180    # max wait for the process to appear after a launch
$HeartbeatGrace  = 90     # after proc appears, wait up to this long for heartbeat to start (load/login)
$PollSecs        = 3
$MaxRelaunch     = 30     # session safety cap
$CrashLoopSecs   = 45     # if it dies < this long after launching, count it as a crash-loop
$CrashLoopMax    = 4      # this many rapid crash-loops in a row -> stop (something is fundamentally broken)

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    $line | Tee-Object -FilePath $LogFile -Append | Out-Null
}

function Get-GameProc { Get-Process -Name $GameProcName -ErrorAction SilentlyContinue | Select-Object -First 1 }

function Kill-CrashUI {
    # UE crash reporter is a separate process; the UE4SS "Fatal Error!" MessageBox belongs to the
    # game process and dies with it. Kill the reporter + any lingering game proc so relaunch is clean.
    Get-Process -Name 'CrashReportClient','UnrealCEFSubProcess','CrashReportClientEditor' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name $GameProcName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Latest-CrashStamp {
    # newest crash-artifact time (UE4CC dir OR UE4SS crash_*.dmp), or [datetime]::MinValue
    $t = [datetime]::MinValue
    $d = Get-ChildItem $CrashesDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($d -and $d.LastWriteTime -gt $t) { $t = $d.LastWriteTime }
    $m = Get-ChildItem (Join-Path $Win64 'crash_*.dmp') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($m -and $m.LastWriteTime -gt $t) { $t = $m.LastWriteTime }
    return $t
}

function Read-Behind {
    # parse `behind=N` from heartbeat; -1 if unreadable
    try {
        $c = Get-Content $Heartbeat -Raw -ErrorAction Stop
        if ($c -match 'behind=(\d+)') { return [int]$matches[1] }
    } catch {}
    return -1
}

function Launch-Game {
    Log "launching Wayfinder via steam://rungameid/$AppId"
    Start-Process "steam://rungameid/$AppId"
}

# ---- main loop ----
Log "=== watchdog started ==="
$relaunches = 0
$crashLoop  = 0

while ($true) {
    $launchAt = Get-Date
    $crashBaseline = Latest-CrashStamp
    if (-not (Get-GameProc)) { Launch-Game }

    # wait for the process to appear
    $waited = 0
    while (-not (Get-GameProc) -and $waited -lt $BootTimeoutSecs) { Start-Sleep 2; $waited += 2 }
    $proc = Get-GameProc
    if (-not $proc) { Log "process never appeared in ${BootTimeoutSecs}s - giving up"; break }
    Log "game process up (pid $($proc.Id)); waiting for heartbeat..."

    # wait for the heartbeat to start updating (covers EOS login / shader compile / first load)
    $hbArmed = $false; $waited = 0
    while ($waited -lt $HeartbeatGrace) {
        if ((Get-GameProc) -eq $null) { break }
        $hb = Get-Item $Heartbeat -ErrorAction SilentlyContinue
        if ($hb -and ((Get-Date) - $hb.LastWriteTime).TotalSeconds -lt 10) { $hbArmed = $true; break }
        Start-Sleep 3; $waited += 3
    }
    if ($hbArmed) { Log "heartbeat live - monitoring (freeze>${FreezeSecs}s, behind>${BehindLimit})" }
    else { Log "heartbeat not seen in ${HeartbeatGrace}s (mod off? still loading) - monitoring process only" }

    # monitor until the process dies or hangs
    $reason = $null
    while ($true) {
        Start-Sleep $PollSecs
        $proc = Get-GameProc
        if (-not $proc) { $reason = 'gone'; break }
        if ($hbArmed) {
            $hb = Get-Item $Heartbeat -ErrorAction SilentlyContinue
            $age = if ($hb) { ((Get-Date) - $hb.LastWriteTime).TotalSeconds } else { 999 }
            if ($age -gt $FreezeSecs)      { $reason = 'freeze'; break }
            $behind = Read-Behind
            if ($behind -ge $BehindLimit)  { $reason = 'hang';   break }
        }
    }

    $alive = ((Get-Date) - $launchAt).TotalSeconds

    if ($reason -eq 'gone') {
        # crash vs intentional quit: did a NEW crash artifact appear?
        Start-Sleep 2  # let the crash reporter finish writing
        $crashed = (Latest-CrashStamp) -gt $crashBaseline
        if (-not $crashed) { Log "game exited cleanly after $([int]$alive)s - you quit; watchdog stopping."; break }
        Log "CRASH detected (new dump) after $([int]$alive)s"
        Kill-CrashUI
    }
    elseif ($reason -eq 'freeze') { Log "FREEZE (whole process, heartbeat stale) after $([int]$alive)s - killing"; Kill-CrashUI }
    elseif ($reason -eq 'hang')   { Log "HANG (game thread, behind climbed) after $([int]$alive)s - killing"; Kill-CrashUI }

    # crash-loop guard: dying repeatedly within seconds = unplayable, stop hammering
    if ($alive -lt $CrashLoopSecs) { $crashLoop++ } else { $crashLoop = 0 }
    if ($crashLoop -ge $CrashLoopMax) { Log "crash-loop ($crashLoop rapid failures) - stopping. fix the root cause / verify vanilla."; break }

    $relaunches++
    if ($relaunches -ge $MaxRelaunch) { Log "hit relaunch cap ($MaxRelaunch) - stopping."; break }

    Log "relaunch #$relaunches in 6s..."
    Start-Sleep 6
}
Log "=== watchdog exited ==="
