# AI Memory - wayfinder-mods

Per-repo memory. Append-only, concise. Format: `### YYYY-MM-DD - Category - entry`.

---

### 2026-07-04 - TechStack - Wayfinder UE4SS setup facts
- Game dir: `D:/SteamLibrary/steamapps/common/Wayfinder`, exe dir `Atlas/Binaries/Win64` (project name = Atlas)
- EAC is dead post-Echoes: `EasyAntiCheat/Settings.json` points at `Atlas/Binaries/Win64/WayfinderClient.exe` which does not exist. Nexus UE4SS mods run fine.
- UE4SS v3.0.1 (flat layout: dwmapi.dll + UE4SS.dll + Mods/ at exe dir). Wayfinder REQUIRES custom `UE4SS_Signatures/GUObjectArray.lua` AOB sig (shipped by ShowNameplates + SmartSort, identical) AND `bUseUObjectArrayCache = false` in UE4SS-settings.ini.
- Native class prefix `/Script/Wayfinder.` (e.g. `PlayerInventoryComponent:CLIENT_NotifyItemAdded`). Player pawn BP: `/Game/Blueprints/Main/WFPlayerCharacter_Base.WFPlayerCharacter_Base_C`.
- Game uses GAS. Player abilities: `Atlas/Content/Blueprints/Player/GAS/GameplayAbilities/` - weapon families 2H / 2HR / DW / SnS / RangedWeapon. Combo GAs `GA_Player_2H_LightAttack1..4`, parry `GA_Player_2H_Parry{,_Light,_Heavy}`, block `GA_Player_Block{,_2H}`. `GA_Player_Melee_Base` holds `Attack1PressCombo`, `HasComboFollowUps`, `InputTask`, CallFuncs `HandlePlayerInputPress/Hold/ReleaseWithAbility`.
- Char BP input UFunctions: `InpActEvt_Attack1_K2Node_InputActionEvent_36/_37` (M1), `InpActEvt_Attack2_K2Node_InputActionEvent_40/_41` (M2). Pressed vs released edge = TBD at runtime (recon phase).
- Full FModel JSON dump in repo `Atlas/` (gitignored), from Nexus mod 2 ("serialised file").
