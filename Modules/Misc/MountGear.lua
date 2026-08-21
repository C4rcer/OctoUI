local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local pairs, ipairs, type, tonumber = pairs, ipairs, type, tonumber
local getn, tinsert = table.getn, table.insert
local format, lower, gsub, find = string.format, string.lower, string.gsub, string.find
--WoW API / Variables
local CreateFrame = CreateFrame
local CursorHasItem = CursorHasItem
local GetContainerItemLink = GetContainerItemLink
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerNumSlots = GetContainerNumSlots
local GetInventoryItemLink = GetInventoryItemLink
local GetInventorySlotInfo = GetInventorySlotInfo
local GetItemInfo = GetItemInfo
local UnitAffectingCombat = UnitAffectingCombat

--PickupContainerItem, PickupInventoryItem and ClearCursor are deliberately NOT cached the
--way everything above is. The Bags module replaces those three globals to track whether
--what the cursor holds is a protected item, and a cached copy taken at load would be the
--original -- bypassing that and leaving its flag describing an item that is no longer
--there. Resolving them at call time keeps the guards in the loop.

--[[
	Riding gear that goes on with the mount and comes off with it.

	MOUNT DETECTION IS NOT REBUILT HERE. AutoDismount already answers "is this player buff a
	mount" for this client, tooltip wording and Turtle's riding-skill lines included, and it
	was measured rather than guessed. M:DismountScanBuffs is that same check, so this asks it
	instead of starting a second list of mount textures that would drift out of step.

	THE SLOT IS REMEMBERED, NOT THE OUTFIT. What was in the slot before the swap is written
	down at the moment it is displaced, and put back when the mount goes. That survives a
	/reload because it lives in the profile: reloading while mounted used to be the obvious
	way to lose track of a displaced trinket forever.

	ONLY WHAT WE DID IS UNDONE. Restore checks that the slot still holds the riding item
	before touching it. Change gear yourself while mounted and your choice stands -- the
	alternative is an addon that quietly reverses a deliberate swap.

	NO GEAR CHANGES IN COMBAT. The transition is remembered and applied when the combat flag
	drops, which is the common case for the way OFF: something attacks you, the mount is
	gone, and the restore has to wait.

	THE CURSOR, NOT UseContainerItem. A right-click equips to whichever slot the client
	picks, which is a guess for a trinket, and this addon's own bag protection intercepts
	UseContainerItem to toggle a lock when Alt is held -- an automatic call arriving at the
	wrong moment would toggle protection instead of equipping. Pick up, place in the exact
	inventory slot, put whatever came off into the bag slot just vacated: no guessing, and
	no dependence on a modifier key nobody is thinking about.
]]

--The four slots worth swapping for on this client. Names are the ones
--GetInventorySlotInfo takes, and match the list in Compatibility/api/wowAPI.lua.
local SLOTS = {
	{key = "Trinket0Slot", alias = "trinket1", label = "Trinket 1"},
	{key = "Trinket1Slot", alias = "trinket2", label = "Trinket 2"},
	{key = "FeetSlot", alias = "boots", label = "Boots"},
	{key = "HandsSlot", alias = "gloves", label = "Gloves"}
}

local mountGearFrame
local mounted
local pendingAction
local lastResults = {}

--Declared with the rest of the state rather than beside the re-apply code below, because
--ApplyMountGear sets `applying` and a local declared after that function would not be the
--one it writes to -- the assignment would land on a global and the guard would never fire.
local applying
local reapplyPending

local function Store()
	local db = E.db.general
	if not db.mountGear then
		db.mountGear = {}
	end

	local mg = db.mountGear
	--Off by default. Everything here moves the player's equipment around, and that is not
	--something to start doing because an update landed.
	if mg.enable == nil then mg.enable = false end
	if not mg.slots then mg.slots = {} end
	if not mg.saved then mg.saved = {} end
	--The gear you FIGHT in, declared rather than inferred. `saved` records whatever
	--happened to be displaced; that is only the right thing to put back if you were
	--already wearing the right thing when you mounted. This is what should be on when
	--the mount goes, whatever was on when it arrived.
	if not mg.fight then mg.fight = {} end

	return mg
end

local function LinkID(link)
	if not link then return nil end
	local _, _, id = find(link, "item:(%d+)")
	return id and tonumber(id) or nil
end

local function LinkName(link)
	if not link then return nil end
	local _, _, name = find(link, "%[(.-)%]")
	return name
end

--Accepts a shift-clicked link, a bare item id, or a name typed by hand.
function M:ParseMountGearItem(text)
	if type(text) ~= "string" then return nil end

	text = gsub(text, "^%s+", "")
	text = gsub(text, "%s+$", "")
	if text == "" then return nil end

	local id = LinkID(text)
	if id then
		return {id = id, name = LinkName(text)}
	end

	if find(text, "^%d+$") then
		local numeric = tonumber(text)
		--Not tail-called: GetItemInfo returns nine values and all nine would be returned.
		local name = GetItemInfo(numeric)
		if name == "" then name = nil end
		return {id = numeric, name = name}
	end

	return {name = text}
end

function M:MountGearLabel(entry)
	if not entry then return nil end

	if not entry.name and entry.id then
		local name = GetItemInfo(entry.id)
		if name and name ~= "" then entry.name = name end
	end

	if entry.name then return entry.name end
	if entry.id then return format(L["MOUNTGEAR_ITEM_ID"], entry.id) end
	return nil
end

--Either half matching is enough. An entry recorded from a link has both, one typed by hand
--has only a name, and a server item this client cannot look up may never resolve to more
--than an id.
local function ItemMatches(entry, link)
	if not entry or not link then return false end

	local id = LinkID(link)
	if entry.id and id and entry.id == id then return true end

	local name = LinkName(link)
	if entry.name and name and lower(entry.name) == lower(name) then return true end

	return false
end

local function NumBags()
	return NUM_BAG_FRAMES or 4
end

local function FindInBags(entry)
	for bag = 0, NumBags() do
		for slot = 1, GetContainerNumSlots(bag) do
			if ItemMatches(entry, GetContainerItemLink(bag, slot)) then
				return bag, slot
			end
		end
	end

	return nil
end

--Backpack first, since it takes anything. A specialised bag can refuse what is being put
--into it, and the only sign of that is the item staying on the cursor -- which the callers
--below check for rather than assume.
local function FindFreeBagSlot()
	for bag = 0, NumBags() do
		for slot = 1, GetContainerNumSlots(bag) do
			if not GetContainerItemLink(bag, slot) then return bag, slot end
		end
	end

	return nil
end

--[[
	The swap itself.

	Pick the item up, place it in the inventory slot, and put whatever came off into the bag
	slot just emptied. Every step is checked against the cursor rather than assumed: a
	locked slot, a bag that will not take the item, or a pickup the client simply ignored
	all show up as the cursor still being full, and each one gets a reason the report can
	name. ClearCursor is the last resort -- it returns the item to where it came from, which
	is a great deal better than leaving it stuck to the pointer.
]]
local function EquipFromBag(bag, slot, invSlot)
	if CursorHasItem() then return false, L["MOUNTGEAR_CURSOR_BUSY"] end

	local _, _, locked = GetContainerItemInfo(bag, slot)
	if locked then return false, L["MOUNTGEAR_LOCKED"] end

	PickupContainerItem(bag, slot)
	if not CursorHasItem() then return false, L["MOUNTGEAR_NO_PICKUP"] end

	PickupInventoryItem(invSlot)

	if CursorHasItem() then
		PickupContainerItem(bag, slot)
	end

	if CursorHasItem() then
		ClearCursor()
		return false, L["MOUNTGEAR_CURSOR_STUCK"]
	end

	return true
end

local function UnequipToBags(invSlot)
	if not GetInventoryItemLink("player", invSlot) then return true end
	if CursorHasItem() then return false, L["MOUNTGEAR_CURSOR_BUSY"] end

	local bag, slot = FindFreeBagSlot()
	if not bag then return false, L["MOUNTGEAR_NO_SPACE"] end

	PickupInventoryItem(invSlot)
	if not CursorHasItem() then return false, L["MOUNTGEAR_NO_PICKUP"] end

	PickupContainerItem(bag, slot)

	if CursorHasItem() then
		ClearCursor()
		return false, L["MOUNTGEAR_CURSOR_STUCK"]
	end

	return true
end

local function Record(def, ok, detail)
	tinsert(lastResults, {slot = def.label, ok = ok and true or false, detail = detail})
end

function M:ApplyMountGear()
	local db = Store()
	lastResults = {}

	--Our own swaps fire UNIT_INVENTORY_CHANGED, which is what asks for a re-apply. This
	--flag is what stops that being a loop.
	applying = true

	for _, def in ipairs(SLOTS) do
		local entry = db.slots[def.key]
		if entry and (entry.id or entry.name) then
			local invSlot = GetInventorySlotInfo(def.key)
			local current = GetInventoryItemLink("player", invSlot)

			if ItemMatches(entry, current) then
				--Already on. Nothing is written down, so the restore leaves it alone too --
				--it was the player's own choice before the mount and stays theirs after.
				Record(def, true, L["MOUNTGEAR_ALREADY_ON"])
			else
				local bag, slot = FindInBags(entry)
				if not bag then
					Record(def, false, L["MOUNTGEAR_NOT_IN_BAGS"])
				else
					--Written down BEFORE the swap. An empty slot is remembered as empty,
					--which restore reads as "take ours back off again".
					--ONLY THE FIRST DISPLACEMENT IS REMEMBERED. Take the riding item off
					--while still mounted and this runs again to put it back -- overwriting
					--here would record whatever was in the slot at that moment (usually
					--nothing) as the thing you are owed, and your real trinket would never
					--come back.
					--
					--The link is kept alongside the id and name purely so the report can show
					--exactly what is owed back, including an item this client cannot name.
					local justSaved
					if not db.saved[def.key] then
						db.saved[def.key] = current and {id = LinkID(current), name = LinkName(current), link = current} or {empty = true}
						justSaved = true
					end

					local ok, why = EquipFromBag(bag, slot, invSlot)
					if ok then
						Record(def, true, L["MOUNTGEAR_EQUIPPED"])
					elseif justSaved then
						--Nothing moved, so nothing is owed back -- but only the record THIS
						--pass wrote is dropped. An earlier successful swap on this slot is
						--still owed, and clearing it here would strand the player's trinket.
						db.saved[def.key] = nil
						Record(def, false, why)
					else
						Record(def, false, why)
					end
				end
			end
		end
	end

	applying = nil
end

--[[
	Riding gear that comes off while the mount is still under you.

	Reported 2026-08-13: take the trinket off mid-flight and nothing put it back. Nothing
	could -- the gear was applied on the TRANSITION into mounted and never looked at again,
	so the only thing that could have restored it was dismounting and mounting a second time.

	While the mount is up, these slots belong to the riding set: anything that leaves one of
	them empty, or fills it with something else, is put right. Deliberately one-directional.
	Taking a riding item off while mounted is nearly always the bags being tidied or an
	on-use trinket being swapped back by another addon, not a decision -- and the way to
	stop it for good is to clear the box, not to fight it every time.

	The cheap test runs first: one GetInventoryItemLink per configured slot. Only when a
	slot is actually wrong does the expensive bag walk happen.
]]
local function NeedsReapply()
	local db = Store()

	for _, def in ipairs(SLOTS) do
		local entry = db.slots[def.key]
		if entry and (entry.id or entry.name) then
			local invSlot = GetInventorySlotInfo(def.key)
			if not ItemMatches(entry, GetInventoryItemLink("player", invSlot)) then
				return true
			end
		end
	end

	return false
end

local function ReapplyCheck()
	reapplyPending = nil

	if not mounted then return end
	if not Store().enable then return end
	if not NeedsReapply() then return end

	--Held for the end of the fight rather than dropped, same as every other transition.
	if UnitAffectingCombat("player") then
		pendingAction = "equip"
		return
	end

	M:ApplyMountGear()
end

--Coalesced, because one swap fires several inventory events and the check would otherwise
--run in the middle of our own three-step equip, reading a slot that is mid-move.
local function ScheduleReapply()
	if reapplyPending or applying then return end

	reapplyPending = true
	E:Delay(0.2, ReapplyCheck)
end

function M:RestoreMountGear()
	local db = Store()
	lastResults = {}

	for _, def in ipairs(SLOTS) do
		--A DECLARED FIGHT ITEM OUTRANKS WHAT WAS DISPLACED. `saved` only records what
		--was in the slot at the moment of mounting, which is the right thing to put
		--back only if it was right to begin with. Mount up wearing the wrong trinket
		--and the old behaviour faithfully returned the wrong trinket.
		local wanted = db.fight[def.key]
		local saved = db.saved[def.key]

		if wanted or saved then
			local invSlot = GetInventorySlotInfo(def.key)
			local current = GetInventoryItemLink("player", invSlot)

			--Only undo our own swap. Anything else in the slot was put there deliberately
			--while mounted, and that decision outranks this one.
			if not ItemMatches(db.slots[def.key], current) then
				Record(def, true, L["MOUNTGEAR_CHANGED_BY_HAND"])
				db.saved[def.key] = nil
			elseif wanted and ItemMatches(wanted, current) then
				--Riding item and fight item are the same thing. Nothing to do, and
				--trying would send FindInBags hunting for an item already worn.
				Record(def, true, L["MOUNTGEAR_FIGHT_ALREADY"])
				db.saved[def.key] = nil
			elseif wanted then
				local bag, slot = FindInBags(wanted)
				if not bag then
					--Left for the next dismount, same as a missing displaced item: it
					--may be in the bank rather than gone.
					Record(def, false, L["MOUNTGEAR_FIGHT_NOT_IN_BAGS"])
				else
					local ok, why = EquipFromBag(bag, slot, invSlot)
					Record(def, ok, ok and L["MOUNTGEAR_FIGHT_RESTORED"] or why)
					if ok then db.saved[def.key] = nil end
				end
			elseif saved.empty then
				local ok, why = UnequipToBags(invSlot)
				Record(def, ok, ok and L["MOUNTGEAR_REMOVED"] or why)
				if ok then db.saved[def.key] = nil end
			else
				local bag, slot = FindInBags(saved)
				if not bag then
					--Kept rather than dropped: the item may be in the bank, and the next
					--dismount with it to hand should still put it back.
					Record(def, false, L["MOUNTGEAR_OLD_NOT_IN_BAGS"])
				else
					local ok, why = EquipFromBag(bag, slot, invSlot)
					Record(def, ok, ok and L["MOUNTGEAR_RESTORED"] or why)
					if ok then db.saved[def.key] = nil end
				end
			end
		end
	end
end

function M:MountGearIsMounted()
	if not M.DismountScanBuffs then return false end

	local mounts = M:DismountScanBuffs()
	return (mounts and getn(mounts) > 0) and true or false
end

--Gear cannot be swapped in combat, so the transition is held and replayed when the flag
--drops. Only the latest one is kept: mounting and dismounting inside one fight leaves
--exactly one thing worth doing at the end of it.
local function RunOrDefer(action)
	if UnitAffectingCombat("player") then
		pendingAction = action
		return
	end

	pendingAction = nil
	if action == "equip" then
		M:ApplyMountGear()
	else
		M:RestoreMountGear()
	end
end

function M:UpdateMountGear()
	local db = Store()
	if not db.enable then return end

	--Nothing can mount in combat, so an unmounted player in a fight has no transition to
	--find and the buff scan can be skipped entirely. Mounted is different: that is exactly
	--when combat takes the mount away.
	if not mounted and UnitAffectingCombat("player") then return end

	local isMounted = M:MountGearIsMounted()
	if isMounted == mounted then return end

	mounted = isMounted
	RunOrDefer(isMounted and "equip" or "restore")
end

--PLAYER_AURAS_CHANGED arrives in bursts -- one per aura, and a fight or a round of buffing
--produces a great many -- while the check behind it is a tooltip scan of every player buff.
--Coalescing them into one look a tenth of a second later costs nothing anyone can feel on a
--gear swap and takes the scan off the hot path.
local checkPending

local function ScheduleCheck()
	if checkPending then return end
	if not Store().enable then return end

	checkPending = true
	E:Delay(0.1, function()
		checkPending = nil
		M:UpdateMountGear()
	end)
end

function M:GetMountGearSlots()
	return SLOTS
end

function M:GetMountGearSettings()
	return Store()
end

--Forget the last known state and look again. Turning the feature on has to do this or
--nothing happens until the next aura change -- which, if you are already sitting on a
--mount, may not be until you get off it. The options toggle always did this; the slash
--command did not, which made "/octoui-mountgear on" while mounted look like a dead feature.
function M:ResetMountGearState()
	mounted = nil
	M:UpdateMountGear()
end

function M:GetMountGearResults()
	return lastResults, pendingAction
end

function M:SetMountGearItem(slotKey, text)
	local db = Store()

	if not text or text == "" then
		db.slots[slotKey] = nil
		return nil
	end

	db.slots[slotKey] = M:ParseMountGearItem(text)
	return db.slots[slotKey]
end

--The fight-gear counterpart. Separate function rather than a third argument on the
--one above, so no existing caller can land in the wrong table by omission.
function M:SetFightGearItem(slotKey, text)
	local db = Store()

	if not text or text == "" then
		db.fight[slotKey] = nil
		return nil
	end

	db.fight[slotKey] = M:ParseMountGearItem(text)
	return db.fight[slotKey]
end

function M:GetFightGearItem(slotKey)
	return Store().fight[slotKey]
end

--[[
	The options page, built here rather than in Config/ for the same reason Blacklist's is:
	Config files are read from the .toc at process start, so a change there needs a full
	exit of the client while a change here needs only /reload.
]]
local function BuildOptions()
	local general = E.Options and E.Options.args and E.Options.args.general
	if not general or not general.args then return end

	local args = {
		intro = {
			order = 1,
			type = "description",
			name = L["Puts riding gear on with the mount and your own gear back when it goes. Leave a box empty to leave that slot alone. Shift-click an item into a box, or type an item id or name."]
		},
		enable = {
			order = 2,
			type = "toggle",
			name = L["Enable"],
			desc = L["Off by default, because this moves your equipment around on its own."],
			get = function() return Store().enable and true or false end,
			set = function(_, value)
				Store().enable = value and true or false
				M:ResetMountGearState()
			end
		},
		combat = {
			order = 3,
			type = "description",
			name = L["Gear cannot be swapped in combat. A change that lands mid-fight is held until the fight ends."]
		}
	}

	args.ridingHeader = {
		order = 9,
		type = "header",
		name = L["Riding gear"]
	}

	for index, def in ipairs(SLOTS) do
		local key = def.key
		args[key] = {
			order = 10 + index,
			type = "input",
			width = "full",
			name = L[def.label],
			desc = L["The item to wear in this slot while mounted."],
			get = function()
				return M:MountGearLabel(Store().slots[key]) or ""
			end,
			set = function(_, value)
				M:SetMountGearItem(key, value)
			end
		}
	end

	args.fightHeader = {
		order = 20,
		type = "header",
		name = L["Fight gear"]
	}

	args.fightIntro = {
		order = 21,
		type = "description",
		name = L["What to put back on when the mount goes. Leave a box empty and that slot returns whatever it was wearing before you mounted, which is only right if it was right at the time."]
	}

	for index, def in ipairs(SLOTS) do
		local key = def.key
		args["fight"..key] = {
			order = 21 + index,
			type = "input",
			width = "full",
			name = L[def.label],
			desc = L["The item to wear in this slot when not mounted."],
			get = function()
				return M:MountGearLabel(Store().fight[key]) or ""
			end,
			set = function(_, value)
				M:SetFightGearItem(key, value)
			end
		}
	end

	general.args.mountGear = {
		--Between Loot Rolls (5) and Chat Bubbles (6), which already own whole numbers here.
		order = 5.5,
		type = "group",
		name = L["Mount Gear"],
		args = args
	}
end

function M:LoadMountGear()
	Store()
	BuildOptions()

	--Its own frame rather than M:RegisterEvent, because Misc already registers events on
	--the module elsewhere and AceEvent keeps one callback per event per object.
	mountGearFrame = CreateFrame("Frame")
	mountGearFrame:RegisterEvent("PLAYER_AURAS_CHANGED")
	mountGearFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	mountGearFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	--Riding gear taken off while the mount is still up. See ReapplyCheck.
	mountGearFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")

	mountGearFrame:SetScript("OnEvent", function()
		if event == "UNIT_INVENTORY_CHANGED" then
			--Fires for every unit whose equipment the client can see; only ours matters, and
			--this one is common enough that the mount check must not run for anyone else's.
			if arg1 == "player" then ScheduleReapply() end
			return
		end

		if event == "PLAYER_REGEN_ENABLED" then
			--The held transition first, and straight away rather than coalesced -- this is
			--the moment the player has been waiting for their own gear back.
			if pendingAction and Store().enable then
				RunOrDefer(pendingAction)
			end
		end

		--Then a fresh look either way: the mount may well have gone during the fight that
		--just ended.
		ScheduleCheck()
	end)
end
