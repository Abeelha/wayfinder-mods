-- WFQoL: Wayfinder quality-of-life bundle with on-screen overlay.
--   F7  AutoChain  - hold M1 to auto-chain melee attacks
--   F8  AutoParry  - timed parry/block just before enemy melee hits land
--   F6  AutoSprint - sprint while moving out of combat (foot + mount)
--   F9  AutoReload - reload minigame always lands the perfect window
--   F10 AimAssist  - controller aim assist (soft lock/magnetism) on KB+M
--   INS overlay on/off
--
-- Safety rule (learned the hard way): no FindAllOf/ExecuteInGameThread engine
-- access until the player pawn exists. pcall'd RegisterHook attempts are fine.

local state = {
    chain = true,
    parry = true,
    sprint = true,
    reload = true,
    aim = true,
    overlay = true,
}

local function log(fmt, ...) print(string.format("[WFQoL] " .. fmt .. "\n", ...)) end

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
local KISMET = "/Script/Engine.Default__KismetSystemLibrary"

local LMB = { KeyName = FName("LeftMouseButton") }
local BLOCK_TAG = { TagName = FName("Input.Combat.Block") }
local INCOMBAT_TAG = { TagName = FName("Character.State.Generic.InCombat") }
local SPRINTING_TAG = { TagName = FName("Character.State.Generic.Sprinting") }

local timings = require("timings") -- enemy GA class -> seconds to first weapon trace

-- ---------------------------------------------------------------- pawn / ready
local ready = false
local pawnRef = nil

local function getPawn()
    if pawnRef and pawnRef:IsValid() then return pawnRef end
    pawnRef = nil
    pcall(function()
        for _, p in pairs(FindAllOf(CHAR_CLASS_ONLY) or {}) do
            if p:IsValid() then pawnRef = p break end
        end
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
local m1Held = false
local injecting = false
local sendRelease = false

-- reload minigame state lives up here: AutoChain must stop injecting M1 while
-- the minigame runs (Attack1 AND Reload both count as minigame inputs - a
-- spammed press outside the window = guaranteed failed reload)
local currentReload = nil -- { t0, maxT }
local function reloadInProgress()
    if not currentReload then return false end
    return (os.clock() - currentReload.t0) < ((currentReload.maxT or 3.0) + 0.5)
end

LoopAsync(70, function()
    if not (state.chain and m1Held and ready) then return false end
    if reloadInProgress() then return false end
    ExecuteInGameThread(function()
        if not pawnRef or not pawnRef:IsValid() then return end
        injecting = true
        pcall(function()
            if sendRelease then
                pawnRef:InpActEvt_Attack1_K2Node_InputActionEvent_37(LMB)
            else
                pawnRef:InpActEvt_Attack1_K2Node_InputActionEvent_36(LMB)
            end
        end)
        injecting = false
        sendRelease = not sendRelease
    end)
    return false
end)

-- ---------------------------------------------------------------- AutoParry
local LEAD = 0.25
local DEFAULT_HIT = 0.6
local PARRY_COOLDOWN = 0.3
local PARRY_RANGE = 800.0        -- schedule-time prefilter
local CONNECT_RANGE = 450.0      -- fire-time: attack must actually reach us
local FACING_DOT = 0.2           -- fire-time: enemy must be aimed at us
local STAMINA_RESERVE = 0.35     -- keep this much stamina for dashing
local lastParry = 0.0
local lastScheduled = 0.0
local lastParryInfo = "" -- for the external overlay
local lastStaminaSkipLog = 0.0

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

-- the parry abilities reference their stamina-cost effects via SOFT class refs;
-- lazy-loading those mid-combat can land on a non-game thread = fatal crash
-- ("AssembleReferenceTokenStream ... called on a non-game thread"). preload them
-- from a guaranteed game-thread context instead.
local PRELOAD = {
    "/Game/Blueprints/Player/GAS/GameplayAbilities/2H/GameplayEffects/GE_2H_Parry_Cooldown",
    "/Game/Blueprints/Player/GAS/GameplayAbilities/2H/GameplayEffects/GE_2H_Parry_DamageReduction",
    "/Game/Blueprints/Player/GAS/GameplayAbilities/DW/GameplayEffects/GE_Player_DW_ConsumeStamina_Parry",
    "/Game/Blueprints/Player/GAS/GameplayAbilities/DW/GameplayEffects/GE_Player_DW_ConsumeStamina_Parry_Survivalist",
    "/Game/Blueprints/Player/GAS/GameplayAbilities/DW/GA_Player_DW_Parry_Pushback",
    "/Game/Blueprints/Player/GAS/GameplayAbilities/DW/TA_Player_DW_Parry_Pushback",
    "/Game/Blueprints/Player/GAS/GameplayAbilities/SnS/GE_Player_SNS_ConsumeStamina_Parry",
    "/Game/Blueprints/Player/GAS/GameplayAbilities/SnS/GE_Player_SNS_ConsumeStamina_Parry_Survivalist",
    -- reload success/fail cue notify classes: preloading makes them hookable at spawn
    "/Game/Blueprints/GameplayCueNotifies/Ability/2HR/GCNA_2HR_ActiveReload_Success",
    "/Game/Blueprints/GameplayCueNotifies/Ability/2HR/GCNA_2HR_ActiveReload_Fail",
    -- player projectile BP base (magic bullets registers a spawn notify on it)
    "/Game/Blueprints/Projectiles/WFProjectile_Base_BP",
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

-- stamina read via the HUD stamina meter widget (same trick ShowNameplates uses)
local metersCache = nil
local function staminaPct()
    local ok, pct = pcall(function()
        if not metersCache or not metersCache:IsValid() then
            metersCache = nil
            for _, m in pairs(FindAllOf("HUD_PlayerMeters_C") or {}) do
                if m.PlayerShieldBar and m.PlayerShieldBar:IsValid() then
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

-- returns "ok" (activated), "active" (block/parry already running - success),
-- or false (rejected)
local function tryActivateParry(asc)
    local blockAbility = asc:GetAbilityFromInputTag(BLOCK_TAG)
    if not blockAbility or not blockAbility:IsValid() then return false end
    local isActive = false
    pcall(function() isActive = blockAbility:IsActive() end)
    if isActive then return "active" end
    if asc:TryActivateAbilityByClass(blockAbility:GetClass(), true) then return "ok" end
    return false
end

-- forcing ladder: plain activation -> cancel current swing montage + retry ->
-- two more delayed rounds -> give up loudly
local function doParry(className, delayMs, enemy, attempt)
    attempt = attempt or 1
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if not state.parry then return end
            if reloadInProgress() then return end -- parry/montage-stop would kill the minigame
            local now = os.clock()
            if now - lastParry < PARRY_COOLDOWN then return end
            local pawn = getPawn()
            if not pawn then return end

            -- only spend the parry if this attack is actually about to land on us
            if not willConnect(enemy, pawn) then return end

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
            if r == "active" then return end -- already blocking/parrying, nothing to force
            if r == "ok" then
                lastParry = now
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
                log("parry FAILED vs %s after %d attempts", className, attempt)
            end
        end)
        if not ok then logErrorOnce("parry", err) end
    end)
end

-- verdict memo: tag containers iterated once per ABILITY CLASS ever, not per activation
local meleeCache = {}

local function onEnemyAbility(self)
    if not state.parry then return end
    local now = os.clock()
    if now - lastScheduled < 0.05 then return end
    local ok, err = pcall(function()
        local ab = self:get()
        local className = ab:GetClass():GetFName():ToString()
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
        local hitTime = timings[className] or DEFAULT_HIT
        local delayMs = math.floor(math.max(hitTime - LEAD, 0) * 1000)
        lastScheduled = now
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
local sprintMode = "ability"
local sprintTries = 0
local tagInjected = false
local tagTicks = 0
local tagBaseline = nil
local tagVerified = false
local speedBoosted = false
local origMaxWalk = nil
local lastCombat = nil

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

local function maxWalk(actor)
    local ok, v = pcall(function() return actor.CharacterMovement.MaxWalkSpeed end)
    return ok and v or nil
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
        pcall(function()
            if ref:IsValid() and base then ref.CharacterMovement.MaxWalkSpeed = base end
        end)
        mountBoostRef = nil
        mountBoostAddr = nil
    end
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

local function stopSprintAssist(pawn, asc)
    if tagInjected then
        pcall(function() asc:RemoveGameplayTag(SPRINTING_TAG) end)
        tagInjected = false
        tagTicks = 0
    end
    if speedBoosted and origMaxWalk then
        pcall(function() pawn.CharacterMovement.MaxWalkSpeed = origMaxWalk end)
        speedBoosted = false
    end
    stopMountBoost()
end

LoopAsync(300, function()
    if not ready then return false end
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pawn = getPawn()
            if not pawn then return end
            local asc = getASC(pawn)
            if not asc then return end

            local inCombat = ascHasTag(asc, INCOMBAT_TAG)
            if inCombat ~= lastCombat then
                lastCombat = inCombat
                log("combat: %s", tostring(inCombat))
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
                if tagInjected or speedBoosted then
                    pcall(function() asc:RemoveGameplayTag(SPRINTING_TAG) end)
                    tagInjected = false
                    if speedBoosted and origMaxWalk then
                        pcall(function() pawn.CharacterMovement.MaxWalkSpeed = origMaxWalk end)
                    end
                    speedBoosted = false
                end
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
                    pcall(function() mount.CharacterMovement.MaxWalkSpeed = target end)
                end
                return
            end
            stopMountBoost() -- just dismounted

            local shouldSprint = state.sprint and not inCombat and velSq(pawn) >= MIN_SPEED_SQ
            if not shouldSprint then
                stopSprintAssist(pawn, asc)
                return
            end

            if ascHasTag(asc, SPRINTING_TAG) and not tagInjected then
                sprintTries = 0 -- real sprint is running
                return
            end

            if sprintMode == "ability" then
                local sprintClass = getSprintClass()
                if sprintClass then
                    asc:TryActivateAbilityByClass(sprintClass, true)
                    sprintTries = sprintTries + 1
                    if sprintTries >= 5 then
                        sprintMode = "tag"
                        log("sprint: ability path inert, trying tag injection")
                    end
                end
            elseif sprintMode == "tag" then
                if not tagInjected then
                    tagBaseline = maxWalk(pawn)
                    pcall(function() asc:AddUniqueGameplayTag(SPRINTING_TAG) end)
                    tagInjected = true
                    tagTicks = 0
                else
                    tagTicks = tagTicks + 1
                    if tagTicks == 3 and not tagVerified then
                        local now = maxWalk(pawn)
                        if tagBaseline and now and now > tagBaseline + 1 then
                            tagVerified = true
                            log("sprint: tag injection works (walk %.0f -> %.0f)", tagBaseline, now)
                        else
                            stopSprintAssist(pawn, asc)
                            sprintMode = "speed"
                            log("sprint: tag inert (walk stuck at %s), using direct speed", tostring(now))
                        end
                    end
                end
            else -- speed mode
                if not speedBoosted then
                    origMaxWalk = maxWalk(pawn)
                    if origMaxWalk then
                        pcall(function() pawn.CharacterMovement.MaxWalkSpeed = origMaxWalk * 1.5 end)
                        speedBoosted = true
                        log("sprint: direct speed %.0f -> %.0f", origMaxWalk, origMaxWalk * 1.5)
                    end
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
            if s:IsValid() then
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

-- ---------------------------------------------------------------- AimAssist
-- everything gamepad-flavored in the game (magnet consumption, input-source
-- checks) is C++-gated and unreachable, so the assist is built here from two
-- ungateable parts:
--   magnetizer: while aiming, find the best soft-lock target via the pawn's
--     TargetingComponent and write it into m_MagnetizedAimTarget
--   camera pull: rotate the camera toward that target ourselves via
--     AddControllerYaw/PitchInput - gentle, capped, cone-limited, with a
--     deadzone so the mouse always has the final say
local aimWeights = { Radius = 3000.0, Yaw = 40.0, bCanTargetFriendly = false, bIgnoreHardLockedTarget = false }
local aimMagnetized = false

-- tunables live in Mods/WFQoL/aim-config.json, written by the overlay's
-- sliders and hot-reloaded here every second:
--   fov      degrees around the crosshair targets are acquired in (2-90)
--   bullets  magic bullets: our projectiles home into the acquired target
--   strength homing acceleration, 0-1 (1 = bullets take hard curves)
--   pull     camera-pull assist on/off (bullets made this mostly obsolete)
--   smooth   camera pull: fraction of remaining angle per 16ms tick
--   adsOnly  camera pull only while ADS (acquisition always runs when
--            aiming OR firing - bullets need a target during hipfire too)
local AIMCFG_REL = "Mods/WFQoL/aim-config.json"
local AIMCFG_ABS = "D:/SteamLibrary/steamapps/common/Wayfinder/Atlas/Binaries/Win64/Mods/WFQoL/aim-config.json"
local aimCfg = { fov = 20.0, smooth = 0.15, adsOnly = true, bullets = true, strength = 0.6, pull = false }
local aimCfgRaw = nil

local PULL_DEADZONE = 0.25 -- degrees; inside this, hands off
local lastPullYaw, lastPullPitch = 0.0, 0.0

LoopAsync(1000, function()
    pcall(function()
        local f = io.open(AIMCFG_REL, "r") or io.open(AIMCFG_ABS, "r")
        if not f then return end
        local raw = f:read("*a")
        f:close()
        if raw == aimCfgRaw then return end
        aimCfgRaw = raw
        local fov = tonumber(raw:match('"fov"%s*:%s*([%d%.]+)'))
        local smooth = tonumber(raw:match('"smooth"%s*:%s*([%d%.]+)'))
        local strength = tonumber(raw:match('"strength"%s*:%s*([%d%.]+)'))
        local ads = raw:match('"adsOnly"%s*:%s*(%a+)')
        local bullets = raw:match('"bullets"%s*:%s*(%a+)')
        local pull = raw:match('"pull"%s*:%s*(%a+)')
        if fov then aimCfg.fov = math.max(2, math.min(90, fov)) end
        if smooth then aimCfg.smooth = math.max(0.02, math.min(1, smooth)) end
        if strength then aimCfg.strength = math.max(0, math.min(1, strength)) end
        if ads then aimCfg.adsOnly = (ads == "true") end
        if bullets then aimCfg.bullets = (bullets == "true") end
        if pull then aimCfg.pull = (pull == "true") end
        aimWeights.Yaw = math.min(90, aimCfg.fov * 1.5) -- acquire wider than we pull
        log("aim: config fov=%.0f bullets=%s strength=%.2f pull=%s smooth=%.2f adsOnly=%s",
            aimCfg.fov, tostring(aimCfg.bullets), aimCfg.strength,
            tostring(aimCfg.pull), aimCfg.smooth, tostring(aimCfg.adsOnly))
    end)
    return false
end)

local function normDeg(a)
    while a > 180 do a = a - 360 end
    while a < -180 do a = a + 360 end
    return a
end

local function isAimingNow(pawn)
    local aiming = false
    pcall(function() aiming = pawn:IsAiming() end)
    if not aiming then pcall(function() aiming = pawn:IsFreeFireAiming() end) end
    return aiming
end

-- acquisition: any time we're aiming OR firing (bullets need targets on hipfire)
local function aimEngaged(pawn)
    if not state.aim then return false end
    return isAimingNow(pawn) or m1Held
end

-- camera pull: its own gates on top
local function pullEngaged(pawn)
    if not (state.aim and aimCfg.pull) then return false end
    if isAimingNow(pawn) then return true end
    if not aimCfg.adsOnly and m1Held then return true end
    return false
end
local aimSettingsDone = false
local function applyAimSettings()
    if aimSettingsDone then return end
    pcall(function()
        for _, s in pairs(FindAllOf("WFGameUserSettings") or {}) do
            if s:IsValid() then
                local old = nil
                pcall(function() old = s.bCameraAssistOnGamepad end)
                s.bCameraAssistOnGamepad = true
                -- native ADS friction (slowdown over targets); ships defaulted to 0
                pcall(function() s.ADSAimFriction = 1.0 end)
                aimSettingsDone = true
                log("aim: bCameraAssistOnGamepad %s -> true, ADSAimFriction -> 1", tostring(old))
            end
        end
    end)
end

LoopAsync(100, function()
    if not ready then return false end
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pawn = getPawn()
            if not pawn then return end
            local tc = pawn.TargetingComponent
            if not tc or not tc:IsValid() then return end

            local aiming = aimEngaged(pawn)
            if not aiming then
                if aimMagnetized then
                    pcall(function() tc:ClearMagnetizedAimTarget() end)
                    aimMagnetized = false
                end
                return
            end

            -- bIsResultTransient=false stores results on the component; reading
            -- the stored property avoids UE4SS struct-return marshaling
            tc:FindSoftLockTarget(aimWeights, false, true)
            local best = nil
            pcall(function()
                local targets = tc.m_CurrentSoftLockTargetResults.AssociatedTargets
                if targets and #targets > 0 then best = targets[1] end
            end)
            if best and best:IsValid() then
                tc.m_MagnetizedAimTarget = best
                if not aimMagnetized then
                    aimMagnetized = true
                    pcall(function() log("aim: magnetized %s", best:GetClass():GetFName():ToString()) end)
                end
            end
        end)
        if not ok then logErrorOnce("aim", tostring(err)) end
    end)
    return false
end)

-- camera pull toward the magnetized target. look-at math in plain Lua, and
-- the rotation is WRITTEN via SetControlRotation - the additive
-- AddController*Input route went through the game's input pipeline which
-- scales/dampens it to nothing during ADS (session 15: calls executed
-- errorless, zero movement). direct writes bypass all of that; the mouse
-- still fights back fine because every tick re-reads the current rotation.
local aimPulling = false
LoopAsync(16, function()
    if not (state.aim and ready) then return false end
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pawn = getPawn()
            if not pawn or not pullEngaged(pawn) then aimPulling = false return end
            local tc = pawn.TargetingComponent
            if not tc or not tc:IsValid() then return end
            local target = tc:GetMagnetizedAimTarget()
            if not target or not target:IsValid() then aimPulling = false return end
            local controller = pawn:GetController()
            if not controller or not controller:IsValid() then return end

            local camLoc = nil
            pcall(function() camLoc = controller.PlayerCameraManager:GetCameraLocation() end)
            if not camLoc then camLoc = pawn:K2_GetActorLocation() end
            local tgtLoc = nil
            pcall(function()
                local s = tc:GetMagnetizedAimTargetSocketLocation()
                if s and not (s.X == 0 and s.Y == 0 and s.Z == 0) then tgtLoc = s end
            end)
            if not tgtLoc then tgtLoc = target:K2_GetActorLocation() end

            local dx, dy, dz = tgtLoc.X - camLoc.X, tgtLoc.Y - camLoc.Y, tgtLoc.Z - camLoc.Z
            local dist2d = math.sqrt(dx * dx + dy * dy)
            if dist2d < 50 then return end
            local wantYaw = math.deg(math.atan(dy, dx))
            local wantPitch = math.deg(math.atan(dz, dist2d))
            local cur = controller:GetControlRotation()
            local dyaw = normDeg(wantYaw - cur.Yaw)
            local dpitch = normDeg(wantPitch - cur.Pitch)
            if math.abs(dyaw) > aimCfg.fov or math.abs(dpitch) > aimCfg.fov then
                aimPulling = false
                return
            end
            if math.abs(dyaw) < PULL_DEADZONE and math.abs(dpitch) < PULL_DEADZONE then return end

            -- exponential approach: smooth = fraction of remaining angle per
            -- 16ms tick (1.0 = instant snap), capped so low smooth stays gentle
            local k = aimCfg.smooth
            local cap = 12.0 * k
            local function step(d)
                local p = d * k
                if p > cap then p = cap elseif p < -cap then p = -cap end
                return p
            end
            local py, pp = step(dyaw), step(dpitch)
            lastPullYaw, lastPullPitch = py, pp
            local newPitch = normDeg(cur.Pitch + pp)
            if newPitch > 75 then newPitch = 75 elseif newPitch < -75 then newPitch = -75 end
            controller:SetControlRotation({ Pitch = newPitch, Yaw = normDeg(cur.Yaw + py), Roll = 0.0 })
            if not aimPulling then
                aimPulling = true
                log("aim: pulling (dyaw=%.1f dpitch=%.1f)", dyaw, dpitch)
            end
        end)
        if not ok then logErrorOnce("aimpull", tostring(err)) end
    end)
    return false
end)

-- magic bullets: every projectile the PLAYER fires is force-connected into
-- the acquired target via the movement component's FakeNewHit (the game's own
-- guaranteed-impact API). the ONLY knob is FOV: how close your crosshair must
-- be to the target for the magic to engage. homing (SetHomingTarget) is the
-- fallback if the forced hit ever errors.
-- player shot class chain: WFProjectile_2HR_Slug_C -> WFProjectile_Base_BP_C
-- -> MayhemProjectile -> MayhemBaseProjectile; notify registered on all
-- levels because v15's base-only registration never fired.
local lastBulletLog = 0.0
local lastBulletDiag = 0.0
local seenProj = {}
local seenProjCount = 0

local function angleToTarget(controller, camLoc, tgtLoc)
    local dx, dy, dz = tgtLoc.X - camLoc.X, tgtLoc.Y - camLoc.Y, tgtLoc.Z - camLoc.Z
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1 then return 999 end
    local rot = controller:GetControlRotation()
    local yr, pr = math.rad(rot.Yaw), math.rad(rot.Pitch)
    local fx, fy, fz = math.cos(pr) * math.cos(yr), math.cos(pr) * math.sin(yr), math.sin(pr)
    local dot = (fx * dx + fy * dy + fz * dz) / len
    if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
    return math.deg(math.acos(dot))
end

local function onProjectile(proj)
    if not (ready and state.aim and aimCfg.bullets) then return end
    ExecuteWithDelay(30, function() -- spawn props aren't set in the constructor yet
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                if not proj:IsValid() then return end
                -- several hooks/notifies can report the same shot, and pooled
                -- projectiles REUSE addresses across shots: dedup with a
                -- short time window instead of forever
                local addr = addrOf(proj)
                local nowD = os.clock()
                if addr and seenProj[addr] and nowD - seenProj[addr] < 0.5 then return end
                if addr then
                    seenProj[addr] = nowD
                    seenProjCount = seenProjCount + 1
                    if seenProjCount > 400 then seenProj = { [addr] = nowD } seenProjCount = 1 end
                end
                local pawn = getPawn()
                if not pawn then return end

                local projCls, instCls, ownCls = "?", "nil", "nil"
                pcall(function() projCls = proj:GetClass():GetFName():ToString() end)
                local inst, owner = nil, nil
                pcall(function() inst = proj:GetInstigator() end)
                pcall(function() owner = proj:GetOwner() end)
                pcall(function() if inst and inst:IsValid() then instCls = inst:GetClass():GetFName():ToString() end end)
                pcall(function() if owner and owner:IsValid() then ownCls = owner:GetClass():GetFName():ToString() end end)
                local now = os.clock()
                if now - lastBulletDiag > 2 then
                    lastBulletDiag = now
                    log("bullets: saw %s inst=%s owner=%s", projCls, instCls, ownCls)
                end

                -- ours? instigator or owner is the player pawn (or at least a player char)
                local mine = false
                if inst and inst:IsValid() and addrOf(inst) == addrOf(pawn) then mine = true end
                if not mine and owner and owner:IsValid() and addrOf(owner) == addrOf(pawn) then mine = true end
                if not mine and instCls == CHAR_CLASS_ONLY then mine = true end
                if not mine then return end

                local tc = pawn.TargetingComponent
                if not tc or not tc:IsValid() then return end
                local target = tc:GetMagnetizedAimTarget()
                if not (target and target:IsValid()) then
                    -- hipfire before the magnetizer ticked: acquire right now
                    pcall(function() tc:FindSoftLockTarget(aimWeights, false, true) end)
                    pcall(function()
                        local t = tc.m_CurrentSoftLockTargetResults.AssociatedTargets
                        if t and #t > 0 then target = t[1] end
                    end)
                end
                if not (target and target:IsValid()) then return end

                -- FOV is the one and only gate
                local controller = pawn:GetController()
                if not controller or not controller:IsValid() then return end
                local camLoc = nil
                pcall(function() camLoc = controller.PlayerCameraManager:GetCameraLocation() end)
                if not camLoc then camLoc = pawn:K2_GetActorLocation() end
                local tgtLoc = nil
                pcall(function()
                    local s = tc:GetMagnetizedAimTargetSocketLocation()
                    if s and not (s.X == 0 and s.Y == 0 and s.Z == 0) then tgtLoc = s end
                end)
                if not tgtLoc then tgtLoc = target:K2_GetActorLocation() end
                if angleToTarget(controller, camLoc, tgtLoc) > aimCfg.fov then return end

                -- force the impact: the projectile "hits" the target right now
                local forced = false
                pcall(function()
                    local comp = target:K2_GetRootComponent()
                    if not (comp and comp:IsValid()) then return end
                    local pl = proj:K2_GetActorLocation()
                    local nx, ny, nz = pl.X - tgtLoc.X, pl.Y - tgtLoc.Y, pl.Z - tgtLoc.Z
                    local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
                    if nl < 1 then nx, ny, nz, nl = 0, 0, 1, 1 end
                    proj.MovementComponent:FakeNewHit(target, comp,
                        { X = tgtLoc.X, Y = tgtLoc.Y, Z = tgtLoc.Z },
                        { X = nx / nl, Y = ny / nl, Z = nz / nl })
                    forced = true
                end)
                if not forced then
                    -- fallback: max-strength homing
                    pcall(function()
                        proj:SetHomingTarget(target)
                        local mc = proj.MovementComponent
                        mc.bIsHomingProjectile = true
                        mc.HomingAccelerationMagnitude = 40000.0
                    end)
                end
                if now - lastBulletLog > 2 then
                    lastBulletLog = now
                    pcall(function()
                        log("bullets: %s -> %s", forced and "FORCED HIT" or "homing", target:GetClass():GetFName():ToString())
                    end)
                end
            end)
            if not ok then logErrorOnce("bullets", tostring(err)) end
        end)
    end)
end

-- session 17 finding: NotifyOnNewObject NEVER fired for shots on any class
-- level (registered clean, zero callbacks) - projectiles are pooled
-- (IPoolableProjectileInterface), constructed once and reused per shot.
-- notifies kept for genuinely fresh spawns; the real per-shot signal is the
-- BP base's own per-launch functions, hooked in registerAll below.
NotifyOnNewObject("/Script/Wayfinder.MayhemBaseProjectile", onProjectile)
NotifyOnNewObject("/Script/Wayfinder.MayhemProjectile", onProjectile)
local WFPROJ_BP = "/Game/Blueprints/Projectiles/WFProjectile_Base_BP.WFProjectile_Base_BP_C"
local function onProjectileFn(self)
    pcall(function() onProjectile(self:get()) end)
end

-- session 18 finding: the BASIC rifle attack is HITSCAN
-- (GA_Player_RangedWeapon_Fire_Batched CDO: IsHitscanWeapon=true) - it never
-- spawns projectile actors, it line-traces via a WFTargetActor_LineTrace.
-- magic bullets for hitscan = the game's own enum: the trace actor's
-- EndpointAimType supports AimAtSoftTargetActor (=1) - the trace END becomes
-- the soft-lock target our magnetizer acquires, regardless of where the
-- camera points. plus every spread var on ability AND trace actor zeroed =
-- laser accuracy. props persist on the instanced ability, re-asserted on
-- every fire activation.
local AIM_SOFT_TARGET = 1   -- EWFTargetActorEndLocationAimingType::AimAtSoftTargetActor
local AIM_CAMERA_FWD = 2    -- ::AimAtCameraForward
local lastHitscanLog = 0.0

local function currentBulletTarget(pawn)
    local tc = pawn.TargetingComponent
    if not tc or not tc:IsValid() then return nil end
    local target = tc:GetMagnetizedAimTarget()
    if not (target and target:IsValid()) then
        pcall(function() tc:FindSoftLockTarget(aimWeights, false, true) end)
        pcall(function()
            local t = tc.m_CurrentSoftLockTargetResults.AssociatedTargets
            if t and #t > 0 then target = t[1] end
        end)
    end
    if not (target and target:IsValid()) then return nil end
    local controller = pawn:GetController()
    if not controller or not controller:IsValid() then return nil end
    local camLoc = nil
    pcall(function() camLoc = controller.PlayerCameraManager:GetCameraLocation() end)
    if not camLoc then camLoc = pawn:K2_GetActorLocation() end
    local tgtLoc = target:K2_GetActorLocation()
    if angleToTarget(controller, camLoc, tgtLoc) > aimCfg.fov then return nil end
    return target
end

local function onFireAbility(self)
    local ok, err = pcall(function()
        if not (state.aim and aimCfg.bullets and ready) then return end
        local ab = self:get()
        if not ab:IsValid() then return end
        local pawn = getPawn()
        if not pawn then return end

        -- laser accuracy on the ability's own spread vars
        pcall(function()
            ab.BaseSpread = 0.0
            ab.AimSpreadModifier = 0.0
            ab.SpreadIncrement = 0.0
            ab.SpreadMax = 0.0
        end)

        local target = currentBulletTarget(pawn)
        pcall(function()
            local ta = ab.TraceTargetActor
            if not (ta and ta:IsValid()) then return end
            ta.BaseSpread = 0.0
            ta.AimingSpreadMod = 0.0
            ta.TargetingSpreadIncrement = 0.0
            ta.TargetingSpreadMax = 0.0
            ta.EndpointAimType = target and AIM_SOFT_TARGET or AIM_CAMERA_FWD
        end)

        local now = os.clock()
        if now - lastHitscanLog > 2 then
            lastHitscanLog = now
            if target then
                pcall(function()
                    log("bullets: hitscan locked -> %s", target:GetClass():GetFName():ToString())
                end)
            else
                log("bullets: hitscan zero-spread (no target in fov)")
            end
        end
    end)
    if not ok then logErrorOnce("bullets-hitscan", tostring(err)) end
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
            '{"chain":%s,"parry":%s,"sprint":%s,"reload":%s,"aim":%s,"sprintMode":"%s","combat":%s,"lastParry":"%s","ts":%d}',
            tostring(state.chain), tostring(state.parry), tostring(state.sprint),
            tostring(state.reload), tostring(state.aim), sprintMode,
            tostring(lastCombat == true), lastParryInfo, os.time()))
        f:close()
    end)
    if not ok then logErrorOnce("statefile", err) end
end

LoopAsync(1000, function()
    writeState()
    return false
end)

-- overlay is a resident tray app (login autostart via tools/overlay/install-autostart.ps1);
-- it shows itself whenever the heartbeat in overlay-state.json is fresh

-- ---------------------------------------------------------------- hooks
local pending = {}
local registered = {}

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
        pawnRef = self:get()
    end)
    tryHook(CHAR .. ":InpActEvt_Attack1_K2Node_InputActionEvent_37", function(self)
        if injecting then return end
        m1Held = false
    end)
    tryHook(AIBASE .. ":K2_ActivateAbility", onEnemyAbility)
    tryHook(RELOAD_GA .. ":K2_ActivateAbility", onReloadActivated)
    tryHook(RELOAD_GA .. ":K2_OnEndAbility", onReloadEnded)
    tryHook(RELOAD_OK_GA .. ":K2_ActivateAbility", onReloadSucceeded)
    -- magic bullets: per-shot functions on the (pooled) projectile BP base
    tryHook(WFPROJ_BP .. ":ReceiveBeginPlay", onProjectileFn)
    tryHook(WFPROJ_BP .. ":ComputeInitialSpeed", onProjectileFn)
    tryHook(WFPROJ_BP .. ":FindTargetActor", onProjectileFn)
    -- magic bullets: hitscan fire abilities (basic attacks) - every variant
    local FIREDIR = "/Game/Blueprints/Player/GAS/GameplayAbilities/RangedWeapon/"
    tryHook(FIREDIR .. "GA_Player_RangedWeapon_Fire_Batched.GA_Player_RangedWeapon_Fire_Batched_C:K2_ActivateAbility", onFireAbility)
    tryHook(FIREDIR .. "GA_Player_RangedWeapon_Fire_Batched_Burst.GA_Player_RangedWeapon_Fire_Batched_Burst_C:K2_ActivateAbility", onFireAbility)
    tryHook(FIREDIR .. "GA_Player_RangedWeapon_Fire_Batched_Rail.GA_Player_RangedWeapon_Fire_Batched_Rail_C:K2_ActivateAbility", onFireAbility)
    tryHook(FIREDIR .. "GA_Player_RangedWeapon_Fire_Batched_Shotgun.GA_Player_RangedWeapon_Fire_Batched_Shotgun_C:K2_ActivateAbility", onFireAbility)
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
    local ok, p = pcall(function() return NewPawn:get() end)
    if ok then
        pawnRef = p
        ready = true
        m1Held = false
        pcall(function() log("pawn: %s", p:GetClass():GetFName():ToString()) end)
    end
    libCache = nil
    sprintClassCache = nil
    preloadParryAssets() -- ClientRestart hook = guaranteed game thread
    applyAimSettings()
    registerAll()
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
bindToggle(Key.F10, "aim", "AimAssist")

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
            local magnet, magnetizing = "-", "?"
            pcall(function()
                local t = pawn.TargetingComponent:GetMagnetizedAimTarget()
                if t and t:IsValid() then magnet = t:GetClass():GetFName():ToString() end
            end)
            pcall(function() magnetizing = tostring(pawn:IsMagnetizingAim()) end)
            log("diag: magnet=%s magnetizing=%s aiming=%s pull=%.2f/%.2f", magnet, magnetizing,
                tostring(isAimingNow(pawn)), lastPullYaw, lastPullPitch)
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

log("loaded - F6 sprint / F7 chain / F8 parry / F9 reload / F10 aim / overlay via tools/overlay")
