# WFQoL Watchdog Launcher

**You can't stop a shaky UE4 game from crashing** — the recent crashes are the *base game* (crash
stacks show 0 mod frames, e.g. `EXCEPTION_ACCESS_VIOLATION reading 0x228` = the game's own null
deref). Wayfinder crashes vanilla too. So instead of chasing an unwinnable "never crash", this makes
crashes **not matter**: it auto-detects a crash or freeze and relaunches you back to the hub in
~30-60s (the game is always-online, so you resume where you were).

This is the launcher idea done where it actually works — not DLL re-injection (UE4SS is *already*
in-process DLL injection, and any mod that touches game objects has the same crash surface in any
language), but **crash resilience** around the game.

## Use
1. Run `install-shortcut.ps1` once → puts **"Wayfinder (WFQoL)"** on your Desktop (game's icon).
2. Double-click it → the watchdog starts (hidden), launches Wayfinder **via Steam** (overlay +
   SteamID + achievements all intact), and babysits.
3. Play. On crash/freeze it relaunches automatically.
4. To stop babysitting: **quit the game normally** (clean exit = watchdog stops). To force-stop:
   end the hidden `powershell` in Task Manager.

## How it decides (no false-fires on normal loading)
| Signal | Meaning | Action |
|---|---|---|
| process gone **+ new crash dump** since launch | crash | relaunch |
| process gone, **no** crash dump | you quit on purpose | stop |
| `heartbeat.txt` file mtime stale > 25s (proc alive) | whole-process freeze | kill + relaunch |
| `heartbeat.txt` `behind=N` climbs ≥ 18 | game-thread hang | kill + relaunch |

The heartbeat is written every ~1s by the WFQoL mod (`Mods/WFQoL/heartbeat.txt`). During normal
level loads the async thread keeps writing it, so loads don't false-trigger.

## Safety
- **Crash-loop guard**: 4 failures within 45s of launching each = stop (something is fundamentally
  broken; don't hammer Steam). Fix the root cause or verify vanilla first.
- **Relaunch cap**: 30 per session.
- Everything is logged to `watchdog.log` next to the script.

## Files
- `wf-watchdog.ps1` — the watchdog (edit config paths at the top if the install moves).
- `launch-wayfinder.vbs` — runs the watchdog hidden (what the shortcut calls).
- `install-shortcut.ps1` — creates the Desktop shortcut.
