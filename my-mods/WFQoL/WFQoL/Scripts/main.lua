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

local function getLib()
    local lib = StaticFindObject(WFLIB)
    return lib and lib:IsValid() and lib or nil
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
local PARRY_COOLDOWN = 0.6
local PARRY_RANGE = 800.0
local lastParry = 0.0
local lastScheduled = 0.0

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

local function doParry(className, delayMs)
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if not state.parry then return end
            local now = os.clock()
            if now - lastParry < PARRY_COOLDOWN then return end
            local pawn = getPawn()
            if not pawn then return end
            local asc = getASC(pawn)
            if not asc then return end
            local blockAbility = asc:GetAbilityFromInputTag(BLOCK_TAG)
            if not blockAbility or not blockAbility:IsValid() then return end
            if asc:TryActivateAbilityByClass(blockAbility:GetClass(), true) then
                lastParry = now
                log("parry vs %s (delay %dms)", className, delayMs)
            end
        end)
        if not ok then logErrorOnce("parry", err) end
    end)
end

local function onEnemyAbility(self)
    if not state.parry then return end
    local now = os.clock()
    if now - lastScheduled < 0.15 then return end
    local ok, err = pcall(function()
        local ab = self:get()
        if not isMeleeAttack(ab) then return end
        local className = ab:GetClass():GetFName():ToString()
        local enemy = ab:GetAvatarActorFromActorInfo()
        local pawn = getPawn()
        if not (enemy and enemy:IsValid() and pawn) then return end
        if distTo(enemy, pawn) > PARRY_RANGE then return end
        local hitTime = timings[className] or DEFAULT_HIT
        local delayMs = math.floor(math.max(hitTime - LEAD, 0) * 1000)
        lastScheduled = now
        if delayMs < 20 then
            doParry(className, delayMs)
        else
            ExecuteWithDelay(delayMs, function() doParry(className, delayMs) end)
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

local function speedSq(pawn)
    local v = pawn:GetVelocity()
    local s = v.X * v.X + v.Y * v.Y
    if s > 1 then return s end
    local ok, parent = pcall(function() return pawn:GetAttachParentActor() end)
    if ok and parent and parent:IsValid() then
        local pv = parent:GetVelocity()
        return pv.X * pv.X + pv.Y * pv.Y
    end
    return s
end

local function maxWalk(pawn)
    local ok, v = pcall(function() return pawn.CharacterMovement.MaxWalkSpeed end)
    return ok and v or nil
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

            local shouldSprint = state.sprint and not inCombat
                and speedSq(pawn) >= MIN_SPEED_SQ
            if not shouldSprint then
                stopSprintAssist(pawn, asc)
                return
            end

            if ascHasTag(asc, SPRINTING_TAG) and not tagInjected then
                sprintTries = 0 -- real sprint is running
                return
            end

            if sprintMode == "ability" then
                local sprintClass = StaticFindObject(SPRINT_CLASS)
                if sprintClass and sprintClass:IsValid() then
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
                            log("sprint: tag injection works (walk %d -> %d)", tagBaseline, now)
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
                        log("sprint: direct speed %d -> %d", origMaxWalk, origMaxWalk * 1.5)
                    end
                end
            end
        end)
        if not ok then logErrorOnce("sprint", err) end
    end)
    return false
end)

-- ---------------------------------------------------------------- AutoReload
-- force the active-reload minigame checks to always pass, and auto-press the
-- second reload input shortly after the reload starts
local function onReloadActivated(self)
    if not state.reload then return end
    ExecuteWithDelay(300, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                if not state.reload then return end
                if not pawnRef or not pawnRef:IsValid() then return end
                injecting = true
                pawnRef:InpActEvt_Reload_K2Node_InputActionEvent_12(RKEY)
                injecting = false
            end)
            if not ok then logErrorOnce("reload", err) end
        end)
    end)
end

-- ---------------------------------------------------------------- overlay
local kismet = nil
local function overlayTick()
    if not (state.overlay and ready) then return end
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pawn = getPawn()
            if not pawn then return end
            if not kismet or not kismet:IsValid() then
                kismet = StaticFindObject(KISMET)
            end
            if not kismet or not kismet:IsValid() then return end
            local function tag(on) return on and "ON" or "--" end
            local line = string.format(
                "WFQoL   chain[F7]:%s   parry[F8]:%s   sprint[F6]:%s   reload[F9]:%s",
                tag(state.chain), tag(state.parry), tag(state.sprint), tag(state.reload))
            kismet:PrintString(pawn, line, true, false,
                { R = 0.25, G = 1.0, B = 0.75, A = 1.0 }, 0.65)
        end)
        if not ok then logErrorOnce("overlay", err) end
    end)
end
LoopAsync(500, function()
    overlayTick()
    return false
end)

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
    -- any press timing counts as perfect while reload feature is on
    tryHook(RELOAD_GA .. ":CheckInWindow", function()
        if state.reload then return true end
    end)
    tryHook(RELOAD_GA .. ":CheckInForgivenessWindow", function()
        if state.reload then return true end
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
    end
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
    end)
end

bindToggle(Key.F6, "sprint", "AutoSprint")
bindToggle(Key.F7, "chain", "AutoChain")
bindToggle(Key.F8, "parry", "AutoParry")
bindToggle(Key.F9, "reload", "AutoReload")
pcall(function() bindToggle(Key.INS, "overlay", "Overlay") end)

log("loaded - F6 sprint / F7 chain / F8 parry / F9 reload / INS overlay")
