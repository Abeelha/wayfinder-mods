-- AutoSprint: sprint automatically while moving out of combat. F6 toggles.

local ENABLED = true
local MIN_SPEED_SQ = 100 * 100 -- only sprint when actually moving
local INCOMBAT_TAG = { TagName = FName("Character.State.Generic.InCombat") }
local SPRINT_CLASS = "/Game/Blueprints/Player/GAS/GameplayAbilities/GA_Player_Sprint.GA_Player_Sprint_C"

local function log(fmt, ...) print(string.format("[AutoSprint] " .. fmt .. "\n", ...)) end

local UEHelpers = require("UEHelpers")
local warnedOnce = false
local lastCombat = nil

LoopAsync(300, function()
    if not ENABLED then return false end
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pawn = UEHelpers:GetPlayerController().Pawn
            if not pawn or not pawn:IsValid() then return end

            local inCombat = pawn:HasMatchingGameplayTag(INCOMBAT_TAG)
            if inCombat ~= lastCombat then
                lastCombat = inCombat
                log("combat state: %s", tostring(inCombat))
            end
            if inCombat then return end
            if pawn:IsPlayerSprinting() then return end

            local vel = pawn:GetVelocity()
            if (vel.X * vel.X + vel.Y * vel.Y) < MIN_SPEED_SQ then return end

            local lib = StaticFindObject("/Script/Wayfinder.Default__WFAbilitySystemBlueprintLibrary")
            local sprintClass = StaticFindObject(SPRINT_CLASS)
            if not (lib and lib:IsValid() and sprintClass and sprintClass:IsValid()) then return end

            local asc = lib:GetWFPlayerAbilitySystemComponent(pawn)
            if asc and asc:IsValid() then
                asc:TryActivateAbilityByClass(sprintClass, true)
            end
        end)
        if not ok and not warnedOnce then
            warnedOnce = true
            log("error: %s", tostring(err))
        end
    end)
    return false
end)

RegisterKeyBind(Key.F6, function()
    ENABLED = not ENABLED
    log("%s", ENABLED and "ON" or "OFF")
end)

log("loaded (F6 toggles, currently ON)")
