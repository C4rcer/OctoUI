-- English localization file for enUS and enGB.
local AceLocale = LibStub:GetLibrary("AceLocale-3.0");
local L = AceLocale:NewLocale("ElvUI", "enUS", true, true);
if not L then return; end

--GlobalStrings Override
GUILD_STATUS = "Guild Status"
PLAYER_STATUS = "Player Status"

--*_ADDON locales
L["INCOMPATIBLE_ADDON"] = "The addon %s is not compatible with OctoUI's %s module. Please select either the addon or the OctoUI module to disable."

--*_MSG locales
L["LOGIN_MSG"] = "Welcome to %sOctoUI|r version %s%s|r, type /oc to access the in-game configuration menu. If you are in need of technical support you can visit us at https://github.com/C4rcer/OctoUI/issues"

--ActionBars
L["Binding"] = true;
L["Key"] = true;
L["KEY_ALT"] = "A"
L["KEY_CTRL"] = "C"
L["KEY_DELETE"] = "Del"
L["KEY_HOME"] = "Hm"
L["KEY_INSERT"] = "Ins"
L["KEY_MOUSEBUTTON"] = "M"
L["KEY_MOUSEWHEELDOWN"] = "MwD"
L["KEY_MOUSEWHEELUP"] = "MwU"
L["KEY_NUMPAD"] = "N"
L["KEY_PAGEDOWN"] = "PD"
L["KEY_PAGEUP"] = "PU"
L["KEY_SHIFT"] = "S"
L["KEY_SPACE"] = "SpB"
L["No bindings set."] = true;
L["Remove Bar %d Action Page"] = true;
L["Trigger"] = true;

--Bags
L["Bank"] = true;
L["Hold Control + Right Click:"] = true;
L["Hold Shift + Drag:"] = true;
L["Purchase Bags"] = true;
L["Reset Position"] = true;
L["Sort Bags"] = true;
L["Temporary Move"] = true;
L["Toggle Bags"] = true;
L["Vendor Grays"] = true;

--Chat
L["AFK"] = true; --Also used in datatexts
L["BG"] = true;
L["BGL"] = true;
L["DND"] = true; --Also used in datatexts
L["G"] = true;
L["Invalid Target"] = true;
L["O"] = true;
L["P"] = true;
L["PL"] = true;
L["R"] = true;
L["RL"] = true;
L["RW"] = true;
L["says"] = true;
L["whispers"] = true;
L["yells"] = true;

--DataTexts
L["(Hold Shift) Memory Usage"] = true;
L["Avoidance Breakdown"] = true;
L["Character: "] = true;
L["Chest"] = true;
L["Combat"] = true;
L["Combat Time"] = true;
L["Coords"] = true;
L["copperabbrev"] = "|cffeda55fc|r" --Also used in Bags
L["Deficit:"] = true;
L["DPS"] = true;
L["Earned:"] = true;
L["Friends List"] = true;
L["Friends"] = true; --Also in Skins
L["Gold"] = true;
L["goldabbrev"] = "|cffffd700g|r" --Also used in Bags
L["Hit"] = true;
L["Hold Shift + Right Click:"] = true;
L["Home Latency:"] = true;
L["HP"] = true;
L["HPS"] = true;
L["lvl"] = true;
L["Miss Chance"] = true;
L["Mitigation By Level: "] = true;
L["No Guild"] = true;
L["Profit:"] = true;
L["Realm time:"] = true;
L["Reload UI"] = true;
L["Reset Data: Hold Shift + Right Click"] = true;
L["Right Click: Reset CPU Usage"] = true;
L["Saved Raid(s)"] = true;
L["Server: "] = true;
L["Session:"] = true;
L["silverabbrev"] = "|cffc7c7cfs|r" --Also used in Bags
L["SP"] = true;
L["Spell/Heal Power"] = true;
L["Spent:"] = true;
L["Stats For:"] = true;
L["System"] = true;
L["Total CPU:"] = true;
L["Total Memory:"] = true;
L["Total: "] = true;
L["Unhittable:"] = true;
L["Wintergrasp"] = true;

--DebugTools
L["%s: %s tried to call the protected function '%s'."] = true;
L["No locals to dump"] = true;

--Distributor
L["%s is attempting to share his filters with you. Would you like to accept the request?"] = true;
L["%s is attempting to share the profile %s with you. Would you like to accept the request?"] = true;
L["Data From: %s"] = true;
L["Filter download complete from %s, would you like to apply changes now?"] = true;
L["Lord! It's a miracle! The download up and vanished like a fart in the wind! Try Again!"] = true;
L["Profile download complete from %s, but the profile %s already exists. Change the name or else it will overwrite the existing profile."] = true;
L["Profile download complete from %s, would you like to load the profile %s now?"] = true;
L["Profile request sent. Waiting for response from player."] = true;
L["Request was denied by user."] = true;
L["Your profile was successfully recieved by the player."] = true;

--Install
L["Aura Bars & Icons"] = true;
L["Auras Set"] = true;
L["Auras"] = true;
L["Caster DPS"] = true;
L["Chat Set"] = true;
L["Choose a theme layout you wish to use for your initial setup."] = true;
L["Classic"] = true;
L["Click the button below to resize your chat frames, unitframes, and reposition your actionbars."] = true;
L["Config Mode:"] = true;
L["CVars Set"] = true;
L["CVars"] = true;
L["Dark"] = true;
L["Disable"] = true;
L["ElvUI Installation"] = "OctoUI Installation";
L["Finished"] = true;
L["Grid Size:"] = true;
L["Healer"] = true;
L["High Resolution"] = true;
L["high"] = true;
L["Icons Only"] = true; --Also used in Bags
L["If you have an icon that you don't want to display simply hold down shift and right click the icon for it to disapear."] = true;
L["Importance: |cff07D400High|r"] = true;
L["Importance: |cffD3CF00Medium|r"] = true;
L["Importance: |cffFF0000Low|r"] = true;
L["Installation Complete"] = true;
L["Layout Set"] = true;
L["Layout"] = true;
L["Lock"] = true;
L["Low Resolution"] = true;
L["low"] = true;
L["Nudge"] = true;
L["Physical DPS"] = true;
L["Please click the button below so you can setup variables and ReloadUI."] = true;
L["Please click the button below to setup your CVars."] = true;
L["Please press the continue button to go onto the next step."] = true;
L["Resolution Style Set"] = true;
L["Resolution"] = true;
L["Select the type of aura system you want to use with ElvUI's unitframes. Set to Aura Bar & Icons to use both aura bars and icons, set to icons only to only see icons."] = "Select the type of aura system you want to use with OctoUI's unitframes. Set to Aura Bar & Icons to use both aura bars and icons, set to icons only to only see icons.";
L["Setup Chat"] = true;
L["Setup CVars"] = true;
L["Skip Process"] = true;
L["Sticky Frames"] = true;
L["Tank"] = true;
L["The chat windows function the same as Blizzard standard chat windows, you can right click the tabs and drag them around, rename, etc. Please click the button below to setup your chat windows."] = true;
L["The in-game configuration menu can be accessed by typing the /ec command or by clicking the 'C' button on the minimap. Press the button below if you wish to skip the installation process."] = "The in-game configuration menu can be accessed by typing the /oc command or by clicking the 'C' button on the minimap. Press the button below if you wish to skip the installation process.";
L["Theme Set"] = true;
L["Theme Setup"] = true;
L["This install process will help you learn some of the features in ElvUI has to offer and also prepare your user interface for usage."] = "This install process will help you learn some of the features in OctoUI has to offer and also prepare your user interface for usage.";
L["This is completely optional."] = true;
L["This part of the installation process sets up your chat windows names, positions and colors."] = true;
L["This part of the installation process sets up your World of Warcraft default options it is recommended you should do this step for everything to behave properly."] = true;
L["This resolution doesn't require that you change settings for the UI to fit on your screen."] = true;
L["This resolution requires that you change some settings to get everything to fit on your screen."] = true;
L["This will change the layout of your unitframes and actionbars."] = true;
L["Trade"] = true;
L["Welcome to ElvUI version %s!"] = "Welcome to OctoUI version %s!";
L["You are now finished with the installation process. If you are in need of technical support please visit us at https://github.com/ElvUI-Vanilla/ElvUI"] = "You are now finished with the installation process. If you are in need of technical support please visit us at https://github.com/C4rcer/OctoUI/issues";
L["You can always change fonts and colors of any element of ElvUI from the in-game configuration."] = "You can always change fonts and colors of any element of OctoUI from the in-game configuration.";
L["You can now choose what layout you wish to use based on your combat role."] = true;
L["You may need to further alter these settings depending how low you resolution is."] = true;
L["Your current resolution is %s, this is considered a %s resolution."] = true;

--Misc
L["ABOVE_THREAT_FORMAT"] = "%s: %.0f%% [%.0f%% above |cff%02x%02x%02x%s|r]"
L["Bars"] = true; --Also used in UnitFrames
L["Calendar"] = true;
L["Can't Roll"] = true;
L["Disband Group"] = true;
L["Empty Slot"] = true;
L["Enable"] = true; --Doesn't fit a section since it's used a lot of places
L["Experience"] = true;
L["Farm Mode"] = true;
L["Fishy Loot"] = true;
L["Left Click:"] = true; --layout\layout.lua
L["Mouse"] = true;
L["Raid Menu"] = true;
L["Remaining:"] = true;
L["Rested:"] = true;
L["Right Click:"] = true; --layout\layout.lua
L["Show BG Texts"] = true; --layout\layout.lua
L["Toggle Chat Frame"] = true; --layout\layout.lua
L["Toggle Configuration"] = true; --layout\layout.lua
L["XP:"] = true;
L["You don't have permission to mark targets."] = true;

--Movers
L["Bag Mover (Grow Down)"] = true;
L["Bag Mover (Grow Up)"] = true;
L["Bag Mover"] = true;
L["Bags"] = true; --Also in DataTexts
L["Bank Mover (Grow Down)"] = true;
L["Bank Mover (Grow Up)"] = true;
L["Bar "] = true; --Also in ActionBars
L["Classbar"] = true; --Also used in UnitFrames
L["Experience Bar"] = true;
L["Focus Castbar"] = true;
L["Focus Frame"] = true; --Also used in UnitFrames
L["FocusTarget Frame"] = true; --Also used in UnitFrames
L["GM Ticket Frame"] = true;
L["Left Chat"] = true;
L["Loot / Alert Frames"] = true;
L["Loot Frame"] = true;
L["MA Frames"] = true;
L["Micro Bar"] = true; --Also in ActionBars
L["MirrorTimer"] = true;
L["Popups"] = true;
L["MT Frames"] = true;
L["Party Frames"] = true; --Also used in UnitFrames
L["Pet Bar"] = true; --Also in ActionBars
L["Pet Castbar"] = true;
L["Pet Frame"] = true; --Also used in UnitFrames
L["PetTarget Frame"] = true; --Also used in UnitFrames
L["Player Buffs"] = true;
L["Player Castbar"] = true;
L["Player Debuffs"] = true;
L["Player Frame"] = true; --Also used in UnitFrames
L["Player Powerbar"] = true;
L["Raid Frames"] = true;
L["Raid Pet Frames"] = true;
L["Raid-40 Frames"] = true;
L["Reputation Bar"] = true;
L["Right Chat"] = true;
L["Stance Bar"] = true; --Also in ActionBars
L["Target Castbar"] = true;
L["Target Frame"] = true; --Also used in UnitFrames
L["Target Powerbar"] = true;
L["TargetTarget Frame"] = true; --Also used in UnitFrames
L["TargetTargetTarget Frame"] = true; --Also used in UnitFrames
L["Time Manager Frame"] = true;
L["Tooltip"] = true;
L["Watch Frame"] = true;
L["Weapons"] = true;
L["DESC_MOVERCONFIG"] = "Movers unlocked. Move them now and click Lock when you are done.\nOptions:\nShift + RightClick - Hides mover temporarily.\nCtrl + RightClick - Resets mover position to default."

--Plugin Installer
L["ElvUI Plugin Installation"] = "OctoUI Plugin Installation";
L["In Progress"] = true;
L["List of installations in queue:"] = true;
L["Pending"] = true;
L["Steps"] = true;

--Prints
L[" |cff00ff00bound to |r"] = true;
L["%s frame(s) has a conflicting anchor point, please change either the buff or debuff anchor point so they are not attached to each other. Forcing the debuffs to be attached to the main unitframe until fixed."] = true;
L["All keybindings cleared for |cff00ff00%s|r."] = true;
L["Already Running.. Bailing Out!"] = true;
L["Battleground datatexts temporarily hidden, to show type /bgstats or right click the 'C' icon near the minimap."] = true;
L["Battleground datatexts will now show again if you are inside a battleground."] = true;
L["Binds Discarded"] = true;
L["Binds Saved"] = true;
L["Confused.. Try Again!"] = true;
L["No gray items to delete."] = true;
L["The spell '%s' has been added to the Blacklist unitframe aura filter."] = true;
L["This setting caused a conflicting anchor point, where '%s' would be attached to itself. Please check your anchor points. Setting '%s' to be attached to '%s'."] = true;
L["Vendored gray items for:"] = true;
L["You don't have enough money to repair."] = true;
L["You must be at a vendor."] = true;
L["Your items have been repaired for: "] = true;
L["Your items have been repaired using guild bank funds for: "] = true;
L["|cFFE30000Lua error recieved. You can view the error message when you exit combat."] = true;

--Skins
L["Abandon"] = true
L["Share"] = true
L["Track"] = true

--Static Popups
L["A setting you have changed will change an option for this character only. This setting that you have changed will be uneffected by changing user profiles. Changing this setting requires that you reload your User Interface."] = true;
L["Accepting this will reset your Filter Priority lists for all auras on NamePlates. Are you sure?"] = true
L["Accepting this will reset your Filter Priority lists for all auras on UnitFrames. Are you sure?"] = true
L["Are you sure you want to apply this font to all ElvUI elements?"] = "Are you sure you want to apply this font to all OctoUI elements?";
L["Are you sure you want to disband the group?"] = true;
L["Are you sure you want to reset all the settings on this profile?"] = true;
L["Are you sure you want to reset every mover back to it's default position?"] = true;
L["Because of the mass confusion caused by the new aura system I've implemented a new step to the installation process. This is optional. If you like how your auras are setup go to the last step and click finished to not be prompted again. If for some reason you are prompted repeatedly please restart your game."] = true;
L["Can't buy anymore slots!"] = true;
L["Delete gray items?"] = true
L["Disable Warning"] = true;
L["Discard"] = true;
L["Do you enjoy the new ElvUI?"] = "Do you enjoy the new OctoUI?";
L["Do you swear not to post in technical support about something not working without first disabling the addon/module combination first?"] = true;
L["ElvUI is five or more revisions out of date. You can download the newest version from https://github.com/ElvUI-Vanilla/ElvUI/"] = "OctoUI is five or more revisions out of date. You can download the newest version from https://github.com/C4rcer/OctoUI";
L["ElvUI is out of date. You can download the newest version from https://github.com/ElvUI-Vanilla/ElvUI/"] = "OctoUI is out of date. You can download the newest version from https://github.com/C4rcer/OctoUI";
L["ElvUI needs to perform database optimizations please be patient."] = "OctoUI needs to perform database optimizations please be patient.";
L["Hover your mouse over any actionbutton or spellbook button to bind it. Press the escape key or right click to clear the current actionbutton's keybinding."] = true;
L["I Swear"] = true;
L["No, Revert Changes!"] = true;
L["Oh lord, you have got ElvUI and Tukui both enabled at the same time. Select an addon to disable."] = "Oh lord, you have got OctoUI and Tukui both enabled at the same time. Select an addon to disable.";
L["One or more of the changes you have made require a ReloadUI."] = true;
L["One or more of the changes you have made will effect all characters using this addon. You will have to reload the user interface to see the changes you have made."] = true;
L["Save"] = true;
L["The profile you tried to import already exists. Choose a new name or accept to overwrite the existing profile."] = true;
L["Type /hellokitty to revert to old settings."] = true;
L["Using the healer layout it is highly recommended you download the addon Clique if you wish to have the click-to-heal function."] = true;
L["Yes, Keep Changes!"] = true;
L["You have changed the Thin Border Theme option. You will have to complete the installation process to remove any graphical bugs."] = true;
L["You have changed your UIScale, however you still have the AutoScale option enabled in ElvUI. Press accept if you would like to disable the Auto Scale option."] = "You have changed your UIScale, however you still have the AutoScale option enabled in OctoUI. Press accept if you would like to disable the Auto Scale option.";
L["You have imported settings which may require a UI reload to take effect. Reload now?"] = true;
L["You must purchase a bank slot first!"] = true;

--Tooltip
L["Count"] = true;
L["Item Level:"] = true;
L["Talent Specialization:"] = true;
L["Targeted By:"] = true;

--Tutorials
L["A raid marker feature is available by pressing Escape -> Keybinds scroll to the bottom under ElvUI and setting a keybind for the raid marker."] = "A raid marker feature is available by pressing Escape -> Keybinds scroll to the bottom under OctoUI and setting a keybind for the raid marker.";
L["ElvUI has a dual spec feature which allows you to load different profiles based on your current spec on the fly. You can enable this from the profiles tab."] = "OctoUI has a dual spec feature which allows you to load different profiles based on your current spec on the fly. You can enable this from the profiles tab.";
L["For technical support visit us at https://github.com/ElvUI-Vanilla/ElvUI"] = "For technical support visit us at https://github.com/C4rcer/OctoUI/issues";
L["If you accidently remove a chat frame you can always go the in-game configuration menu, press install, go to the chat portion and reset them."] = true;
L["If you are experiencing issues with ElvUI try disabling all your addons except ElvUI, remember ElvUI is a full UI replacement addon, you cannot run two addons that do the same thing."] = "If you are experiencing issues with OctoUI try disabling all your addons except OctoUI, remember OctoUI is a full UI replacement addon, you cannot run two addons that do the same thing.";
L["The focus unit can be set by typing /focus when you are targeting the unit you want to focus. It is recommended you make a macro to do this."] = true;
L["To move abilities on the actionbars by default hold shift + drag. You can change the modifier key from the actionbar options menu."] = true;
L["To setup which channels appear in which chat frame, right click the chat tab and go to settings."] = true;
L["You can access copy chat and chat menu functions by mouse over the top right corner of chat panel and left/right click on the button that will appear."] = true;
L["You can see someones average item level of their gear by holding shift and mousing over them. It should appear inside the tooltip."] = true;
L["You can set your keybinds quickly by typing /kb."] = true;
L["You can toggle the microbar by using your middle mouse button on the minimap you can also accomplish this by enabling the actual microbar located in the actionbar settings."] = true;
L["You can use the /resetui command to reset all of your movers. You can also use the command to reset a specific mover, /resetui <mover name>.\nExample: /resetui Player Frame"] = true;

--UnitFrames
L["Dead"] = true;
L["Ghost"] = true;
L["Offline"] = true;

--Ported ShaguTweaks features
L["Auto Stance"] = true;
L["Automatically switch to the required warrior or druid stance on spell cast."] = true;
L["Auto Dismount"] = true;
L["Automatically dismount or leave shapeshift form when casting a spell that requires it."] = true;
L["Energy Ticks"] = true;
L["Show energy and mana tick timers on the player power bar."] = true;
L["Combat Feedback"] = true;
L["Show floating combat feedback numbers on the player and target frames."] = true;
L["Reveal World Map"] = true;
L["Reveal unexplored areas of the world map."] = true;
L["Exploration Markers"] = true;
L["Show a marker on unexplored areas revealed by the world map overlay."] = true;
L["Reveal Unexplored"] = true;
L["Exploration Point"] = true;

--Character stats panel
L["Spell Power"] = true;
L["Healing Power"] = true;
L["Spell Hit"] = true;
L["Spell Crit"] = true;
L["Haste"] = true;
L["Casting Speed"] = true;
L["Mana Regen"] = true;
L["Mana While Casting"] = true;
L["Spell Penetration"] = true;
L["Armor Penetration"] = true;
L["Melee Hit"] = true;
L["Melee Crit"] = true;
L["Agility"] = true;
L["Intellect"] = true;
L["Spirit"] = true;
--School-specific spell power; shown only when it beats the generic figure
L["Arcane Damage"] = true;
L["Fire Damage"] = true;
L["Frost Damage"] = true;
L["Holy Damage"] = true;
L["Nature Damage"] = true;
L["Shadow Damage"] = true;
--API-sourced rows
L["Attack Power"] = true;
L["Ranged Attack Power"] = true;
L["Defense"] = true;
L["Dodge"] = true;
L["Parry"] = true;
L["Block"] = true;
L["Block Value"] = true;
L["Arcane Resistance"] = true;
L["Fire Resistance"] = true;
L["Frost Resistance"] = true;
L["Holy Resistance"] = true;
L["Nature Resistance"] = true;
L["Shadow Resistance"] = true;
--%s is an attribute name, one of the three above.
L["STATS_INCOMPLETE"] = "Gear, buffs and talents only. The base every character gets from %s is not calculated yet, so this is not your real total.";
--Shown for a row whose stat has no scan patterns and whose API this client does not have.
L["STATS_NO_API"] = "This client does not provide a function for this stat, so there is nothing to read. The row is kept so it appears by itself if a future client adds one.";
--%.2f is the measured crit rate, %d the number of casts behind it.
L["STATS_CRIT_MEASURED"] = "Measured: %.2f%% over %d casts. The figure above is calculated; this one is what actually happened.";
--%.1f is Intellect per 1%% crit.
L["STATS_CRIT_IMPLIED"] = "That rate implies %.1f Intellect per 1%% crit. If it stays far from the calculated figure over a few hundred casts, this server uses a different formula.";

--Damage meter spell breakdown
L["Pet"] = true;
L["Melee"] = true;
L["Damage Shield"] = true;

--Experience datatext
L["Remaining"] = true;
L["Rested"] = true;
L["Kills to Level"] = true;


--Strings that reached the options tree and the chat frame without ever having a
--locale entry. AceLocale is registered silent (the fourth argument to NewLocale), so
--an unknown key quietly returns the key string instead of raising -- which is why
--these worked at all, and why nothing ever pointed them out. Grouped by the file that
--uses them.

--Core/ClassCache.lua
L["Class DB cache wiped."] = true;
L["Class session cache wiped."] = true;

--Core/StaticPopups.lua
L["OctoUI is five or more revisions out of date. You can download the newest version from https://github.com/C4rcer/OctoUI"] = true;
L["Accepting this will reset the UnitFrame settings for %s. Are you sure?"] = true;
L["Error resetting UnitFrame."] = true;

--Core/core.lua
L["OctoUI is out of date. You can download the newest version from https://github.com/C4rcer/OctoUI"] = true;

--Modules/Threat/TWThreat.lua
L["Threat Meter"] = true;

--Modules/Bags/Bags.lua
L["%s is no longer protected."] = true;
L["%s is now protected from selling and deleting."] = true;
L["%s is protected. Alt + Right-Click it in your bags to unlock it."] = true;
L["Alt + Right-Click a bag item to protect it from being sold or deleted."] = true;
L["Protected: cannot be sold or deleted."] = true;
L["That item is protected. Alt + Right-Click it in your bags to unlock it."] = true;
L["Vendor / Delete Grays"] = true;
L["Vendored gray items for: %s"] = true;
L["Vendoring Grays"] = true;

--Modules/Blizzard/CaptureBar.lua
L["PvP"] = true;

--Modules/Blizzard/ColorPicker.lua
L["Copy"] = true;
L["Paste"] = true;

--Modules/DataTexts/Durability.lua
L["Durability"] = true;

--Modules/DataTexts/Time.lua
L["Saved Instance(s)"] = true;
L["Realm Time:"] = true;

--Modules/Misc/BagItemClick.lua
L["Hold [Shift] to use item."] = true;

--Modules/UnitFrames/UnitFrames.lua
L["You cannot copy settings from the same unit."] = true;

--Core/StaticPopups.lua
L["AddOn changes take effect the next time the UI loads. Reload now?"] = true;

--Modules/Misc/Blacklist.lua
L["Ignore List"] = true;
L["Notes on the players you have ignored. Membership is the game's own ignore list - use /ignore and /unignore as normal, and this remembers why."] = true;
L["Warn me in my group"] = true;
L["Prints a private line when someone on your ignore list is in your party or raid. Only you ever see it."] = true;
L["Ignore a player"] = true;
L["Same as typing /ignore. Add the reason afterwards below."] = true;
L["Your ignore list is empty. Use /ignore <name> in game, then add a note here."] = true;
L["This client does not provide the ignore list API, so nothing can be shown here."] = true;
L["Reason"] = true;
L["Noted %s"] = true;
L["Why this player is on your list."] = true;
L["Un-ignore"] = true;
L["Removes them from the game's ignore list. The note is kept in case they end up back on it."] = true;

--Modules/Bags/Bags.lua
L["Hearthstone"] = true;
L["No hearthstone found in your bags."] = true;

--Modules/Misc/AuctionHouse.lua
--Per-unit line under a browse row: %s is the bid per unit, %s the buyout per unit.
L["AUCTION_UNIT_PRICE"] = "%s / %s ea"
--Same row where the auction has no buyout at all. %s is the bid per unit, %s the marker.
L["AUCTION_UNIT_PRICE_NO_BUYOUT"] = "%s ea, %s"
L["no buyout"] = true;
L["Auction house: AuctionFrameBrowse_Update is missing, using the event fallback for per-unit prices."] = true;
L["Auction house: a browse row's item name matched neither auction index, so per-unit prices may be against the wrong row. Please report this."] = true;

--Modules/Misc/AuctionHouse.lua -- the scan and its results window
L["Scan"] = true;
L["Cancel"] = true;
L["Scanning %d/%d"] = true;
L["Item"] = true;
L["Qty"] = true;
L["Seller"] = true;
L["Bid ea"] = true;
L["Buyout ea"] = true;
L["Buyout"] = true;
L["Total buyout"] = true;
L["Page %d / %d"] = true;
L["Not one of these auctions has a buyout."] = true;
L["AUCTION_SCAN_TITLE"] = "Auction scan: %s - %d auction(s)"
L["AUCTION_SCAN_CHEAPEST"] = "Cheapest per unit: %s each, as a stack of %d for %s from %s."
L["AUCTION_SCAN_DONE"] = "Scanned %s: %d auction(s) over %d page(s)."
L["AUCTION_SCAN_TIMEOUT"] = "Auction scan timed out waiting for a page; stopped with %d auction(s)."
L["AUCTION_SCAN_CANCELLED"] = "Auction scan stopped with %d auction(s) collected."
L["AUCTION_SCAN_NEEDS_NAME"] = "Type an item name in the search box first - a scan walks every page of one search, not the whole auction house."

--Modules/Misc/AuctionHouse.lua -- the filter, and taking the browse list to a result
L["Buyout only"] = true;
L["Click a row to take the browse list to it."] = true;
L["AUCTION_JUMP_FOUND"] = "Auction house taken to page %d, row %d from the top - marked with >> in the list."
L["AUCTION_JUMP_GONE"] = "That auction is no longer on the page it was scanned from - it has most likely sold. Scan again for current prices."
L["AUCTION_JUMP_NEEDS_AH"] = "Open the auction house first."
L["AUCTION_JUMP_TIMEOUT"] = "Timed out asking the auction house for that page."

--Modules/Tooltip/Tooltip.lua -- auction value against vendor value
L["Auction (cheapest buyout)"] = true;
L["Auction (cheapest bid)"] = true;
L["%dm ago"] = true;
L["%dh ago"] = true;
L["%dd ago"] = true;
L["AUCTION_TOOLTIP_EACH"] = "%s each"
L["AUCTION_TOOLTIP_STACK"] = "%s each, %s for %d"
L["AUCTION_TOOLTIP_LIST_IT"] = "%.1fx vendor - worth listing"
L["AUCTION_TOOLTIP_MARGINAL"] = "%.1fx vendor - marginal"
L["AUCTION_TOOLTIP_VENDOR_IT"] = "the vendor pays more - do not list"
L["Auction (typical)"] = true;
L["AUCTION_TOOLTIP_SEEN"] = "%s, %d seen"

--Modules/Misc/MailTools.lua
L["Take All"] = true;
L["Stop"] = true;
L["MAIL_TAKEALL_DONE"] = "Mailbox: %d attachment(s) and %s collected."
L["MAIL_TAKEALL_COD"] = "%d cash-on-delivery letter(s) left alone - taking those spends your gold, so they are never automatic."
L["MAIL_TAKEALL_TIMEOUT"] = "Stopped: the server stopped answering."
L["MAIL_TAKEALL_STALLED"] = "Stopped: the last action was refused without an error, which usually means there is nowhere to put the item."
L["MAIL_TAKEALL_BAGS_FULL"] = "Stopped: no free bag space."
L["MAIL_TAKEALL_CANCELLED"] = "Stopped."

--Modules/Misc/MailTools.lua -- /octoui-mail, the inbox as the take-all sees it
L["present"] = true;
L["absent"] = true;
L["MAIL_REPORT_HEADER"] = "Inbox: %d letter(s). Attachment slots per letter: %d. AutoLootMailItem is %s."
L["MAIL_REPORT_ATTACHMENTS"] = "%d attachment(s) (hasItem=%s)"
L["MAIL_REPORT_TAKE"] = "would take"
L["MAIL_REPORT_SKIP_COD"] = "SKIPPED, cash on delivery %s"
L["MAIL_REPORT_NOTHING"] = "nothing to take"

--Modules/Bags/Sort.lua
L["Sort stopped: a move could not be completed."] = true;
L["Sort stopped by a Lua error: %s"] = true;
L["Sort finished, but %d move(s) could not be completed. Run /octoui-bags to see which."] = true;

--Modules/Chat/Chat.lua
L["Undocked the right chat window; the dock was hiding it on every login."] = true;
L["Reopened the right chat window; the client had it closed."] = true;

--Modules/Misc/AutoRoll.lua -- per-item loot roll rules
L["Loot Rolls"] = true;
L["Rolls need, greed or pass for you on the items named here. Anything not on the list is left alone. Paste an item link, an item id, or type a name."] = true;
L["Turns every rule below off at once without losing the list."] = true;
L["Remove after winning"] = true;
L["What new entries start with. Each entry keeps its own setting afterwards."] = true;
L["Takes this off the list once the item reaches you. Turn it off for something that drops again and again, like a reputation turn-in."] = true;
L["What new entries start with."] = true;
L["Add item"] = true;
L["An item link, an item id, or a name. Shift-clicking an item into the box is the safest of the three."] = true;
L["Nothing on the list. Every roll is left to you until you add something."] = true;
L["Takes this off the list. Rolls for it go back to being yours to make."] = true;
L["Roll"] = true;
L["Remove"] = true;
L["Silence the confirmation"] = true;
L["A bind-on-pickup roll raises a confirmation dialog, and the sound it makes is the clunk you hear. This swallows that one sound, for automatic rolls only."] = true;
--Fallbacks for the client's own NEED / GREED / PASS, which are not safe to read straight
--into the options tree. See the note above E:SafeString in Core/core.lua.
L["Need"] = true;
L["Greed"] = true;
L["Pass"] = true;
L["AUTOROLL_ITEM_ID"] = "Item #%d"
L["AUTOROLL_ROLLED"] = "Rolled %s on %s."
L["AUTOROLL_REMOVED"] = "Won %s - taken off the loot roll list."

--Modules/Misc/MountGear.lua -- riding gear that goes on with the mount
L["Mount Gear"] = true;
L["Swim Gear"] = true;
L["Swimming gear"] = true;
L["Land gear"] = true;
L["The item to wear in this slot while swimming."] = true;
L["The item to wear in this slot when out of the water."] = true;
L["SWIMGEAR_INTRO"] = "Puts swim gear on when you enter the water and your land gear back when you leave it. Leave a box empty to leave that slot alone. Shift-click an item into a box, or type an item id or name."
L["SWIMGEAR_LAND_INTRO"] = "What to put back on when you leave the water. Leave a box empty and that slot returns whatever it was wearing before you got in, which is only right if it was right at the time."
L["Puts riding gear on with the mount and your own gear back when it goes. Leave a box empty to leave that slot alone. Shift-click an item into a box, or type an item id or name."] = true;
L["Off by default, because this moves your equipment around on its own."] = true;
L["Gear cannot be swapped in combat. A change that lands mid-fight is held until the fight ends."] = true;
L["The item to wear in this slot while mounted."] = true;
L["Trinket 1"] = true;
L["Trinket 2"] = true;
L["Boots"] = true;
L["Gloves"] = true;
L["MOUNTGEAR_ITEM_ID"] = "Item #%d"
L["MOUNTGEAR_ALREADY_ON"] = "already worn"
L["MOUNTGEAR_EQUIPPED"] = "put on"
L["MOUNTGEAR_RESTORED"] = "put back"
L["MOUNTGEAR_REMOVED"] = "taken off"
L["MOUNTGEAR_CHANGED_BY_HAND"] = "you changed this slot yourself, left alone"
L["MOUNTGEAR_NOT_IN_BAGS"] = "not in your bags"
L["MOUNTGEAR_OLD_NOT_IN_BAGS"] = "your own item is not in your bags, still owed back"
L["MOUNTGEAR_NO_SPACE"] = "no free bag space"
L["MOUNTGEAR_CURSOR_BUSY"] = "the cursor was already holding something"
L["MOUNTGEAR_CURSOR_STUCK"] = "the swap left an item on the cursor"
L["MOUNTGEAR_LOCKED"] = "that bag slot was locked"
L["MOUNTGEAR_NO_PICKUP"] = "the client did not pick the item up"

--Modules/Misc/CCWatch.lua -- what you have crowd controlled
L["CC Watch"] = true;
L["Lists what you have crowd controlled, with the time left on each. Click a row to target that mob. Only your own casts appear, so another player's fear on the same mob is not counted as yours."] = true;
L["How many at once. Anything past this is still tracked, it just does not have a row."] = true;
L["Use /moveui to position the list. /octoui-cc lists every spell currently watched."] = true;
L["Watch another spell"] = true;
L["The spell's name exactly as the game writes it. It also needs an entry in the debuff duration table, or there is no timer to show."] = true;
L["Stop watching a spell"] = true;
L["Removes it from the list, whether it was one of yours or one of the built-in ones."] = true;
L["Rows"] = true;
L["CC_LOOSE"] = "LOOSE"

--Modules/Misc/WarlockSummon.lua -- the raid summon list
L["Summon List"] = true;
L["A raider types the trigger word in chat and every warlock in the raid gets a clickable row. Left-click summons them, Ctrl-click only targets them, right-click drops the row. Summoning takes the row off everyone's list."] = true;
L["The word a raider types to ask for a summon. Matched at the start of the line only."] = true;
L["Announce In"] = true;
L["Where the summon is announced. Say reaches the people standing at the stone, which is usually who needs to see it."] = true;
L["Whisper Target"] = true;
L["Also whispers the person being summoned, so they know to click."] = true;
L["Include Zone"] = true;
L["Adds where you are summoning to, which is the one thing a raider cannot see from the dialog."] = true;
L["Include Shard Count"] = true;
L["Adds how many soul shards you have left to the announcement."] = true;
L["Sound On Request"] = true;
L["Plays a sound when somebody joins the list."] = true;
--Kept short on purpose: the row is 120px wide and the FontString is anchored on both sides,
--so anything longer wraps onto a second line inside a 16px row. Grey is what says "empty".
L["WARLOCKSUMMON_EMPTY_ROW"] = "Summon List"
L["Alert Sound"] = true;
L["Which sound. The dropdown plays each one as you move through it, which is the only reliable way to hear what a file does on this client."] = true;
L["Use /moveui to position the list. /octoui-summon shows it and reports who is waiting."] = true;
L["Say"] = true;
L["Raid"] = true;
L["None"] = true;
--Sent to the raid, so these are plain sentences rather than anything OctoUI-branded.
L["WARLOCKSUMMON_SAY"] = "Summoning %s"
L["WARLOCKSUMMON_WHISPER"] = "Summoning you"
L["WARLOCKSUMMON_TO_ZONE"] = "to %s"
L["WARLOCKSUMMON_SHARDS"] = "[%d shards left]"
L["WARLOCKSUMMON_EVILTWIN_WHISPER"] = "Cannot summon you while you have Evil Twin -- you need to die or run it yourself."
--These go to your own chat frame through E:Print, which prefixes them with OctoUI.
L["WARLOCKSUMMON_EVILTWIN"] = "%s has |cffff0000Evil Twin|r and cannot be summoned."
L["WARLOCKSUMMON_IN_RANGE"] = "%s is already |cff44ff44in range|r -- taken off the list."
L["WARLOCKSUMMON_IN_COMBAT"] = "Cannot summon %s: one of you is in combat."
L["WARLOCKSUMMON_NOT_IN_RAID"] = "%s is not in the raid -- taken off the list."
L["WARLOCKSUMMON_WAITING"] = "Waiting for a summon (%d): %s"
L["WARLOCKSUMMON_EMPTY"] = "Nobody is waiting for a summon."
L["WARLOCKSUMMON_NOT_WARLOCK"] = "The summon list is warlock only, and nothing is loaded on this character."

--Modules/Misc/LuaMacros.lua -- Lua that loads itself so a macro can call it
L["Lua Macros"] = true;
L["Lua that is compiled and run every time the UI loads, so a macro can call it by name. A 255 character macro cannot hold a function; this is where the function lives. Call it with /run YourFunction()"] = true;
L["New snippet"] = true;
L["A name for it. Letters and numbers, no spaces - it is only a label, not the function name."] = true;
L["Run all now"] = true;
L["Run now"] = true;
L["Runs it immediately, without waiting for the next reload."] = true;
L["Code"] = true;
L["Delete"] = true;
L["Nothing here yet. Name one above, then paste its code into the box that appears."] = true;
L["LUAMACRO_OK"] = "|cff44ff44Loaded.|r"
L["LUAMACRO_ERROR"] = "|cffff3333%s|r"
L["LUAMACRO_LOAD_FAILED"] = "%d Lua snippet(s) failed to load, %d loaded. Run /octoui-lua to see which."
L["Loaded from UserMacros.lua"] = true;

--Modules/ActionBars/ButtonColoring.lua
L["Range Glow"] = true;
L["Glows a button when pressing it right now would work - in range, affordable and off cooldown. Macros are included: a /cast macro uses whichever spell its conditions resolve to, and a /run macro uses the range you declare for it in Modules\\Misc\\UserMacros.lua."] = true;
L["LUAMACRO_FILE_LIST"] = "|cff44ff44%d function(s) loaded|r, callable from a macro with /run Name()\n\n%s"
L["LUAMACRO_FILE_EMPTY"] = "|cffff8800Nothing loaded from that file.|r It lives at Interface\\AddOns\\OctoUI\\Modules\\Misc\\UserMacros.lua - edit it in a text editor and /reload."
L["LUAMACRO_FILE_LOADED"] = "Lua loaded (%d): %s"

--Modules/Recipes/RecipeFinder.lua
L["Recipe Finder"] = true;
L["Click to look up where a recipe comes from."] = true;
L["Recipe Finder: database failed to load."] = true;
L["Search recipes..."] = true;
L["Select a recipe"] = true;
L["Learnable"] = true;
L["Vendor"] = true;
L["Content tier"] = true;
L["Reagents"] = true;
L["skill"] = true;
L["profession inferred"] = true;
L["%d of %d shown"] = true;
L["Vanilla only"] = true;
L["Up to Molten Core"] = true;
L["Up to Blackwing Lair"] = true;
L["Up to Zul'Gurub"] = true;
L["Up to AQ40"] = true;
L["Everything"] = true;
L["Unlearned"] = true;
L["Unlearned only"] = true;
L["Hides recipes you already know."] = true;
L["%d known in %s."] = true;
L["Open your %s window once so it can read what you know."] = true;
L["%d known"] = true;
L["open your %s window to filter known recipes"] = true;
L["Hides recipes from content later than this."] = true;
L["Unknown location"] = true;
L["Unknown faction"] = true;
L["NPC %d"] = true;
L["Item %d"] = true;
L["Requires %s - %s"] = true;
L["Sold by (%s)"] = true;
L["Sold by (price unknown)"] = true;
L["limited: %d"] = true;
L["Dropped by"] = true;
L["World drop from %d creatures"] = true;
L["(level %d-%d)"] = true;
L["Mostly"] = true;
L["Best rates"] = true;
L["Found in containers"] = true;
L["Quest reward"] = true;
L["Taught by a trade skill trainer"] = true;
L["Known automatically at the required skill"] = true;
L["Taught by a quest"] = true;
L["Learned from a world object"] = true;
L["No source known. See REPORT.md."] = true;
L["No recipe matching '%s'."] = true;
L["Raises the skill cap to %d"] = true;
L["also"] = true;

--Modules/UnitFrames/Elements/SpecRoleIcon.lua
L["Role icons: the threat meter is not loaded, so no roles are known."] = true;
L["Role icons - broadcast specs seen this session:"] = true;
L["Nobody in range is broadcasting a spec."] = true;
L["unmapped"] = true;
L["declared"] = true;

--Modules/Misc/MountGear.lua -- fight gear
L["Riding gear"] = true;
L["Fight gear"] = true;
L["The item to wear in this slot when not mounted."] = true;
L["What to put back on when the mount goes. Leave a box empty and that slot returns whatever it was wearing before you mounted, which is only right if it was right at the time."] = true;
L["MOUNTGEAR_FIGHT_RESTORED"] = "fight gear equipped"
L["MOUNTGEAR_FIGHT_ALREADY"] = "fight gear already worn"
L["MOUNTGEAR_FIGHT_NOT_IN_BAGS"] = "fight gear is not in your bags"

--Modules/Auction
L["Auction House"] = true;
L["Search"] = true;
L["Sell"] = true;
L["Bids"] = true;
L["Auctions"] = true;
L["switched off"] = true;
L["ready"] = true;
L["%s is loaded and owns the auction house"] = true;
L["OctoUI auction house: %s."] = true;
L["OctoUI auction house is off: %s is loaded and owns the auction house."] = true;
L["Disable %s and reload to use this instead."] = true;
L["OctoUI auction house switched off. Blizzard's own window comes back next time you visit an auctioneer."] = true;
L["AUCTION_ENABLED"] = "OctoUI auction house switched on. It replaces Blizzard's window at any auctioneer - search a name to walk every page and price it per unit."
L["AUCTION_HOW_TO_ENABLE"] = "Switch it on with /octoui-ah on, or in /oc under General -> General -> Auction House."
L["Item"] = true;
L["Qty"] = true;
L["Bid/ea"] = true;
L["Buyout/ea"] = true;
L["Total"] = true;
L["Time"] = true;
L["Seller"] = true;
L["Item name..."] = true;
L["Min"] = true;
L["Max"] = true;
L["Cancel"] = true;
L["Auction house: you are not at an auctioneer."] = true;
L["Auction house: type something to search for."] = true;
L["Auction house: finish or cancel the search first."] = true;
L["Auction house: the page did not come back. Nothing was bought."] = true;
L["Searching for %s..."] = true;
L["Page %d, %d of %d auctions"] = true;
L["Timed out. %d auctions found."] = true;
L["Cancelled. %d auctions found."] = true;
L["%d auctions found."] = true;
L["Scan All"] = true;
L["AUCTION_SCAN_ALL_TIP"] = "Scan the whole auction house to build the pricing data. Run it weekly to stay accurate."
L["AUCTION_FULL_SCAN_START"] = "Scanning the auction house, up to %d pages. Press Cancel at any point - whatever it has read is kept."
L["AUCTION_FULL_SCAN_START_ALL"] = "Scanning the whole auction house. Press Cancel at any point - whatever it has read is kept."
L["AUCTION_FULL_SCAN_RESUME"] = "Carrying on from page %d. Press Scan All again after this pass if there is more."
L["Scan All (resume)"] = true;
L["AUCTION_FULL_SCAN_STATUS"] = "Scanning the whole auction house..."
L["AUCTION_FULL_SCAN_PROGRESS"] = "Page %d - %d of %d auctions priced"
L["AUCTION_PROGRESS_PAGES"] = "Page %d of %d  -  %d auctions read"
L["AUCTION_PROGRESS_ETA"] = "Page %d of %d  -  %d auctions  -  %s left"
L["AUCTION_ETA_SECONDS"] = "%ds"
L["AUCTION_ETA_MINUTES"] = "%dm"
L["AUCTION_ETA_HOURS"] = "%dh %dm"
L["AUCTION_PROGRESS_STARTING"] = "Asking for page %d..."
L["AUCTION_FULL_SCAN_NO_ANSWER_SHORT"] = "The auction house did not answer. Re-open it from the auctioneer."
L["AUCTION_FULL_SCAN_NO_ANSWER"] = "The auction house did not answer a single page, which means the session is closed even though the window is open - usually after a /reload. Close this window, talk to the auctioneer again, then scan."
L["AUCTION_FULL_SCAN_DONE"] = "Auction house scanned: %d item(s) priced from %d auction(s). Their prices are on item tooltips now."
L["AUCTION_FULL_SCAN_PARTIAL"] = "Stopped early: %d item(s) priced from %d auction(s). What it read is kept."
L["AUCTION_FULL_SCAN_CAPPED"] = "Hit the page limit: %d item(s) priced from %d auction(s). Scan again to pick up the rest."
L["Stack of %d"] = true;
L["Bid %s each"] = true;
L["Buyout %s each"] = true;
L["Click to buy. The page it came from is re-queried first."] = true;
--Modules/Auction/Tabs/Search.lua -- the category browse, and Listing.lua's shared
--item tooltip
L["Category"] = true;
L["Subcategory"] = true;
L["Slot"] = true;
L["Quality"] = true;
L["Usable"] = true;
L["Clear"] = true;
L["All categories"] = true;
L["All subcategories"] = true;
L["All slots"] = true;
L["Any quality"] = true;
L["everything"] = true;
L["AUCTION_FILTER_USABLE_TIP"] = "Only show what your class and level can actually use."
L["AUCTION_FILTER_CLEAR_TIP"] = "Clears the category, quality, usable and level filters. What you have typed in the search box is left alone."
L["AUCTION_SEARCH_NEEDS_TERM"] = "Type an item name, or pick a category to browse - an unfiltered search is the whole auction house, which is what Scan All is for."
L["AUCTION_SEARCH_CAPPED"] = "First %d auctions - there are more. Narrow it with a subcategory or a level range."
L["AUCTION_ITEM_REQUIRES_LEVEL"] = "Requires level %d"

L["AUCTION_SEARCH_CLICK_BUYOUT"] = "Left click to buy it out for %s."
L["AUCTION_SEARCH_CLICK_BID"] = "Right click to bid %s."
L["AUCTION_SEARCH_NO_BID"] = "That auction cannot be bid on."
L["Buy"] = true;
L["AUCTION_BULK_TIP"] = "Type how many you want and press Buy. It works out the cheapest listings that reach that number, tells you what it costs and how far over or under it lands, and asks before spending anything."
L["AUCTION_BULK_NEEDS_QTY"] = "Type how many you want in the Qty box first."
L["AUCTION_BULK_NOTHING"] = "Nothing with a buyout is listed for %s. Search again, and remember your own auctions cannot be bought."
L["AUCTION_BULK_SUMMARY"] = "%s of %s, across %d auction(s)"
L["AUCTION_BULK_EXACT"] = "Buy exactly %d"
L["AUCTION_BULK_OVER"] = "Buy %d (you asked for %d)"
L["AUCTION_BULK_SHORT"] = "Only %d available of the %d you asked for - buy those"
L["AUCTION_BULK_PROGRESS"] = "Buying %d of %d..."
L["AUCTION_BULK_DONE"] = "Bought %d %s for %s."
L["AUCTION_BULK_STOPPED"] = "Stopped after %d %s (%s spent). The market moved - search again."
L["AUCTION_BULK_MISSED"] = "Bought %d %s for %s. %d auction(s) had already sold and were skipped."
L["AUCTION_BULK_STOPPED_MISSED"] = "Stopped after %d %s (%s spent) - %d auction(s) in a row had gone. The market moved; search again."
L["AUCTION_BUYLOG_HINT"] = "Run /octoui-ah buylog to see what happened to each one."
L["AUCTION_BUYLOG_EMPTY"] = "Auction buy log: nothing bought yet this session."
L["Lvl"] = true;

--Modules/Skins/Blizzard/Craft.lua -- the slot filter on the Enchanting window
L["All Slots"] = true;

--Modules/NamePlates -- cross-faction plates
L["Unflagged Players Are Friendly"] = true;
L["NP_UNFLAGGED_DESC"] = "This server lets Horde and Alliance group together, so an opposite faction player who is not flagged for PvP cannot be attacked and is shown as friendly. Flagged players still show as hostile. Switch off for vanilla behaviour, where any opposite faction player reads as an enemy."
L["CRAFT_SLOT_TIP"] = "Left click for the list of slots, right click to step through them one at a time."

--Modules/DataTexts/DataTexts.lua -- the battleground scoreboard on the chat panels
L["Battleground"] = true;
L["Killing Blows"] = true;
L["Honorable Kills"] = true;
L["Deaths"] = true;
L["Honor Gained"] = true;
L["DT_BG_WAITING"] = "Scoreboard..."
L["DT_BG_HONOR"] = "Honor: %d"
L["DT_BG_KILLS"] = "KB: %d  HK: %d"
L["DT_BG_DEATHS"] = "Deaths: %d"
L["DT_BG_CLICK_HIDE"] = "Click to show your normal datatexts instead."
L["AUCTION_QUERY_NONE"] = "Auction query: nothing has been searched yet this session."
L["AUCTION_QUERY_SENT"] = "Sent: name=%s class=%s subclass=%s invType=%s min=%s max=%s quality=%s usable=%s page=%s"
L["AUCTION_QUERY_ANSWER"] = "Answered: %d row(s) on the page, %d total, after %.2fs"
L["AUCTION_QUERY_NO_ANSWER"] = "Answered: nothing at all - the query was accepted and never served."
L["AUCTION_BUYLOG_HEADER"] = "Auction buy log: %d attempt(s), oldest first."
L["AUCTION_BUYLOG_ROW"] = "%d. %s x%d at %s - scan page %d, asked page %d - %s"
L["That auction has no buyout."] = true;
L["Buy %s for %s?"] = true;
L["Bought %s x%d for %s."] = true;
L["Bought %s x%d."] = true;
L["That auction is gone - it sold or expired. Search again."] = true;
L["AUCTION_ALREADY_SOLD"] = "That one has already sold. Search again for what is still up."
L["That auction is gone."] = true;
L["Checking that %s is still there..."] = true;
L["This tab has not been built yet."] = true;
L["yes"] = true;
L["no"] = true;
L["Auction window: not built yet."] = true;
L["AUCTION_STATUS_TABS"] = "Tab builders loaded: %s"
L["AUCTION_TAB_FAILED"] = "The %s tab failed: %s"
L["AUCTION_POSITION_RESET"] = "Auction window moved back to the centre of the screen."
L["AUCTION_RATE_LINE"] = "%s: %d samples, min %.2fs, avg %.2fs, max %.2fs"
L["AUCTION_RATE_NONE"] = "No scan timings yet. Run a search or Scan All, then /octoui-ah rate."
L["AUCTION_RATE_LEARNED"] = "Learned pace: %.2fs between pages, held at or above %.2fs because that dropped queries."
L["AUCTION_RATE_LEARNED_CLEAN"] = "Learned pace: %.2fs between pages. No pace has dropped a query yet - the server gate is doing all of it."
L["AUCTION_RATE_LAST"] = "Last %s: %d page(s), %d of %d auctions, ended '%s'."
L["AUCTION_RATE_RUNNING"] = "Still scanning: page %d, %d of %d auctions so far."
L["full scan"] = true;
L["search"] = true;
L["AUCTION_WINDOW_FAILED"] = "The auction window failed to build: %s"
L["AUCTION_FELL_BACK"] = "Falling back to Blizzard's auction house. Run /octoui-ah status and send the error above."
L["AUCTION_STATUS_WINDOW"] = "Auction window: built, showing tab '%s'."
L["AUCTION_STATUS_WIDTH"] = "Window %d, page %d, list %d."
L["AUCTION_STATUS_PRICES"] = "Price store loaded: %s. Price database present: %s."

--Modules/Auction/Tabs/Bids.lua
L["Your bid"] = true;
L["Next bid"] = true;
L["Buyout"] = true;
L["Status"] = true;
L["Winning"] = true;
L["Outbid"] = true;
L["AUCTION_BIDS_HINT"] = "Click a bid to raise it, or to buy the auction out."
L["AUCTION_BIDS_LOADING"] = "Reading your bids..."
L["AUCTION_BIDS_TIMEOUT"] = "The auction house did not send your bids back. Try Refresh."
L["AUCTION_BIDS_COUNT"] = "%d auction(s) you have bid on."
L["AUCTION_BID_YOU_LEAD"] = "You are the highest bidder."
L["AUCTION_BID_OUTBID_BY"] = "You have been outbid - %s takes it back."
L["AUCTION_BID_CLICK_BUYOUT"] = "Click to buy it out for %s."
L["AUCTION_BID_CLICK_BID"] = "Click to bid %s."
L["AUCTION_BID_ALREADY_LEADING"] = "You are already the highest bidder and there is no buyout to take."
L["AUCTION_BID_CONFIRM"] = "%s - %s"
L["AUCTION_BID_AS_BUYOUT"] = "buy it out for %s?"
L["AUCTION_BID_AS_BID"] = "bid %s?"
L["AUCTION_BID_PLACED"] = "Bid %s on %s."
L["AUCTION_BID_GONE"] = "That auction is no longer listed - it sold or expired."
L["AUCTION_BID_NO_LIST"] = "Could not re-read your bids, so nothing was bid."

--Modules/Auction/Tabs/Auctions.lua
L["Refresh"] = true;
L["Bidder"] = true;
L["AUCTION_OWN_HINT"] = "Click an auction to cancel it."
L["AUCTION_OWN_LOADING"] = "Reading your auctions..."
L["AUCTION_OWN_TIMEOUT"] = "The auction house did not send your auctions back. Try Refresh."
L["AUCTION_OWN_COUNT"] = "%d auction(s) of yours are up."
L["AUCTION_OWN_HAS_BID"] = "Bid of %s already placed - cancelling loses the deposit."
L["AUCTION_OWN_CLICK_CANCEL"] = "Click to cancel this auction."
L["AUCTION_CANCEL_CONFIRM"] = "Cancel %s? %s"
L["AUCTION_CANCEL_NO_BIDS"] = "No bids on it, so only the deposit stays spent."
L["AUCTION_CANCEL_LOSES_DEPOSIT"] = "It has a bid on it - the deposit is forfeit."
L["AUCTION_CANCELLED"] = "Cancelled %s x%d."
L["AUCTION_CANCEL_GONE"] = "That auction is no longer listed - it sold or expired."
L["AUCTION_CANCEL_NO_LIST"] = "Could not re-read your auctions, so nothing was cancelled."
L["AUCTION_CANCEL_BUSY"] = "Still reading your auctions. Try again in a moment."

--Modules/Auction/Tabs/Sell.lua
L["2h"] = true;
L["8h"] = true;
L["24h"] = true;
L["Stack size"] = true;
L["Stacks"] = true;
L["Duration"] = true;
L["Undercut"] = true;
L["Check now"] = true;
L["Post"] = true;
L["AUCTION_SELL_PICK_ITEM"] = "Right-click an item in your bags to put it up for sale."
L["AUCTION_SELL_STOCK"] = "%d in bags, largest stack %d"
L["AUCTION_SELL_SUMMARY"] = "Posting %d stack(s) of %d %s - buyout %s per stack, opening bid %s."
L["AUCTION_SELL_DEPOSIT"] = "Deposit %s."
L["AUCTION_SELL_SOURCE"] = "Market %s each, scanned %s."
L["AUCTION_SELL_NO_DATA"] = "This item has never been scanned, so there is no market price to undercut. Use Scan All, or Check now."
L["AUCTION_SELL_NEVER_SCANNED"] = "No scanned price for %s. Search for it, or run Scan All, then press Undercut."
L["AUCTION_SELL_NEEDS_PRICE"] = "Set a bid or a buyout before posting."
L["AUCTION_SELL_BUYOUT_BELOW_BID"] = "The buyout is below the opening bid, which the auction house will not accept."
L["AUCTION_SELL_CONFIRM"] = "Post %s for %s?"
L["AUCTION_SELL_CHECK_TIP"] = "Scan the auction house for this item again and reprice from what is on it right now. Runs automatically when you pick an item; this is for when it has been sitting a while."
L["AUCTION_SELL_CHECKING"] = "Checking prices..."
L["AUCTION_SELL_CHECKING_START"] = "Checking what %s is going for..."
L["AUCTION_SELL_CHECKING_PAGE"] = "Checking %s - page %d of %d"
L["AUCTION_SELL_NO_COMPETITION"] = "Nobody else is selling this, so there is nothing to undercut - name your price."
L["AUCTION_POST_PROGRESS"] = "Posting %d of %d..."
L["AUCTION_POST_STAGE"] = "Posting %d of %d - %s"
L["clearing the slot"] = true;
L["splitting the stack"] = true;
L["picking it up"] = true;
L["placing it"] = true;
L["waiting for the auction house"] = true;
L["AUCTION_POST_DONE"] = "Posted %d auction(s)."
L["AUCTION_POST_STOPPED"] = "Stopped after %d auction(s)."
L["AUCTION_POST_OUT_OF_STOCK"] = "Ran out of items after %d auction(s)."
L["AUCTION_POST_SLOT_FAILED"] = "Could not put the item in the auction slot. Stopped after %d auction(s)."
L["AUCTION_POST_SPLIT_FAILED"] = "Could not split the stack. Stopped after %d auction(s) - a bag slot was busy or there was nowhere to put the split."
L["AUCTION_POST_NO_BAG_SPACE"] = "No free bag slot. Splitting a stack needs somewhere to put the piece being split off - make room and try again."
L["AUCTION_POST_NO_CONFIRM"] = "The auction house did not confirm the last post, so nothing more was sent. %d auction(s) went up. Check the Auctions tab before trying again."

--Modules/Auction/Prices.lua -- the scanned price database, read by /octoui-ah prices
L["never"] = true;
L["unknown"] = true;
L["Auction prices: nothing has been scanned yet."] = true;
L["Auction prices: nothing stored matching %s."] = true;
L["Auction prices: %d reading(s) older than %d day(s) removed."] = true;
L["AUCTION_PRICE_REPORT_HEADER"] = "Auction prices: %d item(s) stored, oldest reading %s."
L["AUCTION_PRICE_REPORT_ROW"] = "%s - cheapest %s ea, typical %s ea, usual stack %d, %d auction(s) seen, %s"
L["AUCTION_PURGE_USAGE"] = "Usage: /octoui-ah purge <days> - removes stored prices older than that many days. Scanning is the only way to get them back."
