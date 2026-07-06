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
local lastDrivenHp, lastDrivenStam = nil, nil -- diag: track driven values to see if they move
local captureMissLogged = false -- one-shot diag: self-capture ran but addr didn't match

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
local lastHudScan = 0.0   -- throttle the resolveHUD 135k-object scan (game-thread, per-frame reachable)
local lastVisDrive = 0.0  -- throttle driveSelf() calls from the per-frame ShouldBeVisible eval
local function resolveHUD()
    if hudMeters and hudMeters:IsValid() then return true end
    hudMeters = nil
    -- THROTTLE the 135k-object scan: resolveHUD is reachable from the per-frame ShouldBeVisible
    -- eval, so when the HUD can't resolve (the both-bars gate below fails during a transition) an
    -- unthrottled FindAllOf every frame ON THE GAME THREAD = hard freeze. cap to ~2x/sec; between
    -- scans report "unresolved" so the caller just skips driving this frame.
    if (os.clock() - lastHudScan) < 0.5 then return false end
    lastHudScan = os.clock()
    for _, e in pairs(FindAllOf("HUD_PlayerMeters_C") or {}) do
        local ok, valid = pcall(function()
            if e:GetFName():ToString():sub(1, 9) == "Default__" then return false end -- skip CDO
            -- require BOTH bars valid (not just shield) so a stale/unpopulated HUD instance
            -- (whose .Percent defaults to 1.0) can't get picked and peg self HP full.
            return e.PlayerShieldBar and e.PlayerShieldBar:IsValid()
                and e.PlayerHealthBar and e.PlayerHealthBar:IsValid()
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
    -- read HEALTH+SHIELD independently from STAMINA. stamina lives on a SEPARATE widget
    -- (HUD_PlayerStaminaMeters.PlayerStaminaMeter) that can be nil - reading all three in ONE
    -- pcall meant a nil stamina widget threw and killed the health/shield update too (the
    -- HP-stuck-full + stamina-blank bug). each sub-widget is guarded on its own now.
    local okHS, shieldP, healthP = pcall(function()
        local hb = hudMeters.PlayerHealthBar
        local sb = hudMeters.PlayerShieldBar
        local h = (hb and hb:IsValid()) and hb.Percent or nil
        local s = (sb and sb:IsValid()) and sb.Percent or nil
        return s, h
    end)
    if okHS and healthP then
        setPct(np, "PlayerHealthBar",     healthP) -- primary fill
        setPct(np, "PlayerLastHealthBar", healthP) -- damage trail
        showWidget(np, "PlayerHealthBar")
        showWidget(np, "PlayerLastHealthBar")
    end
    if okHS and shieldP then
        setPct(np, "PlayerHealthBar_Additive", shieldP) -- shield overlay
        showWidget(np, "PlayerHealthBar_Additive")
    end
    local okS, staminaP = pcall(function()
        local sm = hudMeters.HUD_PlayerStaminaMeters
        sm = sm and sm.PlayerStaminaMeter
        return (sm and sm:IsValid()) and sm.Percent or nil
    end)
    if okS and staminaP then
        setPct(np, "characterStaminaFill", staminaP) -- stamina fill
        showWidget(np, "characterStaminaFill")
    end
    -- diag: log whenever the driven hp/stam CHANGES (>2%) so we can see if the value TRACKS
    -- vs is stuck-full (the MP-host bug). change-throttled, not spammy.
    if healthP and (math.abs(healthP - (lastDrivenHp or -1)) > 0.02
                 or math.abs((staminaP or 0) - (lastDrivenStam or -1)) > 0.02) then
        lastDrivenHp = healthP; lastDrivenStam = staminaP or 0
        print(string.format("[ShowNameplates] drive: hp=%.2f shield=%.2f stam=%.2f\n", healthP or -1, shieldP or -1, staminaP or -1))
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
            -- NB: SetHealthMeterVisibility/SetStaminaMeterVisibility do NOT exist on this widget
            -- (verified: 0 in the object dump) - calling them THREW and aborted this whole
            -- callback before the capture ran (why self was never captured -> stuck-full HP).
            -- raw showWidget (SetVisibility 0) is the real reveal.
            showWidget(np, "PlayerHealthBar")
            showWidget(np, "PlayerLastHealthBar")
            showWidget(np, "PlayerHealthBar_Additive")
            -- capture the LOCAL nameplate once
            if not (selfNameplate and selfNameplate:IsValid()) then
                local owner = np.AttachedOwnerActor
                -- LOCAL player's pawn via UMG's own GetOwningPlayerPawn (the UI is owned by the
                -- local player) - NO require("UEHelpers") dependency, which was FAILING here so
                -- the address never matched and self was never captured -> stuck-full HP / no
                -- stamina. fall back to localPawn() if the getter returns nil.
                local lp = nil
                pcall(function() lp = np:GetOwningPlayerPawn() end)
                if not (lp and lp:IsValid()) then lp = localPawn() end
                if owner and owner:IsValid() and lp and lp:IsValid() and addrOf(owner) == addrOf(lp) then
                    selfNameplate = np
                    print("[ShowNameplates] self nameplate captured\n")
                    driveSelf() -- populate immediately on capture
                elseif not captureMissLogged then
                    captureMissLogged = true
                    print(string.format("[ShowNameplates] capture miss: owner=%s lp=%s\n",
                        tostring(owner and addrOf(owner)), tostring(lp and addrOf(lp))))
                end
            end
            -- STAMINA only on the LOCAL player's nameplate (allies get health only)
            if selfNameplate and selfNameplate:IsValid() and addrOf(np) == addrOf(selfNameplate) then
                showWidget(np, "characterStaminaFill")
                -- ShouldBeVisible fires EVERY frame; throttle the refresh to ~10x/sec so an
                -- unresolved HUD can't drive a per-frame resolveHUD scan (freeze guard).
                if (os.clock() - lastVisDrive) > 0.1 then lastVisDrive = os.clock(); driveSelf() end
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

-- TEARDOWN GUARD (crash-on-close / return-to-menu): only ClientRestart armed the settle gate,
-- so on close the HUD change-hooks (-> driveSelf) + ShouldBeVisible ran against tearing-down
-- widgets. arm settling + drop the cached refs so every callback (all gate on settling()) bails.
-- sets only Lua state = itself crash-safe.
local function npTeardown()
    transitionAt = os.clock()
    selfNameplate = nil
    hudMeters = nil
end
RegisterHook("/Script/Engine.PlayerController:ClientReturnToMainMenu", npTeardown)
RegisterHook("/Script/Engine.PlayerController:ClientGameEnded", npTeardown)

-- mod restarted mid-map: install immediately if the widget class is already loaded
do
    local wp = StaticFindObject(NP_PLAYER)
    if wp and wp:IsValid() then pcall(installHooks) end
end

-- LIFECYCLE RAIL: the game swaps the local pawn on EVERY instance change (dungeon / other
-- instance / death / fall-out-of-map / hub) and MOST do NOT fire ClientRestart - so the cached
-- self-nameplate + HUD-meter refs would keep pointing at the OLD instance (the "HP stuck full /
-- stamina blank after a zone change" bug). cheap 300ms poll of the local pawn ADDRESS (a pointer
-- read, NOT the per-frame object scan that was the old fps killer): any change - or a cached ref
-- going invalid - arms the settle gate + drops the caches so ShouldBeVisible/driveSelf re-capture
-- cleanly for the new pawn. degrades safely: if localPawn() can't resolve, the stale-ref check
-- still drops caches the moment they go invalid.
local npLastPawnAddr = nil
LoopAsync(300, function()
    -- GAME-THREAD WRAP: reading pawn/widget UObjects off the async loop thread can race the
    -- game thread mid-transition (torn read -> AV). all native reads go through
    -- ExecuteInGameThread, same as the WFQoL loops. the poll itself only sets Lua state.
    ExecuteInGameThread(function()
        pcall(function()
            local p = localPawn()
            local pa = p and addrOf(p) or nil
            local staleRef = (selfNameplate and not selfNameplate:IsValid())
                          or (hudMeters and not hudMeters:IsValid())
            if pa ~= npLastPawnAddr or staleRef then
                npLastPawnAddr = pa
                transitionAt = os.clock()
                selfNameplate = nil
                hudMeters = nil
                captureMissLogged = false
                svbLogged = false
            end
        end)
    end)
    return false
end)

print("[ShowNameplates] loaded - players only, event-driven + 300ms lifecycle poll, MP + perf safe\n")
