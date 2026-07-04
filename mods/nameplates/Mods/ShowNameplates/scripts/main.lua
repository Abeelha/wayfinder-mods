local function OverrideReturn(UFunctionName, ReturnValue, Callback)
    Callback = Callback or function() end
    return RegisterHook(UFunctionName, function(...) Callback(...); return ReturnValue end)
end

---@param Player AWFPlayerCharacter_Base_C
local function main(Player)
    local playerNameplate ---@type UUI_NameplateWidget_Player_C
    -- print(string.format("Player %s", Player:GetFullName()))

    local HUD_PlayerMeters_C ---@type UHUD_PlayerMeters_C
    local function updateNameplate()
        if not playerNameplate or not playerNameplate:IsValid() then return end
        if not HUD_PlayerMeters_C or not HUD_PlayerMeters_C:IsValid() then
            for _, entry in pairs(FindAllOf("HUD_PlayerMeters_C") or {}) do
                if entry.PlayerShieldBar and entry.PlayerShieldBar:IsValid() then --#TODO: better check
                    HUD_PlayerMeters_C = entry
                    break
                end
            end
            if not HUD_PlayerMeters_C or not HUD_PlayerMeters_C:IsValid() then return end
        end

        local shieldPct = HUD_PlayerMeters_C.PlayerShieldBar.Percent
        local healthPct = HUD_PlayerMeters_C.PlayerHealthBar.Percent
        local staminaPct = HUD_PlayerMeters_C.HUD_PlayerStaminaMeters.PlayerStaminaMeter.Percent

        playerNameplate.PlayerHealthBar_Additive:SetPercent(shieldPct) --Use as shield bar
        playerNameplate.PlayerLastHealthBar:SetPercent(healthPct)
        playerNameplate.characterStaminaFill:SetPercent(staminaPct)
    end

    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerMeters.HUD_PlayerMeters_C:UpdateShieldBar", updateNameplate)
    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerMeters.HUD_PlayerMeters_C:OnHealthChanged", updateNameplate)
    RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerStaminaMeters.HUD_PlayerStaminaMeters_C:OnStaminaChanged", updateNameplate)

    OverrideReturn("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/UI_NameplateWidget_Enemy.UI_NameplateWidget_Enemy_C:ShouldBeVisible", true)
    OverrideReturn("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/UI_NameplateWidget_Player.UI_NameplateWidget_Player_C:ShouldBeVisible", true, function(self)
        local UI_NameplateWidget_Player_C = self:get() ---@type UUI_NameplateWidget_Player_C
        if UI_NameplateWidget_Player_C.AttachedOwnerActor:GetAddress() ~= Player:GetAddress() then return end

        if not playerNameplate or not playerNameplate:IsValid() then --run only once
            playerNameplate = UI_NameplateWidget_Player_C
            UI_NameplateWidget_Player_C.richNameText:SetText(FText("")) --Hide player name
            UI_NameplateWidget_Player_C:SetStaminaMeterVisibility(true) --Show stamina
            updateNameplate()
        end
    end)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self, NewPawn) main(NewPawn:get()) end)
local UI_NameplateWidget_Player_C = StaticFindObject("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/UI_NameplateWidget_Player.UI_NameplateWidget_Player_C")
if UI_NameplateWidget_Player_C:IsValid() then
    local UEHelpers = require("UEHelpers")
    local Player = UEHelpers:GetPlayerController().Pawn
    main(Player)
end
