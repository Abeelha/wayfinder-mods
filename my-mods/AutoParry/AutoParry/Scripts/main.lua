-- AutoParry v2: timed parry. On enemy melee attack start, look up that attack's
-- real hit timing (extracted from its montage's WeaponTrace notify) and activate
-- the weapon's block/parry ability just before the hit lands. F8 toggles.

local ENABLED = true
local LEAD = 0.25         -- seconds before the hit to press parry (parry startup + margin)
local DEFAULT_HIT = 0.6   -- fallback for attacks without extracted timing
local COOLDOWN = 0.6      -- seconds between auto-parries
local RANGE = 800.0       -- only react to enemies this close at schedule AND fire time

local AIBASE = "/Game/Blueprints/Abilities/AIGeneric/GA_AI_Base.GA_AI_Base_C"
local BLOCK_TAG = { TagName = FName("Input.Combat.Block") }

local timings = require("timings") -- GA class name -> seconds to first weapon trace

local function log(fmt, ...) print(string.format("[AutoParry] " .. fmt .. "\n", ...)) end

local UEHelpers = require("UEHelpers")

local function getLib()
    local lib = StaticFindObject("/Script/Wayfinder.Default__WFAbilitySystemBlueprintLibrary")
    return lib and lib:IsValid() and lib or nil
end

-- enemy attack GAs are tagged Ability.Characteristic.Attack + .Melee (verified in dump)
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

local lastParry = 0.0
local lastScheduled = 0.0

local function doParry(className, delayMs)
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if not ENABLED then return end
            local now = os.clock()
            if now - lastParry < COOLDOWN then return end

            local pawn = UEHelpers:GetPlayerController().Pawn
            if not pawn or not pawn:IsValid() then return end

            local lib = getLib()
            if not lib then return end
            local asc = lib:GetWFPlayerAbilitySystemComponent(pawn)
            if not asc or not asc:IsValid() then return end

            local blockAbility = asc:GetAbilityFromInputTag(BLOCK_TAG)
            if not blockAbility or not blockAbility:IsValid() then return end

            if asc:TryActivateAbilityByClass(blockAbility:GetClass(), true) then
                lastParry = now
                log("parry vs %s (delay %dms)", className, delayMs)
            end
        end)
        if not ok then log("error: %s", tostring(err)) end
    end)
end

local function onEnemyAbility(self)
    if not ENABLED then return end
    local now = os.clock()
    if now - lastScheduled < 0.15 then return end -- collapse bursts of activations

    local ok, err = pcall(function()
        local ab = self:get()
        if not isMeleeAttack(ab) then return end

        local className = ab:GetClass():GetFName():ToString()
        local enemy = ab:GetAvatarActorFromActorInfo()
        local pawn = UEHelpers:GetPlayerController().Pawn
        if not (enemy and enemy:IsValid() and pawn and pawn:IsValid()) then return end
        if distTo(enemy, pawn) > RANGE then return end

        local hitTime = timings[className] or DEFAULT_HIT
        local delayMs = math.floor(math.max(hitTime - LEAD, 0) * 1000)
        lastScheduled = now

        if delayMs < 20 then
            doParry(className, delayMs)
        else
            ExecuteWithDelay(delayMs, function() doParry(className, delayMs) end)
        end
    end)
    if not ok then log("error: %s", tostring(err)) end
end

local pendingHook = true
local function registerHooks()
    if not pendingHook then return end
    if pcall(RegisterHook, AIBASE .. ":K2_ActivateAbility", onEnemyAbility) then
        pendingHook = false
        log("enemy ability hook registered (%d attack timings loaded)", (function()
            local c = 0
            for _ in pairs(timings) do c = c + 1 end
            return c
        end)())
    end
end

registerHooks()
RegisterHook("/Script/Engine.PlayerController:ClientRestart", registerHooks)

RegisterKeyBind(Key.F8, function()
    ENABLED = not ENABLED
    log("%s", ENABLED and "ON" or "OFF")
end)

log("loaded (F8 toggles, currently ON)")
