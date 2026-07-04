--[[
    WEAPON FILTERS

    Available Properties:
    - belowLevel: targets any weapon with a level equal or below of the provided
        - eg: { belowLevel = 32 }

    - aboveLevel: targets any weapon with a level equal or above of the provided
        - eg: { aboveLevel = 38 }

    - slots: targets any weapon with the provided echo slots
        - eg: { slots = { "Alfa", "Bravo" } }

    Slot Index:
        Alfa = Attack
        Bravo = Guard
        Charlie = Balance
        Delta = Cross
        Echo = Rush
]]

-- Rules to favorite weapons
local weaponFavoriteFilters = {
    { aboveLevel = 38 }
}

-- Rules to junk weapons
local weaponJunkFilters = {}


--[[
    ACCESSORY FILTERS

    Available Properties:
    - belowLevel: targets any accessory with a level equal or below of the provided
        - eg: { belowLevel = 32 }

    - aboveLevel: targets any accessory with a level equal or above of the provided
        - eg: { aboveLevel = 38 }

    - slots: targets any accessory with the provided echo slots
        - eg: { slots = { "Alfa", "Bravo" } }

    Slot Index:
        Alfa = Attack
        Bravo = Guard
        Charlie = Balance
        Delta = Cross
        Echo = Rush
]]

-- Rules to favorite accessories
local accessoryJunkFilters = {}

-- Rules to junk accessories
local accessoryFavoriteFilters = {}


--[[
    ECHO FILTERS

    Available Properties:
    - belowLevel: targets any echo with a level equal or below of the provided
        - eg: { belowLevel = 32 }

    - aboveLevel: targets any echo with a level equal or above of the provided
        - eg: { aboveLevel = 38 }

    - rarity: targets any echo with the provided rarities
        - eg: { rarity = { 1, 3 } }

    - upgraded: targets any echo that has been upgraded
        - eg: { upgraded = true }

    Rarity Index:
        1 = Common
        2 = Uncommon
        3 = Rare
        4 = Epic
]]

-- Junks any weapon below level 30 (inclusive) or with an Alpha slot
local echoJunkFilters = {}

-- Favorites any weapon with level 35+
local echoFavoriteFilters = {}



return {
    weaponJunkFilters = weaponJunkFilters,
    weaponFavoriteFilters = weaponFavoriteFilters,
    accessoryJunkFilters = accessoryJunkFilters,
    accessoryFavoriteFilters = accessoryFavoriteFilters,
    echoJunkFilters = echoJunkFilters,
    echoFavoriteFilters = echoFavoriteFilters,
}
