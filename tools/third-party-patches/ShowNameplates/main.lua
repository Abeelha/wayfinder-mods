-- ShowNameplates - forces the player's own nameplate visible and mirrors the HUD
-- health/shield/stamina meters onto it. Patched (WFQoL): hooks install ONCE (the
-- old main() re-ran every ClientRestart -> stacked hooks + stale closures wrote
-- wrong values, and spammed "Was unable to register a hook"); the primary health
-- fill (PlayerHealthBar) is now driven - the old code only set the damage-trail
-- bar so self life read wrong. Bar names confirmed present via a one-shot probe:
-- PlayerHealthBar (main), PlayerHealthBar_Additive (shield), PlayerLastHealthBar
-- (trail), characterStaminaFill (stamina).

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
local enemySeen       = {}     -- enemy owner class names logged once (find bosses)

-- (re)find the HUD meters widget; cached until it goes invalid (level change)
local function resolveHUD()
    if hudMeters and hudMeters:IsValid() then return true end
    hudMeters = nil
    for _, entry in pairs(FindAllOf("HUD_PlayerMeters_C") or {}) do
        -- skip the class default object (CDO); it has no real bars
        local ok, valid = pcall(function()
            if entry:GetFName():ToString():sub(1, 9) == "Default__" then return false end
            return entry.PlayerShieldBar and entry.PlayerShieldBar:IsValid()
        end)
        if ok and valid then hudMeters = entry break end
    end
    return hudMeters ~= nil and hudMeters:IsValid()
end

-- set a bar by name if it exists on the widget (missing names no-op via pcall)
local function setPct(np, name, pct)
    pcall(function()
        local bar = np[name]
        if bar and bar:IsValid() then bar:SetPercent(pct) end
    end)
end

-- force a sub-widget visible (ESlateVisibility: 0 = Visible). the player's OWN
-- nameplate hides its health bars by default (only other players' show HP) - so
-- self showed stamina but no HP. re-assert visible so self HP shows too.
local function showWidget(np, name)
    pcall(function()
        local w = np[name]
        if w and w:IsValid() then w:SetVisibility(0) end
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
    setPct(playerNameplate, "PlayerHealthBar",          healthPct)  -- primary fill
    setPct(playerNameplate, "PlayerLastHealthBar",      healthPct)  -- damage trail
    setPct(playerNameplate, "PlayerHealthBar_Additive", shieldPct)  -- shield overlay
    setPct(playerNameplate, "characterStaminaFill",     staminaPct) -- stamina fill
    -- keep the self health bars visible (game re-hides them on the local player)
    showWidget(playerNameplate, "PlayerHealthBar")
    showWidget(playerNameplate, "PlayerLastHealthBar")
    showWidget(playerNameplate, "PlayerHealthBar_Additive")
end

local function installHooks()
    if hooksInstalled then return end
    hooksInstalled = true
    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerMeters.HUD_PlayerMeters_C:UpdateShieldBar", updateNameplate)
    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerMeters.HUD_PlayerMeters_C:OnHealthChanged", updateNameplate)
    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerStaminaMeters.HUD_PlayerStaminaMeters_C:OnStaminaChanged", updateNameplate)

    -- force normal enemy nameplates visible, but HIDE the boss's small nameplate:
    -- forcing it on conflicts with the boss's dedicated health bar. detect boss by
    -- owner class name (logged once each so the match can be made precise). returns
    -- true for normal enemies, false for bosses (their big boss bar shows health).
    RegisterHook(NP_ENEMY .. ":ShouldBeVisible", function(self)
        local show = true
        pcall(function()
            local np = self:get()
            if not (np and np:IsValid()) then return end
            local owner = np.AttachedOwnerActor
            if not (owner and owner:IsValid()) then return end
            local cn = owner:GetClass():GetFName():ToString()
            if not enemySeen[cn] then enemySeen[cn] = true; print("[ShowNameplates] enemy owner " .. cn .. "\n") end
            if cn:lower():find("boss") then show = false end
        end)
        return show
    end)
    OverrideReturn(NP_PLAYER .. ":ShouldBeVisible", true, function(self)
        local np = self:get()
        local ok, mine = pcall(function()
            -- MULTIPLAYER: this fires for every player nameplate incl remote ones.
            -- a remote/just-spawned nameplate can have a NULL AttachedOwnerActor;
            -- calling :GetAddress() on it is a native null-deref (0x10) that pcall
            -- can't catch. validate np + owner + currentPlayer before touching them.
            if not (np and np:IsValid() and currentPlayer and currentPlayer:IsValid()) then return false end
            local owner = np.AttachedOwnerActor
            if not (owner and owner:IsValid()) then return false end
            return owner:GetAddress() == currentPlayer:GetAddress()
        end)
        if not (ok and mine) then return end
        if not playerNameplate or not playerNameplate:IsValid() then
            playerNameplate = np
            pcall(function() np.richNameText:SetText(FText("")) end)  -- hide player name
            pcall(function() np:SetStaminaMeterVisibility(true) end)  -- show stamina meter
            -- show HEALTH too: no meter-toggle method exists (probed: all false), so
            -- force the health bar widgets visible directly (ESlateVisibility 0).
            showWidget(np, "PlayerHealthBar")
            showWidget(np, "PlayerLastHealthBar")
            showWidget(np, "PlayerHealthBar_Additive")
            updateNameplate()
        end
    end)
end

-- refresh the player + widget refs; the widget is rebuilt per level so drop the
-- cached nameplate and let ShouldBeVisible re-capture it for the new pawn
local function onRestart(pawn)
    installHooks() -- once, regardless of pawn type
    -- co-op downs swap the pawn to BP_Spectator_Pawn_C; binding the self-nameplate
    -- to a spectator/edit pawn shows wrong health ("breaks sometimes"). only track
    -- the real player character - keep the last real one through a down/respawn.
    -- DEFER the class read: reading GetClass() on the RAW ClientRestart pawn hits a
    -- still-constructing pawn whose class ptr is null -> native 0x10 access violation
    -- that pcall CANNOT catch (crash on world load). let it settle, then re-validate.
    ExecuteWithDelay(300, function()
        local ok, cn = pcall(function()
            if not (pawn and pawn:IsValid()) then return nil end
            return pawn:GetClass():GetFName():ToString()
        end)
        if not (ok and cn == "WFPlayerCharacter_Base_C") then return end
        currentPlayer   = pawn
        playerNameplate = nil
        hudMeters       = nil
    end)
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
