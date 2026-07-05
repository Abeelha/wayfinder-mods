-- ShowNameplates - PLAYER nameplates only. SELF nameplate shows health + stamina; ALLY
-- (co-op teammate) nameplates show health ONLY (no stamina). Enemy nameplates are left
-- ALONE (the game shows those by default). Only the LOCAL player's own nameplate needs
-- values pushed - the game hides your own health/stamina meters (shown on the HUD instead);
-- teammates' health self-drives natively once its meter is visible.
--
-- EVENT-DRIVEN: no polling loop, no per-tick FindAllOf object scan (that scan over ~135k
-- objects 5x/sec was the fps killer). Work happens only inside the widget's own
-- ShouldBeVisible hook and the HUD meter-change events, which fire on demand.
--
-- LOCAL values mirror the live HUD meters (guaranteed-real, responsive) - not the widget's
-- GetStaminaPercentage (which read wrong). MP-safe: visibility is a pure widget toggle (no
-- owner-ASC read) so it is safe on remote teammates; we NEVER read a remote teammate's ASC
-- (unresolved client-side -> native AV on MP join, uncatchable by pcall). Crash-safe: settle
-- gate skips native work during actor teardown/build; no GetClass() on fresh/dying actors.

local NP_PLAYER = "/Game/UI/UI_WF_Blueprints/UI_WF_HUD/UI_NameplateWidget_Player.UI_NameplateWidget_Player_C"

-- SETTLE GATE: after a ClientRestart, actors are (un)constructing; a native call on a
-- half-built/dying object is an access violation pcall can't catch. skip briefly.
local SETTLE_SECS = 1.5
local transitionAt = 0.0
local function settling() return (os.clock() - transitionAt) < SETTLE_SECS end

local selfNameplate  = nil   -- cached LOCAL player's nameplate (captured in ShouldBeVisible)
local hudMeters      = nil   -- cached local HUD meters widget (value source)
local hooksInstalled = false

local function OverrideReturn(UFunctionName, ReturnValue, Callback)
    Callback = Callback or function() end
    return RegisterHook(UFunctionName, function(...) Callback(...); return ReturnValue end)
end

local function setPct(np, name, pct)
    pcall(function()
        local bar = np[name]
        if bar and bar:IsValid() then bar:SetPercent(pct) end
    end)
end

-- reveal a sub-widget directly (ESlateVisibility 0 = Visible). the widget's own
-- SetHealthMeterVisibility/SetStaminaMeterVisibility toggles proved unreliable solo; raw
-- SetVisibility on the bar widgets is the method that actually shows self health/stamina.
local function showWidget(np, name)
    pcall(function()
        local w = np[name]
        if w and w:IsValid() then w:SetVisibility(0) end
    end)
end

local svbLogged = false -- one-shot diag: player ShouldBeVisible fired
local drove = false     -- one-shot diag: driveSelf succeeded (capture + HUD resolve OK)

-- safe pointer read (address value only, no object-internal deref -> safe on any owner)
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

-- (re)find the LOCAL HUD meters widget; cached until it goes invalid (level change). the
-- FindAllOf is bounded (runs only when the cache is stale, NOT per frame).
local function resolveHUD()
    if hudMeters and hudMeters:IsValid() then return true end
    hudMeters = nil
    for _, e in pairs(FindAllOf("HUD_PlayerMeters_C") or {}) do
        local ok, valid = pcall(function()
            if e:GetFName():ToString():sub(1, 9) == "Default__" then return false end -- skip CDO
            return e.PlayerShieldBar and e.PlayerShieldBar:IsValid()
        end)
        if ok and valid then hudMeters = e break end
    end
    return hudMeters ~= nil and hudMeters:IsValid()
end

-- mirror the local player's LIVE HUD health/shield/stamina onto the cached self nameplate.
-- these are the real, responsive values the HUD itself shows. driven by the HUD meter-change
-- events (fires on change) - no polling.
local function driveSelf()
    if settling() then return end
    local np = selfNameplate
    if not (np and np:IsValid()) then return end
    if not resolveHUD() then return end
    local ok, shieldP, healthP, staminaP = pcall(function()
        return hudMeters.PlayerShieldBar.Percent,
               hudMeters.PlayerHealthBar.Percent,
               hudMeters.HUD_PlayerStaminaMeters.PlayerStaminaMeter.Percent
    end)
    if not ok then return end
    pcall(function() np:SetHealthMeterVisibility(true) end)
    pcall(function() np:SetStaminaMeterVisibility(true) end)
    setPct(np, "PlayerHealthBar",          healthP)  -- primary fill
    setPct(np, "PlayerLastHealthBar",      healthP)  -- damage trail
    setPct(np, "PlayerHealthBar_Additive", shieldP)  -- shield overlay
    setPct(np, "characterStaminaFill",     staminaP) -- stamina fill
    -- raw-reveal the bars too (the meter-visibility toggles proved unreliable solo)
    showWidget(np, "PlayerHealthBar")
    showWidget(np, "PlayerLastHealthBar")
    showWidget(np, "PlayerHealthBar_Additive")
    showWidget(np, "characterStaminaFill")
    if not drove then
        drove = true
        print(string.format("[ShowNameplates] self drive OK: hp=%.2f shield=%.2f stam=%.2f\n", healthP or -1, shieldP or -1, staminaP or -1))
    end
end

local function installHooks()
    if hooksInstalled then return end
    hooksInstalled = true

    -- LOCAL player's values: driven only when the HUD meters actually change (cheap,
    -- event-driven). these fire for the local player only.
    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerMeters.HUD_PlayerMeters_C:OnHealthChanged", driveSelf)
    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerMeters.HUD_PlayerMeters_C:UpdateShieldBar", driveSelf)
    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerStaminaMeters.HUD_PlayerStaminaMeters_C:OnStaminaChanged", driveSelf)

    -- PLAYER nameplate visibility only (enemies are left to the game). the game calls
    -- ShouldBeVisible per nameplate; re-assert the meters visible here (counters the game's
    -- re-hide -> fixes flicker). visibility is a pure widget toggle -> safe on remote
    -- teammates. capture the LOCAL nameplate once for value-driving.
    OverrideReturn(NP_PLAYER .. ":ShouldBeVisible", true, function(self)
        if settling() then return end
        pcall(function()
            local np = self:get()
            if not (np and np:IsValid()) then return end
            if not svbLogged then svbLogged = true; print("[ShowNameplates] player ShouldBeVisible firing\n") end
            np:SetHealthMeterVisibility(true) -- HEALTH for self AND allies
            showWidget(np, "PlayerHealthBar")
            showWidget(np, "PlayerLastHealthBar")
            showWidget(np, "PlayerHealthBar_Additive")
            -- capture the LOCAL nameplate once
            if not (selfNameplate and selfNameplate:IsValid()) then
                local owner = np.AttachedOwnerActor
                if owner and owner:IsValid() then
                    local lp = localPawn()
                    if lp and addrOf(owner) == addrOf(lp) then
                        selfNameplate = np
                        print("[ShowNameplates] self nameplate captured\n")
                        driveSelf() -- populate immediately on capture
                    end
                end
            end
            -- STAMINA only on the LOCAL player's nameplate (allies get health only)
            if selfNameplate and selfNameplate:IsValid() and addrOf(np) == addrOf(selfNameplate) then
                np:SetStaminaMeterVisibility(true)
                showWidget(np, "characterStaminaFill")
            end
        end)
    end)
end

-- arm the settle gate + install hooks once per ClientRestart; drop stale refs so they are
-- re-captured for the new pawn/level. NO native read on the fresh pawn here.
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    transitionAt = os.clock()
    selfNameplate = nil
    hudMeters = nil
    pcall(installHooks)
end)

-- mod restarted mid-map: install immediately if the widget class is already loaded
do
    local wp = StaticFindObject(NP_PLAYER)
    if wp and wp:IsValid() then pcall(installHooks) end
end

print("[ShowNameplates] loaded - players only, event-driven (no polling), MP + perf safe\n")
