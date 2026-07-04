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

### 2026-07-04 - Milestone - Runtime recon done (WFRecon session 1), verified APIs
- Input edges CONFIRMED: `InpActEvt_Attack1_..._36` = PRESS, `_37` = RELEASE. Attack2: `_40` = press, `_41` = release. M1 hold produces NO extra events (game has no native auto-chain).
- ALL enemy generic attacks flow through `GA_AI_Base_C:K2_ActivateAbility` (base hook catches Skirmisher/Brawler/Rifleman/etc subclasses). Enemy attack GAs tagged `Ability.Characteristic.Attack` + `.Melee` (verified GA_AI_Atk_Melee defaults).
- Weapon defense model differs per family: SnS = `GA_Player_Block_SNS` (hold), 2H = `GA_Player_Block_2H` + `GA_Player_2H_Parry*`, DW = `GA_Player_DW_Parry` (active parry w/ InvulnEffect + `DW_Parry_Pushback` counter). DW M2 = HeavyAttack_Flourish, NOT block - Block is its own input (`EWFGameplayAbilityInput::Block`, tag `Input.Combat.Block`).
- Player ASC = `WFPlayerAbilitySystemComponent` living on PLAYERSTATE as `UnrealAbilityComponent`, NOT on pawn. Clean access: static lib `/Script/Wayfinder.Default__WFAbilitySystemBlueprintLibrary` -> `GetWFPlayerAbilitySystemComponent(actor)`.
- Key callable natives (UHT dump `Win64/UHTHeaderDump/Wayfinder/Public/`): `WFPlayerAbilitySystemComponent:GetAbilityFromInputTag(FGameplayTag)` (weapon-agnostic block/parry lookup), `AbilitySystemComponent:TryActivateAbilityByClass(class, bool)`, `WFAbilitySystemComponent:AddGameplayTag/RemoveGameplayTag`, `WFAbilitySystemBlueprintLibrary:AUTH_TryGiveAndActivateAbilityOnce(...)`.
- Combo system: melee GA waits on `WFPlayerInputAsyncQuery*`/`WFAbilityTask_HandlePlayerInput*` tasks listening for INPUT TAGS; next ability class per attack in `Attack1PressCombo`/`Attack2PressCombo` properties.
- Sprint: `GA_Player_Sprint_C:K2_ActivateAbility` hook works. `WFPlayerCharacter:IsPlayerSprinting()` pure native. Combat tag `Character.State.Generic.InCombat`.
- GAME CRASHED (EXCEPTION_ACCESS_VIOLATION, UE4SS frames) ~200s into session. Prime suspect: WFRecon's LoopAsync combat probe touching UObjects OFF game thread (probe also never logged = failing silently in pcall). RULE: every LoopAsync body that touches UE objects goes inside ExecuteInGameThread. WFRecon removed from game + repo (git history baf5ab0).
- Session log archived: scratchpad/UE4SS-session1.log. Object dump: Win64/UE4SS_ObjectDump.txt (from GUI Console tab "Dump Objects & Properties" button; Dumpers tab "Generate UHT Compatible Headers" for the SDK).

### 2026-07-04 - Milestone - AutoChain + AutoParry + AutoSprint v1 deployed
- AutoChain (F7): hooks Attack1 press/release edges for held state; LoopAsync 70ms alternates synthetic press/release calls of the char's own `InpActEvt_Attack1_*` UFunctions; `injecting` guard flag prevents self-hook feedback loop.
- AutoParry (F8): hooks `GA_AI_Base_C:K2_ActivateAbility`; filters melee attacks by AbilityTags; range gate 700u; activates `GetAbilityFromInputTag(Input.Combat.Block):GetClass()` via `TryActivateAbilityByClass` = weapon-agnostic (DW parry / SnS block / 2H parry). 0.6s cooldown.
- AutoSprint (F6): LoopAsync 300ms in game thread; gates: not InCombat tag, not IsPlayerSprinting, speed > 100u/s; activates GA_Player_Sprint_C.
- All need in-game test (user). Open Qs: does synthetic InpActEvt call drive combo? does DW parry fire counter (Pushback) on parried hit? does InCombat tag actually flip?

### 2026-07-04 - Milestone - v2: timed AutoParry + fixed AutoSprint (test 1 feedback)
- Test 1 results: AutoChain WORKS (hold M1 chains). AutoParry triggered but at windup START (parry window expired before hit). AutoSprint dead.
- AutoSprint root cause: `pawn:HasMatchingGameplayTag()` is PURE_VIRTUAL C++ interface stub - calling it via UE4SS UFunction dispatch silently fails. Same reason WFRecon combat probe never logged. FIX: static `WFAbilitySystemBlueprintLibrary:AbilitySystemHasTagExactly(ASC, tag)` - works for any tag check. Also `UEHelpers.GetPlayerController` calls global `Print` (nil in mod env) when no PC exists (menu) - avoid UEHelpers in loops, cache pawn via ClientRestart hook + FindAllOf fallback.
- AutoParry v2 timing solution: DATA-DRIVEN. `tools/extract-attack-timings.py` walks dump enemy GA jsons -> Montage -> AnimSequence -> first `AnimNotifyState_WeaponTrace` (or MeleeTrace) notify LinkValue = damage window start (montage segment mapping: StartPos + (t - AnimStartTime)/rate). 295 attack timings extracted (median 1.0s, e.g. Skirmisher Sweeping_Slash 0.476s, Brawler Punch_01 1.262s). Emits `AutoParry/Scripts/timings.lua`; mod schedules parry at hitTime - LEAD (0.25s) via ExecuteWithDelay, re-validates at fire (range/cooldown/enabled).
- Mount facts: player pawn STAYS the pawn while mounted (`WFCharacter.m_pMountComponent`, `IsMounted()`); sprint is the same GA_Player_Sprint (mount speed via GE_Mount_SprintSpeed passed to PlayerToggleMount). Rider velocity ~0 while mounted -> read `GetAttachParentActor():GetVelocity()`.
- Sprint status tag: `Character.State.Generic.Sprinting` (granted by GE_Status_Sprint; blocked by Character.State.Disable.Sprint / Exhausted / InAir).
- Re-run timing extractor after game updates (dump refresh) to regenerate timings.lua.

### 2026-07-04 - Gotcha - boot crash: no FindAllOf/ExecuteInGameThread before player spawn
- v2 AutoSprint crashed game AT LAUNCH (AV right after "Event loop start"): its LoopAsync ran FindAllOf("WFPlayerCharacter_Base_C") + ExecuteInGameThread at the MAIN MENU while the BP class was not loaded yet.
- RULE for this game: mods with periodic loops gate ALL engine access behind a `ready` flag set by the `PlayerController:ClientRestart` hook (plus boot-time `StaticFindObject(class):IsValid()` check to survive "Restart All Mods" mid-map - that pattern is safe, ShowNameplates uses it). Commit 9ab5d15.
