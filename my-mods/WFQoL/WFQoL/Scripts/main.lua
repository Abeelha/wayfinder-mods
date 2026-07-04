-- WFQoL: Wayfinder quality-of-life bundle with on-screen overlay.
--   F7  AutoChain  - hold M1 to auto-chain melee attacks
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
local RKEY = { KeyName = FName("R") }
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

LoopAsync(70, function()
    if not (state.chain and m1Held and ready) then return false end
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
-- two paths:
--  LEARNED: if a perfect press time is known for this weapon's reload montage
--           (taught by YOUR manual perfect reloads, or a prior auto success),
--           replay the press at that exact time.
--  PROBE:   otherwise poll the ability's CheckInWindow every 40ms and press
--           when the window opens. every success teaches the LEARNED path.
local LEARN_REL = "Mods/WFQoL/reload-times.txt"
local LEARN_ABS = "D:/SteamLibrary/steamapps/common/Wayfinder/Atlas/Binaries/Win64/Mods/WFQoL/reload-times.txt"
local learned = {}
local currentReload = nil -- { montage, t0, pressAt }
local reloadPolling = false
local reloadCallStyle = nil

pcall(function()
    local f = io.open(LEARN_REL, "r") or io.open(LEARN_ABS, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^(.+)=([%d%.]+)$")
        if k and tonumber(v) then learned[k] = tonumber(v) end
    end
    f:close()
end)

local function saveLearned()
    pcall(function()
        local f = io.open(LEARN_REL, "w") or io.open(LEARN_ABS, "w")
        if not f then return end
        for k, v in pairs(learned) do f:write(string.format("%s=%.3f\n", k, v)) end
        f:close()
    end)
end

local function pressReload(elapsed) -- game thread only
    if pawnRef and pawnRef:IsValid() then
        injecting = true
        pawnRef:InpActEvt_Reload_K2Node_InputActionEvent_12(RKEY)
        injecting = false
        if currentReload then currentReload.pressAt = elapsed end
    end
end

-- UE4SS out-param calling convention differs by version: try out-table first,
-- fall back to multi-return; remember whichever works
local function checkInWindow(ab, elapsed)
    if reloadCallStyle ~= "multi" then
        local ok, res = pcall(function()
            local out = {}
            local r = ab:CheckInWindow(elapsed, out)
            return (r == true) or (out.bInWindow == true)
        end)
        if ok then
            reloadCallStyle = "table"
            return res
        end
    end
    local ok2, a, b = pcall(function() return ab:CheckInWindow(elapsed) end)
    if ok2 then
        reloadCallStyle = "multi"
        return (a == true) or (b == true)
    end
    return nil
end

local function startProbe(ab, t0)
    if reloadPolling then return end
    reloadPolling = true
    local ticks = 0
    local done = false
    LoopAsync(40, function()
        ticks = ticks + 1
        if done or ticks > 150 then
            reloadPolling = false
            return true
        end
        ExecuteInGameThread(function()
            local phase = "start"
            local ok, err = pcall(function()
                if done then return end
                if not state.reload then done = true return end
                phase = "isvalid"
                if not ab:IsValid() then done = true return end
                phase = "isactive"
                if not ab:IsActive() then done = true return end
                phase = "checkwindow"
                local elapsed = os.clock() - t0
                local inWindow = checkInWindow(ab, elapsed)
                if inWindow == nil then
                    logErrorOnce("reload", "CheckInWindow failed in both call styles")
                    done = true
                    return
                end
                if inWindow then
                    phase = "press"
                    pressReload(elapsed)
                    log("reload: window press at %.2fs", elapsed)
                    done = true
                end
            end)
            if not ok then
                logErrorOnce("reload@" .. phase, tostring(err))
                done = true
            end
        end)
        return false
    end)
end

local function onReloadActivated(self)
    local ok, err = pcall(function()
        local ab = self:get()
        local montage = "unknown"
        pcall(function() montage = ab.ReloadMontage:GetFName():ToString() end)
        local t0 = os.clock()
        currentReload = { montage = montage, t0 = t0, pressAt = nil }
        if not state.reload then return end

        local t = learned[montage]
        if t then
            ExecuteWithDelay(math.max(math.floor((t - 0.03) * 1000), 20), function()
                ExecuteInGameThread(function()
                    pcall(function()
                        if state.reload and ab:IsValid() and ab:IsActive() then
                            pressReload(os.clock() - t0)
                        end
                    end)
                end)
            end)
        else
            startProbe(ab, t0)
        end
    end)
    if not ok then logErrorOnce("reload-activate", tostring(err)) end
end

-- success = the game activated the Succeeded ability; whatever press time led
-- here (manual or injected) becomes the learned perfect time for this montage
local function onReloadSucceeded(self)
    local ok = pcall(function()
        if currentReload and currentReload.pressAt and currentReload.montage ~= "unknown" then
            local first = learned[currentReload.montage] == nil
            learned[currentReload.montage] = currentReload.pressAt
            saveLearned()
            if first then
                log("reload: LEARNED perfect time %.2fs for %s", currentReload.pressAt, currentReload.montage)
            end
        end
    end)
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
            '{"chain":%s,"parry":%s,"sprint":%s,"reload":%s,"sprintMode":"%s","combat":%s,"lastParry":"%s","ts":%d}',
            tostring(state.chain), tostring(state.parry), tostring(state.sprint),
            tostring(state.reload), sprintMode, tostring(lastCombat == true),
            lastParryInfo, os.time()))
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
    tryHook(RELOAD_OK_GA .. ":K2_ActivateAbility", onReloadSucceeded)
    -- capture YOUR manual reload presses so successes teach the perfect time
    tryHook(CHAR .. ":InpActEvt_Reload_K2Node_InputActionEvent_12", function(self)
        if injecting then return end
        if currentReload then
            currentReload.pressAt = os.clock() - currentReload.t0
        end
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

log("loaded - F6 sprint / F7 chain / F8 parry / F9 reload / overlay via tools/overlay")
