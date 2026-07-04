-- WFRecon: throwaway combat recon logger. Maps hook targets for AutoChain + AutoParry.
-- Not a gameplay mod. Remove after recon phase.

local t0 = os.clock()
local function log(fmt, ...)
    print(string.format("[WFRecon %8.3f] " .. fmt .. "\n", os.clock() - t0, ...))
end

local function classOf(obj)
    local ok, name = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return ok and name or "?"
end

local function avatarOf(ability)
    local ok, name = pcall(function()
        return ability:GetAvatarActorFromActorInfo():GetFName():ToString()
    end)
    return ok and name or "?"
end

-- lazy hook registration: BP classes only exist once their package loads
local pending = {}
local registered = {}

local function tryHook(path, fn)
    if registered[path] then return true end
    local ok = pcall(RegisterHook, path, fn)
    if ok then
        registered[path] = true
        pending[path] = nil
        log("hooked %s", path)
    else
        pending[path] = fn
    end
    return ok
end

local CHAR = "/Game/Blueprints/Main/WFPlayerCharacter_Base.WFPlayerCharacter_Base_C"
local MELEE = "/Game/Blueprints/Player/GAS/GameplayAbilities/GA_Player_Melee_Base.GA_Player_Melee_Base_C"
local BLOCK = "/Game/Blueprints/Player/GAS/GameplayAbilities/GA_Player_Block.GA_Player_Block_C"
local AIBASE = "/Game/Blueprints/Abilities/AIGeneric/GA_AI_Base.GA_AI_Base_C"
local SPRINT = "/Game/Blueprints/Player/GAS/GameplayAbilities/GA_Player_Sprint.GA_Player_Sprint_C"

local function registerAll()
    -- M1 / M2 input edges: which node index is press vs release
    tryHook(CHAR .. ":InpActEvt_Attack1_K2Node_InputActionEvent_36", function(self)
        log("INPUT Attack1 node36 (self=%s)", classOf(self:get()))
    end)
    tryHook(CHAR .. ":InpActEvt_Attack1_K2Node_InputActionEvent_37", function(self)
        log("INPUT Attack1 node37 (self=%s)", classOf(self:get()))
    end)
    tryHook(CHAR .. ":InpActEvt_Attack2_K2Node_InputActionEvent_40", function(self)
        log("INPUT Attack2 node40 (self=%s)", classOf(self:get()))
    end)
    tryHook(CHAR .. ":InpActEvt_Attack2_K2Node_InputActionEvent_41", function(self)
        log("INPUT Attack2 node41 (self=%s)", classOf(self:get()))
    end)

    -- every player melee GA activation/end (combo chain + parry counters, all weapons)
    tryHook(MELEE .. ":K2_ActivateAbility", function(self)
        local ab = self:get()
        log("MELEE GA activate: %s avatar=%s", classOf(ab), avatarOf(ab))
    end)
    tryHook(MELEE .. ":K2_OnEndAbility", function(self)
        log("MELEE GA end: %s", classOf(self:get()))
    end)

    -- block ability lifecycle + the hit event that decides parry vs plain block
    tryHook(BLOCK .. ":K2_ActivateAbility", function(self)
        local ab = self:get()
        local light, heavy = "?", "?"
        pcall(function() light = ab.ParryAbility_Light:GetFName():ToString() end)
        pcall(function() heavy = ab.ParryAbility_Heavy:GetFName():ToString() end)
        log("BLOCK activate: %s parryLight=%s parryHeavy=%s", classOf(ab), light, heavy)
    end)
    tryHook(BLOCK .. ":K2_OnEndAbility", function(self)
        log("BLOCK end: %s", classOf(self:get()))
    end)
    tryHook(BLOCK .. ":OnHitEvent_AE2142DE4CC75306798B578B19416D3F", function(self)
        log("BLOCK OnHitEvent: %s", classOf(self:get()))
    end)
    tryHook(BLOCK .. ":OnHitEventClient_AE2142DE4CC75306798B578B19416D3F", function(self)
        log("BLOCK OnHitEventClient: %s", classOf(self:get()))
    end)

    -- sprint lifecycle (for AutoSprint)
    tryHook(SPRINT .. ":K2_ActivateAbility", function(self)
        log("SPRINT activate: %s", classOf(self:get()))
    end)

    -- every generic enemy ability activation (melee windups included)
    tryHook(AIBASE .. ":K2_ActivateAbility", function(self)
        local ab = self:get()
        log("AI GA activate: %s avatar=%s", classOf(ab), avatarOf(ab))
    end)
end

registerAll()

-- retry until every hook lands (classes load with the first map)
LoopAsync(5000, function()
    if next(pending) == nil then
        log("all hooks registered")
        return true
    end
    registerAll()
    return false
end)

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self, NewPawn)
    local ok, name = pcall(function() return NewPawn:get():GetFullName() end)
    log("ClientRestart pawn=%s", ok and name or "?")
    registerAll()
end)

-- probe InCombat tag on the pawn (verifies FGameplayTag marshaling for AutoSprint)
local lastCombat = nil
LoopAsync(2000, function()
    local ok, inCombat = pcall(function()
        local UEHelpers = require("UEHelpers")
        local pawn = UEHelpers:GetPlayerController().Pawn
        return pawn:HasMatchingGameplayTag({ TagName = FName("Character.State.Generic.InCombat") })
    end)
    if ok and inCombat ~= lastCombat then
        lastCombat = inCombat
        log("COMBAT state changed: %s", tostring(inCombat))
    end
    return false
end)

RegisterKeyBind(Key.F9, function()
    log("--- pending hooks ---")
    for path in pairs(pending) do log("PENDING %s", path) end
    log("--- end ---")
end)

log("WFRecon loaded")
