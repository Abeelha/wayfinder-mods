-- ShowNameplates - forces the player's own nameplate visible and mirrors the HUD
-- health/shield/stamina meters onto it. Patched (WFQoL): hooks now install ONCE
-- (the old main() re-ran every ClientRestart -> stacked hooks + stale closures
-- wrote wrong values, and spammed "Was unable to register a hook"); the primary
-- health fill is now driven (old code only set the damage-trail bar, so self life
-- read wrong); a one-shot diag logs which nameplate bars actually exist.

local function OverrideReturn(UFunctionName, ReturnValue, Callback)
    Callback = Callback or function() end
    return RegisterHook(UFunctionName, function(...) Callback(...); return ReturnValue end)
end

local NP_ENEMY  = "/Game/UI/UI_WF_Blueprints/UI_WF_HUD/UI_NameplateWidget_Enemy.UI_NameplateWidget_Enemy_C"
local NP_PLAYER = "/Game/UI/UI_WF_Blueprints/UI_WF_HUD/UI_NameplateWidget_Player.UI_NameplateWidget_Player_C"

local playerNameplate = nil    -- current player's nameplate widget
local hudMeters       = nil    -- source HUD meters (health/shield/stamina)
local currentPlayer   = nil    -- player pawn, refreshed on each ClientRestart
local hooksInstalled  = false  -- register the UFunction hooks exactly once

-- one-shot: log which candidate bars exist on the real widget so the value
-- mapping can be trimmed to the correct names next pass.
local diagDone = false
local function diagBars(np)
    if diagDone then return end
    diagDone = true
    for _, name in ipairs({
        "PlayerHealthBar", "PlayerHealthBar_Additive", "PlayerLastHealthBar",
        "characterHealthFill", "characterStaminaFill", "PlayerStaminaBar",
    }) do
        local ok, present = pcall(function() return np[name] ~= nil and np[name]:IsValid() end)
        print(string.format("[ShowNameplates] bar '%s' present=%s\n", name, tostring(ok and present)))
    end
end

-- (re)find the HUD meters widget; cached until it goes invalid (level change)
local function resolveHUD()
    if hudMeters and hudMeters:IsValid() then return true end
    hudMeters = nil
    for _, entry in pairs(FindAllOf("HUD_PlayerMeters_C") or {}) do
        local ok, valid = pcall(function() return entry.PlayerShieldBar and entry.PlayerShieldBar:IsValid() end)
        if ok and valid then hudMeters = entry break end
    end
    return hudMeters ~= nil and hudMeters:IsValid()
end

-- set a bar by name if it exists on the widget (wrong names no-op via pcall)
local function setPct(np, name, pct)
    pcall(function()
        local bar = np[name]
        if bar and bar:IsValid() then bar:SetPercent(pct) end
    end)
end

local function updateNameplate()
    if not playerNameplate or not playerNameplate:IsValid() then return end
    if not resolveHUD() then return end
    local ok, shieldPct, healthPct, staminaPct = pcall(function()
        return hudMeters.PlayerShieldBar.Percent,
               hudMeters.PlayerHealthBar.Percent,
               hudMeters.HUD_PlayerStaminaMeters.PlayerStaminaMeter.Percent
    end)
    if not ok then return end
    diagBars(playerNameplate)
    -- health -> primary fill + trail bar (whichever the widget actually has);
    -- shield -> additive overlay; stamina -> its fill
    setPct(playerNameplate, "PlayerHealthBar",          healthPct)
    setPct(playerNameplate, "characterHealthFill",      healthPct)
    setPct(playerNameplate, "PlayerLastHealthBar",      healthPct)
    setPct(playerNameplate, "PlayerHealthBar_Additive", shieldPct)
    setPct(playerNameplate, "characterStaminaFill",     staminaPct)
end

local function installHooks()
    if hooksInstalled then return end
    hooksInstalled = true
    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerMeters.HUD_PlayerMeters_C:UpdateShieldBar", updateNameplate)
    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerMeters.HUD_PlayerMeters_C:OnHealthChanged", updateNameplate)
    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerStaminaMeters.HUD_PlayerStaminaMeters_C:OnStaminaChanged", updateNameplate)

    OverrideReturn(NP_ENEMY .. ":ShouldBeVisible", true)
    OverrideReturn(NP_PLAYER .. ":ShouldBeVisible", true, function(self)
        local np = self:get()
        local ok, mine = pcall(function()
            return currentPlayer and currentPlayer:IsValid()
               and np.AttachedOwnerActor:GetAddress() == currentPlayer:GetAddress()
        end)
        if not (ok and mine) then return end
        if not playerNameplate or not playerNameplate:IsValid() then
            playerNameplate = np
            pcall(function() np.richNameText:SetText(FText("")) end)  -- hide player name
            pcall(function() np:SetStaminaMeterVisibility(true) end)  -- show stamina meter
            updateNameplate()
        end
    end)
end

-- refresh the player + widget refs; the widget is rebuilt per level so drop the
-- cached nameplate and let ShouldBeVisible re-capture it for the new pawn
local function onRestart(pawn)
    currentPlayer   = pawn
    playerNameplate = nil
    hudMeters       = nil
    installHooks()
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self, NewPawn)
    local ok, p = pcall(function() return NewPawn:get() end)
    if ok and p then pcall(function() onRestart(p) end) end
end)

-- mod restarted mid-map: bind immediately if the widget class is already loaded
do
    local wp = StaticFindObject(NP_PLAYER)
    if wp and wp:IsValid() then
        local ok, player = pcall(function()
            local UEHelpers = require("UEHelpers")
            return UEHelpers:GetPlayerController().Pawn
        end)
        if ok and player then onRestart(player) end
    end
end
