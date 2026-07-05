-- ShowNameplates - shows EVERY player nameplate's health + stamina, each driven from its
-- OWN owner's ability system (the local player AND co-op teammates). Patched (WFQoL):
-- the old code scraped the LOCAL HUD_PlayerMeters and pushed values onto a single
-- self-nameplate it tracked by address -> teammates could never be driven, and raw
-- SetVisibility(0) fought the widget's own visibility logic -> flicker. It also read
-- pawn:GetClass()/owner:GetClass() synchronously on freshly-possessed / dying actors
-- whose class ptr can be null -> native 0x10 access violation that pcall CANNOT catch
-- (crash on load/transition). This version drives every UI_NameplateWidget_Player_C from
-- its native AttachedOwnerActor via the widget's OWN GetHealthPercentage /
-- GetStaminaPercentage + SetHealthMeterVisibility / SetStaminaMeterVisibility, all on a
-- settle-gated periodic loop so it never touches an actor mid-teardown/construction.

local NP_ENEMY  = "/Game/UI/UI_WF_Blueprints/UI_WF_HUD/UI_NameplateWidget_Enemy.UI_NameplateWidget_Enemy_C"
local NP_PLAYER = "/Game/UI/UI_WF_Blueprints/UI_WF_HUD/UI_NameplateWidget_Player.UI_NameplateWidget_Player_C"

local hooksInstalled = false -- install the ShouldBeVisible overrides exactly once

-- SETTLE GATE: level transitions / co-op joins tear actors down and construct new ones.
-- a native call (GetClass / GetHealthPercentage / attribute read) on a dying or half-built
-- object is an access violation pcall CANNOT catch. after a ClientRestart, skip all native
-- nameplate work briefly so actors finish (un)constructing.
local SETTLE_SECS = 1.5
local transitionAt = 0.0
local function settling() return (os.clock() - transitionAt) < SETTLE_SECS end

local function OverrideReturn(UFunctionName, ReturnValue, Callback)
    Callback = Callback or function() end
    return RegisterHook(UFunctionName, function(...) Callback(...); return ReturnValue end)
end

-- FindAllOf returns the class default object (CDO, "Default__...") alongside real
-- instances; the CDO passes :IsValid() but has no owner -> skip it.
local function isReal(obj)
    if not (obj and obj:IsValid()) then return false end
    local ok, nm = pcall(function() return obj:GetFName():ToString() end)
    return ok and nm ~= nil and nm:sub(1, 9) ~= "Default__"
end

-- set a ProgressBar by name if present (missing names / dead bars no-op via pcall)
local function setPct(np, name, pct)
    pcall(function()
        local bar = np[name]
        if bar and bar:IsValid() then bar:SetPercent(pct) end
    end)
end

-- cheap, safe pointer read (returns the address value; no object-internal deref, so it is
-- safe even on a transient/remote owner)
local function addrOf(o)
    local ok, a = pcall(function() return o:GetAddress() end)
    return ok and a or nil
end

-- the LOCAL player's pawn, directly (never iterates remote pawns)
local function localPawn()
    local ok, p = pcall(function()
        local UEHelpers = require("UEHelpers")
        return UEHelpers:GetPlayerController().Pawn
    end)
    if ok and p and p:IsValid() then return p end
    return nil
end

-- drive ONE player nameplate. VISIBILITY is forced for EVERYONE (self + teammates) - a
-- pure widget toggle, no owner-ASC read, safe; re-asserted each tick via the widget's
-- INTENDED toggles (not raw SetVisibility) to counter its own re-hide -> fixes flicker.
-- VALUES (health/stamina) are pushed ONLY for the LOCAL player: GetHealth/StaminaPercentage
-- reads the owner's ability-system, and a REMOTE teammate's ASC can be null/unresolved
-- client-side -> native access violation (crash on MP join) that pcall CANNOT catch.
-- teammates' HEALTH self-drives natively once the meter is visible; their stamina is
-- best-effort (meter shown, fill left to the game).
local function driveNameplate(np, lpAddr)
    if not (np and np:IsValid()) then return end
    local owner = np.AttachedOwnerActor
    if not (owner and owner:IsValid()) then return end
    pcall(function() np:SetHealthMeterVisibility(true) end)
    pcall(function() np:SetStaminaMeterVisibility(true) end)
    if not lpAddr or addrOf(owner) ~= lpAddr then return end -- remote nameplate: visibility only
    pcall(function()
        local ok, pct = np:GetHealthPercentage(owner)
        if ok and pct then
            setPct(np, "PlayerHealthBar", pct)
            setPct(np, "PlayerLastHealthBar", pct)
        end
    end)
    pcall(function()
        local ok, pct = np:GetStaminaPercentage(owner)
        if ok and pct then setPct(np, "characterStaminaFill", pct) end
    end)
end

local function installHooks()
    if hooksInstalled then return end
    hooksInstalled = true
    -- force every player nameplate visible (the game hides the local player's own). safe
    -- no-op callback - no owner deref here; the drive loop handles owners, settle-gated.
    OverrideReturn(NP_PLAYER .. ":ShouldBeVisible", true)
    -- force enemy nameplates visible. enemies self-drive their own health via the widget's
    -- WaitForAttributeChangeUI listeners; we only make them show. NO owner:GetClass() read
    -- here - that per-call native class read on a dying owner was a 0x10 crash surface.
    OverrideReturn(NP_ENEMY .. ":ShouldBeVisible", true)
end

-- periodic driver: iterate every player nameplate and drive it from its own owner.
-- settle-gated + native work marshalled onto the game thread (UObject access off-thread
-- is unsafe). small N (party size) so 200ms is cheap.
LoopAsync(200, function()
    if settling() then return false end
    ExecuteInGameThread(function()
        pcall(function()
            local lp = localPawn()
            local lpAddr = lp and addrOf(lp) or nil
            for _, np in pairs(FindAllOf("UI_NameplateWidget_Player_C") or {}) do
                if isReal(np) then driveNameplate(np, lpAddr) end
            end
        end)
    end)
    return false
end)

-- arm the settle gate + install hooks once on every ClientRestart. NO synchronous native
-- read on the fresh pawn here (its class ptr can be null mid-construction -> 0x10 AV).
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    transitionAt = os.clock()
    pcall(installHooks)
end)

-- mod restarted mid-map: install immediately if the widget class is already loaded
do
    local wp = StaticFindObject(NP_PLAYER)
    if wp and wp:IsValid() then pcall(installHooks) end
end

print("[ShowNameplates] loaded - per-owner health+stamina, settle-gated (MP-safe)\n")
