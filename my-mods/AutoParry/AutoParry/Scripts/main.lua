-- AutoParry: when an enemy starts a melee attack near you, auto-activate your
-- weapon's block/parry ability (whatever is bound to Input.Combat.Block for the
-- equipped weapon: DW parry, SnS shield, 2H parry). F8 toggles.

local ENABLED = true
local lastTrigger = 0.0
local COOLDOWN = 0.6      -- seconds between auto-parries
local RANGE = 700.0       -- units; only react to enemies this close

local AIBASE = "/Game/Blueprints/Abilities/AIGeneric/GA_AI_Base.GA_AI_Base_C"
local BLOCK_TAG = { TagName = FName("Input.Combat.Block") }

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

local function onEnemyAbility(self)
    if not ENABLED then return end
    local now = os.clock()
    if now - lastTrigger < COOLDOWN then return end

    local ok, err = pcall(function()
        local ab = self:get()
        if not isMeleeAttack(ab) then return end

        local enemy = ab:GetAvatarActorFromActorInfo()
        local pawn = UEHelpers:GetPlayerController().Pawn
        if not (enemy and enemy:IsValid() and pawn and pawn:IsValid()) then return end
        if distTo(enemy, pawn) > RANGE then return end

        local lib = getLib()
        if not lib then return end
        local asc = lib:GetWFPlayerAbilitySystemComponent(pawn)
        if not asc or not asc:IsValid() then return end

        local blockAbility = asc:GetAbilityFromInputTag(BLOCK_TAG)
        if not blockAbility or not blockAbility:IsValid() then return end

        if asc:TryActivateAbilityByClass(blockAbility:GetClass(), true) then
            lastTrigger = now
            log("parry vs %s", ab:GetClass():GetFName():ToString())
        end
    end)
    if not ok then log("error: %s", tostring(err)) end
end

local pendingHook = true
local function registerHooks()
    if not pendingHook then return end
    if pcall(RegisterHook, AIBASE .. ":K2_ActivateAbility", onEnemyAbility) then
        pendingHook = false
        log("enemy ability hook registered")
    end
end

registerHooks()
RegisterHook("/Script/Engine.PlayerController:ClientRestart", registerHooks)

RegisterKeyBind(Key.F8, function()
    ENABLED = not ENABLED
    log("%s", ENABLED and "ON" or "OFF")
end)

log("loaded (F8 toggles, currently ON)")
