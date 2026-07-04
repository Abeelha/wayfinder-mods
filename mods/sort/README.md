# Smart Sort

This mod will automatically mark as `favorite` or `for sell (junk)` existent and new items based on provided rules, so its easier to sell/dust them.

Currently, the mod supports weapons, accessories and echos.

## Configuration

The config file can be found at `Mods/SmartSort/scripts/config.lua`. When opening the file, there will be 2 variables for each supported item type, one for favorite rules and another one for junk rules.

The way the rules work, is that you can provide a list of rule entries for each item type, each rule entry works as an `AND` while all rule entries are treated as an `OR`.

Eg:

```
local weaponFavoriteRules = {
    { aboveLevel = 38 },
    { aboveLevel = 35, slots = { "Alfa", "Rush" } }
}
```

In this example, the mod will favorite all weapons that are either level 38 or above (first rule) OR weapons that are level 35 or above AND with an `Alfa` and `Rush` slots (second rule)

Multiple rules can be set within the available parameter for each item type

Favorite rules will run first, and favorite items wont be overruled, this means that if your favorite and junk rules overwrite each other for the same item, the item will be favorite first and the junk rules will be ignored for that same item. You will have to manually unfavorite the items so the mod takes them into consideration again.

## InGame Usage

Any new items will be sorted automatically, but if you want to sort currently existing items, then press F10 so the console pops ups, and type `RunSmartSort`, which will run the rules on all the supported items currently in the inventory.

Note: This operation may take a while depending on how many items you have and how many rules are set, so don't worry if the game freezes for a bit while it processes all of them.

## Installation

1. Download UE4SS (https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip)

- You can skip this if you already have it

2. Extract the contents of UE4SS to the path of Wayfinder executable directory. Usually looks like this "C:\Program Files (x86)\Steam\steamapps\common\Wayfinder\Atlas\Binaries\Win64"

- You can skip this if you already have it

3. Extract the contents of this mod onto the same place you did for UE4SS. Replace any existing files (unless you know what you are doing, and you can decide to not replace the configs)

4. Edit the `mods.txt` file located at `Mods/mods.txt`, and add `SmartSort : 1` to the list of mods.

5. Run the game

## Update ConfigRules

If you update the config rules, you will need to restart the game for them to take place.

Alternatively, if you have the `UE4SS GUI Console on *`, you can press `Restart Mods`

\* You can do this by setting `GuiConsoleEnabled = 1` and `GuiConsoleVisible = 1` in the `UE4SS-settings.ini` file
