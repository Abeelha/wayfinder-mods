-- AutoSprint v2: sprint automatically while moving (on foot or mounted), pauses
-- in combat. F6 toggles.
-- v2 fixes: pawn:HasMatchingGameplayTag is a PURE_VIRTUAL stub via UE4SS - use
-- WFAbilitySystemBlueprintLibrary:AbilitySystemHasTagExactly instead. Mounted
-- movement read from the attach parent (rider pawn's own velocity is ~0).

local ENABLED = true
local MIN_SPEED_SQ = 100 * 100
local INCOMBAT_TAG = { TagName = FName("Character.State.Generic.InCombat") }
local SPRINTING_TAG = { TagName = FName("Character.State.Generic.Sprinting") }
local SPRINT_CLASS = "/Game/Blueprints/Player/GAS/GameplayAbilities/GA_Player_Sprint.GA_Player_Sprint_C"

local function log(fmt, ...) print(string.format("[AutoSprint] " .. fmt .. "\n", ...)) end

local seenErrors = {}
local function logErrorOnce(err)
    local msg = tostring(err)
    if not seenErrors[msg] then
        seenErrors[msg] = true
        log("error: %s", msg)
    end
end

local pawnRef = nil
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self, NewPawn)
    local ok, p = pcall(function() return NewPawn:get() end)
    if ok then pawnRef = p end
end)

local function getPawn()
    if pawnRef and pawnRef:IsValid() then return pawnRef end
    local ok = pcall(function()
        for _, p in pairs(FindAllOf("WFPlayerCharacter_Base_C") or {}) do
            if p:IsValid() then pawnRef = p break end
        end
    end)
    if ok and pawnRef and pawnRef:IsValid() then return pawnRef end
    return nil
end

local function speedSq(pawn)
    local v = pawn:GetVelocity()
    local s = v.X * v.X + v.Y * v.Y
    if s > 1 then return s end
    -- mounted: rider is attached, movement lives on the mount
    local ok, parent = pcall(function() return pawn:GetAttachParentActor() end)
    if ok and parent and parent:IsValid() then
        local pv = parent:GetVelocity()
        return pv.X * pv.X + pv.Y * pv.Y
    end
    return s
end

local lastCombat = nil

LoopAsync(300, function()
    if not ENABLED then return false end
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pawn = getPawn()
            if not pawn then return end

            local lib = StaticFindObject("/Script/Wayfinder.Default__WFAbilitySystemBlueprintLibrary")
            if not lib or not lib:IsValid() then return end
            local asc = lib:GetWFPlayerAbilitySystemComponent(pawn)
            if not asc or not asc:IsValid() then return end

            local inCombat = lib:AbilitySystemHasTagExactly(asc, INCOMBAT_TAG)
            if inCombat ~= lastCombat then
                lastCombat = inCombat
                log("combat: %s", tostring(inCombat))
            end
            if inCombat then return end
            if lib:AbilitySystemHasTagExactly(asc, SPRINTING_TAG) then return end
            if speedSq(pawn) < MIN_SPEED_SQ then return end

            local sprintClass = StaticFindObject(SPRINT_CLASS)
            if sprintClass and sprintClass:IsValid() then
                asc:TryActivateAbilityByClass(sprintClass, true)
            end
        end)
        if not ok then logErrorOnce(err) end
    end)
    return false
end)

RegisterKeyBind(Key.F6, function()
    ENABLED = not ENABLED
    log("%s", ENABLED and "ON" or "OFF")
end)

log("loaded (F6 toggles, currently ON)")
