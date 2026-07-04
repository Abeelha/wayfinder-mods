-- AutoChain: hold M1 to auto-chain melee attacks. F7 toggles.
-- Works by re-firing the character's own Attack1 input event while M1 is held,
-- so the game's input buffer + combo windows drive the chain exactly like mashing.

local ENABLED = true
local held = false
local injecting = false
local pawnRef = nil
local sendRelease = false

local CHAR = "/Game/Blueprints/Main/WFPlayerCharacter_Base.WFPlayerCharacter_Base_C"
local PRESS_FN = "InpActEvt_Attack1_K2Node_InputActionEvent_36"   -- verified: fires on press
local RELEASE_FN = "InpActEvt_Attack1_K2Node_InputActionEvent_37" -- verified: fires on release
local LMB = { KeyName = FName("LeftMouseButton") }

local function log(fmt, ...) print(string.format("[AutoChain] " .. fmt .. "\n", ...)) end

local pendingHooks = true
local function registerHooks()
    if not pendingHooks then return end
    local ok1 = pcall(RegisterHook, CHAR .. ":" .. PRESS_FN, function(self)
        if injecting then return end
        held = true
        pawnRef = self:get()
    end)
    local ok2 = pcall(RegisterHook, CHAR .. ":" .. RELEASE_FN, function(self)
        if injecting then return end
        held = false
    end)
    if ok1 and ok2 then
        pendingHooks = false
        log("input hooks registered")
    end
end

registerHooks()
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    registerHooks()
    held = false
end)

LoopAsync(70, function()
    if not (ENABLED and held and not pendingHooks) then return false end
    ExecuteInGameThread(function()
        if not pawnRef or not pawnRef:IsValid() then return end
        injecting = true
        pcall(function()
            if sendRelease then
                pawnRef:InpActEvt_Attack1_K2Node_InputActionEvent_37(LMB)
            else
                pawnRef:InpActEvt_Attack1_K2Node_InputActionEvent_36(LMB)
            end
        end)
        injecting = false
        sendRelease = not sendRelease
    end)
    return false
end)

RegisterKeyBind(Key.F7, function()
    ENABLED = not ENABLED
    held = false
    log("%s", ENABLED and "ON" or "OFF")
end)

log("loaded (F7 toggles, currently ON)")
