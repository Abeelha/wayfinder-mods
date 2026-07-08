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
local lastDrivenHp, lastDrivenStam = nil, nil -- diag: track driven values to see if they move
local lastDriveLog = 0.0 -- min interval between drive diag lines
local selfAddr = nil     -- address of the captured self nameplate (cheap identity compare)

-- safe pointer read (address value only, no object-internal deref -> safe on any owner)
local function addrOf(o)
    local ok, a = pcall(function() return o:GetAddress() end)
    return ok and a or nil
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
local driving = false  -- re-entrancy guard: teardown fires the meter hooks in a nested cascade
                       -- (crash stack showed 3x re-entry on dungeon-leave); a nested driveSelf must
                       -- NOT run against the half-freed HUD.
local function driveSelf()
    if driving or settling() then return end
    local np = selfNameplate
    if not (np and np:IsValid()) then return end
    -- teardown safety is settling(), armed SECONDS early by the travel-request hooks below (cause-side
    -- signal) + the HUD Destruct hooks. NO game-native liveness probes here: IsValid() (UE4SS-side
    -- flag read) is the only probe used; native calls on a dying object AV through pcall.
    driving = true
    pcall(function()
        if not resolveHUD() then return end
        -- read HEALTH+SHIELD independently from STAMINA. stamina lives on a SEPARATE widget
        -- (HUD_PlayerStaminaMeters.PlayerStaminaMeter) that can be nil - reading all three in ONE
        -- pcall meant a nil stamina widget threw and killed the health/shield update too (the
        -- HP-stuck-full + stamina-blank bug). each sub-widget is guarded on its own now. re-check
        -- hudMeters:IsValid() immediately before the field deref = smallest possible use-after-free
        -- window if the HUD frees mid-callback during a transition.
        local okHS, shieldP, healthP = pcall(function()
            if not (hudMeters and hudMeters:IsValid()) then return nil, nil end
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
            if not (hudMeters and hudMeters:IsValid()) then return nil end
            local sm = hudMeters.HUD_PlayerStaminaMeters
            sm = sm and sm.PlayerStaminaMeter
            return (sm and sm:IsValid()) and sm.Percent or nil
        end)
        if okS and staminaP then
            setPct(np, "characterStaminaFill", staminaP) -- stamina fill
            showWidget(np, "characterStaminaFill")
        end
        -- diag: >5% change AND >=1s apart. the old >2%-only version printed on every stamina tick
        -- = hundreds of print() I/O lines per minute ON THE GAME THREAD (perf smell, log noise).
        local now = os.clock()
        if healthP and (now - lastDriveLog) >= 1.0
           and (math.abs(healthP - (lastDrivenHp or -1)) > 0.05
             or math.abs((staminaP or 0) - (lastDrivenStam or -1)) > 0.05) then
            lastDrivenHp = healthP; lastDrivenStam = staminaP or 0; lastDriveLog = now
            print(string.format("[ShowNameplates] drive: hp=%.2f shield=%.2f stam=%.2f\n", healthP or -1, shieldP or -1, staminaP or -1))
        end
    end)
    driving = false
end

local npTeardown -- forward-declared: defined below, referenced by installHooks (Destruct hooks)
local destructHooked = false
local function installHooks()
    -- HUD Destruct = the moment the HUD widget actually dies (any transition kind). registered HERE
    -- (ClientRestart, classes loaded) because a boot-time attempt silently failed in pcall (class not
    -- loaded yet) - the guard never existed. retried until it lands, then flagged.
    if not destructHooked then
        destructHooked = pcall(function()
            RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerMeters.HUD_PlayerMeters_C:Destruct", npTeardown)
            RegisterHook("/Game/UI/UI_WF_Blueprints/UI_WF_HUD/HUD_PlayerStaminaMeters.HUD_PlayerStaminaMeters_C:Destruct", npTeardown)
        end)
        if destructHooked then print("[ShowNameplates] HUD Destruct teardown hooks registered\n") end
    end
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
            -- SELF-HEALING CAPTURE: identity = "is this widget's owner the pawn *I* control?"
            -- owner:IsLocallyControlled() is safe HERE because the game is actively evaluating this
            -- LIVE widget this frame (owner alive by construction); remote teammates return false.
            -- capture REPLACES the cache whenever a *different* local nameplate shows up - death
            -- respawn / instance change / MP rejoin all spawn a NEW widget, whose ShouldBeVisible
            -- fires, and we re-capture instantly. the old code captured ONCE and skipped while the
            -- stale cache was still IsValid (valid != visible) -> bars gone until relog. also gone:
            -- the addr-compare against GetOwningPlayerPawn/localPawn (localPawn was ALWAYS nil in
            -- this game, and nil==nil could mis-capture an ally plate in MP).
            local npAddr = addrOf(np)
            if npAddr ~= selfAddr then
                local owner = np.AttachedOwnerActor
                local isMine = false
                if owner and owner:IsValid() then
                    pcall(function() isMine = owner:IsLocallyControlled() == true end)
                end
                if isMine then
                    selfNameplate = np
                    selfAddr = npAddr
                    print("[ShowNameplates] self nameplate captured\n")
                    driveSelf() -- populate immediately on capture
                end
            end
            -- STAMINA only on the LOCAL player's nameplate (allies get health only)
            if npAddr and npAddr == selfAddr then
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
    selfAddr = nil
    hudMeters = nil
    pcall(installHooks)
end)

-- TEARDOWN GUARD (crash-on-close / return-to-menu): only ClientRestart armed the settle gate,
-- so on close the HUD change-hooks (-> driveSelf) + ShouldBeVisible ran against tearing-down
-- widgets. arm settling + drop the cached refs so every callback (all gate on settling()) bails.
-- sets only Lua state = itself crash-safe.
npTeardown = function()
    -- EXTENDED hold: travel request fires seconds before CleanupWorld frees the HUD widgets; keep
    -- settling() true ~6s from the arm (SETTLE_SECS 1.5 alone expired before the world actually died).
    -- ClientRestart / the rail re-arm a normal window when the new world signals in.
    transitionAt = os.clock() + 4.5
    selfNameplate = nil
    selfAddr = nil
    hudMeters = nil
end
RegisterHook("/Script/Engine.PlayerController:ClientReturnToMainMenu", npTeardown)
RegisterHook("/Script/Engine.PlayerController:ClientGameEnded", npTeardown)
-- TRAVEL-REQUEST TEARDOWN ARM (cause-side, seconds before CleanupWorld). same verified UFunction
-- family as WFQoL. NOTE the HUD Destruct hooks are registered in installHooks() (ClientRestart),
-- NOT here: at boot the BP widget classes aren't loaded yet, so a boot-time RegisterHook silently
-- failed inside pcall and the Destruct guard NEVER actually existed (found via boot-log audit).
for _, fn in ipairs({
    "/Script/Wayfinder.WFPlayerTravelComponent:RequestMainMenuTravel",
    "/Script/Wayfinder.WFPlayerTravelComponent:ReturnFromExpedition",
    "/Script/Wayfinder.WFPlayerTravelComponent:PerformGeneratedLevelTravel",
    "/Script/Wayfinder.WFPlayerTravelComponent:RequestTravel",
    "/Script/Wayfinder.WFPlayerTravelComponent:RequestTravelSimple",
    "/Script/Wayfinder.WFPlayerTravelComponent:RequestTravelWithNextUnlock",
    "/Script/Wayfinder.WFPlayerTravelComponent:SERVER_ConfirmTravel",
    "/Script/Wayfinder.WFPlayerTravelComponent:CLIENT_InternalRequestTravel",
    "/Script/Wayfinder.WFPlayerTravelComponent:PerformServerTravelDelayedHelper",
    "/Script/Wayfinder.WFPlayerController:CLIENT_HandleInteractWithTravelRegion",
}) do
    pcall(function() RegisterHook(fn, npTeardown) end)
end

-- mod restarted mid-map: install immediately if the widget class is already loaded
do
    local wp = StaticFindObject(NP_PLAYER)
    if wp and wp:IsValid() then pcall(installHooks) end
end

-- NO lifecycle rail anymore (deleted, deliberately): its pawn-address branch was 100% dead
-- (localPawn()/UEHelpers is ALWAYS nil in this game -> the address never changed), and its only
-- live effect was arming a 1.5s settle pause every time the self widget got recycled = the
-- "self nameplate captured" churn + frozen bars every 1-2 min. capture is now SELF-HEALING at
-- ShouldBeVisible time (fires per-frame on live widgets - the correct lifecycle signal), and
-- driveSelf/resolveHUD re-validate their caches on every call.

print("[ShowNameplates] loaded - players only, event-driven, self-healing capture, MP + perf safe\n")
