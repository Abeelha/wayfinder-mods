# wayfinder-mods

UE4SS Lua mods for [Wayfinder](https://store.steampowered.com/app/1171690/Wayfinder/) (post-Echoes, offline).

## Layout

- `my-mods/` - mods built here. Layout per mod: `my-mods/<Mod>/<Mod>/{enabled.txt,Scripts/main.lua}`
- `mods/` - reference mods from Nexus (ShowNameplates, SmartSort) - working API examples
- `tools/deploy-mods.ps1` - copy a mod to the live game Mods folder (timestamped backup first)
- `Atlas/` (gitignored, local only) - full FModel JSON dump of game content ([Nexus mod 2](https://www.nexusmods.com/wayfinder/mods/2)), used for API verification

## Game setup

- Game: `D:\SteamLibrary\steamapps\common\Wayfinder`, exe dir `Atlas\Binaries\Win64`
- UE4SS v3.0.1 + custom `UE4SS_Signatures/GUObjectArray.lua` (required for Wayfinder) + `bUseUObjectArrayCache = false`
- Mods live at `Atlas\Binaries\Win64\Mods\`, enabled via `Mods\mods.txt`

## Mods

**WFQoL** (single mod, all features, on-screen overlay via INS):

| Feature | What | Toggle |
|---------|------|--------|
| AutoChain | hold M1 = auto-chain melee attacks | F7 |
| AutoParry | timed parry just before enemy melee hits land (295 attack timings from montage data) | F8 |
| AutoSprint | sprint while moving out of combat, foot + mount | F6 |
| AutoReload | ranged active-reload minigame always perfect | F9 |
