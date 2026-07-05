local Rules = require("config")

-- DATA TABLES
local ITEM_TYPES = {
    Weapon = {
        "Inventory/2HScytheItems",
        "Inventory/2HSwordItems",
        "Inventory/AxeItems",
        "Inventory/DWItems",
        "Inventory/MaceItems",
        "Inventory/RifleItems",
        "Inventory/SnSItems",
    },
    Echo = {
        "Inventory/CreatureEchoes/CreatureEchoItems"
    },
    Accessory = {
        "Inventory/Accessories/AccessoryInventoryItems"
    },
    Housing = {}
}

local SLOT_TYPES = {
    [0] = "Invalid",
    [1] = "Alfa",
    [2] = "Bravo",
    [3] = "Charlie",
    [4] = "Delta",
    [5] = "Echo",
    [6] = "ArmorModHead",
    [7] = "ArmorModChest",
    [8] = "ArmorModArms",
    [9] = "ArmorModLegs",
    [10] = "ArmorModFeet",
    [11] = "WeaponCharm",
    [12] = "EFogSoulCategory_MAX"
}

local ECHO_CURVE = {
    [1] = 414,
    [2] = 468,
    [3] = 522,
    [4] = 576,
}

local ECHO_CURVE_INCREMENT = 54

local WEAPON_CURVE = {
    0, 375, 1212, 3029, 5538, 8827, 12981, 18087, 24231, 31500, 39981, 49760, 60923, 72837, 87000, 100215, 114660, 130380, 147420, 165000, 186450, 208800, 232943, 258945, 285938, 317340, 351120, 387368, 426173, 466538, 501742.5,
    539087.4, 576432.3, 613777.2, 651122.1, 688467, 725811.9,
    763156.8
}

local ACCESSORY_CURVE = {
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45
}


-- CONFIG
local debug = false -- WFQoL: off again (auto-sort confirmed; per-item spam added freeze pressure)


-- Text Strings
local Text = {
    noInventory = "InventoryComponent hasn't been loaded yet!",
    flaggingItems = "Smart Sorting Items...",
    flaggedItems = "Items Sorted.",
}

-- FUNCTIONS

function Log(Message, OutputDevice)
    if OutputDevice then
        OutputDevice:Log(string.format("[SmartSort] %s\n", Message))
    else
        if debug then
            print(string.format("[SmartSort] %s\n", Message))
        end
    end
end

function expToLevel(exp, curveObject)
    local levelCurveNumber = 0

    for idx, levelExp in ipairs(curveObject) do
        if levelExp <= exp then
            levelCurveNumber = idx
        else
            break -- Exit the loop once the condition is not met
        end
    end

    return levelCurveNumber
end

function echoExpToLevel(xp, rarity)
    local currentXp = xp
    local initialXp = ECHO_CURVE[rarity]
    local remainingXP = math.max(currentXp - initialXp, 0)
    local firstLevel = currentXp < initialXp and 0 or 1
    local levels = math.ceil(remainingXP / ECHO_CURVE_INCREMENT)
    return 1 + firstLevel + levels
end

-- Check if the string contains any of the table values
function existsInTable(dataString, list)
    for _, item in ipairs(list) do
        if string.find(dataString, item) then
            return true -- Found a match
        end
    end
    return false -- No matches found
end

-- Applies tag to item
function applyTagToItem(PlayerInventoryComponent, itemHandle, flagToAPply)
    local pre0, post0 = RegisterHook(
        "/Script/Wayfinder.PlayerInventoryComponent:SERVER_TryApplyItemFlags",
        function(_, p1)
            local struct = p1:get()

            struct.ID = { A = itemHandle.ID.A, B = itemHandle.ID.B, C = itemHandle.ID.C, D = itemHandle.ID.D }
            struct.Data = {
                RowName = itemHandle.Data.RowName
            }
        end)


    if PlayerInventoryComponent and PlayerInventoryComponent:IsValid() then
        PlayerInventoryComponent:SERVER_TryApplyItemFlags({}, flagToAPply)
    end

    UnregisterHook("/Script/Wayfinder.PlayerInventoryComponent:SERVER_TryApplyItemFlags", pre0, post0)
end

function handleApplyItemFlag(PlayerInventoryComponent, itemEntry, rules, levelCurve, isEcho, flatToApply)
    local itemSpec = itemEntry.Spec;
    local itemFlag = itemSpec.ItemFlags;
    local itemRarity = itemSpec.echoRarity;

    -- Returns immediately if item is set as favorite
    if itemFlag == 2 then
        return true
    end

    local hasTriggeredRule = false;

    for _, rule in ipairs(rules) do
        -- Check rule for belowLevel
        if rule.belowLevel then
            local level = isEcho and echoExpToLevel(itemSpec.CurrentExp, itemRarity) or
                expToLevel(itemSpec.CurrentExp, levelCurve);

            if level <= rule.belowLevel then
                hasTriggeredRule = true
            end
        end

        -- Check rule for aboveLevel
        if rule.aboveLevel then
            local level = isEcho and echoExpToLevel(itemSpec.CurrentExp, itemRarity) or
                expToLevel(itemSpec.CurrentExp, levelCurve);

            if level >= rule.aboveLevel then
                hasTriggeredRule = true
            end
        end

        -- Check rule for slots
        if rule.slots then
            local itemSlots = itemEntry.Spec.m_GeneratedFogSoulSlots

            for i = 1, #itemSlots do
                local hasSlot = existsInTable(SLOT_TYPES[itemSlots[i].Category], rule.slots)
                if hasSlot then
                    hasTriggeredRule = true
                end
            end
        end

        if rule.rarity then
            local hasRarity = existsInTable(itemSpec.echoRarity, rule.rarity)
            if hasRarity then
                hasTriggeredRule = true
            end
        end

        if rule.upgraded and isEcho then
            local cur, start = itemSpec.CurrentExp, itemSpec.StartingExp
            if cur and start and cur > start then -- nil-guarded: field may be absent (was nil>nil error)
                hasTriggeredRule = true
            end
        end
    end

    -- Apply the tag if all condition are true
    -- Also prevent re-applying of current flag
    if hasTriggeredRule and itemFlag ~= flatToApply then
        Log(string.format("applying flag %d (2=fav,1=junk,4=echo-junk)", flatToApply))
        applyTagToItem(PlayerInventoryComponent, itemEntry.Handle, flatToApply)
    end

    return hasTriggeredRule;
end

-- @param PlayerInventoryComponent: UActorComponent
-- @param itemEntry: InventoryItemEntry
function FlagItem(PlayerInventoryComponent, itemEntry)
    local itemType = itemEntry["Handle"]["Data"]["DataTable"]:GetFullName();

    local isWeapon = existsInTable(itemType, ITEM_TYPES.Weapon)
    local isAccessory = existsInTable(itemType, ITEM_TYPES.Accessory)
    local isEcho = existsInTable(itemType, ITEM_TYPES.Echo)

    Log(string.format("FlagItem type=%s weapon=%s acc=%s echo=%s", itemType,
        tostring(isWeapon), tostring(isAccessory), tostring(isEcho)))

    if isWeapon then
        -- Handle Favorite
        local isFavorite = handleApplyItemFlag(PlayerInventoryComponent, itemEntry, Rules.weaponFavoriteFilters,
            WEAPON_CURVE, isEcho, 2)

        if not isFavorite then
            -- Handle Junk
            handleApplyItemFlag(PlayerInventoryComponent, itemEntry, Rules.weaponJunkFilters, WEAPON_CURVE, isEcho, 1)
        end
    elseif isAccessory then
        -- Handle Favorite
        local isFavorite = handleApplyItemFlag(PlayerInventoryComponent, itemEntry, Rules.accessoryFavoriteFilters,
            ACCESSORY_CURVE, isEcho, 2)

        if not isFavorite then
            -- Handle Junk
            handleApplyItemFlag(PlayerInventoryComponent, itemEntry, Rules.accessoryJunkFilters, ACCESSORY_CURVE, isEcho,
                1)
        end
    elseif isEcho then
        local isFavorite = handleApplyItemFlag(PlayerInventoryComponent, itemEntry, Rules.echoFavoriteFilters,
            {}, isEcho, 2)

        if not isFavorite then
            -- Handle Junk
            handleApplyItemFlag(PlayerInventoryComponent, itemEntry, Rules.echoJunkFilters,
                {}, isEcho, 4)
        end
    end
end

function FlagItems(PlayerInventoryComponent)
    local items = PlayerInventoryComponent:GetItemsByTag({
        GameplayTags = {},
        ParentTags = {}
    })

    Log(string.format("ITEM COUNT: %s\n", #items))
    for _, item in ipairs(items) do
        FlagItem(PlayerInventoryComponent, item["Handle"])
    end
end

-- AUTO-SORT-ON-PICKUP DISABLED (WFQoL): the CLIENT_NotifyItemAdded hook judged each item
-- ALONE (per-config junk), so it could not tell a low-level pickup that is a UNIQUE (only
-- copy - must never be junked) from a duplicate, and it junked uniques. all sorting now
-- goes through the overlay SORT button (sortOwnedItems below), which is dupe-aware: it only
-- junks DUPLICATE extras (keeping the best) and never touches a unique. hook not registered.

RegisterConsoleCommandHandler("RunSmartSort", function(FullCommand, Parameters, OutputDevice)
    local PlayerInventoryComponent = FindFirstOf("PlayerInventoryComponent");

    if PlayerInventoryComponent:IsValid() then
        Log(Text.flaggingItems, OutputDevice)
        FlagItems(PlayerInventoryComponent);
        Log(Text.flaggedItems, OutputDevice);
    else
        Log(Text.noInventory, OutputDevice)
    end

    return true
end)

-- ==================== WFQoL: dedup + overlay SORT button ====================
-- BATCHED flag applier. SERVER_TryApplyItemFlags is a server RPC (round-trips to the host
-- in MP); doing hundreds synchronously froze the game (why SmartSort was disabled). the
-- owned-items sort ENQUEUES flag ops and drains a few per tick so the game thread never
-- stalls.
-- teardown guard: on close / return-to-menu, stop touching the freeing inventory. the poll,
-- the queue drain, and sortOwnedItems all check this. hook sets only a Lua flag = crash-safe.
local tearing = false
RegisterHook("/Script/Engine.PlayerController:ClientReturnToMainMenu", function() tearing = true end)
RegisterHook("/Script/Engine.PlayerController:ClientGameEnded", function() tearing = true end)
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function() tearing = false end)

local flagQueue = {}
local flagRunning = false
local function processQueue()
    if flagRunning then return end
    flagRunning = true
    local function step()
        if tearing then flagQueue = {}; flagRunning = false; return end -- world tearing down: drop pending
        local n = 0
        while #flagQueue > 0 and n < 8 do
            local job = table.remove(flagQueue, 1)
            pcall(function() applyTagToItem(job.pic, job.handle, job.flag) end)
            n = n + 1
        end
        if #flagQueue > 0 then
            ExecuteWithDelay(60, step)
        else
            flagRunning = false
            print("[SmartSort] sort complete\n")
        end
    end
    step()
end
local function enqueueFlag(pic, handle, flag)
    table.insert(flagQueue, { pic = pic, handle = handle, flag = flag })
end

-- item helpers (mirror the field access FlagItem/handleApplyItemFlag already use)
local function ss_category(entry)
    local ok, t = pcall(function() return entry["Handle"]["Data"]["DataTable"]:GetFullName() end)
    if not ok then return nil end
    if existsInTable(t, ITEM_TYPES.Weapon) then return "weapon" end
    if existsInTable(t, ITEM_TYPES.Accessory) then return "accessory" end
    if existsInTable(t, ITEM_TYPES.Echo) then return "echo" end
    return nil
end
local function ss_level(entry, cat)
    local spec = entry.Spec
    if cat == "echo" then return echoExpToLevel(spec.CurrentExp, spec.echoRarity) end
    if cat == "weapon" then return expToLevel(spec.CurrentExp, WEAPON_CURVE) end
    return expToLevel(spec.CurrentExp, ACCESSORY_CURVE)
end
local function ss_key(entry)
    local ok, rn = pcall(function() return entry["Handle"]["Data"]["RowName"]:ToString() end)
    return ok and rn or nil
end
-- config junk/favorite rule eval for a UNIQUE item -> flag (2 fav / 1 junk / 4 echo-junk) or nil
local function ss_ruleFlag(entry, cat, lvl)
    local favRules, junkRules, junkFlag
    if cat == "weapon" then favRules = Rules.weaponFavoriteFilters; junkRules = Rules.weaponJunkFilters; junkFlag = 1
    elseif cat == "accessory" then favRules = Rules.accessoryFavoriteFilters; junkRules = Rules.accessoryJunkFilters; junkFlag = 1
    else favRules = Rules.echoFavoriteFilters; junkRules = Rules.echoJunkFilters; junkFlag = 4 end
    local function match(rules)
        for _, rule in ipairs(rules or {}) do
            if rule.belowLevel and lvl <= rule.belowLevel then return true end
            if rule.aboveLevel and lvl >= rule.aboveLevel then return true end
            if rule.rarity then
                local ok, has = pcall(function() return existsInTable(entry.Spec.echoRarity, rule.rarity) end)
                if ok and has then return true end
            end
        end
        return false
    end
    if match(favRules) then return 2 end
    if match(junkRules) then return junkFlag end
    return nil
end

-- SORT OWNED ITEMS (overlay button): idempotent, self-correcting pass over the inventory.
-- for each item it computes the DESIRED mark and applies it only if it DIFFERS from the
-- current one - so re-clicking SORT also CLEARS stale/wrong marks (un-dusts), no manual
-- deselect. MARKS ONLY, never sells. rules:
--   * FAVORITED (flag 2) + equipped items: never touched (respect the player's choice).
--   * UNIQUE (single copy): kept -> desired NONE (clears any stale mark). always >=1 of each.
--   * DUPLICATES: keep exactly ONE - the BEST copy (echoes: highest RARITY then most XP;
--     weapons/accessories: most XP / highest level) -> NONE. DUST every other echo dupe,
--     JUNK every other weapon/accessory dupe, REGARDLESS of rarity (so rare/epic dupes are
--     not hoarded - the single best of each item is kept, the extras marked). the highest
--     rarity/most-upgraded copy is always the keeper, so the good one is never marked.
-- favorites are left entirely to the player (never auto-applied). flag 0 = no flags.
-- pick the REAL populated inventory. FindFirstOf can return the CDO (Default__) or a
-- preview-character inventory - both have 0 items (seen returning "0 items" mid-session).
-- scan all instances, skip the CDO, pick the one whose GetItemsByTag returns the MOST items.
local function findInventory()
    local best, bestN = nil, -1
    for _, c in ipairs(FindAllOf("PlayerInventoryComponent") or {}) do
        local ok, n = pcall(function()
            if not c:IsValid() then return -1 end
            if c:GetFName():ToString():sub(1, 9) == "Default__" then return -1 end
            return #c:GetItemsByTag({ GameplayTags = {}, ParentTags = {} })
        end)
        if ok and n and n > bestN then bestN = n; best = c end
    end
    if best and bestN > 0 then return best, bestN end
    return nil, 0
end

local function sortOwnedItems(pic)
    if tearing or not (pic and pic:IsValid()) then return end
    local items = pic:GetItemsByTag({ GameplayTags = {}, ParentTags = {} })
    local groups = {}
    for _, item in ipairs(items) do
        local entry = item["Handle"]
        pcall(function()
            local cat = ss_category(entry); if not cat then return end
            local key = ss_key(entry); if not key then return end
            local rarity, exp, cur, equipped = 0, 0, 0, false
            pcall(function() rarity = entry.Spec.echoRarity or 0 end)
            pcall(function() exp = entry.Spec.CurrentExp or 0 end)
            pcall(function() cur = entry.Spec.ItemFlags or 0 end)
            -- EQUIPPED (on THIS or ANY character): InventoryItemSpec.EquippedToSlotName is the
            -- real field (no bEquipped/Equipped bool exists - the old read was always false).
            -- set to a slot name when equipped anywhere, "None"/empty otherwise. the game blocks
            -- selling equipped items (incl. equipped on another char) server-side, so we must
            -- NOT mark them - skip = respect it, and stop re-enqueuing marks the game rejects.
            pcall(function()
                local sn = entry.Spec.EquippedToSlotName
                local s = sn and sn:ToString() or "None"
                equipped = (s ~= "None" and s ~= "")
            end)
            groups[key] = groups[key] or {}
            table.insert(groups[key], { entry = entry, cat = cat, rarity = rarity, exp = exp, cur = cur, equipped = equipped })
        end)
    end
    local marked, cleared = 0, 0
    local function want(it, desired)
        if it.cur == 2 or it.equipped then return end -- never override a favorite / equipped item
        if desired == it.cur then return end          -- already correct -> nothing to do
        enqueueFlag(pic, it.entry.Handle, desired)
        if desired == 0 then cleared = cleared + 1 else marked = marked + 1 end
    end
    for key, list in pairs(groups) do
        if #list == 1 then
            want(list[1], 0) -- UNIQUE: keep, clear any stale mark
        else
            -- keeper = best copy: echoes rank by RARITY then XP; others by XP (level/upgrade)
            local keepIdx, bR, bE = 1, -1, -1
            for i, it in ipairs(list) do
                local better
                if it.cat == "echo" then
                    better = (it.rarity > bR) or (it.rarity == bR and it.exp > bE)
                else
                    better = (it.exp > bE)
                end
                if better then bR = it.rarity; bE = it.exp; keepIdx = i end
            end
            -- diag: reveals WHY a dupe wasn't marked - flag=2 (favorite) or eq=true (equipped)
            -- both block marking; a dupe you expected here showing up as a lone group instead
            -- means it has a different RowName (not grouped). one line per dupe group.
            local dbg = {}
            for i, it in ipairs(list) do
                dbg[#dbg + 1] = string.format("[%d exp=%d flag=%d eq=%s%s]",
                    i, it.exp, it.cur, tostring(it.equipped), i == keepIdx and " KEEP" or "")
            end
            print(string.format("[SmartSort] group '%s' n=%d %s\n", key, #list, table.concat(dbg, " ")))
            for i, it in ipairs(list) do
                if i == keepIdx then want(it, 0)             -- keeper: keep
                elseif it.cat == "echo" then want(it, 4)     -- dust every other echo dupe
                else want(it, 1) end                         -- junk every other weapon/accessory dupe
            end
        end
    end
    print(string.format("[SmartSort] SORT: %d items, %d marked, %d cleared\n", #items, marked, cleared))
    processQueue()
end

-- overlay command channel: the WFQoL overlay's SORT button writes smartsort-cmd.json {seq};
-- on a NEW seq, run the owned-items sort. low-freq poll of a tiny file (no object scan).
local SS_CMD_REL = "Mods/SmartSort/smartsort-cmd.json"
local SS_CMD_ABS = "D:/SteamLibrary/steamapps/common/Wayfinder/Atlas/Binaries/Win64/Mods/SmartSort/smartsort-cmd.json"
local lastSortSeq = nil
LoopAsync(500, function()
    pcall(function()
        if tearing then return end -- don't launch a sort into a tearing-down world
        local f = io.open(SS_CMD_REL, "r") or io.open(SS_CMD_ABS, "r")
        if not f then return end
        local raw = f:read("*a"); f:close()
        local seq = raw:match('"seq"%s*:%s*(%d+)')
        if not seq then return end
        if lastSortSeq == nil then lastSortSeq = seq; return end -- ignore the stale seq at load
        if seq ~= lastSortSeq then
            lastSortSeq = seq
            print("[SmartSort] overlay SORT clicked - sorting owned items...\n")
            local pic, n = findInventory()
            if pic then pcall(function() sortOwnedItems(pic) end)
            else print("[SmartSort] SORT: no populated inventory found (0 items) - open inventory then retry\n") end
        end
    end)
    return false
end)
