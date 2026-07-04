# ShowNameplates (patched)

Third-party UE4SS mod that forces the player's own nameplate visible and mirrors
the HUD health/shield/stamina meters onto it. NOT one of ours - patched by WFQoL
to fix self health/stamina reading wrong.

## What was broken
- `main()` re-ran on EVERY `ClientRestart` -> hooks stacked each transition and
  stale closures wrote values from an old pawn's HUD. Also spammed UE4SS
  "Was unable to register a hook" on every level load.
- Only the damage-trail bar (`PlayerLastHealthBar`) got health; the primary
  health fill was never driven, so self life read wrong.

## Patch
- Hooks install exactly once (`hooksInstalled` guard); `ClientRestart` only
  refreshes the player + widget refs (`onRestart`).
- Drives the primary health fill (candidates `PlayerHealthBar` /
  `characterHealthFill`) in addition to the trail bar.
- One-shot `diagBars()` logs which nameplate bar properties actually exist, so
  the value mapping can be trimmed to the confirmed names.
- All native access pcall-guarded so a transition can't crash it.

## Deploy
Not covered by `tools/deploy-mods.ps1` (that only syncs `my-mods/`). Copy manually:
`cp tools/third-party-patches/ShowNameplates/main.lua "D:/SteamLibrary/steamapps/common/Wayfinder/Atlas/Binaries/Win64/Mods/ShowNameplates/scripts/main.lua"`
Original backed up in the game folder as `main.lua.wfqol-bak-*`.
