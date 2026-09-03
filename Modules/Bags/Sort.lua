local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local B = E:GetModule("Bags");
local Search = LibStub("LibItemSearch-1.2");
local LIP = LibStub("ItemPrice-1.1");

--Cache global variables
--Lua functions
local ipairs, pairs, tonumber, select, unpack, pcall = ipairs, pairs, tonumber, select, unpack, pcall
local next = next
local getn, tinsert, tremove, tsort, twipe = table.getn, table.insert, table.remove, table.sort, table.wipe
local floor, mod = math.floor, math.mod
local band = bit.band
local match, gmatch, find, format, lower = string.match, string.gmatch, string.find, string.format, string.lower
--WoW API / Variables
local ContainerIDToInventoryID = ContainerIDToInventoryID
local CursorHasItem = CursorHasItem
local GetAuctionItemClasses = GetAuctionItemClasses
local GetAuctionItemSubClasses = GetAuctionItemSubClasses
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerItemLink = GetContainerItemLink
local GetContainerNumSlots = GetContainerNumSlots
local GetInventoryItemLink = GetInventoryItemLink
local GetItemInfo = GetItemInfo
local GetTime = GetTime
local PickupContainerItem = PickupContainerItem
local PickupInventoryItem = PickupInventoryItem
local BankButtonIDToInvSlotID = BankButtonIDToInvSlotID
local BANK_CONTAINER = BANK_CONTAINER
local SplitContainerItem = SplitContainerItem
local ARMOR, EN = ARMOR

local MAX_MOVE_TIME = 1.25
--How long a move may keep failing before the sort gives up. Measured from the FIRST
--failure, not the last -- see stallStart in DoMoves.
local MAX_STALL_TIME = 5

--Copied rather than referenced so that nothing in here can mutate the lists the bag
--frames are built from. See the note on B.BankIDs in Bags.lua for why these are not
--derived from NUM_BAG_SLOTS/NUM_BANKBAGSLOTS any more.
local bankBags = {}
for _, id in ipairs(B.BankIDs) do
	tinsert(bankBags, id)
end

local playerBags = {}
for _, id in ipairs(B.PlayerIDs) do
	tinsert(playerBags, id)
end

local allBags = {}
for _, i in ipairs(playerBags) do
	tinsert(allBags, i)
end
for _, i in ipairs(bankBags) do
	tinsert(allBags, i)
end

local coreGroups = {
	bank = bankBags,
	bags = playerBags,
	all = allBags,
}

local bagCache = {}
local bagIDs = {}
local bagQualities = {}
local bagStacks = {}
local bagMaxStacks = {}
local bagGroups = {}
local initialOrder = {}
local itemTypes, itemSubTypes = {}, {}
local bagSorted, bagLocked = {}, {}
local moves = {}
local targetItems = {}
local sourceUsed = {}
local targetSlots = {}
local specialtyBags = {}
local emptySlots = {}
--Slots holding an item this client has no data for -- see ScanBags. On a Vanilla+ server
--this is the interesting set, not an edge case.
local bagUnknown = {}
--Slots the CLIENT reports as locked. Not OctoUI's padlock (that is a saved item-id list in
--Bags.lua and touches nothing here) -- this is the real flag, and a slot carrying it will
--refuse every move made through it for as long as it is set. See ScanBags.
local stuckSlots = {}
local stuckCount = 0
--The move queue as PLANNED, with one verdict line per move, captured at StartStacking.
--
--Neither of the obvious places to look survives the failure. The live queue is wiped by
--StopStacking, and when planning itself throws, the queue is never filled at all -- so by
--the time anyone runs /octoui-bags there is nothing left to inspect. This copy is what the
--report audits.
local plannedMoves, moveVerdicts, suspectVerdicts = {}, {}, {}
local plannedSuspects = 0
--Moves abandoned so the rest of the queue could run, and the per-move clock that decides
--when to abandon one. See the failure branch in RunMoves.
local deferredMoves, moveStall = {}, {}

local moveRetries = 0
local lastItemID, currentItemID, lockStop, lastDestination, lastMove
--Deliberately NOT cleared by the per-pass reset in DoMoves. See the note there.
local stallStart
local moveTracker = {}

local inventorySlots = {
	INVTYPE_AMMO = 0,
	INVTYPE_HEAD = 1,
	INVTYPE_NECK = 2,
	INVTYPE_SHOULDER = 3,
	INVTYPE_BODY = 4,
	INVTYPE_CHEST = 5,
	INVTYPE_ROBE = 5,
	INVTYPE_WAIST = 6,
	INVTYPE_LEGS = 7,
	INVTYPE_FEET = 8,
	INVTYPE_WRIST = 9,
	INVTYPE_HAND = 10,
	INVTYPE_FINGER = 11,
	INVTYPE_TRINKET = 12,
	INVTYPE_CLOAK = 13,
	INVTYPE_WEAPON = 14,
	INVTYPE_SHIELD = 15,
	INVTYPE_2HWEAPON = 16,
	INVTYPE_WEAPONMAINHAND = 18,
	INVTYPE_WEAPONOFFHAND = 19,
	INVTYPE_HOLDABLE = 20,
	INVTYPE_RANGED = 21,
	INVTYPE_THROWN = 22,
	INVTYPE_RANGEDRIGHT = 23,
	INVTYPE_RELIC = 24,
	INVTYPE_TABARD = 25,
}

local safe = {
	[BANK_CONTAINER] = true,
	[0] = true
}

local frame = CreateFrame("Frame")
local t, WAIT_TIME = 0, 0.05
frame:SetScript("OnUpdate", function()
	t = t + (arg1 or 0.01)
	if t > WAIT_TIME then
		t = 0
		B:DoMoves()
	end
end)
frame:Hide()
B.SortUpdateTimer = frame

local function BuildSortOrder()
	for i, iType in ipairs({GetAuctionItemClasses()}) do
		itemTypes[iType] = i
		itemSubTypes[iType] = {}
		for ii, isType in ipairs({GetAuctionItemSubClasses(i)}) do
			itemSubTypes[iType][isType] = ii
		end
	end
end

local function UpdateLocation(from, to)
	--THE BAG FREEZE. `bagStacks[to] < bagMaxStacks[to]` compares a number against nil the
	--moment GetItemInfo has no data for the item in `to`, and Lua raises rather than
	--returning false. bagMaxStacks is nil for exactly one reason: ScanBags could not read a
	--stack size, which on this server is every custom quest item the client has not cached.
	--
	--Two copies of such an item are enough. Stack() sees `bagStacks ~= bagMaxStacks`
	--(number ~= nil, so true), decides the stack is partial, and calls AddMove -> here.
	--
	--This throws inside the PLANNING phase, which is why none of the DoMoves timeouts ever
	--fired: the sort button has already unregistered the bag frame's events and desaturated
	--every slot, and the error means StartStacking is never reached, so the timer never
	--shows, StopStacking never runs, and RegisterUpdateDelayed never re-registers anything.
	--Bags grey, sorting refusing, logout required -- with no error visible unless the client
	--has Lua errors switched on.
	--
	--ScanBags now guarantees a number here, and the guard stays because a nil is a bug
	--worth surviving rather than a state worth crashing on.
	local stackSize = bagMaxStacks[to]
	if (bagIDs[from] == bagIDs[to]) and stackSize and bagStacks[to] and bagStacks[from]
		and (bagStacks[to] < stackSize) then
		if (bagStacks[to] + bagStacks[from]) > stackSize then
			bagStacks[from] = bagStacks[from] - (stackSize - bagStacks[to])
			bagStacks[to] = stackSize
		else
			bagStacks[to] = bagStacks[to] + bagStacks[from]
			bagStacks[from] = nil
			bagIDs[from] = nil
			bagQualities[from] = nil
			bagMaxStacks[from] = nil
		end
	else
		bagIDs[from], bagIDs[to] = bagIDs[to], bagIDs[from]
		bagQualities[from], bagQualities[to] = bagQualities[to], bagQualities[from]
		bagStacks[from], bagStacks[to] = bagStacks[to], bagStacks[from]
		bagMaxStacks[from], bagMaxStacks[to] = bagMaxStacks[to], bagMaxStacks[from]
	end
end

local function PrimarySort(a, b)
	local aName, aLink, _, aLvl = GetItemInfo(bagIDs[a])
	local bName, bLink, _, bLvl = GetItemInfo(bagIDs[b])

	local aPrice = LIP:GetSellValue(aLink)
	local bPrice = LIP:GetSellValue(bLink)

	if aLvl ~= bLvl and aLvl and bLvl then
		return aLvl > bLvl
	end

	if aPrice ~= bPrice and aPrice and bPrice then
		return aPrice > bPrice
	end

	if aName and bName then
		return aName < bName
	end
end

local function DefaultSort(a, b)
	local aID = bagIDs[a]
	local bID = bagIDs[b]

	if (not aID) or (not bID) then return aID end

	local aOrder, bOrder = initialOrder[a], initialOrder[b]

	if aID == bID then
		local aCount = bagStacks[a]
		local bCount = bagStacks[b]
		if aCount and bCount and aCount == bCount then
			return aOrder < bOrder
		elseif aCount and bCount then
			return aCount < bCount
		end
	end

	local _, _, _, _, aType, aSubType, _, aEquipLoc = GetItemInfo(aID)
	local _, _, _, _, bType, bSubType, _, bEquipLoc = GetItemInfo(bID)

	local aRarity, bRarity = bagQualities[a], bagQualities[b]

	if aRarity ~= bRarity and aRarity and bRarity then
		return aRarity > bRarity
	end

	local aItemClassId, aItemSubClassId = itemTypes[aType] or 99, itemSubTypes[aType] and itemSubTypes[aType][aSubType] or 99
	local bItemClassId, bItemSubClassId = itemTypes[bType] or 99, itemSubTypes[bType] and itemSubTypes[bType][bSubType] or 99

	if aItemClassId ~= bItemClassId then
		return aItemClassId < bItemClassId
	end

	if aItemClassId == 1 or aItemClassId == 2 then
		local aEquipLoc = inventorySlots[aEquipLoc] or -1
		local bEquipLoc = inventorySlots[bEquipLoc] or -1
		if aEquipLoc == bEquipLoc then
			return PrimarySort(a, b)
		end

		if aEquipLoc and bEquipLoc then
			return aEquipLoc < bEquipLoc
		end
	end
	if (aItemClassId == bItemClassId) and (aItemSubClassId == bItemSubClassId) then
		return PrimarySort(a, b)
	end

	return (aItemSubClassId or 99) < (bItemSubClassId or 99)
end

local function ReverseSort(a, b)
	return DefaultSort(b, a)
end

local function UpdateSorted(source, destination)
	for i, bs in pairs(bagSorted) do
		if bs == source then
			bagSorted[i] = destination
		elseif bs == destination then
			bagSorted[i] = source
		end
	end
end

local function ShouldMove(source, destination)
	if destination == source then return end

	if not bagIDs[source] then return end
	if bagIDs[source] == bagIDs[destination] and bagStacks[source] == bagStacks[destination] then return end

	return true
end

local function IterateForwards(bagList, i)
	i = i + 1
	local step = 1
	for _, bag in ipairs(bagList) do
		local slots = B:GetNumSlots(bag)
		if i > slots + step then
			step = step + slots
		else
			for slot = 1, slots do
				if step == i then
					return i, bag, slot
				end
				step = step + 1
			end
		end
	end
end

local function IterateBackwards(bagList, i)
	i = i + 1
	local step = 1
	for ii = getn(bagList), 1, -1 do
		local bag = bagList[ii]
		local slots = B:GetNumSlots(bag)
		if i > slots + step then
			step = step + slots
		else
			for slot = slots, 1, -1 do
				if step == i then
					return i, bag, slot
				end
				step = step + 1
			end
		end
	end
end

function B.IterateBags(bagList, reverse)
	return (reverse and IterateBackwards or IterateForwards), bagList, 0
end

function B:GetItemID(bag, slot)
	local link = self:GetItemLink(bag, slot)
	return link and tonumber(match(link, "item:(%d+)"))
end

function B:GetItemInfo(bag, slot)
	return GetContainerItemInfo(bag, slot)
end

function B:GetItemLink(bag, slot)
	return GetContainerItemLink(bag, slot)
end

function B:PickupItem(bag, slot)
	currentItemID = self:GetItemID(bag, slot)

	--The main bank container is only half a container as far as 1.12 is concerned: it
	--reads fine through GetContainerNumSlots and GetContainerItemLink, but Blizzard's
	--own bank buttons pick up with PickupInventoryItem on an inventory slot, not with
	--PickupContainerItem. Ask the wrong one and nothing lands on the cursor, no error
	--is raised, and DoMove reports the move a success -- which is exactly how a bank
	--sort planned 29 moves and shifted not a single item.
	if bag == BANK_CONTAINER and BankButtonIDToInvSlotID and PickupInventoryItem then
		return PickupInventoryItem(BankButtonIDToInvSlotID(slot))
	end

	return PickupContainerItem(bag, slot)
end

function B:SplitItem(bag, slot, amount)
	return SplitContainerItem(bag, slot, amount)
end

function B:GetNumSlots(bag)
	if bag then
		return GetContainerNumSlots(bag)
	end

	return 0
end

local function ConvertLinkToID(link)
	if not link then return end

	if tonumber(match(link, "item:(%d+)")) then
		return tonumber(match(link, "item:(%d+)"))
	end
end

local function DefaultCanMove()
	return true
end

function B:Encode_BagSlot(bag, slot)
	return (bag * 100) + slot
end

--Subtraction rather than mod, because the bank container is bag -1 and Lua 5.0's
--math.mod is C fmod: the result takes the sign of the *dividend*, so slot 1 of the
--bank encodes to -99 and mod(-99, 100) gives back -99 instead of 1. Every bank
--container move then read an empty slot, DoMove found no source item and bailed out
--with "Confused.. Try Again!" before picking anything up -- which is the whole of why
--bank sorting did nothing while bag sorting was fine. Bags 0-4 never go negative.
--floor already rounds towards minus infinity, so bag * 100 is the exact base.
function B:Decode_BagSlot(int)
	local bag = floor(int / 100)
	return bag, int - (bag * 100)
end

function B:IsPartial(bag, slot)
	local bagSlot = B:Encode_BagSlot(bag, slot)
	return ((bagMaxStacks[bagSlot] or 0) - (bagStacks[bagSlot] or 0)) > 0
end

function B:EncodeMove(source, target)
	return (source * 10000) + target
end

--Same trap one level up: a move is source * 10000 + target, and either half can be
--a negative bank-container slot. Subtraction keeps t in [0, 10000) whatever the sign
--of the move, which is what upstream's fix-up below already assumed -- it converts a
--target that was itself negative back, and could never fire when mod handed it a
--negative t.
function B:DecodeMove(move)
	local s = floor(move / 10000)
	local t = move - (s * 10000)
	s = (t > 9000) and (s + 1) or s
	t = (t > 9000) and (t - 10000) or t
	return s, t
end

function B:AddMove(source, destination)
	UpdateLocation(source, destination)
	tinsert(moves, 1, B:EncodeMove(source, destination))
end

function B:ScanBags()
	twipe(bagUnknown)
	twipe(stuckSlots)
	stuckCount = 0

	for _, bag, slot in B.IterateBags(allBags) do
		local bagSlot = B:Encode_BagSlot(bag, slot)
		local itemID = ConvertLinkToID(B:GetItemLink(bag, slot))
		if itemID then
			local name, _, rarity, _, _, _, stackCount = GetItemInfo(itemID)
			local _, itemCount, slotLocked = B:GetItemInfo(bag, slot)

			--A LOCKED SLOT REFUSES EVERY MOVE MADE THROUGH IT, so the sort must plan around
			--it rather than plan through it and discover the refusal one move at a time.
			--
			--This is the client's own flag, the same one the bag frame desaturates on, so a
			--slot recorded here is one of the grey "bugged" items. It is normally transient --
			--set while a move is in flight, cleared when the server confirms -- but a pickup
			--that never resolved leaves it set until a relog, and from then on every sort
			--refuses that slot forever.
			--
			--Skipping at PLAN time matters more than it sounds. Dropping a move mid-queue
			--desynchronises every later move that expected the swap to have happened: measured
			--on 2026-08-08, deferring this exact pair left move 14 moving a Runed Silver Rod
			--where the plan meant it to move Morning Glory Dew. A slot excluded before planning
			--simply is not part of the permutation, and everything else stays consistent.
			if slotLocked then
				stuckSlots[bagSlot] = true
				stuckCount = stuckCount + 1
			end

			--GetItemInfo is the client's own item cache, not a database this addon ships. Ask
			--it about an id the client has never received and it returns NOTHING -- no name,
			--no quality, and crucially no stack size. Server-added items are the common case:
			--a Turtle quest item the client has not cached reads exactly like a broken link.
			--
			--Recorded rather than skipped, because a slot dropped from the scan still exists
			--in the bag and every later pass would then plan moves onto an item it believes
			--is not there. Instead the slot keeps its real count and is treated as
			--UNSTACKABLE, which is the only assumption that is safe without data: it can be
			--swapped around, but nothing will ever be merged into or out of it.
			--[[
				A NEGATIVE COUNT IS CHARGES, NOT A QUANTITY -- and not corruption either.

				MEASURED 2026-09-03, and the first reading of it here was wrong. Three bank
				slots reported by `/octoui-bags locks` came back with `count=-5`, and the
				obvious conclusion was a corrupt cache entry. The item's own tooltip settled
				it: Wizard Oil, itemID 20750, "5 Charges". This client returns an item's
				CHARGES in the count field as a negative number. `quality=-1` alongside it is
				not a symptom either -- vanilla never populated that field reliably and every
				slot reads that way here, which is why bagQualities is taken from the link.

				It still cannot be fed to the stacking arithmetic. `itemCount or 1` passes -5
				through, because -5 is perfectly truthy, and bagMaxStacks gets the item's REAL
				maximum from GetItemInfo -- so a five-charge oil reads as `-5 < 5`, a stack
				with room in it. Stack() then plans a merge and works out -5 + -5 = -10 for
				the result. The comparator orders on the same numbers. Nothing raises; the
				moves are simply wrong, which is the worst shape a sort bug can take.

				So: charges are not a stack size, and an item carrying them must not be
				merged by count. Treated exactly as an uncached item is, by falling into the
				branch below -- count 1 and unstackable. It still gets SWAPPED into position
				like anything else, so charged items sort normally; nothing is ever merged
				into or out of them, which is the only safe reading of a number that is not
				a quantity.

				Note this is NOT why the three slots would not sort. That is the `locked`
				flag above, which excludes a slot from the permutation entirely and survives
				until a relog. Two separate things that arrived on the same slots.
			]]
			if not itemCount or itemCount <= 0 then
				bagUnknown[bagSlot] = itemID
				itemCount = nil
				stackCount = nil
			end

			if not (name and stackCount) then
				bagUnknown[bagSlot] = itemID
				stackCount = itemCount or 1
			end

			bagMaxStacks[bagSlot] = stackCount
			bagIDs[bagSlot] = itemID
			bagQualities[bagSlot] = rarity
			bagStacks[bagSlot] = itemCount or 1
		end
	end
end

function B:IsSpecialtyBag(bagID)
	if safe[bagID] then return false end

	local inventorySlot = ContainerIDToInventoryID(bagID)
	if not inventorySlot then return false end

	--pcall because the slot is only as trustworthy as ContainerIDToInventoryID: hand
	--it a container the client has no inventory slot for and GetInventoryItemLink
	--raises rather than returning nil, which aborts the whole sort from in here.
	local ok, bag = pcall(GetInventoryItemLink, "player", inventorySlot)
	if not ok or not bag then return false end

	local family = GetItemFamily(bag, true)
	if family == 0 or family == nil then return false end

	return family
end

function B:CanItemGoInBag(bag, slot, targetBag)
	local item = bagIDs[B:Encode_BagSlot(bag, slot)]
	local itemFamily = GetItemFamily(item)
	if itemFamily and itemFamily > 0 then
		local equipSlot = select(8, GetItemInfo(item))
		if equipSlot == "INVTYPE_QUIVER" then
			itemFamily = 1
		end
	end
	local bagFamily = GetItemFamily(GetInventoryItemLink("player", ContainerIDToInventoryID(targetBag)), true)

	--A GENERIC bag takes anything. Only a specialty bag restricts, and then only to its own
	--family.
	--
	--The old form returned false whenever itemFamily was nil, which meant an item the
	--family database has never heard of could not be moved ANYWHERE -- and GetItemFamily is
	--a polyfill that returns nil for every id above LAST_ITEM_ID (24283), i.e. for every
	--item this Vanilla+ server added. Unknown now means "not allowed into a specialty bag",
	--which is the cautious reading, rather than "not allowed to move at all".
	if not bagFamily or bagFamily == 0 then return true end
	if not itemFamily or itemFamily == 0 then return false end

	return band(itemFamily, bagFamily) > 0
end

--EVERY PLANNED MOVE, CHECKED ONE AT A TIME.
--
--Aggregates cannot name a culprit. "17 moves planned, queue not draining" is true of a
--soul bag rejecting a bandage, of an item the client has no data for, and of a sort that
--is merely slow, and the three need opposite fixes. This walks the queue move by move and
--says, for each one, which item it is and what is wrong with it.
--
--Run at PLAN time (see AuditPlannedMoves), for two reasons: the bags have not moved yet so
--every read is accurate, and it is the only moment the full queue exists -- StopStacking
--wipes it, and a crash during planning means it is never filled at all.

--A MOVE MUST BE JUDGED AGAINST THE BAGS AS THEY WILL BE WHEN IT RUNS.
--
--The queue is a chain of swaps, so from move two onward the live containers no longer say
--what a slot holds by the time its move is reached. Reading them live for every move
--described move 12's source as the item that move 1 had already moved out of it -- so a
--queue was reported as entirely fine on evidence that was stale for all but the first few
--entries. The verdicts were worthless in exactly the case they exist for.
--
--So the audit keeps a simulation: slots are faulted in from the real bags on first use,
--and each move is applied to it before the next move is judged.

--false means "known to be empty", nil means "not read yet". The distinction is what makes
--lazy faulting possible.
local function ReadSlot(bag, slot)
	local link = B:GetItemLink(bag, slot)
	if not link then return false end

	local id = tonumber(match(link, "item:(%d+)"))
	--Guarded and pcall'd: a link the pattern cannot parse would otherwise reach GetItemInfo
	--as nil, and this is the one function in the file that must never raise -- it exists to
	--explain a crash, so raising inside it would take the explanation with it.
	local name, stackSize
	if id then
		local ok, n, _, _, _, _, _, s = pcall(GetItemInfo, id)
		if ok then name, stackSize = n, s end
	end
	local _, count = B:GetItemInfo(bag, slot)

	return {
		id = id,
		name = name,
		count = count or 1,
		stackSize = stackSize,
		--No name and no stack size together is the signature of an item the client cannot
		--describe. That is the state every piece of stack arithmetic in this file used to
		--assume away.
		known = (name and stackSize) and true or false,
	}
end

local function SimGet(sim, bagSlot)
	local entry = sim[bagSlot]
	if entry == nil then
		entry = ReadSlot(B:Decode_BagSlot(bagSlot))
		sim[bagSlot] = entry
	end
	return entry
end

--OctoUI's own item protection (the padlock, Bags.lua) is a saved list of item ids in
--ElvCharacterDB.LockedItems. It does NOT set the client's `locked` flag, so it cannot by
--itself make a slot refuse a move -- but the two are easy to confuse when a sort stops with
--"locked", so the audit marks it and lets the evidence settle it.
local function Protected(entry)
	if not (entry and entry.id) then return "" end

	local ok, protected = pcall(B.IsItemLocked, B, entry.id)
	return (ok and protected) and " |cffff9900[protected]|r" or ""
end

local function Describe(entry)
	if not entry then return "|cff999999empty|r" end

	return format("%s x%s (id %s%s)%s",
		entry.name or "|cffff0000UNKNOWN ITEM|r",
		tostring(entry.count),
		tostring(entry.id or "?"),
		(entry.id and entry.id > 24283) and ", |cffff9900custom|r" or "",
		Protected(entry))
end

--Merge when the client would merge, swap otherwise -- the same branch DoMove takes.
local function SimApply(sim, source, target)
	local s, t = SimGet(sim, source), SimGet(sim, target)

	if s and t and s.id == t.id and s.known and t.known and t.count < t.stackSize then
		local room = t.stackSize - t.count
		if s.count <= room then
			t.count = t.count + s.count
			sim[source] = false
		else
			s.count = s.count - room
			t.count = t.stackSize
		end
		return
	end

	sim[source], sim[target] = t, s
end

--The legality test CanItemGoInBag performs, but reading live and pcall-wrapped. A bank
--container has no inventory slot, so the unguarded GetInventoryItemLink inside
--CanItemGoInBag can raise -- which is why IsSpecialtyBag has always pcall'd it.
local function CheckLegality(itemID, targetBag)
	local invID = ContainerIDToInventoryID and ContainerIDToInventoryID(targetBag)
	if not invID then return true, nil end

	local ok, bagLink = pcall(GetInventoryItemLink, "player", invID)
	if not ok or not bagLink then return true, nil end

	local bagFamily = GetItemFamily(bagLink, true)
	if not bagFamily or bagFamily == 0 then return true, nil end

	local itemFamily = itemID and GetItemFamily(itemID)
	if not itemFamily or itemFamily == 0 then return false, bagFamily end

	return band(itemFamily, bagFamily) > 0, bagFamily
end

--`sim` carries the simulated bag state forward across the queue. Passing nil audits a single
--move against the bags exactly as they are, which is what the post-mortem on a refused move
--wants.
function B:AuditMove(move, sim)
	sim = sim or {}

	local source, target = B:DecodeMove(move)
	local sourceBag, sourceSlot = B:Decode_BagSlot(source)
	local targetBag, targetSlot = B:Decode_BagSlot(target)

	local s, t = SimGet(sim, source), SimGet(sim, target)

	local problems = ""
	local function flag(text)
		problems = problems..(problems == "" and "" or "; ")..text
	end

	--Ordered worst first, because the first line of a verdict is the one that gets read.
	if s and t and s.id == t.id and not (s.known and t.known) then
		flag("|cffff0000SAME ITEM BOTH ENDS WITH NO STACK SIZE -- nil arithmetic|r")
	end
	if s and not s.known then
		flag("|cffff0000source item has no client data (nil stack size)|r")
	end
	if t and not t.known then
		flag("|cffff0000target item has no client data (nil stack size)|r")
	end

	local legal, bagFamily = CheckLegality(s and s.id, targetBag)
	if not legal then
		flag(format("|cffff0000item is not allowed in bag %d (specialty, family %s)|r",
			targetBag, tostring(bagFamily)))
	end

	if not s then
		flag("|cffff9900source slot is empty -- nothing to pick up|r")
	end
	if targetSlot > (GetContainerNumSlots(targetBag) or 0) then
		flag(format("|cffff0000target slot %d does not exist in bag %d|r", targetSlot, targetBag))
	end
	if source == target then
		flag("|cffff9900move is a no-op, source and target are the same slot|r")
	end

	local suspect = (problems ~= "")

	--Two strings rather than one with a newline in it: AddMessage does not split on \n, it
	--renders the escape, and a wrapped verdict is unreadable in a chat frame.
	return format("  %s bag %d slot %d -> bag %d slot %d | %s -> %s",
		suspect and "|cffff0000X|r" or "|cff00ff00ok|r",
		sourceBag, sourceSlot, targetBag, targetSlot,
		Describe(s), Describe(t)),
		suspect and ("      ^ "..problems) or nil,
		suspect
end

--Called from StartStacking, before the scan tables are wiped and before a single move is
--attempted, so the snapshot survives whatever happens next.
function B:AuditPlannedMoves()
	twipe(plannedMoves)
	twipe(moveVerdicts)
	twipe(suspectVerdicts)
	plannedSuspects = 0

	--One simulated bag state threaded through the whole queue.
	local sim = {}

	--Backwards, because DoMoves executes the queue from the end down. This lists them in
	--the order they will actually be tried, so the first suspect is the one that stops it.
	for i = getn(moves), 1, -1 do
		tinsert(plannedMoves, moves[i])

		local ok, line, problem, suspect = pcall(B.AuditMove, B, moves[i], sim)
		if not ok then
			--An audit that itself raises is the loudest possible result: whatever is wrong
			--with this move is wrong enough to break the code that inspects it.
			line, problem, suspect = format("  |cffff0000X|r move %s could not even be audited",
				tostring(moves[i])), "      ^ |cffff0000"..tostring(line).."|r", true
		end

		--One entry per move, so a verdict can be found by move number -- which is what lets
		--the listing mark the move the sort actually stopped on.
		tinsert(moveVerdicts, {line = line, problem = problem})

		--Suspects are recorded as indices into the above: a full queue is 20-40 lines of chat,
		--worth having on request but it drowns the one line that matters by default.
		if suspect then
			plannedSuspects = plannedSuspects + 1
			tinsert(suspectVerdicts, getn(moveVerdicts))
		end

		--Advanced whether or not the audit succeeded, so one unreadable move does not
		--desynchronise every move after it.
		pcall(SimApply, sim, B:DecodeMove(moves[i]))
	end
end

function B.Compress(...)
	for i = 1, arg.n do
		local bags = arg[i]
		B.Stack(bags, bags, B.IsPartial)
	end
end

function B.Stack(sourceBags, targetBags, canMove)
	if not canMove then canMove = DefaultCanMove end

	for _, bag, slot in B.IterateBags(targetBags, nil, "deposit") do
		local bagSlot = B:Encode_BagSlot(bag, slot)
		local itemID = bagIDs[bagSlot]

		--A locked slot cannot receive; see the note in ScanBags.
		if itemID and not stuckSlots[bagSlot] and (bagStacks[bagSlot] ~= bagMaxStacks[bagSlot]) then
			targetItems[itemID] = (targetItems[itemID] or 0) + 1
			tinsert(targetSlots, bagSlot)
		end
	end

	for _, bag, slot in B.IterateBags(sourceBags, true, "withdraw") do
		local sourceSlot = B:Encode_BagSlot(bag, slot)
		local itemID = bagIDs[sourceSlot]

		--...nor give. A locked slot is out of the sort entirely.
		if itemID and not stuckSlots[sourceSlot] and targetItems[itemID] and canMove(itemID, bag, slot) then
			for i = getn(targetSlots), 1, -1 do
				local targetedSlot = targetSlots[i]
				if bagIDs[sourceSlot] and bagIDs[targetedSlot] == itemID and targetedSlot ~= sourceSlot and not (bagStacks[targetedSlot] == bagMaxStacks[targetedSlot]) and not sourceUsed[targetedSlot] then
					B:AddMove(sourceSlot, targetedSlot)
					sourceUsed[sourceSlot] = true

					if bagStacks[targetedSlot] == bagMaxStacks[targetedSlot] then
						targetItems[itemID] = (targetItems[itemID] > 1) and (targetItems[itemID] - 1) or nil
					end
					if bagStacks[sourceSlot] == 0 then
						targetItems[itemID] = (targetItems[itemID] > 1) and (targetItems[itemID] - 1) or nil
						break
					end
					if not targetItems[itemID] then break end
				end
			end
		end
	end

	twipe(targetItems)
	twipe(targetSlots)
	twipe(sourceUsed)
end

local blackListedSlots = {}
local blackList = {}
local blackListQueries = {}

local function buildBlacklist(arg)
	for entry in pairs(arg) do
		local itemName = GetItemInfo(entry)

		if itemName then
			blackList[itemName] = true
		elseif entry ~= "" then
			if find(entry, "%[") and find(entry, "%]") then
				--For some reason the entry was not treated as a valid item. Extract the item name.
				entry = match(entry, "%[(.*)%]")
			end
			tinsert(blackListQueries, entry)
		end
	end
end

function B.Sort(bags, sorter, invertDirection)
	if not sorter then sorter = invertDirection and ReverseSort or DefaultSort end
	if not itemTypes then BuildSortOrder() end

	--Wipe tables before we begin
	twipe(blackList)
	twipe(blackListQueries)
	twipe(blackListedSlots)
	--These two are wiped at the END as well, which was the only wipe they had. A sort that
	--threw part-way left them populated, and the next sort appended to them -- so bagSorted
	--held slots from a bag group that was no longer being sorted, and the ordering loop below
	--read past the destinations it had. Wiping on entry makes each sort independent of how
	--the last one ended.
	twipe(bagSorted)
	twipe(initialOrder)

	--Build blacklist of items based on the profile and global list
	buildBlacklist(B.db.ignoredItems)
	buildBlacklist(E.global.bags.ignoredItems)

	for i, bag, slot in B.IterateBags(bags, nil, "both") do
		local bagSlot = B:Encode_BagSlot(bag, slot)
		local link = B:GetItemLink(bag, slot)
		local id = B:GetItemID(bag, slot)

		--A locked slot is excluded exactly as a blacklisted one is: left where it is, and not
		--counted as a destination, so the ordering below never assigns anything to it.
		if stuckSlots[bagSlot] then
			blackListedSlots[bagSlot] = true
		end

		if link then
			if blackList[GetItemInfo(id)] then
				blackListedSlots[bagSlot] = true
			end

			if not blackListedSlots[bagSlot] then
				for _, itemsearchquery in pairs(blackListQueries) do
					local success, result = pcall(Search.Matches, Search, link, itemsearchquery)
					if success and result then
						blackListedSlots[bagSlot] = blackListedSlots[bagSlot] or result
						break
					end
				end
			end
		end

		if not blackListedSlots[bagSlot] then
			initialOrder[bagSlot] = i
			tinsert(bagSorted, bagSlot)
		end
	end

	tsort(bagSorted, sorter)

	--Capped. This loop should always terminate -- every pass makes at least one move, and a
	--move it cannot make does not ask for another pass -- but it runs inside the planning
	--phase, where a spin is not a slow sort, it is a hung client with no way out but the task
	--manager. One slot's worth of passes per slot is far more than any real sort needs, so
	--hitting the cap means the reasoning above is wrong, and a mis-sorted bag beats a hang.
	local passLimit = getn(bagSorted) + 10
	local passes = 0

	local passNeeded = true
	while passNeeded and passes < passLimit do
		passes = passes + 1
		passNeeded = false
		local i = 1
		for _, bag, slot in B.IterateBags(bags, nil, "both") do
			local destination = B:Encode_BagSlot(bag, slot)
			local source = bagSorted[i]

			if not blackListedSlots[destination] then
				--A destination the source item is not allowed into can never complete. Fill
				--checks legality and Stack only ever merges onto a slot already holding the
				--same item, but this ordering pass assigned sorted items to every slot in the
				--group with no legality check at all -- including a specialty bag, which takes
				--only its own family. The client refuses such a move forever.
				--
				--Worth keeping, but NOT the freeze: a refused move fails cleanly, and the
				--stall timeout in DoMoves ends it. The freeze is UpdateLocation raising on an
				--item with no stack size, which happens during planning, before any of that
				--machinery exists. See the note there.
				--
				--Decoded only once `source` is known to exist. The previous form called
				--Decode_BagSlot(source) unconditionally and checked `not source` afterwards,
				--which is arithmetic on nil if bagSorted ever runs short of destinations.
				--
				--CheckLegality rather than CanItemGoInBag because this loop also runs over the
				--bank, and the bank container has no inventory slot: the unguarded
				--GetInventoryItemLink inside CanItemGoInBag raises there, which would have
				--stranded bank sorts the same way. CheckLegality pcalls it, as IsSpecialtyBag
				--has always done.
				local legal = true
				if source then
					legal = CheckLegality(bagIDs[source], bag)
				end

				if ShouldMove(source, destination) and legal then
					if not (bagLocked[source] or bagLocked[destination]) then
						B:AddMove(source, destination)
						UpdateSorted(source, destination)
						bagLocked[source] = true
						bagLocked[destination] = true
					else
						passNeeded = true
					end
				end
				i = i + 1
			end
		end
		twipe(bagLocked)
	end

	twipe(bagSorted)
	twipe(initialOrder)
end

function B.FillBags(from, to)
	B.Stack(from, to)
	for _, bag in ipairs(to) do
		if B:IsSpecialtyBag(bag) then
			tinsert(specialtyBags, bag)
		end
	end
	if getn(specialtyBags) > 0 then
		B:Fill(from, specialtyBags)
	end

	B.Fill(from, to)
	twipe(specialtyBags)
end

function B.Fill(sourceBags, targetBags, reverse, canMove)
	if not canMove then canMove = DefaultCanMove end

	--Wipe tables before we begin
	twipe(blackList)
	twipe(blackListedSlots)

	--Build blacklist of items based on the profile and global list
	buildBlacklist(B.db.ignoredItems)
	buildBlacklist(E.global.bags.ignoredItems)

	for _, bag, slot in B.IterateBags(targetBags, reverse, "deposit") do
		local bagSlot = B:Encode_BagSlot(bag, slot)
		if not bagIDs[bagSlot] and not stuckSlots[bagSlot] then
			tinsert(emptySlots, bagSlot)
		end
	end

	for _, bag, slot in B.IterateBags(sourceBags, not reverse, "withdraw") do
		if getn(emptySlots) == 0 then break end
		local bagSlot = B:Encode_BagSlot(bag, slot)
		local targetBag = B:Decode_BagSlot(emptySlots[1])
		local id = B:GetItemID(bag, slot)

		if id and blackList[GetItemInfo(id)] then
			blackListedSlots[bagSlot] = true
		end

		if bagIDs[bagSlot] and not stuckSlots[bagSlot] and B:CanItemGoInBag(bag, slot, targetBag) and canMove(bagIDs[bagSlot], bag, slot) and not blackListedSlots[bagSlot] then
			B:AddMove(bagSlot, tremove(emptySlots, 1))
		end
	end
	twipe(emptySlots)
end

function B.SortBags(...)
	for i = 1, arg.n do
		local bags = arg[i]
		for _, slotNum in ipairs(bags) do
			local bagType = B:IsSpecialtyBag(slotNum)
			if bagType == false then bagType = "Normal" end
			if not bagCache[bagType] then bagCache[bagType] = {} end
			tinsert(bagCache[bagType], slotNum)
		end

		for bagType, sortedBags in pairs(bagCache) do
			if bagType ~= "Normal" then
				B.Stack(sortedBags, sortedBags, B.IsPartial)
				B.Stack(bagCache.Normal, sortedBags)
				B.Fill(bagCache.Normal, sortedBags, B.db.sortInverted)
				B.Sort(sortedBags, nil, B.db.sortInverted)
				twipe(sortedBags)
			end
		end

		if bagCache.Normal then
			B.Stack(bagCache.Normal, bagCache.Normal, B.IsPartial)
			B.Sort(bagCache.Normal, nil, B.db.sortInverted)
			twipe(bagCache.Normal)
		end
		twipe(bagCache)
		twipe(bagGroups)
	end
end

function B:StartStacking()
	--kept for /octoui-bags: once the queue drains there is no way to tell a sort that
	--found nothing to do from one that never got the chance to look
	B.lastPlannedMoves = getn(moves)
	B.failedPickups, B.lastFailedBag = 0, nil
	B.movesDone, B.lastStopReason = 0, nil

	--Before the wipes below and before the first move is tried: the bags still look exactly
	--as they did when these moves were worked out, which is the only state the plan can
	--honestly be judged against.
	B:AuditPlannedMoves()

	--Kept until the NEXT sort starts, so the report still has them after this one ends.
	twipe(deferredMoves)
	twipe(moveStall)

	twipe(bagMaxStacks)
	twipe(bagStacks)
	twipe(bagIDs)
	twipe(bagQualities)
	twipe(moveTracker)

	if getn(moves) > 0 then
		self.SortUpdateTimer:Show()
	else
		B:StopStacking()
	end
end

local function RegisterUpdateDelayed()
	local shouldUpdateFade
 	for _, bagFrame in pairs(B.BagFrames) do
		if bagFrame.registerUpdate then
			bagFrame:UpdateAllSlots()
 			bagFrame.registerUpdate = nil -- call update and re-register events, keep this after UpdateAllSlots
			shouldUpdateFade = true -- we should refresh the bag search after sorting

			bagFrame:RegisterEvent("BAG_UPDATE")
			bagFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")

			for _, event in pairs(bagFrame.events) do
				bagFrame:RegisterEvent(event)
			end
		end
	end
 	if shouldUpdateFade then
		B:RefreshSearch() -- this will clear the bag lock look during a sort
	end
end

function B:StopStacking(message, noUpdate)
	--How the sort ENDED, kept because an abandoned sort and a completed one look identical
	--from outside: StopStacking wipes the queue either way, so `queue 0, timer nil` proves
	--nothing on its own. Misread as success on 2026-08-08, one message after documenting the
	--same class of mistake about lastPlannedMoves.
	B.lastStopReason = message or "finished normally"

	twipe(moves)
	twipe(moveTracker)
	moveRetries, lastItemID, lockStop, lastDestination, lastMove = 0, nil, nil, nil, nil, nil
	stallStart = nil

	self.SortUpdateTimer:Hide()

	if not noUpdate then
		--Add a delayed update call, as BAG_UPDATE fires slightly delayed
		-- and we don't want the last few unneeded updates to be catched
		E:Delay(0.6, RegisterUpdateDelayed)
	end

	if message then
		E:Print(message)
	end
end

function B:DoMove(move)
	if CursorHasItem() then
		return false, "cursorhasitem"
	end

	local source, target = B:DecodeMove(move)
	local sourceBag, sourceSlot = B:Decode_BagSlot(source)
	local targetBag, targetSlot = B:Decode_BagSlot(target)

	local _, sourceCount, sourceLocked = B:GetItemInfo(sourceBag, sourceSlot)
	local _, targetCount, targetLocked = B:GetItemInfo(targetBag, targetSlot)

	if sourceLocked or targetLocked then
		--WHICH side is locked, kept separately. Lumping them cost a full round trip: the sort
		--stopped on a move whose two slots had not been touched by any earlier move, so the
		--lock was pre-existing, and "one of these two" was not enough to say which item was
		--carrying it.
		B.lastLockDetail = format("source bag %d slot %d locked=%s, target bag %d slot %d locked=%s",
			sourceBag, sourceSlot, tostring(sourceLocked),
			targetBag, targetSlot, tostring(targetLocked))

		return false, sourceLocked and (targetLocked and "both slots locked" or "SOURCE slot locked")
			or "TARGET slot locked"
	end

	local sourceItemID = self:GetItemID(sourceBag, sourceSlot)
	local targetItemID = self:GetItemID(targetBag, targetSlot)

	if not sourceItemID then
		if moveTracker[source] then
			return false, "move incomplete"
		else
			return B:StopStacking(L["Confused.. Try Again!"])
		end
	end

	--The execution-side twin of the UpdateLocation crash. With no item data stackSize is nil,
	--`targetCount ~= stackSize` is therefore true, and the next clause adds two numbers and
	--compares the result against nil -- which raises. This one raises inside the OnUpdate
	--handler, so it repeats every tick forever: tremove never runs, the queue never drains,
	--StopStacking is never reached, and the stall timeout at the top of DoMoves cannot fire
	--because DoMove never returns to set the clock it reads.
	--An unknown item takes the plain swap path.
	local _, _, _, _, _, _, stackSize = GetItemInfo(sourceItemID)
	if (sourceItemID == targetItemID) and stackSize and sourceCount and targetCount
		and (targetCount ~= stackSize) and ((targetCount + sourceCount) > stackSize) then
		B:SplitItem(sourceBag, sourceSlot, stackSize - targetCount)
	else
		B:PickupItem(sourceBag, sourceSlot)
	end

	if CursorHasItem() then
		B:PickupItem(targetBag, targetSlot)
	else
		--Nothing on the cursor means the pickup above did not take, so the place never
		--happens and this move accomplishes nothing at all. Counted rather than treated
		--as an error because it is silent by nature; /octoui-bags reports it.
		B.failedPickups = (B.failedPickups or 0) + 1
		B.lastFailedBag = sourceBag
	end

	return true, sourceItemID, source, targetItemID, target
end

--A Lua error in here used to be unrecoverable, and silently so unless the client had error
--display switched on. The OnUpdate handler raises, the tick is abandoned before tremove,
--the queue never drains, StopStacking is never reached, and the timer stays shown -- so
--every later press hits "Already Running.. Bailing Out!" and the only way out is a logout.
--Worse, the stall timeout at the top cannot help: it reads a clock that is only ever set
--AFTER DoMove returns, and a raise means it never returns.
--
--Wrapped, an error now ends the sort the same way any other failure does -- through
--StopStacking without noUpdate, which re-registers the bag frame's events and clears the
--desaturation -- and the message is kept for /octoui-bags.
function B:DoMoves()
	local ok, err = pcall(B.RunMoves, B)
	if not ok then
		B.lastLuaError = tostring(err)
		B:StopStacking(format(L["Sort stopped by a Lua error: %s"], tostring(err)))
	end
end

function B:RunMoves()
	--THE BAG LOCK-UP, measured live on 2026-08-08: `live queue: 10 move(s) left, lockStop
	--0.1s ago, retries 0` -- unchanged for as long as the bags stayed locked.
	--
	--B:DoMove was failing on every tick, and the failure path sets `lockStop = GetTime()`
	--each time. So any timeout measured from lockStop compares against a clock that resets
	--itself and can never elapse; an earlier attempt at this timed out on lockStop and was
	--therefore dead code. The per-pass reset further down wipes lockStop as well, so it
	--cannot carry elapsed time across ticks at all.
	--
	--stallStart is set once on the first failure, survives both resets, and is cleared by
	--any move that succeeds. It is the only thing here that measures how long the sort has
	--genuinely been stuck rather than how long since the last attempt.
	--
	--StopStacking is called WITHOUT noUpdate, so the slots update, the bag frame's events
	--are re-registered and the desaturation clears -- which is what turns this from "log
	--out to recover" into a message and working bags.
	if stallStart and (GetTime() - stallStart) > MAX_STALL_TIME then
		B:StopStacking(L["Sort stopped: a move could not be completed."])
		return
	end

	if CursorHasItem() and currentItemID then
		if lastItemID ~= currentItemID then
			return B:StopStacking(L["Confused.. Try Again!"])
		end

		if moveRetries < 100 then
			local targetBag, targetSlot = self:Decode_BagSlot(lastDestination)
			local _, _, targetLocked = self:GetItemInfo(targetBag, targetSlot)
			if not targetLocked then
				self:PickupItem(targetBag, targetSlot)
				WAIT_TIME = 0.1
				lockStop = GetTime()
				moveRetries = moveRetries + 1
				return
			end
		end
	end

	if lockStop then
		--Kept for the tracked case: a move that landed but whose item never arrived.
		--THE BAG LOCK-UP proper is handled by stallStart at the top of this function.
		--A failed DoMove sets lockStop with an EMPTY moveTracker -- it is
		--wiped immediately before the moves loop below and only refilled by a move that
		--SUCCEEDS. The MAX_MOVE_TIME timeout that would abandon a doomed move lives inside
		--the tracker loop, so with nothing to iterate it is unreachable: lockStop is cleared
		--at the bottom of this function and the same impossible move is retried forever.
		--
		--The visible result is the bug reported 2026-08-05 and caught live on 2026-08-07 --
		--every slot desaturated by SortingFadeBags, the bag frame's events left
		--unregistered, sorting refusing, and a full logout needed. /octoui-bags showed it
		--exactly: `sort timer running: 1, moves the last sort planned: 17` with zero failed
		--pickups, twice, with the move count never draining.
		--
		--StopStacking is called WITHOUT noUpdate, so it restores the slots, re-registers the
		--events and clears the fade.
		if not next(moveTracker) and (GetTime() - lockStop) > MAX_MOVE_TIME then
			B:StopStacking(L["Sort stopped: a move could not be completed."])
			return
		end

		for slot, itemID in pairs(moveTracker) do
			local actualItemID = self:GetItemID(self:Decode_BagSlot(slot))
			if actualItemID ~= itemID then
				WAIT_TIME = 0.1
				if (GetTime() - lockStop) > MAX_MOVE_TIME then
					if lastMove and moveRetries < 100 then
						local success, moveID, moveSource, targetID, moveTarget = self:DoMove(lastMove)
						WAIT_TIME = 0.1

						if not success then
							lockStop = GetTime()
							moveRetries = moveRetries + 1
							return
						end

						moveTracker[moveSource] = targetID
						moveTracker[moveTarget] = moveID
						lastDestination = moveTarget
						-- lastMove = moves[i] --Where does "i" come from???
						lastItemID = moveID
						-- tremove(moves, i) --Where does "i" come from???
						return
					end

					B:StopStacking()
					return
				end
				return --give processing time to happen
			end
			moveTracker[slot] = nil
		end
	end

	lastItemID, lockStop, lastDestination, lastMove = nil, nil, nil, nil
	twipe(moveTracker)

	local success, moveID, targetID, moveSource, moveTarget
	if getn(moves) > 0 then
		for i = getn(moves), 1, -1 do
			success, moveID, moveSource, targetID, moveTarget = B:DoMove(moves[i])
			if not success then
				--DoMove has always returned a reason in its second value when it fails, and
				--this caller has always thrown it away by reading that slot as moveID. It is
				--the difference between "a move failed" and "the client refused the pickup
				--because the target bag will not take this item", so it is kept.
				B.lastFailedMove, B.lastFailedReason = moves[i], tostring(moveID or "unknown")

				--DoMove's "Confused.. Try Again!" branch calls StopStacking and then returns
				--nil, which lands here looking like an ordinary failure. Setting stallStart
				--below would then re-arm a clock StopStacking has just cleared, and the NEXT
				--sort would read it as already five seconds stale and abort on its first tick.
				--A hidden timer is the reliable signal that the sort is already over.
				if not B.SortUpdateTimer:IsShown() then return end

				--ONE STUCK SLOT MUST NOT COST THE WHOLE SORT.
				--
				--This loop returns on the first failure, so a slot the client will not release
				--blocks every move behind it however unrelated they are -- 6 of 17 done and the
				--other 11 abandoned, none of which touched the stuck slot. Measured on
				--2026-08-08: a permanently locked slot, pre-existing rather than caused by the
				--sort, killed the queue at move 7.
				--
				--So a move that keeps failing is dropped from the queue and recorded, and the
				--rest carry on. The overall stall clock is cleared with it, because the sort is
				--making progress again -- what has stalled is one move, not the sort.
				local now = GetTime()
				if not moveStall[moves[i]] then moveStall[moves[i]] = now end

				if (now - moveStall[moves[i]]) > MAX_MOVE_TIME then
					local dropped = moves[i]
					local dropSource, dropTarget = B:DecodeMove(dropped)

					tinsert(deferredMoves, dropped)
					moveStall[dropped] = nil
					tremove(moves, i)

					--AND EVERY LATER MOVE THAT DEPENDED ON IT.
					--
					--The queue is a chain of swaps, so a skipped move leaves its two slots
					--holding what they held rather than what the plan assumed. Any remaining
					--move touching either slot would then act on the wrong item -- observed
					--2026-08-08, where skipping `bag 1 slot 11 <-> bag 3 slot 3` left a later
					--move carrying a Runed Silver Rod off to the slot meant for Morning Glory
					--Dew. Dropping the dependents keeps the bags merely unsorted rather than
					--shuffled wrongly, and a second sort plans afresh from the real state.
					for j = getn(moves), 1, -1 do
						local s, t = B:DecodeMove(moves[j])
						if s == dropSource or s == dropTarget or t == dropSource or t == dropTarget then
							tinsert(deferredMoves, moves[j])
							moveStall[moves[j]] = nil
							tremove(moves, j)
						end
					end

					stallStart = nil
					WAIT_TIME = 0
					return
				end

				WAIT_TIME = 0.1
				lockStop = GetTime()
				--First failure only: this is the clock the give-up test above reads.
				if not stallStart then stallStart = GetTime() end
				return
			end

			--Progress. Anything that moves resets the stall clock.
			stallStart = nil
			moveStall[moves[i]] = nil
			moveTracker[moveSource] = targetID
			moveTracker[moveTarget] = moveID
			lastDestination = moveTarget
			lastMove = moves[i]
			lastItemID = moveID
			tremove(moves, i)
			--Dispatched, not merely planned. This is the number that says whether a sort did
			--anything.
			B.movesDone = (B.movesDone or 0) + 1

			if moves[i - 1] then
				WAIT_TIME = 0
				return
			end
		end
	end

	--Finished, but say so honestly if part of the queue was abandoned. Silence here would
	--read as a clean sort when items are still sitting where they started.
	if getn(deferredMoves) > 0 then
		B:StopStacking(format(L["Sort finished, but %d move(s) could not be completed. Run /octoui-bags to see which."],
			getn(deferredMoves)))
		return
	end

	B:StopStacking()
end

function B:GetGroup(id)
	if match(id, "^[-%d,]+$") then
		local bags = {}
		for b in gmatch(id, "-?%d+") do
			tinsert(bags, tonumber(b))
		end
		return bags
	end
	return coreGroups[id]
end

--Why a bank sort did nothing. The bank is the awkward one of the two: its bag list
--is built from Blizzard constants rather than the hardcoded list the bank frame
--itself uses, its slots only read while the bank is open, and a sort that finds no
--legal move looks exactly like a sort that never ran. Lives here rather than in
--Core/Commands.lua because bankBags and moves are locals of this file.
--The move the client actually refused, and what it said. Printed by BOTH forms of the
--report: it is the single most useful line either can produce, and putting it only in the
--default one meant the person looking at the move list -- exactly the person who needs it --
--never saw it.
--
--Audited with no simulation, against the bags as they are now. The sort has stopped, so
--"now" is the state the refused move was attempted in.
--Raw GetContainerItemInfo, read right now. A lock that is still set after the sort has
--stopped is a property of the slot, not of the sort -- which is the whole question once the
--refusal is known to be a lock. Vanilla returns texture, count, locked, quality, readable.
local function ProbeSlot(label, bag, slot)
	local ok, texture, count, locked, quality, readable = pcall(GetContainerItemInfo, bag, slot)
	if not ok then
		E:Print(format("    %s bag %d slot %d: |cffff0000read failed: %s|r", label, bag, slot, tostring(texture)))
		return
	end

	--Both kinds of lock side by side. If the client says locked while the sort is stopped and
	--nothing is on the cursor, the flag is a property of the item, not of a move in flight --
	--and if the same slot is also [protected], the two are worth comparing.
	local okProt, protected = pcall(B.IsSlotLocked, B, bag, slot)

	E:Print(format("    %s bag %d slot %d: client locked=%s%s, OctoUI protected=%s, count=%s, quality=%s, readable=%s, texture=%s",
		label, bag, slot,
		tostring(locked),
		locked and " |cffff0000<- STILL LOCKED|r" or "",
		okProt and tostring(protected) or "?",
		tostring(count), tostring(quality), tostring(readable),
		texture and "yes" or "none"))
end

--Moves the sort gave up on so the rest of the queue could run. These are the items that did
--not end up where the sort wanted them, and the only record that anything was left undone.
local function PrintDeferred()
	if getn(deferredMoves) == 0 then return end

	E:Print(format("|cffff9900%d move(s) abandoned so the rest of the sort could finish:|r",
		getn(deferredMoves)))

	for _, move in ipairs(deferredMoves) do
		local ok, line, problem = pcall(B.AuditMove, B, move)
		E:Print(ok and line or format("  |cffff0000could not audit move %s: %s|r", tostring(move), tostring(line)))
		if ok and problem then E:Print(problem) end

		--Probed live: a lock still set here is the stale kind that survives a sort, which is
		--a different problem from one that was merely in flight when the move was tried.
		local okDecode, source, target = pcall(B.DecodeMove, B, move)
		if okDecode then
			ProbeSlot("source", B:Decode_BagSlot(source))
			ProbeSlot("target", B:Decode_BagSlot(target))
		end
	end
end

local function PrintLastFailure()
	if not B.lastFailedMove then return end

	--A refusal that the sort then recovered from is NOT a failure, and must not be dressed as
	--one. Locks are normally transient -- set while a move is in flight, cleared when the
	--server confirms -- so a move being refused once and succeeding on retry is the system
	--working. Observed 2026-08-08: a clean 13-of-13 sort still carried a red "the client
	--REFUSED this move" line, which reads as a fault on a run that had none.
	--
	--The queue draining with nothing deferred is what says it recovered.
	local recovered = (getn(deferredMoves) == 0)
		and ((B.movesDone or 0) >= getn(plannedMoves))
		and (getn(plannedMoves) > 0)

	if recovered then
		E:Print(format("|cff999999one move was refused mid-sort (%s) and went through on retry -- the sort still completed.|r",
			tostring(B.lastFailedReason)))
		return
	end

	E:Print(format("|cffff0000the client REFUSED this move, reason: %s|r", tostring(B.lastFailedReason)))

	local ok, line, problem = pcall(B.AuditMove, B, B.lastFailedMove)
	E:Print(ok and line or format("  |cffff0000could not audit it: %s|r", tostring(line)))
	if ok and problem then E:Print(problem) end

	if B.lastLockDetail then
		E:Print(format("  when it was refused: %s", tostring(B.lastLockDetail)))
	end

	--Probed live, so a lock that has since cleared is distinguishable from one that has not.
	local okDecode, source, target = pcall(B.DecodeMove, B, B.lastFailedMove)
	if okDecode then
		E:Print("  the two slots as the client reports them right now:")
		ProbeSlot("source", B:Decode_BagSlot(source))
		ProbeSlot("target", B:Decode_BagSlot(target))
	end
end

--[[
	Every slot the CLIENT reports as locked, read right now.

	The existing `stuckSlots` list only fills in when a sort is PLANNED, so it answers
	nothing for somebody looking at two greyed-out squares who has not sorted. This walks
	the bags and the bank as they are and names them.

	A METHOD ON B RATHER THAN A LOCAL FUNCTION, deliberately, and this is not a style
	choice. `B:SortReport` already sits at exactly 32 upvalues, which is Lua 5.0's hard
	ceiling -- one more name from this file referenced inside it is a COMPILE error that
	takes all of Sort.lua out of the build, and a file that does not load takes bag sorting
	with it and says nothing. Calling `B:LockedSlotsReport()` from there charges only `B`,
	which is charged already. Adding `allBags` and `GetContainerItemInfo` to SortReport
	instead would have made it 34. Check with
	`python ../octoui-dev/tools/lua50upvalues.py Modules/Bags` after touching either.

	What the answer means: a client lock set while nothing is on the cursor and no sort is
	running is not something this addon can set or clear. It is the client's own in-flight
	flag for a move the server never confirmed, and CLAUDE.md records that it survives
	/reload and needs a full relog. Lag is the usual reason the confirmation never arrived.
]]
function B:LockedSlotsReport()
	E:Print("|cff00ff00slots the CLIENT reports as locked, read right now:|r")

	local found = 0
	local readable = 0

	for _, bag in ipairs(allBags) do
		local slots = GetContainerNumSlots(bag) or 0
		readable = readable + slots

		for slot = 1, slots do
			local ok, _, _, slotLocked = pcall(GetContainerItemInfo, bag, slot)
			if ok and slotLocked then
				found = found + 1
				ProbeSlot("locked", bag, slot)
			end
		end
	end

	--Zero readable slots is not "no locks", it is "nothing was read". The bank's bags
	--report no slots at all while the bank is closed, so a scan run away from the banker
	--covers the carried bags only and would report a clean bank it never looked at.
	if readable == 0 then
		E:Print("  |cffff9900no slots could be read at all. Are the bags loaded?|r")
		return
	end

	if found == 0 then
		E:Print(format("  none, across %d readable slot(s). If the bank is not open, its bags were NOT included -- walk to a banker and run this again.", readable))
		return
	end

	E:Print(format("  |cffff0000%d locked slot(s)|r out of %d readable.", found, readable))
	E:Print("  Nothing on the cursor and no sort running means this is the client's own")
	E:Print("  in-flight flag for a move the server never confirmed. It is not OctoUI's")
	E:Print("  padlock, this addon cannot clear it, and it survives /reload -- relog.")
end

function B:SortReport(msg)
	--`/octoui-bags moves` prints the verdict for every planned move. The default prints only
	--the failing ones, because a full bag sort plans 20-40 and a chat frame that long buries
	--the answer. Both walk the same audit -- every move is checked either way, only the
	--printing differs.
	--Routed through B: so this branch adds no upvalue to SortReport, which has none
	--spare. See the note on B:LockedSlotsReport.
	if msg and lower(msg) == "locks" then
		B:LockedSlotsReport()
		return
	end

	local movesOnly = msg and (lower(msg) == "moves" or lower(msg) == "move")

	if movesOnly then
		E:Print(format("every move the last sort planned (%d), in the order they are tried:",
			getn(plannedMoves)))

		if getn(moveVerdicts) == 0 then
			E:Print("  |cffff9900nothing planned -- either no sort has run since login, or the sort threw before it planned anything. Run /octoui-bags for the Lua error line.|r")
		end

		--The move after the last one dispatched is the one the sort died on. Marked rather
		--than left to be counted by hand, because "6 dispatched" and a 40-line list is a
		--needless puzzle -- and the marked line is the whole answer when nothing is flagged.
		--
		--Only when the queue genuinely did not drain. Deferred moves also leave dispatched
		--short of the plan, and marking a move the sort ran straight past reads as a failure
		--that never happened.
		local dispatched = B.movesDone or 0
		local accounted = dispatched + getn(deferredMoves)
		local stopAt = (accounted < getn(plannedMoves)) and (dispatched + 1) or nil

		for i, v in ipairs(moveVerdicts) do
			E:Print(v.line..((i == stopAt) and "  |cffff0000<- STOPPED HERE|r" or ""))
			if v.problem then E:Print(v.problem) end
		end

		E:Print(format("%d of %d moves cannot complete; %d dispatched before it stopped.",
			plannedSuspects, getn(plannedMoves), dispatched))

		PrintDeferred()
		PrintLastFailure()
		return
	end

	E:Print(format("constants: BANK_CONTAINER %s, NUM_BAG_SLOTS %s, NUM_BANKBAGSLOTS %s",
		tostring(BANK_CONTAINER), tostring(NUM_BAG_SLOTS), tostring(NUM_BANKBAGSLOTS)))

	--Frame and sorter now share B.BankIDs, so this can no longer disagree with what the
	--bank window is showing -- it is printed to catch the constants changing under us
	local ids = ""
	for _, id in ipairs(bankBags) do
		ids = ids..(ids == "" and "" or ",")..id
	end
	E:Print(format("bank sort group: %d bags [%s] -- the bank frame shows 8 (-1 plus 5-11)",
		getn(bankBags), ids))

	local readable = 0
	for _, id in ipairs(bankBags) do
		local slots = GetContainerNumSlots(id) or 0
		if slots > 0 then readable = readable + 1 end

		--IsSpecialtyBag resolves the bag item through this; vanilla's version is only
		--correct for bags 1-4, so a wrong or empty answer here for 5-11 means specialty
		--bank bags (quivers, soul bags) are being treated as ordinary ones
		local invID = ContainerIDToInventoryID and ContainerIDToInventoryID(id)
		local ok, link = pcall(GetInventoryItemLink, "player", invID)

		E:Print(format("  bag %d: %d slots, inventory id %s, bag item %s",
			id, slots, tostring(invID),
			(not ok) and "|cffff0000invalid slot|r" or (link and "found" or "none")))
	end

	E:Print(format("%d of %d bank containers readable -- 0 slots means either no bag in that slot or the bank is shut",
		readable, getn(bankBags)))

	--The decorator refuses to start while this is shown. If a previous run never
	--finished it stays up, and every later click bails out instead of sorting.
	E:Print(format("sort timer running: %s, moves the last sort planned: %s, disableBankSort %s",
		tostring(B.SortUpdateTimer and B.SortUpdateTimer:IsShown()),
		tostring(B.lastPlannedMoves or "no sort run yet"),
		tostring(E.db.bags.disableBankSort)))

	--LIVE state, which is what a stall actually needs and what this report was missing.
	--`lastPlannedMoves` above is a snapshot taken when the sort was planned and never
	--decreases, so it says nothing about progress -- it was misread twice on 2026-08-07 as
	--"N moves are stuck" when it only ever meant "N were planned".
	--
	--The queue length is the number that moves. lockStop tells you whether DoMoves is
	--waiting on a move to land, and the cursor is the other way a sort wedges: an item
	--picked up and never put down blocks everything after it.
	--PLAYER BAGS, with what the sorter thinks each one IS.
	--
	--A specialty bag the sorter does not recognise is the worst case: it gets treated as
	--ordinary storage, the sort plans moves putting normal items into it, and the client
	--refuses every one of them forever. A warlock's soul bag is the obvious example and is
	--what prompted this -- "if it's trying to put anything other than a soul shard into the
	--soul shard bag then it wont work".
	--
	--GetItemFamily here is a POLYFILL (Compatibility/api/wowAPI.lua): 1.12 has no such API,
	--so it reads a static table and **returns nil for any item id above LAST_ITEM_ID
	--(24283)**. IsSpecialtyBag treats nil exactly like 0, so a custom bag this server added
	--is silently classified as generic. That is the difference this line exposes.
	E:Print("player bags -- what the sorter thinks each one is:")
	for bagID = 0, NUM_BAG_SLOTS do
		local slots = GetContainerNumSlots(bagID) or 0
		local link = (bagID > 0) and GetInventoryItemLink("player", ContainerIDToInventoryID(bagID)) or nil
		local id = link and tonumber((select(3, find(link, "(%d+):")))) or nil
		local family = link and GetItemFamily(link, true)
		local special = B:IsSpecialtyBag(bagID)

		E:Print(format("  bag %d: %d slots, item id %s, family %s, specialty: %s%s",
			bagID, slots, tostring(id or "backpack"), tostring(family),
			special and format("|cff00ff00yes (%s)|r", tostring(special)) or "|cffff9900no|r",
			(id and id > 24283) and " |cffff0000<- id above LAST_ITEM_ID, family is UNKNOWABLE|r" or ""))
	end

	E:Print(format("last sort: %s planned, %s dispatched, ended: %s",
		tostring(B.lastPlannedMoves or "none"),
		tostring(B.movesDone or 0),
		tostring(B.lastStopReason or "never stopped")))

	E:Print(format("live queue: %d move(s) left, lockStop %s, retries %d, cursor holding an item: %s",
		getn(moves),
		lockStop and format("%.1fs ago", GetTime() - lockStop) or "not set",
		moveRetries or 0,
		CursorHasItem() and "|cffff0000yes|r" or "no"))

	--A move whose pickup never reached the cursor is reported as a success by DoMove,
	--so this is the only place the silence shows up
	E:Print(format("moves whose pickup never reached the cursor: %s%s",
		tostring(B.failedPickups or 0),
		B.lastFailedBag and format(" (last in bag %d)", B.lastFailedBag) or ""))

	--THE ANSWER, if there is one. Everything above is context.
	--
	--A Lua error is reported first because it outranks the rest: it means the sort did not
	--finish its own code, so the counts above describe a run that was cut off mid-way rather
	--than a run that tried and failed.
	if B.lastLuaError then
		E:Print(format("|cffff0000last Lua error during a sort: %s|r", tostring(B.lastLuaError)))
	end

	--Slots the last scan found locked, and therefore left out of the sort entirely. These are
	--the grey "bugged" items: the sort no longer plans through them, so it completes, but
	--they stay where they are until the lock clears.
	if stuckCount > 0 then
		E:Print(format("|cffff9900%d slot(s) were LOCKED when the sort was planned and were left out of it:|r", stuckCount))

		for bagSlot in pairs(stuckSlots) do
			local bag, slot = B:Decode_BagSlot(bagSlot)
			local link = B:GetItemLink(bag, slot)
			E:Print(format("  bag %d slot %d: %s", bag, slot, link or "no link"))
			ProbeSlot("  now", bag, slot)
		end

		E:Print("|cffff9900  A lock that never clears is client state, not a sort bug -- it survives until the server resyncs that slot. Relogging is what clears it.|r")
	end

	PrintDeferred()
	PrintLastFailure()

	E:Print(format("planned-move audit: %d of %d cannot complete, %d dispatched%s",
		plannedSuspects, getn(plannedMoves), B.movesDone or 0,
		(plannedSuspects > 0) and " |cffff0000<- these are the items breaking the sort|r" or ""))

	for _, idx in ipairs(suspectVerdicts) do
		local v = moveVerdicts[idx]
		if v then
			E:Print(v.line)
			if v.problem then E:Print(v.problem) end
		end
	end

	--Unstackable-by-assumption is a real behaviour change for these slots, so they are named
	--whether or not they broke anything: an item listed here sorts, but never merges.
	local unknown = ""
	local unknownCount = 0
	for bagSlot, itemID in pairs(bagUnknown) do
		local bag, slot = B:Decode_BagSlot(bagSlot)
		unknownCount = unknownCount + 1
		if unknownCount <= 10 then
			unknown = unknown..(unknown == "" and "" or ", ")..format("id %d @ bag %d slot %d", itemID, bag, slot)
		end
	end

	if unknownCount > 0 then
		E:Print(format("|cffff9900%d item(s) this client has NO data for (no name, no stack size): %s%s|r",
			unknownCount, unknown, (unknownCount > 10) and ", ..." or ""))
		E:Print("|cffff9900  These are the server's own items. They are sorted but never stacked, because a stack size that does not exist cannot be compared against.|r")
	end

	E:Print(format("|cff999999run|r /octoui-bags moves |cff999999for the verdict on all %d planned moves.|r",
		getn(plannedMoves)))
end

function B:CommandDecorator(func, groupsDefaults)
	return function(groups)
		--Aborting a running sort MUST restore what that sort switched off.
		--
		--This passed noUpdate = true, which skips RegisterUpdateDelayed -- and that is the
		--only thing that calls UpdateAllSlots, RE-REGISTERS the bag frame's events, and runs
		--RefreshSearch to clear the desaturation. StopStacking below hides the timer and
		--wipes the move list, so this genuinely aborts the sort; leaving the frame with its
		--events unregistered means it never hears BAG_UPDATE again and the slots stay grey
		--and dead until the UI is rebuilt.
		--
		--That is the bug reported 2026-08-05 and finally caught live on 2026-08-07: bags
		--grey, items unusable, sorting refusing, and **a full logout needed**. Pressing sort
		--again did not recover it -- it came straight back here and stranded the frame a
		--second time. Captured by /octoui-bags mid-failure: `sort timer running: 1, moves the
		--last sort planned: 25`, a sort left part-finished with its timer still up.
		if self.SortUpdateTimer:IsShown() then
			B:StopStacking(L["Already Running.. Bailing Out!"])
			return
		end

		twipe(bagGroups)
		if not groups or getn(groups) == 0 then
			groups = groupsDefaults
		end
		for bags in gmatch(groups or "", "%S+") do
			bags = B:GetGroup(bags)
			if bags then
				tinsert(bagGroups, bags)
			end
		end

		--Cleared per run, not per queue: a sort that throws during planning never reaches
		--StartStacking, so anything reset there would still be describing the run before it.
		B.lastLuaError, B.lastFailedMove, B.lastFailedReason = nil, nil, nil

		--THE PLANNING PHASE, WHICH IS WHERE THE FREEZE ACTUALLY LIVES.
		--
		--By the time this runs the sort button has already unregistered the bag frame's
		--events and desaturated every slot. Nothing restores that except RegisterUpdateDelayed,
		--and the only route to it is StopStacking. If ScanBags or the sorter raises -- and
		--UpdateLocation raised on any two copies of an item the client has no stack size for --
		--then StartStacking is never reached, the timer never shows, StopStacking never runs,
		--and the bags stay grey and dead with no error on screen. Every timeout added to
		--DoMoves was irrelevant to this, because DoMoves never got to run.
		--
		--pcall'd, a planning error now takes the same exit as any other failure and says what
		--it was.
		local ok, err = pcall(function()
			B:ScanBags()
			return func(unpack(bagGroups))
		end)

		if not ok then
			B.lastLuaError = tostring(err)

			--Audited BEFORE StopStacking wipes the queue. Planning throws part-way, so what is
			--in `moves` is every move it managed to work out before it hit the item it could
			--not handle -- and the last entry is the neighbourhood of the culprit. The scan
			--tables are still intact here because StartStacking, which wipes them, was never
			--reached.
			B.lastPlannedMoves = getn(moves)
			pcall(B.AuditPlannedMoves, B)

			--Leaves the queue and the scan tables wiped, the frames restored, and the button
			--usable again rather than stuck on "Already Running".
			twipe(bagGroups)
			B:StopStacking(format(L["Sort stopped by a Lua error: %s"], tostring(err)))
			return
		end

		if err == false then
			--The sorter opting out. Still has to restore the frames the button faded.
			twipe(bagGroups)
			B:StopStacking()
			return
		end

		twipe(bagGroups)
		B:StartStacking()
	end
end