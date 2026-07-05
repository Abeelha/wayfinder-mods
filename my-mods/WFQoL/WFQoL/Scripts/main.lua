-- WFQoL: Wayfinder quality-of-life bundle with on-screen overlay.
--   F7  AutoChain  - hold M1 to auto-chain light attacks, M2 for heavy attacks
--   F8  AutoParry  - timed parry/block just before enemy melee hits land
--   F6  AutoSprint - sprint while moving out of combat (foot + mount)
--   F9  AutoReload - reload minigame always lands the perfect window
--   INS overlay on/off
--
-- Safety rule (learned the hard way): no FindAllOf/ExecuteInGameThread engine
-- access until the player pawn exists. pcall'd RegisterHook attempts are fine.

local state = {
    chain = true,
    parry = true,
    sprint = true,
    reload = true,
    overlay = true,
}

local function log(fmt, ...) print(string.format("[WFQoL] " .. fmt .. "\n", ...)) end

-- FindAllOf returns the class DEFAULT OBJECT (CDO, "Default__...") alongside real
-- instances. the CDO passes :IsValid() but has no world/components, so native
-- calls that treat it as a live actor (K2_GetActorLocation, GetASC, ...) read
-- garbage or crash (pcall can't catch native AVs). skip it.
local function isReal(obj)
    if not (obj and obj:IsValid()) then return false end
    local ok, nm = pcall(function() return obj:GetFName():ToString() end)
    return not (ok and nm and nm:sub(1, 9) == "Default__")
end

local seenErrors = {}
local function logErrorOnce(tag, err)
    local msg = tag .. ": " .. tostring(err)
    if not seenErrors[msg] then
        seenErrors[msg] = true
        log("error %s", msg)
    end
end

-- ---------------------------------------------------------------- paths / tags
local CHAR = "/Game/Blueprints/Main/WFPlayerCharacter_Base.WFPlayerCharacter_Base_C"
local CHAR_CLASS_ONLY = "WFPlayerCharacter_Base_C"
local AIBASE = "/Game/Blueprints/Abilities/AIGeneric/GA_AI_Base.GA_AI_Base_C"
local RELOAD_GA = "/Game/Blueprints/Player/GAS/GameplayAbilities/RangedWeapon/GA_Player_RangedWeapon_ActiveReload.GA_Player_RangedWeapon_ActiveReload_C"
local RELOAD_OK_GA = "/Game/Blueprints/Player/GAS/GameplayAbilities/RangedWeapon/GA_Player_RangedWeapon_ActiveReloadSucceeded.GA_Player_RangedWeapon_ActiveReloadSucceeded_C"
local SPRINT_CLASS = "/Game/Blueprints/Player/GAS/GameplayAbilities/GA_Player_Sprint.GA_Player_Sprint_C"
local WFLIB = "/Script/Wayfinder.Default__WFAbilitySystemBlueprintLibrary"

local LMB = { KeyName = FName("LeftMouseButton") }
local RMB = { KeyName = FName("RightMouseButton") }  -- Attack2 = heavy melee, bound to RMB (verified Input.ini)
local BLOCK_TAG = { TagName = FName("Input.Combat.Block") }
local INCOMBAT_TAG = { TagName = FName("Character.State.Generic.InCombat") }
local SPRINTING_TAG = { TagName = FName("Character.State.Generic.Sprinting") }

local timings = require("timings") -- enemy GA class -> seconds to first weapon trace

-- ---------------------------------------------------------------- pawn / ready
local ready = false
local pawnRef = nil
-- level transitions (breach load / open-world streaming) tear actors down while
-- our game-thread loops keep running: touching a dying pawn's CharacterMovement
-- or ASC natively = access violation that pcall CANNOT catch (crash reading
-- 0x1c). SETTLE gate: after a pawn swap, skip native loop work briefly so the
-- new/old actors finish (un)constructing.
local SETTLE_SECS = 1.5
local transitionAt = 0.0
local function settling() return (os.clock() - transitionAt) < SETTLE_SECS end
-- open-world streaming / zone travel swaps the pawn WITHOUT firing ClientRestart,
-- so the settle gate above never armed for those loads and our game-thread loops
-- kept driving torn-down actors (suspected perma-load cause). track the pawn
-- address in the sprint loop; any change = a transition we got no ClientRestart
-- for -> arm the settle gate the same way.
local lastPawnAddr = nil

local function getPawn()
    if pawnRef and pawnRef:IsValid() then return pawnRef end
    pawnRef = nil
    pcall(function()
        -- MULTIPLAYER: FindAllOf now returns REMOTE players' characters too (their
        -- components are null client-side -> native crash if we drive one). prefer
        -- the LOCALLY-controlled pawn; fall back to first real (single-player).
        local first = nil
        for _, p in pairs(FindAllOf(CHAR_CLASS_ONLY) or {}) do
            if isReal(p) then
                first = first or p
                local okl, loc = pcall(function() return p:IsLocallyControlled() end)
                if okl and loc then pawnRef = p break end
            end
        end
        if not pawnRef then pawnRef = first end
    end)
    return pawnRef
end

pcall(function()
    if StaticFindObject(CHAR):IsValid() then ready = true end -- mod restarted mid-map
end)

-- cache engine object refs: repeated StaticFindObject lookups in loops cost frames
local libCache = nil
local function getLib()
    if libCache and libCache:IsValid() then return libCache end
    local lib = StaticFindObject(WFLIB)
    libCache = (lib and lib:IsValid()) and lib or nil
    return libCache
end

local sprintClassCache = nil
local function getSprintClass()
    if sprintClassCache and sprintClassCache:IsValid() then return sprintClassCache end
    local c = StaticFindObject(SPRINT_CLASS)
    sprintClassCache = (c and c:IsValid()) and c or nil
    return sprintClassCache
end

local function getASC(pawn)
    local lib = getLib()
    if not lib then return nil end
    local asc = lib:GetWFPlayerAbilitySystemComponent(pawn)
    return asc and asc:IsValid() and asc or nil
end

local function ascHasTag(asc, tag)
    local lib = getLib()
    return lib and lib:AbilitySystemHasTagExactly(asc, tag) or false
end

-- ---------------------------------------------------------------- AutoChain
-- one loop chains BOTH: hold M1 -> auto light attacks (Attack1), hold M2 -> auto heavy
-- attacks (Attack2). same F7 toggle. the game gates the next swing by animation, so a
-- 70ms inject just keeps the combo flowing (light AND heavy combos: HeavyAttack1->2->3).
local m1Held = false
local m2Held = false
local injecting = false
local sendRelease = false
local sendRelease2 = false

-- reload minigame state lives up here: AutoChain must stop injecting M1 while
-- the minigame runs (Attack1 AND Reload both count as minigame inputs - a
-- spammed press outside the window = guaranteed failed reload)
local currentReload = nil -- { t0, maxT }
local function reloadInProgress()
    if not currentReload then return false end
    return (os.clock() - currentReload.t0) < ((currentReload.maxT or 3.0) + 0.5)
end

LoopAsync(70, function()
    if not (state.chain and ready) or settling() then return false end
    if not (m1Held or m2Held) then return false end
    if reloadInProgress() then return false end
    ExecuteInGameThread(function()
        if not pawnRef or not pawnRef:IsValid() then return end
        injecting = true
        pcall(function()
            if m1Held then
                if sendRelease then pawnRef:InpActEvt_Attack1_K2Node_InputActionEvent_37(LMB)
                else pawnRef:InpActEvt_Attack1_K2Node_InputActionEvent_36(LMB) end
                sendRelease = not sendRelease
            end
            if m2Held then
                if sendRelease2 then pawnRef:InpActEvt_Attack2_K2Node_InputActionEvent_41(RMB)
                else pawnRef:InpActEvt_Attack2_K2Node_InputActionEvent_40(RMB) end
                sendRelease2 = not sendRelease2
            end
        end)
        injecting = false
    end)
    return false
end)

-- ---------------------------------------------------------------- AutoParry
local LEAD = 0.25
-- fallback hit-time for attacks with no extracted montage timing. many common
-- enemy attacks CAN'T be statically timed: the generic AI melee (GA_AI_Atk_Melee_
-- *_ALC) resolves its montage at runtime per-enemy via the ALC "Atk_Basic" key, and
-- ranged casts (Farseer Blast/Channel/Meteor) have no weapon-trace notify. so those
-- ride this default. measured across the 250 real melee timings the median is
-- ~0.94s (old 0.60 fired ~0.35s too early); 0.8 sits near the light-melee cluster
-- (0.65-0.85) - late enough for slow swings, still early enough for basics.
local DEFAULT_HIT = 0.8
local PARRY_COOLDOWN = 0.3
local PARRY_RANGE = 800.0        -- schedule-time prefilter
local CONNECT_RANGE = 450.0      -- fire-time: attack must actually reach us
local FACING_DOT = 0.2           -- fire-time: enemy must be aimed at us
local STAMINA_RESERVE = 0.20     -- keep this much stamina for dashing (was 0.35:
                                 -- log showed constant skips at 25-34%, missing
                                 -- parries the mod exists to land; a blocked hit
                                 -- beats a saved dash. still holds a small buffer)
local lastParry = 0.0
local lastScheduled = 0.0
local lastParryInfo = "" -- for the external overlay
local lastStaminaSkipLog = 0.0
local lastConnectLog = 0.0

local function isMeleeAttack(ability)
    local hasAttack, hasMelee = false, false
    local ok = pcall(function()
        local tags = ability.AbilityTags.GameplayTags
        for i = 1, #tags do
            local n = tags[i].TagName:ToString()
            if n == "Ability.Characteristic.Attack" then hasAttack = true end
            if n == "Ability.Characteristic.Melee" then hasMelee = true end
        end
    end)
    return ok and hasAttack and hasMelee
end

local function distTo(a, b)
    local pa = a:K2_GetActorLocation()
    local pb = b:K2_GetActorLocation()
    local dx, dy, dz = pa.X - pb.X, pa.Y - pb.Y, pa.Z - pb.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- static preload (ClientRestart, game thread). weapon PARRY cost/pushback assets
-- are NOT hardcoded here anymore - preloadAbilityGraph() derives + loads them
-- universally from whatever weapon is equipped (see below). this list is only for
-- non-weapon-specific assets that must be loaded early.
local PRELOAD = {
    -- reload success/fail cue notify classes: preloading makes them hookable at spawn
    "/Game/Blueprints/GameplayCueNotifies/Ability/2HR/GCNA_2HR_ActiveReload_Success",
    "/Game/Blueprints/GameplayCueNotifies/Ability/2HR/GCNA_2HR_ActiveReload_Fail",
}
local preloaded = false
local function preloadParryAssets()
    if preloaded then return end
    preloaded = true
    for _, path in ipairs(PRELOAD) do
        pcall(function() LoadAsset(path) end)
    end
    log("parry cost assets preloaded")
end

-- DIAGNOSTIC ONLY (v35): name the equipped block ability once per class so its
-- parry cost GE can be added to the static PRELOAD list (which loads safely on
-- ClientRestart, game thread) precisely. NO runtime LoadAsset here - the v34
-- attempt to LoadAsset live class refs mid-combat/every-reload caused a fatal
-- freed-pointer crash (0xffff...ffff). GetFName()/ToString() is a cheap, safe read.
-- UNIVERSAL parry preload (replaces the hardcoded-per-weapon PRELOAD approach):
-- every weapon's block ability lives at .../GameplayAbilities/<WPN>/GA_Player_*,
-- and its parry cost/cooldown/pushback assets follow fixed name patterns in that
-- same <WPN> folder (+ <WPN>/GameplayEffects/). so we derive the folder from the
-- LIVE block ability and sync-load those siblings on the GAME THREAD, once per
-- weapon (deduped) - covers EVERY weapon type, no per-weapon hardcoding.
-- activating a block ability whose cost GE hasn't loaded makes the game async-load
-- it and finalize the class off-thread = the AssembleReferenceTokenStream crash;
-- pre-loading synchronously here prevents that. non-existent speculative paths are
-- harmless no-ops (LoadAsset is synchronous, can't off-thread-async-load).
local abilityGraphPreloaded = {}
local function preloadAbilityGraph(ability)
    if not ability or not ability:IsValid() then return end
    if settling() then return end -- never sync-LoadAsset in a transition window (retries after settle)
    local ok, key = pcall(function() return ability:GetClass():GetFName():ToString() end)
    if not ok or not key or abilityGraphPreloaded[key] then return end
    abilityGraphPreloaded[key] = true

    local classPath = "?"
    pcall(function() classPath = ability:GetClass():GetFullName() end)

    -- "<ClassType> /Game/.../GA_X.GA_X_C" -> package "/Game/.../GA_X"
    local objPath = classPath:match("%s(/%S+)$")
    local pkg = objPath and objPath:match("^(.-)%.")
    local folder, wpn = nil, nil
    if pkg then folder, wpn = pkg:match("^(.*/GameplayAbilities/([^/]+))/") end
    log("parry: block ability=%s folder=%s", key, tostring(folder))
    if not folder or not wpn then return end -- unrecognized layout: crash+diag will name it

    local seen = {}
    local function tryLoad(p) if p and not seen[p] then seen[p] = true; pcall(function() LoadAsset(p) end) end end
    -- token casing varies (folder "SnS" -> GE token "SNS") and GEs live either in
    -- <WPN>/GameplayEffects/ (2H, DW) OR directly in <WPN>/ (SnS) - try all combos
    for _, t in ipairs({ wpn, wpn:upper() }) do
        for _, base in ipairs({ folder .. "/GameplayEffects/", folder .. "/" }) do
            tryLoad(base .. "GE_Player_" .. t .. "_ConsumeStamina_Parry")
            tryLoad(base .. "GE_Player_" .. t .. "_ConsumeStamina_Parry_Survivalist")
            tryLoad(base .. "GE_" .. t .. "_Parry_Cooldown")
            tryLoad(base .. "GE_" .. t .. "_Parry_DamageReduction")
        end
        tryLoad(folder .. "/GA_Player_" .. t .. "_Parry_Pushback")
        tryLoad(folder .. "/TA_Player_" .. t .. "_Parry_Pushback")
    end
end

-- stamina read via the HUD stamina meter widget (same trick ShowNameplates uses)
local metersCache = nil
local function staminaPct()
    local ok, pct = pcall(function()
        if not metersCache or not metersCache:IsValid() then
            metersCache = nil
            for _, m in pairs(FindAllOf("HUD_PlayerMeters_C") or {}) do
                if isReal(m) and m.PlayerShieldBar and m.PlayerShieldBar:IsValid() then
                    metersCache = m
                    break
                end
            end
        end
        if not metersCache then return nil end
        return metersCache.HUD_PlayerStaminaMeters.PlayerStaminaMeter.Percent
    end)
    if ok then return pct end
    return nil
end

-- fire-time check: is this attack actually going to land on us?
local function willConnect(enemy, pawn)
    local ok, res = pcall(function()
        if not enemy or not enemy:IsValid() then return false end
        local pe = enemy:K2_GetActorLocation()
        local pp = pawn:K2_GetActorLocation()
        local dx, dy, dz = pp.X - pe.X, pp.Y - pe.Y, pp.Z - pe.Z
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if dist > CONNECT_RANGE then return false end
        local fwd = enemy:GetActorForwardVector()
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 1 then
            local dot = (fwd.X * dx + fwd.Y * dy) / len
            if dot < FACING_DOT then return false end
        end
        return true
    end)
    return ok and res
end

-- returns "ok" (activated), "active" (already blocking - success), "noblock" (this weapon
-- has NO block/parry ability - caller must NOT force), or false (has block but rejected
-- this instant - safe to force via montage-stop).
-- REQUIRES a live block ability from the input tag. a weapon with no parry returns nil
-- here, so we skip entirely instead of force-cancelling the player's OWN actions - the old
-- stale-cached-class fallback kept forcing a parry on no-parry weapons (montage-stop mid
-- action) = the "janky, cancels what i'm doing" bug the user hit.
-- find the equipped weapon's block/parry ability by scanning GRANTED abilities on the ASC.
-- tag-INDEPENDENT: survives a parry-key rebind (GetAbilityFromInputTag goes nil then) AND
-- finds nothing on a no-block weapon. fully guarded - if the native struct walk fails it
-- returns nil (parry just stands down, never crashes).
local function findGrantedBlockAbility(asc)
    local found = nil
    pcall(function()
        local items = asc.ActivatableAbilities.Items
        if not items then return end
        for i = 1, #items do
            local ab = items[i].Ability
            if ab and ab:IsValid() then
                local nm = ab:GetClass():GetFName():ToString()
                -- player block (GA_Player_Block_<WPN>) or parry (..._Parry); skip Block_Broken
                if (nm:find("^GA_Player_Block_") and not nm:find("Broken")) or nm:find("_Parry") then
                    found = ab
                    return
                end
            end
        end
    end)
    return found
end

-- current weapon's block ability: input tag first (fast; nil after a key rebind), then the
-- tag-independent granted-abilities scan. nil = weapon genuinely has no parry.
local blockSrcLogged = nil
local function currentBlockAbility(asc)
    local ab = asc:GetAbilityFromInputTag(BLOCK_TAG)
    if ab and ab:IsValid() then blockSrcLogged = "tag"; return ab end
    ab = findGrantedBlockAbility(asc)
    if ab and blockSrcLogged ~= "enum" then
        blockSrcLogged = "enum"
        pcall(function() log("parry: block found via granted-ability scan (%s) - parry key rebound?", ab:GetClass():GetFName():ToString()) end)
    end
    return ab
end

-- returns "ok"/"active"/"noblock"/false. block resolved weapon-accurately + rebind-safe.
-- "noblock" = no parry on this weapon -> doParry bails BEFORE the montage-stop force ladder
-- (= no cancelling the player's own actions on a no-parry weapon).
local function tryActivateParry(asc)
    local blockAbility = currentBlockAbility(asc)
    if not (blockAbility and blockAbility:IsValid()) then return "noblock" end
    preloadAbilityGraph(blockAbility)
    local isActive = false
    pcall(function() isActive = blockAbility:IsActive() end)
    if isActive then return "active" end
    local cls = blockAbility:GetClass()
    if cls and cls:IsValid() and asc:TryActivateAbilityByClass(cls, true) then return "ok" end
    return false
end

-- ---------------------------------------------------------------- targeting + stats
-- session stat counters (shown on the overlay) + the current incoming-attack telegraph
local stat = { parry = 0, parryFail = 0, seen = 0 }
local incoming = { name = "", kind = "", ts = 0 }

-- forcing ladder: plain activation -> cancel current swing montage + retry ->
-- two more delayed rounds -> give up loudly
local function doParry(className, delayMs, enemy, attempt)
    attempt = attempt or 1
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if not state.parry or settling() then return end
            if reloadInProgress() then return end -- parry/montage-stop would kill the minigame
            local now = os.clock()
            if now - lastParry < PARRY_COOLDOWN then return end
            local pawn = getPawn()
            if not pawn then return end

            -- only spend the parry if this attack is actually about to land on us
            if not willConnect(enemy, pawn) then
                if now - lastConnectLog > 5 then
                    lastConnectLog = now
                    log("parry: %s scheduled but not connecting (out of range/not facing)", className)
                end
                return
            end

            -- keep a stamina reserve for dashing
            local sp = staminaPct()
            if sp and sp < STAMINA_RESERVE then
                if now - lastStaminaSkipLog > 5 then
                    lastStaminaSkipLog = now
                    log("parry skipped: stamina %.0f%% below %.0f%% reserve", sp * 100, STAMINA_RESERVE * 100)
                end
                return
            end

            local asc = getASC(pawn)
            if not asc then return end

            local r = tryActivateParry(asc)
            if r == "noblock" then return end -- weapon has no parry: do NOTHING (no force = no action-cancel jank)
            if r == "active" then return end -- already blocking/parrying, nothing to force
            if r == "ok" then
                lastParry = now
                stat.parry = stat.parry + 1
                lastParryInfo = string.format("%s @%dms", className:gsub("^GA_", ""):gsub("_C$", ""), delayMs)
                log("parry vs %s (delay %dms)", className, delayMs)
                return
            end

            -- mid-swing: cancel the player's current montage and force it through
            pcall(function() asc:ServerCurrentMontageStop(0.15) end)
            r = tryActivateParry(asc)
            if r == "active" then return end
            if r == "ok" then
                lastParry = now
                lastParryInfo = string.format("%s @%dms forced", className:gsub("^GA_", ""):gsub("_C$", ""), delayMs)
                log("parry FORCED (cancelled swing) vs %s", className)
                return
            end

            if attempt < 3 then
                ExecuteWithDelay(80, function() doParry(className, delayMs, enemy, attempt + 1) end)
            else
                stat.parryFail = stat.parryFail + 1
                log("parry FAILED vs %s after %d attempts", className, attempt)
            end
        end)
        if not ok then logErrorOnce("parry", err) end
    end)
end

-- verdict memo: tag containers iterated once per ABILITY CLASS ever, not per activation
local meleeCache = {}

local function onEnemyAbility(self)
    if not state.parry or settling() then return end
    local now = os.clock()
    if now - lastScheduled < 0.05 then return end
    local ok, err = pcall(function()
        local ab = self:get()
        -- MULTIPLAYER: this hook fires for replicated/remote enemy abilities too;
        -- a client-side stub can be non-nil but invalid -> GetClass() null-deref
        -- (0x10) through pcall. validate the ability before any native call.
        if not (ab and ab:IsValid()) then return end
        local className = ab:GetClass():GetFName():ToString()
        -- DIAGNOSTIC: log every enemy ability this hook catches (once/class). if a
        -- boss fight logs nothing here, the boss doesn't derive from GA_AI_Base and
        -- we must hook its ability base class too for parry to work vs it.
        if not meleeCache["_seen_" .. className] then
            meleeCache["_seen_" .. className] = true
            stat.seen = stat.seen + 1
            log("parry: enemy GA seen %s", className)
        end
        local verdict = meleeCache[className]
        if verdict == nil then
            verdict = isMeleeAttack(ab)
            meleeCache[className] = verdict
        end
        if not verdict then return end
        local enemy = ab:GetAvatarActorFromActorInfo()
        local pawn = getPawn()
        if not (enemy and enemy:IsValid() and pawn) then return end
        if distTo(enemy, pawn) > PARRY_RANGE then return end
        local hitTime = timings[className]
        if not hitTime then
            -- no extracted timing for this attack: parry uses a rough default.
            -- logged once per class so the timings table can be extended offline.
            if not meleeCache["_notimed_" .. className] then
                meleeCache["_notimed_" .. className] = true
                log("parry: no timing for %s (default %.2fs)", className, DEFAULT_HIT)
            end
            hitTime = DEFAULT_HIT
        end
        local delayMs = math.floor(math.max(hitTime - LEAD, 0) * 1000)
        lastScheduled = now
        incoming = { name = className:gsub("^GA_", ""):gsub("_C$", ""), kind = "parry", ts = os.time() }
        if delayMs < 20 then
            doParry(className, delayMs, enemy)
        else
            ExecuteWithDelay(delayMs, function() doParry(className, delayMs, enemy) end)
        end
    end)
    if not ok then logErrorOnce("parry-schedule", err) end
end

-- ---------------------------------------------------------------- AutoSprint
-- escalating strategies, each verified before moving on:
--   ability: TryActivateAbilityByClass(GA_Player_Sprint) - real sprint
--   tag:     inject Character.State.Generic.Sprinting loose tag
--   speed:   write CharacterMovement.MaxWalkSpeed directly (x1.5)
local MIN_SPEED_SQ = 100 * 100
local sprintMode = "real"  -- foot: game's own WFLocomotionComponent BeginSprint/EndSprint
local preloadTick = 0      -- throttles the per-tick weapon-swap parry preload
local lastCombat = nil     -- raw InCombat tag (drives sprint gate + overlay, updated instantly)
local loggedCombat = nil   -- last LOGGED combat state (debounced - tag flaps rapidly near enemies)
local combatPendingSince = 0.0

local function velSq(actor)
    local ok, s = pcall(function()
        local v = actor:GetVelocity()
        return v.X * v.X + v.Y * v.Y
    end)
    return ok and s or 0
end

local function attachParent(pawn)
    local ok, parent = pcall(function() return pawn:GetAttachParentActor() end)
    if ok and parent and parent:IsValid() then return parent end
    return nil
end

-- CharacterMovement can be null on an actor that's being torn down; validate the
-- sub-object BEFORE reading/writing MaxWalkSpeed (a null-deref here is native =
-- uncatchable). fetch the component, IsValid-check it, then touch the property.
local function maxWalk(actor)
    local ok, v = pcall(function()
        local cm = actor.CharacterMovement
        if not (cm and cm:IsValid()) then return nil end
        return cm.MaxWalkSpeed
    end)
    return ok and v or nil
end

local function setMaxWalk(actor, v)
    pcall(function()
        if not (actor and actor:IsValid()) then return end
        local cm = actor.CharacterMovement
        if cm and cm:IsValid() then cm.MaxWalkSpeed = v end
    end)
end

-- mount speed assist tracked separately: boost lives on the MOUNT actor, never
-- inject the sprint tag on the rider while mounted (anim/dismount jank).
-- baselines keyed by actor ADDRESS: RemoteObject wrappers don't compare with ~=
-- (the v8 clunk: identity misfires re-captured mid-gallop speeds as baselines)
local mountBaselines = {}
local mountBoostRef = nil
local mountBoostAddr = nil

local function addrOf(obj)
    local ok, a = pcall(function() return obj:GetAddress() end)
    return ok and a or nil
end

local function stopMountBoost()
    if mountBoostRef then
        local ref = mountBoostRef
        local base = mountBoostAddr and mountBaselines[mountBoostAddr]
        if base then setMaxWalk(ref, base) end
        mountBoostRef = nil
        mountBoostAddr = nil
    end
end

-- ON-FOOT sprint = the game's OWN sprint (WFLocomotionComponent:BeginSprint/EndSprint):
-- real anim/stamina/speed, no MaxWalkSpeed hacks. the component lives at
-- pawn.LocomotionComponent (verified in the object dump).
local function getLoco(pawn)
    local ok, c = pcall(function() return pawn.LocomotionComponent end)
    if ok and c and c:IsValid() then return c end
    return nil
end
local function isSprinting(loco)
    local ok, v = pcall(function() return loco:IsSprintingLocomotionStateActive() end)
    return ok and v or false
end

-- returns mount actor (or nil). IsMounted() native first, class-name fallback.
local function getMount(pawn)
    local parent = attachParent(pawn)
    local ok, v = pcall(function() return pawn:IsMounted() end)
    if ok and v then return parent or pawn end
    if parent then
        local okc, cn = pcall(function() return parent:GetClass():GetFName():ToString() end)
        if okc and cn and cn:find("Mount") then return parent end
    end
    return nil
end

LoopAsync(300, function()
    if not ready or settling() then return false end
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if settling() then return end
            local pawn = getPawn()
            if not pawn then return end
            -- transition detection (open-world streaming doesn't fire ClientRestart):
            -- a changed pawn address means actors were rebuilt; arm the settle gate
            -- and skip this tick so we don't drive half-constructed movement/ASC
            -- through a loading screen (perma-load guard).
            local pa = addrOf(pawn)
            if pa and pa ~= lastPawnAddr then
                local firstSeen = (lastPawnAddr == nil)
                lastPawnAddr = pa
                if not firstSeen then transitionAt = os.clock(); return end
            end
            local asc = getASC(pawn)
            if not asc then return end

            local inCombat = ascHasTag(asc, INCOMBAT_TAG)
            if inCombat ~= lastCombat then
                lastCombat = inCombat            -- raw: gate + overlay react immediately
                combatPendingSince = os.clock()  -- start the log-debounce window
            end
            -- only LOG a combat state that has settled >=0.75s (the game's InCombat
            -- tag micro-flaps near enemies: 199 flips in one session was pure noise).
            -- a state that flips back inside the window keeps resetting -> never logged.
            if loggedCombat ~= lastCombat and (os.clock() - combatPendingSince) >= 0.75 then
                loggedCombat = lastCombat
                log("combat: %s", tostring(lastCombat))
            end
            -- name the equipped weapon's block ability + cost GE once per class
            -- (deduped). runs every tick so equipping a weapon logs it immediately,
            -- no combat needed - diagnostic to fill the static PRELOAD precisely.
            -- weapon-swap parry preload: throttled to ~every 10th tick (~3s) instead of a
            -- native GetAbilityFromInputTag every 300ms tick (moderate perf trim).
            preloadTick = (preloadTick + 1) % 10
            if state.parry and preloadTick == 0 then
                pcall(function() preloadAbilityGraph(asc:GetAbilityFromInputTag(BLOCK_TAG)) end)
            end

            -- mount resolved BEFORE the moving gate: rider velocity is ~0 while
            -- mounted, so gating on pawn speed first killed the mount branch (v4 bug)
            local mount = getMount(pawn)
            -- some mount systems swap possession: the PAWN becomes the mount
            if not mount then
                local okc, cn = pcall(function() return pawn:GetClass():GetFName():ToString() end)
                if okc and cn and cn:find("Mount") then mount = pawn end
            end

            -- mounted: boost the mount's own movement, nothing touches the rider.
            -- combat gate ignored (you can't fight mounted), hysteresis on the
            -- moving gate (start >100u/s, stop <30u/s), and the boost is
            -- RE-APPLIED every tick because the game periodically rewrites
            -- the mount's MaxWalkSpeed (the v5 start/stop jitter)
            if mount then
                local addr = addrOf(mount)
                if mountBoostAddr and mountBoostAddr ~= addr then stopMountBoost() end

                if not state.sprint then
                    stopMountBoost()
                    return
                end

                -- persistent while mounted, baseline captured ONCE per mount actor
                -- (address-keyed for the whole session). MaxWalkSpeed is a cap -
                -- holding it high while standing is harmless, no velocity gating.
                local base = addr and mountBaselines[addr]
                if not base then
                    base = maxWalk(mount)
                    if not base then return end
                    if addr then mountBaselines[addr] = base end
                    log("sprint: mount baseline %.0f, boosting to %.0f", base, base * 1.4)
                end
                mountBoostRef = mount
                mountBoostAddr = addr
                local target = base * 1.4
                local cur = maxWalk(mount)
                -- re-assert only if the game dropped it BELOW target; its own
                -- faster states are left alone
                if cur and cur < target - 1 then
                    setMaxWalk(mount, target)
                end
                return
            end
            stopMountBoost() -- on foot (or just dismounted)

            -- ON FOOT: the game's OWN sprint. BeginSprint the moment you're moving out of
            -- combat, EndSprint otherwise. real anim/stamina/speed - NO MaxWalkSpeed writes.
            -- guarded by IsSprintingLocomotionStateActive so Begin/End fire ONLY on a state
            -- CHANGE = near-zero work per tick (no spam, no fps hit). velocity gate = you must
            -- actually be moving (press W) to sprint.
            local loco = getLoco(pawn)
            if loco then
                local wantSprint = state.sprint and not lastCombat and velSq(pawn) >= MIN_SPEED_SQ
                local active = isSprinting(loco)
                if wantSprint and not active then
                    pcall(function() loco:BeginSprint() end)
                elseif active and not wantSprint then
                    pcall(function() loco:EndSprint() end)
                end
            end
        end)
        if not ok then logErrorOnce("sprint", err) end
    end)
    return false
end)

-- ---------------------------------------------------------------- AutoReload
-- two tricks:
--  window forcing: CheckInWindow doesn't compare against the DISPLAYED
--    WindowMin/WindowMax - it reads an ASC attribute window
--    (WFRangedWeaponAttributeSet.ActiveReloadCenter/Bounds) +/- the instance's
--    Tolerance (default 3). every activation forces those wide open, so any
--    press (yours included) at any time = perfect.
--  press = the GA's own input callback: injecting the pawn's InpActEvt_Reload
--    does NOT feed the minigame's WFAbilityTask_HandlePlayerInputPress - it
--    just queued a SECOND reload after the first ended (the v12 double-reload
--    bug). the graph's bound press handlers (OnTriggered_*(ElapsedTime)) are
--    plain UFunctions on the ability - call those directly.
local RELOAD_LATENCY = 0.03 -- scheduling/input latency compensation, seconds
local windowForcedLogged = false
local successThisCycle = false

local function pressReload(ab, elapsed) -- game thread only
    local ok = pcall(function() ab:OnTriggered_99CA32B34E7E0E8640D86BAE3837FFCB(elapsed) end)
    if not ok then logErrorOnce("reload-press", "OnTriggered_99CA call failed") end
end

local function forceWindowOpen(ab)
    pcall(function() ab.Tolerance = 1000.0 end)
    pcall(function() ab.EarlyPressForgivenessPercent = 0.0 end)
    -- whichever operand the check reads, cover it: widen the attribute window too
    pcall(function()
        for _, s in pairs(FindAllOf("WFRangedWeaponAttributeSet") or {}) do
            if isReal(s) then
                pcall(function()
                    s.ActiveReloadBounds.CurrentValue = 200.0
                    s.ActiveReloadBounds.BaseValue = 200.0
                end)
            end
        end
    end)
    if not windowForcedLogged then
        windowForcedLogged = true
        log("reload: window forced open")
    end
end

-- window props are set by the GA's ubergraph right after activation; values
-- are normalized 0-1 of the slider unless they read as plain seconds
local function readWindow(ab)
    local maxT, wmin, wmax, wcenter
    local ok = pcall(function()
        maxT = ab.MaxReloadTime
        wmin = ab.WindowMin
        wmax = ab.WindowMax
        wcenter = ab.WindowCenter
    end)
    if not ok or not maxT or maxT <= 0.05 then return nil end
    local center
    if wmin and wmax and wmax > 0 then
        center = (wmin + wmax) / 2
    elseif wcenter and wcenter > 0 then
        center = wcenter
    end
    if not center then return nil end
    -- values seen in the wild: 0-100 percent of the slider (session 12 log:
    -- "window 40-60 max 1.5s"), possibly 0-1 normalized on other weapons
    if center > 1.001 then center = center / 100 end
    return center * maxT, wmin or -1, wmax or -1, maxT
end

local windowUnreadable = false
local function scheduleWindowPress(ab, t0, attempt)
    attempt = attempt or 1
    if attempt > 10 then
        if not windowUnreadable then
            windowUnreadable = true
            log("reload: window props unreadable - press manually (any time = perfect)")
        end
        return
    end
    ExecuteWithDelay(attempt == 1 and 100 or 60, function()
        ExecuteInGameThread(function()
            local phase = "read"
            local ok, err = pcall(function()
                if not state.reload or not currentReload or currentReload.t0 ~= t0 then return end
                if not ab:IsValid() then return end
                local pressSec, wmin, wmax, maxT = readWindow(ab)
                if not pressSec then
                    scheduleWindowPress(ab, t0, attempt + 1)
                    return
                end
                currentReload.maxT = maxT
                log("reload: window %.2f-%.2f max %.2fs -> press at %.2fs", wmin, wmax, maxT, pressSec)
                phase = "press"
                local function firePress()
                    if not (state.reload and currentReload and currentReload.t0 == t0 and ab:IsValid()) then return end
                    currentReload.pressed = true
                    pressReload(ab, os.clock() - t0)
                    log("reload: pressed at %.2fs", os.clock() - t0)
                    -- second bound handler, in case the first isn't the press path
                    ExecuteWithDelay(250, function()
                        ExecuteInGameThread(function()
                            pcall(function()
                                if state.reload and currentReload and currentReload.t0 == t0 and ab:IsValid() then
                                    local e2 = os.clock() - t0
                                    pcall(function() ab:OnTriggered_0C5309BB4DBB1136C0E5DEBE6E42DF1A(e2) end)
                                    log("reload: fallback press at %.2fs", e2)
                                end
                            end)
                        end)
                    end)
                end
                local remainMs = math.floor((pressSec - RELOAD_LATENCY - (os.clock() - t0)) * 1000)
                if remainMs <= 10 then
                    firePress()
                    return
                end
                ExecuteWithDelay(remainMs, function()
                    ExecuteInGameThread(function()
                        pcall(firePress)
                    end)
                end)
            end)
            if not ok then logErrorOnce("reload@" .. phase, tostring(err)) end
        end)
    end)
end

local function onReloadActivated(self)
    local ok, err = pcall(function()
        local ab = self:get()
        if not (ab and ab:IsValid()) then return end -- MP: skip remote/invalid reload abilities
        -- MP: only OUR reload - never apply window-forcing/press-injection to a
        -- remote player's replicated reload (would touch their ability + everyone's
        -- attribute sets)
        local avatar = nil
        pcall(function() avatar = ab:GetAvatarActorFromActorInfo() end)
        if avatar and avatar:IsValid() then
            local mine = getPawn()
            if mine and addrOf(avatar) ~= addrOf(mine) then return end
        end
        local t0 = os.clock()
        successThisCycle = false
        currentReload = { t0 = t0, maxT = nil, pressed = false, successClass = nil }
        pcall(function() currentReload.maxT = ab.MaxReloadTime end)
        pcall(function() currentReload.successClass = ab.ReloadSuccessType end)
        if not state.reload then return end
        forceWindowOpen(ab) -- hook runs on game thread, before any press lands
        scheduleWindowPress(ab, t0)
    end)
    if not ok then logErrorOnce("reload-activate", tostring(err)) end
end

local function onReloadSucceeded(self)
    successThisCycle = true
    pcall(function() log("reload: PERFECT") end)
end

-- minigame over (success, fail or cancel): stop pending presses so a stale
-- injected press can't start a second reload. if the game didn't grant the
-- success ability (= the perfect buff) after OUR press, force it.
local function onReloadEnded(self)
    local ok = pcall(function()
        local cr = currentReload
        currentReload = nil
        if not cr then return end
        log("reload: ended at %.2fs", os.clock() - cr.t0)
        if not (state.reload and cr.pressed) then return end
        local successClass = cr.successClass
        ExecuteWithDelay(250, function()
            ExecuteInGameThread(function()
                pcall(function()
                    if successThisCycle then return end
                    if not successClass or not successClass:IsValid() then return end
                    local pawn = getPawn()
                    local asc = pawn and getASC(pawn)
                    if asc and asc:TryActivateAbilityByClass(successClass, true) then
                        log("reload: buff FORCED via success ability")
                    end
                end)
            end)
        end)
    end)
    if not ok then logErrorOnce("reload-end", "handler failed") end
end

-- ---------------------------------------------------------------- overlay state file
-- consumed by the external overlay app (tools/overlay/WFQoL-Overlay.ps1).
-- pure Lua io: safe to run any time, no engine access.
local STATE_FILE = "Mods/WFQoL/overlay-state.json"
local STATE_FILE_ABS = "D:/SteamLibrary/steamapps/common/Wayfinder/Atlas/Binaries/Win64/Mods/WFQoL/overlay-state.json"

local function writeState()
    local ok, err = pcall(function()
        local f = io.open(STATE_FILE, "w") or io.open(STATE_FILE_ABS, "w")
        if not f then error("cannot open " .. STATE_FILE) end
        f:write(string.format(
            '{"chain":%s,"parry":%s,"sprint":%s,"reload":%s,"overlay":%s,"sprintMode":"%s","combat":%s,"lastParry":"%s","incoming":"%s","incomingKind":"%s","incomingTs":%d,"statParry":%d,"statParryFail":%d,"statSeen":%d,"ts":%d}',
            tostring(state.chain), tostring(state.parry), tostring(state.sprint),
            tostring(state.reload), tostring(state.overlay), sprintMode,
            tostring(lastCombat == true), lastParryInfo,
            incoming.name, incoming.kind, incoming.ts,
            stat.parry, stat.parryFail, stat.seen, os.time()))
        f:close()
    end)
    if not ok then logErrorOnce("statefile", err) end
end

-- perf watchdog: the state loop should tick every ~1.0s. a much larger gap =
-- the game hitched (GPU/CPU spike). logged (throttled) so we can correlate
-- stutters with what's happening and tune Engine.ini. cheap: just clock math.
local perfLastTick = os.clock()
local perfLastLog = 0.0
-- game-thread freeze fingerprint: a perma-load / native hang freezes the GAME
-- thread but NOT UE4SS's async loops, so it leaves no crash and no lua error - the
-- log just stops. this watchdog (async thread) pings the game thread each tick; if
-- several pings go unanswered while the watchdog keeps ticking, the game thread is
-- frozen. log it once so the NEXT perma-load leaves a fingerprint (base-game stream
-- hang vs a mod hang). re-arms after a normal (finite) zone load recovers.
local gtBeat, gtAck, gtFrozenLogged = 0, 0, false
LoopAsync(1000, function()
    writeState()
    local now = os.clock()
    local dt = now - perfLastTick
    perfLastTick = now
    if dt > 2.0 and now - perfLastLog > 10 then
        perfLastLog = now
        log("perf: hitch %.1fs (combat=%s) - engine.ini tuning candidate", dt, tostring(lastCombat == true))
    end
    gtBeat = gtBeat + 1
    local myBeat = gtBeat
    ExecuteInGameThread(function() gtAck = myBeat end)
    local behind = gtBeat - gtAck
    if behind >= 6 and not gtFrozenLogged then
        gtFrozenLogged = true
        log("GAME THREAD FROZEN ~%ds: async watchdog alive but game thread not responding (perma-load / native hang, no lua error)", behind)
    elseif behind < 3 then
        gtFrozenLogged = false -- recovered (normal zone load), re-arm
    end
    return false
end)

-- overlay -> mod command channel: clicking a mod row in the overlay writes
-- overlay-cmd.json {seq, feature}; we toggle that mod's state on a new seq.
-- the pre-existing seq at load is recorded but not applied (stale click guard).
local CMD_REL = "Mods/WFQoL/overlay-cmd.json"
local CMD_ABS = "D:/SteamLibrary/steamapps/common/Wayfinder/Atlas/Binaries/Win64/Mods/WFQoL/overlay-cmd.json"
local lastCmdSeq = nil
LoopAsync(200, function()
    pcall(function()
        local f = io.open(CMD_REL, "r") or io.open(CMD_ABS, "r")
        if not f then return end
        local raw = f:read("*a")
        f:close()
        local seq = raw:match('"seq"%s*:%s*(%d+)')
        local feat = raw:match('"feature"%s*:%s*"(%a+)"')
        if not seq then return end
        if lastCmdSeq == nil then lastCmdSeq = seq return end
        if seq ~= lastCmdSeq then
            lastCmdSeq = seq
            if feat and state[feat] ~= nil then
                state[feat] = not state[feat]
                log("%s %s (overlay click)", feat, state[feat] and "ON" or "OFF")
                writeState()
            end
        end
    end)
    return false
end)

-- ---------------------------------------------------------------- hooks
local pending = {}
local registered = {}

-- launch the external overlay when the game starts (once). the overlay
-- self-exits when our heartbeat goes stale, so it lives and dies with the
-- game - no Windows login autostart (that spawned it on every PC boot).
local OVERLAY_VBS = "C:/Users/Abeelha/Documents/github/wayfinder-mods/tools/overlay/launch-overlay.vbs"
local overlayLaunched = false
local function launchOverlay()
    if overlayLaunched then return end
    overlayLaunched = true
    pcall(function() os.execute('wscript "' .. OVERLAY_VBS .. '"') end)
end

local function tryHook(path, fn)
    if registered[path] then return end
    if pcall(RegisterHook, path, fn) then
        registered[path] = true
        pending[path] = nil
        log("hooked %s", path)
    else
        pending[path] = true
    end
end

local function registerAll()
    tryHook(CHAR .. ":InpActEvt_Attack1_K2Node_InputActionEvent_36", function(self)
        if injecting then return end
        m1Held = true
        local p = self:get()
        if p and p:IsValid() then pawnRef = p end -- guard: never cache an invalid pawn
    end)
    tryHook(CHAR .. ":InpActEvt_Attack1_K2Node_InputActionEvent_37", function(self)
        if injecting then return end
        m1Held = false
    end)
    -- heavy attack (Attack2 = RMB): _40 press / _41 release, mirrors Attack1
    tryHook(CHAR .. ":InpActEvt_Attack2_K2Node_InputActionEvent_40", function(self)
        if injecting then return end
        m2Held = true
        local p = self:get()
        if p and p:IsValid() then pawnRef = p end
    end)
    tryHook(CHAR .. ":InpActEvt_Attack2_K2Node_InputActionEvent_41", function(self)
        if injecting then return end
        m2Held = false
    end)
    tryHook(AIBASE .. ":K2_ActivateAbility", onEnemyAbility)
    tryHook(RELOAD_GA .. ":K2_ActivateAbility", onReloadActivated)
    tryHook(RELOAD_GA .. ":K2_OnEndAbility", onReloadEnded)
    tryHook(RELOAD_OK_GA .. ":K2_ActivateAbility", onReloadSucceeded)
    -- ground-truth signals from the game's own success/fail cues (preloaded)
    tryHook("/Game/Blueprints/GameplayCueNotifies/Ability/2HR/GCNA_2HR_ActiveReload_Success.GCNA_2HR_ActiveReload_Success_C:K2_HandleGameplayCue", function()
        successThisCycle = true
        log("reload: success cue")
    end)
    tryHook("/Game/Blueprints/GameplayCueNotifies/Ability/2HR/GCNA_2HR_ActiveReload_Fail.GCNA_2HR_ActiveReload_Fail_C:K2_HandleGameplayCue", function()
        log("reload: FAIL cue (should be impossible - report this)")
    end)
end

registerAll()

LoopAsync(5000, function()
    if next(pending) == nil then return true end
    registerAll()
    return false
end)

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self, NewPawn)
    -- whole body guarded: an uncaught throw here surfaces as UE4SS
    -- "Error executing hook pre-callback ClientRestart" and can abort a transition
    local hookOk, hookErr = pcall(function()
        transitionAt = os.clock() -- arm the settle gate: actors are (un)constructing
        ready = true
        m1Held = false
        local ok, p = pcall(function() return NewPawn:get() end)
        if ok and p and p:IsValid() then
            pawnRef = p -- cache only a VALID pawn; else getPawn re-finds the local one
            -- do NOT read p:GetClass() here: the raw ClientRestart pawn can still be
            -- mid-construction with a null class ptr -> native 0x10 AV pcall can't catch
            -- (load/transition crash). getPawn() re-validates lazily when actually used.
        end
        libCache = nil
        sprintClassCache = nil
        metersCache = nil -- HUD widgets are rebuilt on the new level; drop stale ref
        preloadParryAssets() -- ClientRestart hook = guaranteed game thread
        launchOverlay()
        registerAll()
    end)
    if not hookOk then logErrorOnce("clientrestart", tostring(hookErr)) end
end)

-- ---------------------------------------------------------------- keybinds
-- debounced: key auto-repeat fires RegisterKeyBind multiple times per press
local lastToggle = {}
local function bindToggle(key, name, label)
    RegisterKeyBind(key, function()
        local now = os.clock()
        if lastToggle[name] and now - lastToggle[name] < 0.3 then return end
        lastToggle[name] = now
        state[name] = not state[name]
        log("%s %s", label, state[name] and "ON" or "OFF")
        writeState()
    end)
end

bindToggle(Key.F6, "sprint", "AutoSprint")
bindToggle(Key.F7, "chain", "AutoChain")
bindToggle(Key.F8, "parry", "AutoParry")
bindToggle(Key.F9, "reload", "AutoReload")

-- INS: show/hide the overlay window. flips state.overlay -> writeState; the overlay
-- app hides/shows itself on this flag (stays alive polling, so INS re-shows it).
pcall(function()
    local insKey = Key.INS or Key.INSERT
    if insKey then
        bindToggle(insKey, "overlay", "Overlay")
        log("overlay show/hide bound to INS")
    else
        log("overlay toggle: no INS key found in UE4SS Key enum")
    end
end)

-- F5: one-shot diagnostic dump (mount debugging etc)
RegisterKeyBind(Key.F5, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pawn = getPawn()
            if not pawn then log("diag: no pawn") return end
            local cls = pawn:GetClass():GetFName():ToString()
            local okm, mountedNative = pcall(function() return pawn:IsMounted() end)
            local parent = attachParent(pawn)
            local parentCls, parentVel = "none", 0
            if parent then
                parentCls = parent:GetClass():GetFName():ToString()
                parentVel = math.sqrt(velSq(parent))
            end
            local asc = getASC(pawn)
            local combat = asc and ascHasTag(asc, INCOMBAT_TAG) or false
            local sprinting = asc and ascHasTag(asc, SPRINTING_TAG) or false
            log("diag: pawn=%s vel=%.0f mountedNative=%s parent=%s parentVel=%.0f walk=%s parentWalk=%s mode=%s combat=%s sprintTag=%s",
                cls, math.sqrt(velSq(pawn)),
                okm and tostring(mountedNative) or "CALL-FAILED",
                parentCls, parentVel,
                tostring(maxWalk(pawn)), parent and tostring(maxWalk(parent)) or "-",
                sprintMode, tostring(combat), tostring(sprinting))
        end)
        if not ok then log("diag error: %s", tostring(err)) end
    end)
end)

log("loaded - F6 sprint / F7 chain / F8 parry / F9 reload / INS overlay")
